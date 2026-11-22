# Architecture (code map)

> **Targets WoW: Forever** (Interface 16001, a Mainline 12.1.x API surface).
> WoWClearance is a fork of EbonClearance, a WoW 3.3.5a addon; the port is
> complete and the file layout below is the current one. For what has been
> measured on the live client, read [PORT_STATUS.md](PORT_STATUS.md).

A bird's-eye map of where things live, for a contributor or AI agent landing
in the repo. This is a map, not a manual: it tells you which file to open, not
how every function works. For the deep reference (Lua 5.1 constraints, gotchas,
refactoring traps, comms internals) read
[ADDON_GUIDE.md](ADDON_GUIDE.md). For deferred work, read
[CODE_REVIEW.md](CODE_REVIEW.md).

WoWClearance is a bag manager for WoW: Forever (Lua 5.1, as every WoW client
runs): it vendors, deletes, protects items by rule, and runs profession
processing. Loot tracking lives in an optional sibling addon,
`WoWClearance_Loot` (see below). No external libraries; all Blizzard APIs.

## How the files fit together

The `.toc` ([WoWClearance.toc](../WoWClearance.toc)) is the load-order source
of truth; the list below groups those files by role, not load order. Every file
starts with `local NS = select(2, ...)` and shares state through that `NS`
table. The only true globals are `WoWClearanceDB`, `WoWClearanceAccountDB`,
the slash-command handles, and the `WoWClearance_*` keybind handlers called
from `Bindings.xml`.

### Engine (no UI)

| File | Owns |
|------|------|
| [WoWClearance_Kit.lua](../WoWClearance_Kit.lua) | The author's shared kit (`NS.Kit`: colours, chat printer, copy window), a byte-identical copy of a file a sibling addon ships. Loads first. Never edit it here. |
| [WoWClearance_Core.lua](../WoWClearance_Core.lua) | Provenance/fingerprint, shared "junk-drawer" state (`WC_compCache`), `STATE` constants and the `NS` bootstrap. Depends on nothing but the kit. (`EnsureDB` / `EnsureAccountDB` live in `Events.lua`.) |
| [WoWClearance_Decision.lua](../WoWClearance_Decision.lua) | The sell/keep/delete decision core (v2.71.0-v2.71.3). `NS.Decision.sell(ctx)` and `NS.Decision.deleteEligible(ctx)` are PURE (no WoW API, no DB) and return verdicts + reason tokens; two adapters (`buildCtx` for bag slots, `buildTooltipCtx` for hovers/chat links) share one snapshot helper. `WC_IsSellable` + `deleteListSlotEligible` in Events delegate here. Runtime-tested by `tests/test_decision.lua`. |
| [WoWClearance_Protection.lua](../WoWClearance_Protection.lua) | What to *keep*: Resilience, tome / recipe and learn-state detection, plus the Forever protections' detectors (`isUncollectedAppearance`, `isTradeableOrRefundable`). |
| [WoWClearance_Process.lua](../WoWClearance_Process.lua) | The Process Bags engine: Disenchant / Lockpick / Convert, plus Mill / Prospect where the client has those spells (`processModeExists`; Forever does not). |
| [WoWClearance_BagDisplay.lua](../WoWClearance_BagDisplay.lua) | Bag-slot sell-border tint + the sellinfo inspector, and every host bag UI adapter (`installHostBagBorderHook`). That includes the DaylightUI bag integration: borders, list groups, the merged Alt+Right-Click menu, and the lock / junk-mark / one-seller hooks. Since v2.71.1 the inspector's verdict comes from `Decision.sell`; only the per-step narration is local. |

### Event hub & comms

| File | Owns |
|------|------|
| [WoWClearance_Events.lua](../WoWClearance_Events.lua) | The single event frame, the `/wc` slash commands, and the residual glue. Adding an event = `RegisterEvent` + a branch here, never a new frame. Also where every Interface Options panel is registered centrally. |
| [WoWClearance_Comms.lua](../WoWClearance_Comms.lua) | `NS.Comms` addon-to-addon transport + the version-update gossip (and the Loot module's Stats - Guild; Stats - Server was removed in v0.9.0). |

### Interface Options panels (feature UI)

One file per panel (or closely-related pair). All register centrally in
`Events.lua`; none self-registers.

[MainPanel](../WoWClearance_MainPanel.lua) ·
[MerchantPanel](../WoWClearance_MerchantPanel.lua) ·
[ProcessBagsPanel](../WoWClearance_ProcessBagsPanel.lua) ·
[SellListPanels](../WoWClearance_SellListPanels.lua) ·
[KeepDeletePanels](../WoWClearance_KeepDeletePanels.lua) ·
[ProtectionPanel](../WoWClearance_ProtectionPanel.lua) ·
[ItemHighlightingPanel](../WoWClearance_ItemHighlightingPanel.lua) ·
[ProfilesPanel](../WoWClearance_ProfilesPanel.lua) (hosts List Profiles, Settings Profiles, and Import/Export) ·
[StatsPanel](../WoWClearance_StatsPanel.lua) (sold-side stats only) ·
[QuickstartPanel](../WoWClearance_QuickstartPanel.lua) ·
[HelpPanel](../WoWClearance_HelpPanel.lua)

### Panel infrastructure (shared widgets)

| File | Owns |
|------|------|
| [WoWClearance_PanelInfra.lua](../WoWClearance_PanelInfra.lua) | The panel-width registry + reactivity layer (`WC_compCache`). Any widget that snapshots panel width MUST go through it. |
| [WoWClearance_PanelWidgets.lua](../WoWClearance_PanelWidgets.lua) | Panel widget primitives, plus `NS.MakeStatRow` - the shared two-column stat row (`row.left` / `row.right` at a fixed value X) every stats surface uses so numbers stack in a column. Also `NS.MakeSelector` (the home-made dropdown every option list uses; `UIDropDownMenu` and `MenuUtil` are off limits on Forever), `NS.MakeRarityDropdown` built on it, and `NS.RaiseTooltipAboveWindows` for TOOLTIP-strata pop-outs - see the WC-TRAP notes there before adding a dropdown or tooltip. |
| [WoWClearance_ListWidget.lua](../WoWClearance_ListWidget.lua) | The reusable list-management widget (add input / search / sort / rarity filter). |

### Localization

| File | Owns |
|------|------|
| [WoWClearance_Locale.lua](../WoWClearance_Locale.lua) | `NS.L`: returns the English key unchanged. This version is English only; the French / German templates and `/wc locale` were removed. Loads right after Core. |

Player-facing strings are wrapped at the call site as `L["English text"]`
(`local L = NS.L`), so a translation layer can come back without touching
every call site.

### Other UI & utility

| File | Owns |
|------|------|
| [WoWClearance_Minimap.lua](../WoWClearance_Minimap.lua) | Minimap button, launcher data object, and the addon compartment handler (`WoWClearance_OnAddonCompartmentClick`, named in the `.toc`). |
| [WoWClearance_Tooltip.lua](../WoWClearance_Tooltip.lua) | Bag-item tooltip annotations. Since v2.71.2 it reads all state through `Decision.buildTooltipCtx` and its labels are guarded by `Decision.sell`'s verdict (equipped-honesty fix-up + sentinel line); only the per-branch label text is local. |
| [WoWClearance_BagContextMenu.lua](../WoWClearance_BagContextMenu.lua) | Alt+Right-Click bag-item quick-action popup. Stands down on a host bag UI whose own menu carries a row for it (`WC_compCache.hostOwnsItemMenu`). |
| [WoWClearance_Window.lua](../WoWClearance_Window.lua) | The standalone settings window (sidebar + hosted panels), `NS.SkinWindow`, and the single launcher page in the game's Settings. Must load before any file that calls `NS.SkinWindow` at file scope. |
| [WoWClearance_Daylight.lua](../WoWClearance_Daylight.lua) | Optional DaylightUI integration that is not about bags: a WC section in its options, `/dui wc`, a data text, and window movers. WC's windows are not restyled here; a skin addon does that. Loads last; does nothing without DaylightUI. |
| [WoWClearance_BugReport.lua](../WoWClearance_BugReport.lua) | Diagnostic snapshot builder + display frame (`/wc bugreport`). |
| [WoWClearance_HistoryWindow.lua](../WoWClearance_HistoryWindow.lua) | The interactive Sold History window (`/wc history`, v2.57.0): sell/delete log with All/Sold/Deleted filters + search, over `NS.recentSoldLog` / `NS.recentDeletedLog`. Since v0.6.0 those tables are saved per character (`DB.soldHistory`, loaded at login by `WC_compCache.loadSoldHistory`). |

`Bindings.xml` defines keybinds that call the `WoWClearance_*` global handlers.

### Optional Loot module (`WoWClearance_Loot/`, v0.9.0)

A separate addon in its own folder with its own
[`.toc`](../WoWClearance_Loot/WoWClearance_Loot.toc)
(`## Dependencies: WoWClearance`), shipped in the same zip and on by default.
The Main panel's "Loot module" checkbox turns it on or off (reload needed).
It reaches the core `NS` through `C_AddOns.GetAddOnLocalTable("WoWClearance")`
(allowed by `## AllowAddOnTableAccess: 1` in the core `.toc`); module files
read it as `select(2, ...).core`. No new global and no new SavedVariables: its
data stays in `WoWClearanceDB` / `WoWClearanceAccountDB`, seeded by the core
`EnsureDB`.

| File | Owns |
|------|------|
| [WoWClearance_LootCapture.lua](../WoWClearance_Loot/WoWClearance_LootCapture.lua) | Loot bag-delta capture, looted coin, `NS.StampBestGPH`, zone attribution, the Shift+L claim, and the module's one event frame (`LOOT_READY`, `LOOT_CLOSED`, `PLAYER_MONEY`, `CHAT_MSG_LOOT`, `PLAYER_LOGIN`). Loads first; sets `own.core`. |
| [WoWClearance_LootHistory.lua](../WoWClearance_Loot/WoWClearance_LootHistory.lua) | The Loot Log's History view store: an account-wide ring of the last 20000 pickups, saved as packed strings with a decoded in-memory mirror, plus the locale-safe group-loot chat parser. |
| [WoWClearance_LootWindow.lua](../WoWClearance_Loot/WoWClearance_LootWindow.lua) | The Loot Log window (`NS.ToggleLootWindow`). |
| [WoWClearance_LootPanel.lua](../WoWClearance_Loot/WoWClearance_LootPanel.lua) | The "Stats - Loot" panel (`WoWClearanceOptionsLoot`): gold looted, session / best gold per hour, top zones, Loot Log button. |
| [WoWClearance_GuildShare.lua](../WoWClearance_Loot/WoWClearance_GuildShare.lua) | `NS.GuildShare`: opt-in, anonymous-by-default "Stats - Guild" pooling over `NS.Comms` (guild + group). |
| [WoWClearance_GuildPanel.lua](../WoWClearance_Loot/WoWClearance_GuildPanel.lua) | The "Stats - Guild" panel (`WoWClearanceOptionsGuild`). |

Core-side hooks, each nil-checked at the call site so the core runs the same
without the module: `WC_compCache.scanLootDelta()` (BAG_UPDATE flush),
`WC_compCache.onSoldCopper(copper)` (manual sale + `FinishRun`),
`WC_compCache.onResetSession()`. The core exposes `WC_compCache.bumpStat` /
`bumpStatBucket` for it. `/wc loot` and the Loot Log key binding stay in core
and print a hint when the module is off.

## Boundaries (the things that must stay true)

These are the invariants an agent should not "simplify" across. Many are pinned
in code with `WC-TRAP:` markers; run `grep -rn "WC-TRAP:"` before touching
anything that looks like dead code or a bug.

- **One event frame.** It lives in `Events.lua`. Features do not create their own;
  they expose a handler or hook and the hub calls it. The exceptions: the
  chat transport (`Comms.lua`) owns one frame for `CHAT_MSG_ADDON`, and the
  Loot module, a separate addon, owns one frame for its loot events.
- **The Events main chunk is at Lua 5.1's 200-locals cap.** New state goes on
  `WC_compCache` or `NS`, not new file-scope locals.
- **Cross-file state goes through `NS`.** New globals are not added.
- **SavedVariables change only via `EnsureDB` / `EnsureAccountDB`** nil-default
  migrations (downgrade-safe, additive). Both live in `Events.lua` (the
  `EnsureDB` body around the per-char field list; `Core.lua` owns the namespace
  shape, not the migrations).
- **Verify every new API, event and template on Forever** with the `wow` MCP
  tools (`flavor: "forever"`) before writing it; luacheck cannot tell a real
  event name from an invented one. See CLAUDE.md.
- **Chat output only through `PrintNice` / `PrintNicef`.** Never
  `DEFAULT_CHAT_FRAME:AddMessage` directly.
- **Panel width only through `WC_compCache`** (PanelInfra), or it freezes at
  build-time width on resize.
- **State transitions use `STATE.*` constants,** not raw strings.
- **No third-party addon names** in new code, docs, or player-facing text. DaylightUI is the one deliberate exception (see CLAUDE.md).
- **No em dashes (U+2014) anywhere.**

## Where do I make change X?

| I want to... | Open |
|--------------|------|
| Change what counts as sellable / keepable | `Decision.lua` (the sell/keep core; add a fixture in `tests/test_decision.lua`) + `Protection.lua` for detection helpers |
| Change vendor pacing / per-run cap | `Events.lua` (`WC_Effective*` helpers) |
| Add a profession-processing rule | `Process.lua` |
| Add a settings checkbox | the relevant `*Panel.lua` + an `EnsureDB` default in `Events.lua` |
| Add a keep rule | a veto in `Decision.sell` (decide whether it stops only the auto rules, like the tome and Forever protections), a ctx thunk in both adapters, a detector in `Protection.lua`, fixtures in `tests/test_decision.lua` |
| Change the Loot Log, looted coin, gold per hour or zones | the Loot module: `WoWClearance_Loot/` (`LootCapture.lua` records, `LootHistory.lua` + `tests/test_loothistory.lua` stores, `LootWindow.lua` / `LootPanel.lua` show) |
| Add a whole new options panel | new `*Panel.lua` + register it centrally in `Events.lua` |
| React to a new game event | `RegisterEvent` + a branch in `Events.lua` (not a new frame) |
| Add a `/wc` subcommand | the slash handler in `Events.lua` (and a row in `README.md`) |
| Change a bag border or tooltip annotation | `BagDisplay.lua` / `Tooltip.lua` |
| Support another bag UI, or change the DaylightUI bag integration | a `try...Host` adapter in `BagDisplay.lua`'s `installHostBagBorderHook` |
| Change the DaylightUI options section, data text or movers | `Daylight.lua` |
| Send an addon-to-addon message | `NS.Comms` in `Comms.lua` |
| Add or align a row on a stats surface | `NS.MakeStatRow` in `PanelWidgets.lua`; the refresh body lives in `MainPanel.lua` (`NS.RefreshStats`) |

## Verifying a change

From the repo root:

```
lua tests/run_all.lua                                 # all nine invariant suites in one shot
luac -p WoWClearance_*.lua WoWClearance_Loot/*.lua    # syntax check every shipped file (luac5.1 in CI)
luacheck WoWClearance_*.lua WoWClearance_Loot/*.lua   # 0 warnings expected (runs in CI; see CLAUDE.md)
```

CI ([.github/workflows/test.yml](../.github/workflows/test.yml)) runs the syntax
check, luacheck, and `tests/run_all.lua` on every push; the release workflow
re-runs them at the tag gate. See [CLAUDE.md](../CLAUDE.md) for the full release
process.
