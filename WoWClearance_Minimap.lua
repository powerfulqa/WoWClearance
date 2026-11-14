-- WoWClearance_Minimap - minimap button, LDB launcher, combat-vendor button.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8b of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- Three self-contained UI buttons that live outside the Interface Options
-- panel hierarchy:
--
--   * WC_UpdateMinimapPos  - moves the minimap button to the stored angle
--                             (DB.minimapButtonAngle) via the kit's btn.Place.
--   * WC_CreateMinimapButton - draggable minimap button with left/middle/
--                              right-click bindings (options / Process /
--                              toggle) and a hover tooltip showing free
--                              bag slots, sellable count, est. value.
--                              dispatches through (combat-lockdown safe).
--   * WC_CreateLDBLauncher - LibDataBroker plugin so users with Bazooka,
--                            ChocolateBar, etc. get the same launcher in
--                            their preferred frame.
--
-- These are wired from WoWClearance_Events.lua's ADDON_LOADED branch via the
-- existing names (still file-scope locals in WoWClearance_Events.lua that we
-- expose on NS below). Existing call sites in WoWClearance_Events.lua
-- (PLAYER_LOGIN, slash command "/wc minimap") read NS-qualified names.
--
-- Cross-file dependencies read inline:
--   * NS.compCache               (Core)
--   * NS.DB / NS.ADB             - captured at function entry
--   * NS.PreviewSellable         (Vendor) - tooltip "Sellable now: N"
--   * NS.CopperToColoredText     (WoWClearance_Events.lua) - tooltip est. value
--   * NS.GetFreeBagSlots         (WoWClearance_Events.lua) - tooltip free slots
--   * NS.PrintNice / PrintNicef  (WoWClearance_Events.lua)
--   * _G["WoWClearanceOptionsMain"]      - main settings panel (named frame)
--   * _G["WoWClearanceOptionsProcessBags"] - Process Bags panel (named frame)
--   * WoWClearance_ToggleSettings / ToggleEnabled / ForceSell - WoW
--     globals from the keybinding handler block in WoWClearance_Events.lua

local NS = select(2, ...)

-- v0.5.8 (Serv report): the WC button sat exactly on top of another addon's.
-- Not a coincidence - the common minimap-button libraries default to 225
-- degrees, and WC defaulted to 220. Five degrees is roughly six pixels at
-- this radius, so two 24px buttons overlapped almost completely.
--
-- 190 clears it by 35 degrees, about 45 pixels of arc, which separates them
-- with room to spare. Exposed on NS so the three places that seed this value
-- cannot drift apart again - it was hardcoded in all three before.
--
-- Worth knowing if it ever collides again: the player can drag the button
-- and DB.minimapButtonAngle remembers it (saving works from client build
-- 70245), so changing it here only moves the button for new installs.
local MINIMAP_DEFAULT_ANGLE = 190
NS.MINIMAP_DEFAULT_ANGLE = MINIMAP_DEFAULT_ANGLE
local WC_compCache = NS.compCache
local L = NS.L

-- Moves the button to the saved angle. The shared kit owns the maths
-- (radius from the minimap size + 5, square-minimap clamp). A button that
-- another UI has collected (reparented away from the minimap, e.g. into a
-- button tray) is left where that UI put it: re-anchoring it to the
-- minimap would fight the collector.
local ICON = "Interface\\Icons\\INV_Misc_Coin_01"
local CLICK_HINT = L["Left-click: Settings  |  Middle-click: Process Bags  |  Right-click: Turn on/off  |  Drag: move"]

-- The standard minimap-button library, when another addon has loaded it.
-- WC ships no libraries, but a minimap-button collector only recognises
-- buttons built by that library: our own button gets wrapped with a
-- "custom button" notice in place of our tooltip. So with the library
-- present the button is registered through it, and the kit button is the
-- fallback.
local function dbIcon()
    return _G.LibStub and _G.LibStub("LibDBIcon-1.0", true)
end

-- The minimap button, whichever built it (nil when none exists).
local function WC_GetMinimapButton()
    local lib = dbIcon()
    return _G["WoWClearanceMinimapButton"] or (lib and lib:GetMinimapButton("WoWClearance"))
end

-- Moves the button to the saved angle. The shared kit owns the maths
-- (radius from the minimap size + 5, square-minimap clamp). A button that
-- another UI has collected (reparented away from the minimap, e.g. into a
-- button tray) is left where that UI put it: re-anchoring it to the
-- minimap would fight the collector.
local function WC_UpdateMinimapPos()
    local btn = _G["WoWClearanceMinimapButton"]
    if btn and btn.Place and btn:GetParent() == Minimap then
        btn.Place()
    end
    local lib = dbIcon()
    if lib and lib:GetMinimapButton("WoWClearance") then
        lib:Refresh("WoWClearance")
    end
end

-- One click handler for the minimap button and the LDB launcher.
local function WC_MinimapClick(_, button)
    local DB = NS.DB
    -- Shift+Left-Click reloads the UI. Deliberately undocumented (no
    -- tooltip line, Help entry or README row): a developer/tester
    -- convenience, not a player feature. Checked before the combat
    -- guard below because a reload is allowed in combat.
    if button == "LeftButton" and IsShiftKeyDown() then
        ReloadUI()
        return
    end
    if button == "LeftButton" then
        -- Combat lockdown blocks the InterfaceOptions panel-swap path;
        -- queue the open so it fires the moment combat ends. The user
        -- gets a one-line note so silent no-op doesn't look broken.
        if InCombatLockdown and InCombatLockdown() then
            WC_compCache.pendingOpenAfterCombat = "main"
            NS.PrintNice(L["|cffffb84dSettings will open when combat ends.|r"])
            return
        end
        NS.OpenOptionsPanel("WoWClearanceOptionsMain")
    elseif button == "MiddleButton" then
        if InCombatLockdown and InCombatLockdown() then
            WC_compCache.pendingOpenAfterCombat = "process"
            NS.PrintNice(L["|cffffb84dProcess Bags will open when combat ends.|r"])
            return
        end
        NS.OpenOptionsPanel("WoWClearanceOptionsProcessBags")
    elseif button == "RightButton" then
        if not DB then
            return
        end
        -- v2.39.1: route through the canonical helper so the
        -- minimap icon + Main panel checkbox + chat message +
        -- sound stay consistent with every other entry point.
        if WoWClearance_ToggleEnabled then
            WoWClearance_ToggleEnabled()
        end
    end
end

-- Tooltip body shared by both buttons: status lines, click hint last.
local function WC_MinimapTooltipLines()
    local DB = NS.DB
    local stateStr = (DB and DB.enabled ~= false) and L["|cff00ff00Enabled|r"] or L["|cffff4444Disabled|r"]
    local freeSlots = NS.GetFreeBagSlots()
    local slotColor = freeSlots >= 10 and "|cff00ff00" or (freeSlots >= 5 and "|cffffff00" or "|cffff4444")
    local sellCount, sellCopper = NS.PreviewSellable()
    local lines = {
        L["Status: "] .. stateStr,
        L["Free bag slots: "] .. slotColor .. freeSlots .. "|r",
        string.format(L["Sellable now: |cffffff00%d|r items"], sellCount),
    }
    if sellCopper > 0 then
        lines[#lines + 1] = L["Est. value: "] .. NS.CopperToColoredText(sellCopper)
    end
    return lines
end

-- Optional LibDataBroker-1.1 launcher. No-op if LibStub or LDB is not present,
-- so users on Titan Panel / Bazooka / ChocolateBar / etc. get an entry in
-- their display addon without us taking a hard dependency on anything.
-- Returns the data object (also the source of the library minimap button).
local function WC_CreateLDBLauncher()
    local LDB = _G.LibStub and _G.LibStub("LibDataBroker-1.1", true)
    if not LDB then
        return nil
    end
    local existing = LDB.GetDataObjectByName and LDB:GetDataObjectByName("WoWClearance")
    if existing then
        return existing
    end
    return LDB:NewDataObject("WoWClearance", {
        type = "launcher",
        label = "WoWClearance",
        icon = ICON,
        OnClick = WC_MinimapClick,
        OnTooltipShow = function(tt)
            tt:AddLine("|cff66ccffWoWClearance|r")
            for _, line in ipairs(WC_MinimapTooltipLines()) do
                tt:AddLine(line, 1, 1, 1, true)
            end
            tt:AddLine(CLICK_HINT, 0.6, 0.6, 0.6, true)
        end,
    })
end

-- The library keeps its position and hidden state in a table it reads and
-- writes. This one maps both onto WC's own saved fields, so the drag angle,
-- /wc minimap reset and the Show toggle stay one setting whichever button
-- is in use. The table stays empty, so every read and write goes through.
local iconDB = setmetatable({}, {
    __index = function(_, k)
        local DB = NS.DB
        if k == "minimapPos" then
            return DB and DB.minimapButtonAngle or MINIMAP_DEFAULT_ANGLE
        elseif k == "hide" then
            return DB and DB.minimapButton == false
        end
    end,
    __newindex = function(_, k, v)
        local DB = NS.DB
        if not DB then
            return
        end
        if k == "minimapPos" and type(v) == "number" then
            DB.minimapButtonAngle = v
        elseif k == "hide" then
            DB.minimapButton = not v
        end
    end,
})

local function WC_CreateMinimapButton()
    local DB = NS.DB
    if not DB then
        return
    end
    if WC_GetMinimapButton() then
        return
    end -- only create once
    -- v2.44.8: skip creation entirely when the player has the toggle off.
    -- v2.44.7's "create then Hide()" wasn't enough for Safra's report -
    -- even with the button hidden, the act of parenting a child frame to
    -- Minimap (which some host UI replacements hook aggressively) turned
    -- her minimap canvas black. Skipping creation removes the Minimap-
    -- parented child entirely; no parent-child link exists for a host
    -- UI hook to react to. NS.SetMinimapButtonVisible(true) lazy-creates
    -- if the player flips the toggle back on without a /reload.
    if DB.minimapButton == false then
        return
    end

    local lib = dbIcon()
    local obj = lib and NS.CreateLDBLauncher()
    if obj then
        lib:Register("WoWClearance", obj, iconDB)
        local b = lib:GetMinimapButton("WoWClearance")
        if b and b.icon and DB.enabled == false then
            b.icon:SetDesaturated(true)
        end
        return
    end

    -- The shared kit button: same look as RaidLootController's, and an
    -- OnUpdate only while dragging (the old one ran every frame).
    local btn = NS.Kit.MinimapButton({
        name = "WoWClearanceMinimapButton",
        icon = ICON,
        db = DB,
        key = "minimapButtonAngle",
        angle = MINIMAP_DEFAULT_ANGLE,
    })
    btn:SetScript("OnClick", WC_MinimapClick)

    -- Apply initial desaturation if disabled
    if DB.enabled == false then
        btn.icon:SetDesaturated(true)
    end

    -- Shared tooltip shape: brand title, status lines, grey click hint last.
    btn:SetScript("OnEnter", function(self)
        NS.Kit.MinimapTooltip(self, "WoWClearance", "66ccff", WC_MinimapTooltipLines(), CLICK_HINT)
    end)
    btn:SetScript("OnLeave", GameTooltip_Hide)
end

-- v2.44.7: runtime visibility toggle for the WC minimap button. Called by
-- the Main panel checkbox + the /wc minimap slash command.
-- v2.44.8: lazy-creates the button when flipping ON if creation was
-- skipped at ADDON_LOADED (DB.minimapButton was false). Required because
-- WC_CreateMinimapButton now early-returns instead of "create then Hide".
local function WC_SetMinimapButtonVisible(visible)
    local DB = NS.DB
    if DB then
        DB.minimapButton = visible and true or false
    end
    local btn = WC_GetMinimapButton()
    if visible and not btn then
        -- Creation was skipped at ADDON_LOADED. DB.minimapButton is true
        -- (we just set it), so the early-return inside doesn't trip.
        NS.CreateMinimapButton()
        btn = WC_GetMinimapButton()
    end
    local lib = dbIcon()
    if lib and lib:GetMinimapButton("WoWClearance") then
        -- The library reads "hide" from iconDB, which mirrors DB.
        if visible then
            lib:Show("WoWClearance")
        else
            lib:Hide("WoWClearance")
        end
    elseif btn then
        if visible then
            btn:Show()
            WC_UpdateMinimapPos()
        else
            btn:Hide()
        end
    end
end

NS.UpdateMinimapPos = WC_UpdateMinimapPos
NS.CreateMinimapButton = WC_CreateMinimapButton
NS.CreateLDBLauncher = WC_CreateLDBLauncher
NS.SetMinimapButtonVisible = WC_SetMinimapButtonVisible
NS.GetMinimapButton = WC_GetMinimapButton

-- Addon compartment entry (the minimap's addon-list button on Forever),
-- declared in the .toc via AddonCompartmentFunc. Same actions as the
-- minimap button, for players who hide that button: left-click opens
-- settings, right-click turns the addon on or off. Global by necessity:
-- the compartment looks the handler up by name.
function WoWClearance_OnAddonCompartmentClick(_, buttonName)
    if buttonName == "RightButton" then
        if NS.DB and WoWClearance_ToggleEnabled then
            WoWClearance_ToggleEnabled()
        end
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        WC_compCache.pendingOpenAfterCombat = "main"
        NS.PrintNice(L["|cffffb84dSettings will open when combat ends.|r"])
        return
    end
    NS.OpenOptionsPanel("WoWClearanceOptionsMain")
end
