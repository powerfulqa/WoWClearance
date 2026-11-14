-- WoWClearance_KeepDeletePanels - Keep List + Delete List Interface Options panels.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-v of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The Keep List + Delete List panels - sibling list-management UIs
-- bundled together. Both use the shared CreateListUI helper and have
-- the same panel rhythm (header + description + hint + list).
--
-- The Keep Settings panel (BlacklistSettingsPanel - auto-protect
-- toggles for equipped / upgrades / gear sets)
-- stays in WoWClearance_Events.lua for now; it's a different domain
-- (settings, not list management) and will move in a later stage.
--
-- Moved into this file:
--   * local DeletePanel = CreateFrame(...) + OnShow build (Delete List)
--   * local BlacklistPanel = CreateFrame(...) + OnShow build (Keep List)
--
-- Cross-file dependencies satisfied by NS:
--   * NS.compCache (Core) - initPanel, setPanelWidth, registerWidth
--   * NS.DB captured at each OnShow entry
--   * NS.MakeHeader / NS.MakeLabel (8e-i)
--   * NS.CreateListUI (8e-iv)
--   * NS.RefreshSellBorders (BagDisplay) - used by the Enable deletion
--     toggle's OnClick to repaint Delete category tints

local NS = select(2, ...)
local WC_compCache = NS.compCache
local L = NS.L

local DeletePanel = CreateFrame("Frame", "WoWClearanceOptionsDeletion", NS.OptionsHost())
DeletePanel.name = "Delete List"
DeletePanel.parent = "WoWClearance"

DeletePanel:SetScript("OnShow", function(self)
    WC_compCache.initPanel(self, function(self)
        if self.listUI then
            self.listUI:Refresh()
        end
    end, function(self)
        -- v2.47.2: settings extracted to the sibling Delete Settings panel
        -- (see below). This panel now matches the Sell List / Keep List /
        -- Account Sell List rhythm: header + description + hint + list.
        -- Mirrors the v2.15.0 Keep List refactor's rationale: five
        -- checkboxes plus explanatory notes had pushed the actual list
        -- well below the fold on smaller Interface Options window sizes.
        local heading = NS.MakeHeader(self, L["Delete List"], -16)
        NS.AddHelpIcon(self, heading, "LEFT", "RIGHT", 8, 0, "what-are-the-lists")
        local delDesc = NS.MakeLabel(
            self,
            L["Press Delete Next (or its key) to destroy one item from this list. This cannot be undone."],
            16,
            -44
        )
        local delHint = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        delHint:SetPoint("TOPLEFT", delDesc, "BOTTOMLEFT", 0, -4)
        WC_compCache.setPanelWidth(delHint, 16)
        delHint:SetJustifyH("LEFT")
        delHint:SetJustifyV("TOP")
        if delHint.SetWordWrap then
            delHint:SetWordWrap(true)
        end
        delHint:SetText(
            L["Add items by shift-clicking them, dragging them in, or typing the item ID below."]
        )

        -- Grey pointer to the sibling Delete Settings panel. Mirrors the
        -- Keep List -> Keep Settings pointer added in v2.15.0.
        local settingsPtr = self:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        settingsPtr:SetPoint("TOPLEFT", delHint, "BOTTOMLEFT", 0, -6)
        WC_compCache.setPanelWidth(settingsPtr, 16)
        settingsPtr:SetJustifyH("LEFT")
        settingsPtr:SetJustifyV("TOP")
        if settingsPtr.SetWordWrap then
            settingsPtr:SetWordWrap(true)
        end
        settingsPtr:SetText(
            L["|cffaaaaaaGrey marking, PvP Resilience marking, and chat announcements live on the |r|cffffb84dDelete Settings|r|cffaaaaaa panel.|r"]
        )

        -- The game only lets addons delete inside the player's own click or
        -- key press, so deleting is this button (and the Delete Next key),
        -- one item per press. See the WC-TRAP on executeBagSlotDelete.
        local deleteNextBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
        deleteNextBtn:SetSize(130, 22)
        deleteNextBtn:SetPoint("TOPLEFT", settingsPtr, "BOTTOMLEFT", 0, -8)
        deleteNextBtn:SetText(L["Delete Next"])
        deleteNextBtn:SetScript("OnClick", function()
            WoWClearance_DeleteNext()
            if self.listUI then
                self.listUI:Refresh()
            end
        end)

        self.listUI = NS.CreateListUI(self, L["Delete List"], "deleteList", 16, -130)
        -- v2.11.0: anchor BOTTOMRIGHT so the list stretches with the panel
        -- on Interface Options frame resize - mirrors the Whitelist /
        -- Blacklist / Account-Whitelist setups.
        self.listUI:ClearAllPoints()
        self.listUI:SetPoint("TOPLEFT", deleteNextBtn, "BOTTOMLEFT", 0, -12)
        self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
        self.listUI:Refresh()
    end)
end)

-- v2.47.2: Delete Settings sub-panel. Extracted from the Delete List panel
-- so the list gets its full vertical space back (mirrors the v2.15.0 Keep
-- List -> Keep Settings extraction). All DB field names unchanged,
-- so slash commands / BugReport dumps / tooltip annotations continue to
-- work. Widget names unchanged so tests that read the source still resolve.
local DeletionSettingsPanel = CreateFrame(
    "Frame",
    "WoWClearanceOptionsDeletionSettings",
    NS.OptionsHost()
)
DeletionSettingsPanel.name = "Delete Settings"
DeletionSettingsPanel.parent = "WoWClearance"

DeletionSettingsPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    WC_compCache.initPanel(self, function(self)
        -- Settings are DB-backed; nothing to refresh on re-show, except the
    end, function(_, content)
        -- v2.59.8 (Serv report): the panel is now scroll-wrapped so
        -- wrapped checkbox labels (v2.59.8's reactive-width fix) can't
        -- overflow the panel bottom past the Okay/Cancel buttons.
        -- Bind `self` to the scroll region so every child widget
        -- below hangs off the scrollable content instead of the raw
        -- panel - none of the OnClick closures in this build capture
        -- `self`, verified before the rename. First arg ignored (`_`)
        -- because the raw panel is no longer the parent for children.
        local self = content
        local heading = NS.MakeHeader(self, L["Delete Settings"], -16)
        NS.AddHelpIcon(self, heading, "LEFT", "RIGHT", 8, 0, "gate-auto-delete-grey")
        local desc = NS.MakeLabel(
            self,
            L["Choose what Delete Next may remove, and what gets added to your Delete List automatically."],
            16,
            -44
        )

        local refreshAutoCBEnabled

        -- Master switch. Off = nothing on the Delete List is destroyed,
        -- regardless of the sub-toggles.
        local delCB =
            CreateFrame("CheckButton", "WoWClearanceEnableDeleteCB", self, "InterfaceOptionsCheckButtonTemplate")
        delCB:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -8)
        delCB:SetChecked(DB.enableDeletion)
        local dt = _G[delCB:GetName() .. "Text"]
        if dt then
            dt:SetText(L["Allow items to be deleted"])
            -- v2.59.8 (Serv report): reactive width. Pre-fix a bare
            -- SetWidth(420) always overflowed the ~360px panel, cutting
            -- off long labels. Same treatment (setPanelWidth + word-wrap)
            -- as the adjacent note FontStrings, so labels rewrap on
            -- Interface Options resize instead of clipping.
            WC_compCache.setPanelWidth(dt, 60)
            dt:SetJustifyH("LEFT")
            if dt.SetWordWrap then
                dt:SetWordWrap(true)
            end
        end
        local delNote = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        delNote:SetPoint("TOPLEFT", delCB, "BOTTOMLEFT", 26, -2)
        -- v2.47.2: reactive width. A bare SetWidth(<literal>) here freezes
        -- the note at build-time width and clips past the panel's right
        -- edge on Interface Options resize. Padding = 60, the inset every
        -- checkbox label and note uses (indent + scroll gutter + right
        -- margin). WC-TRAP per
        -- docs/ADDON_GUIDE.md's reactive-panel-layout invariant: any
        -- widget that snapshots panel width MUST go through setPanelWidth
        -- (test_layout_reactivity.lua enforces this for WC_PANEL_WIDTH-
        -- derived expressions but not for bare literals - see Test 105e
        -- in test_perf_guardrails.lua for the specific pin).
        WC_compCache.setPanelWidth(delNote, 60)
        delNote:SetJustifyH("LEFT")
        if delNote.SetWordWrap then
            delNote:SetWordWrap(true)
        end
        delNote:SetText(
            L["|cff888888Master switch. Off = nothing on the Delete List is destroyed, even if the sub-toggles below are on.|r"]
        )
        delCB:SetScript("OnClick", function()
            DB.enableDeletion = delCB:GetChecked() and true or false
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            -- Toggling deletion changes WC_IsSellable / BuildQueue's
            -- delete-list verdict for every Delete List slot. Repaint so
            -- the slot tints track immediately without requiring a bag
            -- close/reopen. Same rule as the list-mutation refresh
            -- invariant (Test 26 in test_perf_guardrails.lua).
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
            if refreshAutoCBEnabled then
                refreshAutoCBEnabled()
            end
        end)

        -- v0.6.0: the two automatic delete toggles (on pickup, grey on loot)
        -- are gone: Forever only lets an addon delete inside the player's own
        -- key press or click (WC-TRAP on executeBagSlotDelete). This one marks
        -- greys so Delete Next removes them after the Delete List.
        local greyCB =
            CreateFrame("CheckButton", "WoWClearanceAutoDeleteGreyCB", self, "InterfaceOptionsCheckButtonTemplate")
        greyCB:SetPoint("TOPLEFT", delNote, "BOTTOMLEFT", -26, -8)
        greyCB:SetChecked(DB.markGreyForDeletion)
        local greyText = _G[greyCB:GetName() .. "Text"]
        if greyText then
            greyText:SetText(L["Mark grey items for deletion"])
            WC_compCache.setPanelWidth(greyText, 60)
            greyText:SetJustifyH("LEFT")
            if greyText.SetWordWrap then
                greyText:SetWordWrap(true)
            end
        end
        local greyNote = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        greyNote:SetPoint("TOPLEFT", greyCB, "BOTTOMLEFT", 26, -2)
        WC_compCache.setPanelWidth(greyNote, 60)
        greyNote:SetJustifyH("LEFT")
        if greyNote.SetWordWrap then
            greyNote:SetWordWrap(true)
        end
        greyNote:SetText(
            L["|cff888888Delete Next also removes grey items, cheapest first, after your Delete List. Never touches keep-listed items, equipment, or quest items.|r"]
        )

        -- v2.44.0: Resilience auto-mark sub-toggle. Adds PvP gear with the
        -- "Resilience" tooltip line to the Delete List on the next BAG_UPDATE.
        -- Delete Next then removes
        -- it. Same enabled-state rule as greyCB. Asked for by Murlocked:
        -- PvP gear on PE has sellPrice = 0 and clutters bags after farming.
        local resilienceCB = CreateFrame(
            "CheckButton",
            "WoWClearanceAutoMarkResilienceCB",
            self,
            "InterfaceOptionsCheckButtonTemplate"
        )
        resilienceCB:SetPoint("TOPLEFT", greyNote, "BOTTOMLEFT", -26, -8)
        resilienceCB:SetChecked(DB.autoMarkResilience)
        local resilienceText = _G[resilienceCB:GetName() .. "Text"]
        if resilienceText then
            resilienceText:SetText(L["Auto-mark PvP gear (Resilience) for deletion"])
            WC_compCache.setPanelWidth(resilienceText, 60)
            resilienceText:SetJustifyH("LEFT")
            if resilienceText.SetWordWrap then
                resilienceText:SetWordWrap(true)
            end
        end
        local resilienceNote = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        resilienceNote:SetPoint("TOPLEFT", resilienceCB, "BOTTOMLEFT", 26, -2)
        WC_compCache.setPanelWidth(resilienceNote, 60)
        resilienceNote:SetJustifyH("LEFT")
        if resilienceNote.SetWordWrap then
            resilienceNote:SetWordWrap(true)
        end
        resilienceNote:SetText(
            L["|cff888888PvP gear with 'Resilience' and no vendor value gets added to the Delete List automatically. Still needs 'Allow items to be deleted' above, then Delete Next removes it.|r"]
        )

        -- v2.60.0 (Serv follow-up): the "Protect high-iLvl items from
        -- auto-mark" toggle was briefly on this panel
        -- but moved to Keep Settings on Serv's request - it's semantically
        -- a "Protect X" toggle and belongs with the other Keep-Settings
        -- protection toggles for discoverability. See
        -- WoWClearance_ProtectionPanel.lua for the actual UI + wiring.

        -- v2.60.0 (Serv report, Recipe: Haunted Herring / Recipe: Last
        -- Week's Mammoth): auto-mark learned profession recipes with
        -- sellPrice 0 for deletion. Parallel to the Resilience
        -- auto-mark above. Requires the parent "Sell known recipes"
        -- toggle on (see Merchant Settings) so the mental model is a single
        -- "get rid of learned recipes" opt-in with two disposition paths.
        local knownRecipeCB = CreateFrame(
            "CheckButton",
            "WoWClearanceAutoMarkKnownRecipesCB",
            self,
            "InterfaceOptionsCheckButtonTemplate"
        )
        knownRecipeCB:SetPoint("TOPLEFT", resilienceNote, "BOTTOMLEFT", -26, -8)
        knownRecipeCB:SetChecked(DB.autoMarkKnownUnsellableRecipes)
        local knownRecipeText = _G[knownRecipeCB:GetName() .. "Text"]
        if knownRecipeText then
            knownRecipeText:SetText(L["Auto-mark unsellable known recipes for deletion"])
            WC_compCache.setPanelWidth(knownRecipeText, 60)
            knownRecipeText:SetJustifyH("LEFT")
            if knownRecipeText.SetWordWrap then
                knownRecipeText:SetWordWrap(true)
            end
        end
        local knownRecipeNote = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        knownRecipeNote:SetPoint("TOPLEFT", knownRecipeCB, "BOTTOMLEFT", 26, -2)
        WC_compCache.setPanelWidth(knownRecipeNote, 60)
        knownRecipeNote:SetJustifyH("LEFT")
        if knownRecipeNote.SetWordWrap then
            knownRecipeNote:SetWordWrap(true)
        end
        knownRecipeNote:SetText(
            L["|cff888888Learned profession recipes with no vendor value (some low-rank Cooking recipes, low-level schematics). Needs 'Sell recipes you already know' on in Merchant Settings.|r"]
        )

        -- v2.44.4: announce-in-chat toggle. Gates the "WC just deleted /
        -- marked X" lines. Default ON (destructive actions should be
        -- visible); turn off if the chat noise is unwelcome. Asked for
        -- by ayres.
        local announceCB = CreateFrame(
            "CheckButton",
            "WoWClearanceAnnounceAutoDeleteCB",
            self,
            "InterfaceOptionsCheckButtonTemplate"
        )
        announceCB:SetPoint("TOPLEFT", knownRecipeNote, "BOTTOMLEFT", -26, -8)
        announceCB:SetChecked(DB.announceAutoDelete ~= false)
        local announceText = _G[announceCB:GetName() .. "Text"]
        if announceText then
            announceText:SetText(L["Announce deletions in chat"])
            WC_compCache.setPanelWidth(announceText, 60)
            announceText:SetJustifyH("LEFT")
            if announceText.SetWordWrap then
                announceText:SetWordWrap(true)
            end
        end
        local announceNote = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        announceNote:SetPoint("TOPLEFT", announceCB, "BOTTOMLEFT", 26, -2)
        WC_compCache.setPanelWidth(announceNote, 60)
        announceNote:SetJustifyH("LEFT")
        if announceNote.SetWordWrap then
            announceNote:SetWordWrap(true)
        end
        announceNote:SetText(
            L["|cff888888One chat line per delete or auto-mark. Off is fine if the chat is too noisy while farming; your Delete List still tracks every destroyed item.|r"]
        )

        -- v2.60.0: per-rarity multi-select filter under the master
        -- announce toggle. Master off silences everything; master on
        -- lets each rarity's tickbox decide. Vertical layout matches
        -- the panel's existing one-checkbox-per-line pattern; each
        -- label uses the rarity's quality color for at-a-glance
        -- reading. Defaults all-on so existing users see no behaviour
        -- change (announceAutoDelete stays their single tunable until
        -- they explicitly untick a rarity here).
        DB.announceAutoDeleteQualities = DB.announceAutoDeleteQualities or {}
        local RARITY_ROWS = {
            { q = 0, key = "Poor",     hex = "9d9d9d" },
            { q = 1, key = "Common",   hex = "ffffff" },
            { q = 2, key = "Uncommon", hex = "1eff00" },
            { q = 3, key = "Rare",     hex = "0070dd" },
            { q = 4, key = "Epic",     hex = "a335ee" },
        }
        local rarityCBs = {}
        local prevAnchor = announceNote
        for _, row in ipairs(RARITY_ROWS) do
            local cb = CreateFrame(
                "CheckButton",
                "WoWClearanceAnnounceAutoDeleteRarity" .. row.key .. "CB",
                self,
                "InterfaceOptionsCheckButtonTemplate"
            )
            cb:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 0, -2)
            cb:SetChecked(DB.announceAutoDeleteQualities[row.q] ~= false)
            local ct = _G[cb:GetName() .. "Text"]
            if ct then
                ct:SetText("|cff" .. row.hex .. L[row.key] .. "|r")
                WC_compCache.setPanelWidth(ct, 60)
                ct:SetJustifyH("LEFT")
            end
            cb:SetScript("OnClick", function()
                DB.announceAutoDeleteQualities[row.q] = cb:GetChecked() and true or false
                PlaySound(cb:GetChecked() and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
            end)
            rarityCBs[row.q] = { cb = cb, text = ct }
            prevAnchor = cb
        end

        announceCB:SetScript("OnClick", function()
            DB.announceAutoDelete = announceCB:GetChecked() and true or false
            PlaySound(DB.announceAutoDelete and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
            -- v2.60.0: re-apply the enable/disable state on the rarity
            -- sub-toggles so they grey out when the master is off (the
            -- sub-toggles have no effect without the master).
            if refreshAutoCBEnabled then refreshAutoCBEnabled() end
        end)

        refreshAutoCBEnabled = function()
            if DB.enableDeletion then
                greyCB:Enable()
                resilienceCB:Enable()
                announceCB:Enable()
                if greyText then
                    greyText:SetTextColor(1, 0.82, 0)
                end
                if resilienceText then
                    resilienceText:SetTextColor(1, 0.82, 0)
                end
                if announceText then
                    announceText:SetTextColor(1, 0.82, 0)
                end
            else
                greyCB:Disable()
                resilienceCB:Disable()
                announceCB:Disable()
                if greyText then
                    greyText:SetTextColor(0.5, 0.5, 0.5)
                end
                if resilienceText then
                    resilienceText:SetTextColor(0.5, 0.5, 0.5)
                end
                if announceText then
                    announceText:SetTextColor(0.5, 0.5, 0.5)
                end
            end
            -- v2.60.0: the rarity sub-toggles need TWO conditions to be
            -- fully enabled - the master enableDeletion (whole panel is
            -- gated on it) AND the announce master. If either is off,
            -- the sub-toggles are inert; grey them so the UI makes that
            -- obvious. Uses ITEM_QUALITY_COLORS for the label color so
            -- the rarity is still visually identifiable when disabled.
            local subActive = DB.enableDeletion and DB.announceAutoDelete ~= false
            for _, entry in pairs(rarityCBs) do
                if subActive then
                    entry.cb:Enable()
                    if entry.text then
                        entry.text:SetAlpha(1.0)
                    end
                else
                    entry.cb:Disable()
                    if entry.text then
                        entry.text:SetAlpha(0.5)
                    end
                end
            end
        end
        refreshAutoCBEnabled()

        greyCB:SetScript("OnClick", function()
            DB.markGreyForDeletion = greyCB:GetChecked() and true or false
            PlaySound(DB.markGreyForDeletion and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
        end)

        -- v2.44.0: Resilience auto-mark OnClick. No confirmation popup - it
        -- only adds items to the Delete List (reversible). Kicks a debounce
        -- scan so items already in bags get marked immediately.
        resilienceCB:SetScript("OnClick", function()
            DB.autoMarkResilience = resilienceCB:GetChecked() and true or false
            PlaySound(DB.autoMarkResilience and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
            if DB.autoMarkResilience and WC_compCache.bagUpdateFrame then
                WC_compCache.bagUpdateAccum = 0
                WC_compCache.bagUpdateFrame:Show()
            end
        end)

        -- v2.60.0: known-unsellable-recipe auto-mark OnClick. Same shape.
        knownRecipeCB:SetScript("OnClick", function()
            DB.autoMarkKnownUnsellableRecipes = knownRecipeCB:GetChecked() and true or false
            PlaySound(DB.autoMarkKnownUnsellableRecipes and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
            if DB.autoMarkKnownUnsellableRecipes and WC_compCache.bagUpdateFrame then
                WC_compCache.bagUpdateAccum = 0
                WC_compCache.bagUpdateFrame:Show()
            end
        end)

        -- v2.59.8: size the scroll content to the last widget so the
        -- scroll bar knows the full extent. Announced last-widget is
        -- announceNote (the "Announce auto-deletions in chat" note).
        -- v2.60.0: fit the scroll content to the LAST rarity sub-toggle
        -- (was announceNote pre-v2.60.0). rarityCBs[4] is the Epic
        -- checkbox, the bottom-most widget in the Announce sub-section.
        NS.FitScrollContent(content, rarityCBs[4] and rarityCBs[4].cb or announceNote)
    end, true)
end)

local BlacklistPanel = CreateFrame("Frame", "WoWClearanceOptionsBlacklist", NS.OptionsHost())
BlacklistPanel.name = "Keep List"
BlacklistPanel.parent = "WoWClearance"

BlacklistPanel:SetScript("OnShow", function(self)
    WC_compCache.initPanel(self, function(self)
        if self.listUI then
            self.listUI:Refresh()
        end
    end, function(self)
        -- v2.15.0: the auto-protect toggles (autoAddEquipped, autoProtectUpgrades,
        -- autoProtectEquipmentSets) plus their explanatory notes used to live on
        -- this panel and dominated it visually - 3 checkboxes + 3 multi-line notes
        -- stacked above the actual list. They moved to the new `Keep Settings`
        -- sub-panel so this panel matches the Sell List / Delete List / Account
        -- Sell List rhythm (header + description + hint + list). DB field names
        -- unchanged so all event handlers, tooltip annotations, and slash commands
        -- continue to work without modification.
        local heading = NS.MakeHeader(self, L["Keep List"], -16)
        NS.AddHelpIcon(self, heading, "LEFT", "RIGHT", 8, 0, "what-are-the-lists")
        local blDesc = NS.MakeLabel(
            self,
            L["Items the addon should never touch. Good for things you'd rather sell at the auction house yourself."],
            16,
            -44
        )

        -- Grey side-note on its own line so it doesn't blend into the
        -- white action text above.
        local blNote = self:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        blNote:SetPoint("TOPLEFT", blDesc, "BOTTOMLEFT", 0, -6)
        WC_compCache.setPanelWidth(blNote, 16)
        blNote:SetJustifyH("LEFT")
        blNote:SetJustifyV("TOP")
        if blNote.SetWordWrap then
            blNote:SetWordWrap(true)
        end
        blNote:SetText(
            L["|cffaaaaaaAutomatic protection rules (equipped gear, upgrades, gear sets, recipes) are on the |r|cffffb84dKeep Settings|r|cffaaaaaa panel.|r"]
        )

        -- Anchored to blNote so the hint stays below even when the
        -- description wraps to multiple lines.
        local blHint = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        blHint:SetPoint("TOPLEFT", blNote, "BOTTOMLEFT", 0, -8)
        WC_compCache.setPanelWidth(blHint, 16)
        blHint:SetJustifyH("LEFT")
        blHint:SetJustifyV("TOP")
        if blHint.SetWordWrap then
            blHint:SetWordWrap(true)
        end
        blHint:SetText(L["Add items by shift-clicking them, dragging them in, or typing the item ID."])

        self.listUI = NS.CreateListUI(self, L["Protected Items"], "blacklist", 16, -130)
        self.listUI:ClearAllPoints()
        self.listUI:SetPoint("TOPLEFT", blHint, "BOTTOMLEFT", 0, -16)
        self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
        self.listUI:Refresh()
    end)
end)
