-- WoWClearance_StatsPanel - dedicated stats sub-panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Holds every stat widget (statsMoney, statsSold, statsDeleted, statsRepairs,
-- statsRepairCost, statsNet, statsAvgWorth, statsMostSold, statsNote,
-- WoWClearanceResetStatsBtn). Looting numbers (Loot Log, looted coin, gold
-- per hour, top zones) live in the optional Loot module since v0.9.0.
-- These used to live on the Main panel; v2.36.x split them out so the Main
-- panel can read as a welcome page and Stats can grow.
--
-- RefreshStats (defined in WoWClearance_MainPanel.lua pre-split; re-homed
-- here post-split) writes to the panel.statsX attachments below. The
-- attachments are the public contract with the rest of the addon:
-- WoWClearance_Events.lua's data-change handlers call RefreshStats; this
-- file owns the panel object that holds the FontStrings.

local NS = select(2, ...)
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
        -- full-repaints only when a rendered counter actually changed. The
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
        -- `panel.statsMoney` and friends as the public contract with RefreshStats - keep the literals.
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

        -- Lifetime + session stats. Each panel.statsX is the contract
        -- with RefreshStats (called from WoWClearance_Events.lua's data
        -- handlers). Order matches the old MainPanel layout for visual
        -- continuity. The explicit panel.statsX = fs assignments below
        -- are the contract the test suite scans for - keep them literal
        -- (no table-driven indirection) so the static-pattern check can
        -- find them.
        -- v2.66.1 iter (Serv report): aggregate rows now use NS.MakeStatRow
        -- (row.left / row.right) so the value column aligns at a fixed X -
        -- lines up the columns. RefreshStats writes to
        -- row.left (label) and row.right (formatted value) instead of a
        -- single :SetText on the FontString.
        local AGGREGATE_VALUE_X = 200
        local function makeStatRow(yOffset, anchorPrev)
            return NS.MakeStatRow(content, anchorPrev, yOffset, AGGREGATE_VALUE_X)
        end

        -- v2.38.1: first stat row anchors below the started-at note now
        -- (was -44 from content TOPLEFT, which assumed the heading was
        -- the only thing above the stats).
        local money = makeStatRow(-16, startedAtNote)
        panel.statsMoney = money
        local sold = makeStatRow(-6, money)
        panel.statsSold = sold
        local deleted = makeStatRow(-6, sold)
        panel.statsDeleted = deleted
        local repairs = makeStatRow(-6, deleted)
        panel.statsRepairs = repairs
        local repairCost = makeStatRow(-6, repairs)
        panel.statsRepairCost = repairCost
        -- v0.7.0: money made - repair cost.
        local net = makeStatRow(-6, repairCost)
        panel.statsNet = net
        local avgWorth = makeStatRow(-6, net)
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
        -- X. RefreshStats writes to row.left (rank +
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

        -- v0.7.0: the last seven days, one row each, account-wide. Always
        -- seven rows (a quiet day reads "-"), so nothing below re-anchors
        -- on a hidden row.
        local days = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        days:SetPoint("TOPLEFT", lastProcess, "BOTTOMLEFT", 0, -10)
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
