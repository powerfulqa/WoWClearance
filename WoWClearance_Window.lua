-- WoWClearance_Window.lua
--
-- v0.5.3: standalone config window.
--
-- WHY THIS EXISTS. WoWClearance's panels are Settings canvases, and
-- Blizzard's SettingsPanel is registered with area = "center" and no
-- allowOtherPanels (Blizzard_Settings_Shared/Blizzard_Registration.lua:3-10).
-- UIParentPanelManager.lua:288-292 then reads:
--
--     if ( frameArea == "center" ) then
--         securecall("CloseWindows");
--         if ( not GetUIPanelAttribute(frame, "allowOtherPanels") ) then
--             securecall("CloseAllBags");
--         end
--
-- so opening ANY Settings page closes the player's bags, and keybinds are
-- suppressed while a system window is up. For a bag addon that is the
-- worst possible pairing: you cannot see the bags while configuring the
-- thing that manages them.
--
-- This window is a plain UIParent child. It is not a UIPanel, so neither
-- CloseAllBags nor the keybind suppression applies to it.
--
-- WC-TRAP: do NOT add this frame to UISpecialFrames. That table is not
-- "Escape closes this"; CloseWindows calls CloseSpecialWindows
-- (UIParentPanelManager.lua:1164 -> :1102) which Hide()s every shown
-- member unconditionally, so joining it would re-introduce the exact
-- coupling that closing the Settings panel used to cause. Dismissal is
-- the title-bar close button. This has been fixed three times in this
-- port already; do not make it four.
--
-- DUAL HOSTING. The Settings registration is kept, so WoWClearance still
-- appears under Esc -> Options for discoverability. A panel frame can only
-- have one parent, so panels are REPARENTED on demand between the Settings
-- container and this window's content area. NS.OptionsHost() returns
-- whichever host is currently active, which keeps NS.GetPanelWidth and the
-- reactive width registry pointing at the right frame without any panel
-- file needing to know this window exists.

local NS = select(2, ...)
local WC_compCache = NS.compCache

local WC_window
local WC_activePanelName
local WC_sidebarButtons = {}
local L = NS.L

-- True while combat forbids moving or hiding this window: the Process Bags
-- cast button is secure, and on Forever hiding or dragging an ANCESTOR of a
-- shown secure button is refused in combat (ADDON_ACTION_BLOCKED). Measured
-- on Forever 2026-10-06; the InCombatLockdown guard was player-checked
-- 2026-10-09 (wow-forever-api skill, taint reference). Other panels hide the
-- button, so the window behaves normally whenever Process Bags is not shown.
local function WC_secureLocked()
    local btn = _G.WoWClearanceProcessCastBtn
    return InCombatLockdown() and btn ~= nil and btn:IsVisible()
end

-- Sidebar order: the one copy. Configuration panels first, then the stats
-- dashboard, then the curated lists
-- (Keep Settings under Keep List, mirroring Delete List + Delete Settings),
-- then the tools. Panels live here, not as Settings sub-categories, because
-- a panel rendered inside SettingsPanel closes the player's bags.
local WC_PANEL_ORDER = {
    "WoWClearanceOptionsMain",
    "WoWClearanceOptionsMerchant",
    "WoWClearanceOptionsCharacter",
    "WoWClearanceOptionsStats",
    -- Optional Loot module (WoWClearance_Loot); skipped when it is off.
    "WoWClearanceOptionsLoot",
    "WoWClearanceOptionsGuild",
    "WoWClearanceOptionsWhitelist",
    "WoWClearanceOptionsAccountWhitelist",
    "WoWClearanceOptionsBlacklist",
    "WoWClearanceOptionsBlacklistSettings",
    "WoWClearanceOptionsDeletion",
    "WoWClearanceOptionsDeletionSettings",
    "WoWClearanceOptionsProcessBags",
    "WoWClearanceOptionsProfiles",
    "WoWClearanceOptionsSettingsProfiles",
    "WoWClearanceOptionsImportExport",
    "WoWClearanceOptionsHelp",
}


-- ===========================================================================
-- v0.5.5: Blizzard frame skin
-- ===========================================================================
-- Every WC pop-out used a hand-rolled DialogBox backdrop, which looked
-- nothing like this client's own frames. Blizzard's ButtonFrameTemplate
-- (Blizzard_SharedXML/Mainline/SharedUIPanelTemplates.xml:711) is the
-- standard retail addon window: gold border, portrait, title bar, close
-- button, and a content Inset anchored TOPLEFT(4,-60) BOTTOMRIGHT(-6,26).
-- It is what BankFrameTemplate and ContainerFrameTemplate build on, which
-- is why those all match each other.
--
-- Everything here is capability-checked rather than assumed. The template
-- is Mainline-only art; on a client without it CreateFrame would have
-- thrown at the call site, so callers pass the template name and this
-- helper only decorates what actually arrived.
--
-- Returns the frame that content should parent to: the Inset when the
-- template provided one, otherwise the frame itself. Callers MUST use the
-- return value rather than assuming, or content lands under the title bar.
function NS.SkinWindow(frame, titleText, iconPath)
    if not frame then
        return nil
    end
    -- Title resolution. SetTitle FIRST: it is the supported API and both
    -- templates have it.
    --
    -- CORRECTED v0.5.6. An earlier version of this comment claimed
    -- DefaultPanelTemplate had no SetTitle, "because DefaultPanelMixin
    -- defines none". The second half is true and the conclusion was wrong:
    --
    --     Blizzard_SharedXML/PortraitFrame.lua:12  function TitledPanelMixin:SetTitle
    --     Blizzard_SharedXML/PortraitFrame.lua:30  DefaultPanelMixin  = CreateFromMixins(TitledPanelMixin)
    --     Blizzard_SharedXML/PortraitFrame.lua:32  PortraitFrameMixin = CreateFromMixins(TitledPanelMixin)
    --
    -- CreateFromMixins copies the methods in, so both templates carry
    -- SetTitle, SetTitleColor, SetTitleFormatted and GetTitleText. The
    -- mistake came from reading a mixin listing that reports what a mixin
    -- DECLARES as though it reported what a frame HAS. Caught by the
    -- BarWarden-Forever port; verified here against the source above.
    --
    -- The TitleContainer.TitleText fallback below is NOT redundant. A
    -- template can carry a title strip without carrying the mixin -
    -- BasicFrameTemplateWithInset is the case that matters - and falling
    -- straight through to a hand-made FontString there puts the text at
    -- roughly y=-14, straddling the strip, which is the exact
    -- "title cut in half by the header" fault this helper exists to avoid.
    if titleText then
        if frame.SetTitle then
            frame:SetTitle(titleText)
        else
            local tc = frame.TitleContainer
            if tc and tc.TitleText then
                tc.TitleText:SetText(titleText)
            elseif frame.TitleText then
                frame.TitleText:SetText(titleText)
            end
        end
    end
    if frame.SetPortraitToAsset then
        frame:SetPortraitToAsset(iconPath or "Interface\\Icons\\INV_Misc_Coin_01")
    end
    return frame.Inset or frame
end

local SIDEBAR_W = 168

-- Returns the content frame panels should parent to while this window is
-- the active host, or nil when it is not. NS.OptionsHost consults this.
function NS.StandaloneHost()
    if WC_window and WC_window:IsShown() and WC_window.content then
        return WC_window.content
    end
    return nil
end

-- Move a panel between hosts. Panels build lazily on first OnShow, so a
-- panel that has never been opened simply gets its parent set and builds
-- against the new host when shown - no special-casing needed.
local function WC_attachPanel(frame, host)
    if not (frame and host) then
        return
    end
    frame:SetParent(host)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    frame:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)
end

local function WC_hideAllPanels()
    for _, name in ipairs(WC_PANEL_ORDER) do
        local f = _G[name]
        if f then
            f:Hide()
        end
    end
end

local function WC_refreshSidebarSelection()
    for name, btn in pairs(WC_sidebarButtons) do
        if name == WC_activePanelName then
            btn.sel:Show()
            btn.label:SetTextColor(1, 0.82, 0)
        else
            btn.sel:Hide()
            btn.label:SetTextColor(0.85, 0.85, 0.85)
        end
    end
end

-- Show one panel inside the window. Public so the minimap, slash commands
-- and the Help panel's jump buttons can all route here.
function NS.ShowStandalonePanel(frameName)
    if not WC_window then
        return
    end
    -- Showing Process Bags reparents the panel that holds the secure cast
    -- button, which combat refuses even while the button is hidden.
    if WC_secureLocked() then
        NS.PrintNice(L["Leave combat to close this while Process Bags is open."])
        return
    end
    if InCombatLockdown() and frameName == "WoWClearanceOptionsProcessBags" then
        NS.PrintNice(L["Leave combat to open Process Bags."])
        return
    end
    local frame = frameName and _G[frameName]
    if not frame then
        frameName = "WoWClearanceOptionsMain"
        frame = _G[frameName]
    end
    if not frame then
        return
    end
    WC_hideAllPanels()
    WC_activePanelName = frameName
    WC_attachPanel(frame, WC_window.content)
    -- OnShow drives initPanel, which builds on first open and refreshes on
    -- every subsequent one. Showing is therefore all that is required.
    frame:Show()
    WC_refreshSidebarSelection()
end

local function WC_buildSidebar(win)
    local host = win.host or win
    local scroll = CreateFrame("ScrollFrame", "WoWClearanceWindowSidebarScroll", host, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", host, "TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 6, 6)
    scroll:SetWidth(SIDEBAR_W)

    local list = CreateFrame("Frame", nil, scroll)
    list:SetSize(SIDEBAR_W, 10)
    scroll:SetScrollChild(list)

    local y = 0
    for _, name in ipairs(WC_PANEL_ORDER) do
        local frame = _G[name]
        if frame then
            local btn = CreateFrame("Button", nil, list)
            btn:SetSize(SIDEBAR_W - 6, 22)
            btn:SetPoint("TOPLEFT", list, "TOPLEFT", 0, y)

            local sel = btn:CreateTexture(nil, "BACKGROUND")
            sel:SetAllPoints(btn)
            sel:SetColorTexture(1, 0.82, 0, 0.16)
            sel:Hide()
            btn.sel = sel

            local hl = btn:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(btn)
            hl:SetColorTexture(1, 1, 1, 0.08)

            local label = btn:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
            label:SetPoint("LEFT", btn, "LEFT", 8, 0)
            label:SetPoint("RIGHT", btn, "RIGHT", -4, 0)
            label:SetJustifyH("LEFT")
            label:SetText(frame.name or name)
            btn.label = label

            btn:SetScript("OnClick", function()
                NS.ShowStandalonePanel(name)
            end)

            WC_sidebarButtons[name] = btn
            y = y - 23
        end
    end
    list:SetHeight(math.max(10, -y))
    win.sidebar = scroll
end

local function WC_createWindow()
    if WC_window then
        return WC_window
    end

    -- BackdropTemplate is REQUIRED on this client: a plain frame has no
    -- SetBackdrop method, and the call is a nil-call that aborts the rest
    -- of this function. Measured during the port.
    local win = CreateFrame("Frame", "WoWClearanceWindow", UIParent, "ButtonFrameTemplate")
    win:SetSize(880, 560)
    win:SetPoint("CENTER")
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:SetMovable(true)
    win:SetResizable(true)
    if win.SetResizeBounds then
        win:SetResizeBounds(700, 420)
    end
    win:SetClampedToScreen(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function(self)
        if not WC_secureLocked() then
            self:StartMoving()
        end
    end)
    win:SetScript("OnDragStop", function(self)
        if not WC_secureLocked() then
            self:StopMovingOrSizing()
        end
    end)
    win:Hide()

    -- Title, portrait and close button all come from the template. The
    -- hand-rolled backdrop, FontString title and UIPanelCloseButton that
    -- used to live here are gone deliberately - duplicating them would
    -- double-draw over the template's own chrome.
    local host = NS.SkinWindow(win, "WoWClearance", "Interface\\Icons\\INV_Misc_Coin_01")
    win.host = host

    -- The template's CloseButton calls HideUIPanel by default, which is
    -- wrong here: this is not a UIPanel, and the panels need parking.
    if win.CloseButton then
        win.CloseButton:SetScript("OnClick", function()
            NS.HideStandaloneWindow()
        end)
    end

    local content = CreateFrame("Frame", "WoWClearanceWindowContent", host)
    content:SetPoint("TOPLEFT", host, "TOPLEFT", SIDEBAR_W + 12, -6)
    content:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -6, 6)
    win.content = content

    -- Resizing changes the content width, which every panel reads through
    -- NS.GetPanelWidth / the reactive width registry. Repaint on size
    -- change so widgets reflow instead of freezing at build-time width.
    win:SetScript("OnSizeChanged", function()
        if WC_compCache.refreshLayouts then
            WC_compCache.refreshLayouts()
        end
    end)

    -- Shared kit grip; OnMouseDown is replaced to keep the combat lock
    -- (the kit's own handler always starts sizing).
    local grip = NS.Kit.ResizeGrip(win, function()
        if not WC_secureLocked() then
            win:StopMovingOrSizing()
        end
    end)
    grip:SetScript("OnMouseDown", function()
        if not WC_secureLocked() then
            win:StartSizing("BOTTOMRIGHT", true)
        end
    end)

    WC_buildSidebar(win)
    WC_window = win
    return win
end

-- Park every panel hidden on UIParent. Also run once at login: the panel
-- files create their frames shown and parented to the Settings container,
-- so opening the game's Settings before /wc fired OnShow on all of them
-- and built every panel in one frame (and sent the Guild panel's request).
function NS.ParkPanels()
    for _, name in ipairs(WC_PANEL_ORDER) do
        local f = _G[name]
        if f then
            f:Hide()
            f:SetParent(UIParent)
        end
    end
end

function NS.HideStandaloneWindow()
    if not WC_window then
        return
    end
    if WC_secureLocked() then
        NS.PrintNice(L["Leave combat to close this while Process Bags is open."])
        return
    end
    WC_hideAllPanels()
    WC_window:Hide()
    -- v0.5.4: panels are parked hidden on UIParent rather than handed back
    -- to the Settings container. Since the sub-categories were removed,
    -- this window is their only host - the Settings entry is a launcher
    -- (see WC_buildLauncher below), not a page they render into.
    NS.ParkPanels()
    WC_activePanelName = nil
end

function NS.ShowStandaloneWindow(frameName)
    -- A frame that is not one of the window's panels (Quickstart is its own
    -- floating window) is just shown. Attaching it would reparent it into
    -- the window, where it stays stuck: nothing parks it back on UIParent.
    if frameName and _G[frameName] then
        local isPanel = false
        for _, name in ipairs(WC_PANEL_ORDER) do
            isPanel = isPanel or name == frameName
        end
        if not isPanel then
            _G[frameName]:Show()
            return
        end
    end
    local win = WC_createWindow()
    if not win then
        return
    end
    win:Show()
    win:Raise()
    NS.ShowStandalonePanel(frameName or WC_activePanelName or "WoWClearanceOptionsMain")
end


-- ===========================================================================
-- v0.5.4: the Settings entry is a LAUNCHER, not the config itself
-- ===========================================================================
-- WoWClearance used to register seventeen Settings sub-categories. Every one
-- of them inherited the system-window problems: opening any of them called
-- CloseAllBags() and suppressed keybinds. Registering a single launcher page
-- keeps WoWClearance discoverable where players look for addon settings,
-- while the actual configuration lives in the standalone window where the
-- bags stay open.
--
-- WC-TRAP: do not "restore" the sub-category registrations. A panel rendered
-- inside SettingsPanel is a panel that closes the player's bags, which is the
-- whole reason this window exists.
local function WC_buildLauncher()
    local panel = CreateFrame("Frame", "WoWClearanceOptionsLauncher", UIParent)
    panel.name = "WoWClearance"

    local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", 16, -16)
    heading:SetText("|cff66ccffWoWClearance|r")

    local byline = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    byline:SetPoint("TOPLEFT", 16, -40)
    byline:SetText("|cff888888by " .. (NS.ADDON_AUTHOR or "") .. "  \194\183  " .. (NS.ADDON_URL or "") .. "|r")

    local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", 16, -70)
    desc:SetWidth(560)
    desc:SetJustifyH("LEFT")
    if desc.SetWordWrap then
        desc:SetWordWrap(true)
    end
    desc:SetText(
        NS.L["WoWClearance settings open in their own window, so you can see your bags while you change them.\n\n"]
            .. NS.L["Opening settings from this game menu closes your bags - that is how the game's own settings window works, not something this addon can change."]
    )

    local btn = CreateFrame("Button", "WoWClearanceOptionsLauncherButton", panel, "UIPanelButtonTemplate")
    btn:SetSize(220, 26)
    btn:SetPoint("TOPLEFT", 16, -140)
    btn:SetText(NS.L["Open WoWClearance"])
    btn:SetScript("OnClick", function()
        -- Close the Settings window first. Leaving it open would keep the
        -- bags shut, which defeats the point of the button.
        if SettingsPanel and SettingsPanel.Hide and SettingsPanel:IsShown() then
            HideUIPanel(SettingsPanel)
        end
        NS.ShowStandaloneWindow("WoWClearanceOptionsMain")
    end)

    local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 16, -176)
    hint:SetText(NS.L["You can also use /wc or the minimap button."])

    -- v0.5.5 (Serv request): the slash-command reference lives HERE, not in
    -- the pop-out window. It is read-once reference material, so it belongs
    -- on the page you visit to find out how the addon works rather than
    -- taking permanent space in the window you actually work in.
    --
    -- Built lazily on first show: NS.BuildSlashCommandList is defined in
    -- WoWClearance_MainPanel.lua, which loads AFTER this file, so calling it
    -- at file scope here would hit a nil. OnShow also means a player who
    -- never opens this page never pays for building it.
    panel:SetScript("OnShow", function(self)
        if self.slashBuilt then
            return
        end
        if not NS.BuildSlashCommandList then
            return
        end
        self.slashBuilt = true

        local scroll = CreateFrame("ScrollFrame", "WoWClearanceLauncherScroll", self, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -16)
        scroll:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -32, 16)

        local content = CreateFrame("Frame", "WoWClearanceLauncherScrollChild", scroll)
        content:SetSize(560, 10)
        scroll:SetScrollChild(content)

        -- The list anchors its first row below whatever is passed in, so it
        -- needs a zero-height widget at the top of the scroll child.
        local top = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        top:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        top:SetText("")

        local last = NS.BuildSlashCommandList(content, top)
        if last and NS.FitScrollContent then
            NS.FitScrollContent(content, last)
        end
    end)

    NS.RegisterOptionsRoot(panel, "WoWClearance")
end

WC_buildLauncher()
