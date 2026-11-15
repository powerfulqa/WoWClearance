-- WoWClearance_Protection - item-marker and tome / recipe detection.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 4 of the multi-stage file split tracked in docs/CODE_REVIEW.md
-- item 4. This file owns the protection-detection cluster:
--
--   * scanItemMarkers - the tooltip walk that fills the Resilience cache
--     for a bag slot. It used to fill the bind-type cache too; on Forever
--     bind state comes from container/item info (see getBindType).
--   * itemHasResilience - PvP-gear detection for the auto-mark sweep.
--   * Tome / recipe detection and learn-state (itemIsTome, tomeKind,
--     playerKnowsTomeSpell) plus their live-tooltip variants for the
--     tooltip annotator.
--
-- This file used to be dominated by the Project Ebonhold affix and
-- chance-on-hit subsystem (random-affix parsing, the engraving-spell
-- catalog, proc detection, the Anvil bridge). All of that was removed in
-- the port: WoW: Forever has no affix system, no Anvil and no
-- extraction. What is left is the realm-agnostic remainder.
--
-- Every helper is attached to WC_compCache (= NS.compCache, created in
-- WoWClearance_Core.lua). Call sites elsewhere in the addon resolve
-- through the WC_compCache upvalue.
--
-- Cross-file API surface this file relies on:
--   * NS.compCache              (Core)  - target table for all helpers
--   * NS.scanTooltip            (WoWClearance_Events.lua) - the private named
--                                 GameTooltip used by every scan call.
--                                 We bind it lazily via NS.scanTooltip
--                                 inside function bodies, NOT as a
--                                 file-load upvalue, because the frame
--                                 is created by WoWClearance_Events.lua's
--                                 main chunk which runs AFTER this
--                                 file loads. By the time any of these
--                                 functions is first called (BAG_UPDATE,
--                                 vendor run, tooltip annotation), the
--                                 frame exists.
--
-- Naming: the file-scope upvalue `WC_scanTooltip` is restored at the top
-- of this file by reading NS.scanTooltip... but NS.scanTooltip is nil at
-- our file-load time. The TextLeft FontStrings are looked up by the
-- absolute name "WoWClearanceScanTooltipTextLeft<N>" via _G, which is
-- only resolved at call time, so they keep working. The `WC_scanTooltip`
-- identifier inside method bodies is rewritten to NS.scanTooltip inline
-- when called (closures capture the NS table, not the field, and the
-- field is dereferenced at call time).

local NS = select(2, ...)
local WC_compCache = NS.compCache

-- "any" on French/German clients.
function WC_compCache.scanItemMarkers(bag, slot, itemID)
    if not itemID or not bag or not slot then
        return
    end
    WC_compCache.scanBagItem(bag, slot)
    local sawAnyLine = false
    local resilience = false
    for i = 1, 30 do
        local line = WC_compCache.scanLines[i]
        if not line then
            break
        end
        local txt = line:GetText()
        if txt and txt ~= "" then
            sawAnyLine = true
            if not resilience and txt:lower():find("resilience", 1, true) then
                resilience = true
            end
        end
    end
    if not sawAnyLine then
        return
    end
    if WC_compCache.resilienceCache[itemID] == nil then
        WC_compCache.resilienceCache[itemID] = resilience
    end
end

-- v2.44.0: Resilience-stat detection. Mirrors the other cached-predicate
-- pattern. PvP gear on most 3.3.5a servers has a "Resilience" /
-- "Resilience Rating" stat line and sellPrice = 0, so it can't be
-- sold and just clutters bags. Murlocked asked for an option to
-- auto-mark these for deletion; the toggle that drives the sweep
-- lives on the Item Protection panel. Detection is per-itemID,
-- locale-tolerant (matches the substring "Resilience" which is the
-- common root for both the bare stat and the rating variant).
function WC_compCache.itemHasResilience(bag, slot, itemID)
    if not itemID then
        return false
    end
    if WC_compCache.resilienceCache[itemID] ~= nil then
        return WC_compCache.resilienceCache[itemID]
    end
    if not bag or not slot then
        return false
    end
    -- v2.69.0: the shared combined walk fills this cache (and bind +
    -- chance-on-hit) in one pass. Case-fold matching (the v2.60.0
    -- Jouster's Fury fix) and the v2.68.1 cold-tooltip guard both live
    -- inside scanItemMarkers now; a cold tooltip fills nothing and the
    -- next call retries.
    WC_compCache.scanItemMarkers(bag, slot, itemID)
    return WC_compCache.resilienceCache[itemID] or false
end

-- Tome detection. A "tome" here means a spell-teaching item: profession
-- recipes (Recipe class via GetItemInfoInstant) and class spell books / talent
-- tomes / mount-training scrolls (detected via a `Use: Teaches you...`
-- tooltip line). Two helpers because the two signals decay at different
-- rates:
--   * itemIsTome    - stable per itemID. Recipe class is a hard
--                     fast-path; tooltip-scan covers everything else.
--   * playerKnowsTomeSpell - flips when the player learns the spell.
--                     Scans the live tooltip for the locale-aware
--                     ITEM_SPELL_KNOWN string ("Already known").
function WC_compCache.itemIsTome(bag, slot, itemID)
    if not itemID then
        return false
    end
    if WC_compCache.tomeCache[itemID] ~= nil then
        return WC_compCache.tomeCache[itemID]
    end
    local instant = WC_compCache.instantTomeVerdict(itemID)
    if instant ~= nil then
        WC_compCache.tomeCache[itemID] = instant
        return instant
    end
    -- Slow path: tooltip-scan for `Use: Teaches...`. Covers class
    -- spell books (e.g. Death Knight talent tomes) and other PE
    -- custom tome formats whose class isn't "Recipe". Needs bag/slot
    -- for SetBagItem.
    if not bag or not slot then
        WC_compCache.tomeCache[itemID] = false
        return false
    end
    -- v2.38.3: SetOwner-before-SetBagItem via the shared helper.
    WC_compCache.scanBagItem(bag, slot)
    local result = false
    local sawAnyLine = false
    local usePrefix = ITEM_SPELL_TRIGGER_ONUSE or "Use:"
    for i = 1, 30 do
        local line = WC_compCache.scanLines[i]
        if not line then
            break
        end
        local txt = line:GetText()
        if type(txt) == "string" and txt ~= "" then
            sawAnyLine = true
        end
        if type(txt) == "string"
            and txt:find(usePrefix, 1, true) == 1
            and txt:find("[Tt]eaches", 1, false)
        then
            -- v2.32.x: belt-and-braces vanity-collectible reject.
            -- The GetItemInfo class/subclass check above catches
            -- the obvious case (class=Miscellaneous + subclass=
            -- Companion/Mount), but in 3.3.5a many vanity pets are
            -- actually filed under subclass="Junk" (the
            -- "Companion Pets" subtype is a later WoW addition).
            -- The tooltip text itself is the most reliable signal:
            -- pets use "summon this companion", mount-summon items
            -- use "summon this mount", and riding-training scrolls
            -- use "how to ride". Spell tomes / profession recipes
            -- don't carry any of these phrases. Hard-coded enUS
            -- because the addon targets a single locale (enUS PE).
            local low = txt:lower()
            if low:find("this companion", 1, true)
                or low:find("this mount", 1, true)
                or low:find("how to ride", 1, true)
            then
                break
            end
            result = true
            break
        end
    end
    -- A cold scan tooltip returns no lines, and a half-loaded one shows
    -- only "Retrieving item information": answer "not a tome" for now but
    -- do not cache it, or the item stays unprotected all session (porting
    -- lesson 14, same guard as scanItemMarkers).
    if not sawAnyLine or not C_Item.IsItemDataCachedByID(itemID) then
        return false
    end
    WC_compCache.tomeCache[itemID] = result
    return result
end

function WC_compCache.playerKnowsTomeSpell(bag, slot, itemID)
    if not itemID then
        return false
    end
    if WC_compCache.tomeIsKnownCache[itemID] ~= nil then
        return WC_compCache.tomeIsKnownCache[itemID]
    end
    if not bag or not slot then
        return false
    end
    -- v2.38.3: SetOwner-before-SetBagItem via the shared helper.
    WC_compCache.scanBagItem(bag, slot)
    local result = false
    local knownStr = ITEM_SPELL_KNOWN or "Already known"
    for i = 1, 30 do
        local line = WC_compCache.scanLines[i]
        if not line then
            break
        end
        local txt = line:GetText()
        if type(txt) == "string" and txt:find(knownStr, 1, true) then
            result = true
            break
        end
    end
    WC_compCache.tomeIsKnownCache[itemID] = result
    return result
end

-- Class-ID verdict for tome detection, from client data (no server round
-- trip, so it never comes back empty for an uncached item) and not from
-- the localized class names, which only matched on English clients.
-- true = Recipe class (profession recipes and books); false = companion
-- pet or mount item (these say "Use: Teaches" too but are collectibles,
-- not tomes); nil = no opinion, fall through to the tooltip scan.
function WC_compCache.instantTomeVerdict(itemID)
    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(itemID)
    if classID == Enum.ItemClass.Recipe then
        return true
    end
    if
        classID == Enum.ItemClass.Miscellaneous
        and (
            subClassID == Enum.ItemMiscellaneousSubclass.CompanionPet
            or subClassID == Enum.ItemMiscellaneousSubclass.Mount
        )
    then
        return false
    end
    return nil
end

-- Pick the right label for a protected tome / recipe. Returns "Recipe"
-- for profession crafting recipes and "Tome" for everything else (books
-- and anything the tooltip scan matched). Recipe class covers both, so
-- the Book subclass tells them apart.
function WC_compCache.tomeKind(itemID)
    if not itemID then
        return "Tome"
    end
    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(itemID)
    if classID == Enum.ItemClass.Recipe and subClassID ~= Enum.ItemRecipeSubclass.Book then
        return "Recipe"
    end
    return "Tome"
end

-- Live-tooltip variants of the tome helpers. Used by the tooltip
-- annotation system (WoWClearance_Tooltip.lua) which has the live
-- tooltip frame but not a bag/slot pair. Mirror
-- the bag-slot scanners' structure: cache hit fast-path; else
-- scan the visible tooltip lines and write the result back into the
-- same per-itemID caches shared with the bag-item path.
function WC_compCache.liveTooltipIsTome(tooltip, itemID)
    if itemID and WC_compCache.tomeCache[itemID] ~= nil then
        return WC_compCache.tomeCache[itemID]
    end
    if itemID then
        local instant = WC_compCache.instantTomeVerdict(itemID)
        if instant ~= nil then
            WC_compCache.tomeCache[itemID] = instant
            return instant
        end
    end
    if not tooltip or not tooltip.NumLines or not tooltip.GetName then
        return false
    end
    local tname = tooltip:GetName()
    if not tname then
        return false
    end
    local n = tooltip:NumLines() or 0
    local usePrefix = ITEM_SPELL_TRIGGER_ONUSE or "Use:"
    local result = false
    for i = 2, n do
        local fs = _G[tname .. "TextLeft" .. i]
        if fs and fs.GetText then
            local txt = fs:GetText()
            if type(txt) == "string"
                and txt:find(usePrefix, 1, true) == 1
                and txt:find("[Tt]eaches", 1, false)
            then
                -- v2.32.x: belt-and-braces vanity-collectible
                -- reject. Same phrasing-based filter as itemIsTome -
                -- catches the case where GetItemInfo reports an
                -- unexpected subclass (e.g. 3.3.5a pets often file
                -- under "Junk" rather than "Companion"). Hard-coded
                -- enUS; the addon targets a single locale.
                local low = txt:lower()
                if low:find("this companion", 1, true)
                    or low:find("this mount", 1, true)
                    or low:find("how to ride", 1, true)
                then
                    break
                end
                result = true
                break
            end
        end
    end
    -- Same guard as the bag path above: a half-loaded tooltip answers "not
    -- a tome" for now but must not cache it, or the item stays unprotected
    -- all session.
    if itemID and (result or (n > 1 and C_Item.IsItemDataCachedByID(itemID))) then
        WC_compCache.tomeCache[itemID] = result
    end
    return result
end

function WC_compCache.liveTooltipPlayerKnowsTome(tooltip, itemID)
    -- v2.32.x: live tooltip is the authoritative source; the cache is
    -- a side-effect output (still consulted by playerKnowsTomeSpell
    -- which has no live tooltip), not a read-path fast-path. The
    -- cache-first fast-path was buggy: PE's roguelite "Tome of Echo"
    -- mechanic doesn't teach a Blizzard spell on use, so
    -- LEARNED_SPELL_IN_TAB / SPELLS_CHANGED don't fire, the cache
    -- never gets wiped, and a cached `false` from a hover BEFORE the
    -- tome was used stuck around forever - tooltip showed Blizzard's
    -- own "Already known" line but WC kept labelling the item as
    -- "Protected - Tome (unlearned)". Scanning the live tooltip on
    -- every hover is cheap (~30 line iterations) and self-healing:
    -- whatever state PE's tooltip code wrote IS what the user sees,
    -- so we read the same source.
    local tname = tooltip and tooltip.NumLines and tooltip.GetName and tooltip:GetName()
    if not tname then
        -- No tooltip to scan - fall back to the cache (if any) so the
        -- bag-scan variant's prior write stays useful.
        if itemID and WC_compCache.tomeIsKnownCache[itemID] ~= nil then
            return WC_compCache.tomeIsKnownCache[itemID]
        end
        return false
    end
    local n = tooltip:NumLines() or 0
    local knownStr = ITEM_SPELL_KNOWN or "Already known"
    local result = false
    for i = 2, n do
        local fs = _G[tname .. "TextLeft" .. i]
        if fs and fs.GetText then
            local txt = fs:GetText()
            if type(txt) == "string" and txt:find(knownStr, 1, true) then
                result = true
                break
            end
        end
    end
    if itemID then
        WC_compCache.tomeIsKnownCache[itemID] = result
    end
    return result
end

-- "Keep appearances you haven't collected" (Forever). True when this copy
-- carries an appearance the account does not own yet and this character
-- can collect. No sourceID (not a transmog item) answers false: no
-- opinion, the other rules decide. Data still loading answers true.
function WC_compCache.isUncollectedAppearance(link)
    if not link then
        return false
    end
    local _, sourceID = C_TransmogCollection.GetItemInfo(link)
    if not sourceID then
        return false
    end
    if C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance(sourceID) then
        return false
    end
    local hasItemData, canCollect = C_TransmogCollection.PlayerCanCollectSource(sourceID)
    if not hasItemData then
        -- Still loading: keep it for now (porting lesson 14). The next
        -- vendor visit or tooltip asks again.
        return true
    end
    return canCollect and true or false
end

-- "Keep loot you can still trade or refund" (Forever). True while this
-- copy can be refunded at a vendor, or while its tooltip carries the
-- group-loot trade timer. Both are per copy and expire, so nothing is
-- cached. Only reached when an auto-sell rule already matched.
function WC_compCache.isTradeableOrRefundable(bag, slot)
    if not (bag and slot) then
        return false
    end
    local loc = NS.Decision.slotLocation(bag, slot)
    if not C_Item.DoesItemExist(loc) then
        return false
    end
    if C_Item.CanBeRefunded(loc) then
        return true
    end
    local data = C_TooltipInfo.GetBagItem(bag, slot)
    local lines = data and data.lines
    if lines then
        local tradeType = Enum.TooltipDataLineType.TradeTimeRemaining
        for i = 1, #lines do
            if lines[i].type == tradeType then
                return true
            end
        end
    end
    return false
end
