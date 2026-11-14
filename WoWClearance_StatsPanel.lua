-- WoWClearance_StatsPanel - dedicated stats sub-panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Holds every stat widget (statsMoney, statsSold, statsDeleted, statsRepairs,
-- statsRepairCost, statsSessionGPH, statsBestGPH + zone/when sub-line,
-- statsAvgWorth, statsMostSold, statsNote, WoWClearanceResetStatsBtn).
-- These used to live on the Main panel; v2.36.x split them out so the Main
-- panel can read as a welcome page and Stats can grow.
--
-- RefreshStats (defined in WoWClearance_MainPanel.lua pre-split; re-homed
-- here post-split) writes to the panel.statsX attachments below. The
-- attachments are the public contract with the rest of the addon:
-- WoWClearance_Events.lua's data-change handlers call RefreshStats; this
-- file owns the panel object that holds the FontStrings.

local NS = select(2, ...)
local GetCoinTextureString = C_CurrencyInfo.GetCoinTextureString
local GetItemInfo = C_Item.GetItemInfo
local GetContainerItemID = C_Container.GetContainerItemID
local GetContainerNumSlots = C_Container.GetContainerNumSlots
local WC_compCache = NS.compCache
local L = NS.L

local StatsPanel = CreateFrame("Frame", "WoWClearanceOptionsStats", NS.OptionsHost())
StatsPanel.name = "Stats - Personal"
StatsPanel.parent = "WoWClearance"

-- v2.38.2: live refresh while the Stats panel is shown. RefreshStats
-- otherwise only fires on OnShow + after the GetItemInfo warmup, so the
-- panel goes static the moment the player opens it - they sell more
-- items, lifetime + session totals keep updating in memory, but the
-- displayed numbers stay frozen until the panel is closed and reopened.
-- v2.38.1's new "(session +N)" delta suffix made the static display
-- glaringly obvious because the suffix sits next to the lifetime total.
-- A 1Hz OnUpdate driver (cheap: one script call/sec, gated on visibility)
-- repaints while the panel is shown.
StatsPanel:SetScript("OnUpdate", function(self, elapsed)
    self._statsTickAcc = (self._statsTickAcc or 0) + elapsed
    if self._statsTickAcc >= 1.0 then
        self._statsTickAcc = 0
        -- v2.68.1: the tick routes through RefreshStatsTick, which
        -- full-repaints only when a rendered counter actually changed and
        -- otherwise refreshes just the time-varying Gold/Hour rows. The
        -- old unconditional NS.RefreshStats() rewrote ~40 FontStrings and
        -- re-anchored 6 section headers every second for nothing.
        if self:IsShown() then
            if NS.RefreshStatsTick then
                NS.RefreshStatsTick()
            elseif NS.RefreshStats then
                NS.RefreshStats()
            end
        end
    end
end)

StatsPanel:SetScript("OnShow", function(self)
    WC_compCache.initPanel(self, function(refreshSelf)
        if NS.RefreshStats then
            NS.RefreshStats()
        end
    end, function(buildSelf, content)
        -- Alias buildSelf as `panel` so the explicit panel.statsX = fs
        -- assignments below stay literal. The test suite scans for
        -- `panel.statsMoney`, `panel.statsSessionGPH`, `panel.statsBestGPH`
        -- as the public contract with RefreshStats - keep the literals.
        local panel = buildSelf
        -- Heading. Same -16 y offset as Keep List / Sell List etc.
        local heading = NS.MakeHeader(content, L["Stats - Personal"], -16)
        NS.AddHelpIcon(content, heading, "LEFT", "RIGHT", 8, 0, "stats-overview")

        -- v2.38.1: Character / Account view toggle. Sits between the
        -- heading and the first stat row. Two UIRadioButtonTemplate
        -- buttons + a one-line started-at note for the account ledger.
        -- _statsView is in-memory only - opens on Character view every
        -- time the panel shows.
        panel._statsView = panel._statsView or "character"

        local charRadio = CreateFrame("CheckButton", nil, content, "UIRadioButtonTemplate")
        charRadio:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -8)
        charRadio:SetChecked(panel._statsView == "character")
        local charLbl = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        charLbl:SetPoint("LEFT", charRadio, "RIGHT", 4, 0)
        charLbl:SetText(L["Character"])

        local acctRadio = CreateFrame("CheckButton", nil, content, "UIRadioButtonTemplate")
        acctRadio:SetPoint("LEFT", charLbl, "RIGHT", 16, 0)
        acctRadio:SetChecked(panel._statsView == "account")
        local acctLbl = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        acctLbl:SetPoint("LEFT", acctRadio, "RIGHT", 4, 0)
        acctLbl:SetText(L["Account"])

        charRadio:SetScript("OnClick", function()
            panel._statsView = "character"
            charRadio:SetChecked(true)
            acctRadio:SetChecked(false)
            if NS.RefreshStats then
                NS.RefreshStats()
            end
            if panel._updateResetLabel then
                panel._updateResetLabel()
            end
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
        acctRadio:SetScript("OnClick", function()
            panel._statsView = "account"
            charRadio:SetChecked(false)
            acctRadio:SetChecked(true)
            if NS.RefreshStats then
                NS.RefreshStats()
            end
            if panel._updateResetLabel then
                panel._updateResetLabel()
            end
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)

        -- Started-at note. Reads ADB.accountStats.startedAt and formats
        -- as a date string so the player understands the account ledger
        -- counts from v2.38.1 install, not from their full history.
        local startedAtNote = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        startedAtNote:SetPoint("TOPLEFT", charRadio, "BOTTOMLEFT", 0, -4)
        WC_compCache.setPanelWidth(startedAtNote, 16)
        startedAtNote:SetJustifyH("LEFT")
        if startedAtNote.SetWordWrap then
            startedAtNote:SetWordWrap(true)
        end
        local function refreshStartedAt()
            local ADB = NS.ADB
            local AS = ADB and ADB.accountStats
            local startedAt = AS and AS.startedAt or 0
            if startedAt > 0 then
                startedAtNote:SetText(
                    string.format(
                        L["|cff888888Account totals counting from %s. Older history stays on Character view.|r"],
                        date("%Y-%m-%d", startedAt)
                    )
                )
            else
                startedAtNote:SetText("")
            end
        end
        refreshStartedAt()
        panel._refreshStartedAt = refreshStartedAt

        -- Loot Log opener. Sits near the top (right under the view toggle)
        -- so it's easy to find rather than buried below the stat stack.
        -- Opens the standalone loot window (also reachable via /wc loot):
        -- what you've looted this session and the account-wide running
        -- total. Styled like the Main panel's Open Quickstart button.
        local lootBtn = CreateFrame("Button", "WoWClearanceOpenLootBtn", content, "UIPanelButtonTemplate")
        lootBtn:SetSize(140, 26)
        lootBtn:SetPoint("TOPLEFT", startedAtNote, "BOTTOMLEFT", 0, -10)
        lootBtn:SetText(L["Loot Log"])
        lootBtn:SetScript("OnClick", function()
            if NS.ToggleLootWindow then
                NS.ToggleLootWindow()
            end
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
        local lootHint = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        lootHint:SetPoint("LEFT", lootBtn, "RIGHT", 10, 0)
        lootHint:SetJustifyH("LEFT")
        if lootHint.SetWordWrap then
            lootHint:SetWordWrap(true)
        end
        WC_compCache.setPanelWidth(lootHint, 180)
        lootHint:SetText(L["|cff888888What you've looted this session, or account-wide.|r"])

        -- Lifetime + session stats. Each panel.statsX is the contract
        -- with RefreshStats (called from WoWClearance_Events.lua's data
        -- handlers). Order matches the old MainPanel layout for visual
        -- continuity. The explicit panel.statsX = fs assignments below
        -- are the contract the test suite scans for - keep them literal
        -- (no table-driven indirection) so the static-pattern check can
        -- find them.
        -- v2.66.1 iter (Serv report): aggregate rows now use NS.MakeStatRow
        -- (row.left / row.right) so the value column aligns at a fixed X -
        -- matches Stats - Guild / Stats - Server. RefreshStats writes to
        -- row.left (label) and row.right (formatted value) instead of a
        -- single :SetText on the FontString.
        local AGGREGATE_VALUE_X = 200
        local function makeStatRow(yOffset, anchorPrev)
            return NS.MakeStatRow(content, anchorPrev, yOffset, AGGREGATE_VALUE_X)
        end

        -- v2.38.1: first stat row anchors below the started-at note now
        -- (was -44 from content TOPLEFT, which assumed the heading was
        -- the only thing above the stats).
        local money = makeStatRow(-16, lootBtn)
        panel.statsMoney = money
        -- v0.7.0: coin picked up from loot windows.
        local lootCoin = makeStatRow(-6, money)
        panel.statsLootCoin = lootCoin
        local sold = makeStatRow(-6, lootCoin)
        panel.statsSold = sold
        local deleted = makeStatRow(-6, sold)
        panel.statsDeleted = deleted
        local repairs = makeStatRow(-6, deleted)
        panel.statsRepairs = repairs
        local repairCost = makeStatRow(-6, repairs)
        panel.statsRepairCost = repairCost
        -- v0.7.0: money made + coin looted - repair cost.
        local net = makeStatRow(-6, repairCost)
        panel.statsNet = net
        local sessionGPH = makeStatRow(-6, net)
        panel.statsSessionGPH = sessionGPH
        local bestGPH = makeStatRow(-6, sessionGPH)
        panel.statsBestGPH = bestGPH
        local avgWorth = makeStatRow(-6, bestGPH)
        panel.statsAvgWorth = avgWorth
        -- v2.66.1 iter (Serv report): Sold-by-Quality now header + per-
        -- quality MakeStatRow so the value column aligns at TOP5_VALUE_X
        -- (same X used by Top 5 lists below). RefreshStats writes to
        -- row.left / row.right per quality bucket instead of a single
        -- table.concat FontString.
        local qualityBreakdown = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        qualityBreakdown:SetPoint("TOPLEFT", avgWorth, "BOTTOMLEFT", 0, -10)
        WC_compCache.setPanelWidth(qualityBreakdown, 16)
        qualityBreakdown:SetJustifyH("LEFT")
        qualityBreakdown:SetJustifyV("TOP")
        -- Also declare the row containers here so the anchor chain below
        -- can descend past all 8 possible rows. Quality indices 0..7.
        -- v2.66.1 iter 2 (Serv report): third column for Sold-by-Quality's
        -- gold value. row.left = quality name, row.right = count, row.gold
        -- = gold value at a fixed X column so the "Xg" values stack.
        -- v2.66.1 iter 2 (Serv report): gold column moved closer to the
        -- count column (was 320 - too far right). 260 keeps them visually
        -- as a pair while still stacking to a fixed X across rows.
        local SOLD_GOLD_X = 260
        panel._soldByQualityRows = {}
        local lastSoldQ = qualityBreakdown
        for q = 0, 7 do
            local row = NS.MakeStatRow(content, lastSoldQ, q == 0 and -2 or 0, 200)
            row.gold = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            row.gold:SetPoint("LEFT", row, "LEFT", SOLD_GOLD_X, 0)
            row.gold:SetJustifyH("LEFT")
            panel._soldByQualityRows[q] = row
            lastSoldQ = row
        end
        panel._soldByQualityEmpty = NS.MakeStatRow(content, qualityBreakdown, -2, 200)
        if qualityBreakdown.SetWordWrap then
            qualityBreakdown:SetWordWrap(true)
        end
        panel.statsQualityBreakdown = qualityBreakdown
        -- v2.37.x: "Deleted by Quality" mirrors "Sold by Quality" -
        -- per-rarity counts only (no copper, deletion produces no
        -- money). Rendered when DB.deletedItemsByQuality has any
        -- non-zero entry; reads "None yet" otherwise.
        -- v2.66.1 iter: anchor descends past all 8 Sold-by-Quality rows.
        -- Deleted-by-Quality itself becomes header + per-quality rows too.
        local deletedByQuality = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        deletedByQuality:SetPoint("TOPLEFT", lastSoldQ, "BOTTOMLEFT", 0, -10)
        WC_compCache.setPanelWidth(deletedByQuality, 16)
        deletedByQuality:SetJustifyH("LEFT")
        deletedByQuality:SetJustifyV("TOP")
        panel.statsDeletedByQuality = deletedByQuality
        panel._deletedByQualityRows = {}
        local lastDelQ = deletedByQuality
        for q = 0, 7 do
            local row = NS.MakeStatRow(content, lastDelQ, q == 0 and -2 or 0, 200)
            panel._deletedByQualityRows[q] = row
            lastDelQ = row
        end
        panel._deletedByQualityEmpty = NS.MakeStatRow(content, deletedByQuality, -2, 200)
        -- v2.66.1 iter (Serv report): Top 5 lists converted from a single
        -- FontString (with newline-joined rows) to a header + per-row
        -- MakeStatRow containers so the count column aligns at a fixed
        -- X - matches the spreadsheet-style alignment on Stats - Guild
        -- and Stats - Server. RefreshStats writes to row.left (rank +
        -- item name) and row.right (count) instead of a table.concat.
        local TOP5_VALUE_X = 200
        local function makeTopRow(anchor, yOff)
            return NS.MakeStatRow(content, anchor, yOff, TOP5_VALUE_X)
        end
        -- Header FontString (unchanged in shape from v2.37.0).
        local mostSoldHeader = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        -- v2.66.1 iter: descend past all 8 Deleted-by-Quality rows.
        mostSoldHeader:SetPoint("TOPLEFT", lastDelQ, "BOTTOMLEFT", 0, -10)
        WC_compCache.setPanelWidth(mostSoldHeader, 16)
        mostSoldHeader:SetJustifyH("LEFT")
        panel.statsMostSold = mostSoldHeader
        panel._mostSoldHeader = mostSoldHeader
        panel._mostSoldRows = {}
        local lastMostSoldAnchor = mostSoldHeader
        for i = 1, 5 do
            local row = makeTopRow(lastMostSoldAnchor, i == 1 and -2 or 0)
            panel._mostSoldRows[i] = row
            lastMostSoldAnchor = row
        end
        panel._mostSoldEmpty = makeTopRow(mostSoldHeader, -2)

        -- Top 5 Most Deleted mirrors Top 5 Most Sold.
        local mostDeletedHeader = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        mostDeletedHeader:SetPoint("TOPLEFT", lastMostSoldAnchor, "BOTTOMLEFT", 0, -10)
        WC_compCache.setPanelWidth(mostDeletedHeader, 16)
        mostDeletedHeader:SetJustifyH("LEFT")
        panel.statsMostDeleted = mostDeletedHeader
        panel._mostDeletedHeader = mostDeletedHeader
        panel._mostDeletedRows = {}
        local lastMostDeletedAnchor = mostDeletedHeader
        for i = 1, 5 do
            local row = makeTopRow(lastMostDeletedAnchor, i == 1 and -2 or 0)
            panel._mostDeletedRows[i] = row
            lastMostDeletedAnchor = row
        end
        panel._mostDeletedEmpty = makeTopRow(mostDeletedHeader, -2)

        -- v2.66.1 iter 4 (Serv report): Process Bags Totals converted from
        -- a single multi-line FontString to a header + per-operation
        -- MakeStatRow rig so the count column aligns at TOP5_VALUE_X -
        -- matches the spreadsheet-style alignment elsewhere on the panel.
        -- RefreshStats writes to row.left (operation label) and row.right
        -- (count) instead of table.concat.
        local processTotals = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        processTotals:SetPoint("TOPLEFT", lastMostDeletedAnchor, "BOTTOMLEFT", 0, -10)
        WC_compCache.setPanelWidth(processTotals, 16)
        processTotals:SetJustifyH("LEFT")
        processTotals:SetJustifyV("TOP")
        panel.statsProcessTotals = processTotals
        panel._processRows = {}
        local lastProcess = processTotals
        for i = 1, 4 do
            local row = makeTopRow(lastProcess, i == 1 and -2 or 0)
            panel._processRows[i] = row
            lastProcess = row
        end
        -- (v2.68.1: the old panel._processEmpty "Nothing processed yet" row
        -- was removed - all four process rows always render since v2.66.1,
        -- so the empty-state could never show.)

        -- v2.66.1 iter: Top zones header + per-zone MakeStatRow so the
        -- gold column aligns at TOP5_VALUE_X.
        local topZones = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        topZones:SetPoint("TOPLEFT", lastProcess, "BOTTOMLEFT", 0, -10)
        WC_compCache.setPanelWidth(topZones, 16)
        topZones:SetJustifyH("LEFT")
        topZones:SetJustifyV("TOP")
        panel.statsTopZones = topZones
        panel._topZoneRows = {}
        local lastZone = topZones
        for i = 1, 5 do
            local row = NS.MakeStatRow(content, lastZone, i == 1 and -2 or 0, 200)
            panel._topZoneRows[i] = row
            lastZone = row
        end
        panel._topZoneEmpty = NS.MakeStatRow(content, topZones, -2, 200)

        -- v0.7.0: the last seven days, one row each, account-wide. Always
        -- seven rows (a quiet day reads "-"), so nothing below re-anchors
        -- on a hidden row.
        local days = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        days:SetPoint("TOPLEFT", lastZone, "BOTTOMLEFT", 0, -10)
        WC_compCache.setPanelWidth(days, 16)
        days:SetJustifyH("LEFT")
        panel.statsDays = days
        panel._dayRows = {}
        local lastDay = days
        for i = 1, 7 do
            local row = NS.MakeStatRow(content, lastDay, i == 1 and -2 or 0, 200)
            panel._dayRows[i] = row
            lastDay = row
        end

        -- Footnote about buyback exclusion.
        local statsNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        -- v0.7.0: descends past the seven day rows.
        statsNote:SetPoint("TOPLEFT", lastDay, "BOTTOMLEFT", 0, -4)
        WC_compCache.setPanelWidth(statsNote, 16)
        statsNote:SetJustifyH("LEFT")
        statsNote:SetText(L["|cff888888Stats don't account for items bought back from a merchant.|r"])
        panel.statsNote = statsNote

        -- Reset Session button. Clears the in-memory session deltas (the
        -- "session +X" suffixes next to each stat) without touching the
        -- lifetime totals. NS.ResetSession lives in WoWClearance_Events.lua.
        local resetSessionBtn = CreateFrame("Button", "WoWClearanceResetSessionBtn", content, "UIPanelButtonTemplate")
        resetSessionBtn:SetSize(170, 22)
        resetSessionBtn:SetPoint("TOPLEFT", statsNote, "BOTTOMLEFT", 0, -10)
        resetSessionBtn:SetText(L["Reset Session Stats"])
        resetSessionBtn:SetScript("OnClick", function()
            if NS.ResetSession then
                NS.ResetSession()
            end
            if NS.RefreshStats then
                NS.RefreshStats()
            end
        end)

        -- Reset Lifetime button. v2.38.1: branches on the active view -
        -- Character view clears this character's DB.* lifetime; Account
        -- view clears the ADB.accountStats.* aggregate. NS.ResetLifetimeStats
        -- reads panel._statsView to decide which side to wipe. The button
        -- label adapts so the player knows what they're about to nuke.
        local resetBtn = CreateFrame("Button", "WoWClearanceResetStatsBtn", content, "UIPanelButtonTemplate")
        resetBtn:SetSize(220, 22)
        resetBtn:SetPoint("LEFT", resetSessionBtn, "RIGHT", 8, 0)
        local function updateResetLabel()
            if panel._statsView == "account" then
                resetBtn:SetText(L["Reset Lifetime (account)"])
            else
                resetBtn:SetText(L["Reset Lifetime (this character)"])
            end
        end
        updateResetLabel()
        panel._updateResetLabel = updateResetLabel
        resetBtn:SetScript("OnClick", function()
            local dialog = StaticPopup_Show("WC_CONFIRM_RESET_LIFETIME")
            -- Raise above the Interface Options frame or the player cannot
            -- click Yes (WC-TRAP note in WoWClearance_PanelWidgets.lua).
            if NS.RaisePopupAboveOptions then
                NS.RaisePopupAboveOptions(dialog)
            end
            if dialog then
                dialog.data = function()
                    if NS.ResetLifetimeStats then
                        NS.ResetLifetimeStats()
                    end
                    if NS.RefreshStats then
                        NS.RefreshStats()
                    end
                    -- Account-view reset stamps a new startedAt; refresh
                    -- the date line so the player sees the new "counting
                    -- from <today>" immediately.
                    if panel._refreshStartedAt then
                        panel._refreshStartedAt()
                    end
                end
            end
        end)

        if NS.RefreshStats then
            NS.RefreshStats()
        end
        -- v2.37.x: size the scroll content frame to fit the bottom-most
        -- widget so the panel scrolls when the stack grows past the
        -- Interface Options container's natural height. resetBtn is the
        -- last widget; FitScrollContent measures its bottom edge against
        -- the content frame's TOPLEFT. Same pattern as the Main /
        -- Merchant / Item Highlighting panels.
        if NS.FitScrollContent then
            NS.FitScrollContent(content, resetBtn)
        end
    end, true)
end)

-- v2.36.x: registered from
-- WoWClearance_Events.lua (right after the Main panel) so the sub-panel
-- sort order (Main / Stats / Merchant / ...) is controlled at one place.

-- ============================================================
-- Session Loot window
-- ============================================================
-- Standalone floating window opened by the Stats panel's "Session Loot"
-- button and by /wc loot. Read-only scroll list of items looted showing
-- count, vendor value and each item's share of the total, in three scopes:
-- Session (NS.lootSession, in-memory, clears on /reload or Reset Session),
-- Character (DB.lootedItemCounts) and Account (the persisted account-wide
-- running total). Narrowed by a rarity dropdown and a free-text search.
-- Resizable via the bottom-right grip, but it never snapshots
-- WC_PANEL_WIDTH - the scroll child tracks the viewport through the
-- scroll frame's own OnSizeChanged, so this window stays outside the
-- reactive-width contract that governs the Interface Options sub-panels.
-- Loot capture + storage live in WoWClearance_Events.lua.
local lootWindow

local LOOT_ROW_H = 18
-- Width of the History view's looter column.
local LOOT_WHO_W = 84
-- Gap between the number columns (count, value, share).
local LOOT_COL_GAP = 10
-- v2.68.0: per-itemID cache-priming attempt counter. Session-only, and
-- deliberately NOT saved: the client's item cache persists to disk, so a
-- later session usually resolves these on the first GetItemInfo with no
-- priming at all. The cap stops a handful of itemIDs that never resolve
-- (removed from the game DB, or a server that will not serve them) from
-- re-priming on every single refresh forever, which would also pin the
-- loot window on its fast refresh cadence permanently.
local lootPrimeTries = {}
local LOOT_PRIME_MAX_TRIES = 3

-- v2.68.0 (Serv report): coin text with a comma-grouped gold figure.
-- GetCoinTextureString emits the gold amount raw, and a seven-digit
-- total ("1037251g") is unreadable at a glance.
--
-- WC-TRAP: only the LEADING digit run is substituted, and only once. The
-- rest of the returned string is texture escapes
-- (|TInterface\MoneyFrame\UI-GoldIcon:12:12:2:0|t) which contain digits
-- of their own - a global %d substitution corrupts the coin icons.
-- When gold is 0 the string starts with the silver figure instead, which
-- is at most two digits, so commaing it is a harmless no-op.
local function lootCoinText(copper, fallback)
    if not (copper and copper > 0 and GetCoinTextureString) then
        return fallback
    end
    local s = GetCoinTextureString(copper)
    return (s:gsub("^(%d+)", function(g)
        return NS.CommaNumber(tonumber(g) or 0)
    end, 1))
end
local LOOT_DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Forward-declared so the row factory's right-click handler (defined before
-- the body below) can call it as an upvalue. Assigned with `function
-- lootRefresh(win)` further down, NOT `local function`, so it stays the same
-- upvalue everything here captures.
local lootRefresh

-- Build a sorted array of { id, qty, value, name, quality, texture } for the
-- given scope, narrowed by rarityFilter and/or search when set, plus the
-- totals of quantity AND vendor value.
--
-- v2.68.0 (Serv request): the totals cover ONLY the rows that survive the
-- filters. They used to span every entry in the scope, so with a filter on,
-- the per-row percentages read as a share of everything ever looted and the
-- visible rows summed to some small fraction of 100%. Now filtering to Epics
-- gives you each Epic's share OF YOUR EPICS, and the shares of what is on
-- screen add up to 100%. The header counts rebase the same way, so the whole
-- window consistently describes the current view rather than mixing the two.
--
-- value = per-unit vendor sell price (GetItemInfo) x quantity; it's 0 for
-- items with no sell price, which is itself useful - it flags the worthless
-- drops worth deleting. One GetItemInfo per item (cached) feeds sort + render.
-- Returns (arr, total, totalValue, primed); `primed` is how many item-cache
-- fetches this pass kicked off, which drives the window's refresh cadence.
-- History view support. lootHistoryArr is reused across builds (it holds
-- ring slots, not row tables). Looter display names are memoised because
-- the same few names repeat across thousands of entries.
local lootHistoryArr = {}
local lootWhoShort = {}
local function lootWhoDisplay(who)
    local d = lootWhoShort[who]
    if not d then
        d = Ambiguate(who, "none")
        lootWhoShort[who] = d
    end
    return d
end
local lootHistoryRow = {}
-- Per-slot sort key + recency rank for the History sort, reused across
-- builds. Stale entries for slots not in the current array are harmless.
local lootHistoryKey, lootHistoryRank = {}, {}

-- `range` (v0.7.0): History view only, seconds back from now (nil = all).
local function lootBuildArray(scope, sortKey, sortDir, rarityFilter, search, range)
    local src
    if scope == "account" then
        local AS = NS.ADB and NS.ADB.accountStats
        src = AS and AS.lootedItemCounts
    elseif scope == "character" then
        src = NS.DB and NS.DB.lootedItemCounts
    else
        src = NS.lootSession
    end
    -- Hidden items (right-clicked to hide) are dropped before the totals, so
    -- the remaining rows' count/gold shares rebase as if the hidden ones were
    -- never looted. As of v2.68.0 the rarity + search filters behave the same
    -- way, so all three narrowing mechanisms are consistent: whatever is out
    -- of view is out of the totals.
    local hidden = (NS.ADB and NS.ADB.lootLogHidden) or {}
    local arr, total, totalValue = {}, 0, 0
    -- v2.68.0 (Serv report): the account scope aggregates loot from every
    -- character, so it names items THIS character has never seen. Those
    -- are absent from the client's item cache, GetItemInfo returns nil
    -- for all of them, and the row rendered as "item:3669" with a "?"
    -- icon. Less visibly it also contributed 0 to the gold column and
    -- was invisible to any rarity filter, because sellPrice and quality
    -- were nil too.
    --
    -- Prime the cache with C_Item.RequestLoadItemDataByID. Bounded per pass - an account log with thousands of
    -- uncached items would otherwise fire thousands of fetches in one
    -- frame. Anything left unresolved fills in on a later pass: the
    -- window's own 2 s safety refresh re-renders, so the rows populate
    -- themselves with no extra timer.
    local primesLeft = 25
    local primed = 0
    -- v0.7.0: shared matcher ("||" for either, quotes for an exact name).
    local match = NS.SearchMatcher(search)
    local function itemInfo(itemID)
        local name, _, q, _, _, _, _, _, _, texture, sellPrice = GetItemInfo(itemID)
        local tries = lootPrimeTries[itemID] or 0
        if not name and primesLeft > 0 and tries < LOOT_PRIME_MAX_TRIES then
            primesLeft = primesLeft - 1
            lootPrimeTries[itemID] = tries + 1
            primed = primed + 1
            -- Forever: ask the client to load the item directly. The old
            -- hidden-tooltip SetHyperlink did the same fetch but also ran
            -- every addon's item-tooltip post-call per primed item. The
            -- answer arrives asynchronously; the window's 2 s refresh while
            -- `primed > 0` picks it up.
            C_Item.RequestLoadItemDataByID(itemID)
        end
        return name, q, texture, sellPrice
    end
    -- History: one row per pickup, already newest first, so no sort. Up to
    -- 20000 entries, so the array holds ring SLOTS (integers) in a table
    -- reused across builds, and lootRenderVisible decodes only the rows on
    -- screen. Item info is looked up once per itemID per build; looter
    -- display names are memoised for the session. Search matches looters too.
    if scope == "history" then
        local LH = NS.LootHistory
        arr = lootHistoryArr
        local n = 0
        local memo = {}
        local whoHit = {}
        local since = range and (time() - range)
        local count = LH and LH.Count() or 0
        for k = 1, count do
            local slot = LH.SlotAt(k)
            local t, itemID, qty, who = LH.Get(slot)
            -- Newest first, so the first entry older than the range ends it.
            if since and t and t < since then
                break
            end
            if itemID and not hidden[itemID] then
                local m = memo[itemID]
                if not m then
                    local name, q, _, sellPrice = itemInfo(itemID)
                    local displayName = name or ("item:" .. itemID)
                    m = { q = q, price = sellPrice or 0, lname = displayName:lower() }
                    m.hit = match and match(displayName)
                    memo[itemID] = m
                end
                local matches = (rarityFilter == nil or m.q == rarityFilter)
                if matches and match and not m.hit then
                    -- Search matches looters too; memoised per looter.
                    local hit = whoHit[who]
                    if hit == nil then
                        hit = match(lootWhoDisplay(who))
                        whoHit[who] = hit
                    end
                    matches = hit
                end
                if matches then
                    n = n + 1
                    arr[n] = slot
                    total = total + qty
                    totalValue = totalValue + m.price * qty
                    lootHistoryRank[slot] = k
                    if sortKey == "name" then
                        lootHistoryKey[slot] = m.lname
                    elseif sortKey == "count" then
                        lootHistoryKey[slot] = qty
                    elseif sortKey == "gold" then
                        lootHistoryKey[slot] = m.price * qty
                    end
                end
            end
        end
        for i = n + 1, #arr do
            arr[i] = nil
        end
        -- The loop above already produced newest-first. "time" ascending is
        -- that order reversed; the other keys sort, newest first on ties.
        if sortKey == "time" or not sortKey then
            if sortDir == 1 then
                for i = 1, math.floor(n / 2) do
                    arr[i], arr[n - i + 1] = arr[n - i + 1], arr[i]
                end
            end
        else
            local keys, rank = lootHistoryKey, lootHistoryRank
            table.sort(arr, function(a, b)
                local ka, kb = keys[a], keys[b]
                if ka ~= kb then
                    if sortDir == 1 then
                        return ka < kb
                    end
                    return ka > kb
                end
                return rank[a] < rank[b]
            end)
        end
        return arr, total, totalValue, primed
    end
    if src then
        for itemID, qty in pairs(src) do
            if qty and qty > 0 and not hidden[itemID] then
                local name, q, texture, sellPrice = itemInfo(itemID)
                local value = (sellPrice or 0) * qty
                -- v2.68.0 (Serv request): free-text name filter, matching the
                -- Sold History window's search box. Matched against the
                -- DISPLAYED name so an uncached "item:3669" row is still
                -- findable while its name resolves.
                local displayName = name or ("item:" .. itemID)
                local matchesSearch = not match or match(displayName)
                if (rarityFilter == nil or q == rarityFilter) and matchesSearch then
                    -- Totals accumulate INSIDE the filter test, so they cover
                    -- only what is on screen (see the note on this function).
                    -- Moving these two lines back out silently reverts the
                    -- percentages to a share-of-everything reading.
                    total = total + qty
                    totalValue = totalValue + value
                    arr[#arr + 1] = {
                        id = itemID,
                        qty = qty,
                        value = value,
                        name = displayName,
                        quality = q,
                        texture = texture,
                    }
                end
            end
        end
    end
    -- sortDir: 1 = ascending, -1 = descending. Ties break on itemID for a
    -- stable order. "count" sorts by quantity, "gold" by vendor value (these
    -- diverge when prices differ - the whole point of the gold column), and
    -- "name" alphabetically.
    sortDir = sortDir or -1
    local function byField(field)
        return function(a, b)
            if a[field] ~= b[field] then
                if sortDir == 1 then
                    return a[field] < b[field]
                end
                return a[field] > b[field]
            end
            return a.id < b.id
        end
    end
    if sortKey == "name" then
        table.sort(arr, function(a, b)
            if a.name ~= b.name then
                if sortDir == 1 then
                    return a.name < b.name
                end
                return a.name > b.name
            end
            return a.id < b.id
        end)
    elseif sortKey == "gold" then
        table.sort(arr, byField("value"))
    else
        table.sort(arr, byField("qty"))
    end
    -- `primed` tells the caller whether names are still resolving, which
    -- picks the window's refresh cadence (see the OnUpdate driver).
    return arr, total, totalValue, primed
end

-- Pooled row factory. Rows anchor to content's TOPLEFT/TOPRIGHT so they
-- stretch with the (fixed) content width; reused across Refresh calls.
-- v2.68.0: `i` is now the POOL slot, not the data index, and the row is
-- positioned by lootRenderVisible at bind time rather than here. The
-- pool holds only enough rows to cover the viewport (see the note on
-- lootRenderVisible); a given slot shows a different item as you scroll.
local function lootGetRow(win, i)
    win.rows = win.rows or {}
    local row = win.rows[i]
    if row then
        return row
    end
    row = CreateFrame("Frame", nil, win.content)
    row:SetHeight(LOOT_ROW_H)
    -- Alt+hover shows the item's tooltip, which WoWClearance's tooltip hook
    -- annotates with the SAME plain-English verdict + reason you see hovering
    -- the item in your bags ("Keep (Green, no item level)", "Won't Sell (no
    -- value)", "Will Sell (junk)", etc.) - the humanised read, NOT the
    -- technical /wc sellinfo step trace. We hover the live bag item when it's
    -- still in bags (most precise) and fall back to a generic item tooltip
    -- otherwise, noting it's no longer in bags. Plain hover does nothing, so
    -- the list stays quiet unless the player asks.
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if not self.itemID then
            return
        end
        -- History rows: a plain hover shows the item and when / who looted
        -- it, since the row itself no longer carries the date and time.
        if not IsAltKeyDown() then
            if not self.lootedAt then
                return
            end
            NS.AnchorTooltipBesideWindow(self, win)
            GameTooltip:SetHyperlink("item:" .. self.itemID)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(string.format(L["Looted by %s, %s"], self.lootedBy or "?", self.lootedAt), 1, 0.82, 0)
            GameTooltip:AddLine(L["|cff808080Click to show only this item.|r"], 1, 1, 1, true)
            GameTooltip:Show()
            NS.RaiseTooltipAboveWindows()
            return
        end
        local id = self.itemID
        local foundBag, foundSlot
        for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
            local slots = GetContainerNumSlots(bag) or 0
            for slot = 1, slots do
                if GetContainerItemID(bag, slot) == id then
                    foundBag, foundSlot = bag, slot
                    break
                end
            end
            if foundBag then
                break
            end
        end
        NS.AnchorTooltipBesideWindow(self, win)
        if foundBag then
            -- SetBagItem fires the tooltip hook, which appends WC's verdict
            -- line with its reason - exactly the bag-hover annotation.
            GameTooltip:SetBagItem(foundBag, foundSlot)
        else
            GameTooltip:SetHyperlink("item:" .. id)
            GameTooltip:AddLine(L["|cff888888Not in your bags now - hover it in your bags for the live read.|r"], 1, 1, 1, true)
        end
        if self.lootedAt then
            GameTooltip:AddLine(string.format(L["Looted by %s, %s"], self.lootedBy or "?", self.lootedAt), 1, 0.82, 0)
        end
        GameTooltip:AddLine(L["|cff808080Click to show only this item.|r"], 1, 1, 1, true)
        GameTooltip:AddLine(L["|cff808080Right-click to hide from the Loot Log.|r"], 1, 1, 1, true)
        GameTooltip:Show()
        -- This window is TOOLTIP strata, so the tooltip renders behind it
        -- without an absolute level stamp. See the WC-TRAP note on the
        -- helper in WoWClearance_PanelWidgets.lua.
        NS.RaiseTooltipAboveWindows()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    -- Right-click hides this item from the Loot Log. Hidden items drop out
    -- of the list AND the totals, so every other row's count/gold share
    -- rebases. Restore them all with the window's "Unhide All" button.
    row:SetScript("OnMouseUp", function(self, button)
        -- v0.7.0: left-click shows only this item (an exact-name search);
        -- click again to clear.
        if button == "LeftButton" and self.itemName and win.searchBox then
            local term = '"' .. self.itemName .. '"'
            win.searchBox:SetText(win.searchBox:GetText() == term and "" or term)
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            return
        end
        if button ~= "RightButton" or not self.itemID then
            return
        end
        if NS.ADB then
            NS.ADB.lootLogHidden = NS.ADB.lootLogHidden or {}
            NS.ADB.lootLogHidden[self.itemID] = true
        end
        lootRefresh(win)
        if NS.PrintNicef then
            local n = (GetItemInfo(self.itemID)) or ("item:" .. self.itemID)
            NS.PrintNicef(L["Hid %s from the Loot Log. Use Unhide All to bring it back."], n)
        end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.icon = icon
    -- Three right-aligned number columns (count, value, share), anchored to
    -- the row's right so they stay visible; the name truncates instead.
    -- They used to be one "xN  value  P%" string, which could not line up
    -- across rows because each part's width varies. Column widths are set
    -- per render to the widest visible value (lootRenderVisible).
    local pct = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    pct:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    pct:SetJustifyH("RIGHT")
    row.pct = pct
    local coin = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    coin:SetPoint("RIGHT", pct, "LEFT", -LOOT_COL_GAP, 0)
    coin:SetJustifyH("RIGHT")
    row.coin = coin
    local qty = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    qty:SetPoint("RIGHT", coin, "LEFT", -LOOT_COL_GAP, 0)
    qty:SetJustifyH("RIGHT")
    row.qty = qty
    -- History only: the looter, in a fixed-width column so item names line
    -- up. Long names truncate rather than push the item along.
    local who = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    who:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    who:SetWidth(LOOT_WHO_W)
    who:SetJustifyH("LEFT")
    who:SetWordWrap(false)
    who:SetTextColor(1, 0.82, 0)
    who:Hide()
    row.who = who
    local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    label:SetPoint("RIGHT", qty, "LEFT", -6, 0)
    label:SetJustifyH("LEFT")
    row.label = label
    win.rows[i] = row
    return row
end

-- v2.68.0 (Serv report: account scope slowed the WHOLE game, not just
-- this window): render ONLY the rows currently in the viewport.
--
-- Before this, lootRefresh created a frame per entry - with 5000+ items
-- in the Character / Account scopes that is 5000 frames, each carrying
-- an icon texture and two FontStrings, so ~20000 live UI objects. WoW's
-- layout cost scales with live frame count across the whole UI, which is
-- why the slowdown was global rather than confined to the list, and why
-- scrolling (which re-lays-out the scroll child) made it worst.
--
-- Now the pool holds only what fits the viewport plus a small buffer
-- (~20 rows), and scrolling re-binds those same frames to a different
-- slice of the array. Frame count is constant regardless of list size,
-- so Account scope costs the same as Session. The scrollbar range still
-- reflects the full list because content height is still #arr rows.
--
-- WC-TRAP: rows are positioned HERE, per bind, not in lootGetRow. The
-- pool index is a screen slot, NOT the data index - do not "simplify"
-- by anchoring rows once at creation, that is what this replaced.
local function lootRenderVisible(win)
    if not win or not win.content then
        return
    end
    local arr = win._arr or {}
    local totalValue = win._totalValue or 0
    local scroll = win.scroll
    local viewH = (scroll and scroll:GetHeight()) or 0
    local offset = (scroll and scroll:GetVerticalScroll()) or 0
    -- Index of the first row intersecting the top of the viewport.
    local first = math.floor(offset / LOOT_ROW_H)
    if first < 0 then
        first = 0
    end
    -- +2 covers the partially-visible rows at each edge.
    local slots = math.ceil(viewH / LOOT_ROW_H) + 2
    for j = 1, slots do
        local idx = first + j
        local e = arr[idx]
        if type(e) == "number" then
            -- History view: arr holds ring slots; decode just this row.
            local t, itemID, qty, who = NS.LootHistory.Get(e)
            if itemID then
                local name, _, q, _, _, _, _, _, _, texture, sellPrice = GetItemInfo(itemID)
                local r = lootHistoryRow
                r.id, r.qty, r.t, r.who = itemID, qty, t, lootWhoDisplay(who)
                r.name, r.quality, r.texture = name or ("item:" .. itemID), q, texture
                r.value = (sellPrice or 0) * qty
                e = r
            else
                e = nil
            end
        end
        local row = lootGetRow(win, j)
        if e then
            local y = -(idx - 1) * LOOT_ROW_H
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", win.content, "TOPLEFT", 0, y)
            row:SetPoint("TOPRIGHT", win.content, "TOPRIGHT", 0, y)
            row.itemID = e.id
            local hex = "ffffffff"
            if
                e.quality
                and ITEM_QUALITY_COLORS
                and ITEM_QUALITY_COLORS[e.quality]
                and ITEM_QUALITY_COLORS[e.quality].hex
            then
                hex = ITEM_QUALITY_COLORS[e.quality].hex:gsub("|c", "")
            end
            row.icon:SetTexture(e.texture or LOOT_DEFAULT_ICON)
            if e.t then
                -- History row: looter column, then the item. The date and
                -- time move to the hover tooltip. "%d %b" reads the same in
                -- every region, unlike 07/10 vs 10/07.
                row.who:SetText(e.who)
                row.who:Show()
                row.label:SetPoint("LEFT", row.who, "RIGHT", 6, 0)
                row.lootedBy = e.who
                row.lootedAt = date("%d %b %H:%M", e.t)
            else
                row.who:Hide()
                row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
                row.lootedBy, row.lootedAt = nil, nil
            end
            row.label:SetText(string.format("|c%s%s|r", hex, e.name))
            row.itemName = e.name
            -- Amount column: count, vendor value, and that value's share of
            -- the gold total for the CURRENT view (v2.68.0) - so with a
            -- filter on the shares are relative to what you filtered to, and
            -- the visible rows add up to 100%. A worthless drop shows a grey
            -- dash + 0%, the cue to filter/delete.
            local goldPct = (totalValue > 0) and (e.value / totalValue * 100) or 0
            local coin = lootCoinText(e.value, "|cff707070-|r")
            -- v2.68.0 (Serv report): two decimals, not one. With thousands of
            -- distinct drops every share is under ~1.5%, so at one decimal
            -- whole runs of rows all read "0.8%" and the column stopped
            -- ranking anything. The second decimal separates them again.
            row.qty:SetText("|cff808080x" .. NS.CommaNumber(e.qty) .. "|r")
            row.coin:SetText(coin)
            row.pct:SetText(string.format("|cff888888%.2f%%|r", goldPct))
            row:Show()
        else
            row.itemID = nil
            row.itemName = nil
            row.lootedBy, row.lootedAt = nil, nil
            row:Hide()
        end
    end
    -- Slots beyond what the current viewport needs (window was shrunk).
    if win.rows then
        for j = slots + 1, #win.rows do
            win.rows[j]:Hide()
        end
    end
    -- Size each number column to its widest visible value so the counts,
    -- values and shares line up down the list, whatever their length.
    local wQty, wCoin, wPct = 0, 0, 0
    for j = 1, math.min(slots, #(win.rows or {})) do
        local row = win.rows[j]
        if row:IsShown() then
            wQty = math.max(wQty, row.qty:GetUnboundedStringWidth())
            wCoin = math.max(wCoin, row.coin:GetUnboundedStringWidth())
            wPct = math.max(wPct, row.pct:GetUnboundedStringWidth())
        end
    end
    for j = 1, math.min(slots, #(win.rows or {})) do
        local row = win.rows[j]
        row.qty:SetWidth(wQty + 1)
        row.coin:SetWidth(wCoin + 1)
        row.pct:SetWidth(wPct + 1)
    end
end
function lootRefresh(win)
    if not win then
        return
    end
    local arr, total, totalValue, primed =
        lootBuildArray(
            win.scope or "session",
            win.scope == "history" and win.histSortKey or win.sortKey,
            win.scope == "history" and win.histSortDir or win.sortDir,
            win.rarityFilter,
            win.search,
            win.timeRange
        )
    -- Stashed for lootRenderVisible, which re-binds the pooled rows on
    -- every scroll WITHOUT rebuilding or re-sorting the array.
    win._arr = arr
    win._totalValue = totalValue
    -- History has its own sort state and an extra Time button.
    if win.updateSortButtons then
        win.updateSortButtons()
    end
    win._primedLast = primed or 0
    -- v0.7.0: only the History view carries times.
    if win.timeDD then
        win.timeDD:SetEnabled(win.scope == "history")
    end
    win.content:SetHeight(math.max(1, #arr * LOOT_ROW_H))
    lootRenderVisible(win)
    -- Reflect the hidden-item count on the Unhide All button, and grey it out
    -- when nothing is hidden.
    if win.unhideBtn then
        local nHidden = 0
        local h = NS.ADB and NS.ADB.lootLogHidden
        if h then
            for _ in pairs(h) do
                nHidden = nHidden + 1
            end
        end
        if nHidden > 0 then
            win.unhideBtn:SetText(string.format(L["Unhide All (%d)"], nHidden))
            win.unhideBtn:Enable()
        else
            win.unhideBtn:SetText(L["Unhide All"])
            win.unhideBtn:Disable()
        end
    end
    if win.totalLine then
        if #arr == 0 then
            win.totalLine:SetText(L["|cff888888Nothing looted yet.|r"])
        else
            local coinTotal = lootCoinText(totalValue, "0")
            win.totalLine:SetText(
                string.format(L["%s items  |  %s looted  |  %s"], NS.CommaNumber(#arr), NS.CommaNumber(total), coinTotal)
            )
        end
    end
end

local function lootEnsureWindow()
    if lootWindow then
        return lootWindow
    end
    local win = CreateFrame("Frame", "WoWClearanceLootWindow", UIParent, "DefaultPanelTemplate")
    -- v2.66.1 (Serv report): TOOLTIP strata (not FULLSCREEN_DIALOG) so
    -- the loot log sits above the Interface Options frame. Same reason
    -- the Quickstart panel + Sold History window use TOOLTIP.
    win:SetFrameStrata("TOOLTIP")
    win:SetSize(420, 440)
    win:SetPoint("CENTER")
    win:EnableMouse(true)
    win:SetMovable(true)
    win:SetResizable(true)
    -- v0.5.2: SetMinResize/SetMaxResize removed on Forever; SetResizeBounds
    -- takes both pairs at once. The old guarded calls silently did nothing
    -- here, so these windows had no resize limits at all on this client.
    if win.SetResizeBounds then
        win:SetResizeBounds(380, 260, 800, 820)
    end
    win:RegisterForDrag("LeftButton")
    -- v2.75.0 (fresh-audit follow-up): pause the per-frame rebuild while the
    -- window is being dragged. During an AOE loot burst lootWindowDirty
    -- flips constantly, so the OnUpdate below would rebuild the row list ~once a
    -- second mid-drag and hitch the move. Refresh once when the drag ends.
    win:SetScript("OnDragStart", function(self)
        self._lootDragging = true
        self:StartMoving()
    end)
    win:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self._lootDragging = false
        lootRefresh(self)
    end)
    win:Hide()
    win.scope = "session"
    win.sortKey = "gold" -- "name" | "count" | "gold"
    win.sortDir = -1 -- 1 ascending, -1 descending (highest-earning first by default)
    -- History keeps its own sort so switching tabs doesn't disturb either:
    -- "time" | "name" | "count" | "gold", newest first by default.
    win.histSortKey = "time"
    win.histSortDir = -1
    win.rarityFilter = nil -- nil = all; otherwise a quality number 0-4
    win.search = "" -- free-text name filter; "" = no filter
    win.timeRange = nil -- History view: seconds back from now; nil = all time

    local title = win:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -12)
    -- v0.5.6: the visible title now goes in the template's own
    -- TitleContainer.TitleText (DefaultPanelBaseTemplate:486), which is
    -- centred in the header bar at frameLevel 510. This FontString is
    -- kept but BLANK because later widgets anchor to it; deleting it
    -- would unpick the whole anchor chain below.
    title:SetText("")
    if NS.SkinWindow then
        NS.SkinWindow(win, "WoWClearance: " .. L["Loot Log"])
    end

    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 1, 0)

    -- Scope radios: Session (this login, in-memory) / Character (this
    -- character's lifetime) / Account (all characters combined). A single
    -- setScope helper keeps exactly one checked and re-renders.
    local scopeRadios = {}
    local function setScope(scope)
        win.scope = scope
        for k, r in pairs(scopeRadios) do
            r:SetChecked(k == scope)
        end
        lootRefresh(win)
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end
    local function makeScopeRadio(scope, labelText, anchorTo)
        local r = CreateFrame("CheckButton", nil, win, "UIRadioButtonTemplate")
        if anchorTo then
            r:SetPoint("LEFT", anchorTo, "RIGHT", 14, 0)
        else
            r:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
        end
        local lbl = win:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        lbl:SetPoint("LEFT", r, "RIGHT", 4, 0)
        lbl:SetText(labelText)
        r:SetScript("OnClick", function()
            setScope(scope)
        end)
        scopeRadios[scope] = r
        return lbl
    end
    local sessLbl = makeScopeRadio("session", L["Session"], nil)
    local charLbl = makeScopeRadio("character", L["Character"], sessLbl)
    local acctLbl = makeScopeRadio("account", L["Account"], charLbl)
    makeScopeRadio("history", L["History"], acctLbl)
    scopeRadios.session:SetChecked(true)

    -- Total line (under the radios).
    local totalLine = win:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    totalLine:SetPoint("TOPLEFT", scopeRadios.session, "BOTTOMLEFT", 0, -8)
    totalLine:SetJustifyH("LEFT")
    win.totalLine = totalLine

    -- Clear button. Wipes only the currently-viewed scope.
    local clearBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    clearBtn:SetSize(90, 20)
    clearBtn:SetPoint("TOPRIGHT", win, "TOPRIGHT", -14, -54)
    clearBtn:SetText(L["Clear"])
    -- Stop the total line short of Clear so a long total never runs under
    -- it: window width minus its 12 px left inset and Clear's 110 px
    -- (14 margin + 90 button + 6 gap). Width, not a RIGHT anchor, because
    -- a second anchor on Clear would also move the line vertically.
    local function fitTotalLine(w)
        totalLine:SetWidth(math.max((w or win:GetWidth()) - 122, 60))
    end
    fitTotalLine()
    win:HookScript("OnSizeChanged", function(_, w)
        fitTotalLine(w)
    end)
    clearBtn:SetScript("OnClick", function()
        if NS.ClearLoot then
            NS.ClearLoot(win.scope)
        end
        lootRefresh(win)
    end)

    -- Sort controls. Name / Count / Gold each toggle ascending <-> descending
    -- on repeat clicks; the active column shows a direction caret. Count sorts
    -- by quantity looted, Gold by vendor value (qty x sell price) - these
    -- diverge when prices differ, which is the whole point of the gold view.
    local sortLabel = win:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sortLabel:SetPoint("TOPLEFT", totalLine, "BOTTOMLEFT", 0, -8)
    sortLabel:SetText(L["Sort:"])

    local sortBtns = {}
    local function updateSortButtons()
        local hist = win.scope == "history"
        local curKey = hist and win.histSortKey or win.sortKey
        local curDir = hist and win.histSortDir or win.sortDir
        local function caret(key)
            if curKey ~= key then
                return ""
            end
            return curDir == 1 and " |cffffd200^|r" or " |cffffd200v|r"
        end
        sortBtns.name:SetText(L["Name"] .. caret("name"))
        sortBtns.count:SetText(L["Count"] .. caret("count"))
        sortBtns.gold:SetText(L["Gold"] .. caret("gold"))
        sortBtns.time:SetText(L["Time"] .. caret("time"))
        sortBtns.time:SetShown(hist)
    end
    win.updateSortButtons = updateSortButtons
    local function setSort(key)
        local keyField = (win.scope == "history") and "histSortKey" or "sortKey"
        local dirField = (win.scope == "history") and "histSortDir" or "sortDir"
        if win[keyField] == key then
            win[dirField] = -win[dirField]
        else
            win[keyField] = key
            -- Names read best A-Z; amounts and times read best most-first.
            win[dirField] = (key == "name") and 1 or -1
        end
        updateSortButtons()
        lootRefresh(win)
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end
    local function makeSortBtn(key, w, anchorTo)
        local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        b:SetSize(w, 20)
        b:SetPoint("LEFT", anchorTo, "RIGHT", 6, 0)
        b:SetScript("OnClick", function()
            setSort(key)
        end)
        return b
    end
    sortBtns.name = makeSortBtn("name", 64, sortLabel)
    sortBtns.count = makeSortBtn("count", 60, sortBtns.name)
    sortBtns.gold = makeSortBtn("gold", 56, sortBtns.count)
    sortBtns.time = makeSortBtn("time", 56, sortBtns.gold)
    updateSortButtons()

    -- Rarity filter. "All rarities" plus one entry per quality; restricts
    -- which rows show. As of v2.68.0 the header counts and the per-row
    -- percentages rebase onto the filtered set, so filtering to Epics gives
    -- each Epic's share of your Epics and the visible rows sum to 100%.
    local rarityLabel = win:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    rarityLabel:SetPoint("TOPLEFT", sortLabel, "BOTTOMLEFT", 0, -14)
    rarityLabel:SetText(L["Show:"])
    -- v2.68.0 (Serv report): built through NS.MakeRarityDropdown, shared
    -- with the Sold History window. The helper's list opens at TOOLTIP
    -- strata above this window (see the WC-TRAP note on NS.MakeSelector in
    -- WoWClearance_PanelWidgets.lua) - do not rebuild this inline.
    local rarityDD = NS.MakeRarityDropdown(win, "WoWClearanceLootRarityDD", function(q)
        win.rarityFilter = q
        lootRefresh(win)
    end)
    rarityDD:SetPoint("LEFT", rarityLabel, "RIGHT", 6, 0)

    -- Unhide All button, on the rarity row. Right-clicking a row hides that
    -- item (it drops from the list and the totals); this restores every
    -- hidden item. Label carries the hidden count; disabled when none hidden.
    -- The hidden set is account-wide (ADB.lootLogHidden), so it applies to all
    -- three scope views.
    local unhideBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    unhideBtn:SetSize(110, 20)
    unhideBtn:SetPoint("LEFT", rarityDD, "RIGHT", 8, 0)
    unhideBtn:SetText(L["Unhide All"])
    unhideBtn:SetScript("OnClick", function()
        if NS.ADB and NS.ADB.lootLogHidden then
            for k in pairs(NS.ADB.lootLogHidden) do
                NS.ADB.lootLogHidden[k] = nil
            end
        end
        lootRefresh(win)
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    win.unhideBtn = unhideBtn

    -- v2.68.0 (Serv request): free-text filter. With thousands of rows in
    -- the Character / Account scopes, scrolling to one item is hopeless;
    -- this narrows by name the way the Sold History window's search box
    -- does. Combines with the rarity dropdown and the scope radios.
    -- Own row: the window is only 420 px wide (380 min), so the rarity
    -- row is already full with the dropdown plus Unhide All.
    local searchLabel = win:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    searchLabel:SetPoint("TOPLEFT", rarityLabel, "BOTTOMLEFT", 0, -22)
    searchLabel:SetText(L["Search:"])
    local search = CreateFrame("EditBox", "WoWClearanceLootSearch", win, "InputBoxTemplate")
    search:SetSize(150, 20)
    search:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
    search:SetAutoFocus(false)
    -- v2.68.1: debounced via the shared helper - each keystroke used to
    -- re-run the full lootBuildArray sweep (GetItemInfo per item + sort;
    -- on Account scope that is the exact thousands-of-items pass the
    -- v2.68.0 rebuild was built to tame). The text stash stays immediate;
    -- only the rebuild waits for a 250 ms typing idle.
    NS.MakeSearchDebounce(search, function()
        lootRefresh(win)
    end, function(text)
        win.search = text
    end)
    search:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    win.searchBox = search
    -- v0.7.0: time range on the search row (the box was narrowed to fit).
    -- History view only; lootRefresh greys it out on the other views.
    local timeDD = NS.MakeTimeDropdown(win, function(secs)
        win.timeRange = secs
        lootRefresh(win)
    end)
    timeDD:SetPoint("LEFT", search, "RIGHT", 8, 0)
    win.timeDD = timeDD

    -- Scroll chrome (matches the list windows' backdrop look).
    local scrollBg = CreateFrame("Frame", nil, win, "BackdropTemplate")
    -- v2.68.0: anchored to the last chrome row instead of the old fixed
    -- -120 offset. That magic number had to be hand-bumped every time a
    -- chrome row was added, and a missed bump overlaps the list on top of
    -- the row above it. Chaining it removes the trap.
    scrollBg:SetPoint("TOPLEFT", searchLabel, "BOTTOMLEFT", 0, -10)
    scrollBg:SetPoint("BOTTOMRIGHT", -12, 12)
    scrollBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    -- v0.5.6: these two were deleted in error by the v0.5.5 skinning pass -
    -- its regex removed the FIRST SetBackdropColor in the file, and this
    -- window had none of its own, so it ate the SCROLL background's instead
    -- 250 lines away. Without them the list area renders at the default
    -- bright grey. They match WoWClearance_ListWidget.lua, which is the
    -- reference for how a WC list background should look.
    scrollBg:SetBackdropColor(0, 0, 0, 0.6)
    scrollBg:SetBackdropBorderColor(0.4, 0.35, 0.25, 1)

    local scroll = CreateFrame("ScrollFrame", "WoWClearanceLootScroll", scrollBg, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -28, 6)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(290, 1)
    scroll:SetScrollChild(content)
    if NS.HookScrollbarAutoHide then
        NS.HookScrollbarAutoHide(scroll)
    end
    win.content = content
    -- v2.68.0: lootRenderVisible needs the viewport to know which slice of
    -- the array is on screen.
    win.scroll = scroll
    -- Re-bind the pooled rows as the view moves. HookScript, NOT SetScript:
    -- UIPanelScrollFrameTemplate's own OnVerticalScroll drives the
    -- scrollbar thumb, and replacing it would freeze the bar.
    scroll:HookScript("OnVerticalScroll", function()
        lootRenderVisible(win)
    end)

    -- Keep the scroll child's width in step with the (resizable) viewport so
    -- rows fill the window and never trigger a horizontal scrollbar. Rows
    -- anchor to content's TOPLEFT/TOPRIGHT, so they reflow automatically.
    scroll:SetScript("OnSizeChanged", function(_, w)
        if w and w > 0 then
            content:SetWidth(w)
        end
        -- v2.68.0: a taller viewport needs more pooled rows bound, a
        -- shorter one needs the surplus hidden. Cheap - re-binds only the
        -- visible slice, no rebuild.
        lootRenderVisible(win)
    end)

    -- Bottom-right resize grip (shared kit).
    NS.Kit.ResizeGrip(win, function()
        win:StopMovingOrSizing()
        lootRefresh(win)
    end)

    -- Live refresh while shown: loot accrues in the background, so a 1Hz
    -- tick keeps the open window current without a manual reopen. Cheap
    -- (one script call/sec, gated on visibility).
    win:SetScript("OnUpdate", function(self, elapsed)
        if not self:IsShown() then
            return
        end
        -- v2.75.0: skip the rebuild while dragging (OnDragStop refreshes once).
        if self._lootDragging then
            return
        end
        self._lootTick = (self._lootTick or 0) + elapsed
        -- v2.50.1: rebuild when new loot was actually credited (WC_BumpLoot
        -- flips WC_compCache.lootWindowDirty), coalesced to at most once a
        -- second so a multi-item loot burst rebuilds once. A 2 s safety
        -- refresh backs it up so the view can never go stale even if the
        -- flag is missed. Previously this rebuilt unconditionally every
        -- second - an open window kept calling GetItemInfo over every looted
        -- itemID and re-sorting even when nothing new had dropped (e.g. a
        -- boss fight with the window left open).
        -- v2.68.0: the unconditional safety refresh used to fire every 2 s
        -- forever. A rebuild walks every itemID in the scope calling
        -- GetItemInfo and re-sorts, so on Account scope (thousands of
        -- items) that was a full sweep twice a second-and-a-half, whether
        -- or not anything had changed. The dirty flag already catches real
        -- loot; the safety net only needs to be frequent while item names
        -- are still resolving from the cache primer. Once nothing is being
        -- primed it drops to a slow tick.
        local safetyEvery = (self._primedLast or 0) > 0 and 2.0 or 15.0
        if WC_compCache.lootWindowDirty and self._lootTick >= 1.0 then
            self._lootTick = 0
            WC_compCache.lootWindowDirty = false
            lootRefresh(self)
        elseif self._lootTick >= safetyEvery then
            self._lootTick = 0
            WC_compCache.lootWindowDirty = false
            lootRefresh(self)
        end
    end)

    -- v0.5.2 (Serv report): deliberately NOT added to UISpecialFrames.
    -- Closing any UI panel runs Blizzard's CloseSpecialWindows(), which
    -- hides EVERY frame named in that table - so while this window was
    -- registered there, closing the WoWClearance settings panel took the
    -- log window down with it. A log you open to read alongside the panel
    -- is exactly the thing that must outlive the panel.
    --
    -- The cost is that Escape no longer closes it. That is covered: the
    -- window carries a UIPanelCloseButton, which is the same way Blizzard's
    -- own detachable log windows are dismissed.
    --
    -- CONFIRMED BY THE OWNER 2026-09-19, after the alternatives were
    -- checked and ruled out: hideOnEscape does NOT help here (its only two
    -- consumers on this client are inside the StaticPopup machinery,
    -- StaticPopup.lua:845 and StaticPopupGamepad.lua:320 - a plain frame
    -- setting it gets nothing), and hand-rolling ESCAPE via EnableKeyboard
    -- was declined as not worth a new input-handling surface. Losing
    -- Escape here is a deliberate, accepted trade, not an oversight.
    -- Do not "restore" the UISpecialFrames line.

    -- Match a category-based host bag UI's window opacity (BagDisplay).
    win:HookScript("OnShow", NS.MatchHostBagOpacity)

    lootWindow = win
    return win
end

local function ToggleLootWindow()
    local win = lootEnsureWindow()
    if win:IsShown() then
        win:Hide()
        return
    end
    lootRefresh(win)
    win:Show()
    if win.Raise then
        win:Raise()
    end
end
NS.ToggleLootWindow = ToggleLootWindow
