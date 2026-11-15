-- WoWClearance_Events - event hub + slash commands + residual glue.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Responsibility: event hub, slash commands, Bindings.xml handlers, and
-- the glue that ties Core / Companion / Protection / Vendor / Process /
-- the panel files together. ADDON_VERSION (read from the .toc) lives in
-- this file. See docs/CODE_REVIEW.md "Resolved -> file split" for
-- the history of how this file got carved out of the original monolith.
--
-- Shared namespace for the addon. WoW passes (addonName, namespaceTable) as
-- the varargs to every .lua file in an addon; the same table is shared
-- across files. NS was first bootstrapped in Stage 1 of the file split and
-- has been the spine of every subsequent extraction. Reading or writing
-- NS.foo from any WoWClearance_*.lua file picks up the same table this
-- assignment creates. `select(2, ...)` is used instead of
-- `local addonName, NS = ...` because the main chunk is already at Lua
-- 5.1's 200-locals cap; capturing only the namespace (and not the addon
-- name string, which we don't use) spends one slot instead of two.
local NS = select(2, ...)
local IsAddOnLoaded = C_AddOns.IsAddOnLoaded
local GetAddOnMetadata = C_AddOns.GetAddOnMetadata
local GetContainerNumFreeSlots = C_Container.GetContainerNumFreeSlots
local GetContainerItemLink = C_Container.GetContainerItemLink

local ADDON_NAME = "WoWClearance"
-- Provenance globals (WOWCLEARANCE_* and __WoWClearance_*) plus the
-- WC_Fingerprint helper now live in WoWClearance_Core.lua per the file
-- split (Stage 2, see docs/CODE_REVIEW.md item 4). Core writes those
-- globals on load and exposes the helper as NS.Fingerprint. The byline
-- strings are read directly from NS.ADDON_AUTHOR / NS.ADDON_URL where the
-- settings byline is built (WoWClearance_MainPanel.lua).

-- Localization passthrough. NS.L is a metatable-backed table set by
-- WoWClearance_Locale.lua (loads earlier per the .toc), so it exists at
-- this file's load time. L[key] returns key unchanged unless a translation
-- exists, so wrapping player-facing strings is a no-op on the enUS client.
local L = NS.L

-- The .toc `## Version:` field is the single source of truth; the release
-- workflow rewrites only the .toc. WoW re-reads .toc files on a client
-- restart, not on /reload, so right after an in-place update the shown
-- version stays the old one until the game restarts.
local ADDON_VERSION = GetAddOnMetadata(ADDON_NAME, "Version") or "unknown"
local function WC_GetVersion()
    return ADDON_VERSION
end
-- Exposed to split files (the bug-report builder in Stage 8 reads this).
NS.GetVersion = WC_GetVersion

-- Build watermark: a precomputed fingerprint of "WoWClearance@<version>".
-- Exposed as a global so /run inspection and external auditors can read it.
-- If this exact 6-char hex value (computed for our version) ever appears in
-- another addon's source, that addon is a verbatim copy of WoWClearance.
-- Lives in this file (not Core) because it reads ADDON_VERSION.
_G["__WoWClearance_watermark"] = NS.Fingerprint("WoWClearance@" .. ADDON_VERSION)

local WC_GetPlayerName
local WC_IsAddonEnabledForChar

-- Cached API upvalues (the C_* namespaces on Forever). Local lookups beat _G hash on hot paths
-- (bag scans, vendor loop, pet-check OnUpdate). See docs/ADDON_GUIDE.md.
local GetItemInfo = C_Item.GetItemInfo
local GetContainerItemID = C_Container.GetContainerItemID
local GetContainerNumSlots = C_Container.GetContainerNumSlots
local UseContainerItem = C_Container.UseContainerItem
local PickupContainerItem = C_Container.PickupContainerItem
local DeleteCursorItem = DeleteCursorItem
-- Merchant API (GetMerchantNumItems / GetMerchantItemInfo / GetMerchantItemLink)
-- removed from the cached-upvalue block: not currently called on any hot path.
-- Re-add here if a future feature needs them.
local IsEquippedItem = C_Item.IsEquippedItem -- v0.5.1: moved to C_Item on Forever
-- v0.5.7: GetItemCount is namespaced too. The bare global appears ZERO times
-- in the shipped UI source, so it is gone, and all three call sites below
-- used the "GetItemCount and GetItemCount(...)" fail-open idiom - which
-- resolved to nil and then "or 0", silently returning a count of zero
-- forever. See the WC-TRAP at the external-delete check for what that cost.
local GetItemCount = C_Item.GetItemCount
-- v0.5.7: same story, same idiom. Both verified present on this client
-- (C_Item.IsUsableItem -> usable, noMana; C_Item.GetItemFamily -> number?)
-- and verified ABSENT as bare globals - zero occurrences each across the
-- shipped UI source. These two failed CLOSED rather than open, so they
-- disabled a self-heal and a skip rather than inverting a safety check,
-- which is why they were less visible than GetItemCount.
local IsUsableItem = C_Item.IsUsableItem
local GetItemFamily = C_Item.GetItemFamily
local UnitName = UnitName
local GetCursorInfo = GetCursorInfo
local GetTime = GetTime

-- The shared cross-file cache table. The actual table literal lives in
-- WoWClearance_Core.lua (Stage 2 of the file split, see docs/CODE_REVIEW.md
-- item 4) and is exposed on the addon namespace as NS.compCache. We re-bind
-- it to the file-scope upvalue here so every `WC_compCache.foo` reference
-- downstream resolves through the local. Same table; both names alias the
-- same memory. Comments documenting individual fields live next to the
-- declaration in Core.
local WC_compCache = NS.compCache

-- v2.59.5 (Serv report): city zones don't count as farming areas. A player
-- vendoring mailboxed items in Dalaran / Stormwind / Orgrimmar is not
-- farming there, so their sale copper should not pollute the "Top Zones"
-- leaderboard the Stats / Stats-Guild / Stats-Server panels render.
-- Consumed by WC_compCache.attributeCopperToZone (sender-side skip),
-- the receiver-side decode filters in GuildShare / ServerShare (drop
-- city entries from peer payloads), and the EnsureDB / EnsureAccountDB
-- scrubs that strip historical city keys from DB.copperByZone and
-- ADB.accountStats.copperByZone. Wallet totalCopper is bumped
-- separately and stays accurate.
--
-- v2.59.11 (Serv report - "Fossoyeuse" appeared in Realm's Best Farming
-- Zones): the pre-fix set was enUS only. Realm-wide aggregation pools
-- from EVERY locale on the realm, so a frFR client writes "Fossoyeuse"
-- (French Undercity) into their bucket and sends it in SDAT. Our
-- English-locale receiver didn't recognize the localized name and let
-- it land on the leaderboard. Now the set covers the ten WotLK capitals
-- across enUS/enGB, deDE, frFR, and esES/esMX. Additional locales
-- (ruRU, koKR, zhCN/zhTW) can be added when reported - keeping the
-- table small until a specific locale's names show up in the wild.
local WC_CITY_ZONES_BY_LOCALE = {
    -- enUS / enGB (Project Ebonhold's primary audience)
    enUS = {
        "Stormwind City", "Ironforge", "Darnassus", "The Exodar",
        "Orgrimmar", "Thunder Bluff", "Undercity", "Silvermoon City",
        "Shattrath City", "Dalaran",
    },
    -- deDE
    deDE = {
        "Sturmwind", "Eisenschmiede", "Darnassus", "Die Exodar",
        "Orgrimmar", "Donnerfels", "Unterstadt", "Silbermond",
        "Shattrath", "Dalaran",
    },
    -- frFR
    frFR = {
        "Hurlevent", "Forgefer", "Darnassus", "L'Exodar",
        "Orgrimmar", "Les Pitons du Tonnerre", "Fossoyeuse", "Lune-d'argent",
        "Shattrath", "Dalaran",
    },
    -- esES / esMX
    esES = {
        "Ventormenta", "Forjaz", "Darnassus", "El Exodar",
        "Orgrimmar", "Cima del Trueno", "Entra\195\177as", "Lunargenta",
        "Shattrath", "Dalaran",
    },
}
local WC_CITY_ZONES = {}
for _, names in pairs(WC_CITY_ZONES_BY_LOCALE) do
    for _, name in ipairs(names) do
        WC_CITY_ZONES[name] = true
    end
end
function WC_compCache.isCityZone(zone)
    return type(zone) == "string" and WC_CITY_ZONES[zone] == true
end

-- Open the named options sub-panel. Centralised here (on NS, so the minimap
-- and LDB launcher reach it too) rather than copy-pasted at every open site.
-- Callers pass the global FRAME name, e.g. "WoWClearanceOptionsMain", which
-- is the convention every existing caller already uses.
--
-- The old body called InterfaceOptionsFrame_OpenToCategory TWICE, and the
-- WC-TRAP on it said not to dedupe: on 3.3.5a the first call only registered
-- the category and the second actually focused it. That trap is retired, not
-- ignored - its premise was a bug in a function that no longer exists.
-- Settings.OpenToCategory is a single call on Forever, and calling it twice
-- re-opens the panel.
--
-- Note the argument change: Settings.OpenToCategory takes a category ID, not
-- a frame, so the frame name is mapped through the registry built at
-- registration time (see NS.RegisterOptionsSub in WoWClearance_PanelInfra.lua).
function NS.OpenOptionsPanel(frameName)
    -- v0.5.3: WC's OWN entry points (minimap, /wc, the Help panel's jump
    -- buttons) route to the standalone window rather than the Settings
    -- panel. Opening a Settings page calls CloseAllBags and suppresses
    -- keybinds, because SettingsPanel is an area="center" UIPanel with no
    -- allowOtherPanels - see WoWClearance_Window.lua for the source refs.
    -- The Settings registration is still live, so Esc -> Options continues
    -- to work for anyone who goes looking there.
    --
    -- v0.6.0: the Settings.OpenToCategory fallback is gone. Window.lua always
    -- loads first, and the fallback was a restricted call
    -- (C_SettingsUtil.OpenSettingsPanel, HasRestrictions) that the combat-end
    -- drain could have reached outside a hardware event.
    NS.ShowStandaloneWindow(frameName)
end

-- v2.65.1 (Serv report - rough-terrain farming spammed the chat with
-- "went quiet" / "resummoned" every 10-15 s while the recovery loop
-- correctly dismissed + re-summoned a stuck pet). The recovery MECHANIC
-- is legitimate; the spam is what makes it read as "lots of problems".
-- Rate-limit the announce to at most one pair (went quiet -> resummoned)
-- per WC_RECOVERY_ANNOUNCE_COOLDOWN seconds. Subsequent stuck-signal
-- dismiss+resummons within the cooldown still happen, just silently.
-- Counter + last-fire timestamp surface in /wc bugreport so a session's
-- actual recovery cadence stays visible without chat noise.
--
-- v2.9.0 manual-sell attribution. inSelfSell brackets every UseContainerItem
-- call DoNextAction makes so the hooksecurefunc bound at ADDON_LOADED skips
-- it (counters are bumped directly by the worker queue). snapshot is a
-- slot -> { link, count, itemID } map taken at MERCHANT_SHOW and refreshed
-- per-slot after every observed sell; the hook reads it to identify what
-- just left a bag slot once the slot is empty.
local WC_manualSell = {
    inSelfSell = false,
    snapshot = {},
    hookInstalled = false,
}
-- vendorRunning state was promoted from `local running = false` to
-- WC_compCache.vendorRunning (initialised in WoWClearance_Core.lua's
-- table literal), shared through the cache table.

-- Forward-declared so WC_AddItemToList (defined below) can call it before the
-- helper body is reached further down the file. Returns the name of a list
-- that already holds the item with a different intent (keep / sell / delete),
-- or nil when the add is safe. Same-intent scopes (character whitelist plus
-- account whitelist) do not conflict.
local WC_FindAddConflict

-- v2.51.0: forward-declare the diagnostic-hook helpers so hook sites
-- above their definitions can call them. Each helper is a session-local
-- ring-buffer / snapshot / timestamp appender consumed by
-- /wc bugreport. Bodies are assigned further down the file next to the
-- ring buffer they own. Without the forward-declare, load-time
-- resolution would bind these names to (nil) globals - the runtime
-- error "attempt to call global 'WC_StampEvent' (a nil value)" v2.51.0
-- initially shipped with, before this fix.
local WC_LogSilentRefusal
local WC_LogRecentSold
local WC_LogRecentDeleted
local WC_StampEvent

-- Forward-declared on NS so the Character Settings panel's toggle +
-- colour-picker closures can call it before the bag-display hooks (which
-- own the body) install. Stub-assigned to a no-op here so settings flips
-- work even before the hooks register. The real body is assigned by
-- WoWClearance_BagDisplay.lua (Stage 6 of the file split, see
-- docs/CODE_REVIEW.md item 4). Lives on NS rather than as a file-scope
-- local because the body assignment is in a different file post-Stage-6;
-- a `local` here would mean BagDisplay's assignment creates a global
-- instead of replacing the stub. Callers reach it as NS.RefreshSellBorders.
NS.RefreshSellBorders = function() end

-- ===========================================================================
-- Per-character partition (v2.34.x migration).
-- ---------------------------------------------------------------------------
-- The .toc declares `## SavedVariables: WoWClearanceDB, WoWClearanceAccountDB`
-- which makes BOTH tables account-wide. Prior to this migration the
-- documented "per-character" semantics for the lists / profiles / per-mode
-- preferences were silently account-wide; every character on the account
-- shared the same Keep List, Sell List, Delete List, profile catalogue,
-- and the Process Bags ignore / collapsed-section state. Reported in-game
-- as the auto-Keep-equipped tag leaking onto a freshly-logged alt that
-- had never worn the item.
--
-- Fix without a .toc-directive change (which would risk cross-character
-- data loss because WoW serializes per-saved-variable-name): partition
-- inside the existing account-wide table.
--
--   * Top-level `WoWClearanceDB.<field>` stays as the legacy snapshot.
--     Reads / writes from current code never go here (the proxy routes
--     PER_CHAR_FIELDS to the per-character namespace). The snapshot is
--     the seed for newly-migrated characters AND the downgrade safety
--     net: a v2.33.x-or-earlier client looking for `DB.blacklist` etc.
--     still finds its pre-migration baseline at the top level.
--   * `WoWClearanceDB.chars[charKey]` holds each character's live data.
--     Each character gets a deep-copy of the snapshot on first load with
--     the new schema, then diverges from there.
--   * `DB` is a metatable proxy: PER_CHAR_FIELDS route to
--     `chars[charKey]`, everything else routes to the top level.
--
-- Test 66 in tests/test_perf_guardrails.lua locks the structural
-- invariants of this partition.
local PER_CHAR_FIELDS = {
    -- v2.75.0 (fresh-audit fix): the master Enable/Disable flag. The README,
    -- the panel checkbox, and /wc enable|disable have always described this as
    -- per-character ("skip the addon on alts"), but the flag was routed to the
    -- account-wide top level, so disabling on one alt disabled every character.
    -- Making it per-character matches the documented behaviour. Existing saves
    -- migrate: a character namespace that predates this seeds `enabled` from the
    -- frozen account-wide value (see the seed block in EnsureDB), so a player
    -- who had WC disabled account-wide is never silently re-enabled.
    enabled = true,
    blacklist = true,
    blacklistAuto = true,
    whitelist = true,
    deleteList = true,
    whitelistProfiles = true,
    blacklistProfiles = true,
    activeProfileName = true,
    processIgnored = true,
    processCollapsedModes = true,
    -- v2.62.0 per-skill Process Bags toggles ({ mode = bool }, default-on).
    -- Per-character because professions vary by alt (mirrors the
    -- processCollapsedModes / processIgnored precedent).
    processEnabledModes = true,
    -- v2.35.x gold-per-hour stats. bestGPH stores the highest sustained
    -- session GPH (copper/hour) the character has reached; bestGPHAt is
    -- the wall-clock timestamp via `time()` so the panel can render a
    -- humanised "N days ago" / absolute-date string; bestGPHZone is the
    -- GetRealZoneText snapshot at the moment the best was set. All
    -- three are written atomically by the RefreshStats best-update
    -- gate (5-minute minimum session). See
    -- EbonClearance's docs/specs/2026-05-26-gph-stats-design.md.
    bestGPH = true,
    bestGPHAt = true,
    bestGPHZone = true,
    -- Per-character loot ledger (itemID -> total quantity looted by this
    -- character, persisted). The Loot Log's Character scope reads this; the
    -- account-wide aggregate lives in ADB.accountStats.lootedItemCounts and
    -- the live session view in the in-memory WC_lootSession.
    lootedItemCounts = true,
    -- v0.6.0: the Sold History logs (sold + deleted), saved per character
    -- so each character's history survives logout. Shape and loader live
    -- next to the logs (WC_compCache.loadSoldHistory).
    soldHistory = true,
    -- v2.36.x Help / FAQ panel per-section collapse state. Stored
    -- per-character so each character can independently choose which
    -- sections (troubleshooting / gates / labels) are expanded vs
    -- collapsed. Matches the processCollapsedModes precedent. See
    -- EbonClearance's docs/specs/2026-05-26-help-faq-panel-design.md.
    helpSectionsCollapsed = true,
    -- v2.72.0 settings profiles: WHICH settings profile this character
    -- uses. The profile BODIES live at the top-level
    -- WoWClearanceDB.settingsProfiles[name] (account-wide, so alts can
    -- share one by pointing at it); only the pointer is per-character.
    activeSettingsProfile = true,
}

-- v2.72.0 settings profiles: the selling-behaviour fields that live in a
-- named settings profile instead of the account-wide top level. The DB
-- proxy routes reads/writes of these through the character's active
-- profile (see WC_DBBuildProxy), so every existing `DB.<field>` call
-- site - panels, the decision core, the vendor cycle - works unchanged.
-- Scope decision (Serv, 2026-07-30): selling behaviour + vendor-visit
-- actions + pacing ONLY. Master enable, looting behaviour,
-- visual preferences, locale, lists, and stats stay account-wide or
-- per-character exactly as before.
-- Top-level copies of these fields freeze at migration time as the
-- downgrade safety net + the seed for the "Default" profile (the same
-- model PER_CHAR_FIELDS established in v2.34).
-- Hangs off WC_compCache (not a main-chunk local): the Events main
-- chunk is AT the 200-locals cap.
WC_compCache.settingsProfileFields = {
    -- merchant / rules
    qualityRules = true,
    -- deletion + auto-mark
    enableDeletion = true,
    markGreyForDeletion = true,
    announceAutoDelete = true,
    announceAutoDeleteQualities = true,
    autoMarkResilience = true,
    autoMarkKnownUnsellableRecipes = true,
    automarkProtectHighILvl = true,
    -- protections
    protectUnlearnedTomes = true,
    protectAllTomes = true,
    protectUncollectedAppearances = true,
    protectTradeableLoot = true,
    autoAddEquipped = true,
    autoProtectUpgrades = true,
    autoProtectEquipmentSets = true,
    -- vendor selling master + grey auto-sell
    sellAtVendor = true,
    sellGreys = true,
    -- recipes
    sellKnownRecipes = true,
    sellKnownRecipeQualities = true,
    sellKnownRecipeBindFilter = true,
    -- vendor-visit actions + pacing
    repairGear = true,
    repairUseGuildBank = true,
    vendorInterval = true,
    maxItemsPerRun = true,
    fastMode = true,
    turboMode = true,
}

-- "First Surname-Realm". Forever has character surnames and first names are
-- not unique, so the first name alone let two characters share one
-- partition (Keep / Sell / Delete lists, enabled, Sold History).
local function WC_DBCharKey()
    return (GetUnitName("player", true) or "Unknown") .. "-" .. (GetRealmName() or "Unknown")
end

-- The pre-surname key, "First-Realm", for the one-time copy-forward below.
local function WC_DBLegacyCharKey()
    return (UnitName("player") or "Unknown") .. "-" .. (GetRealmName() or "Unknown")
end

local function WC_DBDeepCopy(t)
    if type(t) ~= "table" then
        return t
    end
    local c = {}
    for k, v in pairs(t) do
        c[k] = WC_DBDeepCopy(v)
    end
    return c
end

local function WC_DBBuildProxy(charNamespace)
    local SPF = WC_compCache.settingsProfileFields
    -- Resolve this character's settings-profile body. Falls back to
    -- "Default" when the pointer names a profile that no longer exists
    -- (safety net; the delete path also repoints stale pointers), and
    -- to nil pre-migration so the read drops through to the top-level
    -- legacy values.
    local function activeSettings()
        local profiles = rawget(WoWClearanceDB, "settingsProfiles")
        if not profiles then
            return nil
        end
        return profiles[charNamespace.activeSettingsProfile or "Default"] or profiles.Default
    end
    return setmetatable({}, {
        __index = function(_, k)
            if PER_CHAR_FIELDS[k] then
                return charNamespace[k]
            end
            if SPF[k] then
                local p = activeSettings()
                if p then
                    local v = p[k]
                    if v ~= nil then
                        return v
                    end
                    -- v2.75.0 (fresh-audit fix): the active profile exists but
                    -- lacks this field (a settings-profile field added AFTER the
                    -- profile was created - the "future-field trap"). Fall
                    -- through to the frozen top-level legacy value instead of
                    -- returning nil, matching the pre-migration fallback the
                    -- design intended. EnsureDB then writes the nil-default back
                    -- into the profile through __newindex on its next pass.
                end
            end
            return rawget(WoWClearanceDB, k)
        end,
        __newindex = function(_, k, v)
            if PER_CHAR_FIELDS[k] then
                charNamespace[k] = v
                return
            end
            if SPF[k] then
                local p = activeSettings()
                if p then
                    p[k] = v
                    return
                end
            end
            rawset(WoWClearanceDB, k, v)
        end,
    })
end

local DB
-- Account-wide SavedVariable. Holds a single `whitelist` table that unions with
-- the per-character whitelist at sell time. Bootstrapped by EnsureAccountDB().
local ADB

-- Resolves list names (used by CreateListUI) to the underlying table. Extra
-- scopes (e.g. account whitelist) register themselves here so CreateListUI can
-- render them without knowing about the scope.
local WC_ExtraListTables = {}

local function WC_GetListTable(name)
    local extra = WC_ExtraListTables[name]
    if extra ~= nil then
        return extra
    end
    return DB and DB[name]
end
NS.GetListTable = WC_GetListTable

local function EnsureAccountDB()
    if WoWClearanceAccountDB == nil then
        WoWClearanceAccountDB = {}
    end
    ADB = WoWClearanceAccountDB
    -- Mirror the live ADB binding onto the namespace so split files (post-
    -- Stage 3) can read NS.ADB inline at call time. Same table; both
    -- names alias the same memory. See docs/CODE_REVIEW.md item 4.
    NS.ADB = ADB
    if type(ADB.whitelist) ~= "table" then
        ADB.whitelist = {}
    end
    WC_ExtraListTables["accountWhitelist"] = ADB.whitelist
    -- Account-wide per-item override list. Marking an itemID releases the
    -- protection safety nets so future drops auto-sell via the normal
    -- quality rules and become eligible for Process Bags. Account-wide
    -- because whether to keep or sell a protected item is an item-property
    -- decision, not a per-character one.
    if type(ADB.allowedItems) ~= "table" then
        ADB.allowedItems = {}
    end
    -- v2.46.x: Loot Log per-item hide set (itemID -> true). A display-only
    -- filter so high-volume low-interest drops (e.g. cloth) can be hidden so
    -- they stop skewing the share percentages; hidden items are excluded from
    -- both the list AND the totals so remaining shares rebase. Account-wide
    -- because it's a display preference, not character data. Cleared by the
    -- Loot Log's "Unhide All" button.
    if type(ADB.lootLogHidden) ~= "table" then
        ADB.lootLogHidden = {}
    end
    -- Loot Log "History" view: one entry per pickup, ring-capped. Shape and
    -- writer live in WoWClearance_LootHistory.lua.
    if type(ADB.lootHistory) ~= "table" then
        ADB.lootHistory = { v = 2, writes = 0, e = {}, names = {} }
    end
    -- v2.38.1: account-wide stats ledger. Every per-character stat write
    -- mirrors into ADB.accountStats so the Stats panel's Account view
    -- aggregates totals across all characters. Counts forward from
    -- v2.38.1 install (no backfill from existing DB.* fields). The
    -- panel surfaces `startedAt` in a one-liner so the user understands
    -- the account ledger may have started after their per-character
    -- history.
    if type(ADB.accountStats) ~= "table" then
        ADB.accountStats = {}
    end
    local AS = ADB.accountStats
    if type(AS.totalCopper) ~= "number" then
        AS.totalCopper = 0
    end
    if type(AS.totalItemsSold) ~= "number" then
        AS.totalItemsSold = 0
    end
    if type(AS.totalItemsDeleted) ~= "number" then
        AS.totalItemsDeleted = 0
    end
    if type(AS.totalRepairs) ~= "number" then
        AS.totalRepairs = 0
    end
    if type(AS.totalRepairCopper) ~= "number" then
        AS.totalRepairCopper = 0
    end
    -- v0.7.0: coin picked up from loot windows, and per-day totals keyed
    -- "YYYY-MM-DD" (see WC_BumpDay). One small row per day played.
    if type(AS.totalLootCopper) ~= "number" then
        AS.totalLootCopper = 0
    end
    if type(AS.daily) ~= "table" then
        AS.daily = {}
    end
    if type(AS.soldItemCounts) ~= "table" then
        AS.soldItemCounts = {}
    end
    if type(AS.deletedItemCounts) ~= "table" then
        AS.deletedItemCounts = {}
    end
    if type(AS.soldItemsByQuality) ~= "table" then
        AS.soldItemsByQuality = {}
    end
    if type(AS.soldCopperByQuality) ~= "table" then
        AS.soldCopperByQuality = {}
    end
    if type(AS.deletedItemsByQuality) ~= "table" then
        AS.deletedItemsByQuality = {}
    end
    if type(AS.processCastCounts) ~= "table" then
        AS.processCastCounts = {}
    end
    if type(AS.copperByZone) ~= "table" then
        AS.copperByZone = {}
    end
    -- v2.59.5 (Serv report): scrub city-zone entries from the account-
    -- wide bucket.
    -- v2.59.10 (bug-hunt): removed the one-shot marker gate, same
    -- rationale as the DB scrub above - self-heal a downgrade -> upgrade
    -- cycle that would leave the marker true while re-poisoning the
    -- account bucket via the intermediate version.
    for zone in pairs(WC_CITY_ZONES) do
        AS.copperByZone[zone] = nil
    end
    ADB.cityZonesScrubbed = nil -- old one-shot marker; nothing reads it
    -- Session loot tracker, account-wide running total. Keyed by itemID ->
    -- total quantity looted across all characters since install. Aggregate
    -- only (one integer per distinct item), so it stays bounded. The live
    -- session view is held in memory (NS.lootSession); this is the
    -- persisted side the loot window's Account scope reads.
    if type(AS.lootedItemCounts) ~= "table" then
        AS.lootedItemCounts = {}
    end
    if type(AS.bestGPH) ~= "number" then
        AS.bestGPH = 0
    end
    if type(AS.bestGPHAt) ~= "number" then
        AS.bestGPHAt = 0
    end
    if type(AS.bestGPHZone) ~= "string" then
        AS.bestGPHZone = ""
    end
    if type(AS.bestGPHChar) ~= "string" then
        AS.bestGPHChar = ""
    end
    if type(AS.startedAt) ~= "number" then
        AS.startedAt = time()
    end
    -- One-shot migration from the v2.26.0 field `allowedProcs`.
    -- rawget avoids the EnsureDefaults pattern's auto-create when
    -- the legacy field has already been migrated away.
    local legacy = rawget(ADB, "allowedProcs")
    if type(legacy) == "table" then
        for k, v in pairs(legacy) do
            ADB.allowedItems[k] = v
        end
        ADB.allowedProcs = nil
    end
end

local function EnsureDB()
    -- Fresh-install detection, captured before any field default below
    -- creates the table. Drives the "default autoAddEquipped ON for new
    -- installs only" rule.
    local isFreshInstall = (WoWClearanceDB == nil)
    if WoWClearanceDB == nil then
        WoWClearanceDB = {}
    end
    -- Version-update nudge (opt-out, default ON). Account-level: a single
    -- toggle that also gates all addon-message comms in this release.
    if WoWClearanceDB.versionAlerts == nil then
        WoWClearanceDB.versionAlerts = true
    end
    -- Guild farming/stats sharing (opt-in, default OFF). Account-level.
    if WoWClearanceDB.shareGuildData == nil then
        WoWClearanceDB.shareGuildData = false
    end
    -- Show player name with shared data (opt-in, default OFF). Account-level.
    if WoWClearanceDB.shareGuildName == nil then
        WoWClearanceDB.shareGuildName = false
    end
    -- shareServerData feeds the anonymous "Stats - Server" odometer AND is what
    -- lets you see it (it shows no names, so there is no name-sharing toggle).
    -- Turning it on is also what joins the realm chat channel; a channel slot
    -- is never used otherwise.
    --
    -- WC-TRAP: this MUST stay default OFF. The v2.59.1 default-ON seed and its
    -- shareServerDataDefaultBumped migration marker are deliberately GONE. Do
    -- not restore either as a "reasonable default"; both are listed here so a
    -- reader knows their absence is a decision rather than an oversight.
    --
    -- Two reasons, and the second is the one that is easy to miss.
    --
    -- 1. Forever is a live Blizzard realm, not a private server. Joining a
    --    chat channel and broadcasting on login is a decision that belongs to
    --    the player, not to a shipped default. See PORT_STATUS work item 7.
    -- 2. On client build 69913 the opt-out COULD NOT persist, so a
    --    default-ON seed was not merely a default, it was a re-decision taken
    --    on the player's behalf every launch: SavedVariables were written on
    --    exit and never read back (hard release gate in PORT_STATUS), so
    --    shareServerData read nil at every launch and the fresh-install
    --    branch fired again. Saving works from build 70245, but if a later
    --    build regresses, this reason comes back with it.
    --
    -- Seeding OFF is safe under that same breakage, which is the whole point:
    -- an erased opt-IN costs a feature until the player re-enables it, where
    -- an erased opt-OUT costs them a broadcast they had declined. Fail in the
    -- direction that stays quiet.
    if WoWClearanceDB.shareServerData == nil then
        WoWClearanceDB.shareServerData = false
    end
    -- v0.6.0 one-shot cleanup. Saves written by the pre-port default-ON code
    -- carry shareServerDataDefaultBumped = true next to a shareServerData =
    -- true the player never chose. Now that saved data persists (build
    -- 70245), that forced value would stick, and opening the Stats - Server
    -- panel would join the realm channel on it. The marker only ever came
    -- from that forced path, so its presence means "not the player's
    -- choice": turn sharing off and drop the marker. Runs once, because the
    -- marker is gone afterwards; a later opt-in from the panel is kept.
    if WoWClearanceDB.shareServerDataDefaultBumped ~= nil then
        WoWClearanceDB.shareServerData = false
        WoWClearanceDB.shareServerDataDefaultBumped = nil
    end
    -- The French / German translations and /wc locale were dropped: this
    -- version is English only. Clear the old override.
    WoWClearanceDB.localeOverride = nil

    -- Per-character partition (v2.34.x). See the PER_CHAR_FIELDS block at
    -- the top of the file for the rationale. Top-level fields remain as
    -- the legacy snapshot (downgrade safety + migration seed); each
    -- character's live data lives at WoWClearanceDB.chars[charKey].
    if WoWClearanceDB.chars == nil then
        WoWClearanceDB.chars = {}
    end
    local charKey = WC_DBCharKey()
    -- Guard: at a very early ADDON_LOADED, UnitName("player") /
    -- GetRealmName() can still be nil, making the key "Unknown-...". Never
    -- persist a partition under that key (it would be an orphan namespace
    -- in SavedVariables, one per fresh account); bind a transient in-memory
    -- namespace instead. The PLAYER_LOGIN EnsureDB re-run resolves the real
    -- key and rebinds to the persisted partition, so nothing written before
    -- login can land on an orphan.
    local charNSIsTransient = charKey:find("^Unknown%-") ~= nil
    if charNSIsTransient then
        WC_compCache.unknownCharNS = WC_compCache.unknownCharNS or {}
    elseif
        not WoWClearanceDB.chars[charKey]
        and WoWClearanceDB.chars[WC_DBLegacyCharKey()]
        and not (WoWClearanceDB.surnameCopied and WoWClearanceDB.surnameCopied[WC_DBLegacyCharKey()])
    then
        -- Surname key migration: COPY the old first-name partition (never
        -- move it), ONCE. Marking it copied stops a character created later
        -- with the same first name from inheriting another character's Sell
        -- and Delete Lists. The old partition stays as a backup.
        local legacyKey = WC_DBLegacyCharKey()
        WoWClearanceDB.chars[charKey] = WC_DBDeepCopy(WoWClearanceDB.chars[legacyKey])
        WoWClearanceDB.surnameCopied = WoWClearanceDB.surnameCopied or {}
        WoWClearanceDB.surnameCopied[legacyKey] = charKey
        NS.PrintNice(L["Your lists were copied to this character's new save slot."])
    elseif not WoWClearanceDB.chars[charKey] then
        local charNS = {}
        for k in pairs(PER_CHAR_FIELDS) do
            if WoWClearanceDB[k] ~= nil then
                charNS[k] = WC_DBDeepCopy(WoWClearanceDB[k])
            end
        end
        WoWClearanceDB.chars[charKey] = charNS
    end

    -- v2.34.x cleanup pass for the cross-character auto-Keep leak.
    -- ----------------------------------------------------------------
    -- The initial per-character migration above deep-copies the entire
    -- legacy snapshot into every newly-migrated character's namespace.
    -- That preserves manual user adds (Sell / Keep / Delete lists)
    -- correctly, but it also carries forward AUTO-added entries that
    -- were stamped by some OTHER character during the pre-migration
    -- account-wide period: equipped gear, upgrade detections, equipment-
    -- set items. Symptom in-game: the main character picks up an item
    -- only the alt has ever worn and the tooltip still says
    -- "Keep (equipped)" because the legacy auto-tag is on this
    -- character's namespace too.
    --
    -- Fix: drop blacklist + blacklistAuto entries that appear in the
    -- LEGACY snapshot's blacklistAuto map (top-level, frozen). Those
    -- are by definition auto-added pre-migration. Manual blacklist
    -- entries (no blacklistAuto tag) are preserved.
    --
    -- The live auto-protect paths (PLAYER_EQUIPMENT_CHANGED ->
    -- protectEquipSlot, checkBagsForUpgrades, EQUIPMENT_SETS_CHANGED)
    -- will repopulate this character's tags authentically under their
    -- own login. To make that immediate for currently-equipped gear,
    -- arm pendingFreshInstallSync so PLAYER_LOGIN runs syncEquipped
    -- after a 2 s settle.
    --
    -- Gate via `_migratedV2` so the cleanup runs exactly once per
    -- character; otherwise a subsequent /reload would re-drop entries
    -- the live paths just re-added.
    local charNS = charNSIsTransient and WC_compCache.unknownCharNS or WoWClearanceDB.chars[charKey]
    if not charNS._migratedV2 then
        local legacyAuto = WoWClearanceDB.blacklistAuto
        if type(legacyAuto) == "table" then
            if type(charNS.blacklist) == "table" then
                for id in pairs(legacyAuto) do
                    charNS.blacklist[id] = nil
                end
            end
            if type(charNS.blacklistAuto) == "table" then
                for id in pairs(legacyAuto) do
                    charNS.blacklistAuto[id] = nil
                end
            end
        end
        charNS._migratedV2 = true
        -- First sight of this character: sync its worn gear at login if
        -- "auto-add equipped" is on. The setting lives in the settings
        -- profile, which only the proxy can read, so the check itself is
        -- below, after the proxy and the default exist. (It used to read
        -- the raw top level here, which nothing writes any more, so alts
        -- never got the sync.)
        -- Not for the transient pre-login namespace: it is new every
        -- session, so it would re-run the sync for existing characters.
        if not charNSIsTransient then
            WC_compCache.newCharNeedsEquipSync = true
        end
    end

    -- v2.75.0 (fresh-audit fix): `enabled` became a PER_CHAR_FIELDS field. A
    -- character namespace created before this change has no `enabled` key, so
    -- the proxy would read nil and EnsureDB would default it to true - silently
    -- re-enabling a player who had WoWClearance disabled account-wide. Seed it
    -- once from the frozen top-level (account-wide) value so that state carries
    -- across per character. Newly-migrated / fresh characters were already
    -- seeded by the PER_CHAR_FIELDS copy loop above; this only fills the gap for
    -- namespaces that predate the field.
    if charNS.enabled == nil and type(WoWClearanceDB.enabled) == "boolean" then
        charNS.enabled = WoWClearanceDB.enabled
    end

    -- v2.72.0 settings-profile migration. Runs BEFORE the proxy build so
    -- it reads the RAW top-level values. One-shot seed: the "Default"
    -- profile is a deep copy of the current account-wide selling
    -- settings, and every character starts pointed at it - zero
    -- behaviour change on upgrade. The top-level copies freeze from here
    -- on (downgrade safety net, same model as the v2.34 partition); all
    -- live reads/writes route through the proxy into the active profile.
    -- Fresh installs seed an empty Default that the nil-default blocks
    -- below fill through the proxy.
    if type(WoWClearanceDB.settingsProfiles) ~= "table" then
        WoWClearanceDB.settingsProfiles = {}
    end
    if type(WoWClearanceDB.settingsProfiles.Default) ~= "table" then
        local def = {}
        for f in pairs(WC_compCache.settingsProfileFields) do
            if WoWClearanceDB[f] ~= nil then
                def[f] = WC_DBDeepCopy(WoWClearanceDB[f])
            end
        end
        WoWClearanceDB.settingsProfiles.Default = def
    end
    if type(charNS.activeSettingsProfile) ~= "string" then
        charNS.activeSettingsProfile = "Default"
    end

    -- DB is a metatable proxy so existing call sites (`DB.foo`) keep
    -- working unchanged. Per-character fields route to chars[charKey];
    -- settings-profile fields route to the character's active settings
    -- profile; everything else stays on the top-level (account-wide) table.
    DB = WC_DBBuildProxy(charNS)
    -- Mirror the live DB binding onto the namespace so split files can
    -- read NS.DB inline at call time. Same proxy; both names alias it.
    -- EnsureAccountDB() below does the same for ADB. See
    -- docs/CODE_REVIEW.md item 4.
    NS.DB = DB
    EnsureAccountDB()

    if type(DB.lootedItemCounts) ~= "table" then
        DB.lootedItemCounts = {}
    end
    if type(DB.deleteList) ~= "table" then
        DB.deleteList = {}
    end
    if type(DB.allowedChars) ~= "table" then
        DB.allowedChars = {}
    end

    if type(DB.totalCopper) ~= "number" then
        DB.totalCopper = 0
    end

    if type(DB.totalItemsSold) ~= "number" then
        DB.totalItemsSold = 0
    end
    if type(DB.totalItemsDeleted) ~= "number" then
        DB.totalItemsDeleted = 0
    end
    if type(DB.totalRepairs) ~= "number" then
        DB.totalRepairs = 0
    end
    if type(DB.totalRepairCopper) ~= "number" then
        DB.totalRepairCopper = 0
    end
    if type(DB.totalLootCopper) ~= "number" then
        DB.totalLootCopper = 0
    end

    if type(DB.soldItemCounts) ~= "table" then
        DB.soldItemCounts = {}
    end
    if type(DB.deletedItemCounts) ~= "table" then
        DB.deletedItemCounts = {}
    end

    -- v2.37.0: per-quality breakdown of lifetime sells. Keyed by item
    -- rarity (0=Poor through 7=Heirloom). Captured at the sell-success
    -- site in both the manual (UseContainerItem hook) and worker
    -- (auto-cycle) paths so the Stats panel can render a "Sold by
    -- Quality" rollup. Counts are stack-event counts (matching
    -- DB.totalItemsSold / DB.soldItemCounts semantics for the
    -- respective path), copper is summed per-event.
    if type(DB.soldItemsByQuality) ~= "table" then
        DB.soldItemsByQuality = {}
    end
    if type(DB.soldCopperByQuality) ~= "table" then
        DB.soldCopperByQuality = {}
    end
    -- v2.37.x: per-quality breakdown of lifetime deletions. Mirrors
    -- soldItemsByQuality but keyed by item rarity. Stamped at the
    -- worker delete-action site (Delete-List auto-deletions). No
    -- copper field - deletion produces no money.
    if type(DB.deletedItemsByQuality) ~= "table" then
        DB.deletedItemsByQuality = {}
    end
    -- v2.37.0: Process Bags lifetime cast counters. Keyed by the
    -- localised spell name UNIT_SPELLCAST_SUCCEEDED emits ("Disenchant",
    -- "Milling", "Prospecting", "Pick Lock"). Counts EVERY successful
    -- cast of these spells - both Process Bags-driven and manual
    -- casts. "Opening" is excluded (fires on every right-click box
    -- open, which would over-attribute).
    if type(DB.processCastCounts) ~= "table" then
        DB.processCastCounts = {}
    end
    -- v2.37.0: lifetime gold earned per zone. Keyed by the localised
    -- GetRealZoneText string at sell time (or "Unknown" when the zone
    -- text isn't available, e.g. mid-load). Both the manual sell hook
    -- and the worker-cycle FinishRun add to this so the Stats panel
    -- can render a "Top Zones" rollup matching the wallet totals.
    if type(DB.copperByZone) ~= "table" then
        DB.copperByZone = {}
    end
    -- v2.59.5 (Serv report): scrub city-zone entries from the per-
    -- character bucket. Mailbox-vendoring in cities had polluted the
    -- Top Zones list.
    -- v2.59.10 (bug-hunt): removed the one-shot marker gate. Downgrade
    -- -> upgrade cycles could leave the marker true while re-poisoning
    -- copperByZone via the intermediate version's un-filtered
    -- attribution. Running the scrub every EnsureDB is 10 table lookups
    -- and any-city-key removal - trivial overhead - and self-heals the
    -- edge case.
    for zone in pairs(WC_CITY_ZONES) do
        DB.copperByZone[zone] = nil
    end
    DB.cityZonesScrubbed = nil -- old one-shot marker; nothing reads it

    if type(DB.repairGear) ~= "boolean" then
        DB.repairGear = true
    end
    -- v2.9.0: opt-in guild-bank repair. Off by default so existing users
    -- keep paying out of personal funds; turning it on routes through
    -- RepairAllItems(true) when the player is in a guild AND has bank-funded
    -- repair permission AND the bank holds at least the required amount.
    if type(DB.repairUseGuildBank) ~= "boolean" then
        DB.repairUseGuildBank = false
    end

    if type(DB.enableDeletion) ~= "boolean" then
        DB.enableDeletion = true
    end
    -- v0.6.0: the two automatic delete settings are gone (the game refuses
    -- automatic deletes; see the WC-TRAP on executeBagSlotDelete). Clear
    -- them so old saves carry no dead switch.
    DB.autoDeleteOnPickup = nil
    DB.autoDeleteGreyOnLoot = nil
    -- Delete Next also removes grey items. Destructive, so default OFF.
    if type(DB.markGreyForDeletion) ~= "boolean" then
        DB.markGreyForDeletion = false
    end
    -- v2.44.0: auto-mark PvP gear with Resilience for deletion. Adds
    -- detected items to DB.deleteList; Delete Next removes them. Default
    -- OFF - the destination is the user's Delete List, which they
    -- might have curated for other reasons, and an unsolicited
    -- auto-mark could surprise them. Asked for by Murlocked: PvP
    -- gear on PE has sellPrice = 0 and clutters bags after farming.
    if type(DB.autoMarkResilience) ~= "boolean" then
        DB.autoMarkResilience = false
    end
    -- v2.44.4: announce delete actions in chat. Covers BOTH the
    -- "Deleted X" line from Delete Next AND
    -- the "Marked for deletion (Resilience, unsellable)" line from
    -- the resilience auto-mark sweep - same category of "WC just
    -- touched something" notification. Default ON (the player should
    -- see destructive actions); ayres asked for the off switch.
    if type(DB.announceAutoDelete) ~= "boolean" then
        DB.announceAutoDelete = true
    end
    -- v2.60.0: per-rarity filter for the auto-delete / auto-mark chat
    -- announcements. announceAutoDelete stays as the master (off silences
    -- everything); when on, each rarity's tickbox decides whether that
    -- rarity's deletion prints. Defaults all true so existing users see
    -- no behaviour change (matches the pre-v2.60.0 "all-or-nothing"
    -- toggle). Poor / Common / Uncommon / Rare / Epic keys only;
    -- higher rarities (Legendary+) are extremely rare drops that don't
    -- typically hit the Delete List.
    if type(DB.announceAutoDeleteQualities) ~= "table" then
        DB.announceAutoDeleteQualities = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true }
    else
        for q = 0, 4 do
            if type(DB.announceAutoDeleteQualities[q]) ~= "boolean" then
                DB.announceAutoDeleteQualities[q] = true
            end
        end
    end
    -- v2.49.2: warn once at PLAYER_LOGIN when a third-party auto-delete
    -- addon is running alongside WC. Opt-out; default on so the conflict
    -- is surfaced immediately without the player having to opt in first.
    if type(DB.warnConflictingAddons) ~= "boolean" then
        DB.warnConflictingAddons = true
    end
    if type(DB.vendorInterval) ~= "number" then
        DB.vendorInterval = 0.1
    end
    if DB.vendorInterval < 0.05 then
        DB.vendorInterval = 0.1
    end
    if type(DB.maxItemsPerRun) ~= "number" then
        DB.maxItemsPerRun = 80
    end
    if type(DB.fastMode) ~= "boolean" then
        DB.fastMode = false
    end
    -- Vendor selling master switch and the grey auto-sell. Both default ON
    -- (the behaviour before these toggles existed).
    if type(DB.sellAtVendor) ~= "boolean" then
        DB.sellAtVendor = true
    end
    if type(DB.sellGreys) ~= "boolean" then
        DB.sellGreys = true
    end
    -- v2.37.7: batch-vendor opt-in. When on, the worker pops multiple
    -- sells per fire instead of one, so a bag-clear finishes in a fraction
    -- of the time. Default OFF (existing setups unchanged on upgrade).
    -- Reported by a player on Discord ("2.1") that the existing fastest
    -- setting still felt slow when trying to dodge environment hazards
    -- while bag-clearing; this is the follow-up pacing pass.
    if type(DB.turboMode) ~= "boolean" then
        DB.turboMode = false
    end
    if type(DB.autoOpenContainers) ~= "boolean" then
        DB.autoOpenContainers = false
    end
    -- v2.60.0 (Serv follow-up): sub-toggle for the v2.57.2 iLvl safety
    -- net that skips auto-mark at or above WC_AUTOMARK_PROTECT_ILVL. That safety
    -- net was added to prevent a near-item-loss on brand-new high-value
    -- drops (Bizzaro's report), but for a player with
    -- a mature Keep List AND autoAddEquipped / autoProtectUpgrades /
    -- autoProtectEquipmentSets on, the iLvl gate over-protects old PvP
    -- gear the player deliberately wants trashed. Default TRUE
    -- (preserves the v2.57.2 behaviour); users can untick to allow
    -- auto-mark to catch high-iLvl items. Other safety nets (Keep List,
    -- Sell List, gear-set members, currently equipped, quest items)
    -- stay unconditional.
    if type(DB.automarkProtectHighILvl) ~= "boolean" then
        DB.automarkProtectHighILvl = true
    end
    -- v2.60.0 (Serv report, Recipe: Haunted Herring / Recipe: Last Week's
    -- Mammoth): auto-mark learned profession recipes with sellPrice 0 for
    -- deletion. "Sell Known Recipes" only fires when the vendor accepts
    -- the item; a sellPrice 0 recipe stays in bags forever even when the
    -- player knows the recipe. This toggle catches those. Paired with
    -- sellKnownRecipes (that toggle must be on for this scan to run at
    -- all) so the mental model is a single "get rid of learned recipes"
    -- opt-in with two disposition paths (vendor for sellable, delete for
    -- unsellable). Default OFF (opt-in, leads to deletion).
    if type(DB.autoMarkKnownUnsellableRecipes) ~= "boolean" then
        DB.autoMarkKnownUnsellableRecipes = false
    end
    -- Tome protection. Tome / recipe learn-state is per-character, so
    -- different alts know different tomes / recipes and may want
    -- different protection behaviour. The per-
    -- character flag matches that - one alt can vendor freely while
    -- another hoards spares for the auction house. Two independent
    -- toggles:
    --   * protectUnlearnedTomes - items that teach a spell the
    --     character does NOT yet know are HARD-vetoed by WC_IsSellable
    --     even when on the Sell List. The user must explicitly mark
    --     Allow Sell (Alt+Right-Click -> Allow Sell, ADB.allowedItems)
    --     to lift the protection. Mirrors the item protection
    --     design rather than a narrowing:
    --     tomes are high-value enough that "two-key" confirmation
    --     (Sell List entry + Allow Sell) is required before vendoring.
    --   * protectAllTomes - same hard-veto semantic; protects every
    --     spell-teaching item regardless of whether the character has
    --     learned it.
    if type(DB.protectUnlearnedTomes) ~= "boolean" then
        DB.protectUnlearnedTomes = true
    end
    if type(DB.protectAllTomes) ~= "boolean" then
        DB.protectAllTomes = false
    end
    -- v0.6.0 Forever protections, default ON (they only stop the auto
    -- rules; Sell List and Allow Sell still sell). See Decision.sell.
    if type(DB.protectUncollectedAppearances) ~= "boolean" then
        DB.protectUncollectedAppearances = true
    end
    if type(DB.protectTradeableLoot) ~= "boolean" then
        DB.protectTradeableLoot = true
    end
    -- Sell Known Recipes. Opt-in auto-sell of profession recipes the
    -- character has ALREADY learned (tooltip shows "Already known"). The
    -- toggle is account-wide like the protect* toggles above, but the
    -- learn-state is read per-character from the live tooltip at sell
    -- time (playerKnowsTomeSpell), so each alt only sells the recipes IT
    -- knows. Per-quality gate so a player can sell known white/green
    -- recipes while keeping known blue/purple ones (e.g. for the auction
    -- house). Default OFF (every auto-action is opt-in). "Protect all
    -- tomes" wins outright and disables this signal.
    if type(DB.sellKnownRecipes) ~= "boolean" then
        DB.sellKnownRecipes = false
    end
    if type(DB.sellKnownRecipeQualities) ~= "table" then
        DB.sellKnownRecipeQualities = { [1] = true, [2] = true, [3] = true, [4] = true }
    else
        for q = 1, 4 do
            if type(DB.sellKnownRecipeQualities[q]) ~= "boolean" then
                DB.sellKnownRecipeQualities[q] = true
            end
        end
    end
    -- v2.47.1: per-quality bind-type filter for Sell Known Recipes.
    -- Mirrors the quality-rule bindFilter shape from v2.10.0 so the
    -- "BoE only" / "BoP only" semantics are consistent across the
    -- two sell-rule surfaces. Default "any" everywhere keeps the
    -- v2.46.0 behaviour for existing users (additive migration).
    if type(DB.sellKnownRecipeBindFilter) ~= "table" then
        DB.sellKnownRecipeBindFilter = { [1] = "any", [2] = "any", [3] = "any", [4] = "any" }
    else
        for q = 1, 4 do
            local v = DB.sellKnownRecipeBindFilter[q]
            if v ~= "any" and v ~= "boe" and v ~= "bop" then
                DB.sellKnownRecipeBindFilter[q] = "any"
            end
        end
    end
    -- v2.22.0: Process Bags panel. Lets the player batch-cast their
    -- profession spells (Disenchant / Mill / Prospect) on eligible
    -- bag items via a secure-button macro. Soulbound DE is opt-in
    -- (default OFF) because it's irreversible; DE quality cap
    -- defaults to Epic (max permissive). Ignored items are
    -- per-character (DB, not ADB) since profession alts vary.
    if type(DB.processIncludeSoulbound) ~= "boolean" then
        DB.processIncludeSoulbound = false
    end
    if type(DB.processMaxDEQuality) ~= "number" or DB.processMaxDEQuality < 2 or DB.processMaxDEQuality > 4 then
        DB.processMaxDEQuality = 4
    end
    if type(DB.processIgnored) ~= "table" then
        DB.processIgnored = {}
    end
    -- v2.25.0: Lockpick mode in Process Bags. Adds a fourth mode (DE /
    -- Mill / Prospect / Lockpick) for rogues, listing locked containers
    -- in bags and driving Pick Lock via the existing SecureActionButton
    -- workflow. Inert on non-rogues (the Pick Lock spell is not known).
    -- Enabled by default since the entry point is the panel itself.
    if type(DB.lockpickEnabled) ~= "boolean" then
        DB.lockpickEnabled = true
    end
    -- v2.62.0: per-skill Process Bags toggles. A { mode = bool } table
    -- (Disenchant / Mill / Prospect / Lockpick / Convert); a missing entry
    -- means enabled, so reads use `DB.processEnabledModes[mode] ~= false`.
    -- Default empty (all skills on). Seed Lockpick once from the old
    -- DB.lockpickEnabled flag so upgraders keep their choice; lockpickEnabled
    -- is left in place (unread by new code) for downgrade safety.
    if type(DB.processEnabledModes) ~= "table" then
        DB.processEnabledModes = {}
    end
    if DB.processEnabledModes.Lockpick == nil then
        DB.processEnabledModes.Lockpick = (DB.lockpickEnabled ~= false)
    end
    -- Optional combat-exit chat hint: "N lockbox(es) available. Click
    -- Process Next to open." Default off (one extra line on every
    -- combat exit gets noisy for opted-in users with many lockboxes).
    if type(DB.lockpickNotifyOnCombatExit) ~= "boolean" then
        DB.lockpickNotifyOnCombatExit = false
    end
    -- v2.25.0: per-mode collapsed state for the Process Bags panel.
    -- Each key (Disenchant / Mill / Prospect / Lockpick) maps to true
    -- when the player has collapsed that section. Persisted so the
    -- preference survives /reload and login. Default empty (all
    -- expanded). Cursor logic in rearmProcessButton skips entries
    -- whose mode is in this set.
    if type(DB.processCollapsedModes) ~= "table" then
        DB.processCollapsedModes = {}
    end
    -- v2.16.0: Fast Loot. When on AND Blizzard's auto-loot CVar is
    -- effectively enabled, WC_HandleLootReady queues every slot in the
    -- loot window for draining, so the loot frame flashes briefly or
    -- skips entirely. Pairs with the auto-loot cycle: faster per-kill
    -- looting = bag-full threshold trips sooner = vendor cycle turns
    -- over faster. Default off so existing users keep the standard
    -- loot-window behaviour and BoP-bind safety prompts. Pattern
    -- borrowed from FasterLoot (others/FasterLoot/FasterLoot.lua).
    --
    -- v2.21.0 retrofit: drain is now queue-based with a ~110 ms
    -- throttle per slot (was: tight loop over GetNumLootItems in one
    -- frame), reducing disconnect risk on busy private servers. The
    -- toggle, schema, and BoP-bind auto-confirm are unchanged from
    -- v2.16.0; only the internal draining is refactored.
    if type(DB.fastLoot) ~= "boolean" then
        DB.fastLoot = false
    end
    if type(DB.enabled) ~= "boolean" then
        DB.enabled = true
    end
    -- v2.30.x: decommission the per-character enable filter. The Enable
    -- toggle (DB.enabled) covers the per-character disable use case - and as
    -- of v2.75.0 it is genuinely per-character (a PER_CHAR_FIELDS field), so
    -- that claim now holds; the dedicated allowlist added little value and
    -- lived behind a UI panel that's been repurposed for Item Highlighting.
    -- Force the flag false on every load so existing users with the
    -- filter previously enabled don't end up locked out of the addon on
    -- characters not in their old DB.allowedChars set. DB.allowedChars
    -- itself stays in the SV (dormant, ignored) so a downgrade to a
    -- pre-v2.30.x version restores the user's list.
    -- WC-TRAP: dormant on purpose - do NOT remove this gate or the dormant
    -- DB.allowedChars field. Forcing it false guards a downgrade regression
    -- (the old per-character allowlist locking users out). See comment above.
    DB.enableOnlyListedChars = false

    if type(DB.inventoryWorthTotal) ~= "number" then
        DB.inventoryWorthTotal = 0
    end
    if type(DB.inventoryWorthCount) ~= "number" then
        DB.inventoryWorthCount = 0
    end
    if type(DB.whitelist) ~= "table" then
        DB.whitelist = {}
    end
    -- v2.10.0: parallel "source" map flagging which Blacklist (Keep) entries
    -- arrived via the auto-protect-equipped path versus a manual user add.
    -- Used by WC_AnnotateTooltip to surface "(auto-protected: equipped)" so
    -- users who expected an item to sell can see why it's being kept and
    -- follow the existing context-menu remove path to override. The
    -- blacklist check itself (IsInSet(DB.blacklist, ...)) only reads
    -- DB.blacklist; this map is purely diagnostic. Cleared in lockstep
    -- with DB.blacklist on every remove path so it can never carry a
    -- stale entry.
    if type(DB.blacklistAuto) ~= "table" then
        DB.blacklistAuto = {}
    end
    -- v2.10.0: master toggle for the auto-protect-equipped behaviour. When
    -- on, equipping an item auto-adds its ID to the per-character Blacklist
    -- (Keep) list and stamps DB.blacklistAuto. The auto-rules' blacklist
    -- veto then prevents that item from ever auto-selling. Default off so
    -- existing users see no behaviour change until they enable it from
    -- the Blacklist (Keep) panel.
    if type(DB.autoAddEquipped) ~= "boolean" then
        -- Fresh installs from v2.12.0+ default to ON so brand-new users
        -- get equipped-gear protection out of the box - matches common
        -- niche UX. Existing users (v2.10.0+ already have the field as a
        -- boolean and skip this branch; pre-v2.10.0 users hit this branch
        -- but with isFreshInstall = false) keep OFF so they don't see a
        -- silent behaviour change on upgrade.
        DB.autoAddEquipped = isFreshInstall
        -- v2.12.0: arm the first-run welcome message + setup popup.
        -- Persisted via DB._needsWelcome (not session-scoped) so a
        -- /reload between ADDON_LOADED and PLAYER_LOGIN doesn't lose it.
        -- Existing characters never reach this branch because their
        -- WoWClearanceDB existed before the session and isFreshInstall
        -- is false. The flag is consumed (set to nil) by the
        -- PLAYER_LOGIN handler after the welcome fires.
        if isFreshInstall then
            -- v2.38.0: fresh installs auto-open the Quickstart panel at
            -- PLAYER_LOGIN. Renamed from the v2.12.0 `_needsWelcome` flag
            -- (which fired a 2-button popup pointing at the Main panel)
            -- to make the intent explicit: open the wizard directly.
            DB._needsQuickstartOpen = true
        end
    end
    -- Defer the one-shot equipped-gear sync to PLAYER_LOGIN (handled at the
    -- bottom of the file): inventory APIs aren't reliably populated at
    -- ADDON_LOADED time. Armed for every character seen for the first
    -- time, which includes a fresh install (see newCharNeedsEquipSync).
    if WC_compCache.newCharNeedsEquipSync then
        WC_compCache.newCharNeedsEquipSync = nil
        if DB.autoAddEquipped then
            WC_compCache.pendingFreshInstallSync = true
        end
    end
    -- v2.38.0: one-shot migration from v2.37.x. If an upgrader had the
    -- old _needsWelcome flag set (installed but never logged in), promote
    -- it to _needsQuickstartOpen so the wizard fires on their first
    -- v2.38.0 login. Clear the stale field either way.
    if DB._needsWelcome ~= nil then
        if DB._needsWelcome == true then
            DB._needsQuickstartOpen = true
        end
        DB._needsWelcome = nil
    end
    -- v2.38.0: Quickstart bookkeeping. _activeQuickstartPreset stores
    -- the most-recently-applied preset key (or nil for tailored answers)
    -- so the panel can render the "Active" tag.
    if DB._activeQuickstartPreset ~= nil and type(DB._activeQuickstartPreset) ~= "string" then
        DB._activeQuickstartPreset = nil
    end
    -- Drop the never-read undo snapshot older versions saved on every Apply.
    DB._previousQuickstartSnapshot = nil
    if type(DB.autoProtectUpgrades) ~= "boolean" then
        DB.autoProtectUpgrades = false
    end
    -- v2.13.0 Equipment Manager protection. When ON, every item in any of
    -- the player's saved equipment sets (Blizzard's stock 3.3.5a Equipment
    -- Manager, NOT a third-party set addon) lands on the Keep list with
    -- origin tag "set". Solves the dual-spec / off-set problem: items
    -- assigned to your alternate gear set sit in bags between swaps and
    -- are unprotected by autoAddEquipped (which only catches currently-
    -- equipped slots). v2.57.2: default ON for new installs (Serv request -
    -- saved-set items should land on the Keep List for safety). Existing saves
    -- keep whatever the player already set; only a brand-new DB gets the ON
    -- default. Note the auto-delete gate protects set members regardless of
    -- this toggle - it only controls the visible Keep-List stamp + sell
    -- protection. EQUIPMENT_SETS_CHANGED drives live re-syncs when the user
    -- adds / modifies / deletes a set.
    if type(DB.autoProtectEquipmentSets) ~= "boolean" then
        DB.autoProtectEquipmentSets = true
    end
    if type(DB.whitelistMinQuality) ~= "number" then
        DB.whitelistMinQuality = 1
    end
    if DB.whitelistMinQuality > 3 then
        DB.whitelistMinQuality = 3
    end
    if type(DB.whitelistQualityEnabled) ~= "boolean" then
        DB.whitelistQualityEnabled = false
    end

    -- Per-rarity quality threshold rules (v2.4.0+). Replaces the old single
    -- whitelistMinQuality dropdown. Each rarity has its own enabled flag and
    -- optional max iLvl (0 = no cap). Default all off (opt-in). Existing
    -- users get a one-time migration: their old cumulative dropdown maps
    -- to per-rarity flags up to and including the chosen rarity, with no
    -- iLvl cap. The legacy keys stay for one release in case of rollback.
    if type(DB.qualityRules) ~= "table" then
        DB.qualityRules = {
            [1] = { enabled = false, maxILvl = 0 },
            [2] = { enabled = false, maxILvl = 0 },
            [3] = { enabled = false, maxILvl = 0 },
            [4] = { enabled = false, maxILvl = 0 },
        }
        if DB.whitelistQualityEnabled and type(DB.whitelistMinQuality) == "number" then
            -- Legacy migration: the old dropdown only ever offered up to
            -- quality 3. Clamp the migration source to 3 so we don't
            -- accidentally light up Epic on legacy upgraders. Existing
            -- post-v2.4 installs without the legacy keys go through the
            -- per-quality default (all off).
            local minQ = math.min(math.max(DB.whitelistMinQuality, 1), 3)
            for q = 1, minQ do
                DB.qualityRules[q].enabled = true
            end
        end
        -- v2.12.0: fresh installs default to dynamic-cap mode for whites
        -- and greens so brand-new players get useful auto-vendoring out
        -- of the box without risk - the cap follows their equipped iLvl
        -- in the same slot, so anything they're already wearing stays
        -- safe and any quest reward they haven't equipped yet would
        -- have to be a strict downgrade vs current gear to vendor.
        -- Blues and purples stay disabled - whitelist territory.
        if isFreshInstall then
            DB.qualityRules[1].enabled = true
            DB.qualityRules[1].useEquippedILvl = true
            DB.qualityRules[2].enabled = true
            DB.qualityRules[2].useEquippedILvl = true
        end
    end
    for q = 1, 4 do
        if type(DB.qualityRules[q]) ~= "table" then
            DB.qualityRules[q] = { enabled = false, maxILvl = 0 }
        end
        if type(DB.qualityRules[q].enabled) ~= "boolean" then
            DB.qualityRules[q].enabled = false
        end
        if type(DB.qualityRules[q].maxILvl) ~= "number" then
            DB.qualityRules[q].maxILvl = 0
        end
        if DB.qualityRules[q].maxILvl < 0 then
            DB.qualityRules[q].maxILvl = 0
        end
        if DB.qualityRules[q].maxILvl > 300 then
            DB.qualityRules[q].maxILvl = 300
        end
        -- v2.10.0: per-rarity bind-type filter. "any" preserves the v2.4.0+
        -- behaviour (rule applies regardless of bind type); "boe" / "bop"
        -- restrict matches to items the tooltip says bind on equip / on
        -- pickup. Items with no bind line at all (consumables, reagents)
        -- read as "any" from WC_compCache.getBindType and are protected
        -- when bindFilter is "boe" or "bop". Existing users see the "any"
        -- default; idempotent re-init matches the rest of EnsureDB.
        if type(DB.qualityRules[q].bindFilter) ~= "string" then
            DB.qualityRules[q].bindFilter = "any"
        end
        if
            DB.qualityRules[q].bindFilter ~= "any"
            and DB.qualityRules[q].bindFilter ~= "boe"
            and DB.qualityRules[q].bindFilter ~= "bop"
        then
            DB.qualityRules[q].bindFilter = "any"
        end
        -- v2.12.0: per-rarity dynamic-cap mode. When true, the maxILvl
        -- input is ignored at runtime and the cap is the equipped item's
        -- iLvl in the same slot (per-item lookup via
        -- WC_compCache.isDowngradeVsEquipped). Existing users default
        -- to false (fixed-cap mode preserved); fresh installs flip
        -- whites and greens to true via the table-init branch above.
        if type(DB.qualityRules[q].useEquippedILvl) ~= "boolean" then
            DB.qualityRules[q].useEquippedILvl = false
        end
    end
    if type(DB.minimapButtonAngle) ~= "number" then
        DB.minimapButtonAngle = NS.MINIMAP_DEFAULT_ANGLE or 190
    end
    -- v2.44.7: minimap button visibility toggle. Default ON (existing
    -- players see no change). Off-switch is the workaround for clashes
    -- with minimap-replacement / magnifier addons (Magnify-WotLK was
    -- the trigger - Safra's report). WC stays fully functional with
    -- the button hidden: slash commands, the LDB launcher (Bazooka /
    -- Titan Panel), and key bindings all still work.
    if type(DB.minimapButton) ~= "boolean" then
        DB.minimapButton = true
    end
    -- Opt-in slot-frame border tint that highlights bag items the current
    -- rule chain would sell at the next vendor visit. Texture sits on a
    -- frame-overlay sublevel ABOVE the slot's quality-border but does not
    -- draw on the icon itself, so the icon canvas stays untouched.
    -- Off by default; users opt in via the Character Settings panel and
    -- pick their own colour through the standard colour-picker dialog.
    if type(DB.sellBorderEnabled) ~= "boolean" then
        DB.sellBorderEnabled = false
    end
    -- Master switch over all item highlighting (borders + item level).
    -- Off hides both without touching their own settings. Default ON so
    -- existing setups look the same.
    if type(DB.itemHighlighting) ~= "boolean" then
        DB.itemHighlighting = true
    end
    if type(DB.sellBorderColor) ~= "table" then
        DB.sellBorderColor = { r = 1.0, g = 0.82, b = 0.0, a = 0.9 }
    else
        -- Repair partially-corrupted saves so a missing component never
        -- blanks the border. Each channel falls back to the default if it
        -- isn't a number in [0, 1].
        local c = DB.sellBorderColor
        local function clamp01(v, fallback)
            if type(v) ~= "number" or v ~= v then
                return fallback
            end
            if v < 0 then
                return 0
            end
            if v > 1 then
                return 1
            end
            return v
        end
        c.r = clamp01(c.r, 1.0)
        c.g = clamp01(c.g, 0.82)
        c.b = clamp01(c.b, 0.0)
        c.a = clamp01(c.a, 0.9)
    end
    -- v2.30.x: per-category sell-border colours. Five distinct sell /
    -- delete verdicts each get their own enable toggle + colour so the
    -- user can see WHY a slot would clear at a glance. The legacy
    -- DB.sellBorderColor field stays in the SV (ignored by the new
    -- paint path) so a downgrade to v2.29.x doesn't lose the user's
    -- previous colour pick. New installs and existing-but-unmigrated
    -- saves both land on the five-category default set.
    if type(DB.sellBorderCategories) ~= "table" then
        DB.sellBorderCategories = {}
    end
    do
        local function defaultCat(r, g, b, a)
            return { enabled = true, color = { r = r, g = g, b = b, a = a } }
        end
        local CAT_DEFAULTS = {
            delete = defaultCat(1.0, 0.20, 0.20, 0.9), -- red - highest visibility
            -- v2.37.0: Keep List verdict. Soft cool white, distinct from
            -- the warm-toned sell verdicts. Reads as "pristine /
            -- protected" - the visual-reassurance use case from
            -- EbonClearance's docs/specs/2026-05-28-keep-highlighting-design.md.
            -- Default OFF: every existing category defaults ON, but
            -- Keep is opt-in so the player picks up no NEW slot colour
            -- on the v2.37.0 upgrade unless they explicitly enable it.
            -- This matches the v2.37.0 principle of "don't change
            -- existing players' setups without their action".
            keep = { enabled = false, color = { r = 0.95, g = 0.95, b = 1.00, a = 0.9 } },
            accountSell = defaultCat(0.4, 1.0, 0.4, 0.9), -- bright green
            charSell = defaultCat(0.4, 0.7, 1.0, 0.9), -- cyan / sky blue
            junk = defaultCat(0.7, 0.7, 0.7, 0.7), -- low-alpha grey
            rule = defaultCat(1.0, 0.82, 0.0, 0.9), -- gold (matches v2.29 single-colour default)
        }
        local function clamp01b(v, fallback)
            if type(v) ~= "number" or v ~= v then
                return fallback
            end
            if v < 0 then
                return 0
            end
            if v > 1 then
                return 1
            end
            return v
        end
        for cat, def in pairs(CAT_DEFAULTS) do
            local existing = DB.sellBorderCategories[cat]
            if type(existing) ~= "table" then
                DB.sellBorderCategories[cat] = {
                    enabled = def.enabled,
                    color = { r = def.color.r, g = def.color.g, b = def.color.b, a = def.color.a },
                }
            else
                if type(existing.enabled) ~= "boolean" then
                    existing.enabled = def.enabled
                end
                if type(existing.color) ~= "table" then
                    existing.color =
                        { r = def.color.r, g = def.color.g, b = def.color.b, a = def.color.a }
                else
                    existing.color.r = clamp01b(existing.color.r, def.color.r)
                    existing.color.g = clamp01b(existing.color.g, def.color.g)
                    existing.color.b = clamp01b(existing.color.b, def.color.b)
                    existing.color.a = clamp01b(existing.color.a, def.color.a)
                end
            end
        end
    end
    -- Opt-in tooltip annotation: append the numeric item ID under the WC
    -- status line on bag-item / item-link tooltips. Useful for filing bug
    -- reports and for authoring Keep / Sell / Delete entries by ID. Off
    -- by default; users opt in via the Item Highlighting panel. The line
    -- rides the same OnTooltipSetItem hook WC already installs, so there
    -- is no extra hook cost when the toggle is off.
    if type(DB.showItemIDOnTooltip) ~= "boolean" then
        DB.showItemIDOnTooltip = false
    end
    -- v0.7.0: "Sold: N  Looted: N" (account-wide counts) on item tooltips.
    if type(DB.showItemStatsOnTooltip) ~= "boolean" then
        DB.showItemStatsOnTooltip = true
    end
    -- v2.37.0 (Borrow C): item-level text overlay on equippable gear.
    -- Master toggle + 3 sub-toggle surfaces. Bags is on by default the
    -- first time the master flips on; paperdoll + merchant default off.
    -- Once seeded, the user's sub-toggle choices persist across master
    -- toggles. Only equipLoc-whitelisted gear shows text; consumables
    -- and quest items are skipped. Spec at
    -- EbonClearance's docs/specs/2026-05-28-keep-highlighting-design.md (Borrow C).
    if type(DB.itemLevelOverlay) ~= "table" then
        DB.itemLevelOverlay = {}
    end
    if type(DB.itemLevelOverlay.enabled) ~= "boolean" then
        DB.itemLevelOverlay.enabled = false
    end
    if type(DB.itemLevelOverlay.bags) ~= "boolean" then
        DB.itemLevelOverlay.bags = true
    end
    if type(DB.itemLevelOverlay.paperdoll) ~= "boolean" then
        DB.itemLevelOverlay.paperdoll = false
    end
    if type(DB.itemLevelOverlay.merchant) ~= "boolean" then
        DB.itemLevelOverlay.merchant = false
    end
    -- Font size for the iLvl text. Clamped to a sensible range so a
    -- corrupt SV can't render the number invisible (sub-6) or
    -- catastrophically large (>20). 12 matches the default
    -- NumberFontNormalSmall size.
    if type(DB.itemLevelOverlay.fontSize) ~= "number"
        or DB.itemLevelOverlay.fontSize < 6
        or DB.itemLevelOverlay.fontSize > 20
    then
        DB.itemLevelOverlay.fontSize = 12
    end
    if type(DB.keepBagsOpen) ~= "boolean" then
        -- v2.12.0: flipped from true to false per UX feedback - the
        -- "bags stay open after merchant closes" behaviour was felt
        -- as intrusive. Existing users with the field already set to
        -- true keep their saved value and can untick the panel toggle
        -- if they want bags closing again. New installs default off.
        DB.keepBagsOpen = false
    end
    -- v2.13.3: dropped the DB.vendorBtnShown defaulter alongside the
    -- vendor-button cluster removal. The field had no readers in any
    -- live code path post-v2.13.0 (the only consumer was
    -- WC_UpdateVendorButtonVisibility which itself was orphaned).
    if type(DB.blacklist) ~= "table" then
        DB.blacklist = {}
    end

    -- Whitelist profiles migration. First-run of the profile-aware schema:
    -- if the user already has items in the flat DB.whitelist (from pre-profile
    -- builds), snapshot them into
    -- an "Imported" profile and auto-activate it so nothing is lost. Fresh
    -- installs get an empty Default profile as the active one. Depends on
    -- DB.whitelist having been initialised upstream -- do not reorder.
    if type(DB.whitelistProfiles) ~= "table" then
        DB.whitelistProfiles = {}
        DB.whitelistProfiles["Default"] = {}
        local hasItems = next(DB.whitelist) ~= nil
        if hasItems then
            local snapshot = {}
            for k, v in pairs(DB.whitelist) do
                snapshot[k] = v
            end
            DB.whitelistProfiles["Imported"] = snapshot
            DB.activeProfileName = "Imported"
        else
            DB.activeProfileName = "Default"
        end
    end
    if type(DB.activeProfileName) ~= "string" then
        DB.activeProfileName = "Default"
    end
    DB.whitelistProfiles["Default"] = {}
    if type(DB.blacklistProfiles) ~= "table" then
        DB.blacklistProfiles = {}
    end

    -- v2.13.3: dropped the DB._seededLists write-only guard. The seed body
    -- it once gated (item IDs 300581 / 300574, removed in the v2.0.13
    -- quality pass) hasn't existed for many releases; the flag was being
    -- written but never read. New first-install seeding, if ever needed,
    -- should use a feature-specific guard rather than reviving this one.

end
-- Exposed to split files (the bug-report builder in Stage 8 calls
-- EnsureDB() to guarantee fields exist before reading them).
NS.EnsureDB = EnsureDB

-- Session stats (in-memory only; reset on /reload or by user button).
-- v2.35.x: `startedAt` is the GetTime() snapshot at session start. The
-- MainPanel's RefreshStats reads it to compute Session Gold/Hour and to
-- gate the bestGPH update on the 5-minute minimum duration. Initialised
-- at file load (so /reload starts a fresh session timer) and rewritten
-- by WC_ResetSession on the Reset Session Stats button.
local WC_session = {
    copper = 0,
    sold = 0,
    deleted = 0,
    repairs = 0,
    repairCopper = 0,
    lootCopper = 0,
    startedAt = GetTime(),
}
NS.session = WC_session

-- Session loot ledger. Keyed by itemID -> total quantity looted this
-- session. In-memory only (clears on /reload and Reset Session). This is
-- an AGGREGATE, not an event log: storage is one small integer per
-- distinct item, so it stays bounded no matter how long the farm runs.
-- The persisted account-wide running total lives in
-- ADB.accountStats.lootedItemCounts (see WC_BumpLoot). Exposed on NS so
-- the Stats panel's loot window can read it.
local WC_lootSession = {}
NS.lootSession = WC_lootSession

local function WC_ResetSession()
    WC_session.copper = 0
    WC_session.sold = 0
    WC_session.deleted = 0
    WC_session.repairs = 0
    WC_session.repairCopper = 0
    WC_session.lootCopper = 0
    WC_session.startedAt = GetTime()
    -- Wipe the session loot ledger in place (keep the same table object so
    -- NS.lootSession references held by the loot window stay valid).
    for k in pairs(WC_lootSession) do
        WC_lootSession[k] = nil
    end
end
NS.ResetSession = WC_ResetSession

-- Clear one scope of the loot ledger. "session" wipes the in-memory
-- session table; "account" wipes the persisted account-wide bucket. Both
-- wipe in place so existing table references stay valid.
local function WC_ClearLoot(scope)
    if scope == "account" then
        local AS = ADB and ADB.accountStats
        if AS and AS.lootedItemCounts then
            for k in pairs(AS.lootedItemCounts) do
                AS.lootedItemCounts[k] = nil
            end
        end
    elseif scope == "history" then
        if NS.LootHistory then
            NS.LootHistory.Clear()
        end
    elseif scope == "character" then
        if DB and DB.lootedItemCounts then
            for k in pairs(DB.lootedItemCounts) do
                DB.lootedItemCounts[k] = nil
            end
        end
    else
        for k in pairs(WC_lootSession) do
            WC_lootSession[k] = nil
        end
    end
end
NS.ClearLoot = WC_ClearLoot

-- v2.38.1: every per-character stat write mirrors into ADB.accountStats
-- so the Stats panel's Account view aggregates totals across all
-- characters. DB.* is the source of truth for the Character view; the
-- ADB.accountStats.* mirror counts forward from v2.38.1 install.
--
-- WC_BumpStat: scalar counters (totalCopper, totalItemsSold, etc.).
-- WC_BumpStatBucket: keyed sub-tables (soldItemCounts[itemID],
-- soldItemsByQuality[quality], copperByZone[zoneName], etc.).
--
-- Both helpers are defensive against missing tables - DB or ADB may not
-- exist yet when called from a corner case (e.g. an event firing during
-- ADDON_LOADED before EnsureDB runs).
-- v0.7.0: per-day totals (account-wide), so the Stats panel can show
-- recent days. Keyed by local date; short field names keep the saved
-- rows small: c = sold copper, s = items sold, d = items deleted,
-- r = repair copper, g = looted coin, l = items looted.
WC_compCache.dayFields = {
    totalCopper = "c",
    totalItemsSold = "s",
    totalItemsDeleted = "d",
    totalRepairCopper = "r",
    totalLootCopper = "g",
}
function WC_compCache.bumpDay(key, delta)
    local AS = ADB and ADB.accountStats
    if not (AS and key and delta and delta > 0) then
        return
    end
    AS.daily = AS.daily or {}
    local day = date("%Y-%m-%d")
    local row = AS.daily[day]
    if not row then
        row = {}
        AS.daily[day] = row
    end
    row[key] = (row[key] or 0) + delta
end

local function WC_BumpStat(field, delta)
    delta = delta or 1
    if DB then
        DB[field] = (DB[field] or 0) + delta
    end
    if ADB and ADB.accountStats then
        ADB.accountStats[field] = (ADB.accountStats[field] or 0) + delta
    end
    WC_compCache.bumpDay(WC_compCache.dayFields[field], delta)
end

local function WC_BumpStatBucket(bucket, key, delta)
    delta = delta or 1
    if DB then
        DB[bucket] = DB[bucket] or {}
        DB[bucket][key] = (DB[bucket][key] or 0) + delta
    end
    if ADB and ADB.accountStats then
        ADB.accountStats[bucket] = ADB.accountStats[bucket] or {}
        ADB.accountStats[bucket][key] = (ADB.accountStats[bucket][key] or 0) + delta
    end
end

-- Session loot tracker bump. Writes the in-memory session ledger and the
-- persisted account-wide running total. Deliberately NOT routed through
-- WC_BumpStat / WC_BumpStatBucket: those also mirror into a per-character
-- DB bucket, but loot tracking is session + account only (no per-character
-- lifetime view by design). Aggregate per itemID, so it never grows into
-- an event log.
local function WC_BumpLoot(itemID, qty)
    if not itemID then
        return
    end
    qty = qty or 1
    if qty <= 0 then
        return
    end
    WC_lootSession[itemID] = (WC_lootSession[itemID] or 0) + qty
    if DB then
        DB.lootedItemCounts = DB.lootedItemCounts or {}
        DB.lootedItemCounts[itemID] = (DB.lootedItemCounts[itemID] or 0) + qty
    end
    if ADB and ADB.accountStats then
        ADB.accountStats.lootedItemCounts = ADB.accountStats.lootedItemCounts or {}
        ADB.accountStats.lootedItemCounts[itemID] = (ADB.accountStats.lootedItemCounts[itemID] or 0) + qty
    end
    -- Per-pickup history (who/when). Own loot only; group members' loot
    -- arrives from chat in WoWClearance_LootHistory.lua.
    if NS.LootHistory then
        NS.LootHistory.Add(itemID, qty)
    end
    WC_compCache.bumpDay("l", qty)
    -- v2.50.1: mark the Loot Log window for refresh. Its OnUpdate rebuilds
    -- on this flag (throttled) instead of unconditionally every second, so
    -- an open window costs nothing while no new loot is arriving.
    WC_compCache.lootWindowDirty = true
end

-- Loot capture. We track NET BAG INCREASES rather than parsing
-- CHAT_MSG_LOOT, because a pet or AOE loot source can drop its haul straight
-- into your bags without firing a "you receive loot" chat line - so chat
-- parsing only ever saw what the PLAYER looted by hand. A bag-delta scan
-- catches every source uniformly: manual loot, the auto-loot cycle, AND
-- into bags with no loot message. Summing per itemID across all bags means moving or
-- splitting stacks nets to zero (no false count); only genuine increases
-- are recorded.
--
-- Runs from the BAG_UPDATE debounce flush (already coalesced for the
-- rapid multi-item bursts), so it costs one bag walk per
-- settled burst - no tooltip scans. To avoid counting non-loot inflows
-- (vendor buys / buybacks, bank or mail withdrawals, trade, auction,
-- crafting output), the scan only DIFFS when no transactional window is
-- open; while one is open it just re-baselines the snapshot so the next
-- open-world loot diffs against the right starting point.
local WC_lootBagSnapshot = {}
local WC_lootSnapshotReady = false

-- Frame NAMES (not refs) for the windows through which items legitimately
-- enter bags without being "loot". Looked up via _G at call time because
-- several are load-on-demand (GuildBankFrame, TradeFrame, AuctionFrame,
-- TradeSkillFrame, CraftFrame are nil until first opened) - and a table of
-- frame refs with nil holes would make ipairs stop at the first nil,
-- silently skipping every frame after it (the v2.46.0 bug where mailbox
-- takes were counted because GuildBankFrame was nil and short-circuited
-- the scan of MailFrame). QuestFrame / GossipFrame cover quest-reward and
-- gossip-vendor item grants.
local WC_LOOT_TXN_FRAMES = {
    "MerchantFrame",
    "BankFrame",
    "GuildBankFrame",
    "MailFrame",
    "OpenMailFrame",
    "TradeFrame",
    -- Forever names (AuctionFrame / TradeSkillFrame / CraftFrame do not
    -- exist here, so crafts and auction pickups counted as loot).
    "AuctionHouseFrame",
    "ProfessionsFrame",
    "QuestFrame",
    "GossipFrame",
}

-- True while a window is open through which items legitimately enter bags
-- without being "loot" (so we shouldn't count the delta as looted).
local function WC_LootTransactionWindowOpen()
    for i = 1, #WC_LOOT_TXN_FRAMES do
        local f = _G[WC_LOOT_TXN_FRAMES[i]]
        if f and f.IsShown and f:IsShown() then
            return true
        end
    end
    return false
end

-- v0.7.0: coin picked up from loot windows. Money gained between a loot
-- window opening (LOOT_READY) and 2 s after it closes is loot coin: the
-- money update can land just after LOOT_CLOSED under auto-loot. Reading
-- the money total instead of the loot slots or the chat line keeps this
-- free of localized text. Gains while a transaction window is open
-- (merchant, mail, quest, ...) never count. Coin from loot that skips the
-- loot window entirely is not seen.
function WC_compCache.lootMoneyEvent(event)
    local now = GetTime()
    if event == "LOOT_READY" then
        WC_compCache.lootMoneyBase = GetMoney()
        WC_compCache.lootMoneyUntil = math.huge
    elseif event == "LOOT_CLOSED" then
        if WC_compCache.lootMoneyUntil then
            WC_compCache.lootMoneyUntil = now + 2
        end
    elseif event == "PLAYER_MONEY" then
        local base, money = WC_compCache.lootMoneyBase, GetMoney()
        WC_compCache.lootMoneyBase = money
        if base and money > base and now <= (WC_compCache.lootMoneyUntil or 0) and not WC_LootTransactionWindowOpen() then
            local gain = money - base
            WC_session.lootCopper = WC_session.lootCopper + gain
            WC_BumpStat("totalLootCopper", gain)
            if NS.StampBestGPH then
                NS.StampBestGPH()
            end
        end
    end
end

-- Build a fresh { itemID = totalCount } snapshot across the backpack, bags 1-4 and the reagent bag.
local function WC_BuildBagSnapshot()
    local snap = {}
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local id = GetContainerItemID(bag, slot)
            if id then
                local cInfo = C_Container.GetContainerItemInfo(bag, slot)
                local count = cInfo and cInfo.stackCount
                snap[id] = (snap[id] or 0) + (count or 1)
            end
        end
    end
    return snap
end

-- v2.59.0: shared per-flush bag snapshot. The settled BAG_UPDATE flush used
-- to fan out into 5-9 independent full bag walks (auto-open, upgrade scan,
-- auto-mark scans, loot delta, the since-removed delete scans) - each re-deriving
-- GetContainerItemID / GetContainerItemInfo for the same ~100 slots. The
-- flush now builds this ONCE and every scanner iterates `entries` instead
-- of walking bags; `counts` ({itemID = total}) feeds the loot-delta diff.
--
-- Validity is the FRAME it was built in (`at == GetTime()`; GetTime is
-- frame-constant on 3.3.5a): currentFlushSnapshot() returns nil on any
-- later frame, so an error mid-flush can never leave a stale snapshot
-- influencing a scanner called outside the flush. Staleness WITHIN the
-- flush (a scanner can change a slot mid-chain; the delete scans that did
-- this were removed in v0.6.0) is handled at the consumer: every scanner
-- that runs after that point re-verifies the live slot
-- (GetContainerItemID(bag, slot) == entry.itemID) before scanning a
-- tooltip or acting destructively.
function WC_compCache.buildBagFlushSnapshot()
    local entries = {}
    local counts = {}
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID then
                local cInfo = C_Container.GetContainerItemInfo(bag, slot)
                local count = cInfo and cInfo.stackCount
                local locked = cInfo and cInfo.isLocked
                local quality = cInfo and cInfo.quality
                entries[#entries + 1] = {
                    bag = bag,
                    slot = slot,
                    itemID = itemID,
                    count = count or 1,
                    locked = locked or false,
                    -- May be nil / -1 for uncached items; consumers treat
                    -- "unknown" as "check the slow path", never as "skip".
                    quality = quality,
                }
                counts[itemID] = (counts[itemID] or 0) + (count or 1)
            end
        end
    end
    return { entries = entries, counts = counts, at = GetTime() }
end

-- The flush's shared snapshot, or nil when not inside a flush frame.
function WC_compCache.currentFlushSnapshot()
    local snap = WC_compCache.flushSnapshot
    if snap and snap.at == GetTime() then
        return snap
    end
    return nil
end

-- v2.63.0: lazy acquire - return this frame's shared snapshot, building
-- and caching it on FIRST use. The flush no longer builds the snapshot
-- eagerly: in the default configuration every entries-consumer is toggled
-- off and the only flush consumer is the loot delta, which needs just the
-- flat `counts` map - so the eager build allocated ~one table per occupied
-- bag slot per burst for nobody. The first scanner that actually runs
-- builds it; every later scanner in the same frame reuses it; the flush
-- still clears the ref when it finishes.
function WC_compCache.acquireFlushSnapshot()
    local snap = WC_compCache.currentFlushSnapshot()
    if snap then
        return snap
    end
    snap = WC_compCache.buildBagFlushSnapshot()
    WC_compCache.flushSnapshot = snap
    return snap
end

-- v2.49.0: equipped snapshot for the unequip guard on WC_ScanLootDelta.
-- Reported by Serv: unequipping a worn item counts it as loot because
-- the item moves from an equipment slot to a bag slot, showing as a
-- new bag delta. Comparing this snapshot across scan runs lets us
-- detect "was equipped last scan, isn't now" and subtract that itemID
-- from the positive bag delta before crediting as loot. Standard
-- inventory slots 1-19 (INVSLOT_HEAD through INVSLOT_TABARD).
local WC_lootEquippedSnapshot = {}
-- v2.68.1: double-buffer. The scan fills the spare, diffs it against the
-- baseline, then the two tables SWAP - so this always-on BAG_UPDATE-path
-- consumer stops allocating a fresh 19-slot table (plus the `unequipped`
-- scratch below) every settled burst. Same wipe-and-reuse pattern as
-- WC_manualSell.snapshotBags. On WC_compCache, not file-scope locals:
-- the main chunk sits at Lua 5.1's 200-locals cap.
WC_compCache.lootEquippedSpare = {}
WC_compCache.lootUnequippedScratch = {}
local function WC_BuildEquippedSnapshot(into)
    wipe(into)
    if not GetInventoryItemID then
        return into
    end
    for slot = 1, 19 do
        local id = GetInventoryItemID("player", slot)
        if id then
            into[id] = (into[id] or 0) + 1
        end
    end
    return into
end

-- Diff current bags against the last snapshot and record positive deltas as
-- looted. Called from the BAG_UPDATE debounce flush. The first call after
-- login / reload only baselines (existing bag contents are not "loot").
local function WC_ScanLootDelta()
    -- Master enable gate, consistent with the other debounce-driven scans.
    if NS.IsAddonEnabledForChar and not NS.IsAddonEnabledForChar() then
        return
    end
    -- Skip entirely while an item is on the cursor: a bag reorganise picks
    -- an item up (total count drops) then drops it back (count returns).
    -- Leaving the snapshot untouched until the cursor clears means the
    -- round-trip nets to zero instead of crediting a phantom +1. Any real
    -- loot that lands while the cursor is busy is caught on the next scan.
    if CursorHasItem and CursorHasItem() then
        return
    end
    -- v2.59.0: reuse the shared flush snapshot's {itemID = count} map when
    -- inside a flush (saves a second full bag walk); standalone calls keep
    -- building their own. The shared map is never mutated after build, so
    -- retaining it as the next baseline (bottom of this function) is safe.
    local sharedSnap = WC_compCache.currentFlushSnapshot()
    local snap = sharedSnap and sharedSnap.counts or WC_BuildBagSnapshot()
    -- While a transactional window is open, or on the very first scan, just
    -- re-baseline without crediting any delta as loot.
    if not WC_lootSnapshotReady or WC_LootTransactionWindowOpen() then
        WC_lootBagSnapshot = snap
        WC_BuildEquippedSnapshot(WC_lootEquippedSnapshot)
        WC_lootSnapshotReady = true
        return
    end
    -- v2.49.0: unequip guard. Reported by Serv - unequipping a worn
    -- item moves it from an equipment slot to a bag slot, showing as
    -- a positive bag delta and getting credited as loot. Diff the
    -- equipped snapshot vs the previous run and build a per-itemID
    -- "just unequipped" count. Subtract from the bag delta before
    -- crediting. Equipping (bag -> slot) doesn't trigger a positive
    -- bag delta so no equivalent guard needed on that side.
    local equippedNow = WC_BuildEquippedSnapshot(WC_compCache.lootEquippedSpare)
    local unequipped = WC_compCache.lootUnequippedScratch
    wipe(unequipped)
    for id, prevEq in pairs(WC_lootEquippedSnapshot) do
        local nowEq = equippedNow[id] or 0
        if nowEq < prevEq then
            unequipped[id] = prevEq - nowEq
        end
    end
    -- Delete List items count as loot: nothing deletes them on arrival any
    -- more (v0.6.0, the game refuses automatic deletes), so they stay in
    -- bags until the player presses Delete Next, like any other loot.
    for id, count in pairs(snap) do
        local prev = WC_lootBagSnapshot[id] or 0
        if count > prev then
            local delta = count - prev
            -- v2.49.0: subtract items just unequipped so a worn->bag
            -- transition doesn't count as loot.
            local unequipDelta = unequipped[id] or 0
            local netDelta = delta - unequipDelta
            -- NS.IsInSet rather than the file-local IsInSet because that
            -- local is declared further down in the chunk (after this
            -- function's definition point) and isn't a captured upvalue
            -- here. Same membership semantics; one extra table lookup.
            if netDelta > 0 then
                WC_BumpLoot(id, netDelta)
            end
        end
    end
    WC_lootBagSnapshot = snap
    -- Rotate the double-buffer: the just-built table becomes the baseline,
    -- the old baseline becomes next scan's spare (wiped on fill).
    WC_compCache.lootEquippedSpare = WC_lootEquippedSnapshot
    WC_lootEquippedSnapshot = equippedNow
end

-- Keep bags open when merchant closes
local WC_keepBagsFlag = false

local function WC_OpenAllBags()
    if OpenAllBags then
        OpenAllBags()
    elseif OpenBackpack then
        OpenBackpack()
        for i = 1, 4 do
            if OpenBag then
                OpenBag(i)
            end
        end
    end
end

WC_GetPlayerName = function()
    local n = UnitName("player")
    if not n or n == "" then
        return ""
    end
    return n
end

-- v2.13.1 robustness helper for WC_IsCharacterAllowed: case-insensitive +
-- invisible-whitespace-stripped name normalisation. Catches entries added
-- with different capitalisation (user typed "zittla" but UnitName returns
-- "Zittla"), entries pasted from chat / web with embedded non-breaking
-- space (U+00A0) or zero-width joiner (U+200B), and similar look-alike
-- strings the v2.13.0 add-time trim missed. On a single PE-style private
-- server character names are unique by case, so a lowercase match cannot
-- collide with another player's name. (v2.68.1: hoisted out of the
-- function - it was a closure rebuilt on every slow-path call. Hung off
-- WC_compCache rather than a file-scope local because the main chunk sits
-- at Lua 5.1's 200-locals cap.)
function WC_compCache.stripCharName(s)
    return (s or ""):lower():gsub("[%s\194\160\226\128\139]+", "")
end

local function WC_IsCharacterAllowed()
    if not DB or not DB.enableOnlyListedChars then
        return true
    end
    if not DB.allowedChars then
        return false
    end
    local name = WC_GetPlayerName()
    -- Fast path: exact-case match (the common case for entries added via
    -- the Add Me button or typed identically).
    if DB.allowedChars[name] == true then
        return true
    end
    local target = WC_compCache.stripCharName(name)
    if target == "" then
        return false
    end
    for key, val in pairs(DB.allowedChars) do
        if val == true and type(key) == "string" and WC_compCache.stripCharName(key) == target then
            return true
        end
    end
    return false
end

WC_IsAddonEnabledForChar = function()
    if DB and DB.enabled == false then
        return false
    end
    return WC_IsCharacterAllowed()
end
-- Expose to split files. Process Bags (Stage 7+) gates its operations
-- on this; any future per-character feature can read it via NS.
NS.IsAddonEnabledForChar = WC_IsAddonEnabledForChar

-- Set-membership helper. Captures the canonical NS.IsInSet (defined in
-- WoWClearance_Core.lua); per-call cost is one local read.
local IsInSet = NS.IsInSet

-- Whitelist profile functions
local function WC_ValidateProfileName(name)
    if type(name) ~= "string" then
        return false, "Invalid name."
    end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        return false, "Profile name cannot be empty."
    end
    if name:find("[:|]") then
        return false, "Profile name cannot contain : or | characters."
    end
    return true, name
end

local function WC_CountItems(tbl)
    local n = 0
    for k, v in pairs(tbl) do
        if type(k) == "number" and (v == true or v == 1) then
            n = n + 1
        end
    end
    return n
end
-- Exposed to split files (the bug-report builder in Stage 8 uses it for
-- the "Sell List Items: N" / "Account Sell List Items: N" / etc. lines).
NS.CountItems = WC_CountItems

local function WC_SaveProfile(name)
    local ok, cleaned = WC_ValidateProfileName(name)
    if not ok then
        return false, cleaned
    end
    name = cleaned
    if name == "Default" then
        return false, "The Default profile is locked to empty and cannot be overwritten."
    end
    local snapshot = {}
    for k, v in pairs(DB.whitelist) do
        snapshot[k] = v
    end
    DB.whitelistProfiles[name] = snapshot
    local blSnapshot = {}
    for k, v in pairs(DB.blacklist) do
        blSnapshot[k] = v
    end
    DB.blacklistProfiles[name] = blSnapshot
    DB.activeProfileName = name
    local wlCount = WC_CountItems(snapshot)
    local blCount = WC_CountItems(blSnapshot)
    return true, string.format('Saved profile "|cffffff00%s|r" (%d sell, %d keep).', name, wlCount, blCount)
end

local function WC_LoadProfile(name)
    if type(name) ~= "string" or not DB.whitelistProfiles[name] then
        return false, string.format('Profile "%s" not found.', tostring(name))
    end
    wipe(DB.whitelist)
    -- v2.10.0: profiles persist Whitelist + Blacklist item IDs but not the
    -- "auto-added when equipped" source flag. Loading a profile is a fresh
    -- intent (the user is changing what they want protected); reset the
    -- Blacklist auto map so leftover entries from the previous profile
    -- don't bleed their tooltip annotation through.
    if type(DB.blacklistAuto) == "table" then
        wipe(DB.blacklistAuto)
    end
    for k, v in pairs(DB.whitelistProfiles[name]) do
        DB.whitelist[k] = v
    end
    wipe(DB.blacklist)
    if DB.blacklistProfiles[name] then
        for k, v in pairs(DB.blacklistProfiles[name]) do
            DB.blacklist[k] = v
        end
    end
    DB.activeProfileName = name
    local wlCount = WC_CountItems(DB.whitelist)
    local blCount = WC_CountItems(DB.blacklist)
    -- Refresh panels if they exist
    local wp = _G["WoWClearanceOptionsWhitelist"]
    if wp and wp.listUI then
        wp.listUI:Refresh()
    end
    local bp = _G["WoWClearanceOptionsBlacklist"]
    if bp and bp.listUI then
        bp.listUI:Refresh()
    end
    -- Profile load wholesale-rewrites DB.whitelist + DB.blacklist, which
    -- changes WC_IsSellable's verdict for every item previously / newly
    -- on those lists. Repaint slot-border tints so the categories
    -- (charSell / and the indirect knock-on through the rule category)
    -- track immediately. Same rule as the list-mutation refresh invariant
    -- (Test 26) and the settings-toggle refresh invariant (Test 42).
    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end
    return true, string.format('Loaded profile "|cffffff00%s|r" (%d sell, %d keep).', name, wlCount, blCount)
end

local function WC_DeleteProfile(name)
    if type(name) ~= "string" or not DB.whitelistProfiles[name] then
        return false, string.format('Profile "%s" not found.', tostring(name))
    end
    if name == "Default" then
        return false, "The Default profile cannot be deleted."
    end
    -- Count remaining profiles
    local count = 0
    for _ in pairs(DB.whitelistProfiles) do
        count = count + 1
    end
    if count <= 1 then
        return false, "Cannot delete the only remaining profile."
    end
    DB.whitelistProfiles[name] = nil
    DB.blacklistProfiles[name] = nil
    if DB.activeProfileName == name then
        DB.activeProfileName = next(DB.whitelistProfiles) or "Default"
    end
    return true, string.format('Deleted profile "|cffffff00%s|r".', name)
end

local function WC_RenameProfile(oldName, newName)
    if type(oldName) ~= "string" or not DB.whitelistProfiles[oldName] then
        return false, string.format('Profile "%s" not found.', tostring(oldName))
    end
    if oldName == "Default" then
        return false, "The Default profile cannot be renamed."
    end
    local ok, cleaned = WC_ValidateProfileName(newName)
    if not ok then
        return false, cleaned
    end
    newName = cleaned
    if newName == "Default" then
        return false, 'Cannot rename a profile to "Default".'
    end
    if newName == oldName then
        return true, "Name unchanged."
    end
    if DB.whitelistProfiles[newName] then
        return false, string.format('A profile named "%s" already exists.', newName)
    end
    DB.whitelistProfiles[newName] = DB.whitelistProfiles[oldName]
    DB.whitelistProfiles[oldName] = nil
    if DB.blacklistProfiles[oldName] then
        DB.blacklistProfiles[newName] = DB.blacklistProfiles[oldName]
        DB.blacklistProfiles[oldName] = nil
    end
    if DB.activeProfileName == oldName then
        DB.activeProfileName = newName
    end
    return true, string.format('Renamed "|cffffff00%s|r" to "|cffffff00%s|r".', oldName, newName)
end
-- Stage 8e-viii: profile-management helpers exposed on NS so the
-- ProfilesPanel (extracted into WoWClearance_ProfilesPanel.lua) can
-- reach them. Bodies remain file-scope locals in WoWClearance_Events.lua;
-- slash command handlers + the panel's button OnClicks both resolve
-- through the same NS entries.
NS.SaveProfile = WC_SaveProfile
NS.LoadProfile = WC_LoadProfile
NS.DeleteProfile = WC_DeleteProfile
NS.RenameProfile = WC_RenameProfile

-- ===========================================================================
-- v2.72.0 settings profiles (management).
-- ---------------------------------------------------------------------------
-- Unlike the list profiles above (per-character snapshots that Load COPIES
-- into the live lists), a settings profile is a LIVE body: the DB proxy
-- resolves every selling-behaviour read/write through the character's
-- active profile, so "Use" just moves the per-character pointer. Bodies
-- live at the top-level WoWClearanceDB.settingsProfiles[name] so alts
-- share a profile by pointing at the same name.
-- Defined directly on NS (no main-chunk locals - the 200-locals cap).

-- Re-fires the option panels + bag borders after the active settings
-- change under a panel's feet (same repaint set Quickstart uses).
function NS.RepaintAfterSettingsSwitch()
    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end
    local panels = {
        "WoWClearanceOptionsMain",
        "WoWClearanceOptionsMerchant",
        "WoWClearanceOptionsBlacklistSettings",
        "WoWClearanceOptionsDeletionSettings",
        "WoWClearanceOptionsSettingsProfiles",
    }
    for _, panelName in ipairs(panels) do
        local p = _G[panelName]
        if p and p.inited and p.GetScript and p:GetScript("OnShow") then
            p:GetScript("OnShow")(p)
        end
    end
end

-- Snapshot the character's CURRENT selling settings under `name` and
-- switch to it (mirror of WC_SaveProfile's save-then-activate shape).
-- v2.75.0 (fresh-audit fix): returns the cleaned profile name if a profile with
-- that (validated) name already exists, else nil. Lets the Profiles panel raise
-- an overwrite confirmation before Save replaces an existing profile's body.
function NS.SettingsProfileExists(name)
    local ok, cleaned = WC_ValidateProfileName(name)
    if not ok then
        return nil
    end
    local profiles = WoWClearanceDB and WoWClearanceDB.settingsProfiles
    return (profiles and profiles[cleaned] ~= nil) and cleaned or nil
end

function NS.SaveSettingsProfile(name)
    local ok, cleaned = WC_ValidateProfileName(name)
    if not ok then
        return false, cleaned
    end
    local profiles = WoWClearanceDB and WoWClearanceDB.settingsProfiles
    if not profiles then
        return false, L["Settings profiles are not ready yet."]
    end
    local snap = {}
    for f in pairs(WC_compCache.settingsProfileFields) do
        -- Reads route through the proxy, so this snapshots the values
        -- the character is actually using right now.
        snap[f] = WC_DBDeepCopy(DB[f])
    end
    profiles[cleaned] = snap
    DB.activeSettingsProfile = cleaned
    return true, string.format(L['Saved settings as "|cffffff00%s|r" - this character now uses it.'], cleaned)
end

-- Point this character at an existing settings profile.
function NS.UseSettingsProfile(name)
    local profiles = WoWClearanceDB and WoWClearanceDB.settingsProfiles
    if not (profiles and name and profiles[name]) then
        return false, string.format(L['No settings profile named "|cffffff00%s|r".'], tostring(name))
    end
    if DB.activeSettingsProfile == name then
        return true, string.format(L['Already using settings profile "|cffffff00%s|r".'], name)
    end
    DB.activeSettingsProfile = name
    -- Re-run the idempotent bootstrap so a profile saved by an older
    -- version picks up nil-defaults for fields added since (the defaults
    -- write through the proxy into the newly-active profile).
    EnsureDB()
    NS.RepaintAfterSettingsSwitch()
    return true, string.format(L['This character now uses settings profile "|cffffff00%s|r".'], name)
end

function NS.DeleteSettingsProfile(name)
    if name == "Default" then
        return false, L["The Default settings profile cannot be deleted."]
    end
    local profiles = WoWClearanceDB and WoWClearanceDB.settingsProfiles
    if not (profiles and name and profiles[name]) then
        return false, string.format(L['No settings profile named "|cffffff00%s|r".'], tostring(name))
    end
    profiles[name] = nil
    -- Note whether THIS character used it before the walk below repoints
    -- every namespace (the walk includes ours).
    local repointedSelf = DB.activeSettingsProfile == name
    -- Repoint every character that used it back to Default (the proxy
    -- also falls back to Default at read time, but a live pointer to a
    -- dead profile should not persist).
    local chars = WoWClearanceDB.chars
    if chars then
        for _, charNS in pairs(chars) do
            if charNS.activeSettingsProfile == name then
                charNS.activeSettingsProfile = "Default"
            end
        end
    end
    if repointedSelf then
        -- Covers the transient pre-login namespace too (not in chars).
        DB.activeSettingsProfile = "Default"
        NS.RepaintAfterSettingsSwitch()
        return true,
            string.format(L['Deleted settings profile "|cffffff00%s|r" - this character is back on Default.'], name)
    end
    return true, string.format(L['Deleted settings profile "|cffffff00%s|r".'], name)
end

function NS.RenameSettingsProfile(oldName, newName)
    if oldName == "Default" then
        return false, L["The Default settings profile cannot be renamed."]
    end
    local ok, cleaned = WC_ValidateProfileName(newName)
    if not ok then
        return false, cleaned
    end
    local profiles = WoWClearanceDB and WoWClearanceDB.settingsProfiles
    if not (profiles and oldName and profiles[oldName]) then
        return false, string.format(L['No settings profile named "|cffffff00%s|r".'], tostring(oldName))
    end
    if profiles[cleaned] then
        return false, string.format(L['A settings profile named "|cffffff00%s|r" already exists.'], cleaned)
    end
    profiles[cleaned] = profiles[oldName]
    profiles[oldName] = nil
    local wasSelf = DB.activeSettingsProfile == oldName
    local chars = WoWClearanceDB.chars
    if chars then
        for _, charNS in pairs(chars) do
            if charNS.activeSettingsProfile == oldName then
                charNS.activeSettingsProfile = cleaned
            end
        end
    end
    if wasSelf then
        -- Covers the transient pre-login namespace too (not in chars).
        DB.activeSettingsProfile = cleaned
    end
    return true, string.format(L['Renamed settings profile "|cffffff00%s|r" to "|cffffff00%s|r".'], oldName, cleaned)
end

local function CopperToColoredText(copper)
    if not copper or copper < 0 then
        copper = 0
    end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop = copper % 100

    -- v2.58.0: comma-separate the gold amount for readability (e.g. 802,579g);
    -- silver/copper are always 0-99 so they never need it. NS.CommaNumber loads
    -- before this file, but guard defensively in case load order changes.
    local goldText = (NS.CommaNumber and NS.CommaNumber(gold)) or tostring(gold)
    local g = string.format("|cffF8D943%sg|r", goldText)
    local s = string.format("|cffC0C0C0%ds|r", silver)
    local c = string.format("|cffB87333%dc|r", cop)
    return string.format("%s %s %s", g, s, c)
end
NS.CopperToColoredText = CopperToColoredText

-- v2.66.1 iter (Serv report): gold-only variant for the Stats panel's
-- aggregate lines (Total Money Made, Total Repair Cost, Session /
-- Best Gold/Hour). Silver + copper are noise at multi-thousand-gold
-- totals. Per-item vendor prices (loot log entries, bug report line
-- items) still use the full CopperToColoredText above where the
-- silver/copper components can be meaningful.
local function CopperToGoldOnlyText(copper)
    if not copper or copper < 0 then
        copper = 0
    end
    local gold = math.floor(copper / 10000)
    local goldText = (NS.CommaNumber and NS.CommaNumber(gold)) or tostring(gold)
    return string.format("|cffF8D943%sg|r", goldText)
end
NS.CopperToGoldOnlyText = CopperToGoldOnlyText

-- "WoWClearance: msg", the label in the brand colour (shared kit form).
local PrintNice = NS.Kit.Printer("WoWClearance", "66ccff")

-- Format + print convenience. Use instead of PrintNice(string.format(fmt, ...)).
local function PrintNicef(fmt, ...)
    PrintNice(string.format(fmt, ...))
end

-- Expose to split files (Stage 6+ uses NS.PrintNice / NS.PrintNicef from
-- WoWClearance_BagDisplay.lua's sellinfo trace output). WoWClearance_Events.lua's
-- own call sites keep using the file-scope upvalues.
NS.PrintNice = PrintNice
NS.PrintNicef = PrintNicef

-- Price provider seam. Returns vendor sellPrice * count. The signature
-- keeps the leading itemLink + itemID args (underscore-prefixed today)
-- so future price-source plumbing can plug in here without rewriting
-- callers.
local function WC_GetItemPrice(_itemLink, _itemID, sellPrice, count)
    return (sellPrice or 0) * (count or 1)
end

local function WC_CalcInventoryWorthCopper()
    local total = 0
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID then
                local cInfo = C_Container.GetContainerItemInfo(bag, slot)
                local itemCount = cInfo and cInfo.stackCount
                if itemCount and itemCount > 0 then
                    local sellPrice = select(11, GetItemInfo(itemID))
                    if sellPrice and sellPrice > 0 then
                        total = total + (sellPrice * itemCount)
                    end
                end
            end
        end
    end
    return total
end

local function WC_RecordInventoryWorthSample()
    if not DB then
        return
    end
    local worth = WC_CalcInventoryWorthCopper()
    DB.inventoryWorthTotal = (DB.inventoryWorthTotal or 0) + worth
    DB.inventoryWorthCount = (DB.inventoryWorthCount or 0) + 1
end

-- WC-TRAP: this raw global override must NOT be "fixed" to hooksecurefunc.
-- v2.37.4 (audit issue #2): this is one of the few raw global overrides
-- left in the addon. hooksecurefunc is NOT a drop-in swap here because
-- the hook below intentionally SHORT-CIRCUITS the original handler when
-- an WC ID-input box is focused (the shift-click insert goes into the
-- WC field, not the chat input). hooksecurefunc always runs the original
-- first, so swapping to it would leak the link into the chat editbox.
-- The .luacheckrc allow-lists this assignment by name. Wrap-with-original
-- + early-return stays.
local WC_Original_ChatEdit_InsertLink = ChatEdit_InsertLink

local function WC_ExtractItemID(link)
    if type(link) ~= "string" then
        return nil
    end
    local id = link:match("item:(%d+)")
    if id then
        return tonumber(id)
    end
    return nil
end

-- v0.5.7 (Serv report): shift-clicking a bag item no longer filled the WC
-- ID box. The replacement above targets ChatEdit_InsertLink, which on
-- Forever exists ONLY as a deprecation alias:
--
--     Blizzard_DeprecatedChatInfo/Deprecated_ChatFrame.lua:43
--         ChatEdit_InsertLink = ChatFrameUtil.InsertLink;
--
-- Blizzard's own code calls ChatFrameUtil.InsertLink DIRECTLY, so replacing
-- the alias replaces something nothing calls. The alias also only exists at
-- all when deprecation fallbacks are loaded, so WC_Original_ was likely nil
-- as well - a second failure hiding behind the first.
--
-- This is the shape to watch for generally: a deprecation shim makes the
-- old name RESOLVE, which makes a capability check pass, while every real
-- caller has already moved to the new name. Checking "does the old global
-- exist" is the wrong question; the right one is "does anything still call
-- it".
--
-- WC-TRAP: both paths REPLACE rather than hooksecurefunc, for the reason
-- given above - the wrapper must early-return to stop the link leaking into
-- the chat editbox, and a hook cannot suppress. Do not "fix" either branch
-- into a hook.
local function WC_InsertLinkIntoIDBox(link)
    local box = NS.activeIDBox
    if box and box:IsShown() then
        local id = WC_ExtractItemID(link)
        if id then
            box:SetText(tostring(id))
            box:HighlightText()
            return true
        end
    end
    return nil
end

if ChatFrameUtil and ChatFrameUtil.InsertLink then
    local origInsertLink = ChatFrameUtil.InsertLink
    ChatFrameUtil.InsertLink = function(text)
        if WC_InsertLinkIntoIDBox(text) then
            return true
        end
        return origInsertLink(text)
    end
else
    ChatEdit_InsertLink = function(link)
        if WC_InsertLinkIntoIDBox(link) then
            return true
        end
        return WC_Original_ChatEdit_InsertLink(link)
    end
end

local WC_delayFrame = CreateFrame("Frame")
local WC_timers = {}

local function WC_Delay(seconds, func)
    if type(func) ~= "function" then
        return
    end
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then
        func()
        return
    end
    WC_timers[#WC_timers + 1] = { t = seconds, f = func }
end

WC_delayFrame:SetScript("OnUpdate", function(self, elapsed)
    if #WC_timers == 0 then
        return
    end
    for i = #WC_timers, 1, -1 do
        local item = WC_timers[i]
        item.t = item.t - elapsed
        if item.t <= 0 then
            table.remove(WC_timers, i)
            local ok, err = pcall(item.f)
            if not ok and geterrorhandler then
                geterrorhandler()(err)
            end
        end
    end
end)
-- Expose WC_Delay to split files via NS. Used by post-Stage-7
-- WoWClearance_Process.lua and any future split file that needs to
-- schedule a delayed callback. The forward-declared `WC_delayFrame`
-- and `WC_timers` stay local to this file; only the scheduling helper
-- is part of the namespace surface.
NS.Delay = WC_Delay

local function WC_GetFreeBagSlots()
    local free = 0
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        local numFree = GetContainerNumFreeSlots(bag)
        if numFree then
            free = free + numFree
        end
    end
    return free
end
NS.GetFreeBagSlots = WC_GetFreeBagSlots

-- Fast Mode: when enabled, pin the per-item vendor interval to the 0.05 s
-- floor and double the per-run cap. Opt-in via DB.fastMode.
local function WC_EffectiveVendorInterval()
    if DB and DB.fastMode then
        return 0.05
    end
    local i = (DB and DB.vendorInterval) or 0.1
    if i < 0.05 then
        i = 0.05
    end
    return i
end

local function WC_EffectiveMaxItemsPerRun()
    if DB and DB.fastMode then
        return 160
    end
    return (DB and DB.maxItemsPerRun) or 80
end

-- v2.37.7: Turbo Mode pops multiple items off the queue per worker fire
-- so a bag clear finishes in a fraction of the time. Stacks with Fast
-- Mode: with both on the effective rate is 4 / 0.05 = 80 items/sec.
-- Standalone Turbo with default 0.1 s interval = 40 items/sec. The
-- batch size is deliberately small (4) so the per-frame UseContainerItem
-- burst stays well inside what server-side rate limiting will accept;
-- the per-run cap still applies. Surfaced in the Merchant panel; the
-- effective items/sec readout under the slider reflects the current
-- combination.
local TURBO_BATCH_SIZE = 4

local function WC_EffectiveBatchSize()
    if DB and DB.turboMode then
        return TURBO_BATCH_SIZE
    end
    return 1
end

-- Auto-open container in-flight flag. Same forward-declaration discipline as
-- the timers above: WC_HandleAutoOpenContainers writes this, and we don't want
-- the write to leak into _G if the function is parsed before the local exists.
local WC_autoOpenInFlight = false

-- v2.21.0: Fast Loot queue state hung off WC_compCache to stay under
-- Lua 5.1's 200-locals-per-main-chunk cap (CLAUDE.md discipline). The
-- queue replaces v2.16.0's tight-loop drain with a slot-index queue
-- that drains via OnUpdate throttle, reducing per-frame LootSlot
-- pressure to mitigate disconnect risk on busy 3.3.5a private
-- servers. WC_compCache.lootQueue is initialised here so the OnUpdate
-- driver (built lazily in WC_HandleLootReady) can reach it via
-- WC_compCache. Resets naturally on /reload and on every LOOT_READY
-- (re-population wipes + refills).
WC_compCache.lootQueue = {
    slots = {},
    isProcessing = false,
    lastLootAt = 0,
    delay = 0.11, -- 110 ms; matches the reference implementation's default
    frame = nil, -- built lazily in WC_HandleLootReady on first call
}

-- ===========================================================================
-- Auto-open lootable containers
-- ---------------------------------------------------------------------------
-- Hidden tooltip used to scan bag items for the "Right Click to Open" line,
-- bind type detection, and Process Bags
-- mode detection. Anchored offscreen via SetOwner(UIParent, "ANCHOR_NONE")
-- so it never flashes on the user's screen during scans.
--
-- Lives in this file (not WoWClearance_Protection.lua) because callers
-- exist in both Protection and non-protection code (auto-open driver,
-- Process Bags helpers, bug-report builder). Exposed on the namespace so
-- WoWClearance_Protection.lua can dereference it lazily at call time
-- (Protection loads BEFORE this file, so an upvalue capture at Protection's
-- load would store nil).
local WC_scanTooltip = CreateFrame("GameTooltip", "WoWClearanceScanTooltip", UIParent, "GameTooltipTemplate")
WC_scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
NS.scanTooltip = WC_scanTooltip

-- v2.68.1: memoised access to the scan tooltip's line FontStrings. Every
-- offscreen tooltip scanner used to rebuild the global name per line per
-- scan (`_G["WoWClearanceScanTooltipTextLeft" .. i]`) - a throwaway
-- string + _G hash lookup per iteration, ~1,000+ allocations per scanner
-- pass on a cold-cache bag walk. Once a line FontString exists it is a
-- stable session-long reference (fixed frame name), so cache it forever.
--
-- MUST stay lazy-fill, NOT an eager loop at load: GameTooltipTemplate only
-- pre-creates the first line FontStrings; the client materialises higher
-- indices on demand as tooltips grow. An eager array would freeze nil for
-- every not-yet-rendered line and silently truncate all scans. The
-- metatable fires only on a miss; after the rawset, reads are plain hash
-- hits. A nil return (line not created yet) keeps today's `break`
-- semantics in every scan loop. Consumers in Protection/Process/BugReport
-- read WC_compCache.scanLines at CALL time (those files load before this
-- one - the Test 41 load-order trap).
WC_compCache.scanLines = setmetatable({}, {
    __index = function(t, i)
        local fs = _G["WoWClearanceScanTooltipTextLeft" .. i]
        if fs then
            rawset(t, i, fs)
        end
        return fs
    end,
})

-- v2.38.3: SetOwner-before-SetBagItem invariant. WoW's GameTooltip
-- silently drops ownership when something calls :Hide() on it - and
-- anyone iterating UIParent's children (host bag UI replacements, host
-- UI replacements, profiling addons) can trigger that hide unexpectedly.
-- Once ownership is gone, every SetBagItem on this frame populates zero
-- lines and the tooltip-scan-based predicates (processTooltipHasLine,
-- processIsSoulbound, canPickLock, sell-info /
-- delete-list scans, etc.) silently return false. The cache then
-- poisons with "none" until /reload.
--
-- All scan-tooltip call sites in the addon must go through this helper.
-- It re-establishes ownership defensively so SetBagItem always works.
-- Cost: two extra C calls per scan; negligible vs. the silent-failure
-- mode this prevents.
function WC_compCache.scanBagItem(bag, slot)
    WC_scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    WC_scanTooltip:ClearLines()
    WC_scanTooltip:SetBagItem(bag, slot)
    return WC_scanTooltip
end

-- Forward declaration so the debounce frame's OnUpdate closure below
-- can resolve the name. Without this, Lua's lexical scoping resolves
-- the reference to the (nil) global at closure-creation time and the
-- auto-open driver never fires from the debounce path. v2.24.0 perf
-- regression discovered post-v2.25.0 when locked boxes that the user
-- opened via Process Bags weren't being auto-opened by the debounce.
-- Function body still lives at its original spot below.
local WC_HandleAutoOpenContainers

-- v2.24.0: BAG_UPDATE coalescing frame. AOE looting
-- 5 items in <100 ms fires 5 BAG_UPDATE events; running the full
-- deferred-work chain (auto-open containers, upgrade scan, Process
-- Bags rearm, panel refresh) per-event caused 1.5 s freezes in
-- v2.22.0+v2.23.0. This frame's OnUpdate watches a "burst settled"
-- accumulator and fires the work once after the configured idle
-- window. State on WC_compCache to stay under Lua 5.1's 200-locals
-- cap.
WC_compCache.bagUpdateAccum = 0
WC_compCache.BAG_UPDATE_DEBOUNCE_S = 0.12 -- 120 ms idle window
WC_compCache.bagUpdateFrame = CreateFrame("Frame")
WC_compCache.bagUpdateFrame:Hide()

-- ------------------------------------------------------------------
-- Frame-spike diagnostic (session-only). A cheap always-on watchdog
-- watches per-frame time; when a single frame runs long enough to be a
-- visible hitch, it records how many milliseconds WC spent in each of
-- its heavy phases that frame (bag-update flush, vendor cycle, tooltip
-- annotation) and flags the worst offender. Surfaced by /wc spike.
--
-- Phase counters are cumulative wall-clock ms from debugprofilestop - a
-- high-res timer that, unlike CPU profiling, is always available on
-- 3.3.5a with no CVar. The watchdog only reads deltas, so the counters
-- climbing over a session is harmless. Everything is in-memory and
-- bounded; it clears on /reload and is never persisted.
--
-- Perf: the watchdog does a few subtractions per frame and allocates a
-- table only on an actual spike, so it adds no measurable per-frame cost
-- and touches none of the BAG_UPDATE coalescing state.
local WC_prof = debugprofilestop
local WC_SPIKE_THRESHOLD_S = 0.05 -- ~50 ms frame: a visible micro-stutter
local WC_SPIKE_CEILING_S = 2.0 -- ignore loading-screen / alt-tab mega-frames
local WC_SPIKE_LOG_MAX = 20
local WC_SPIKE_EPSILON_MS = 0.1 -- "WC did real work this frame" floor
local WC_spikeLog = {}
-- Cumulative ms per phase. Exposed on WC_compCache so the tooltip module
-- (a separate file) can add to the same counters.
local WC_spikePhase = { bagupdate = 0, vendor = 0, tooltip = 0 }
WC_compCache.spikePhase = WC_spikePhase
WC_compCache.spikeProf = WC_prof
NS.recentSpikeLog = WC_spikeLog
-- v2.76.0: the worst-N frames of the session, sorted descending by ms,
-- so one big hitch is not evicted by twenty later small ones (the
-- recent ring above is a severity-blind FIFO). Entries are SHARED with
-- NS.recentSpikeLog - never mutate an entry after insert.
NS.worstSpikeLog = {}
NS.worstSpikeLogMax = 10

local WC_spikeFrame = CreateFrame("Frame")
local WC_spikePrevBag, WC_spikePrevVendor, WC_spikePrevTip = 0, 0, 0
WC_spikeFrame:SetScript("OnUpdate", function(_, elapsed)
    local p = WC_spikePhase
    local dBag = p.bagupdate - WC_spikePrevBag
    local dVendor = p.vendor - WC_spikePrevVendor
    local dTip = p.tooltip - WC_spikePrevTip
    WC_spikePrevBag = p.bagupdate
    WC_spikePrevVendor = p.vendor
    WC_spikePrevTip = p.tooltip
    if elapsed < WC_SPIKE_THRESHOLD_S or elapsed > WC_SPIKE_CEILING_S then
        return
    end
    -- Which WC phase ate the most time during this hitch?
    local dom, domMs = nil, WC_SPIKE_EPSILON_MS
    if dBag > domMs then
        dom, domMs = "Bag update", dBag
    end
    if dVendor > domMs then
        dom, domMs = "Vendor cycle", dVendor
    end
    if dTip > domMs then
        -- Last phase checked: nothing reads domMs after this, so only the
        -- winning label needs updating (leaving domMs here would be a dead
        -- write - luacheck flags it).
        dom = "Tooltip scan"
    end
    -- Only record hitches WC actually contributed to. An empty /wc spike
    -- after a stutter storm is itself the answer: WC wasn't busy then.
    if not dom then
        return
    end
    -- v2.76.0: ecMs (WC's total work this frame) is captured at insert
    -- because the entry is shared between the recent and worst rings and
    -- immutable after this point; the display derives the percentage.
    -- The phase deltas are cumulative-counter differences, so ecMs >= 0.
    local entry = {
        ms = elapsed * 1000,
        dominant = dom,
        bagMs = dBag,
        vendorMs = dVendor,
        tipMs = dTip,
        ecMs = dBag + dVendor + dTip,
        fps = (GetFramerate and GetFramerate()) or 0,
        loggedAt = date("%H:%M:%S"),
    }
    table.insert(WC_spikeLog, 1, entry)
    if #WC_spikeLog > WC_SPIKE_LOG_MAX then
        table.remove(WC_spikeLog)
    end
    -- Worst ring: sorted insert (descending by ms) with a replace-min
    -- early-out, then trim the tail. Eviction is by SEVERITY, never
    -- FIFO - the whole point is that a 400 ms hitch survives twenty
    -- later 51 ms ones. Strict < in the scan keeps equal-ms entries in
    -- arrival order (oldest of equals ranks first).
    local worst = NS.worstSpikeLog
    if #worst < NS.worstSpikeLogMax or entry.ms > worst[#worst].ms then
        local pos = #worst + 1
        while pos > 1 and worst[pos - 1].ms < entry.ms do
            pos = pos - 1
        end
        table.insert(worst, pos, entry)
        if #worst > NS.worstSpikeLogMax then
            table.remove(worst)
        end
    end
end)

-- Copyable list of frame hitches: the worst of the session (biggest
-- first) then the most recent (newest first), each line showing WC's
-- share of the frame so a pasted report proves whose stutter it was.
-- Backs the /wc spike command. Session-only - both rings clear on /reload.
function NS.ShowFrameSpikes()
    local body
    if #WC_spikeLog == 0 then
        body = L["No frame hitches blamed on WoWClearance this session. Either there were none, or WoWClearance wasn't doing heavy work during any slow frame. Clears on /reload."]
    else
        -- v2.76.0: the share is derived here from the stored ecMs; the
        -- clamp guards the two-clock case (debugprofilestop vs elapsed)
        -- ever pushing it past 100.
        local function fmtLine(e)
            local ms = tonumber(e.ms) or 0
            local ecMs = tonumber(e.ecMs) or 0
            local pct = ms > 0 and math.min(100, ecMs / ms * 100) or 0
            -- When WC's total rounds to 0 ms, naming an WC phase as "busiest"
            -- reads as blame on a frame the share just exonerated. Same
            -- wording as the Help answer: the stutter came from something
            -- else. Raw English like the phase labels (line content is
            -- unlocalized diagnostic text; only the headers are L-wrapped).
            local busiest = ecMs < 0.5 and "something else" or tostring(e.dominant or "?")
            return string.format(
                "[%s] %.0f ms hitch - busiest: %s - WC %.0f of %.0f ms (%.0f%%)  |cff888888(bag %.0f / vendor %.0f / tooltip %.0f ms, %.0f FPS)|r",
                tostring(e.loggedAt or "?"),
                ms,
                busiest,
                ecMs,
                ms,
                pct,
                tonumber(e.bagMs) or 0,
                tonumber(e.vendorMs) or 0,
                tonumber(e.tipMs) or 0,
                tonumber(e.fps) or 0
            )
        end
        local lines = {}
        lines[#lines + 1] = L["Worst hitches this session (biggest first):"]
        for i = 1, #NS.worstSpikeLog do
            lines[#lines + 1] = fmtLine(NS.worstSpikeLog[i])
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = L["Most recent hitches (newest first):"]
        for i = 1, #WC_spikeLog do
            lines[#lines + 1] = fmtLine(WC_spikeLog[i])
        end
        body = table.concat(lines, "\n")
    end
    if NS.ShowCopyFrame then
        NS.ShowCopyFrame(L["WoWClearance: Frame Hitches"], body)
    else
        PrintNice(body)
    end
end

WC_compCache.bagUpdateFrame:SetScript("OnUpdate", function(self, elapsed)
    WC_compCache.bagUpdateAccum = WC_compCache.bagUpdateAccum + elapsed
    if WC_compCache.bagUpdateAccum < WC_compCache.BAG_UPDATE_DEBOUNCE_S then
        return
    end
    self:Hide()
    -- Frame-spike timing: the whole settled-burst flush (loot-delta scan
    -- included) is the "bag update" phase.
    local _spikeT0 = WC_prof and WC_prof()
    WC_StampEvent("bagUpdate")
    -- v2.75.0 (fresh-audit fix): resolve any deferred external-delete candidate
    -- now that the bag burst has settled and the cursor is likely clear.
    if WC_compCache.confirmPendingExternalDelete then
        WC_compCache.confirmPendingExternalDelete()
    end
    -- v2.63.0: the shared bag snapshot is now acquired LAZILY - the first
    -- scanner below that actually runs builds it via
    -- WC_compCache.acquireFlushSnapshot() and later scanners in this same
    -- frame reuse it. With every entries-consumer toggled off (the default
    -- config) no snapshot is built at all; the loot delta falls back to
    -- its cheap flat {itemID = count} walk.
    -- Burst settled. Fire the deferred work once.
    if WC_HandleAutoOpenContainers then
        WC_HandleAutoOpenContainers()
    end
    if WC_compCache.checkBagsForUpgrades then
        WC_compCache.checkBagsForUpgrades()
    end
    if WC_compCache.rearmProcessButton then
        WC_compCache.rearmProcessButton()
    end
    local pbp = _G["WoWClearanceOptionsProcessBags"]
    if pbp and pbp:IsShown() and WC_compCache.refreshProcessPanel then
        WC_compCache.refreshProcessPanel()
    end
    -- v2.30.x: repaint slot-border tints after the bag burst settles.
    -- The host bag UI's per-slot Update hook fires immediately during
    -- a move - while the slot is still locked - and NS.IsSellable
    -- bails on locked items, so the category resolver returns nil and
    -- the tint hides. For list-based categories (delete / account
    -- sell / character sell) the host's follow-up UpdateBorder often
    -- catches things up via the search-fade path, but rule-category
    -- items (which depend entirely on qualityPass via NS.IsSellable)
    -- don't always get a second pass. Refreshing here after the
    -- 120 ms idle ensures the locked state has cleared by the time
    -- the final paint runs. The refresh iterates only tracked buttons
    -- (weak-keyed registry) so the cost is one category lookup per
    -- visible bag slot - bounded by the user's open bag count. The repaint
    -- only: NS.RefreshSellBorders would also re-file every item in a
    -- category-based host bag UI, which is for setting changes.
    if WC_compCache.repaintSellBorders then
        WC_compCache.repaintSellBorders()
    end
    -- v2.44.0: auto-mark Resilience PvP gear for deletion. Runs from
    -- the same debounce so the BAG_UPDATE coalescing applies. The
    -- helper itself routes through WC_IsAddonEnabledForChar so the
    -- master Enable toggle vetoes consistently with every other
    -- destructive path.
    if WC_compCache.runAutoMarkResilience then
        WC_compCache.runAutoMarkResilience()
    end
    -- v2.60.0: auto-mark learned recipes with sellPrice 0 (Sell Known Recipes
    -- can't move them; they'd sit in bags forever). Same debounce + master-
    -- gate discipline as the two auto-marks above.
    if WC_compCache.runAutoMarkKnownUnsellableRecipes then
        WC_compCache.runAutoMarkKnownUnsellableRecipes()
    end
    -- Loot tracker bag-delta scan. Runs last in the flush.
    if WC_ScanLootDelta then
        WC_ScanLootDelta()
    end
    -- Drop the shared snapshot reference; the frame stamp already stops
    -- cross-frame reuse, this just lets the tables GC promptly.
    WC_compCache.flushSnapshot = nil
    if _spikeT0 then
        WC_spikePhase.bagupdate = WC_spikePhase.bagupdate + (WC_prof() - _spikeT0)
    end
end)

-- True iff the slotted item shows ITEM_OPENABLE in its tooltip and is not
-- locked. ITEM_OPENABLE is the standard Blizzard locale string ("<Right
-- Click to Open>" in enUS) used by every container, gift bag, and
-- treasure pouch in 3.3.5a. LOCKED is the same string that gets shown on
-- junkboxes / lockpickable containers; we exclude those because the user
-- needs a key or lockpicking skill to open them.
local function WC_IsOpenable(bag, slot)
    -- v2.59.0: per-itemID cache. "never" skips the slot with zero API calls.
    -- v2.59.3 fix (Serv report, lockbox auto-open loop): we NO LONGER cache
    -- "openable" per-itemID. Bug scenario: rogue Pick Lock unlocks lockbox
    -- A of itemID X, cache stamps X="openable", another still-locked
    -- lockbox of itemID X in bags then skipped the tooltip re-scan and
    -- relied on GetContainerItemInfo's `locked` field. That field is
    -- unreliable for never-picked lockboxes in 3.3.5a - it flips true only
    -- when the item is mid-cast / mid-swap, not "requires unlock". So the
    -- still-locked box passed the openable check, UseContainerItem fired,
    -- server refused, 0.4s retry loop spammed the "item is locked" chat
    -- error. The tooltip LOCKED line is the only reliable per-instance
    -- signal, so always do the tooltip scan.
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return false
    end
    local cached = WC_compCache.openableCache[itemID]
    if cached == "never" then
        return false
    end
    local cInfo = C_Container.GetContainerItemInfo(bag, slot)
    local itemCount = cInfo and cInfo.stackCount
    local locked = cInfo and cInfo.isLocked
    if not itemCount or itemCount <= 0 or locked then
        return false
    end
    -- v2.38.3: SetOwner-before-SetBagItem via the shared helper.
    WC_compCache.scanBagItem(bag, slot)
    -- Cap iterations: tooltips can technically grow long; 30 lines is more
    -- than any container we care about will produce.
    local sawAnyLine = false
    for i = 1, 30 do
        local line = WC_compCache.scanLines[i]
        if not line then
            break
        end
        local txt = line:GetText()
        if txt and txt ~= "" then
            sawAnyLine = true
        end
        if txt == LOCKED then
            -- Do NOT return before checking for ITEM_OPENABLE elsewhere in
            -- the tooltip - keep scanning. But: a "Locked" line is
            -- definitive: this instance is not openable right now. Never
            -- cache "openable" for the itemID either (a different instance
            -- of same itemID could be locked - the cache would poison the
            -- next call). Just return false.
            return false
        end
        if txt == ITEM_OPENABLE then
            -- Deliberately NOT caching "openable" per the v2.59.3 fix
            -- comment above.
            return true
        end
    end
    -- Only negative-cache when the tooltip actually rendered: an uncached
    -- item (client data still warming up) produces an empty tooltip, and
    -- caching "never" from that would permanently skip a real container.
    if sawAnyLine then
        WC_compCache.openableCache[itemID] = "never"
    end
    return false
end

-- Auto-open driver. Walks bags, opens the first openable item, and recurses
-- via WC_Delay if more remain. WC_autoOpenInFlight coalesces BAG_UPDATE
-- bursts so we never stack `UseContainerItem` calls within the inter-item
-- delay. Reassigns the forward-declared `WC_HandleAutoOpenContainers` local
-- (declared above near the v2.24.0 BAG_UPDATE debounce frame, so the
-- frame's OnUpdate closure can capture this name). Body lives in this file
-- because it references file-scope locals WC_IsOpenable + WC_autoOpenInFlight.
function WC_HandleAutoOpenContainers()
    -- Set only by this function's own 0.4 s retry; read here so an early
    -- return below can never leave it armed for an unrelated call.
    local isRetry = WC_compCache.autoOpenRetry
    WC_compCache.autoOpenRetry = nil
    if not DB or not DB.autoOpenContainers then
        return
    end
    if WC_compCache.vendorRunning then
        return
    end
    if InCombatLockdown() then
        -- Session-scoped one-shot deferral announce. The earlier per-combat
        -- variant re-fired the message on every combat instance that
        -- happened to have a BAG_UPDATE-during-combat with openable items
        -- in bag; rogues leveling with lockboxes in bag (continuous kill-
        -- mob-combat cycle) saw the line spam. The flag is now NEVER
        -- cleared at PLAYER_REGEN_ENABLED, so a user sees the deferral
        -- notice at most once per /reload. The driver still resumes
        -- post-combat through PLAYER_REGEN_ENABLED's WC_HandleAutoOpenContainers
        -- call; the message is just discoverability, not load-bearing.
        --
        -- Short-circuit openable scan: walk bags but bail on the first
        -- openable, so the worst case (no openables in bag) is bounded by
        -- a single bag walk per /reload. Without this gate, the announce
        -- would fire on every combat-during-BAG_UPDATE event regardless of
        -- whether anything is actually deferred.
        if not WC_compCache.combatDeferredAnnounced then
            WC_compCache.combatDeferredAnnounced = true
            local hasOpenable = false
            local snap = WC_compCache.acquireFlushSnapshot()
            for i = 1, #snap.entries do
                local e = snap.entries[i]
                if WC_IsOpenable(e.bag, e.slot) then
                    hasOpenable = true
                    break
                end
            end
            if hasOpenable then
                PrintNice(L["Containers deferred until out of combat."])
            end
        end
        return
    end
    if WC_autoOpenInFlight then
        return
    end
    if not WC_IsAddonEnabledForChar() then
        return
    end
    -- v2.59.0: iterate the shared flush snapshot (or a fresh one when
    -- called outside the flush, e.g. from PLAYER_REGEN_ENABLED or the
    -- post-open WC_Delay retry). WC_IsOpenable re-reads the live slot, so
    -- a snapshot entry that has moved just resolves to "not openable".
    -- Progress check: the 0.4 s retry stops when it would use the very
    -- stack the last pass used (full bags, or a cast still running).
    -- Without it the retry re-fired every 0.4 s until bag space freed up.
    -- The next settled bag change runs a fresh pass.
    local snap = WC_compCache.acquireFlushSnapshot()
    for i = 1, #snap.entries do
        local e = snap.entries[i]
        if WC_IsOpenable(e.bag, e.slot) then
            local key = e.bag .. ":" .. e.slot .. ":" .. tostring(e.itemID) .. ":" .. tostring(e.count)
            if isRetry and key == WC_compCache.autoOpenLastKey then
                return
            end
            WC_compCache.autoOpenLastKey = key
            WC_autoOpenInFlight = true
            UseContainerItem(e.bag, e.slot)
            -- 0.4 s gives the prior open's cast room to finish before we
            -- trigger the next one. Tunable; lower would feel snappier
            -- but risks interrupting the previous use.
            WC_Delay(0.4, function()
                WC_autoOpenInFlight = false
                WC_compCache.autoOpenRetry = true
                WC_HandleAutoOpenContainers()
            end)
            return
        end
    end
end

-- v2.10.0: bind-type detection for the per-rarity bindFilter rule. Returns
-- "boe", "bop", or "any".
--
-- Items with no bind type at all (consumables, reagents, trade goods,
-- quest items) return "any" - they aren't subject to BoE-only or BoP-only
-- filters, which is the user-intended behaviour: "Sell BoE only" should
-- not sweep up reagents.
--
-- Forever: bound state is read PER COPY from the slot, never cached. The
-- old itemID cache treated "Soulbound" as immutable, so one worn copy of a
-- BoE item made every unworn copy read "bop" for the rest of the session -
-- and a "BoP only" filter would then sell a tradeable BoE. Only the item's
-- bind TYPE (GetItemInfo's 14th return, Enum.ItemBind) is fixed per itemID,
-- so that is all bindCache holds now. No tooltip scan.
function WC_compCache.itemBindType(itemID)
    local cached = WC_compCache.bindCache[itemID]
    if cached then
        return cached
    end
    local bindType = select(14, GetItemInfo(itemID))
    if bindType == nil then
        return "any" -- not cached yet; do not store a guess
    end
    local result = (bindType == 1 and "bop") or (bindType == 2 and "boe") or "any"
    WC_compCache.bindCache[itemID] = result
    return result
end

function WC_compCache.getBindType(bag, slot)
    local cInfo = C_Container.GetContainerItemInfo(bag, slot)
    if not (cInfo and cInfo.itemID) then
        return "any"
    end
    if cInfo.isBound then
        return "bop"
    end
    return WC_compCache.itemBindType(cInfo.itemID)
end

-- v2.10.0: bind-type detection that reads a live tooltip's lines instead
-- of scanning a freshly-built WC_scanTooltip via SetBagItem. Used by
-- WC_AnnotateTooltip so the bind-filter rule can colour-code an item the
-- user is hovering when we don't have a (bag, slot) pair (the annotation
-- entry point is itemLink, not a container slot). Reads the cache first
-- so a previously-scanned bag item never re-scans; otherwise walks the
-- live tooltip's TextLeft lines for the same client-localized bind
-- globals the bag-scan path matches (v2.69.0; was enUS literals). Stamps
-- the cache on a successful result so a subsequent WC_IsSellable call on
-- the same itemID stays cheap.
--
-- Forever: the hovered copy's lines are per-copy truth, so they are read
-- every time and NOT written to bindCache (that was the cross-copy
-- poisoning path). With no bind line, fall back to the item's bind type.
function WC_compCache.getBindTypeFromTooltip(tooltip, itemID)
    if not tooltip or not tooltip.NumLines or not tooltip.GetName then
        return "any"
    end
    local tname = tooltip:GetName()
    if not tname then
        return "any"
    end
    local n = tooltip:NumLines() or 0
    local result = "any"
    local bopLine = ITEM_BIND_ON_PICKUP or "Binds when picked up"
    local sbLine = ITEM_SOULBOUND or "Soulbound"
    local boeLine = ITEM_BIND_ON_EQUIP or "Binds when equipped"
    -- Start at line 2: line 1 is the item name; bind line is always one of
    -- the early header lines (line 2 or 3 in 3.3.5a item tooltips).
    for i = 2, n do
        local fs = _G[tname .. "TextLeft" .. i]
        if fs and fs.GetText then
            local txt = fs:GetText()
            if txt then
                if txt == bopLine or txt == sbLine then
                    result = "bop"
                    break
                elseif txt == boeLine then
                    result = "boe"
                    break
                end
            end
        end
    end
    if result == "any" and itemID then
        return WC_compCache.itemBindType(itemID)
    end
    return result
end

-- The item-protection detection clusters
-- all live in WoWClearance_Protection.lua (Stage 4 of the file split,
-- see docs/CODE_REVIEW.md item 4). Every helper is attached to
-- WC_compCache, so call sites elsewhere in this file already resolve
-- through the shared upvalue and need no changes.

-- v2.21.0: pre-flight bag-space check used by the Fast Loot queue
-- before each LootSlot call. Returns true if the item can fit (free
-- slot in a compatible bag, OR room in an existing stack). False
-- means bags are too full - the queue defers, and the loot window
-- stays open for the player to deal with manually. Money and items
-- with no link (currency drops) always return true since they don't
-- consume bag space.
function WC_compCache.canLootItem(link)
    if not link then
        return true
    end
    local itemFamily = GetItemFamily(link) or 0
    local totalFree = 0
    for i = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        local free, bagFamily = GetContainerNumFreeSlots(i)
        bagFamily = bagFamily or 0
        -- bagFamily 0 = generic bag, accepts anything. Non-zero =
        -- specialty bag (quiver, soul shard pouch, etc.) - only
        -- accepts items whose family bit matches.
        if free and (bagFamily == 0 or (itemFamily and bit.band(itemFamily, bagFamily) > 0)) then
            totalFree = totalFree + free
        end
    end
    if totalFree > 0 then
        return true
    end
    -- Bags full but check if the item can stack into an existing
    -- partial stack of the same item.
    local have = GetItemCount(link) or 0
    if have > 0 then
        local _, _, _, _, _, _, _, stackSize = GetItemInfo(link)
        if stackSize and stackSize > 1 then
            local remainder = have % stackSize
            if remainder > 0 then
                return true
            end
        end
    end
    return false
end

-- The Process Bags engine (Disenchant / Mill / Prospect / Lockpick
-- eligibility predicates + spell IDs + buildProcessSummary bag walk)
-- lives in WoWClearance_Process.lua after Stage 7 of the file split.
-- The Process Bags PANEL (rearmProcessButton, refreshProcessPanel,
-- updateProcessSelection, skipProcessTarget + the SecureActionButton
-- UI) stays in this file for Stage 8 because it pulls in a dense web
-- of UI-building helpers. See docs/CODE_REVIEW.md item 4.


-- v2.21.0: Fast Loot driver. Replaces v2.16.0's tight-loop drain
-- (which fired N LootSlot calls in one frame and risked anti-flood
-- disconnect on busy 3.3.5a private servers) with a queue + OnUpdate
-- throttle: on LOOT_READY, the slot indices are pushed into
-- WC_lootQueue.slots and the OnUpdate driver below drains one slot
-- every WC_LOOT_QUEUE_DELAY seconds. Each pop re-validates the slot
-- and pre-checks bag space before calling LootSlot. The 0.3 s
-- LOOT_READY debounce from v2.16.0 is gone - re-populating the queue
-- on a fresh LOOT_READY is idempotent (wipe + refill).
--
-- The "auto-loot is effectively on right now?" check is unchanged
-- from v2.16.0: autoLootDefault is the CVar setting, AUTOLOOTTOGGLE
-- is the modifier key (typically Shift) that inverts auto-loot for
-- one interaction. When the CVar's value matches whether the
-- modifier is held, auto-loot is OFF for this loot (user is
-- explicitly opting OUT - or didn't opt IN); when they differ,
-- auto-loot is ON. Skip when off so the user keeps the standard
-- loot window for selective looting.
--
-- BoP-bind auto-confirm (also v2.16.0) is unchanged: the
-- hooksecurefunc on LootSlot fires whether the call comes from the
-- old tight loop or the new queue. Fast Loot users still don't see
-- the bind popup.
local function WC_HandleLootReady()
    if not DB or not DB.fastLoot then
        return
    end
    if GetCVarBool("autoLootDefault") == IsModifiedClick("AUTOLOOTTOGGLE") then
        return
    end
    local n = GetNumLootItems()
    if n == 0 then
        return
    end
    local q = WC_compCache.lootQueue
    -- Lazy-build the OnUpdate driver frame on first LOOT_READY. Lives
    -- for the rest of the session; cheap when DB.fastLoot is off
    -- because the OnUpdate body bails on isProcessing == false.
    if not q.frame then
        q.frame = CreateFrame("Frame")
        q.frame:SetScript("OnUpdate", function(self)
            local qs = WC_compCache.lootQueue
            if not qs.isProcessing then
                return
            end
            if (GetTime() - qs.lastLootAt) < qs.delay then
                return
            end
            if #qs.slots == 0 then
                qs.isProcessing = false
                return
            end
            local slotIdx = qs.slots[1]
            table.remove(qs.slots, 1)
            -- Per-slot revalidation: server-side loot state can
            -- desync from the snapshot at LOOT_READY (a slot can
            -- become invalid before we reach it).
            -- Mainline order: texture, name, quantity, currencyID, quality,
            -- locked (LootFrame.lua:228). The 3.3.5a 5th return is now quality.
            local _, _, _, _, _, locked = GetLootSlotInfo(slotIdx)
            if locked then
                -- BoP / roll item: leave for player. The existing
                -- BoP-bind auto-confirm hook only fires AFTER a
                -- successful LootSlot, so skipping here leaves the
                -- loot window open for manual handling.
                return
            end
            -- Bag-space pre-check: avoids ERR_INV_FULL spam in the
            -- chat frame when bags are full.
            local link = GetLootSlotLink(slotIdx)
            if link and not WC_compCache.canLootItem(link) then
                return
            end
            qs.lastLootAt = GetTime()
            LootSlot(slotIdx)
        end)
    end
    wipe(q.slots)
    for i = n, 1, -1 do
        q.slots[#q.slots + 1] = i
    end
    q.isProcessing = true
    q.lastLootAt = 0
end

-- ===========================================================================

-- ===========================================================================
-- Right-click bag-item context menu (Alt+Right-Click)
-- ---------------------------------------------------------------------------
-- Adds an WoWClearance popup to bag items: Whitelist (Character/Account),
-- Blacklist, Deletion List, Sell Now. Triggered by Alt+Right-Click so it
-- doesn't override the default right-click-to-use behaviour. We replace
-- (rather than hooksecurefunc) ContainerFrameItemButton_OnClick because we
-- need to *suppress* the default action on our modifier combo, not just
-- append.
--
-- Implementation: a hand-built popup frame with regular Buttons. We avoid
-- UIDropDownMenu in "MENU" mode because 3.3.5a's implementation has a known
-- issue where the click handlers on menu items silently no-op when parented
-- to a custom frame.

local WC_CTX_PANEL_FOR = {
    whitelist = "WoWClearanceOptionsWhitelist",
    accountWhitelist = "WoWClearanceOptionsAccountWhitelist",
    blacklist = "WoWClearanceOptionsBlacklist",
    deleteList = "WoWClearanceOptionsDeletion",
}

-- v2.10.0: optional `quiet` flag suppresses the success / dedupe / conflict
-- chat lines and returns true on a successful add, false on dedupe, conflict
-- or unresolved list. Used by the auto-protect-equipped one-shot sync (which
-- prints a single summary line for the whole 19-slot walk) and by the
-- PLAYER_EQUIPMENT_CHANGED reactive handler (which prints one targeted line
-- per add). The default-mode call sites are unchanged - they pass nil for
-- quiet and ignore the return value.
-- v2.51.0: session-scoped silent-refusal log. WC_AddItemToList's cross-list
-- conflict guard refuses adds silently when called with quiet=true (the
-- auto-protect sync path uses quiet=true, so a Keep-List add for an
-- equipped item that's already on Delete List returns false with zero
-- diagnostic trail). That silent-refusal path was the root cause of the
-- Stickybackpack shirt-loss bug (v2.50.2). Ring buffer preserves the
-- last N refusals so /wc bugreport surfaces them. Session-local, wiped
-- on /reload. Ring shifts oldest out on overflow.
local WC_SILENT_REFUSAL_LOG_MAX = 15
local WC_silentRefusalLog = {}
WC_LogSilentRefusal = function(itemID, targetList, conflictList, caller)
    if not itemID then
        return
    end
    if #WC_silentRefusalLog >= WC_SILENT_REFUSAL_LOG_MAX then
        table.remove(WC_silentRefusalLog, 1)
    end
    local _, link = GetItemInfo(itemID)
    WC_silentRefusalLog[#WC_silentRefusalLog + 1] = {
        itemID = itemID,
        itemName = link or ("item:" .. tostring(itemID)),
        targetList = targetList or "?",
        conflictList = conflictList or "?",
        caller = caller or "?",
        loggedAt = date("%H:%M:%S"),
    }
end
NS.silentRefusalLog = WC_silentRefusalLog

local function WC_AddItemToList(setName, itemID, label, quiet)
    if not itemID then
        return false
    end
    local t = WC_GetListTable(setName)
    if not t then
        if not quiet then
            PrintNicef(L["|cffff4444Could not resolve list: %s|r"], tostring(setName))
        end
        return false
    end
    local itemName = GetItemInfo(itemID) or ("ItemID:" .. itemID)
    if t[itemID] then
        if not quiet then
            PrintNicef(L["|cffaaaaaa%s already on %s.|r"], itemName, label)
        end
        return false
    end
    -- Cross-intent conflict guard. Refuse adds that would create a multi-list
    -- conflict; the user must explicitly remove the item from the other list
    -- first. Same-intent scopes (character + account whitelist) do not trip
    -- this and the add proceeds normally.
    local conflictName = WC_FindAddConflict(itemID, setName)
    if conflictName then
        if not quiet then
            PrintNicef(L["|cffff8888%s is already on %s. Remove it from there first.|r"], itemName, conflictName)
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
        else
            -- v2.51.0: silent quiet-mode refusals go to the diagnostic
            -- ring buffer so /wc bugreport can surface them. The caller
            -- (equipped-sync, upgrade-scan, equipment-set-sync,
            -- protection-refresh) gets a false return and no chat noise;
            -- the log is the audit trail.
            WC_LogSilentRefusal(itemID, setName, conflictName, label)
        end
        return false
    end
    t[itemID] = true
    if not quiet then
        PrintNicef(L["Added |cffb6ffb6%s|r to %s."], itemName, label)
    end
    -- Refresh the corresponding settings panel if it's been opened.
    local panelName = WC_CTX_PANEL_FOR[setName]
    if panelName then
        local p = _G[panelName]
        if p and p.listUI then
            p.listUI:Refresh()
        end
    end
    -- Any list mutation can change a bag slot's would-sell verdict, so
    -- repaint the slot-border tints across already-decorated buttons. The
    -- helper is a no-op when the toggle is off or no buttons are tracked.
    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end
    return true
end
-- Exposed to split files. Stage 8d uses NS.AddItemToList from the bag
-- context menu's "Add to ... list" row click handlers.
NS.AddItemToList = WC_AddItemToList

-- v2.13.0 ElvUI bag buttons: cursor-drop helper. Called by the bag-frame
-- buttons' OnReceiveDrag handler. Reads the cursor item via GetCursorInfo
-- (returns "item", itemID, itemLink for items), clears the cursor, and
-- routes through WC_AddItemToList so cross-list conflict guards and
-- duplicate checks apply. The label is the human-readable list name used
-- in the chat reply ("Sell List", "Keep List", "Delete List").
-- Hung off WC_compCache (rather than a file-scope local) to stay under
-- Lua 5.1's 200-locals-per-main-chunk cap.
function WC_compCache.handleItemDrop(setName, label)
    local cursorType, cursorID, cursorLink = GetCursorInfo()
    if cursorType ~= "item" then
        ClearCursor()
        return
    end
    local id = (type(cursorID) == "number") and cursorID or (cursorLink and tonumber(cursorLink:match("item:(%d+)")))
    ClearCursor()
    if not id then
        return
    end
    -- v2.13.3: removed redundant panel refresh - WC_AddItemToList already
    -- refreshes the panel via the same WC_CTX_PANEL_FOR lookup. The label
    -- arg is what the user sees in the chat reply.
    WC_AddItemToList(setName, id, label)
end

-- v2.13.0 ElvUI bag buttons: opens the WC options frame and jumps straight
-- to the panel that owns the requested list. Mirrors the slash-command's
-- double-call pattern (3.3.5a quirk: the first call only registers the
-- category, the second actually focuses it). Hung off WC_compCache so it
-- doesn't consume a main-chunk local slot.
function WC_compCache.openPanelToList(setName)
    local panelName = WC_CTX_PANEL_FOR and WC_CTX_PANEL_FOR[setName]
    if not panelName then
        return
    end
    NS.OpenOptionsPanel(panelName)
end

-- v2.13.0 ElvUI bag buttons. Three small icon buttons attached to the
-- top-right of ElvUI's main bag frame in Sell | Keep | Delete order.
-- Each button:
--   - Drag-drop: adds the cursor item to the corresponding WC list,
--     routed through WC_compCache.handleItemDrop -> WC_AddItemToList so cross-list
--     conflicts and dedupe checks apply.
--   - Right-click: jumps the WC options frame to the relevant list panel.
--   - Sell button only: left-click at a merchant fires a manual sell run
--     via the existing WoWClearance_ForceSell entry point.
-- Audience: ElvUI users on Project Ebonhold (a meaningful slice of the
-- player base). Non-ElvUI users see no change; the gate is the existence
-- of _G.ElvUI_ContainerFrame at call time. Idempotent: a guard on
-- WC_compCache.elvuiButtonsBuilt makes a second call cheap if anything
-- ever calls this twice.
function WC_compCache.buildElvUIBagButtons()
    if WC_compCache.elvuiButtonsBuilt then
        return
    end
    local bagFrame = _G.ElvUI_ContainerFrame
    if not bagFrame then
        return
    end
    WC_compCache.elvuiButtonsBuilt = true

    -- Shared backdrop for the three buttons. Subtle dark fill with a 1px
    -- mid-grey edge that brightens on hover; matches a sibling addon's
    -- bag buttons so users running both get a consistent visual.
    local function applyBackdrop(btn)
        btn:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            tile = false,
            tileSize = 16,
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        btn:SetBackdropColor(0, 0, 0, 0.6)
        btn:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    end

    -- Mints a button with shared chrome. iconHover is the (r,g,b) the icon
    -- texture vertex-tints to on hover; matches WC's tooltip color scheme
    -- (green for sell, orange for keep, red for delete).
    local function makeButton(name, parent, iconTexture, hoverR, hoverG, hoverB)
        local btn = CreateFrame("Button", name, parent, "BackdropTemplate")
        btn:SetSize(20, 20)
        applyBackdrop(btn)
        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 2, -2)
        icon:SetPoint("BOTTOMRIGHT", -2, 2)
        icon:SetTexture(iconTexture)
        if iconTexture:find("Icons\\") then
            -- Icon textures need the 0.07/0.93 inset to crop the default
            -- Blizzard border; UI-GroupLoot textures don't.
            icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        end
        btn._icon = icon
        btn._hoverR, btn._hoverG, btn._hoverB = hoverR, hoverG, hoverB
        btn:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
            self:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
            self._icon:SetVertexColor(1, 1, 1)
        end)
        return btn
    end

    -- Sell button (whitelist) - leftmost. Gold coin icon. Drag adds to
    -- whitelist; right-click opens Whitelist panel; left-click at a
    -- merchant triggers WoWClearance_ForceSell.
    local sellBtn =
        makeButton("WoWClearance_ElvUISellBtn", bagFrame, "Interface\\Icons\\INV_Misc_Coin_01", 0.71, 1.0, 0.71)
    sellBtn:SetPoint("TOPRIGHT", bagFrame, "TOPRIGHT", -98, -4)
    sellBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine(L["|cff66ccffWoWClearance:|r |cffb6ffb6Sell|r"], 0.71, 1, 0.71)
        GameTooltip:AddLine(L["Drop item to add to Sell List."], 1, 1, 1)
        GameTooltip:AddLine(L["Click at a vendor to start selling now."], 0.7, 0.7, 0.7)
        GameTooltip:AddLine(L["Right-click to open the Sell List panel."], 0.7, 0.7, 0.7)
        if not (MerchantFrame and MerchantFrame:IsShown()) then
            GameTooltip:AddLine(L["Not at a vendor."], 1, 0.4, 0.4)
        end
        GameTooltip:Show()
        self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        self._icon:SetVertexColor(self._hoverR, self._hoverG, self._hoverB)
    end)
    sellBtn:RegisterForDrag("LeftButton")
    sellBtn:RegisterForClicks("AnyUp")
    sellBtn:SetScript("OnReceiveDrag", function()
        WC_compCache.handleItemDrop("whitelist", "Sell List")
    end)
    sellBtn:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            WC_compCache.openPanelToList("whitelist")
        elseif CursorHasItem() then
            WC_compCache.handleItemDrop("whitelist", "Sell List")
        elseif WoWClearance_ForceSell then
            WoWClearance_ForceSell()
        end
    end)

    -- Keep button (blacklist) - middle. Shield icon (semantically clearer
    -- than AutoDelete's chocolate box for "protected"). Drag adds to
    -- Blacklist (Keep); right-click opens the Blacklist panel.
    local keepBtn =
        makeButton("WoWClearance_ElvUIKeepBtn", bagFrame, "Interface\\Icons\\INV_Shield_06", 1.0, 0.78, 0.30)
    keepBtn:SetPoint("LEFT", sellBtn, "RIGHT", 4, 0)
    keepBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine(L["|cff66ccffWoWClearance:|r |cffffb84dKeep|r"], 1, 0.78, 0.30)
        GameTooltip:AddLine(L["Drop item to add to Keep List."], 1, 1, 1)
        GameTooltip:AddLine(L["Items here are never auto-sold or auto-deleted."], 0.7, 0.7, 0.7)
        GameTooltip:AddLine(L["Right-click to open the Keep List panel."], 0.7, 0.7, 0.7)
        GameTooltip:Show()
        self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        self._icon:SetVertexColor(self._hoverR, self._hoverG, self._hoverB)
    end)
    keepBtn:RegisterForDrag("LeftButton")
    keepBtn:RegisterForClicks("AnyUp")
    keepBtn:SetScript("OnReceiveDrag", function()
        WC_compCache.handleItemDrop("blacklist", "Keep List")
    end)
    keepBtn:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            WC_compCache.openPanelToList("blacklist")
        elseif CursorHasItem() then
            WC_compCache.handleItemDrop("blacklist", "Keep List")
        end
    end)

    -- Delete button - rightmost. Red X icon (Blizzard's loot-pass texture,
    -- no icon-inset crop needed). Drag adds to delete list; right-click
    -- opens the Delete List panel.
    local delBtn = makeButton(
        "WoWClearance_ElvUIDeleteBtn",
        bagFrame,
        "Interface\\Buttons\\UI-GroupLoot-Pass-Up",
        1.0,
        0.30,
        0.30
    )
    delBtn:SetPoint("LEFT", keepBtn, "RIGHT", 4, 0)
    delBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine(L["|cff66ccffWoWClearance:|r |cffff4444Delete|r"], 1, 0.3, 0.3)
        GameTooltip:AddLine(L["Drop item to add to Delete List."], 1, 1, 1)
        GameTooltip:AddLine(L["Delete Next removes these, one per press."], 0.7, 0.7, 0.7)
        GameTooltip:AddLine(L["Right-click to open the Delete List panel."], 0.7, 0.7, 0.7)
        GameTooltip:Show()
        self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        self._icon:SetVertexColor(self._hoverR, self._hoverG, self._hoverB)
    end)
    delBtn:RegisterForDrag("LeftButton")
    delBtn:RegisterForClicks("AnyUp")
    delBtn:SetScript("OnReceiveDrag", function()
        WC_compCache.handleItemDrop("deleteList", "Delete List")
    end)
    delBtn:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            WC_compCache.openPanelToList("deleteList")
        elseif CursorHasItem() then
            WC_compCache.handleItemDrop("deleteList", "Delete List")
        end
    end)
end

-- v2.37.4 (audit issue #4): side-meta tags shown on list-panel rows.
-- Those tables were stamped at add-time + on tooltip backfill but never
-- cleared on remove, so orphan entries accumulated over time. Clears both
-- meta entries when the itemID is absent from every list this character
-- can see (per-character sell/keep/delete + account sell). Alt characters
-- that still have the itemID on one of their lists will see the tag get
-- re-stamped on next tooltip hover via the WC_AnnotateTooltip backfill, so
-- this is safe to call from a single character's remove path.
local function WC_PruneSideMetaForItem(itemID)
    if not itemID or not ADB then
        return
    end
    if DB then
        if (DB.whitelist and DB.whitelist[itemID])
            or (DB.blacklist and DB.blacklist[itemID])
            or (DB.deleteList and DB.deleteList[itemID])
        then
            return
        end
    end
    if ADB.whitelist and ADB.whitelist[itemID] then
        return
    end
end
NS.PruneSideMetaForItem = WC_PruneSideMetaForItem

local function WC_RemoveItemFromList(setName, itemID, label)
    if not itemID then
        return
    end
    local t = WC_GetListTable(setName)
    if not t or not t[itemID] then
        return
    end
    t[itemID] = nil
    WC_PruneSideMetaForItem(itemID)
    -- v2.10.0: keep the auto-protected source map in lockstep so the
    -- tooltip annotation can never claim "(auto-protected: equipped)" for
    -- an item the user has explicitly removed. Cleared regardless of
    -- which list we removed from; blacklistAuto entries are only ever
    -- valid against the per-character Blacklist (Keep), but the no-op
    -- branch is fast on the other lists.
    if DB and type(DB.blacklistAuto) == "table" then
        DB.blacklistAuto[itemID] = nil
    end
    local itemName = GetItemInfo(itemID) or ("ItemID:" .. itemID)
    PrintNicef(L["Removed |cffb6ffb6%s|r from %s."], itemName, label)
    -- Refresh the corresponding settings panel if it's been opened.
    local panelName = WC_CTX_PANEL_FOR[setName]
    if panelName then
        local p = _G[panelName]
        if p and p.listUI then
            p.listUI:Refresh()
        end
    end
    -- Any list mutation can change a bag slot's would-sell verdict, so
    -- repaint the slot-border tints across already-decorated buttons. The
    -- helper is a no-op when the toggle is off or no buttons are tracked.
    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end
end
-- Exposed to split files. Stage 8d uses NS.RemoveItemFromList from the
-- bag context menu's "Remove from ... list" row click handlers.
NS.RemoveItemFromList = WC_RemoveItemFromList

-- v2.10.0: equipped-gear protection. Slot 19 (tabard) is cosmetic-only and
-- skipped. Slot 4 (shirt) USED to be skipped too but v2.50.2 pulled it out
-- of the skip: some realms put stat rolls onto shirts (Ironhide
-- IV etc.), so shirts are real gear that must land on the Keep List when
-- worn - otherwise the auto-mark scans see a soulbound
-- shirt in bags with no Keep signal and writes it to deleteList. Reported
-- by Bizzaro on behalf of Stickybackpack against v2.50.1. Helpers hang off
-- WC_compCache (same pattern as the v2.9.2 PROF_LOOT_SPELLS set) to keep
-- this addon under Lua 5.1's 200-local cap.
-- WC-TRAP: do NOT re-add "slot == 4" to the skip below. On PE the "cosmetic
-- only" assumption is false for shirts, and the auto-mark scan will destroy
-- stat shirts if the equipped-protection path skips them.

-- Auto-protect a single equipped slot. Routes through WC_AddItemToList in
-- quiet mode so the success / dedupe / conflict chat lines are suppressed
-- during the 19-slot one-shot sync; the reactive PLAYER_EQUIPMENT_CHANGED
-- caller prints one targeted line per add. Stamps DB.blacklistAuto on a
-- successful add so WC_AnnotateTooltip can attach the "(auto-protected:
-- equipped)" suffix at hover time. Returns true iff the slot was newly
-- added to the whitelist.
function WC_compCache.protectEquipSlot(slot)
    if not slot or slot == 19 then
        return false
    end
    local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
    if not link then
        return false
    end
    local id = tonumber(link:match("item:(%d+)"))
    if not id then
        return false
    end
    -- v2.10.0: equipped gear lands on the BLACKLIST (Keep / do-not-sell)
    -- list, not the Whitelist (sell list). The Whitelist is the list of
    -- items the addon WILL sell - adding equipped gear there would mean
    -- "vendor everything I'm wearing the moment I swap to anything else".
    -- Blacklist is the protected list; that's the correct semantic for
    -- "remember what I'm wearing and don't auto-sell it".
    DB.blacklistAuto = DB.blacklistAuto or {}
    if WC_AddItemToList("blacklist", id, "Keep List", true) then
        -- v2.12.0: tag the entry with its origin so the tooltip can
        -- show "(Worn)" vs "(Upgrade)" instead of a generic
        -- Auto-Protected label. Legacy boolean-true entries from
        -- v2.10.0 / v2.11.0 fall back to the generic label at hover
        -- time.
        DB.blacklistAuto[id] = "equipped"
        return true
    elseif DB.blacklistAuto[id] then
        -- v2.12.0: item was already on the blacklist with an existing
        -- auto-tag ("upgrade" from autoProtectUpgrades, or "set" from
        -- v2.13.0's Equipment Manager protection). The user has now
        -- explicitly equipped it, so the more accurate tag is
        -- "equipped" - refresh in place. Manual blacklist entries
        -- (where blacklistAuto[id] is nil) stay untouched - the user
        -- added those deliberately.
        DB.blacklistAuto[id] = "equipped"
        return false
    end
    return false
end

-- One-shot sync helper. Called by the Blacklist (Keep) panel's
-- "Auto-protect equipped gear" checkbox when the user flips it from off to
-- on. Walks every gear slot once and prints a single summary line for the
-- whole batch. The reactive PLAYER_EQUIPMENT_CHANGED handler covers all
-- subsequent equipment swaps; this one-shot is only needed at toggle time.
function WC_compCache.syncEquipped()
    local added = 0
    for slot = 1, 19 do
        if WC_compCache.protectEquipSlot(slot) then
            added = added + 1
        end
    end
    if added > 0 then
        PrintNicef(L["|cffb6ffb6Added %d equipped item%s to your Keep List.|r"], added, added == 1 and "" or "s")
    else
        PrintNice(L["|cffaaaaaaYour equipped gear is already on the Keep List.|r"])
    end
end

-- v2.13.0 Equipment Manager protection. Adds an item from a saved equipment
-- set to the Keep list with origin tag "set". Routes through WC_AddItemToList
-- so cross-list conflicts and duplicate guards apply. Items already equipped
-- (tag "equipped") and looted upgrades (tag "upgrade") keep their existing
-- tag - "set" is the weakest tag and shouldn't downgrade more specific
-- ones. Manual blacklist entries (no auto-tag) are not touched. Returns
-- true iff a new entry was added.
function WC_compCache.protectEquipmentSetItem(itemID)
    -- The `> 1` guard dates from 3.3.5a, where GetEquipmentSetItemIDs filled a
    -- buffer using 0 for "slot empty" and 1 for "ignore this slot". On Forever
    -- (measured 2026-09-18) C_EquipmentSet.GetItemIDs instead OMITS unused
    -- slots, and the sample contained no 0 or 1 values at all. The guard is
    -- kept because that sample had no ignored slots, so whether an ignored
    -- slot still yields 1 here is unmeasured - and itemID 1 is not
    -- auto-protectable equipment either way, so the check costs nothing.
    if not itemID or itemID <= 1 then
        return false
    end
    DB.blacklistAuto = DB.blacklistAuto or {}
    if WC_AddItemToList("blacklist", itemID, "Keep List", true) then
        DB.blacklistAuto[itemID] = "set"
        return true
    end
    -- Already on the blacklist. Do not promote or downgrade an existing
    -- tag - "equipped" / "upgrade" are more specific and should win.
    return false
end

-- One-shot sync helper. Called by the Blacklist (Keep) panel's
-- "Auto-protect equipment-manager sets" checkbox when the user flips it from
-- off to on, and by the EQUIPMENT_SETS_CHANGED reactive handler. Walks every
-- saved equipment set, dedupes itemIDs across sets via a session-local seen
-- map, and stamps each onto the Keep list. `silent` skips the chat summary -
-- used by the live EQUIPMENT_SETS_CHANGED path so set-edits don't spam.
--
-- PORT STATUS (work item 4/6): ported to the C_EquipmentSet namespace.
--
-- The 3.3.5a API was GetNumEquipmentSets / GetEquipmentSetInfo(index) /
-- GetEquipmentSetItemIDs(name, buf).
--
-- MEASURED on Forever (probe, 2026-09-18, against a real saved set):
--   * all three bare 3.3.5a globals are nil
--   * GetEquipmentSetIDs() -> DENSE array of set IDs, and set IDs are
--     ZERO-BASED: a single saved set came back as { [1] = 0 }
--   * GetItemIDs(setID) -> table keyed by equipment SLOT, SPARSE. A real
--     9-item set returned keys 5,6,7,8,9,10,15,16,18. Unused slots are
--     ABSENT rather than stored as a 0 sentinel.
--   * GetEquipmentSetInfo(setID) -> POSITIONAL values, not a table:
--     name, iconFileID, setID, isEquipped, ...  (measured "Test", 134400,
--     0, true). Nothing here calls it; noted so nobody destructures it as
--     a table on the strength of the C_ prefix.
--
-- WC-TRAP: the item loop below MUST stay `pairs`, and the emptiness test
-- above MUST stay `next()`. Both were `ipairs` / `#t` for one commit, and
-- on the measured data that is not a partial failure but a total one: the
-- lowest slot key was 5, so `ipairs` finds nil at index 1 and yields ZERO
-- iterations. Every item in every set would have gone unprotected, on every
-- character, with no error - and unprotected gear is gear this addon will
-- sell. `#t` is no better: it reported 10 for that 9-entry table. Neither
-- operator is defined on a sparse table. Do not "tidy" either one back.
--
-- The same trap has a second door: C_EquipmentSet.GetNumEquipmentSets exists,
-- so `for i = 1, GetNumEquipmentSets()` looks like a tidy equivalent. It is
-- not. Set IDs are zero-based and are NOT positional indices, so that loop
-- silently skips set 0 - which is the only set a character with one saved
-- set has. Always walk the IDs GetEquipmentSetIDs hands back.
function WC_compCache.syncEquipmentSets(silent)
    if not (C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs and C_EquipmentSet.GetItemIDs) then
        return 0
    end
    local setIDs = C_EquipmentSet.GetEquipmentSetIDs()
    -- next() rather than #setIDs: an emptiness test that does not itself
    -- assume the table is a dense array (see the WC-TRAP above).
    if not setIDs or next(setIDs) == nil then
        if not silent then
            PrintNice(
                L["|cffaaaaaaNo equipment sets saved. Use the Blizzard Equipment Manager to create one, then re-tick this option.|r"]
            )
        end
        return 0
    end
    -- v2.50.2: reuse this walk to rebuild WC_compCache.equipmentSetIDs, a
    -- session-scoped { [itemID] = true } cache consumed by the auto-mark scans
    -- and runAutoMarkResilience so items in any saved equipment set are never
    -- auto-marked, even if the Keep-List stamp is delayed or silently refused
    -- by WC_FindAddConflict (see the shirt-loss root-cause note in v2.50.2's
    -- CHANGELOG). Wipe the cache upfront so removed set members don't linger.
    -- The same table doubles as the dedupe map for the outer walk (replacing
    -- the previous file-local `seen`), so populating the cache costs nothing.
    -- Cache rebuild runs even when DB.autoProtectEquipmentSets is off - the
    -- scan-side rescue MUST honour set membership as user intent regardless
    -- of whether the user opted into the automatic Keep-List stamping.
    WC_compCache.equipmentSetIDs = WC_compCache.equipmentSetIDs or {}
    wipe(WC_compCache.equipmentSetIDs)
    local seen = WC_compCache.equipmentSetIDs
    local stampToKeep = DB and DB.autoProtectEquipmentSets
    local added, sets = 0, 0
    for _, setID in pairs(setIDs) do
        local itemIDs = C_EquipmentSet.GetItemIDs(setID)
        if itemIDs then
            sets = sets + 1
            for _, id in pairs(itemIDs) do
                if id and id > 1 and not seen[id] then
                    seen[id] = true
                    if stampToKeep and WC_compCache.protectEquipmentSetItem(id) then
                        added = added + 1
                    end
                end
            end
        end
    end
    if not silent then
        if added > 0 then
            PrintNicef(
                L["|cffb6ffb6Auto-protected %d item%s from %d equipment set%s.|r"],
                added,
                added == 1 and "" or "s",
                sets,
                sets == 1 and "" or "s"
            )
        else
            PrintNicef(
                L["|cffaaaaaaScanned %d equipment set%s; all items already on the keep list.|r"],
                sets,
                sets == 1 and "" or "s"
            )
        end
    end
    return added
end

-- v2.11.0 auto-protect upgraded gear (BAG_UPDATE-driven). Closes the gap
-- left by v2.10.0's PLAYER_EQUIPMENT_CHANGED-driven path: that path only
-- protected the *previously-equipped* item the moment the user swaps in
-- an upgrade. A higher-iLvl drop sitting in bags waiting to be equipped
-- was unprotected, and any active per-rarity iLvl-cap rule could vendor
-- it on the next merchant visit. The new path scans bag items on every
-- BAG_UPDATE, computes their slot type and base iLvl from GetItemInfo,
-- and stamps the Keep list when a bag item's iLvl exceeds the equipped
-- item in any of its candidate slots. Multi-slot equipLocs (rings,
-- trinkets, weapons) compare against the LOWER of the two equipped
-- iLvls so any genuine upgrade triggers.
--
-- Cost: GetItemInfo + a few inventory link reads per never-seen-before
-- itemID. WC_compCache.upgradeProcessed dedupes per-itemID for the
-- session - a /reload reseeds. WC_AddItemToList's quiet+dedupe path
-- short-circuits items already on the blacklist, so the only chat
-- output is the per-add notice.
WC_compCache.INVTYPE_SLOTS = {
    INVTYPE_HEAD = { 1 },
    INVTYPE_NECK = { 2 },
    INVTYPE_SHOULDER = { 3 },
    INVTYPE_CHEST = { 5 },
    INVTYPE_ROBE = { 5 },
    INVTYPE_WAIST = { 6 },
    INVTYPE_LEGS = { 7 },
    INVTYPE_FEET = { 8 },
    INVTYPE_WRIST = { 9 },
    INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 },
    INVTYPE_TRINKET = { 13, 14 },
    INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16, 17 },
    INVTYPE_2HWEAPON = { 16 },
    INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 },
    INVTYPE_HOLDABLE = { 17 },
    INVTYPE_SHIELD = { 17 },
    INVTYPE_RANGED = { 18 },
    INVTYPE_RANGEDRIGHT = { 18 },
    INVTYPE_THROWN = { 18 },
    INVTYPE_RELIC = { 18 },
}

WC_compCache.upgradeProcessed = {}

function WC_compCache.getEquippedILvl(slotID)
    local link = GetInventoryItemLink and GetInventoryItemLink("player", slotID)
    if not link then
        return 0
    end
    -- The equipped copy's real level (bonus IDs included), so it compares
    -- like-for-like with the bag copy's GetCurrentItemLevel in buildCtx.
    local actual = C_Item.GetDetailedItemLevelInfo(link)
    if actual and actual > 0 then
        return actual
    end
    local _, _, _, iLvl = GetItemInfo(link)
    return iLvl or 0
end

-- Lowest equipped iLvl across the given candidate slots, skipping empty
-- ones; nil when none are filled. Shared by the upgrade sweep (cleanup +
-- new-item) and the stale-upgrade report. NOTE: isDowngradeVsEquipped does
-- NOT use this - it treats an empty candidate slot as "don't auto-sell"
-- (returns early), which is a different rule.
function WC_compCache.getLowestEquippedILvl(slots)
    -- v2.59.10 (bug-hunt): defensive nil-guard. Every current caller
    -- guards, but Lua 5.1 crashes on `ipairs(nil)` and a future caller
    -- passing nil (e.g. equipLoc that doesn't map to INVTYPE_SLOTS)
    -- would take down the sell path. Return nil consistently.
    if not slots then
        return nil
    end
    local lowest = nil
    for _, sid in ipairs(slots) do
        local eq = WC_compCache.getEquippedILvl(sid)
        if eq > 0 and (lowest == nil or eq < lowest) then
            lowest = eq
        end
    end
    return lowest
end

-- v2.12.0 mirror of checkBagsForUpgrades' iLvl-vs-equipped comparison,
-- inverted: returns true iff a looted item's iLvl is strictly LESS than
-- the lowest populated equipped iLvl across the item's candidate slots.
-- Drives the per-rarity "Use equipped iLvl" sell mode in WC_IsSellable.
--
-- Multi-slot conservative rule: a ring / trinket / 1H weapon sells only
-- when worse than EVERY equipped slot - if any slot would treat it as
-- an upgrade, keep it. Empty slots are skipped entirely (the user might
-- want to fill that slot with the looted item, so we don't auto-sell).
--
-- Trade goods, reagents, consumables, and quest items have no equipLoc
-- in WC_compCache.INVTYPE_SLOTS, so they're naturally protected by the
-- early-return below.
function WC_compCache.isDowngradeVsEquipped(itemID, lootedILvl, equipLoc)
    -- v2.12.0+ returns (boolean, reason) so the tooltip annotation can
    -- distinguish "rule fired and decided keep" from "rule short-
    -- circuited on an empty slot". WC_IsSellable's call site only reads
    -- the boolean (Lua multi-return is transparent there).
    -- reason values:
    --   "not_equippable" - missing itemID / iLvl / equipLoc
    --   "no_slot_mapping" - equipLoc not in INVTYPE_SLOTS (relics, bags, etc.)
    --   "empty_slot"      - any candidate slot was empty; rule bailed without
    --                       comparing iLvls so the looted item could fill it
    --   "below_lowest"    - looted iLvl is below the lowest populated slot
    --                       (this is the only reason the boolean is true)
    --   "at_or_above"     - looted iLvl met or exceeded the lowest populated
    --                       slot's iLvl - actual iLvl comparison happened
    if not itemID or not lootedILvl or lootedILvl <= 0 then
        return false, "not_equippable"
    end
    if not equipLoc or equipLoc == "" then
        return false, "not_equippable"
    end
    local slots = WC_compCache.INVTYPE_SLOTS[equipLoc]
    if not slots then
        return false, "no_slot_mapping"
    end
    -- v2.33.x: 2H-aware narrowing for INVTYPE_WEAPON. A 1H weapon's
    -- candidate slots are {16, 17} but the offhand (17) is LOCKED EMPTY
    -- when the player wields a 2H - it's not an unfilled "could fill
    -- this" slot, so the empty_slot bailout below would falsely keep
    -- every 1H in bags (reported by "Perfect Bidoof"). When the main
    -- hand holds an INVTYPE_2HWEAPON, narrow the candidate slots to
    -- {16} only so the comparison happens against the equipped 2H.
    -- v2.45.1: mirror this for OFFHAND equipLocs (SHIELD / HOLDABLE /
    -- WEAPONOFFHAND). When MH is a 2H, slot 17 is locked empty and an
    -- offhand item can't actually fill it - the player would have to
    -- swap out their 2H first. Reported by Zukii: an offhand looted
    -- while a staff was equipped showed "Keep (Green, possible
    -- upgrade)" because empty_slot returned not_a_downgrade. The
    -- comparison-against-the-2H baseline is what real players want:
    -- low-level offhand drops vendor when the player has chosen 2H,
    -- and only items genuinely above the 2H's iLvl get the upgrade
    -- flag (still rare in practice but theoretically right).
    if equipLoc == "INVTYPE_WEAPON"
        or equipLoc == "INVTYPE_SHIELD"
        or equipLoc == "INVTYPE_HOLDABLE"
        or equipLoc == "INVTYPE_WEAPONOFFHAND"
    then
        local mhLink = GetInventoryItemLink and GetInventoryItemLink("player", 16)
        if mhLink then
            local _, _, _, _, _, _, _, _, mhEquipLoc = GetItemInfo(mhLink)
            if mhEquipLoc == "INVTYPE_2HWEAPON" then
                slots = { 16 }
            end
        end
    end
    local lowestEquipped = nil
    for _, sid in ipairs(slots) do
        local eq = WC_compCache.getEquippedILvl(sid)
        if eq <= 0 then
            return false, "empty_slot"
        end
        if lowestEquipped == nil or eq < lowestEquipped then
            lowestEquipped = eq
        end
    end
    if lowestEquipped == nil then
        return false, "no_slot_mapping"
    end
    if lootedILvl < lowestEquipped then
        return true, "below_lowest"
    end
    return false, "at_or_above"
end

-- Candidate equipped slots for an upgrade comparison, with the 2H
-- narrowing: when the main hand holds a two-hander, slot 17 is locked
-- empty, so 1H and off-hand items compare against slot 16 only (rationale
-- in isDowngradeVsEquipped above, which keeps its own copy because it also
-- reports why). One helper for the automatic cleanup, the upgrade stamp
-- and /wc clean upgrades, which had drifted: the manual report did not
-- narrow, so it "skipped" off-hands the automatic cleanup removed.
WC_compCache.MAIN_HAND_ONLY = { 16 }
function WC_compCache.upgradeSlotsFor(equipLoc)
    local slots = equipLoc and WC_compCache.INVTYPE_SLOTS[equipLoc]
    if slots and (equipLoc == "INVTYPE_WEAPON"
        or equipLoc == "INVTYPE_SHIELD"
        or equipLoc == "INVTYPE_HOLDABLE"
        or equipLoc == "INVTYPE_WEAPONOFFHAND")
    then
        local mhLink = GetInventoryItemLink("player", 16)
        if mhLink and select(9, GetItemInfo(mhLink)) == "INVTYPE_2HWEAPON" then
            return WC_compCache.MAIN_HAND_ONLY
        end
    end
    return slots
end

function WC_compCache.checkBagsForUpgrades()
    if not DB or not DB.autoProtectUpgrades then
        return
    end
    -- Skip while a vendor cycle is mid-flight: the worker queue was
    -- built before any add we'd make now, so a fresh blacklist stamp
    -- wouldn't influence the current run anyway. Next BAG_UPDATE post-
    -- MERCHANT_CLOSED picks up the same items cleanly.
    if WC_compCache.vendorRunning then
        return
    end
    -- v2.33.x: re-evaluate existing "upgrade"-tagged Keep List entries
    -- and release ones that are no longer above the currently equipped
    -- iLvl. Without this, an item added when the player had a low-iLvl
    -- weapon equipped (e.g. a starter weapon during early levelling)
    -- stays on the Keep List forever even after the player upgrades
    -- their gear past it. The `/wc clean upgrades apply` slash command
    -- exists for manual cleanup but users shouldn't have to remember
    -- it - the path that ADDED the entry should clean its own stale
    -- entries. Only touches autoTag "upgrade" entries; manual Keep
    -- List adds (no autoTag) and "equipped" / "set" autoTags are left
    -- alone (those have their own reactive sync paths).
    -- The answer only changes when worn gear changes, so run once after
    -- login and once per PLAYER_EQUIPMENT_CHANGED (which clears the flag),
    -- not on every settled bag change.
    if DB.blacklistAuto and not WC_compCache.staleUpgradesChecked then
        WC_compCache.staleUpgradesChecked = true
        for itemID, tag in pairs(DB.blacklistAuto) do
            if tag == "upgrade" then
                -- v2.44.0: class-restriction self-heal. Pre-v2.44.0 the
                -- upgrade sweep didn't check IsUsableItem, so a Druid
                -- could end up with bows / Mages with relics / etc.
                -- stamped as "upgrade" against the relic / ranged slot.
                -- Strip those stale entries on every sweep, via
                -- classCannotUse (a class veto only: a level requirement or
                -- an uncached item leaves the entry alone).
                if WC_compCache.classCannotUse(itemID) then
                    if DB.blacklist then
                        DB.blacklist[itemID] = nil
                    end
                    DB.blacklistAuto[itemID] = nil
                    if WC_compCache.upgradeProcessed then
                        WC_compCache.upgradeProcessed[itemID] = nil
                    end
                else
                    local _, _, _, iLvl, _, _, _, _, equipLoc = GetItemInfo(itemID)
                    local slots = WC_compCache.upgradeSlotsFor(equipLoc)
                    if iLvl and iLvl > 0 and slots then
                        local lowestEquipped = WC_compCache.getLowestEquippedILvl(slots)
                        -- Remove only when a slot is actually populated and
                        -- the item's iLvl is at or below it. If every
                        -- candidate slot is empty, be conservative and keep
                        -- the entry - the next cycle will re-evaluate once
                        -- gear comes back.
                        if lowestEquipped and iLvl <= lowestEquipped then
                            if DB.blacklist then
                                DB.blacklist[itemID] = nil
                            end
                            DB.blacklistAuto[itemID] = nil
                            -- Clear the per-session memo so a future gear
                            -- downgrade can re-add this item via the
                            -- new-entry loop below.
                            if WC_compCache.upgradeProcessed then
                                WC_compCache.upgradeProcessed[itemID] = nil
                            end
                        end
                    end
                end
            end
        end
    end
    -- v2.59.0: iterate the shared flush snapshot (or a fresh one when
    -- called outside the flush, e.g. the Protection panel toggle). The
    -- upgradeProcessed memo and every action below are itemID-keyed list
    -- writes, so snapshot iteration needs no live slot re-verify here.
    local snap = WC_compCache.acquireFlushSnapshot()
    for i = 1, #snap.entries do
        do -- scoping block keeps the old two-level loop body untouched
            local itemID = snap.entries[i].itemID
            if itemID and not WC_compCache.upgradeProcessed[itemID] then
                WC_compCache.upgradeProcessed[itemID] = true
                -- v2.44.0: skip items the player's class can't use. A
                -- Druid will never equip a bow; a Mage will never use
                -- a relic - they shouldn't be polluting the Keep List
                -- as "upgrade" candidates. Real player report from
                -- Murlocked. IsUsableItem returns false on a class
                -- restriction; `nil` (uncached) doesn't match and lets
                -- the iLvl logic still run on the warmup pass.
                if WC_compCache.classCannotUse(itemID) then -- luacheck: ignore 542
                    -- Intentional no-op fall-through to the next slot.
                    -- upgradeProcessed[itemID] stays true so we don't
                    -- re-check every BAG_UPDATE; /reload reseeds the
                    -- cache if the player's class somehow changes.
                elseif not (DB.blacklist and DB.blacklist[itemID]) then
                    local _, _, _, iLvl, _, _, _, _, equipLoc = GetItemInfo(itemID)
                    -- The bag copy's real level, matching getEquippedILvl's
                    -- real equipped level on the other side of the compare.
                    local e = snap.entries[i]
                    local current = equipLoc
                        and equipLoc ~= ""
                        and C_Item.GetCurrentItemLevel(NS.Decision.slotLocation(e.bag, e.slot))
                    if current and current > 0 then
                        iLvl = current
                    end
                    local slots = WC_compCache.upgradeSlotsFor(equipLoc)
                    -- 2H narrowing (in upgradeSlotsFor) matters here: without
                    -- it an off-hand in bags compares against the locked-empty
                    -- slot 17 and every off-hand is stamped as an upgrade.
                    if iLvl and iLvl > 0 and slots then
                        -- For multi-slot equipLocs (rings, trinkets,
                        -- 1H weapons), compute the LOWEST iLvl among
                        -- the populated candidate slots. Empty slots
                        -- are ignored - otherwise an empty ring-2 slot
                        -- (iLvl 0) would suppress upgrade detection
                        -- against an iLvl-250 ring-1.
                        local lowestEquipped = WC_compCache.getLowestEquippedILvl(slots)
                        -- v2.12.0: require at least one populated slot to
                        -- give us a real baseline. The pre-fix behaviour
                        -- fell back to threshold = 0 when every candidate
                        -- slot was empty (e.g. logging in with no weapons),
                        -- which mass-stamped every iLvl > 0 item in bags
                        -- as an "upgrade" - polluting the Keep list with
                        -- dozens of low-iLvl daggers / spare gear that
                        -- weren't actually upgrades against anything. Now
                        -- if no slot is populated we skip this iteration
                        -- entirely; we'll re-check this itemID when
                        -- upgradeProcessed is reset (a /reload). When the
                        -- user equips something later, PLAYER_EQUIPMENT_
                        -- CHANGED + autoAddEquipped covers the equipped
                        -- side; subsequent BAG_UPDATEs cover the bag side
                        -- once at least one slot is populated.
                        if lowestEquipped and iLvl > lowestEquipped then
                            if WC_AddItemToList("blacklist", itemID, "Keep List", true) then
                                DB.blacklistAuto = DB.blacklistAuto or {}
                                -- v2.12.0: origin tag for tooltip fork.
                                DB.blacklistAuto[itemID] = "upgrade"
                                local name = GetItemInfo(itemID) or ("Item:" .. itemID)
                                PrintNicef(L["|cffb6ffb6Kept %s (looks like an upgrade).|r"], name)
                            end
                        end
                    end
                end
            end
        end
    end
end

-- The bag-item Alt+Right-Click context menu (WC_CTX_ROWS,
-- WC_BuildCtxFrame, WC_ShowItemContextMenu, WC_InstallBagContextHookOnce)
-- lives in WoWClearance_BagContextMenu.lua after Stage 8d of the file
-- split. Exposed as NS.InstallBagContextHookOnce for the ADDON_LOADED
-- branch in this file to call.


-- v2.9.0: bag snapshot for manual-sell attribution. Run at MERCHANT_SHOW so
-- the post-call hook can look up what was in (bag, slot) before the player
-- right-clicked it. By the time hooksecurefunc fires the slot is empty, so
-- a synchronous read inside the hook can't see what was sold. All three
-- helpers hang off WC_manualSell to keep main-chunk local count down (Lua
-- 5.1 caps that at 200).
-- v2.37.0: add a sell's copper to the current zone's lifetime total
-- (or "Unknown" when the zone text isn't ready, e.g. mid-load). Shared by
-- the manual UseContainerItem hook and the worker-cycle FinishRun so the
-- Stats panel's "Top Zones" rollup matches the wallet totals.
function WC_compCache.attributeCopperToZone(copper)
    local zone = GetRealZoneText and GetRealZoneText() or nil
    if not zone or zone == "" then
        zone = "Unknown"
    end
    -- v2.59.5 (Serv report): drop city sales. Vendoring mailboxed items
    -- in Dalaran / Stormwind / etc. is not farming and would otherwise
    -- pollute the Top Zones leaderboard. Wallet totalCopper is bumped
    -- separately by the caller, so wallet views stay accurate.
    if WC_CITY_ZONES[zone] then
        return
    end
    -- v2.38.1: helper writes to DB AND ADB.accountStats for the
    -- account-view aggregate.
    WC_BumpStatBucket("copperByZone", zone, copper)
end

function WC_manualSell.snapshotBags()
    wipe(WC_manualSell.snapshot)
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local cInfo = C_Container.GetContainerItemInfo(bag, slot)
                local count = cInfo and cInfo.stackCount
                WC_manualSell.snapshot[bag * 1000 + slot] = {
                    link = link,
                    count = count or 1,
                    itemID = GetContainerItemID(bag, slot),
                }
            end
        end
    end
end

function WC_manualSell.refreshSlot(bag, slot)
    if not bag or not slot then
        return
    end
    local key = bag * 1000 + slot
    local link = GetContainerItemLink(bag, slot)
    if link then
        local cInfo = C_Container.GetContainerItemInfo(bag, slot)
        local count = cInfo and cInfo.stackCount
        WC_manualSell.snapshot[key] = {
            link = link,
            count = count or 1,
            itemID = GetContainerItemID(bag, slot),
        }
    else
        WC_manualSell.snapshot[key] = nil
    end
end

-- Hook UseContainerItem ONCE at addon load. hooksecurefunc preserves the
-- original (we cannot replace it: UseContainerItem is in the secure-dispatch
-- path for items that trigger spells/casts, and Blizzard's secure system
-- silently rejects calls to a non-Blizzard implementation). The hook only
-- attributes a sell when (a) we did NOT do it ourselves (WC_manualSell.inSelfSell is
-- false) and (b) the merchant frame is open and (c) the snapshot has an
-- entry for that slot - i.e. the item was present at MERCHANT_SHOW or after
-- the last refresh. Stat fields match what DoNextAction bumps for the
-- worker-driven path so lifetime/session totals are uniform regardless of
-- which path actually completed the sale.
function WC_manualSell.installHookOnce()
    if WC_manualSell.hookInstalled then
        return
    end
    WC_manualSell.hookInstalled = true
    -- v0.5.2 port fix: UseContainerItem is namespaced to C_Container on
    -- Forever, so the string form of hooksecurefunc throws
    -- "UseContainerItem is not a function" and aborts installHookOnce
    -- before the manual-sell detection is wired. Measured in-game
    -- 2026-09-19. hooksecurefunc's table form hooks the namespaced
    -- member directly.
    hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
        if WC_manualSell.inSelfSell then
            return
        end
        if not (MerchantFrame and MerchantFrame:IsShown()) then
            return
        end
        if not bag or not slot then
            return
        end
        local snap = WC_manualSell.snapshot[bag * 1000 + slot]
        if snap and snap.link then
            local _, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(snap.link)
            if sellPrice and sellPrice > 0 then
                local copper = sellPrice * (snap.count or 1)
                if DB then
                    -- v2.38.1: helpers write to DB + ADB.accountStats.
                    WC_BumpStat("totalCopper", copper)
                    WC_BumpStat("totalItemsSold", 1)
                    if snap.itemID then
                        WC_BumpStatBucket("soldItemCounts", snap.itemID, 1)
                    end
                    if quality then
                        WC_BumpStatBucket("soldItemsByQuality", quality, 1)
                        WC_BumpStatBucket("soldCopperByQuality", quality, copper)
                    end
                    -- v2.37.0: attribute the sell to the current zone.
                    WC_compCache.attributeCopperToZone(copper)
                end
                WC_session.copper = WC_session.copper + copper
                WC_session.sold = WC_session.sold + 1
                -- v2.51.0: recent-sold ring buffer for /wc bugreport.
                WC_LogRecentSold(snap.itemID, snap.count or 1, "manual", copper)
            end
        end
        -- Refresh the snapshot for this slot after the sell completes. The
        -- 0.1 s delay gives the bag a tick to update before we re-read
        -- (hooksecurefunc fires synchronously inside the protected call,
        -- so the slot may still report the just-sold item if we read now).
        WC_Delay(0.1, function()
            WC_manualSell.refreshSlot(bag, slot)
        end)
    end)
end

-- ===========================================================================
-- v2.73.0 external-action attribution (competitive review Tier A,
-- owner-promoted 2026-07-31).
-- ---------------------------------------------------------------------------
-- Sold History only recorded WoWClearance's own actions, so a manual
-- drag-delete (or another addon's cursor delete) left no trail and the
-- "your addon deleted my item" report class could not be answered from
-- inside the game. Two hooksecurefunc hooks (never a global replacement
-- - house convention) attribute cursor deletes WC did not perform:
--
--   * PickupContainerItem remembers what landed on the cursor. The hook
--     fires after the pickup; GetCursorInfo is the truth for WHAT is
--     held, the (still-locked) slot supplies the count.
--   * DeleteCursorItem logs the remembered item as source="external".
--     WC's own deletes never reach either hook: executeBagSlotDelete calls
--     the PickupContainerItem / DeleteCursorItem locals captured at file
--     load, before these hooks replace the globals.
--
-- External rows carry a neutral reason, are EXCLUDED from every stat
-- counter (these are not WC actions - the row exists to prove that),
-- and surface in the Sold History window + /wc bugreport's Recent
-- Deleted section via the existing ring. State + installer live on
-- WC_compCache (the Events main chunk is at the 200-locals cap).
function WC_compCache.installExternalActionHooksOnce()
    if WC_compCache.externalActionHooksInstalled then
        return
    end
    WC_compCache.externalActionHooksInstalled = true
    -- v0.5.2 port fix: namespaced to C_Container on Forever, same as
    -- UseContainerItem above. The string form throws and would abort
    -- this installer before the external-delete detection is wired -
    -- which is a SAFETY path, so it failing silently is worse than the
    -- throw looks.
    hooksecurefunc(C_Container, "PickupContainerItem", function(bag, slot)
        local kind, cursorItemID = GetCursorInfo()
        if kind == "item" and cursorItemID then
            local count
            if bag and slot and GetContainerItemID(bag, slot) == cursorItemID then
                local cInfo = C_Container.GetContainerItemInfo(bag, slot)
                local slotCount = cInfo and cInfo.stackCount
                count = slotCount
            end
            WC_compCache.lastCursorPickup = { itemID = cursorItemID, count = count or 1, bag = bag, slot = slot }
        else
            WC_compCache.lastCursorPickup = nil
        end
    end)
    hooksecurefunc("DeleteCursorItem", function()
        local cp = WC_compCache.lastCursorPickup
        WC_compCache.lastCursorPickup = nil
        if not cp then
            return
        end
        -- v2.75.0 (fresh-audit 2026-08-03): DeleteCursorItem also fires when the
        -- Blizzard confirmation popup is RAISED for a rare/epic/quest item, not
        -- only when the delete completes - which is exactly why WC's own
        -- good-item deletes may show a popup. Logging here recorded a
        -- false "Deleted outside WoWClearance" row that stayed forever if the
        -- player then clicked Cancel. Defer: remember the candidate and its
        -- current in-bag count, and let the settled bag flush confirm the item
        -- actually left the bags before writing the row. GetItemCount excludes
        -- the on-cursor item, so a completed delete leaves the count unchanged
        -- while a cancel returns the item and raises it.
        WC_compCache.pendingExternalDelete = {
            itemID = cp.itemID,
            count = cp.count,
            bagCount = GetItemCount(cp.itemID) or 0,
            at = GetTime(),
        }
    end)
end

-- v2.75.0 (fresh-audit fix): confirm-or-drop a deferred external-delete
-- candidate. Called from the settled bag flush. While the delete popup is still
-- open the item sits on the cursor - wait. Once the cursor clears, an unchanged
-- in-bag count means the item was really destroyed (log it); a raised count
-- means the player cancelled and it returned to the bags (drop it). Expires
-- after 30 s so a popup left open forever cannot leak a stale candidate.
function WC_compCache.confirmPendingExternalDelete()
    local pe = WC_compCache.pendingExternalDelete
    if not pe then
        return
    end
    if GetTime() - (pe.at or 0) > 30 then
        WC_compCache.pendingExternalDelete = nil
        return
    end
    if GetCursorInfo and GetCursorInfo() == "item" then
        return -- popup still open / item still held; re-check next settle
    end
    WC_compCache.pendingExternalDelete = nil
    -- v0.5.7 WC-TRAP: do NOT reintroduce an "if GetItemCount then" guard
    -- here. GetItemCount is namespaced on Forever, so the old guarded form
    -- resolved to nil and "or 0" made BOTH this count and the recorded
    -- bagCount zero. The comparison below then read 0 <= 0, which is always
    -- true, so this logged "Deleted outside WoWClearance" on every settle
    -- whether or not anything had been deleted. The whole point of this
    -- check is to tell the player when something ELSE removed their items,
    -- so a guard that makes it always fire is worse than no check at all.
    local nowCount = GetItemCount(pe.itemID) or 0
    if nowCount <= (pe.bagCount or 0) then
        WC_LogRecentDeleted(pe.itemID, pe.count, "external", L["Deleted outside WoWClearance - by you or another addon"])
    end
end

-- `running` is forward-declared at the top of the file.
local queue = {}
local queueIndex = 1
local goldThisVendoring = 0
local WC_batchTotalSold = 0
local WC_batchTotalGold = 0

-- v2.46.4 vendor-refusal blacklist. Reported by Broyo: an Epic item
-- the vendor refuses to buy (server-side BoP-on-use, quest-adjacent,
-- stale GetItemInfo cache) wedged the sell cycle. UseContainerItem
-- returned silently, the slot stayed full, BuildQueue's fresh bag
-- walk re-queued the item, and the loop spammed "Sold X items so
-- far" forever. Keyed by (bag * 100 + slot) -> itemID so the entry
-- only blocks the exact item that was refused; a different item
-- landing in the same slot still gets a fresh try. Wiped on
-- StartRun / MERCHANT_CLOSED so a new merchant visit retries.
-- WC-TRAP: do not drop the itemID equality check - a key-only
-- presence test would block organic slot-moves and freeze
-- legitimate sells.
local WC_vendorRefusedThisRun = {}
local function WC_refusalKey(bag, slot) return bag * 100 + slot end

local worker = CreateFrame("Frame")
worker:Hide()

-- v2.13.0 quest-item safety net. Returns true iff GetItemInfo classifies
-- the item as itemClass "Quest". It vetoes the automatic quality rules and
-- the auto-mark and grey-delete picks only: an explicit Sell List entry
-- still sells a quest item (pinned in tests/test_decision.lua), and Delete
-- Next still takes a Delete-Listed one. Manual paths (Alt+Right-Click) are
-- not gated either. GetItemInfo's 6th return is the localized class name,
-- so this matches on English clients only, which is all this addon
-- supports (owner decision, 2026-11-15).
function WC_compCache.isQuestItem(itemID)
    if not itemID then
        return false
    end
    local _, _, _, _, _, itemType = GetItemInfo(itemID)
    return itemType == "Quest"
end

-- Shared sell predicate. Used by BuildQueue to build the vendor queue and by
-- WC_PreviewSellable to drive the minimap mouse-over preview. Returns:
--   sellable (bool), link, itemID, sellPrice, itemCount, quality.
-- `junkOnly` restricts matches to quality-0 items (used when the current
-- merchant mode disallows the whitelist/quality threshold).
--
-- INVARIANT: Grey items (quality == 0) with a positive sell price ALWAYS
-- match via isJunk, independent of DB.whitelist, DB.whitelistQualityEnabled,
-- or DB.whitelistMinQuality, unless the player turns off "Sell grey items"
-- (DB.sellGreys). The quality threshold only gates non-grey items. Do
-- not "simplify" the three independent passes (isJunk /
-- qualityPass / whitelistPass) into one combined check -- you will silently
-- break the grey-always-sold guarantee that users and docs rely on.
-- Blacklist and IsEquippedItem are the only things that can veto a sale.
-- WC-TRAP: do NOT combine isJunk / qualityPass / whitelistPass into
-- "one cleaner check" - that breaks the grey-always-sold guarantee (see
-- ADDON_GUIDE "Grey items are sold by default").
-- (Historical note: this trap once also forbade unifying WC_AnnotateTooltip
-- with this logic. That was RETIRED in v2.71.2 - the tooltip now renders from
-- the shared decision core, so the DECISION is unified; only the label
-- formatting is still per-surface. See docs/CODE_REVIEW.md item 6.)
-- v2.71.0 (decision-classifier Stage 1): WC_IsSellable is now a thin
-- delegate over the pure decision core in WoWClearance_Decision.lua.
-- The 500-line decision body moved there VERBATIM (see the spec at
-- EbonClearance's docs/specs/2026-07-29-decision-classifier-design.md); this wrapper
-- preserves the historical return contract
-- (sellable, link, itemID, sellPrice, itemCount, quality) and the
-- lastSellSignal scratch that BuildQueue reads. The trace and tooltip
-- mirrors convert in Stages 2-3; until then their WC-TRAP parity
-- contracts hold against the core's behaviour (identical by
-- construction + pinned at runtime by tests/test_decision.lua).
local function WC_IsSellable(bag, slot, junkOnly)
    local ctx = NS.Decision and NS.Decision.buildCtx(bag, slot, junkOnly)
    if not ctx then
        return false
    end
    local verdict, token, fields = NS.Decision.sell(ctx)
    if verdict ~= "sell" then
        return false
    end
    WC_compCache.lastSellSignal = (fields and fields.signal) or token
    return true, ctx.link, ctx.itemID, ctx.sellPrice, ctx.count, ctx.quality
end
NS.IsSellable = WC_IsSellable

-- Plain-English "why sold" line for the session decision log, built from the
-- signal WC_IsSellable just recorded. The history window has room to spell it
-- out fully (unlike the tooltip), and because the signal comes straight from
-- WC_IsSellable the explanation can't drift from the real sell logic.
function WC_compCache.sellReasonForSignal(signal, quality, rule)
    -- v2.68.0: quality NAMES, not tooltip colour words. This expression
    -- used to read White / Green / Blue / Epic - three colours and one
    -- quality name, so the same window could print "white item" and
    -- "Epic item" a line apart. Matches the Merchant panel wording.
    local rarity = (quality == 1 and L["Common"])
        or (quality == 2 and L["Uncommon"])
        or (quality == 3 and L["Rare"])
        or (quality == 4 and L["Epic"])
        or "?"
    if signal == "whitelist_char" then
        return L["On your Sell List - you marked this item to always be sold."]
    elseif signal == "whitelist_account" then
        return L["On your account-wide Sell List (shared across all your characters)."]
    elseif signal == "recipe" then
        return L["A profession recipe this character has already learned - Sell Known Recipes vendored the duplicate."]
    elseif signal == "junk" then
        return L["Junk with a vendor price - junk sells at any vendor."]
    end
    -- Quality-rule case: spell out the item-level decision + any bind filter.
    local bindNote = ""
    if rule and rule.bindFilter == "boe" then
        bindNote = L[" (BoE only)"]
    elseif rule and rule.bindFilter == "bop" then
        bindNote = L[" (BoP only)"]
    end
    if rule and rule.useEquippedILvl then
        return string.format(
            L["Matched your %s auto-sell rule: its item level was below what you have equipped in that slot%s."],
            rarity, bindNote
        )
    elseif rule and (rule.maxILvl or 0) > 0 then
        return string.format(
            L["Matched your %s auto-sell rule: its item level was at or below your cap of %d%s."],
            rarity, rule.maxILvl, bindNote
        )
    end
    return string.format(L["Matched your %s auto-sell rule (it sells all items of that rarity)%s."], rarity, bindNote)
end

-- v2.42.0: shared Delete-List eligibility predicate. Returns (itemID, count,
-- quality) when the bag slot holds a Delete-List item eligible for destruction,
-- else nil. Used by Delete Next (and by BuildQueue to never sell a
-- Delete-List item), one policy for both.
-- v2.71.3 (classifier Stage 4): now a thin delegate - the eligibility policy
-- (the v2.50.2 Keep-signal / equipped rescues)
-- lives in NS.Decision.deleteEligible, with its rationale + WC-TRAPs.
function WC_compCache.deleteListSlotEligible(bag, slot)
    local DB = NS.DB
    if not (DB and DB.deleteList) then
        return nil
    end
    -- Cheap membership pre-gate BEFORE building a decision ctx: this
    -- predicate runs per slot inside the BAG_UPDATE scans and BuildQueue,
    -- and unlisted slots (the overwhelming majority) must stay at one
    -- item-ID read + one table lookup. Only listed slots pay for the
    -- snapshot.
    local id = GetContainerItemID(bag, slot)
    if not (id and IsInSet(DB.deleteList, id)) then
        return nil
    end
    -- v2.71.3 (classifier Stage 4): the eligibility policy lives in the
    -- decision core. The v2.50.2 rescue vetoes (Keep List / account Sell
    -- List / equipped - the Stickybackpack shirt-loss fix) and the
    -- moved there WITH their WC-TRAPs.
    local ctx = NS.Decision and NS.Decision.buildCtx(bag, slot, false)
    if not ctx then
        return nil
    end
    if not NS.Decision.deleteEligible(ctx) then
        return nil
    end
    return ctx.itemID, ctx.count, ctx.quality
end

-- True when this character's CLASS can never use the item. IsUsableItem is
-- false for a level requirement too (and returns a plain bool, never nil),
-- so an item still above the player's level, or not cached yet, counts as
-- usable: a level-locked upgrade must keep its Keep List entry.
function WC_compCache.classCannotUse(itemID)
    local name, _, _, _, minLevel = GetItemInfo(itemID)
    if not name or (minLevel or 0) > (UnitLevel("player") or 0) then
        return false
    end
    return IsUsableItem(itemID) == false
end

-- Delete one bag slot: pick the item up, delete it, and count the delete
-- once it is confirmed. If the game shows its own DELETE_* popup,
-- the player answers it: an addon click on Yes runs C_Item.DeleteItem
-- outside a hardware event and is blocked (the old auto-confirm hook was
-- removed for that reason). `announce` true prints one chat line.
-- v2.60.0: per-rarity chat-announce gate. Master toggle
-- (announceAutoDelete) OFF silences everything; ON lets the per-quality
-- sub-filter (announceAutoDeleteQualities) decide. Unknown quality
-- (nil) errs on the side of announcing so we never silently drop an
-- event the user might care about. Consumed by executeBagSlotDelete +
-- runAutoMarkResilience.
function WC_compCache.shouldAnnounceAutoDelete(quality)
    if not DB or DB.announceAutoDelete == false then
        return false
    end
    if not DB.announceAutoDeleteQualities then
        return true
    end
    if quality == nil then
        return true
    end
    return DB.announceAutoDeleteQualities[quality] == true
end

-- Returns true if the delete was issued.
--
-- WC-TRAP: DeleteCursorItem is PROTECTED on Forever. MEASURED 2026-10-10
-- (build 70291): an auto-delete from the BAG_UPDATE debounce raised
-- ADDON_ACTION_BLOCKED "tried to call the protected function
-- 'DeleteCursorItem()'", left the item on the cursor, and the next bag flush
-- tried again - a loop. The docs mark it HasRestrictions, like
-- SendChatMessage, which addons may call only inside a player's click or key
-- press. So this refuses unless WC_compCache.deleteFromInput is set by an
-- input handler (Delete Next) for the duration of that call. Do NOT call it
-- from a timer, OnUpdate or event, and do NOT drop this guard to "make
-- auto-delete work again": it cannot work here.
function WC_compCache.executeBagSlotDelete(bag, slot, itemID, count, quality, announce)
    if not WC_compCache.deleteFromInput then
        if not WC_compCache.deleteBlockedNoted then
            WC_compCache.deleteBlockedNoted = true
            PrintNice(L["This game only lets you delete items yourself. Use the Delete Next key or button to remove Delete List items."])
        end
        return false
    end
    ClearCursor()
    -- The copy's GUID, read before the pickup: the popup hook confirms only
    -- a DELETE_* popup carrying this exact GUID.
    local loc = NS.Decision.slotLocation(bag, slot)
    local guid = C_Item.DoesItemExist(loc) and C_Item.GetItemGUID(loc) or nil
    PickupContainerItem(bag, slot)
    if GetCursorInfo() ~= "item" then
        ClearCursor()
        return false
    end
    DeleteCursorItem()
    -- Rare, epic and quest items get the game's confirm popup, which closes
    -- itself as soon as the cursor is empty (GameDialogDefs.lua DELETE_*
    -- OnUpdate). Leave the item on the cursor while it is up: the player
    -- answers it (an addon click on Yes is blocked, porting lesson 16).
    if not WC_compCache.deletePopupShown() then
        ClearCursor()
    end
    -- Count only a delete that happened, checked by GUID (the slot may
    -- refill with a different copy). While the popup waits for the player,
    -- look again every second, up to 30 s; Cancel leaves the item in place
    -- and nothing is counted. Without a GUID, count as before.
    local tries = 0
    local function confirm()
        tries = tries + 1
        if guid then
            local still = NS.Decision.slotLocation(bag, slot)
            if C_Item.DoesItemExist(still) and C_Item.GetItemGUID(still) == guid then
                if tries < 30 and WC_compCache.deletePopupShown() then
                    NS.Delay(1, confirm)
                end
                return
            end
        end
        WC_compCache.countBagSlotDelete(itemID, count, quality, announce)
    end
    NS.Delay(1, confirm)
    return true
end

-- True while one of the game's delete confirmations is on screen.
-- (No main-chunk local: this chunk is at the 200-locals cap.)
function WC_compCache.deletePopupShown()
    return StaticPopup_Visible("DELETE_ITEM")
        or StaticPopup_Visible("DELETE_GOOD_ITEM")
        or StaticPopup_Visible("DELETE_QUEST_ITEM")
        or StaticPopup_Visible("DELETE_GOOD_QUEST_ITEM")
        or false
end

-- Stats, the recent-deleted ring and the chat line for a delete that
-- executeBagSlotDelete confirmed.
function WC_compCache.countBagSlotDelete(itemID, count, quality, announce)
    local delCount = count or 1
    WC_BumpStat("totalItemsDeleted", delCount)
    WC_session.deleted = WC_session.deleted + delCount
    if itemID then
        WC_BumpStatBucket("deletedItemCounts", itemID, delCount)
    end
    if quality then
        WC_BumpStatBucket("deletedItemsByQuality", quality, delCount)
    end
    -- v2.51.0: recent-deleted ring buffer for /wc bugreport. Every own
    -- delete is a Delete Next press since v0.6.0 (source "auto" keeps the
    -- saved ring's existing tag).
    WC_LogRecentDeleted(itemID, delCount, "auto")
    if announce and WC_compCache.shouldAnnounceAutoDelete(quality) then
        local link = select(2, GetItemInfo(itemID)) or ("item:" .. tostring(itemID))
        PrintNicef(L["|cffff4444Deleted|r %s."], link)
    end
end


-- The grey item Delete Next removes when "Mark grey items for deletion" is
-- on: the cheapest stack by vendor value, never keep-listed, auto-kept,
-- Delete-Listed (those go first), equipped or quest. Returns bag, slot,
-- itemID, count, quality, or nil.
function WC_compCache.nextGreyToDelete()
    local DB = NS.DB
    local keepList = DB.blacklist
    local accountKeep = NS.ADB and NS.ADB.whitelist
    local blacklistAuto = DB.blacklistAuto
    local deleteList = DB.deleteList
    local best, bestValue
    local snap = WC_compCache.acquireFlushSnapshot()
    for i = 1, #snap.entries do
        local e = snap.entries[i]
        local id = e.itemID
        if (e.quality == nil or e.quality < 1) and GetContainerItemID(e.bag, e.slot) == id then
            local _, _, quality, _, _, itemType, _, _, _, _, sellPrice = GetItemInfo(id)
            if quality == 0
                and itemType ~= "Quest"
                and not IsEquippedItem(id)
                and not (keepList and keepList[id])
                and not (accountKeep and accountKeep[id])
                and not (blacklistAuto and blacklistAuto[id])
                and not (deleteList and deleteList[id])
                and not (WC_compCache.equipmentSetIDs and WC_compCache.equipmentSetIDs[id])
                and not (WC_compCache.hostLocked and WC_compCache.hostLocked(id))
            then
                local cInfo = C_Container.GetContainerItemInfo(e.bag, e.slot)
                local count = cInfo and cInfo.stackCount
                if cInfo and not cInfo.isLocked and count and count > 0 then
                    local value = (sellPrice or 0) * count
                    if not bestValue or value < bestValue then
                        best = { e.bag, e.slot, id, count, quality }
                        bestValue = value
                    end
                end
            end
        end
    end
    if best then
        return best[1], best[2], best[3], best[4], best[5]
    end
end

-- v2.50.3: session-scoped auto-mark event log. Ring buffer of the last N
-- items runAutoMarkResilience wrote to
-- DB.deleteList. Consumed by /wc bugreport so a report tells us WHEN and
-- WHY WC last auto-marked something, without asking the user's chat log
-- to survive as evidence. Session-local (not persisted); wiped on
-- /reload. Ring shifts oldest out on overflow.
local WC_AUTOMARK_LOG_MAX = 15
local WC_autoMarkLog = {}

local function WC_LogAutoMark(itemID, reason)
    if not itemID then
        return
    end
    if #WC_autoMarkLog >= WC_AUTOMARK_LOG_MAX then
        table.remove(WC_autoMarkLog, 1)
    end
    local _, link = GetItemInfo(itemID)
    WC_autoMarkLog[#WC_autoMarkLog + 1] = {
        itemID = itemID,
        itemName = link or ("item:" .. tostring(itemID)),
        reason = reason or "?",
        loggedAt = date("%H:%M:%S"),
    }
end
NS.autoMarkLog = WC_autoMarkLog

-- v2.51.0: session-scoped ring buffers for what WC has SOLD and DELETED
-- this session. The lifetime + session counters in DB / ADB.accountStats
-- tell "how much" but say nothing about "which items and when", so when
-- a user reports "it sold something I didn't want" there's no evidence
-- trail. These ring buffers capture the last N of each so /wc bugreport
-- surfaces them.
--
-- path/source tags:
--   * recentSold.path   = "manual" (user clicked at vendor, hooksecurefunc
--                                    fired) or "worker" (WC vendor cycle
--                                    UseContainerItem)
--   * recentDeleted.source = "auto" (Delete Next since v0.6.0; older saved
--                                    rows may also say "vendor")
--
-- v2.57.0: these are the FULL session logs behind the Sold History window,
-- not just a "recent" snapshot. Cap is high (5000 each) so a whole farming
-- session is captured; on overflow the oldest shift out and a trim counter
-- records how many, so the window can tell the player "N earlier entries
-- trimmed" rather than silently dropping them. /wc bugreport still shows only
-- the last WC_BUGREPORT_RECENT_MAX of each (a tail slice) so reports stay
-- short. Saved per character since v0.6.0 (see loadSoldHistory below), so
-- the logs span sessions; the Clear button wipes them.
local WC_RECENT_SOLD_LOG_MAX = 5000
local WC_RECENT_DELETED_LOG_MAX = 5000
local WC_BUGREPORT_RECENT_MAX = 20
local WC_recentSoldLog = {}
local WC_recentDeletedLog = {}
local WC_soldLogTrimmed = 0
local WC_deletedLogTrimmed = 0
-- v2.68.1: per-log write counters driving a TRUE ring. At the cap the old
-- code did table.remove(t, 1) per event - an O(5000) front-shift on the
-- vendor path during exactly the marathon sessions that fill the log
-- (Turbo mode sells up to 80 items per run). The write slot is now
-- ((writes - 1) % MAX) + 1: below the cap that is a plain append, at the
-- cap it overwrites the oldest in place. The array order becomes ROTATED
-- at the cap - readers must order by the per-entry `seq`, never by array
-- index (the Sold History window always did; /wc bugreport was converted
-- alongside this change). On WC_compCache, not file-scope locals: the main
-- chunk sits at Lua 5.1's 200-locals cap.
WC_compCache.soldLogWrites = 0
WC_compCache.deletedLogWrites = 0
-- Monotonic insertion sequence stamped on every entry so the Sold History
-- window can merge the two logs into an exact newest-first order (loggedAt is
-- only 1 s granular and would tie). Session-local.
local WC_historySeq = 0

-- `reason` (v2.54.x) is the plain-English "why" captured at decision time -
-- the rule that fired (e.g. "Sell List", "Auto-sell (Green)", "Delete List").
-- Optional: when omitted it falls back to a sensible default derived from the
-- path/source tag, so older call sites keep working. This is what /wc history
-- surfaces so the player can see what was sold/deleted AND why.
WC_LogRecentSold = function(itemID, count, path, copper, reason)
    if not itemID then
        return
    end
    WC_compCache.soldLogWrites = WC_compCache.soldLogWrites + 1
    local idx = ((WC_compCache.soldLogWrites - 1) % WC_RECENT_SOLD_LOG_MAX) + 1
    if WC_compCache.soldLogWrites > WC_RECENT_SOLD_LOG_MAX then
        WC_soldLogTrimmed = WC_soldLogTrimmed + 1
    end
    local _, link = GetItemInfo(itemID)
    WC_historySeq = WC_historySeq + 1
    WC_compCache.historySeq = WC_historySeq
    WC_recentSoldLog[idx] = {
        itemID = itemID,
        itemName = link or ("item:" .. tostring(itemID)),
        count = count or 1,
        path = path or "?",
        copper = copper or 0,
        reason = reason or (path == "manual" and "Sold by you" or "Auto-sell rule"),
        loggedAt = date("%H:%M:%S"),
        t = time(),
        seq = WC_historySeq,
    }
    WC_compCache.historyDirty = true
    WC_compCache.syncSoldHistory()
end

WC_LogRecentDeleted = function(itemID, count, source, reason)
    if not itemID then
        return
    end
    WC_compCache.deletedLogWrites = WC_compCache.deletedLogWrites + 1
    local idx = ((WC_compCache.deletedLogWrites - 1) % WC_RECENT_DELETED_LOG_MAX) + 1
    if WC_compCache.deletedLogWrites > WC_RECENT_DELETED_LOG_MAX then
        WC_deletedLogTrimmed = WC_deletedLogTrimmed + 1
    end
    local _, link = GetItemInfo(itemID)
    WC_historySeq = WC_historySeq + 1
    WC_compCache.historySeq = WC_historySeq
    WC_recentDeletedLog[idx] = {
        itemID = itemID,
        itemName = link or ("item:" .. tostring(itemID)),
        count = count or 1,
        source = source or "?",
        reason = reason or (source == "auto" and "Delete Next" or "Delete List"),
        loggedAt = date("%H:%M:%S"),
        t = time(),
        seq = WC_historySeq,
    }
    WC_compCache.historyDirty = true
    WC_compCache.syncSoldHistory()
end

NS.recentSoldLog = WC_recentSoldLog
NS.recentDeletedLog = WC_recentDeletedLog

-- v2.70.0 (competitive-review A4): items SAVED by drain-time re-validation.
-- When a rule or protection changes while the vendor worker is mid-burst,
-- the re-check in DoNextAction skips the destructive call and records the
-- item here so Sold History and /wc bugreport can say WHY nothing
-- happened. Rare by nature (needs a settings change during a run), so the
-- cap is small. Same ring + seq discipline as the sold/deleted logs; on
-- NS/WC_compCache rather than new locals (main chunk is at the Lua 5.1
-- 200-locals cap). kind is "sell" or "delete" (which action was skipped).
NS.recentSavedLog = {}
WC_compCache.savedLogWrites = 0
function WC_compCache.logRecentSaved(itemID, count, kind, reason)
    if not itemID then
        return
    end
    WC_compCache.savedLogWrites = WC_compCache.savedLogWrites + 1
    local idx = ((WC_compCache.savedLogWrites - 1) % 200) + 1
    local _, link = GetItemInfo(itemID)
    WC_historySeq = WC_historySeq + 1
    WC_compCache.historySeq = WC_historySeq
    NS.recentSavedLog[idx] = {
        itemID = itemID,
        itemName = link or ("item:" .. tostring(itemID)),
        count = count or 1,
        kind = kind or "?",
        reason = reason or "?",
        loggedAt = date("%H:%M:%S"),
        seq = WC_historySeq,
    }
    WC_compCache.historyDirty = true
    -- Always announce: a mid-run save means the user JUST changed a rule
    -- and is watching; one line confirms the change took effect in time.
    PrintNicef(L["|cffffd700Kept|r %s - %s"], link or ("item:" .. tostring(itemID)), reason or "?")
end

-- v2.59.4: Process Bags cast log. Session ring buffer of successful
-- Disenchant / Milling / Prospecting / Pick Lock / Convert casts, one
-- entry per successful spell resolution. Captured pre-cast on the
-- panel's PostClick (so the item info is still valid) and committed
-- on UNIT_SPELLCAST_SUCCEEDED matching the pending spell name. Fills
-- the visibility gap in /wc bugreport ("what did I DE this session?")
-- that led to Serv's v2.59.3 worry about accidentally disenchanting a
-- Session-local; wiped on /reload.
local WC_RECENT_PROCESSED_LOG_MAX = 200
local WC_recentProcessedLog = {}
-- Pending capture between PostClick and UNIT_SPELLCAST_SUCCEEDED.
-- Populated by the panel just before the cast fires (bag/slot/itemID
-- are still valid; the /cast has not yet resolved), consumed by the
-- spellcast handler that matches the same spell name.
WC_compCache.pendingProcessCast = nil

function NS.LogRecentProcessed(entry)
    if not entry or not entry.itemID then
        return
    end
    if #WC_recentProcessedLog >= WC_RECENT_PROCESSED_LOG_MAX then
        table.remove(WC_recentProcessedLog, 1)
    end
    local _, link = GetItemInfo(entry.itemID)
    WC_recentProcessedLog[#WC_recentProcessedLog + 1] = {
        itemID = entry.itemID,
        itemName = entry.itemName or link or ("item:" .. tostring(entry.itemID)),
        mode = entry.mode or "?",
        spellName = entry.spellName or "?",
        count = tonumber(entry.count) or 1,
        loggedAt = date("%H:%M:%S"),
    }
end

NS.recentProcessedLog = WC_recentProcessedLog
-- How many of each log /wc bugreport dumps (a tail slice) so reports stay
-- short even though the logs now hold the whole session.
NS.bugReportRecentMax = WC_BUGREPORT_RECENT_MAX

-- Live trim counts for the Sold History window's "N earlier entries trimmed"
-- note. Returned as (sold, deleted); numbers are value-copied, so this has to
-- be a function rather than a snapshot field.
function NS.SessionHistoryTrimmed()
    return WC_soldLogTrimmed, WC_deletedLogTrimmed
end

-- Wipe the session sell/delete logs (the Sold History window's Clear button)
-- and zero the trim counters so the "trimmed" note resets too.
function NS.ClearSessionHistory()
    wipe(WC_recentSoldLog)
    wipe(WC_recentDeletedLog)
    WC_soldLogTrimmed = 0
    WC_deletedLogTrimmed = 0
    -- Reset the ring write cursors so post-clear writes append from slot 1
    -- again (a stale cursor would leave holes ipairs stops at).
    WC_compCache.soldLogWrites = 0
    WC_compCache.deletedLogWrites = 0
    -- v2.70.0: the saved-items log clears with the rest of the session
    -- history (same Clear button contract).
    wipe(NS.recentSavedLog)
    WC_compCache.savedLogWrites = 0
    WC_compCache.syncSoldHistory()
end

-- v0.6.0: the sold + deleted logs persist per character (DB.soldHistory).
-- The live log tables ARE the saved ones: at login the saved entries are
-- copied into the existing tables (NS.recentSoldLog etc. keep their
-- identity) and the store then points at them, so every later write lands
-- in SavedVariables with no extra copy. The ring cursors, trim counts and
-- insertion sequence are mirrored into the store after every write so the
-- ring and the newest-first order carry on across sessions.
-- The "saved by re-check" log stays session-only on purpose: it reports a
-- rule changed mid-run, which means nothing once the session is over.
function WC_compCache.syncSoldHistory()
    local h = WC_compCache.soldHistoryStore
    if not h then
        return
    end
    h.soldWrites = WC_compCache.soldLogWrites
    h.deletedWrites = WC_compCache.deletedLogWrites
    h.soldTrimmed = WC_soldLogTrimmed
    h.deletedTrimmed = WC_deletedLogTrimmed
    h.seq = WC_historySeq
end

function WC_compCache.loadSoldHistory()
    if WC_compCache.soldHistoryStore or not DB then
        return
    end
    local h = DB.soldHistory
    if type(h) ~= "table" then
        h = {}
    end
    local maxSeq = tonumber(h.seq) or 0
    local function adopt(saved, live)
        if type(saved) ~= "table" or saved == live then
            return 0
        end
        local n = 0
        for k, e in pairs(saved) do
            if type(k) == "number" and type(e) == "table" and e.itemID then
                live[k] = e
                n = n + 1
                if (tonumber(e.seq) or 0) > maxSeq then
                    maxSeq = e.seq
                end
            end
        end
        return n
    end
    local soldN = adopt(h.sold, WC_recentSoldLog)
    local deletedN = adopt(h.deleted, WC_recentDeletedLog)
    h.sold = WC_recentSoldLog
    h.deleted = WC_recentDeletedLog
    WC_compCache.soldLogWrites = math.max(tonumber(h.soldWrites) or 0, soldN)
    WC_compCache.deletedLogWrites = math.max(tonumber(h.deletedWrites) or 0, deletedN)
    WC_soldLogTrimmed = tonumber(h.soldTrimmed) or 0
    WC_deletedLogTrimmed = tonumber(h.deletedTrimmed) or 0
    WC_historySeq = maxSeq
    WC_compCache.historySeq = maxSeq
    DB.soldHistory = h
    WC_compCache.soldHistoryStore = h
    WC_compCache.historyDirty = true
end

-- Session sell/delete history. Opens the interactive Sold History window
-- (WoWClearance_HistoryWindow.lua): the whole session, newest-first, with
-- All / Sold / Deleted + search filters and a Copy button. Falls back to a
-- plain copyable text dump if that module didn't load. Shared by the
-- /wc history command, the Main panel's Sold History button, and the Alt+
-- Right-Click menu. The logs are saved per character (v0.6.0).
function NS.ShowSessionHistory()
    if NS.ShowHistoryWindow then
        NS.ShowHistoryWindow()
        return
    end
    local rows = {}
    local function push(e, action)
        rows[#rows + 1] = {
            at = e.loggedAt or "",
            text = string.format(
                "[%s] %s %dx %s  |cff888888- %s|r",
                tostring(e.loggedAt or "?"),
                action,
                tonumber(e.count) or 1,
                tostring(e.itemName),
                tostring(e.reason or "?")
            ),
        }
    end
    for _, e in ipairs(WC_recentSoldLog) do
        push(e, L["Sold"])
    end
    for _, e in ipairs(WC_recentDeletedLog) do
        push(e, L["Deleted"])
    end
    -- Newest-first. loggedAt is HH:MM:SS, string-sortable within a session.
    table.sort(rows, function(a, b)
        return a.at > b.at
    end)
    local body
    if #rows == 0 then
        body = L["Nothing sold or deleted yet this session."]
    else
        local lines = {}
        for i = 1, #rows do
            lines[i] = rows[i].text
        end
        body = table.concat(lines, "\n")
    end
    if NS.ShowCopyFrame then
        NS.ShowCopyFrame(L["WoWClearance: Sold History"], body)
    else
        PrintNice(body)
    end
end

-- v2.51.0: watch-list toggle snapshot at PLAYER_LOGIN, after EnsureDB.
-- The watch list is a curated set of high-diagnostic-value toggles - the
-- ones that meaningfully change addon behaviour and that a user might
-- flip mid-session. /wc bugreport diffs this snapshot against the live
-- values to surface "toggles you changed this session". No mutation
-- hooks; the diff at report time is enough.
--
-- Not exhaustive on purpose: cosmetic toggles (tint colours, border
-- widths) don't affect what the addon does, so they're excluded.
local WC_TOGGLE_WATCH_LIST = {
    -- destructive
    "enableDeletion", "markGreyForDeletion",
    "announceAutoDelete", "warnConflictingAddons",
    -- auto-mark
    "autoMarkResilience", "autoMarkKnownUnsellableRecipes",
    -- protection
    "protectAllTomes", "protectUnlearnedTomes",
    "protectUncollectedAppearances", "protectTradeableLoot",
    -- auto-protect (equipped / upgrades / sets)
    "autoAddEquipped", "autoProtectUpgrades", "autoProtectEquipmentSets",
    -- sell rules
    "sellKnownRecipes",
    -- vendor mode
    "repairGear", "repairUseGuildBank",
    -- sharing (v2.53.0)
    "shareGuildData", "shareGuildName",
    -- realm-wide sharing (v2.58.0)
    "shareServerData",
}
local WC_toggleLoginSnapshot = nil
local function WC_CaptureToggleLoginSnapshot()
    if not DB then
        return
    end
    WC_toggleLoginSnapshot = {}
    for i = 1, #WC_TOGGLE_WATCH_LIST do
        local k = WC_TOGGLE_WATCH_LIST[i]
        WC_toggleLoginSnapshot[k] = DB[k]
    end
end
local function WC_ToggleDiffSinceLogin()
    if not (WC_toggleLoginSnapshot and DB) then
        return {}
    end
    local diffs = {}
    for i = 1, #WC_TOGGLE_WATCH_LIST do
        local k = WC_TOGGLE_WATCH_LIST[i]
        local before = WC_toggleLoginSnapshot[k]
        local now = DB[k]
        if before ~= now then
            diffs[#diffs + 1] = { key = k, before = before, now = now }
        end
    end
    return diffs
end
NS.CaptureToggleLoginSnapshot = WC_CaptureToggleLoginSnapshot
NS.ToggleDiffSinceLogin = WC_ToggleDiffSinceLogin

-- v2.51.0: prime the client's item cache for Delete List entries at
-- login. GetItemInfo returns nil for items the client hasn't seen this
-- session; Delete List entries persist across sessions and often
-- haven't been hovered, so /wc bugreport's Delete List Preview shows
-- "item:ID" for everything on a fresh login. SetHyperlink fires an
-- async client-cache request; by the time the user runs /wc bugreport
-- later in the session, the client has received the responses and
-- names resolve properly. The single-sweep is fine for the typical
-- delete-list size (100-500 entries) - the client batches these
-- server-side and the burst settles in a couple of seconds.
local function WC_PrimeDeleteListItemCache()
    if not (DB and DB.deleteList) then
        return
    end
    local st = NS.scanTooltip
    if not st then
        return
    end
    for id in pairs(DB.deleteList) do
        if type(id) == "number" then
            pcall(st.SetOwner, st, UIParent, "ANCHOR_NONE")
            pcall(st.ClearLines, st)
            pcall(st.SetHyperlink, st, "item:" .. id)
        end
    end
end
NS.PrimeDeleteListItemCache = WC_PrimeDeleteListItemCache

-- v2.51.0: last-run timestamps for the addon's driving events. When a
-- user reports "auto-mark isn't firing" or "the vendor cycle got stuck",
-- knowing WHEN each subsystem last ran narrows the search: an
-- EQUIPMENT_SETS_CHANGED that fired 2 hours ago vs. never is a
-- meaningful signal. `date()` is enUS-locale-safe (24h format).
-- Values start as nil and remain nil until the event actually fires
-- so a "never" in the bug report is diagnostic in its own right.
local WC_lastEventAt = {
    bagUpdate = nil,          -- BAG_UPDATE debounce settled
    equipmentSetsChanged = nil,
    merchantShow = nil,
    merchantClosed = nil,
    autoMarkResilience = nil, -- runAutoMarkResilience ran to completion
    autoMarkKnownRecipe = nil, -- runAutoMarkKnownUnsellableRecipes ran to completion
    vendorRunStart = nil,     -- StartRun fired
}
WC_StampEvent = function(key)
    -- Store the cheap epoch integer; /wc bugreport formats it to HH:MM:SS at
    -- render time. date("%H:%M:%S") here was a strftime + string alloc per
    -- stamp, and one call site sits on the RAW (un-coalesced) BAG_UPDATE /
    -- ITEM_LOCK_CHANGED path where it ran once per event during AOE loot.
    WC_lastEventAt[key] = time()
end
NS.lastEventAt = WC_lastEventAt

-- v2.44.0: auto-mark Resilience PvP gear for deletion. When the
-- toggle is on, every BAG_UPDATE scans bags for items with a
-- "Resilience" tooltip line and adds them to the Delete List (one
-- chat line per add). Delete Next does the destroying - this function
-- only adds entries to the list. Gated on the master Enable toggle like
-- every destructive path.
function WC_compCache.runAutoMarkResilience()
    local DB = NS.DB
    if not WC_IsAddonEnabledForChar() then
        return
    end
    if not (DB and DB.autoMarkResilience) then
        return
    end
    WC_StampEvent("autoMarkResilience")
    if WC_compCache.vendorRunning then
        return
    end
    -- Skip items that are already on a curated list. Keep List wins
    -- (the player has explicitly said "do not touch"); items already
    -- on the Delete List are a no-op.
    local deleteList = DB.deleteList
    if not deleteList then
        return
    end
    local keepList = DB.blacklist
    local accountKeep = NS.ADB and NS.ADB.whitelist
    -- v2.59.0: iterate the shared flush snapshot. Runs after the pickup-
    -- delete scan (which can synchronously empty one slot mid-flush), so
    -- the live slot is re-verified against the snapshotted itemID before
    -- the tooltip scan - itemHasResilience caches by itemID, and scanning
    -- a changed slot would poison that cache.
    local snap = WC_compCache.acquireFlushSnapshot()
    for i = 1, #snap.entries do
        do -- scoping block keeps the old two-level loop body untouched
            local e = snap.entries[i]
            local id = e.itemID
            if id and not deleteList[id] and GetContainerItemID(e.bag, e.slot) == id then
                -- Also equipment-set members, equipped copies, quest items
                -- and (toggle) high item level: itemProtectedFromAutoMarkDelete
                -- had lost its only caller when the affix auto-mark went,
                -- which left the iLvl toggle doing nothing.
                local protectedByKeep = (keepList and keepList[id])
                    or (accountKeep and accountKeep[id])
                    or WC_compCache.itemProtectedFromAutoMarkDelete(id)
                if not protectedByKeep then
                    if WC_compCache.itemHasResilience(e.bag, e.slot, id) then
                        -- v2.44.0 iter: only mark UNSELLABLE Resilience
                        -- gear (sellPrice 0 / nil). The original
                        -- feedback (Murlocked: "delete pvp item with
                        -- resillience (they are unsellable)") was
                        -- specifically about gear the vendor refuses.
                        -- A real player report on this iteration: green
                        -- Slippers of Serenity / Pauldrons of Sufferance
                        -- with Resilience BUT a vendor price (2g+)
                        -- were getting auto-deleted - the user
                        -- reasonably expected those to be sold instead.
                        -- Skip anything sellable; the normal sell rules
                        -- handle them (Sell List, quality rule).
                        -- v2.60.0: also destructure `quality` (3rd return)
                        -- so the announce gate can consult
                        -- DB.announceAutoDeleteQualities[quality].
                        local _, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(id)
                        if sellPrice and sellPrice > 0 then -- luacheck: ignore 542
                            -- Sellable; let the vendor cycle do its
                            -- job. Don't fall through to the next
                            -- slot via `return` - the BAG_UPDATE
                            -- coalescing keeps the rest of the bag
                            -- in scope for this same sweep.
                        else
                            deleteList[id] = true
                            -- v2.50.3: session ring-buffer log for /wc bugreport.
                            WC_LogAutoMark(id, "resilience")
                            if WC_compCache.shouldAnnounceAutoDelete(quality) then
                                local link = select(2, GetItemInfo(id)) or ("item:" .. tostring(id))
                                -- v2.50.2: append recovery hint so the player
                                -- has a path back if the auto-mark caught an
                                -- item they wanted to keep.
                                PrintNicef(
                                    L["|cffff4444Marked for deletion (Resilience, unsellable):|r %s"]
                                        .. " "
                                        .. L["|cffaaaaaaAdd to Keep List (Alt+Right-Click on the bag slot) to save it.|r"],
                                    link
                                )
                            end
                            -- One add per BAG_UPDATE fire keeps the
                            -- chat tidy if the player loots multiple
                            -- PvP pieces at once; the next BAG_UPDATE
                            -- (any bag event re-fires the debounce)
                            -- picks up the next one.
                            return
                        end
                    end
                end
            end
        end
    end
end

-- v2.57.2: item levels at/above this are "real gear" and are never auto-marked
-- for deletion by the auto-mark scans. Plenty of top-end soulbound gear has
-- sellPrice 0, so "no vendor value" alone is NOT a safe "trash" signal - a
-- high-iLvl drop must be protected. Tunable.
--
-- v2.60.0 (Serv report): raised from 100 to 200. On a max-level character
-- most gear sits above iLvl 100 - the old threshold protected essentially
-- everything, including mid-era drops the player doesn't care about. The
-- threshold keeps real endgame gear safe while letting the auto-mark scan
-- catch old low-mid-iLvl dupes. Users who want tighter or looser protection
-- can toggle DB.automarkProtectHighILvl off entirely (unlocks all iLvls for
-- auto-mark, safe if the Keep List / Sets / Equipped tags cover everything
-- important).
--
-- v0.5.4 (Serv report): 200 -> 80. The inherited 200 was calibrated for
-- 3.3.5a item levels. The highest item level available on WoW: Forever is
-- 92, so a 200 floor could never be reached by any item in the game and the
-- protection was DEAD - every drop, however good, was eligible for
-- auto-mark. 80 sits just below the ceiling, which restores the intent:
-- endgame gear protected, older mid-level dupes still catchable.
--
-- WC-TRAP: this number is client-relative, not universal. If the level cap
-- or item-level ceiling moves, this moves with it. A value above the game's
-- maximum item level silently disables the protection rather than
-- tightening it, which is the failure this change fixes and is invisible
-- from the UI - the toggle still reads as ON.
local WC_AUTOMARK_PROTECT_ILVL = 80
-- Exposed so the panel label and help text FORMAT this number rather than
-- hardcoding it. The label used to read "iLvl 200+" as a literal string, so
-- changing the gate would have left the UI confidently stating the old
-- value. Format from the constant; never retype it.
NS.AUTOMARK_PROTECT_ILVL = WC_AUTOMARK_PROTECT_ILVL

-- v2.57.2 SAFETY: shared "is this item protected from auto-mark deletion?" gate,
-- called by BOTH the auto-mark scans (the real marking) and the tooltip's
-- "Will Delete" preview so the two can't drift (Serv report:
-- an equipment-set-member ring/shirt showed a false "Will Delete" while the real
-- logic skipped it). Covers the itemID-keyed protections: equipment-set
-- membership, the account Sell List, currently-equipped, quest items, and high
-- item level. (The character Keep List, tomes, and baseline tools are checked by
-- each caller in its own context.)
-- v2.60.0 (Serv follow-up): also returns a second value naming the
-- SPECIFIC reason the item is protected, so the tooltip's "Keep
-- (protected)" label can be more precise. Reason keys are canonical
-- English tokens ("set" / "sellList" / "equipped" / "quest" /
-- "highIlvl") the tooltip / trace map to localized strings. Callers
-- that only need the boolean still work unchanged (they read the first
-- return and ignore the second).
function WC_compCache.itemProtectedFromAutoMarkDelete(id)
    if not id then
        return false
    end
    if WC_compCache.equipmentSetIDs and WC_compCache.equipmentSetIDs[id] then
        return true, "set"
    end
    local ADB = NS.ADB
    if ADB and ADB.whitelist and NS.IsInSet and NS.IsInSet(ADB.whitelist, id) then
        return true, "sellList"
    end
    if IsEquippedItem and IsEquippedItem(id) then
        return true, "equipped"
    end
    if WC_compCache.isQuestItem and WC_compCache.isQuestItem(id) then
        return true, "quest"
    end
    if DB and DB.automarkProtectHighILvl ~= false then
        local _, _, _, ilvl = GetItemInfo(id)
        if ilvl and ilvl >= WC_AUTOMARK_PROTECT_ILVL then
            return true, "highIlvl"
        end
    end
    return false
end

-- v2.60.0 (Serv report, Recipe: Haunted Herring / Recipe: Last Week's Mammoth):
-- auto-mark learned profession recipes with sellPrice 0 for deletion. Some
-- BoP profession recipes (Cooking recipes at low ranks, some low-level Skinning /
-- Lockpicking schematics) return sellPrice 0 from GetItemInfo, so "Sell Known
-- Recipes" can't do anything with them (vendor refuses). When this toggle is on,
-- and the parent sellKnownRecipes toggle is also on, learned unsellable recipes
-- are added to the Delete List instead. Skips Keep List / equipment-set /
-- currently-equipped / quest / non-recipe tomes. Announce goes through the
-- shared per-rarity chat filter (announceAutoDeleteQualities). Gated like the
-- other destructive scans (master Enable + enableDeletion).
function WC_compCache.runAutoMarkKnownUnsellableRecipes()
    local DB = NS.DB
    if not WC_IsAddonEnabledForChar() then
        return
    end
    if not (DB and DB.enableDeletion and DB.autoMarkKnownUnsellableRecipes) then
        return
    end
    if not DB.sellKnownRecipes then
        return
    end
    WC_StampEvent("autoMarkKnownRecipe")
    -- WC-TRAP: this scan deliberately does NOT consult protectAllTomes /
    -- protectUnlearnedTomes. It rides the same documented carve-out as
    -- WC_IsSellable's recipePass ("Sell Known Recipes overrides the tome
    -- veto for LEARNED recipes"): the feature only exists for learned,
    -- unsellable recipes, and it requires three explicit opt-ins
    -- (enableDeletion + autoMarkKnownUnsellableRecipes + sellKnownRecipes).
    -- Adding a protectAllTomes guard here would make the toggle silently
    -- inert for exactly the users who asked for it. Unlearned recipes are
    -- never touched (playerKnowsTomeSpell gate below).
    if WC_compCache.vendorRunning then
        return
    end
    local deleteList = DB.deleteList
    if not deleteList then
        return
    end
    local keepList = DB.blacklist
    local accountKeep = NS.ADB and NS.ADB.whitelist
    local setMembers = WC_compCache.equipmentSetIDs
    local snap = WC_compCache.acquireFlushSnapshot()
    for i = 1, #snap.entries do
        do
            local e = snap.entries[i]
            local id = e.itemID
            if id and not deleteList[id] and GetContainerItemID(e.bag, e.slot) == id then
                local protectedByKeep = (keepList and keepList[id])
                    or (accountKeep and accountKeep[id])
                    or (setMembers and setMembers[id])
                if not protectedByKeep
                    and not IsEquippedItem(id)
                    and not (WC_compCache.isQuestItem and WC_compCache.isQuestItem(id))
                then
                    local _, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(id)
                    if not (sellPrice and sellPrice > 0)
                        and WC_compCache.itemIsTome
                        and WC_compCache.tomeKind
                        and WC_compCache.playerKnowsTomeSpell
                        and WC_compCache.itemIsTome(e.bag, e.slot, id)
                        and WC_compCache.tomeKind(id) == "Recipe"
                        and WC_compCache.playerKnowsTomeSpell(e.bag, e.slot, id)
                    then
                        deleteList[id] = true
                        WC_LogAutoMark(id, "knownRecipe")
                        if WC_compCache.shouldAnnounceAutoDelete(quality) then
                            local link = select(2, GetItemInfo(id)) or ("item:" .. tostring(id))
                            PrintNicef(
                                L["|cffff4444Marked for delete|r %s - recipe you know (no vendor value)."]
                                    .. " "
                                    .. L["|cffaaaaaaAdd to Keep List (Alt+Right-Click on the bag slot) to save it.|r"],
                                link
                            )
                        end
                        return
                    end
                end
            end
        end
    end
end

local function BuildQueue(junkOnly)
    wipe(queue)
    queueIndex = 1
    goldThisVendoring = 0
    -- v2.70.0 (competitive-review A4): stash the run's junkOnly context so
    -- DoNextAction can re-run WC_IsSellable with the SAME merchant-mode
    -- restriction at drain time. On WC_compCache (main chunk is at the
    -- Lua 5.1 200-locals cap).
    WC_compCache.runJunkOnly = junkOnly and true or false
    -- Single bag walk that produces both the sell and delete queue entries.
    --
    -- v2.37.0 reversed the per-slot dispatch order. Pre-v2.37.0 the sell
    -- pass ran first and only fell through to the delete-list check when
    -- WC_IsSellable returned false. Result: a grey item on the Delete
    -- List had isJunk = true, got queued as "sell", and the user's
    -- explicit "destroy this" intent silently lost to greyAutoSell. The
    -- bag-slot tint + tooltip annotation already followed the inverse
    -- precedence ("delete" tint wins over sell verdicts) so the cycle's
    -- order disagreed with what the UI was telling the player. Now the
    -- Delete-List check fires first per slot: an item on the list (with
    -- Enable Deletion on) is queued
    -- as "delete" regardless of any sell signal. Sell branch only runs
    -- when the slot didn't queue a delete. Matches the bag-tint logic
    -- in WoWClearance_BagDisplay.lua's bagSlotWillSellCategory (delete
    -- first) and the new Delete-List step in describeSellability.
    -- v0.6.0: the run no longer queues deletes. The worker runs from
    -- OnUpdate, and Forever refuses DeleteCursorItem outside the player's
    -- own click or key press (WC-TRAP on executeBagSlotDelete), so a queued
    -- delete could only fail. Delete List items wait for Delete Next.
    local deletionOn = DB.enableDeletion == true
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            -- Never sell a Delete List item either: deleting is the intent.
            local queuedDelete = deletionOn and WC_compCache.deleteListSlotEligible(bag, slot) ~= nil
            if not queuedDelete then
                -- v2.46.4: cheap pre-check for the vendor-refused
                -- guard. WC_IsSellable does a tooltip scan + multiple
                -- API hits; skip it on slots we already know the
                -- vendor refused this cycle. Equality on itemID is
                -- the discriminator - empty slot or different item
                -- in slot = nil/changed, so the check fails and the
                -- new item gets a fair try.
                local refusedID = WC_vendorRefusedThisRun[WC_refusalKey(bag, slot)]
                local skipForRefusal = refusedID and refusedID == GetContainerItemID(bag, slot)
                local sellable, link, itemID, sellPrice, itemCount, quality
                if not skipForRefusal then
                    sellable, link, itemID, sellPrice, itemCount, quality = WC_IsSellable(bag, slot, junkOnly)
                end
                if sellable then
                    -- v2.37.0: rarity is captured at queue-build time so the
                    -- worker path can attribute the sell to a quality bucket
                    -- without re-querying GetItemInfo at action execution;
                    -- WC_IsSellable already computed it, so it rides along on
                    -- the return tuple instead of a second GetItemInfo here.
                    -- Plain-English "why" for the session decision log, built
                    -- from the exact signal WC_IsSellable just recorded
                    -- (WC_compCache.lastSellSignal) so the history explanation
                    -- can't drift from the real sell logic. Read here, right
                    -- after the WC_IsSellable call above, before any other
                    -- WC_IsSellable runs.
                    local sellReason = WC_compCache.sellReasonForSignal
                        and WC_compCache.sellReasonForSignal(
                            WC_compCache.lastSellSignal,
                            quality,
                            DB.qualityRules and DB.qualityRules[quality]
                        )
                        or nil
                    queue[#queue + 1] = {
                        type = "sell",
                        bag = bag,
                        slot = slot,
                        itemID = itemID,
                        count = itemCount,
                        price = sellPrice or 0,
                        quality = quality,
                        reason = sellReason,
                        -- Counted when the sale happens (DoNextAction), so
                        -- items cut by the per-run cap or left by a closed
                        -- merchant never count as gold earned.
                        copper = (sellPrice and sellPrice > 0) and WC_GetItemPrice(link, itemID, sellPrice, itemCount)
                            or 0,
                    }
                end
            end
        end
    end

    -- Batch size, not a limit: FinishRun re-scans and sells the rest in
    -- further batches while the merchant stays open.
    local cap = WC_EffectiveMaxItemsPerRun()
    for i = #queue, cap + 1, -1 do
        queue[i] = nil
    end
end

local function FinishRun()
    WC_compCache.vendorRunning = false
    worker:Hide()

    -- The queue holds only sells since v0.6.0 (deletes are Delete Next).
    WC_batchTotalSold = WC_batchTotalSold + #queue
    WC_batchTotalGold = WC_batchTotalGold + (goldThisVendoring or 0)
    -- v2.37.0: attribute the auto-cycle haul to the current zone so the
    -- Stats panel's "Top Zones" rollup tracks worker sells too.
    if (goldThisVendoring or 0) > 0 then
        WC_compCache.attributeCopperToZone(goldThisVendoring)
        if NS.StampBestGPH then
            NS.StampBestGPH()
        end
    end

    -- One summary builder for the mid-run and final lines below, so the
    -- exit paths can't drift on wording. (The run never deletes since
    -- v0.6.0, so there is no delete phrasing.)
    local function WC_BatchSummary(final)
        if final then
            return string.format(
                L["Vendoring complete! Sold |cffffff00%d|r items. |cffb6ffb6Money Collected:|r %s"],
                WC_batchTotalSold,
                CopperToColoredText(WC_batchTotalGold)
            )
        end
        return string.format(L["Sold |cffffff00%d|r items so far. Checking for more..."], WC_batchTotalSold)
    end

    -- Check if merchant is still open - delay re-scan so server can process sold items
    if MerchantFrame and MerchantFrame:IsShown() then
        PrintNice(WC_BatchSummary(false))
        WC_Delay(1.0, function()
            if not MerchantFrame or not MerchantFrame:IsShown() or WC_compCache.merchantBuysNothing then
                return
            end
            -- A run that started during the wait (merchant re-opened, Force
            -- Sell) owns the queue now; rebuilding it here would wipe it.
            if WC_compCache.vendorRunning then
                return
            end
            -- "Object is busy" means the client dropped a sale rather than
            -- the merchant refusing it, but the slot looks the same at
            -- re-scan, so the refusal marks would skip it for the visit.
            -- Clear them for a re-scan, three times at most per run: an
            -- item the merchant really refuses gets at most three more
            -- tries, never a loop.
            if WC_compCache.vendorBusySeen and (WC_compCache.vendorBusyRetries or 0) < 3 then
                WC_compCache.vendorBusyRetries = (WC_compCache.vendorBusyRetries or 0) + 1
                wipe(WC_vendorRefusedThisRun)
            end
            WC_compCache.vendorBusySeen = false
            BuildQueue(false)
            if #queue > 0 then
                WC_compCache.vendorRunning = true
                worker.t = 0
                worker:Show()
            else
                -- Nothing left - print final summary
                PrintNice(WC_BatchSummary(true))
            end
        end)
        return
    end

    -- All done - print final summary
    PrintNice(WC_BatchSummary(true))

end

local function DoNextAction()
    -- v2.38.2: Turbo Mode runs a batch of N DoNextAction calls per tick
    -- (in the OnUpdate batch loop below). When the queue exhausts mid-batch,
    -- the remaining iterations would re-enter the `not action` branch and
    -- re-fire FinishRun N-1 extra times - resulting in N x "Vendoring
    -- complete!" chat spam AND N x bumps of DB.totalCopper / WC_session.copper.
    -- FinishRun sets vendorRunning to false, so checking it here gates
    -- the post-finish iterations. Belt-and-braces with the batch loop's
    -- own break below.
    if not WC_compCache.vendorRunning then
        return
    end
    if not MerchantFrame or not MerchantFrame:IsShown() then
        WC_compCache.vendorRunning = false
        worker:Hide()
        return
    end

    local action = queue[queueIndex]
    if not action then
        FinishRun()
        return
    end

    -- Safety: verify the item at this slot still matches what we queued.
    -- Bags can shift between queue build and execution (player moves items, etc).
    local currentID = GetContainerItemID(action.bag, action.slot)
    if currentID ~= action.itemID then
        queueIndex = queueIndex + 1
        return
    end

    if action.type == "sell" then
        -- v2.70.0 (competitive-review A4): drain-time re-validation. The
        -- queue was built at StartRun; the user can change a rule while the
        -- worker is mid-burst (Turbo runs up to 80 actions). Re-run the
        -- full sell predicate against CURRENT settings immediately before
        -- the destructive call; when it no longer passes, the item is
        -- SAVED - logged with a reason so Sold History and /wc bugreport
        -- show why nothing happened. Cheap second run: every tooltip-backed
        -- cache is warm from BuildQueue. Deliberately does NOT write the
        -- vendor-refusal mark (nothing was attempted).
        if not WC_IsSellable(action.bag, action.slot, WC_compCache.runJunkOnly) then
            WC_compCache.logRecentSaved(action.itemID, action.count, "sell",
                L["Rules changed during the run - no longer matches a sell rule."])
            queueIndex = queueIndex + 1
            return
        end
        -- v2.9.0: bracket the worker-path UseContainerItem so the
        -- manual-sell hook (installed at ADDON_LOADED) skips this call.
        -- The counters below own the attribution for the worker path.
        WC_manualSell.inSelfSell = true
        UseContainerItem(action.bag, action.slot)
        WC_manualSell.inSelfSell = false
        -- v2.46.4: mark this slot as "attempted" for the vendor-refused
        -- guard. Verification happens at the next BuildQueue (after the
        -- 1s inter-batch gate in FinishRun) when the slot has had time
        -- to empty for a successful sale. If the SAME itemID is still
        -- there at re-scan time, the vendor refused and BuildQueue
        -- skips it. Successful sales leave the slot empty / different,
        -- so the equality check fails and the entry is implicitly
        -- stale (cleared on the next StartRun anyway).
        if action.itemID then
            WC_vendorRefusedThisRun[WC_refusalKey(action.bag, action.slot)] = action.itemID
        end
        -- v2.38.1: helpers write to DB + ADB.accountStats.
        local soldCount = action.count or 1
        WC_BumpStat("totalItemsSold", soldCount)
        WC_session.sold = WC_session.sold + soldCount
        if action.itemID then
            WC_BumpStatBucket("soldItemCounts", action.itemID, soldCount)
        end
        local soldCopper = 0
        if action.quality then
            soldCopper = (action.price or 0) * soldCount
            WC_BumpStatBucket("soldItemsByQuality", action.quality, soldCount)
            WC_BumpStatBucket("soldCopperByQuality", action.quality, soldCopper)
        end
        -- v2.51.0: recent-sold ring buffer for /wc bugreport.
        WC_LogRecentSold(action.itemID, soldCount, "worker", soldCopper, action.reason)
        -- Lifetime and session gold, per sale (v2.38.1 helper writes to DB
        -- + ADB.accountStats). The run summary totals goldThisVendoring.
        local copper = action.copper or 0
        goldThisVendoring = goldThisVendoring + copper
        WC_BumpStat("totalCopper", copper)
        WC_session.copper = WC_session.copper + copper
    end

    queueIndex = queueIndex + 1
end

-- The 0.05s interval floor is an anti-disconnect guarantee, not a performance
-- tuning choice. Faster per-item pacing floods the server with UseContainerItem
-- packets and trips a server-side rate limit that boots the client. See
-- docs/ADDON_GUIDE.md "Performance rules" and v2.0.11 in the README changelog.
-- v2.37.7: Turbo Mode pops WC_EffectiveBatchSize() items per fire. The
-- default batch (1) preserves the v2.0.11 invariant exactly; the opt-in
-- larger batch is gated on DB.turboMode and capped so the per-frame
-- packet count stays bounded.
worker:SetScript("OnUpdate", function(self, elapsed)
    self.t = (self.t or 0) + elapsed
    local interval = WC_EffectiveVendorInterval()
    if self.t >= interval then
        self.t = 0
        local batch = WC_EffectiveBatchSize()
        local _spikeT0 = WC_prof and WC_prof()
        for _ = 1, batch do
            DoNextAction()
            -- v2.38.2: stop iterating the moment FinishRun fires. The
            -- alternative is queue-exhausted DoNextAction calls
            -- repeating FinishRun once per remaining batch slot.
            if not WC_compCache.vendorRunning then
                break
            end
        end
        if _spikeT0 then
            WC_spikePhase.vendor = WC_spikePhase.vendor + (WC_prof() - _spikeT0)
        end
    end
end)

-- The merchant's answers to a sale arrive as error messages. A merchant
-- that buys nothing stops the run at once: every further sale would fail
-- the same way, and the run would otherwise try (and count) every item.
-- It stays stopped for the visit (cleared on MERCHANT_CLOSED). A busy
-- answer is noted for the re-scan in FinishRun. Hidden frames still get
-- events, so the worker listens between batches too. The ERR_* strings are
-- read from _G at call time: a missing one is nil and never matches.
worker:RegisterEvent("UI_ERROR_MESSAGE")
worker:SetScript("OnEvent", function(self, _, _, message)
    if not message or not (MerchantFrame and MerchantFrame:IsShown()) then
        return
    end
    if message == _G.ERR_OBJECT_IS_BUSY then
        WC_compCache.vendorBusySeen = true
    elseif message == _G.ERR_VENDOR_DOESNT_BUY or message == _G.ERR_VENDOR_HATES_YOU then
        if not WC_compCache.merchantBuysNothing then
            WC_compCache.merchantBuysNothing = true
            PrintNice(L["|cffffb84dThis merchant doesn't buy items. Selling stopped.|r"])
        end
        WC_compCache.vendorRunning = false
        self:Hide()
    end
end)

-- Mouse-over preview: counts what BuildQueue would sell right now. When no
-- merchant is targeted, fall back to the broadest case (merchantAllowed=true)
-- so the preview reflects the whitelist/quality threshold, not only greys.
local function WC_PreviewSellable()
    if not DB then
        return 0, 0
    end
    local junkOnly = false
    local count, copper = 0, 0
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local sellable, link, itemID, sellPrice, itemCount = WC_IsSellable(bag, slot, junkOnly)
            if sellable then
                count = count + (itemCount or 1)
                if sellPrice and sellPrice > 0 then
                    copper = copper + WC_GetItemPrice(link, itemID, sellPrice, itemCount)
                end
            end
        end
    end
    return count, copper
end
-- Exposed to split files. The minimap mouse-over tooltip (now in
-- WoWClearance_Minimap.lua post-Stage-8b) calls this for its
-- "Sellable now: N items" + "Est. value: ..." lines. Also reachable
-- by the LDB launcher's `OnTooltipShow`.
NS.PreviewSellable = WC_PreviewSellable

-- The Release-1 bag-display layer (sell-border tint helpers, the
-- NS.RefreshSellBorders body, the sellability-trace inspector that
-- drives /wc sellinfo and Alt+Shift+Right-Click, plus the
-- bagSlotFromButton helper) all live in WoWClearance_BagDisplay.lua
-- after Stage 6 of the file split. Every helper is attached to
-- WC_compCache (= NS.compCache, declared in Core), so call sites in
-- this file already resolve via the shared cache table and need no
-- changes. NS.RefreshSellBorders is forward-declared as a no-op stub
-- near the top of THIS file (so the Character Settings panel toggle
-- can call it before BagDisplay loads its real body).


local function StartRun(force)
    if not WC_IsAddonEnabledForChar() then
        return
    end
    WC_StampEvent("vendorRunStart")
    if WC_compCache.vendorRunning then
        return
    end
    if WC_compCache.merchantBuysNothing then
        PrintNice(L["|cffffb84dThis merchant doesn't buy items. Selling stopped.|r"])
        return
    end

    WC_compCache.vendorRunning = true

    -- v2.46.4: fresh merchant cycle, fresh attempts. See declaration
    -- of WC_vendorRefusedThisRun above for the wedge bug this guards.
    wipe(WC_vendorRefusedThisRun)
    WC_compCache.vendorBusySeen = false
    WC_compCache.vendorBusyRetries = 0

    WC_RecordInventoryWorthSample()

    -- Auto-repair. v2.9.0 added the optional guild-bank branch: when
    -- DB.repairUseGuildBank is on AND the player is in a guild AND the
    -- guild bank can fund the full repair cost, RepairAllItems(true) charges
    -- the bank instead of personal gold. Any miss in the guild chain
    -- falls through to the existing personal-gold branch.
    if
        DB
        and DB.repairGear == true
        and CanMerchantRepair
        and CanMerchantRepair()
        and GetRepairAllCost
        and RepairAllItems
    then
        local repairCost, canRepair = GetRepairAllCost()
        if canRepair and repairCost and repairCost > 0 then
            local useGuild = DB.repairUseGuildBank == true
                and IsInGuild
                and IsInGuild()
                and CanGuildBankRepair
                and CanGuildBankRepair()
            if useGuild then
                -- What the guild will pay, as Blizzard's repair button
                -- reckons it (MerchantFrame.xml:351): -1 is a guild leader
                -- with no limit, and any limit is capped by the bank balance.
                local funds = GetGuildBankWithdrawMoney()
                local bank = GetGuildBankMoney()
                if funds == -1 or funds > bank then
                    funds = bank
                end
                useGuild = funds >= repairCost
            end
            if useGuild then
                RepairAllItems(true) -- true = use guild bank funds
                -- v2.38.1: helpers write to DB + ADB.accountStats.
                WC_BumpStat("totalRepairs", 1)
                WC_BumpStat("totalRepairCopper", repairCost)
                WC_session.repairs = WC_session.repairs + 1
                WC_session.repairCopper = WC_session.repairCopper + repairCost
                PrintNicef(L["Repaired from guild bank: %s"], CopperToColoredText(repairCost))
            elseif GetMoney and GetMoney() >= repairCost then
                RepairAllItems()
                WC_BumpStat("totalRepairs", 1)
                WC_BumpStat("totalRepairCopper", repairCost)
                WC_session.repairs = WC_session.repairs + 1
                WC_session.repairCopper = WC_session.repairCopper + repairCost
            end
        end
    end

    -- "Sell at vendors" off: repair above still runs; only the automatic
    -- sell is skipped. Force Sell (the key binding) is explicit and sells.
    if not force and DB and DB.sellAtVendor == false then
        WC_compCache.vendorRunning = false
        return
    end

    BuildQueue(false)

    if #queue == 0 then
        PrintNice(L["Nothing to sell."])
        WC_compCache.vendorRunning = false
        return
    end

    worker.t = 0
    worker:Show()
end

-- The tooltip annotation system (WC_AnnotateTooltip + WC_ClearTooltipFlag
-- + WC_InstallTooltipHookOnce) lives in WoWClearance_Tooltip.lua after
-- Stage 8c of the file split. Exposed as NS.InstallTooltipHookOnce for
-- the ADDON_LOADED branch in this file to call.


-- v2.16.0: Fast Loot BoP-bind auto-dismiss. When Fast Loot is on and the
-- user loots a Bind-on-Pickup item, Blizzard normally shows a LOOT_BIND
-- popup asking "are you sure?". That popup blocks the rest of the loot
-- queue draining and defeats the point of Fast Loot. This hook auto-
-- confirms each LootSlot call and force-hides the popup. Self-gates on
-- DB.fastLoot at call time so non-Fast-Loot users keep the Blizzard
-- safety prompt. Idempotent: the hookedOnce guard makes a second call
-- cheap if anything ever calls this twice. Pattern borrowed from
-- LootClicker (others/LootClicker-master/core.lua:158-161).
local WC_fastLootHooked = false
local function WC_InstallFastLootHookOnce()
    if WC_fastLootHooked then
        return
    end
    WC_fastLootHooked = true
    hooksecurefunc("LootSlot", function(slot)
        if not DB or not DB.fastLoot then
            return
        end
        ConfirmLootSlot(slot)
        StaticPopup_Hide("LOOT_BIND")
    end)
end




-- The list-row factories (WC_compCache.makeListRowFactory,
-- buildListHeaderRow, buildListSearchAndSortRow,
-- buildListScrollArea) live in WoWClearance_ListWidget.lua after
-- Stage 8e-ix-d of the file split. Hung off WC_compCache (not as
-- file-scope locals) to stay under Lua 5.1's 200-locals-per-main-chunk
-- cap.

-- ---------------------------------------------------------------------------
-- Panel-text principle (v2.20.2)
-- ---------------------------------------------------------------------------
-- Panel descriptions (yellow MakeLabel) and grey checkbox notes
-- (|cff888888...|r) should answer one of three questions for the
-- player:
--   1. What does this do?
--   2. When does it apply?
--   3. How do I override it?
-- If a sentence explains WHY a feature exists, cites version history,
-- or names an internal mechanism, cut it. The player doesn't care; we
-- have CLAUDE.md and source comments for that. Same lens applies when
-- adding a new toggle or panel description.


-- CreateListUI body lives in WoWClearance_ListWidget.lua after
-- Stage 8e-ix-d of the file split. Exposed as NS.CreateListUI for
-- split panel files that need to build a list widget.


-- The minimap button, LDB launcher, and combat-vendor button live in
-- WoWClearance_Minimap.lua after Stage 8b of the file split. Exposed
-- as NS.CreateMinimapButton, NS.CreateLDBLauncher,
-- NS.UpdateMinimapPos.


-- v2.13.3: removed the dormant vendor-button cluster (WC_vendorButton,
-- WC_CreateVendorButton, WC_SaveVendorButtonPos, WC_UpdateVendorButtonVisibility,
-- and the vendorBtn{X,Y,Point,RelPoint,Shown} DB fields). The cluster had
-- carried a luacheck:ignore suppression because no caller existed since
-- before v2.13.0. If a future opt-in vendor button is desired, build it
-- fresh on top of WC_CreateTargetMerchantButton (the existing combat-safe
-- SecureActionButton helper) rather than reviving this dead surface.

StaticPopupDialogs["WC_CONFIRM_RESET_LIFETIME"] = {
    text = L["Reset |cffb6ffb6WoWClearance|r lifetime stats?\n|cffaaaaaaThis clears money earned, items sold, items deleted, and repair totals. Session stats are not affected.|r"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["WC_CONFIRM_RESET_SESSION"] = {
    text = L["Reset session stats?"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- v2.72.0: confirm popups triggered from inside the Interface Options
-- window can spawn UNDER it - the options frame is toplevel
-- (click-raises above same-strata siblings) and sits high enough that
-- FULLSCREEN_DIALOG was still not above it in the field. TOOLTIP is the
-- strata this codebase already uses for pop-outs that must beat the
-- settings window (NS.RaiseTooltipAboveWindows precedent). Raise while
-- shown and restore on hide - scoped per-show because Blizzard REUSES
-- the StaticPopup1..4 frames for its own dialogs; a permanent strata
-- change would leak onto those.
WC_compCache.popupRaiseOnShow = function(self)
    self._ecPrevStrata = self:GetFrameStrata()
    self:SetFrameStrata("TOOLTIP")
end
WC_compCache.popupRaiseOnHide = function(self)
    if self._ecPrevStrata then
        self:SetFrameStrata(self._ecPrevStrata)
        self._ecPrevStrata = nil
    end
end

StaticPopupDialogs["WC_CONFIRM_DELETE_PROFILE"] = {
    text = L['Delete profile "|cffffff00%s|r"?\n|cffaaaaaaThis cannot be undone.|r'],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    OnShow = WC_compCache.popupRaiseOnShow,
    OnHide = WC_compCache.popupRaiseOnHide,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- v2.72.0: deleting a settings profile repoints every character that
-- used it back to Default, so spell that out in the prompt.
StaticPopupDialogs["WC_CONFIRM_DELETE_SPROFILE"] = {
    text = L['Delete settings profile "|cffffff00%s|r"?\n|cffaaaaaaCharacters using it switch to Default. This cannot be undone.|r'],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    OnShow = WC_compCache.popupRaiseOnShow,
    OnHide = WC_compCache.popupRaiseOnHide,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- v2.75.0 (fresh-audit fix): saving over an existing same-name settings
-- profile used to overwrite it silently (delete had a confirm, save did not).
StaticPopupDialogs["WC_CONFIRM_OVERWRITE_SPROFILE"] = {
    text = L['Overwrite settings profile "|cffffff00%s|r"?\n|cffaaaaaaIts saved settings are replaced with this character\'s current ones. This cannot be undone.|r'],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    OnShow = WC_compCache.popupRaiseOnShow,
    OnHide = WC_compCache.popupRaiseOnHide,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["WC_CONFIRM_CLEAR_PROFILE"] = {
    text = L['Clear all items from profile "|cffffff00%s|r"?\n|cffaaaaaaThe profile itself will remain.|r'],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    OnShow = WC_compCache.popupRaiseOnShow,
    OnHide = WC_compCache.popupRaiseOnHide,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Generic confirmation for the per-list "Clear All" button on every list panel
-- (Whitelist - Character / Whitelist - Account / Blacklist / Deletion List).
-- The %s slot is filled with the list's user-facing title.
StaticPopupDialogs["WC_CONFIRM_CLEAR_LIST"] = {
    -- v2.76.0 (Serv report): names the count as well as the list. Knowing
    -- you are about to drop 327 entries is the thing that makes an
    -- irreversible confirmation worth reading.
    text = L['Remove all |cffffff00%s|r items from |cffffff00%s|r?\n|cffaaaaaaThis cannot be undone.|r'],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- v2.12.0 stale-upgrade cleanup confirmation popup. The %d slot is filled
-- with the count of stale entries detected by /wc clean upgrades. The
-- OnAccept invokes the callback function passed via StaticPopup_Show's
-- third "data" argument, mirroring the WC_CONFIRM_CLEAR_LIST pattern.
-- v2.49.2: conflicting-addon warning popup. Shown once at PLAYER_LOGIN
-- when WC's delete path is active AND the detected conflicting addon is
-- loaded AND the player hasn't opted out. Modal so it can't be missed
-- (a one-time chat line was easy to scroll past). "Open Settings" jumps
-- to the main panel where the opt-out toggle lives.
-- WC-TRAP: this popup deliberately NAMES the conflicting addon ("Auto
-- Delete") - a user-sanctioned exception to the "No third-party addon
-- references in new WC artefacts" rule, granted because the detection is
-- folder-specific and naming it makes the warning actionable. The
-- exception is THIS STRING ONLY: the detection helper, all comments, and
-- the /wc bugreport line stay neutral. Do NOT propagate the name
-- elsewhere, and do NOT "neutralise" this string back.
StaticPopupDialogs["WC_CONFLICT_WARNING"] = {
    text = L["|cffff4444Another addon that deletes items is also running.|r Running both can make items disappear unexpectedly. Turn one off. You can silence this warning in WoWClearance settings."],
    button1 = L["Open Settings"],
    button2 = OKAY,
    OnAccept = function()
        NS.OpenOptionsPanel("WoWClearanceOptionsMain")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["WC_CONFIRM_CLEAN_UPGRADES"] = {
    text = L["Remove |cffffff00%d|r stale 'Upgrade'-tagged entries from your Keep List?\n|cffaaaaaaThese items were auto-tagged as upgrades but are no longer above your currently-equipped iLvl. Manual Keep List entries (no auto-tag) and 'Worn'-tagged entries are not affected.|r"],
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- v2.12.0 first-run welcome popup. Fired once on PLAYER_LOGIN when EnsureDB
-- detected a fresh install (DB._needsWelcome). Two-button choice:
-- Keep Defaults (closes silently after a chat ack) or Open Settings (jumps
-- the options frame to the WoWClearance main panel, via NS.OpenOptionsPanel -
-- the same helper the slash command's "open settings" fallback uses).
-- v2.38.0: confirmation popup for the Quickstart panel's Apply button.
-- The text() callback fills the preset name (or "your tailored answers")
-- via the dialog's `data` arg captured at StaticPopup_Show time. OnAccept
-- reads data.answers / data.fixedCaps / data.presetKey and calls
-- NS.Quickstart.Apply. The popup is settings-only - the body text spells
-- this out so a player who applies a preset can't be surprised about
-- Sell / Keep / Delete lists.
StaticPopupDialogs["WC_APPLY_QUICKSTART"] = {
    text = L["Apply %s?\n\nThis changes your speed, protection, auto-sell, and visual settings, and turns vendor selling on.\n\nYour |cffb6ffb6Sell|r, |cffb6ffb6Keep|r, and |cffb6ffb6Delete|r lists stay exactly as they are."],
    button1 = "Apply",
    button2 = CANCEL,
    OnAccept = function(self, data)
        if data and NS.Quickstart and NS.Quickstart.Apply then
            NS.Quickstart.Apply(data.answers, data.fixedCaps, data.presetKey)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Build the static widgets for the main options panel. Called once per panel
-- (guarded by `panel.inited` in OnShow). `refreshStats` is the dynamic refresh
-- callback captured by the Reset button.


-- Root category. Everything else registers as a SUBcategory of this, in the
-- order of the calls further down, which is what sets sidebar order.
-- v0.5.4: the Main panel is NO LONGER the Settings root. Settings gets a
-- single launcher page (WoWClearanceOptionsLauncher, built in
-- WoWClearance_Window.lua) whose only job is a button that opens the
-- standalone window. Registering real panels in Settings is what closed the
-- player's bags; see the WC-TRAP in that file before undoing this.
-- v2.38.0: Quickstart is intentionally NOT registered as an Interface
-- Options sub-panel - it's a standalone modal frame parented to UIParent.
-- The only entry points are the "Open Quickstart" button on the Main
-- panel and the fresh-install PLAYER_LOGIN auto-open. Keeps the sidebar
-- focused on the long-form settings panels.


-- CreateListUI, the 5 list-row factories, and WC_AddScanByQualityRow live in
-- WoWClearance_ListWidget.lua after Stage 8e-ix-d of the file split. Exposed
-- as NS.CreateListUI and NS.AddScanByQualityRow for split panel files.


-- ============================================================
-- Whitelist Profiles Panel



-- v2.11.0 reactive panel layout. The Interface Options frame is user-
-- resizable in some UI mod packs (and the resize handle is exposed as a
-- draggable widget on PE-ElvUI). Pre-v2.11.0 the addon's panels stayed
-- clamped at their build-time width because every label, scroll-content,
-- and list-row width was a snapshot of WC_PANEL_WIDTH taken at first
-- OnShow. Hooking the Settings container's OnSizeChanged once routes every
-- registered widget through WC_compCache.refreshLayouts on each resize -
-- labels re-wrap, scroll content re-fits, list frames already track via
-- BOTTOMRIGHT anchors (their visible drift was just label clutter on
-- top, fixed by the same width refresh).
do
    local host = NS.OptionsHost and NS.OptionsHost()
    if host and host.HookScript then
        host:HookScript("OnSizeChanged", function()
            WC_compCache.refreshLayouts()
        end)
    end
end

-- The bug-report diagnostic snapshot (WC_CopperToPlainText,
-- WC_BuildBugReport, WC_ShowBugReport) lives in
-- WoWClearance_BugReport.lua after Stage 8 of the file split.
-- Exposed as NS.ShowBugReport for the button on the main settings panel.


-- Conflict detection + resolution across whitelist/blacklist/deleteList.
-- Precedence when auto-resolving: blacklist > deleteList > whitelist.
-- Keybinding registration. Populates the "WoWClearance" section of
-- ESC -> Key Bindings. The operational bindings (open/close settings,
-- toggle enabled, force sell at current merchant, toggle loot log) are
-- declared in Bindings.xml and wired to the WoWClearance_* global handlers
-- further down this file; "Process Next" is dispatched through a hidden
-- SecureActionButton so it works in combat lockdown.
BINDING_HEADER_WOWCLEARANCE = "WoWClearance"
-- Secure click bindings show their raw "CLICK <button>:<mouseButton>" action
-- string in the keybind UI unless a BINDING_NAME_ global gives them a label.
_G["BINDING_NAME_CLICK WoWClearanceProcessCastBtn:LeftButton"] = "Process Next"
BINDING_NAME_WOWCLEARANCE_TOGGLE_SETTINGS = "Open/close settings"
BINDING_NAME_WOWCLEARANCE_TOGGLE_ENABLED = "Toggle enabled"
BINDING_NAME_WOWCLEARANCE_FORCE_SELL = "Force sell at current merchant"
BINDING_NAME_WOWCLEARANCE_TOGGLE_LOOTLOG = "Open/close Loot Log"
BINDING_NAME_WOWCLEARANCE_DELETE_NEXT = "Delete next Delete List item"
-- Cross-list intent groups for the add-time conflict guard:
--   keep   = whitelist (per-character) + accountWhitelist (account-wide)
--   sell   = blacklist
--   delete = deleteList
-- Same-intent scopes are NOT in conflict (whitelist + accountWhitelist is
-- redundant, not contradictory). Cross-intent IS the conflict we refuse at
-- input time. The post-hoc WC_ApplyCleanResolution below remains as the
-- legacy-data safety net for DBs that pre-date this guard.
--
-- Returns the name of an already-occupying list with a different intent,
-- or nil when the add is safe. Forward-declared at the top of the file so
-- WC_AddItemToList can call it before this body is reached.
WC_FindAddConflict = function(itemID, targetListName)
    if not itemID or not targetListName then
        return nil
    end
    local function intentOf(n)
        if n == "whitelist" or n == "accountWhitelist" then
            return "keep"
        end
        if n == "blacklist" then
            return "sell"
        end
        if n == "deleteList" then
            return "delete"
        end
        return nil
    end
    local targetIntent = intentOf(targetListName)
    if not targetIntent then
        return nil
    end
    local checks = {
        { name = "blacklist", data = DB and DB.blacklist },
        { name = "deleteList", data = DB and DB.deleteList },
        { name = "whitelist", data = DB and DB.whitelist },
        { name = "accountWhitelist", data = ADB and ADB.whitelist },
    }
    for i = 1, #checks do
        local c = checks[i]
        if c.name ~= targetListName and c.data and c.data[itemID] and intentOf(c.name) ~= targetIntent then
            return c.name
        end
    end
    return nil
end
-- Exposed to split files. Stage 8d uses NS.FindAddConflict from the bag
-- context menu's row-click conflict guard (refuses the add at click time
-- when the item is already on a different-intent list).
NS.FindAddConflict = WC_FindAddConflict

local function WC_ScanListConflicts()
    local lists = {
        { name = "whitelist", data = DB.whitelist },
        { name = "blacklist", data = DB.blacklist },
        { name = "deleteList", data = DB.deleteList },
    }
    local where = {}
    for i = 1, #lists do
        local e = lists[i]
        if type(e.data) == "table" then
            for id in pairs(e.data) do
                if type(id) == "number" then
                    where[id] = where[id] or {}
                    where[id][#where[id] + 1] = e.name
                end
            end
        end
    end
    local conflicts = {}
    for id, names in pairs(where) do
        if #names >= 2 then
            conflicts[#conflicts + 1] = { id = id, lists = names }
        end
    end
    table.sort(conflicts, function(a, b)
        return a.id < b.id
    end)
    return conflicts
end

local function WC_PrintConflictReport(conflicts)
    if #conflicts == 0 then
        PrintNice(L["|cff00ff00No list conflicts found.|r"])
        return
    end
    PrintNicef(L["Found |cffffff00%d|r item(s) present in multiple lists:"], #conflicts)
    for i = 1, #conflicts do
        local c = conflicts[i]
        local name = GetItemInfo(c.id) or ("ItemID:" .. c.id)
        PrintNicef(L["  |cffb6ffb6%d|r  %s  [%s]"], c.id, name, table.concat(c.lists, ", "))
    end
end

local function WC_ApplyCleanResolution(conflicts)
    local removed = 0
    for i = 1, #conflicts do
        local c = conflicts[i]
        local inBL, inDel, inWL = false, false, false
        for j = 1, #c.lists do
            local n = c.lists[j]
            if n == "blacklist" then
                inBL = true
            elseif n == "deleteList" then
                inDel = true
            elseif n == "whitelist" then
                inWL = true
            end
        end
        if inBL and inWL then
            DB.whitelist[c.id] = nil
            removed = removed + 1
        end
        if inBL and inDel then
            DB.deleteList[c.id] = nil
            removed = removed + 1
        end
        if inDel and inWL then
            DB.whitelist[c.id] = nil
            removed = removed + 1
        end
    end
    return removed
end

-- v2.12.0 stale-upgrade scanner. Walks DB.blacklistAuto entries with the
-- "upgrade" tag and re-evaluates each against the player's currently-
-- equipped gear. Returns three lists:
--   stale    - entries that are no longer upgrades (iLvl <= lowest equipped)
--   deferred - entries we couldn't evaluate (GetItemInfo not loaded yet)
--   skipped  - entries we can't evaluate (no equipLoc / all candidate slots
--              empty / equipLoc not in INVTYPE_SLOTS); these stay put
-- Mirror of WC_compCache.checkBagsForUpgrades' eligibility logic, inverted.
-- Hung off WC_compCache to avoid burning two main-chunk local slots
-- (Lua 5.1 caps that at 200 and we sit near it).
function WC_compCache.buildStaleUpgradeReport()
    local stale, deferred, skipped = {}, {}, {}
    if not DB or type(DB.blacklistAuto) ~= "table" then
        return { stale = stale, deferred = deferred, skipped = skipped }
    end
    for id, tag in pairs(DB.blacklistAuto) do
        if tag == "upgrade" and DB.blacklist and DB.blacklist[id] then
            local name, _, _, iLvl, _, _, _, _, equipLoc = GetItemInfo(id)
            if not name or not iLvl then
                deferred[#deferred + 1] = id
            else
                local slots = WC_compCache.upgradeSlotsFor(equipLoc)
                if not slots then
                    skipped[#skipped + 1] = { id = id, name = name }
                else
                    local lowestEquipped = WC_compCache.getLowestEquippedILvl(slots)
                    if not lowestEquipped then
                        skipped[#skipped + 1] = { id = id, name = name }
                    elseif iLvl <= lowestEquipped then
                        stale[#stale + 1] = { id = id, name = name, iLvl = iLvl, lowestEquipped = lowestEquipped }
                    end
                end
            end
        end
    end
    return { stale = stale, deferred = deferred, skipped = skipped }
end

-- Removes the entries flagged as stale by buildStaleUpgradeReport.
-- Pulls them out of both DB.blacklist and DB.blacklistAuto so the tooltip
-- annotation and WC_IsSellable both stop treating them as protected.
-- Returns the count of removed entries.
function WC_compCache.applyStaleUpgradeCleanup(report)
    if not report or not report.stale then
        return 0
    end
    local removed = 0
    for i = 1, #report.stale do
        local id = report.stale[i].id
        if DB.blacklist and DB.blacklist[id] then
            DB.blacklist[id] = nil
        end
        if DB.blacklistAuto and DB.blacklistAuto[id] then
            DB.blacklistAuto[id] = nil
        end
        removed = removed + 1
    end
    return removed
end

-- Handlers for the three operational keybindings (declared in Bindings.xml,
-- labels above with the binding registration block).
function WoWClearance_ToggleSettings()
    if NS.StandaloneHost and NS.StandaloneHost() then
        NS.HideStandaloneWindow()
    elseif SettingsPanel and SettingsPanel:IsShown() then
        SettingsPanel:Hide()
    else
        NS.OpenOptionsPanel("WoWClearanceOptionsMain")
    end
end

function WoWClearance_ToggleLootLog()
    EnsureDB()
    if NS.ToggleLootWindow then
        NS.ToggleLootWindow()
    end
end

-- Default key for the Loot Log: Shift+L. Claimed ONCE per account
-- (ADB.lootLogKeyClaimed) and only when both sides are free - the Loot Log
-- has no key yet AND nothing else uses Shift+L - so it never overwrites a
-- binding, and a player who later unbinds it does not get it back. Run a few
-- seconds after login, not at PLAYER_LOGIN itself: saving the binding set
-- before the client has loaded it could write over the player's bindings.
-- SetBinding is blocked in combat, so a combat login just tries next login.
function WC_compCache.claimLootLogKey()
    if not ADB or ADB.lootLogKeyClaimed or InCombatLockdown() then
        return
    end
    ADB.lootLogKeyClaimed = true
    if GetBindingKey("WOWCLEARANCE_TOGGLE_LOOTLOG") then
        return
    end
    local current = GetBindingAction("SHIFT-L")
    if current and current ~= "" then
        return
    end
    if SetBinding("SHIFT-L", "WOWCLEARANCE_TOGGLE_LOOTLOG") then
        SaveBindings(GetCurrentBindingSet())
        PrintNice(L["Shift+L now opens the Loot Log. Change it under Key Bindings > WoWClearance."])
    end
end

function WoWClearance_ToggleEnabled()
    EnsureDB()
    DB.enabled = not DB.enabled
    PrintNicef(L["Now %s."], DB.enabled and L["|cff00ff00enabled|r"] or L["|cffff4444disabled|r"])
    PlaySound(DB.enabled and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    -- v2.39.1: single source of truth for the master Enable state.
    -- The helper now refreshes every UI surface that mirrors
    -- DB.enabled so a flip via ANY entry point (minimap right-click,
    -- Main panel checkbox, /wc enable / disable, keybind, LDB
    -- launcher) keeps every other surface in sync. Without this,
    -- toggling via the panel left the minimap icon stuck saturated
    -- (and vice versa) - bug found right after v2.39.1 wired the
    -- panel checkbox.
    local mb = NS.GetMinimapButton and NS.GetMinimapButton()
    if mb and mb.icon and mb.icon.SetDesaturated then
        mb.icon:SetDesaturated(not DB.enabled)
    end
    local mp = _G["WoWClearanceOptionsMain"]
    if mp and mp.enableCB then
        mp.enableCB:SetChecked(DB.enabled ~= false)
    end
end

function WoWClearance_ForceSell()
    EnsureDB()
    if not MerchantFrame or not MerchantFrame:IsShown() then
        PrintNice(L["|cffff4444Force sell|r: open a merchant first."])
        return
    end
    StartRun(true)
end

-- Delete ONE item: the next eligible Delete List item, else (with "Mark grey
-- items for deletion" on) the cheapest grey. Bound to a key and to the
-- Delete List panel's button, so it runs inside the player's key press or
-- click: the only time Forever allows DeleteCursorItem (WC-TRAP on
-- executeBagSlotDelete). MEASURED 2026-10-10: the button deleted a green
-- with no popup.
function WoWClearance_DeleteNext()
    EnsureDB()
    if not WC_IsAddonEnabledForChar() or not DB.enableDeletion then
        PrintNice(L["Deleting is turned off in WoWClearance."])
        return
    end
    -- The gate is open only for this one call, inside the player's input.
    local function deleteNow(bag, slot, id, count, quality)
        WC_compCache.deleteFromInput = true
        local ok = pcall(WC_compCache.executeBagSlotDelete, bag, slot, id, count, quality, true)
        WC_compCache.deleteFromInput = false
        if not ok then
            ClearCursor()
        end
    end
    local snap = WC_compCache.acquireFlushSnapshot()
    for i = 1, #snap.entries do
        local e = snap.entries[i]
        if IsInSet(DB.deleteList, e.itemID) then
            local id, count, quality = WC_compCache.deleteListSlotEligible(e.bag, e.slot)
            if id then
                deleteNow(e.bag, e.slot, id, count, quality)
                return
            end
        end
    end
    if DB.markGreyForDeletion then
        local bag, slot, id, count, quality = WC_compCache.nextGreyToDelete()
        if bag then
            deleteNow(bag, slot, id, count, quality)
            return
        end
    end
    PrintNice(L["Nothing to delete in your bags."])
end

SLASH_WOWCLEARANCE1 = "/wc"
SlashCmdList["WOWCLEARANCE"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" then
        NS.OpenOptionsPanel("WoWClearanceOptionsMain")
        return
    end

    local cmd, rest = msg:match("^(%S+)%s*(.*)")
    cmd = (cmd or ""):lower()
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if cmd == "profile" or cmd == "profiles" then
        local sub, arg = rest:match("^(%S+)%s*(.*)")
        sub = (sub or ""):lower()
        arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")

        if sub == "save" and arg ~= "" then
            EnsureDB()
            -- Discard the boolean ok flag; PrintNice surfaces the failure
            -- message itself for the user. Renamed local from `msg` to
            -- `result` to avoid shadowing the outer slash-input `msg`.
            local _, result = WC_SaveProfile(arg)
            PrintNice(result)
        elseif sub == "load" and arg ~= "" then
            EnsureDB()
            local _, result = WC_LoadProfile(arg)
            PrintNice(result)
        elseif sub == "delete" and arg ~= "" then
            EnsureDB()
            local _, result = WC_DeleteProfile(arg)
            PrintNice(result)
        elseif sub == "list" or sub == "" then
            EnsureDB()
            PrintNice(L["List Profiles:"])
            local names = {}
            for name in pairs(DB.whitelistProfiles) do
                if type(name) == "string" then
                    names[#names + 1] = name
                end
            end
            table.sort(names, function(a, b)
                return a:lower() < b:lower()
            end)
            for i = 1, #names do
                local wlCount = WC_CountItems(DB.whitelistProfiles[names[i]])
                local blCount = DB.blacklistProfiles[names[i]] and WC_CountItems(DB.blacklistProfiles[names[i]]) or 0
                local tag = (names[i] == DB.activeProfileName) and L[" |cff00ff00(active)|r"] or ""
                PrintNicef(L["  |cffffff00%s|r - %d sell, %d keep%s"], names[i], wlCount, blCount, tag)
            end
        else
            PrintNice(L["Usage: /wc profile save|load|delete|list <name>"])
        end
        return
    elseif cmd == "sprofile" or cmd == "sprofiles" then
        -- v2.72.0 settings profiles (selling behaviour per character).
        local sub, arg = rest:match("^(%S+)%s*(.*)")
        sub = (sub or ""):lower()
        arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")

        if sub == "save" and arg ~= "" then
            EnsureDB()
            local _, result = NS.SaveSettingsProfile(arg)
            PrintNice(result)
        elseif sub == "use" and arg ~= "" then
            EnsureDB()
            local _, result = NS.UseSettingsProfile(arg)
            PrintNice(result)
        elseif sub == "delete" and arg ~= "" then
            EnsureDB()
            local _, result = NS.DeleteSettingsProfile(arg)
            PrintNice(result)
        elseif sub == "list" or sub == "" then
            EnsureDB()
            PrintNice(L["Settings Profiles:"])
            local profiles = WoWClearanceDB.settingsProfiles or {}
            local names = {}
            for name in pairs(profiles) do
                if type(name) == "string" then
                    names[#names + 1] = name
                end
            end
            table.sort(names, function(a, b)
                return a:lower() < b:lower()
            end)
            local chars = WoWClearanceDB.chars or {}
            for i = 1, #names do
                local users = 0
                for _, charNS in pairs(chars) do
                    if (charNS.activeSettingsProfile or "Default") == names[i] then
                        users = users + 1
                    end
                end
                local tag = (names[i] == (DB.activeSettingsProfile or "Default")) and L[" |cff00ff00(this character)|r"]
                    or ""
                PrintNicef(L["  |cffffff00%s|r - used by %d character(s)%s"], names[i], users, tag)
            end
        else
            PrintNice(L["Usage: /wc sprofile save|use|delete|list <name>"])
        end
        return
    end

    if cmd == "bugreport" then
        NS.ShowBugReport()
        return
    end

    if cmd == "commtest" then
        -- v2.39.0: solo diagnostic for the version-alert comms layer.
        -- Tests wire relay (guild echo) and the nudge logic (simulated peer).
        if NS.Comms then
            NS.Comms.RunSelfTest()
        else
            PrintNice(L["|cffff4444Comms module not loaded.|r"])
        end
        return
    end

    if cmd == "guildtest" then
        -- Solo diagnostic for the guild-share panel: inject simulated members.
        if NS.GuildShare then
            local n = NS.GuildShare.InjectTestPeers()
            PrintNicef(L["Injected %d simulated guild members. Open the Guild panel (or re-run this with it open) to see the pooled data."], n)
        else
            PrintNice(L["|cffff4444Guild-share module not loaded.|r"])
        end
        return
    end

    if cmd == "servertest" then
        -- v2.58.0: solo diagnostic for the Server Stats odometer. Injects fake
        -- realm sharers (including a spoofed one the sanity cap must drop) so
        -- the panel + live user-count can be exercised on one account.
        if NS.ServerShare then
            local n = NS.ServerShare.InjectTestPeers()
            PrintNicef(L["Injected %d simulated realm sharer(s). Open the Server panel to see the odometer (the spoofed one should be ignored)."], n)
        else
            PrintNice(L["|cffff4444Server-share module not loaded.|r"])
        end
        return
    end

    if cmd == "realmtest" then
        -- v2.58.0: solo diagnostic for the realm channel transport. Chat
        -- channels echo your own messages, so this verifies join/hide/send/
        -- receive with no second player.
        if NS.RealmComms then
            NS.RealmComms.RunSelfTest()
        else
            PrintNice(L["|cffff4444Realm comms module not loaded.|r"])
        end
        return
    end

    if cmd == "status" or cmd == "enable" or cmd == "disable" then
        -- v2.39.1: discoverable surface for the master Enable toggle.
        -- Pre-v2.39.1 the only ways to flip DB.enabled were the
        -- minimap right-click (subtle) or a keybind (only fires if
        -- bound). A real player report (Paladin, v2.39.0) showed up
        -- with `Enabled: false` in their bug report and "the addon
        -- stopped working" because they had no idea they'd disabled
        -- it. These three subcommands give a slash-driven recovery
        -- path that complements the new Main panel checkbox.
        EnsureDB()
        local currentlyEnabled = DB and DB.enabled ~= false
        if cmd == "status" then
            PrintNicef(
                L["Currently %s."],
                currentlyEnabled and L["|cff00ff00ENABLED|r"] or L["|cffff4444DISABLED|r"]
            )
            PrintNice(L["|cff888888Right-click the minimap icon, tick the Main panel checkbox, or type /wc enable / /wc disable to switch.|r"])
        elseif cmd == "enable" then
            if currentlyEnabled then
                PrintNice(L["Already enabled."])
            else
                WoWClearance_ToggleEnabled()
            end
        elseif cmd == "disable" then
            if not currentlyEnabled then
                PrintNice(L["Already disabled."])
            else
                WoWClearance_ToggleEnabled()
            end
        end
        -- v2.39.1: no need to re-sync UI surfaces here -
        -- WoWClearance_ToggleEnabled() does that for every entry
        -- point. The status-only branch above also doesn't flip
        -- state, so nothing to sync there either.
        return
    end

    if cmd == "highlight" then
        DB.itemHighlighting = DB.itemHighlighting == false
        PrintNicef(
            L["Item highlighting %s."],
            DB.itemHighlighting and L["|cff00ff00on|r"] or L["|cffff4444off|r"]
        )
        if NS.SyncItemHighlighting then
            NS.SyncItemHighlighting()
        end
        return
    end

    if cmd == "rules" then
        -- v2.44.0: rule-summary copy frame. Plain-English breakdown
        -- of every active toggle + the precedence order WC uses.
        -- Same surface as the Main panel's "Current Rules" button.
        if NS.ShowRuleSummary then
            NS.ShowRuleSummary()
        else
            PrintNice("|cffff4444Rule summary is unavailable.|r")
        end
        return
    end

    if cmd == "minimap" then
        -- v2.44.7: show / hide / reset the WC minimap button.
        -- Workaround for clashes with minimap-replacement / magnifier
        -- addons (Magnify-WotLK clash reported by Safra).
        local sub = string.lower(rest or "")
        if sub == "on" or sub == "show" then
            if NS.SetMinimapButtonVisible then
                NS.SetMinimapButtonVisible(true)
            end
            PrintNice(L["|cffb6ffb6Minimap button shown.|r"])
        elseif sub == "off" or sub == "hide" then
            if NS.SetMinimapButtonVisible then
                NS.SetMinimapButtonVisible(false)
            end
            PrintNice(L["|cffffb84dMinimap button hidden. Use /wc, the addon list button, or your key binding.|r"])
        elseif sub == "reset" then
            DB.minimapButtonAngle = NS.MINIMAP_DEFAULT_ANGLE or 190
            if NS.UpdateMinimapPos then
                NS.UpdateMinimapPos()
            end
            PrintNice(L["|cffb6ffb6Minimap button position reset.|r"])
        else
            local state = (DB.minimapButton ~= false) and L["shown"] or L["hidden"]
            PrintNicef(L["Minimap button is currently |cffffff00%s|r."], state)
            PrintNice(L["Usage: /wc minimap on||off||reset"])
        end
        return
    end

    if cmd == "scandebug" then
        -- v2.44.12: scan-tooltip diagnostic. Dumps every TextLeft line
        -- of the hidden WoWClearanceScanTooltip after SetBagItem on
        -- the given bag slot, plus the parsed detection-helper outputs.
        -- Use when an item silently sells despite seeming to have an
        -- reveals whether the text is in
        -- the scan tooltip at all, or whether PE's enrichment skips
        -- hidden tooltips (the leading hypothesis for Zukii's report).
        -- Usage: /wc scandebug <bag> <slot>
        local bagS, slotS = rest:match("^(%S+)%s+(%S+)")
        local bag = tonumber(bagS)
        local slot = tonumber(slotS)
        if not bag or not slot then
            PrintNice(L["Usage: /wc scandebug <bag> <slot>"])
            return
        end
        if NS.ShowScanDebugDump then
            NS.ShowScanDebugDump(bag, slot)
        else
            PrintNice("|cffff4444Scan debug helper unavailable.|r")
        end
        return
    end

    if cmd == "processdebug" then
        -- v2.38.3: one-shot diagnostic for the Process Bags engine.
        -- Opens a copyable window with every gate that decides whether
        -- an item appears in the Disenchant / Mill / Prospect / Lockpick
        -- list (spell-known states, settings, per-slot scan results,
        -- buildProcessSummary entry counts). Players whose herbs / ores
        -- don't show up can paste the output and we can identify which
        -- layer is failing on their setup (private-server spell IDs,
        -- tooltip-marker variance, etc.) before guessing a fix.
        --
        -- Sub-commands:
        --   /wc processdebug         - open the diagnostic window
        --   /wc processdebug clear   - wipe processCache (forces fresh
        --                              tooltip scans on the next bag
        --                              walk; lets us confirm whether a
        --                              "none" entry is genuine or
        --                              cache-poisoned from a /reload
        --                              tooltip race)
        local sub = (rest:match("^(%S+)") or ""):lower()
        if sub == "clear" then
            if WC_compCache and WC_compCache.processCache then
                local n = 0
                for _ in pairs(WC_compCache.processCache) do
                    n = n + 1
                end
                for k in pairs(WC_compCache.processCache) do
                    WC_compCache.processCache[k] = nil
                end
                PrintNicef(L["|cffb6ffb6Process cache cleared|r (%d entry/entries removed). Re-run |cffffff00/wc processdebug|r to scan fresh."], n)
            else
                PrintNice(L["|cffff4444processCache not available.|r"])
            end
            return
        end
        if NS.ShowProcessDebugDump then
            NS.ShowProcessDebugDump()
        else
            PrintNice(L["|cffff4444Process debug dump is unavailable.|r"])
        end
        return
    end

    if cmd == "sellinfo" then
        EnsureDB()
        -- Optional positional args: bag, slot. Defaults to the first
        -- non-empty bag slot when omitted.
        local bagArg, slotArg = rest:match("^%s*(%S+)%s+(%S+)%s*$")
        local bag = tonumber(bagArg)
        local slot = tonumber(slotArg)
        if WC_compCache.printSellabilityTrace then
            WC_compCache.printSellabilityTrace(bag, slot)
        end
        return
    end

    if cmd == "loot" then
        EnsureDB()
        if NS.ToggleLootWindow then
            NS.ToggleLootWindow()
        end
        return
    end

    if cmd == "history" then
        EnsureDB()
        NS.ShowSessionHistory()
        return
    end

    if cmd == "perf" then
        -- v2.37.6: self-diagnostic for "is WC bloated / hot?". Surfaces
        -- the four numbers that actually answer the question: addon
        -- memory footprint, addon CPU cost (when scriptProfile is on),
        -- the per-itemID cache sizes (bounded by unique items seen),
        -- and the user's list sizes. Also flags whether it's
        -- been left on after a diagnostic session.
        local function countKeys(t)
            if type(t) ~= "table" then
                return 0
            end
            local n = 0
            for _ in pairs(t) do
                n = n + 1
            end
            return n
        end
        if UpdateAddOnMemoryUsage then
            UpdateAddOnMemoryUsage()
        end
        local memKb = GetAddOnMemoryUsage and GetAddOnMemoryUsage("WoWClearance") or 0
        PrintNice(L["|cffffff00=== WoWClearance perf ===|r"])
        PrintNicef(L["Memory: |cffb6ffb6%.1f KB|r"], memKb)
        local profileOn = GetCVarBool and GetCVarBool("scriptProfile")
        if profileOn then
            if UpdateAddOnCPUUsage then
                UpdateAddOnCPUUsage()
            end
            local cpuMs = GetAddOnCPUUsage and GetAddOnCPUUsage("WoWClearance") or 0
            local fps = (GetFramerate and GetFramerate()) or 60
            if fps < 1 then
                fps = 1
            end
            PrintNicef(
                L["CPU: |cffb6ffb6%.1f ms total|r (%.3f ms/frame avg at %.0f FPS)"],
                cpuMs, cpuMs / fps, fps
            )
        else
            PrintNice(
                L["|cff888888CPU profile is off. Enable with /console set scriptProfile 1 then /reload to see CPU numbers here.|r"]
            )
        end
        PrintNicef(
            L["Caches: %d recipe / %d processable / %d bind"],
            countKeys(WC_compCache.tomeCache),
            countKeys(WC_compCache.processCache),
            countKeys(WC_compCache.bindCache)
        )
        if DB then
            PrintNicef(
                L["Lists: %d sell / %d keep / %d delete / %d account-sell"],
                countKeys(DB.whitelist),
                countKeys(DB.blacklist),
                countKeys(DB.deleteList),
                (ADB and countKeys(ADB.whitelist)) or 0
            )
        end
        return
    end

    if cmd == "spike" then
        -- Session frame-hitch diagnostic: the worst recent frames WC
        -- contributed to and which phase (bag update / vendor / tooltip)
        -- was busiest during each. Complements /wc perf (which reports
        -- steady-state footprint) by answering "what caused that stutter?".
        EnsureDB()
        NS.ShowFrameSpikes()
        return
    end

    if cmd == "help" or cmd == "?" then
        -- v2.37.6: slimmed to a 2-line redirect. The Main panel's Slash
        -- Commands section is now the canonical reference (each command
        -- has a click-to-run button), so the chat dump that used to
        -- live here is duplication. Keeps the command so the
        -- conventional /<addon> help expectation still gives a useful
        -- response.
        PrintNice(L["|cffffff00WoWClearance|r: type |cffffff00/wc|r to open settings."])
        PrintNice(
            L["|cffaaaaaaThe Slash Commands section there has every command with click-to-run buttons. The Help page there has the full FAQ.|r"]
        )
        return
    end

    if cmd == "clean" then
        EnsureDB()
        -- v2.12.0: subcommand fork. "/wc clean upgrades [apply]" walks the
        -- DB.blacklistAuto entries with tag "upgrade" and reports / removes
        -- ones that are no longer upgrades vs current gear (cleans up the
        -- spurious entries the v2.11.0 empty-slot bug left on user lists).
        -- Existing "/wc clean [apply]" cross-list conflict resolver is
        -- unchanged.
        if rest == "upgrades" or rest == "upgrades apply" then
            local report = WC_compCache.buildStaleUpgradeReport()
            local nStale = #report.stale
            local nDeferred = #report.deferred
            local nSkipped = #report.skipped
            if nStale == 0 and nDeferred == 0 and nSkipped == 0 then
                PrintNice(L["|cffaaaaaaNo 'Upgrade'-tagged entries on your Keep List.|r"])
                return
            end
            PrintNicef(
                L["|cffffff00%d|r stale 'Upgrade' entr%s found (no longer above your equipped iLvl)."],
                nStale,
                nStale == 1 and "y" or "ies"
            )
            if nStale > 0 then
                local cap = math.min(nStale, 10)
                for i = 1, cap do
                    local s = report.stale[i]
                    PrintNicef(
                        L["  |cffaaaaaa[%d]|r %s |cffaaaaaa(iLvl %d, equipped %d)|r"],
                        s.id,
                        s.name,
                        s.iLvl,
                        s.lowestEquipped
                    )
                end
                if nStale > cap then
                    PrintNicef(L["  |cffaaaaaa... and %d more.|r"], nStale - cap)
                end
            end
            if nDeferred > 0 then
                PrintNicef(
                    L["|cffaaaaaaDeferred %d entr%s (item info not loaded; rerun the command later).|r"],
                    nDeferred,
                    nDeferred == 1 and "y" or "ies"
                )
            end
            if nSkipped > 0 then
                PrintNicef(
                    L["|cffaaaaaaSkipped %d entr%s (no candidate slot populated to compare against).|r"],
                    nSkipped,
                    nSkipped == 1 and "y" or "ies"
                )
            end
            if rest == "upgrades apply" and nStale > 0 then
                local dialog = StaticPopup_Show("WC_CONFIRM_CLEAN_UPGRADES", nStale)
                if dialog then
                    dialog.data = function()
                        local removed = WC_compCache.applyStaleUpgradeCleanup(report)
                        PrintNicef(
                            L["Removed |cffffff00%d|r stale 'Upgrade' entr%s from the Keep List."],
                            removed,
                            removed == 1 and "y" or "ies"
                        )
                        local bp = _G["WoWClearanceOptionsBlacklist"]
                        if bp and bp.listUI then
                            bp.listUI:Refresh()
                        end
                    end
                end
            elseif nStale > 0 then
                PrintNice(L["Run |cffffff00/wc clean upgrades apply|r to remove them."])
            end
            return
        end
        local conflicts = WC_ScanListConflicts()
        WC_PrintConflictReport(conflicts)
        if rest == "apply" and #conflicts > 0 then
            local removed = WC_ApplyCleanResolution(conflicts)
            PrintNicef(
                L["Removed |cffffff00%d|r duplicate entr%s (Keep List wins, then Delete List, then Sell List)."],
                removed,
                removed == 1 and "y" or "ies"
            )
            local wp = _G["WoWClearanceOptionsWhitelist"]
            if wp and wp.listUI then
                wp.listUI:Refresh()
            end
            local bp = _G["WoWClearanceOptionsBlacklist"]
            if bp and bp.listUI then
                bp.listUI:Refresh()
            end
        elseif #conflicts > 0 then
            PrintNice(L["Run |cffffff00/wc clean apply|r to fix them (Keep List wins, then Delete List, then Sell List)."])
        end
        return
    end

    -- Unknown subcommand - open options
    NS.OpenOptionsPanel("WoWClearanceOptionsMain")
end

SLASH_WCDEBUG1 = "/wcdebug"
SlashCmdList["WCDEBUG"] = function()
    if not DB then
        PrintNice(L["|cffff4444DB not loaded.|r"])
        return
    end
    PrintNice(L["|cffffff00=== WoWClearance Debug ===|r"])
    for q = 1, 4 do
        local r = DB.qualityRules and DB.qualityRules[q] or {}
        local rarityName = (q == 1) and "White" or (q == 2) and "Green" or (q == 3) and "Blue" or "Epic"
        local capStr = (r.maxILvl and r.maxILvl > 0) and tostring(r.maxILvl) or "no cap"
        PrintNicef("Quality[%s]: enabled=%s, max iLvl=%s", rarityName, tostring(r.enabled), capStr)
    end

    -- Print whitelist contents
    local wlCount = 0
    for k, v in pairs(DB.whitelist or {}) do
        local n = GetItemInfo(k) or ("ItemID:" .. tostring(k))
        PrintNicef("  Sell List[%s] = %s  (%s)", tostring(k), tostring(v), n)
        wlCount = wlCount + 1
    end
    if wlCount == 0 then
        PrintNice(L["  (Sell List is empty)"])
    end

    -- Scan bags and check which items would be sold. v2.13.4: routes
    -- through WC_IsSellable so the debug output reflects every check
    -- the live merchant cycle applies. The previous inline predicate
    -- was missing v2.10.0+ rules (bind filter, Use equipped iLvl,
    -- quest-item safety net, blacklist veto, IsEquippedItem veto)
    -- and silently produced wrong "would sell" answers for items
    -- those checks cover. The breakdown columns (junk/wp/qp) are now
    -- inferred from WC_IsSellable's authoritative outcome plus the
    -- two cheap stable predicates (isJunk and whitelistPass) computed
    -- locally.
    PrintNice(L["|cffffff00--- Bag scan ---|r"])
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID then
                local sellable, _, _, _, _ = WC_IsSellable(bag, slot, false)
                if sellable then
                    local name, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
                    local junk = (quality ~= nil) and (quality == 0) and sellPrice and sellPrice > 0 and DB.sellGreys ~= false
                    local wp = IsInSet(DB.whitelist, itemID) or (ADB and IsInSet(ADB.whitelist, itemID))
                    -- Quality-rule path is whatever's left when the
                    -- authoritative WC_IsSellable says yes but neither
                    -- of the explicit list/junk paths matched.
                    local qp = sellable and not junk and not wp
                    PrintNicef(
                        "|cff00ff00SELL|r bag=%d slot=%d id=%d q=%s junk=%s wp=%s qp=%s sp=%s name=%s",
                        bag,
                        slot,
                        itemID,
                        tostring(quality),
                        tostring(junk),
                        tostring(wp),
                        tostring(qp),
                        tostring(sellPrice),
                        tostring(name)
                    )
                end
            end
        end
    end
    PrintNice(L["|cffffff00=== End Debug ===|r"])
end

-- v2.49.2: detects a third-party auto-delete addon running alongside
-- WC. Called at PLAYER_LOGIN (chat warning) and by /wc bugreport
-- (Environment Capabilities line). Only the IsAddOnLoaded string is
-- specific; comments + variable names stay neutral per CLAUDE.md's
-- "No third-party addon references in new WC artefacts" rule.
local function WC_HasConflictingDeleteAddon()
    return (IsAddOnLoaded and IsAddOnLoaded("AutoDelete")) and true or false
end
NS.HasConflictingDeleteAddon = WC_HasConflictingDeleteAddon

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("MERCHANT_SHOW")
f:RegisterEvent("MERCHANT_CLOSED")
f:RegisterEvent("BAG_UPDATE")
-- v2.25.0: ITEM_LOCK_CHANGED fires when a bag slot's `locked` flag
-- transitions - either a transient mid-pickup lock or a Pick Lock /
-- key-use unlock. BAG_UPDATE does NOT fire for lock-state changes
-- because the slot's contents haven't changed, so Pick Lock leaves
-- the Process Bags panel showing a stale row + the auto-open driver
-- unaware that the box is now openable. Routing this event through
-- the same debounce frame as BAG_UPDATE refreshes the panel, fires
-- the auto-open driver, and re-arms the cast button.
f:RegisterEvent("ITEM_LOCK_CHANGED")
-- v2.9.2: track player-only profession-cast successes so the LOOT_CLOSED
-- handler can suppress the loot-silence ring push when the loot was
-- triggered by a craft / disenchant / mill / prospect / lockpick rather
-- than a corpse loot. Player only, never unfiltered: on Forever other
-- units' casts carry secret spell IDs, and indexing the spell tables with
-- one throws.
f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
-- v2.10.0: drives the auto-protect-equipped reactive path. Fires every time
-- the player swaps a gear slot; the handler routes through
-- WC_AutoProtectEquippedSlot which short-circuits when the toggle is off,
-- so users not opted in pay one early-return per swap.
f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
-- v2.13.0: drives the Equipment Manager protection re-sync when the user
-- adds, modifies, or deletes a saved equipment set via the Blizzard
-- Equipment Manager. Handler is gated on DB.autoProtectEquipmentSets so
-- users without the toggle on pay one early-return per set save.
f:RegisterEvent("EQUIPMENT_SETS_CHANGED")
-- Spell events. SPELLS_CHANGED fires after the spellbook is fully
-- populated post-login and on bulk updates, invalidating the tome
-- "already known" cache so a just-learned recipe stops being protected.
--
-- LEARNED_SPELL_IN_TAB is deliberately NOT registered. An in-game event
-- probe on build 1.60.1.69913 measured it REJECTED on this client, and
-- RegisterEvent THROWS on an unknown event name. Registered bare here it
-- aborted the rest of this chunk, taking out every registration below
-- (SPELLS_CHANGED, PLAYER_REGEN_ENABLED, LOOT_READY,
-- GROUP_ROSTER_UPDATE) plus ~400 further lines of top-level code in this
-- file - so the addon lost Fast Loot, the combat-exit wake, the tome
-- cache invalidation and the version gossip, with no error after the
-- first. Same failure class as PARTY_MEMBERS_CHANGED below; this is the
-- third instance, and the forever-addon-kit README names this very event
-- as its worked example of it.
--
-- Do NOT "restore" it under a guessed modern name. The plausible
-- LEARNED_SPELL_IN_SKILL_LINE is UNMEASURED on this client, and porting
-- lesson 1 is about exactly that. SPELLS_CHANGED alone carries the
-- invalidation: it fires on bulk spellbook updates, learning included.
--
-- The OnEvent handler still branches on the old name so the branch
-- survives if the event is ever reinstated and measured. An event that
-- was never registered simply never arrives.
f:RegisterEvent("SPELLS_CHANGED")
-- Wakes the auto-open-containers driver when combat ends. Without this the
-- combat-deferred queue could sit indefinitely if no further BAG_UPDATE
-- arrives. Handler self-gates on DB.autoOpenContainers, so users with the
-- toggle off pay one early-return per combat exit.
f:RegisterEvent("PLAYER_REGEN_ENABLED")
-- v2.16.0: drives the Fast Loot driver. Handler self-gates on
-- DB.fastLoot and on Blizzard's autoLootDefault CVar, so users without
-- the toggle on pay one early-return per loot interaction.
f:RegisterEvent("LOOT_READY")
-- v0.7.0: looted coin (WC_compCache.lootMoneyEvent).
f:RegisterEvent("LOOT_CLOSED")
f:RegisterEvent("PLAYER_MONEY")
-- Loot Log History: group members' loot lines (WoWClearance_LootHistory.lua).
f:RegisterEvent("CHAT_MSG_LOOT")
-- Group-roster event for version-gossip probes (port work item 6).
--
-- WAS: PARTY_MEMBERS_CHANGED + RAID_ROSTER_UPDATE, with a comment saying
-- GROUP_ROSTER_UPDATE "is 4.0+ and must not be used here". That is exactly
-- inverted on Forever: GROUP_ROSTER_UPDATE is the live event and covers both
-- party and raid, while PARTY_MEMBERS_CHANGED is REJECTED by this client.
--
-- The rejection is not a silent degradation. RegisterEvent THROWS on an
-- unknown event name, and the uncaught throw aborts the rest of the calling
-- chunk - which would have taken out every registration after this line in a
-- 7,000-line file. Measured by the BarWarden-Forever port, which also found
-- that RAID_ROSTER_UPDATE is still accepted: the accept/reject split cannot
-- be reasoned about from an event's age, only measured.
f:RegisterEvent("GROUP_ROSTER_UPDATE")

f:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON_NAME then
            EnsureDB()
            -- Defensive nil-guards around the NS bootstrap chain. A
            -- missing or partial-sync split file is the most common
            -- failure mode during development (one .lua not yet
            -- copied to the live addon folder); without these guards
            -- a single missing file kills the whole init chain at the
            -- nil call site, hiding which subsystem actually failed
            -- to load.
            WC_InstallFastLootHookOnce()
            if NS.CreateMinimapButton then NS.CreateMinimapButton() end
            -- v0.5.2: install the Forever container-frame hooks once at
            -- login so bag highlighting appears without waiting for a list
            -- change. No-op on 3.3.5a (the global hook covers it there).
            if WC_compCache.ensureContainerFrameHooks then
                WC_compCache.ensureContainerFrameHooks()
            end
            if NS.InstallTooltipHookOnce then NS.InstallTooltipHookOnce() end
            if NS.CreateLDBLauncher then NS.CreateLDBLauncher() end
            if NS.InstallBagContextHookOnce then NS.InstallBagContextHookOnce() end
            if WC_manualSell and WC_manualSell.installHookOnce then
                WC_manualSell.installHookOnce()
        WC_compCache.installExternalActionHooksOnce()
            end
        elseif addonName == "Bagnon" then
            -- The host bag UI's slot class was registered during its load
            -- pass; install the sell-border hook now so the first paint
            -- after bags open already runs through our refresh path. The
            -- PLAYER_LOGIN-deferred fallback further down is idempotent so
            -- double-firing is harmless.
            if WC_compCache.installHostBagBorderHook then
                WC_compCache.installHostBagBorderHook()
            end
            if WC_compCache.installHostBagItemLevelHook then
                WC_compCache.installHostBagItemLevelHook()
            end
        elseif addonName == "Blizzard_InspectUI" then
            if WC_compCache.installInspectItemLevelHook then
                WC_compCache.installInspectItemLevelHook()
            end
        end
    elseif event == "PLAYER_LOGOUT" then -- luacheck: ignore 542
        -- No-op. The previous body (`WoWClearanceDB = DB`) was a defensive
        -- mirror back to the saved-variable when DB == WoWClearanceDB.
        -- After the v2.34.x per-character partition, DB is a metatable
        -- proxy, NOT the saved table itself; reassigning WoWClearanceDB
        -- to the proxy would replace the SV with an empty table and
        -- wipe the user's data on next logout. WoW serialises whatever
        -- WoWClearanceDB points to natively; we don't need to nudge it.
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        -- EnsureDB is load-bearing at PLAYER_LOGIN (the real character key is
        -- available there; ADDON_LOADED already ran it once for early reads).
        -- PLAYER_ENTERING_WORLD re-fires on every loading screen (zone change,
        -- instance, taxi) and nothing in the DB shape can change between
        -- those, so skip the full migration sweep + proxy rebuild there.
        if event == "PLAYER_LOGIN" then
            EnsureDB()
        end
        -- v2.49.2: conflict warning. Fires only when WC's delete path
        -- is active AND the player hasn't opted out AND a third-party
        -- auto-delete addon is loaded. Modal popup (not a chat line -
        -- a one-time chat message was easy to miss). Neutral framing per
        -- project rule; player identifies the other addon via their own
        -- list. Inside the PLAYER_LOGIN-only branch so it's one-shot per
        -- session (PLAYER_ENTERING_WORLD zone changes don't re-fire it).
        if event == "PLAYER_LOGIN" then
            if DB.enableDeletion and DB.warnConflictingAddons and WC_HasConflictingDeleteAddon() then
                StaticPopup_Show("WC_CONFLICT_WARNING")
            end
        end
        -- Panels are created shown inside the Settings container; park
        -- them so opening the game's Settings cannot build them all.
        if event == "PLAYER_LOGIN" and NS.ParkPanels then
            NS.ParkPanels()
        end
        -- v2.51.0: watch-list toggle snapshot at PLAYER_LOGIN, after
        -- EnsureDB has seeded defaults. /wc bugreport diffs against
        -- this to show which toggles the user flipped this session.
        -- No mutation hooks needed; the diff at report time gives us
        -- the "since login" audit trail. Watch list is a curated set of
        -- high-diagnostic-value toggles (destructive / protection /
        -- feature-gating) - not every checkbox in the addon.
        if event == "PLAYER_LOGIN" and NS.CaptureToggleLoginSnapshot then
            NS.CaptureToggleLoginSnapshot()
        end
        -- v2.51.0: warm the client's item cache for Delete List entries
        -- after a short settle so /wc bugreport (later in the session)
        -- can resolve names. Delayed by 5s to let the login-storm
        -- (PLAYER_LOGIN + inventory scans + Blizzard's own cache prime)
        -- settle first. Best-effort - if the delay helper isn't loaded
        -- (Core race) we just skip; user's next bugreport will still
        -- get whatever the client has cached by then.
        if event == "PLAYER_LOGIN" and NS.PrimeDeleteListItemCache then
            if NS.Delay then
                NS.Delay(5, NS.PrimeDeleteListItemCache)
            else
                NS.PrimeDeleteListItemCache()
            end
        end
        -- Version gossip: once per session (login / reload, not zone changes),
        -- after a short settle, ask the guild for versions.
        if event == "PLAYER_LOGIN" then
            WC_compCache.loadSoldHistory()
            NS.Delay(5, WC_compCache.claimLootLogKey)
            -- Decode the saved Loot Log history (up to 20,000 entries, ~10 ms)
            -- now, not inside the first bag update that records a pickup.
            NS.Delay(6, function()
                if NS.LootHistory and NS.LootHistory.Count then
                    NS.LootHistory.Count()
                end
            end)
            NS.Delay(5, function()
                if NS.Comms and GetGuildInfo("player") then
                    NS.Comms.FireVersionProbe("GUILD")
                end
            end)
            -- WC-TRAP: there is deliberately NO realm-channel join on login.
            -- v2.58.0 joined the channel and fired a request 7s after
            -- PLAYER_LOGIN, gated only on shareServerData. Removed, and it
            -- must not come back as a convenience.
            --
            -- Why the gate was not enough. shareServerData was seeded ON, and
            -- on build 69913 SavedVariables never read back, so the seed ran
            -- again at every launch and the player's opt-out was erased before
            -- this hook fired. The effect was that WoWClearance joined a chat
            -- channel and broadcast on a LIVE Blizzard realm, on every login,
            -- whatever the player had chosen. That is a decision for the
            -- player and it was being taken for them silently.
            --
            -- The join now happens only where the player asks for it: the
            -- "Stats - Server" panel toggle (WoWClearance_ServerStatsPanel),
            -- in the same session, by hand. Nothing on a timer, nothing at
            -- login. If realm sharing ever needs a login path again, it needs
            -- consent the player gave, saved, and read back on a build where
            -- saving is measured to work.
            -- See PORT_STATUS work item 7.
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Combat ended: re-fire the open driver. If the toggle is off or
        -- the queue is empty the driver early-returns; cost on combat
        -- exit for opted-out users is one branch.
        --
        -- The combatDeferredAnnounced flag is intentionally NOT cleared
        -- here. It used to be (per-combat re-announce), but a tester
        -- rogue-leveling with lockboxes in bag reported the deferral line
        -- firing repeatedly across short mob fights. The announce is now
        -- session-scoped (one per /reload) since its purpose is one-time
        -- discoverability, not a per-combat status reminder.
        WC_HandleAutoOpenContainers()
        -- Drain any settings-panel open that was queued while combat was
        -- active. Same double-call workaround as the original click paths.
        local pendingOpen = WC_compCache.pendingOpenAfterCombat
        if pendingOpen then
            WC_compCache.pendingOpenAfterCombat = nil
            if pendingOpen == "main" then
                NS.OpenOptionsPanel("WoWClearanceOptionsMain")
            elseif pendingOpen == "process" then
                NS.OpenOptionsPanel("WoWClearanceOptionsProcessBags")
            end
        end
        -- v2.22.0: Process Bags cast-button re-arm. SetAttribute is blocked
        -- during combat, so any re-arm attempts from BAG_UPDATE bail and
        -- this combat-exit catch-up restores a current macrotext.
        WC_compCache.rearmProcessButton()
        -- v2.25.0: optional one-line nudge when combat ends with
        -- lockable containers in bags. Off by default (one extra line
        -- per combat exit is noisy for rogues farming heavy zones).
        -- Only counts containers, not casts available; the user picks
        -- which one to open via the panel / hold-key-to-drain.
        -- (Bare IsSpellKnown only exists with deprecation fallbacks on, and
        -- lockpickEnabled was superseded by processEnabledModes.Lockpick.)
        if
            not (DB.processEnabledModes and DB.processEnabledModes.Lockpick == false)
            and DB.lockpickNotifyOnCombatExit
            and WC_compCache.spellKnown(WC_compCache.SPELL_PICK_LOCK)
        then
            local n = 0
            for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
                local slots = GetContainerNumSlots(bag) or 0
                for slot = 1, slots do
                    if WC_compCache.canPickLock(bag, slot) then
                        n = n + 1
                    end
                end
            end
            if n > 0 then
                PrintNicef(
                    L["|cffaaaaaa%d lockbox(es) available.|r Click |cffffb84dProcess Next|r in Process Bags to open."],
                    n
                )
            end
        end
    elseif event == "EQUIPMENT_SETS_CHANGED" then
        WC_StampEvent("equipmentSetsChanged")
        -- v2.13.0: live re-sync of Blizzard equipment-manager sets onto
        -- the Keep list. Silent variant suppresses the chat summary so
        -- save-edit-save cycles in the Equipment Manager UI don't spam.
        -- v2.50.2: run the sync UNCONDITIONALLY so WC_compCache.equipmentSetIDs
        -- is rebuilt whether or not autoProtectEquipmentSets is on. The scan-
        -- side rescue consults the cache to veto
        -- auto-marking items in a saved set - that veto MUST hold even when
        -- the automatic Keep-List stamping is opt-out. syncEquipmentSets
        -- itself now gates the Keep-List stamp on the toggle internally.
        if DB then
            WC_compCache.syncEquipmentSets(true)
            if DB.autoProtectEquipmentSets then
                local bp = _G["WoWClearanceOptionsBlacklist"]
                if bp and bp.listUI then
                    bp.listUI:Refresh()
                end
            end
        end
    elseif event == "LEARNED_SPELL_IN_TAB" or event == "SPELLS_CHANGED" then
        -- Tome "Already known" lookups read the LIVE tooltip via
        -- SetBagItem, so flipping false -> true on a tome the player
        -- just learned needs the cache cleared immediately. The wipe
        -- is cheap (one table reset); doing it synchronously avoids
        -- the 0.5 s debounce window where the next auto-rule sweep
        -- could still treat a just-learned recipe as unlearned and
        -- protect it from vendoring. tomeCache itself isn't wiped
        -- because is-a-tome is stable per itemID.
        if WC_compCache.tomeIsKnownCache then
            wipe(WC_compCache.tomeIsKnownCache)
        end
    elseif event == "BAG_UPDATE" or event == "ITEM_LOCK_CHANGED" then
        -- (The "bagUpdate" bugreport stamp lives in the settled flush, not
        -- here: this raw branch fires once per slot filled during AOE loot
        -- and should stay free of any per-event work beyond the debounce
        -- arm + the synchronous bag-full check.)
        -- v2.24.0 perf: work goes through WC_compCache.bagUpdateFrame's
        -- 120 ms debounce - AOE looting fires one BAG_UPDATE per slot
        -- filled, and doing the full deferred-work chain per-event
        -- caused 1.5 s freezes.
        -- v2.25.0: ITEM_LOCK_CHANGED routes through the same debounce
        -- so a Pick Lock completion refreshes the panel + fires the
        -- auto-open driver (which picks up the now-`Right Click to
        -- Open` box).
        WC_compCache.bagUpdateAccum = 0
        WC_compCache.bagUpdateFrame:Show()
    elseif event == "CHAT_MSG_LOOT" then
        if NS.LootHistory then
            NS.LootHistory.OnChatMsgLoot(...)
        end
    elseif event == "LOOT_READY" then
        -- Coin baseline first: Fast Loot below can take the coin at once.
        WC_compCache.lootMoneyEvent(event)
        -- v2.16.0: Fast Loot driver. Self-gates on DB.fastLoot and on
        -- Blizzard's autoLootDefault CVar so non-Fast-Loot users pay
        -- one early-return per loot interaction.
        WC_HandleLootReady()
    elseif event == "LOOT_CLOSED" or event == "PLAYER_MONEY" then
        WC_compCache.lootMoneyEvent(event)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- Payload on Forever is (unitTarget, castGUID, spellID). 3.3.5a
        -- sent the spell NAME second; reading arg2 here got the castGUID,
        -- so none of the name matches below ever fired. Resolve the ID to
        -- the localized name the PROF_LOOT_SPELLS / PICK_LOCK_NAME tables
        -- are keyed by.
        local _, _, spellID = ...
        local spellName = spellID and WC_compCache.spellName(spellID)
        -- v2.37.0: Process Bags lifetime cast counters. Counts every
        -- successful Disenchant / Milling / Prospecting / Pick Lock,
        -- whether the cast came from the Process Bags secure button
        -- or a manual cast bar. "Opening" is excluded - it fires on
        -- every container right-click and would over-attribute.
        if DB and spellName and WC_compCache.PROF_LOOT_SPELLS[spellName] and spellName ~= "Opening" then
            -- v2.38.1: helper writes to DB + ADB.accountStats.
            WC_BumpStatBucket("processCastCounts", spellName, 1)
        end
        -- v2.59.4: consume pendingProcessCast if the successful spell
        -- matches what the Process Bags panel captured just before the
        -- macrotext ran. Log to NS.recentProcessedLog and clear the
        -- pending struct. If the spell doesn't match, leave pending
        -- alone (a bumped Auto Attack, self-heal, etc. shouldn't
        -- consume the DE/Mill/Prospect/Pick Lock capture).
        do
            local pending = WC_compCache.pendingProcessCast
            if pending and spellName and pending.spellName == spellName then
                if NS.LogRecentProcessed then
                    NS.LogRecentProcessed(pending)
                end
                -- Remember the picked box by GUID so canPickLock drops it
                -- at once, whatever the tooltip still says. The 10 s
                -- window stops a stale capture (a click whose cast failed)
                -- from marking a box that a later manual cast did not hit.
                if pending.mode == "Lockpick" and GetTime() - (pending.startedAt or 0) < 10 then
                    local loc = NS.Decision.slotLocation(pending.bag, pending.slot)
                    if C_Item.DoesItemExist(loc) then
                        WC_compCache.pickedLockGUIDs[C_Item.GetItemGUID(loc)] = true
                    end
                end
                WC_compCache.pendingProcessCast = nil
            end
        end
        -- v2.25.0: Pick Lock completion - BAG_UPDATE doesn't fire for a
        -- lockbox's lock-state change (slot contents unchanged), and
        -- ITEM_LOCK_CHANGED doesn't reliably fire either. UNIT_SPELLCAST_SUCCEEDED
        -- with the Pick Lock spell name is the most reliable trigger.
        -- Route through the same debounce frame as BAG_UPDATE so the
        -- panel refreshes (drops the now-unlocked row) and the auto-
        -- open driver fires (opens the now-`Right Click to Open` box).
        if spellName and WC_compCache.PICK_LOCK_NAME and spellName == WC_compCache.PICK_LOCK_NAME then
            WC_compCache.bagUpdateAccum = 0
            WC_compCache.bagUpdateFrame:Show()
        end
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        WC_compCache.staleUpgradesChecked = nil
        -- v2.10.0: auto-protect equipped gear. arg1 is the slot id (1-19);
        -- empty slots fire too (the player just un-equipped). The helper
        -- gates on DB.autoAddEquipped, skips shirt/tabard, and bails when
        -- the slot is empty. On a successful add it prints one targeted
        -- chat line and stamps DB.blacklistAuto so the tooltip annotation
        -- can label the entry as "(auto-protected: equipped)".
        if not (DB and DB.autoAddEquipped) then
            return
        end
        local slot = ...
        if WC_compCache.protectEquipSlot(slot) then
            local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
            local id = link and tonumber(link:match("item:(%d+)"))
            local itemName = (id and GetItemInfo(id)) or "item"
            PrintNicef(L["Auto-protected |cffb6ffb6%s|r (added to Keep list)."], itemName)
            local bp = _G["WoWClearanceOptionsBlacklist"]
            if bp and bp.listUI then
                bp.listUI:Refresh()
            end
        end
    elseif event == "MERCHANT_SHOW" then
        WC_StampEvent("merchantShow")
        -- Login already ran the full default sweep; only bootstrap here.
        if not DB then
            EnsureDB()
        end
        WC_batchTotalSold = 0
        WC_batchTotalGold = 0
        WC_keepBagsFlag = true
        -- v2.9.0: snapshot bag contents BEFORE StartRun fires its first sell.
        -- The hooksecurefunc on UseContainerItem reads this map to attribute
        -- right-click sells (which empty the slot before the hook callback
        -- runs); the worker path is excluded by WC_manualSell.inSelfSell. Captured even
        -- when the addon is disabled for this character so manual sells at a
        -- merchant the user opened by hand are still tracked.
        WC_manualSell.snapshotBags()
        if not WC_IsAddonEnabledForChar() then
            return
        end
        StartRun()
    elseif event == "MERCHANT_CLOSED" then
        WC_StampEvent("merchantClosed")
        WC_compCache.vendorRunning = false
        worker:Hide()
        -- v2.46.4: merchant gone, drop any refusal marks so the next
        -- visit retries afresh. Cheap insurance alongside the
        -- StartRun wipe (covers player-closes-merchant-mid-loop).
        wipe(WC_vendorRefusedThisRun)
        WC_compCache.merchantBuysNothing = false
        -- Reopen bags after merchant closes
        if DB and DB.keepBagsOpen and WC_keepBagsFlag then
            WC_Delay(0.8, WC_OpenAllBags)
        end
        WC_keepBagsFlag = false
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- One event now covers both cases, so the channel is chosen from the
        -- group state rather than from which event fired.
        local groupChannel = NS.Comms and NS.Comms.GroupChannel()
        if groupChannel then
            NS.Comms.FireVersionProbe(groupChannel)
        end
    end

    if event == "PLAYER_LOGIN" then
        WC_Delay(1, function()
            -- v2.38.0: fresh installs auto-open the Quickstart panel
            -- directly (no welcome popup). Existing characters keep the
            -- unchanged single-line welcome.
            if DB and DB._needsQuickstartOpen then
                DB._needsQuickstartOpen = nil
                PrintNice(
                    L["|cffffff00Welcome to WoWClearance!|r Opening Quickstart - pick a preset or answer a few questions to set up."]
                )
                -- Extra 0.3s defer so the UI has finished settling
                -- before the standalone Quickstart frame floats up.
                WC_Delay(0.3, function()
                    local qf = _G["WoWClearanceOptionsQuickstart"]
                    if qf and qf.Show then
                        qf:Show()
                    end
                end)
            else
                PrintNice(L["Enabled. Use |cff00ff00/wc|r to configure."])
            end
            -- Fresh-install one-shot equipped sync. Set in EnsureDB only
            -- when the SavedVariable was nil at first ADDON_LOADED, so
            -- existing characters never trigger this. The 2 s extra
            -- defer (on top of the 1 s welcome delay) gives inventory
            -- APIs time to settle before walking the slots.
            if WC_compCache.pendingFreshInstallSync then
                WC_compCache.pendingFreshInstallSync = nil
                WC_Delay(2, function()
                    if WC_compCache.syncEquipped then
                        WC_compCache.syncEquipped()
                    end
                end)
            end
            -- v2.13.0 ElvUI bag buttons. ElvUI's container frame is
            -- constructed lazily during its own load sequence; the 2 s
            -- defer (on top of the 1 s PLAYER_LOGIN delay) is borrowed
            -- from AutoDelete's matching feature and is enough on every
            -- realm we've seen. Self-gates on _G.ElvUI_ContainerFrame at
            -- call time, so non-ElvUI users pay one nil-check per login.
            WC_Delay(2, function()
                if WC_compCache.buildElvUIBagButtons then
                    WC_compCache.buildElvUIBagButtons()
                end
            end)
            -- Sell-border tint: try installing the host bag-UI adapter
            -- IMMEDIATELY (the common case: host already loaded by
            -- PLAYER_LOGIN). If the host's slot class isn't ready yet, the
            -- call self-gates on LibStub + AceAddon presence and no-ops;
            -- the 2 s fallback below catches the late-load case. Both
            -- calls are idempotent via _hostBagBorderHookInstalled. Without
            -- the immediate attempt, bags opened during the 2 s window
            -- paint without our hook attached and the first border only
            -- appears after the next host-driven slot refresh.
            if WC_compCache.installHostBagBorderHook then
                WC_compCache.installHostBagBorderHook()
            end
            if WC_compCache.installHostBagItemLevelHook then
                WC_compCache.installHostBagItemLevelHook()
            end
            WC_Delay(2, function()
                if WC_compCache.installHostBagBorderHook then
                    WC_compCache.installHostBagBorderHook()
                end
                if WC_compCache.installHostBagItemLevelHook then
                    WC_compCache.installHostBagItemLevelHook()
                end
            end)
        end)
    end
end)
