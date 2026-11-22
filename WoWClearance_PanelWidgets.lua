-- WoWClearance_PanelWidgets - panel widget primitives.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-ix-c of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- Seven widget primitives bundled in one file: MakeHeader, MakeLabel,
-- StyleInputBox, AddCheckbox, AddSlider, ColorTextByQuality, and the
-- help-icon button (MakeHelpIcon, exposed as NS.AddHelpIcon). Every
-- Interface Options panel in the addon builds widgets through these
-- helpers. All seven are exposed on NS so split panel files can call
-- them (the bare locals would only be visible inside this file).
--
-- Moved into this file:
--   * MakeHeader         (GameFontNormalLarge at TOPLEFT 16, y)
--   * StyleInputBox      (InputBoxTemplate EditBox chrome treatment;
--                         pulls glyph layers to BACKGROUND so the text
--                         renders on top)
--   * MakeLabel          (GameFontHighlight wrapped label; registers
--                         width with WC_compCache.registerWidth so
--                         the wrap re-flows on Interface Options
--                         container resize)
--   * AddCheckbox        (InterfaceOptionsCheckButtonTemplate +
--                         text + click handler)
--   * ColorTextByQuality (ITEM_QUALITY_COLORS-aware text formatter)
--   * MakeHelpIcon       ([?] help-icon button; exposed as NS.AddHelpIcon)
--   * AddSlider          (OptionsSliderTemplate + label + value
--                         display + commit on OnValueChanged)
--
-- Cross-file dependencies satisfied by NS:
--   * NS.compCache (Core)  - WC_compCache.registerWidth (MakeLabel)
--   * NS.GetPanelWidth     - MakeLabel's initial-width snapshot;
--                            8e-ix-b prep exposure
--
-- The list-row factories (WC_compCache.makeListRowFactory +
-- buildList*Row helpers) + CreateListUI + WC_AddScanByQualityRow were
-- extracted to WoWClearance_ListWidget.lua in Stage 8e-ix-d.

local NS = select(2, ...)
local WC_compCache = NS.compCache
local L = NS.L

local function MakeHeader(parent, text, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetText(text)
    return fs
end
NS.MakeHeader = MakeHeader

-- StyleInputBox: applied to every InputBoxTemplate EditBox we use. v2.18.0
-- moved this up from its old position below CreateListUI so the new
-- WC_compCache.buildListHeaderRow / buildListSearchAndSortRow helpers
-- (which call it during their pure-layout build) can see it as an
-- upvalue. Forward-reference discipline: Lua file-scope
-- locals are only visible to code AFTER their declaration; the v2.18.0
-- split inadvertently placed the helpers BEFORE StyleInputBox, which
-- worked at parse time but exploded at first OnShow with
-- "attempt to call global 'StyleInputBox' (a nil value)".
local function StyleInputBox(editBox)
    if not editBox then
        return
    end
    if editBox.SetTextInsets then
        editBox:SetTextInsets(6, 6, 0, 0)
    end

    local fs = editBox.GetFontString and editBox:GetFontString()
    if fs and fs.SetDrawLayer then
        fs:SetDrawLayer("OVERLAY")
    end
    if fs and fs.SetAlpha then
        fs:SetAlpha(1)
    end

    local n = editBox.GetName and editBox:GetName()
    if n then
        local left = _G[n .. "Left"]
        local mid = _G[n .. "Middle"]
        local right = _G[n .. "Right"]
        if left and left.SetDrawLayer then
            left:SetDrawLayer("BACKGROUND")
        end
        if mid and mid.SetDrawLayer then
            mid:SetDrawLayer("BACKGROUND")
        end
        if right and right.SetDrawLayer then
            right:SetDrawLayer("BACKGROUND")
        end
    end
    editBox:SetFrameLevel((editBox:GetParent() and editBox:GetParent():GetFrameLevel() or editBox:GetFrameLevel()) + 2)

    if editBox.GetText and editBox.SetText then
        local t = editBox:GetText() or ""
        editBox:SetText(t)
        if editBox.SetCursorPosition then
            editBox:SetCursorPosition(0)
        end
    end
end
NS.StyleInputBox = StyleInputBox

local function MakeLabel(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetWidth(NS.GetPanelWidth() - x)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    -- v2.11.0: register the label's width with the reactive layout
    -- registry so it re-wraps when the panel container resizes.
    WC_compCache.registerWidth(fs, x)
    if fs.SetWordWrap then
        fs:SetWordWrap(true)
    end
    fs:SetText(text)
    return fs
end
NS.MakeLabel = MakeLabel

-- Thousands-separator for large counts (WoW 3.3.5a has no BreakUpLargeNumbers).
-- Floors to an integer and inserts commas every three digits, e.g.
-- 2200199 -> "2,200,199". Gold values keep using CopperToColoredText; this is
-- for plain counts (items sold/deleted/processed, sharer counts).
local function CommaNumber(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local neg = s:sub(1, 1) == "-"
    if neg then
        s = s:sub(2)
    end
    while true do
        local rebuilt = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
        if rebuilt == s then
            break
        end
        s = rebuilt
    end
    return (neg and "-" or "") .. s
end
NS.CommaNumber = CommaNumber

-- Shared search debounce (v2.68.1). Typing in a search box must not fire a
-- full list rebuild per keystroke - on the Loot Log's Account scope that is
-- a GetItemInfo sweep + sort over thousands of items, nine times for the
-- word "bloodpike". Same design as the ListWidget original (v2.28.0): a
-- hidden per-widget OnUpdate frame arms a 250 ms countdown, every keystroke
-- resets it, and one fn() fires when typing goes idle. The editBox's
-- OnTextChanged is OWNED by this helper; callers that need the live text
-- immediately (e.g. stashing win.search) pass it via onText, which runs
-- per keystroke BEFORE the debounce arms.
function NS.MakeSearchDebounce(editBox, fn, onText)
    local debounce = CreateFrame("Frame")
    debounce:Hide()
    debounce.elapsed = 0
    debounce:SetScript("OnUpdate", function(self, dt)
        self.elapsed = self.elapsed + dt
        if self.elapsed >= 0.25 then
            self:Hide()
            fn()
        end
    end)
    editBox:SetScript("OnTextChanged", function(self)
        if onText then
            onText(self:GetText() or "")
        end
        debounce.elapsed = 0
        debounce:Show()
    end)
    return debounce
end

-- Shared two-column stat row. row.left is the label, row.right the value
-- FontString whose left edge sits at valueX. Full panel width (reactive via
-- WC_compCache.setPanelWidth) so the row frame doubles as a hover target.
function NS.MakeStatRow(parent, anchor, yOff, valueX)
    local row = CreateFrame("Frame", nil, parent)
    row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff or -2)
    row:SetHeight(14)
    WC_compCache.setPanelWidth(row, 16)
    row.left = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.left:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.left:SetJustifyH("LEFT")
    row.right = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.right:SetPoint("LEFT", row, "LEFT", valueX or 200, 0)
    row.right:SetJustifyH("LEFT")
    return row
end

-- Home-made selector: a button that opens a small list of options.
--
-- WC-TRAP: do NOT go back to UIDropDownMenu_* or the Menu / MenuUtil API.
-- On Forever, UIDropDownMenu writes shared globals (UIDROPDOWNMENU_MENU_LEVEL)
-- and is a measured cause of ADDON_ACTION_BLOCKED on the action bars in
-- combat, blamed on the addon; opening a Menu-system menu from an addon
-- crashed the client (ldebug.c assertion). Both measured on Forever in
-- September 2026 (wow-forever-api skill, taint-and-protected-frames
-- reference). The list sits at TOOLTIP strata and is raised on open,
-- because the Loot Log and Sold History windows run at TOOLTIP themselves
-- (v2.66.1) and a lower list opens behind its own window.
--
-- getOptions() returns { { text = "...", checked = bool, ... }, ... } and is
-- read on every open; onPick(option) runs after the list closes.
local WC_selectorList
local function WC_getSelectorList()
    if WC_selectorList then
        return WC_selectorList
    end
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    f:SetFrameStrata("TOOLTIP")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.92)
    f.rows = {}
    f:Hide()
    -- Close on a click anywhere outside the list and its button.
    f:SetScript("OnUpdate", function(self)
        if IsMouseButtonDown() and not self:IsMouseOver() and not (self.owner and self.owner:IsMouseOver()) then
            self:Hide()
        end
    end)
    f:SetScript("OnHide", function(self)
        self.owner = nil
    end)
    WC_selectorList = f
    return f
end

function NS.MakeSelector(parent, width, getOptions, onPick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    local arrow = b:CreateTexture(nil, "OVERLAY")
    arrow:SetAtlas("common-dropdown-a-button")
    arrow:SetSize(14, 14)
    arrow:SetPoint("RIGHT", b, "RIGHT", -4, 0)
    b:SetScript("OnClick", function(self)
        local list = WC_getSelectorList()
        if list:IsShown() and list.owner == self then
            list:Hide()
            return
        end
        list.owner = self
        local opts = getOptions()
        for i, opt in ipairs(opts) do
            local row = list.rows[i]
            if not row then
                row = CreateFrame("Button", nil, list)
                row:SetHeight(20)
                row:SetPoint("TOPLEFT", list, "TOPLEFT", 8, -6 - (i - 1) * 20)
                row:SetPoint("RIGHT", list, "RIGHT", -8, 0)
                row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                row.check = row:CreateTexture(nil, "ARTWORK")
                row.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
                row.check:SetSize(14, 14)
                row.check:SetPoint("LEFT", row, "LEFT", 0, 0)
                row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
                row.text:SetPoint("LEFT", row, "LEFT", 16, 0)
                row.text:SetJustifyH("LEFT")
                list.rows[i] = row
            end
            row.text:SetText(opt.text)
            row.check:SetShown(opt.checked == true)
            row:SetScript("OnClick", function()
                list:Hide()
                PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
                onPick(opt)
            end)
            row:Show()
        end
        for i = #opts + 1, #list.rows do
            list.rows[i]:Hide()
        end
        list:SetSize(math.max(width, 120), #opts * 20 + 12)
        list:ClearAllPoints()
        list:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
        list:Show()
        list:Raise()
    end)
    b:HookScript("OnHide", function(self)
        if WC_selectorList and WC_selectorList.owner == self then
            WC_selectorList:Hide()
        end
    end)
    return b
end

-- v2.68.0 (Serv report): keep GameTooltip visible over a TOOLTIP-strata
-- window. Call immediately AFTER GameTooltip:Show().
--
-- WC-TRAP: GameTooltip parents under its owner. When the owner is a row
-- inside a window that is itself at TOOLTIP strata (Loot Log, Sold
-- History), the tooltip inherits a frame level BELOW that window and
-- renders behind it - the tooltip is up, the player just cannot read
-- half of it. GameTooltip:Raise() does NOT fix this: a toplevel parent
-- still wins. Only an absolute frame level does.
--
-- 250 is the same value WoWClearance_QuickstartPanel.lua has used since
-- v2.38.1 for the identical reason (Quickstart is TOOLTIP strata at
-- level 100). Keep the two in step; this helper is the shared home for
-- the trick so a third TOOLTIP-strata window does not have to
-- rediscover it.
-- Tooltip for a row inside a pop-out window (Loot Log, Sold History): set
-- OUTSIDE the window, level with the hovered row. ANCHOR_RIGHT on the row
-- put it at the row's right edge, which is inside the window, so it covered
-- the window's border and close button.
function NS.AnchorTooltipBesideWindow(row, win)
    GameTooltip:SetOwner(row, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    local dy = (row:GetTop() or 0) - (win:GetTop() or 0)
    GameTooltip:SetPoint("TOPLEFT", win, "TOPRIGHT", 4, dy)
end

function NS.RaiseTooltipAboveWindows()
    if not GameTooltip then
        return
    end
    GameTooltip:SetFrameStrata("TOOLTIP")
    GameTooltip:SetFrameLevel(250)
end

-- v2.76.0 (Serv report): bring a StaticPopup above the Interface Options
-- frame. Call on the dialog StaticPopup_Show returns.
--
-- WC-TRAP: StaticPopup1 lives at a LOWER strata than the Interface Options
-- container, so a confirmation raised from any options panel renders
-- BEHIND the panel that raised it. The popup is modal in intent but not in
-- effect, so the player is left with an action that silently refuses to
-- complete and no visible reason - Serv hit this on all four list "Clear
-- All" buttons and could not reach the Yes button at all.
--
-- Every StaticPopup_Show call made from a panel MUST pass its dialog
-- through here. QuickstartPanel carried this fix inline from v2.38.0; this
-- is that same trick, shared, so the next popup added to a panel does not
-- have to rediscover it. Guarded because StaticPopup_Show returns nil when
-- all popup slots are occupied.
function NS.RaisePopupAboveOptions(dialog)
    if not dialog then
        return
    end
    if dialog.SetFrameStrata then
        dialog:SetFrameStrata("TOOLTIP")
    end
    if dialog.Raise then
        dialog:Raise()
    end
    return dialog
end

-- Shared "Show: [rarity]" filter for the Loot Log + Sold History windows.
-- Quality names come from the client's ITEM_QUALITYn_DESC globals.
-- onSelect receives the chosen quality number, or nil for "All rarities";
-- the caller stores it and re-renders. `name` is kept for the callers but
-- unused: the selector needs no global name.
function NS.MakeRarityDropdown(win, name, onSelect)
    local opts = {
        { text = L["All rarities"], q = nil },
        { text = _G["ITEM_QUALITY0_DESC"] or "Poor", q = 0 },
        { text = _G["ITEM_QUALITY1_DESC"] or "Common", q = 1 },
        { text = _G["ITEM_QUALITY2_DESC"] or "Uncommon", q = 2 },
        { text = _G["ITEM_QUALITY3_DESC"] or "Rare", q = 3 },
        { text = _G["ITEM_QUALITY4_DESC"] or "Epic", q = 4 },
    }
    local dd
    dd = NS.MakeSelector(win, 110, function()
        for _, opt in ipairs(opts) do
            opt.checked = (dd.selected == opt.q)
        end
        return opts
    end, function(opt)
        dd.selected = opt.q
        dd:SetText(opt.text)
        if onSelect then
            onSelect(opt.q)
        end
    end)
    dd:SetText(L["All rarities"])
    return dd
end

-- v0.7.0: time-range dropdown for the Loot Log (History view) and Sold
-- History. onSelect gets the range in seconds, or nil for all time. Built
-- on NS.MakeSelector like the rarity dropdown above, so its list opens
-- above the TOOLTIP-strata windows too.
function NS.MakeTimeDropdown(win, onSelect)
    local opts = {
        { text = L["All time"], secs = nil },
        { text = L["Last hour"], secs = 3600 },
        { text = L["Last 24 hours"], secs = 86400 },
        { text = L["Last 7 days"], secs = 7 * 86400 },
        { text = L["Last 30 days"], secs = 30 * 86400 },
    }
    local dd
    dd = NS.MakeSelector(win, 110, function()
        for _, opt in ipairs(opts) do
            opt.checked = (dd.selected == opt.secs)
        end
        return opts
    end, function(opt)
        dd.selected = opt.secs
        dd:SetText(opt.text)
        if onSelect then
            onSelect(opt.secs)
        end
    end)
    dd:SetText(L["All time"])
    return dd
end

-- MakeHelpIcon: small clickable [?] anchored next to a setting widget.
-- Clicking deep-links into the Help panel via NS.OpenHelpEntry(entryId),
-- which opens Help, expands the section containing the target entry,
-- scrolls the entry to the top of the viewport, and briefly flashes it.
-- See WoWClearance_HelpPanel.lua for NS.OpenHelpEntry.
--
-- Args:
--   parent       - frame to parent the icon to
--   anchorWidget - widget to anchor next to (the setting's label or row)
--   anchorPoint  - anchor point ON the icon (typically "LEFT")
--   relPoint     - anchor point on the target widget (typically "RIGHT")
--   xOff, yOff   - pixel offset (defaults 4, 0 if nil)
--   entryId      - stable id of the Help entry to deep-link to (e.g. "gate-keep-list-blocks")
--
-- Returns the Button frame so the caller can chain further anchors.
local function MakeHelpIcon(parent, anchorWidget, anchorPoint, relPoint, xOff, yOff, entryId)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(20, 20)
    btn:SetPoint(anchorPoint, anchorWidget, relPoint, xOff or 4, yOff or 0)
    btn:RegisterForClicks("LeftButtonUp")

    local fs = btn:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetAllPoints(btn)
    fs:SetJustifyH("CENTER")
    fs:SetJustifyV("MIDDLE")
    fs:SetText("|cffffff00[?]|r")
    btn:SetFontString(fs)

    -- Hover highlight + GameTooltip prompt.
    btn:SetScript("OnEnter", function(self)
        fs:SetText("|cffffffaa[?]|r")
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(L["Click for help"], 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function()
        fs:SetText("|cffffff00[?]|r")
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)

    btn:SetScript("OnClick", function()
        if NS.OpenHelpEntry then
            NS.OpenHelpEntry(entryId)
        end
        if PlaySound then
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end
    end)

    return btn
end
NS.AddHelpIcon = MakeHelpIcon

local function AddCheckbox(parent, name, anchor, labelText, getter, setter, yOff)
    local cb = CreateFrame("CheckButton", name, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff or -6)
    cb:SetChecked(getter())

    local t = _G[name .. "Text"]
    if t then
        t:SetText(labelText)
        -- v2.59.8 (Serv report): reactive width for the checkbox label.
        -- Pre-fix a bare SetWidth(420) overflowed the ~360px default
        -- Interface Options panel width and froze at build time.
        -- SetWordWrap on so long labels wrap instead of clipping.
        -- v2.66.1 iter (Serv report): inset raised from 42 to 60 so the
        -- [?] help icon anchored to text:RIGHT + 6 stays inside the
        -- scrollbar zone. Inset 42 left only ~26 px of margin past the
        -- text frame's right edge, so the [?] icon (20 px wide) landed
        -- underneath the scrollbar and clipped to "[" on both the
        -- Merchant panel. 60 matches the Keep Settings
        -- panel's manual-CB inset, which the user confirmed as the
        -- correct alignment.
        WC_compCache.setPanelWidth(t, 60)
        t:SetJustifyH("LEFT")
        if t.SetWordWrap then
            t:SetWordWrap(true)
        end
    end

    cb:SetScript("OnClick", function()
        setter(cb:GetChecked() and true or false)
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    return cb
end
NS.AddCheckbox = AddCheckbox

local function ColorTextByQuality(quality, text)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    local hex = (c and c.hex) or "|cffffffff"
    return hex .. text .. "|r"
end
NS.ColorTextByQuality = ColorTextByQuality

local function AddSlider(parent, name, anchor, labelText, minVal, maxVal, step, getter, setter, yOff, fmt)
    fmt = fmt or "%.3fs"
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff or -16)
    s:SetMinMaxValues(minVal, maxVal)
    if s.SetValueStep then
        s:SetValueStep(step)
    end
    if s.SetObeyStepOnDrag then
        s:SetObeyStepOnDrag(true)
    end
    s:SetValue(getter())

    local low = _G[name .. "Low"]
    local high = _G[name .. "High"]
    local text = _G[name .. "Text"]

    if low then
        low:SetText(string.format(fmt, minVal))
    end
    if high then
        high:SetText(string.format(fmt, maxVal))
    end

    local function RefreshText(v)
        if text then
            text:SetText(labelText .. ": " .. string.format(fmt, v))
        end
    end
    RefreshText(getter())

    s:SetScript("OnValueChanged", function(self, value)
        value = tonumber(value) or minVal
        if step and step > 0 then
            value = math.floor((value / step) + 0.5) * step
        end
        if value < minVal then
            value = minVal
        end
        if value > maxVal then
            value = maxVal
        end
        setter(value)
        RefreshText(value)
    end)

    return s
end
NS.AddSlider = AddSlider
