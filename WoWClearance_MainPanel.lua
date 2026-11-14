-- WoWClearance_MainPanel - main "WoWClearance" Interface Options panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-ix-a of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The top-level "WoWClearance" panel - the entry point users hit
-- first when opening Interface Options. Hosts the welcome blurb,
-- feature orientation, the Alt+Right-Click tip, and the slash
-- command reference. Stats moved to WoWClearance_StatsPanel.lua
-- in v2.36.x (sub-panel split). The NS.RefreshStats / NS.ResetLifetimeStats
-- helpers still live in this file so Events.lua data-change handlers
-- have a stable namespace entry point; they write to the Stats panel
-- via _G["WoWClearanceOptionsStats"] and no-op until that panel is
-- built.
--
-- Moved into this file:
--   * local MainOptions = CreateFrame(...) frame creation
--   * BuildMainPanel function (~153 LOC; builds the panel body)
--   * The MainOptions OnShow handler which composes RefreshStats +
--     BuildMainPanel through WC_compCache.initPanel
--
-- The panel-infrastructure helpers (WC_PANEL_WIDTH, initPanel,
-- registerWidth, setPanelWidth, etc.) live in
-- WoWClearance_PanelInfra.lua, and the widget primitives (MakeHeader,
-- MakeLabel, AddCheckbox, AddSlider) in WoWClearance_PanelWidgets.lua;
-- both are exposed on NS and shared across every panel.
--
-- Cross-file dependencies satisfied by NS:
--   * NS.compCache (Core) - initPanel, setPanelWidth
--   * NS.DB / NS.ADB captured at OnShow + BuildMainPanel entry
--   * NS.MakeHeader / NS.MakeLabel (8e-i)
--   * NS.FitScrollContent (8e-ii)
--   * NS.CopperToColoredText (Stage 8 era)
--   * NS.GetVersion (Stage 8 era)
--   * NS.ResetSession (8e-ix-a prep) - session-stats reset handler
--     used by the Reset Session button on this panel

local NS = select(2, ...)
local GetItemInfo = C_Item.GetItemInfo
local WC_compCache = NS.compCache
local L = NS.L

local MainOptions = CreateFrame("Frame", "WoWClearanceOptionsMain", NS.OptionsHost())
MainOptions.name = "WoWClearance"

-- ---------------------------------------------------------------------------
-- NS.RefreshStats / NS.ResetLifetimeStats - namespace-exposed helpers.
-- ---------------------------------------------------------------------------
-- Stage 8e-ix-b of the file split: the stats refresh + lifetime-reset
-- logic was a closure local to MainOptions:OnShow. Stats widgets are
-- moving to WoWClearance_StatsPanel.lua (Task 4) and the data-change
-- handlers in WoWClearance_Events.lua need to drive a refresh without
-- knowing which panel owns the FontStrings. Hoisting these to file
-- scope and exposing them on NS gives callers a stable entry point.
-- The stats widgets now hang on _G["WoWClearanceOptionsStats"]; both
-- functions look it up and no-op if the panel isn't built yet.

-- GetTopNItems: return up to N {id, count} pairs ordered by count desc.
-- v2.37.0 superset of the old GetMostItem (which returned only the top
-- entry). The Stats panel renders the top 5 most-sold items; passing
-- n=1 reproduces the v2.36.x single-line "Most Sold Item" behaviour.
local function GetTopNItems(countTable, n)
    if type(countTable) ~= "table" then
        return {}
    end
    local entries = {}
    for id, cnt in pairs(countTable) do
        if type(id) == "number" and type(cnt) == "number" and cnt > 0 then
            entries[#entries + 1] = { id = id, count = cnt }
        end
    end
    table.sort(entries, function(a, b)
        if a.count == b.count then
            return a.id < b.id
        end
        return a.count > b.count
    end)
    local top = {}
    for i = 1, math.min(n or 1, #entries) do
        top[i] = entries[i]
    end
    return top
end

-- v2.37.0: quality bucket order + display names + colours. WoW's
-- ITEM_QUALITY_COLORS table exists in 3.3.5a but its colour codes
-- don't always include the leading "ff" alpha pair our format
-- strings expect; hardcoding keeps the rendering stable. Heirloom
-- (7) reuses the Artifact (6) gold tone, matching the legacy
-- in-game tooltip palette.
local QUALITY_NAMES = {
    [0] = L["Poor"],
    [1] = L["Common"],
    [2] = L["Uncommon"],
    [3] = L["Rare"],
    [4] = L["Epic"],
    [5] = L["Legendary"],
    [6] = L["Artifact"],
    [7] = L["Heirloom"],
}
local QUALITY_HEX = {
    [0] = "9d9d9d",
    [1] = "ffffff",
    [2] = "1eff00",
    [3] = "0070dd",
    [4] = "a335ee",
    [5] = "ff8000",
    [6] = "e6cc80",
    [7] = "e6cc80",
}

-- ItemLabel: resolve an itemID to a coloured name string, with a
-- cache-warmup deferred re-render for cold-cache cases. The warmup
-- flag hangs on the stats panel itself so a hidden panel doesn't
-- accumulate pending refreshes.
local function ItemLabel(id)
    if not id then
        return L["None"]
    end
    local name = GetItemInfo(id)
    if name then
        return string.format("|cff24ffb6%s|r", name)
    end
    -- GetItemInfo cold-cache. Post per-character partition (v2.34.0),
    -- each character inherits the snapshot of accumulated counts -
    -- which can include items the current character has never seen
    -- this session, and those items haven't been requested from the
    -- server yet. Trigger a SetHyperlink-driven cache fetch and
    -- schedule one re-render so the name resolves the moment the
    -- client receives the data (typically 100-300 ms). Falls back
    -- to the ItemID string for this paint; the re-render replaces it.
    if NS.scanTooltip and NS.scanTooltip.SetHyperlink then
        NS.scanTooltip:ClearLines()
        NS.scanTooltip:SetHyperlink("item:" .. tostring(id))
    end
    local statsPanel = _G["WoWClearanceOptionsStats"]
    if statsPanel and not statsPanel._statsWarmupPending and NS.Delay then
        statsPanel._statsWarmupPending = true
        NS.Delay(0.6, function()
            statsPanel._statsWarmupPending = nil
            if statsPanel.IsShown and statsPanel:IsShown() and NS.RefreshStats then
                NS.RefreshStats()
            end
        end)
    end
    return "ItemID: " .. tostring(id)
end

-- v2.68.1: cheap change-token over every counter RefreshStats renders.
-- The Stats panel's 1Hz tick used to run the FULL repaint (~40 SetTexts +
-- a 6-section re-anchor pass) every second while open, even when nothing
-- changed. The tick now compares this token and only full-repaints on a
-- real change; between changes it refreshes just the time-varying
-- Gold/Hour rows. Session-suffix fields only ever change alongside these
-- lifetime counters (a session reset repaints via its direct
-- NS.RefreshStats call), so they don't need their own terms.
local function WC_statsChangeToken(src)
    local t = (src.totalCopper or 0)
        + (src.totalItemsSold or 0)
        + (src.totalItemsDeleted or 0)
        + (src.totalRepairs or 0)
        + (src.totalRepairCopper or 0)
        + (src.totalLootCopper or 0)
        + (src.inventoryWorthCount or 0)
    local counts = src.processCastCounts
    if counts then
        for _, n in pairs(counts) do
            t = t + (tonumber(n) or 0)
        end
    end
    return t
end

-- v2.35.x Session + Best Gold/Hour rows. Extracted from RefreshStats
-- (v2.68.1) so the Stats panel's 1Hz tick can refresh ONLY these
-- time-varying rows between real stat changes. Includes the best-record
-- stamping (5-minute gate, all three fields written together) - it must
-- keep running every tick so a record set mid-session is never missed.
--
-- The session line shows the live rate (copper/hour) computed from
-- session.copper / elapsed-seconds, with a 10-second floor on the elapsed
-- value so sub-second extrapolation doesn't produce absurd numbers right
-- after /reload. The best line shows the record + zone + when context.
-- See docs/specs/2026-05-26-gph-stats-design.md.
local function WC_RefreshGPHRows(panel, view, src, DB, ADB)
    local startedAt = NS.session.startedAt or 0
    local now = GetTime()
    local elapsed = (startedAt > 0) and (now - startedAt) or 0
    local function humanDuration(secs)
        secs = math.floor(secs)
        if secs < 60 then
            return string.format("%ds", secs)
        elseif secs < 3600 then
            return string.format("%dm %ds", math.floor(secs / 60), secs % 60)
        end
        local h = math.floor(secs / 3600)
        local m = math.floor((secs % 3600) / 60)
        local s = secs % 60
        return string.format("%dh %dm %ds", h, m, s)
    end
    local sessionGPH
    if elapsed >= 10 then
        -- v0.7.0: looted coin counts as income too.
        sessionGPH = math.floor(((NS.session.copper + (NS.session.lootCopper or 0)) / elapsed) * 3600)
    end
    if panel.statsSessionGPH then
        panel.statsSessionGPH.left:SetText(L["Session Gold/Hour"])
        if sessionGPH then
            panel.statsSessionGPH.right:SetText(
                NS.CopperToGoldOnlyText(sessionGPH)
                    .. string.format("  |cff888888(%s)|r", humanDuration(elapsed))
            )
        else
            panel.statsSessionGPH.right:SetText(L["|cff888888-  (computing...)|r"])
        end
    end

    -- Best-update gate: 5 minutes of session AND new high. Compared
    -- against both records independently so a character-best update
    -- doesn't require an account-best, and vice versa.
    if sessionGPH and elapsed >= 300 then
        local zone = GetRealZoneText()
        local zoneText = (zone and zone ~= "") and zone or "Unknown"
        local nowTime = time()
        if sessionGPH > (DB.bestGPH or 0) then
            DB.bestGPH = sessionGPH
            DB.bestGPHAt = nowTime
            DB.bestGPHZone = zoneText
        end
        -- v2.38.1: account-wide best record. Stamp the character name
        -- so the Account view's ribbon can say "on <CharName>".
        local AS = ADB and ADB.accountStats
        if AS and sessionGPH > (AS.bestGPH or 0) then
            AS.bestGPH = sessionGPH
            AS.bestGPHAt = nowTime
            AS.bestGPHZone = zoneText
            AS.bestGPHChar = GetUnitName("player", true) or ""
        end
    end

    if panel.statsBestGPH then
        local best = src.bestGPH or 0
        if best > 0 then
            local at = src.bestGPHAt or 0
            local zone = src.bestGPHZone
            if not zone or zone == "" then
                zone = L["Unknown"]
            end
            local when
            if at <= 0 then
                when = L["unknown date"]
            else
                local secs = time() - at
                if secs < 60 then
                    when = L["just now"]
                elseif secs < 3600 then
                    local n = math.floor(secs / 60)
                    when = string.format(L["%d minute%s ago"], n, n == 1 and "" or "s")
                elseif secs < 86400 then
                    local n = math.floor(secs / 3600)
                    when = string.format(L["%d hour%s ago"], n, n == 1 and "" or "s")
                elseif secs < 30 * 86400 then
                    local n = math.floor(secs / 86400)
                    when = string.format(L["%d day%s ago"], n, n == 1 and "" or "s")
                else
                    when = date("%Y-%m-%d", at)
                end
            end
            -- v2.38.1: append the character name in Account view so
            -- "Best Gold/Hour: 12345g  in Stranglethorn, 2 hours ago on Bob"
            -- tells the player which character set the account record.
            local charSuffix = ""
            if view == "account" and src.bestGPHChar and src.bestGPHChar ~= "" then
                charSuffix = string.format(L[" on %s"], src.bestGPHChar)
            end
            panel.statsBestGPH.left:SetText(L["Best Gold/Hour"])
            panel.statsBestGPH.right:SetText(
                NS.CopperToGoldOnlyText(best)
                    .. string.format(L["  |cff888888in %s, %s%s|r"], zone, when, charSuffix)
            )
        else
            panel.statsBestGPH.left:SetText(L["Best Gold/Hour"])
            panel.statsBestGPH.right:SetText(L["|cff888888-|r"])
        end
    end
end

-- v0.7.0: the last seven days from ADB.accountStats.daily (written by
-- WC_compCache.bumpDay). Net = sold + looted coin - repairs, then the item
-- counts in grey. Account-wide in both views: the header says so.
local function WC_RefreshDayRows(panel, ADB)
    if not (panel.statsDays and panel._dayRows) then
        return
    end
    panel.statsDays:SetText(L["|cffffd200Last 7 Days (all characters)|r"])
    local daily = ADB and ADB.accountStats and ADB.accountStats.daily or {}
    local now = time()
    for i = 1, 7 do
        local row = panel._dayRows[i]
        -- Noon of each day, so a daylight-saving hour never lands on the
        -- day before.
        local t = now - (i - 1) * 86400
        local d = date("*t", t)
        d.hour, d.min, d.sec = 12, 0, 0
        t = time(d)
        local label = (i == 1 and L["Today"]) or (i == 2 and L["Yesterday"]) or date("%a %d %b", t)
        local r = daily[date("%Y-%m-%d", t)]
        row.left:SetText(label)
        if r then
            local net = (r.c or 0) + (r.g or 0) - (r.r or 0)
            local text = NS.CopperToGoldOnlyText(math.abs(net))
            row.right:SetText(
                (net < 0 and ("|cffff4444-|r" .. text) or text)
                    .. string.format(
                        L["  |cff888888(%s sold, %s deleted, %s looted)|r"],
                        NS.CommaNumber(r.s or 0),
                        NS.CommaNumber(r.d or 0),
                        NS.CommaNumber(r.l or 0)
                    )
            )
        else
            row.right:SetText("|cff888888-|r")
        end
        row:Show()
    end
end

function NS.RefreshStats()
    local panel = _G["WoWClearanceOptionsStats"]
    if not panel or not panel.statsMoney then
        return
    end
    local DB = NS.DB
    local ADB = NS.ADB
    if not DB then
        return
    end
    -- v2.38.1: view-aware. Character view reads DB.* (this character's
    -- lifetime). Account view reads ADB.accountStats.* (aggregated
    -- across all characters since v2.38.1 install). Session deltas only
    -- render in Character view - "session" is inherently per-character.
    local view = panel._statsView or "character"
    local src = (view == "account") and (ADB and ADB.accountStats) or DB
    if not src then
        return
    end
    local showSession = (view == "character")
    -- Thousands-separated count. Lazy delegate over the nil-safe
    -- NS.CommaNumber (this closure runs post-load, so the lookup always
    -- resolves; the old `and/or` fallback was dead defensiveness).
    local function num(n)
        return NS.CommaNumber(n)
    end
    local function sessionSuffix(n)
        if not showSession then
            return ""
        end
        return string.format(L["  |cff888888(session +%s)|r"], num(n))
    end
    local function sessionMoneySuffix(c)
        if not showSession then
            return ""
        end
        return "  |cff888888(session +" .. NS.CopperToGoldOnlyText(c or 0) .. "|cff888888)|r"
    end
    -- v2.66.1 iter (Serv report): aggregate rows are now two-column
    -- MakeStatRow containers (row.left = label, row.right = value).
    -- Label stays static, value updates per refresh; session-suffix is
    -- appended to the value cell so it flows with the same column.
    panel.statsMoney.left:SetText(L["Total Money Made"])
    panel.statsMoney.right:SetText(NS.CopperToGoldOnlyText(src.totalCopper or 0) .. sessionMoneySuffix(NS.session.copper))
    panel.statsSold.left:SetText(L["Total Items Sold"])
    panel.statsSold.right:SetText(num(src.totalItemsSold or 0) .. sessionSuffix(NS.session.sold))
    panel.statsDeleted.left:SetText(L["Total Items Deleted"])
    panel.statsDeleted.right:SetText(num(src.totalItemsDeleted or 0) .. sessionSuffix(NS.session.deleted))
    panel.statsRepairs.left:SetText(L["Total Repairs"])
    panel.statsRepairs.right:SetText(num(src.totalRepairs or 0) .. sessionSuffix(NS.session.repairs))
    panel.statsRepairCost.left:SetText(L["Total Repair Cost"])
    panel.statsRepairCost.right:SetText(NS.CopperToGoldOnlyText(src.totalRepairCopper or 0) .. sessionMoneySuffix(NS.session.repairCopper))
    -- v0.7.0: looted coin and the net line (sold + looted coin - repairs).
    if panel.statsLootCoin then
        panel.statsLootCoin.left:SetText(L["Gold Looted"])
        panel.statsLootCoin.right:SetText(
            NS.CopperToGoldOnlyText(src.totalLootCopper or 0) .. sessionMoneySuffix(NS.session.lootCopper)
        )
    end
    if panel.statsNet then
        local net = (src.totalCopper or 0) + (src.totalLootCopper or 0) - (src.totalRepairCopper or 0)
        local text = NS.CopperToGoldOnlyText(math.abs(net))
        panel.statsNet.left:SetText(L["Net (after repairs)"])
        panel.statsNet.right:SetText(net < 0 and ("|cffff4444-|r" .. text) or text)
    end
    WC_RefreshDayRows(panel, ADB)

    -- v2.35.x: Session + Best Gold/Hour - body extracted to
    -- WC_RefreshGPHRows (v2.68.1) so the 1Hz tick can run it alone.
    WC_RefreshGPHRows(panel, view, src, DB, ADB)

    if panel.statsAvgWorth then
        -- inventoryWorthTotal / inventoryWorthCount are per-character
        -- only (no account aggregate). Account view shows a dash for
        -- this row since the average wouldn't be meaningful across
        -- characters with different equip levels.
        panel.statsAvgWorth.left:SetText(L["Average Inventory Worth"])
        if view == "account" then
            panel.statsAvgWorth.right:SetText(L["|cff888888- (per-character only)|r"])
        else
            local cnt = DB.inventoryWorthCount or 0
            local total = DB.inventoryWorthTotal or 0
            local avg = 0
            if cnt > 0 then
                avg = math.floor((total / cnt) + 0.5)
            end
            panel.statsAvgWorth.right:SetText(NS.CopperToGoldOnlyText(avg))
        end
    end

    -- v2.66.1 iter (Serv report): Sold-by-Quality now header + per-quality
    -- MakeStatRow with .left (color-coded quality name) and .right (count
    -- + gold value). Rows Hide when their quality bucket has 0 entries;
    -- empty-state row Shows when all are 0.
    if panel.statsQualityBreakdown then
        panel.statsQualityBreakdown:SetText(L["|cffffd200Sold by Quality|r"])
    end
    -- Empty quality buckets are Hidden, never collapsed with SetHeight(0).
    --
    -- WC-TRAP: SetHeight(0) on these row frames was tried during v2.66.1
    -- and broke the anchor chain outright - every section BELOW this one
    -- stopped rendering in-game. Hide() alone is correct here. The gap a
    -- Hidden row leaves (it still occupies its 14px slot) is closed at the
    -- end of RefreshStats instead, where each section header re-anchors to
    -- the last VISIBLE row above it. Do not reintroduce height collapsing.
    if panel._soldByQualityRows and panel._soldByQualityEmpty then
        local items = src.soldItemsByQuality or {}
        local copper = src.soldCopperByQuality or {}
        local any = false
        for q = 0, 7 do
            local row = panel._soldByQualityRows[q]
            local cnt = items[q]
            if row then
                if cnt and cnt > 0 then
                    any = true
                    row.left:SetText(string.format(
                        "  |cff%s%s|r",
                        QUALITY_HEX[q] or "ffffff",
                        QUALITY_NAMES[q] or ("Quality " .. q)
                    ))
                    row.right:SetText(string.format("|cff888888x%s|r", num(cnt)))
                    if row.gold then
                        row.gold:SetText(NS.CopperToGoldOnlyText(copper[q] or 0))
                    end
                    row:Show()
                else
                    row.left:SetText("")
                    row.right:SetText("")
                    if row.gold then
                        row.gold:SetText("")
                    end
                    row:Hide()
                end
            end
        end
        if not any then
            panel._soldByQualityEmpty.left:SetText(L["  |cff888888Nothing sold yet.|r"])
            panel._soldByQualityEmpty.right:SetText("")
            panel._soldByQualityEmpty:Show()
        else
            panel._soldByQualityEmpty:Hide()
        end
    end

    if panel.statsDeletedByQuality then
        panel.statsDeletedByQuality:SetText(L["|cffffd200Deleted by Quality|r"])
    end
    if panel._deletedByQualityRows and panel._deletedByQualityEmpty then
        local items = src.deletedItemsByQuality or {}
        local any = false
        for q = 0, 7 do
            local row = panel._deletedByQualityRows[q]
            local cnt = items[q]
            if row then
                if cnt and cnt > 0 then
                    any = true
                    row.left:SetText(string.format(
                        "  |cff%s%s|r",
                        QUALITY_HEX[q] or "ffffff",
                        QUALITY_NAMES[q] or ("Quality " .. q)
                    ))
                    row.right:SetText(string.format("|cff888888x%s|r", num(cnt)))
                    row:Show()
                else
                    row.left:SetText("")
                    row.right:SetText("")
                    row:Hide()
                end
            end
        end
        if not any then
            panel._deletedByQualityEmpty.left:SetText(L["  |cff888888Nothing deleted yet.|r"])
            panel._deletedByQualityEmpty.right:SetText("")
            panel._deletedByQualityEmpty:Show()
        else
            panel._deletedByQualityEmpty:Hide()
        end
    end

    -- v2.66.1 iter (Serv report): Top 5 lists now render via per-row
    -- MakeStatRow containers so the count column aligns at a fixed X -
    -- matches Stats - Guild / Stats - Server. Header widget still lives
    -- on panel.statsMostSold / panel.statsMostDeleted (name preserved
    -- as a contract surface); the actual data rows live on
    -- panel._mostSoldRows / panel._mostDeletedRows (built in
    -- WoWClearance_StatsPanel.lua's buildCallback).
    if panel.statsMostSold then
        panel.statsMostSold:SetText(L["|cffffd200Top 5 Most Sold|r"])
    end
    if panel._mostSoldRows and panel._mostSoldEmpty then
        local top = GetTopNItems(src.soldItemCounts, 5)
        for i = 1, 5 do
            local row = panel._mostSoldRows[i]
            local e = top[i]
            if row then
                if e then
                    row.left:SetText(string.format("  %d. %s", i, ItemLabel(e.id)))
                    row.right:SetText(string.format("|cff888888x|r|cffffffff%s|r", num(e.count)))
                    row:Show()
                else
                    row.left:SetText("")
                    row.right:SetText("")
                    row:Hide()
                end
            end
        end
        if #top == 0 then
            panel._mostSoldEmpty.left:SetText(L["  |cff888888Nothing sold yet.|r"])
            panel._mostSoldEmpty.right:SetText("")
            panel._mostSoldEmpty:Show()
        else
            panel._mostSoldEmpty:Hide()
        end
    end

    if panel.statsMostDeleted then
        panel.statsMostDeleted:SetText(L["|cffffd200Top 5 Most Deleted|r"])
    end
    if panel._mostDeletedRows and panel._mostDeletedEmpty then
        local top = GetTopNItems(src.deletedItemCounts, 5)
        for i = 1, 5 do
            local row = panel._mostDeletedRows[i]
            local e = top[i]
            if row then
                if e then
                    row.left:SetText(string.format("  %d. %s", i, ItemLabel(e.id)))
                    row.right:SetText(string.format("|cff888888x|r|cffffffff%s|r", num(e.count)))
                    row:Show()
                else
                    row.left:SetText("")
                    row.right:SetText("")
                    row:Hide()
                end
            end
        end
        if #top == 0 then
            panel._mostDeletedEmpty.left:SetText(L["  |cff888888Nothing deleted yet.|r"])
            panel._mostDeletedEmpty.right:SetText("")
            panel._mostDeletedEmpty:Show()
        else
            panel._mostDeletedEmpty:Hide()
        end
    end

    if panel.statsProcessTotals then
        panel.statsProcessTotals:SetText(L["|cffffd200Process Bags Totals|r"])
    end
    if panel._processRows then
        local counts = src.processCastCounts or {}
        -- Fixed display order: Disenchant, Milling, Prospecting, Pick Lock,
        -- skipping any skill this client does not have (Forever has no
        -- Milling or Prospecting). Uses the same data-driven check as the
        -- Process Bags panel (processModeExists), so a skill a future build
        -- adds comes back with no code change. Shown rows pack to the top
        -- and the rest hide; the section below anchors to the last shown
        -- row. Zero counts render greyed out.
        local order = { "Disenchant", "Milling", "Prospecting", "Pick Lock" }
        local labels = {
            Disenchant = L["Disenchanted"],
            Milling = L["Milled"],
            Prospecting = L["Prospected"],
            ["Pick Lock"] = L["Lockboxes Picked"],
        }
        -- processCastCounts is keyed by spell name; the existence check by
        -- Process Bags mode.
        local modeOf = { Disenchant = "Disenchant", Milling = "Mill", Prospecting = "Prospect", ["Pick Lock"] = "Lockpick" }
        local exists = WC_compCache.processModeExists
        local shown = 0
        for _, k in ipairs(order) do
            if not exists or exists(modeOf[k]) then
                shown = shown + 1
                local row = panel._processRows[shown]
                local n = counts[k] or 0
                if row then
                    if n > 0 then
                        row.left:SetText(string.format("  %s", labels[k]))
                        row.right:SetText(string.format("|cffffffff%s|r", num(n)))
                    else
                        row.left:SetText(string.format("  |cff888888%s|r", labels[k]))
                        row.right:SetText("|cff888888" .. num(n) .. "|r")
                    end
                    row:Show()
                end
            end
        end
        for i = shown + 1, 4 do
            if panel._processRows[i] then
                panel._processRows[i]:Hide()
            end
        end
    end

    -- v2.66.1 iter (Serv report): Top Zones now header + per-zone
    -- MakeStatRow so the gold column aligns at a fixed X.
    if panel.statsTopZones then
        panel.statsTopZones:SetText(L["|cffffd200Top Zones (gold earned)|r"])
    end
    if panel._topZoneRows and panel._topZoneEmpty then
        local zones = src.copperByZone or {}
        local entries = {}
        for name, copper in pairs(zones) do
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
        local cap = math.min(#entries, 5)
        for i = 1, 5 do
            local row = panel._topZoneRows[i]
            local e = (i <= cap) and entries[i] or nil
            if row then
                if e then
                    row.left:SetText(string.format("  %d. %s", i, e.name))
                    row.right:SetText(NS.CopperToGoldOnlyText(e.copper))
                    row:Show()
                else
                    row.left:SetText("")
                    row.right:SetText("")
                    row:Hide()
                end
            end
        end
        if #entries == 0 then
            panel._topZoneEmpty.left:SetText(L["  |cff888888No zones tracked yet.|r"])
            panel._topZoneEmpty.right:SetText("")
            panel._topZoneEmpty:Show()
        else
            panel._topZoneEmpty:Hide()
        end
    end

    -- v2.66.1 iter 4 (Serv report): dynamic gap closure. Each section
    -- header re-anchors at refresh time to the LAST VISIBLE row of the
    -- previous section, rather than staying pinned to row N of a fixed
    -- N-row block. Hidden rows still occupy their 14px slot in the
    -- static anchor chain built by StatsPanel, so with (say) 5 of 8
    -- quality buckets populated, the next section header would otherwise
    -- sit ~42px below the last populated row. Re-anchoring closes those
    -- gaps to a natural 10-14px header padding.
    local function lastVisibleRow(rows, header, emptyRow, minIndex, maxIndex)
        if rows then
            for i = maxIndex, minIndex, -1 do
                local row = rows[i]
                if row and row:IsShown() then
                    return row
                end
            end
        end
        if emptyRow and emptyRow:IsShown() then
            return emptyRow
        end
        return header
    end
    local function reanchor(target, anchor, yOff)
        if not target or not anchor then
            return
        end
        target:ClearAllPoints()
        target:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff)
    end
    if panel.statsDeletedByQuality then
        reanchor(
            panel.statsDeletedByQuality,
            lastVisibleRow(panel._soldByQualityRows, panel.statsQualityBreakdown, panel._soldByQualityEmpty, 0, 7),
            -10
        )
    end
    if panel.statsMostSold then
        reanchor(
            panel.statsMostSold,
            lastVisibleRow(
                panel._deletedByQualityRows,
                panel.statsDeletedByQuality,
                panel._deletedByQualityEmpty,
                0,
                7
            ),
            -10
        )
    end
    if panel.statsMostDeleted then
        reanchor(
            panel.statsMostDeleted,
            lastVisibleRow(panel._mostSoldRows, panel.statsMostSold, panel._mostSoldEmpty, 1, 5),
            -10
        )
    end
    if panel.statsProcessTotals then
        reanchor(
            panel.statsProcessTotals,
            lastVisibleRow(panel._mostDeletedRows, panel.statsMostDeleted, panel._mostDeletedEmpty, 1, 5),
            -10
        )
    end
    if panel.statsTopZones then
        reanchor(
            panel.statsTopZones,
            -- v2.68.1: emptyRow arg is nil - the always-hidden _processEmpty
            -- widget was removed; the header fallback covers the (unreachable
            -- since v2.66.1) all-rows-hidden case identically.
            lastVisibleRow(panel._processRows, panel.statsProcessTotals, nil, 1, 4),
            -10
        )
    end
    -- v0.7.0: the day rows follow Top Zones; all seven always show, so
    -- the footnote anchors to the seventh.
    if panel.statsDays then
        reanchor(
            panel.statsDays,
            lastVisibleRow(panel._topZoneRows, panel.statsTopZones, panel._topZoneEmpty, 1, 5),
            -10
        )
    end
    if panel.statsNote and panel._dayRows then
        reanchor(panel.statsNote, panel._dayRows[7], -4)
    end

    -- v2.68.1: stamp the change-token so the 1Hz tick (NS.RefreshStatsTick)
    -- can tell whether anything this repaint rendered has changed since.
    panel._statsToken = WC_statsChangeToken(src)
    panel._statsTokenView = view
end

-- v2.68.1: the Stats panel's 1Hz driver. Full repaint ONLY when a rendered
-- counter changed (or the view flipped under us); otherwise just the
-- time-varying Gold/Hour rows. Direct NS.RefreshStats callers (view
-- toggles, resets, OnShow) are unaffected - they re-stamp the token.
function NS.RefreshStatsTick()
    local panel = _G["WoWClearanceOptionsStats"]
    if not panel or not panel.statsMoney then
        return
    end
    local DB = NS.DB
    local ADB = NS.ADB
    if not DB then
        return
    end
    local view = panel._statsView or "character"
    local src = (view == "account") and (ADB and ADB.accountStats) or DB
    if not src then
        return
    end
    if view ~= panel._statsTokenView or WC_statsChangeToken(src) ~= panel._statsToken then
        NS.RefreshStats()
    else
        WC_RefreshGPHRows(panel, view, src, DB, ADB)
        -- Seven rows; loot counts move them without changing the token.
        WC_RefreshDayRows(panel, ADB)
    end
end

-- v2.38.1: view-aware Reset Lifetime. Character view clears this
-- character's DB.* lifetime totals (existing behaviour). Account view
-- clears the ADB.accountStats.* aggregate (every character's
-- contribution since v2.38.1 install). Both wipe the Best GPH triple
-- on their respective side.
function NS.ResetLifetimeStats()
    local panel = _G["WoWClearanceOptionsStats"]
    local view = (panel and panel._statsView) or "character"
    if view == "account" then
        local ADB = NS.ADB
        local AS = ADB and ADB.accountStats
        if not AS then
            return
        end
        AS.totalCopper = 0
        AS.totalItemsSold = 0
        AS.totalItemsDeleted = 0
        AS.totalRepairs = 0
        AS.totalRepairCopper = 0
        AS.totalLootCopper = 0
        if AS.daily then
            wipe(AS.daily)
        end
        if AS.soldItemCounts then
            wipe(AS.soldItemCounts)
        end
        if AS.deletedItemCounts then
            wipe(AS.deletedItemCounts)
        end
        if AS.soldItemsByQuality then
            wipe(AS.soldItemsByQuality)
        end
        if AS.soldCopperByQuality then
            wipe(AS.soldCopperByQuality)
        end
        if AS.deletedItemsByQuality then
            wipe(AS.deletedItemsByQuality)
        end
        if AS.processCastCounts then
            wipe(AS.processCastCounts)
        end
        if AS.copperByZone then
            wipe(AS.copperByZone)
        end
        AS.bestGPH = 0
        AS.bestGPHAt = 0
        AS.bestGPHZone = ""
        AS.bestGPHChar = ""
        AS.startedAt = time()
        return
    end
    -- Character view: clear DB.* (per-character).
    local DB = NS.DB
    if not DB then
        return
    end
    DB.totalCopper = 0
    DB.totalItemsSold = 0
    DB.totalItemsDeleted = 0
    DB.totalRepairs = 0
    DB.totalRepairCopper = 0
    DB.totalLootCopper = 0
    DB.inventoryWorthTotal = 0
    DB.inventoryWorthCount = 0
    wipe(DB.soldItemCounts)
    wipe(DB.deletedItemCounts)
    if DB.soldItemsByQuality then
        wipe(DB.soldItemsByQuality)
    end
    if DB.soldCopperByQuality then
        wipe(DB.soldCopperByQuality)
    end
    if DB.deletedItemsByQuality then
        wipe(DB.deletedItemsByQuality)
    end
    if DB.processCastCounts then
        wipe(DB.processCastCounts)
    end
    if DB.copperByZone then
        wipe(DB.copperByZone)
    end
    -- v2.35.x: Reset Lifetime wipes the GPH best record too.
    -- The user is opting in to a full lifetime reset; per the
    -- spec (docs/specs/2026-05-26-gph-stats-design.md) the
    -- best record is part of lifetime state and goes with it.
    DB.bestGPH = 0
    DB.bestGPHAt = 0
    DB.bestGPHZone = ""
end


local function BuildMainPanel(panel, content)
    -- v2.12.0: widgets are created on `content` (the scroll-frame child)
    -- so vertical overflow is handled by the scroll bar.
    -- v2.36.x: stats widgets + Reset buttons moved to the Stats sub-panel
    -- (WoWClearance_StatsPanel.lua); the `panel` arg is unused here now
    -- but kept in the signature because WC_compCache.initPanel passes it.
    local addonVersion = NS.GetVersion()
    local heading = NS.MakeHeader(content, "WoWClearance " .. addonVersion, -16)
    NS.AddHelpIcon(content, heading, "LEFT", "RIGHT", 8, 0, "what-does-ec-do")

    -- Byline (required by LICENSE; do not remove in derivatives).
    local byline = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    byline:SetPoint("TOPLEFT", 16, -32)
    byline:SetText("|cff888888by " .. NS.ADDON_AUTHOR .. "  \194\183  " .. NS.ADDON_URL .. "|r")

    -- v2.76.0 (Serv report): the old "Welcome to WoWClearance" greeting is
    -- gone - it only restated the panel heading and the byline above it, so
    -- the description opens the panel directly.
    local descLabel2 = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    descLabel2:SetPoint("TOPLEFT", 16, -52)
    WC_compCache.setPanelWidth(descLabel2, 16)
    descLabel2:SetJustifyH("LEFT")
    descLabel2:SetJustifyV("TOP")
    if descLabel2.SetWordWrap then
        descLabel2:SetWordWrap(true)
    end
    descLabel2:SetText(
        L["Out of the box it sells your junk and old gear when you visit a merchant, keeps your upgrades, and never touches anything important.\n\n"]
            .. L["Want more control?\n"]
            .. L["  |cffb6ffb6Sell List|r - items you want sold every time.\n"]
            .. L["  |cffb6ffb6Keep List|r - items the addon should never touch.\n"]
            .. L["  |cffb6ffb6Merchant Settings|r - change what counts as old gear.\n"]
            -- v0.5.6 (Serv report): this used to name milling and
            -- prospecting unconditionally. Neither exists on WoW: Forever,
            -- so the addon was advertising skills the game cannot teach.
            -- Built from the modes actually present, so the sentence cannot
            -- drift from the toggles the Process Bags panel offers.
            .. string.format(
                L["  |cffb6ffb6Process Bags|r - one button to %s."],
                (WC_compCache.processModeVerbList and WC_compCache.processModeVerbList())
                    or L["process items in your bags"]
            )
    )

    -- v2.39.1: master Enable toggle on the Main panel. The flag
    -- (DB.enabled) gates the sell engine, auto-loot,
    -- auto-open, tooltip annotations, and post-merchant cleanup, but
    -- pre-v2.39.1 the only ways to flip it were the minimap
    -- right-click, a Bindings.xml keybind, or the global Lua function
    -- - none of which a confused player thinks to try when the addon
    -- "stopped working" (real bug report: v2.39.0, Paladin, ticket
    -- relayed via Discord). Putting the checkbox at the top of the
    -- panel that players DO check makes the disabled state recoverable
    -- from the first place they look. The setter routes through
    -- WoWClearance_ToggleEnabled() so the chat message + sound stay
    -- identical across all three entry points (minimap, keybind,
    -- panel checkbox).
    local enableCB = NS.AddCheckbox(
        content,
        "WoWClearanceMainEnableCB",
        descLabel2,
        L["Enable WoWClearance"],
        function()
            return NS.DB and NS.DB.enabled ~= false
        end,
        function(v)
            local newState = v and true or false
            local curr = (NS.DB and NS.DB.enabled ~= false) and true or false
            if curr ~= newState and WoWClearance_ToggleEnabled then
                WoWClearance_ToggleEnabled()
            end
        end,
        -14
    )
    -- Store on the panel so the OnShow re-sync can refresh the
    -- checkbox state after a minimap-right-click or /wc enable that
    -- happened while the panel was hidden.
    panel.enableCB = enableCB

    -- v2.38.0: Quickstart entry row. Button + one-line nudge so returning
    -- players can find the guided setup wizard any time. Fresh installs
    -- get the wizard opened automatically at PLAYER_LOGIN; this row is the
    -- way back in.
    local quickstartBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    quickstartBtn:SetSize(140, 26)
    quickstartBtn:SetPoint("TOPLEFT", enableCB, "BOTTOMLEFT", 0, -10)
    quickstartBtn:SetText(L["Open Quickstart"])
    quickstartBtn:SetScript("OnClick", function()
        local qf = _G["WoWClearanceOptionsQuickstart"]
        if qf and qf.Show then
            qf:Show()
        end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    local quickstartHint = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    quickstartHint:SetPoint("LEFT", quickstartBtn, "RIGHT", 10, 0)
    quickstartHint:SetJustifyH("LEFT")
    if quickstartHint.SetWordWrap then
        quickstartHint:SetWordWrap(true)
    end
    WC_compCache.setPanelWidth(quickstartHint, 180)
    quickstartHint:SetText(L["|cff888888New here? Pick a preset or answer a few questions for a guided setup.|r"])

    -- v2.44.0: Current Rules button. Surfaces every active toggle +
    -- the precedence order WC uses to decide DELETE / SELL / KEEP,
    -- in plain English with the player's labels. Sits directly under
    -- Open Quickstart so the two complementary entry points (set up
    -- vs. inspect) are visually grouped. Opens the same copy-frame
    -- pattern /wc bugreport / /wc processdebug
    -- use, so the player can also paste the summary into chat or
    -- Discord when asking for help.
    local rulesBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    rulesBtn:SetSize(140, 26)
    rulesBtn:SetPoint("TOPLEFT", quickstartBtn, "BOTTOMLEFT", 0, -8)
    rulesBtn:SetText(L["Current Rules"])
    rulesBtn:SetScript("OnClick", function()
        if NS.ShowRuleSummary then
            NS.ShowRuleSummary()
        end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    local rulesHint = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    rulesHint:SetPoint("LEFT", rulesBtn, "RIGHT", 10, 0)
    rulesHint:SetJustifyH("LEFT")
    if rulesHint.SetWordWrap then
        rulesHint:SetWordWrap(true)
    end
    WC_compCache.setPanelWidth(rulesHint, 180)
    rulesHint:SetText(L["|cff888888See every active rule, in the order they are checked.|r"])

    -- Sold History button. Opens the copyable session log of what was sold /
    -- deleted this login and why. Same style + placement pattern as the
    -- Quickstart / Current Rules buttons above it.
    local historyBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    historyBtn:SetSize(140, 26)
    historyBtn:SetPoint("TOPLEFT", rulesBtn, "BOTTOMLEFT", 0, -8)
    historyBtn:SetText(L["Sold History"])
    historyBtn:SetScript("OnClick", function()
        if NS.ShowSessionHistory then
            NS.ShowSessionHistory()
        end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    local historyHint = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    historyHint:SetPoint("LEFT", historyBtn, "RIGHT", 10, 0)
    historyHint:SetJustifyH("LEFT")
    if historyHint.SetWordWrap then
        historyHint:SetWordWrap(true)
    end
    WC_compCache.setPanelWidth(historyHint, 180)
    historyHint:SetText(L["|cff888888What was sold or deleted on this character, and why. Saved between sessions.|r"])

    -- Loot Log button. Same opener as the Stats - Personal panel's button
    -- (NS.ToggleLootWindow, also reachable via /wc loot); placed here so
    -- the two session windows (Sold History + Loot Log) sit together.
    local lootLogBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    lootLogBtn:SetSize(140, 26)
    lootLogBtn:SetPoint("TOPLEFT", historyBtn, "BOTTOMLEFT", 0, -8)
    lootLogBtn:SetText(L["Loot Log"])
    lootLogBtn:SetScript("OnClick", function()
        if NS.ToggleLootWindow then
            NS.ToggleLootWindow()
        end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    local lootLogHint = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    lootLogHint:SetPoint("LEFT", lootLogBtn, "RIGHT", 10, 0)
    lootLogHint:SetJustifyH("LEFT")
    if lootLogHint.SetWordWrap then
        lootLogHint:SetWordWrap(true)
    end
    WC_compCache.setPanelWidth(lootLogHint, 180)
    lootLogHint:SetText(L["|cff888888Everything looted this session, plus your account-wide totals.|r"])

    -- Tip on its own line, in grey, so it reads as a hint rather than
    -- another sentence in the main description block.
    local mainTip = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    mainTip:SetPoint("TOPLEFT", lootLogBtn, "BOTTOMLEFT", 0, -14)
    WC_compCache.setPanelWidth(mainTip, 16)
    mainTip:SetJustifyH("LEFT")
    mainTip:SetJustifyV("TOP")
    if mainTip.SetWordWrap then
        mainTip:SetWordWrap(true)
    end
    mainTip:SetText(L["|cff888888Right-click any bag item with Alt held for quick actions.|r"])

    -- Update-available nudge toggle. Anchored below mainTip; cmdHeader
    -- re-anchors to this checkbox so the layout chain stays intact.
    local versionAlertCB = NS.AddCheckbox(
        content,
        "WoWClearanceVersionAlertCB",
        mainTip,
        L["Tell me when an update is available"],
        function()
            -- versionAlerts is an account-level field on the top-level
            -- SavedVariables (not per-character), so read it directly rather
            -- than via a panel DB upvalue this builder does not have.
            return WoWClearanceDB and WoWClearanceDB.versionAlerts
        end,
        function(v)
            if WoWClearanceDB then
                WoWClearanceDB.versionAlerts = v
            end
        end,
        -14
    )

    -- v2.66.1 iter 2 (Serv report): notice appears BELOW the checkbox on
    -- its own line, only when an update is detected. Widgets below
    -- (minimapButtonCB, warnConflictCB, cmdHeader) dynamically re-anchor
    -- to either the notice text (update available) or the checkbox
    -- itself (on latest), so on-latest state closes the notice slot
    -- entirely.
    -- v2.66.1 iter 3 (Serv report): FontString is a direct child of
    -- content (no wrapper frame). Earlier iterations wrapped the notice
    -- in a Frame that toggled between height 0 and 16, but SetHeight(0)
    -- on the wrapper broke the anchor chain for widgets below on the
    -- user's client - the whole panel below the checkbox vanished when
    -- no update was available. Direct FontString + dynamic re-anchor of
    -- minimapButtonCB avoids the zero-height frame entirely.
    local versionNotice = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    versionNotice:SetPoint("TOPLEFT", versionAlertCB, "BOTTOMLEFT", 26, -2)
    versionNotice:SetJustifyH("LEFT")
    versionNotice:SetText("")
    versionNotice:Hide()

    -- v2.44.7: show / hide the WC minimap button. Workaround for clashes
    -- with minimap-replacement / magnifier addons (Magnify-WotLK was the
    -- trigger). WC stays fully functional with the button hidden via the
    -- LDB launcher, slash commands, and key bindings.
    local minimapButtonCB = NS.AddCheckbox(
        content,
        "WoWClearanceMinimapButtonCB",
        versionAlertCB,
        L["Show the WoWClearance minimap button"],
        function()
            return DB and DB.minimapButton ~= false
        end,
        function(v)
            if NS.SetMinimapButtonVisible then
                NS.SetMinimapButtonVisible(v)
            elseif DB then
                DB.minimapButton = v and true or false
            end
        end,
        -2
    )

    -- Now that minimapButtonCB exists, define the refresh that also
    -- re-anchors the widget below the notice when an update is available.
    -- The default anchor was set at build time (versionAlertCB.BOTTOMLEFT
    -- -2); when a peer version is heard, we re-anchor to sit below the
    -- notice line instead.
    NS._refreshVersionNotice = function()
        local latest = (NS.Comms and NS.Comms.GetLatestPeerVersion) and NS.Comms.GetLatestPeerVersion() or nil
        minimapButtonCB:ClearAllPoints()
        if latest then
            versionNotice:SetText(string.format(L["|cffffff00Update available: %s|r"], latest))
            versionNotice:Show()
            minimapButtonCB:SetPoint("TOPLEFT", versionNotice, "BOTTOMLEFT", -26, -4)
        else
            versionNotice:SetText("")
            versionNotice:Hide()
            minimapButtonCB:SetPoint("TOPLEFT", versionAlertCB, "BOTTOMLEFT", 0, -2)
        end
    end
    NS._refreshVersionNotice()

    -- v2.49.2: conflicting-addon warning opt-out. Sits with the other
    -- global toggles (version alert / minimap button) rather than in
    -- Delete Settings - it's an informational preference, not a delete
    -- rule. Per-character NS.DB.warnConflictingAddons; default on. When on
    -- (and WC's delete path is active), a popup at login flags a
    -- third-party auto-delete addon running alongside WC. Neutral label
    -- per project rule; the other addon is never named.
    -- WC-TRAP: read/write NS.DB fully-qualified, NOT a bare `DB`.
    -- BuildMainPanel has no `DB` upvalue (the file-local `DB` at the top
    -- belongs to a sibling function that ends before this one), so bare
    -- `DB` resolves to the nil global and the toggle silently fails to
    -- persist - the tick reverts on /reload. enableCB above uses the
    -- same NS.DB pattern for this reason.
    local warnConflictCB = NS.AddCheckbox(
        content,
        "WoWClearanceWarnConflictingAddonsCB",
        minimapButtonCB,
        L["Warn about conflicting addons"],
        function()
            return NS.DB and NS.DB.warnConflictingAddons ~= false
        end,
        function(v)
            if NS.DB then
                NS.DB.warnConflictingAddons = v and true or false
            end
        end,
        -2
    )

    -- DaylightUI look (WoWClearance_Daylight.lua). Saved in
    -- WoWClearanceDB.daylightLook (nil = on). Disabled without DaylightUI.
    local hasDaylight = _G.DaylightUI ~= nil
    local daylightCB = NS.AddCheckbox(
        content,
        "WoWClearanceDaylightLookCB",
        warnConflictCB,
        L["Use DaylightUI look"],
        function()
            return not (WoWClearanceDB and WoWClearanceDB.daylightLook == false)
        end,
        function(v)
            if WoWClearanceDB then
                WoWClearanceDB.daylightLook = v and true or false
            end
        end,
        -2
    )
    local daylightDesc = hasDaylight and L["Needs DaylightUI. Takes a /reload to switch back."]
        or L["Needs DaylightUI. Takes a /reload to switch back."] .. " (DaylightUI is not installed.)"
    if not hasDaylight then
        daylightCB:Disable()
    end
    daylightCB:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L["Use DaylightUI look"], 1, 1, 1)
        GameTooltip:AddLine(daylightDesc, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    daylightCB:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)


    -- v2.12.0: size the scroll content to fit the bottom-most widget so
    -- the scroll bar engages when the Interface Options frame is too
    -- short to show everything (matches the Merchant /
    -- Profiles / Import-Export panels' pattern).
    -- v0.5.7: the bag-closing note lives HERE, at the end of the anchor
    -- chain, not pinned to the content's BOTTOMLEFT. Pinned, it drew on top
    -- of whatever the last widget happened to be - reported as the bottom of
    -- the panel overlapping itself.
    --
    -- Shown ONLY while this panel is hosted inside Blizzard's Settings
    -- window, where opening a page calls CloseAllBags. The standalone window
    -- has no such limitation, so the warning would be false there.
    local hostNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    hostNote:SetPoint("TOPLEFT", daylightCB, "BOTTOMLEFT", 0, -14)
    WC_compCache.setPanelWidth(hostNote, 16)
    hostNote:SetJustifyH("LEFT")
    if hostNote.SetWordWrap then
        hostNote:SetWordWrap(true)
    end
    hostNote:SetText(
        L["|cffffd100Note:|r Opening this window from the game menu closes your bags - that is how the game's own settings window behaves, not something this addon can change.\n"]
            .. L["To see your bags while you change settings, open WoWClearance with |cffb6ffb6/wc|r or the minimap button instead."]
    )
    panel.hostNote = hostNote
    -- Set the initial state HERE as well as in the refresh pass. initPanel
    -- runs build OR refresh, never both, so a note whose visibility was only
    -- decided on refresh stayed visible for the whole of the first open -
    -- which is exactly how it appeared in the standalone window, where it is
    -- not true.
    hostNote:SetShown(not (NS.StandaloneHost and NS.StandaloneHost() ~= nil))

    NS.FitScrollContent(content, hostNote)
end

MainOptions:SetScript("OnShow", function(self)
    -- RefreshStats / ResetLifetimeStats live on NS at file scope (see
    -- top of this file) and write to the Stats sub-panel via
    -- _G["WoWClearanceOptionsStats"]. The Main panel no longer renders
    -- stats itself (v2.36.x split), but we still trigger a refresh on
    -- show so the Stats panel stays up to date when users tab over.
    -- v2.39.1: also re-sync the Enable checkbox so a minimap-driven or
    -- slash-driven toggle that happened while the panel was hidden
    -- shows the current state when the player reopens the panel.
    WC_compCache.initPanel(self, function(refreshSelf)
        -- v0.5.3: the bag-closing note is relevant only in the Settings
        -- host. The panel is reparented between hosts at runtime, so this
        -- is decided per show rather than once at build.
        if refreshSelf.hostNote then
            local inStandalone = NS.StandaloneHost and NS.StandaloneHost() ~= nil
            refreshSelf.hostNote:SetShown(not inStandalone)
        end
        if NS.RefreshStats then
            NS.RefreshStats()
        end
        if refreshSelf.enableCB then
            refreshSelf.enableCB:SetChecked(NS.DB and NS.DB.enabled ~= false)
        end
        -- v2.66.1 iter: refresh the "Latest available" notice on panel
        -- show so a peer version detected while the panel was hidden
        -- surfaces the next time the player opens the panel.
        if NS._refreshVersionNotice then
            NS._refreshVersionNotice()
        end
    end, function(buildSelf, content)
        -- v2.12.0: scroll-wrap the Main panel so the Slash Commands block
        -- at the bottom doesn't overlap the OK/Cancel button strip when
        -- the Interface Options frame is shorter than the panel content.
        -- Merchant Settings is wrapped the same way.
        BuildMainPanel(buildSelf, content)
        if NS.RefreshStats then
            NS.RefreshStats()
        end
    end, true)
end)

-- v0.5.5 (Serv request): the slash-command reference moved OUT of the main
-- panel and onto the Settings launcher page. It is read-once reference
-- material, so it was taking permanent space in the working window while
-- the launcher page sat nearly empty.
--
-- MOVED, not copied. There is exactly one definition of the command list,
-- and it lives here because this file already owns it. Returns the LAST
-- widget anchored, so the caller finishes its own scroll sizing from there.
function NS.BuildSlashCommandList(content, firstAnchor)
    -- Slash commands reference.
    -- Stats widgets + Reset buttons moved to WoWClearance_StatsPanel.lua
    -- in v2.36.x; this anchor chain now goes mainTip -> versionAlertCB ->
    -- minimapButtonCB -> warnConflictCB -> cmdHeader.
    local cmdHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    cmdHeader:SetPoint("TOPLEFT", firstAnchor, "BOTTOMLEFT", 0, -20)
    cmdHeader:SetText(L["Slash Commands"])

    -- v2.37.6: per-row slash command list. Each row gets a [Run] button
    -- when the command works without arguments (or with the safe default
    -- form). Argument-required commands (profile) stay
    -- text-only: a single button can't pick a sub-command for the user.
    -- Labels start at the same x regardless of whether the row has a
    -- button, so the two columns line up.

    -- v2.49.0: heading rows (heading = "..." field) group commands under
    -- a thin gold divider + section label so the list scans as
    -- Basics / Profiles / Cleanup / Windows / Diagnostics
    -- rather than one long undifferentiated run.
    local SLASH_ROWS = {
        { heading = L["Basics"] },
        { label = "|cffffff00/wc|r  " .. L["Open settings |cffaaaaaa(you are here)|r"] },
        {
            run = "status",
            label = "|cffffff00/wc status|r  " .. L["Is WoWClearance currently on or off?"],
        },
        {
            run = "enable",
            label = "|cffffff00/wc enable|r  " .. L["Turn WoWClearance on"],
        },
        {
            run = "disable",
            label = "|cffffff00/wc disable|r  " .. L["Turn WoWClearance off"],
        },
        { heading = L["Profiles"] },
        { run = "profile list", label = "|cffffff00/wc profile list|r  " .. L["Show your saved List Profiles"] },
        {
            prefill = "/wc profile ",
            label = "|cffffff00/wc profile [save|load|delete] <name>|r  "
                .. L["Manage List Profiles by name |cffaaaaaa(or use the List Profiles panel)|r"],
        },
        { run = "sprofile list", label = "|cffffff00/wc sprofile list|r  " .. L["Show your Settings Profiles"] },
        {
            prefill = "/wc sprofile ",
            label = "|cffffff00/wc sprofile [save|use|delete] <name>|r  "
                .. L["Manage Settings Profiles by name |cffaaaaaa(or use the Settings Profiles panel)|r"],
        },
        { heading = L["Lists cleanup"] },
        {
            run = "clean",
            label = "|cffffff00/wc clean|r  " .. L["Find items on more than one list |cffaaaaaa(add 'apply' to fix)|r"],
        },
        {
            run = "clean upgrades",
            label = "|cffffff00/wc clean upgrades|r  "
                .. L["Find old 'Upgrade'-tagged Keep List items |cffaaaaaa(add 'apply' to remove)|r"],
        },
        { heading = L["Windows & reports"] },
        {
            run = "loot",
            label = "|cffffff00/wc loot|r  " .. L["Open the Loot Log window"],
        },
        {
            run = "rules",
            label = "|cffffff00/wc rules|r  "
                .. L["See every active rule + the order WC applies them"],
        },
        {
            run = "highlight",
            label = "|cffffff00/wc highlight|r  " .. L["Turn all item highlighting on or off"],
        },
        {
            run = "history",
            label = "|cffffff00/wc history|r  "
                .. L["See what was sold or deleted this session, and why"],
        },
        {
            -- v2.44.7: `||` renders as a literal pipe inside a WoW UI font
            -- string. A single `|r` would terminate the |cffffff00 colour
            -- block and the trailing "eset" would render in the default
            -- colour (rendered as "on|offeset" until this fix).
            prefill = "/wc minimap ",
            label = "|cffffff00/wc minimap on||off||reset|r  "
                .. L["Show, hide, or re-centre the WC minimap button"],
        },
        {
            run = "bugreport",
            label = "|cffffff00/wc bugreport|r  " .. L["Generate a report to share when something's wrong"],
        },
        { heading = L["Diagnostics"] },
        {
            prefill = "/wc scandebug ",
            label = "|cffffff00/wc scandebug <bag> <slot>|r  "
                .. L["Diagnostic: dump the scan tooltip lines for a bag slot"],
        },
        {
            run = "processdebug",
            label = "|cffffff00/wc processdebug|r  " .. L["Diagnose items missing from Process Bags"],
        },
        {
            run = "processdebug clear",
            label = "|cffffff00/wc processdebug clear|r  " .. L["Wipe Process Bags cache (force fresh tooltip scans)"],
        },
        { run = "perf", label = "|cffffff00/wc perf|r  " .. L["Show WC's memory, CPU, cache and list sizes"] },
        {
            run = "spike",
            label = "|cffffff00/wc spike|r  " .. L["Show the worst and most recent frame hitches WC caused, and WC's share of each"],
        },
    }

    -- Layout strategy: each label is its OWN FontString with setPanelWidth,
    -- so when the panel scales the label re-wraps and its height grows /
    -- shrinks naturally. The Run button anchors to the label's TOPLEFT
    -- (offset to the left of the label column), so a label that wraps to
    -- 2+ lines doesn't push the button down - the button stays aligned
    -- with the first line. The next row anchors to the previous label's
    -- BOTTOMLEFT, so wrapping pushes everything below it down cleanly.
    local LABEL_COL_X = 70 -- button width (64) + 6 px gap; labels start at this x
    local PANEL_RIGHT_PAD = 16 -- same right margin the original cmdText used
    local prevAnchor = cmdHeader
    -- v2.49.0: track prev anchor's x-offset in content so we can flip
    -- heading rows (which span the full width from x=0) and command
    -- rows (which sit indented at LABEL_COL_X) without either staircasing
    -- or unindenting after a heading. cmdHeader lives at x=0; any command
    -- label or heading label lives at x=LABEL_COL_X.
    local prevX = 0
    for i, row in ipairs(SLASH_ROWS) do
        if row.heading then
            -- Section divider: thin gold line spanning the full content
            -- width + a gold GameFontNormal label indented into the label
            -- column so it aligns with the command rows beneath it.
            local topGap = (prevAnchor == cmdHeader) and -8 or -16
            local divider = content:CreateTexture(nil, "ARTWORK")
            -- WC-TRAP: SetTexture(r,g,b,a) draws a solid colour on 3.3.5a.
            -- Do NOT "fix" this to SetColorTexture (does not exist here).
            -- Matches the ListWidget divider colour so the visual family
            -- stays consistent across panels.
            -- v0.5.8: SetColorTexture, not SetTexture(r,g,b,a). The in-game widget
            -- probe reports SetTexture with colour args as "accepted (may still
            -- no-op)" on this client - it does not error, so nothing would ever have
            -- told us whether this line drew. SetColorTexture is confirmed present and
            -- is the call that means what this line intends. A divider that silently
            -- fails to draw is invisible in exactly the way a missing divider is.
            divider:SetColorTexture(0.4, 0.35, 0.25, 0.8)
            divider:SetHeight(1)
            divider:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", -prevX, topGap)
            WC_compCache.setPanelWidth(divider, PANEL_RIGHT_PAD)

            local head = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            head:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", LABEL_COL_X, -6)
            head:SetText("|cffffd870" .. row.heading .. "|r")

            prevAnchor = head
            prevX = LABEL_COL_X
        else
            local gap = (i == 1) and -8 or -10
            -- xOffset re-establishes the LABEL_COL_X indent whenever
            -- prevAnchor sits at x=0 (i.e. cmdHeader before the first
            -- row); anything else already lives in the label column.
            local xOffset = LABEL_COL_X - prevX

            local fs = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            fs:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", xOffset, gap)
            fs:SetJustifyH("LEFT")
            if fs.SetWordWrap then
                fs:SetWordWrap(true)
            end
            -- Width = panel width - (left inset for label column) - (right pad).
            -- setPanelWidth subtracts the given xOffset from WC_PANEL_WIDTH and
            -- re-applies on resize, so the wrapped height tracks panel scale.
            WC_compCache.setPanelWidth(fs, LABEL_COL_X + PANEL_RIGHT_PAD)
            fs:SetText(row.label)

            if row.run or row.prefill then
                local btn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
                btn:SetSize(64, 20)
                -- LEFT-to-LEFT vertically-centres the button against the
                -- label's centre line, so single-line labels (the common
                -- case) read as perfectly aligned. The button still sits in
                -- the column to the left of the label via -LABEL_COL_X.
                -- For a wrapped multi-line label, the button centres on the
                -- whole wrapped block, which is acceptable visual drift.
                btn:SetPoint("LEFT", fs, "LEFT", -LABEL_COL_X, 0)
                btn:SetText(row.run and L["Run"] or L["How"])
                if row.run then
                    local runCmd = row.run
                    btn:SetScript("OnClick", function()
                        local handler = SlashCmdList and SlashCmdList["WOWCLEARANCE"]
                        if handler then
                            handler(runCmd)
                        end
                        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
                    end)
                else
                    -- v2.49.1: `prefill` variant. Rows whose command requires
                    -- arguments (profile save/load/delete, scandebug bag slot,
                    -- autolearnsim itemID spellID, minimap on/off/reset) can't
                    -- fire directly - the user has to type the missing pieces.
                    -- The button prints what to type. Opening the chat box from
                    -- addon code would taint it (and secure commands typed in
                    -- it later), so the player types the command themselves.
                    local prefillCmd = row.prefill
                    btn:SetScript("OnClick", function()
                        NS.PrintNicef(L["Type: %s"], prefillCmd)
                        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
                    end)
                end
            end

            prevAnchor = fs
            prevX = LABEL_COL_X
        end
    end
    return prevAnchor
end
