-- Luacheck configuration for WoWClearance (WoW 3.3.5a / WotLK / Lua 5.1)
-- Run:  luacheck *.lua
-- (The addon ships as multiple WoWClearance_*.lua files after the
-- multi-stage file split; the original monolith WoWClearance.lua was
-- renamed to WoWClearance_Events.lua. CLAUDE.md tracks the exact count.)
-- See docs/ADDON_GUIDE.md for the rationale behind these settings.

std = "lua51"
max_line_length = 140

-- Ignore (idiomatic WoW-UI noise, not defects; see docs/ADDON_GUIDE.md):
--   212 : unused function argument. WoW script handlers and panel-builder
--         callbacks have fixed positional signatures (self, event, elapsed,
--         slider, panel, ...); many callbacks legitimately use only some.
--   213 : unused loop variable (common in pairs/ipairs with only values).
--   431 : shadowing an upvalue. Nested closures re-localise `DB = NS.DB`
--         inside a builder/handler; harmless and common across the panels.
--   432 : shadowing an upvalue ARGUMENT. The pervasive pattern is the outer
--         `self` (the panel) vs an inner widget-handler `self`; the inner
--         one is the intended receiver at that scope.
--   631 : line is too long (some colour-coded strings are unavoidably long).
ignore = { "212", "213", "431", "432", "631" }

-- WoW saved variables and slash-command handles: addon writes to these at the
-- global scope. Everything else in the addon should stay local.
globals = {
    "WoWClearanceDB",
    "WoWClearanceAccountDB",   -- account-wide whitelist store
    "SLASH_WOWCLEARANCE1",
    "SLASH_WCDEBUG1",
    "SlashCmdList",
    "ChatEdit_InsertLink",      -- replaced by module to capture shift-click links (3.3.5a path)
    "ContainerFrameItemButtonMixin",            -- v0.5.2: the Forever replacement for the above
    -- Keybinding headers / names (read by Blizzard, set by addon)
    "BINDING_HEADER_WOWCLEARANCE",
    "BINDING_NAME_WOWCLEARANCE_TOGGLE_SETTINGS",
    "BINDING_NAME_WOWCLEARANCE_TOGGLE_ENABLED",
    "BINDING_NAME_WOWCLEARANCE_FORCE_SELL",
    -- Globally-exposed handlers called from Bindings.xml
    "WoWClearance_ToggleSettings",
    "WoWClearance_ToggleEnabled",
    "WoWClearance_OnAddonCompartmentClick",
    "WoWClearance_ForceSell",
    "WoWClearance_DeleteNext",
    "BINDING_NAME_WOWCLEARANCE_DELETE_NEXT",
    -- Provenance / attribution globals (see LICENSE §2; do not remove).
    "WOWCLEARANCE_IDENT",
    "WOWCLEARANCE_AUTHOR",
    "WOWCLEARANCE_ORIGIN",
    "__WoWClearance_origin",
    "__WoWClearance_author",
    -- _G is writable because one binding name contains a space (standard
    -- Blizzard pattern for SecureActionButton-based keybinds, see
    -- WoWClearanceTargetMerchantButton wiring).
    "_G",
    -- StaticPopupDialogs is read-only by Blizzard's API but we register
    -- our own dialog templates onto it (StaticPopupDialogs.WC_CONFIRM_*).
    -- Treating it as writable silences the "setting read-only field" noise
    -- on every dialog registration.
    "StaticPopupDialogs",
    -- v2.50.x: loot-log toggle handler + its Bindings.xml name (called from
    -- Bindings.xml / SlashCmdList, same pattern as the other handler globals).
    "WoWClearance_ToggleLootLog",
    "BINDING_NAME_WOWCLEARANCE_TOGGLE_LOOTLOG",
    -- SetItemRef is REPLACED (not hooked) so a custom "wcupdate:" chat link
    -- opens the update popup; the stock 3.3.5a handler errors on it. See the
    -- WC-TRAP in WoWClearance_Comms.lua. Written at file scope, so writable.
    "SetItemRef",
    "LinkProcessorResponse",  -- v0.5.4: Forever link dispatcher; verified in shipped source
    "LinkUtil",  -- v0.5.4: Forever link dispatcher; verified in shipped source
    -- GameTooltip / ItemRefTooltip get a custom `__WC_annotated` marker field
    -- written on them (dedupe guard for the tooltip annotation hook). Listed
    -- as writable so the field write isn't flagged read-only; still read
    -- elsewhere, which writable also permits.
    "GameTooltip",
    "ItemRefTooltip",
    -- v0.5.7: ChatFrameUtil.InsertLink is REPLACED to capture shift-clicked
    -- item links into a WC ID box, for the same reason as SetItemRef above:
    -- the wrapper must early-return to stop the link leaking into the chat
    -- editbox, and a hook cannot suppress.
    --
    -- Declared ONCE here, writable, rather than also in read_globals. A
    -- read_globals fields list wins over a writable declaration of the same
    -- namespace, so having both left the write flagged read-only no matter
    -- which one named the field. Writable permits reads too, which is the
    -- same resolution GameTooltip above uses.
    ChatFrameUtil = {
        fields = { "InsertLink" },
    },
}

-- WoW 3.3.5a API surface this addon touches. Grouped loosely by subsystem.
-- If the addon starts using a new API, add it here rather than silencing
-- the whole check.
read_globals = {
    -- Frame/UI
    -- (GameTooltip / ItemRefTooltip moved to the writable `globals` block:
    -- we set a custom __WC_annotated field on them.)
    "CreateFrame", "CreateFont", "UIParent", "Minimap",
    -- v0.5.7: NOT a Blizzard global. Some UI replacements define it to report
    -- a square minimap; the call site guards for its absence.
    "GetMinimapShape",
    "MerchantFrame", "OpenAllBags", "OpenBackpack", "OpenBag",
    "HideUIPanel",  -- v0.5.4: UIParentPanelManager.lua:903; verified by shipped-source grep
    "PlaySound", "SOUNDKIT", "StaticPopup_Show", "StaticPopup_Hide",
    "GameTooltip_Hide", "UIFrameFlash",
    "ColorPickerFrame",
    -- OpacitySliderFrame and OpenColorPicker are ABSENT on WoW: Forever and
    -- were removed from the code in work item 6. Deliberately NOT declared,
    -- so reintroducing either is a lint error rather than a silent nil - the
    -- colour-picker alpha convention also flipped (the old slider was
    -- inverted; ColorPickerFrame:GetColorAlpha is not), so a reintroduction
    -- would likely carry the inversion back with it.
    "CANCEL",
    "StaticPopup_Visible",

    -- Error handler
    "geterrorhandler",

    -- Chat
    "DEFAULT_CHAT_FRAME",

    -- Items / bags
    "DeleteCursorItem", "ClearCursor",
    -- Equipped inventory (v2.10.0 auto-protect-equipped path)
    "GetInventoryItemLink",

    -- Merchant
    "GetMerchantItemLink",
    "RepairAllItems", "GetRepairAllCost", "CanMerchantRepair",
    "GetMoney",
    -- Guild bank repair (v2.9.0 optional repair-funds path)
    "IsInGuild", "CanGuildBankRepair", "GetGuildBankWithdrawMoney", "GetGuildBankMoney",

    -- Unit / player
    "UnitName", "UnitExists", "UnitClass",
    -- "First Surname" on Forever (NameUtil.lua), the spelling of message senders.
    "GetUnitName",
    "IsMounted",
    "IsAltKeyDown", "IsShiftKeyDown", "IsControlKeyDown", "InCombatLockdown",
    "ReloadUI",
    "IsMouseButtonDown",

    -- Blizzard constants / static popup buttons
    "YES", "NO", "OKAY",
    -- Locale strings used by the auto-open container tooltip scan
    "ITEM_OPENABLE", "LOCKED",
    -- Cursor positioning for the bag right-click popup
    "GetCursorPosition", "GetCursorInfo",
    -- Escape-key auto-hide for the bag right-click popup
    "UISpecialFrames",
    -- Shared kit copy window (WoWClearance_Kit.lua); Blizzard_SharedXML
    "ButtonFrameTemplate_HidePortrait",
    -- UIDropDownMenu_* / CloseDropDownMenus and MenuUtil are deliberately NOT
    -- declared: on Forever the first taints the action bars and the second
    -- crashed the client. Use NS.MakeSelector (WoWClearance_PanelWidgets.lua).

    -- Keybinding
    "GetBindingKey", "GetBindingAction", "SetBinding", "SaveBindings", "GetCurrentBindingSet",

    -- Addon metadata

    -- Misc utilities
    "hooksecurefunc", "wipe", "select", "tinsert",
    "ITEM_QUALITY_COLORS",
    "GetTime", "date", "time", "debugprofilestop",
    "GetRealmName",

    -- ------------------------------------------------------------------
    -- Additional 3.3.5a API surface reconciled when the luacheck CI gate
    -- was re-enabled (docs/CODE_REVIEW.md item 4). Grouped by subsystem.
    -- ------------------------------------------------------------------
    -- Items / bags (more)
    "CursorHasItem",
    "NUM_TOTAL_EQUIPPED_BAG_SLOTS", "NUM_CONTAINER_FRAMES",
    -- Item tooltip locale strings (Process Bags + protection scans)
    "ITEM_BIND_ON_EQUIP", "ITEM_BIND_ON_PICKUP",
    "ITEM_MILLABLE", "ITEM_PROSPECTABLE", "ITEM_SOULBOUND", "ITEM_SPELL_KNOWN",
    "ITEM_SPELL_TRIGGER_ONUSE",

    -- Unit / player (more)
    "UnitLevel", "UnitCastingInfo",
    -- Spellbook (recipe learn-state scans)
    -- Equipment Manager sets: the three 3.3.5a globals (GetEquipmentSetInfo,
    -- GetEquipmentSetItemIDs, GetNumEquipmentSets) were REMOVED from this list
    -- once the last call site moved to C_EquipmentSet. All three are measured
    -- nil on Forever, so leaving them declared made the guard below vacuous:
    -- a bare GetEquipmentSetItemIDs(name, buf) - the exact spelling the old
    -- code used, and so the exact spelling someone would reintroduce - linted
    -- clean. Undeclared, it is now an "accessing undefined variable" error.
    -- CVars / modified-click
    "GetCVarBool", "IsModifiedClick",
    -- Addon list + CPU/memory diagnostics (/wc bugreport)
    "GetAddOnCPUUsage", "GetAddOnMemoryUsage",
    "UpdateAddOnCPUUsage", "UpdateAddOnMemoryUsage",
    -- Money / coin text
    -- Zone / locale / guild / group / perf
    "GetRealZoneText", "GetLocale", "GetGuildInfo", "GetInventoryItemID",
    "GetFramerate",
    -- Addon-to-addon comms transport
    -- Bit library (3.3.5a exposes the BitLib `bit` table globally)
    "bit",

    -- _G moved to the writable globals block above; we write to _G[...]
    -- for one keybinding name that contains a space.

    -- =====================================================================
    -- WoW: Forever (Mainline) namespaces. Port work item 3.
    -- =====================================================================
    -- Declared with explicit `fields` rather than as bare names, and that
    -- distinction is the whole point.
    --
    -- A bare `"C_Item"` here tells luacheck the global exists and vouches
    -- for NOTHING inside it, so `C_Item.GetItemCooldownDuration(123)` - a
    -- member that does not exist on this client - lints clean and ships.
    -- With `fields`, luacheck reports "accessing undefined field" and the
    -- existing CI gate catches it at zero extra cost.
    --
    -- The sharp case: C_EquipmentSet below deliberately OMITS
    -- GetEquipmentSetItemIDs. The namespace exists on Forever and so do its
    -- other two members, but that one does not - measured, not assumed. It
    -- was the source of this addon's gear-set rescue cache, so anyone
    -- reaching for it again gets a lint error instead of a silent nil.
    --
    -- Rule for this block: a member goes in ONLY when it has been seen on
    -- the live client (WCProbe capture) or in the forever_api.json baseline.
    -- Adding one on the strength of a wiki page or a third-party shim table
    -- defeats the guard. See docs/PORT_STATUS.md.
    --
    -- The 3.3.5a globals above stay until work item 4 ports their call
    -- sites; the two surfaces coexist during the migration.
    C_Container = {
        fields = {
            "GetContainerItemInfo", "GetContainerNumSlots", "GetContainerItemLink",
            "GetContainerItemID", "GetContainerNumFreeSlots",
            "UseContainerItem", "PickupContainerItem",
        },
    },
    C_Item = {
        fields = {
            "GetItemInfo", "GetItemCount",
            "IsEquippedItem", "IsEquippableItem",
            "IsUsableItem", "GetItemFamily",
            "RequestLoadItemDataByID",
            -- Per-copy reads (verified on Forever): the copy's real item
            -- level, the refund check, and the location validity check.
            "GetCurrentItemLevel", "GetDetailedItemLevelInfo",
            "CanBeRefunded", "DoesItemExist",
            -- Class IDs for tome detection (no server data needed) and the
            -- per-copy GUID the delete popup carries (verified on Forever).
            "GetItemInfoInstant", "GetItemGUID", "IsItemDataCachedByID",
        },
    },
    C_TransmogCollection = {
        -- "Keep appearances you haven't collected" protection.
        fields = { "GetItemInfo", "PlayerHasTransmogItemModifiedAppearance", "PlayerCanCollectSource" },
    },
    ItemLocation = {
        fields = { "CreateEmpty" },
    },
    C_Spell = {
        fields = {
            "GetSpellInfo",
        },
    },
    C_SpellBook = {
        fields = {
            "IsSpellInSpellBook",
        },
    },
    C_AddOns = {
        fields = {
            "GetAddOnMetadata", "GetAddOnInfo", "IsAddOnLoaded", "GetNumAddOns",
            -- Loot module: core namespace access + its on/off switch.
            "GetAddOnLocalTable", "DoesAddOnExist", "GetAddOnEnableState",
            "EnableAddOn", "DisableAddOn",
        },
    },
    C_ChatInfo = {
        -- RegisterAddonMessagePrefix is MANDATORY on this client: without it
        -- CHAT_MSG_ADDON is never delivered for the prefix and the comms
        -- layer fails silently. See docs/PORT_STATUS.md.
        fields = { "SendAddonMessage", "RegisterAddonMessagePrefix", "SendChatMessage", "InChatMessagingLockdown" },
    },
    C_CurrencyInfo = {
        -- The replacement for the absent GetCoinTextureString; verified live.
        fields = { "GetCoinTextureString" },
    },
    C_TooltipInfo = {
        -- Structured replacement for the hidden-GameTooltip line scan.
        fields = { "GetBagItem" },
    },
    C_EquipmentSet = {
        -- GetEquipmentSetItemIDs is ABSENT on this client. Do not add it.
        -- GetEquipmentSetIDs and GetItemIDs were both seen in this client's
        -- live member dump (probe, 2026-09-18), which is what qualifies them
        -- for this list. Note the probe measured that the members EXIST; it
        -- did not measure what they RETURN, because the probed character had
        -- no saved sets. The call site in WoWClearance_Events.lua carries a
        -- WC-TRAP explaining why it iterates with pairs rather than ipairs.
        fields = { "GetNumEquipmentSets", "GetEquipmentSetInfo", "GetEquipmentSetIDs", "GetItemIDs" },
    },
    C_Timer = {
        fields = { "After", "NewTicker" },
    },
    Settings = {
        fields = {
            "RegisterCanvasLayoutCategory", "RegisterCanvasLayoutSubcategory",
            "RegisterAddOnCategory", "OpenToCategory",
        },
    },
    -- Frames and enums: members are Blizzard-defined and numerous, so these
    -- stay bare. They are declared only so the names resolve.
    "SettingsPanel",
    "TooltipDataProcessor",
    "Enum",
    -- Blizzard's chat filters guard every chat payload with this; present on
    -- Forever (captured bare in Blizzard_ChatFrameBase/ChatFrameFilters.lua).
    "canaccessvalue",
    "Ambiguate",
    "InCombatLockdown",
    "IsInRaid", "IsInGroup", "LE_PARTY_CATEGORY_INSTANCE",
}
