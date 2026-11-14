# Agent entry point

> **PORT COMPLETE. PUBLIC SINCE v0.8.0.**
> WoWClearance is a fork of [EbonClearance](https://github.com/powerfulqa/EbonClearance)
> ported from **WoW 3.3.5a** to **WoW: Forever** (Interface 16001).
> Forever is the retail/Mainline client wearing a Classic version number:
> it tracks Mainline 12.1.5, so this was a Classic-to-Retail rewrite, not a
> version bump.
>
> **This repository is public and its history starts at v0.8.0.** The port
> itself was done in a private repository; its commit log was not carried
> over. `CHANGELOG.md` and `docs/PORT_STATUS.md` hold the record of that work.
>
> **Port status.** The Project Ebonhold subsystem is removed, the container /
> item / spell layer is on the `C_*` namespaces, the options UI is on the
> Settings API, and v0.6.0 added Forever-only features (Loot Log History,
> saved Sold History, appearance and trade/refund protections, reagent bag,
> addon compartment). The core paths have been played in game: panels,
> tooltips, the vendor sell path, the Loot Log and Sold History, and saved
> settings across a restart. `WoWClearance_RealmComms.lua` was rebuilt on
> 2026-10-10 by the owner's decision: addon messages on a temporary custom
> channel, opt-in only, unmeasured in game (PORT_STATUS work item 7).
>
> See [docs/PORT_STATUS.md](docs/PORT_STATUS.md) for what is done, what is
> measured on the live client, and what is still open - it is the
> authoritative record, not this file. Its **Porting lessons** section is
> the first thing to read before assuming anything about this client;
> every rule in it cost real time to learn.
>
> **SavedVariables: broken on build 69913, working on 1.60.1.70245.** On the
> older build the client wrote saved data on exit and never read it back, so
> every launch started from defaults and then overwrote the saved copy. That
> was the release blocker: an addon whose protection rules silently reset is
> more dangerous than no addon. On 2026-10-07, on build 70245, saved data
> survived a real cold start, read off the screen and confirmed on disk
> (account scope; evidence in the hard-release-gate section of PORT_STATUS).
> Not covered: per-character scope (this addon has none of its own) and an
> independent second addon on the same boundary. **Tagging a release is still the
> owner's decision; do not tag one without it.** If a later client
> build regresses, the gate comes back. `GetTime()` on this client counts
> from system boot, not client launch, so no in-client check can tell a
> reload from a relaunch - establish that boundary from outside (a new
> `WowB.exe` PID, or `WTF/SavedVariables/Blizzard_GlueSavedVariables.lua`
> rotating to `.bak`).

## How to write code here ("ponytail": lazy senior dev)

Lazy means efficient, not careless. The best code is the code never written.

Understand first: read the task and the code it touches, and trace the real
flow end to end (event hub branch, decision core, adapters, panel). Then stop
at the first rung that holds:

1. Does this need to be built at all? (YAGNI)
2. Does it already exist in this codebase? Reuse the `NS` / `WC_compCache`
   helper or the pattern already here (`PrintNice`, `NS.MakeStatRow`,
   `Decision.slotLocation`, the ring-log pattern, `processModeExists`, ...).
3. Does Lua 5.1's standard library do it? Use it.
4. Does Blizzard's API or shipped UI already do it? Use it, after confirming it
   exists on Forever with the `wow` MCP tools (`flavor: "forever"`).
5. Can it be one line? Make it one line.
6. Only then: write the minimum code that works.

(There is no rung for "add a dependency": this addon ships no external libraries.)

Bug fix = root cause, not symptom. Grep every caller of the function you touch
and fix the shared function once; patching only the path the report names
leaves sibling callers broken.

- No abstractions, boilerplate or new dependencies nobody asked for.
- Deletion over addition. Boring over clever. Fewest files possible.
- Shortest working diff wins, but only once the problem is understood. The
  smallest change in the wrong place is a second bug.
- Question complex requests: "Do you need X, or does Y cover it?"
- When two approaches are the same size, pick the edge-case-correct one.
- Never lazy about: understanding the problem, input validation at trust
  boundaries (chat payloads, other players' addon messages, saved data that
  may be malformed), anything that could sell, delete or lose the player's
  items or settings, security, accessibility, and anything explicitly
  requested.
- Non-trivial logic leaves ONE runnable check behind (a fixture in an
  existing suite, or a new suite registered in `tests/run_all.lua`). Trivial
  one-liners need none.
- Lazy never overrides a `WC-TRAP:` marker: "simpler" is not a reason to
  remove one. Read its pointer first (see below).

For a one-screen orientation (which file owns what, the boundaries, and a "where do I change X?" table), read the code map in **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** first.

For the deep reference, **read [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md)**. It is the prescriptive guide for working in this codebase and covers:

- Lua 5.1 constraints (no `goto`). The 3.3.5a API constraints in that guide
  are historical: the addon now targets the Forever `C_*` surface, declared
  with explicit member lists in [`.luacheckrc`](.luacheckrc)
- Multi-file architecture (one Core file + feature files + per-panel files + the event hub), and state-machine conventions
- Cached API upvalue patterns for hot paths
- SavedVariables migrations via `EnsureDB`
- Interface Options panel idempotency
- The decision record for **not** embedding Ace3
- **Gotchas and refactoring traps** - non-obvious design choices that have silently broken in the past. Read this before you "simplify" anything.

**Before you delete or "simplify" anything that looks like dead code, cruft, or a bug, run `grep -rn "WC-TRAP:"`.** Every hit marks intentional code that has lured someone down a wrong path before (forced-default flags whose branches look dead, 3.3.5a APIs that look wrong, parallel systems that look redundant, raw global overrides that "should" be `hooksecurefunc`). Read the marker and follow its pointer (a locking test, an ADDON_GUIDE section, or a `docs/CODE_REVIEW.md` item) before touching it. Do not remove an `WC-TRAP:` line as part of a cleanup.

## The short version

- This is a bag-manager addon being ported to WoW: Forever. The architecture below is inherited from EbonClearance (a WoW 3.3.5a addon for Project Ebonhold) and is accurate as a map of the files; the API-level claims in it are not yet true of Forever. After the file split (docs/CODE_REVIEW.md item 4), the v2.36.0 Help / Stats sub-panel extractions, the v2.38.0 Quickstart panel, the v2.39.0 `WoWClearance_Comms.lua` addition, the v2.40.0 guild-share panel (`WoWClearance_GuildShare.lua` + `WoWClearance_GuildPanel.lua`), the v2.43.0 localization layer (`WoWClearance_Locale.lua`, loaded right after Core; now an English passthrough, since this version is English only and the French / German templates were removed), and the v2.57.0 interactive Sold History window (`WoWClearance_HistoryWindow.lua`, an on-demand scrollable window over the full-session sell/delete logs, modelled on the Loot Log window), and the v2.58.0 realm-wide sharing layer (`WoWClearance_RealmComms.lua`, a transport sibling of `NS.Comms`, rebuilt in v0.6.0 as addon messages on a temporary custom channel because chat text on a channel needs a hardware event on Forever; opt-in only, and a channel reaches only your own underlying realm. See PORT_STATUS work item 7; `WoWClearance_ServerShare.lua`, its odometer aggregator; `WoWClearance_ServerStatsPanel.lua`, the "Stats - Server" panel), and the v2.71.0 decision core (`WoWClearance_Decision.lua`, loaded right after Core: `NS.Decision.sell(ctx)` is the PURE sell/keep decision - no WoW API reads - and `NS.Decision.buildCtx(bag, slot, junkOnly)` is the adapter that snapshots live state into a ctx with lazy thunks; `WC_IsSellable` in Events is now a thin delegate), and the port's per-pickup loot history (`WoWClearance_LootHistory.lua`, loaded right after the event hub: an account-wide ring of the last 20000 pickups with time and looter, fed by the bag-delta loot path for your own loot and by `CHAT_MSG_LOOT` for group members), and the optional DaylightUI look (`WoWClearance_Daylight.lua`, loaded LAST: dresses WC's own windows, panels and Alt+Right-Click menu through `DaylightUI.API` when DaylightUI is loaded and `WoWClearanceDB.daylightLook ~= false`, the "Use DaylightUI look" toggle on the Main panel; it reads that flag inside its skin callback, never at file scope, because saved variables are not loaded yet when the file runs), the addon ships as 36 `.lua` files (one of them, `WoWClearance_Kit.lua`, is Serv's shared kit: a byte-identical copy of RaidLootController's `RLC_Kit.lua`, loaded first, setting `NS.Kit`; edit it there, never here); the event hub + slash commands + Bindings.xml glue live in [WoWClearance_Events.lua](WoWClearance_Events.lua) (renamed from the original monolith `WoWClearance.lua` in Stage 9). Addon-to-addon comms (the version-update gossip + the reusable `NS.Comms` transport) live in [WoWClearance_Comms.lua](WoWClearance_Comms.lua), which loads after the event hub; `WoWClearance_GuildShare.lua` (an `NS.Comms` consumer) + `WoWClearance_GuildPanel.lua` add the guild/group-scoped, opt-in, anonymous-by-default "Stats - Guild" sharing, and `WoWClearance_ServerShare.lua` (an `NS.RealmComms` consumer) + `WoWClearance_ServerStatsPanel.lua` add the realm-wide anonymous "Stats - Server" odometer + realm-wide update checks (default OFF since the port, and the channel is joined only from the panel toggle, never at login; the old `shareServerDataDefaultBumped` migration was removed). The [.toc](WoWClearance.toc) lists every file in load order.
- No external libraries. All Blizzard APIs.
- Run `stylua *.lua && luacheck *.lua` before committing. If a new warning appears, fix the cause or extend [`.luacheckrc`](.luacheckrc) - do not silence with blanket directives. **Luacheck CI gating is ENABLED** (the pre-existing debt was reconciled): [.github/workflows/test.yml](.github/workflows/test.yml) installs luacheck via luarocks and runs `luacheck WoWClearance_*.lua` as a gate on every push, alongside `luac -p` (globbed over every `WoWClearance_*.lua`, v2.75.0) and all ten suites. The gate must stay at **0 warnings** - the WoW: Forever API surface is declared in `read_globals`, intentional globals (`SetItemRef`, the loot-log handler/binding globals, `GameTooltip`/`ItemRefTooltip` field writes) are declared, and idiomatic-noise categories (`212` unused args, `213`, `431`/`432` shadowing, `631` long lines) are ignored with rationale in `.luacheckrc`. Anything else: fix the cause or add the global/API to `.luacheckrc`, never a blanket silence. **Know what this gate cannot see.** `RegisterEvent` takes a string, so luacheck cannot tell a valid event name from an invented one: a file registering `"THIS_EVENT_DOES_NOT_EXIST_ANYWHERE"` passes at 0 warnings / 0 errors, verified. That is structural, not a config gap, and on this client a bad name THROWS and aborts the rest of the chunk. Event names are pinned by `test_comms_version.lua`'s rejected list and by porting lesson 15 in [docs/PORT_STATUS.md](docs/PORT_STATUS.md); check a new event name against a Forever-flavour source before registering it, and never infer safety from a green gate.
- Run all ten invariant tests before committing. The single entry point is **`lua tests/run_all.lua`** (runs every suite below and is the source of truth for the suite list; CI and the release gate both call it). To run one suite in isolation, invoke it directly:
  - `lua tests/test_decision.lua` - the v2.71.0 decision-core RUNTIME suite (the only non-static suite besides the codec tests). Loads `WoWClearance_Decision.lua` under stock lua5.1 and exercises `NS.Decision.sell(ctx)` + `NS.Decision.deleteEligible(ctx)` (v2.71.3) with fixture contexts: every reason token, the grey-always-sold WC-TRAP, the junkOnly / sellPrice gates on every positive signal, the v2.50.2 delete-rescue vetoes (incl. the account-vs-character Sell List asymmetry), and the surviving golden field-incident regressions (v2.51.2/v2.59.10 Sell-List-vs-tome, v2.50.2 shirt-loss delete rescue). The affix / chance-on-hit fixtures went with that subsystem. New sell/keep/delete behaviour MUST land with a fixture here.
  - `lua tests/test_dbproxy.lua` - the v2.75.0 DB-proxy RUNTIME suite (a second non-static suite). Slices the real `WC_DBBuildProxy` + `PER_CHAR_FIELDS` out of `WoWClearance_Events.lua` and drives the three-tier routing (top-level account / per-character / settings-profile) against a synthetic saved-variables table: per-character reads/writes land on the char namespace (incl. `enabled`, made per-character in v2.75.0), settings-profile fields route to the active profile, a profile field the active profile LACKS falls back to the frozen top-level legacy value (the fresh-audit "future-field trap" fix), and plain account fields route to the top level. Version-agnostic loader (loadstring+setfenv on 5.1, `load` with an _ENV arg on 5.2+).
  - `lua tests/test_layout_reactivity.lua` - the v2.11.0 reactive-panel-layout invariants. Any new widget that snapshots `WC_PANEL_WIDTH` MUST go through `WC_compCache.setPanelWidth(widget, x)` or `WC_compCache.registerWidth(widget, x)` - otherwise it'll silently freeze at build-time width on resize.
  - `lua tests/test_perf_guardrails.lua` - the v2.24.0 perf invariants (BAG_UPDATE coalescing, name-sort pre-compute, search debounce) plus v2.29.0 invariants (list-mutation refresh call sites, sell-border helpers pinned to WC_compCache), plus the port's options-panel registration-completeness check, plus the v2.55.0 frame-spike diagnostic invariants (Test 115: session-only bounded ring, delta-based watchdog gated on per-frame elapsed, each phase timed additively via debugprofilestop, tooltip body kept separate from its timing wrapper, `/wc spike` wired to `NS.ShowFrameSpikes`), plus the v2.59.0/v2.63.0 shared flush-snapshot invariants (Test 119: scanners lazily acquire ONE shared per-frame bag snapshot via acquireFlushSnapshot - never an eager per-flush build, same-frame validity stamp, live slot re-verify in the scanners that run after the pickup-delete, openable cache never stores the LOCKED state), plus the v2.68.1 invariants (Test 124: both pop-out windows' search boxes route through NS.MakeSearchDebounce, and the 5000-cap session logs ring-write - never table.remove(t, 1) - with seq-ordered readers), plus the v2.76.0 spike-attribution invariants (Test 134: the worst-10 spike ring evicts by SEVERITY never FIFO, entries are shared between the rings and carry ecMs captured at insert, and both /wc spike and the bugreport render WC's clamped share of each frame). Since v2.68.1 this suite (and comment-hygiene + layout-reactivity) derives its SOURCE_PATHS from the .toc, so new files are scanned automatically.
  - `lua tests/test_comment_hygiene.lua` - the v2.29.0 comment hygiene check. Counts comment-line occurrences of a fixed watch-list of forbidden patterns and fails if any count exceeds the v2.29.0 baseline.
  - `lua tests/test_comms_version.lua` - the v2.39.0 comms / version-alert invariants. Loads `WoWClearance_Comms.lua` in isolation and unit-tests `parseVersion` (numeric compare, not lexical), plus static-pattern checks on the comms layer's shape. **Note:** this suite used to assert the ABSENCE of `RegisterAddonMessagePrefix`, which was correct on 3.3.5a and is exactly backwards on Forever, where that registration is MANDATORY or `CHAT_MSG_ADDON` is never delivered and the whole transport fails silently. **Inverted and fixed** during the port: it now asserts the prefix IS registered, before the listener attaches. Since v0.6.0 `NS.RealmComms` also uses addon messages, so `test_servershare.lua` asserts its prefix IS registered too. **v0.5.0** added the rejected-event guard here: it pinned only `PARTY_MEMBERS_CHANGED` and passed the whole time `LEARNED_SPELL_IN_TAB` was registered bare in the event hub, which on this client throws and aborts the rest of the chunk. It now walks a list of four MEASURED-rejected names (`PARTY_MEMBERS_CHANGED`, `LEARNED_SPELL_IN_TAB`, `UNIT_COMBO_POINTS`, `RUNE_UPDATE`) plus two non-vacuity checks, since every assertion in that block is negative and an unread source would satisfy them all. Adding a name is cheap; removing one requires a fresh in-game measurement, because absence from that list reads as "safe to register".
  - `lua tests/test_loothistory.lua` - the port's loot-history RUNTIME suite. Loads `WoWClearance_LootHistory.lua` in isolation and drives the group-loot chat parser (multiple / single forms, own "You receive" lines rejected, positional format strings parsed independent of capture order), the `CHAT_MSG_LOOT` handler (looter gets the realm appended, own name and unreadable secret payloads skipped), and the ring buffer (newest-first reads, storage never exceeds the cap).
  - `lua tests/test_guildshare.lua` - the v2.40.0 guild-share invariants. Loads `WoWClearance_GuildShare.lua` in isolation and unit-tests the payload encode/decode (items by `id~name`, per-rarity counts) + aggregation merge (pool items by id, contributor names, best-GPH holder name), plus static-pattern checks (reply gated on `shareGuildData`, uses `NS.Comms`, no `GROUP_ROSTER_UPDATE`).
  - `lua tests/test_servershare.lua` - the v2.58.0 realm-wide "Stats - Server" odometer invariants. Loads `WoWClearance_ServerShare.lua` in isolation with a stub `NS.RealmComms` (+ controllable `GetTime`) and unit-tests the compact codec (`t:cop,sold,del,proc | ver: | i: | z:`) encode/decode, the **per-sender keyed aggregate** (a re-send from the same sender never double-counts; distinct senders sum AND give the headcount; the per-contributor sanity cap drops absurd totals; entries expire after the 20min TTL), the SREQ responder (reply gated on `shareServerData`, self-skip, one reply per 30s floor, replies sent channel-wide with NO whisper target), the `ver:` piggyback feeding `NS.Comms.NotePeerVersion`, and anonymity (a sender name never appears in the displayed aggregate); plus static-pattern checks over both `NS.ServerShare` and `NS.RealmComms` (registers `"SREQ"`/`"SDAT"`; the v0.6.0 transport registers its prefix, sends addon messages on `"CHANNEL"`, never posts chat text, joins a TEMPORARY channel only after `/1` is taken, leaves on opt-out, never joins from `Send`, reads only accessible `CHANNEL` messages, waits out chat lockdown; has `RunSelfTest`, NO chunking, NO `GROUP_ROSTER_UPDATE`, panel not self-registered, Events registers it + seeds `shareServerData`; Refresh while opted out neither joins nor sends).
  - `lua tests/test_api_surface.lua` - the port's API-surface invariants. Loads the real `.luacheckrc` as Lua and asserts every `C_*` namespace is declared with an explicit `fields` list rather than as a bare name (a bare name makes luacheck vouch for the namespace and nothing inside it, so a member this client lacks lints clean and returns nil), that measured-absent members like `C_EquipmentSet.GetEquipmentSetItemIDs` are NOT listed, and that members which DO exist still are. Also asserts every moved 3.3.5a global is namespaced at the call site or bound from its `C_` namespace in that file - luacheck cannot catch that, because the old names are still declared while the migration finishes.
- **No third-party addon references in new WC artefacts** - the v2.29.0 implementation constraint. Code comments, commit messages, `CHANGELOG.md`, `README.md`, `docs/`, slash command help, `/wc bugreport` output, settings labels, and tooltip annotations MUST NOT name other addons. Detection code may still call specific globals (necessary), but the comment uses neutral framing ("host bag UI", "third-party bag UI adapter"). Existing mentions stay. **One deliberate exception (owner's decision, 2026-11-14): DaylightUI may be named** - in `WoWClearance_Daylight.lua`, the "Use DaylightUI look" toggle and its tooltip, the bag-ring adapter's detection, and the docs that describe them. Do not strip those mentions in a cleanup. Full statement in `docs/ADDON_GUIDE.md` "No third-party addon references in new WC artefacts".
- **Player-facing text stays brief, concise, and new-player friendly.** The v2.32.x text-simplification pass set the bar: tooltip labels, panel descriptions, checkbox text, chat messages, slash command help, and any other string a player can read in-game must lead with what happens, drop the "why" / mechanism, and avoid code jargon (no "predicate", "sweep", "veto", "throughput", "case-fold", "qualifying event", "auto-rule"). Use plain verbs ("Keep" / "Will Sell" / "Won't Sell" / "Will Delete"), parenthesised one-or-two-word reasons, active voice, present tense. Internal docstrings and code comments may stay technical; the rule is about the surface the player sees. When adding a new label, ask: "would a brand-new player understand this without context?" If not, simplify before shipping.
- **Never use em dashes (Unicode U+2014) anywhere in this repo.** Not in player-facing text, not in code comments, not in markdown docs, not in commit messages, not in CHANGELOG entries. Em dashes are a dead giveaway that an LLM wrote the text and read as inauthentic for an addon shipped by a human author. Use plain hyphens with spaces (` - `), periods, colons, or commas instead. The same rule applies to en dashes (Unicode U+2013) outside numeric ranges. A grep for the U+2014 character against the repo MUST return zero results - this is enforced by spot-check before commit and by reviewers. The rule applies recursively: this line itself does not contain the banned character, and neither should any future rule that references it (use the Unicode codepoint instead).
- Known deferred refactors are tracked in [docs/CODE_REVIEW.md](docs/CODE_REVIEW.md). Don't repeat items that are already there - cite them by number if you touch adjacent code.

## Conventions at a glance

- Everything is `local`, prefixed `WC_`. Globals are `WoWClearanceDB` and the slash-command handles only.
- Chat output goes through `PrintNice` / `PrintNicef`. Never call `DEFAULT_CHAT_FRAME:AddMessage` directly.
- State transitions use `STATE.*` constants (not raw strings) so typos fail loudly.
- Forward-declare `local` variables at the top of the file when functions defined earlier need to capture them as upvalues. This bit us in v2.0.12 and is now explicit.
- Cross-file references go through the shared `NS` namespace (`local NS = select(2, ...)` at the top of every file; `NS.compCache = WC_compCache` exposes the shared cache table; per-feature exposures like `NS.RefreshSellBorders` are wired at the end of the file that owns the body).

## Release process

The release is driven by [.github/workflows/release.yml](.github/workflows/release.yml). It triggers on any `v*` tag push (and via `workflow_dispatch` for recovery). The workflow:

1. Rewrites `WoWClearance.toc` (`## Version:` field; the Title carries no version) from the tag name. The .toc is the single source of the version: `WoWClearance_Events.lua` reads it with `C_AddOns.GetAddOnMetadata`. **Manual version-bumps are not needed.**
2. Packages every `WoWClearance*.lua` file, `WoWClearance.toc`, `Bindings.xml`, `LICENSE`, and `AGENTS.md` (the licence notes for AI coding tools; it must stay in step with `LICENSE`) into `WoWClearance.zip`.
3. Commits the version bump back to `origin/master` as a `Update version to vX.Y.Z [skip ci]` bot commit. **After the workflow runs, your local branch will be 1 commit behind origin; run `git pull --rebase` to catch up before the next commit.**
4. Extracts the `### vX.Y.Z` stanza from [CHANGELOG.md](CHANGELOG.md) and uses it as the body of the GitHub Release at `https://github.com/powerfulqa/WoWClearance/releases/tag/vX.Y.Z`. If no stanza exists, the workflow falls back to a generic stub: `Patch release. See the previous minor version for the feature description.` The auto-generated `**Full Changelog**: ...compare/...` footer is appended automatically.

### The correct order

**Always add the CHANGELOG stanza AND sync the surrounding docs BEFORE you tag.** The recommended sequence:

1. Make code changes; verify with the invariant suites (`lua tests/run_all.lua`).
2. **Audit the iteration for leftovers and clean them up.** Multi-iteration features leave debris: stale comments that describe controls/parameters that were renamed or removed, orphaned locals/functions, unreachable branches, doc-comment return signatures that drifted. Sweep the diff (grep for the names of any symbols you removed; read each changed function end-to-end) and fix what you find BEFORE tagging, so the release ships clean. This is also the moment to spot feature-creep duplication introduced across iterations.
3. Add the `### vX.Y.Z` stanza to `CHANGELOG.md` describing what's in the release.
4. **Sync the docs.** Audit the diff and ask "did this patch touch anything externally visible to a player or a contributor?" If yes, update the relevant docs in the same patch:
   - In-game Help / FAQ ([WoWClearance_HelpPanel.lua](WoWClearance_HelpPanel.lua)) - for any player-facing surface change (new panel, toggle, view, slash command, tooltip annotation, changed default, schema-visible change).
   - [README.md](README.md) - for installation, configuration, slash-command table, or feature-bullet changes. Slash-command additions ALWAYS get a row in the README table.
   - [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md) - for architecture, file layout, shared helpers, naming conventions, test invariants, or 3.3.5a gotchas. Contributors read this first.
   - [NOTICE.md](NOTICE.md) - for adopting or diverging from a convention shared with related projects.
   - This file ([CLAUDE.md](CLAUDE.md)) - if you add or remove a `.lua` file (update the count), change the test invariants list, or introduce a new release-process step.
5. Commit code + CHANGELOG + docs together (or in two commits if the diff is large: features first, then docs).
6. Push to `origin/master`.
7. Tag the release: `git tag vX.Y.Z && git push origin vX.Y.Z`.
8. The workflow runs (~1-2 min) and re-runs all ten test suites at the gate. The version-bump bot commit (`Update version to vX.Y.Z [skip ci]`) lands on `origin/master`, carrying the CI-side rewrite of `WoWClearance.toc`.
9. **Required final step: `git pull --rebase` to sync local with the CI build work.** Because step 8 committed the version bump upstream, your local branch is now 1 commit behind `origin/master`. You MUST rebase before any further work, or the next local commit diverges from origin. Confirm with `git status -sb` - it should read `## master...origin/master` with no `[ahead N]` / `[behind N]`.

If you tag without a CHANGELOG stanza (e.g. a fast patch where the commit message was the only record), the release page ships with the fallback stub and players reading the release notes see no detail. The recovery path:

- Add the stanza to CHANGELOG.md retroactively + commit + push.
- Extract the stanza and update the existing release body:
  ```
  awk -v target="### vX.Y.Z" '$0 == target { f=1; print; next } f && /^### v/ { f=0 } f { print }' CHANGELOG.md > /tmp/notes.md
  printf "\n\n**Full Changelog**: https://github.com/powerfulqa/WoWClearance/compare/vPREV...vX.Y.Z\n" >> /tmp/notes.md
  gh release edit vX.Y.Z --notes-file /tmp/notes.md
  ```
  The `gh release edit` REPLACES the body, so re-append the compare-link footer manually (the workflow's `generate_release_notes: true` adds it on first creation but doesn't preserve it on edits).

### Discord patch note

After each tag, the user expects a copy-paste Discord post in chat-summary style. The format matches the CHANGELOG stanza tone but compresses heavily (Discord's 2000-char limit). Lead with the headline change in **bold**, then a short feature list, then a `**Full Changelog**:` link. No emojis (the project rule applies). Patch releases get tighter posts than minor releases.

### Version numbering

- **Minor (`vX.Y.0`)**: new features, schema additions, sizeable changes. Earns a long-form CHANGELOG stanza with the headline-bullet format the v2.37.0 entry uses.
- **Patch (`vX.Y.Z` where Z > 0)**: fixes only, no new features, no schema-breaking changes. Shorter CHANGELOG stanza. Always safe-overwrite from the previous minor.

Schema additions are allowed in patch releases as long as they're additive and gated by `EnsureDB`'s nil-default pattern (existing saves auto-migrate, downgrade-safe). Schema *removals* require a minor bump.

For everything else, [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md) is authoritative.

## WoW tooling: the `wow` MCP server and the addon-architect agent

This machine has a `wow` MCP server (tools named `mcp__wow__*`) indexing the game's Lua
API, Blizzard's own shipped UI source, and the client's file and atlas data. Use it
rather than recalling the WoW API from memory. If those tools are deferred in your
session, load them in ONE `ToolSearch` call, not one per tool.

**Always pass `flavor: "forever"` explicitly.** The tools default to retail. Omitting the
flavor does not error - it silently answers for a client this addon does not run on.

That trap is sharper here than it looks. Forever runs a Mainline 12.1.x API surface, so a
retail answer is *usually* right, which is exactly what makes a wrong one hard to notice.
Measured from the indexed source: Forever exposes 279 `C_*` namespaces, 266 of them
shared with retail 12.1.0; 2 retail namespaces are absent and 13 are Forever-only. So the
`mainline` index is a fair cross-reference when Forever's data is thin, but confirm
against `forever` before writing anything into the addon. `vanilla` (Classic Era 1.15.x)
is a different client again - 74 namespaces short of Forever - and is not relevant here.

What to reach for:

- `wow_api_search`, `wow_api_event_search`, `wow_api_type_search`, `wow_api_diff` -
  confirm a function, event or type exists on Forever *before* writing the call.
- `wow_ui_list_packages`, `wow_ui_grep`, `wow_ui_read_file`, `wow_ui_template_search`,
  `wow_ui_mixin_search` - read how Blizzard implements a piece of UI before building it
  from scratch.
- `wow_lua_lint`, `wow_toc_validate`, `wow_xml_validate` - run before calling work
  finished; catches removed APIs and taint problems that otherwise only bite at runtime.
- `wow_file_search`, `wow_atlas_search`, `wow_icon_search` - resolve real texture and
  atlas paths. A wrong path fails silently in-game.
- `wow_data_status` - run this before concluding something does not exist; a data set may
  simply not be synced.

The **`wow-addon-architect`** subagent is installed user-level (`~/.claude/agents`), so it
is available in this repo. Hand it the deep API / Widget / Blizzard-reference questions:
"does X exist on Forever", "how does Blizzard implement Y", "why is this frame nil". It is
under standing orders never to state an API it has not verified, and to name the flavor it
checked.

Gotcha: if a tool reports a flavor as "not synced" immediately after someone synced it,
the server cached its index at startup. Restart Claude Code rather than re-running the
sync.

**This repo's luacheck gate has a hole this closes.** `RegisterEvent` takes a string, so
luacheck cannot tell a valid event name from an invented one - a file registering
`"THIS_EVENT_DOES_NOT_EXIST_ANYWHERE"` passes at 0 warnings. `wow_api_event_search` with
`flavor: "forever"` is the check the gate cannot perform. Use it on every new event name
before registering it, exactly as porting lesson 15 in
[docs/PORT_STATUS.md](docs/PORT_STATUS.md) requires. The same applies to `C_*` members
added to `.luacheckrc`: verify the member exists on Forever before declaring it, or the
gate will vouch for a call that returns nil.

### What these tools cannot tell you (measured 2026-09-19)

`wow_api_stats` reports Forever as **6577 functions, 1802 events, 1738 tables, 0 globals,
0 cvars**, explicitly flagged `no upstream source yet: globals, eventNames, cvars`. Retail
has 6832 globals and 1652 cvars indexed, so these gaps are Forever-specific - cross-
referencing `mainline` tells you about retail, not about this client. Four consequences,
each measured rather than inferred:

1. **`wow_lua_lint` does not check that a function exists on Forever**, and its
   known-removed-API check does not fire either. It emits `api/unchecked` saying upstream
   publishes no global function list. Its own note claims removed-API checks still run;
   measured, they do not: a file calling eight bare 3.3.5a globals that have all been
   namespaced on this client (`GetContainerNumSlots`, `GetContainerItemInfo`,
   `GetItemInfo`, `GetAddOnMetadata`, `IsAddOnLoaded`, `GetSpellInfo`, `SendAddonMessage`,
   `RegisterAddonMessagePrefix`) returns **0 errors, 0 warnings**. So do not use a clean
   lint as evidence that a migration is finished. What does fire, measured: `event/unknown`,
   `taint/protected-call`, `taint/combat-locked`, `global-frame-name`.
2. **`wow_cvar_search` comes back empty because the data is missing, not because the cvar
   is absent.** Never cite an empty result as evidence of absence.
3. **The event list is derived from Blizzard's generated documentation, not a shipped event
   list.** A miss means "not documented", not "not present". That has predicted client
   absence correctly every time it has been tested in-game so far, which makes it a strong
   prior - not proof.
4. **`wow_api_event_search` fuzzy-matches, and does not say when there is no exact hit.**
   `RUNE_UPDATE` does not exist on this client, yet the search returns real neighbours
   (`RUNE_TYPE_UPDATE`, `RUNE_POWER_UPDATE`, ...) with no warning. The result count is
   whatever `limit` you passed - the index is deterministic, so differing counts between
   runs are your limit, not instability. The rule is **exact name match**, never "the
   search returned something".

5. **A namespaced-only `wow_api_search` result is NOT evidence the bare global is gone.**
   With 0 globals indexed, a namespaced hit is the only thing the search *can* return,
   whether or not the legacy name still works. Measured: `wow_api_search("InCombatLockdown",
   forever)` returns exactly one result, `C_RestrictedActions.InCombatLockdown()`. In
   Blizzard's own shipped source that namespaced form appears **0 times**, while the bare
   global appears 14 times plus 4 file-scope self-captures (`local InCombatLockdown =
   InCombatLockdown`) in Blizzard_RestrictedAddOnEnvironment and UIParentPanelManager. The
   search result is inverted relative to actual usage. **The discriminator is a source grep,
   never the API search**: no bare usage in shipped source is evidence the global is gone;
   plenty of bare usage is evidence it is alive. Getting this backwards turns a working
   `X and X(...)` fail-open idiom into a phantom defect report.

**For event names, lint the file rather than searching each name.** `wow_lua_lint` on
flavor forever flags `RegisterEvent("RUNE_UPDATE")` and
`RegisterEvent("THIS_EVENT_DOES_NOT_EXIST_ANYWHERE")` as `event/unknown` by exact name,
and its message states the consequence: RegisterEvent throws for unknown events, which
aborts the calling function. That is strictly better than checking names by hand - there
is no result list to misread, and it reads every `RegisterEvent` in the source rather than
the ones someone remembered to check. Use `wow_api_event_search` for the payload signature
once the name is established. The lint still shares the limitation in consequence 3: it
removes the fuzzy-match failure, not the documentation-derived one.

The general shape: these tools are strong evidence of presence and weak evidence of
absence. Verified-present is near-certain; verified-absent is a strong prior that wants an
in-game check before anything irreversible depends on it.
