-- WoWClearance_Daylight.lua
--
-- DaylightUI integration. Loads last. Does nothing (and touches nothing of
-- DaylightUI) when DaylightUI is missing or is another major version.
--   * The look: DaylightUI's style on WoWClearance's own windows, panels and
--     item menu, unless the player turned it off
--     (WoWClearanceDB.daylightLook == false; the checkbox is on the Main panel).
--   * Always (not tied to the look): a WoWClearance section in DaylightUI's
--     options, /dui wc, a data text for its data bars, and the Loot Log /
--     Sold History / main windows placeable with /dui unlock.
-- The bag integration (rings, groups, item menu row, locks, one seller)
-- lives in WoWClearance_BagDisplay.lua beside the other bag UI adapters.
-- Uses the public API in DaylightUI/API.md.

local NS = select(2, ...)
local DUI = _G.DaylightUI
local API = DUI and DUI.API
if not API or API.major ~= 1 then return end
-- The off switch is read in the skin callback below, not here: saved
-- variables are not loaded yet when this file runs, so a check here always
-- saw nil and skinned anyway.

local me = API.For("WoWClearance")
local L = NS.L

-- ---------------------------------------------------------------------------
-- Plugin section in DaylightUI's options. Its rows read and write
-- WoWClearance's own settings (get/set), so there is one copy of each.
-- ---------------------------------------------------------------------------
local function dbGet(field)
    return function()
        local DB = NS.DB
        return DB ~= nil and DB[field] ~= false
    end
end
local function dbSet(field, after)
    return function(v)
        local DB = NS.DB
        if DB then
            DB[field] = v and true or false
            if after then
                after()
            end
        end
    end
end
local function syncHighlight()
    if NS.SyncItemHighlighting then
        NS.SyncItemHighlighting()
    end
end
local function openPanel(name)
    return function()
        if NS.OpenOptionsPanel then
            NS.OpenOptionsPanel(name)
        end
    end
end

if DUI.RegisterPlugin and DUI.RegisterModule then
    local ok = pcall(DUI.RegisterPlugin, "WoWClearance", {
        needs = { 1, 3 },
        color = "66ccff",
        short = "Clearance",
        blurb = L["Sells your junk at vendors and keeps what matters."],
    })
    if ok then
        pcall(DUI.RegisterModule, DUI, "WoWClearance", {
            plugin = "WoWClearance",
            label = "WoWClearance",
            defaults = {},
            options = {
                pages = {
                    {
                        id = "main",
                        label = "WoWClearance",
                        desc = L["The main switches. Everything else is in WoWClearance's own settings."],
                        groups = {
                            {
                                label = L["Selling"],
                                items = {
                                    { type = "toggle", label = L["Sell items at vendors"], get = dbGet("sellAtVendor"), set = dbSet("sellAtVendor"),
                                      desc = L["Sells your junk and rule matches when you talk to a vendor. DaylightUI's own junk sale waits while this and Sell grey items are both on."] },
                                    { type = "toggle", label = L["Sell grey items"], get = dbGet("sellGreys"), set = dbSet("sellGreys", syncHighlight) },
                                    { type = "toggle", label = L["Repair gear while selling"], get = dbGet("repairGear"), set = dbSet("repairGear") },
                                },
                            },
                            {
                                label = L["Bags"],
                                items = {
                                    { type = "toggle", label = L["Item highlighting"], get = dbGet("itemHighlighting"), set = dbSet("itemHighlighting", syncHighlight) },
                                    { type = "toggle", label = L["Show borders"], get = dbGet("sellBorderEnabled"), set = dbSet("sellBorderEnabled", syncHighlight),
                                      disabled = function() local DB = NS.DB return DB ~= nil and DB.itemHighlighting == false end },
                                    { type = "toggle", label = L["Use DaylightUI look"], reload = true,
                                      get = function() return not (WoWClearanceDB and WoWClearanceDB.daylightLook == false) end,
                                      set = function(v) if WoWClearanceDB then WoWClearanceDB.daylightLook = v and true or false end end },
                                },
                            },
                            {
                                label = L["Open"],
                                items = {
                                    { type = "button", label = L["WoWClearance settings"], func = openPanel("WoWClearanceOptionsMain") },
                                    { type = "button", label = L["Loot Log"], func = function() if NS.ToggleLootWindow then NS.ToggleLootWindow() end end },
                                    { type = "button", label = L["Sold History"], func = function() if NS.ShowSessionHistory then NS.ShowSessionHistory() end end },
                                },
                            },
                        },
                    },
                },
            },
        })
    end
end

-- /dui wc <anything /wc takes>
me.RegisterCommand("wc", function(rest)
    local handler = SlashCmdList and SlashCmdList.WOWCLEARANCE
    if handler then
        handler(rest or "")
    end
end, L["WoWClearance (same as /wc)"])

-- ---------------------------------------------------------------------------
-- Data text: this session's vendor gold, for DaylightUI's data bars (any
-- broker display reads it). Needs a broker library another addon loaded;
-- without one there is simply no data text.
-- ---------------------------------------------------------------------------
local function money(c)
    c = math.floor(c or 0)
    local g, sv = math.floor(c / 10000), math.floor(c / 100) % 100
    if g > 0 then
        return string.format("%dg %ds", g, sv)
    end
    return string.format("%ds %dc", sv, c % 100)
end

local function makeDataText()
    local LDB = _G.LibStub and _G.LibStub("LibDataBroker-1.1", true)
    if not LDB or (LDB.GetDataObjectByName and LDB:GetDataObjectByName("WoWClearance Session")) then
        return
    end
    local obj = LDB:NewDataObject("WoWClearance Session", {
        type = "data source",
        label = L["Vendored"],
        text = "0s 0c",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
        OnClick = function(_, button)
            if button == "RightButton" then
                if NS.ToggleLootWindow then
                    NS.ToggleLootWindow()
                end
            elseif NS.OpenOptionsPanel then
                NS.OpenOptionsPanel("WoWClearanceOptionsMain")
            end
        end,
        OnTooltipShow = function(tip)
            local ses = NS.session or {}
            tip:AddLine("|cff66ccffWoWClearance|r " .. L["this session"])
            tip:AddDoubleLine(L["Vendored"], money(ses.copper), 1, 1, 1, 1, 1, 1)
            tip:AddDoubleLine(L["Items sold"], tostring(ses.sold or 0), 1, 1, 1, 1, 1, 1)
            tip:AddDoubleLine(L["Items deleted"], tostring(ses.deleted or 0), 1, 1, 1, 1, 1, 1)
            tip:AddDoubleLine(L["Gold looted"], money(ses.lootCopper), 1, 1, 1, 1, 1, 1)
            tip:AddLine(L["Click: settings. Right-click: Loot Log."], 0.6, 0.6, 0.6)
        end,
    })
    -- A broker display redraws on each change; only write when it moved.
    local last
    C_Timer.NewTicker(2, function()
        local c = NS.session and NS.session.copper or 0
        if c ~= last then
            last = c
            obj.text = money(c)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Movers: WoWClearance's own windows get a handle in /dui unlock. They are
-- made on first open, so each is registered the first time it exists.
-- ---------------------------------------------------------------------------
local MOVERS = {
    { name = "WoWClearanceLootWindow", key = "lootLog", label = L["WoWClearance Loot Log"] },
    { name = "WoWClearanceHistoryWindow", key = "soldHistory", label = L["WoWClearance Sold History"] },
    { name = "WoWClearanceWindow", key = "settings", label = L["WoWClearance settings"] },
}
local moved = {}
local function registerMovers()
    for _, m in ipairs(MOVERS) do
        local f = not moved[m.key] and _G[m.name]
        if f then
            moved[m.key] = true
            local p, rel, rp, x, y = f:GetPoint(1)
            me.RegisterMover(f, m.key, m.label, { p or "CENTER", rel or UIParent, rp or "CENTER", x or 0, y or 0 })
        end
    end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
    makeDataText()
    -- The windows open from several places; catch each one as it appears.
    for _, fn in ipairs({ "ToggleLootWindow", "ShowSessionHistory", "ShowStandaloneWindow", "ShowStandalonePanel" }) do
        local orig = NS[fn]
        if type(orig) == "function" then
            NS[fn] = function(...)
                local a, b, c = orig(...)
                registerMovers()
                return a, b, c
            end
        end
    end
end)

-- Own windows with their own chrome, own popups, and panels (hosted either in
-- the standalone window or in the Settings page). All are made lazily, so they
-- are looked up by global name each tick until they exist.
local WINDOWS = {
    "WoWClearanceWindow", "WoWClearanceHistoryWindow", "WoWClearanceLootWindow",
    "WoWClearanceOptionsQuickstart", "WoWClearanceCopy",
}
local POPUPS = { "WoWClearanceCtxFrame" }
local PANELS = {
    "WoWClearanceOptionsMain", "WoWClearanceOptionsMerchant", "WoWClearanceOptionsCharacter",
    "WoWClearanceOptionsStats", "WoWClearanceOptionsGuild", "WoWClearanceOptionsServer",
    "WoWClearanceOptionsWhitelist", "WoWClearanceOptionsAccountWhitelist",
    "WoWClearanceOptionsBlacklist", "WoWClearanceOptionsBlacklistSettings",
    "WoWClearanceOptionsDeletion", "WoWClearanceOptionsDeletionSettings",
    "WoWClearanceOptionsProcessBags", "WoWClearanceOptionsProfiles",
    "WoWClearanceOptionsSettingsProfiles", "WoWClearanceOptionsImportExport",
    "WoWClearanceOptionsHelp",
}

local Kit
local seen = {} -- frame -> true once its one-time skin ran

local function rgb(key)
    local c = API.Colors()[key]
    if c then return c[1], c[2], c[3] end
    return 1, 1, 1
end

-- Plain frames that draw their own backdrop (list backgrounds, drop-down
-- popups): strip them. Popups sit on a higher strata, so they get the opaque
-- window shell; everything else the darker inset.
local function backdrops(f, strata, depth)
    for _, c in ipairs({ f:GetChildren() }) do
        if c:GetObjectType() == "Frame" and c.GetBackdrop and c:GetBackdrop() then
            if c:GetFrameStrata() ~= strata then Kit.Panel(c) else Kit.Inset(c) end
        end
        if depth < 4 then backdrops(c, strata, depth + 1) end
    end
end

-- A checkbox dressed as a switch: its label sits flush against the switch.
-- Move each label a few pixels right, once, keeping its own anchor.
local spaced = {}
local function spaceLabels(f, depth)
    for _, c in ipairs({ f:GetChildren() }) do
        if c:GetObjectType() == "CheckButton" and not spaced[c] then
            local name = c:GetName()
            local t = c.Text or c.text or (name and _G[name .. "Text"])
            if t and t.GetNumPoints and t:GetNumPoints() == 1 then
                local p, rel, rp, x, y = t:GetPoint(1)
                t:SetPoint(p, rel, rp, (x or 0) + 6, y or 0)
                spaced[c] = true
            end
        end
        if depth < 6 then spaceLabels(c, depth + 1) end
    end
end

local function pass(f, shownOnly)
    Kit.Auto(f, { shownOnly = shownOnly })
    backdrops(f, f:GetFrameStrata(), 1)
    spaceLabels(f, 1)
end

local function hex(r, g, b)
    return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
end

-- The item menu's text carries WoWClearance's own color codes (blue brand,
-- orange "Remove from"). Swap them for the accent and WARN colors.
local function recode(text)
    if type(text) ~= "string" then return text end
    local r, g, b = API.Accent()
    text = text:gsub("|cff66ccff", hex(r, g, b))
    text = text:gsub("|cffffff00", hex(r, g, b))      -- [?] help icons
    text = text:gsub("|cffffffaa", hex(rgb("VALUE")))  -- [?] under the mouse
    return (text:gsub("|cffff8000", hex(rgb("WARN"))))
end

-- Re-sets text through recode after WoWClearance sets it (guarded so our
-- own SetText does not loop).
local function recodeOn(region)
    local busy = false
    hooksecurefunc(region, "SetText", function(self, text)
        if busy then return end
        local new = recode(text)
        if new ~= text then
            busy = true
            self:SetText(new)
            busy = false
        end
    end)
end

local menuFont, menuFontOff
local function menuFonts()
    if not menuFont then
        menuFont = CreateFont("WoWClearanceDaylightMenuFont")
        menuFontOff = CreateFont("WoWClearanceDaylightMenuFontOff")
    end
    menuFont:SetFont(API.Font(), 12, "")
    menuFont:SetTextColor(rgb("TEXT"))
    menuFontOff:SetFont(API.Font(), 12, "")
    menuFontOff:SetTextColor(rgb("OFF"))
end

-- The Alt+Right-Click item menu: Daylight UI's window shell, the player's
-- font, an accent wash on hover, and thin lines for the dividers.
local function dressMenu(f)
    if f.SetBackdrop then f:SetBackdrop(nil) end
    API.Skin(f, { window = true })
    -- The menu's height follows its rows on every open; the shell is
    -- redrawn to match (API.Skin asks to be called again after a resize).
    hooksecurefunc(f, "SetHeight", function() API.Skin(f, { window = true }) end)
    menuFonts()
    if f.title then
        f.title:SetFont(API.Font(), 13, "")
        f.title:SetTextColor(rgb("TITLE"))
        recodeOn(f.title)
    end
    for _, btn in ipairs(f.buttons or {}) do
        btn:SetNormalFontObject(menuFont)
        btn:SetHighlightFontObject(menuFont)
        btn:SetDisabledFontObject(menuFontOff)
        if btn:IsMouseEnabled() then
            local hl = btn:GetHighlightTexture()
            if hl then
                hl:SetTexture(nil)
                hl:SetAllPoints(btn)
                btn.wcHighlight = hl
            end
            recodeOn(btn)
        else
            btn:SetText("")
            local line = btn:CreateTexture(nil, "ARTWORK")
            line:SetHeight(1)
            line:SetPoint("LEFT", 4, 0)
            line:SetPoint("RIGHT", -4, 0)
            line:SetColorTexture(1, 1, 1, 0.12)
        end
    end
    -- The accent can change: read it each time the menu opens.
    local function tint()
        local r, g, b = API.Accent()
        for _, btn in ipairs(f.buttons or {}) do
            if btn.wcHighlight then btn.wcHighlight:SetColorTexture(r, g, b, 0.18) end
        end
    end
    f:HookScript("OnShow", tint)
    tint()
end

local function skin(f, kind)
    if not f or InCombatLockdown() then return end
    if kind == "popup" then
        if not seen[f] then
            seen[f] = true
            dressMenu(f)
        end
        return
    end
    if not seen[f] then
        seen[f] = true
        if kind == "window" then Kit.Window(f) end
        f:HookScript("OnShow", function(self)
            if not InCombatLockdown() then pass(self, true) end
        end)
        pass(f, false)
    elseif f:IsShown() then
        pass(f, true)
    end
end

-- The standalone window's sidebar: gold/grey text and selection wash become
-- the accent and the text color.
local function recolor()
    local win = _G.WoWClearanceWindow
    -- Hidden window: nothing to recolor (this runs on a 1 s ticker).
    local list = win and win:IsShown() and win.sidebar and win.sidebar:GetScrollChild()
    if not list then return end
    for _, btn in ipairs({ list:GetChildren() }) do
        if btn.label and btn.sel then
            if btn.sel:IsShown() then
                local r, g, b = API.Accent()
                btn.label:SetTextColor(r, g, b)
                btn.sel:SetColorTexture(r, g, b, 0.16)
            else
                btn.label:SetTextColor(rgb("TEXT"))
            end
        end
    end
end

local function sweep()
    for _, n in ipairs(WINDOWS) do skin(_G[n], "window") end
    for _, n in ipairs(POPUPS) do skin(_G[n], "popup") end
    for _, n in ipairs(PANELS) do skin(_G[n], "panel") end
    recolor()
end

local function wrap(tbl, key, after)
    local orig = tbl and tbl[key]
    if type(orig) ~= "function" then return end
    tbl[key] = function(...)
        local a, b, c = orig(...)
        after(a, b, c)
        return a, b, c
    end
end

me.RegisterSkin("WoWClearance", function(K)
    if not API.IsModuleEnabled("Skins") then return false end
    if WoWClearanceDB and WoWClearanceDB.daylightLook == false then return end
    Kit = K
    -- Help panel headings and questions: Daylight UI's label and accent
    -- colors instead of the shared gold / light blue. Read when the Help
    -- panel draws, which is after this.
    if NS.Kit and NS.Kit.COLOR then
        local r, g, b = API.Accent()
        NS.Kit.COLOR.section = hex(rgb("LABEL"))
        NS.Kit.COLOR.question = hex(r, g, b)
    end
    -- [?] help icons in the accent, through the same recode as the menu.
    wrap(NS, "AddHelpIcon", function(btn)
        local fs = btn and btn.GetFontString and btn:GetFontString()
        if fs then
            recodeOn(fs)
            fs:SetText(fs:GetText())
        end
    end)
    -- Windows are created on demand inside these; dress them as they appear.
    wrap(NS, "ShowStandaloneWindow", sweep)
    wrap(NS, "ShowStandalonePanel", sweep)
    wrap(NS.Kit, "ShowCopy", function(copy) skin(copy, "window") end)
    -- Catch everything else made later (history, loot, menu, list rows).
    C_Timer.NewTicker(1, sweep)
    API.On("StyleChanged", recolor, "WoWClearance")
    sweep()
end)
