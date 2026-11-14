-- WoWClearance_MerchantPanel - Merchant Settings Interface Options panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-ii of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The Merchant Settings UI panel: vendor mode dropdown, repair toggles,
-- vendor interval / max-items sliders, fast-mode toggle, per-rarity
-- rule rows (White/Green/Blue/Epic with iLvl caps + bind filter +
-- useEquippedILvl toggle).
--
-- Moved into this file:
--   * WC_WHITELIST_QUALITIES dropdown data (rarity labels for the
--     per-rarity rule rows)
--   * MerchantPanel frame (named "WoWClearanceOptionsMerchant")
--   * The MerchantPanel OnShow handler (the panel-build body that
--     constructs all the dropdowns, sliders, and per-rarity rule rows)
--
-- Cross-file dependencies read inline:
--   * NS.compCache (Core) - initPanel, setPanelWidth, registerWidth,
--     refreshLayouts, getBindType
--   * NS.DB captured at OnShow entry
--   * NS.MakeHeader / NS.MakeLabel (WoWClearance_Events.lua) - panel text;
--     NS-exposed in Stage 8e-i.
--   * NS.AddCheckbox / NS.AddSlider / NS.ColorTextByQuality /
--     NS.StyleInputBox / NS.FitScrollContent (WoWClearance_Events.lua) -
--     panel widget primitives; NS-exposed as Stage 8e-ii prep.
--   * NS.PrintNice / NS.PrintNicef (WoWClearance_Events.lua) - chat output.
--   * Various WoW globals - CreateFrame,
--     PlaySound, GameTooltip, etc.

local NS = select(2, ...)
local WC_compCache = NS.compCache
local L = NS.L

-- Quality-threshold options shared by the Merchant Settings panel.
--
-- The table is constructed inside the OnShow build callback (not at file
-- load time) because this file loads BEFORE WoWClearance_Events.lua and the
-- NS.ColorTextByQuality binding doesn't exist yet at load. Eager table
-- construction would call nil here. The build callback runs lazily on
-- first OnShow, by which time WoWClearance_Events.lua has loaded and NS is
-- fully populated. The OnShow build is gated by initPanel's "build
-- only once" lock so this evaluates exactly once per session, same as
-- the original file-scope upvalue.
local WC_WHITELIST_QUALITIES   -- assigned inside the build callback below

local MerchantPanel = CreateFrame("Frame", "WoWClearanceOptionsMerchant", NS.OptionsHost())
MerchantPanel.name = "Merchant Settings"
MerchantPanel.parent = "WoWClearance"

MerchantPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    WC_compCache.initPanel(self, function(self)
        if self.sellAtVendorCB then
            self.sellAtVendorCB:SetChecked(DB.sellAtVendor ~= false)
        end
        if self.sellGreysCB then
            self.sellGreysCB:SetChecked(DB.sellGreys ~= false)
        end
        if self.repairCB then
            self.repairCB:SetChecked(DB.repairGear)
        end
        if self.guildRepairCB then
            self.guildRepairCB:SetChecked(DB.repairUseGuildBank)
        end
        if self.keepBagsCB then
            self.keepBagsCB:SetChecked(DB.keepBagsOpen)
        end
        if self.speedSlider then
            self.speedSlider:SetValue(DB.vendorInterval or 0.1)
        end
        if self.fastModeCB then
            self.fastModeCB:SetChecked(DB.fastMode)
        end
        if self.turboModeCB then
            self.turboModeCB:SetChecked(DB.turboMode)
        end
        if self.refreshSpeedReadout then
            self.refreshSpeedReadout()
        end
        for q = 1, 4 do
            local cb = self["qualityRow" .. q .. "CB"]
            local input = self["qualityRow" .. q .. "Input"]
            local dd = self["qualityRow" .. q .. "DD"]
            local useEqCB = self["qualityRow" .. q .. "UseEq"]
            if cb and DB.qualityRules and DB.qualityRules[q] then
                cb:SetChecked(DB.qualityRules[q].enabled)
            end
            if input and DB.qualityRules and DB.qualityRules[q] then
                input:SetText(tostring(DB.qualityRules[q].maxILvl or 0))
            end
            if dd and DB.qualityRules and DB.qualityRules[q] and self._BindFilterText then
                dd:SetText(self._BindFilterText(DB.qualityRules[q].bindFilter))
            end
            -- v2.12.0: refresh the per-rarity Use-equipped-iLvl tickbox
            -- and the maxILvl input's enabled state. The applyInputEnabled
            -- helper was stashed on the row's main checkbox at build time.
            if useEqCB and DB.qualityRules and DB.qualityRules[q] then
                useEqCB:SetChecked(DB.qualityRules[q].useEquippedILvl == true)
            end
            if cb and cb._applyInputEnabled then
                cb._applyInputEnabled()
            end
        end
        -- v2.49.3: re-sync the moved "Sell recipes you already know" controls.
        if self.sellRecipesCB then
            self.sellRecipesCB:SetChecked(DB.sellKnownRecipes)
        end
        if self.recipeQualityCBs then
            for q = 1, 4 do
                local qcb = self.recipeQualityCBs[q]
                if qcb then
                    qcb:SetChecked(DB.sellKnownRecipeQualities and DB.sellKnownRecipeQualities[q])
                end
            end
        end
        if self.recipeBindDDs and self._BindFilterText then
            for q = 1, 4 do
                local dd = self.recipeBindDDs[q]
                if dd then
                    local v = (DB.sellKnownRecipeBindFilter and DB.sellKnownRecipeBindFilter[q]) or "any"
                    dd:SetText(self._BindFilterText(v))
                end
            end
        end
        if self.UpdateRecipeQualitiesEnabled then
            self:UpdateRecipeQualitiesEnabled()
        end
    end, function(self, content)
        -- Build-time table population. See the WC_WHITELIST_QUALITIES
        -- declaration above for why this can't run at file load.
        WC_WHITELIST_QUALITIES = {
            { text = NS.ColorTextByQuality(1, L["Common"]), value = 1 },
            { text = NS.ColorTextByQuality(2, L["Uncommon"]), value = 2 },
            { text = NS.ColorTextByQuality(3, L["Rare"]), value = 3 },
            { text = NS.ColorTextByQuality(4, L["Epic"]), value = 4 },
        }

        NS.MakeHeader(content, L["Merchant Settings"], -16)
        -- Panel-specific intro only. Generic "grey junk auto-sells" cross-cut
        -- removed; it's covered on the Main panel.
        local intro =
            NS.MakeLabel(content, L["Change which items sell automatically, and at which merchants."], 16, -44)

        -- Master switch for the automatic sell at a vendor. Off leaves repair
        -- and the Force Sell key working.
        local sellAtVendorCB = NS.AddCheckbox(
            content,
            "WoWClearanceSellAtVendorCB",
            intro,
            L["Sell items at vendors"],
            function()
                return DB.sellAtVendor ~= false
            end,
            function(v)
                DB.sellAtVendor = v
            end
        )
        sellAtVendorCB:ClearAllPoints()
        sellAtVendorCB:SetPoint("TOPLEFT", 16, -76)
        self.sellAtVendorCB = sellAtVendorCB
        NS.AddHelpIcon(content, _G[sellAtVendorCB:GetName() .. "Text"], "LEFT", "RIGHT", 6, 0, "gate-sell-at-vendor")

        local sellGreysCB = NS.AddCheckbox(
            content,
            "WoWClearanceSellGreysCB",
            sellAtVendorCB,
            L["Sell grey items"],
            function()
                return DB.sellGreys ~= false
            end,
            function(v)
                DB.sellGreys = v
                if NS.RefreshSellBorders then
                    NS.RefreshSellBorders()
                end
            end,
            -2
        )
        self.sellGreysCB = sellGreysCB
        NS.AddHelpIcon(content, _G[sellGreysCB:GetName() .. "Text"], "LEFT", "RIGHT", 6, 0, "gate-sell-greys")

        local repairCB =
            CreateFrame("CheckButton", "WoWClearanceRepairGearCB", content, "InterfaceOptionsCheckButtonTemplate")
        repairCB:SetPoint("TOPLEFT", sellGreysCB, "BOTTOMLEFT", 0, -6)
        repairCB:SetChecked(DB.repairGear)
        local rt = _G[repairCB:GetName() .. "Text"]
        if rt then
            rt:SetText(L["Repair gear while selling"])
            -- v2.59.8: reactive width matches the shared NS.AddCheckbox
            -- helper. v2.66.1 iter: bumped from 42 to 60 (matching the
            -- shared helper's new default) so the [?] icon at text:RIGHT
            -- + 6 stays inside the scrollbar zone.
            WC_compCache.setPanelWidth(rt, 60)
            rt:SetJustifyH("LEFT")
            if rt.SetWordWrap then
                rt:SetWordWrap(true)
            end
        end
        repairCB:SetScript("OnClick", function()
            DB.repairGear = repairCB:GetChecked() and true or false
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
        self.repairCB = repairCB
        if rt then
            -- v2.66.1 iter (Serv report): right-edge-align across the
            -- panel to match Keep Settings. Label FontString is already
            -- reactive-wide via setPanelWidth above; anchor LEFT-to-RIGHT
            -- puts the icon at the label's right edge (panel edge minus
            -- inset).
            NS.AddHelpIcon(content, rt, "LEFT", "RIGHT", 6, 0, "gate-repair")
        end

        -- Guild-bank funded repair. Indented under the master repair toggle so
        -- the visual hierarchy reads "repair, and prefer guild bank if I can".
        -- The runtime path falls back to personal gold whenever the bank can't
        -- supply the full amount, so toggling this on is safe even on alts who
        -- aren't in a guild.
        local guildRepairCB =
            CreateFrame("CheckButton", "WoWClearanceRepairGuildBankCB", content, "InterfaceOptionsCheckButtonTemplate")
        guildRepairCB:SetPoint("TOPLEFT", repairCB, "BOTTOMLEFT", 22, -2)
        guildRepairCB:SetChecked(DB.repairUseGuildBank)
        local grt = _G[guildRepairCB:GetName() .. "Text"]
        if grt then
            grt:SetText(L["Pay from guild bank when possible"])
            WC_compCache.setPanelWidth(grt, 80)
            grt:SetJustifyH("LEFT")
        end
        guildRepairCB:SetScript("OnClick", function()
            DB.repairUseGuildBank = guildRepairCB:GetChecked() and true or false
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
        self.guildRepairCB = guildRepairCB
        if grt then
            NS.AddHelpIcon(content, grt, "LEFT", "RIGHT", 6, 0, "gate-guild-bank-repair")
        end

        local keepBagsCB =
            CreateFrame("CheckButton", "WoWClearanceKeepBagsOpenCB", content, "InterfaceOptionsCheckButtonTemplate")
        keepBagsCB:SetPoint("TOPLEFT", guildRepairCB, "BOTTOMLEFT", -22, -6)
        keepBagsCB:SetChecked(DB.keepBagsOpen)
        local kbt = _G[keepBagsCB:GetName() .. "Text"]
        if kbt then
            kbt:SetText(L["Keep bags open after talking to a merchant"])
            WC_compCache.setPanelWidth(kbt, 60)
            kbt:SetJustifyH("LEFT")
        end
        keepBagsCB:SetScript("OnClick", function()
            DB.keepBagsOpen = keepBagsCB:GetChecked() and true or false
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
        self.keepBagsCB = keepBagsCB
        if kbt then
            NS.AddHelpIcon(content, kbt, "LEFT", "RIGHT", 6, 0, "gate-keep-bags-open")
        end

        -- v2.37.7: slider label changed from "Vendoring Speed" to
        -- "Time between sells" because the value semantic is INTERVAL
        -- (lower = faster). The old "Speed" label invited players to
        -- drag the slider to its maximum value thinking they were
        -- selecting maximum speed; they were actually selecting maximum
        -- delay between sells. A live readout below the slider now
        -- translates the interval into items/second so the practical
        -- effect is visible.
        local speedSlider = NS.AddSlider(
            content,
            "WoWClearanceVendoringSpeedSlider",
            keepBagsCB,
            L["Time between sells"],
            0.05,
            0.500,
            0.01,
            function()
                return DB.vendorInterval or 0.1
            end,
            function(v)
                DB.vendorInterval = v
            end,
            -16
        )
        self.speedSlider = speedSlider
        speedSlider:SetWidth(200)
        -- v2.66.1 iter: anchor to the slider's label FontString (inline
        -- with the label at the top of the slider) instead of the
        -- slider frame's TOPRIGHT corner. Matches Keep Settings' slider
        -- [?] pattern.
        local speedSliderText = _G["WoWClearanceVendoringSpeedSliderText"]
        NS.AddHelpIcon(
            content,
            speedSliderText or speedSlider,
            "LEFT",
            speedSliderText and "RIGHT" or "TOPRIGHT",
            6,
            0,
            "gate-sell-speed"
        )

        -- v2.37.7: live items/sec readout. Updated whenever the slider
        -- moves OR when Fast Mode / Turbo Mode toggles flip the
        -- effective rate. Format matches: "About 10 sells per second"
        -- with a parenthesised note when Fast Mode is overriding the
        -- slider value so the user knows what's actually in effect.
        local speedReadout = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        -- Anchor below the slider's Low label rather than the track's
        -- BOTTOMLEFT so the readout doesn't overlap the slider's
        -- "0.050s" min/max labels (OptionsSliderTemplate positions Low /
        -- High BELOW the track, so slider:BOTTOMLEFT is above them).
        local lowLabel = _G[speedSlider:GetName() .. "Low"]
        if lowLabel then
            speedReadout:SetPoint("TOPLEFT", lowLabel, "BOTTOMLEFT", 0, -8)
        else
            speedReadout:SetPoint("TOPLEFT", speedSlider, "BOTTOMLEFT", 0, -20)
        end
        WC_compCache.setPanelWidth(speedReadout, 60)
        speedReadout:SetJustifyH("LEFT")
        if speedReadout.SetWordWrap then
            speedReadout:SetWordWrap(true)
        end
        self.speedReadout = speedReadout

        -- The readout shows the SLIDER's interpretation as the primary
        -- number so dragging the slider always changes the visible
        -- value, even with Fast Mode on. When Fast Mode overrides the
        -- slider value, a secondary "(Fast Mode active: N/sec)" note
        -- surfaces what's actually going to happen at the vendor.
        local function refreshSpeedReadout()
            local sliderValue = DB.vendorInterval or 0.1
            if sliderValue < 0.05 then
                sliderValue = 0.05
            end
            local batch = DB.turboMode and 4 or 1
            local sliderRate = batch / sliderValue
            local effectiveInterval = DB.fastMode and 0.05 or sliderValue
            local effectiveRate = batch / effectiveInterval
            local mainText = string.format(L["About %.0f sells per second."], sliderRate)
            local noteText = ""
            if DB.fastMode and math.abs(sliderRate - effectiveRate) > 0.5 then
                noteText = string.format(L["  |cffaaaaaa(Fast Mode active: %.0f/sec)|r"], effectiveRate)
            elseif DB.fastMode and DB.turboMode then
                noteText = L["  |cffaaaaaa(Fast + Turbo)|r"]
            elseif DB.fastMode then
                noteText = L["  |cffaaaaaa(Fast Mode)|r"]
            elseif DB.turboMode then
                noteText = L["  |cffaaaaaa(Turbo Mode)|r"]
            end
            speedReadout:SetText(mainText .. noteText)
        end
        refreshSpeedReadout()
        speedSlider:HookScript("OnValueChanged", refreshSpeedReadout)
        self.refreshSpeedReadout = refreshSpeedReadout

        local fastModeCB = NS.AddCheckbox(
            content,
            "WoWClearanceFastModeCB",
            speedReadout,
            L["Fast Mode (0.05 s interval, 160-item cap)"],
            function()
                return DB.fastMode
            end,
            function(v)
                DB.fastMode = v
                refreshSpeedReadout()
            end,
            -10
        )
        self.fastModeCB = fastModeCB
        do
            local fmt = _G[fastModeCB:GetName() .. "Text"]
            if fmt then
                NS.AddHelpIcon(content, fmt, "LEFT", "RIGHT", 6, 0, "gate-fast-mode")
            end
        end

        local fastModeNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        fastModeNote:SetPoint("TOPLEFT", fastModeCB, "BOTTOMLEFT", 26, -2)
        WC_compCache.setPanelWidth(fastModeNote, 60)
        fastModeNote:SetJustifyH("LEFT")
        if fastModeNote.SetWordWrap then
            fastModeNote:SetWordWrap(true)
        end
        fastModeNote:SetText(
            L["|cff888888May cause disconnects on unstable connections - turn off if it does.|r"]
        )

        -- v2.37.7: Turbo Mode - pops multiple items per worker fire.
        -- Stacks with Fast Mode; the live readout reflects whichever
        -- combination is in effect. AddCheckbox anchors the new
        -- checkbox at the previous anchor's X, but our anchor here is
        -- fastModeNote which is indented +26 px to sit under the
        -- fastModeCB text. Without an override the Turbo checkbox would
        -- inherit that indent and cascade the indent to every widget
        -- below it (Quality Threshold etc.). ClearAllPoints + manual
        -- SetPoint snaps it back to fastModeCB's left column.
        local turboModeCB = NS.AddCheckbox(
            content,
            "WoWClearanceTurboModeCB",
            fastModeNote,
            L["Turbo Mode (4 items per cycle - bag-clear in seconds)"],
            function()
                return DB.turboMode
            end,
            function(v)
                DB.turboMode = v
                refreshSpeedReadout()
            end,
            -10
        )
        turboModeCB:ClearAllPoints()
        turboModeCB:SetPoint("TOPLEFT", fastModeNote, "BOTTOMLEFT", -26, -10)
        self.turboModeCB = turboModeCB
        do
            local tmt = _G[turboModeCB:GetName() .. "Text"]
            if tmt then
                NS.AddHelpIcon(content, tmt, "LEFT", "RIGHT", 6, 0, "gate-turbo-mode")
            end
        end

        local turboModeNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        turboModeNote:SetPoint("TOPLEFT", turboModeCB, "BOTTOMLEFT", 26, -2)
        WC_compCache.setPanelWidth(turboModeNote, 60)
        turboModeNote:SetJustifyH("LEFT")
        if turboModeNote.SetWordWrap then
            turboModeNote:SetWordWrap(true)
        end
        turboModeNote:SetText(
            L["|cff888888Combine with Fast Mode for the fastest cycle. Turn off if you see disconnects.|r"]
        )

        -- Quality threshold (v2.4.0+): three per-rarity rows, each independently
        -- togglable with its own optional max iLvl. Replaces the old single-dropdown
        -- "sell up to quality X" model. Default all off; opt-in per rarity.
        local thresholdHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        thresholdHeader:SetPoint("TOPLEFT", turboModeNote, "BOTTOMLEFT", -26, -24)
        thresholdHeader:SetText(L["Quality Threshold"])
        NS.AddHelpIcon(content, thresholdHeader, "LEFT", "RIGHT", 6, 0, "gate-quality-rules")

        -- v2.10.0: bind-type filter options shared across all four rarity rows.
        -- "any" = today's behaviour (rule applies regardless of bind type);
        -- "boe" / "bop" restrict to items the tooltip says bind on equip /
        -- on pickup. Items with no bind line at all read as "any" from
        -- WC_compCache.getBindType so reagents/consumables/quest items are
        -- protected when bindFilter is "boe" or "bop".
        local WC_BIND_FILTER_OPTIONS = {
            { text = L["Any bind type"], value = "any" },
            { text = L["BoE only"], value = "boe" },
            { text = L["BoP only"], value = "bop" },
        }
        local function WC_BindFilterText(value)
            for _, entry in ipairs(WC_BIND_FILTER_OPTIONS) do
                if entry.value == value then
                    return entry.text
                end
            end
            return WC_BIND_FILTER_OPTIONS[1].text
        end

        -- Build a row per rarity. Each row: checkbox on the left, "max iLvl:"
        -- label + numeric input on the right (0-300). Below the checkbox, a
        -- "Bind: <Any/BoE/BoP>" dropdown that gates the rule on bind type.
        -- Returns the bind dropdown so the next row's anchor descends past
        -- the second line cleanly.
        local function MakeQualityRow(anchor, qualityIdx, labelText, yOff)
            local cb = NS.AddCheckbox(
                content,
                "WoWClearanceQualityRow" .. qualityIdx .. "CB",
                anchor,
                labelText,
                function()
                    return DB.qualityRules[qualityIdx].enabled
                end,
                function(v)
                    DB.qualityRules[qualityIdx].enabled = v
                    -- Per-rarity rule flip changes WC_IsSellable's
                    -- qualityPass for every slot of this rarity.
                    -- Repaint so slot tints track immediately. Same
                    -- rule as the list-mutation refresh invariant.
                    if NS.RefreshSellBorders then
                        NS.RefreshSellBorders()
                    end
                end,
                yOff
            )

            local input =
                CreateFrame("EditBox", "WoWClearanceQualityRow" .. qualityIdx .. "Input", content, "InputBoxTemplate")
            input:SetSize(50, 20)
            -- Anchored to content's right edge with a small margin. Content's
            -- right edge already sits 26 px inside the panel (scrollbar gutter),
            -- so -6 here matches the original panel-anchored -32 offset visually.
            input:SetPoint("RIGHT", content, "RIGHT", -6, 0)
            input:SetPoint("TOP", cb, "TOP", 0, -2)
            input:SetAutoFocus(false)
            input:SetNumeric(true)
            input:SetMaxLetters(3)
            input:SetText(tostring(DB.qualityRules[qualityIdx].maxILvl or 0))
            NS.StyleInputBox(input)

            local lbl = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
            lbl:SetPoint("RIGHT", input, "LEFT", -6, 0)
            lbl:SetText(L["max iLvl:"])

            -- v2.12.0: per-rarity "Use equipped iLvl" tickbox. When checked,
            -- the maxILvl input is ignored at runtime and the cap is the
            -- player's currently-equipped iLvl in the same slot (per-item
            -- via WC_compCache.isDowngradeVsEquipped). The input is visibly
            -- disabled while this is checked so the user understands the
            -- maxILvl number isn't being applied.
            local useEqCB = CreateFrame(
                "CheckButton",
                "WoWClearanceQualityRow" .. qualityIdx .. "UseEqCB",
                content,
                "InterfaceOptionsCheckButtonTemplate"
            )
            useEqCB:SetPoint("RIGHT", lbl, "LEFT", -8, 0)
            useEqCB:SetChecked(DB.qualityRules[qualityIdx].useEquippedILvl == true)
            -- The InterfaceOptionsCheckButtonTemplate auto-creates a label
            -- to the RIGHT of the box; that label would extend rightward
            -- into the "max iLvl:" field on this layout. Blank the
            -- auto-generated label and place a separate FontString to the
            -- LEFT of the box instead so the row reads
            -- "<rarity>  Use equipped iLvl [✓]  max iLvl: [   ]".
            local autoLabel = _G[useEqCB:GetName() .. "Text"]
            if autoLabel then
                autoLabel:SetText("")
            end
            local useEqText = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
            useEqText:SetPoint("RIGHT", useEqCB, "LEFT", -2, 0)
            useEqText:SetText(L["Use equipped iLvl"])

            -- iLvl-mode help: [?] sits just left of the "Use equipped iLvl"
            -- toggle (the controls it explains), deep-linking the fixed-cap
            -- vs. equipped-iLvl entry. The bind-filter [?] on the second
            -- line below links to its own entry, so each icon matches the
            -- control beside it.
            local ilvlHelp = NS.AddHelpIcon(content, useEqText, "RIGHT", "LEFT", -2, 0, "gate-fixed-vs-equipped-ilvl")

            -- Re-anchor the rarity-row checkbox's auto-label so its right
            -- edge is bounded by the "Use equipped iLvl" text's left edge.
            -- The row-specific LEFT+RIGHT anchor pair fits the max-iLvl
            -- input + Use-Equipped controls better than a fixed or
            -- reactive width would; the rarity name truncates cleanly
            -- rather than visually colliding with the iLvl controls.
            -- v2.59.10 (bug-hunt finding): NS.AddCheckbox now registers
            -- the label in the reactive-width registry (v2.59.8) so the
            -- reactive-panel-layout invariant applies to it on every
            -- Interface Options resize. This row's LEFT+RIGHT anchor
            -- pair below is the actual width source; a per-resize
            -- SetWidth would fight it. Deregister the label from the
            -- registry after we set the anchor pair so anchor-derived
            -- sizing wins cleanly. Only site in the codebase that
            -- combines AddCheckbox + LEFT+RIGHT re-anchor.
            local rowLabel = _G[cb:GetName() .. "Text"]
            if rowLabel then
                rowLabel:ClearAllPoints()
                rowLabel:SetPoint("LEFT", cb, "RIGHT", 4, 1)
                rowLabel:SetPoint("RIGHT", ilvlHelp, "LEFT", -4, 0)
                rowLabel:SetJustifyH("LEFT")
                if rowLabel.SetWordWrap then
                    rowLabel:SetWordWrap(false)
                end
                if rowLabel.SetNonSpaceWrap then
                    rowLabel:SetNonSpaceWrap(false)
                end
                if WC_compCache.deregisterWidth then
                    WC_compCache.deregisterWidth(rowLabel)
                end
            end

            useEqCB.tooltipText = L["Use equipped iLvl"]
            useEqCB.tooltipRequirement = L["When checked, the cap for this rarity is your currently-equipped iLvl in the same slot. "]
                .. L["Items below auto-sell. Multi-slot items (rings, trinkets, weapons) compare against the "]
                .. L["worst equipped slot. Empty slots are skipped."]

            local function applyInputEnabled()
                local on = DB.qualityRules[qualityIdx].useEquippedILvl == true
                if on then
                    -- 3.3.5a EditBox doesn't expose Enable/Disable - use
                    -- SetEditable + EnableMouse to actually block input,
                    -- and grey both the field text and the "max iLvl:" label
                    -- so the disabled state is obvious.
                    if input.SetEditable then
                        input:SetEditable(false)
                    end
                    input:EnableMouse(false)
                    if input.HasFocus and input:HasFocus() then
                        input:ClearFocus()
                    end
                    input:SetTextColor(0.5, 0.5, 0.5)
                    if lbl.SetTextColor then
                        lbl:SetTextColor(0.5, 0.5, 0.5)
                    end
                else
                    if input.SetEditable then
                        input:SetEditable(true)
                    end
                    input:EnableMouse(true)
                    input:SetTextColor(1, 1, 1)
                    if lbl.SetTextColor then
                        lbl:SetTextColor(1, 0.82, 0)
                    end
                end
            end
            applyInputEnabled()

            useEqCB:SetScript("OnClick", function(self_)
                DB.qualityRules[qualityIdx].useEquippedILvl = self_:GetChecked() and true or false
                applyInputEnabled()
                PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
                -- Toggling useEquippedILvl switches the per-rarity
                -- rule between fixed-cap and dynamic-cap modes - same
                -- slot verdict can flip either direction. Repaint so
                -- tints track.
                if NS.RefreshSellBorders then
                    NS.RefreshSellBorders()
                end
            end)
            cb._applyInputEnabled = applyInputEnabled

            local function commit()
                local v = tonumber(input:GetText() or "0") or 0
                if v < 0 then
                    v = 0
                end
                if v > 300 then
                    v = 300
                end
                DB.qualityRules[qualityIdx].maxILvl = v
                input:SetText(tostring(v))
                -- Cap change flips qualityPass for every slot at the
                -- threshold; repaint so tints track. Note: this fires
                -- on every focus-lost (every commit), which is the
                -- right granularity - per-keystroke firing would be
                -- wasted work.
                if NS.RefreshSellBorders then
                    NS.RefreshSellBorders()
                end
            end
            input:SetScript("OnEnterPressed", function()
                input:ClearFocus()
            end)
            input:SetScript("OnEscapePressed", function()
                input:SetText(tostring(DB.qualityRules[qualityIdx].maxILvl or 0))
                input:ClearFocus()
            end)
            input:SetScript("OnEditFocusLost", commit)

            -- Bind-type filter dropdown on a second line below the checkbox.
            -- Indented to align with the checkbox label so the rule reads as
            -- "[x] Blue (Rare) max iLvl: [200] / Bind: [Any bind type]".
            local bindLbl = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
            bindLbl:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 26, -8)
            bindLbl:SetText(L["Bind:"])

            local bindDD
            bindDD = NS.MakeSelector(content, 140, function()
                local out = {}
                for i, entry in ipairs(WC_BIND_FILTER_OPTIONS) do
                    out[i] = { text = entry.text, value = entry.value, checked = DB.qualityRules[qualityIdx].bindFilter == entry.value }
                end
                return out
            end, function(entry)
                DB.qualityRules[qualityIdx].bindFilter = entry.value
                bindDD:SetText(entry.text)
                -- Bind-filter change can drop or restore many slots from
                -- qualityPass at once; repaint.
                if NS.RefreshSellBorders then
                    NS.RefreshSellBorders()
                end
            end)
            bindDD:SetPoint("LEFT", bindLbl, "RIGHT", 6, 0)
            bindDD:SetText(WC_BindFilterText(DB.qualityRules[qualityIdx].bindFilter))

            -- Per-row help icon for the bind-type filter, sitting right
            -- after the Bind dropdown it explains (the fixed-vs-equipped
            -- iLvl decision has its own [?] up on line 1 next to the
            -- "Use equipped iLvl" toggle).
            NS.AddHelpIcon(content, bindDD, "LEFT", "RIGHT", 4, 2, "gate-bind-type")

            return cb, input, bindDD, useEqCB
        end

        -- All four rarity rows anchor their checkbox to the threshold header,
        -- not to the previous row's selector, so every checkbox, bind label,
        -- and selector stays on the same X column.
        --
        -- Per-row vertical budget: ~26 px checkbox + ~24 px to the bottom of
        -- the 22 px Bind selector + ~10 px gap to the next row = 60 px.
        -- The first row sits -16 below the header (was -10 below
        -- a multi-line description block before Task 16 stripped it - the [?]
        -- icon next to the header now carries the explanation).
        local row1CB, row1Input, row1DD, row1UseEq =
            MakeQualityRow(thresholdHeader, 1, WC_WHITELIST_QUALITIES[1].text, -16)
        local row2CB, row2Input, row2DD, row2UseEq =
            MakeQualityRow(thresholdHeader, 2, WC_WHITELIST_QUALITIES[2].text, -76)
        local row3CB, row3Input, row3DD, row3UseEq =
            MakeQualityRow(thresholdHeader, 3, WC_WHITELIST_QUALITIES[3].text, -136)
        local row4CB, row4Input, row4DD, row4UseEq =
            MakeQualityRow(thresholdHeader, 4, WC_WHITELIST_QUALITIES[4].text, -196)

        self.qualityRow1CB, self.qualityRow1Input, self.qualityRow1DD, self.qualityRow1UseEq =
            row1CB, row1Input, row1DD, row1UseEq
        self.qualityRow2CB, self.qualityRow2Input, self.qualityRow2DD, self.qualityRow2UseEq =
            row2CB, row2Input, row2DD, row2UseEq
        self.qualityRow3CB, self.qualityRow3Input, self.qualityRow3DD, self.qualityRow3UseEq =
            row3CB, row3Input, row3DD, row3UseEq
        self.qualityRow4CB, self.qualityRow4Input, self.qualityRow4DD, self.qualityRow4UseEq =
            row4CB, row4Input, row4DD, row4UseEq

        -- Stash the BindFilterText helper on the panel so the inited refresh
        -- block can update each dropdown's display text without re-defining
        -- the option set.
        self._BindFilterText = WC_BindFilterText

        -- v2.49.3: "Sell recipes you already know" moved here from the
        -- Keep Settings panel (formerly Protection Settings) - it is a sell
        -- rule, so it belongs with the merchant sell rules. When ON,
        -- profession recipes this character has ALREADY learned auto-sell at
        -- vendors, gated per rarity + bind type. Unknown recipes are never
        -- sold. The runtime "keep all tomes wins over sell-known-recipes"
        -- precedence still lives in WC_IsSellable; this toggle is not greyed
        -- by that setting (it just loses at decision time), so no cross-panel
        -- dependency is needed. Reuses WC_BIND_FILTER_OPTIONS / WC_BindFilterText
        -- (previously duplicated on the Protection panel; the dupe is gone).
        local sellRecipesCB = CreateFrame(
            "CheckButton",
            "WoWClearanceSellKnownRecipesCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        sellRecipesCB:SetPoint("TOPLEFT", row4CB, "BOTTOMLEFT", 0, -40)
        sellRecipesCB:SetChecked(DB.sellKnownRecipes)
        local srText = _G[sellRecipesCB:GetName() .. "Text"]
        if srText then
            srText:SetText(L["Sell recipes you already know"])
            WC_compCache.setPanelWidth(srText, 60)
            srText:SetJustifyH("LEFT")
        end
        self.sellRecipesCB = sellRecipesCB
        if srText then
            NS.AddHelpIcon(content, srText, "LEFT", "RIGHT", 6, 0, "gate-sell-known-recipes")
        end

        -- Per-quality gate: four indented child checkboxes, one per recipe
        -- rarity, each writing DB.sellKnownRecipeQualities[q]. Greyed out when
        -- the parent is off. Each row has a Bind dropdown mirroring the
        -- per-rarity bind-type filter on the quality rules above.
        -- v2.66.1 iter (Serv report): colour words replaced with quality
        -- names ("Common"/"Uncommon"/"Rare"/"Epic"). Matches the quality-
        -- threshold rows above.
        local recipeQualityLabels = { L["Common"], L["Uncommon"], L["Rare"], L["Epic"] }
        local recipeQualityCBs = {}
        local recipeBindDDs = {}
        local recipeAnchor = sellRecipesCB
        for q = 1, 4 do
            local qcb = CreateFrame(
                "CheckButton",
                "WoWClearanceSellKnownRecipeQ" .. q .. "CB",
                content,
                "InterfaceOptionsCheckButtonTemplate"
            )
            if q == 1 then
                qcb:SetPoint("TOPLEFT", recipeAnchor, "BOTTOMLEFT", 26, -6)
            else
                qcb:SetPoint("TOPLEFT", recipeAnchor, "BOTTOMLEFT", 0, -4)
            end
            qcb:SetChecked(DB.sellKnownRecipeQualities and DB.sellKnownRecipeQualities[q] or false)
            local qText = _G[qcb:GetName() .. "Text"]
            if qText then
                qText:SetText(recipeQualityLabels[q])
                qText:SetJustifyH("LEFT")
            end
            qcb:SetScript("OnClick", function(cb)
                DB.sellKnownRecipeQualities = DB.sellKnownRecipeQualities or {}
                DB.sellKnownRecipeQualities[q] = cb:GetChecked() and true or false
                PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
                if NS.RefreshSellBorders then
                    NS.RefreshSellBorders()
                end
            end)
            recipeQualityCBs[q] = qcb

            -- Bind-type dropdown to the right of this rarity row.
            local bindDD
            bindDD = NS.MakeSelector(content, 140, function()
                local cur = (DB.sellKnownRecipeBindFilter and DB.sellKnownRecipeBindFilter[q]) or "any"
                local out = {}
                for i, entry in ipairs(WC_BIND_FILTER_OPTIONS) do
                    out[i] = { text = entry.text, value = entry.value, checked = cur == entry.value }
                end
                return out
            end, function(entry)
                DB.sellKnownRecipeBindFilter = DB.sellKnownRecipeBindFilter or {}
                DB.sellKnownRecipeBindFilter[q] = entry.value
                bindDD:SetText(entry.text)
                if NS.RefreshSellBorders then
                    NS.RefreshSellBorders()
                end
            end)
            bindDD:SetPoint("LEFT", qcb, "RIGHT", 72, 0)
            local curBind = (DB.sellKnownRecipeBindFilter and DB.sellKnownRecipeBindFilter[q]) or "any"
            bindDD:SetText(WC_BindFilterText(curBind))
            recipeBindDDs[q] = bindDD

            recipeAnchor = qcb
        end
        self.recipeQualityCBs = recipeQualityCBs
        self.recipeBindDDs = recipeBindDDs

        local function UpdateRecipeQualitiesEnabled()
            local on = DB.sellKnownRecipes == true
            for q = 1, 4 do
                local qcb = recipeQualityCBs[q]
                local qText = qcb and _G[qcb:GetName() .. "Text"]
                local dd = recipeBindDDs[q]
                if on then
                    qcb:Enable()
                    if qText then
                        qText:SetTextColor(1, 0.82, 0)
                    end
                    if dd then
                        dd:Enable()
                    end
                else
                    qcb:Disable()
                    if qText then
                        qText:SetTextColor(0.5, 0.5, 0.5)
                    end
                    if dd then
                        dd:Disable()
                    end
                end
            end
        end
        self.UpdateRecipeQualitiesEnabled = UpdateRecipeQualitiesEnabled
        UpdateRecipeQualitiesEnabled()

        sellRecipesCB:SetScript("OnClick", function(cb)
            DB.sellKnownRecipes = cb:GetChecked() and true or false
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            UpdateRecipeQualitiesEnabled()
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
        end)

        -- Size the scroll content to fit the bottom-most widget so the scrollbar
        -- range matches actual content. The Epic recipe row is now the lowest.
        NS.FitScrollContent(content, recipeQualityCBs[4])
    end, true)
end)
