-- WoWClearance_Daylight.lua
--
-- DaylightUI integration. Loads last. Does nothing (and touches nothing of
-- DaylightUI) when DaylightUI is missing or is another major version.
-- A WoWClearance section in DaylightUI's options, /dui wc, a data text for
-- its data bars, and the Loot Log / Sold History / main windows placeable
-- with /dui unlock. WoWClearance does not restyle its own windows; a skin
-- addon can do that.
-- The bag integration (rings, groups, item menu row, locks, one seller)
-- lives in WoWClearance_BagDisplay.lua beside the other bag UI adapters.
-- Uses the public API in DaylightUI/API.md.

local NS = select(2, ...)
local DUI = _G.DaylightUI
local API = DUI and DUI.API
if not API or API.major ~= 1 then return end

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
                                },
                            },
                            {
                                label = L["Open"],
                                items = {
                                    { type = "button", label = L["WoWClearance settings"], func = openPanel("WoWClearanceOptionsMain") },
                                    { type = "button", label = L["Loot Log"], func = function() WoWClearance_ToggleLootLog() end },
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
                WoWClearance_ToggleLootLog()
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
            -- Looted coin comes from the optional Loot module.
            if ses.lootCopper then
                tip:AddDoubleLine(L["Gold looted"], money(ses.lootCopper), 1, 1, 1, 1, 1, 1)
                tip:AddLine(L["Click: settings. Right-click: Loot Log."], 0.6, 0.6, 0.6)
            else
                tip:AddLine(L["Click: settings."], 0.6, 0.6, 0.6)
            end
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
