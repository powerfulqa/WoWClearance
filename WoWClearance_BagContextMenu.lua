-- WoWClearance_BagContextMenu - Alt+Right-Click bag-item quick-action popup.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8d of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The bag-item context menu - a custom popup frame (not a Blizzard
-- DropDownMenu) wired through hooksecurefunc on
-- ContainerFrameItemButtonMixin.OnModifiedClick. Alt+Right-Click any bag
-- slot to surface a quick-action list: add to Sell / Keep / Delete
-- list, remove from existing list, allow-sell (tome / recipe
-- protection override), open the relevant settings panel.
--
-- Moved into this file:
--   * WC_CTX_ROWS - row metadata for the popup
--   * WC_BuildCtxFrame - lazily creates the popup frame on first show
--   * WC_ShowItemContextMenu - per-show: sets row labels, OnClick
--     handlers, anchors at cursor, shows the frame
--   * WC_InstallBagContextHookOnce - the
--     ContainerFrameItemButtonMixin.OnModifiedClick hook installer.
--     Exposed as NS.InstallBagContextHookOnce for the ADDON_LOADED
--     branch in WoWClearance_Events.lua.
--
-- Local IsInSet helper carried along (same pattern as Vendor /
-- BagDisplay / Tooltip).
--
-- Cross-file dependencies read inline:
--   * NS.compCache (Core) - itemIsTome, tomeKind, etc.
--   * NS.DB / NS.ADB - captured at function entry
--   * NS.AddItemToList / NS.RemoveItemFromList / NS.FindAddConflict
--     (WoWClearance_Events.lua) - list-mutation helpers driven by row clicks
--   * NS.PrintNice / PrintNicef (WoWClearance_Events.lua)
--   * NS.compCache.openPanelToList - opens the relevant settings panel
--     via _G[<panel-name>] lookup (panels are named frames)
--   * Various WoW globals - GameTooltip, GetCursorPosition,
--     hooksecurefunc, ContainerFrameItemButton_OnModifiedClick, ...

local NS = select(2, ...)
local GetItemInfo = C_Item.GetItemInfo
local GetContainerItemID = C_Container.GetContainerItemID
local WC_compCache = NS.compCache
local L = NS.L

-- IsInSet binding intentionally not imported here; the bag-context popup
-- doesn't consult set membership directly (the list-mutation helpers it
-- delegates to handle their own checks). If a future row handler needs
-- it, add `local IsInSet = NS.IsInSet` here.

-- Row metadata for the popup. Each "list" row toggles between "Add to ..."
-- (white) and "Remove from ..." (orange) based on the item's live list
-- membership at show time. Special rows ("sellNow", "cancel") get plain text
-- and fixed handlers. WC_ShowItemContextMenu sets per-row text + OnClick on
-- every show; the buttons created in WC_BuildCtxFrame are empty placeholders.
local WC_CTX_ROWS = {
    { kind = "list", setName = "whitelist", label = L["Sell List (this character)"] },
    { kind = "list", setName = "accountWhitelist", label = L["Sell List (account-wide)"] },
    { kind = "list", setName = "blacklist", label = L["Keep List"] },
    { kind = "list", setName = "deleteList", label = L["Delete List"] },
    { kind = "sellNow" },
    { kind = "separator" },
    { kind = "sellinfo", label = L["Sell Info"] },
    { kind = "history", label = L["Sold History"] },
    { kind = "separator" },
    { kind = "cancel" },
}

local WC_ctxFrame

local function WC_BuildCtxFrame()
    if WC_ctxFrame then
        return WC_ctxFrame
    end
    local rowCount = #WC_CTX_ROWS
    -- Layout: 8 top pad + 22 title + 6 gap + rows*22 + 8 bottom pad
    local frameHeight = 8 + 22 + 6 + (rowCount * 22) + 8
    local frame = CreateFrame("Frame", "WoWClearanceCtxFrame", UIParent, "BackdropTemplate")
    -- 3.3.5a strata layering: host bag UI replacements commonly run
    -- their bag frames at DIALOG strata with a very high internal
    -- frame level, so a popup at plain DIALOG can render BEHIND the
    -- bag frame and become invisible. Same class of bug already
    -- handled for the colour picker in
    -- WoWClearance_ItemHighlightingPanel.lua; same fix applied here -
    -- bump one strata up to FULLSCREEN_DIALOG + Raise() on every show
    -- so the menu always wins the layering contest regardless of
    -- which host bag UI is loaded.
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetSize(240, frameHeight)
    -- Same look as the panel selector lists (NS.MakeSelector).
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.92)
    frame:EnableMouse(true)
    frame:Hide()

    local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetPoint("TOPRIGHT", -10, -8)
    title:SetJustifyH("LEFT")
    if title.SetWordWrap then
        title:SetWordWrap(false)
    end
    frame.title = title

    frame.buttons = {}
    for i = 1, #WC_CTX_ROWS do
        local btn = CreateFrame("Button", nil, frame)
        btn:SetSize(220, 20)
        btn:SetPoint("TOPLEFT", 10, -(8 + 22 + 6) - (i - 1) * 22)
        btn:SetNormalFontObject("GameFontHighlightSmall")
        btn:SetDisabledFontObject("GameFontDisableSmall")
        local fs = btn:GetFontString()
        if WC_CTX_ROWS[i].kind == "separator" then
            -- Non-interactive divider between menu sections. No hover
            -- highlight, no click, no mouse. Text is static (set here,
            -- not per-show) - a muted dashed line, centred. Its shown /
            -- hidden state is still decided per-show by the packing loop
            -- so a divider never leads or doubles up.
            btn:EnableMouse(false)
            if fs then
                fs:ClearAllPoints()
                fs:SetPoint("LEFT", btn, "LEFT", 4, 0)
                fs:SetPoint("RIGHT", btn, "RIGHT", -4, 0)
                fs:SetJustifyH("CENTER")
            end
            btn:SetText("|cff555555--------------------------------|r")
        else
            if fs then
                fs:ClearAllPoints()
                fs:SetPoint("LEFT", btn, "LEFT", 4, 0)
                fs:SetJustifyH("LEFT")
            end
            -- Hover highlight, same as the panel selector rows.
            btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        end
        -- Text + OnClick are populated per-show by WC_ShowItemContextMenu
        -- so the row labels reflect the item's live list membership
        -- (separators excepted - their text is static, set above).
        frame.buttons[i] = btn
    end

    -- Escape closes the popup. Standard Blizzard pattern: anything in the
    -- UISpecialFrames table is auto-hidden on Escape. Avoids the previous
    -- fullscreen-overlay approach which could intercept bag clicks if it ever
    -- got stuck shown after a disable/enable cycle.
    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "WoWClearanceCtxFrame")
    end
    frame:SetScript("OnHide", function()
        frame.bag = nil
        frame.slot = nil
    end)

    WC_ctxFrame = frame
    return frame
end

local function WC_ShowItemContextMenu(button)
    local DB = NS.DB
    local ADB = NS.ADB
    local frame = WC_BuildCtxFrame()
    -- v0.5.7 (Serv report): the menu named a DIFFERENT item from the one
    -- clicked. This resolved the bag itself as button:GetParent():GetID(),
    -- which is a 3.3.5a assumption - one ContainerFrame per bag. On Forever
    -- the combined-bags frame parents EVERY slot button, so that returns one
    -- value for all of them and the menu acts on the wrong item.
    --
    -- Route through the shared resolver, which prefers the mixin's
    -- GetSlotAndBagID. Do not reintroduce a local parent:GetID() here: this
    -- file had its own copy of the resolution, so fixing the shared helper
    -- alone left this path still broken.
    local bag, slot
    if WC_compCache.bagSlotFromButton then
        bag, slot = WC_compCache.bagSlotFromButton(button)
    end
    if not (bag and slot) then
        return
    end
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return
    end
    frame.bag = bag
    frame.slot = slot

    -- Pull sellPrice alongside the name so the smart-row filter below can
    -- decide which actions are meaningful for this item.
    local name, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
    local itemName = name or ("ItemID:" .. itemID)
    frame.title:SetText("|cff66ccffWoWClearance|r: " .. itemName)

    -- Smart-row filter. When we know the item has no vendor value (sellPrice
    -- 0 or nil from a cache hit) the only useful "Add to X" action is the
    -- Deletion List - the auto-rules already ignore unsellable items so
    -- whitelisting/blacklisting them is no-op, and Sell Now is meaningless
    -- because no vendor will buy it. Existing list memberships still expose
    -- a "Remove from X" row so users can clean up stale entries (e.g. an
    -- item that was added to the whitelist before its sellPrice was known).
    -- The cross-list conflict greying remains unchanged: an unsellable item
    -- already on the Whitelist still shows the Deletion List row as a
    -- greyed "Add to Deletion List" so the user knows they need to remove
    -- it from Whitelist first - same UX rule the panel-side adds enforce,
    -- which is why the tooltip annotation also stays as the canonical
    -- "why is this item being treated this way?" indicator.
    --
    -- The cache-miss path (name == nil) falls back to showing every row;
    -- we don't know yet whether the item is unsellable. Reopen the menu
    -- after a moment to let GetItemInfo populate.
    local cacheKnown = (name ~= nil)
    local noVendorValue = cacheKnown and (not sellPrice or sellPrice == 0)

    -- v2.26.0 / v2.27.0: a protected item shows a single "Allow Sell"
    -- option in place of Sell Now while unmarked. Picking it releases the
    -- safety net - future drops auto-sell via the normal quality rules and
    -- the item becomes available to Process Bags. While unmarked, the Sell
    -- List / Delete List rows are hidden so the user must consciously
    -- acknowledge the protection before adding it to a sell rule. Once
    -- marked, the full menu opens up and the sellNow row shows "Remove from
    -- Allow Sell" as the toggle.
    -- Sell Known Recipes carve-out. A learned profession recipe of an
    -- enabled quality is going to SELL (via recipePass in WC_IsSellable),
    -- so it must NOT be treated as a protected tome here - otherwise the
    -- menu hides the Sell / Keep / Delete rows behind an "Allow Sell" gate
    -- for an item that already sells. Mirrors the recipeSellable carve-out
    -- in WC_IsSellable and the tooltip.
    local recipeSellable = false
    if DB.sellKnownRecipes
        and sellPrice
        and sellPrice > 0
        and WC_compCache.itemIsTome
        and WC_compCache.itemIsTome(bag, slot, itemID)
        and WC_compCache.tomeKind
        and WC_compCache.tomeKind(itemID) == "Recipe"
        and WC_compCache.playerKnowsTomeSpell
        and WC_compCache.playerKnowsTomeSpell(bag, slot, itemID)
    then
        local _, _, rq = GetItemInfo(itemID)
        if rq and DB.sellKnownRecipeQualities and DB.sellKnownRecipeQualities[rq] then
            -- Bind filter, as in Decision.sell's recipePass.
            local bf = DB.sellKnownRecipeBindFilter and DB.sellKnownRecipeBindFilter[rq] or "any"
            recipeSellable = bf == "any" or bf == WC_compCache.getBindType(bag, slot)
        end
    end
    -- Tome protection: per-itemID storage
    -- (ADB.allowedItems[itemID]), so the Allow Sell / Remove from
    -- Allow List flow shares those branches. The unlearned-only mode
    -- gates on playerKnowsTomeSpell; protectAllTomes is unconditional.
    -- Skipped for recipeSellable items (they sell, so no Allow Sell gate).
    local hasTome = false
    if not recipeSellable
        and (DB.protectAllTomes or DB.protectUnlearnedTomes)
        and WC_compCache.itemIsTome
        and WC_compCache.itemIsTome(bag, slot, itemID)
    then
        if DB.protectAllTomes then
            hasTome = true
        elseif DB.protectUnlearnedTomes
            and WC_compCache.playerKnowsTomeSpell
            and not WC_compCache.playerKnowsTomeSpell(bag, slot, itemID)
        then
            hasTome = true
        end
    end
    -- v0.6.0 Forever protections. Same Allow Sell flow: ADB.allowedItems
    -- also releases these vetoes in Decision.sell, so without this the menu
    -- had no way to override them for one item.
    local hasForeverProtection = false
    if not hasTome then
        if DB.protectUncollectedAppearances
            and WC_compCache.isUncollectedAppearance
            and WC_compCache.isUncollectedAppearance(C_Container.GetContainerItemLink(bag, slot))
        then
            hasForeverProtection = true
        elseif DB.protectTradeableLoot
            and WC_compCache.isTradeableOrRefundable
            and WC_compCache.isTradeableOrRefundable(bag, slot)
        then
            hasForeverProtection = true
        end
    end
    local hasProtection = hasTome or hasForeverProtection
    -- Allowance is a manual itemID mark (ADB.allowedItems).
    local itemAllowed = hasProtection and ADB.allowedItems and ADB.allowedItems[itemID] == true
    local procProtected = hasProtection and not itemAllowed

    local visibleSlot = 0
    -- Tracks whether a real (non-separator) row has been shown since the
    -- last shown separator (or the top of the menu). Drives the divider
    -- orphan guard below.
    local shownSinceSep = false
    for i, row in ipairs(WC_CTX_ROWS) do
        local btn = frame.buttons[i]
        local rowHidden = false
        if row.kind == "list" and procProtected and row.setName ~= "blacklist" then
            -- v2.26.0: hide the Sell / Delete list rows while protected. User
            -- must click "Allow Sell" first to unlock those on a protected
            -- item. v2.57.2 (Serv): the Keep List (blacklist) row is EXEMPT -
            -- adding to Keep is always a safe, protective action, so it's
            -- always offered (you should never be unable to protect an item).
            rowHidden = true
        elseif row.kind == "list" then
            local t = NS.GetListTable(row.setName)
            local onList = t and t[itemID] == true
            if onList then
                -- Orange "Remove from ..." when the item is already on this
                -- list. Clicking removes it. Always shown - this is how
                -- users clean up stale entries, including for unsellable
                -- items that may have been added before their price was
                -- known.
                btn:SetText(L["|cffff8000Remove from "] .. row.label .. "|r")
                btn:SetScript("OnClick", function()
                    NS.RemoveItemFromList(row.setName, itemID, row.label)
                    frame:Hide()
                end)
                btn:Enable()
            elseif noVendorValue and (row.setName == "whitelist" or row.setName == "accountWhitelist") then
                -- Hide only the SELL-list Add rows for items the auto-rules
                -- can't sell anyway (no vendor value). The Keep List
                -- (blacklist) and Delete List rows STAY visible: you must be
                -- able to PROTECT a no-value item (e.g. a quest-reward token
                -- with sellPrice 0) from auto-delete, and deleting it is the
                -- other useful action. v2.57.2 fix (Serv): previously the Keep
                -- row was hidden here too, so a no-value quest reward could
                -- ONLY be Delete-Listed - there was no way to protect it.
                rowHidden = true
            else
                -- v2.26.0: dropped the "Add to" prefix on add rows -
                -- the label alone is self-evident and orange
                -- "Remove from" rows provide the contrast.
                local conflictName = NS.FindAddConflict(itemID, row.setName)
                if conflictName then
                    btn:SetText(row.label)
                    btn:SetScript("OnClick", function() end)
                    btn:Disable()
                else
                    btn:SetText(row.label)
                    btn:SetScript("OnClick", function()
                        NS.AddItemToList(row.setName, itemID, row.label)
                        frame:Hide()
                    end)
                    btn:Enable()
                end
            end
        elseif row.kind == "sellNow" then
            -- v2.26.0 / v2.27.0: "Allow Sell" toggle for a protected item.
            -- Marks the itemID in ADB.allowedItems, so future drops of the
            -- same item auto-sell via the normal quality rules.
            local hasManualMark = itemAllowed
            if hasManualMark then
                btn:SetText(L["|cffff8000Remove from Allow Sell|r"])
                btn:SetScript("OnClick", function()
                    if ADB.allowedItems then
                        ADB.allowedItems[itemID] = nil
                    end
                    frame:Hide()
                    NS.PrintNicef(L["Removed %s from Allow Sell."], itemName)
                    -- Cascade: removing Allow Sell expresses the user intent
                    -- "re-protect this item from auto-selling".
                    -- If the item is also on a Sell List, the protection
                    -- only narrows back to the auto-rule sweep (per the
                    -- v2.20.1 "explicit user intent overrides safety net"
                    -- design) - the item would STILL vendor via the
                    -- whitelist path. Clearing the Sell List entries here
                    -- matches the menu-driven workflow most users follow
                    -- (Allow Sell + Add to Sell + later Remove from Allow
                    -- List = full undo). Keep List and Delete List are NOT
                    -- cascaded: those are different intents (Keep = never
                    -- sell, Delete = destroy) that the protection toggle
                    -- doesn't logically conflict with. NS.RemoveItemFromList
                    -- no-ops when the item isn't on the list, prints its
                    -- own "Removed X from <list>" line when it does, and
                    -- handles panel refresh + border repaint.
                    NS.RemoveItemFromList("whitelist", itemID, L["Character Sell List"])
                    NS.RemoveItemFromList("accountWhitelist", itemID, L["Account Sell List"])
                    -- Border repaint covers the case where neither sell
                    -- list contained the item (so RemoveItemFromList no-
                    -- op'd and didn't trigger its own repaint). Same
                    -- rationale as before the cascade: the Allow List
                    -- mutation can flip a slot's would-sell verdict.
                    if NS.RefreshSellBorders then
                        NS.RefreshSellBorders()
                    end
                end)
                btn:Enable()
            elseif hasProtection then
                btn:SetText(L["Allow Sell"])
                btn:SetScript("OnClick", function()
                    ADB.allowedItems = ADB.allowedItems or {}
                    ADB.allowedItems[itemID] = true
                    NS.PrintNicef(
                        L["Marked %s as allowed. Future drops will auto-sell."],
                        itemName
                    )
                    frame:Hide()
                    -- Same reasoning as the remove-from-allow path: this
                    -- mutation can flip a slot from "protected" to "will
                    -- sell" so the border should track immediately.
                    if NS.RefreshSellBorders then
                        NS.RefreshSellBorders()
                    end
                end)
                btn:Enable()
            else
                rowHidden = true
            end
        elseif row.kind == "sellinfo" then
            -- Same per-item decision trace as `/wc sellinfo`, for the
            -- clicked slot. Always shown (works even on protected items)
            -- so the player can always inspect why an item will or won't
            -- sell. Capture bag/slot from the outer locals: frame.bag /
            -- frame.slot are cleared by the OnHide handler, so reading
            -- them after frame:Hide() would be nil.
            btn:SetText(L["Sell Info"])
            btn:SetScript("OnClick", function()
                frame:Hide()
                if WC_compCache.printSellabilityTrace then
                    WC_compCache.printSellabilityTrace(bag, slot)
                end
            end)
            btn:Enable()
        elseif row.kind == "history" then
            -- Fast access to the session sell/delete history. Always shown
            -- (item-independent) - a quick way to answer "what did WC just
            -- sell and why?" without opening the panel or typing a command.
            btn:SetText(L["Sold History"])
            btn:SetScript("OnClick", function()
                frame:Hide()
                if NS.ShowSessionHistory then
                    NS.ShowSessionHistory()
                end
            end)
            btn:Enable()
        elseif row.kind == "cancel" then
            btn:SetText(L["Cancel"])
            btn:SetScript("OnClick", function()
                frame:Hide()
            end)
            btn:Enable()
        elseif row.kind == "separator" then
            -- Divider text + non-interactivity are fixed at build time.
            -- Show it only when a real row precedes it in this section, so
            -- it never renders as the first row or doubles up when the
            -- rows above are all hidden. (No trailing-divider guard is
            -- needed: Sell Info / Sold History / Cancel always follow a
            -- divider and are always shown.)
            rowHidden = not shownSinceSep
        end

        if rowHidden then
            btn:Hide()
        else
            -- Pack visible rows contiguously starting at slot 0; the frame
            -- height below resizes to match the count so the trailing
            -- padding is consistent regardless of how many rows are shown.
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", 10, -(8 + 22 + 6) - visibleSlot * 22)
            btn:Show()
            visibleSlot = visibleSlot + 1
            if row.kind == "separator" then
                shownSinceSep = false
            else
                shownSinceSep = true
            end
        end
    end

    -- Resize the frame to match the visible row count. Same layout formula
    -- the build path uses; visibleSlot is the count of rows we just laid
    -- out (it ended at last_index + 1).
    frame:SetHeight(8 + 22 + 6 + (visibleSlot * 22) + 8)

    -- Position at the cursor. WoW's GetCursorPosition returns screen
    -- pixels; divide by UIParent's effective scale to get UIParent-local
    -- coords. Clamp the menu's TOPLEFT so the frame's RIGHT / BOTTOM
    -- edges stay inside the UIParent bounds - without this, Alt+Right-
    -- Clicking a bag slot near the right edge (common with host bag UI
    -- adapters that pin bags to the right side) lets the menu clip off
    -- the screen.
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    local cx, cy = x / scale, y / scale
    local fw, fh = frame:GetWidth() or 240, frame:GetHeight() or 200
    local maxX = UIParent:GetWidth() - fw - 4
    local minY = fh + 4
    if cx > maxX then
        cx = maxX
    end
    if cx < 0 then
        cx = 0
    end
    if cy < minY then
        cy = minY
    end
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx, cy)
    frame:Show()
    -- Belt-and-braces: even at FULLSCREEN_DIALOG strata, a host bag UI
    -- replacement might have raised one of its own frames to the top
    -- of the same strata. Calling Raise() on every show guarantees the
    -- menu sits at the highest frame level within FULLSCREEN_DIALOG,
    -- so it lands above whatever the host bag UI is doing.
    if frame.Raise then
        frame:Raise()
    end
end

local WC_bagContextHookInstalled = false

-- WC-TRAP: never ASSIGN into a Blizzard mixin table (or replace a Blizzard
-- global) here; use hooksecurefunc. MEASURED in game on Forever: the old
-- installer replaced ContainerFrameItemButtonMixin.OnModifiedClick and
-- BankPanelItemButtonMixin.OnClick so it could suppress the default action.
-- That made the mixin entry addon-owned (tainted). Bag buttons are built on
-- demand by Mixin(), which copies every key with pairs(); reading the
-- tainted entry taints the rest of the copy, so the button's OnClick and
-- GetBagID end up tainted too. A plain right-click then reaches
-- C_Container.UseContainerItem from tainted code and the client blocks it:
-- ADDON_ACTION_FORBIDDEN "WoWClearance tried to call the protected function"
-- from ContainerFrameItemButton_OnClick. Nothing needs suppressing anyway:
-- on a modified click both default handlers only run the modifier actions
-- (chat link, dress-up, split stack); they never use, sell or move the item.
-- The 3.3.5a globals (ContainerFrameItemButton_OnModifiedClick,
-- BankFrameItemButtonGeneric_OnClick) do not exist on this client and are
-- no longer wrapped. Locked by Test 39 in tests/test_perf_guardrails.lua.
--
-- Known limit: mixin methods are copied onto each button when it is
-- created, so buttons built BEFORE this runs keep the unhooked method. The
-- installer runs at PLAYER_LOGIN and bag buttons are built when a bag first
-- opens, so in practice it lands first; reopening the bag is the workaround.
local function WC_InstallBagContextHookOnce()
    if WC_bagContextHookInstalled then
        return
    end
    WC_bagContextHookInstalled = true

    -- Alt+Right-Click opens the WC menu; Alt+Shift+Right-Click prints the
    -- sellability trace for the slot.
    local function WC_afterClick(self, button)
        if button ~= "RightButton" or not IsAltKeyDown() or IsControlKeyDown() then
            return
        end
        if not IsShiftKeyDown() then
            -- A host bag UI whose own Alt+Right-Click menu carries a row for
            -- ours: let that one open, or both menus fight over the click.
            if WC_compCache.hostOwnsItemMenu and WC_compCache.hostOwnsItemMenu(self) then
                return
            end
            WC_ShowItemContextMenu(self)
        elseif WC_compCache.bagSlotFromButton and WC_compCache.printSellabilityTrace then
            local bag, slot = WC_compCache.bagSlotFromButton(self)
            if bag and slot then
                WC_compCache.printSellabilityTrace(bag, slot)
            end
        end
    end

    local mixin = _G.ContainerFrameItemButtonMixin
    if type(mixin) == "table" and type(mixin.OnModifiedClick) == "function" then
        hooksecurefunc(mixin, "OnModifiedClick", WC_afterClick)
    end
    -- Bank items (BankPanelItemButtonMixin): their OnModifiedClick gets no
    -- mouse button, so hook OnClick, which has it.
    local bankMixin = _G.BankPanelItemButtonMixin
    if type(bankMixin) == "table" and type(bankMixin.OnClick) == "function" then
        hooksecurefunc(bankMixin, "OnClick", WC_afterClick)
    end
end

NS.InstallBagContextHookOnce = WC_InstallBagContextHookOnce
NS.ShowItemContextMenu = WC_ShowItemContextMenu
