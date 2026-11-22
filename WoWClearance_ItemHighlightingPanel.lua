-- WoWClearance_ItemHighlightingPanel - Item Highlighting Interface Options panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-vii of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The Item Highlighting UI panel (v2.30.x rename of the former
-- Character Settings panel; internal frame name
-- "WoWClearanceOptionsCharacter" preserved for SV compatibility).
-- Hosts the master sell-border toggle + the five per-category
-- enable/colour rows (delete / accountSell / charSell / junk / rule).
--
-- Moved into this file:
--   * local CharPanel = CreateFrame(...) frame creation
--   * The CharPanel OnShow handler (panel-build body that constructs
--     the master toggle + the SELL_BORDER_CATEGORIES iteration that
--     builds one enable+colour row per category + the
--     RefreshSellBorderSwatch helper that re-syncs every swatch on
--     panel reshow)
--
-- Cleanups bundled into this stage:
--   - The dead CreateNameListUI function (~170 LOC) is dropped. It
--     was orphaned in §4.5 when the per-character allowlist UI was
--     decommissioned along with the panel rename. Zero call sites in
--     any shipped file confirmed via grep.
--   - Orphan comment headers from Stages 8e-v / 8e-vi extractions
--     are stripped from WoWClearance_Events.lua (BlacklistPanel and
--     BlacklistSettingsPanel docstrings that survived the moves).
--
-- Cross-file dependencies satisfied by NS:
--   * NS.compCache (Core) - initPanel
--   * NS.DB captured at OnShow entry
--   * NS.MakeHeader / NS.MakeLabel (8e-i)
--   * NS.RefreshSellBorders (BagDisplay) - used by the master toggle
--     and each per-category enable / colour-picker OnClick handler
--     to repaint slot tints immediately (Issue B refresh invariant)

local NS = select(2, ...)
local WC_compCache = NS.compCache
local L = NS.L

local CharPanel = CreateFrame("Frame", "WoWClearanceOptionsCharacter", NS.OptionsHost())
CharPanel.name = "Item Highlighting"
CharPanel.parent = "WoWClearance"

-- Apply a flip of the master "Item highlighting" switch (DB.itemHighlighting)
-- everywhere at once: repaint borders and item levels, and grey out the
-- panel's options if it has been built. Shared by the panel checkbox and
-- the /wc highlight command.
NS.SyncItemHighlighting = function()
    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end
    if NS.RefreshItemLevelOverlay then
        NS.RefreshItemLevelOverlay()
    end
    if CharPanel.syncHighlightControls then
        CharPanel.syncHighlightControls()
    end
end

-- Enable or grey out one checkbox, its label included (the template does
-- not dim the label by itself).
local function setControlOn(cb, on)
    if not cb then
        return
    end
    if on then
        cb:Enable()
    else
        cb:Disable()
    end
    local t = cb.GetName and cb:GetName() and _G[cb:GetName() .. "Text"]
    if t then
        if on then
            t:SetTextColor(1, 1, 1)
        else
            t:SetTextColor(0.5, 0.5, 0.5)
        end
    end
end

CharPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    WC_compCache.initPanel(self, function(self)
        if self.highlightCB then
            self.highlightCB:SetChecked(DB.itemHighlighting ~= false)
        end
        if self.sellBorderCB then
            self.sellBorderCB:SetChecked(DB.sellBorderEnabled)
        end
        if self.RefreshSellBorderSwatch then
            self:RefreshSellBorderSwatch()
        end
        if self.syncHighlightControls then
            self.syncHighlightControls()
        end
        if self.showItemIDCB then
            self.showItemIDCB:SetChecked(DB.showItemIDOnTooltip)
        end
        if self.showItemStatsCB then
            self.showItemStatsCB:SetChecked(DB.showItemStatsOnTooltip)
        end
    end, function(self, content)
        -- v2.37.0 (Borrow C polish): the panel is scroll-wrapped because
        -- the iLvl section + slider pushed total content past the
        -- Interface Options sub-panel's natural height. Widgets parent
        -- to `content` (the scroll-wrapped child) so resize follows the
        -- panel; `self.xxxCB = ...` storage stays on the panel frame
        -- so the OnShow refresh callback can still find the widgets.
        NS.MakeHeader(content, L["Item Highlighting"], -16)
        -- v2.30.x: panel repurposed from "Character Settings" to focus
        -- entirely on bag-item highlighting. The per-character enable
        -- allowlist was removed (minimap toggle covers that use case);
        -- DB.enableOnlyListedChars is force-disabled in EnsureDB and
        -- DB.allowedChars sits dormant in the SV for downgrade safety.
        -- Master switch: off hides every border and item level and greys
        -- out all the options below. Their own settings are kept, so
        -- turning it back on restores them.
        local highlightCB = NS.AddCheckbox(
            content,
            "WoWClearanceItemHighlightingCB",
            content,
            L["Item highlighting"],
            function()
                return DB.itemHighlighting ~= false
            end,
            function(v)
                DB.itemHighlighting = v
                NS.SyncItemHighlighting()
            end
        )
        highlightCB:ClearAllPoints()
        highlightCB:SetPoint("TOPLEFT", 16, -44)
        self.highlightCB = highlightCB
        NS.AddHelpIcon(
            content,
            _G[highlightCB:GetName() .. "Text"],
            "LEFT",
            "RIGHT",
            6,
            0,
            "gate-item-highlighting"
        )

        local bagDesc = NS.MakeLabel(
            content,
            L["Coloured borders around bag items so you can see what will sell, what's junk, and what's protected - at a glance. Icons are untouched."],
            16,
            -44
        )
        bagDesc:ClearAllPoints()
        bagDesc:SetPoint("TOPLEFT", highlightCB, "BOTTOMLEFT", 0, -6)

        local sbCB =
            CreateFrame("CheckButton", "WoWClearanceSellBorderCB", content, "InterfaceOptionsCheckButtonTemplate")
        sbCB:SetPoint("TOPLEFT", bagDesc, "BOTTOMLEFT", 0, -8)
        sbCB:SetChecked(DB.sellBorderEnabled)

        -- Text auto-sizes to its content (no width snapshot) so the colour
        -- button can dock immediately to the text's right edge without
        -- overlapping. The standard checkbox-template text anchors LEFT of
        -- the checkbox icon already; only the wrap width was the problem.
        local sbText = _G[sbCB:GetName() .. "Text"]
        if sbText then
            sbText:SetText(L["Show borders"])
            sbText:SetJustifyH("LEFT")
        end

        sbCB:SetScript("OnClick", function()
            DB.sellBorderEnabled = sbCB:GetChecked() and true or false
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
            if self.syncHighlightControls then
                self.syncHighlightControls()
            end
        end)
        self.sellBorderCB = sbCB
        if sbText then
            NS.AddHelpIcon(content, sbText, "LEFT", "RIGHT", 6, 0, "tshoot-bag-borders")
        end

        -- v2.30.x: per-category colour pickers. One enable checkbox +
        -- one swatch + one Change-colour button per verdict category.
        -- Each row is anchored to the previous row so the column flows
        -- naturally and the bottom-most row drives the listUI anchor.
        --
        -- Category display order matches the tooltip annotation
        -- priority order: Delete first (highest visibility), then the
        -- two Sell lists, then Junk, then per-rarity rule.
        local SELL_BORDER_CATEGORIES = {
            { key = "delete", label = L["Delete List (red)"] },
            { key = "keep", label = L["Keep List (white)"] },
            { key = "accountSell", label = L["Account Sell List (green)"] },
            { key = "charSell", label = L["Character Sell List (cyan)"] },
            { key = "junk", label = L["Junk - greys (faint grey)"] },
            { key = "rule", label = L["Quality rule match (gold)"] },
        }
        local catSwatchUpdaters = {}
        -- v2.66.1 iter (Serv report): buttons in this list used to float
        -- right of each row's label + swatch, so the varying label widths
        -- put each Change colour button at a different X. Track the row
        -- widgets so a post-pass below can re-align swatch + button to a
        -- fixed column past the widest label. All catCBs share the same
        -- X (row-1 anchor offset + subsequent 0-offset chain), so the
        -- fixed column is well-defined.
        local rowCatCBTexts = {}
        local rowCatSwatches = {}
        local rowCatBtns = {}
        local rowCatCBs = {}

        local lastRowAnchor = sbCB
        for i, cat in ipairs(SELL_BORDER_CATEGORIES) do
            local key = cat.key
            -- Per-category enable checkbox. First row indents 18 px
            -- relative to the master toggle so the rows visually nest
            -- under it; subsequent rows align with the first.
            local catCB = CreateFrame(
                "CheckButton",
                "WoWClearanceSellBorderCB_" .. key,
                content,
                "InterfaceOptionsCheckButtonTemplate"
            )
            local xOff = (i == 1) and 18 or 0
            local yOff = (i == 1) and -6 or -4
            catCB:SetPoint("TOPLEFT", lastRowAnchor, "BOTTOMLEFT", xOff, yOff)
            catCB:SetChecked(DB.sellBorderCategories[key].enabled)
            local catCBText = _G[catCB:GetName() .. "Text"]
            if catCBText then
                catCBText:SetText(cat.label)
                catCBText:SetJustifyH("LEFT")
            end
            rowCatCBTexts[i] = catCBText
            rowCatCBs[i] = catCB
            catCB:SetScript("OnClick", function()
                DB.sellBorderCategories[key].enabled = catCB:GetChecked() and true or false
                PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
                if NS.RefreshSellBorders then
                    NS.RefreshSellBorders()
                end
            end)

            -- Per-row [?] help icons were removed in a later iteration:
            -- every row pointed to the same `tshoot-bag-borders` Help entry
            -- as the master "Show borders" toggle's [?], so they added
            -- visual noise without conveying anything new. The master
            -- [?] above the rows covers the whole feature.

            -- Per-category swatch and Change-colour button on the same
            -- row, to the right of the label.
            local catSwatch = content:CreateTexture(nil, "OVERLAY")
            catSwatch:SetSize(16, 16)
            catSwatch:SetPoint("LEFT", catCBText or catCB, "RIGHT", 12, 0)
            catSwatch:SetTexture("Interface\\Buttons\\WHITE8X8")
            rowCatSwatches[i] = catSwatch

            local function updateCatSwatch()
                local entry = DB.sellBorderCategories[key]
                if entry and entry.color then
                    local c = entry.color
                    catSwatch:SetVertexColor(c.r, c.g, c.b, 1)
                end
            end
            updateCatSwatch()
            catSwatchUpdaters[#catSwatchUpdaters + 1] = updateCatSwatch

            local catBtn = CreateFrame(
                "Button",
                "WoWClearanceSellBorderColorBtn_" .. key,
                content,
                "UIPanelButtonTemplate"
            )
            catBtn:SetSize(110, 22)
            catBtn:SetPoint("LEFT", catSwatch, "RIGHT", 6, 0)
            catBtn:SetText(L["Change colour"])
            rowCatBtns[i] = catBtn
            catBtn:SetScript("OnClick", function()
                local c = DB.sellBorderCategories[key].color
                local function commit(r, g, b, a)
                    c.r, c.g, c.b, c.a = r, g, b, a
                    updateCatSwatch()
                    if NS.RefreshSellBorders then
                        NS.RefreshSellBorders()
                    end
                end

                -- Colour picker (port work item 6). THE ALPHA CONVENTION
                -- CHANGED, and this is the trap: 3.3.5a's OpacitySliderFrame
                -- was INVERTED (0 = fully opaque, 1 = fully transparent), so
                -- this code flipped on the way in and back on the way out.
                -- OpacitySliderFrame is gone, and ColorPickerFrame's
                -- GetColorAlpha() is NOT inverted - it is plain alpha, the
                -- same convention as the stored c.a.
                --
                -- So the flips are REMOVED, not ported. Porting the symbol
                -- while keeping `1 - x` would have silently inverted every
                -- saved bag-tint alpha: a 0.9 opaque tint would render at
                -- 0.1, and the setting would look broken rather than error.
                -- Credit to the BarWarden-Forever port for flagging that the
                -- convention moved twice.
                local function readPicked()
                    local r, g, b = ColorPickerFrame:GetColorRGB()
                    local a = 0.9
                    if ColorPickerFrame.GetColorAlpha then
                        a = ColorPickerFrame:GetColorAlpha() or 0.9
                    end
                    return r, g, b, a
                end
                local pickerInfo = {
                    r = c.r,
                    g = c.g,
                    b = c.b,
                    opacity = c.a or 0.9,
                    hasOpacity = true,
                    swatchFunc = function()
                        commit(readPicked())
                    end,
                    opacityFunc = function()
                        commit(readPicked())
                    end,
                    cancelFunc = function(prev)
                        if not prev then
                            return
                        end
                        -- The restore payload's alpha field name is not
                        -- pinned by anything measured here, so accept either
                        -- spelling rather than guess one and silently restore
                        -- a nil alpha on cancel.
                        local a = prev.a or prev.opacity or c.a or 0.9
                        commit(prev.r, prev.g, prev.b, a)
                    end,
                }
                if ColorPickerFrame.SetupColorPickerAndShow then
                    ColorPickerFrame:SetupColorPickerAndShow(pickerInfo)
                end
                -- The options container can sit at the same frame strata as
                -- the colour picker, so the picker renders behind it on some
                -- clients. Force it to the top AFTER the show call has reset
                -- the frame state.
                ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
                if ColorPickerFrame.Raise then
                    ColorPickerFrame:Raise()
                end
            end)

            lastRowAnchor = catCB
        end

        -- Swatch + button column. Each label gets a reactive width that
        -- stops short of the panel's right edge, and the swatch + button
        -- sit just past it. A fixed column measured from the widest label
        -- at build time went stale when another font (a UI skin) widened
        -- the labels afterwards and the text ran under the swatches.
        local SWATCH_COLUMN = 230
        for i, btn in ipairs(rowCatBtns) do
            local txt = rowCatCBTexts[i]
            local swatch = rowCatSwatches[i]
            if txt and swatch then
                WC_compCache.setPanelWidth(txt, SWATCH_COLUMN)
                if txt.SetWordWrap then
                    txt:SetWordWrap(false)
                end
                swatch:ClearAllPoints()
                swatch:SetPoint("LEFT", txt, "RIGHT", 8, 0)
                btn:ClearAllPoints()
                btn:SetPoint("LEFT", swatch, "RIGHT", 6, 0)
            end
        end

        -- v2.37.0 (Borrow C): item-level text overlay on bag slots. Master
        -- toggle + font size; the slider disables when the master is off.
        -- The -18 x-offset un-nests this section header from the
        -- indented per-category rows above.
        local iLvlHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        iLvlHeader:SetPoint("TOPLEFT", lastRowAnchor, "BOTTOMLEFT", -18, -16)
        iLvlHeader:SetText(L["Item level on bag slots"])

        local iLvlMainCB = CreateFrame(
            "CheckButton",
            "WoWClearanceILvlMainCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        iLvlMainCB:SetPoint("TOPLEFT", iLvlHeader, "BOTTOMLEFT", 0, -6)
        iLvlMainCB:SetChecked(DB.itemLevelOverlay.enabled)
        local iLvlMainText = _G[iLvlMainCB:GetName() .. "Text"]
        if iLvlMainText then
            iLvlMainText:SetText(L["Show item level on slots"])
            iLvlMainText:SetJustifyH("LEFT")
        end
        if iLvlMainText then
            NS.AddHelpIcon(content, iLvlMainText, "LEFT", "RIGHT", 6, 0, "tshoot-item-level-overlay")
        end

        -- v2.37.0 (Borrow C polish): font-size slider for the iLvl text.
        -- Default 12 (matches the original NumberFontNormalSmall size);
        -- player can scale down to 6 for crowded bag layouts or up to
        -- 20 for high-DPI displays. The slider greys out when the master is off.
        local iLvlSlider = CreateFrame(
            "Slider",
            "WoWClearanceILvlFontSizeSlider",
            content,
            "OptionsSliderTemplate"
        )
        iLvlSlider:SetPoint("TOPLEFT", iLvlMainCB, "BOTTOMLEFT", 18, -18)
        iLvlSlider:SetWidth(180)
        iLvlSlider:SetMinMaxValues(6, 20)
        iLvlSlider:SetValueStep(1)
        iLvlSlider:SetValue(DB.itemLevelOverlay.fontSize or 12)
        if iLvlSlider.SetObeyStepOnDrag then
            iLvlSlider:SetObeyStepOnDrag(true)
        end
        _G[iLvlSlider:GetName() .. "Low"]:SetText("6")
        _G[iLvlSlider:GetName() .. "High"]:SetText("20")
        local iLvlSliderText = _G[iLvlSlider:GetName() .. "Text"]
        if iLvlSliderText then
            iLvlSliderText:SetText(L["Item level font size: "] .. (DB.itemLevelOverlay.fontSize or 12))
        end
        iLvlSlider:SetScript("OnValueChanged", function(slider, value)
            value = math.floor((value or 12) + 0.5)
            if value < 6 then
                value = 6
            elseif value > 20 then
                value = 20
            end
            DB.itemLevelOverlay.fontSize = value
            if iLvlSliderText then
                iLvlSliderText:SetText(L["Item level font size: "] .. value)
            end
            if NS.RefreshItemLevelOverlay then
                NS.RefreshItemLevelOverlay()
            end
        end)

        local function syncILvlSliderEnabled()
            local on = DB.itemHighlighting ~= false and DB.itemLevelOverlay.enabled
            if on then
                iLvlSlider:Enable()
            else
                iLvlSlider:Disable()
            end
            if iLvlSliderText then
                if on then
                    iLvlSliderText:SetTextColor(1, 0.82, 0)
                else
                    iLvlSliderText:SetTextColor(0.5, 0.5, 0.5)
                end
            end
        end
        syncILvlSliderEnabled()

        -- Grey out everything under a switch that is off: the master
        -- switch covers every option, "Show borders" covers its colour
        -- rows, and "Show item level" covers its font size.
        self.syncHighlightControls = function()
            local on = DB.itemHighlighting ~= false
            local bordersOn = on and DB.sellBorderEnabled and true or false
            setControlOn(sbCB, on)
            for i, catCB in ipairs(rowCatCBs) do
                setControlOn(catCB, bordersOn)
                if rowCatBtns[i] then
                    rowCatBtns[i]:SetEnabled(bordersOn)
                end
                if rowCatSwatches[i] then
                    rowCatSwatches[i]:SetAlpha(bordersOn and 1 or 0.35)
                end
            end
            setControlOn(iLvlMainCB, on)
            syncILvlSliderEnabled()
        end
        self.syncHighlightControls()

        -- Now wire the master OnClick. Runs everything that depends on
        -- the master state: save the toggle, sync slider enable state,
        -- repaint visible slots.
        -- Single SetScript call - no chain via GetScript (which can
        -- swallow anonymous closures on 3.3.5a).
        iLvlMainCB:SetScript("OnClick", function()
            DB.itemLevelOverlay.enabled = iLvlMainCB:GetChecked() and true or false
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            syncILvlSliderEnabled()
            if NS.RefreshItemLevelOverlay then
                NS.RefreshItemLevelOverlay()
            end
        end)

        lastRowAnchor = iLvlSlider

        -- Tooltip section. Opt-in itemID annotation that appends the
        -- numeric item ID to the WC tooltip status line. Defaults OFF;
        -- power users (bug reports, list authoring by ID) flip this on.
        -- The -18 x-offset un-nests this section from the indented
        -- per-category rows above so the header aligns with the master
        -- sell-border toggle.
        local tipHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        tipHeader:SetPoint("TOPLEFT", lastRowAnchor, "BOTTOMLEFT", -18, -16)
        tipHeader:SetText(L["Tooltip"])

        local idCB = CreateFrame(
            "CheckButton",
            "WoWClearanceShowItemIDCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        idCB:SetPoint("TOPLEFT", tipHeader, "BOTTOMLEFT", 0, -6)
        idCB:SetChecked(DB.showItemIDOnTooltip)
        local idCBText = _G[idCB:GetName() .. "Text"]
        if idCBText then
            idCBText:SetText(L["Show item ID in tooltip"])
            idCBText:SetJustifyH("LEFT")
        end
        idCB:SetScript("OnClick", function()
            DB.showItemIDOnTooltip = idCB:GetChecked() and true or false
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            -- Tooltips don't re-render themselves while visible, and
            -- WC_AnnotateTooltip's __WC_annotated dedupe flag can keep
            -- an already-drawn tooltip pinned to the pre-toggle state
            -- until the cursor moves off it. Drop the flag and hide
            -- any visible tooltip so the next hover paints fresh -
            -- avoids needing a /reload to see the change take effect.
            if GameTooltip then
                GameTooltip.__WC_annotated = nil
                if GameTooltip:IsShown() then
                    GameTooltip:Hide()
                end
            end
            if ItemRefTooltip then
                ItemRefTooltip.__WC_annotated = nil
            end
        end)
        self.showItemIDCB = idCB

        -- v0.7.0: account-wide sold / looted counts on item tooltips.
        local statsCB = CreateFrame(
            "CheckButton",
            "WoWClearanceShowItemStatsCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        statsCB:SetPoint("TOPLEFT", idCB, "BOTTOMLEFT", 0, -2)
        statsCB:SetChecked(DB.showItemStatsOnTooltip)
        local statsCBText = _G[statsCB:GetName() .. "Text"]
        if statsCBText then
            statsCBText:SetText(L["Show how many you've sold and looted"])
            statsCBText:SetJustifyH("LEFT")
        end
        statsCB:SetScript("OnClick", function()
            DB.showItemStatsOnTooltip = statsCB:GetChecked() and true or false
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            if GameTooltip then
                GameTooltip.__WC_annotated = nil
                if GameTooltip:IsShown() then
                    GameTooltip:Hide()
                end
            end
        end)
        self.showItemStatsCB = statsCB

        -- Discoverability hint. The toggle takes effect on the NEXT
        -- tooltip render, not on already-visible ones - tell the user
        -- so they don't assume a /reload is required.
        local idHint = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        idHint:SetPoint("TOPLEFT", statsCB, "BOTTOMLEFT", 4, -2)
        idHint:SetText(L["|cff888888Move your cursor off and back on to refresh open tooltips.|r"])

        -- Single refresh helper that re-syncs every category's swatch
        -- and checkbox state. Called from the REFRESH branch of
        -- initPanel (when the user navigates back to the panel after
        -- a settings-pack import or other external DB mutation).
        self.RefreshSellBorderSwatch = function(panel)
            for _, updater in ipairs(catSwatchUpdaters) do
                updater()
            end
            for _, cat in ipairs(SELL_BORDER_CATEGORIES) do
                local cb = _G["WoWClearanceSellBorderCB_" .. cat.key]
                if cb and cb.SetChecked then
                    cb:SetChecked(DB.sellBorderCategories[cat.key].enabled)
                end
            end
            -- v2.37.0 (Borrow C): re-sync the item-level overlay toggles
            -- when the panel reshows. Same need as the sell-border row
            -- re-sync above: a settings import or external DB mutation
            -- could have changed DB.itemLevelOverlay since panel build.
            if iLvlMainCB and iLvlMainCB.SetChecked then
                iLvlMainCB:SetChecked(DB.itemLevelOverlay.enabled)
            end
            panel.syncHighlightControls()
        end

        -- v2.37.0 (Borrow C polish): size the scroll content frame to
        -- fit the bottom-most widget so the scroll bar engages when the
        -- Interface Options container is shorter than the rendered
        -- panel (the iLvl section + slider + Tooltip section together
        -- can exceed the natural panel height). idHint is the lowest
        -- widget; FitScrollContent measures its bottom edge against
        -- the content frame's TOPLEFT.
        if NS.FitScrollContent then
            NS.FitScrollContent(content, idHint)
        end
    end, true)
end)
