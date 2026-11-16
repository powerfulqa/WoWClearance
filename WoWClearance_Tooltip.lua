-- WoWClearance_Tooltip - bag-item tooltip annotation system.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8c of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The tooltip annotation surface that decorates every bag item with a
-- coloured line indicating what WC will do (Will Sell / Protected -
-- Allowed - Account Sell /
-- etc.). Self-contained UI subsystem hooked at addon load against
-- GameTooltip + ItemRefTooltip.
--
-- Moved into this file:
--   * WC_AnnotateTooltip - the per-tooltip body that produces a humane
--     status line. Since v2.71.2 (classifier Stage 3) it reads all state
--     from NS.Decision.buildTooltipCtx and its final label is guarded by
--     NS.Decision.sell's verdict (a sentinel line surfaces any label
--     branch that falls behind the core); the per-branch labels remain
--     hand-written because they need the WHY, not just yes/no.
--   * WC_ClearTooltipFlag - resets the per-tooltip dedupe flag
--     (recipe tooltips fire OnTooltipSetItem twice; the flag prevents
--     duplicate annotation lines).
--   * WC_InstallTooltipHookOnce - installs the OnTooltipSetItem +
--     OnTooltipCleared hooks on GameTooltip + ItemRefTooltip. Exposed
--     as NS.InstallTooltipHookOnce.
--
-- Cross-file dependencies read inline:
--   * NS.compCache (Core) - isDowngradeVsEquipped,
--     getEquippedILvl, INVTYPE_SLOTS, baselineProtectedIDs, qualityNames
--   * NS.DB / NS.ADB - captured at function entry
--   * NS.IsAddonEnabledForChar (WoWClearance_Events.lua) - early-out gate
--   * Various WoW globals - ITEM_QUALITY_COLORS, GetItemInfo, etc.

local NS = select(2, ...)
local WC_compCache = NS.compCache

-- Localization lookup. Verdict labels are wrapped at the point they are
-- built; see the WC-TRAP note on statusTag below for why the displayed
-- string can no longer be introspected once it may be translated.
local L = NS.L
local IsInSet = NS.IsInSet

-- Allow Sell destination rewrite. Walks the explicit-list precedence
-- chain when a protection (tome / recipe) has been
-- manually allow-listed and decides what the tooltip should say:
--   * Keep List membership returns currentLine unchanged (the earlier
--     Keep label stays - blacklist wins over Allow Sell).
--   * deleteList -> Will Delete
--   * account whitelist -> Will Sell (your Account List)
--   * character whitelist -> Will Sell (your Character List)
--   * no list claims it -> nil, and the caller picks the fallback
--     ("Override on - add to a list to sell" for Allow Sell prompts,
-- The pre-extraction code duplicated this chain across the
-- tome blocks; centralising removes the drift surface so a future
-- protection rule reuses the same precedence without paired edits.
-- Returns (line, tag). tag is an English token the caller uses for logic
-- (see statusTag below); the line is the localized display string. The
-- blacklist case returns the caller's current line/tag unchanged.
-- v2.71.3 (classifier Stage 4): reads the decision ctx, and the Will
-- Delete line requires Decision.deleteEligible - a listed item the
-- v2.50.2 rescues would skip falls through to its real destination.
local function destinationLabel(ctx, currentLine, currentTag)
    if ctx.blacklisted then
        return currentLine, currentTag
    end
    if ctx.onDeleteList and ctx.enableDeletion and NS.Decision.deleteEligible(ctx) then
        return "|cffff4444" .. L["Will Delete"] .. "|r", "willdelete"
    end
    if ctx.whitelistedAccount then
        return "|cffb6ffb6" .. L["Will Sell (your Account List)"] .. "|r", "willsell"
    end
    if ctx.whitelistedChar then
        return "|cffb6ffb6" .. L["Will Sell (your Character List)"] .. "|r", "willsell"
    end
    return nil
end

-- Tooltip annotation. Adds a coloured line indicating whether WoWClearance
-- will sell, protect, or delete the hovered item. Hooked once on addon load
-- against GameTooltip and ItemRefTooltip (chat-linked items use the latter).
--
-- Dedupe: recipe tooltips fire OnTooltipSetItem twice (once for the recipe,
-- once for the embedded result), so we flag the tooltip after adding a line
-- and clear the flag when the tooltip is reset.
local WC_tooltipHooked = false

-- v2.71.2 (classifier Stage 3): this surface consumes the decision core.
-- NS.Decision.buildTooltipCtx supplies the ONE state snapshot every read
-- below uses (instance predicates routed to the liveTooltip* scanners),
-- and NS.Decision.sell's verdict guards the final label via a sentinel -
-- a Will Sell label the engine would refuse (or vice versa) surfaces as
-- a visible mismatch line instead of a silent lie. The per-branch label
-- selection stays hand-written (it needs the WHY at a granularity a
-- single winning token can't carry); if you change the core's logic,
-- update the matching label branch so the label matches the verdict.
local function WC_AnnotateTooltipInner(tooltip, out)
    local DB = NS.DB
    if not DB or not tooltip or not tooltip.GetItem then
        return
    end
    -- Honour the addon-enabled toggle and per-character allowlist. If the
    -- addon won't act on the item, don't mislead the user by annotating it.
    if NS.IsAddonEnabledForChar and not NS.IsAddonEnabledForChar() then
        return
    end
    local _, link = tooltip:GetItem()
    if not link then
        return
    end
    local id = tonumber(link:match("|Hitem:(%d+)"))
    if not id then
        return
    end

    -- One snapshot for every read below (GetItemInfo included) - the
    -- live-tooltip sibling of the adapter the vendor engine uses.
    local ctx = NS.Decision and NS.Decision.buildTooltipCtx(tooltip, id)
    if not ctx then
        return
    end
    local itemQuality, itemILvl, itemEquipLoc, itemSellPrice = ctx.quality, ctx.ilvl, ctx.equipLoc, ctx.sellPrice

    -- WC-TRAP: statusLine is the DISPLAYED verdict and may be translated, so
    -- it can no longer be introspected for logic (a frFR client's "Vente" will
    -- not match :find("Will Sell")). statusTag carries the English verdict
    -- token instead - every statusLine assignment sets a matching tag, and the
    -- downstream "is this a Will Sell / tome-known verdict?"
    -- checks read the tag, never the string. Do NOT reintroduce
    -- statusLine:find(...) for control flow.
    local statusLine, statusTag
    if ctx.blacklisted then
        -- v2.10.0: distinguish "user manually blacklisted this" from "the
        -- auto-protect-equipped path added it". DB.blacklistAuto is stamped
        -- only by the equipment handler / one-shot sync; manual adds don't
        -- touch it. The suffix is concatenated onto the existing label so
        -- the annotation stays a single line. The suffix tells the user
        -- "this is on Keep because you equipped it, not because you hand-
        -- added it" - useful when they expected an item to vendor and want
        -- to know why the rules are leaving it alone. The override is the
        -- existing Alt+Right-Click context menu's "Remove from Blacklist"
        -- row.
        local autoTag = DB.blacklistAuto and DB.blacklistAuto[id]
        if autoTag then
            -- v2.12.0: origin-aware label. The auto-protect path stamps
            -- one of two string tags so the tooltip can tell the user
            -- WHICH rule kept the item. Legacy boolean-true entries from
            -- v2.10.0 / v2.11.0 fall back to the generic label.
            if autoTag == "equipped" then
                statusLine = "|cffffb84d" .. L["Keep (equipped)"] .. "|r"
            elseif autoTag == "upgrade" then
                statusLine = "|cffffb84d" .. L["Keep (upgrade)"] .. "|r"
            elseif autoTag == "set" then
                -- v2.13.0: items from a saved Blizzard Equipment Manager set.
                -- Most likely an off-set / dual-spec piece sitting in bags
                -- between swaps; the tag promotes to "(equipped)" the next
                -- time the user actually equips it.
                statusLine = "|cffffb84d" .. L["Keep (in gear set)"] .. "|r"
            else
                statusLine = "|cffffb84d" .. L["Keep (auto)"] .. "|r"
            end
        elseif ctx.hostLocked and not IsInSet(DB.blacklist, id) then
            statusLine = "|cffffb84d" .. L["Keep (locked)"] .. "|r"
        else
            statusLine = "|cffffb84d" .. L["Keep"] .. "|r"
        end
        statusTag = "keep"
    elseif ctx.onDeleteList and ctx.enableDeletion and NS.Decision.deleteEligible(ctx) then
        -- v2.71.3 (classifier Stage 4): the Will Delete label requires the
        -- core's delete gate, so a listed item the v2.50.2 rescues would
        -- skip (account Sell List / equipped) falls
        -- through to its real verdict instead of threatening a delete
        -- that will never fire. (Keep List is the branch above.)
        statusLine = "|cffff4444" .. L["Will Delete"] .. "|r"
        statusTag = "willdelete"
    elseif ctx.whitelistedChar or ctx.whitelistedAccount then
        -- Honesty: the engine also requires sellPrice > 0 and not currently
        -- equipped. Without these checks the tooltip used to claim "Will Sell"
        -- on items that the merchant cycle correctly refuses (custom items
        -- with no vendor price, or items the player has equipped). Surface
        -- both reasons in warning-yellow so the user sees them at the point
        -- of decision instead of wondering why the cycle skipped them.
        if ctx.equipped then
            statusLine = "|cffffb84d" .. L["Won't Sell (equipped)"] .. "|r"
            statusTag = "wontsell"
        elseif not (itemSellPrice and itemSellPrice > 0) then
            statusLine = "|cffffb84d" .. L["Won't Sell (no value)"] .. "|r"
            statusTag = "wontsell"
        else
            statusLine = "|cffb6ffb6" .. L["Will Sell"] .. "|r"
            statusTag = "willsell"
        end
    elseif DB.qualityRules then
        local quality, ilvl, equipLoc, sellPrice = itemQuality, itemILvl, itemEquipLoc, itemSellPrice
        -- Grey-quality invariant. WC_IsSellable's "isJunk" branch always
        -- matches a grey item with a positive sell price - independent of
        -- DB.qualityRules, useEquippedILvl, bind filter, or any other
        -- rule setting. Mirror that here so users see why an Item-Level
        -- 47 grey shoulderpad on their level-80 character will vendor.
        -- Reported by an in-game tester via Discord: "I dont see the Will
        -- Sell - Junk".
        if sellPrice and sellPrice > 0 and DB.sellGreys ~= false and (quality == 0 or ctx.hostMarkedJunk) then
            statusLine = "|cffb6ffb6" .. L["Will Sell (junk)"] .. "|r"
            statusTag = "willsell"
        elseif quality and quality >= 1 and quality <= 4 and sellPrice and sellPrice > 0 then
            local rule = ctx.qualityRule
            if rule and rule.enabled then
                local rarityName = (quality == 1) and L["White"]
                    or (quality == 2) and L["Green"]
                    or (quality == 3) and L["Blue"]
                    or L["Epic"]
                local hasVisibleILvl = equipLoc and equipLoc ~= "" and ilvl and ilvl > 0
                -- v2.12.0: split on useEquippedILvl mode. Dynamic-cap mode
                -- mirrors WC_compCache.isDowngradeVsEquipped semantics so
                -- the tooltip is honest about what will / won't sell.
                local matchesILvl = false
                local matchedAgainstEquipped = false
                -- v2.44.6: capture the reason isDowngradeVsEquipped gives
                -- back so the "Keep (possible upgrade)" branch below can
                -- distinguish "this item type has no equipment slot we
                -- can compare against" (ammo, bags, tabards, class-
                -- restricted relics) from "real upgrade candidate". Both
                -- previously fell into the "possible upgrade" branch,
                -- mislabelling Doomshot etc.
                local equipReason = nil
                local cap = rule.maxILvl or 0
                if rule.useEquippedILvl then
                    matchedAgainstEquipped = true
                    if hasVisibleILvl then
                        local downgrade, reason = WC_compCache.isDowngradeVsEquipped(id, ilvl, equipLoc)
                        if downgrade then
                            matchesILvl = true
                        end
                        equipReason = reason
                    end
                else
                    matchesILvl = (cap == 0) or (hasVisibleILvl and ilvl <= cap)
                end
                if matchesILvl and ctx.isQuestItem then
                    -- v2.13.x: quest-item safety-net honesty. After the
                    -- v2.13.x narrowing, WC_IsSellable returns false when
                    -- a qualityPass auto-rule would catch a quest-class
                    -- item. Reflect that here so the tooltip doesn't
                    -- claim "Will Sell" when the merchant cycle will
                    -- silently skip. The whitelist match path above is
                    -- unaffected (whitelist overrides safety net).
                    statusLine = "|cffffb84d" .. L["Keep (quest item)"] .. "|r"
                    statusTag = "keep"
                elseif matchesILvl and ctx.baselineProtected and not ctx.allowedItem then
                    -- Baseline profession-tool safety net (Monrad's report).
                    -- Same honesty as the quest-item case: the auto-rule
                    -- sweep would have caught the tool but WC_IsSellable
                    -- vetoes; the tooltip should say so. Allow Sell
                    -- override unsets this annotation (the item flows to
                    -- the normal sell path).
                    statusLine = "|cffffb84d" .. L["Keep (profession tool)"] .. "|r"
                    statusTag = "keep"
                elseif matchesILvl then
                    -- v2.10.0: bind-filter check. WC_IsSellable applies this
                    -- AFTER the iLvl gate; the tooltip annotation has to
                    -- mirror the same chain so users get an accurate read
                    -- of what the rules will do at the next vendor visit.
                    local bindFilter = rule.bindFilter or "any"
                    local bindRejected = false
                    if bindFilter ~= "any" then
                        local bindType = ctx.bindType()
                        if bindType ~= bindFilter then
                            bindRejected = true
                        end
                    end
                    if bindRejected then
                        local fLabel = (bindFilter == "boe") and L["BoE"] or L["BoP"]
                        statusLine = string.format(
                            "|cffffb84d" .. L["Keep (%s rule wants %s only)"] .. "|r",
                            rarityName,
                            fLabel
                        )
                        statusTag = "keep"
                    elseif matchedAgainstEquipped then
                        statusLine = string.format(
                            "|cffb6ffb6" .. L["Will Sell (%s, lower than equipped)"] .. "|r",
                            rarityName
                        )
                        statusTag = "willsell"
                    elseif cap == 0 then
                        statusLine = string.format(
                            "|cffb6ffb6" .. L["Will Sell (%s)"] .. "|r",
                            rarityName
                        )
                        statusTag = "willsell"
                    else
                        statusLine = string.format(
                            "|cffb6ffb6" .. L["Will Sell (%s, iLvl %d, cap %d)"] .. "|r",
                            rarityName,
                            ilvl,
                            cap
                        )
                        statusTag = "willsell"
                    end
                elseif matchedAgainstEquipped then
                    -- Dynamic-cap mode and the item didn't qualify. Routes
                    -- on the reason isDowngradeVsEquipped gave us:
                    --   * "no_slot_mapping" / "not_equippable": item has
                    --     no equipment slot the addon can reason about
                    --     (ammo, bags, tabards, class-restricted relics).
                    --     v2.44.6: distinct "Won't Sell" label so the
                    --     player understands the addon ISN'T actively
                    --     protecting these as upgrades - it's just
                    --     declining to evaluate them. statusTag flips
                    --     from "keep" to "wontsell" to match the
                    --     framing of Won't Sell (equipped) and Won't
                    --     Sell (no value). WC-TRAP: don't reframe this
                    --     as "Keep" - a Doomshot/AMMO test case
                    --     reasonably read "Keep" as "the addon thinks
                    --     I should hold onto this", which is the
                    --     opposite of what's actually happening.
                    --   * "empty_slot": rule short-circuited because at
                    --     least one candidate slot is empty - the looted
                    --     item could fill it (relevant for dual-wielders).
                    --   * "at_or_above": actual iLvl compare happened and
                    --     the looted item met or exceeded the lowest
                    --     populated slot - could be an upgrade for the
                    --     weakest slot in a multi-slot equipLoc, or a
                    --     same-iLvl sidegrade.
                    -- "empty_slot" and "at_or_above" both mean "kept because
                    -- this could be useful"; "possible upgrade" is the
                    -- user-friendly framing for both.
                    if equipReason == "no_slot_mapping" or equipReason == "not_equippable" then
                        statusLine = string.format(
                            "|cffffb84d" .. L["Won't Sell (%s, no equipment slot)"] .. "|r",
                            rarityName
                        )
                        statusTag = "wontsell"
                    elseif not hasVisibleILvl then
                        statusLine = string.format(
                            "|cffffb84d" .. L["Keep (%s, no item level)"] .. "|r",
                            rarityName
                        )
                        statusTag = "keep"
                    else
                        statusLine = string.format(
                            "|cffffb84d" .. L["Keep (%s, possible upgrade)"] .. "|r",
                            rarityName
                        )
                        statusTag = "keep"
                    end
                elseif not hasVisibleILvl then
                    -- Fixed-cap mode; non-equippable has no visible iLvl.
                    statusLine = string.format(
                        "|cffffb84d" .. L["Keep (%s, no item level)"] .. "|r",
                        rarityName
                    )
                    statusTag = "keep"
                else
                    -- Fixed-cap mode; equippable item iLvl above cap.
                    statusLine = string.format(
                        "|cffffb84d" .. L["Keep (%s, iLvl %d, cap %d)"] .. "|r",
                        rarityName,
                        ilvl,
                        cap
                    )
                    statusTag = "keep"
                end
            end
        end
    end

    -- Tome protection annotation. Same precedence shape as chance-on-
    -- hit above: a Keep List entry (blacklist) leaves any earlier
    -- Protected / Auto-Protected label alone; an Allow Sell mark
    -- (ADB.allowedItems) rewrites to the destination list; the
    -- unmarked default is "Protected - Tome (unlearned)" or
    -- "Protected - Tome". The aggressive "all tomes" toggle wins over
    -- "unlearned only" - same precedence as WC_IsSellable.
    -- Sell Known Recipes eligibility for THIS character. A learned
    -- profession recipe of an enabled quality is sellable when the feature
    -- is on. Computed before the tome-protection block so it can carve the
    -- recipe out of that veto: the sell opt-in wins over "keep all tomes"
    -- for learned recipes, while non-recipe tomes and unknown recipes stay
    -- protected. Learn-state is read from this character's live tooltip.
    local recipeSellable = ctx.sellKnownRecipes
        and itemSellPrice
        and itemSellPrice > 0
        and not ctx.equipped
        and ctx.sellKnownRecipeQuality
        and ctx.isTome()
        and ctx.tomeKind() == "Recipe"
        and ctx.knowsTomeSpell()
        and true
        or false
    -- v2.50.4 fix (Serv report, Plans: Ragesteel Breastplate): also honour
    -- the per-quality recipe bind-type filter, matching the engine's
    -- recipePass. Without this, a soulbound Blue recipe with the
    -- Blue-recipe filter set to "boe" showed "Will Sell (known recipe)"
    -- in the tooltip but the vendor cycle correctly refused.
    -- ctx.recipeBindFilter snapshots DB.sellKnownRecipeBindFilter for
    -- this quality; ctx.bindType() is the live-tooltip bind reader
    -- (no bag/slot pair here).
    if recipeSellable then
        local recipeBindFilter = ctx.recipeBindFilter or "any"
        if recipeBindFilter ~= "any" then
            local bindType = ctx.bindType() or "any"
            if recipeBindFilter ~= bindType then
                recipeSellable = false
            end
        end
    end

    -- v2.51.2 (Serv report, Pattern: Mooncloth Leggings): Sell List
    -- membership releases the tome veto in the engine, so the tooltip
    -- must not overwrite the earlier "Will Sell" label with a
    -- tome-protection label (either Sell List - the earlier branch
    -- fires on both).
    -- v2.71.3: the old three-way paired-edit WC-TRAP is retired - the
    -- authoritative predicate lives in Decision.sell's tome veto and
    -- the sentinel flags this label branch if it falls behind. Keep the
    -- branch's shape matching the core so the label matches the verdict.
    local onSellList = ctx.whitelistedChar or ctx.whitelistedAccount
    local tomeProtected = false
    local tomeHave = false
    local tomeKindLabel
    if (ctx.protectAllTomes or ctx.protectUnlearnedTomes)
        and not recipeSellable
        and not onSellList
        and ctx.isTome()
    then
        -- Label the protection accurately. GetItemInfo's class is
        -- "Recipe" for BOTH profession crafting items (Plans /
        -- Schematic / Pattern / Formula / Recipe / Design / Manual)
        -- AND generic spell-teaching tomes (class spell books, mount
        -- scrolls, PE Tome of Echo). The distinguishing field is the
        -- subtype - profession recipes carry a profession-name
        -- subtype; everything else falls through to "Tome".
        tomeKindLabel = ctx.tomeKind() or L["Recipe"]
        if ctx.protectAllTomes then
            tomeProtected = true
            tomeHave = ctx.knowsTomeSpell() and true or false
        elseif ctx.protectUnlearnedTomes and not ctx.knowsTomeSpell() then
            tomeProtected = true
            tomeHave = false
        end
    end
    if tomeProtected then
        -- Tome protection HARD-VETOES the SELL path in the engine
        -- regardless of Sell List membership, so the Keep label is the
        -- truth for sellable tomes. Keep List membership stays. Allow
        -- Sell override flips to the destination-list label.
        -- v2.71.3: a Will Delete verdict stands too - the delete gate
        -- has NO tome veto, so a Delete-Listed tome really is deleted;
        -- overwriting with "Keep (learned tome)" was the same lie class
        -- as the branches above.
        if ctx.blacklisted or statusTag == "willdelete" then -- luacheck: ignore 542
            -- Explicit-list verdict wins; leave the earlier label alone.
        elseif ctx.allowedItem then
            -- destinationLabel walks the explicit-list precedence chain.
            -- Returns nil when no list claims it; the fallback picks an
            -- existing quality-rule "Will Sell" verdict if there is one,
            -- otherwise prompts the user to pick a list.
            local newLine, newTag = destinationLabel(ctx, statusLine, statusTag)
            if newLine then
                statusLine = newLine
                statusTag = newTag
            elseif statusTag ~= "willsell" then
                statusLine = "|cffffea80"
                    .. L["Override on - add to a list to sell"]
                    .. "|r"
                statusTag = "override"
            end
        elseif tomeHave then
            local haveLabel
            if tomeKindLabel == "Recipe" then
                haveLabel = L["Keep (learned recipe)"]
            else
                haveLabel = L["Keep (learned recipe)"]
            end
            statusLine = "|cffffb84d" .. haveLabel .. "|r"
            statusTag = "tome_have"
        else
            local newLabel
            if tomeKindLabel == "Recipe" then
                newLabel = L["Keep (unlearned recipe)"]
            else
                newLabel = L["Keep (unlearned recipe)"]
            end
            statusLine = "|cffffb84d" .. newLabel .. "|r"
            statusTag = "tome_new"
        end
    end

    -- Sell Known Recipes verdict. WC_IsSellable sells a learned recipe via
    -- recipePass independently of the per-rarity quality rules, so the
    -- tooltip must say "Will Sell" even when the quality-rule branch above
    -- stamped a "Keep (...)" label on it (e.g. a recipe has no equip slot
    -- to compare against in compare-to-equipped mode). Override that here -
    -- but never override the real Keep List or Delete List (those win in
    -- the engine too), and don't bother relabelling an existing Will Sell.
    -- WC-TRAP: gate on statusTag (English token), never the localized
    -- statusLine.
    if recipeSellable
        and statusTag ~= "willsell"
        and statusTag ~= "willdelete"
        and not ctx.blacklisted
        and not (ctx.onDeleteList and ctx.enableDeletion)
    then
        statusLine = "|cffb6ffb6" .. L["Will Sell (known recipe)"] .. "|r"
        statusTag = "willsell"
    end

    -- v2.60.0 iter 3 (Serv follow-up): non-weapon items with chance-on-
    -- hit lines are treated as any other item without a proc line. No
    -- special tooltip label is emitted for them; the tooltip either
    -- shows a verdict from an earlier rule (Keep List, Sell List,
    -- quality rule, etc.) or shows nothing - same as any other item
    -- WC has no rule for.

    if statusLine then
        -- v2.71.2 honesty guard: the engine's equipped veto beats EVERY
        -- positive signal, but only the Sell List branch above checked
        -- it. Centralise: no label may promise a sale of an item the
        -- player is wearing (paper-doll hovers of rule-matched gear were
        -- the visible case; a worn item with a bag copy is the subtle one).
        if statusTag == "willsell" and ctx.equipped then
            statusLine = "|cffffb84d" .. L["Won't Sell (equipped)"] .. "|r"
            statusTag = "wontsell"
        end
        -- v0.6.0 Forever protections have no hand-written label branch:
        -- the core is asked directly, so the label cannot drift from it.
        if statusTag == "willsell" then
            local verdict, token = NS.Decision.sell(ctx)
            if verdict == "keep" and token == "appearance" then
                statusLine = "|cffffb84d" .. L["Keep (new appearance)"] .. "|r"
                statusTag = "keep"
            elseif verdict == "keep" and token == "tradeable" then
                statusLine = "|cffffb84d" .. L["Keep (tradeable)"] .. "|r"
                statusTag = "keep"
            end
        end
        -- Drift sentinel (classifier Stage 3): compare the label's class
        -- against the decision core's verdict on the SAME ctx. The label
        -- branches above are still hand-maintained; a mismatch means one
        -- fell behind the core - surface it instead of letting the
        -- tooltip quietly lie. Delete-side labels are out of the core's
        -- scope until Stage 4, so they are excluded.
        out[#out + 1] = statusLine
        -- v2.71.3 (classifier Stage 4): the sentinel now covers delete
        -- labels too. A "Will Delete" without Delete-List membership is
        -- the auto-mark PREVIEW (predicts a future marking, out of the
        -- core's scope) and stays excluded; everything else answers to
        -- the core: listed + eligible + deletion on MUST read Will
        -- Delete, and anything else compares its sell class against
        -- Decision.sell as before.
        local willDeleteReal = ctx.onDeleteList
            and ctx.enableDeletion
            and NS.Decision.deleteEligible(ctx)
            and true
            or false
        local mismatch = false
        if statusTag == "willdelete" and not ctx.onDeleteList then -- luacheck: ignore 542
            -- Auto-mark preview; no core decision to compare against.
        elseif willDeleteReal then
            mismatch = statusTag ~= "willdelete"
        else
            local verdict = NS.Decision.sell(ctx)
            mismatch = (verdict == "sell") ~= (statusTag == "willsell")
        end
        if mismatch then
            out[#out + 1] = "|cff888888" .. L["(WC label check failed - please report via /wc bugreport)"] .. "|r"
        end
    end
    -- v2.37.0 (Borrow B): grey "already known" annotation on tome /
    -- recipe items the current character has already learned.
    -- Surfaces the existing tomeIsKnownCache as a user-visible cue
    -- independent of the protection toggles - players running with
    -- protectUnlearnedTomes off AND protectAllTomes off still see
    -- the cue. Skipped when the WC status line already carries a
    -- "(... you have)" suffix from the tome-protection block above
    -- so the annotation doesn't double up. Per-character via the
    -- cache's character-scoped lifecycle (the tooltip scan runs on
    -- THIS character's spellbook + recipe list).
    if id and ctx.isTome() and ctx.knowsTomeSpell() and statusTag ~= "tome_have" then
        out[#out + 1] = "|cff888888" .. L["Already known by this character"] .. "|r"
    end
    -- Opt-in item-ID annotation. Surfaces the numeric itemID under the
    -- WC verdict line for users filing bug reports or authoring Keep /
    -- Sell / Delete entries by ID. The id has already been parsed at
    -- the top of this function from the |Hitem:NNNN| link, so this is a
    -- single conditional AddLine - no extra parsing cost.
    if DB.showItemIDOnTooltip then
        out[#out + 1] = string.format("|cff666666" .. L["Item ID: %d"] .. "|r", id)
    end
    -- Discoverability hint for the v2.3.0 right-click context menu. Shown on
    -- every bag/item-link tooltip so users know the action is available.
    -- Hidden when DaylightUI's bags own Alt+Right-Click (their menu carries
    -- our row, so the hint would point at the wrong menu).
    if not WC_compCache.hostOwnsItemMenu then
        out[#out + 1] = "|cff666666" .. L["Alt+Right-Click for WoWClearance menu"] .. "|r"
    end
end

-- Frame-spike timing wrapper. Times the annotation body into the shared
-- tooltip phase counter so /wc spike can attribute a mouseover-storm
-- stutter to tooltip work (the ctx build + Decision.sell sentinel are
-- inside the timed body). Falls straight through when the timer is
-- unavailable.
--
-- Forever: a bag-button tooltip is rebuilt every TOOLTIP_UPDATE_TIME (0.2 s)
-- while hovered, and each rebuild clears our flag. So the computed lines
-- are kept per tooltip and replayed while the same link stays under the
-- same owner, for up to WC_TOOLTIP_REUSE_SECONDS; after that (or on a new
-- item) the verdict is recomputed, so a rule change shows within a second.
-- No tooltip:Show() here: TooltipDataHandler calls Show() right after the
-- post-calls, and a second Show() only re-runs the layout.
local WC_TOOLTIP_REUSE_SECONDS = 1.0
local function WC_ClearTooltipFlag(tooltip)
    if tooltip then
        tooltip.__WC_annotated = nil
    end
end

local function WC_AnnotateTooltip(tooltip)
    if not tooltip or tooltip.__WC_annotated or not tooltip.GetItem then
        return
    end
    -- WC's own hidden scan tooltip goes through the same item post-call:
    -- annotating it cost a full sell decision per scan and put WC's lines
    -- in front of the scanners reading it.
    if tooltip == NS.scanTooltip then
        return
    end
    -- The post-call also fires for comparison tooltips, which the installer
    -- does not know about. Hook their clear once here, or the flag set below
    -- sticks and they show the WC line only once per session.
    if not tooltip.__WC_clearHooked and tooltip.HookScript then
        tooltip:HookScript("OnTooltipCleared", WC_ClearTooltipFlag)
        tooltip.__WC_clearHooked = true
    end
    local _, link = tooltip:GetItem()
    local owner = tooltip.GetOwner and tooltip:GetOwner()
    local now = GetTime()
    local c = tooltip.__WC_cache
    local lines
    if c and link and c.link == link and c.owner == owner and (now - c.t) < WC_TOOLTIP_REUSE_SECONDS then
        lines = c.lines
    else
        lines = {}
        local prof = WC_compCache.spikeProf
        local t0 = prof and prof()
        WC_AnnotateTooltipInner(tooltip, lines)
        local sp = WC_compCache.spikePhase
        if t0 and sp then
            sp.tooltip = sp.tooltip + (prof() - t0)
        end
        tooltip.__WC_cache = { link = link, owner = owner, t = now, lines = lines }
    end
    -- Plain lines, no brand label: each line already says what it means.
    for i = 1, #lines do
        tooltip:AddLine(lines[i])
    end
    -- Bank count, only when the bank holds some. Bank (reagent bank too)
    -- minus bags. Two count reads, so it runs on every rebuild instead of
    -- riding the cached lines, and a deposit shows at once.
    local _, _, itemID = tooltip:GetItem()
    itemID = itemID or (link and C_Item.GetItemInfoInstant(link))
    if itemID then
        local bank = (C_Item.GetItemCount(itemID, true, false, true) or 0) - (C_Item.GetItemCount(itemID) or 0)
        -- Left out when another addon already puts bank counts on item
        -- tooltips, so the number isn't shown twice. Checked each time:
        -- cheap, and addons can load on demand after us.
        local otherShowsBank = C_AddOns.IsAddOnLoaded("DaylightMogul") or C_AddOns.IsAddOnLoaded("DaylightUI_Bags")
        if bank > 0 and not otherShowsBank then
            tooltip:AddLine(string.format(L["Bank: %d"], bank), 1, 1, 1)
        end
        -- v0.7.0: account-wide lifetime counts, only the ones above zero.
        local DB, AS = NS.DB, NS.ADB and NS.ADB.accountStats
        if DB and DB.showItemStatsOnTooltip and AS then
            local sold = AS.soldItemCounts and AS.soldItemCounts[itemID] or 0
            local looted = AS.lootedItemCounts and AS.lootedItemCounts[itemID] or 0
            local parts = {}
            if sold > 0 then
                parts[#parts + 1] = string.format(L["Sold: %s"], NS.CommaNumber(sold))
            end
            if looted > 0 then
                parts[#parts + 1] = string.format(L["Looted: %s"], NS.CommaNumber(looted))
            end
            if #parts > 0 then
                tooltip:AddLine(table.concat(parts, "   "), 0.7, 0.7, 0.7)
            end
        end
    end
    tooltip.__WC_annotated = true
end

local function WC_InstallTooltipHookOnce()
    if WC_tooltipHooked then
        return
    end
    WC_tooltipHooked = true
    -- v0.5.1 port fix. WC-TRAP: do NOT "restore" the OnTooltipSetItem
    -- HookScript calls this replaced. That script type does not exist on
    -- Forever (zero occurrences across all 4393 shipped Blizzard UI files)
    -- and hooking it throws "bad argument #2 to HookScript", which aborted
    -- the rest of this installer and left item tooltips unannotated.
    -- Measured in-game 2026-09-19.
    --
    -- The replacement is Blizzard's own dispatcher, declared in
    -- Blizzard_SharedXMLGame/Tooltip/TooltipDataHandler.lua. It registers
    -- ONCE and globally rather than per-tooltip, so this single call covers
    -- GameTooltip AND ItemRefTooltip: that is why there is no longer an
    -- ItemRefTooltip branch for the annotate path. The post-call receives
    -- (tooltip, data) and WC_AnnotateTooltip already takes the tooltip
    -- first, so the signature carries over unchanged.
    --
    -- OnTooltipCleared is still a valid script type. It is hooked per
    -- tooltip on first annotate (WC_AnnotateTooltip), which also covers the
    -- comparison tooltips this post-call reaches.
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, WC_AnnotateTooltip)
    end
end

NS.InstallTooltipHookOnce = WC_InstallTooltipHookOnce
