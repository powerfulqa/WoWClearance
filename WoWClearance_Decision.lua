-- WoWClearance_Decision - the single sell/keep decision core.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 1 of the decision-classifier plan
-- (EbonClearance's docs/specs/2026-07-29-decision-classifier-design.md; CODE_REVIEW audit
-- item 6 / competitive-review Tier A1). Two layers:
--
--   * NS.Decision.sell(ctx) - the PURE core. Reads ONLY the ctx table
--     (plain values + caller-supplied thunks). No WoW API, no DB, no
--     WC_compCache, no locale reads. Loadable under stock lua5.1, which
--     is what makes tests/test_decision.lua the addon's first RUNTIME
--     coverage of the sell logic.
--   * NS.Decision.buildCtx(bag, slot, junkOnly) - the adapter. Performs
--     every WoW / DB / cache read, reusing the existing cached accessors
--     (getBindType, itemIsTome, isDowngradeVsEquipped, ...) so scan
--     cost and lazy-fill behaviour are unchanged. Expensive predicates
--     ride as THUNKS so the core only pays for them on the branches that
--     need them - the same short-circuit profile WC_IsSellable had.
--
-- The core's logic is a faithful transcription of WC_IsSellable at
-- v2.70.0 (the vendor engine is ground truth). The long per-version
-- rationale comments stay in git history on WoWClearance_Events.lua;
-- the load-bearing WC-TRAPs and invariants move here WITH the logic.
--
-- Verdicts: "sell" | "keep" | "none".
--   "sell" - a positive signal fired and survived every veto.
--   "keep" - an explicit protection refused it (the reason token says
--            which one).
--   "none" - nothing matched (or the slot is empty/locked/unusable).
-- Tokens are append-only once shipped; renderers must tolerate unknown
-- tokens with a neutral fallback.

local NS = select(2, ...)

-- Cached API upvalues (engine-file convention). Only the adapter uses
-- them; the core reads ctx exclusively.
local GetContainerItemID = C_Container.GetContainerItemID
local GetItemInfo = C_Item.GetItemInfo
-- v0.5.1 port fix: moved to C_Item on Forever; the bare global is nil, which
-- made every ctx.equipped read throw and took the sell/keep decision with it.
local IsEquippedItem = C_Item.IsEquippedItem
local GetContainerItemLink = C_Container.GetContainerItemLink

-- The shared cache table is created in Core (loads first), so binding it
-- at file scope is safe; its MEMBERS are added later by Events /
-- Protection, so every member access below still resolves at call time.
local WC_compCache = NS.compCache

local Decision = {}
NS.Decision = Decision

-- One reusable ItemLocation for per-copy C_Item reads. The adapters run
-- per bag slot per flush, and CreateFromBagAndSlot would allocate a new
-- object every time. Created on first use (not at file scope) so the
-- headless test stub, which has no ItemLocation mixin, can still load us.
local sharedLoc
function Decision.slotLocation(bag, slot)
    sharedLoc = sharedLoc or ItemLocation:CreateEmpty()
    sharedLoc:SetBagAndSlot(bag, slot)
    return sharedLoc
end

-- ---------------------------------------------------------------------------
-- Pure core.
-- ---------------------------------------------------------------------------
-- INVARIANT (WC-TRAP): grey items (quality == 0) with a positive sell
-- price ALWAYS match via isJunk, independent of whitelist / quality-rule
-- settings. The one exception is the player's own "Sell grey items"
-- toggle (ctx.sellGreys == false); nil reads as ON so old fixtures and
-- saves keep the guarantee. An item a host bag UI marked as junk
-- (ctx.hostMarkedJunk) also matches isJunk, at any quality. Do NOT combine the isJunk / qualityPass / whitelistPass
-- passes into "one cleaner check" - that silently breaks the
-- grey-always-sold guarantee (ADDON_GUIDE "Grey items are sold by default").
-- The runtime fixtures in tests/test_decision.lua pin this for the first
-- time.
function Decision.sell(ctx)
    if not ctx or not ctx.itemID then
        return "none", "empty"
    end
    if not ctx.count or ctx.count <= 0 or ctx.locked then
        return "none", "locked"
    end
    local quality = ctx.quality
    local junkOnly = ctx.junkOnly
    local hasSellPrice = ctx.sellPrice and ctx.sellPrice > 0
    local isJunk = hasSellPrice and ((quality == 0 and ctx.sellGreys ~= false) or ctx.hostMarkedJunk == true)
    local whitelistPass = not junkOnly
        and hasSellPrice
        and (ctx.whitelistedChar or ctx.whitelistedAccount)

    -- Per-rarity rules (v2.4.0+). cap == 0 -> sell everything of the
    -- rarity; cap > 0 -> STRICT: only equippable items (non-empty
    -- equipLoc, visible iLvl) at or under the cap.
    local qualityPass = false
    local rule = ctx.qualityRule
    if not junkOnly and hasSellPrice and quality and quality >= 1 and quality <= 4 and rule and rule.enabled then
        if rule.useEquippedILvl then
            -- v2.12.0 dynamic-cap mode: compare against the player's
            -- equipped item (empty-slot guard etc. live in the thunk).
            if ctx.downgradeVsEquipped() then
                qualityPass = true
            end
        else
            local cap = rule.maxILvl or 0
            local hasVisibleILvl = ctx.equipLoc and ctx.equipLoc ~= "" and ctx.ilvl and ctx.ilvl > 0
            if cap == 0 then
                qualityPass = true
            elseif hasVisibleILvl and ctx.ilvl <= cap then
                qualityPass = true
            end
        end
        -- v2.10.0 bind filter: no-bind-line items read "any" and are
        -- excluded by both "boe" and "bop" ("Sell BoE only" must not
        -- sweep up reagents).
        if qualityPass then
            local bindFilter = rule.bindFilter or "any"
            if bindFilter ~= "any" and bindFilter ~= ctx.bindType() then
                qualityPass = false
            end
        end
    end
    -- v2.13.x quest-item safety net: vetoes the auto-rule sweep only;
    -- explicit Sell List entries override (the whitelist IS user intent).
    if qualityPass and ctx.isQuestItem then
        qualityPass = false
    end
    -- Baseline profession-tool safety net: same narrowing; per-item
    -- Allow Sell (allowedItem) bypasses.
    if qualityPass and ctx.baselineProtected and not ctx.allowedItem then
        qualityPass = false
    end

    -- Sell Known Recipes: learned profession recipes only (tomeKind ==
    -- "Recipe"); per-quality enable + per-quality bind filter. Overrides
    -- the tome veto below for exactly this case.
    local recipePass = false
    if not junkOnly
        and hasSellPrice
        and ctx.sellKnownRecipes
        and quality
        and quality >= 1
        and quality <= 4
        and ctx.sellKnownRecipeQuality
        and ctx.isTome()
        and ctx.tomeKind() == "Recipe"
        and ctx.knowsTomeSpell()
    then
        recipePass = true
        local recipeBindFilter = ctx.recipeBindFilter or "any"
        if recipeBindFilter ~= "any" and recipeBindFilter ~= ctx.bindType() then
            recipePass = false
        end
    end

    if not (isJunk or qualityPass or whitelistPass or recipePass) then
        return "none", "noSignal"
    end
    if ctx.equipped then
        return "keep", "equipped"
    end
    if ctx.blacklisted then
        return "keep", "blacklist"
    end

    -- Tome protection. Releases: whitelistPass (v2.51.2/v2.59.10 - Sell
    -- List is user intent, including the both-signals case), recipePass
    -- (Sell Known Recipes carve-out), per-item Allow Sell. WC-TRAP: this
    -- is the condition shape all three mirrors must share; from Stage 2
    -- onward they render from this core.
    if qualityPass
        and not whitelistPass
        and not recipePass
        and (ctx.protectAllTomes or ctx.protectUnlearnedTomes)
        and ctx.isTome()
    then
        if not ctx.allowedItem then
            if ctx.protectAllTomes then
                return "keep", "tomeProtected"
            elseif ctx.protectUnlearnedTomes and not ctx.knowsTomeSpell() then
                return "keep", "tomeUnlearned"
            end
        end
    end

    -- Forever protections (v0.6.0). Same release shape as the tome veto:
    -- they stop the AUTO rules only. A Sell List entry or Allow Sell is
    -- explicit intent and still sells; greys (isJunk) are never reached
    -- here because the quality rules only cover quality 1-4.
    if qualityPass and not whitelistPass and not recipePass and not ctx.allowedItem then
        if ctx.protectUncollectedAppearances and ctx.uncollectedAppearance() then
            return "keep", "appearance"
        end
        if ctx.protectTradeableLoot and ctx.tradeable() then
            return "keep", "tradeable"
        end
    end

    -- Exit-gate recheck. The tome veto above can clear qualityPass after
    -- the first gate passed, so the signal set has to be re-tested rather
    -- than assumed. WC-TRAP: do not drop this recheck - trimming the
    -- equivalent set "to match the original v2.20.x shape" was the v2.44.1
    -- bug, and the same trap applies to whatever signals live here.
    if not (isJunk or qualityPass or whitelistPass or recipePass) then
        return "none", "noSignal"
    end

    -- Winning-signal precedence (most specific / explicit first). Same
    -- vocabulary the Sold History reasons have used since v2.54.x.
    local signal
    if whitelistPass then
        signal = ctx.whitelistedChar and "whitelist_char" or "whitelist_account"
    elseif recipePass then
        signal = "recipe"
    elseif isJunk then
        signal = "junk"
    else
        signal = "quality"
    end
    return "sell", signal, { signal = signal }
end

-- ---------------------------------------------------------------------------
-- Pure core: delete eligibility (v2.71.3, classifier Stage 4).
-- ---------------------------------------------------------------------------
-- "Is this Delete-List item instance destroyable right now?" - a faithful
-- transcription of WC_compCache.deleteListSlotEligible at v2.71.2 (which
-- now delegates here). Returns eligible (boolean), token, fields.
--
-- The v2.50.2 rescue vetoes (the Stickybackpack shirt-loss fix) are the
-- load-bearing part: the auto-mark scans write to deleteList WITHOUT the
-- cross-list conflict guard, so any later Keep intent (Keep List, account
-- Sell List, equipped) must rescue the item at DESTRUCTION time.
-- WC-TRAP: do NOT collapse these vetoes into one another, and note the
-- asymmetry is deliberate: the ACCOUNT Sell List vetoes (a cross-character
-- "I want this" signal) but the character Sell List does not.
--
-- Callers gate on DB.enableDeletion themselves (ctx.enableDeletion is in
-- the snapshot for renderers); this predicate answers eligibility only.
function Decision.deleteEligible(ctx)
    if not ctx or not ctx.itemID then
        return false, "empty"
    end
    if not ctx.onDeleteList then
        return false, "notOnList"
    end
    if ctx.blacklisted then
        return false, "keepList"
    end
    if ctx.whitelistedAccount then
        return false, "sellList"
    end
    if ctx.equipped then
        return false, "equipped"
    end
    if not ctx.count or ctx.count <= 0 or ctx.locked then
        return false, "locked"
    end
    return true, "deleteList"
end

-- ---------------------------------------------------------------------------
-- Adapters: capture everything the core needs from the live game state.
-- ---------------------------------------------------------------------------
-- Cheap reads are snapshotted; tooltip-backed predicates ride as thunks
-- so the core pays for them only on the branches that need them (the
-- same lazy profile WC_IsSellable had). All WC_compCache accessors keep
-- their own itemID/itemString caches, so repeated thunk calls are cheap.
-- DB / ADB resolve at CALL time (EnsureDB rebinds NS.DB per login; this
-- file loads before Events - the Test 41 load-order trap).
--
-- Two adapters share one snapshot helper so they cannot drift:
--   * buildCtx(bag, slot, junkOnly) - the vendor engine + trace surface;
--     item-instance predicates read the hidden scan tooltip via the
--     bag/slot accessors.
--   * buildTooltipCtx(tooltip, itemID) - the live-tooltip surface
--     (v2.71.2, classifier Stage 3); there is NO bag/slot for a hovered
--     or chat-linked item, so instance predicates read the LIVE tooltip
--     via the liveTooltip* scanners instead. Same per-instance
--     semantics (the hovered tooltip IS the instance).

-- Shared snapshot: itemID-keyed memberships, the settings the core
-- reads (none of these depend on how
-- the item instance is being inspected).
local function WC_fillSharedCtx(ctx, DB, ADB, itemID, quality)
    local IsInSet = NS.IsInSet
    -- memberships / cheap values
    ctx.whitelistedChar = IsInSet(DB.whitelist, itemID)
    ctx.whitelistedAccount = (ADB and IsInSet(ADB.whitelist, itemID)) or false
    -- A host bag UI's own "never sell" lock counts as a Keep List entry
    -- everywhere (sell, delete, tooltip, trace); its "sell as junk" mark
    -- counts as junk. Both are adapter thunks set by BagDisplay when such a
    -- host is loaded, so the pure core only ever sees booleans.
    ctx.hostLocked = (WC_compCache.hostLocked and WC_compCache.hostLocked(itemID)) and true or false
    ctx.hostMarkedJunk = (WC_compCache.hostMarkedJunk and WC_compCache.hostMarkedJunk(itemID)) and true or false
    ctx.blacklisted = IsInSet(DB.blacklist, itemID) or ctx.hostLocked
    ctx.onDeleteList = (DB.deleteList and IsInSet(DB.deleteList, itemID)) and true or false
    ctx.enableDeletion = DB.enableDeletion == true
    ctx.equipped = IsEquippedItem(itemID) and true or false
    ctx.isQuestItem = WC_compCache.isQuestItem(itemID)
    ctx.baselineProtected = (WC_compCache.baselineProtectedIDs and WC_compCache.baselineProtectedIDs[itemID])
            and true
        or false
    ctx.allowedItem = (ADB and ADB.allowedItems and ADB.allowedItems[itemID]) and true or false
    -- settings snapshot
    ctx.qualityRule = (quality and DB.qualityRules) and DB.qualityRules[quality] or nil
    ctx.sellGreys = DB.sellGreys ~= false
    ctx.sellKnownRecipes = DB.sellKnownRecipes
    ctx.sellKnownRecipeQuality = (quality and DB.sellKnownRecipeQualities) and DB.sellKnownRecipeQualities[quality]
        or false
    ctx.recipeBindFilter = (quality and DB.sellKnownRecipeBindFilter) and DB.sellKnownRecipeBindFilter[quality]
        or "any"
    ctx.protectAllTomes = DB.protectAllTomes
    ctx.protectUnlearnedTomes = DB.protectUnlearnedTomes
    ctx.protectUncollectedAppearances = DB.protectUncollectedAppearances
    ctx.protectTradeableLoot = DB.protectTradeableLoot
    -- itemID-keyed thunks (identical for both adapters)
    function ctx.tomeKind()
        return WC_compCache.tomeKind(itemID)
    end
end

function Decision.buildCtx(bag, slot, junkOnly)
    local DB = NS.DB
    local ADB = NS.ADB
    if not DB or not WC_compCache then
        return nil
    end
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return { itemID = nil }
    end
    local cInfo = C_Container.GetContainerItemInfo(bag, slot)
    local itemCount = cInfo and cInfo.stackCount
    local locked = cInfo and cInfo.isLocked
    local name, link, quality, ilvl, _, _, _, _, equipLoc, _, sellPrice = GetItemInfo(itemID)
    -- The copy's real item level. GetItemInfo(itemID) gives the base level;
    -- an upgraded or bonus-ID copy is higher, and judging it by the base
    -- would let the "below equipped" rule sell an upgrade.
    -- Gear only: nothing else is judged by item level.
    if equipLoc and equipLoc ~= "" then
        local current = C_Item.GetCurrentItemLevel(Decision.slotLocation(bag, slot))
        if current and current > 0 then
            ilvl = current
        end
    end
    local ctx = {
        junkOnly = junkOnly and true or false,
        bag = bag,
        slot = slot,
        itemID = itemID,
        count = itemCount,
        locked = locked,
        name = name,
        link = link,
        quality = quality,
        ilvl = ilvl,
        equipLoc = equipLoc,
        sellPrice = sellPrice,
    }
    WC_fillSharedCtx(ctx, DB, ADB, itemID, quality)
    -- instance predicates: hidden scan tooltip via bag/slot accessors
    function ctx.bindType()
        return WC_compCache.getBindType(bag, slot)
    end
    function ctx.downgradeVsEquipped()
        return WC_compCache.isDowngradeVsEquipped(itemID, ilvl, equipLoc)
    end
    function ctx.isTome()
        return WC_compCache.itemIsTome(bag, slot, itemID)
    end
    function ctx.knowsTomeSpell()
        return WC_compCache.playerKnowsTomeSpell(bag, slot, itemID)
    end
    function ctx.uncollectedAppearance()
        return WC_compCache.isUncollectedAppearance(GetContainerItemLink(bag, slot))
    end
    function ctx.tradeable()
        return WC_compCache.isTradeableOrRefundable(bag, slot)
    end
    return ctx
end

-- v2.71.2 (classifier Stage 3): live-tooltip adapter for the tooltip
-- annotation surface. The hovered (or chat-linked) instance has no
-- bag/slot, so the instance predicates read the LIVE tooltip through
-- the same liveTooltip* scanners WC_AnnotateTooltip has always used -
-- the verdict describes what the vendor engine would do to this item
-- as rendered. count=1 / locked=false: a hover is never mid-pickup.
function Decision.buildTooltipCtx(tooltip, itemID)
    local DB = NS.DB
    local ADB = NS.ADB
    if not DB or not WC_compCache or not itemID then
        return nil
    end
    local name, link, quality, ilvl, _, _, _, _, equipLoc, _, sellPrice = GetItemInfo(itemID)
    -- The hovered copy's own link carries its bonus IDs, so its level is
    -- the real one. A bag-button owner also gives us the copy's bag/slot,
    -- which the per-copy trade/refund check needs; other owners (chat
    -- links, the character sheet) have no slot and answer "no opinion".
    local _, tipLink = tooltip:GetItem()
    if tipLink then
        local actual = C_Item.GetDetailedItemLevelInfo(tipLink)
        if actual and actual > 0 then
            ilvl = actual
        end
    end
    local tipBag, tipSlot
    local owner = tooltip.GetOwner and tooltip:GetOwner()
    if owner and owner.GetSlotAndBagID then
        local s2, b2 = owner:GetSlotAndBagID()
        if b2 and s2 and C_Container.GetContainerItemID(b2, s2) == itemID then
            tipBag, tipSlot = b2, s2
        end
    end
    local ctx = {
        junkOnly = false,
        itemID = itemID,
        count = 1,
        locked = false,
        name = name,
        link = link,
        quality = quality,
        ilvl = ilvl,
        equipLoc = equipLoc,
        sellPrice = sellPrice,
    }
    WC_fillSharedCtx(ctx, DB, ADB, itemID, quality)
    -- instance predicates: the live tooltip IS the instance
    function ctx.bindType()
        return WC_compCache.getBindTypeFromTooltip and WC_compCache.getBindTypeFromTooltip(tooltip, itemID) or "any"
    end
    function ctx.downgradeVsEquipped()
        return WC_compCache.isDowngradeVsEquipped(itemID, ilvl, equipLoc)
    end
    function ctx.isTome()
        return WC_compCache.liveTooltipIsTome and WC_compCache.liveTooltipIsTome(tooltip, itemID) or false
    end
    function ctx.knowsTomeSpell()
        return WC_compCache.liveTooltipPlayerKnowsTome and WC_compCache.liveTooltipPlayerKnowsTome(tooltip, itemID)
            or false
    end
    function ctx.uncollectedAppearance()
        return WC_compCache.isUncollectedAppearance(tipLink)
    end
    function ctx.tradeable()
        return WC_compCache.isTradeableOrRefundable(tipBag, tipSlot)
    end
    return ctx
end
