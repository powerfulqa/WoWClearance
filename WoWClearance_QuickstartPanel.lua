-- WoWClearance_QuickstartPanel - guided setup wizard for new players.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- v2.38.0. The Quickstart panel is a one-click on-ramp: four preset
-- shortcuts at the top (Recommended / Cautious / Farmer / Power) pre-fill
-- a 16-question form below. The player can pick a preset and Apply, or
-- walk the questions, or pick a preset and then tweak individual answers.
-- Either path converges on a single Apply function.
--
-- Critical invariant: the apply path NEVER reads or writes any of the
-- four user-list tables (the per-character sell / keep / delete lists,
-- nor the account-wide sell list). User list data is sacred; the wizard
-- only changes SETTINGS (toggles, sliders, quality rules, etc.). Test
-- 88m in tests/test_perf_guardrails.lua locks this with a static-text
-- absence check on the relevant field names.
--
-- Cross-file dependencies satisfied by NS:
--   * NS.compCache (Core) - initPanel, deregisterWidth
--   * NS.DB captured at OnShow entry
--   * NS.MakeLabel / NS.FitScrollContent (PanelWidgets)
--   * NS.PrintNice / NS.PrintNicef (Events) - chat output

local NS = select(2, ...)
local WC_compCache = NS.compCache
local L = NS.L

-- v2.38.0: Quickstart is a standalone modal-ish frame parented to
-- UIParent (NOT an Interface Options sub-panel) so it doesn't show up
-- in the addon's sidebar. The only entry point is the "Open Quickstart"
-- button on the Main panel + the fresh-install auto-open. Closing the
-- panel just hides the frame; the global is retained for the next open.
-- UISpecialFrames entry makes Escape close it like a normal popup.
local QuickstartPanel = CreateFrame("Frame", "WoWClearanceOptionsQuickstart", UIParent, "DefaultPanelTemplate")
-- Width sized so labels using WC_PANEL_WIDTH (which is the Interface
-- Options container's width minus 40, typically ~580) fit inside the
-- scroll viewport without clipping. Math: scroll content needs to be
-- >= WC_PANEL_WIDTH; scroll content = panel.width - 32 (chrome) - 26
-- (scrollbar gutter); so panel.width >= WC_PANEL_WIDTH + 58. 660 gives
-- comfortable margin for the worst-case 580-px label and a bit beyond.
QuickstartPanel:SetSize(660, 600)
-- Scroll content width inside this window: 660 - 32 (inner frame insets)
-- - 26 (scrollbar gutter). Labels size against this, NOT the settings
-- window's width (setPanelWidth / MakeLabel), which is a different frame.
local QS_CONTENT_W = 602
local function qsWidth(widget, x)
    widget:SetWidth(QS_CONTENT_W - x)
end
QuickstartPanel:SetPoint("CENTER")
-- PORT NOTE: the "highest available" claim below is a 3.3.5a fact that has
-- NOT been re-measured on Forever, and the reason for it (host-addon
-- Interface Options wrappers) no longer applies now the options UI is on the
-- Settings API. Left as-is because the escalation is harmless and reverting
-- it untested would risk the original symptom; worth re-checking in-game.
-- TOOLTIP strata was the highest available in 3.3.5a - normally reserved
-- for GameTooltip, but escalated to here because FULLSCREEN_DIALOG (the
-- usual "modal dialog" strata) puts us behind host-addon Interface
-- Options wrappers that rebrand the panel. The tradeoff: while Quickstart
-- is showing, game tooltips that try to display behind our frame area
-- may render below us. Acceptable for a settings wizard the user closes
-- when done. SetToplevel + level 100 are belt-and-braces.
QuickstartPanel:SetFrameStrata("TOOLTIP")
QuickstartPanel:SetToplevel(true)
QuickstartPanel:SetFrameLevel(100)
QuickstartPanel:EnableMouse(true)
QuickstartPanel:SetMovable(true)
QuickstartPanel:SetClampedToScreen(true)
QuickstartPanel:RegisterForDrag("LeftButton")
QuickstartPanel:SetScript("OnDragStart", QuickstartPanel.StartMoving)
QuickstartPanel:SetScript("OnDragStop", QuickstartPanel.StopMovingOrSizing)
QuickstartPanel:Hide()
-- v0.5.5: border art now comes from DefaultPanelTemplate, so the
-- hand-rolled backdrop block that used to sit here is gone.
-- v0.5.3 (Serv report): deliberately NOT in UISpecialFrames, for the same
-- reason as the Loot Log and Sold History windows. Membership there is not
-- "Escape closes this", it is "this frame closes whenever anything calls
-- CloseWindows" (UIParentPanelManager.lua:1164 -> :1102, which Hide()s every
-- shown member unconditionally). Quickstart is a guided-setup window read
-- ALONGSIDE the settings panel, so closing the panel was taking it down
-- mid-setup. Dismissal is via its own close button. Owner-confirmed.

-- Title bar at the top of the chrome. Made grabbable for drag (the
-- whole frame is movable, so anywhere on the frame works, but the title
-- is the obvious drag handle).
do
    local titleFs = QuickstartPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleFs:SetPoint("TOP", QuickstartPanel, "TOP", 0, -18)
    -- v0.5.6 (Serv report): the title used to overlap the header art,
    -- because a FontString at y=-12 straddles the template's title strip.
    -- The template has a slot for exactly this.
    titleFs:SetText("")
    if NS.SkinWindow then
        NS.SkinWindow(QuickstartPanel, "WoWClearance: " .. L["Quickstart"])
    end

    local closeX = CreateFrame("Button", nil, QuickstartPanel, "UIPanelCloseButton")
    closeX:SetPoint("TOPRIGHT", 1, 0)
end

-- Inner content frame: the scroll wraps THIS, not the chrome frame, so
-- the title stays visible above the scroll viewport.
local QuickstartContent = CreateFrame("Frame", nil, QuickstartPanel)
QuickstartContent:SetPoint("TOPLEFT", QuickstartPanel, "TOPLEFT", 16, -44)
QuickstartContent:SetPoint("BOTTOMRIGHT", QuickstartPanel, "BOTTOMRIGHT", -16, 16)

-- Default fixed-iLvl cap for the Q4b "fixed cap" mode, used when the player
-- picks fixed mode without entering a number. The same for every rarity:
-- ten below the character's level, so only clearly outgrown gear sells. On
-- this client item level tracks character level (level 60 gear sits around
-- item level 55-65, the best raid gear around 80), so the old per-rarity
-- constants (45 / 85 / 125 / 165, from a higher item-level curve) sat above
-- every Uncommon, Rare and Epic item and would have sold all of them.
-- Indexed like a table so the call sites read the same as before.
local DEFAULT_FIXED_ILVL = setmetatable({}, {
    __index = function()
        return math.max(1, ((UnitLevel and UnitLevel("player")) or 1) - 10)
    end,
})

-- ============================================================================
-- ANSWER_MAP - each question's choice keys map to a function that writes
-- the relevant DB fields. Functions take the DB table (and optionally a
-- player-supplied numeric input table for Q4b's fixed-iLvl caps).
-- ============================================================================
local ANSWER_MAP = {
    speed = {
        normal = function(DB)
            DB.fastMode = false
            DB.turboMode = false
            DB.vendorInterval = 0.1
        end,
        fast = function(DB)
            DB.fastMode = true
            DB.turboMode = false
        end,
        turbo = function(DB)
            DB.fastMode = true
            DB.turboMode = true
        end,
    },
    fastLoot = {
        on = function(DB)
            DB.fastLoot = true
        end,
        off = function(DB)
            DB.fastLoot = false
        end,
    },
    autoOpen = {
        on = function(DB)
            DB.autoOpenContainers = true
        end,
        off = function(DB)
            DB.autoOpenContainers = false
        end,
    },
    autoSell = {
        none = function(DB)
            for q = 1, 4 do
                if DB.qualityRules[q] then
                    DB.qualityRules[q].enabled = false
                end
            end
        end,
        common = function(DB)
            DB.qualityRules[1].enabled = true
            for q = 2, 4 do
                if DB.qualityRules[q] then
                    DB.qualityRules[q].enabled = false
                end
            end
        end,
        commonUncommon = function(DB)
            DB.qualityRules[1].enabled = true
            DB.qualityRules[2].enabled = true
            for q = 3, 4 do
                if DB.qualityRules[q] then
                    DB.qualityRules[q].enabled = false
                end
            end
        end,
        upToRares = function(DB)
            DB.qualityRules[1].enabled = true
            DB.qualityRules[2].enabled = true
            DB.qualityRules[3].enabled = true
            DB.qualityRules[3].bindFilter = "boe"
            DB.qualityRules[4].enabled = false
        end,
    },
    -- The two Merchant Settings master switches. Without these a preset
    -- could "auto-sell outgrown gear" while vendor selling was switched off.
    vendorSell = {
        on = function(DB)
            DB.sellAtVendor = true
        end,
        off = function(DB)
            DB.sellAtVendor = false
        end,
    },
    greys = {
        on = function(DB)
            DB.sellGreys = true
        end,
        off = function(DB)
            DB.sellGreys = false
        end,
    },
    ilvlMode = {
        dynamic = function(DB)
            for q = 1, 4 do
                if DB.qualityRules[q] then
                    DB.qualityRules[q].useEquippedILvl = true
                end
            end
        end,
        fixed = function(DB, fixedCaps)
            for q = 1, 4 do
                if DB.qualityRules[q] then
                    DB.qualityRules[q].useEquippedILvl = false
                    local cap = (fixedCaps and tonumber(fixedCaps[q])) or DEFAULT_FIXED_ILVL[q]
                    if cap and cap > 0 and cap <= 400 then
                        DB.qualityRules[q].maxILvl = cap
                    else
                        DB.qualityRules[q].maxILvl = DEFAULT_FIXED_ILVL[q]
                    end
                end
            end
        end,
    },
    protect = {
        nothing = function(DB)
            DB.autoAddEquipped = false
            DB.autoProtectUpgrades = false
            DB.autoProtectEquipmentSets = false
        end,
        wearing = function(DB)
            DB.autoAddEquipped = true
            DB.autoProtectUpgrades = false
            DB.autoProtectEquipmentSets = false
        end,
        wearingUpgrades = function(DB)
            DB.autoAddEquipped = true
            DB.autoProtectUpgrades = true
            DB.autoProtectEquipmentSets = false
        end,
        wearingUpgradesSets = function(DB)
            DB.autoAddEquipped = true
            DB.autoProtectUpgrades = true
            DB.autoProtectEquipmentSets = true
        end,
    },
    tomes = {
        unlearned = function(DB)
            DB.protectUnlearnedTomes = true
            DB.protectAllTomes = false
        end,
        all = function(DB)
            DB.protectUnlearnedTomes = true
            DB.protectAllTomes = true
        end,
        off = function(DB)
            DB.protectUnlearnedTomes = false
            DB.protectAllTomes = false
        end,
    },
    -- v2.51.1: expanded from yes/no to no + three bind-filter variants.
    -- The bind filter (DB.sellKnownRecipeBindFilter[quality]) was
    -- Quickstart-invisible pre-v2.51.1 and defaulted to "any" via
    -- EnsureDB - the class of bug that hit Serv against Plans:
    -- Ragesteel Breastplate + Design: Shining Forest Emerald in v2.50.4
    -- / v2.50.5. Now the Quickstart answer explicitly sets all four
    -- qualities to the chosen filter so the tooltip verdict matches
    -- the vendor cycle from the first Quickstart run.
    sellRecipes = {
        no = function(DB)
            DB.sellKnownRecipes = false
        end,
        all = function(DB)
            DB.sellKnownRecipes = true
            DB.sellKnownRecipeQualities = { [1] = true, [2] = true, [3] = true, [4] = true }
            DB.sellKnownRecipeBindFilter = { [1] = "any", [2] = "any", [3] = "any", [4] = "any" }
        end,
        boeOnly = function(DB)
            DB.sellKnownRecipes = true
            DB.sellKnownRecipeQualities = { [1] = true, [2] = true, [3] = true, [4] = true }
            DB.sellKnownRecipeBindFilter = { [1] = "boe", [2] = "boe", [3] = "boe", [4] = "boe" }
        end,
        bopOnly = function(DB)
            DB.sellKnownRecipes = true
            DB.sellKnownRecipeQualities = { [1] = true, [2] = true, [3] = true, [4] = true }
            DB.sellKnownRecipeBindFilter = { [1] = "bop", [2] = "bop", [3] = "bop", [4] = "bop" }
        end,
    },
    -- v0.6.0: deleting is the player's own Delete Next press (the game
    -- refuses automatic deletes), so Q9b only asks whether Delete Next also
    -- takes grey items. Replaces the old vendor / pickup / loot tiers.
    greyDelete = {
        no = function(DB)
            DB.markGreyForDeletion = false
        end,
        yes = function(DB)
            DB.markGreyForDeletion = true
        end,
    },
    repair = {
        gold = function(DB)
            DB.repairGear = true
            DB.repairUseGuildBank = false
        end,
        guild = function(DB)
            DB.repairGear = true
            DB.repairUseGuildBank = true
        end,
        off = function(DB)
            DB.repairGear = false
            DB.repairUseGuildBank = false
        end,
    },
    keepBags = {
        yes = function(DB)
            DB.keepBagsOpen = true
        end,
        no = function(DB)
            DB.keepBagsOpen = false
        end,
    },
    delete = {
        yes = function(DB)
            DB.enableDeletion = true
        end,
        no = function(DB)
            DB.enableDeletion = false
        end,
    },
    ilvlSurfaces = {
        none = function(DB)
            DB.itemLevelOverlay.enabled = false
        end,
        bags = function(DB)
            DB.itemHighlighting = true -- the master switch would hide it
            DB.itemLevelOverlay.enabled = true
            DB.itemLevelOverlay.bags = true
            DB.itemLevelOverlay.paperdoll = false
            DB.itemLevelOverlay.merchant = false
        end,
        bagsPaperdoll = function(DB)
            DB.itemHighlighting = true
            DB.itemLevelOverlay.enabled = true
            DB.itemLevelOverlay.bags = true
            DB.itemLevelOverlay.paperdoll = true
            DB.itemLevelOverlay.merchant = false
        end,
        everywhere = function(DB)
            DB.itemHighlighting = true
            DB.itemLevelOverlay.enabled = true
            DB.itemLevelOverlay.bags = true
            DB.itemLevelOverlay.paperdoll = true
            DB.itemLevelOverlay.merchant = true
        end,
    },
    borders = {
        on = function(DB)
            DB.itemHighlighting = true
            DB.sellBorderEnabled = true
        end,
        off = function(DB)
            DB.sellBorderEnabled = false
        end,
    },
}

-- ============================================================================
-- PRESETS - each preset is a complete answer set for every question.
-- Differences from "recommended" are minimal; see plan file for the full
-- rationale.
-- ============================================================================
local PRESETS = {
    recommended = {
        name = L["Recommended"],
        desc = L["Auto-sells outgrown gear. Protects what you're wearing. Sensible defaults for most players."],
        answers = {
            speed = "normal",
            fastLoot = "on",
            autoOpen = "on",
            autoSell = "commonUncommon",
            ilvlMode = "dynamic",
            vendorSell = "on",
            greys = "on",
            protect = "wearing",
            tomes = "unlearned",
            sellRecipes = "no",
            repair = "gold",
            keepBags = "yes",
            delete = "yes",
            greyDelete = "no",
            ilvlSurfaces = "bags",
            borders = "on",
        },
    },
    cautious = {
        name = L["Cautious"],
        desc = L["Same auto-sell as Recommended, plus protects items that might upgrade you, items in your gear sets and every recipe. Delete Next is off."],
        answers = {
            speed = "normal",
            fastLoot = "on",
            autoOpen = "on",
            autoSell = "commonUncommon",
            ilvlMode = "dynamic",
            vendorSell = "on",
            greys = "on",
            protect = "wearingUpgradesSets",
            tomes = "all",
            sellRecipes = "no",
            repair = "gold",
            keepBags = "yes",
            delete = "no",
            greyDelete = "no",
            ilvlSurfaces = "bags",
            borders = "on",
        },
    },
    farmer = {
        name = L["Farmer"],
        desc = L["Fast vendoring, sells Rares too (BoE only - quest gear stays). Closes bags after."],
        answers = {
            speed = "fast",
            fastLoot = "on",
            autoOpen = "on",
            autoSell = "upToRares",
            ilvlMode = "dynamic",
            vendorSell = "on",
            greys = "on",
            protect = "wearing",
            tomes = "unlearned",
            sellRecipes = "boeOnly",
            repair = "guild",
            keepBags = "no",
            delete = "yes",
            greyDelete = "no",
            ilvlSurfaces = "bagsPaperdoll",
            borders = "on",
        },
    },
    power = {
        name = L["Power"],
        desc = L["Turbo vendoring, sells known recipes too, item levels everywhere. Read the disconnect warning."],
        answers = {
            speed = "turbo",
            fastLoot = "on",
            autoOpen = "on",
            autoSell = "upToRares",
            ilvlMode = "dynamic",
            vendorSell = "on",
            greys = "on",
            protect = "wearing",
            tomes = "unlearned",
            sellRecipes = "all",
            repair = "guild",
            keepBags = "no",
            delete = "yes",
            greyDelete = "no",
            ilvlSurfaces = "everywhere",
            borders = "on",
        },
    },
}

local PRESET_ORDER = { "recommended", "cautious", "farmer", "power" }

-- Local working state: the player's in-progress answers (mirrored to DB on
-- Apply). Initialised from the current DB on every panel show so a
-- returning user sees their existing settings reflected in the radios.
local workingAnswers = {}
local workingFixedCaps = { 0, 0, 0, 0 }

-- ============================================================================
-- Apply - writes the answer set to DB. Settings only; never touches the
-- four user-list tables (see file header for the full statement of the
-- invariant locked by Test 88m).
-- ============================================================================
local function WC_ApplyQuickstart(answers, fixedCaps, presetKey)
    local DB = NS.DB
    if not DB then
        return false, "DB not ready."
    end
    -- Apply each answered question.
    for questionKey, choiceKey in pairs(answers) do
        local question = ANSWER_MAP[questionKey]
        if question then
            local fn = question[choiceKey]
            if fn then
                fn(DB, fixedCaps)
            end
        end
    end
    DB._activeQuickstartPreset = presetKey -- nil when player tailored manually

    -- Repaint surfaces that reflect the new settings.
    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end
    if NS.RefreshItemLevelOverlay then
        NS.RefreshItemLevelOverlay()
    end
    local panelsToRefresh = {
        "WoWClearanceOptionsMain",
        "WoWClearanceOptionsMerchant",
        "WoWClearanceOptionsBlacklistSettings",
        -- v0.5.7: was "WoWClearanceOptionsItemHighlighting", which is not a
        -- frame that exists. The Item Highlighting panel keeps the frame
        -- name WoWClearanceOptionsCharacter for SavedVariables
        -- compatibility (see that file's header). The nil guard below meant
        -- the miss was silent, so that panel simply never refreshed after a
        -- Quickstart apply.
        "WoWClearanceOptionsCharacter",
        -- Refresh the Quickstart panel itself too so its radios snap to
        -- the new preset's answers after Apply.
        "WoWClearanceOptionsQuickstart",
    }
    for _, panelName in ipairs(panelsToRefresh) do
        local p = _G[panelName]
        if p and p.inited and p.GetScript and p:GetScript("OnShow") then
            -- Re-fire OnShow so the refresh callback in initPanel runs
            -- with the new DB state.
            p:GetScript("OnShow")(p)
        end
    end

    if NS.PrintNicef then
        if presetKey and PRESETS[presetKey] then
            NS.PrintNicef(
                L["|cffb6ffb6Quickstart applied:|r |cffffd870%s|r preset. Type |cffffff00/wc|r any time to tweak."],
                PRESETS[presetKey].name
            )
        else
            NS.PrintNicef(
                L["|cffb6ffb6Quickstart applied|r (tailored answers). Type |cffffff00/wc|r any time to tweak."]
            )
        end
    end
    return true
end

NS.Quickstart = {
    Apply = WC_ApplyQuickstart,
    PRESETS = PRESETS,
    PRESET_ORDER = PRESET_ORDER,
    ANSWER_MAP = ANSWER_MAP,
}

-- v2.38.0: immediate-apply for individual radio changes. Clicking a
-- radio writes its single answer to DB right away. Clears the active
-- preset (the player has diverged) and re-fires the OnShow handler on
-- any inited option panels so their widgets reflect the new state.
local function WC_ApplyAnswerImmediate(questionKey, value)
    local DB = NS.DB
    if not DB then
        return
    end
    local question = ANSWER_MAP[questionKey]
    if not question then
        return
    end
    local fn = question[value]
    if not fn then
        return
    end
    fn(DB, workingFixedCaps)
    DB._activeQuickstartPreset = nil
    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end
    if NS.RefreshItemLevelOverlay then
        NS.RefreshItemLevelOverlay()
    end
    local panelsToRefresh = {
        "WoWClearanceOptionsMerchant",
        "WoWClearanceOptionsBlacklistSettings",
        -- v0.5.7: was "WoWClearanceOptionsItemHighlighting", which is not a
        -- frame that exists. The Item Highlighting panel keeps the frame
        -- name WoWClearanceOptionsCharacter for SavedVariables
        -- compatibility (see that file's header). The nil guard below meant
        -- the miss was silent, so that panel simply never refreshed after a
        -- Quickstart apply.
        "WoWClearanceOptionsCharacter",
    }
    for _, panelName in ipairs(panelsToRefresh) do
        local p = _G[panelName]
        if p and p.inited and p.GetScript and p:GetScript("OnShow") then
            p:GetScript("OnShow")(p)
        end
    end
end

-- ============================================================================
-- UI - the question form. Radio buttons via UIRadioButtonTemplate, four
-- preset shortcut buttons at the top, four EditBox inputs that show only
-- when Q4b is set to "fixed cap" mode.
-- ============================================================================

local function snapshotAnswersFromDB(DB)
    local a = {}
    -- Q1 speed
    if DB.turboMode then
        a.speed = "turbo"
    elseif DB.fastMode then
        a.speed = "fast"
    else
        a.speed = "normal"
    end
    -- Q2-3 cycle toggles
    a.fastLoot = DB.fastLoot and "on" or "off"
    a.autoOpen = DB.autoOpenContainers and "on" or "off"
    -- Q4 auto-sell - infer from which qualityRules are enabled
    local r1 = DB.qualityRules and DB.qualityRules[1] and DB.qualityRules[1].enabled
    local r2 = DB.qualityRules and DB.qualityRules[2] and DB.qualityRules[2].enabled
    local r3 = DB.qualityRules and DB.qualityRules[3] and DB.qualityRules[3].enabled
    if r3 then
        a.autoSell = "upToRares"
    elseif r2 then
        a.autoSell = "commonUncommon"
    elseif r1 then
        a.autoSell = "common"
    else
        a.autoSell = "none"
    end
    a.vendorSell = DB.sellAtVendor ~= false and "on" or "off"
    a.greys = DB.sellGreys ~= false and "on" or "off"
    -- Q4b iLvl mode - look at the first enabled rule (or rule 1 if none)
    local sampleRule = DB.qualityRules and DB.qualityRules[1]
    a.ilvlMode = (sampleRule and sampleRule.useEquippedILvl) and "dynamic" or "fixed"
    -- Q6 protect
    if DB.autoProtectEquipmentSets then
        a.protect = "wearingUpgradesSets"
    elseif DB.autoProtectUpgrades then
        a.protect = "wearingUpgrades"
    elseif DB.autoAddEquipped then
        a.protect = "wearing"
    else
        a.protect = "nothing"
    end
    -- Q7b tomes
    if DB.protectAllTomes then
        a.tomes = "all"
    elseif DB.protectUnlearnedTomes then
        a.tomes = "unlearned"
    else
        a.tomes = "off"
    end
    -- Q9b sell known recipes. v2.51.1: also derive the shared bind
    -- filter across the four qualities. If they're all set to the same
    -- value ("boe" / "bop"), reflect that in the radio; otherwise fall
    -- back to "all" (which the ANSWER_MAP normalises to all-"any" on
    -- next answer selection - mixed states get flattened intentionally).
    if not DB.sellKnownRecipes then
        a.sellRecipes = "no"
    else
        local bf = DB.sellKnownRecipeBindFilter
        local uniform = bf and bf[1] and bf[1] == bf[2] and bf[2] == bf[3] and bf[3] == bf[4] and bf[1]
        if uniform == "boe" then
            a.sellRecipes = "boeOnly"
        elseif uniform == "bop" then
            a.sellRecipes = "bopOnly"
        else
            a.sellRecipes = "all"
        end
    end
    -- Q9b: does Delete Next also take grey items?
    a.greyDelete = DB.markGreyForDeletion and "yes" or "no"
    -- Q8 repair
    if not DB.repairGear then
        a.repair = "off"
    elseif DB.repairUseGuildBank then
        a.repair = "guild"
    else
        a.repair = "gold"
    end
    -- Q9-11
    a.keepBags = DB.keepBagsOpen and "yes" or "no"
    a.delete = DB.enableDeletion and "yes" or "no"
    -- Q12 iLvl surfaces
    local ilo = DB.itemLevelOverlay
    if not (ilo and ilo.enabled) or DB.itemHighlighting == false then
        a.ilvlSurfaces = "none"
    elseif ilo.merchant then
        a.ilvlSurfaces = "everywhere"
    elseif ilo.paperdoll then
        a.ilvlSurfaces = "bagsPaperdoll"
    else
        a.ilvlSurfaces = "bags"
    end
    -- Q13 borders
    a.borders = (DB.sellBorderEnabled and DB.itemHighlighting ~= false) and "on" or "off"

    -- Fixed-cap snapshot for Q4b's EditBoxes
    local caps = { 0, 0, 0, 0 }
    if DB.qualityRules then
        for q = 1, 4 do
            local r = DB.qualityRules[q]
            caps[q] = (r and r.maxILvl) or DEFAULT_FIXED_ILVL[q]
        end
    end
    return a, caps
end

-- Section header helper. Adds a coloured FontString anchored to a stop
-- anchor (always at section-X) so headers don't inherit any indent.
local function makeSectionHeader(content, text, anchor, gap)
    local fs = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, gap or -16)
    fs:SetText("|cffffd870" .. text .. "|r")
    return fs
end

-- Radio group. Anchors label + radios under `anchor` (assumed to be at
-- section-X, e.g. the previous section header or the previous group's
-- stop anchor). Returns a NEW invisible stop frame placed at section-X
-- under the last radio, so the next caller can chain without any indent
-- math.
local function makeRadioGroup(content, anchor, questionKey, prompt, options, refreshActiveTag, fixedCapsTrigger)
    local label = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
    qsWidth(label, 32)
    label:SetJustifyH("LEFT")
    if label.SetWordWrap then
        label:SetWordWrap(true)
    end
    label:SetText(prompt)

    local buttons = {}
    local prev = label
    for i, opt in ipairs(options) do
        local btn = CreateFrame("CheckButton", nil, content, "UIRadioButtonTemplate")
        btn:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", (i == 1) and 16 or 0, (i == 1) and -4 or -2)
        btn:SetChecked(workingAnswers[questionKey] == opt.value)
        local fs = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        fs:SetPoint("LEFT", btn, "RIGHT", 4, 0)
        fs:SetJustifyH("LEFT")
        if fs.SetWordWrap then
            fs:SetWordWrap(true)
        end
        qsWidth(fs, 80)
        fs:SetText(opt.label)
        btn:SetScript("OnClick", function()
            workingAnswers[questionKey] = opt.value
            for _, sib in ipairs(buttons) do
                sib:SetChecked(sib._optValue == opt.value)
            end
            -- v2.38.0: write to DB immediately. No staging step.
            WC_ApplyAnswerImmediate(questionKey, opt.value)
            if refreshActiveTag then
                refreshActiveTag()
            end
            if fixedCapsTrigger then
                fixedCapsTrigger(opt.value)
            end
        end)
        btn._optValue = opt.value
        btn._questionKey = questionKey
        buttons[#buttons + 1] = btn
        prev = btn
    end

    -- Stop anchor: invisible frame at section-X under the last radio.
    -- Compensates the 16-px radio indent so the next anchor starts at
    -- section-X without any caller-side X math.
    local stop = CreateFrame("Frame", nil, content)
    stop:SetSize(1, 1)
    stop:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", -16, 0)
    return stop
end

-- ============================================================================
-- Panel OnShow - build once, refresh on subsequent opens.
-- ============================================================================
local function buildPanel(self, content)
    -- Build path: first show. DB is ready after initPanel's EnsureDB
    -- ran. Snapshot before any radio button reads workingAnswers.
    local DB = NS.DB
    if DB then
        workingAnswers, workingFixedCaps = snapshotAnswersFromDB(DB)
    end
    -- Body of build follows. Wrapped in pcall by the OnShow handler so
    -- any runtime error surfaces in chat instead of silently leaving
    -- the panel empty.
        -- The window title already names the panel, so no inner header.
        -- The scroll content and the intro label are sized to this window,
        -- so take them out of the settings-window width registry.
        content:SetWidth(QS_CONTENT_W)
        WC_compCache.deregisterWidth(content)
        local intro = NS.MakeLabel(
            content,
            L["Pick a preset for instant setup, or answer the questions for a tailored config.\n"]
                .. L["|cffb6ffb6Every change applies immediately.|r Only |cffffd870settings|r change - your Sell, Keep, and Delete lists stay exactly as they are."],
            16,
            -16
        )
        WC_compCache.deregisterWidth(intro)
        qsWidth(intro, 32)

        -- ---------------------------------------------------------------
        -- Preset shortcut buttons (4 in a row)
        -- ---------------------------------------------------------------
        local presetLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        presetLabel:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -16)
        presetLabel:SetText(L["|cffffd870Pick a preset to start fast:|r"])

        local presetButtons = {}
        -- Active tag - smaller font, anchored CENTERED BELOW the active
        -- preset button so it doesn't look like it belongs to the
        -- neighbouring button.
        local presetActiveTag = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        presetActiveTag:SetText(L["|cffb6ffb6active|r"])
        presetActiveTag:Hide()

        local presetButtonRow = CreateFrame("Frame", nil, content)
        presetButtonRow:SetSize(500, 28)
        presetButtonRow:SetPoint("TOPLEFT", presetLabel, "BOTTOMLEFT", 0, -6)

        local presetX = 0
        for _, key in ipairs(PRESET_ORDER) do
            local p = PRESETS[key]
            local btn = CreateFrame("Button", nil, presetButtonRow, "UIPanelButtonTemplate")
            btn:SetSize(110, 22)
            btn:SetPoint("LEFT", presetButtonRow, "LEFT", presetX, 0)
            btn:SetText(p.name)
            btn:SetScript("OnEnter", function(self)
                -- Just the description: the button label already shows
                -- the preset name, so repeating it in the tooltip title
                -- is redundant.
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(p.desc, 0.9, 0.9, 0.9, 1, true)
                GameTooltip:Show()
                -- v2.38.1: the Quickstart frame sits at TOOLTIP strata
                -- with frame level 100. GameTooltip is at the same
                -- strata but parents under self (a child of Quickstart)
                -- so its level inherits below the parent + a Raise()
                -- alone doesn't beat the toplevel parent. Stamp a much
                -- higher absolute level so the description always wins.
                GameTooltip:SetFrameStrata("TOOLTIP")
                GameTooltip:SetFrameLevel(250)
            end)
            btn:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
            btn:SetScript("OnClick", function()
                -- v2.38.0: preset click shows a confirmation popup
                -- (because it changes 15 answers at once), then Apply
                -- writes everything. The radios visibly snap to the
                -- preset's answers AFTER the popup is accepted via the
                -- refresh-driven repaint.
                local dialog = StaticPopup_Show("WC_APPLY_QUICKSTART", p.name .. L[" preset"])
                if dialog then
                    local answersCopy = {}
                    for k, v in pairs(p.answers) do
                        answersCopy[k] = v
                    end
                    local capsCopy = {
                        workingFixedCaps[1],
                        workingFixedCaps[2],
                        workingFixedCaps[3],
                        workingFixedCaps[4],
                    }
                    dialog.data = {
                        answers = answersCopy,
                        fixedCaps = capsCopy,
                        presetKey = key,
                    }
                    -- Match Quickstart's TOOLTIP strata so the popup
                    -- doesn't get buried under Quickstart + any host
                    -- addon's Interface Options chrome. Raise within
                    -- the strata so we come up on top of Quickstart.
                    if dialog.SetFrameStrata then
                        dialog:SetFrameStrata("TOOLTIP")
                    end
                    if dialog.Raise then
                        dialog:Raise()
                    end
                end
                PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            end)
            presetButtons[key] = btn
            presetX = presetX + 116
        end

        -- Active-tag refresh: shows BELOW the currently-applied preset
        -- button, centered horizontally. TOP-to-BOTTOM anchoring keeps
        -- the tag centered against the button's width.
        local function refreshActiveTag()
            presetActiveTag:Hide()
            local DBlive = NS.DB
            local activeKey = DBlive and DBlive._activeQuickstartPreset
            if activeKey and presetButtons[activeKey] then
                presetActiveTag:ClearAllPoints()
                presetActiveTag:SetPoint("TOP", presetButtons[activeKey], "BOTTOM", 0, -2)
                presetActiveTag:Show()
            end
        end
        refreshActiveTag()
        self.refreshActiveTag = refreshActiveTag

        -- Gap of -16 px (was -6) to leave room for the small "active" tag
        -- that anchors centered below the active preset button. With -6
        -- the tag overlapped the start of this grey label.
        local presetDescLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        presetDescLabel:SetPoint("TOPLEFT", presetButtonRow, "BOTTOMLEFT", 0, -16)
        qsWidth(presetDescLabel, 32)
        presetDescLabel:SetJustifyH("LEFT")
        if presetDescLabel.SetWordWrap then
            presetDescLabel:SetWordWrap(true)
        end
        presetDescLabel:SetText(
            L["|cff888888Hover a preset for its description. Clicking shows a confirmation - presets change ~15 settings at once.|r"]
        )

        -- ---------------------------------------------------------------
        -- Question sections
        -- ---------------------------------------------------------------

        local refresh = refreshActiveTag

        local sec1 = makeSectionHeader(content, L["Section 1: Speed"], presetDescLabel, -20)

        local lastAnchor = makeRadioGroup(content, sec1, "speed", L["Q1. How fast should WC vendor at merchants?"], {
            { value = "normal", label = L["Normal"] },
            { value = "fast", label = L["Fast"] },
            { value = "turbo", label = L["Turbo  |cffff8000(may disconnect on bad connections)|r"] },
        }, refresh)

        -- The question numbering deliberately keeps its gaps (Q1, Q3, Q4...)
        -- rather than renumbering as questions are removed, so bug reports
        -- and Help references stay comparable across versions. Q2 asked about
        -- the Scavenger auto-loot cycle and went with that companion.

        lastAnchor = makeRadioGroup(
            content,
            lastAnchor,
            "fastLoot",
            L["Q2. Fast Loot (single-click clears loot windows)?"],
            {
                { value = "on", label = L["Yes"] },
                { value = "off", label = L["No"] },
            },
            refresh
        )

        lastAnchor = makeRadioGroup(
            content,
            lastAnchor,
            "autoOpen",
            L["Q3. Auto-open containers in your bags?"],
            {
                { value = "on", label = L["Yes - gift bags, pouches and picked lockboxes"] },
                { value = "off", label = L["No - I'll open them manually"] },
            },
            refresh
        )

        local sec2 = makeSectionHeader(content, L["Section 2: What WC Sells"], lastAnchor, -20)

        lastAnchor = makeRadioGroup(content, sec2, "autoSell", L["Q4. What should WC auto-sell?"], {
            { value = "none", label = L["Only items I add to the Sell List myself"] },
            { value = "common", label = L["Common items I've outgrown"] },
            { value = "commonUncommon", label = L["Common + Uncommon items I've outgrown"] },
            { value = "upToRares", label = L["Up through Rares (BoE only - protects quest gear)"] },
        }, refresh)

        -- Q5b: iLvl mode. When "fixed" is selected, show 4 EditBoxes.
        local ilvlModeAnchor = lastAnchor
        local fixedCapsLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        fixedCapsLabel:SetPoint("TOPLEFT", ilvlModeAnchor, "BOTTOMLEFT", 0, -10)
        qsWidth(fixedCapsLabel, 32)
        fixedCapsLabel:SetJustifyH("LEFT")
        if fixedCapsLabel.SetWordWrap then
            fixedCapsLabel:SetWordWrap(true)
        end
        -- v0.5.8 (Serv report): shown as "Q5b" immediately after Q4, so the
        -- panel read Q4, Q5b, Q5. It was mislabelled long before the v0.5.6
        -- renumbering - this refines Q4 ("what should WC auto-sell") and the
        -- code has always called it Q4b in its own comments at lines ~100,
        -- ~109 and ~603. The label was the only thing saying Q5b.
        --
        -- It escaped the renumbering pass because it is a SINGLE-quoted Lua
        -- string, and that pass matched double-quoted lookups only. Worth
        -- remembering: a
        -- sweep over player-facing strings has to cover both quote styles,
        -- and this file uses single quotes wherever the text contains an
        -- apostrophe.
        fixedCapsLabel:SetText(L['Q4b. How should WC decide what\'s "outgrown"?'])

        local dynBtn = CreateFrame("CheckButton", nil, content, "UIRadioButtonTemplate")
        dynBtn:SetPoint("TOPLEFT", fixedCapsLabel, "BOTTOMLEFT", 16, -4)
        dynBtn:SetChecked(workingAnswers.ilvlMode == "dynamic")
        local dynLbl = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        dynLbl:SetPoint("LEFT", dynBtn, "RIGHT", 4, 0)
        dynLbl:SetText(L["Compare to my currently-worn gear (dynamic, recommended)"])

        local fixBtn = CreateFrame("CheckButton", nil, content, "UIRadioButtonTemplate")
        fixBtn:SetPoint("TOPLEFT", dynBtn, "BOTTOMLEFT", 0, -2)
        fixBtn:SetChecked(workingAnswers.ilvlMode == "fixed")
        local fixLbl = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        fixLbl:SetPoint("LEFT", fixBtn, "RIGHT", 4, 0)
        fixLbl:SetText(L["Use a fixed item-level cap per rarity:"])

        -- The four EditBox inputs - one per rarity. Show only when "fixed".
        local rarityNames = { L["White"], L["Green"], L["Blue"], L["Epic"] }
        local capBoxes = {}
        local lastCapRowAnchor = fixBtn
        for q = 1, 4 do
            local row = CreateFrame("Frame", nil, content)
            row:SetSize(220, 22)
            row:SetPoint("TOPLEFT", lastCapRowAnchor, "BOTTOMLEFT", (q == 1) and 24 or 0, -4)

            local lbl = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            lbl:SetPoint("LEFT", row, "LEFT", 0, 0)
            lbl:SetWidth(80)
            lbl:SetJustifyH("LEFT")
            lbl:SetText(rarityNames[q] .. L[" cap:"])

            -- v2.44.3: explicit unique name (was nil). InputBoxTemplate
            -- references its *Left / *Middle / *Right child textures by
            -- global name, and NS.StyleInputBox uses _G[name .. "Left"]
            -- to normalize their draw layer. With a nil name those
            -- textures aren't reachable and the first editbox (White)
            -- rendered with stale template layering - subsequent boxes
            -- dodged the bug by creation timing. Mirrors the working
            -- Merchant Panel pattern (WoWClearanceQualityRowNInput).
            -- Reported by Luxus/ElvinT.
            local eb = CreateFrame(
                "EditBox",
                "WoWClearanceQuickstartCap" .. q .. "Input",
                row,
                "InputBoxTemplate"
            )
            eb:SetSize(60, 20)
            eb:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
            eb:SetAutoFocus(false)
            eb:SetNumeric(true)
            eb:SetMaxLetters(3)
            eb:SetText(tostring(workingFixedCaps[q] or DEFAULT_FIXED_ILVL[q]))
            eb:SetScript("OnTextChanged", function(self)
                workingFixedCaps[q] = tonumber(self:GetText()) or DEFAULT_FIXED_ILVL[q]
            end)
            -- v2.38.0: apply on lose-focus / Enter. Per-keystroke apply
            -- would thrash on every digit; the user finishes typing then
            -- tabs out (or hits Enter) to commit.
            local function commitCap()
                local DB = NS.DB
                if DB and workingAnswers.ilvlMode == "fixed" then
                    WC_ApplyAnswerImmediate("ilvlMode", "fixed")
                end
            end
            eb:SetScript("OnEditFocusLost", function()
                commitCap()
            end)
            eb:SetScript("OnEnterPressed", function(self)
                self:ClearFocus()
                commitCap()
            end)
            if NS.StyleInputBox then
                NS.StyleInputBox(eb)
            end
            capBoxes[q] = eb
            lastCapRowAnchor = row
        end

        local function updateCapBoxesVisible()
            local show = workingAnswers.ilvlMode == "fixed"
            for q = 1, 4 do
                if capBoxes[q] then
                    if show then
                        capBoxes[q]:GetParent():Show()
                        -- v2.44.3: EditBox:Enable() is Cataclysm+ only -
                        -- calling it on 3.3.5a throws "attempt to call
                        -- method 'Enable' (a nil value)". The editbox is
                        -- enabled by default; Show() on the parent row
                        -- is sufficient. WC-TRAP: don't reintroduce an
                        -- Enable / Disable pair here without using
                        -- EnableMouse / EnableKeyboard, which DO exist.
                    else
                        capBoxes[q]:GetParent():Hide()
                    end
                end
            end
            -- Reposition the stop anchor so the next question sits right
            -- below whatever's currently visible. In dynamic mode the cap
            -- rows are hidden, so we anchor the stop directly below the
            -- fixBtn instead of below the (hidden) cap rows. In fixed
            -- mode the stop sits below the last cap row.
            if self.q5bStop then
                self.q5bStop:ClearAllPoints()
                -- v2.44.3: -8 Y offset (was 0) so Q6's label sits ~22px
                -- below the last cap row instead of ~11px. The tight gap
                -- collapsed to visual overlap with Q6 on low UI scales
                -- (Luxus's Q5b screenshot, useUiScale + 0.66 effective).
                if show then
                    self.q5bStop:SetPoint("TOPLEFT", lastCapRowAnchor, "BOTTOMLEFT", -40, -8)
                else
                    self.q5bStop:SetPoint("TOPLEFT", fixBtn, "BOTTOMLEFT", -16, -8)
                end
            end
        end

        dynBtn:SetScript("OnClick", function()
            workingAnswers.ilvlMode = "dynamic"
            dynBtn:SetChecked(true)
            fixBtn:SetChecked(false)
            updateCapBoxesVisible()
            WC_ApplyAnswerImmediate("ilvlMode", "dynamic")
            refresh()
        end)
        fixBtn:SetScript("OnClick", function()
            workingAnswers.ilvlMode = "fixed"
            fixBtn:SetChecked(true)
            dynBtn:SetChecked(false)
            updateCapBoxesVisible()
            WC_ApplyAnswerImmediate("ilvlMode", "fixed")
            refresh()
        end)
        dynBtn._questionKey = "ilvlMode"
        dynBtn._optValue = "dynamic"
        fixBtn._questionKey = "ilvlMode"
        fixBtn._optValue = "fixed"

        -- Stop anchor: stored on self so updateCapBoxesVisible can
        -- reposition it as the mode toggles between dynamic and fixed.
        -- Created BEFORE the first updateCapBoxesVisible call so the
        -- initial visibility-driven positioning happens immediately.
        local q5bStop = CreateFrame("Frame", nil, content)
        -- v2.44.3: 14px tall (was 1px) so the gap to Q6 survives low UI
        -- scales. Initial anchor matches updateCapBoxesVisible's "fixed"
        -- branch (-40 X, -8 Y). updateCapBoxesVisible runs immediately
        -- after and rebinds for the actual mode.
        q5bStop:SetSize(1, 14)
        q5bStop:SetPoint("TOPLEFT", lastCapRowAnchor, "BOTTOMLEFT", -40, -8)
        self.q5bStop = q5bStop
        lastAnchor = q5bStop

        -- Initial visibility + stop-anchor positioning. Done now (after
        -- self.q5bStop is set) so the very first paint in dynamic mode
        -- doesn't leave a phantom gap below hidden cap rows.
        updateCapBoxesVisible()

        lastAnchor = makeRadioGroup(content, lastAnchor, "greys", L["Q4c. Sell grey (junk) items?"], {
            { value = "on", label = L["Yes (default)"] },
            { value = "off", label = L["No - keep my greys"] },
        }, refresh)

        lastAnchor = makeRadioGroup(content, lastAnchor, "vendorSell", L["Q4d. Sell by itself when you open a vendor?"], {
            { value = "on", label = L["Yes (default)"] },
            { value = "off", label = L["No - another addon sells for me, or I use the Force Sell key"] },
        }, refresh)

        local sec3 = makeSectionHeader(content, L["Section 3: What WC Protects"], lastAnchor, -20)

        lastAnchor = makeRadioGroup(content, sec3, "protect", L["Q5. What should WC auto-protect from selling?"], {
            { value = "nothing", label = L["Nothing - I'll use the Keep List myself"] },
            { value = "wearing", label = L["What I'm currently wearing"] },
            { value = "wearingUpgrades", label = L["Currently wearing + items that would be upgrades"] },
            { value = "wearingUpgradesSets", label = L["All of the above + items in my saved gear sets"] },
        }, refresh)

        -- v0.5.7 (Serv report): reworded from "tomes" to "recipes". Tomes do
        -- not exist on WoW: Forever; crafting recipes do, and the underlying
        -- protection covers both. The question is kept and renamed rather
        -- than removed, because the feature it configures is still live and
        -- still useful - only the word for a thing this game does not have
        -- was wrong.
        --
        -- The DB fields keep their names (protectUnlearnedTomes /
        -- protectAllTomes) on purpose: renaming saved-variable keys would
        -- need a migration and gains nothing a player can see. Do not
        -- "tidy" them to match this label.
        lastAnchor = makeRadioGroup(content, lastAnchor, "tomes", L["Q6. Recipe protection"], {
            { value = "unlearned", label = L["Protect recipes I haven't learned yet (recommended)"] },
            {
                value = "all",
                label = L["Protect ALL recipes - even ones I've already learned (useful for sharing with alts)"],
            },
            { value = "off", label = L["Don't protect recipes"] },
        }, refresh)

        lastAnchor = makeRadioGroup(content, lastAnchor, "sellRecipes", L["Q6b. Sell recipes you've already learned?"], {
            { value = "no", label = L["No, keep my learned recipes (default)"] },
            {
                value = "all",
                label = L["Yes, all recipes (any bind type)"],
            },
            {
                value = "boeOnly",
                label = L["Yes, but only BoE recipes (safer - keeps soulbound recipes for alts)"],
            },
            {
                value = "bopOnly",
                label = L["Yes, but only BoP recipes"],
            },
        }, refresh)

        local sec4 = makeSectionHeader(content, L["Section 4: At the Vendor"], lastAnchor, -20)

        lastAnchor = makeRadioGroup(content, sec4, "repair", L["Q7. Auto-repair gear at merchants?"], {
            { value = "gold", label = L["Yes, pay from my gold"] },
            { value = "guild", label = L["Yes, use guild bank funds if available"] },
            { value = "off", label = L["No - I'll repair manually"] },
        }, refresh)

        lastAnchor = makeRadioGroup(content, lastAnchor, "keepBags", L["Q8. Keep bags open after WC's vendor cycle?"], {
            { value = "yes", label = L["Yes - useful for buyback"] },
            { value = "no", label = L["No - close them when done"] },
        }, refresh)

        lastAnchor = makeRadioGroup(
            content,
            lastAnchor,
            "delete",
            L["Q9. Let WC delete Delete-List items when you press Delete Next?"],
            {
                { value = "no", label = L["No - never delete anything"] },
                { value = "yes", label = L["Yes - one item per press (default)"] },
            },
            refresh
        )

        lastAnchor = makeRadioGroup(
            content,
            lastAnchor,
            "greyDelete",
            L["Q9b. Should Delete Next also remove grey items?"],
            {
                { value = "no", label = L["No - only my Delete List (default)"] },
                { value = "yes", label = L["Yes - greys too, cheapest first"] },
            },
            refresh
        )

        local sec5 = makeSectionHeader(content, L["Section 5: Visual Helpers"], lastAnchor, -20)

        lastAnchor = makeRadioGroup(content, sec5, "ilvlSurfaces", L["Q10. Show item levels on equipment slots?"], {
            { value = "none", label = L["Don't show item levels"] },
            { value = "bags", label = L["On bag slots only"] },
            { value = "bagsPaperdoll", label = L["Bag slots + character sheet / inspect"] },
            { value = "everywhere", label = L["Bag slots + character sheet + merchant window"] },
        }, refresh)

        lastAnchor = makeRadioGroup(
            content,
            lastAnchor,
            "borders",
            L["Q11. Colour bag-slot borders by what WC will do?"],
            {
                { value = "on", label = L["Yes (Red = delete, Cyan = sell, etc.)"] },
                { value = "off", label = L["No"] },
            },
            refresh
        )

        -- ---------------------------------------------------------------
        -- Close button (the only one - changes apply immediately on each
        -- radio click + EditBox commit, so there's no separate Apply step)
        -- ---------------------------------------------------------------
        local btnRow = CreateFrame("Frame", nil, content)
        btnRow:SetSize(500, 32)
        btnRow:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -24)

        local closeBtn = CreateFrame("Button", nil, btnRow, "UIPanelButtonTemplate")
        closeBtn:SetSize(140, 22)
        closeBtn:SetPoint("LEFT", btnRow, "LEFT", 16, 0)
        closeBtn:SetText(L["Close"])
        closeBtn:SetScript("OnClick", function()
            QuickstartPanel:Hide()
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
        end)

        -- Pin the form's bottom-most child for FitScrollContent
        local bottomFooter = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        bottomFooter:SetPoint("TOPLEFT", btnRow, "BOTTOMLEFT", 16, -8)
        qsWidth(bottomFooter, 48)
        bottomFooter:SetJustifyH("LEFT")
        if bottomFooter.SetWordWrap then
            bottomFooter:SetWordWrap(true)
        end
        bottomFooter:SetText(
            L["|cff888888Quickstart only writes settings. Your Sell, Keep, and Delete lists are never touched.|r"]
        )

        -- repaintRadios: re-snap every radio button to the workingAnswers.
        -- Called when a preset button is clicked OR when the panel re-shows
        -- with a fresh DB snapshot.
        -- Walk content's children to capture (button, question) pairs.
        -- We tagged each radio with _optValue earlier; the question key
        -- isn't stored directly, so we hold the map indirectly through
        -- the workingAnswers state - repaint by matching values.
        self.repaintRadios = function()
            for _, child in ipairs({ content:GetChildren() }) do
                if child:GetObjectType() == "CheckButton" and child._optValue ~= nil then
                    -- We can't know the question key from the button alone,
                    -- so the simpler approach: each button knows its
                    -- _questionKey via setter below.
                    if child._questionKey then
                        child:SetChecked(workingAnswers[child._questionKey] == child._optValue)
                    end
                end
            end
            -- Q5b dynamic / fixed buttons specifically
            dynBtn:SetChecked(workingAnswers.ilvlMode == "dynamic")
            fixBtn:SetChecked(workingAnswers.ilvlMode == "fixed")
            updateCapBoxesVisible()
            -- EditBox text from workingFixedCaps
            for q = 1, 4 do
                if capBoxes[q] then
                    capBoxes[q]:SetText(tostring(workingFixedCaps[q] or DEFAULT_FIXED_ILVL[q]))
                end
            end
        end

        NS.FitScrollContent(content, bottomFooter)
end

QuickstartPanel:SetScript("OnShow", function()
    -- initPanel runs on the inner content frame (not the chrome frame).
    -- This keeps the title + close X visible above the scrolling form
    -- and isolates the inited flag from the chrome.
    WC_compCache.initPanel(QuickstartContent, function(self)
        -- Refresh path: initPanel just called EnsureDB, so NS.DB is
        -- populated. Re-snapshot the answers + update the radios.
        local DB = NS.DB
        if DB then
            workingAnswers, workingFixedCaps = snapshotAnswersFromDB(DB)
        end
        if self.repaintRadios then
            self.repaintRadios()
        end
        if self.refreshActiveTag then
            self.refreshActiveTag()
        end
    end, function(self, content)
        -- Build is wrapped in pcall so a runtime error surfaces in chat
        -- instead of silently leaving the panel empty (the v2.37.3
        -- inited-true-but-half-built trap caught us once before).
        local ok, err = pcall(buildPanel, self, content)
        if not ok and NS.PrintNicef then
            NS.PrintNicef("|cffff4444Quickstart build error:|r %s", tostring(err))
        end
    end, true) -- wrapScroll = true

    -- Mirror the inner content's `inited` flag onto the chrome frame so
    -- the cross-panel refresh loop (in WC_ApplyQuickstart) sees this
    -- panel as built and re-fires OnShow on it. Without this, the
    -- "active" tag doesn't reposition when switching presets.
    QuickstartPanel.inited = QuickstartContent.inited

    -- Belt-and-braces: even at TOOLTIP strata, a host UI replacement
    -- could raise one of its own frames to the top of the same strata.
    -- Raise() guarantees we sit above them on each show.
    if QuickstartPanel.Raise then
        QuickstartPanel:Raise()
    end
end)

-- v2.38.0: Quickstart is a standalone modal-ish frame (UIParent-parented
-- with TOOLTIP strata), NOT an Interface Options sub-panel. The frame
-- is intentionally absent from the addon's sidebar - the only entry
-- points are the "Open Quickstart" button on the Main panel and the
-- fresh-install PLAYER_LOGIN auto-open. No InterfaceOptions_AddCategory
-- call exists for this file by design.
