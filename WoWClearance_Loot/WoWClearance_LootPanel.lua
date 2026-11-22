-- WoWClearance_LootPanel - the "Stats - Loot" panel (Loot module).
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Looting numbers that used to sit on the core Stats panel: coin looted,
-- session and best gold per hour, and the top farming zones, plus the
-- button that opens the Loot Log. The core window lists this frame by name
-- (WoWClearanceOptionsLoot in WC_PANEL_ORDER) and skips it when the module
-- is off.

local NS = select(2, ...).core
if not NS then
    return
end
local WC_compCache = NS.compCache
local L = NS.L

local panel = CreateFrame("Frame", "WoWClearanceOptionsLoot", NS.OptionsHost())
panel.name = "Stats - Loot"
panel.parent = "WoWClearance"

local function humanDuration(secs)
    secs = math.floor(secs)
    if secs < 60 then
        return string.format("%ds", secs)
    elseif secs < 3600 then
        return string.format("%dm %ds", math.floor(secs / 60), secs % 60)
    end
    return string.format("%dh %dm %ds", math.floor(secs / 3600), math.floor((secs % 3600) / 60), secs % 60)
end

local function whenText(at)
    if at <= 0 then
        return L["unknown date"]
    end
    local secs = time() - at
    if secs < 60 then
        return L["just now"]
    elseif secs < 3600 then
        local n = math.floor(secs / 60)
        return string.format(L["%d minute%s ago"], n, n == 1 and "" or "s")
    elseif secs < 86400 then
        local n = math.floor(secs / 3600)
        return string.format(L["%d hour%s ago"], n, n == 1 and "" or "s")
    elseif secs < 30 * 86400 then
        local n = math.floor(secs / 86400)
        return string.format(L["%d day%s ago"], n, n == 1 and "" or "s")
    end
    return date("%Y-%m-%d", at)
end

-- Session + best gold per hour. NS.StampBestGPH (LootCapture) also keeps
-- the best record current, so a record set mid-session is never missed.
local function refreshGPH(view, src)
    local startedAt = NS.session.startedAt or 0
    local elapsed = (startedAt > 0) and (GetTime() - startedAt) or 0
    local sessionGPH = NS.StampBestGPH()
    panel.gphSession.left:SetText(L["Session Gold/Hour"])
    if sessionGPH then
        panel.gphSession.right:SetText(
            NS.CopperToGoldOnlyText(sessionGPH) .. string.format("  |cff888888(%s)|r", humanDuration(elapsed))
        )
    else
        panel.gphSession.right:SetText(L["|cff888888-  (computing...)|r"])
    end

    panel.gphBest.left:SetText(L["Best Gold/Hour"])
    local best = src.bestGPH or 0
    if best > 0 then
        local zone = src.bestGPHZone
        if not zone or zone == "" then
            zone = L["Unknown"]
        end
        local charSuffix = ""
        if view == "account" and src.bestGPHChar and src.bestGPHChar ~= "" then
            charSuffix = string.format(L[" on %s"], src.bestGPHChar)
        end
        panel.gphBest.right:SetText(
            NS.CopperToGoldOnlyText(best)
                .. string.format(L["  |cff888888in %s, %s%s|r"], zone, whenText(src.bestGPHAt or 0), charSuffix)
        )
    else
        panel.gphBest.right:SetText(L["|cff888888-|r"])
    end
end

local function refreshZones(src)
    local entries = {}
    for name, copper in pairs(src.copperByZone or {}) do
        if type(name) == "string" and type(copper) == "number" and copper > 0 then
            entries[#entries + 1] = { name = name, copper = copper }
        end
    end
    table.sort(entries, function(a, b)
        if a.copper == b.copper then
            return a.name < b.name
        end
        return a.copper > b.copper
    end)
    for i = 1, 5 do
        local row, e = panel.zoneRows[i], entries[i]
        if e then
            row.left:SetText(string.format("  %d. %s", i, e.name))
            row.right:SetText(NS.CopperToGoldOnlyText(e.copper))
            row:Show()
        else
            row:Hide()
        end
    end
    if #entries == 0 then
        panel.zoneEmpty.left:SetText(L["  |cff888888No zones tracked yet.|r"])
        panel.zoneEmpty:Show()
    else
        panel.zoneEmpty:Hide()
    end
end

local function refresh()
    if not panel.lootCoin then
        return
    end
    local DB, ADB = NS.DB, NS.ADB
    local view = panel.view
    local src = (view == "account") and (ADB and ADB.accountStats) or DB
    if not src then
        return
    end
    local coin = NS.CopperToGoldOnlyText(src.totalLootCopper or 0)
    if view == "character" then
        coin = coin .. "  |cff888888(session +" .. NS.CopperToGoldOnlyText(NS.session.lootCopper or 0) .. "|cff888888)|r"
    end
    panel.lootCoin.left:SetText(L["Gold Looted"])
    panel.lootCoin.right:SetText(coin)
    refreshGPH(view, src)
    refreshZones(src)
end

-- 1Hz while shown: the session rate moves every second.
panel:SetScript("OnUpdate", function(self, elapsed)
    self.tick = (self.tick or 0) + elapsed
    if self.tick >= 1 then
        self.tick = 0
        refresh()
    end
end)

panel:SetScript("OnShow", function(self)
    WC_compCache.initPanel(self, refresh, function(_, content)
        panel.view = panel.view or "character"
        local heading = NS.MakeHeader(content, L["Stats - Loot"], -16)

        local function makeRadio(label, anchor, x)
            local radio = CreateFrame("CheckButton", nil, content, "UIRadioButtonTemplate")
            radio:SetPoint("TOPLEFT", anchor, x and "TOPRIGHT" or "BOTTOMLEFT", x or 0, x and 0 or -8)
            local text = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            text:SetPoint("LEFT", radio, "RIGHT", 4, 0)
            text:SetText(label)
            radio.text = text
            return radio
        end
        local charRadio = makeRadio(L["Character"], heading)
        local acctRadio = makeRadio(L["Account"], charRadio.text, 16)
        local function setView(view)
            panel.view = view
            charRadio:SetChecked(view == "character")
            acctRadio:SetChecked(view == "account")
            refresh()
        end
        charRadio:SetScript("OnClick", function()
            setView("character")
        end)
        acctRadio:SetScript("OnClick", function()
            setView("account")
        end)
        charRadio:SetChecked(panel.view == "character")
        acctRadio:SetChecked(panel.view == "account")

        local lootBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        lootBtn:SetSize(140, 26)
        lootBtn:SetPoint("TOPLEFT", charRadio, "BOTTOMLEFT", 0, -10)
        lootBtn:SetText(L["Loot Log"])
        lootBtn:SetScript("OnClick", function()
            NS.ToggleLootWindow()
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
        local lootHint = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        lootHint:SetPoint("LEFT", lootBtn, "RIGHT", 10, 0)
        lootHint:SetJustifyH("LEFT")
        WC_compCache.setPanelWidth(lootHint, 180)
        lootHint:SetText(L["|cff888888What you've looted this session, or account-wide.|r"])

        panel.lootCoin = NS.MakeStatRow(content, lootBtn, -16, 200)
        panel.gphSession = NS.MakeStatRow(content, panel.lootCoin, -6, 200)
        panel.gphBest = NS.MakeStatRow(content, panel.gphSession, -6, 200)

        local zones = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        zones:SetPoint("TOPLEFT", panel.gphBest, "BOTTOMLEFT", 0, -10)
        WC_compCache.setPanelWidth(zones, 16)
        zones:SetJustifyH("LEFT")
        zones:SetText(L["|cffffd200Top Zones (gold earned)|r"])
        panel.zoneRows = {}
        local last = zones
        for i = 1, 5 do
            panel.zoneRows[i] = NS.MakeStatRow(content, last, i == 1 and -2 or 0, 200)
            last = panel.zoneRows[i]
        end
        panel.zoneEmpty = NS.MakeStatRow(content, zones, -2, 200)

        local note = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        note:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -10)
        WC_compCache.setPanelWidth(note, 16)
        note:SetJustifyH("LEFT")
        note:SetText(
            L["|cff888888Gold per hour counts gold from selling plus coin looted. Top Zones counts selling only, outside cities.|r"]
        )
        refresh()
        NS.FitScrollContent(content, note)
    end, true)
end)
