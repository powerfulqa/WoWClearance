-- WoWClearance_ProtectionPanel - Keep Settings Interface Options panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-vi of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The Keep Settings UI panel (v2.49.3 renamed the sidebar label from
-- "Protection Settings" to "Keep Settings"; internal frame name
-- "WoWClearanceOptionsBlacklistSettings" preserves the v2.15.0 schema
-- and is intentionally NOT renamed - help links / deep-links depend on
-- it). Hosts the auto-protect / keep toggles (autoAddEquipped /
-- autoProtectUpgrades / autoProtectEquipmentSets) and the tome /
-- recipe protection toggles.
-- v2.49.3: "Sell recipes you already know" (a sell rule) moved OUT to
-- WoWClearance_MerchantPanel.lua.
--
-- Moved into this file:
--   * local BlacklistSettingsPanel = CreateFrame(...) frame creation
--   * The Keep Settings OnShow handler (panel-build body)
--
-- Cross-file dependencies satisfied by NS:
--   * NS.compCache (Core) - initPanel, setPanelWidth, registerWidth,
--     syncEquipped, checkBagsForUpgrades, syncEquipmentSets,
--   * NS.DB captured at OnShow entry
--   * NS.MakeHeader / NS.MakeLabel (8e-i)
--   * NS.FitScrollContent (8e-ii)
--   * NS.RefreshSellBorders (BagDisplay) - used by the protection
--     OnClick handlers per the
--     Issue B fix (Test 42 invariant)
--
-- The panel does NOT use AddCheckbox / AddSlider; it builds checkboxes
-- inline because one of the toggles (allTomeCB) carries
-- dynamic status-feedback FontStrings that the flat-row AddCheckbox
-- format can't host. The explanatory notes that used to sit under
-- every toggle were stripped in Task 15 of the help-link refactor;
-- each toggle now links to its Help-panel entry via NS.AddHelpIcon
-- next to the label.

local NS = select(2, ...)
local WC_compCache = NS.compCache
local L = NS.L

-- ============================================================
-- Holds the auto-protect toggles + explanatory notes that previously
-- cluttered the Keep List panel. Schema and behaviour are identical to the
-- pre-v2.15.0 surfacing; this is purely a visual split for consistency with
-- the other list panels' rhythm. The toggles still write to the same DB
-- fields (DB.autoAddEquipped, DB.autoProtectUpgrades, DB.autoProtectEquipmentSets)
-- and still call the same sync helpers (WC_compCache.syncEquipped /
-- checkBagsForUpgrades / syncEquipmentSets), so the PLAYER_EQUIPMENT_CHANGED
-- and EQUIPMENT_SETS_CHANGED reactive paths in the event hub continue to
-- drive the same protection without any wiring changes.
local BlacklistSettingsPanel =
    CreateFrame("Frame", "WoWClearanceOptionsBlacklistSettings", NS.OptionsHost())
BlacklistSettingsPanel.name = "Keep Settings"
BlacklistSettingsPanel.parent = "WoWClearance"

BlacklistSettingsPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    WC_compCache.initPanel(self, function(self)
        if self.autoEquipCB then
            self.autoEquipCB:SetChecked(DB.autoAddEquipped)
        end
        if self.autoUpgradeCB then
            self.autoUpgradeCB:SetChecked(DB.autoProtectUpgrades)
        end
        if self.autoSetCB then
            self.autoSetCB:SetChecked(DB.autoProtectEquipmentSets)
        end
        if self.protectHiILvlCB then
            self.protectHiILvlCB:SetChecked(DB.automarkProtectHighILvl ~= false)
        end
        if self.unlearnedTomeCB then
            self.unlearnedTomeCB:SetChecked(DB.protectUnlearnedTomes)
        end
        if self.allTomeCB then
            self.allTomeCB:SetChecked(DB.protectAllTomes)
        end
        if self.UpdateAllTomeEnabled then
            self:UpdateAllTomeEnabled()
        end
        if self.appearanceCB then
            self.appearanceCB:SetChecked(DB.protectUncollectedAppearances)
        end
        if self.tradeableCB then
            self.tradeableCB:SetChecked(DB.protectTradeableLoot)
        end
    end, function(self, content)
        -- Auto-protect handlers used to refresh `self.listUI` directly because
        -- the list lived on the same frame. Now the list lives on the Keep List
        -- panel, so toggles refresh that panel's list if it's been initialized.
        local function refreshKeepListUI()
            local blPanel = _G["WoWClearanceOptionsBlacklist"]
            if blPanel and blPanel.listUI then
                blPanel.listUI:Refresh()
            end
        end

        NS.MakeHeader(content, L["Keep Settings"], -16)
        local desc = NS.MakeLabel(
            content,
            L["Rules that keep specific items safe from selling. You can override any of them on a single item with Alt+Right-Click - Allow Sell."],
            16,
            -44
        )

        -- v2.10.0: auto-protect equipped gear. Toggling on runs a one-shot sync
        -- of every currently equipped slot into the Keep List, then a reactive
        -- PLAYER_EQUIPMENT_CHANGED handler keeps the list in step with future
        -- gear swaps. The blacklist veto in WC_IsSellable prevents auto-rules
        -- from touching anything on this list, so a replaced upgrade sliding
        -- into bags is automatically protected. Tooltip annotation surfaces
        -- "(auto-protected: equipped)" so users who decide they want an
        -- auto-added item sold can see why it's being kept.
        local autoEquipCB = CreateFrame(
            "CheckButton",
            "WoWClearanceAutoProtectEquippedCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        autoEquipCB:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)
        autoEquipCB:SetChecked(DB.autoAddEquipped)
        local aeText = _G[autoEquipCB:GetName() .. "Text"]
        if aeText then
            aeText:SetText(L["Keep gear you're wearing"])
            WC_compCache.setPanelWidth(aeText, 60)
            aeText:SetJustifyH("LEFT")
        end
        autoEquipCB:SetScript("OnClick", function(cb)
            local on = cb:GetChecked() and true or false
            local wasOff = (DB.autoAddEquipped ~= true)
            DB.autoAddEquipped = on
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            if on and wasOff then
                WC_compCache.syncEquipped()
                refreshKeepListUI()
            end
        end)
        self.autoEquipCB = autoEquipCB
        if aeText then
            NS.AddHelpIcon(content, aeText, "LEFT", "RIGHT", 6, 0, "gate-equipped-never-sells")
        end

        -- v2.11.0 auto-protect upgrades. The companion to v2.10.0's auto-
        -- protect-equipped: this one watches BAG_UPDATE for items whose iLvl
        -- exceeds the equipped item in any of their candidate slots (rings,
        -- trinkets, weapons compare against the lower of the two equipped
        -- slots so any genuine upgrade triggers). Looted upgrades sitting in
        -- bags are stamped on the Keep list before any iLvl-cap rule on
        -- Merchant Settings can sweep them up. Default off; opt-in.
        local autoUpgradeCB = CreateFrame(
            "CheckButton",
            "WoWClearanceAutoProtectUpgradesCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        autoUpgradeCB:SetPoint("TOPLEFT", autoEquipCB, "BOTTOMLEFT", 0, -10)
        autoUpgradeCB:SetChecked(DB.autoProtectUpgrades)
        local auText = _G[autoUpgradeCB:GetName() .. "Text"]
        if auText then
            auText:SetText(L["Keep upgrades found in bags"])
            WC_compCache.setPanelWidth(auText, 60)
            auText:SetJustifyH("LEFT")
        end
        autoUpgradeCB:SetScript("OnClick", function(cb)
            DB.autoProtectUpgrades = cb:GetChecked() and true or false
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            if DB.autoProtectUpgrades then
                -- Re-check on toggle so existing bag contents are evaluated
                -- immediately rather than waiting for the next BAG_UPDATE.
                WC_compCache.checkBagsForUpgrades()
                refreshKeepListUI()
            end
        end)
        self.autoUpgradeCB = autoUpgradeCB
        if auText then
            NS.AddHelpIcon(content, auText, "LEFT", "RIGHT", 6, 0, "tshoot-upgrade-keep")
        end

        -- v2.13.0 Equipment Manager protection. Catches the dual-spec /
        -- off-set gap: items assigned to your alternate Blizzard equipment
        -- set sit in bags between swaps and aren't protected by
        -- autoAddEquipped (which only catches currently-equipped slots).
        -- One-shot sync at toggle, then EQUIPMENT_SETS_CHANGED reactive.
        local autoSetCB =
            CreateFrame("CheckButton", "WoWClearanceAutoProtectSetsCB", content, "InterfaceOptionsCheckButtonTemplate")
        autoSetCB:SetPoint("TOPLEFT", autoUpgradeCB, "BOTTOMLEFT", 0, -10)
        autoSetCB:SetChecked(DB.autoProtectEquipmentSets)
        local asText = _G[autoSetCB:GetName() .. "Text"]
        if asText then
            asText:SetText(L["Keep items in your saved equipment sets"])
            WC_compCache.setPanelWidth(asText, 60)
            asText:SetJustifyH("LEFT")
        end
        autoSetCB:SetScript("OnClick", function(cb)
            local on = cb:GetChecked() and true or false
            local wasOff = (DB.autoProtectEquipmentSets ~= true)
            DB.autoProtectEquipmentSets = on
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            if on and wasOff then
                WC_compCache.syncEquipmentSets(false)
                refreshKeepListUI()
            end
        end)
        self.autoSetCB = autoSetCB
        if asText then
            NS.AddHelpIcon(content, asText, "LEFT", "RIGHT", 6, 0, "label-keep-gear-set")
        end

        -- "Protect iLvl <N>+ items from auto-mark", where N is
        -- NS.AUTOMARK_PROTECT_ILVL (80 on this client, 200 pre-port).
        -- Sub-toggle for the
        -- v2.57.2 iLvl safety net that skips auto-mark on any item at
        -- iLvl >= that constant. Default ON (preserves the Bizzaro-style protection
        -- against auto-trashing a brand-new high-value drop). Turn OFF to
        -- allow auto-mark to catch old high-iLvl PvP gear the player has
        -- grown out of. Other safety nets (Keep List, gear-set members,
        -- currently equipped, quest items) stay unconditional either way.
        -- Lives here in Keep Settings for consistency with the other
        -- "Protect X" toggles, though it affects the Delete Settings
        -- auto-mark scans.
        --
        -- NOT removed with the Project Ebonhold surface even though it sat
        -- inside that run in the panel layout: the Resilience and
        -- learned-recipe auto-mark scans still consult
        -- DB.automarkProtectHighILvl, so dropping the checkbox would have
        -- left a live setting with no way to reach it.
        local protectHiILvlCB = CreateFrame(
            "CheckButton",
            "WoWClearanceAutoMarkProtectHighILvlCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        protectHiILvlCB:SetPoint("TOPLEFT", autoSetCB, "BOTTOMLEFT", 0, -10)
        protectHiILvlCB:SetChecked(DB.automarkProtectHighILvl ~= false)
        local protectHiILvlText = _G[protectHiILvlCB:GetName() .. "Text"]
        if protectHiILvlText then
            protectHiILvlText:SetText(string.format(L["Protect iLvl %d+ items from auto-mark"], NS.AUTOMARK_PROTECT_ILVL or 80))
            WC_compCache.setPanelWidth(protectHiILvlText, 86)
            protectHiILvlText:SetJustifyH("LEFT")
            if protectHiILvlText.SetWordWrap then
                protectHiILvlText:SetWordWrap(true)
            end
        end
        protectHiILvlCB:SetScript("OnClick", function(cb)
            DB.automarkProtectHighILvl = cb:GetChecked() and true or false
            PlaySound(DB.automarkProtectHighILvl and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
        end)
        self.protectHiILvlCB = protectHiILvlCB
        if protectHiILvlText then
            NS.AddHelpIcon(content, protectHiILvlText, "LEFT", "RIGHT", 6, 0, "gate-automark-protect-high-ilvl")
        end

        -- Tome protection. Parent + child checkbox pair:
        --   * Parent (unlearnedTomeCB) controls DB.protectUnlearnedTomes -
        --     when ON, unlearned spell-teaching items (recipes, tomes,
        --     scrolls) are protected.
        --   * Child (allTomeCB), indented and only enabled when parent is
        --     ON, controls DB.protectAllTomes - extends the protection to
        --     items the character has already learned.
        -- Both HARD-VETO in WC_IsSellable: a protected tome / recipe
        -- cannot be vendored even when on the Sell List - the user must
        -- explicitly Alt+Right-Click -> Allow Sell first.
        local unlearnedTomeCB = CreateFrame(
            "CheckButton",
            "WoWClearanceProtectUnlearnedTomesCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        unlearnedTomeCB:SetPoint("TOPLEFT", protectHiILvlCB, "BOTTOMLEFT", 0, -10)
        unlearnedTomeCB:SetChecked(DB.protectUnlearnedTomes)
        local utText = _G[unlearnedTomeCB:GetName() .. "Text"]
        if utText then
            -- v0.5.7: "tomes" dropped - they do not exist on this client. Same
            -- feature, same DB fields; only the label changed.
            utText:SetText(L["Keep unlearned recipes"])
            WC_compCache.setPanelWidth(utText, 60)
            utText:SetJustifyH("LEFT")
        end
        self.unlearnedTomeCB = unlearnedTomeCB
        if utText then
            NS.AddHelpIcon(content, utText, "LEFT", "RIGHT", 6, 0, "gate-tome-recipe")
        end

        -- Child toggle: extends protection to already-known items.
        -- Indented +26 from the parent CB so it sits a column further
        -- right (pre-Task 15 this
        -- inherited the indent from the parent's explanatory note, but
        -- the note was stripped and the indent is now applied directly).
        local allTomeCB = CreateFrame(
            "CheckButton",
            "WoWClearanceProtectAllTomesCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        allTomeCB:SetPoint("TOPLEFT", unlearnedTomeCB, "BOTTOMLEFT", 26, -8)
        allTomeCB:SetChecked(DB.protectAllTomes)
        local atText = _G[allTomeCB:GetName() .. "Text"]
        if atText then
            atText:SetText(L["Keep them even after you learn them"])
            WC_compCache.setPanelWidth(atText, 86)
            atText:SetJustifyH("LEFT")
        end
        self.allTomeCB = allTomeCB
        if atText then
            NS.AddHelpIcon(content, atText, "LEFT", "RIGHT", 6, 0, "label-tome-have")
        end

        -- Status-feedback FontString. After Task 15 the explanatory text
        -- for the active case lives in the Help panel ([?] icon above);
        -- this note now only carries the disabled-state status message
        -- ("Turn on the protection above"). FitScrollContent uses this
        -- as the bottom-most widget so the scroll area still sizes
        -- correctly when the note is empty.
        local allTomeNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        allTomeNote:SetPoint("TOPLEFT", allTomeCB, "BOTTOMLEFT", 26, -2)
        WC_compCache.setPanelWidth(allTomeNote, 86)
        allTomeNote:SetJustifyH("LEFT")
        if allTomeNote.SetWordWrap then
            allTomeNote:SetWordWrap(true)
        end
        self.allTomeNote = allTomeNote

        allTomeCB:SetScript("OnClick", function(cb)
            DB.protectAllTomes = cb:GetChecked() and true or false
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
        end)

        -- Greys-out the child CB when the parent is off, swapping the
        -- explanatory note for a status line. Same shape as
        -- the parent/child enable pattern used above.
        local function UpdateAllTomeEnabled()
            local parentOn = DB.protectUnlearnedTomes == true
            if parentOn then
                allTomeCB:Enable()
                if atText then
                    atText:SetTextColor(1, 0.82, 0)
                end
                allTomeNote:SetText("")
            else
                allTomeCB:Disable()
                if atText then
                    atText:SetTextColor(0.5, 0.5, 0.5)
                end
                allTomeNote:SetText(L["|cff888888Turn on the protection above to use this option.|r"])
            end
        end
        self.UpdateAllTomeEnabled = UpdateAllTomeEnabled
        UpdateAllTomeEnabled()

        unlearnedTomeCB:SetScript("OnClick", function(cb)
            DB.protectUnlearnedTomes = cb:GetChecked() and true or false
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            UpdateAllTomeEnabled()
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
        end)

        -- v0.5.2: a SECOND SetPoint on unlearnedTomeCB used to sit here,
        -- anchoring it to autoSetCB. SetPoint ADDS an anchor rather than
        -- replacing one, so the frame kept both this and the correct anchor
        -- at line ~262 and came to rest exactly on top of protectHiILvlCB -
        -- two checkboxes and two labels drawn in one row, and clicks landing
        -- on whichever was on top, which is why the tick appeared dead.
        -- Almost certainly left behind when protectHiILvlCB was inserted
        -- between autoSetCB and this row. The correct anchor is the one
        -- above; do not re-add one here.

        -- v2.49.3: "Sell recipes you already know" (+ per-rarity gates and
        -- bind dropdowns) moved to Merchant Settings - it is a sell rule,
        -- not a keep rule. The tome KEEP controls stay here. The runtime
        -- "keep all tomes wins over sell-known-recipes" precedence still
        -- lives in WC_IsSellable, unchanged.
        -- v0.6.0 Forever protections. Both stop the auto-sell rules only;
        -- the Sell List and Allow Sell still sell (see Decision.sell).
        local function makeProtectCB(globalName, field, label, anchor, x, y)
            local cb = CreateFrame("CheckButton", globalName, content, "InterfaceOptionsCheckButtonTemplate")
            cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", x, y)
            cb:SetChecked(DB[field])
            local text = _G[globalName .. "Text"]
            if text then
                text:SetText(label)
                WC_compCache.setPanelWidth(text, 86)
                text:SetJustifyH("LEFT")
                if text.SetWordWrap then
                    text:SetWordWrap(true)
                end
            end
            cb:SetScript("OnClick", function(btn)
                DB[field] = btn:GetChecked() and true or false
                PlaySound(DB[field] and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
                if NS.RefreshSellBorders then
                    NS.RefreshSellBorders()
                end
            end)
            return cb
        end
        -- allTomeNote sits 52 px right of the checkbox column (two indents).
        local appearanceCB = makeProtectCB(
            "WoWClearanceProtectAppearanceCB",
            "protectUncollectedAppearances",
            L["Keep gear with an appearance you haven't collected"],
            allTomeNote,
            -52,
            -10
        )
        self.appearanceCB = appearanceCB
        local tradeableCB = makeProtectCB(
            "WoWClearanceProtectTradeableCB",
            "protectTradeableLoot",
            L["Keep loot you can still trade or refund"],
            appearanceCB,
            0,
            -10
        )
        self.tradeableCB = tradeableCB

        NS.FitScrollContent(content, tradeableCB)
    end, true)
end)
