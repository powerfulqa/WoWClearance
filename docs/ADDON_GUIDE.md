# WoWClearance - Addon Development Guide

> **Status: v0.8.0, WoW: Forever.** This is the contributor guide for
> WoWClearance as it runs on **WoW: Forever** (Interface 16001,
> `WOW_PROJECT_MAINLINE`, a Mainline/retail 12.1.x API surface). It covers
> the code conventions, file layout and load order, the saved-variable
> model, the test invariants, and the gotchas that have broken this addon
> before.
>
> WoWClearance is a fork of EbonClearance, a WoW 3.3.5a addon for the
> Project Ebonhold private server. The port moved the container / item /
> spell layer to the `C_*` namespaces, moved the options UI to the Settings
> API plus a standalone window, and removed the Project Ebonhold subsystem
> (affixes, chance-on-hit procs, the Anvil and extraction, the Greedy
> Scavenger / Goblin Merchant companions and the loot-cycle engine).
> **Sections that describe 3.3.5a APIs or that removed subsystem are
> historical.** They are kept, mostly collapsed to a short "Removed in the
> port" note, only where code, tests, other docs or a `WC-TRAP:` comment
> still point at them.
>
> For how the client actually behaves, [PORT_STATUS.md](PORT_STATUS.md) is
> authoritative: its "Porting lessons", "API mapping" and "Hard release
> gate" sections win over anything here. [ARCHITECTURE.md](ARCHITECTURE.md)
> is the one-screen code map; [CLAUDE.md](../CLAUDE.md) holds the repo rules
> and the release process.

**Read this first if you are an AI agent or new contributor touching
this codebase.** It is prescriptive: when the guide and a random
internet tutorial disagree, follow the guide.

## TL;DR conventions

1. **Client target is WoW: Forever (Interface 16001, Lua 5.1).** The API
   is the retail `C_*` surface (`C_Container`, `C_Item`, `C_Spell`,
   `C_SpellBook`, `C_AddOns`, `C_ChatInfo`, `C_EquipmentSet`,
   `C_TransmogCollection`, `C_TooltipInfo`, ...). Do not copy 3.3.5a code
   out of the EbonClearance history, and do not trust a retail answer
   blindly either: confirm every function, event and return shape against
   Forever first (see "Verifying an API on Forever" under Tooling, and
   PORT_STATUS "Porting lessons").
2. **Multi-file since the Stage 1-9 split.** Code lives in the 34
   `WoWClearance_*.lua` files listed in the `.toc` (Core loads first;
   the event hub is `WoWClearance_Events.lua`, renamed from the
   original monolith). Cross-file state goes through the shared `NS`
   namespace; do not add new files without registering them in the
   `.toc` and CLAUDE.md's file count. (v2.68.1: the static test suites
   derive their SOURCE_PATHS from the `.toc` automatically - the old
   hand-written arrays had silently drifted up to nine files behind.)
3. **Namespace via `WC_` prefixed locals.** There is no addon table.
   Nearly everything is `local`; the only intentional globals are the
   saved-variable tables (`WoWClearanceDB`, `WoWClearanceAccountDB`),
   the slash-command handles, the keybinding header / name strings
   (`BINDING_HEADER_WOWCLEARANCE`, `BINDING_NAME_WOWCLEARANCE_*`), the
   handlers wired from `Bindings.xml` (`WoWClearance_ToggleSettings`,
   `WoWClearance_ToggleEnabled`, `WoWClearance_ForceSell`,
   `WoWClearance_ToggleLootLog`), the addon-compartment handler named in
   the `.toc` (`WoWClearance_OnAddonCompartmentClick`, in
   `WoWClearance_Minimap.lua`), and the provenance globals required by
   `LICENSE` §2 (`WOWCLEARANCE_IDENT`, `WOWCLEARANCE_AUTHOR`,
   `WOWCLEARANCE_ORIGIN`, `__WoWClearance_origin`,
   `__WoWClearance_author`, `__WoWClearance_watermark`).
4. **Any state machine uses named constants, never raw strings.** The
   3.3.5a `STATE` table drove the loot-cycle engine and was removed with
   it; the rule stands for whatever replaces it. See "State transitions".
5. **Cache hot API functions at file top**, bound from their namespace
   (`local GetItemInfo = C_Item.GetItemInfo`), then use the locals on hot
   paths (vendor loop, bag scans, OnUpdate callbacks).
6. **One event-dispatch frame for features.** Feature events hang off
   `f` near the bottom of `WoWClearance_Events.lua`. Do not create a new
   event frame for a new feature - add to the dispatch. The only
   exceptions are the self-contained transports (`NS.Comms` owns
   `CHAT_MSG_ADDON` for its prefix, `NS.RealmComms` for its own) and the
   Process Bags cast drivers in `WoWClearance_ProcessBagsPanel.lua`.
7. **Print through `PrintNice` or `PrintNicef`.** Never call
   `DEFAULT_CHAT_FRAME:AddMessage` directly outside those helpers.
8. **Saved variables always go through `EnsureDB()`.** New fields must
   default without breaking an existing `WoWClearanceDB` table.
9. **Option panels are idempotent via `self.inited`.** Every panel's
   OnShow goes through `WC_compCache.initPanel`, which does the "if
   inited then refresh-only; return" dance.
10. **No external libraries.** No Ace3, no LibStub, no LDB. See the
    Ace3 decision record below for the reasoning and escape hatch.
11. **Doc links never use `#L<n>` line anchors.** Link to the file by
    name (e.g. `[CreateListUI](../WoWClearance_ListWidget.lua)`) and let readers
    `grep` for the symbol. Line numbers shift on every refactor; symbol
    names don't.
12. **Do not remove attribution markers.** `LICENSE` §2 lists five
    things every redistribution must preserve: the `## Author:` TOC
    line, the file-header comment block at the top of
    `WoWClearance_Core.lua` (the first file the `.toc` loads), the GUI
    byline, the `WOWCLEARANCE_*` / `__WoWClearance_*` provenance
    globals, and the `LICENSE` file in full. If a refactor would touch
    any of those, leave them alone or update them with care - never
    delete.
13. **The `WoWClearance_Events.lua` main chunk is at Lua 5.1's
    200-locals cap.** New module-level state goes on `WC_compCache` (or
    `NS`), never a new main-chunk `local`. See "Forever port patterns".
14. **Verify before you call.** Every new API call, event name, widget
    method or `.luacheckrc` member is checked against Forever with the
    `wow` MCP tools and `flavor: "forever"`, because the lint gate cannot
    see most of these.

## Client target: WoW: Forever

Forever is the Mainline client wearing a Classic version number (see
PORT_STATUS "What Forever is"). Treat it as retail for API shape and
measure everything else.

### `.toc` fields we use

```
## Interface: 16001                                # WoW: Forever
## Title: ...                                      # colour codes allowed; version badge rewritten by CI
## Notes: ...
## Author: ...                                     # required by LICENSE §2(a)
## X-Website: https://github.com/powerfulqa/WoWClearance
## Version: ...                                    # rewritten by the release workflow
## SavedVariables: WoWClearanceDB, WoWClearanceAccountDB
## IconTexture: Interface\Icons\INV_Misc_Coin_01
## AddonCompartmentFunc: WoWClearance_OnAddonCompartmentClick

WoWClearance_Core.lua
...                                                # full load order under "File layout"
```

`Bindings.xml` ships with the addon but is deliberately **not** listed in
the `.toc`. The client auto-loads a file of that exact name from the addon
folder; listing it as well parses it a second time as ordinary UI XML,
where `<Binding>` is not a valid element and the client logs
"Unrecognized XML: Binding". No shipped Blizzard `.toc` lists it either.
Do not move bindings into Lua.

Both `WoWClearanceDB` and `WoWClearanceAccountDB` are declared with
`## SavedVariables`, which is **account-wide** in WoW's saved-variable
model. (Earlier revisions of this guide claimed `WoWClearanceDB` was
per-character "by default" - that was wrong; `## SavedVariables` has
always been account-wide and the per-character variant is the explicit
`## SavedVariablesPerCharacter` directive, which this addon does not use.)

Whether the client reads SavedVariables back at launch is a measured,
build-specific fact, not an assumption: see PORT_STATUS "Hard release
gate" before relying on anything persisting.

Per-character semantics for the lists, profiles, and per-mode
preferences are restored via an **in-table partition** introduced in
v2.34.x (see the `PER_CHAR_FIELDS` block near the top of
[`WoWClearance_Events.lua`](../WoWClearance_Events.lua)):

- `WoWClearanceDB.chars[<character>-<realm>]` holds each character's
  live per-character data (Keep / Sell / Delete lists, profiles, the
  master `enabled` toggle, Process Bags ignore + collapsed sections, the
  loot ledger, and since v0.6.0 the Sold History logs).
- Top-level `WoWClearanceDB.<field>` is the **legacy snapshot** -
  frozen at migration time. It serves two roles: the seed each newly
  migrated character deep-copies on first load, and the downgrade
  safety net (an older client looking for `DB.blacklist` etc. still
  finds its pre-migration baseline at the top level).
- `WoWClearanceAccountDB` is account-wide: the account Sell List, the
  Allow Sell table, account stats, and the Loot Log History ring.

Inside Lua, `DB` is a metatable proxy. Reads / writes for fields
listed in `PER_CHAR_FIELDS` route to `chars[charKey]`; everything else
routes to the top-level table. Call sites use the existing `DB.foo`
shape unchanged. The PLAYER_LOGOUT branch deliberately does **not**
reassign `WoWClearanceDB = DB` - that would overwrite the
SavedVariable with the empty proxy table on serialization.

Adding a new per-character field means adding the field name to the
`PER_CHAR_FIELDS` table; the proxy routes both reads and writes
automatically. Test 66 in
[`tests/test_perf_guardrails.lua`](../tests/test_perf_guardrails.lua)
locks the partition's structural invariants, and
[`tests/test_dbproxy.lua`](../tests/test_dbproxy.lua) drives the real
proxy at runtime.

**Settings profiles (v2.72.0)** add a third proxy route on the same
model. The selling-behaviour fields enumerated in
`WC_compCache.settingsProfileFields` (quality rules, deletion + auto-mark
toggles, protections including the two Forever ones, recipe settings,
repair, pacing) read/write through
`WoWClearanceDB.settingsProfiles[<name>]`, where `<name>` is the
character's per-char `activeSettingsProfile` pointer (falls back to
`Default`, which `EnsureDB` seeds once from the pre-migration top-level
values). Profile bodies are top-level so alts share one by pointing at
the same name; the top-level field copies freeze at migration as the
downgrade safety net. Consequences for contributors:

- **Adding a new selling-behaviour setting**: add the `EnsureDB`
  nil-default as always (it seeds through the proxy into the active
  profile) AND add the field name to
  `WC_compCache.settingsProfileFields` if it should be per-profile.
  A field left out stays account-wide - that is a valid choice for
  looting/visual/master-enable settings, deliberate scope per the
  2026-07-30 decision.
- **Switching profiles** must go through `NS.UseSettingsProfile` - it
  re-runs the idempotent `EnsureDB` (so an old profile picks up
  nil-defaults for fields added since) and repaints via
  `NS.RepaintAfterSettingsSwitch`.
- Management: `NS.SaveSettingsProfile` / `NS.UseSettingsProfile` /
  `NS.DeleteSettingsProfile` / `NS.RenameSettingsProfile` (bodies in
  Events, consumed by the Settings Profiles panel + `/wc sprofile`).
  Delete repoints every character that used the profile back to
  Default; Default itself cannot be deleted or renamed (it is also the
  proxy's stale-pointer fallback). Test 130 locks all of this.

We do not use `Dependencies`, `OptionalDeps`, `LoadOnDemand`, or
`LoadManagers`.

### Lua 5.1 constraints

WoW's embedded Lua is still 5.1 on Forever, and CI runs the suites under
`lua5.1`, so all of these still apply:

- No `goto` / labels.
- No integer division operator (`//`) - use `math.floor(a / b)`.
- No `bit32`; use the built-in `bit` library (`bit.band`, `bit.bor`, etc).
- No `string.pack`, no `utf8` library.
- `load` takes a reader function, not a string. Use `loadstring` for a
  string chunk (or a version-agnostic `loadstring or load`, as the test
  suites do). Calling `load(str)` under a `pcall` fails silently - that
  is how the old locale-coverage suite ran empty for its whole life
  before v0.5.0.
- At most 200 local variables per function, and a file's main chunk is a
  function. `WoWClearance_Events.lua` is AT that cap; see "Forever port
  patterns".
- `ipairs` stops at the first nil and `#t` is undefined on a sparse
  table; use `pairs` / `next()` for sparse tables. This is live on
  Forever: `C_EquipmentSet.GetItemIDs` returns a slot-keyed sparse table
  whose lowest key can be 5, so `ipairs` yields nothing (a `WC-TRAP:` in
  the equipment-set sync, porting lesson 9).

What changed is the client, not the language: `C_Timer` now exists on
Forever, but the addon keeps its own `WC_Delay` (and the paced OnUpdate
queue in `NS.RealmComms`) because they work and their error routing is
deliberate. Using `C_Timer.After` for new code is fine; verify any other
"modern" API before assuming it.

## Architecture

> For the multi-file map (which `.lua` file owns what, the
> cross-file boundaries, and a "where do I change X?" table), see
> [ARCHITECTURE.md](ARCHITECTURE.md). The per-file ordering notes below
> describe the rough layout *within* the larger files (Core, Events, etc.)
> and predate the file split; treat them as within-file guidance.

### File layout

The `.toc` is the load-order source of truth. Current order (36 files: the 34 numbered below, plus `WoWClearance_Kit.lua` loaded before all of them and `WoWClearance_Daylight.lua` loaded after all of them):

| # | File | Role |
|---|------|------|
| 1 | `WoWClearance_Core.lua` | Provenance globals, `WC_Fingerprint`, `NS.IsInSet`, the `WC_compCache` table (`NS.compCache`). Loads first; depends on nothing. Carries the LICENSE §2(b) header block. |
| 2 | `WoWClearance_Decision.lua` | `NS.Decision`: the pure sell / delete decision core plus its two adapters and `Decision.slotLocation`. |
| 3 | `WoWClearance_Locale.lua` | `NS.L`, an English passthrough. Must precede any file that binds `local L = NS.L` at its main chunk. |
| 4 | `WoWClearance_Protection.lua` | Detection helpers: tome / Resilience marker scan, quest-item and appearance / tradeable predicates. |
| 5 | `WoWClearance_Process.lua` | Process Bags engine (Disenchant / Mill / Prospect / Lockpick). |
| 6 | `WoWClearance_PanelInfra.lua` | `NS.OptionsHost`, the options-category registry, the reactive width registry, `WC_compCache.initPanel`. |
| 7-17 | `ProcessBagsPanel`, `MerchantPanel`, `SellListPanels`, `KeepDeletePanels`, `ProtectionPanel`, `ItemHighlightingPanel`, `ProfilesPanel`, `MainPanel`, `StatsPanel`, `GuildPanel`, `ServerStatsPanel` | One file per options panel (or related pair). They create frames at load and build lazily on first OnShow. |
| 18-19 | `WoWClearance_PanelWidgets.lua`, `WoWClearance_ListWidget.lua` | Shared widget primitives and `CreateListUI`. |
| 20 | `WoWClearance_Window.lua` | The standalone config window, `NS.SkinWindow`, and the single Settings launcher page. Must load BEFORE any file that calls `NS.SkinWindow` at file scope. |
| 21 | `WoWClearance_QuickstartPanel.lua` | The Quickstart modal (calls `NS.SkinWindow` at file scope). |
| 22 | `WoWClearance_Events.lua` | The event hub, `EnsureDB` / `EnsureAccountDB`, the DB proxy, the vendor loop, slash commands, `Bindings.xml` handlers, and most residual glue. |
| 23 | `WoWClearance_LootHistory.lua` | `NS.LootHistory`: the persisted per-pickup Loot Log History ring (v0.6.0). Loads after Events. |
| 24 | `WoWClearance_HistoryWindow.lua` | The Sold History window over `NS.recentSoldLog` / `NS.recentDeletedLog`. |
| 25-28 | `WoWClearance_Comms.lua`, `_RealmComms.lua`, `_GuildShare.lua`, `_ServerShare.lua` | `NS.Comms` transport + version gossip, the realm-channel transport (rebuilt in v0.6.0, see below), and their two consumers. |
| 29-34 | `BagDisplay`, `BugReport`, `Minimap`, `Tooltip`, `BagContextMenu`, `HelpPanel` | Bag-slot tint + `/wc sellinfo` trace, `/wc bugreport`, minimap + compartment entry, tooltip annotations, Alt+Right-Click menu, Help / FAQ. |

Two load-order failures in this port each blanked whole files: a
file-scope call into an `NS` function defined by a file that loaded later
hits nil, and the throw aborts the rest of the calling file. If a file
calls something at FILE SCOPE, its provider must load first; calls made
inside functions that run later resolve at call time and do not care.

Within `WoWClearance_Events.lua` the rough order is still: cached API
upvalues and forward declarations; the `PER_CHAR_FIELDS` /
`settingsProfileFields` tables and the DB proxy; `EnsureDB` /
`EnsureAccountDB`; helpers (bag, list, equipment-set sync, loot delta,
timers); the BAG_UPDATE debounce frame; the vendor loop (`BuildQueue`,
`DoNextAction`, `worker`); the Sold History logs; popups; panel ordering;
the event frame and its handler; slash commands near the very bottom.
Approximate - do not reshuffle without a reason, and remember the
200-locals cap when adding anything at file scope.

### The event hub

Near the bottom of `WoWClearance_Events.lua`, one `CreateFrame("Frame")`
registers every feature event and dispatches via a switch on `event`.
Adding a new event is a two-liner: `f:RegisterEvent("NEW_EVENT")` and a
branch in the OnEvent handler. Do **not** add a second event frame for
"your feature."

Currently registered on the hub: `ADDON_LOADED`, `PLAYER_LOGOUT`,
`PLAYER_LOGIN`, `PLAYER_ENTERING_WORLD`, `MERCHANT_SHOW`,
`MERCHANT_CLOSED`, `BAG_UPDATE`, `ITEM_LOCK_CHANGED`,
`UNIT_SPELLCAST_SUCCEEDED` (player-only via `RegisterUnitEvent`),
`PLAYER_EQUIPMENT_CHANGED`, `EQUIPMENT_SETS_CHANGED`, `SPELLS_CHANGED`,
`PLAYER_REGEN_ENABLED`, `LOOT_READY`, `CHAT_MSG_LOOT` (Loot Log History,
group members' loot) and `GROUP_ROSTER_UPDATE` (version gossip). Outside
the hub: `CHAT_MSG_ADDON` (Comms and RealmComms, one prefix each), and
`UNIT_SPELLCAST_START` / `PLAYER_REGEN_ENABLED` (Process Bags drivers).

`BAG_UPDATE` and `ITEM_LOCK_CHANGED` do no work inline; they arm the
shared debounce frame (see "BAG_UPDATE handler must coalesce bursts").

**`RegisterEvent` throws on an unknown event name on this client**, and
the throw aborts the rest of the calling chunk. Several 3.3.5a names are
measured REJECTED (`PARTY_MEMBERS_CHANGED`, `LEARNED_SPELL_IN_TAB`,
`UNIT_COMBO_POINTS`, `RUNE_UPDATE`; pinned by
`tests/test_comms_version.lua`). luacheck cannot see this - a string is a
string - so lint every new name with `wow_lua_lint` (flavor `forever`),
which flags `event/unknown` by exact name. Porting lesson 15.

### Saved variables shape

`WoWClearanceDB` is a single account-wide table, partitioned three
ways since v2.34/v2.72.0: per-character fields live under
`chars[<char>-<realm>]` (the `PER_CHAR_FIELDS` proxy route), the
selling-behaviour settings live under `settingsProfiles[<name>]` (the
`WC_compCache.settingsProfileFields` proxy route - see "Settings
profiles" above), and everything else sits at the top level. Fields
fall into these groups (not exhaustive - `EnsureDB` is the full list):

- **Lists**: `whitelist` (Sell List), `blacklist` (Keep List),
  `deleteList`, `blacklistAuto` (source tags), plus the dormant
  `enableOnlyListedChars` / `allowedChars` pair (forced off by a
  `WC-TRAP:` in `EnsureDB`).
- **Profiles**: `whitelistProfiles`, `blacklistProfiles`,
  `activeProfileName` (list snapshots, per-character), plus
  `settingsProfiles` (top-level bodies) + `activeSettingsProfile`
  (per-character pointer) for the v2.72.0 settings profiles.
- **Settings**: `enabled` (per-character), `vendorInterval`,
  `maxItemsPerRun`, `fastMode`, `autoOpenContainers`, `fastLoot`,
  `repairGear`, `keepBagsOpen`, `enableDeletion`, `autoDeleteOnPickup`,
  `autoDeleteGreyOnLoot`, `protectAllTomes`, `protectUnlearnedTomes`,
  `protectUncollectedAppearances` and `protectTradeableLoot` (v0.6.0,
  default on), `qualityRules` (per-rarity table, see below),
  `vendorBtnShown` (and `vendorBtnX`, `vendorBtnY`, `vendorBtnPoint`,
  `vendorBtnRelPoint` - dormant; see the `WC_CreateVendorButton` block).
  `fastMode` (v2.2.0+) pins the per-item interval to the 0.05 s floor
  and doubles the per-run cap; consume via `WC_EffectiveVendorInterval`
  / `WC_EffectiveMaxItemsPerRun`, never read it directly on hot paths.
  `qualityRules` (v2.5.0+) is a table indexed by quality (1=White,
  2=Green, 3=Blue, 4=Epic) with
  `{ enabled = bool, maxILvl = number, bindFilter = "any"|"boe"|"bop",
  useEquippedILvl = bool }` per rarity. `maxILvl == 0` means no cap.
  When `maxILvl > 0` the cap only filters items with a non-empty
  `equipLoc` (i.e. items that display an item level on their tooltip);
  trade goods, reagents, and consumables are protected. Since v0.6.0 the
  level compared is the COPY's real level (`C_Item.GetCurrentItemLevel`
  on `Decision.slotLocation`), not the base level from `GetItemInfo`.
  **`useEquippedILvl == true` (v2.12.0+) makes `maxILvl` irrelevant at
  runtime** - the rule fires when the bag item's level is below the
  player's currently-equipped level in the same slot, via
  `WC_compCache.isDowngradeVsEquipped`. The helper requires every
  candidate slot from `WC_compCache.INVTYPE_SLOTS` to be populated;
  any empty slot returns false (don't auto-sell when the user might
  want to fill the slot). If you ever add a fifth tier (Legendary),
  extend the loop in `EnsureDB`, the `quality >= 1 and quality <= 4`
  gate in `Decision.sell`, the matching checks in the tooltip and the
  `/wcdebug` bag scan, plus the per-rarity row builder in the Merchant
  Settings panel.
- **Stats**: `totalCopper`, `totalItemsSold`, `totalItemsDeleted`,
  `totalRepairs`, `totalRepairCopper`, `soldItemCounts`,
  `deletedItemCounts`, `inventoryWorthTotal`, `inventoryWorthCount`,
  `lootedItemCounts` (v2.46.0; per-character loot ledger, `itemID ->
  quantity`, in `PER_CHAR_FIELDS`, drives the Loot Log's Character view).
- **History** (v0.6.0): `soldHistory` (per-character, in
  `PER_CHAR_FIELDS`) holds the Sold History rings. See "Persisted ring
  logs" under "Forever port patterns" for the shape and load order.
- **Recipe selling** (v2.46.0): `sellKnownRecipes` (bool) +
  `sellKnownRecipeQualities` (`{[1..4] = bool}`). Learn-state is read
  per-character at decision time. See the "Sell Known Recipes" gotcha.
- **UI**: `minimapButtonAngle`.

`WoWClearanceAccountDB` (the `ADB` upvalue / `NS.ADB`) is a separate,
account-wide table bootstrapped by `EnsureAccountDB()` (called from
`EnsureDB()`). It holds the account Sell List (`whitelist`, exposed to
`CreateListUI` via the `WC_GetListTable` resolver under the name
`accountWhitelist`; sell-time consultation is a union of the per-char and
account lists), Allow Sell (`allowedItems`), `accountStats` (including
the account loot mirror `accountStats.lootedItemCounts`),
`lootLogHidden`, and since v0.6.0 `lootHistory` (the Loot Log History
ring) and `lootLogKeyClaimed` (the one-shot Shift+L binding claim).

In-memory only (not saved): `WC_session = { copper, sold, deleted,
repairs, repairCopper }`, `WC_lootSession` (`itemID -> quantity`, the
Loot Log's Session view), the "saved by re-check" log
(`NS.recentSavedLog`), and every `WC_compCache` cache. The Session
counters reset on the Reset Session button or `/reload`.

`EnsureDB()` is the **only** place defaults are written. Adding a new
setting means: pick the group, add a default line inside `EnsureDB()`,
and make sure it's `nil`-tolerant (`DB.myField or default`).

## Required patterns

### Locals everywhere

```lua
local function DoThing()  -- good
function DoThing()        -- bad - creates a global
```

Check with `luacheck WoWClearance_*.lua`; the W111/W112 family catches
this.

### Cached API globals

Each file caches the hot API functions it uses at file top, bound from
their Forever namespace:

```lua
local GetItemInfo = C_Item.GetItemInfo
local GetContainerItemID = C_Container.GetContainerItemID
local IsEquippedItem = C_Item.IsEquippedItem
-- ...and the rest of the bag / merchant API
```

When you use one of these on a hot path, you are using the local
upvalue, which is a single register read rather than a `_G` hash
lookup. This cached-upvalue line is also where the port moved each
3.3.5a global onto its namespace (one line per file per API, call sites
unchanged); `tests/test_api_surface.lua` asserts every moved global is
namespaced at the call site or bound from its `C_` namespace.

Two things a cache line cannot do for you:

- **Return shapes changed.** `C_Container.GetContainerItemInfo` returns
  ONE table (`iconFileID`, `stackCount`, `isLocked`, `quality`,
  `isBound`, `itemID`, `hyperlink`, ...) or **nil for an empty slot**,
  not seven positional values. `C_Spell.GetSpellInfo` returns a table
  with no `rank`. Read fields by name with a nil guard; never
  destructure positionally. A `C_` prefix does not imply a table:
  `C_EquipmentSet.GetEquipmentSetInfo` is positional.
- **A namespace vouches for nothing inside it.** Declare every `C_*`
  namespace in `.luacheckrc` with an explicit `fields` list, and add a
  member only once it is verified present on Forever. A bare namespace
  makes luacheck accept members that return nil at runtime.

### State transitions

```lua
WC_someState = WC_STATES.RUNNING           -- good
WC_someState = "running"                   -- bad - typos become silent
```

A typo in a string state is a silent bug (the comparison fails, the
transition never fires). A typo in a constant table key is a
nil-compare that fails closed and usually crashes loudly. The original
`STATE = { IDLE, LOOTING, WAITING_MERCHANT, SELLING }` table belonged to
the removed loot-cycle engine; there is no `STATE` table today, but
any new state machine follows the same rule.

### Chat output

```lua
PrintNice("Hello")                          -- static string
PrintNicef("Sold %d items for %s", n, g)    -- formatted
-- never:
DEFAULT_CHAT_FRAME:AddMessage("[WoWClearance] ...")
```

The prefix/colour are owned by `PrintNice`. Direct `AddMessage` calls
drift the prefix over time.

### Event handler

Add to the hub's switch in `WoWClearance_Events.lua`, do not spawn a new
frame, and verify the event name on Forever before registering it:

```lua
-- In the bottom event handler:
elseif event == "BAG_UPDATE" then
    -- new branch
```

## UI conventions

### Interface Options panels

The heading keeps its 3.3.5a name; on Forever the options UI has three
parts (PORT_STATUS work item 5, plus v0.5.3-v0.5.4):

- **The standalone window** (`WoWClearance_Window.lua`) hosts every
  panel. It is a plain `UIParent` child with a sidebar built from
  `WC_PANEL_ORDER`. It exists because Blizzard's `SettingsPanel` is an
  `area = "center"` UI panel without `allowOtherPanels`, so opening any
  Settings page calls `CloseAllBags()` and suppresses keybinds - for a
  bag addon, the worst possible pairing. Two `WC-TRAP:` markers guard it:
  do not add the window to `UISpecialFrames`, and do not restore the
  per-panel Settings sub-categories.
- **One Settings launcher page.** `NS.RegisterOptionsRoot` registers a
  single canvas category ("WoWClearance") via
  `Settings.RegisterCanvasLayoutCategory` +
  `Settings.RegisterAddOnCategory`, so the addon is still findable under
  Esc -> Options; its button opens the standalone window.
- **`NS.OptionsHost()`** returns whichever host is active (the standalone
  window's content frame when it is shown, else `SettingsPanel.Container`,
  else `UIParent`). Panels are created with it as their initial parent
  and reparented on demand by the window. It is resolved at call time, not
  captured at file load, because panel files run during ADDON_LOADED.

`NS.OpenOptionsPanel(frameName)` is the one way to open a panel by its
global frame name (`"WoWClearanceOptionsMain"` etc.); it routes to
`NS.ShowStandaloneWindow`. `NS.RegisterOptionsSub` and the frame-name ->
category-ID map remain in `WoWClearance_PanelInfra.lua` for the Settings
fallback path.

Pattern for every panel:

```lua
local MyPanel = CreateFrame("Frame", "WoWClearanceOptionsMy", NS.OptionsHost())
MyPanel.name = "My Panel"          -- display name (sidebar label)
MyPanel.parent = "WoWClearance"    -- kept for history; Forever ignores it

MyPanel:SetScript("OnShow", function(self)
    WC_compCache.initPanel(self, function(self)
        -- refresh dynamic widgets from DB (runs on every re-show)
    end, function(self, content)
        -- static widget creation (runs exactly once)
    end, true) -- true = wrap in a scroll frame
end)
```

`initPanel` runs `NS.EnsureDB()` and `WC_UpdatePanelWidth()`, then either
refreshes (when `self.inited`) or builds once. A new panel must also be
added to `WC_PANEL_ORDER` in `WoWClearance_Window.lua` (and to the order
list kept beside the ordering rationale in `WoWClearance_Events.lua`,
`NS.SettingsPanelOrder`); `tests/test_perf_guardrails.lua` checks every
`WoWClearanceOptions*` frame is reachable, because an unlisted panel
exists in memory and silently never appears.

**Reactive layout (v2.11.0+).** Panels are no longer width-frozen at
their first OnShow. Two resize hooks call
[`WC_compCache.refreshLayouts`](../WoWClearance_PanelInfra.lua): the
standalone window's own `OnSizeChanged` (in `WoWClearance_Window.lua`),
and an `OnSizeChanged` hook on the Settings host installed near the
bottom of the event hub (it replaced the 3.3.5a
`InterfaceOptionsFramePanelContainer` hook). On every resize it walks `WC_compCache.widthRegistry.widgets` and re-applies
`SetWidth(WC_PANEL_WIDTH - x)` to each, then re-fits scroll content for
each `(content, lastWidget)` pair on `widthRegistry.scrollFits`.

**Use the helper.** New widgets that snapshot `WC_PANEL_WIDTH` MUST
go through one of these:

```lua
WC_compCache.setPanelWidth(widget, x)        -- SetWidth + register in one call
-- or, when you've already called SetWidth:
WC_compCache.registerWidth(widget, x)        -- register only
```

[`MakeLabel`](../WoWClearance_PanelWidgets.lua) and
[`WC_WrapPanelInScrollFrame`](../WoWClearance_PanelInfra.lua) register their
widgets automatically;
[`NS.FitScrollContent`](../WoWClearance_PanelInfra.lua) registers itself the
first time it's called per panel. List widgets created via
[`CreateListUI`](../WoWClearance_ListWidget.lua) install their own
`box:OnSizeChanged` hook so internal rows track via the registered
content frame. (`CreateNameListUI` was removed; only `CreateListUI`
remains.)

**Panels using CreateListUI MUST anchor BOTTOMRIGHT
to the panel** so the box itself stretches with the panel:

```lua
self.listUI = CreateListUI(self, ...)
self.listUI:ClearAllPoints()
self.listUI:SetPoint("TOPLEFT", anchor, ...)
self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
```

Without the BOTTOMRIGHT anchor the box never receives an
`OnSizeChanged` event when the panel resizes, and the
`box:OnSizeChanged` hook inside the helper never fires.

The registry is session-scoped (lives on `WC_compCache`, not in
SavedVariables); a `/reload` reseeds.

**Regression tests.** The structural invariants are checked by
[`tests/test_layout_reactivity.lua`](../tests/test_layout_reactivity.lua),
run on every push by [`.github/workflows/test.yml`](../.github/workflows/test.yml).
The test catches: bare `:SetWidth(WC_PANEL_WIDTH - X)` calls outside
the helpers, missing `box:OnSizeChanged` hooks, panels missing the
`ClearAllPoints + BOTTOMRIGHT` follow-up, and list-row text using
`SetWidth(w - N)` instead of TOPLEFT/TOPRIGHT anchors. If you add a
new structural invariant, add a check to that file.

### Colour palette

Use the existing palette - do not invent new shades:

| Colour code  | Meaning         |
|--------------|-----------------|
| `\|cff4db8ff` | Addon title     |
| `\|cffb6ffb6` | Success / good  |
| `\|cffff4444` | Error / bad     |
| `\|cffffb84d` | Warning / note  |
| `\|cffffff00` | Emphasis yellow |
| `\|cff7fbfff` | Chat prefix     |
| `\|cff888888` | Muted / caption |

## Performance rules for 3.3.5a

The heading is historical (code comments cite "Performance rules"); the
rules below are the ones that still apply on Forever.

- **Never do a full bag scan per frame.** OnUpdate scripts that run
  every frame must early-return unless an accumulator threshold
  (`elapsed`, interval counter) has elapsed, and bag work goes through
  the BAG_UPDATE debounce frame and its shared snapshot (see the
  gotchas below).
- **Item data can be uncached.** `C_Item.GetItemInfo` returns `nil` for an
  item the client has not loaded. Ask for it with
  `C_Item.RequestLoadItemDataByID(itemID)` and read again later (the Loot
  Log does this, bounded per pass). The 3.3.5a warm-up through a hidden
  `GameTooltip:SetHyperlink()` still exists in places (`CreateListUI`,
  the bug report's name resolver) and still works. Never cache a
  negative answer from a cold item.
- **Vendor interval floor is 0.05s.** The original server disconnected
  addons that hammered the merchant; keep the floor in the
  `DB.vendorInterval` bounds rather than re-measure it on a live realm.
- **`wipe(t)` is preferred over `t = {}`** when clearing a table that
  has external references (saved variables, widgets holding a ref). This
  matters more since v0.6.0: the Sold History log tables ARE the saved
  tables, so replacing one breaks persistence silently.

## Saved variables

Always go through `EnsureDB()`. The function is idempotent and migrates
the legacy `EbonholdStuffDB` on first run. Adding a new field:

```lua
if type(DB.myNewField) ~= "number" then DB.myNewField = 0.5 end
```

Pick the type-tolerant form (`type(...) ~= "expected"`) so manually-
edited saved variables don't corrupt the addon.

Do **not** hard-delete fields when you rename; leave a migration:

```lua
if DB.oldName ~= nil and DB.newName == nil then
    DB.newName = DB.oldName
    DB.oldName = nil
end
```

## Ace3 - decision record

**We do not embed Ace3 in WoWClearance.** Reasoning:

- The addon works and is stable. A library migration is a rewrite, not
  a refactor.
- Ace3 embed is ~200KB of code for an addon that uses maybe 10% of
  the surface.
- Plain Lua keeps every line of the addon checkable against the Forever
  API surface. Third-party libraries are reference reading only, never a
  dependency: see PORT_STATUS "Third-party libraries: reference only,
  never a dependency" (several declare Interface 16001 with no
  Forever-specific handling).

If we ever did migrate, the minimum-viable Ace3 stack for this addon
would be:

| Library              | Replaces                                   |
|----------------------|--------------------------------------------|
| AceAddon-3.0         | The `ADDON_LOADED` / `PLAYER_LOGIN` dance  |
| AceDB-3.0            | `EnsureDB`, profile handling, per-char DBs |
| AceConfig-3.0 +      | The hand-built option panels and the       |
| AceConfigDialog-3.0  | standalone window collapse to one table    |
| AceTimer-3.0         | `WC_Delay` and the OnUpdate timer frames   |

Any embedded revision would have to be verified on Forever first; a
declared `## Interface: 16001` is intent, not evidence (porting lesson 4).

**What we steal without embedding.** The *shape* of AceConfig's options
table (`type`, `name`, `desc`, `order`, `get`, `set`) is worth
imitating even in vanilla code. If we rebuild our options UI, structure
it as an AceConfig-style table first - future migration becomes a
mechanical substitution.

## Tooling

### StyLua (formatter)

```
stylua *.lua                 # rewrite
stylua --check *.lua         # CI-style verify
```

Config is `stylua.toml`. 4-space indent, 120-column wrap, double
quotes preferred.

### Luacheck (linter)

```
luacheck WoWClearance_*.lua
```

Config is `.luacheckrc`. The CI gate requires **0 warnings**. If
Luacheck flags a WoW global we actually use, add it to `read_globals` -
don't silence the whole check. `C_*` namespaces are declared with
explicit `fields` lists; add a member only after verifying it exists on
Forever, or the gate will vouch for a call that returns nil
(`tests/test_api_surface.lua` pins this).

Know what the gate cannot see: event names, widget method names, XML
template names and return shapes are all resolved from strings or at
runtime. A file registering `"THIS_EVENT_DOES_NOT_EXIST_ANYWHERE"` passes
at 0 warnings. Never infer safety from a green gate (porting lessons 11
and 15).

### Tests

`lua tests/run_all.lua` runs every invariant suite and is the source of
truth for the list (10 suites today; CI and the release gate both call
it). Use `lua5.1` to match CI. The suites:

| Suite | Kind | Covers |
|---|---|---|
| `test_decision.lua` | runtime | `Decision.sell` / `Decision.deleteEligible` fixtures, including the v0.6.0 appearance and tradeable vetoes. New sell / keep / delete behaviour MUST land with a fixture here. |
| `test_dbproxy.lua` | runtime | The real `WC_DBBuildProxy` + `PER_CHAR_FIELDS` three-tier routing. |
| `test_api_surface.lua` | static | `.luacheckrc` declares every `C_*` namespace with `fields`; measured-absent members stay out; moved globals are namespaced. |
| `test_layout_reactivity.lua` | static | Reactive panel-width invariants. |
| `test_perf_guardrails.lua` | static | Perf, structure and wiring invariants (numbered Tests). |
| `test_comment_hygiene.lua` | static | Comment watch-list counts stay at or below baseline. |
| `test_comms_version.lua` | runtime + static | `parseVersion`, mandatory prefix registration, the measured-rejected event list. |
| `test_guildshare.lua` | runtime + static | Guild-share codec and aggregation. |
| `test_loothistory.lua` | runtime | `WoWClearance_LootHistory.lua` in isolation: the `CHAT_MSG_LOOT` parser, the ring buffer and the handler (v0.6.0). |
| `test_servershare.lua` | runtime + static | Server odometer codec, per-sender aggregate, default-off. |

Any "nothing is missing" style check needs a non-vacuity floor: an empty
input set satisfies every absence assertion (porting lesson 5).

### Verifying an API on Forever (the `wow` MCP server)

This machine has a `wow` MCP server (`mcp__wow__*` tools) indexing the
game's Lua API, Blizzard's shipped UI source, and the client's file and
atlas data. CLAUDE.md describes it in full; the habits that matter:

- **Always pass `flavor: "forever"`.** The tools default to retail and do
  not error when the flavor is omitted. Forever is close enough to retail
  that a wrong answer looks right.
- **Before writing a call**, confirm it with `wow_api_search` /
  `wow_api_event_search` / `wow_api_type_search`. Before building UI,
  read how Blizzard does it with `wow_ui_grep` / `wow_ui_read_file`.
- **Lint every new event name** with `wow_lua_lint` (flavor `forever`):
  it flags `event/unknown` by exact name, which luacheck cannot. Event
  search fuzzy-matches and does not say when there is no exact hit.
- **Strong evidence of presence, weak evidence of absence.** The Forever
  index has no globals or cvars, so `wow_lua_lint` does not check that a
  function exists, an empty `wow_cvar_search` means "no data", and a
  namespaced-only `wow_api_search` hit is not proof the bare global is
  gone - grep Blizzard's shipped source for bare usage instead.
- Resolve texture and atlas paths with `wow_file_search` /
  `wow_atlas_search`; a wrong path fails silently in game.

For deep "does X exist on Forever" or "how does Blizzard implement Y"
questions, the `wow-addon-architect` agent is available. Anything
irreversible still wants an in-game check.

### Qlty-aligned smell gates

Not wired into CI, but enforce in review:

- Functions over 80 LOC → extract helpers. (OnShow / OnUpdate closures
  may exceed this when building UI; prefer to split the init branch
  into a helper, see `BuildMainPanel`.)
- Nesting depth over 4 → flatten with early-return or extract a
  predicate.
- Argument lists over 5 → pack into an options table.
- Identical or near-identical code blocks over 6 lines → extract. See
  `runImport` (import Merge/Replace dedupe) as the canonical example.

## Slash commands

The README's slash-command table is the player-facing list and gets a
row for every new command. Contributor notes on the ones with internals
worth knowing:

- `/wc` - open the standalone settings window.
- `/wc status` - print whether WoWClearance is currently enabled or
  disabled, plus the three flip paths.
- `/wc enable` / `/wc disable` - flip the master `DB.enabled` toggle
  (per-character since v2.75.0; idempotent: no-op + plain message when
  already in the target state). Both route through
  `WoWClearance_ToggleEnabled()` so the minimap icon + Main panel
  checkbox stay in sync. v2.39.1.
- `/wc profile list|save|load|delete <name>` - list profile management.
- `/wc sprofile list|save|use|delete <name>` - settings profile
  management (v2.72.0).
- `/wc clean` - report items present on more than one list.
- `/wc clean apply` - auto-resolve list conflicts (precedence:
  blacklist > deleteList > whitelist).
- `/wc bugreport` - diagnostic dump for issue reports.
- `/wc highlight` - flip `DB.itemHighlighting`, the master switch over
  bag borders and item levels (`NS.SyncItemHighlighting`). v0.8.0.
- `/wc loot` - open the Loot Log window (`NS.ToggleLootWindow`). v2.46.0.
  Four views since v0.6.0: Session, Character, Account, and History (the
  persisted per-pickup ring in `WoWClearance_LootHistory.lua`).
- `/wc history` - opens the interactive Sold History window (`NS.ShowHistoryWindow` in
  `WoWClearance_HistoryWindow.lua`, v2.57.0; `NS.ShowSessionHistory` prefers it and falls back to
  the old copy-text dump if the module is absent). Reads the `NS.recentSoldLog` /
  `NS.recentDeletedLog` logs (each entry carries a `reason` set at decision time, a monotonic
  `seq` for exact newest-first ordering, and since v0.6.0 a `t = time()` stamp so entries from an
  earlier day show their date). The logs are 5000-entry rings each with a trim counter surfaced
  via `NS.SessionHistoryTrimmed`; on overflow the window shows "N earlier entries trimmed" rather
  than silently dropping. Window offers All/Sold/Deleted filters, a search box, a Clear button
  (`NS.ClearSessionHistory`), and a Copy button (dumps the filtered view through
  `NS.ShowCopyFrame`); it renders the newest `HIST_DISPLAY_MAX` (500) rows and rebuilds on
  `WC_compCache.historyDirty` while open. `/wc bugreport` still shows only the newest
  `NS.bugReportRecentMax` (20) of each so reports stay short. **Persisted per character since
  v0.6.0** (`DB.soldHistory`; see "Persisted ring logs"). Invariants in
  `tests/test_perf_guardrails.lua` Test 116.
- `/wc spike` - copyable session frame-hitch log (`NS.ShowFrameSpikes` over the
  `NS.recentSpikeLog` ring). A cheap always-on watchdog frame reads per-frame `elapsed`; on a
  hitch over the threshold (and under the loading-screen ceiling) it records the ms WC spent in
  each heavy phase that frame and flags the busiest. Phases are timed with `debugprofilestop`
  into `WC_compCache.spikePhase` (`bagupdate` = the settled BAG_UPDATE flush incl. loot-delta
  scan, `vendor` = the worker batch, `tooltip` = the annotation wrapper in the tooltip file).
  Only hitches WC actually contributed to are recorded, so an empty result is itself the answer.
  Session-only; bounded ring; no persistence. Invariants in `tests/test_perf_guardrails.lua`
  Test 115. **v2.76.0**: a second ring, `NS.worstSpikeLog` (cap 10, sorted descending by ms,
  evicted by SEVERITY not FIFO), keeps the biggest hitches of the session so one 400 ms frame
  isn't pushed out by twenty later 51 ms ones. Entries are SHARED between the two rings and
  immutable after insert; each carries `ecMs` (the sum of the three phase deltas, captured at
  insert) and the display derives WC's share of the frame from it ("WC 44 of 260 ms (17%)") -
  the exoneration line that proves whose stutter it was. Both `/wc spike` sections and both
  bugreport sections render it. Invariants in Test 134.
- `/wc rules` - plain-English summary of every active rule + the
  precedence WC uses to decide DELETE / SELL / KEEP. Same surface as
  the "Current Rules" button on the Main panel. v2.44.0.
- `/wc sellinfo` - the per-slot sell / keep trace (`describeSellability`
  in `WoWClearance_BagDisplay.lua`), rendered from `Decision.sell`.
- `/wc minimap on|off|reset`, `/wc perf`, `/wc scandebug`,
  `/wc processdebug [clear]`, `/wc help` - minimap button control and
  diagnostics; see the README table.
- `/wc commtest`, `/wc guildtest`, `/wc servertest`, `/wc realmtest` -
  solo test harnesses for the comms layers (see "Addon comms").
- `/wcdebug` - debug info plus bag scan.

Removed in the port: `/wc affixfallback`, `/wc affixdump`,
`/wc affixfind`, `/wc procdump`, `/wc captureproc`, `/wc procsharetest`
and `/wc bubbles` all belonged to the Project Ebonhold or companion
subsystems.

Key bindings (declared in `Bindings.xml`, handlers near the slash
commands):

- `WOWCLEARANCE_TOGGLE_SETTINGS` → `WoWClearance_ToggleSettings()`.
- `WOWCLEARANCE_TOGGLE_ENABLED` → `WoWClearance_ToggleEnabled()`.
- `WOWCLEARANCE_FORCE_SELL` → `WoWClearance_ForceSell()`.
- `WOWCLEARANCE_TOGGLE_LOOTLOG` → `WoWClearance_ToggleLootLog()`. v2.46.0.
  Since v0.6.0 `WC_compCache.claimLootLogKey` binds Shift+L to it once
  at first login, only if Shift+L is free and the Loot Log has no key
  yet (recorded in `ADB.lootLogKeyClaimed`).
- `CLICK WoWClearanceProcessCastBtn:LeftButton` - the Process Bags cast
  button.

Slash commands and binding handlers are registered near the bottom
of `WoWClearance_Events.lua`.

### PE-only UI visibility: `WC_compCache.peFeaturesVisible()` (v2.74.0)

**Removed in the port.** `peFeaturesVisible()` / `peFeaturesActive()`
gated the affix and chance-on-hit settings on whether the realm had the
Project Ebonhold affix system. Both predicates, the kill switch that
briefly forced them false, `WC_PE_HELP_IDS`, and every gated widget went
with the subsystem (PORT_STATUS work item 2). The heading stays because
ARCHITECTURE.md still points here.

Two lessons from it still apply to any setting you hide or remove:

- **Hiding a setting that defaults ON requires a matching runtime gate**,
  or the stored value keeps driving behaviour with the off-switch
  invisible.
- **Read a widget's or flag's real consumers before deleting it with its
  neighbours.** `DB.automarkProtectHighILvl` sat inside the affix widget
  run but also gates the surviving Resilience and learned-recipe
  auto-mark scans; deleting it with the run would have left a live
  setting unreachable from the UI.

## 3.3.5a gotchas

Historical: these were the 3.3.5a client's traps. What replaced each on
Forever:

- **Item links.** The ID is still the stable part
  (`link:match("|Hitem:(%d+)")`), but Forever links DO carry bonus IDs
  and modifiers, and two copies of one itemID can differ (item level,
  bound state). Per-copy facts come from the slot or an `ItemLocation`,
  never from an itemID-keyed cache.
- **Timers.** `C_Timer` exists on Forever; `WC_Delay` stays (see Lua 5.1
  constraints).
- **`GetContainerItemInfo`.** Gone; `C_Container.GetContainerItemInfo`
  returns one table or nil (see "Cached API globals").
- **`ChatFrame_AddMessageEventFilter` is global.** Still true: track any
  installation with a module-level flag so a `/reload` does not
  double-register.
- **`PLAYER_ENTERING_WORLD` fires after every zone transition**, not
  just login. Guard one-time work with a flag. Still true.

### Forever gotchas

Short list; PORT_STATUS "Porting lessons" has the reasoning.

- **`RegisterEvent` throws on an unknown name** and aborts the rest of the
  calling chunk. Lint the name first (see "The event hub").
- **A nil method usually means a wrong name**, not a missing capability.
  Dump `getmetatable(frame).__index` before concluding absence (lesson 1).
  Example: `popup.editBox` is nil on Forever; use `GetEditBox()` /
  `EditBox`.
- **Sparse tables from `C_*` calls** (equipment sets) need `pairs`.
- **Equipment set IDs are zero-based**; `for i = 1, GetNumEquipmentSets()`
  skips the only set a one-set character has.
- **Opening a Settings page closes the bags** (see "Interface Options
  panels").
- **Replacing a Blizzard global makes the addon a taint source.** The
  update link uses `LinkUtil.RegisterLinkHandler` instead of replacing
  `SetItemRef` (see "Addon comms"). Prefer a registration API or
  `hooksecurefunc` wherever one exists; the remaining raw override (the
  shift-click insert into WC's ID boxes, `ChatFrameUtil.InsertLink` plus
  the `ChatEdit_InsertLink` alias) carries a `WC-TRAP:` explaining why it
  must replace rather than hook.
- **A deprecation shim makes an old name resolve while nothing calls
  it.** `ChatEdit_InsertLink` exists on Forever only as an alias; Blizzard
  calls `ChatFrameUtil.InsertLink` directly, so overriding the alias did
  nothing. Ask "does anything still call it", not "does the global
  exist".
- **A `C_` prefix does not imply a table return.**

## Addon comms (`NS.Comms`) and version alerts

Added in v2.39.0. All addon-to-addon messaging lives in
[WoWClearance_Comms.lua](../WoWClearance_Comms.lua), which loads **after**
`WoWClearance_Events.lua` so `NS.GetVersion`, `NS.PrintNicef`, and `NS.Delay`
are already wired. It has two layers: a generic transport (`NS.Comms`) and the
first consumer (the version-update nudge).

**Transport.** `NS.Comms.Send(msgType, payload, channel, target)` and
`NS.Comms.RegisterHandler(msgType, fn)`. Sends go through
`C_ChatInfo.SendAddonMessage`. One hidden frame owns `CHAT_MSG_ADDON`;
it early-returns on a prefix mismatch and dispatches on the message type. The
wire format is `msgType .. "\t" .. payload` under prefix `"WCLR1"`. A new shared
feature (guild stats, etc.) adds a `RegisterHandler` call and nothing else.

**Forever constraints - several of these INVERT what the 3.3.5a code
did, so read them before "restoring" anything from history:**

- **`C_ChatInfo.RegisterAddonMessagePrefix` is MANDATORY.** On 3.3.5a
  every `CHAT_MSG_ADDON` was delivered and filtering by prefix was the
  whole job. On Forever the client never delivers `CHAT_MSG_ADDON` for an
  unregistered prefix, so without the registration the version gossip and
  the guild share load cleanly and never fire. `tests/test_comms_version.lua`
  asserts the prefix IS registered before the listener attaches (that
  assertion was inverted during the port).
- **Channels:** `PARTY` / `RAID` / `GUILD` / `BATTLEGROUND` / `WHISPER`.
  Reach is guild + group.
- **The group-roster event is `GROUP_ROSTER_UPDATE`**, registered in the
  event hub, which forwards to `NS.Comms.FireVersionProbe(channel)`.
  `PARTY_MEMBERS_CHANGED` is REJECTED by this client and would throw.
- **Version compare is numeric, never lexical.** `Comms.parseVersion` encodes
  `vMAJOR.MINOR.PATCH` to an integer so `v2.10.0 > v2.9.0`. A raw string `>`
  gets that backwards once any component reaches two digits. The unit test in
  `tests/test_comms_version.lua` locks this.

**Clickable chat links use `LinkUtil.RegisterLinkHandler`, not a
`SetItemRef` replacement.** The update nudge prints a custom
`|Hwcupdate:latest|h` hyperlink. On 3.3.5a the stock `SetItemRef` errored
on unknown link types, so the original replaced the global. On Forever
`SetItemRef` asks `LinkUtil.ProcessLink` first and an unregistered type
simply has no handler; replacing the global instead makes the addon a
taint source (measured by a sibling port's taint log). So the file
registers an `"wcupdate"` handler (guarded with `IsLinkHandlerRegistered`,
because a `/reload` re-runs the file and a duplicate registration
asserts). The 3.3.5a replacement is kept only as the fallback for a client
without `LinkUtil`; the `WC-TRAP` (rewritten v0.5.4) says not to collapse
the two branches. The click opens a `StaticPopup` with the release URL
pre-selected (the client cannot open a browser). The popup's edit box is
found through `GetEditBox()` / `EditBox` (the lowercase `editBox` field
does not exist on Forever) and sized in `OnShow` from the dialog width.

**Gating + opt-out.** Everything is gated on `WoWClearanceDB.versionAlerts`
(account-level, default `true`, additive `EnsureDB` nil-default). The Main panel
checkbox reads/writes `WoWClearanceDB.versionAlerts` **directly** - `BuildMainPanel`
has no `DB` proxy upvalue, so referencing a bare `DB` there is a nil-index crash
(it was, in the first cut).

**`/wc commtest`.** Solo diagnostic: a guild self-echo ping proves the server
actually relays addon messages (the gating unknown for any comms feature on a
given core), and a simulated higher-version peer exercises the real nudge path
and the opt-out. Reach for it first when a comms feature "does nothing" on a new
realm.

### Guild stats sharing (`NS.GuildShare`, v2.40.0)

`WoWClearance_GuildShare.lua` is the second `NS.Comms` consumer. It pools
guild/group stats into a transient, session-only aggregate
(`WC_compCache.guildAgg`) - never saved, re-polled each query.

- **Message types:** `GREQ` (broadcast on GUILD/PARTY/RAID when the panel opens
  or Refresh is clicked, throttled to match the comms send throttle) and `GDAT`
  (a whisper reply, sent only if `WoWClearanceDB.shareGuildData`). Payload
  sections, split on `|` and dispatched by prefix (order-independent):
  `stats:totalCopper,itemsSold,bestGPH`, optional `name:<player>` (only if
  `shareGuildData` AND `shareGuildName`), `qual:<q>=<count>;...` (per-rarity sold
  counts), `items:<id>~<name>=<count>;...` (top-3; the id powers the panel hover
  tooltip, the name displays so no `GetItemInfo` cache dependency), and
  `zones:<name>=<copper>;...` (top-5). Capped under 255 bytes; **zones trim
  first** since items/stats/quality are small and wanted.
- **Aggregation:** items pool by id (keeping the name), zones by name, quality
  summed per rarity; the best-GPH holder's name is tracked (nil if anonymous),
  and consenting names collect into a set for the "Shared by" line.
- **Anonymity** is at the display/storage layer: the `GDAT` sender is never
  stored or shown. `shareGuildName` is a dependent sub-toggle of
  `shareGuildData` (disabled/greyed when not sharing).
- **Load order matters:** `WoWClearance_GuildPanel.lua` ("Stats - Guild") loads
  BEFORE `WoWClearance_Events.lua` and `WoWClearance_Window.lua`, so its frame
  exists when the panel order lists (`WC_PANEL_ORDER`, `NS.SettingsPanelOrder`)
  place it right after "Stats - Personal"; its `initPanel`/widgets
  are deferred to OnShow, so the early load only creates the frame and sets
  `NS.RefreshGuildPanel`. `WoWClearance_GuildShare.lua` loads after
  `WoWClearance_Comms.lua` (it needs `NS.Comms` at load).
- **`/wc guildtest`** injects simulated members plus the local player via the
  real send path (honoring live toggles), so the panel is testable solo.

### Chance-on-hit proc-pairing sharing (`NS.ProcShare`, v2.53.0)

**Removed in the port** (PORT_STATUS work item 2, stage A).
`WoWClearance_ProcShare.lua` shared learned Project Ebonhold
chance-on-hit proc pairings (`PREQ` / `PDAT`) between guild peers and
wrote them into `ADB.chanceProcConfirmedItems` with a local-wins merge.
The file, its message types, `/wc procsharetest` and
`NS.recentProcShareMerges` are gone. History is in
EbonClearance's `CHANGELOG.md` (v2.53.0).

### Realm-wide comms + Server Stats odometer (`NS.RealmComms` / `NS.ServerShare`, v2.58.0, transport rebuilt v0.6.0)

Rebuilt for Forever (PORT_STATUS work item 7): **addon messages** (prefix
`"WCLRS"`) on a **temporary** custom channel (`"wowclearance"`), not chat
text. Channel text needs a hardware event on Forever, so the 3.3.5a
`SendChatMessage` design could never send from a timer. A channel reaches
only your own underlying realm, so "realm-wide" means one realm copy.
Default OFF; joined only by an opted-in player, left on opt-out.

- **`NS.RealmComms` ([WoWClearance_RealmComms.lua](../WoWClearance_RealmComms.lua))** is a **sibling** of `NS.Comms`: same `RegisterHandler` / `Send(msgType, payload)` shape, no channel/target (one destination). Its own registered prefix (`"WCLRS"`, mandatory on Forever); `msgType \t payload` on the wire; received on `CHAT_MSG_ADDON` only when `channel == "CHANNEL"` and `canaccessvalue` allows. `Join()` uses `JoinTemporaryChannel` (permanent channels keep their `/N` between sessions) and waits while `/1` is empty; `Leave()` uses `LeaveChannelByName`; `Send` never joins and drops when not joined. An `OnUpdate` queue paces sends at `SEND_DELAY=0.15s`, waits out `InChatMessagingLockdown`, backs off on throttle results and drops permanent refusals. **No chunking** (the client cuts addon messages at 255 bytes without an error). `RunSelfTest()` (`/wc realmtest`) relies on the channel echoing your own message.
- **`NS.ServerShare` ([WoWClearance_ServerShare.lua](../WoWClearance_ServerShare.lua))** is the odometer aggregator. It reuses `GuildShare.topZones` but has its **own** compact codec (fields: `t:cop,sold,del,proc | ver: | i: | z:`, 200-byte capped) because the odometer needs items-deleted + items-processed that GuildShare's payload lacks, and a tighter channel cap. **Per-sender keyed store** `NS.compCache.serverPeers[sender] = {d, t}` (session-only, latest-wins, 20min TTL) - NOT GuildShare's additive `mergeReply`, so a re-broadcast never double-counts and distinct live keys ARE the headcount. `GetAggregate()` sums/pools over live entries. **Anti-storm:** on-demand `SREQ` (self-suppressed if the channel was active in the last 90s; 60s cooldown) -> opted-in peers reply `SDAT` **on the channel** (never whisper), jittered, at most once per 30s. Everyone aggregates passively. **Spoof cap:** `saneDecoded` drops absurd totals (`COPPER_CAP`/`COUNT_CAP`); the tally is never saved. **Update checks piggyback:** the version in `SREQ`/`SDAT` feeds `NS.Comms.NotePeerVersion` (exposed for this), reusing the existing nudge unchanged.
- **Default OFF, and no login-time join. This is a WC-TRAP, not a preference.** The v2.59.1 default-ON seed, its `shareServerDataDefaultBumped` migration marker, and the `PLAYER_LOGIN + 7s` auto-join were all **removed** during the Forever port. Do not restore any of the three. (v0.6.0 `EnsureDB` reads the old marker only to clean it up: a save that still carries `shareServerDataDefaultBumped` had sharing forced on, so the cleanup turns `shareServerData` off and deletes the marker once.) Two reasons, and the second is the one that is easy to miss:
  1. Forever is a **live Blizzard realm**, not a private server. Joining a chat channel and broadcasting on login is a decision that belongs to the player, not to a shipped default. See PORT_STATUS work item 7, still open pending an explicit decision.
  2. On client build 69913 the opt-out **could not persist** (saving works from build 70245), so a default-ON seed is not a default at all - it is a re-decision taken on the player's behalf at every launch. The guide used to say here that "the user can flip it off in the panel and it stays off". That was false: SavedVariables are written on exit and never read back (hard release gate in PORT_STATUS), so `shareServerData` reads nil every launch, the fresh-install branch re-fires, and the marker meant to make the bump one-shot is itself erased every time. **The migration marker could never do its job on this client.**

  Seeding OFF is safe under that same breakage, which is the point: an erased opt-**in** costs a feature until the player re-enables it; an erased opt-**out** costs them a broadcast they had declined. Fail in the direction that stays quiet.

  A single `shareServerData` flag still controls share + view (it shows no names, so there's no name-sharing toggle). The channel is joined **only** for an opted-in player, from the "Stats - Server" panel (its toggle, or `ServerShare.RequestNow` when the panel opens / Refresh), and left when they opt out. **Realm-wide update alerts have NO separate toggle:** the version carried in `SREQ`/`SDAT` feeds the existing `versionAlerts` nudge (via `NotePeerVersion`). Pinned by `tests/test_servershare.lua`, whose two absence-shaped checks carry a non-vacuity guard - mutation-tested, since with the source read stubbed to `""` both negatives pass vacuously and only the guard fires.
- **Panel:** `WoWClearance_ServerStatsPanel.lua` (frame `WoWClearanceOptionsServer`, "Stats - Server"), mirrors GuildPanel; loads after GuildPanel, registered centrally in Events. Viewing requires `shareServerData` (reciprocity + bounds the sample to sharers).
- **`/wc servertest`** injects fake sharers (incl. one the spoof cap must drop) so the panel is testable solo. Locked by `tests/test_servershare.lua`.

## Localization (`NS.L`)

This version is English only. The French / German templates, `/wc locale`
(`DB.localeOverride`) and both locale test suites were removed in the
Forever port. `WoWClearance_Locale.lua` loads right after Core and makes
`NS.L` a passthrough: `L[k]` returns `k`.

The call-site wrapping stays, so a translation layer can come back without
touching every file: `local L = NS.L` at the top of each emitting file, and
the player-facing literal wrapped at the call site
(`PrintNicef(L["Sold %d items."], n)`). The whole format string is one key
(never concatenate fragments). Never wrap a string used in a comparison or as
a table key (`== "..."`, `:find(...)`, `t["..."]`): the tooltip verdict logic
reads an English `statusTag` token, not the displayed label, for this reason.
Engine button globals (`YES`/`NO`/`OKAY`) stay unwrapped.

## Forever port patterns

Patterns added or reshaped by the port that a contributor needs before
touching the surrounding code. Each was verified against the code at
v0.6.0.

### Bind state is read per copy

`WC_compCache.getBindType(bag, slot)` (Events) reads the slot's
`C_Container.GetContainerItemInfo(bag, slot).isBound` **live on every
call** and returns `"bop"` when that copy is bound. Only when the copy is
not bound does it fall back to `WC_compCache.itemBindType(itemID)`, which
reads the item's bind TYPE from `GetItemInfo`'s 14th return
(`Enum.ItemBind`: 1 -> `"bop"`, 2 -> `"boe"`, else `"any"`).

`WC_compCache.bindCache` holds **only that bind type**, keyed by itemID,
because the type is fixed per itemID. Whether a given copy is bound is
never cached. The old itemID cache treated "Soulbound" as immutable, so
one worn copy of a BoE item made every unworn copy read `"bop"` for the
session, and a "BoP only" rule could then sell a tradeable copy. A cold
item (`GetItemInfo` not loaded) returns `"any"` without storing a guess.

`getBindTypeFromTooltip` (hover and chat-link surfaces) reads the hovered
tooltip's lines every time against the client-localized
`ITEM_BIND_ON_PICKUP` / `ITEM_SOULBOUND` / `ITEM_BIND_ON_EQUIP` globals
and never writes `bindCache`; with no bind line it falls back to
`itemBindType`. Do not add a per-itemID cache of bound state anywhere.

### One shared `ItemLocation`: `Decision.slotLocation(bag, slot)`

Per-copy `C_Item` reads (`GetCurrentItemLevel`, `DoesItemExist`,
`CanBeRefunded`) take an `ItemLocation`, not a bag/slot pair.
`NS.Decision.slotLocation(bag, slot)` returns ONE reusable `ItemLocation`
(created lazily with `ItemLocation:CreateEmpty()` and re-pointed with
`SetBagAndSlot`), because the adapters run per slot per flush and
`CreateFromBagAndSlot` would allocate every time. Lazy creation also lets
the headless test stub, which has no `ItemLocation` mixin, load the file.

Rules: use it for any new per-copy read (current users: the bag-item and
equipped-item level reads in `Decision.lua` and the Events item-level
path, and `isTradeableOrRefundable` in Protection). Treat the returned
object as valid only until the next call - read what you need
immediately and never store it.

### The two Forever protections are `Decision.sell` vetoes on auto rules

v0.6.0 added `DB.protectUncollectedAppearances` ("keep gear with an
appearance you haven't collected") and `DB.protectTradeableLoot` ("keep
loot you can still trade or refund"). Both default ON (`EnsureDB`) and
both are settings-profile fields. They are vetoes inside `Decision.sell`,
placed after the tome veto with the same release shape:

```lua
if qualityPass and not whitelistPass and not recipePass and not ctx.allowedItem then
    if ctx.protectUncollectedAppearances and ctx.uncollectedAppearance() then
        return "keep", "appearance"
    end
    if ctx.protectTradeableLoot and ctx.tradeable() then
        return "keep", "tradeable"
    end
end
```

So they **only stop the automatic quality rules**. A Sell List entry,
Sell Known Recipes, and per-item Allow Sell are explicit intent and still
sell; greys never reach them (`isJunk` is quality 0, the rules cover 1-4).
The predicates are lazy thunks, so they cost nothing unless a quality rule
already matched:

- `ctx.uncollectedAppearance()` -> `WC_compCache.isUncollectedAppearance(link)`
  (Protection): `C_TransmogCollection.GetItemInfo` for the source ID, then
  `PlayerHasTransmogItemModifiedAppearance` / `PlayerCanCollectSource`.
  An unknown answer is `false` - no opinion, the other rules decide.
- `ctx.tradeable()` -> `WC_compCache.isTradeableOrRefundable(bag, slot)`
  (Protection): `C_Item.CanBeRefunded` on the shared `ItemLocation`, else a
  `C_TooltipInfo.GetBagItem` line of type
  `Enum.TooltipDataLineType.TradeTimeRemaining`. Per copy and expiring, so
  nothing is cached.

Both adapters (`buildCtx` and `buildTooltipCtx`) define the two thunks,
so the tooltip, the trace and the vendor agree. Fixtures live in
`tests/test_decision.lua`. A new protection should follow the same
shape: a ctx setting + a lazy thunk + a veto token + fixtures.

### Persisted ring logs (Loot Log History, Sold History)

v0.6.0 made two logs outlive the session, once SavedVariables read-back
was measured working (see PORT_STATUS "Hard release gate"). Both are
fixed-size rings: the write slot is `((writes - 1) % MAX) + 1`, so at the
cap the oldest entry is overwritten in place. Never `table.remove(t, 1)`
(the v2.68.1 rule, Test 124), and readers order by sequence, not by array
position.

**Loot Log History** (`WoWClearance_LootHistory.lua`, `NS.LootHistory`,
account-wide `ADB.lootHistory`, `MAX = 20000`):

- Saved shape `{ v = 2, writes = N, e = {...}, names = {...} }`. Each
  entry is ONE packed string `"time:itemID:qty:nameIndex"`; looter names
  are stored once in `names`. Packing roughly halves the saved size of a
  table-per-entry layout.
- In memory the strings are decoded ONCE into parallel number arrays
  (the decoded mirror), rebuilt only when the saved table identity
  changes. `Append` keeps the mirror and the packed string in step.
  Readers use `LootHistory.SlotAt(k)` (newest first) and `Get(slot)`.
- An older v1 shape is migrated on first access by re-appending its
  entries oldest first.
- Sources: own loot via `WC_BumpLoot` calling `LootHistory.Add` with the
  bag-delta count (so it matches the aggregate views exactly), and group
  members via `CHAT_MSG_LOOT` on the event hub, parsed with patterns built
  from the client's `LOOT_ITEM*` format strings. Lines naming the player
  are skipped on purpose - the bag delta already counted them.
- Chat payloads can be secret on this client: the handler checks
  `canaccessvalue` before reading, as Blizzard's own chat filters do.
- Runtime tests: `tests/test_loothistory.lua`.

**Sold History** (Events, per-character `DB.soldHistory`, 5000 sold +
5000 deleted):

- The live log tables (`NS.recentSoldLog` / `NS.recentDeletedLog`) ARE
  the saved tables. At login `WC_compCache.loadSoldHistory()` copies any
  saved entries INTO the existing live tables (they keep their identity,
  because other files hold references), then points `h.sold` /
  `h.deleted` at them and stores `h` as `DB.soldHistory`. Every later
  write lands in SavedVariables with no copy.
- `WC_compCache.syncSoldHistory()` mirrors the ring cursors, trim
  counters and the insertion `seq` into the store after every write and
  after Clear, so the ring and newest-first order carry on across
  sessions.
- **Load order:** `loadSoldHistory` runs in the `PLAYER_LOGIN` branch,
  after `EnsureDB` has bound the per-character proxy - `DB.soldHistory`
  is a `PER_CHAR_FIELDS` entry and must resolve to the right character.
  It is idempotent (`soldHistoryStore` guard). Do not move it earlier.
- Clearing uses `wipe()` on the live tables and resets the cursors; never
  replace a log table with `{}`, or the saved table and the live one
  diverge silently.
- The "saved by re-check" log (`NS.recentSavedLog`) stays session-only on
  purpose.

### DaylightUI integration (v0.8.0)

Built only against DaylightUI's public plugin API (`DaylightUI.API`, its
`API.md`). Its licence forbids copying its code, art or text: read it to
find the call, then write our own. Two homes:

- `WoWClearance_BagDisplay.lua`, inside `installHostBagBorderHook`, beside
  the other bag UI adapters:
  - `tryPluginApiHost`: borders through `me.Paint("bagslot", ...)`, drawn
    on the `API.Attach(slot)` holder. These slots are flat, so the ring is
    a solid 2 px border (`holder._wc_flatRing`), not the additive glow.
    Slots from another character's saved bags arrive as previews and are
    skipped.
  - `tryPluginApiBagGroups`: one bag group per list (keys saved in the
    host's own profile), a wrap of its `Categories.Assign` to file items,
    a row for our menu in its Alt+Right-Click menu, its Lock folded into
    `ctx.blacklisted` (`WC_compCache.hostLocked`), its junk mark as a junk
    signal (`hostMarkedJunk`), and its own junk sale switched off while
    `DB.sellAtVendor` is on.
- `WoWClearance_Daylight.lua` (loads last): the look, a plugin section in
  its options whose rows read and write our own DB (get / set, one copy of
  each setting), `/dui wc`, a broker data text, and window movers.

Traps, each of which cost a round trip:

- **Saved variables are nil at file scope.** `WoWClearanceDB.daylightLook`
  is read inside the skin callback. A file-scope check always saw nil and
  the off switch did nothing.
- **`me.Wrap` / `me.Hook` targets are not promised stable.** Paint,
  Attach, RegisterSkin, RegisterMover, RegisterCommand and the options
  rows are. Every lookup on the host's module tables is type-checked, and
  a miss leaves WoWClearance behaving as if the host were absent.
- **A `.toc` file-list change needs a full client restart**, not `/reload`.

### `WoWClearance_Events.lua` is at the 200-locals cap

Lua 5.1 allows at most 200 local variables in one function, and a file's
main chunk is a function. The Events main chunk sits AT that cap (many
comments in the file say so). Adding one more file-scope `local` there
fails to compile the whole file. So:

- New module-level state or helpers go on `WC_compCache` (e.g.
  `WC_compCache.settingsProfileFields`, `soldHistoryStore`,
  `loadSoldHistory`, `claimLootLogKey`) or on `NS`.
- `local NS = select(2, ...)` captures only the second vararg for the
  same reason.
- If a change genuinely needs a new file-scope local, free one first or
  move a cluster into its own file (as `WoWClearance_LootHistory.lua`
  was) - and register that file in the `.toc` and CLAUDE.md's count.
- Other files are well under the cap but follow the same habit.

The CI step `luac -p` over every `WoWClearance_*.lua` catches an
over-cap chunk as a compile error.

### Verify on Forever before you write

Covered in full under "Verifying an API on Forever (the `wow` MCP
server)". The short form: `flavor: "forever"` on every call, exact-name
lint for events, presence is strong evidence and absence is weak, and
anything destructive or irreversible gets an in-game check.

## Gotchas and refactoring traps

Read this section before touching any of the subsystems below. Each item is
a non-obvious design choice that has silently broken in the past (or would
if you "simplified" it).

Many of these (and a few others) also carry an inline `WC-TRAP:` marker at
the exact line in the code. Before you delete or "simplify" anything that
looks like dead code, cruft, or a bug, run `grep -rn "WC-TRAP:"` - every hit
is intentional code that has misled someone before. Read the marker and
follow its pointer (a locking test, a section here, or a
`docs/CODE_REVIEW.md` item) before changing it. Never remove an `WC-TRAP:`
line as part of a cleanup. When you add a new intentional-but-looks-wrong
construct, mark it the same way: `-- WC-TRAP: <what it looks like>. Do NOT
<wrong action> - <what breaks>. See <pointer>.`

### Saved-variable migration order is load-bearing

`EnsureDB()` does two migrations in a specific order that must not be reshuffled:

1. **Legacy rename**: if `EbonholdStuffDB` exists and `WoWClearanceDB` does
   not, rename the former into the latter. This has to happen first because
2. **Profile migration**: when the profile-aware schema first runs, it
   snapshots any existing `DB.whitelist` into an `"Imported"` profile and
   auto-activates it. If the legacy rename hasn't happened yet, `DB.whitelist`
   is empty and the user's pre-profile data is lost.

If you add a new migration, put it with the others at the top of
`EnsureDB()` and write the order dependency into the comment.

### The sell/keep decision core (v2.71.0, `WoWClearance_Decision.lua`)

Since v2.71.0 the entire sell/keep decision lives in
`WoWClearance_Decision.lua` (Stage 1 of the decision-classifier plan,
`EbonClearance's docs/specs/2026-07-29-decision-classifier-design.md`; CODE_REVIEW item 6):

- **`NS.Decision.sell(ctx)`** is the PURE core: it reads only the ctx
  table (plain values + caller-supplied thunks) - no WoW API, no `DB`,
  no `WC_compCache`. It returns `verdict, reasonToken, fields` where
  verdict is `"sell" | "keep" | "none"`. Tokens are append-only once
  shipped; renderers must tolerate unknown tokens. Current keep tokens:
  `equipped`, `blacklist`, `tomeProtected`, `tomeUnlearned`, and (v0.6.0)
  `appearance`, `tradeable`.
- **`NS.Decision.buildCtx(bag, slot, junkOnly)`** is the adapter: it
  snapshots cheap live reads and wraps the expensive predicates
  (`bindType`, `downgradeVsEquipped`, `isTome`, `knowsTomeSpell`,
  `uncollectedAppearance`, `tradeable`, ...) as lazy thunks routed to the
  existing `WC_compCache` accessors, so scan cost and short-circuit
  behaviour are unchanged. Item level is the copy's
  `C_Item.GetCurrentItemLevel` via `Decision.slotLocation`.
- **`WC_IsSellable` in `WoWClearance_Events.lua` is a thin delegate**
  (buildCtx -> sell -> translate to the legacy return shape +
  `WC_compCache.lastSellSignal`). Callers are unchanged.

Because the core is WoW-free it loads under stock lua5.1, which is what
makes `tests/test_decision.lua` the addon's RUNTIME coverage of the sell
logic. **New sell/keep behaviour MUST land with a fixture there** - the
static pattern pins in `test_perf_guardrails.lua` still guard the source
shape, but the fixtures are what prove the behaviour.

**Stage 2 (v2.71.1):** the trace (`describeSellability` in
BagDisplay.lua) now consumes the core: it builds ONE ctx via
`NS.Decision.buildCtx(bag, slot, false)` for every read, and its
summary renders from `NS.Decision.sell`'s verdict - the trace
structurally cannot disagree with the vendor about the OUTCOME. The
per-step narration is still derived branch by branch (a single winning
token can't explain every non-winning step), so a **drift sentinel**
compares the narration's own conclusion against the core verdict and
emits a visible `traceDrift` step on mismatch (Test 127). If you change
the core, update the matching narration branch so the story matches
the verdict.

**Stage 3 (v2.71.2):** the tooltip (`WC_AnnotateTooltip` in
Tooltip.lua) consumes the core the same way. A second adapter,
`NS.Decision.buildTooltipCtx(tooltip, itemID)`, serves hovers and chat
links: there is NO bag/slot for those, so its instance predicates route
to the `liveTooltip*` scanners (and `getBindTypeFromTooltip`) instead of
the bag-slot accessors. Both adapters fill memberships/settings through
one shared helper (`WC_fillSharedCtx`) so they cannot drift. The label
branches stay hand-written (they need the WHY at a granularity one token
can't carry), guarded two ways: a centralized equipped-honesty fix-up
(no label may promise a sale of a worn item) and a verdict sentinel that
appends a visible "(WC label check failed ...)" line when a label class
contradicts `Decision.sell` on the same ctx (Test 128).

**Stage 4 (v2.71.3):** the delete side. **`NS.Decision.deleteEligible(ctx)`**
is the pure Delete-List destruction gate (tokens: `deleteList` when
eligible; `notOnList` / `keepList` / `sellList` / `equipped` / `locked`
vetoes). The v2.50.2 rescue vetoes (the shirt-loss fix) live in it WITH
their WC-TRAP - including the deliberate asymmetry that the ACCOUNT Sell
List rescues but the character Sell List does not.
`WC_compCache.deleteListSlotEligible` is a thin delegate that keeps a
cheap membership pre-gate (unlisted slots stay at one table lookup - it
runs per slot in BAG_UPDATE scans) before building a ctx. The trace's
`deleteListVerdict` step and BOTH tooltip Will Delete label sites render
from the same gate, and the tooltip sentinel covers delete labels too.
The auto-mark scans and their tooltip preview stay on the shared-gate
contract (`itemProtectedFromAutoMarkDelete`) - deliberately NOT in the
core (they predict a future marking, not a current decision). (The
`affixProtected` delete token and the `affixDisposable` release policy
went with the Project Ebonhold subsystem.)

With Stages 1-4 shipped, every sell AND delete decision reads ONE
state snapshot and answers to ONE verdict source. The remaining
hand-maintained parts are the narration/label branches, and the
sentinels flag those if they fall behind the core.

### Grey items are sold by default, independent of the rule settings

> **v0.8.0:** the player can now turn this off. `DB.sellGreys == false`
> (Merchant Settings, "Sell grey items") reaches the core as
> `ctx.sellGreys` and switches `isJunk` off for greys; nil reads as on. A
> grey on the Sell List still sells through `whitelistPass`. A host bag
> UI's "sell as junk" mark (`ctx.hostMarkedJunk`) also sets `isJunk`, at
> any quality. Everything below still holds with the switch on, and the
> three passes must still not be merged.

In the decision core (`Decision.sell`; historically `WC_IsSellable`),
positive sell signals are ORed together in the initial
gate and the exit-gate recheck. The signals today are:

- `isJunk` (grey `quality == 0 and hasSellPrice`)
- `qualityPass` (per-rarity iLvl rule)
- `whitelistPass` (Sell List membership)
- `recipePass` (`DB.sellKnownRecipes` + learned profession recipe)

(The affix and chance-on-hit signals `affixRankPass`, `autoDupePass` and
`knownProcPass` were removed with the Project Ebonhold subsystem.)

`isJunk` is the only one that is NOT gated on `junkOnly`. This means grey
items with a positive sell price are *always* matched at any merchant -
the quality-threshold toggle and the whitelist have no say. Every OTHER
positive signal MUST gate on `not junkOnly` so a greys-only run restricts
sales to grey. Nothing sets `junkOnly` true since the Goblin Merchant
mode went, but the parameter is kept deliberately (a greys-only mode is a
plausible future use) and the fixtures still pin its gates: if you add a
new positive signal, mirror the `not junkOnly` prefix from `qualityPass`
and add a fixture to the "merchant mode (junkOnly) + sell-price gates"
block in `tests/test_decision.lua`.

Do not combine the passes into "one cleaner check." You will silently
break either the grey-always-sold invariant OR the junkOnly
restriction. The only things that can veto a grey are the equipped check
(`C_Item.IsEquippedItem`) and the Keep List, both of which are safety
gates. The quality-rule vetoes (tome, appearance, tradeable) never see a
grey.

### Removed in the port: companion naming, `"CRITTER"` slot, auto-loot cycle

Three gotchas documented the Greedy Scavenger / Goblin Merchant
companions and the four-state loot-cycle engine (`IDLE` / `LOOTING` /
`WAITING_MERCHANT` / `SELLING`): the `TARGET_NAME` / `PET_NAME` locals
mirroring `DB.merchantName` / `DB.scavengerName`, the shared `"CRITTER"`
companion slot, and the cycle resetting on `MERCHANT_CLOSED`. All of that
code was removed in PORT_STATUS work item 2, stage B (about 3,000 lines),
along with `WoWClearance_Companion.lua` and the Scavenger panel. The full
text is in git history and EbonClearance's `CHANGELOG.md`.

### `WC_Delay` callbacks must surface errors via `geterrorhandler`

The custom `WC_Delay` timer wraps each callback in `pcall`. Without a
follow-up call to `geterrorhandler()(err)`, errors inside delayed callbacks
disappear silently -- which is exactly what hid the v2.0.13 scoping bugs
for several releases.

If you add a new delayed-callback helper (or a new timer frame), route
errors the same way `WC_Delay` does. Do not add new bare `pcall` swallows.

### Delete-list seeding is deliberately empty

`EnsureDB()` still has a `_seededLists` one-shot flag, but the list it used
to seed (item IDs 300581 and 300574) was removed as stale cruft. Empty
delete list on first install is intentional. If a future scenario needs to
pre-populate specific IDs, use the `_seededLists` guard to avoid re-seeding
existing users.

### Deleting is one Delete Next press per item (v0.6.0)

**The automatic delete paths were removed in the port.** On this client
`DeleteCursorItem` needs a hardware event, so the vendor-run delete,
auto-delete on pickup (`runAutoDeleteOnPickup`) and auto-delete grey on
loot (`runAutoDeleteGrey`) are gone. `DB.autoDeleteOnPickup` and
`DB.autoDeleteGreyOnLoot` may still sit in old saves; nothing reads them
as behaviour.

What remains is `WoWClearance_DeleteNext` (a key binding and the Delete
List panel button), which deletes ONE item per press:

- `WC_compCache.deleteListSlotEligible(bag, slot)` is the policy (a
  delegate to `Decision.deleteEligible`: on the list, not locked, plus
  the Keep / account Sell / equipped rescue vetoes). Do not re-inline it.
- `WC_compCache.executeBagSlotDelete(...)` is the destructive sequence
  (pickup, `pendingDelete`, `DeleteCursorItem`, stat bumps). WC-TRAP: do
  not add a second raw `PickupContainerItem` + `DeleteCursorItem` path;
  the helper owns the popup serialisation.
- With "Mark grey items for deletion" on (`DB.markGreyForDeletion`), once
  the Delete List is clear the press takes `WC_compCache.nextGreyToDelete()`:
  the cheapest grey that is not kept, equipped, a quest item or locked by
  a host bag UI.

### Conflicting-addon warning (v2.49.2)

`DB.warnConflictingAddons` (per-character, default on, opt-out) surfaces a modal
warning popup (`StaticPopupDialogs["WC_CONFLICT_WARNING"]`, "Open Settings" jumps
to the main panel) at PLAYER_LOGIN when WC's delete path is active AND a
third-party auto-delete addon is loaded. It is a popup rather than a chat line
because a one-time chat message was easy to scroll past. Detection is
`WC_HasConflictingDeleteAddon()` (exposed as `NS.HasConflictingDeleteAddon` so
`/wc bugreport` shares the source of truth). Per the "No third-party addon
references in new WC artefacts" rule, only the `IsAddOnLoaded` folder-name string
is specific; the helper name, local variables, comments, and the bug-report line
all stay neutral ("third-party auto-delete addon"). Since the port the folder
check goes through `C_AddOns.IsAddOnLoaded` (cached as `IsAddOnLoaded`).
The popup copy is neutral too ("Another addon that deletes items is also
running"); the bug report's Loaded Addons dump lists the addon by folder name.
This mirrors the host-bag-UI detection convention (specific globals in code,
neutral framing everywhere except the one sanctioned player-facing string). The
opt-out toggle lives on
the **main** panel (`WoWClearanceOptionsMain`) with the other global toggles
(version alert / minimap button), not in Delete Settings - it's an informational
preference, not a delete rule.

### Auto-mark unsellable affixes + `affixDisposable` / `playerOwnsAffix` (v2.47.0)

**Removed in the port.** `DB.autoMarkAffixDupes`,
`WC_compCache.runAutoMarkAffixDupes`, `affixDisposable`,
`playerOwnsAffix` and the `keepBoeAffixDupes` bind-type split all
belonged to the Project Ebonhold affix subsystem (PORT_STATUS work item 2,
stages C-F). The surviving auto-mark scans are
`WC_compCache.runAutoMarkResilience` and
`WC_compCache.runAutoMarkKnownUnsellableRecipes`; both still share the
`itemProtectedFromAutoMarkDelete` gate and the Delete-List rescue
described under "`DB.blacklistAuto`" below.

### Vendor-refused items get a per-cycle blacklist (v2.46.4)

On 3.3.5a `UseContainerItem(bag, slot)` at a merchant was measured async
(the slot empties after `ITEM_LOCK_CHANGED` -> `BAG_UPDATE`) with no
status code, so a successful sale and a server-side refusal were
indistinguishable at the call site. The Forever call
(`C_Container.UseContainerItem`, cached as `UseContainerItem`) is used
the same way and the guard below is kept unchanged. `WC_IsSellable` pre-filters
`sellPrice == 0`, but some items pass the client-side pre-check and still
get rejected by the server (BoP-on-use, quest-adjacent epic, race
condition, stale `GetItemInfo` cache).

Before v2.46.4, `BuildQueue`'s fresh bag walk every cycle re-queued the
refused item, `DoNextAction` called `UseContainerItem` again, `FinishRun`
inflated the counter by queue length, and the cycle spun forever spamming
`Sold X items so far, looking for more` (Broyo's bug report).

The guard is a file-local `WC_vendorRefusedThisRun` table in
`WoWClearance_Events.lua`, keyed by `(bag * 100 + slot) -> itemID`:

- `DoNextAction` marks the slot immediately after `UseContainerItem`. Mark,
  not refusal - the verification happens later when the next `BuildQueue`
  sees whether the slot still holds the same item.
- `BuildQueue` consults the table before `WC_IsSellable` (cheap dictionary
  lookup before the expensive tooltip scan). If
  `WC_vendorRefusedThisRun[key] == C_Container.GetContainerItemID(bag, slot)`, the
  slot still holds the same item we tried earlier -> vendor refused ->
  skip. A different item in the slot (loot, drag-drop, swap) gets a fair
  try because the equality check fails.
- The table is wiped on `StartRun` AND `MERCHANT_CLOSED`. A new merchant
  visit (or the same visit reopened) retries refused items afresh.

WC-TRAPs that look like dead code or over-engineering:

- **The itemID equality check is mandatory** - a key-only presence test
  would block organic slot moves (loot, swap) and freeze legitimate sells.
- **The pre-check runs BEFORE `WC_IsSellable`, not after** - reordering
  would re-pay the tooltip scan for every refused duplicate every cycle. A
  worst-case bags-full-of-identical-refused-items scenario depends on this
  ordering for acceptable performance.
- **Two wipe sites (StartRun + MERCHANT_CLOSED) is intentional belt + braces**
  - removing the MERCHANT_CLOSED wipe would carry stale entries across a
  close-and-reopen, and StartRun is gated behind the cycle re-entry
  condition. Both fire on the common path; one is the fallback.

Test 100a-d in `test_perf_guardrails.lua` pins these contracts via
static-pattern checks. The wedge-vs-no-wedge behaviour can only be
verified end-to-end against a real vendor-refused item in-game.

The counter (`WC_batchTotalSold + #queue` in `FinishRun`) still uses
queue-length, not actually-sold count. The inflation is bounded
(at-most-one-per-refused-item-per-cycle) and the cycle terminates - the
unbounded spin is gone. A clean counter fix would need to wait for the
inter-batch `WC_Delay` to settle before counting; doing it synchronously
in `FinishRun` would undercount in-flight successful sales (worse than
slight overcounting for player trust). Tracked as future work.

### Help panel visual style is ported from the sibling BarWarden addon (v2.48.0)

The Help panel renderer + deep-link flash were rewritten in v2.48.0 to match
the visual style of the sibling BarWarden addon
([Options_Help.lua](C:\Users\chris\Wow Addons\barwarden\Options_Help.lua)).
Content, data shape, and public API are unchanged - only the presentation.
Do not "modernise" the color codes or glyphs without checking BarWarden first;
the goal is that the two addons feel like siblings, not that either looks
maximally current.

The specific patterns are pinned by Test 106a-e (test_perf_guardrails.lua):

- **Section headers** are gold `|cffffd870+ Section Name|r` when collapsed
  and `|cffffd870- Section Name|r` when expanded. Hover flips gold ->
  white via a vertex-color override on the FontString; OnLeave restores
  gold RGB (1, 0.845, 0.44). Do NOT change to `[+]` / `[-]` bracket
  glyphs, yellow `|cffffff00`, or any other color.
- **Question text** is light blue `|cff4db8ff`. Answer text keeps the
  default `GameFontHighlightSmall` color (no inline code). If a future
  refactor tries to make the question yellow again (matching the
  in-tooltip `[WC]` yellow), Test 106b catches it - the sibling addon
  parity is intentional.
- **Deep-link flash** is a `BACKGROUND`-layer Texture per entry, tinted
  blue (0.30, 0.56, 1.0, alpha 0.25), driven by `UIFrameFlash(flash,
  0.25, 0.45, 1.4, false, 0, 0.35)`. Do NOT revert to the pre-v2.48.0
  inline-color text swap - it broke when the question color changed
  (the gsub was string-literal-bound) and disturbed the layout for the
  duration of the pulse.
- **Two-pass deferred scroll** at 0.15s + 0.6s. Timings account for WC's
  `FitScrollContent` tick chain (0.1s + 0.5s); BarWarden's raw
  0.05s + 0.20s is too fast because WC's chrome + outer scroll wrap
  layers add settling latency. Both passes gated by
  `HelpPanel._scrollGeneration` so a superseding `[?]` click cancels
  stale passes cleanly.
- **Viewport-width reflow.** `refreshLayout` reads `chrome:GetWidth()`
  each pass and calls `entry.apply(textW)` on every visible entry to
  re-set the q/a FontString widths + recompute the frame height.
  Adopts BarWarden's dynamic reflow pattern instead of the pre-v2.48.0
  `setPanelWidth` registration on the FontStrings (which still works
  but is more machinery than needed inside the chrome).

WC-specific bits preserved (do NOT drop these when porting further BarWarden
touches): the chrome backdrop (`applyChromeBackdrop` + UI-Tooltip-Border
edgeSize=12; Test 75), the search box + client-side filter (v2.46.0), the
per-entry `Open <Panel>` panel-jump buttons + copy-URL rows on the Reporting
Bugs section, and `L[]` localization on every player-facing string. BarWarden
has none of these; the port is style-only.

### Tooltip verdict is introspected via `statusTag`, not the displayed string (v2.43.0)

`WC_AnnotateTooltip` builds the verdict label into `statusLine` and used to
introspect it (`statusLine:find("Will Sell")` and similar) to decide
downstream branches (overrides, precedence, the "Already known" dedupe). Once labels are localized, that string
is French / German on those clients and the English `:find` patterns silently
miss - the sell / keep / delete logic would diverge per language. So every
`statusLine` assignment now also sets an English `statusTag` token
(today: `"willsell"`, `"wontsell"`, `"willdelete"`, `"keep"`, `"override"`,
`"tome_have"`, `"tome_new"`; the affix tags went with that subsystem),
and the branches read the tag. `destinationLabel` returns `(line, tag)`. An
`WC-TRAP` marks the `statusTag` declaration. **Do NOT reintroduce
`statusLine:find(...)` for control flow** - it works on enUS (where `L[k] == k`)
and breaks on every translated client. Locked by the statusTag tests in
`test_perf_guardrails.lua`.

### Removed in the port: the companion gotchas

Nine sections documented the Greedy Scavenger companion: stuck detection
by movement time, the second (loot-silence) stuck signal,
`WC_IsPlayerBusy()` gating `CallCompanion`, leftover-goblin handling in
`WC_TryResummonScavenger`, the `WC_lastScavengerOut` bootstrap,
honouring a manual dismiss, the mount handler's verify-then-act gate,
`SummonGreedyScavenger` / `DismissGreedyScavenger` state sync, the
`muteGreedy` master flag, and the normalized-key bubble mute. All of that
code went with PORT_STATUS work item 2, stage B (a few stale comments
mentioning it remain in `WoWClearance_Events.lua`). The full text is in
git history.

One general rule from that set still applies:

**Caches that mirror server-side state need a bootstrap.** A local that
mirrors external state (group, equipment, spellbook, ...) must be seeded
from the live client when the addon loads or enters the world, guarded so
it runs once, not trusted at its declared default. The default is only
right when the addon loaded before the state could exist, which is false
after a `/reload`.

### Cross-list conflicts are refused at input time, not just resolved post-hoc

`WC_ScanListConflicts` and `WC_ApplyCleanResolution` (driven by `/wc clean`)
sweep up items present on multiple lists with overlapping intent;
precedence is `blacklist > deleteList > whitelist`. They remain, but they
are a safety net for legacy DBs and imports rather than a routine cleanup
tool.

`WC_FindAddConflict` is the upstream guard. It runs at every add site:
the bag-context single-add inside `WC_AddItemToList`, the panel "Add by
ID" button in `CreateListUI`, the `AddMatchingFromBags` substring scan,
and the `ScanBagsForQuality` bulk-by-quality scan. It refuses adds that
would create a cross-intent conflict and prints which list already holds
the item. Same-intent scopes (per-character `whitelist` + account-wide
`accountWhitelist`, both intent "keep") do not conflict and the add
proceeds normally.

If you add another list or another scope, update both `WC_FindAddConflict`
(its `intentOf` map and the `checks` table) and `WC_ScanListConflicts` so
they stay in sync. Skipping the guard means silent post-hoc cleanups will
surprise the user; skipping the cleaner means legacy or imported data has
nowhere to be detected.

### `DB.blacklistAuto` is a source-tag map, not a second blacklist (v2.10.0+)

The auto-protect-equipped feature stores `{ [itemID] = true }` on
`DB.blacklistAuto`. This map is a **diagnostic tag**, not an additive
blacklist. The actual blacklist-veto predicate (`IsInSet(DB.blacklist, ...)`
inside `WC_IsSellable`) only ever reads `DB.blacklist`; `DB.blacklistAuto`
exists exclusively so `WC_AnnotateTooltip` can append the `(auto-protected:
equipped)` suffix when an entry got onto the Keep list via the equipment
handler instead of a manual user add.

The list is the **Blacklist (Keep)** - i.e. `DB.blacklist`, not
`DB.whitelist`. WoWClearance's naming is inverted from the conventional
"whitelist = allow, blacklist = block" sense: in this codebase
`DB.whitelist` is the SELL list ("items to sell on this character") and
`DB.blacklist` is the KEEP / DO-NOT-SELL list ("items the auto-rules
must never touch"). v2.10.0 originally shipped against the wrong list
and was corrected before tag; do not re-introduce that confusion.

**Three invariants any Blacklist remove path must preserve:**

1. Every `DB.blacklist[id] = nil` must be paired with
   `DB.blacklistAuto[id] = nil` (or a `wipe(DB.blacklistAuto)` for bulk
   wipes). Otherwise the tooltip annotation can claim auto-protection
   for an item the user has explicitly removed.
2. Manual adds (panel UI, slash, Alt+Right-Click context menu) MUST NOT
   write to `DB.blacklistAuto`. Only the equipment handler /
   `WC_compCache.protectEquipSlot` /
   `WC_compCache.syncEquipped` paths stamp it.
3. Profile load wipes `DB.blacklistAuto` alongside `DB.blacklist`. A
   profile snapshot doesn't carry the auto flag, so loading a profile
   starts the auto map from scratch. The profile-clear button (which
   only wipes the live whitelist, not the live blacklist) MUST NOT
   touch `blacklistAuto` - the blacklist itself isn't being cleared.

The 200-local cap influenced the implementation: the helpers
`protectEquipSlot` and `syncEquipped` hang off `WC_compCache` (already a
junk-drawer for v2.9.x state) rather than as module-scope `local function`
declarations. Same pattern as `PROF_LOOT_SPELLS`.

**v2.50.2 addition - destruction-time Keep rescue.** The auto-mark scans
(today `runAutoMarkResilience` and `runAutoMarkKnownUnsellableRecipes`;
originally also the removed affix scan) write itemIDs directly
into `DB.deleteList` without routing through `WC_AddItemToList` /
`WC_FindAddConflict`. Any subsequent Keep intent that DOES route through
`WC_AddItemToList` (equipment-set stamp via `protectEquipmentSetItem`,
manual Add-to-Keep via the context menu, `syncEquipped` sweep) is refused
by the cross-intent conflict guard with `quiet=true`, so the user never
sees a warning that their Keep add didn't take. To rescue those items
without untangling the quiet-mode conflict-guard behaviour,
`Decision.deleteEligible` (reached through `deleteListSlotEligible`)
consults the Keep List, the account Sell List and the equipped check -
any Keep signal that arrived after the auto-mark write vetoes destruction
at the last moment. This matches the `blacklist >
deleteList` precedence already documented for `/wc clean`.

The scan side also grew a **session-scoped `WC_compCache.equipmentSetIDs`
cache** (populated inside `syncEquipmentSets`, rebuilt on
`EQUIPMENT_SETS_CHANGED` regardless of the `autoProtectEquipmentSets`
toggle) that the auto-mark gate (`itemProtectedFromAutoMarkDelete`)
consults so items in any saved equipment set are never auto-marked in
the first place. Since the port the cache is built from
`C_EquipmentSet.GetEquipmentSetIDs()` (zero-based IDs) and
`C_EquipmentSet.GetItemIDs(setID)` (sparse, slot-keyed - iterate with
`pairs`, see the `WC-TRAP:` there). Cache rebuild
runs unconditionally even when the toggle is off because the scan-side
rescue must honour set membership as user intent independent of whether
the automatic Keep-List stamping is opt-in.

**WC-TRAP:** the `deleteListSlotEligible` header comment used to declare
"the Delete List is explicit user intent". That claim is retired in
v2.50.2 - the auto-mark scans DO NOT go through `WC_FindAddConflict`, so
Delete List entries are NOT pure user intent. Do not collapse the
Keep-signal + equipped vetoes into one another, and do not restore the
"explicit user intent" comment - shirt-loss regressions will follow.

### BAG_UPDATE handler must coalesce bursts (v2.24.0+)

AOE looting N items fires N BAG_UPDATE events in <100 ms (on 3.3.5a
the Greedy Scavenger made this constant). Any work in the BAG_UPDATE
branch that walks every bag (backpack, bags 1-4 and, since v0.6.0, the
reagent bag: loops run `for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS`) or
scans tooltip text per item compounds:
N events × bag walk = lag spike. v2.22.0 and v2.23.0 each added new
work to the BAG_UPDATE branch without coalescing; the combined cost
hit 1.5 s freezes during AOE farming.

The rule: **BAG_UPDATE must route deferred work through
`WC_compCache.bagUpdateFrame`** (a single shared OnUpdate frame that
waits 120 ms for the burst to settle, then fires the heavy chain
once). Direct calls to `rearmProcessButton`, `checkBagsForUpgrades`,
`HandleAutoOpenContainers`, or `refreshProcessPanel` from inside
the BAG_UPDATE branch are caught by
[tests/test_perf_guardrails.lua](../tests/test_perf_guardrails.lua).

There is no longer any synchronous exception: the bag-full trigger
(`WC_HandleBagFullForCycle`) went with the loot-cycle engine, though one
stale comment above the debounce frame still names it.

Two adjacent rules in the same vein:

1. **Heavy per-bag-walk helpers should be gated on whether the user
   is actively using the feature.** `rearmProcessButton` early-returns
   when `panel:IsShown() == false` AND `GetBindingKey(...)` returns
   nil. Users who never open Process Bags pay zero cost. The hold-
   key-to-drain workflow still works because the keybind check keeps
   the rearm running when a binding exists.

2. **Never cache a per-copy fact by `itemID`.** Two copies of one
   itemID can differ (bound state, item level, refund / trade window).
   Read those per slot (see "Bind state is read per copy"); itemID
   caches are only for facts fixed per item.

### The flush chain shares ONE bag snapshot (v2.59.0+)

Coalescing (above) bounded how often the flush fires; v2.59.0 bounds
what each flush costs. Scanners share ONE bag snapshot per flush
(per-slot entries + an `{itemID = count}` map) instead of walking bags
independently. v2.63.0 made the build LAZY: each scanner calls
`WC_compCache.acquireFlushSnapshot()`, which builds and caches the
snapshot on first use in the frame - with every entries-consumer
toggled off (the default config) no snapshot is built at all, and the
loot delta falls back to its cheap flat count walk via
`currentFlushSnapshot()` (read-only). Locked by Test 119. The
load-bearing details:

- **Validity is the frame it was built in** (`snap.at == GetTime()`;
  GetTime is frame-constant). An error mid-flush can therefore never
  leak a stale snapshot into a later frame; standalone callers just
  build a fresh one.
- **Scanners later in the chain re-verify the live
  slot** (`C_Container.GetContainerItemID(e.bag, e.slot) == id`) before
  tooltip work or destructive action - a slot can empty or change
  mid-chain, and the itemID-keyed caches
  (resilience / tome / bind type) must not be poisoned by scanning an
  emptied slot.
- **Snapshot quality is a pre-gate, never a verdict.** It comes from
  the `C_Container.GetContainerItemInfo` table's `quality` field and can
  be nil for uncached items (and was -1 on 3.3.5a);
  consumers may SKIP on a known-out-of-range quality but must fall
  through to the authoritative `GetItemInfo` check when unknown.
- **`WC_IsOpenable` caches per itemID** ("openable" / "never") but a
  LOCKED tooltip result stays uncached (a lockpicked junkbox flips to
  openable under the same itemID) and "never" is only cached from a
  tooltip that actually rendered lines (client cache warmup renders
  empty tooltips).
- Do not add a new bag-walking scanner to the flush; give it the
  snapshot and, if it acts destructively or scans tooltips, the live
  re-verify.

### Bind / proc / Resilience share ONE combined scan (v2.10.0+, reshaped v2.69.0)

Superseded by the port. On 3.3.5a, `WC_compCache.scanItemMarkers`
(Protection.lua) filled the bind, chance-on-hit and Resilience caches
from one hidden-tooltip walk. Today:

- **Bind state no longer uses a tooltip scan** for bag items: see "Bind
  state is read per copy" under "Forever port patterns" (`isBound` per
  copy, `bindCache` = item bind type only).
- **Chance-on-hit detection is gone** with the Project Ebonhold
  subsystem, and so is `chanceOnHitCache`.
- **`scanItemMarkers` now fills only `resilienceCache`**, from one walk of
  the scan tooltip, and caches nothing from a tooltip that has not
  rendered any lines (the v2.68.1 cold-cache discipline). The Resilience
  substring is still an English text match.
- Tome detection stays a separate walk (class fast-paths +
  collectible-reject semantics).

What has not changed: items with no bind type at all (consumables,
reagents, trade goods, quest items) return `"any"`, and `"any"` is
matched by neither `"boe"` nor `"bop"` filters - so a `BoE only` rule on
Blue does NOT sweep up reagents that happen to be blue quality. That is
the reason the filter check is INSIDE the `qualityPass` branch, not
outside it.

### Sell Known Recipes logic is mirrored in FOUR places (v2.46.0)

The "sell recipes you already know" rule is a positive sell signal
(`recipePass`) for a profession recipe (`tomeKind == "Recipe"`) the
character has learned (`playerKnowsTomeSpell`), gated per rarity via
`DB.sellKnownRecipeQualities`. Crucially it **overrides the tome-protection
veto** for learned recipes - including `protectAllTomes` ("keep them even
after you learn them"). Non-recipe tomes and unlearned recipes are
untouched.

That override has to be applied in **four** code paths. Since the
v2.71.x classifier stages the trace and the tooltip take their VERDICT
from `Decision.sell` (and a sentinel flags disagreement), but their
step narration and labels are still hand-written per branch, and the
context menu still computes its own `recipeSellable`. If you change the
rule, change all four or the explanations drift:

1. The decision core (`Decision.sell` in WoWClearance_Decision.lua;
   `WC_IsSellable` in Events delegates to it since v2.71.0) - computes
   `recipePass`; the tome-veto gate carries `and not recipePass` to
   carve out learned recipes.
2. `describeSellability` (WoWClearance_BagDisplay.lua) - the `/wc sellinfo`
   trace; emits the `knownRecipeRule` step and excludes `recipePass` items
   from the `tomeProtection` veto step.
3. `WC_AnnotateTooltip` (WoWClearance_Tooltip.lua) - computes
   `recipeSellable` BEFORE the tome block, skips the tome block for it, and
   overrides a quality-rule "keep" verdict (but never the real Keep/Delete
   list) with `statusTag = "willsell"`.
4. `WC_ShowItemContextMenu` (WoWClearance_BagContextMenu.lua) - computes
   `recipeSellable` so a sellable learned recipe shows the normal
   Sell/Keep/Delete rows instead of the protected-item "Allow Sell" gate.

The toggle (`DB.sellKnownRecipes`) is account-wide like the sibling
`protect*Tomes` toggles, but the learn-state is read per-character from the
live tooltip at decision time, so the same account setting yields different
results per alt.

### Sell List releases the tome veto (v2.51.2)

Pre-v2.51.2 the tome-protection HARD veto in `WC_IsSellable` fired on
`(qualityPass or whitelistPass)`, which made adding a tome to the Sell List
insufficient to override it - a two-key gate (Sell List + Allow Sell) was
needed. This was inconsistent with the v2.20.1 chance-on-hit narrowing
(chance-on-hit veto explicitly exempts `whitelistPass`) and with the affix
protection (also exempts `whitelistPass`). Reported by Serv against
`Pattern: Mooncloth Leggings` (a learned pattern on Sell List refused to
sell with `protectAllTomes` on).

The v2.51.2 fix narrows all three parity sites to gate on `qualityPass` only:

- The decision core (`Decision.sell` in `WoWClearance_Decision.lua`
  since v2.71.0; originally `WC_IsSellable`) - drops `or whitelistPass`.
- `describeSellability` (`WoWClearance_BagDisplay.lua`) - matching narrowing
  in the `tomeProtection` step so `/wc sellinfo` and the vendor agree.
- `WC_AnnotateTooltip` (`WoWClearance_Tooltip.lua` ~886) - adds an
  `onSellList` guard so the Sell List's `Will Sell` label at line 175
  isn't overwritten by the tome-veto label at line 911.

Adding to Sell List is now sufficient explicit intent to release the veto.
Allow Sell (`ADB.allowedItems[itemID]`) stays as a per-item override. The
auto-rule quality sweep is still gated so a tome that falls into a
per-quality rule range without user intent stays protected.

WC-TRAP: these three parity sites MUST stay in lockstep. Any change to one
must be mirrored to the other two or the trace / tooltip disagrees with
the vendor decision.

### Known vs Needed affix highlight (v2.52.0)

**Removed in the port.** The `affix` / `affixneeded` sell-border
categories, the matching tooltip tags and trace steps, and the rank VI
extension were Project Ebonhold affix features (PORT_STATUS work item 2).

### Loot Log capture is a bag-delta, not loot events (v2.46.0)

The Loot Log counts YOUR items by **net bag increase**, scanned from the
BAG_UPDATE debounce flush (`WC_ScanLootDelta`, the last step in
`WC_compCache.bagUpdateFrame`'s OnUpdate). Own loot is NOT driven by
`CHAT_MSG_LOOT`: on 3.3.5a the Greedy Scavenger dropped its haul into
bags without a "you receive loot" line, and the delta scan catches every
source uniformly. Since v0.6.0 `CHAT_MSG_LOOT` IS registered, but only to
record OTHER group members' loot into Loot Log History; lines about the
player are skipped so nothing is counted twice.

Guards that keep the delta honest (do not remove):

- **First scan only baselines** (existing bag contents are not "loot").
- **Skips while a transaction window is open** (`MerchantFrame`,
  `BankFrame`, `MailFrame`, `TradeFrame`, `AuctionFrame`, `TradeSkillFrame`,
  etc.) so vendor buys / bank or mail withdrawals / crafting output are not
  counted - it re-baselines instead.
- **Skips while the cursor holds an item** (`CursorHasItem`) so a bag
  reorganise (pick up, drop back) does not credit a phantom +1.
- *(Removed in the port: the "skips items destined for auto-delete" rule. Auto-delete on pickup no longer exists and `DB.autoDeleteOnPickup` is cleared in `EnsureDB`, so a Delete-Listed item in your bags is counted as loot like any other.)*

The three aggregate views store per-itemID counts (never an event log), in three
places: in-memory `WC_lootSession` (Session view), per-character
`DB.lootedItemCounts` (Character view, in `PER_CHAR_FIELDS`), and
account-wide `ADB.accountStats.lootedItemCounts` (Account view). `WC_BumpLoot`
writes all three; `WC_ClearLoot(scope)` wipes one in place. `WC_BumpLoot` also appends
each pickup to the fourth view, Loot Log History (a persisted event ring;
see "Persisted ring logs"). The window
(`WoWClearanceLootWindow`, built lazily in WoWClearance_StatsPanel.lua) is
a fixed/ resizable floating frame, so it is outside the reactive-width
contract that governs Interface Options sub-panels.

Two display-layer features sit on top of the stored counts (v2.46.x), both
in `lootBuildArray` / `lootRefresh`, neither adding a stored value:

- **Gold value + share.** Each row shows `qty * sell price` (the 11th
  `GetItemInfo` return) and that value's share of the total looted gold.
  Value is derived at render time, not stored, so a price the client hasn't
  cached yet reads as 0 until it loads; since v0.6.0 the window asks for
  missing data with `C_Item.RequestLoadItemDataByID`, bounded per pass. The "Gold" sort orders by
  this value (distinct from the "Count" sort by quantity).
- **Per-item hide.** Right-clicking a row adds its itemID to the account-wide
  `ADB.lootLogHidden` set; hidden items are skipped in `lootBuildArray`
  BEFORE the totals accumulate, so the remaining rows' count/gold shares
  rebase (this differs from the rarity filter, which hides rows but keeps
  them in the totals). The "Unhide All" button wipes the set. Seeded by
  `EnsureAccountDB` as `{}`.

### PE affix detection uses three sources, not one (v2.23.0+)

**Removed in the port.** The item-title rank suffix, the `@affix@`
tooltip markers, the spellbook "engrave this affix" walk and
`_G.ExtractionService.learnedAffixes` were all Project Ebonhold data
sources, and the detection code (`parseAffixFromTitle`,
`refreshKnownAffixes`, `scanTooltipForAffixDesc`, `/wc scandebug`'s affix
sections, `/wc affixdump` / `affixfind` / `procdump`) went with the
subsystem (PORT_STATUS work item 2, stages C-F). Full text in git history.

### Allow Sell override (v2.26.0 / v2.27.0)

Allow Sell is a per-item, account-wide manual release:
`ADB.allowedItems[itemID] = true`. The two affix-era tables
(`ADB.allowedAffixes`, `ADB.affixedListedItems`) were removed with the
Project Ebonhold subsystem; `EnsureAccountDB` still migrates the old
`allowedProcs` name into `allowedItems`.

In the decision core, `ctx.allowedItem` releases the tome-protection veto
and the two Forever protections (appearance, tradeable). It does not
override the Keep List or the equipped check.

The Alt+Right-Click menu (`WC_ShowItemContextMenu`,
`WoWClearance_BagContextMenu.lua`) offers `Allow Sell` only when the item
is tome-protected (`hasProtection = hasTome`). While protected and not
allowed, the Sell / Delete list rows are hidden, so the player must
consciously pick `Allow Sell` first; the Keep List row is always offered
(v2.57.2). Once allowed, the full menu opens up and the row becomes
`Remove from Allow List`. Both clicks must call the sell-border refresh
(see "List-mutation must call `WC_RefreshSellBorders`").

### Chance-on-hit lookup priority (v2.49.0 / v2.49.1)

**Removed in the port.** `playerHasExtractedProc`, the
`WC_CHANCE_PROC_NEVER_EXTRACTABLE` / `WC_CHANCE_PROC_CONFIRMED_ITEMS`
tables and the `ADB.chanceProcConfirmedItems` autolearn tier depended on
the Project Ebonhold Anvil. Note from PORT_STATUS work item 2: whether
Forever should get a plain "never auto-sell a weapon with a chance-on-hit
proc" protection is an open product question, not a port task.

### Index of magic numbers

| Value | Location | Meaning |
|---|---|---|
| 0.05s | vendor worker OnUpdate | Per-item pacing floor. Below this, the original server booted you for packet spam. |
| 80 items | `maxItemsPerRun` default | Sell-queue cap per run. Same disconnect concern as the vendor-interval floor. Recursive batching kicks in for larger inventories. |
| 0.12s | `WC_compCache.BAG_UPDATE_DEBOUNCE_S` | Idle window before the BAG_UPDATE burst flush runs. |
| 80 | `WC_AUTOMARK_PROTECT_ILVL` | Item level at or above which the auto-mark scans never mark an item. Client-relative (`WC-TRAP:`): a value above the game's maximum item level silently disables the protection. The panel label formats this number rather than hardcoding it. |
| 5000 / 5000 | `WC_RECENT_SOLD_LOG_MAX` / `WC_RECENT_DELETED_LOG_MAX` | Sold History ring sizes, per character, persisted. |
| 20000 | `LootHistory.MAX` | Loot Log History ring size, account-wide, persisted. |
| 500 | `HIST_DISPLAY_MAX` | Rows the Sold History window renders. |
| 20 | `WC_BUGREPORT_RECENT_MAX` | Newest sold / deleted entries in `/wc bugreport`. |
| 20 / 10 | `WC_SPIKE_LOG_MAX` / `NS.worstSpikeLogMax` | Frame-spike rings (recent FIFO / worst by severity). |

The companion timers (`WC_PET_CHECK_INTERVAL`, the stuck thresholds, the
Goblin Merchant summon / target / reminder timers, the mount cooldown and
`GOBLIN_MERCHANT_SPELL_ID`) were removed with the companions.

If you change any of these, update this table and the nearest comment.

### Bag display: sell-border tint (v2.29.0+)

The opt-in slot-border tint draws an additive ring around bag slot frames whose items the rule chain would sell. Three invariants every contributor touching this code must preserve:

1. **Every button that goes through `WC_compCache.applySellBorder` MUST be added to `WC_compCache.sellBorderButtons`**, regardless of the current `willSell` verdict. The registry is the lookup the settings-flip refresh uses; if a button never enters it (e.g. because its first paint was `won't sell`), the refresh can't find it later when the verdict flips. Before v2.29.0 only buttons that received a texture entered the registry; the fix was to track unconditionally. Don't gate the registry insert on `willSell` again.

2. **The host bag-UI adapter MUST install at `ADDON_LOADED` for the host addon, not at `PLAYER_LOGIN` plus a delay.** The host builds its slot class during its own load pass; by the time `PLAYER_LOGIN` plus a 2-second delay fires, the host may already have painted its first set of slots without our hook in place, and those slots stay un-decorated until something else triggers an update. Installing at the host's `ADDON_LOADED` puts our hook in BEFORE the host can build any bag-display frames. The `PLAYER_LOGIN`-deferred install path is kept as an idempotent fallback only.

3. **The ring texture sits on `OVERLAY` sublevel 6 with `BlendMode("ADD")`.** This is deliberately above the host bag-UI's own quality border (sublevel 0) so the two compose additively - a Blue/Rare quality border + an WC sell-border tint read as both colours layered, not one fighting the other. Don't drop the sublevel or change the blend mode without considering how the composition will read.

Anything that mutates the verdict of a bag slot - list adds/removes, allow-list mutations, settings pack imports, colour picks, the master toggle - MUST call `WC_RefreshSellBorders()` after the mutation. The helper is a no-op when the toggle is off, so calling it from a mutation site that isn't gated on the toggle is cheap and correct.

### Affix description normalisation: case-folds (v2.29.0+)

**Removed in the port.** `WC_compCache.normaliseAffixDesc` and the
`ADB.allowedAffixes` key migration it was paired with went with the
Project Ebonhold affix subsystem.

### List-mutation must call `WC_RefreshSellBorders`

Every site that writes to `DB.whitelist`, `DB.blacklist`, `DB.deleteList`,
`ADB.whitelist`, or `ADB.allowedItems` MUST follow the write with the
sell-border refresh. Today that is `NS.RefreshSellBorders()` (body in
`WoWClearance_BagDisplay.lua`; `WoWClearance_Events.lua` installs a no-op
stub early so a call is safe at any load point, and the Vendor file still
names it `WC_RefreshSellBorders` in comments). The helper is a no-op when
the tint toggle is off, so calling it from an ungated site is cheap and
correct.

Current sites that do this correctly:
- `WC_AddItemToList` and `WC_RemoveItemFromList` (Sell / Keep / Delete / Account Sell)
- The Alt+Right-Click `Allow Sell` / `Remove from Allow List` click handlers
- The Item Highlighting slot-border colour picker (commit callback)
- The `importFullPack` deserialiser

If you add a new mutation site without calling the refresh helper, the
slot-border ring goes stale until the user closes and reopens their bags.
`tests/test_perf_guardrails.lua` pins the known sites (it cites this
section as "List-mutation must call the sell-border refresh").

### No third-party addon references in new WC artefacts (v2.29.0+)

WC's shipped artefacts MUST NOT name, mention, or compare against any other addon in NEW code or docs. This includes code comments, commit messages, `CHANGELOG.md`, `README.md`, this file, slash command help text, the `/wc bugreport` output, settings-panel labels, and tooltip annotations.

Allowed alternatives when integration code genuinely needs to be discussed:
- "Host bag UI integration" / "third-party bag UI adapter"
- "Cross-character inventory data source (when available)"
- "Optional external data backend"
- "Detected at runtime via the `_G` lookup; ungated when absent"

The runtime detection still calls the specific global (`_G.Bagnon`, `LibStub("AceAddon-3.0"):GetAddon("AdiBags")`, etc.) - that's necessary for the API to work - but the comment explaining what's happening uses neutral framing.

**One deliberate exception: DaylightUI (owner's decision, 2026-11-14).** It may be named in `WoWClearance_Daylight.lua`, the "Use DaylightUI look" toggle and its tooltip, the bag adapter's detection, and the docs that describe them. Do not neutralise those in a cleanup.

**Existing mentions stay.** Pre-v2.29.0 comments (now in `WoWClearance_Events.lua` and the split files) and entries in `NOTICE.md` / EbonClearance's `CHANGELOG.md` remain untouched. The rule is forward-only.

Rationale: WC reads as a self-contained piece of engineering, not a synthesis or a port. Comments explain WHY a piece of code exists and HOW it works, never "where the idea came from". Borrowing another addon's terminology in WC comments dilutes that voice and signals derivation where the implementations are WC-native.

## Fingerprint and watermark

WoWClearance carries a deliberate, visible fingerprint mechanism so
verbatim copies of the source or the export-string format can be
mechanically detected. Three pieces:

1. **The salt string** - the `SALT` local inside `WC_Fingerprint` in
   `WoWClearance_Core.lua` (it lives inside the function body only so it
   does not spend a main-chunk local slot; it was the module-level
   `WC_FINGERPRINT_SALT` before the split). A project-specific string.
   **Do not** "clean up", refactor, rename, or shorten it; its presence
   in code is the point. Any addon source containing this exact string
   is a verbatim copy.
2. **`WC_Fingerprint(payload)`** helper (exposed as `NS.Fingerprint`).
   djb2-style 24-bit hash folded into 6 hex chars, salted with the
   string above. Used for both the watermark and export strings.
3. **`__WoWClearance_watermark`** global. Set in `WoWClearance_Events.lua`
   (next to `ADDON_VERSION`, read from the .toc with `GetAddOnMetadata`) to
   `WC_Fingerprint("WoWClearance@" .. ADDON_VERSION)`. Visible to
   `/run` and to external auditors. The hex value is reproducible:
   for any version, run the salted hash on
   `"WoWClearance@" .. version` and confirm.

Export strings carry a `;fp=<6 hex>` suffix produced by
`WC_Fingerprint` over the export payload. Imports tolerate strings
with or without the suffix (back-compat with hand-edited and
pre-fingerprint exports); imports do **not** verify the fingerprint
or warn on a bad one. The fingerprint exists to mark our exports
**going out**, not to police imports coming in.

Convention for future agents and contributors:

- Do not normalise, refactor, rename, or remove the salt constant
  or the helper. They are intentional artefacts.
- Do not add a fingerprint-verification step on import. This is a
  considered design choice (see the `;fp=` strip in the two import paths
  in `WoWClearance_ProfilesPanel.lua` and the comment above it).
- If we ever need a per-export-type fingerprint (profiles, settings,
  etc.), reuse `WC_Fingerprint` rather than introducing a second
  hash function. One salt, one helper, one mechanism.
- Section 2(d) of the LICENSE lists `__WoWClearance_watermark`
  alongside the other provenance globals as required-to-preserve in
  derivatives. Adding a new provenance global means updating
  LICENSE 2(d) and `NOTICE.md`.

The convergent prior-art story for the broader provenance pattern
(`__<addon>_origin` / `__<addon>_author`) is documented in
[`NOTICE.md`](../NOTICE.md). Read that before assuming we invented
either pattern.

## File split - in progress

> **Historical record: the split is complete.** Stages 1-9 shipped before
> the port; the heading is unchanged so older references still resolve.
> Some stages describe files that no longer exist
> (`WoWClearance_Companion.lua`, `WoWClearance_ScavengerPanel.lua`,
> `WoWClearance_ProcShare.lua`), and `WoWClearance_Window.lua` and
> `WoWClearance_LootHistory.lua` were added after it. "File layout" above
> is the current map. The per-stage notes are kept because the
> `tests/test_perf_guardrails.lua` invariants they describe (Test 28,
> Test 55, ...) still run.

The single-file layout was kept until the 200-locals cap started forcing
helpers onto `WC_compCache` for the wrong reasons (the table existed to
work around the cap; it accreted into the de-facto module namespace).
Triggers that finally crossed the line:

- File grew past 11,800 LOC (the documented 8K threshold below was
  conservative and was rebuilt mid-flight to the 12K mark before the
  split started).
- The 200-locals cap was hit during v2.29.0 release work twice in a
  single feature - any further module-level local additions now require
  an `WC_compCache` placement or another existing slot to be freed.
- `WC_compCache` had grown to 50+ entries, many of them helpers that
  belong as their own file's locals, not table fields.

The split is a multi-stage internal refactor. Stages are commit-only;
they do NOT bump `ADDON_VERSION` or get their own version tags, because
they ship no user-facing behaviour change. `ADDON_VERSION` stays frozen
at whatever the last feature release was (currently v2.29.0) for the
duration of the split. See docs/CODE_REVIEW.md item 4 for the staged
schedule. Don't mix feature work into a split stage.

### Stage 1: namespace bootstrap (commit `8201442`)

Stage 1 is purely additive. It introduces the shared namespace table
WoW addons use for cross-file state without moving any code:

```lua
local NS = select(2, ...)
```

`select(2, ...)` is used instead of `local addonName, NS = ...` because
the main chunk is at the 200-locals cap; capturing only the second
vararg spends one slot instead of two. WoW passes
`(addonName, namespaceTable)` as the file-load varargs to every `.lua`
file in an addon; the same table is shared across files.

The first thing the bootstrap does is mirror the existing
`WC_compCache` table onto `NS.compCache`. Both names alias the same
memory. Existing call sites continue to use the `WC_compCache` upvalue;
future split files will reach the table via `NS.compCache` without any
churn at existing call sites.

Stage 1 invariants (enforced by `tests/test_perf_guardrails.lua` Test 28):

- The `local NS = select(2, ...)` bootstrap line is present at the top
  of every shipped source file (count >= number of files in the test's
  `SOURCE_PATHS` list).
- `NS.compCache = WC_compCache` appears immediately after the
  `WC_compCache` table literal closes.
- `WC_compCache` has exactly ONE table-literal declaration AND exactly
  ONE re-alias declaration across all shipped sources - shadowing
  literals would silently desync NS.compCache, and a missing re-alias
  would leave WoWClearance.lua's `WC_compCache.foo` references
  resolving to global nil.

### Stage 2: extract WoWClearance_Core.lua (commit `119eca8`)

Stage 2 moves the smallest set of chunks that have no dependencies on
the rest of the file:

- The provenance globals block (`WOWCLEARANCE_*` and `__WoWClearance_*`
  `_G` writes) and the `ADDON_AUTHOR` / `ADDON_URL` locals that back them.
  Both are also exposed on the namespace as `NS.ADDON_AUTHOR` /
  `NS.ADDON_URL` so the settings byline (still in WoWClearance.lua)
  re-aliases them.
- The `WC_Fingerprint` helper, exposed as `NS.Fingerprint`. The two
  export call sites in WoWClearance.lua now call `NS.Fingerprint(payload)`
  directly (no re-alias - cold-path, only fires when the user clicks
  Export, so the table-index lookup is free).
- The `WC_compCache` table literal. Exposed as `NS.compCache`.
  WoWClearance.lua keeps a file-scope `local WC_compCache = NS.compCache`
  re-alias so the ~50+ `WC_compCache.foo` call sites resolve to the
  same table via upvalue.

Things that did NOT move in Stage 2 (deliberate):

- `ADDON_VERSION` - the CI release workflow's `sed` rule targets the
  `local ADDON_VERSION = "..."` line by file path. Moving it would
  require a `.github/workflows` change; deferred to a later split stage.
- `WC_GetVersion` and the watermark `_G` write - both depend on
  `ADDON_VERSION`, so they stay where `ADDON_VERSION` is.
- API cached upvalues, `STATE`, forward declarations, `EnsureDB`,
  `WC_Delay`, session stats - planned for a later stage. Moving them
  requires either re-aliasing on the WoWClearance.lua side (one local
  slot each) or rewriting call sites (large diff). Pacing matters more
  than blast radius here.

Slot accounting on WoWClearance.lua's main chunk:

- Removed: `ADDON_DISPLAY` (already done in Stage 1), `WC_Fingerprint`,
  `ADDON_AUTHOR` was inline but is now a re-alias from `NS.ADDON_AUTHOR`
  (still one slot), `ADDON_URL` likewise.
- Net slot delta: -1 (the `WC_Fingerprint` function definition).

Stage 2 invariants (enforced by `tests/test_perf_guardrails.lua` Test 28):

- Concatenated source contains AT LEAST one `local NS = select(2, ...)`
  per file listed in `SOURCE_PATHS`.
- Exactly one `local WC_compCache = { ... }` (the table literal, now
  in Core).
- At least one `local WC_compCache = NS.compCache` re-alias per
  consumer file (WoWClearance.lua post-Stage-2; WoWClearance_Companion.lua
  post-Stage-3; more files in later stages).
- `NS.compCache = WC_compCache` appears exactly once (still in Core,
  immediately after the table literal).

### Stage 3: extract WoWClearance_Companion.lua (commit `987b5b5`)

Stage 3 moves the contiguous chat-filter / speech-bubble killer cluster
out of WoWClearance.lua (previously lines ~164-446):

- `WC_StripCodes`, `WC_IsGreedyAuthor`, `WC_TrackGreedySpeech` (helpers
  internal to the chat filter).
- `WC_greedyMessages` table + `WC_greedyFiltersInstalled` boolean
  (Companion-only session state).
- `WC_GreedyEventFilter` (per-chat-event mute + Scavenger-speech tracker).
- `WC_InstallGreedyMuteOnce` (one-shot install on 10 chat events).
  Exposed as `NS.InstallGreedyMuteOnce`.
- `WC_bubbleFrame` OnUpdate (200 ms WorldFrame walker + 8 s TTL speech
  window + weak-table kill set).
- `CHAT_FILTER_EVENTS`, `GreedyScavengerChatFilter`, `ApplyGreedyChatFilter`
  (secondary chat-filter system). `ApplyGreedyChatFilter` exposed as
  `NS.ApplyGreedyChatFilter`.

Cross-file plumbing added in this stage:

- `WC_lastScavSpokeAt` was a file-scope local read by both the chat
  filter (now in Companion) and `WC_IsLootSilenceStuck` (still in
  WoWClearance.lua). **Promoted to `WC_compCache.lastScavSpokeAt`**
  so both files reach it via the shared cache table. Initial value
  declared next to `scavSpeechEverHeard` in Core.
- `EnsureAccountDB` now writes `NS.ADB = ADB` and `EnsureDB` writes
  `NS.DB = DB` so Companion's chat filter can read the live binding
  inline (`local DB = NS.DB` at function entry).
- The PET_NAME_LC / PET_NAME / TARGET_NAME refresh sites (initial
  init in WoWClearance.lua, EnsureDB body, and `WC_compCache.refreshNames`)
  all mirror onto `NS.PET_NAME_LC` etc. Companion's `WC_IsGreedyAuthor`
  reads `NS.PET_NAME_LC` inline so localised / renamed pets work.

Four call sites in WoWClearance.lua were updated:

- `ApplyGreedyChatFilter()` -> `NS.ApplyGreedyChatFilter()` (settings
  toggle in the chat-mute checkbox; ADDON_LOADED branch).
- `WC_InstallGreedyMuteOnce()` -> `NS.InstallGreedyMuteOnce()`
  (PLAYER_LOGIN branch; MERCHANT_SHOW branch).

Stage 3 invariants (enforced by `tests/test_perf_guardrails.lua` Test 29):

- `NS.InstallGreedyMuteOnce` and `NS.ApplyGreedyChatFilter` are both
  published by Companion at file-load time.
- No bare `WC_InstallGreedyMuteOnce()` or `ApplyGreedyChatFilter()`
  call sites exist (definition lines in Companion are masked from
  the scan).
- `EnsureDB` writes `NS.DB = DB`.
- Every site that rebinds `PET_NAME_LC` mirrors onto `NS.PET_NAME_LC`.

### Stage 4: extract WoWClearance_Protection.lua (commit `9d65e64`)

Stage 4 moves the PE-protection detection cluster previously in
WoWClearance.lua at lines ~1817-2477:

- **PE random-affix detection** - `linkHasAffix`, `romanToInt`,
  `parseAffixFromTitle`, `scanTooltipForAffixDesc`, `normaliseAffixDesc`,
  `bagSlotAffixData`, `bagSlotHasAffix`, `liveTooltipAffixData`,
  `liveTooltipHasAffix`. The `ROMAN_VALUES` lookup table and the
  `affixDataCache` (per-itemString) live here too.
- **PE engraving / affix-catalog integration** - `knownAffixDescriptions`
  table, `peDetected`, `refreshKnownAffixes`, `refreshExtractionIfDirty`,
  `playerHasAffixDescription`. The `AFFIX_SPELL_PREFIX` literal, the
  `knownExtractionVersion` dirty counter, and the `procIdToDescription`
  cache also live here.
- **PE chance-on-hit detection** - `lineLooksLikeChanceProc`,
  `itemHasChanceOnHit`, `liveTooltipHasChanceOnHit`.
- **PE Anvil bridge** - `findLearnedAffixForItem` plus
  `itemAffixLookupCache` (per-itemLink).

Every helper is attached to `WC_compCache` (Core's table, exposed as
`NS.compCache`). Call sites elsewhere in the addon already resolve
through the shared `WC_compCache` upvalue, so this move required NO
call-site changes anywhere in WoWClearance.lua.

Cross-file plumbing added in this stage:

- `NS.scanTooltip` is written by WoWClearance.lua immediately after
  the `WC_scanTooltip` frame is created. Protection's helper bodies
  dereference `NS.scanTooltip` lazily inside the function body via a
  `scanTip()` accessor (Protection loads BEFORE WoWClearance.lua's
  main chunk, so an upvalue capture at Protection's load time would
  store `nil`; by the time any of these helpers is first CALLED,
  WoWClearance.lua has finished its main chunk).
- The named `GameTooltip` frame stays in WoWClearance.lua because it
  has non-protection callers (auto-open container detection, bug-report
  builder, Process Bags mode detection, bind-type cache).

Stage 4 invariants (enforced by `tests/test_perf_guardrails.lua` Test 30):

- 17 protection helpers stay attached to `WC_compCache` and are not
  shadowed by a module-level `local function NAME(...)` definition.
- `WoWClearance.lua` writes `NS.scanTooltip = WC_scanTooltip`
  immediately after creating the frame.

### Stage 5: extract WoWClearance_Vendor.lua (commit `08c3893`)

Stage 5 is deliberately scoped narrowly. The full vendor cycle
(`WC_IsSellable`, `BuildQueue`, `DoNextAction`, `worker`, `StartRun`,
`WC_manualSell`, `WC_PreviewSellable`) is interleaved with bag-display
helpers (Stage 6 target) AND has wide cross-file dependencies on
WoWClearance.lua-side helpers (`PrintNice`, `WC_Delay`, `WC_session`,
`WC_lootCycleState`, `STATE`, `WC_GetItemPrice`, ...). Moving the whole
thing in one stage requires either a large NS-exposure blast or
function-entry capture boilerplate at every entry point.

Instead, Stage 5 establishes the Vendor file with the smallest
self-contained subsystem and leaves the rest for future stages.

What moved in this stage:

- **`HookDeletePopupOnce`** (the StaticPopup1 DELETE_* auto-confirm
  driver) + its install-once gate `deletePopupHooked`. Exposed as
  `NS.HookDeletePopupOnce`.

What was promoted (Stage 5 prep, both inside this same diff):

- **`running`** -> `WC_compCache.vendorRunning` (vendor cycle gate).
  Cross-cutting readers in 5+ non-vendor handlers in WoWClearance.lua
  all read the new cache field; future Vendor-extraction stages can
  write to the same field from their new home.
- **`pendingDelete`** -> `WC_compCache.pendingDelete` (deletion-popup
  state). Written by `HookDeletePopupOnce` (now in Vendor) AND by
  `DoNextAction` (still in WoWClearance.lua); cleared at
  MERCHANT_CLOSED (event hub in WoWClearance.lua). Cache promotion
  was needed because the writers + clearer ended up in different files.

What did NOT move (future stage targets):

- `WC_IsSellable`, `BuildQueue`, `FinishRun`, `DoNextAction`, `worker`,
  `WC_IsMerchantAllowed`, `WC_PreviewSellable`, `StartRun`,
  `WC_compCache.isQuestItem` (the merchant cycle itself).
- `WC_manualSell` table + methods (manual-sell attribution via
  `hooksecurefunc("UseContainerItem", ...)`).
- The bag-display helpers (`sellBorderButtons`, `applySellBorder`,
  `bagSlotWillSell`, `updateSellBordersForBagFrame`,
  `installHostBagBorderHook`, the `WC_RefreshSellBorders` body,
  `qualityNames`, `describeSellability`, `printSellabilityTrace`,
  `bagSlotFromButton`) which are physically interleaved with vendor
  code in WoWClearance.lua but belong in Stage 6 (BagDisplay).

Future "Stage 5b" / "Stage 5c" will extract those incrementally as
their cross-file dependencies are sorted (probably by exposing the
helpers they call on `NS` one cluster at a time).

Stage 5 invariants (enforced by `tests/test_perf_guardrails.lua` Test 31):

- `NS.HookDeletePopupOnce` exposed by Vendor at file load.
- No bare `HookDeletePopupOnce()` call sites (every call NS-qualified).
- `WC_compCache.vendorRunning` initialised to `false` in Core's table
  literal.
- `WC_compCache.pendingDelete` initialised to `nil` in Core's table
  literal.
- No file-scope `local running` or `local pendingDelete` lurking
  anywhere in the shipped sources (either would silently desync from
  the cache field).

### Stage 6: extract WoWClearance_BagDisplay.lua (commit `5c9399b`)

Stage 6 moves the Release-1 bag-display layer (sell-border tint +
sellinfo predicate-trace inspector) out of WoWClearance.lua to a new
`WoWClearance_BagDisplay.lua`. The block is contiguous (no Stage-5-style
straddling), all helpers are on `WC_compCache`, so call sites elsewhere
in the addon already resolve via the shared cache.

What moved:

- **Sell-border tint helpers**: `WC_compCache.sellBorderButtons`
  (weak-keyed registry), `applySellBorder`, `bagSlotWillSell`,
  `updateSellBordersForBagFrame`, `installHostBagBorderHook`. The
  opt-in coloured ring around bag-slot frames whose items would be
  sold at the next vendor visit. Hooks default `ContainerFrame_Update`
  AND any host bag UI's per-slot class detected at runtime via LibStub.
- **`NS.RefreshSellBorders` real body** (settings-flip repaint). The
  forward-declared stub stays in WoWClearance.lua; this file replaces
  it with the actual body that walks `sellBorderButtons` and re-applies.
- **`WC_compCache.qualityNames`** lookup table.
- **Sellability-trace inspector**: `describeSellability` +
  `printSellabilityTrace`. Drives `/wc sellinfo` and Alt+Shift+Right-Click.
- **`bagSlotFromButton`** helper.

Cross-file API surface added in this stage:

- **`WC_RefreshSellBorders` promoted from a file-scope local to
  `NS.RefreshSellBorders`.** The stub-and-reassign pattern needed to
  cross the file boundary; a `local` in WoWClearance.lua would mean
  BagDisplay's assignment creates a global instead of replacing the
  stub. 14 reference sites (7 call sites × the `if foo then foo() end`
  guard pattern) substituted from `WC_RefreshSellBorders` to
  `NS.RefreshSellBorders` in code-only positions.
- **`NS.IsSellable = WC_IsSellable`** published right after the
  WC_IsSellable definition. BagDisplay's `bagSlotWillSell` and
  `describeSellability` consult it via `NS.IsSellable`.
- **`NS.PrintNice = PrintNice`** and **`NS.PrintNicef = PrintNicef`**
  for the sellinfo trace's fallback chat output (the primary surface
  is the shared copy-frame popup from v2.50.5 onwards - see
  `NS.ShowCopyFrame` published by `WoWClearance_BugReport.lua`).

**Load order is load-bearing.** `.toc` order is `Core → Companion →
Protection → Vendor → WoWClearance.lua → BagDisplay`. BagDisplay loads
AFTER WoWClearance.lua because WoWClearance.lua's stub
`NS.RefreshSellBorders = function() end` would otherwise OVERWRITE
BagDisplay's real body if it loaded second. Reversed order = silently
broken sell-border refresh. Test 33 enforces this ordering.

Stage 6 invariants (enforced by `tests/test_perf_guardrails.lua` Test 33):

- `NS.RefreshSellBorders` stub declared in WoWClearance.lua's
  forward-decl block.
- BagDisplay reassigns `NS.RefreshSellBorders` with the real body.
- All 9 named bag-display helpers (`sellBorderButtons`, `applySellBorder`,
  `bagSlotWillSell`, `updateSellBordersForBagFrame`,
  `installHostBagBorderHook`, `qualityNames`, `describeSellability`,
  `printSellabilityTrace`, `bagSlotFromButton`) present in BagDisplay
  AND attached to `WC_compCache`.
- `.toc` loads BagDisplay AFTER WoWClearance.lua.
- No bare `WC_RefreshSellBorders()` call sites anywhere.

### Stage 7: extract WoWClearance_Process.lua (commit `a24be7d`)

Stage 7 moves the Process Bags ENGINE out of WoWClearance.lua. The
Process Bags PANEL (UI side) stays in WoWClearance.lua for Stage 8
because it pulls in a dense web of UI-building helpers (`MakeHeader`,
`AddCheckbox`, `CreateListUI`, `WC_FitScrollContent`,
`WC_WrapPanelInScrollFrame`, `WC_compCache.initPanel`, etc.) that
themselves haven't moved yet.

Moved into `WoWClearance_Process.lua` (~390 LOC):

- **Spell ID constants** on `WC_compCache`: `SPELL_DISENCHANT` (13262),
  `SPELL_MILLING` (51005), `SPELL_PROSPECTING` (31252),
  `SPELL_PICK_LOCK` (1804), plus `PICK_LOCK_NAME` (resolved at file
  load via `GetSpellInfo`).
- **Eligibility predicates** on `WC_compCache`: `canDisenchant`,
  `canMill`, `canProspect`, `canPickLock`.
- **Tooltip-scan helper** `processTooltipHasLine` (used by canMill /
  canProspect to detect the "Mill" / "Prospect" usage line).
- **BoP check** `processIsSoulbound` (used by buildProcessSummary).
- **The bag walk** `buildProcessSummary` (the categorisation driver
  that walks bags 0-4, applies all eligibility + protection gates,
  and returns the queue table the UI panel renders).

Stays in WoWClearance.lua (Stage 8 target):

- The Process Bags UI panel (`ProcessBagsPanel`, the SecureActionButton,
  collapsible sections, scroll wiring).
- `rearmProcessButton`, `updateProcessSelection`, `skipProcessTarget`,
  `refreshProcessPanel` (UI-driving helpers that read panel widget
  state).

Cross-file API surface added in this stage:

- **`NS.Delay = WC_Delay`** published right after the WC_Delay body.
  Process uses it to schedule the `WC_compCache.refreshExtractionIfDirty`
  follow-up after a Disenchant / Mill / Prospect cast.
- **`NS.IsAddonEnabledForChar = WC_IsAddonEnabledForChar`** published
  right after the body. Process gates its operations on per-character
  enable.
- Existing `NS.scanTooltip`, `NS.PrintNicef`, `NS.DB`, `NS.ADB` are
  consumed inline (function-entry capture for DB/ADB, direct read for
  the others).

`.toc` order: `Core → Companion → Protection → Vendor → Process →
WoWClearance.lua → BagDisplay`. Process loads BEFORE WoWClearance.lua
because its function bodies are called from WoWClearance.lua's
Process UI panel; that panel's code reads `WC_compCache.canDisenchant`
etc. by the time it runs, but the methods need to exist by file-load
time so the panel's setup code (e.g. dropdown population) doesn't
hit nil.

Stage 7 invariants (enforced by `tests/test_perf_guardrails.lua` Test 35):

- 7 eligibility / scan helpers on `WC_compCache`: `canDisenchant`,
  `canMill`, `canProspect`, `canPickLock`, `processTooltipHasLine`,
  `processIsSoulbound`, `buildProcessSummary`.
- 4 spell ID constants on `WC_compCache` with their correct values
  (13262, 51005, 31252, 1804). Drift would silently break the
  Process panel's spell-known checks.
- `NS.Delay = WC_Delay` and `NS.IsAddonEnabledForChar` published.

### Stage 8: extract WoWClearance_BugReport.lua (commit `d2fe9b6`)

Stage 8 in the original plan was "extract everything UI" - ~3,500 LOC
of dense Interface Options panels, list-row factories, the minimap +
LDB + tooltip-annotation cluster. That's too much for one bite, so
Stage 8 is the smallest meaningful UI cluster instead: the bug-report
builder. Future Stages 8b / 8c can take on heavier UI surface.

Moved into `WoWClearance_BugReport.lua` (~430 LOC):

- `WC_CopperToPlainText` (plain-text gold/silver/copper formatter).
- `WC_BuildBugReport` (walks DB / ADB / cache state to build a
  copy-pasteable diagnostic snapshot).
- `WC_ShowBugReport` (lazy popup frame with a scrolling read-only
  EditBox; exposed as `NS.ShowBugReport` so the `/wc bugreport`
  slash command and any settings-panel button can reach it).

Stage 8 prep (state promotions + NS exposures, included in this
commit because the move depends on them):

- **Three cycle-state locals promoted to `WC_compCache.*` fields**
  (matching the Stage 3 `lastScavSpokeAt` + Stage 5 `vendorRunning` /
  `pendingDelete` pattern):
  - `WC_lootCycleState` → `WC_compCache.lootCycleState` (initial
    value `"idle"`, matches `STATE.IDLE`).
  - `WC_lastScavengerOut` → `WC_compCache.lastScavengerOut` (initial
    `false`).
  - `WC_addonDismissed` → `WC_compCache.addonDismissed` (initial
    `false`).
  40 reference sites in WoWClearance.lua substituted in code-only
  positions. Future Scavenger / Vendor extraction stages can read
  these via the shared cache.
- **Four cross-file helpers exposed on NS**:
  - `NS.GetVersion = WC_GetVersion` (bug-report reads it for the
    "Version: vX.Y.Z" line in the snapshot).
  - `NS.GetFreeBagSlots = WC_GetFreeBagSlots` (snapshot reads "Free
    Slots: N").
  - `NS.CopperToColoredText = CopperToColoredText` (reused by future
    UI extractions; exposed now while we're touching the helpers).
  - `NS.EnsureDB = EnsureDB` (BugReport calls it once at the top of
    `WC_BuildBugReport` to guarantee fields exist before reading).

`.toc` order: `Core → Companion → Protection → Vendor → Process →
WoWClearance.lua → BagDisplay → BugReport`. BugReport loads AFTER
WoWClearance.lua so the `NS.ShowBugReport` exposure happens by the
time anything could call it; the slash command + any settings-panel
button references resolve via NS at call time anyway, but the
file-load order keeps it tidy.

Stage 8 invariants (enforced by `tests/test_perf_guardrails.lua` Test 36):

- `NS.ShowBugReport = WC_ShowBugReport` published by BugReport.
- No bare `WC_ShowBugReport()` call sites (every call NS-qualified).
- `WC_compCache.lootCycleState` / `lastScavengerOut` / `addonDismissed`
  initialised in Core's table literal.
- No file-scope `local WC_lootCycleState` / `local WC_lastScavengerOut` /
  `local WC_addonDismissed` lurking anywhere (would silently desync
  from the cache fields).
- `NS.GetVersion` / `NS.GetFreeBagSlots` / `NS.CopperToColoredText` /
  `NS.EnsureDB` exposures all present.

### Stage 8b: extract WoWClearance_Minimap.lua (commit `<pending>`)

Stage 8b moves the minimap button + LDB launcher + the combat-vendor
SecureActionButton to `WoWClearance_Minimap.lua` (~210 LOC). Three
self-contained UI buttons that live OUTSIDE the Interface Options
panel hierarchy.

Moved into Minimap:

- `WC_UpdateMinimapPos` (positions the minimap button using
  `DB.minimapAngle`).
- `WC_CreateMinimapButton` (draggable minimap button with left /
  middle / right-click bindings: options / Process Bags / toggle;
  hover tooltip showing free bag slots, sellable count, est. value).
- `WC_CreateTargetMerchantButton` (hidden SecureActionButton dispatched
  through by the "Target Goblin Merchant" key binding - combat-lockdown safe).
- `WC_CreateLDBLauncher` (LibDataBroker plugin for users running
  Bazooka / ChocolateBar / etc.).

Cross-file reach pattern:

- Both main settings panel (`WoWClearanceOptionsMain`) and Process Bags
  panel (`WoWClearanceOptionsProcessBags`) are named frames. Minimap
  reaches them via `_G[<name>]` lookup instead of an explicit NS
  exposure. One less NS surface to maintain.
- Other helpers (`PreviewSellable`, `CopperToColoredText`,
  `GetFreeBagSlots`, `PrintNice`, `PrintNicef`, `TARGET_NAME`)
  already on NS from prior stages.
- `WoWClearance_ToggleSettings` / `ToggleEnabled` / `ForceSell` are
  WoW globals (Bindings.xml glue) - reachable from any file.
  `WoWClearance_ToggleEnabled` is the canonical helper for the master
  `DB.enabled` flag: it flips the flag, prints the chat message,
  plays the sound, AND refreshes every UI surface that mirrors the
  state (minimap icon desaturation, Main panel "Enable WoWClearance"
  checkbox). Every entry point (minimap right-click, LDB launcher,
  Main panel checkbox, `/wc enable` / `/wc disable`, keybind) MUST
  route through this helper; direct `DB.enabled = not DB.enabled`
  writes are forbidden and locked by Test 88at. See v2.39.1 in
  CHANGELOG for the bidirectional-sync bug this consolidation closed.

Exposed on NS for the ADDON_LOADED branch in WoWClearance.lua:

- `NS.UpdateMinimapPos`
- `NS.CreateMinimapButton`
- `NS.CreateTargetMerchantButton`
- `NS.CreateLDBLauncher`

Three external call sites in WoWClearance.lua's ADDON_LOADED branch
updated to NS-qualified form.

Stage 8b invariants (enforced by `tests/test_perf_guardrails.lua` Test 37):

- All four `NS.<name>` exposures published by Minimap.
- No bare `WC_CreateMinimapButton()` / `WC_CreateTargetMerchantButton()` /
  `WC_CreateLDBLauncher()` call sites in any shipped source.

### Stage 8c: extract WoWClearance_Tooltip.lua (commit `471ae04`)

Stage 8c moves the bag-item tooltip annotation system to
`WoWClearance_Tooltip.lua` (~362 LOC). The system that adds the
coloured "Will Sell" / "Protected - Random affix" / "Allowed -
Account Sell" / "Protected - Profession tool" / etc. line on every
bag item's tooltip.

Moved into Tooltip:

- `WC_AnnotateTooltip` (per-tooltip body - walks the same decision
  chain as `WC_IsSellable` and produces a humane status line;
  mirrors rather than calls `WC_IsSellable` because tooltip output
  needs to know WHY, not just yes/no; see docs/CODE_REVIEW.md
  item 6 for the documented parallel-impl tradeoff).
- `WC_ClearTooltipFlag` (resets the per-tooltip dedupe flag -
  recipe tooltips fire `OnTooltipSetItem` twice).
- `WC_InstallTooltipHookOnce` (hooks `OnTooltipSetItem` +
  `OnTooltipCleared` on `GameTooltip` + `ItemRefTooltip`).
  Exposed as `NS.InstallTooltipHookOnce` for the ADDON_LOADED
  branch.

Cross-file pattern:

- Tooltip carries its own local `IsInSet` helper (same convention
  as Vendor and BagDisplay - pure function, cheap to duplicate,
  avoids cross-file lookup on every tooltip refresh).
- `WC_IsAddonEnabledForChar` substituted to `NS.IsAddonEnabledForChar`
  (exposure already present from Stage 7).
- 9 `WC_compCache.*` references work via the shared cache table.

One external call site in WoWClearance.lua's ADDON_LOADED branch
updated:

- `WC_InstallTooltipHookOnce()` → `NS.InstallTooltipHookOnce()`

Stage 8c invariants (enforced by `tests/test_perf_guardrails.lua` Test 38):

- `NS.InstallTooltipHookOnce = WC_InstallTooltipHookOnce` published
  by Tooltip.
- No bare `WC_InstallTooltipHookOnce()` call sites anywhere.

### Stage 8d: extract WoWClearance_BagContextMenu.lua (commit `af81c07`)

Stage 8d moves the Alt+Right-Click bag-item quick-action popup
(~375 LOC) to `WoWClearance_BagContextMenu.lua`. A custom popup
frame (not a Blizzard DropDownMenu) wired through `hooksecurefunc`
on `ContainerFrameItemButton_OnModifiedClick`.

Moved into BagContextMenu:

- `WC_CTX_ROWS` (row metadata: list rows + special rows like cancel /
  allow-sell).
- `WC_BuildCtxFrame` (lazy popup frame creation).
- `WC_ShowItemContextMenu` (per-show: sets row labels + OnClick
  handlers, anchors at cursor, shows the frame).
- `WC_InstallBagContextHookOnce` (hooks
  `ContainerFrameItemButton_OnModifiedClick`). Exposed as
  `NS.InstallBagContextHookOnce` for ADDON_LOADED.

Stage 8d prep (NS exposures, same commit):

- `NS.AddItemToList = WC_AddItemToList`
- `NS.RemoveItemFromList = WC_RemoveItemFromList`
- `NS.FindAddConflict = WC_FindAddConflict`

Row-click handlers in the context menu call these three list-mutation
helpers; they were file-scope locals in WoWClearance.lua, so the
move required publishing them on NS first.

Local `IsInSet` helper carried along (same pattern as Vendor /
BagDisplay / Tooltip).

One external call site in WoWClearance.lua's ADDON_LOADED branch
updated:

- `WC_InstallBagContextHookOnce()` → `NS.InstallBagContextHookOnce()`

Stage 8d invariants (enforced by `tests/test_perf_guardrails.lua` Test 39):

- `NS.InstallBagContextHookOnce` exposed by BagContextMenu.
- `NS.AddItemToList` / `NS.RemoveItemFromList` / `NS.FindAddConflict`
  / `NS.GetListTable` exposed by WoWClearance.lua.
- No bare `WC_InstallBagContextHookOnce()` call sites anywhere; no bare
  `WC_GetListTable()` call sites inside `WoWClearance_BagContextMenu.lua`.

### Stage 8e-i: extract WoWClearance_ProcessBagsPanel.lua (commit `7db22bf`)

Stage 8e-i moves the v2.22.0 Process Bags Interface Options panel
(~662 LOC moved, file is ~709 LOC with header) to
`WoWClearance_ProcessBagsPanel.lua`. The narrow first slice of the
Stage 8e UI extraction: a self-contained domain (profession
processing) with its four helpers already on `WC_compCache`
(`rearmProcessButton`, `updateProcessSelection`, `skipProcessTarget`,
`refreshProcessPanel`).

The PROFESSION ENGINE (spell IDs, eligibility predicates,
`buildProcessSummary`) was already extracted in Stage 7 into
`WoWClearance_Process.lua`; Stage 8e-i splits the UI layer off from
that. The two files share state through `WC_compCache`
(`processCache`, the can-* predicates, the cast button macrotext) so
the boundary is clean.

Moved into the new file:

- `local ProcessBagsPanel = CreateFrame(...)` frame creation
- `WC_compCache.rearmProcessButton`, `updateProcessSelection`,
  `skipProcessTarget`, `refreshProcessPanel` bodies
- `ProcessBagsPanel:SetScript("OnShow", ...)` panel-build body

Stage 8e-i prep (NS exposures, same commit):

- `NS.MakeHeader` / `NS.MakeLabel` - panel-text primitives that the
  OnShow build body calls. The locals stay in `WoWClearance.lua`;
  the NS bindings let split files reach them lazily at call time.
  Subsequent panel-extraction stages (8e-ii+) reuse these exposures.

Cross-file dependencies satisfied by NS / WC_compCache:

- `NS.PrintNice` / `NS.PrintNicef` (already on NS since Stage 8 prep).
- `NS.DB` captured at function entry per helper / OnShow (matches the
  Stage 4+ pattern for cross-file DB access).
- `WC_compCache.initPanel` / `setPanelWidth` / `registerWidth` /
  `refreshLayouts` (panel infra in `WoWClearance.lua`; reached via
  the shared `WC_compCache` reference).
- `WC_compCache.canDisenchant` / `canMill` / `canProspect` /
  `buildProcessSummary` (from `WoWClearance_Process.lua`).

`InterfaceOptions_AddCategory(ProcessBagsPanel)` in `WoWClearance.lua`
was converted to
`InterfaceOptions_AddCategory(_G["WoWClearanceOptionsProcessBags"])`
since the local binding no longer exists in that file. The .toc loads
`WoWClearance_ProcessBagsPanel.lua` BEFORE `WoWClearance.lua` so the
frame exists at registration time; the helpers' references to
`NS.MakeHeader` / `NS.PrintNicef` resolve lazily at call time (not
load time) so the late binding is safe.

Stage 8e-i invariants (enforced by `tests/test_perf_guardrails.lua` Test 40):

- `NS.MakeHeader` / `NS.MakeLabel` exposed by WoWClearance.lua.
- All four `WC_compCache` helpers defined in
  `WoWClearance_ProcessBagsPanel.lua` (not in `WoWClearance.lua`).
- `WoWClearance_ProcessBagsPanel.lua` calls `NS.MakeHeader` /
  `NS.MakeLabel` rather than the bare locals (which only exist in
  `WoWClearance.lua`'s scope).
- `WoWClearance.lua` registers the panel via the `_G[]` lookup.

### Stage 8e-ii: extract WoWClearance_MerchantPanel.lua (commit `850587f`)

Stage 8e-ii moves the Merchant Settings Interface Options panel
(~478 LOC moved, file is ~513 LOC with header) into
`WoWClearance_MerchantPanel.lua`. Second slice of the UI extraction:
the Merchant panel is a single self-contained domain (vendor mode +
repair + sliders + per-rarity rules) that uses five additional shared
widget primitives.

Moved into the new file:

- `WC_WHITELIST_QUALITIES` table - rarity labels for the per-rarity
  rule rows (used only by this panel; safe to move).
- `local MerchantPanel = CreateFrame(...)` frame creation.
- `WC_MERCHANT_MODES` table - vendor mode dropdown data (used only by
  this panel; safe to move).
- The MerchantPanel OnShow handler (the panel-build body that
  constructs the dropdowns, sliders, fast-mode toggle, and the four
  per-rarity rule rows).

Stage 8e-ii prep (NS exposures, same commit):

- `NS.AddCheckbox` / `NS.AddSlider` - widget primitives that the
  OnShow body invokes for every settings toggle and slider.
- `NS.FitScrollContent` - called at the end of the panel build to
  size the scroll content to the bottom-most widget.
- `NS.ColorTextByQuality` - the `WC_WHITELIST_QUALITIES` table calls
  this at load time of `WoWClearance_MerchantPanel.lua`, but the
  table is only consumed when the panel is built (much later), so
  the lookup resolves at the right time even though the file loads
  before `WoWClearance.lua`.
- `NS.StyleInputBox` - the per-rarity rule rows have iLvl input
  boxes that need the layered-OVERLAY treatment.

Cross-file dependencies satisfied by NS / WC_compCache:

- `NS.MakeHeader` / `NS.MakeLabel` (already on NS since Stage 8e-i).
- `NS.PrintNice` / `NS.PrintNicef` (already on NS).
- `NS.DB` captured at OnShow entry.
- `WC_compCache.initPanel`, `getBindType`, `setPanelWidth`,
  `registerWidth`, `refreshLayouts` (already shared via `WC_compCache`).

`InterfaceOptions_AddCategory(MerchantPanel)` converted to
`InterfaceOptions_AddCategory(_G["WoWClearanceOptionsMerchant"])`
since the local binding no longer exists in `WoWClearance.lua`.
The .toc loads `WoWClearance_MerchantPanel.lua` BEFORE
`WoWClearance.lua` so the frame exists at registration time.

**Mid-stage gotcha 1**: the file-header doc block must NOT contain the
literal text `MerchantPanel:SetScript("OnShow"` because
`tests/test_layout_reactivity.lua` Test 6 (`panelsNeedingWrap`)
greps for that pattern as the panel's OnShow marker. The first hit
wins; if a comment matches before the actual code, the test sees the
comment-to-code range as the panel "block" and misses the
`end, true)` closer. Reworded the header to describe the OnShow
without using the literal pattern.

**Mid-stage gotcha 2 (load-order trap)**: `WC_WHITELIST_QUALITIES`
originally lived as a file-scope local with eager table construction
calling `NS.ColorTextByQuality(...)` for each entry. But this file
loads BEFORE `WoWClearance.lua` (so the `_G[]` registration lookup
works), which means `NS.ColorTextByQuality` is nil at file-scope
load time. The eager call nil-errored, the file aborted before the
MerchantPanel frame was created, and `InterfaceOptions_AddCategory`
in `WoWClearance.lua` then dereferenced a nil frame at the
following line. Fix: move the table construction INSIDE the OnShow
build callback (which fires lazily; by first OnShow,
`WoWClearance.lua` has loaded and NS.* is populated). The
`initPanel` "build once" gate keeps the cost equivalent to the
file-scope upvalue.

**General rule for split files that load BEFORE WoWClearance.lua**:
function bodies referencing `NS.*` are fine (lazy lookup at call
time). Top-level table constructors and other eager code that calls
`NS.*` are NOT fine - defer them into a function body, or move the
helper into Core.lua so it's available before any of the dependent
files load. Test 41 includes a load-order-trap regression check
scanning the file's pre-build-callback region for bare
`NS.ColorTextByQuality(` calls; extend the check to other NS
primitives if future panel extractions reveal new traps.

Stage 8e-ii invariants (enforced by `tests/test_perf_guardrails.lua` Test 41):

- `NS.AddCheckbox` / `NS.AddSlider` / `NS.FitScrollContent` /
  `NS.ColorTextByQuality` / `NS.StyleInputBox` exposed by
  `WoWClearance.lua`.
- MerchantPanel frame created in
  `WoWClearance_MerchantPanel.lua` (not in `WoWClearance.lua`).
- `WoWClearance_MerchantPanel.lua` uses `NS.AddCheckbox` /
  `NS.AddSlider` / `NS.FitScrollContent` (not bare locals).
- `WoWClearance.lua` registers the panel via the `_G[]` lookup.

### Stage 8e-iii: extract WoWClearance_ScavengerPanel.lua (commit `240046d`)

Stage 8e-iii moves the Scavenger Settings Interface Options panel
(~275 LOC moved, file is ~304 LOC with header) to
`WoWClearance_ScavengerPanel.lua`. **Zero new NS exposures needed** -
the five widget primitives the OnShow body uses (`NS.MakeHeader`,
`NS.MakeLabel`, `NS.AddCheckbox`, `NS.AddSlider`,
`NS.FitScrollContent`) were all exposed in 8e-i / 8e-ii prep. The
smallest extraction in the panel-split sequence so far.

Moved into the new file:

- `local ScavengerPanel = CreateFrame(...)` frame creation.
- The ScavengerPanel OnShow handler (companion summon toggles,
  summon-delay slider, mute / hide-chat / hide-bubbles toggles,
  auto-loot cycle, bag-full threshold, auto-open containers, fast
  loot driver).

`InterfaceOptions_AddCategory(ScavengerPanel)` converted to the
`_G[]` lookup; .toc loads the new file BEFORE `WoWClearance.lua`.
DB captured at OnShow entry per the established pattern.

Stage 8e-iii invariants (Test 45): ScavengerPanel frame lives in the
new file (not duplicated in WoWClearance.lua); new file uses
`NS.MakeHeader` / `NS.AddCheckbox` / `NS.AddSlider` (not bare
locals); registration uses `_G[]` lookup.

### Stage 8e-iv: extract WoWClearance_SellListPanels.lua (commit `bcfde1a`)

Stage 8e-iv bundles two sibling panels (Sell List + Account Sell
List) into one file: `WoWClearance_SellListPanels.lua`. Same
concept, different scope (per-character vs account-wide); both are
list-management UIs anchored on the shared `CreateListUI` helper.
~98 LOC moved, new file is ~125 LOC.

Two new NS exposures (Stage 8e-iv prep) - both share between Sell
List family panels AND Keep / Delete list panels (a future stage),
so the exposures stay on the cross-file surface:

- `NS.CreateListUI` - the scrollable item-list UI builder; called by
  every list-management panel.
- `NS.AddScanByQualityRow` - the "Add from bags: Common / Uncommon /
  Rare" bulk-add row used by Sell List + Account Sell List. (Labelled
  White / Green / Blue before v2.67.1; the buttons keep their rarity
  colour codes, only the words changed.)

Moved into the new file:

- `local WhitelistPanel = CreateFrame(...)` + OnShow build body
- `local AccountWhitelistPanel = CreateFrame(...)` + OnShow build body

Both `InterfaceOptions_AddCategory` calls converted to `_G[]` lookups;
.toc loads the new file BEFORE `WoWClearance.lua`. DB captured at
each OnShow entry per the established pattern.

Stage 8e-iv invariants (Test 46): both panel frames live in the new
file (not duplicated in WoWClearance.lua); new file uses
`NS.CreateListUI` / `NS.AddScanByQualityRow` (not bare locals); both
registrations use `_G[]` lookups; the two new NS exposures are
present.

### Stage 8e-v: extract WoWClearance_KeepDeletePanels.lua (commit `17c8d12`)

Stage 8e-v bundles two sibling list-management panels (Keep List +
Delete List) into one file: `WoWClearance_KeepDeletePanels.lua`.
Both are list-management UIs anchored on the shared `CreateListUI`
helper, with the same panel rhythm (header + description + hint +
list).

~123 LOC moved, new file is ~156 LOC.

**Zero new NS exposures needed** - `NS.MakeHeader`, `NS.MakeLabel`,
`NS.CreateListUI` are all already NS-exposed from 8e-i / 8e-iv prep.

Moved into the new file:

- `local DeletePanel = CreateFrame(...)` + OnShow build body (Delete
  List, including the `Enable item deletion` checkbox with its
  refresh-on-toggle wiring from Issue B)
- `local BlacklistPanel = CreateFrame(...)` + OnShow build body
  (Keep List)

**`BlacklistSettingsPanel` (Protection Settings) stays in
WoWClearance.lua for now.** Despite the name overlap with
BlacklistPanel, it's a different domain (auto-protect toggles for
equipped / upgrades / sets / affixes / chance-on-hit) and will move
in a later stage.

Both registrations converted to `_G[]` lookups. .toc loads the new
file BEFORE `WoWClearance.lua`. DB captured at each OnShow entry.

Stage 8e-v invariants (Test 47): both panel frames in the new file
(not duplicated in WoWClearance.lua); new file uses `NS.CreateListUI`
(not bare local); both registrations use `_G[]` lookups. The Stage
8e-v sentinel check verifying `BlacklistSettingsPanel` was still in
WoWClearance.lua was removed in Stage 8e-vi when that panel moved
intentionally.

### Stage 8e-vi: extract WoWClearance_ProtectionPanel.lua (commit `49403cb`)

Stage 8e-vi moves the Protection Settings Interface Options panel
(`BlacklistSettingsPanel` - internal frame name
`WoWClearanceOptionsBlacklistSettings` preserved from v2.15.0 schema)
into `WoWClearance_ProtectionPanel.lua`. ~391 LOC moved, new file is
~426 LOC.

The panel hosts:
- Auto-protect toggles: `autoAddEquipped`, `autoProtectUpgrades`,
  `autoProtectEquipmentSets`.
- v2.20.0 affix + chance-on-hit protection toggles
  (`protectAffixedRareItems`, `protectChanceOnHitItems`).
- `affixAllowExactDupes` setting.
- v2.32.0 tome / recipe protection: parent toggle
  `protectUnlearnedTomes` + child toggle `protectAllTomes` (greyed
  when the parent is off; same shape as the affix-dupe pair).
- Explanatory notes interleaved between toggles (the reason the panel
  builds checkboxes inline rather than using AddCheckbox's flat
  format).

**Zero new NS exposures needed**: `NS.MakeHeader`, `NS.MakeLabel`,
`NS.FitScrollContent` already exposed in 8e-i / 8e-ii prep. The
panel doesn't use AddCheckbox / AddSlider.

Three of the OnClick handlers in this panel write to verdict-impacting
DB fields (the Issue B fix in Test 42 family) and must call
`NS.RefreshSellBorders` after the SV write. Test 48 includes a count
invariant verifying at least 3 such calls survive the extraction.

Registration converted to `_G[]` lookup. .toc loads the new file
BEFORE `WoWClearance.lua`. DB captured at OnShow entry.

Stage 8e-vi invariants (Test 48): frame lives in the new file (not
in WoWClearance.lua); uses `NS.MakeHeader` / `NS.FitScrollContent`
(not bare locals); Issue B refresh calls preserved; registration
uses `_G[]` lookup.

**v2.49.3 update (current state):** this panel's display name is now
**Keep Settings** (was "Protection Settings"), and it is registered in
the sidebar directly under Keep List so Keep List + Keep Settings mirror
Delete List + Delete Settings. The internal frame name
`WoWClearanceOptionsBlacklistSettings` is UNCHANGED (help-link `panel`
pointers, `/wc` deep-links, and saved layout depend on it). The
**"Sell recipes you already know"** control (checkbox + 4 per-rarity
checkboxes + 4 bind dropdowns) moved OUT of this panel to Merchant
Settings (`WoWClearance_MerchantPanel.lua`) in v2.49.3 - it is a sell
rule, not a keep rule, and now reuses Merchant's `WC_BIND_FILTER_OPTIONS`
/ `WC_BindFilterText` (the former per-panel duplicate is gone). The
runtime precedence "keep all tomes wins over sell-known-recipes" still
lives in `WC_IsSellable`; the panel move did not touch it. Tests 104c-e
pin the moved control + the rename.

### Stage 8e-vii: extract WoWClearance_ItemHighlightingPanel.lua (commit `e768df9`)

Stage 8e-vii moves the Item Highlighting Interface Options panel
(`CharPanel` - internal frame name `WoWClearanceOptionsCharacter`
preserved from the pre-v2.30.x "Character Settings" schema) into
`WoWClearance_ItemHighlightingPanel.lua`. ~200 LOC of CharPanel +
OnShow moved; new file is ~242 LOC with header.

**Zero new NS exposures needed** - the panel only uses
`NS.MakeHeader` + `NS.MakeLabel` (both already exposed in 8e-i).
Per-category enable checkboxes and colour buttons are built inline
inside the SELL_BORDER_CATEGORIES iteration loop.

**Bonus cleanups bundled into this stage:**

1. **Drop dead `CreateNameListUI` (~170 LOC).** Orphaned in §4.5 when
   the per-character allowlist UI was decommissioned (panel renamed
   from "Character Settings" to "Item Highlighting"). Zero call sites
   confirmed via grep across all shipped files.
2. **Strip orphan comment headers** left behind by Stages 8e-v / 8e-vi.
   The `"v2.15.0 Blacklist (Do Not Sell) Panel"` and `"v2.15.0
   Protection Settings sub-panel"` docstrings survived their panel
   extractions; ~40 lines of stale documentation removed from
   `WoWClearance.lua`.
3. **Update `tests/test_layout_reactivity.lua` Test 2**: removed the
   `CreateNameListUI installs box:OnSizeChanged` check (function no
   longer exists). Test 3's regex extended from
   `Create[N]?a?m?e?ListUI` to `N?S?%.?CreateListUI` so it matches
   both the bare-local form in WoWClearance.lua AND the `NS.CreateListUI`
   form used by split panel files.

Registration converted to `_G[]` lookup. .toc loads the new file
BEFORE `WoWClearance.lua`. DB captured at OnShow entry.

Stage 8e-vii invariants (Test 49): CharPanel frame in the new file
(not duplicated in WoWClearance.lua); panel name "Item Highlighting"
preserved; new file uses `NS.MakeHeader` (not bare local);
`CreateNameListUI` confirmed dropped from WoWClearance.lua;
registration uses `_G[]` lookup.

### Stage 8e-viii: extract WoWClearance_ProfilesPanel.lua (commit `a1c473a`)

Stage 8e-viii bundles two related panels into one new file:
ProfilesPanel (named-profile management) + ImportExportPanel (profile
pack + settings pack import/export). The two panels are adjacent in
the source so the extraction is a single contiguous range. ~950 LOC
moved, new file is ~986 LOC.

Moved into the new file:

- `local ProfilesPanel = CreateFrame(...)` + OnShow build (save /
  load / rename / delete buttons + the profile list)
- `local ImportExportPanel = CreateFrame(...)` + OnShow build (export
  textarea + import textarea + scope dropdown + mode dropdown +
  buttons)
- The ImportExport region's file-scope helpers (`WC_EXPORT_PREFIX`,
  `WC_GetWhitelistForScope`, `WC_ExportWhitelist`,
  `WC_ImportWhitelist`) - only used inside the panel itself.
- `WC_compCache.exportFullPack` + `WC_compCache.importFullPack` -
  full settings pack serialiser / deserialiser (previously inline in
  this region, on the shared cache table so still reachable via
  `NS.compCache` from any future caller).

Stage 8e-viii prep (5 new NS exposures, same commit):

- `NS.SaveProfile` / `NS.LoadProfile` / `NS.DeleteProfile` /
  `NS.RenameProfile` - profile-mutation helpers whose bodies stay in
  `WoWClearance.lua` (slash commands also resolve them through the
  same NS entries).
- `NS.HookScrollbarAutoHide` - the scrollbar auto-hide utility used
  by the Profiles list + ImportExport textarea. Internal helper
  declared on the same line family as the other 8e-i / 8e-ii
  exposures.

Both `InterfaceOptions_AddCategory` calls converted to `_G[]` lookups;
.toc loads the new file BEFORE `WoWClearance.lua`. DB captured at
each OnShow entry.

Stage 8e-viii invariants (Test 50): the 5 NS exposures present; both
panel frames in the new file (not duplicated in WoWClearance.lua);
new file uses `NS.SaveProfile` / `NS.HookScrollbarAutoHide` (not bare
locals); `WC_GetWhitelistForScope` confirmed gone from
`WoWClearance.lua`; both registrations use `_G[]` lookups.

### Stage 8e-ix-a: extract WoWClearance_MainPanel.lua (commit `8bfa7f8`)

Stage 8e-ix-a moves the top-level "WoWClearance" Interface Options
panel (MainOptions) + its BuildMainPanel helper into
`WoWClearance_MainPanel.lua`. ~241 LOC moved across three
non-contiguous chunks (frame creation, BuildMainPanel body, OnShow
handler). Final file is ~283 LOC.

The panel-infrastructure helpers (`MakeHeader`, `MakeLabel`,
`AddCheckbox`, `AddSlider`, `WC_PANEL_WIDTH`, `WC_UpdatePanelWidth`,
`WC_compCache.initPanel`, `setPanelWidth`, etc.) STAY in
`WoWClearance.lua`. They're shared across every panel and will move
in a later stage (Stage 8e-ix-b / 8e-ix-c).

Stage 8e-ix-a prep (1 new NS exposure):

- `NS.ResetSession` - the session-stats reset handler used by the
  Reset Session button on this panel. Body stays in `WoWClearance.lua`.

In addition, five call sites that previously used the bare
`MainOptions` local for `InterfaceOptionsFrame_OpenToCategory` were
converted to `_G["WoWClearanceOptionsMain"]` lookups:

- The welcome-popup `OnCancel` handler (when a brand-new install
  asks "open settings?").
- `WoWClearance_ToggleSettings` (the keybind handler).
- The `/wc` slash command with no args.
- The unknown-subcommand fallback in `/wc`.
- The combat-deferred panel-open queue in `PLAYER_REGEN_ENABLED`.

Registration line converted to `_G[]` lookup. .toc loads the new
file BEFORE `WoWClearance.lua`. DB + ADB captured at OnShow entry
and BuildMainPanel entry.

Stage 8e-ix-a invariants (Test 51): NS.ResetSession exposed;
MainOptions frame + BuildMainPanel in the new file; new file uses
NS.ResetSession + NS.CopperToColoredText (not bare locals);
MainOptions + BuildMainPanel confirmed gone from `WoWClearance.lua`;
no bare `MainOptions` identifier references remain; registration
uses `_G[]` lookup.

### Stage 8e-ix-b: extract WoWClearance_PanelInfra.lua (commit `04d791c`)

Stage 8e-ix-b moves the panel-infrastructure block (the foundation
that every Interface Options panel in the addon depends on) into
`WoWClearance_PanelInfra.lua`. ~263 LOC moved; new file is ~311 LOC.

Moved into the new file:

- `local WC_PANEL_WIDTH` (mutable; the container's effective width
  minus a fixed 40 px margin)
- `local function WC_UpdatePanelWidth` (refreshes from
  `InterfaceOptionsFramePanelContainer:GetWidth()`)
- `NS.GetPanelWidth` (getter closure; captures the upvalue - must be
  co-located with WC_PANEL_WIDTH for the upvalue to resolve)
- `WC_compCache.widthRegistry` (state table)
- `WC_compCache.registerWidth` / `registerScrollFit` / `setPanelWidth`
  / `refreshLayouts` (the 4 reactive-layout helpers)
- `local function WC_HookScrollbarAutoHide`
- `local function WC_WrapPanelInScrollFrame`
- `local function WC_FitScrollContent`
- `WC_compCache.initPanel` (the panel-OnShow preamble extractor)

The widget primitives (`MakeHeader`, `MakeLabel`, `AddCheckbox`,
`AddSlider`, `StyleInputBox`, `ColorTextByQuality`) + `CreateListUI`
+ the list-row factories STAY in `WoWClearance.lua` for Stages
8e-ix-c / 8e-ix-d.

Stage 8e-ix-b prep (before the extraction):

- Four in-`WoWClearance.lua` bare callers of `WC_PANEL_WIDTH` /
  `WC_HookScrollbarAutoHide` were converted to `NS.GetPanelWidth()` /
  `NS.HookScrollbarAutoHide` so they still work after the move:
  - `MakeLabel` initial-width SetWidth.
  - `CreateListUI` initial-width `local w` snapshot.
  - `WC_AddScanByQualityRow` row-frame SetSize.
  - `WC_compCache.buildListScrollArea` scrollbar hook call.
- Test 1 in `tests/test_layout_reactivity.lua` updated to accept the
  new `fs:SetWidth(NS.GetPanelWidth() - x)` form in MakeLabel
  alongside the legacy `fs:SetWidth(WC_PANEL_WIDTH - x)` form.
- `EnsureDB()` call inside `initPanel` rewritten to `NS.EnsureDB()`
  (NS.EnsureDB was already exposed during Stage 8 prep).

Stage 8e-ix-b invariants (Test 52): `WC_PANEL_WIDTH` + `initPanel` +
`widthRegistry` + `NS.GetPanelWidth` closure live in
`WoWClearance_PanelInfra.lua`; new file uses `NS.EnsureDB` (not
bare); `WoWClearance.lua` no longer declares `WC_PANEL_WIDTH` or
`initPanel`; no bare `WC_PANEL_WIDTH` or `WC_HookScrollbarAutoHide`
references remain in `WoWClearance.lua` code (comments are stripped
before checking via a per-line `%-%-` scan that handles indented
inline comments).

### Stage 8e-ix-c: extract WoWClearance_PanelWidgets.lua (commit `de3fc0b`)

Stage 8e-ix-c bundles the six widget primitives into one new file:

- `MakeHeader` (GameFontNormalLarge anchor at TOPLEFT 16, y)
- `MakeLabel` (wrapped GameFontHighlight; registers width with the
  reactive layout registry)
- `StyleInputBox` (InputBoxTemplate EditBox chrome treatment)
- `AddCheckbox` (InterfaceOptionsCheckButtonTemplate wrapper)
- `AddSlider` (OptionsSliderTemplate wrapper)
- `ColorTextByQuality` (ITEM_QUALITY_COLORS-aware text formatter)

~150 LOC moved across 3 non-contiguous chunks (MakeHeader +
StyleInputBox; MakeLabel; AddCheckbox + ColorTextByQuality +
AddSlider). The list-row factories (`WC_compCache.makeListRowFactory`
+ `buildList*Row` helpers) + `CreateListUI` + `WC_AddScanByQualityRow`
STAY in `WoWClearance.lua` for Stage 8e-ix-d.

**Zero new NS exposures needed** - all six were exposed during the
v2.31.0 + earlier stages' prep work. The existing in-WoWClearance.lua
callers of these widgets (just 3 `StyleInputBox(...)` calls inside
the list-row factories) were converted to `NS.StyleInputBox(...)`
before the extraction.

The extraction script's initial pass missed StyleInputBox because the
blank-line probe forward from `NS.MakeHeader = MakeHeader` stopped at
the leading doc-comment block of StyleInputBox (multi-line comment,
not blank). A small surgical follow-up extracted StyleInputBox
separately and inserted it before the MakeLabel block in the new
file. Same total scope; just two passes of the script.

Stage 8e-ix-c invariants (Test 53): all 6 widgets defined in
`WoWClearance_PanelWidgets.lua`; all 6 NS exposures present in the
new file; no widget primitive is duplicated in `WoWClearance.lua`;
no bare `StyleInputBox()` call sites remain in `WoWClearance.lua`
code (comments stripped before the scan via per-line `%-%-` parse).

### Stage 8e-ix-d: extract WoWClearance_ListWidget.lua (commit `91ea0d5`)

Stage 8e-ix-d is the densest remaining cluster: the reusable list
widget that every list panel (Sell List, Account Sell List, Keep
List, Delete List) composes its UI from. ~605 LOC moved across three
non-contiguous chunks of `WoWClearance.lua`:

- Five row-factory helpers hung off `WC_compCache`
  (`makeListRowFactory`, `buildListHeaderRow`,
  `buildListSearchAndSortRow`, `buildListMatchRow`,
  `buildListScrollArea`) - the layout primitives that compose
  CreateListUI's pieces.
- `CreateListUI` itself (309 LOC) - the assembled list widget,
  including its `Refresh` closure with name-sort, search debounce,
  affix annotation, tooltip prime, and the Add / Clear All / Add
  Matching button OnClick handlers. (v2.41.0: each pooled row now
  carries an 18px item icon in place of the old itemID text, a
  quality-colored name via `NS.ColorTextByQuality`, and a
  cursor-anchored hover tooltip wired once in `makeListRowFactory`
  reading `row.itemID`. The icon texture + quality come from the
  same per-row `GetItemInfo` the name already needed. The header
  controls regrouped into an "Add to list" group (`buildListHeaderRow`,
  now a single merged input that takes an item ID or a name - the old
  `buildListMatchRow` "By name" scan folded into it and that factory was
  removed) and a "Find in list" group (`buildListSearchAndSortRow`:
  divider + Sort button + Clear All + Search + rarity filter). The
  merged add (CreateListUI's `DoAdd`) routes a numeric entry to an ID
  add and resolves text via an exact cached-name `GetItemInfo` hit plus
  a bag substring scan (3.3.5a has no full item-database name search).
  `buildListHeaderRow` dropped its `titleText` arg; the in-box title is
  gone since each panel heads the box itself.
  The Name sort arrow uses the `SORT_ASC` / `SORT_DESC` texture
  constants - the old U+25B2 / U+25BC glyphs are not in the 3.3.5 font
  and rendered as "?". The "ID" sort button was removed (the row no
  longer shows an ID) and replaced by a "Show:" rarity-filter dropdown
  (`NS.MakeSelector`, v0.6.0; options from the `WC_RARITY_FILTERS`
  file-scope table, colored via `NS.ColorTextByQuality`); the
  `rarityFilter` upvalue stacks with search in `Refresh`, and the
  default sort is now `name_asc`. `WC_AddControlTip` attaches plain
  hover tips via `HookScript`. The same icon + cursor tooltip were
  added to the Process Bags queue rows in
  `WoWClearance_ProcessBagsPanel.lua`.)
- `WC_AddScanByQualityRow` (78 LOC) - the shared "Add from bags:
  White / Green / Blue" scan row used by both Sell List panels.

The new file lives after `WoWClearance_PanelInfra.lua` and
`WoWClearance_PanelWidgets.lua` in the `.toc` load order so the
row factories see `NS.StyleInputBox` and `NS.HookScrollbarAutoHide`
as already-published NS members. CreateListUI itself only runs
inside panel OnShow callbacks, so by the time it executes the
panel files (loaded BEFORE WoWClearance.lua) have also bound their
`NS.foo` exposures.

**Two new NS exposures from the new file:**
- `NS.CreateListUI` - panel files (`SellListPanels`,
  `KeepDeletePanels`) call it inside their OnShow build callback.
- `NS.AddScanByQualityRow` - SellListPanels.lua calls it to attach
  the per-quality scan-row above each Sell List widget.

**One prep refactor:** `WC_activeIDBox` was a file-scope local in
`WoWClearance.lua` (line 1238 pre-split) shared by the row-factory
header's OnEditFocusGained/Lost setter and the
`ChatEdit_InsertLink` hook's reader. After the move, the setter is
in `WoWClearance_ListWidget.lua` and the reader is still in
`WoWClearance.lua` - they cannot share a file-scope local across
files. Promoted to `NS.activeIDBox`: the reader at line 1251 now
captures `local box = NS.activeIDBox` before checking
`box:IsShown()`, and the setter writes `NS.activeIDBox = self`.
The bare `local WC_activeIDBox = nil` declaration is gone (line
count stayed identical because the new `local box = NS.activeIDBox`
absorbed its slot).

**CreateListUI body re-targeting:** four formerly file-scope-local
references in the moved body needed to become NS calls:

- `WC_GetListTable` → `NS.GetListTable` (already exposed earlier)
- `WC_AddItemToList` → `NS.AddItemToList` (already exposed earlier)
- `PrintNicef` → `NS.PrintNicef` (already exposed earlier)
- `WC_Delay` → `NS.Delay` (already exposed in Stage 8e-ix-b)

The `WC_compCache` reference works because every split file binds
`local WC_compCache = NS.compCache` at the top (Core.lua exposes
`NS.compCache = WC_compCache`).

Tests 20-22 (existing CreateListUI invariants from v2.28.0) still
pass because they search the concatenated `src` built from
SOURCE_PATHS. They find `local function CreateListUI(` in the new
file's body without modification.

Stage 8e-ix-d invariants (Test 54): all 5 row-factory functions
defined on `WC_compCache.*` in `WoWClearance_ListWidget.lua`;
`local function CreateListUI(` and `local function
WC_AddScanByQualityRow(` defined in the new file;
`NS.CreateListUI` and `NS.AddScanByQualityRow` exposed from the new
file; CreateListUI body uses `NS.GetListTable` / `NS.AddItemToList`
/ `NS.PrintNicef` / `NS.Delay`; buildListHeaderRow uses
`NS.activeIDBox`; no row factories / CreateListUI /
WC_AddScanByQualityRow definitions remain in `WoWClearance.lua`
(comments stripped via per-line `%-%-` parse); no
`local WC_activeIDBox` declaration remains in `WoWClearance.lua`;
`ChatEdit_InsertLink` hook reads `NS.activeIDBox`.

### Stage 9: rename WoWClearance.lua to WoWClearance_Events.lua (commit `defa02e`)

The closing stage of the multi-stage file split. The original
monolith filename was retained through stages 1-8e-ix-d so the
.toc / release workflow / luacheck / stylua all stayed
incrementally working. Once the event hub + slash commands +
Bindings.xml glue were the only substantive content left in
`WoWClearance.lua`, the file's name no longer matched its
responsibility - so Stage 9 renames it.

**Mechanical changes (lockstep):**

- `git mv WoWClearance.lua WoWClearance_Events.lua` -
  preserves history.
- `WoWClearance.toc`: line 26 updated from `WoWClearance.lua` to
  `WoWClearance_Events.lua`. The `.toc` itself keeps its name
  (only the Lua file moved).
- `.github/workflows/release.yml`: 4 sites updated -
  - `sed @VERSION@ ...` target file (line 25)
  - `sed ADDON_VERSION ...` target file (line 35)
  - `cp ... WoWClearance/` source list (line 45)
  - `git add ...` target list (line 64)
- `.github/workflows/test.yml`: `luac5.1 -p WoWClearance.lua` ->
  `WoWClearance_Events.lua`.
- 3 test SOURCE_PATHS arrays: `"WoWClearance.lua"` ->
  `"WoWClearance_Events.lua"`.
- 12 `io.open("WoWClearance.lua", "rb")` sites in
  `tests/test_perf_guardrails.lua`: all retargeted to the new
  filename via `replace_all`.
- Stale `WoWClearance.lua` references in test failure messages
  and surrounding comments: swept via regex replace
  (`(?<![_A-Za-z])WoWClearance\.lua` -> `WoWClearance_Events.lua`,
  preserving every `WoWClearance_<feature>.lua` name).
- `.luacheckrc`, `stylua.toml`: header comments updated to
  `*.lua` wildcards + a note about the rename.
- `CLAUDE.md`: file reference + the stylua/luacheck command line
  updated; "single-file architecture" rewritten to "multi-file
  architecture" with a NS-namespace note.
- `WoWClearance_Events.lua` header: new top-of-file doc block
  noting Stage 9 + the file's actual remaining responsibility
  (event hub + slash commands + Bindings.xml glue). The
  ADDON_VERSION constant's "DO NOT move" warning updated to
  reference the new filename + the matching release.yml sed
  pattern.

**ADDON_VERSION stays in this file:** the release workflow's sed
pattern at `.github/workflows/release.yml` line 35 is anchored to
`WoWClearance_Events.lua` (updated in this stage). The constant
itself stays at `v2.31.0` - Stage 9 is a code-rearrange commit, not
a user-facing release. The watermark
(`WC_Fingerprint("WoWClearance@" .. ADDON_VERSION)`) is unchanged
because the input string is unchanged.

**Sweep of residuals deferred:** the original Stage 9 brief
included "sweep residuals (auto-open driver, Fast Loot driver,
vendor-cycle remnants from Stage 5's narrow scope) to their target
files." The rename itself is large enough as a verify-then-ship
change; teasing those residuals into BagDisplay / Vendor is a
follow-up that can land in subsequent commits without bumping a
stage. The current contents of `WoWClearance_Events.lua` work as
the event hub; the residuals are just sitting alongside it.

Stage 9 invariants (Test 55): the old `WoWClearance.lua` file no
longer exists in the working tree (a leftover copy would shadow
the renamed one if Lua's `package.path` somehow picked it up);
`WoWClearance_Events.lua` exists and contains the `ADDON_VERSION`
constant matching `local ADDON_VERSION = "vX.Y.Z"`; .toc
references the new filename + contains no bare `WoWClearance.lua`
reference; release.yml references the new filename + contains no
bare `WoWClearance.lua` reference (approximate non-identifier
boundary check since Lua patterns lack lookbehind).

### Target architecture (post-split)

Per docs/CODE_REVIEW.md item 4, the planned split shape is:

| File | Responsibility |
|---|---|
| `WoWClearance_Core.lua` | Namespace, constants, API caches, forward decls, EnsureDB / EnsureAccountDB, WC_Delay, WC_compCache |
| `WoWClearance_Companion.lua` | Scavenger / Goblin Merchant lifecycle, chat filters, mount handler, stuck detection |
| `WoWClearance_Protection.lua` | Affix detection, chance-on-hit detection, bind-type cache, process cache |
| `WoWClearance_Vendor.lua` | WC_IsSellable, BuildQueue, DoNextAction, vendor worker, auto-repair (v2.71.0 update: the WC_IsSellable decision body moved to `WoWClearance_Decision.lua` instead - see "The sell/keep decision core"; the cycle mechanics remain the Vendor.lua target) |
| `WoWClearance_Process.lua` | Process Bags engine, hold-key-to-drain |
| `WoWClearance_BagDisplay.lua` | Sell-border hooks, /wc sellinfo, auto-open driver, Fast Loot driver |
| `WoWClearance_UI.lua` | CreateListUI + helpers, all Interface Options panels, minimap, LDB, bug-report |
| `WoWClearance_Events.lua` | Event hub, slash commands, Bindings.xml glue handlers |

Stages 2-8 each extract one file from the monolith. Stage 9 renames
`WoWClearance.lua` -> `WoWClearance_Events.lua` and closes out the
refactor.

### Rules for future stages

- Each stage is a separate release; no feature work in the same release.
- Move-only commits where possible; pure mechanical refactor.
- After each stage, all three invariant tests must still pass. Tests
  concatenate the split files at test time (see the SOURCE_PATH loop
  at the top of each test file after Stage 2 ships) so existing
  invariants apply unchanged.
- LICENSE §2(b) requires the file-header attribution block: it stays
  on whichever file is loaded first in the `.toc` (currently
  `WoWClearance.lua`; will move to `WoWClearance_Core.lua` in Stage 2).
- Forward declarations move from file-scope `local foo = function() end`
  stubs to `NS.foo = function() end` table-slot stubs, reassigned in
  the owning file. Cross-file callers invoke `NS.foo()` - table-index
  lookup at call time, so load order between feature files doesn't
  matter (Core must still load first because it owns the namespace
  shape and the EnsureDB migrations).

## Diagnostic hooks (v2.51.0)

Ring buffers, snapshots and timestamps that `/wc bugreport` dumps. Every hook exists so a pasted bug report answers "why didn't X fire?" or "why didn't Y stick?" without a back-and-forth. All are session-local (wiped on `/reload`) EXCEPT the Sold History logs, which persist per character since v0.6.0.

- **`NS.silentRefusalLog`** (ring, 15 max). `WC_AddItemToList`'s cross-list conflict guard refuses `quiet=true` adds silently - the auto-protect sync path uses `quiet=true`, so a Keep-Add refused because the item's already on Delete List returns `false` with no chat trail. This was the root cause of the v2.50.2 shirt-loss bug. `WC_LogSilentRefusal(itemID, targetList, conflictList, caller)` populates the ring. `caller` is the label the panel passed (e.g. `"Keep List"`, `"Equipment Set"`).
- **`NS.recentSoldLog`** + **`NS.recentDeletedLog`** (5000-entry rings each; overflow overwrites the oldest and bumps `WC_soldLogTrimmed` / `WC_deletedLogTrimmed`, surfaced by `NS.SessionHistoryTrimmed()`). `WC_LogRecentSold(itemID, count, path, copper, reason)` + `WC_LogRecentDeleted(itemID, count, source, reason)` (the `reason` arg, v2.54.0, is the plain-English "why"; each entry also carries a monotonic `seq`, a `t = time()` stamp, sets `WC_compCache.historyDirty`, and calls `WC_compCache.syncSoldHistory()`). **Persisted per character since v0.6.0** through `DB.soldHistory`; see "Persisted ring logs". Three hook sites populate them:
  - `hooksecurefunc(C_Container, "UseContainerItem", ...)` in the manual-sell attribution block (the 3.3.5a hook was on the bare global): `path = "manual"`.
  - `DoNextAction`'s `sell` branch in the worker cycle: `path = "worker"`.
  - `WC_compCache.executeBagSlotDelete`'s single call site (both auto-delete and vendor-cycle delete): `source = announce and "auto" or "vendor"`.
  - Consumed by the **Sold History window** (`WoWClearance_HistoryWindow.lua`, `NS.ShowHistoryWindow`; `NS.ShowSessionHistory` prefers it) and, tail-sliced to the newest `NS.bugReportRecentMax` (20), by `/wc bugreport`. `NS.ClearSessionHistory()` wipes both logs + trim counters and syncs the store.
- **`NS.CaptureToggleLoginSnapshot()`** + **`NS.ToggleDiffSinceLogin()`**. Watched-toggle snapshot at PLAYER_LOGIN (after `EnsureDB` seeds defaults). Diff at report time surfaces "toggles the user flipped this session" without needing mutation hooks on every settings widget. Watch list is `WC_TOGGLE_WATCH_LIST` (destructive, auto-mark, protection including the two v0.6.0 protections, auto-protect, sell rules, pacing).
- **`NS.lastEventAt`** (table) + **`NS.StampEvent(key)`**. Stamp keys: `bagUpdate`, `equipmentSetsChanged`, `merchantShow`, `merchantClosed`, `vendorRunStart`, `autoMarkResilience`, `autoMarkKnownRecipe`, `autoDeleteScan`. Values start nil; a `(never)` reading in `/wc bugreport`'s Last Event Times section is diagnostic on its own.
- **`NS.compCache.bindCache` / `processCache` / `equipmentSetIDs`**. Session caches; `/wc bugreport`'s Cache Stats section counts each and breaks out `bindCache` by `boe / bop / any`. Since v0.6.0 `bindCache` holds item bind TYPES only, so it says nothing about whether a given copy is bound.

`NS.recentProcShareMerges` and the affix caches (`itemAffixLookupCache`, `bagSlotAffixData`, `chanceOnHitCache`) were removed with the Project Ebonhold subsystem.

**Shared copy frame** (`WC_ShowCopyFrame` in `WoWClearance_BugReport.lua`, exposed as `NS.ShowCopyFrame`): a thin wrapper over the shared kit's `NS.Kit.ShowCopy("WoWClearanceCopy", ...)` (`WoWClearance_Kit.lua`, the same file RaidLootController ships as `RLC_Kit.lua`; never edit it here). Help URLs and the update link use the same window. Opens without focus, click selects all, resizable, default 560x400.

**Sell Info popup** (`printSellabilityTrace` in `WoWClearance_BagDisplay.lua`): leads with a header block (character, realm, date/timestamp, bag/slot, item link, colored `WILL SELL` / `WILL DELETE` / `WON'T SELL` verdict), then a `--- Full trace ---` section with the same step chain as before. Rejection branches for the protections and recipe bind-filter mismatches include an inline `Tip: ...` phrase naming the panel + toggle the player can flip.

**Item name resolver** (`WC_ResolveItemLabel` in `WoWClearance_BugReport.lua`): primes the client cache via `NS.scanTooltip:SetHyperlink` then retries `GetItemInfo`. Used by every "list of item IDs" section in the bug report so long-standing Delete-List entries the user hasn't hovered still resolve to names / links.
