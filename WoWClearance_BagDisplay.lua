-- WoWClearance_BagDisplay - bag-slot sell-border tint + sellinfo inspector.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 6 of the multi-stage file split tracked in docs/CODE_REVIEW.md
-- item 4. This file owns the Release-1 bag-display layer:
--
--   * Sell-border tint helpers (sellBorderButtons weak-keyed registry,
--     applySellBorder, bagSlotWillSell, updateSellBordersForBagFrame,
--     installHostBagBorderHook). The opt-in coloured ring around bag-
--     slot frames whose items would be sold at the next vendor visit.
--     Hooks the default container frames and the host bag UIs detected
--     at runtime; a category-based host gets "Sell" / "Delete" groups
--     instead of rings (see installHostBagBorderHook).
--   * NS.RefreshSellBorders body. Forward-declared as a no-op stub on
--     NS in WoWClearance_Events.lua so the Character Settings panel toggle
--     can call it before this file's bag-display hooks install; this
--     file replaces the stub with the real body. Lives on NS (not as
--     a file-scope local) because the stub-and-reassign pattern needs
--     to cross the file boundary.
--   * WC_compCache.qualityNames lookup table used by describeSellability.
--   * Sellability-trace inspector (describeSellability + printSellabilityTrace).
--     Drives /wc sellinfo and Alt+Shift+Right-Click on a bag item.
--     Walks the same decision chain WC_IsSellable runs in the same order
--     and emits a chat-line trace explaining which predicates passed /
--     failed for a given slot.
--   * bagSlotFromButton helper - resolves a host-bag-UI button back to
--     (bag, slot) by walking GetBag/GetID where available with the
--     `button:GetParent():GetID() / button:GetID()` fallback.
--
-- Every helper is attached to WC_compCache (the shared cache table
-- created in WoWClearance_Core.lua), so call sites elsewhere in the
-- addon already resolve via the WC_compCache upvalue. No call-site
-- changes are needed in WoWClearance_Events.lua for the cache helpers.
--
-- Cross-file dependencies read inline:
--   * NS.compCache             (Core)
--   * NS.IsSellable            (WoWClearance_Events.lua) - the central sell
--                                predicate; bagSlotWillSell + describeSellability
--                                consult it
--   * NS.PrintNice / PrintNicef (WoWClearance_Events.lua) - chat output for
--                                the sellinfo trace
--   * NS.scanTooltip           (WoWClearance_Events.lua via the frame creation)
--   * NS.DB                    (WoWClearance_Events.lua via EnsureDB) -
--                                captured as `local DB = NS.DB` at the
--                                start of each function that uses it
--   * NS.ADB                   (WoWClearance_Events.lua via EnsureAccountDB)
--                                - same pattern

local NS = select(2, ...)
local WC_compCache = NS.compCache
local L = NS.L

local GetItemInfo = C_Item.GetItemInfo
local GetContainerItemID = C_Container.GetContainerItemID
local GetContainerItemLink = C_Container.GetContainerItemLink
local GetContainerNumSlots = C_Container.GetContainerNumSlots

-- ===========================================================================
-- Bag display: sell-border tint
-- ===========================================================================
-- Opt-in coloured ring around bag-slot FRAMES whose items the current rule
-- chain would sell at the next vendor visit. The ring texture lives on a
-- frame-overlay sublevel; nothing is drawn on top of the item icon itself,
-- so the slot's quality border + icon stay pristine.
--
-- Four surfaces are decorated:
--   1. The default container frames (`ContainerFrame_Update` hook on
--      3.3.5a, the per-frame `UpdateItems` hook on Forever) - covers
--      the no-extra-bag-UI case and any user who hasn't installed a host
--      bag UI replacement.
--   2. The legacy AceAddon-3.0-registered host bag UI's per-slot class,
--      detected at runtime via LibStub. Re-hooks both the slot's per-call
--      update and its border-only update path so search-fade transitions
--      don't leave a stale ring behind.
--   3. The engine-table-exposure host bag UI's per-slot redraw path,
--      detected at runtime via the framework's global table + module
--      lookup. The slot button is reached through the bag-frame's
--      Bags[bagID][slotID] table.
--   4. The category-based host bag UI, which hides the default frames and
--      draws its own grouped sections. No ring: items that will sell or
--      be deleted are grouped under "WoWClearance: Sell" / "WoWClearance:
--      Delete" through the host's category-function API.
--   5. A full UI suite that reports its bag slots through a public
--      plugin API (a per-slot paint callback plus a holder frame).
-- A full UI replacement that disables the default bags and exposes none
-- of these shows no rings (no error).
--
-- Helpers hang off WC_compCache (not module-local) because the main chunk
-- sits near Lua 5.1's 200-local cap; the registry table is a junk drawer
-- specifically for this case. Decorated buttons are tracked in a weak-keyed
-- set so the toggle and colour picker can re-apply (or hide) the ring
-- across all visible bags without an extra event subscription. Recycled
-- / GC'd buttons drop out naturally via the weak-key metatable.

WC_compCache.sellBorderButtons = setmetatable({}, { __mode = "k" })

-- Set-membership helper. Captures the canonical NS.IsInSet (defined in
-- WoWClearance_Core.lua); per-call cost is one local read.
local IsInSet = NS.IsInSet

-- Per-category sell-verdict resolver. Returns one of the category string
-- keys defined in EnsureDB's DB.sellBorderCategories ("delete" /
-- "accountSell" / "charSell" / "junk" / "rule"), or nil when the slot
-- shouldn't be tinted at all.
--
-- Priority order matches the tooltip annotation:
--   1. Delete List (red) - highest visibility because deletion is
--      irreversible. Gated on DB.enableDeletion so toggling that flag
--      hides the tint.
--   2. Account Sell List - explicit user intent, account-wide scope.
--   3. Character Sell List - explicit user intent, per-character.
--   4. Junk - quality 0 with sell price. The "always sells" baseline.
--   5. Rule - per-rarity rule match (the v2.29 default tint case).
--
-- Returns nil cheaply when the master toggle is off, when the slot is
-- empty, when DB hasn't bootstrapped yet, or when no verdict applies.
function WC_compCache.bagSlotWillSellCategory(bag, slot)
    local DB = NS.DB
    if not (DB and DB.sellBorderEnabled and DB.itemHighlighting ~= false) then
        return nil
    end
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return nil
    end
    -- Delete List path is separate from WC_IsSellable (which returns
    -- false for delete-listed items because they don't go through the
    -- merchant pipeline). Check it first so the red tint is honoured
    -- even though the item "won't sell" from WC_IsSellable's POV.
    -- Same eligibility the tooltip and Delete Next use, so a Delete-List
    -- item rescued by the Keep List, the account Sell List or a worn copy
    -- is not ringed red. "locked" (mid-drag) still counts as delete.
    if DB.enableDeletion and IsInSet(DB.deleteList, itemID) then
        local ok, token = NS.Decision.deleteEligible(NS.Decision.buildCtx(bag, slot, false))
        if ok or token == "locked" then
            return "delete"
        end
    end
    -- v2.37.0: Keep List verdict. Keep-listed items also return false
    -- from WC_IsSellable (that's how the protection works), so the
    -- check has to happen BEFORE the sellable bail. The auto-tag
    -- (DB.blacklistAuto) filter excludes equipped / upgrade / set-
    -- tagged entries; the "keep" tint is for MANUAL Keep List adds
    -- only - the visual-reassurance use case targets explicit user
    -- intent, not addon-driven auto-protections. See
    -- EbonClearance's docs/specs/2026-05-28-keep-highlighting-design.md.
    if IsInSet(DB.blacklist, itemID) and not (DB.blacklistAuto and DB.blacklistAuto[itemID]) then
        return "keep"
    end
    -- Everything below this point requires the item to be sellable per
    -- the normal predicate chain. Filters out protected items,
    -- equipped items, items without a sell price, etc.
    local sellable = NS.IsSellable(bag, slot, false)
    if not sellable then
        return nil
    end
    local ADB = NS.ADB
    if ADB and IsInSet(ADB.whitelist, itemID) then
        return "accountSell"
    end
    if IsInSet(DB.whitelist, itemID) then
        return "charSell"
    end
    -- Junk = grey (quality 0) with positive sell price. WC_IsSellable
    -- returned true so we know it's sellable; the grey discriminator
    -- separates it from per-rarity-rule matches.
    local _, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
    if quality == 0 and sellPrice and sellPrice > 0 then
        return "junk"
    end
    -- Default: the per-rarity rule sweep matched. Gold tint by default
    -- (the v2.29 single-colour default).
    return "rule"
end

function WC_compCache.applySellBorder(button, bag, slot)
    local DB = NS.DB
    if not button then
        return
    end
    -- Stash (bag, slot) on the button so the refresh helper (called from
    -- the Character Settings toggle / colour picker / list mutation) can
    -- re-evaluate the predicate without re-walking the bag tree to figure
    -- out which slot this button currently represents.
    if bag and slot then
        button._wc_sellBag = bag
        button._wc_sellSlot = slot
    end
    -- Track every button we've ever decorated, even when the current
    -- verdict is "won't sell". Without this, a button that first paints
    -- with no tint (e.g. bags open with an item not yet on any list)
    -- never enters the registry, and a later list mutation that flips it
    -- to tinted can't find it during refresh. The set is weak-keyed so
    -- recycled / freed buttons drop out naturally.
    WC_compCache.sellBorderButtons[button] = true

    -- Master gate: feature disabled OR DB not yet bootstrapped.
    if not (DB and DB.sellBorderEnabled and DB.itemHighlighting ~= false) then
        if button._wc_sellBorder then
            button._wc_sellBorder:Hide()
        end
        return
    end

    local category = (bag and slot) and WC_compCache.bagSlotWillSellCategory(bag, slot) or nil
    if not category then
        if button._wc_sellBorder then
            button._wc_sellBorder:Hide()
        end
        return
    end

    -- Per-category enable + colour lookup. A category with enabled =
    -- false (user opted out of that one tint) hides the border just
    -- like a no-verdict slot.
    local catSettings = DB.sellBorderCategories and DB.sellBorderCategories[category]
    if not (catSettings and catSettings.enabled and catSettings.color) then
        if button._wc_sellBorder then
            button._wc_sellBorder:Hide()
        end
        return
    end

    local c = catSettings.color
    -- Flat-slot hosts (button._wc_flatRing): the additive glow below does not
    -- read on flat, tightly packed slots, so draw a plain 2 px solid border
    -- on the slot's own edge instead.
    if button._wc_flatRing then
        local f = button._wc_sellBorder
        if not f then
            f = CreateFrame("Frame", nil, button)
            f:SetAllPoints(button)
            f.edges = {}
            local sides = {
                { "TOPLEFT", "TOPRIGHT", nil, 2 },
                { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 2 },
                { "TOPLEFT", "BOTTOMLEFT", 2, nil },
                { "TOPRIGHT", "BOTTOMRIGHT", 2, nil },
            }
            for i, sd in ipairs(sides) do
                local t = f:CreateTexture(nil, "OVERLAY", nil, 7)
                t:SetPoint(sd[1])
                t:SetPoint(sd[2])
                if sd[3] then
                    t:SetWidth(sd[3])
                else
                    t:SetHeight(sd[4])
                end
                f.edges[i] = t
            end
            button._wc_sellBorder = f
        end
        for _, t in ipairs(f.edges) do
            t:SetColorTexture(c.r, c.g, c.b, c.a or 0.9)
        end
        f:Show()
        return
    end

    local b = button._wc_sellBorder
    if not b then
        -- OVERLAY sublevel 6 sits above the quality border at default
        -- sublevel; the ADD blend composes additively so a coloured ring
        -- reads on top of the quality colour without flattening it.
        b = button:CreateTexture(nil, "OVERLAY", nil, 6)
        b:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        b:SetBlendMode("ADD")
        b:SetPoint("CENTER", button)
        button._wc_sellBorder = b
    end
    -- Size the ring relative to the button each call so the visible
    -- glow hugs the slot edge consistently across host bag UIs with
    -- different button sizes. The 67/37 ratio matches Blizzard's
    -- default container slot (37 px button -> 67 px texture, glow at
    -- slot edge); smaller / larger host slots scale proportionally
    -- to preserve the same tight visual. Per-call (not per-create)
    -- so dynamic resizes by the host adapter still track.
    local sw = button:GetWidth()
    if not sw or sw <= 0 then
        sw = 37
    end
    local textureSize = math.floor(sw * 67 / 37 + 0.5)
    b:SetWidth(textureSize)
    b:SetHeight(textureSize)
    b:SetVertexColor(c.r, c.g, c.b, c.a or 0.9)
    b:Show()
end

-- Boolean wrapper that returns whether the slot would tint under the
-- current settings. Preserved as a public predicate (callers expect a
-- bool); delegates to the category resolver. Returns true when the
-- master toggle is off only if a category WOULD have matched - kept
-- backwards compatible: any path that previously gated on
-- bagSlotWillSell still gates correctly.
function WC_compCache.bagSlotWillSell(bag, slot)
    return WC_compCache.bagSlotWillSellCategory(bag, slot) ~= nil
end

function WC_compCache.updateSellBordersForBagFrame(frame)
    if not (frame and frame.size) then
        return
    end
    local name = frame:GetName()
    if not name then
        return
    end
    local bag = frame:GetID()
    if not bag then
        return
    end
    -- Slot buttons are reverse-indexed in the frame's name: button "Item1"
    -- maps to the LAST slot visually, so iterate the size and reverse the
    -- index when building the global name. applySellBorder resolves the
    -- per-slot verdict internally via bagSlotWillSellCategory, so callers
    -- don't pre-compute it here.
    local apply = WC_compCache.applySellBorder
    for slot = 1, frame.size do
        local button = _G[name .. "Item" .. (frame.size - slot + 1)]
        if button then
            apply(button, bag, slot)
        end
    end
end

-- v0.5.2 port fix. WC-TRAP: the guard below is NOT dead code, and the
-- Forever branch under it is why keep/sell highlighting works at all here.
-- ContainerFrame_Update does not exist on this client (zero occurrences
-- across the shipped UI source), so the 3.3.5a hook silently never
-- installed and NO bag highlighting appeared - no error, no warning.
-- Measured in-game 2026-09-19.
--
-- Forever's equivalent is ContainerFrameMixin:UpdateItems. Two shape
-- differences matter, both verified against
-- Blizzard_UIPanels_Game/Mainline/ContainerFrame.lua:
--   * frame.size and the reverse-indexed _G[name.."Item"..n] naming are
--     gone. BaseContainerFrameMixin:EnumerateItems returns ipairs(self.Items),
--     so we iterate the real buttons instead of reconstructing names.
--   * ContainerFrameItemButtonMixin:GetSlotAndBagID returns (slot, bagID)
--     IN THAT ORDER. Reversing it silently paints the wrong slots.
if _G.ContainerFrame_Update then
    hooksecurefunc("ContainerFrame_Update", WC_compCache.updateSellBordersForBagFrame)
else
    function WC_compCache.updateSellBordersForContainerFrame(frame)
        if not (frame and frame.EnumerateItems) then
            return
        end
        local apply = WC_compCache.applySellBorder
        for _, button in frame:EnumerateItems() do
            if button and button.GetSlotAndBagID then
                local slot, bag = button:GetSlotAndBagID()
                if bag and slot then
                    apply(button, bag, slot)
                end
            end
        end
    end

    -- Mixin methods are copied onto each frame when that frame is created,
    -- so hooking the mixin TABLE would miss every container frame that
    -- already exists. Hook the instances instead, and re-check cheaply
    -- because bag frames can be built on demand. The per-frame flag keeps
    -- this idempotent - hooksecurefunc appends, so hooking twice would
    -- paint twice per update.
    function WC_compCache.ensureContainerFrameHooks()
        local n = _G.NUM_CONTAINER_FRAMES or 13
        for i = 1, n do
            local f = _G["ContainerFrame" .. i]
            if f and f.UpdateItems and not f.__wcSellBorderHooked then
                f.__wcSellBorderHooked = true
                hooksecurefunc(f, "UpdateItems", WC_compCache.updateSellBordersForContainerFrame)
                if WC_compCache.applyContainerItemLevelForever then
                    hooksecurefunc(f, "UpdateItems", WC_compCache.applyContainerItemLevelForever)
                end
            end
        end
        local combined = _G.ContainerFrameCombinedBags
        if combined and combined.UpdateItems and not combined.__wcSellBorderHooked then
            combined.__wcSellBorderHooked = true
            hooksecurefunc(combined, "UpdateItems", WC_compCache.updateSellBordersForContainerFrame)
            if WC_compCache.applyContainerItemLevelForever then
                hooksecurefunc(combined, "UpdateItems", WC_compCache.applyContainerItemLevelForever)
            end
        end
    end
end

-- Host bag-UI adapter. Two surfaces are recognised, each with its own
-- install-once flag so the presence (or absence) of one host doesn't
-- block the other from installing:
--
--   1. Legacy AceAddon-3.0 host: per-slot class with :GetBag() /
--      :GetID() / :GetItem() / :IsCached() methods. Hook the slot
--      class's Update + UpdateBorder methods; force-repaint via the
--      host's per-frame UpdateEverything.
--   2. UI-replacement framework with an "engine table → module" exposure
--      pattern (table at _G, unpack to engine, engine:GetModule("Bags")).
--      The bags module exposes per-slot UpdateSlot(frame, bagID, slotID)
--      and the slot button lives at frame.Bags[bagID][slotID]. Hook the
--      method; force-repaint via the module's UpdateAllBagSlots.
--
-- `installHostBagBorderHook` is called from two sites in the event hub
-- (ADDON_LOADED and PLAYER_LOGIN + 2 s fallback); each attempt below is
-- idempotent through its own install flag.
function WC_compCache.installHostBagBorderHook()
    local apply = WC_compCache.applySellBorder

    -- Attempt 1: legacy AceAddon-3.0-registered host. The slot class
    -- carries its own :GetBag()/:GetID()/:GetItem()/:IsCached() helpers
    -- so we resolve identity per-slot rather than via a container frame.
    local function tryLegacyHost()
        if WC_compCache._hostBagBorderHookInstalled then
            return
        end
        local LibStub = _G.LibStub
        if not LibStub then
            return
        end
        local ok, ace = pcall(LibStub, "AceAddon-3.0", true)
        if not ok or not ace or not ace.GetAddon then
            return
        end
        local ok2, host = pcall(ace.GetAddon, ace, "Bagnon")
        if not ok2 or not host or not host.ItemSlot then
            return
        end

        local ItemSlot = host.ItemSlot

        local function refresh(slot)
            if not (slot and slot.GetBag and slot.GetID) then
                return
            end
            if slot.IsCached and slot:IsCached() then
                apply(slot)
                return
            end
            local link = slot.GetItem and slot:GetItem()
            if not link then
                apply(slot)
                return
            end
            local bag, id = slot:GetBag(), slot:GetID()
            if not (bag and id) then
                return
            end
            apply(slot, bag, id)
        end

        hooksecurefunc(ItemSlot, "Update", refresh)
        if ItemSlot.UpdateBorder then
            hooksecurefunc(ItemSlot, "UpdateBorder", refresh)
        end
        WC_compCache._hostBagBorderHookInstalled = true

        -- Force a one-shot repaint of any already-visible host bag frames.
        -- Without this, slots painted by the host BEFORE our hook installed
        -- sit with no border until the player triggers another host refresh
        -- (open bag, visit bank, move an item). The hook only fires forward.
        if host.frames then
            for _, frame in pairs(host.frames) do
                if frame and frame.UpdateEverything and frame.IsVisible and frame:IsVisible() then
                    pcall(frame.UpdateEverything, frame)
                end
            end
        end
    end

    -- Attempt 2: UI-replacement framework with the engine-table exposure
    -- pattern. The framework table is a global; unpack(table) yields
    -- (Engine, Locales, PrivateDB, ProfileDB, GlobalDB); Engine:GetModule
    -- ("Bags") returns the bag module B which exposes
    -- B:UpdateSlot(frame, bagID, slotID) as the per-slot redraw path.
    -- The slot button is reachable as frame.Bags[bagID][slotID].
    local function tryEngineHost()
        if WC_compCache._engineBagBorderHookInstalled then
            return
        end
        -- Detection code names the framework global directly because we
        -- have to know what to read off _G; the comment frames it
        -- neutrally per the project's third-party-naming rule. The
        -- exact global identifier is necessary for runtime resolution.
        local hostTable = _G.ElvUI
        if type(hostTable) ~= "table" then
            return
        end
        local ok, engine = pcall(unpack, hostTable)
        if not ok or type(engine) ~= "table" or type(engine.GetModule) ~= "function" then
            return
        end
        local ok2, B = pcall(engine.GetModule, engine, "Bags")
        if not ok2 or type(B) ~= "table" or type(B.UpdateSlot) ~= "function" then
            return
        end

        hooksecurefunc(B, "UpdateSlot", function(_self, frame, bagID, slotID)
            if not frame or type(frame.Bags) ~= "table" then
                return
            end
            local bag = frame.Bags[bagID]
            if not bag then
                return
            end
            local slotButton = bag[slotID]
            if not slotButton then
                return
            end
            apply(slotButton, bagID, slotID)
        end)

        WC_compCache._engineBagBorderHookInstalled = true

        -- Force a one-shot repaint of any already-visible bag frames.
        -- Same rationale as the legacy attempt above; slots painted
        -- before the hook installed otherwise sit with no border until
        -- the next host-driven slot refresh.
        if B.UpdateAllBagSlots then
            pcall(B.UpdateAllBagSlots, B)
        end

        -- Belt-and-braces direct paint by predictable global frame
        -- name. The host's Layout path creates slot buttons named
        -- "<bagFrameName>Bag<bagID>Slot<slotID>", and the bag frames
        -- the host builds eagerly during its module init are named
        -- ElvUI_ContainerFrame (main) and ElvUI_BankContainerFrame
        -- (bank, lazy). This loop runs even when B.UpdateAllBagSlots
        -- bailed (e.g. B.BagFrames not yet populated, or the host's
        -- bags feature disabled) so the first paint after WC install
        -- doesn't depend on a subsequent host-driven update firing.
        -- The names are needed for runtime lookup; comments stay
        -- neutral per the project's third-party-naming rule.
        local function paintByName(framePrefix, bagRange)
            for _, bagID in ipairs(bagRange) do
                local numSlots = GetContainerNumSlots(bagID)
                if numSlots and numSlots > 0 then
                    for slotID = 1, numSlots do
                        local name = framePrefix .. "Bag" .. bagID .. "Slot" .. slotID
                        local slot = _G[name]
                        if slot then
                            apply(slot, bagID, slotID)
                        end
                    end
                end
            end
        end
        paintByName("ElvUI_ContainerFrame", { 0, 1, 2, 3, 4 })
        if _G.ElvUI_BankContainerFrame then
            paintByName("ElvUI_BankContainerFrame", { -1, 5, 6, 7, 8, 9, 10 })
        end
    end

    -- Attempt 3: category-based host bag UI (AceAddon-3.0 registered,
    -- with a "Categories" module). It hides the default container frames
    -- and draws its own grouped sections, so there is no slot button to
    -- ring. Instead, register a category function: the host asks it once
    -- per item and groups the item under the name it returns. The verdict
    -- is the same one the ring uses (bagSlotWillSellCategory, so it follows
    -- the Item Highlighting toggles), folded into two groups. Keep and
    -- no-verdict items return nil and stay where the host files them.
    -- The host caches the answer per item, so rule changes go through
    -- WC_compCache.refreshHostCategories (from NS.RefreshSellBorders).
    local function tryCategoryHost()
        if WC_compCache.refreshHostCategories then
            return
        end
        local LibStub = _G.LibStub
        local ace = LibStub and LibStub("AceAddon-3.0", true)
        local ok, host = pcall(function()
            return ace and ace:GetAddon("BetterBags", true)
        end)
        if not (ok and host and host.GetModule) then
            return
        end
        local cats = host:GetModule("Categories", true)
        local ctxMod = host:GetModule("Context", true)
        if not (cats and cats.RegisterCategoryFunction and cats.ReprocessAllItems and cats.WipeCategory and ctxMod) then
            return
        end
        local SELL, DELETE = L["WoWClearance: Sell"], L["WoWClearance: Delete"]
        local ok2 = pcall(cats.RegisterCategoryFunction, cats, "WoWClearance", function(data)
            local bag, slot = data and data.bagid, data and data.slotid
            -- Only the bags a vendor run reads (not the bank).
            if not (bag and slot) or data.isItemEmpty or bag < 0 or bag > NUM_TOTAL_EQUIPPED_BAG_SLOTS then
                return nil
            end
            local category = WC_compCache.bagSlotWillSellCategory(bag, slot)
            local DB = NS.DB
            local catSettings = category and DB and DB.sellBorderCategories and DB.sellBorderCategories[category]
            if not (catSettings and catSettings.enabled) or category == "keep" then
                return nil
            end
            return category == "delete" and DELETE or SELL
        end)
        if not ok2 then
            return
        end
        -- Coalesced: list edits and colour-picker drags can call this many
        -- times in a row, and a reprocess redraws every item. Wiping the two
        -- groups drops the cached answers so each item is asked again.
        local pending = false
        function WC_compCache.refreshHostCategories()
            if pending then
                return
            end
            pending = true
            C_Timer.After(0.5, function()
                pending = false
                pcall(function()
                    local ctx = ctxMod:New("WoWClearance")
                    cats:WipeCategory(ctx, SELL)
                    cats:WipeCategory(ctx, DELETE)
                    cats:ReprocessAllItems(ctx)
                end)
            end)
        end
        -- Items drawn before the function existed were filed without it.
        WC_compCache.refreshHostCategories()
    end

    -- Attempt 4: rings on the category-based host's own item buttons. The
    -- groups above only sort; this paints the same ring the default bags
    -- get. Item objects inherit their methods from one prototype table
    -- through __index, so a hook on the prototype reaches every button,
    -- including ones already built. The drawn button is the item's
    -- "decoration"; a button reused for an empty slot, a free-slot count or
    -- a bank item is cleared, so a later repaint cannot ring it from a
    -- stale bag/slot.
    local function tryCategoryHostRings()
        if WC_compCache._categoryHostRingsInstalled then
            return
        end
        local LibStub = _G.LibStub
        local ace = LibStub and LibStub("AceAddon-3.0", true)
        local ok, host = pcall(function()
            return ace and ace:GetAddon("BetterBags", true)
        end)
        if not (ok and host and host.GetModule) then
            return
        end
        local itemFrame = host:GetModule("ItemFrame", true)
        local proto = itemFrame and itemFrame.itemProto
        if not (proto and proto.SetItemFromData and proto.ResetVisuals and proto.GetDecoration) then
            return
        end
        local function clear(button)
            button._wc_sellBag, button._wc_sellSlot = nil, nil
            if button._wc_sellBorder then
                button._wc_sellBorder:Hide()
            end
        end
        hooksecurefunc(proto, "SetItemFromData", function(self, _ctx, data)
            local button = self._decoration
            if not button then
                return
            end
            local bag, slot = data and data.bagid, data and data.slotid
            if not (bag and slot) or data.isItemEmpty or bag < 0 or bag > NUM_TOTAL_EQUIPPED_BAG_SLOTS then
                clear(button)
                return
            end
            apply(button, bag, slot)
        end)
        hooksecurefunc(proto, "ResetVisuals", function(self)
            if self._decoration then
                clear(self._decoration)
            end
        end)
        WC_compCache._categoryHostRingsInstalled = true
        -- Buttons drawn before the hook: the group refresh above redraws
        -- every item, which now runs through the hook.
    end

    -- Attempt 5: a full UI suite whose bag slots are reported through its
    -- documented plugin API (version 1.3+: Paint kind "bagslot", and
    -- API.Attach for a holder frame over the slot). The ring is drawn on
    -- that holder, never on the host's own textures. Slots from another
    -- character's saved bags arrive as previews and are skipped, and the
    -- live slot must still hold the reported item, so a saved copy is
    -- never judged against this character's bags.
    local function tryPluginApiHost()
        if WC_compCache._pluginApiRingsInstalled then
            return
        end
        local host = _G.DaylightUI
        local API = type(host) == "table" and host.API
        if not (type(API) == "table" and API.major == 1 and (API.minor or 0) >= 3 and API.For and API.Attach) then
            return
        end
        local me = API.For("WoWClearance")
        if not (me and me.Paint and me.On) then
            return
        end
        local preview = setmetatable({}, { __mode = "k" })
        local function notePreview(kind, frame, _unit, isPreview)
            if kind == "bagslot" then
                preview[frame] = isPreview and true or nil
            end
        end
        me.On("FrameMade", notePreview)
        me.On("FrameUnitChanged", notePreview)
        me.Paint("bagslot", function(slotFrame, _parts, item)
            local holder = API.Attach(slotFrame)
            if not holder then
                return
            end
            local bag, slot = item and item.bag, item and item.slot
            if
                preview[slotFrame]
                or not (bag and slot and item.itemID)
                or bag < 0
                or bag > NUM_TOTAL_EQUIPPED_BAG_SLOTS
                or GetContainerItemID(bag, slot) ~= item.itemID
            then
                holder._wc_sellBag, holder._wc_sellSlot = nil, nil
                if holder._wc_sellBorder then
                    holder._wc_sellBorder:Hide()
                end
                return
            end
            holder._wc_flatRing = true
            apply(holder, bag, slot)
        end)
        WC_compCache._pluginApiRingsInstalled = true
    end

    -- Attempt 6: the same suite's bag groups and item menu. Reached through
    -- its documented me.Wrap on the Bags module's own tables (allowed, but
    -- not promised stable by the host, so every lookup is checked).
    --   * One group per WoWClearance list (Delete / Sell / Account Sell /
    --     Keep), made once per host profile. A group the player deletes
    --     stays deleted, and an item the player pinned to a group stays put.
    --   * Its Alt+Right-Click menu gets a "WoWClearance..." row that opens
    --     ours, instead of both menus opening on the same click.
    -- Needs the Bags module enabled (its saved data exists); until then
    -- this returns unflagged and the login retry tries again.
    local function tryPluginApiBagGroups()
        if WC_compCache._pluginApiGroupsInstalled then
            return
        end
        local host = _G.DaylightUI
        local API = type(host) == "table" and host.API
        if not (type(API) == "table" and API.major == 1 and (API.minor or 0) >= 3 and API.For and host.GetModule) then
            return
        end
        local mod = host:GetModule("Bags")
        local bns = type(mod) == "table" and mod.ns
        local Cat = type(bns) == "table" and bns.Categories
        local hostDB = type(bns) == "table" and type(bns.module) == "table" and bns.module.db
        if not (type(Cat) == "table" and Cat.Assign and Cat.AddCustom and Cat.Get and Cat.PinOf and type(hostDB) == "table") then
            return
        end
        local me = API.For("WoWClearance")
        if not (me and me.Wrap and me.AddDefaults) then
            return
        end
        WC_compCache._pluginApiGroupsInstalled = true

        -- Group keys live in the host profile beside its own groups, so a
        -- profile switch there brings its own set.
        me.AddDefaults("Bags", { wowclearanceGroups = false })
        if type(hostDB.wowclearanceGroups) ~= "table" then
            hostDB.wowclearanceGroups = {}
        end
        local keys = hostDB.wowclearanceGroups
        -- setName: the WoWClearance list each group mirrors.
        local GROUPS = {
            { id = "delete", name = L["Delete List"], setName = "deleteList" },
            { id = "charSell", name = L["Sell List"], setName = "whitelist" },
            { id = "accountSell", name = L["Account Sell List"], setName = "accountWhitelist" },
            { id = "keep", name = L["Keep List"], setName = "blacklist" },
        }
        local byKey = {} -- host group key -> GROUPS entry
        for _, g in ipairs(GROUPS) do
            if keys[g.id] == nil then
                keys[g.id] = Cat.AddCustom(g.name) or false
            end
            if keys[g.id] then
                byKey[keys[g.id]] = g
            end
        end
        -- These groups follow list membership only. A pin into one (the
        -- host's menu used to pin there) would hold an item in a list group
        -- it is not on, so drop those pins.
        if Cat.Unpin and type(hostDB.pins) == "table" then
            for itemID, k in pairs(hostDB.pins) do
                if byKey[k] then
                    Cat.Unpin(itemID)
                end
            end
        end

        local function groupFor(itemID)
            local DB, ADB = NS.DB, NS.ADB
            if not (DB and itemID) then
                return nil
            end
            local id
            if IsInSet(DB.deleteList, itemID) then
                id = "delete"
            elseif IsInSet(DB.whitelist, itemID) then
                id = "charSell"
            elseif ADB and IsInSet(ADB.whitelist, itemID) then
                id = "accountSell"
            elseif IsInSet(DB.blacklist, itemID) and not (DB.blacklistAuto and DB.blacklistAuto[itemID]) then
                -- Manual Keep List entries only; auto-kept gear (equipped,
                -- upgrades, sets) stays in its own group.
                id = "keep"
            end
            local key = id and keys[id]
            return key and Cat.Get(key) and key or nil
        end
        me.Wrap(Cat, "Assign", function(original, f, section)
            local key = original(f, section)
            if section == "keyring" or type(f) ~= "table" or Cat.PinOf(f.itemID) then
                return key
            end
            return groupFor(f.itemID) or key
        end)

        -- A list edit re-files the items (chained after any other host's
        -- category refresh).
        local prevRefresh = WC_compCache.refreshHostCategories
        WC_compCache.refreshHostCategories = function()
            if prevRefresh then
                prevRefresh()
            end
            if bns.Relayout then
                bns.Relayout()
            end
            if bns.FillAll then
                bns.FillAll()
            end
        end
        if bns.Relayout then
            bns.Relayout()
        end

        -- The host's own item marks feed our decisions (Decision.buildCtx):
        -- its lock ("never sold or disenchanted") is a Keep, its "sell as
        -- junk" mark is junk.
        if Cat.IsLocked then
            WC_compCache.hostLocked = function(itemID)
                return Cat.IsLocked(itemID) == true
            end
        end
        if Cat.IsMarkedJunk then
            WC_compCache.hostMarkedJunk = function(itemID)
                return Cat.IsMarkedJunk(itemID) == true
            end
        end

        -- One seller of JUNK at vendors. The host's own "sell junk" reads
        -- as off only while we will sell that junk ourselves: vendor selling
        -- on AND "Sell grey items" on. With either off we do not sell junk
        -- (Decision.sell gates greys and host junk marks on sellGreys), so
        -- the host's sale must run or junk would never sell at all - the
        -- v0.8.1 bug, where sellGreys was off and the host was still muted.
        if type(bns.Setting) == "function" then
            me.Wrap(bns, "Setting", function(original, key, ...)
                if key == "sellJunk" then
                    local DB = NS.DB
                    if
                        DB
                        and DB.sellAtVendor ~= false
                        and DB.sellGreys ~= false
                        and NS.IsAddonEnabledForChar
                        and NS.IsAddonEnabledForChar()
                    then
                        return false
                    end
                end
                return original(key, ...)
            end)
        end

        -- One menu: our row on top of the host's.
        local widgets = host.Widgets
        if Cat.Menu and type(widgets) == "table" and widgets.OpenMenu then
            local menuFor
            me.Wrap(Cat, "Menu", function(original, btn, ...)
                menuFor = btn
                original(btn, ...)
                menuFor = nil
            end)
            me.Wrap(widgets, "OpenMenu", function(original, owner, list, values, current, onPick, ...)
                if owner ~= menuFor or type(list) ~= "table" or not NS.ShowItemContextMenu then
                    return original(owner, list, values, current, onPick, ...)
                end
                menuFor = nil
                local bag, slot = WC_compCache.bagSlotFromButton(owner)
                if not (bag and slot and GetContainerItemID(bag, slot)) then
                    return original(owner, list, values, current, onPick, ...)
                end
                -- Our rows together at the top: the menu row, then the list
                -- groups in list order, then the host's own rows.
                local present = {}
                for _, k in ipairs(list) do
                    present[k] = true
                end
                local list2 = { "wowclearance" }
                for _, g in ipairs(GROUPS) do
                    local gk = keys[g.id]
                    if gk and present[gk] then
                        list2[#list2 + 1] = gk
                    end
                end
                for _, k in ipairs(list) do
                    if not byKey[k] then
                        list2[#list2 + 1] = k
                    end
                end
                local values2 = {}
                for k, v in pairs(values or {}) do
                    values2[k] = v
                end
                -- Ours in the brand blue so they stand out from the host's
                -- rows: the menu row and our list groups. A list group row
                -- adds the item to that WoWClearance list, or removes it
                -- when it is already there (never a host pin).
                local itemID = GetContainerItemID(bag, slot)
                values2.wowclearance = "|cff66ccff" .. L["WoWClearance..."] .. "|r"
                for gk, g in pairs(byKey) do
                    if values2[gk] then
                        local t = NS.GetListTable and NS.GetListTable(g.setName)
                        local label = (t and t[itemID]) and (L["Remove from "] .. g.name) or g.name
                        values2[gk] = "|cff66ccff" .. label .. "|r"
                    end
                end
                return original(owner, list2, values2, current, function(key, ...)
                    local g = byKey[key]
                    if key == "wowclearance" then
                        NS.ShowItemContextMenu(owner)
                    elseif g then
                        local t = NS.GetListTable and NS.GetListTable(g.setName)
                        if t and t[itemID] then
                            NS.RemoveItemFromList(g.setName, itemID, g.name)
                        else
                            NS.AddItemToList(g.setName, itemID, g.name)
                        end
                    elseif onPick then
                        return onPick(key, ...)
                    end
                end, ...)
            end)
            -- Tells our own Alt+Right-Click hook to stand down on these slots.
            WC_compCache.hostOwnsItemMenu = function(btn)
                return API.Attach(btn) ~= nil
            end
        end
    end

    tryLegacyHost()
    tryEngineHost()
    tryCategoryHostRings()
    tryCategoryHost()
    tryPluginApiHost()
    tryPluginApiBagGroups()
end

-- Pop-out windows (Loot Log, Sold History) fade their panel background to
-- the category-based host's backpack opacity, so they read the same when
-- open side by side. The host fades the same region (the panel template's
-- Bg). Read at each show, so a host setting change follows. Without the
-- host, nothing changes. pcall: the host's saved data may be half-built.
function NS.MatchHostBagOpacity(win)
    if not (win and win.Bg) then
        return
    end
    local ace = _G.LibStub and _G.LibStub("AceAddon-3.0", true)
    local ok, opacity = pcall(function()
        local host = ace:GetAddon("BetterBags", true)
        local db = host:GetModule("Database")
        local kind = host:GetModule("Constants").BAG_KIND.BACKPACK
        return db:GetBagSizeInfo(kind, db:GetBagView(kind)).opacity
    end)
    if ok and type(opacity) == "number" then
        win.Bg:SetAlpha(math.max(0, math.min(100, opacity)) / 100)
    end
end

-- Settings-flip refresh body. The forward-declared name was stubbed to a
-- no-op at file head; here we replace it with the real implementation so
-- toggling the checkbox or changing the colour repaints every decorated
-- slot button immediately, without waiting for the next bag event.
NS.RefreshSellBorders = function()
    WC_compCache.repaintSellBorders()
    -- A rule or highlight setting changed: re-file items in a category-
    -- based host bag UI too. Not done on the bag-update repaint (which
    -- calls repaintSellBorders directly): a full reprocess per loot would
    -- be far too costly.
    if WC_compCache.refreshHostCategories then
        WC_compCache.refreshHostCategories()
    end
end

function WC_compCache.repaintSellBorders()
    -- v0.5.2: on Forever the container frames are hooked per-instance, and
    -- bag frames can be created on demand, so make sure any new one is
    -- hooked before we repaint. Idempotent and cheap (a flag check per
    -- frame); a no-op on 3.3.5a where the global hook covers everything.
    if WC_compCache.ensureContainerFrameHooks then
        WC_compCache.ensureContainerFrameHooks()
    end
    -- Hidden buttons (closed bags, and the per-bag set while combined bags
    -- are showing, or vice versa) are skipped: each runs a full sell
    -- decision, and a bag repaints its own buttons through the UpdateItems
    -- hook above when it opens.
    local apply = WC_compCache.applySellBorder
    for button in pairs(WC_compCache.sellBorderButtons) do
        local bag, slot = button._wc_sellBag, button._wc_sellSlot
        if bag and slot and button:IsVisible() then
            apply(button, bag, slot)
        end
    end
end

-- ===========================================================================
-- v2.37.0 (Borrow C): item-level text overlay
-- ===========================================================================
-- Quality-coloured "N" text in the bottom-right corner of slot buttons
-- holding equippable gear. Three surfaces, each independently toggled
-- by Item Highlighting: bags (container + bank), paperdoll (character
-- sheet + inspect), merchant (vendor + buyback). The equipLoc
-- whitelist filters consumables / quest items / non-gear so the text
-- only appears where iLvl is meaningful. Master toggle defaults OFF;
-- when first enabled, bags seeds ON and the other two surfaces stay
-- OFF until the player ticks them. See
-- EbonClearance's docs/specs/2026-05-28-keep-highlighting-design.md (Borrow C).

local WC_ITEM_LEVEL_EQUIP_LOCS = {
    INVTYPE_HEAD = true,
    INVTYPE_NECK = true,
    INVTYPE_SHOULDER = true,
    INVTYPE_CHEST = true,
    INVTYPE_ROBE = true,
    INVTYPE_WAIST = true,
    INVTYPE_LEGS = true,
    INVTYPE_FEET = true,
    INVTYPE_WRIST = true,
    INVTYPE_HAND = true,
    INVTYPE_FINGER = true,
    INVTYPE_TRINKET = true,
    INVTYPE_CLOAK = true,
    INVTYPE_WEAPON = true,
    INVTYPE_SHIELD = true,
    INVTYPE_2HWEAPON = true,
    INVTYPE_WEAPONMAINHAND = true,
    INVTYPE_WEAPONOFFHAND = true,
    INVTYPE_HOLDABLE = true,
    INVTYPE_RANGED = true,
    INVTYPE_THROWN = true,
    INVTYPE_RANGEDRIGHT = true,
    INVTYPE_RELIC = true,
}

WC_compCache.itemLevelTexts = setmetatable({}, { __mode = "k" })

-- v2.37.0 (Borrow C polish): user-configurable font size for the iLvl
-- text. SetFontObject locks in the Blizzard font, then SetFont rewrites
-- the size to the player's chosen value (clamped 6-20 in EnsureDB).
-- Called from WC_ensureItemLevelText on first paint and from
-- NS.RefreshItemLevelOverlay so the slider change takes effect on
-- already-painted slots.
local function WC_applyItemLevelFont(fs)
    if not fs then
        return
    end
    fs:SetFontObject("NumberFontNormalSmall")
    local fontFile, _, fontFlags = fs:GetFont()
    if not fontFile then
        return
    end
    local DB = NS.DB
    local size = (DB and DB.itemLevelOverlay and DB.itemLevelOverlay.fontSize) or 12
    if size < 6 then
        size = 6
    elseif size > 20 then
        size = 20
    end
    fs:SetFont(fontFile, size, fontFlags or "")
end

local function WC_ensureItemLevelText(button)
    if not button then
        return nil
    end
    local existing = WC_compCache.itemLevelTexts[button]
    if existing then
        return existing
    end
    -- OVERLAY sublevel 7 (max) so the text renders above the host bag
    -- UI's own per-slot overlays (quality borders, stack-count text,
    -- new-item glow). Without an explicit sublevel the default 0 puts
    -- the FontString under those textures on hosts that paint on
    -- OVERLAY too, which read as "the iLvl toggle did nothing" on
    -- the bags surface.
    local fs = button:CreateFontString(nil, "OVERLAY", nil, 7)
    WC_applyItemLevelFont(fs)
    fs:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
    fs:SetJustifyH("RIGHT")
    fs:SetJustifyV("BOTTOM")
    fs:SetShadowColor(0, 0, 0, 0.95)
    fs:SetShadowOffset(1, -1)
    fs:Hide()
    WC_compCache.itemLevelTexts[button] = fs
    return fs
end

-- Returns iLvl iff the link points to equippable gear via the equipLoc
-- whitelist. Shirts (INVTYPE_BODY) and tabards (INVTYPE_TABARD) are
-- deliberately excluded because their iLvl is cosmetic / meaningless.
function WC_compCache.getGearItemLevel(itemLink)
    if not itemLink then
        return nil
    end
    local _, _, _, itemLevel, _, _, _, _, equipLoc = GetItemInfo(itemLink)
    if not itemLevel or itemLevel <= 0 then
        return nil
    end
    if not equipLoc or not WC_ITEM_LEVEL_EQUIP_LOCS[equipLoc] then
        return nil
    end
    return itemLevel
end

function WC_compCache.getGearQualityRGB(itemLink, fallbackQuality)
    local quality = fallbackQuality
    if not quality and itemLink then
        local _, _, q = GetItemInfo(itemLink)
        quality = q
    end
    if quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality] then
        local c = ITEM_QUALITY_COLORS[quality]
        return c.r, c.g, c.b
    end
    return 1, 1, 1
end

local function WC_itemLevelSurfaceEnabled(surface)
    local DB = NS.DB
    if not (DB and DB.itemHighlighting ~= false and DB.itemLevelOverlay and DB.itemLevelOverlay.enabled) then
        return false
    end
    return DB.itemLevelOverlay[surface] and true or false
end

function WC_compCache.applyItemLevelOverlay(button, itemLink, fallbackQuality, surface)
    if not button then
        return
    end
    button._wc_iLvlSurface = surface
    local fs = WC_ensureItemLevelText(button)
    if not fs then
        return
    end
    if not WC_itemLevelSurfaceEnabled(surface) then
        fs:Hide()
        return
    end
    local iLvl = WC_compCache.getGearItemLevel(itemLink)
    if not iLvl then
        fs:Hide()
        return
    end
    local r, g, b = WC_compCache.getGearQualityRGB(itemLink, fallbackQuality)
    fs:SetText(tostring(iLvl))
    fs:SetTextColor(r, g, b)
    fs:Show()
end

local function WC_applyContainerItemLevel(frame)
    -- v2.62.1 gate: the overlay defaults OFF, yet this hook used to pay two
    -- container API calls per slot (plus a lazy FontString per button) on
    -- every repaint regardless. Every path that flips the surface off goes
    -- through NS.RefreshItemLevelOverlay (Item Highlighting panel toggles),
    -- which hides already-painted numbers - so when disabled this hook can
    -- skip the walk entirely, mirroring the sell-border hook's early bail.
    if not WC_itemLevelSurfaceEnabled("bags") then
        return
    end
    if not (frame and frame.size) then
        return
    end
    local name = frame:GetName()
    if not name then
        return
    end
    local bag = frame:GetID()
    if not bag then
        return
    end
    for slot = 1, frame.size do
        local button = _G[name .. "Item" .. (frame.size - slot + 1)]
        if button then
            local link = GetContainerItemLink(bag, slot)
            local cInfo = C_Container.GetContainerItemInfo(bag, slot)
            local q = cInfo and cInfo.quality
            WC_compCache.applyItemLevelOverlay(button, link, q, "bags")
        end
    end
end
-- v0.5.3 (Serv report): the iLvl numbers rendered in bags at the DEFAULT
-- size and ignored the font-size slider, while the character sheet honoured
-- it. Cause is the same absent global as the sell-border hook above -
-- ContainerFrame_Update does not exist on Forever, so OUR bag overlay never
-- installed at all. The numbers still visible in bags are the client's own,
-- which of course do not read our slider. Forever path mirrors the border
-- one: EnumerateItems for the buttons, GetSlotAndBagID returning
-- (slot, bagID) IN THAT ORDER.
if _G.ContainerFrame_Update then
    hooksecurefunc("ContainerFrame_Update", WC_applyContainerItemLevel)
else
    function WC_compCache.applyContainerItemLevelForever(frame)
        if not WC_itemLevelSurfaceEnabled("bags") then
            return
        end
        if not (frame and frame.EnumerateItems) then
            return
        end
        for _, button in frame:EnumerateItems() do
            if button and button.GetSlotAndBagID then
                local slot, bag = button:GetSlotAndBagID()
                if bag and slot then
                    local link = GetContainerItemLink(bag, slot)
                    local cInfo = C_Container.GetContainerItemInfo(bag, slot)
                    WC_compCache.applyItemLevelOverlay(button, link, cInfo and cInfo.quality, "bags")
                end
            end
        end
    end
end

-- v2.37.0 (Borrow C polish): host bag-UI adapter for the item-level
-- overlay. Mirrors WC_compCache.installHostBagBorderHook above - same
-- two host patterns (legacy AceAddon-3.0 host with ItemSlot class;
-- engine-table-exposure host with Bags module), same idempotent
-- install flags, same one-shot repaint of already-visible bag frames.
-- Without this, players running with a host bag UI installed see iLvl
-- text only on character sheet + merchant; the bags surface paints
-- nothing because the default ContainerFrame_Update hook never fires
-- (the host replaced the underlying bag display).
function WC_compCache.installHostBagItemLevelHook()
    local apply = WC_compCache.applyItemLevelOverlay

    local function tryLegacyHost()
        if WC_compCache._hostBagItemLevelHookInstalled then
            return
        end
        local LibStub = _G.LibStub
        if not LibStub then
            return
        end
        local ok, ace = pcall(LibStub, "AceAddon-3.0", true)
        if not ok or not ace or not ace.GetAddon then
            return
        end
        local ok2, host = pcall(ace.GetAddon, ace, "Bagnon")
        if not ok2 or not host or not host.ItemSlot then
            return
        end
        local ItemSlot = host.ItemSlot
        local function refresh(slot)
            if not (slot and slot.GetBag and slot.GetID) then
                return
            end
            local bag, id = slot:GetBag(), slot:GetID()
            if not (bag and id) then
                return
            end
            local link
            if slot.GetItem then
                link = slot:GetItem()
            end
            if not link then
                link = GetContainerItemLink(bag, id)
            end
            local cInfo = C_Container.GetContainerItemInfo(bag, id)
            local q = cInfo and cInfo.quality
            apply(slot, link, q, "bags")
        end
        hooksecurefunc(ItemSlot, "Update", refresh)
        if ItemSlot.UpdateBorder then
            hooksecurefunc(ItemSlot, "UpdateBorder", refresh)
        end
        WC_compCache._hostBagItemLevelHookInstalled = true
        if host.frames then
            for _, frame in pairs(host.frames) do
                if frame and frame.UpdateEverything and frame.IsVisible and frame:IsVisible() then
                    pcall(frame.UpdateEverything, frame)
                end
            end
        end
    end

    local function tryEngineHost()
        if WC_compCache._engineBagItemLevelHookInstalled then
            return
        end
        local hostTable = _G.ElvUI
        if type(hostTable) ~= "table" then
            return
        end
        local ok, engine = pcall(unpack, hostTable)
        if not ok or type(engine) ~= "table" or type(engine.GetModule) ~= "function" then
            return
        end
        local ok2, B = pcall(engine.GetModule, engine, "Bags")
        if not ok2 or type(B) ~= "table" or type(B.UpdateSlot) ~= "function" then
            return
        end
        hooksecurefunc(B, "UpdateSlot", function(_self, frame, bagID, slotID)
            if not frame or type(frame.Bags) ~= "table" then
                return
            end
            local bag = frame.Bags[bagID]
            if not bag then
                return
            end
            local slotButton = bag[slotID]
            if not slotButton then
                return
            end
            local link = GetContainerItemLink(bagID, slotID)
            local cInfo = C_Container.GetContainerItemInfo(bagID, slotID)
            local q = cInfo and cInfo.quality
            apply(slotButton, link, q, "bags")
        end)
        WC_compCache._engineBagItemLevelHookInstalled = true
        if B.UpdateAllBagSlots then
            pcall(B.UpdateAllBagSlots, B)
        end
    end

    tryLegacyHost()
    tryEngineHost()
end

local function WC_applyPaperDollItemLevel(button)
    if not button then
        return
    end
    local slotID = button:GetID()
    if not slotID or slotID == 0 then
        return
    end
    local link = GetInventoryItemLink("player", slotID)
    -- v2.37.x audit fix: GetInventoryItemQuality doesn't exist in
    -- 3.3.5a (Cataclysm+ API), so the previous defensive call always
    -- short-circuited to nil. Derive quality from the link instead;
    -- getGearQualityRGB does the same fallback internally but reading
    -- it once here keeps the call uniform with the bags surface.
    local quality = link and select(3, GetItemInfo(link)) or nil
    WC_compCache.applyItemLevelOverlay(button, link, quality, "paperdoll")
end
if _G.PaperDollItemSlotButton_Update then
    hooksecurefunc("PaperDollItemSlotButton_Update", WC_applyPaperDollItemLevel)
end

local function WC_applyInspectItemLevel(button)
    if not button then
        return
    end
    local slotID = button:GetID()
    if not slotID or slotID == 0 then
        return
    end
    local unit = (InspectFrame and InspectFrame.unit) or (UnitExists("target") and "target") or nil
    if not unit then
        return
    end
    local link = GetInventoryItemLink(unit, slotID)
    -- v2.37.x audit fix: same as the paperdoll path above - derive
    -- quality from the link rather than via the Cataclysm-only API.
    local quality = link and select(3, GetItemInfo(link)) or nil
    WC_compCache.applyItemLevelOverlay(button, link, quality, "paperdoll")
end
-- The inspect UI is load-on-demand, so this global is nil at file load.
-- The hub calls this again when Blizzard_InspectUI loads.
function WC_compCache.installInspectItemLevelHook()
    if WC_compCache.inspectItemLevelHooked or not _G.InspectPaperDollItemSlotButton_Update then
        return
    end
    WC_compCache.inspectItemLevelHooked = true
    hooksecurefunc("InspectPaperDollItemSlotButton_Update", WC_applyInspectItemLevel)
end
WC_compCache.installInspectItemLevelHook()

local function WC_applyMerchantItemLevel()
    if not (MerchantFrame and MerchantFrame:IsShown()) then
        return
    end
    local page = MerchantFrame.page or 1
    local isBuyback = MerchantFrame.selectedTab == 2
    local perPage = isBuyback and (BUYBACK_ITEMS_PER_PAGE or 12) or (MERCHANT_ITEMS_PER_PAGE or 10)
    for index = 1, perPage do
        local button = _G["MerchantItem" .. index .. "ItemButton"]
        if button then
            local itemIndex = ((page - 1) * perPage) + index
            local link
            if isBuyback and GetBuybackItemLink then
                -- Buyback has no pages (MerchantFrame.lua buyback loop).
                link = GetBuybackItemLink(index)
            elseif GetMerchantItemLink then
                link = GetMerchantItemLink(itemIndex)
            end
            WC_compCache.applyItemLevelOverlay(button, link, nil, "merchant")
        end
    end
end
if _G.MerchantFrame_Update then
    hooksecurefunc("MerchantFrame_Update", WC_applyMerchantItemLevel)
end

local WC_PAPERDOLL_SLOTS = {
    "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot",
    "WristSlot", "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot",
    "Finger0Slot", "Finger1Slot", "Trinket0Slot", "Trinket1Slot",
    "MainHandSlot", "SecondaryHandSlot", "RangedSlot",
}

-- v2.37.0 polish: per-button repaint helper for the bags surface.
-- Used by NS.RefreshItemLevelOverlay to re-paint every bag slot in the
-- registry without relying on the host bag-UI's broad-repaint method
-- fanning out to every slot's Update. Some host bag UIs redraw the
-- frame layout on a broad-repaint call but do not re-fire the per-slot
-- Update method on slots whose inventory data hasn't changed, so a
-- master-toggle OFF -> ON cycle could leave the FontStrings hidden
-- until the slots got their next live update (which only fires on
-- bag-content change, not on a settings toggle). Direct re-derive
-- sidesteps that.
local function WC_repaintBagButton(button)
    if not button then
        return
    end
    -- Shared resolver: in combined-bags mode every button has the same
    -- parent, so a local parent:GetID() read judged them all as one bag.
    local bag, slot = WC_compCache.bagSlotFromButton(button)
    if bag and slot then
        local link = GetContainerItemLink(bag, slot)
        local cInfo = C_Container.GetContainerItemInfo(bag, slot)
        local q = cInfo and cInfo.quality
        WC_compCache.applyItemLevelOverlay(button, link, q, "bags")
    end
end

-- v2.37.0 (Borrow C): repaint every registered button. Called from the
-- Item Highlighting panel toggles so changes take effect immediately
-- without waiting for the next BAG_UPDATE / paperdoll event. Iterates
-- the weak-keyed registry to clear stale text on disabled surfaces,
-- then re-fires the per-surface walker for whichever surfaces are
-- currently enabled.
NS.RefreshItemLevelOverlay = function()
    -- Re-apply the font first so a slider change rewrites the size on
    -- every existing FontString (including ones that won't be repainted
    -- below because their surface is now disabled - we still want the
    -- next time they show to use the right size).
    for _, fs in pairs(WC_compCache.itemLevelTexts) do
        WC_applyItemLevelFont(fs)
    end
    for button, fs in pairs(WC_compCache.itemLevelTexts) do
        if fs and not WC_itemLevelSurfaceEnabled(button._wc_iLvlSurface or "bags") then
            fs:Hide()
        end
    end
    if WC_itemLevelSurfaceEnabled("bags") then
        -- Walk the standard ContainerFrame stack first (covers slots
        -- visible under the default Blizzard bag UI).
        for i = 1, (NUM_CONTAINER_FRAMES or 13) do
            local frame = _G["ContainerFrame" .. i]
            if frame and frame:IsShown() then
                WC_applyContainerItemLevel(frame)
            end
        end
        -- Then re-paint every registered bag-surface button directly.
        -- This catches host-bag-UI slots that were painted earlier
        -- whose host doesn't re-fire its per-slot Update on a settings
        -- toggle (broad-repaint methods skip slots with unchanged data).
        for button in pairs(WC_compCache.itemLevelTexts) do
            if button._wc_iLvlSurface == "bags" then
                WC_repaintBagButton(button)
            end
        end
    end
    if WC_itemLevelSurfaceEnabled("paperdoll") then
        if CharacterFrame and CharacterFrame:IsShown() then
            for _, slotName in ipairs(WC_PAPERDOLL_SLOTS) do
                local button = _G["Character" .. slotName]
                if button then
                    WC_applyPaperDollItemLevel(button)
                end
            end
        end
    end
    if WC_itemLevelSurfaceEnabled("merchant") then
        WC_applyMerchantItemLevel()
    end
    -- v2.37.0 polish: nudge the host bag-UI frameworks to repaint so a
    -- player who just ticked the "On bags" sub-toggle doesn't have to
    -- open + close their bags to see iLvl text appear on the visible
    -- slots. The host's per-slot Update method (which our hook
    -- intercepts) only fires when the host decides to refresh - usually
    -- on bag-open / inventory-change events. Calling the host's
    -- broad-repaint method here forces a refresh now.
    if WC_itemLevelSurfaceEnabled("bags") then
        local LibStub = _G.LibStub
        if LibStub then
            local ok, ace = pcall(LibStub, "AceAddon-3.0", true)
            if ok and ace and ace.GetAddon then
                local ok2, host = pcall(ace.GetAddon, ace, "Bagnon")
                if ok2 and host and host.frames then
                    for _, frame in pairs(host.frames) do
                        if frame and frame.UpdateEverything and frame.IsVisible and frame:IsVisible() then
                            pcall(frame.UpdateEverything, frame)
                        end
                    end
                end
            end
        end
        local hostTable = _G.ElvUI
        if type(hostTable) == "table" then
            local ok, engine = pcall(unpack, hostTable)
            if ok and type(engine) == "table" and type(engine.GetModule) == "function" then
                local ok2, B = pcall(engine.GetModule, engine, "Bags")
                if ok2 and type(B) == "table" and B.UpdateAllBagSlots then
                    pcall(B.UpdateAllBagSlots, B)
                end
            end
        end
    end
end

-- ===========================================================================
-- Sellability trace: per-item predicate inspector
-- ===========================================================================
-- Walks the same decision chain WC_IsSellable runs, in the same order, and
-- emits a chat-line trace explaining which predicates passed / failed for a
-- given bag slot. Surfaced two ways:
--   * /wc sellinfo [bag] [slot] - defaults to the first non-empty bag slot
--   * Alt+Shift+Right-Click on a bag item - uses the existing
--     ContainerFrameItemButton_OnModifiedClick override path
--
-- v2.71.1 (classifier Stage 2): the trace consumes the decision core.
-- NS.Decision.buildCtx supplies the ONE state snapshot every read below
-- uses (same lazy caches the vendor engine hits), and NS.Decision.sell's
-- verdict + token drive the summary - so the trace can no longer disagree
-- with the vendor about the OUTCOME. The per-step narration (pass/fail
-- lines, tips, n/a explanations) is still derived step by step here,
-- because a single winning token can't explain every non-winning branch;
-- if you change the core's logic, update the matching narration branch so
-- the story matches the verdict.

WC_compCache.qualityNames =
    { [0] = L["Junk"], [1] = L["Common"], [2] = L["Uncommon"], [3] = L["Rare"], [4] = L["Epic"], [5] = L["Legendary"] }

-- v2.64.0: pick a specific "why is this item protected from auto-mark"
-- suffix based on the reason token returned by
-- WC_compCache.itemProtectedFromAutoMarkDelete (v2.60.0 tuple return).
function WC_compCache.describeSellability(bag, slot)
    local DB = NS.DB
    local steps = {}
    local function step(name, passed, detail)
        steps[#steps + 1] = { name = name, passed = passed, detail = detail or "" }
    end

    -- One snapshot for every read below - the SAME adapter the vendor
    -- engine uses, so both surfaces see identical state (junkOnly=false:
    -- the trace previews a full-mode vendor visit).
    local ctx = NS.Decision and NS.Decision.buildCtx(bag, slot, false)
    if not ctx or not ctx.itemID then
        return {
            steps = { { name = "slot", passed = false, detail = L["empty"] } },
            wouldSell = false,
            summary = L["Empty slot"],
        }
    end
    -- The authoritative outcome. Narration below explains it step by step;
    -- the summary at the bottom renders from THIS, never from the story.
    local verdict, verdictToken = NS.Decision.sell(ctx)

    local itemID = ctx.itemID
    if not ctx.count or ctx.count <= 0 then
        step("count", false, L["no items in slot"])
        return { steps = steps, wouldSell = false, summary = L["Empty slot"] }
    end

    local quality, ilvl, equipLoc, sellPrice = ctx.quality, ctx.ilvl, ctx.equipLoc, ctx.sellPrice
    local qName = WC_compCache.qualityNames[quality or -1] or tostring(quality)
    step(
        "item",
        true,
        string.format(
            "%s |cffaaaaaa[id=%d, quality=%s, ilvl=%s, sellPrice=%s]|r",
            ctx.link or ctx.name or "?",
            itemID,
            qName,
            tostring(ilvl or 0),
            tostring(sellPrice or 0)
        )
    )

    if ctx.locked then
        step("locked", false, L["slot is locked (mid-pickup) - sell would skip this tick"])
    end

    local hasSellPrice = sellPrice and sellPrice > 0
    step("hasSellPrice", hasSellPrice, hasSellPrice and L["yes"] or L["no (item cannot be vendored)"])

    -- Delete List wins over every sell signal (v2.37.0). Check it first
    -- so the trace agrees with the bag tint + tooltip annotation, and
    -- with BuildQueue's per-slot dispatch which checks Delete List
    -- before the sell branch. v2.71.3 (classifier Stage 4): the verdict
    -- comes from Decision.deleteEligible - the SAME gate BuildQueue and
    -- auto-delete run - so the trace is finally honest about the v2.50.2
    -- rescue vetoes (previously it said WILL DELETE for any listed item
    -- even when the Keep-signal / equipped rescue would skip it).
    local willDelete = false
    if ctx.onDeleteList and ctx.enableDeletion then
        local delEligible, delToken = NS.Decision.deleteEligible(ctx)
        if delEligible then
            willDelete = true
            step("deleteListVerdict", true, L["WILL DELETE - on Delete List, and deleting is allowed"])
        elseif delToken == "keepList" then
            step("deleteListVerdict", true, L["on Delete List but also on your Keep List - Keep List wins, not deleted"])
        elseif delToken == "sellList" then
            step("deleteListVerdict", true, L["on Delete List but on your Account Sell List - kept to sell, not deleted"])
        elseif delToken == "equipped" then
            step("deleteListVerdict", true, L["on Delete List but currently worn - not deleted"])
        else
            step("deleteListVerdict", true, L["on Delete List but the slot is locked (mid-pickup) - skipped this tick"])
        end
    elseif ctx.onDeleteList then
        step(
            "deleteListVerdict",
            true,
            L["on Delete List but 'Allow items to be deleted' is off - sell rules apply instead"]
        )
    else
        step("deleteListVerdict", true, L["not on Delete List"])
    end

    local isJunk = hasSellPrice and ctx.sellGreys ~= false and (quality == 0 or ctx.hostMarkedJunk == true)
    step(
        "greyAutoSell",
        isJunk,
        (isJunk and ctx.hostMarkedJunk and L["yes (marked as junk in your bags)"])
            or (isJunk and L["yes (grey with sell price)"])
            or (quality == 0 and hasSellPrice and L["no (Sell grey items is off)"])
            or L["n/a"]
    )

    local onCharSell = ctx.whitelistedChar or false
    local onAcctSell = ctx.whitelistedAccount or false
    local whitelistPass = hasSellPrice and (onCharSell or onAcctSell)
    local sellListDetail
    if onCharSell and onAcctSell then
        sellListDetail = L["yes (Character + Account Sell List)"]
    elseif onCharSell then
        sellListDetail = L["yes (Character Sell List)"]
    elseif onAcctSell then
        sellListDetail = L["yes (Account Sell List)"]
    else
        sellListDetail = L["no"]
    end
    step("onSellList", whitelistPass, sellListDetail)

    local qualityPass = false
    local qualityDetail
    local rule = ctx.qualityRule
    if hasSellPrice and quality and quality >= 1 and quality <= 4 and rule then
        if rule.enabled then
            if rule.useEquippedILvl then
                if ctx.downgradeVsEquipped() then
                    qualityPass = true
                    qualityDetail = string.format("%s, ilvl=%s below equipped slot", qName, tostring(ilvl))
                else
                    qualityDetail = string.format("%s, ilvl=%s not below equipped slot", qName, tostring(ilvl))
                end
            else
                local cap = rule.maxILvl or 0
                local hasVisibleILvl = equipLoc and equipLoc ~= "" and ilvl and ilvl > 0
                if cap == 0 then
                    qualityPass = true
                    qualityDetail = string.format("%s rule enabled, no ilvl cap", qName)
                elseif hasVisibleILvl and ilvl <= cap then
                    qualityPass = true
                    qualityDetail = string.format("%s, ilvl=%d <= cap=%d", qName, ilvl, cap)
                elseif not hasVisibleILvl then
                    qualityDetail =
                        string.format("%s, no visible ilvl (reagent/consumable/etc - protected from cap)", qName)
                else
                    qualityDetail = string.format("%s, ilvl=%d > cap=%d", qName, ilvl, cap)
                end
            end
            if qualityPass then
                local bindFilter = rule.bindFilter or "any"
                if bindFilter ~= "any" then
                    local bindType = ctx.bindType() or "any"
                    if bindFilter ~= bindType then
                        qualityPass = false
                        qualityDetail = qualityDetail
                            .. string.format(" - bindFilter=%s but item is %s", bindFilter, bindType)
                    else
                        qualityDetail = qualityDetail .. string.format(", bindFilter=%s match", bindFilter)
                    end
                end
            end
        else
            qualityDetail = string.format("%s rule disabled", qName)
        end
    else
        qualityDetail = L["no rule applies (no sell price OR quality outside Common..Epic)"]
    end
    step("qualityRule", qualityPass, qualityDetail)

    -- Sell Known Recipes: mirror WC_IsSellable's recipePass so the trace
    -- agrees with the merchant cycle.
    --
    -- v2.49.1 fix (Serv report, Pattern: Big Voodoo Robe + Schematic:
    -- Large Seaforium Charge): earlier version emitted a knownRecipeRule
    -- step ONLY when itemIsTome+tomeKind both passed, so a false-return
    -- from itemIsTome looked identical to "not a recipe" in the trace.
    -- Now every gate that fails emits its own step so the reader sees
    -- exactly which check killed the sell decision.
    local recipePass = false
    if hasSellPrice and ctx.sellKnownRecipes then
        local isTome = ctx.isTome()
        if not isTome then
            step("knownRecipeRule", false, L["not a recipe"])
        else
            local kind = ctx.tomeKind()
            if kind ~= "Recipe" then
                step("knownRecipeRule", false, string.format(L["recipe kind is '%s', not 'Recipe' - Sell Known Recipes only applies to profession recipes"], tostring(kind)))
            else
                local qualOn = ctx.sellKnownRecipeQuality
                if not qualOn then
                    step("knownRecipeRule", false, L["known-recipe selling is off for this quality"])
                else
                    local known = ctx.knowsTomeSpell()
                    if not known then
                        step("knownRecipeRule", false, L["recipe not yet learned (kept safe)"])
                    else
                        -- v2.50.4 fix (Serv report, Plans: Ragesteel Breastplate):
                        -- WC_IsSellable's recipePass ALSO gates on the per-quality
                        -- bind-type filter (DB.sellKnownRecipeBindFilter). Trace
                        --
                        -- v2.50.5 (Serv report, Design: Shining Forest Emerald):
                        -- read bindType unconditionally so the fail branch can
                        -- name the actual detected bind, not a hardcoded
                        -- "bind-on-pickup" (which lied when the recipe reads as
                        -- "any" - no bind line on the tooltip - and the filter
                        -- was set to "bop"). Also handles the "no bind line"
                        -- explanation so the user understands why an unbound
                        -- recipe only matches a filter of "any".
                        -- mirror was missing this check, so a soulbound Blue
                        -- recipe with the Blue-recipe filter set to "boe" would
                        -- read WILL SELL in /wc sellinfo but the vendor cycle
                        -- would correctly refuse. Match the gate here.
                        local recipeBindFilter = ctx.recipeBindFilter or "any"
                        local bindType = ctx.bindType() or "any"
                        local passedBindFilter = true
                        if recipeBindFilter ~= "any" and recipeBindFilter ~= bindType then
                            passedBindFilter = false
                        end
                        if not passedBindFilter then
                            if bindType == "any" then
                                step("knownRecipeRule", false, string.format(
                                    L["known recipe but bind filter is '%s' and this recipe has no bind line (reads as 'any' - only matches filter 'any'). Tip: set this quality's bind filter to 'any' in Merchant Settings -> Sell Known Recipes."],
                                    tostring(recipeBindFilter)))
                            else
                                step("knownRecipeRule", false, string.format(
                                    L["known recipe but bind filter is '%s' and this recipe binds as '%s'. Tip: set this quality's bind filter to '%s' or 'any' in Merchant Settings -> Sell Known Recipes."],
                                    tostring(recipeBindFilter), tostring(bindType), tostring(bindType)))
                            end
                        else
                            recipePass = true
                            step("knownRecipeRule", true, L["known recipe - sells via Sell Known Recipes"])
                        end
                    end
                end
            end
        end
    end

    if qualityPass and ctx.isQuestItem then
        qualityPass = false
        step("questSafetyNet", false, L["Kept - quest item (add to Sell List to override)"])
    end

    if qualityPass and ctx.baselineProtected and not ctx.allowedItem then
        qualityPass = false
        step(
            "professionToolSafetyNet",
            false,
            L["Kept - profession tool (add to Sell List or Allow Sell to override)"]
        )
    end

    local equipped = ctx.equipped
    if equipped then
        step("equippedVeto", false, L["Kept - you're wearing this"])
    else
        step("equippedVeto", true, L["not currently equipped"])
    end

    local blacklisted = ctx.blacklisted or false
    if blacklisted then
        -- v2.59.9 (Serv report): name the auto-tag reason so the player
        -- can tell at a glance why the item is on the Keep List (equipped
        -- at some point, part of an Equipment Manager set, iLvl upgrade,
        -- or manually added). Two identical-looking "Kept - on Keep List"
        -- lines across two rings gave no signal about which knob to touch
        -- to release the entry.
        local autoTag = DB and DB.blacklistAuto and DB.blacklistAuto[itemID]
        if autoTag == "equipped" then
            step("keepListVeto", false, L["Kept - on Keep List (auto-tagged: equipped)"])
        elseif autoTag == "set" then
            step("keepListVeto", false, L["Kept - on Keep List (auto-tagged: in a gear set)"])
        elseif autoTag == "upgrade" then
            step("keepListVeto", false, L["Kept - on Keep List (auto-tagged: iLvl upgrade)"])
        elseif autoTag then
            step("keepListVeto", false, L["Kept - on Keep List (auto-tagged)"])
        elseif ctx.hostLocked and not IsInSet(DB and DB.blacklist, itemID) then
            step("keepListVeto", false, L["Kept - locked in your bags"])
        else
            step("keepListVeto", false, L["Kept - on Keep List (manually added)"])
        end
    else
        step("keepListVeto", true, L["not on Keep List"])
    end

    -- Tome / recipe protection narration.
    -- v2.51.2 (Serv report, Pattern: Mooncloth Leggings): fires ONLY on
    -- qualityPass, not whitelistPass - an explicit Sell List entry
    -- overrides the tome veto. Allow Sell (Alt+Right-Click) still exists
    -- as a per-item override.
    -- v2.71.3: the old three-way paired-edit WC-TRAP is retired - the
    -- authoritative predicate lives in Decision.sell's tome veto, the
    -- verdict comes from the core, and the drift sentinel flags this
    -- narration if it falls behind. Keep the branch's shape matching
    -- the core so the story matches the verdict.
    local tomeProtected = false
    if qualityPass
        and not isJunk
        and not whitelistPass
        and not recipePass
        and (ctx.protectAllTomes or ctx.protectUnlearnedTomes)
        and ctx.isTome()
    then
        if ctx.allowedItem then
            step("tomeProtection", true, L["recipe, but you Allow-Sold this one"])
        elseif ctx.protectAllTomes then
            tomeProtected = true
            step("tomeProtection", false, L["Kept - 'Keep them even after you learn them' is on. Tip: add this item to the Sell List, turn that off in Keep Settings, or Alt+Right-Click -> Allow Sell to override for this item."])
        elseif ctx.protectUnlearnedTomes and not ctx.knowsTomeSpell() then
            tomeProtected = true
            step("tomeProtection", false, L["Kept - unlearned recipe"])
        else
            step("tomeProtection", true, L["recipe already known - not protected"])
        end
    end

    -- v2.71.1 (classifier Stage 2): the verdict comes from the decision
    -- core, not from the narration above. Whatever story the steps tell,
    -- the summary states what the vendor engine will actually do - the
    -- two surfaces structurally cannot disagree on the outcome anymore.
    local wouldSell = verdict == "sell"

    -- Drift sentinel: the narration still re-derives the signals for its
    -- per-step explanations, so keep computing its own conclusion and
    -- compare. A mismatch means a narration branch fell behind the core
    -- (the pre-Stage-2 mirror-drift bug class); surface it loudly instead
    -- of letting the story quietly contradict the verdict.
    -- v0.6.0 Forever protections: narrated straight from the core's
    -- reason, so there is no separate re-derivation to drift.
    local foreverProtected = false
    if verdict == "keep" and verdictToken == "appearance" then
        foreverProtected = true
        step("appearanceProtection", false, L["Kept - you haven't collected this appearance yet"])
    elseif verdict == "keep" and verdictToken == "tradeable" then
        foreverProtected = true
        step("tradeableProtection", false, L["Kept - you can still trade or refund this item"])
    end

    local positiveSignal = isJunk or qualityPass or whitelistPass or recipePass
    local vetoed = equipped or blacklisted or tomeProtected or foreverProtected
    local traceWouldSell = positiveSignal and not vetoed and not ctx.locked
    if traceWouldSell ~= wouldSell then
        step("traceDrift", false,
            L["internal: this explanation disagrees with the engine's verdict - the verdict above is what will happen. Please report this item via /wc bugreport."])
    end

    local summary
    if willDelete then
        -- Delete-List path wins over every sell verdict. The cycle queues
        -- this slot as a delete regardless of any sell signal further
        -- down. Steps above still run for educational value (the player
        -- can see what WOULD have happened if the item weren't on the
        -- Delete List), but the summary reflects the actual outcome.
        summary = L["|cffff4444WILL DELETE when you press Delete Next|r"]
    elseif wouldSell then
        summary = L["|cff00ff00WILL SELL at the next vendor visit|r"]
    elseif verdict == "keep" then
        -- v2.71.1: keep-verdicts now read
        -- "protected" instead of "no rule matched" - matches the
        -- tooltip's Keep label for the same item.
        summary = L["|cffff4444won't sell - protected|r"]
    elseif verdictToken == "locked" then
        summary = L["|cffff4444won't sell|r"]
    else
        summary = L["|cffffb84dwon't sell - no rule matched|r"]
    end

    return { steps = steps, wouldSell = wouldSell, willDelete = willDelete, summary = summary, token = verdictToken }
end

-- v2.48.2: player-friendly labels for the internal step-name
-- identifiers. describeSellability's step() calls use terse internal
-- names for code readability + test greppability; the printer swaps
-- them for these labels so /wc sellinfo reads as English rather than
-- as camelCase code. Falls back to the raw name if a step is missing
-- from this table (e.g. "count", "locked", "slot", "item" - internal
-- diagnostics that don't need renaming).
local WC_STEP_LABELS = {
    item                    = L["Item"],
    hasSellPrice            = L["Vendor accepts it"],
    deleteListVerdict       = L["Delete List"],
    greyAutoSell            = L["Grey junk"],
    onSellList              = L["Sell List"],
    qualityRule             = L["Quality rule"],
    knownRecipeRule         = L["Known recipe"],
    questSafetyNet          = L["Quest item safety"],
    appearanceProtection    = L["Uncollected appearance"],
    tradeableProtection     = L["Tradeable loot"],
    professionToolSafetyNet = L["Profession tool safety"],
    equippedVeto            = L["Currently worn"],
    keepListVeto            = L["Keep List"],
    tomeProtection          = L["Recipe protection"],
}

function WC_compCache.printSellabilityTrace(bag, slot)
    if not (bag and slot) then
        for b = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
            local n = GetContainerNumSlots(b) or 0
            for s = 1, n do
                if GetContainerItemID(b, s) then
                    bag, slot = b, s
                    break
                end
            end
            if bag then
                break
            end
        end
    end
    if not (bag and slot) then
        NS.PrintNice(L["|cffff4444No items in any bag to inspect.|r"])
        return
    end

    local r = WC_compCache.describeSellability(bag, slot)
    -- v2.50.5 (Serv request): route the trace to the shared copy-frame
    -- popup instead of the chat window. Rationale: 10+ trace lines
    -- scroll off in busy chat channels before the player can screenshot
    -- or copy them, and the popup's EditBox lets the player select /
    -- Ctrl+C the whole trace for pasting into Discord / bug reports.
    -- Falls back to chat prints if NS.ShowCopyFrame isn't loaded
    -- (impossible under the .toc load order but defensive against a
    -- future refactor that separates BugReport from the addon).
    --
    -- v2.51.0: header block adds character / date / item / VERDICT so
    -- a pasted trace stands alone (previously the reader had to
    -- scroll to the Result: line to know the answer; now the verdict
    -- is at the top in the same colour a merchant border tint would
    -- use). Item link uses GetContainerItemLink so the pasted trace
    -- carries a clickable link when re-pasted into WoW chat.
    local itemLink = GetContainerItemLink(bag, slot)
    local verdictText, verdictColor
    if r.willDelete then
        verdictText = "WILL DELETE"
        verdictColor = "|cffff4444"
    elseif r.wouldSell then
        verdictText = "WILL SELL"
        verdictColor = "|cff00ff00"
    else
        verdictText = "WON'T SELL"
        verdictColor = "|cffffea80"
    end
    local playerName = GetUnitName("player", true) or "?"
    local realm = GetRealmName() or "?"
    local timestamp = date("%Y-%m-%d %H:%M:%S")

    local lines = {}
    lines[#lines + 1] = string.format(L["=== WoWClearance Sell Info ==="])
    lines[#lines + 1] = string.format(L["Version: %s"], (NS.GetVersion and NS.GetVersion()) or "unknown")
    lines[#lines + 1] = string.format(L["Character: %s - %s"], playerName, realm)
    lines[#lines + 1] = string.format(L["Date: %s"], timestamp)
    lines[#lines + 1] = string.format(L["Bag / Slot: %d / %d"], bag, slot)
    lines[#lines + 1] = string.format(L["Item: %s"], itemLink or "(no item)")
    lines[#lines + 1] = ""
    -- v2.51.0 cosmetic: r.summary is wrapped in colour codes and
    -- already starts with the verdict word ("|cff...WILL SELL at ...",
    -- "|cff...won't sell - ..."). Since the header prepends the
    -- verdict word again, strip both the colour codes AND the
    -- verdict-prefix so the line doesn't read
    -- "WON'T SELL - won't sell - <reason>".
    local reason = tostring(r.summary or "")
    reason = reason:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    reason = reason:gsub("^[Ww][Oo][Nn]'[Tt]%s+[Ss][Ee][Ll][Ll]%s*%-?%s*", "")
    reason = reason:gsub("^[Ww][Ii][Ll][Ll]%s+[Ss][Ee][Ll][Ll]%s*[Aa][Tt]?%s*", "")
    reason = reason:gsub("^[Ww][Ii][Ll][Ll]%s+[Dd][Ee][Ll][Ee][Tt][Ee]%s*[Aa][Tt]?%s*", "")
    if reason == "" then
        reason = tostring(r.summary or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    end
    lines[#lines + 1] = string.format("%s%s|r - %s", verdictColor, verdictText, reason)
    lines[#lines + 1] = ""
    lines[#lines + 1] = L["--- Full trace ---"]
    for _, s in ipairs(r.steps) do
        local marker = s.passed and "|cff00ff00+|r" or "|cffff4444-|r"
        local label = WC_STEP_LABELS[s.name] or s.name
        lines[#lines + 1] = string.format("  %s %s - %s", marker, label, s.detail)
    end
    local body = table.concat(lines, "\n")

    if NS.ShowCopyFrame then
        NS.ShowCopyFrame(L["WoWClearance: Sell Info"], body, nil)
    else
        NS.PrintNicef(L["|cffffff00=== Sellability trace: bag %d slot %d ===|r"], bag, slot)
        for _, s in ipairs(r.steps) do
            local marker = s.passed and "|cff00ff00+|r" or "|cffff4444-|r"
            local label = WC_STEP_LABELS[s.name] or s.name
            NS.PrintNicef("  %s %s - %s", marker, label, s.detail)
        end
        NS.PrintNicef(L["Result: %s"], r.summary)
    end
end

-- Look up a bag-slot button's (bag, slot) from a hover. Works for both the
-- default container buttons (parent frame's GetID + button's GetID under
-- the reverse-index naming convention) and host bag-UI slot instances that
-- expose GetBag/GetID methods directly.
function WC_compCache.bagSlotFromButton(button)
    if not button then
        return nil
    end
    -- v0.5.7 (Serv report): the Alt+Right-Click menu named a DIFFERENT item
    -- from the one under the cursor.
    --
    -- Forever's bag buttons carry ContainerFrameItemButtonMixin, which has
    -- GetSlotAndBagID and GetBagID - NOT the 3.3.5a GetBag. So the old first
    -- branch never matched here and resolution fell through to
    -- parent:GetID() + button:GetID(). That is wrong on this client in the
    -- worst way: with the combined-bags frame every slot button shares ONE
    -- parent, so parent:GetID() returns the same value for every item in the
    -- bag and the menu acts on whatever slot index happens to collide.
    --
    -- GetSlotAndBagID returns (slot, bagID) IN THAT ORDER - the reverse of
    -- what this function returns. Getting that backwards swaps the two
    -- silently and still produces a plausible-looking item, which is exactly
    -- how this class of bug hides.
    --
    -- BOTH BAG MODES. Forever exposes a "combinedBags" cvar (Settings ->
    -- Controls, "Use Combined Inventory Bags"), so a player can run one
    -- merged frame or one frame per bag, and can switch at any time -
    -- USE_COMBINED_BAGS_CHANGED fires when they do. This path is correct
    -- either way, because ContainerFrameItemButtonMixin:GetBagID reads the
    -- button's OWN bagID first and only falls back to the parent frame:
    --
    --     function ContainerFrameItemButtonMixin:GetBagID()
    --         return self.bagID or self:GetParent():GetID();
    --
    -- That is precisely why the old parent-only resolution broke in combined
    -- mode and worked in separate mode - the bug was invisible to anyone
    -- testing with bags split apart. Test with combined bags ON.
    -- Bank item buttons (BankPanelItemButtonMixin): the tab is the bag.
    if button.GetBankTabID and button.GetContainerSlotID then
        local ok, bag, slot = pcall(function()
            return button:GetBankTabID(), button:GetContainerSlotID()
        end)
        if ok and bag and slot then
            return bag, slot
        end
    end
    if button.GetSlotAndBagID then
        local ok, slot, bag = pcall(button.GetSlotAndBagID, button)
        if ok and bag and slot then
            return bag, slot
        end
    end
    if button.GetBagID and button.GetID then
        local ok1, b = pcall(button.GetBagID, button)
        local ok2, s = pcall(button.GetID, button)
        if ok1 and ok2 and b and s then
            return b, s
        end
    end
    if button.GetBag and button.GetID then
        local ok1, b = pcall(button.GetBag, button)
        local ok2, s = pcall(button.GetID, button)
        if ok1 and ok2 and b and s then
            return b, s
        end
    end
    local parent = button.GetParent and button:GetParent()
    if parent and parent.GetID then
        local pid = parent:GetID()
        local sid = button.GetID and button:GetID()
        if pid and sid then
            return pid, sid
        end
    end
    return nil
end
