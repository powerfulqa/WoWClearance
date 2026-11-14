# Port status: 3.3.5a to WoW: Forever

Living document. Update it as each work item lands.

> **2026-11-14: public from v0.8.0.** The owner decided to publish. The
> repository was published fresh, so the commit hashes quoted in this
> file belong to the private port history and do not resolve here. File,
> suite and count figures inside dated entries are as they were on that
> date; the current ones are in [ARCHITECTURE.md](ARCHITECTURE.md) (36
> `.lua` files, 10 test suites). `docs/INGAME_VERIFICATION.md`, the
> in-game test protocol the entries below cite by phase and step, was the
> owner's own checklist and is not in this repository.

## What Forever is

WoW: Forever is the **retail (Mainline) client wearing a Classic version
number**. Per Meorawr (2026), Forever and modern WoW (Midnight) are two
game types within the Mainline code family: **Camelot** (Forever, to be
renamed before launch) and **Standard** (Midnight). Forever shares
Mainline's UI architecture and the vast majority of APIs available in
**12.1.5**.

Consequence: this is a Classic-to-Retail rewrite, not a version bump.
The 3.3.5a global API surface the original was written against is
absent.

| | |
|---|---|
| Project flag | `WOW_PROJECT_MAINLINE` |
| Interface | 16001 |
| Baseline capture | client 1.60.1 build 69893 |
| Tracks | Mainline 12.1.5 |

## Sources of truth

- **In-game verification is a written protocol, not an ad-hoc session.**
  `docs/INGAME_VERIFICATION.md` holds the ordered steps, the destructive
  warnings and the backup step. That file is the **method**; this file is
  the **record**. Findings go here, never there, so the protocol stays
  runnable.
- **`warcraft.wiki.gg` is not reliable for Forever.** A wiki maintainer
  has publicly confirmed FrameXML functions there are not updated to
  current standards. Example: `MouseIsOver` was removed on Forever
  (replaced by the `ScriptRegion:IsMouseOver` method) and the wiki page
  did not say so.
- FrameXML source: <https://www.townlong-yak.com/framexml/>
- What this client exposes: the captured API baseline in
  `Thunderz96/forever-addon-kit`, `data/forever_api.json`. Clone the kit
  yourself; do not trust a stale copy.

Watch for the global-to-method migration pattern: `MouseIsOver` to
`:IsMouseOver`, `GetMouseFocus` to `GetMouseFoci`. Both confirmed in the
baseline. Neither is used by this addon, but the pattern will recur.

## Porting lessons

Fifteen rules this port was taught the hard way, mostly by getting them
wrong first. Each one cost real time here or in the parallel BarWarden-Forever port
(same user, same client build), and each generalises past the specific API
that produced it. Read these before assuming anything about this client.

1. **A nil method means the name is wrong at least as often as the capability
   is missing.** Three guessed StatusBar method names being absent nearly
   triggered a full engine rewrite in the sibling port; the real API existed
   under a different name. Dump `getmetatable(frame).__index` and grep it
   before concluding absence. Calling an API with no arguments harvests its
   usage string, which names the expected types.

2. **A namespace vouches for nothing inside it.** `C_EquipmentSet` exists and
   has no `GetEquipmentSetItemIDs`; `C_Item` exists and has no
   `GetItemCooldownDuration`. Declared as a bare name in `.luacheckrc`, both
   lint clean and return nil at runtime. Declared with `fields`, luacheck
   catches them - see work item 3.

3. **Sometimes the approach is obsolete, not the name.** A 30-line
   localized tooltip walk for bind state collapses to reading `isBound` off
   the container table. Before porting a scanner, check whether the data is
   simply exposed now.

4. **A declared interface number is intent, not evidence of testing.** Both
   Forever-flavoured libraries inspected declare 16001; one contains no
   Forever-specific handling at all, and the other's own client detection
   misreads Forever as Vanilla.

5. **A guard can be non-vacuous in one direction and vacuous in the other.**
   A registration-completeness check here passed its own mutation test
   because its "is it registered" pattern also matched the name inside
   `CreateFrame("Frame", "NAME", parent)`. Proving a guard catches a known
   bad input, and separately that a known good input passes, does not prove
   the join. Mutate the SOURCE, not just the allowlist.

6. **Assertions phrased "does NOT use \<modern API\>" invert silently.**
   Two here were protecting bugs while passing. On a 3.3.5a-derived codebase
   this is a systematic category, not a one-off.

7. **Audit headers, not just assertions.** A stale TEST header talks someone
   back INTO a bug; a stale SOURCE header talks someone OUT OF a capability.
   Both in good faith, both citing documentation, both survive every test.
   When inverting an assertion, grep the header above it and the source
   file's header too.

8. **Seeing a member in a dump proves it EXISTS, not what it RETURNS.** The
   equipment-set probe listed `GetItemIDs` from the live namespace, and that
   got written up as "measured: returns an array of itemIDs". It had never
   been called - the probed character had no saved sets, so the branch that
   would have called it never ran. A probe answers exactly the question it
   executed. Check the probe's OUTPUT for the value, not just its member
   list, and treat an empty result as "not measured" rather than as
   agreement. Re-probing with a populated set showed the guess was wrong.

9. **When the shape is unmeasured, write the code that is correct under
   every candidate shape.** The same path shipped `ipairs` over a table the
   surrounding code already described as slot-keyed with `0`/`1` sentinels,
   i.e. sparse. `ipairs` truncates at the first gap; `pairs` is right either
   way and costs nothing. Where one option is correct under all hypotheses
   and another under only one, uncertainty is not a reason to guess - it
   decides the choice for you. The follow-up measurement made this concrete:
   the real table's lowest key was 5, so `ipairs` would have yielded nothing
   at all rather than merely truncating. The cautious choice was not
   over-caution; the confident one was simply wrong.

10. **A guard nobody has tried to defeat is not yet a guard.** `.luacheckrc`
    claimed that reaching for `GetEquipmentSetItemIDs` produced a lint error.
    True of `C_EquipmentSet.GetEquipmentSetItemIDs`; false of the bare
    `GetEquipmentSetItemIDs(name, buf)`, still declared in `read_globals` -
    and the bare form is the spelling the old code used, so it is the
    spelling a reintroduction would take. Write the offending line and run
    the linter. Doing that here failed the gate on a real, shipped bug in
    `/wc bugreport` that had been silent since the port began.

11. **Every check here points at a surface someone chose in advance, and
    the string-resolved surfaces have no check at all.** The API capture
    covers globals and namespaces; the luacheck `fields` trick covers `C_`
    members. Neither sees a **widget method**, an **XML template name**, an
    **event name**, or a **return shape** - and what those four have in
    common is that they are resolved from a STRING at runtime, so no static
    tool can see them and no member dump enumerates them. Three of the four
    have already produced silent failures in this port or its sibling. Treat
    "the suites pass" as covering what is nameable at parse time and nothing
    else.

12. **A control that is confidently wrong is worse than no control,
   because it is believed.** Every probe on this machine carried an
   `isColdStart` field built on `GetTime()`, which counts from system boot
   rather than client launch. It reported "reload-level only" 34 seconds
   into a genuine cold start, and three ports reasoned from it for hours
   while the capture that answered the question sat on disk mislabelled.
   The guard discarded the very evidence it existed to find. When a
   control cannot be made reliable - and nothing inside the client
   separates a reload from a relaunch - **delete it rather than
   recalibrate it**, record the raw observation, and establish the fact
   from outside.

13. **A retraction is a message; an assertion is an object. Only objects
   get read later.** Corrections made in conversation while the claim
   stays written down do not survive the conversation. This bit us twice
   in one session: `GetCoinTextureString` was corrected in one place and
   left contradicted in two summaries, and a stale contract header argued
   a contributor back into a bug that had already been fixed. When you
   retract something, grep for every place it is asserted and fix the
   artefacts, not just the discussion. This rule is why the sibling ports'
   findings are written here rather than left in the session that found
   them.

And one design rule, which matters most where this addon can destroy things:

14. **A refused read is not an absent value, and you must fail in the
   direction that preserves the safe state.** Absence means the scan
   finished; refusal means it never ran and you know nothing. For a bag
   manager that means refusing to act rather than acting on incomplete
   information - a protection that cannot be evaluated must never read as
   "no protection found", because the consequence is selling gear. Does not
   currently arise (item and container data are measured plain under combat
   lockdown, and this addon reads no auras), but it is the default if the
   restricted surface ever widens.

15. **A gate that passes because it cannot see is indistinguishable, from
   the outside, from a gate that passed because the code is correct.**
   `RegisterEvent` takes a STRING, so no general-purpose Lua linter can
   know the name is wrong. Verified here: a file containing
   `RegisterEvent("THIS_EVENT_DOES_NOT_EXIST_ANYWHERE")` passes our own
   `luacheck` gate at 0 warnings / 0 errors. That is not a hole in
   `.luacheckrc` to be patched, it is structural, and it is how a
   load-breaking bad event name sat in a 7,720 line file behind a green
   CI gate.

   The WoW-specific linter DOES check event names against a per-flavour
   index, and flags exactly this with the right reason. All 18 events this
   addon registers were swept against the Forever index and are clean, so
   the one that was fixed was the only one. Before adding an event, lint
   the name; do not reason about whether it "looks modern".

   The transferable half is not about events. It is that a checker should
   say what it did NOT check. The WoW linter emits an explicit note that
   unknown-FUNCTION checks are off for this client, so a clean run cannot
   be misread as "everything here was verified". Our luacheck gate emits
   nothing, because it does not know there is anything to check, and it is
   the silent kind that produced the bug. When adding a gate, make its
   blind spot part of its output, and never let it return green on an
   empty input (lesson 5).

16. **`DeleteCursorItem` is protected: an addon cannot delete on its own.**
   MEASURED 2026-10-10, build 1.60.1.70291: auto-delete-on-pickup, running
   from the BAG_UPDATE debounce, raised `ADDON_ACTION_BLOCKED` "AddOn
   'WoWClearance' tried to call the protected function
   'DeleteCursorItem()'" (`WoWClearance_Events.lua:4828`), left the item
   on the cursor, and the next bag flush tried again, a loop. The docs
   mark it `HasRestrictions` (`GameCursorDocumentation.lua:56`), the same
   flag as `SendChatMessage`, and so does `C_Item.DeleteItem`. The 3.3.5a
   design (delete from a timer, auto-confirm Blizzard's popup) cannot work
   here. Deleting now runs only inside the player's key press or click
   (`WoWClearance_DeleteNext`, bound to a key and a Delete List button),
   behind a guard in `executeBagSlotDelete` pinned by Test 143d.
   MEASURED the same day: the Delete Next BUTTON (an addon OnClick)
   deleted a green item with no popup and no error. So the restriction is
   "inside a hardware event", not "Blizzard code only". The key binding
   path is expected to behave the same; not yet measured.

## Work items

| # | Item | Status |
|---|---|---|
| 1 | Rebrand to WoWClearance | **Done** (v0.1.0) |
| 2 | Remove the Project Ebonhold subsystem | **Done** |
| 3 | Move test mocks to the Retail API | **Done** |
| 4 | Container and item layer | **Done**; equipment sets ported, one return shape still unmeasured |
| 5 | Options UI migration | **Done** |
| 6 | Long tail | **Done** (colour picker cancel payload measured; equipment sets ported) |
| 7 | `WoWClearance_RealmComms.lua` | **Rebuilt (owner's decision, 2026-10-10)**; transport unmeasured in game |

### 1. Rebrand (done)

All 36 `.lua` files, the `.toc`, `Bindings.xml`, both SavedVariables
globals, the `WC_` prefix, the `WC-TRAP:` marker, `/wc` and `/wcdebug`,
the provenance globals, the fingerprint salt, and the four wire/export
identifiers (`WCLR1`, `WC:`, `WC_PACK_V1`, channel `wowclearance`). All
All invariant suites passed unchanged afterwards (11 today; the count
fell as the Project Ebonhold suites went with that subsystem).

### 2. Remove Project Ebonhold (done)

Originally scoped as "switch it off and delete later". Changed to a
surgical removal on the maintainer's instruction, so the kill switch below
was temporary scaffolding: it kept the features off while the code came out
in stages, and went with the last of the affix surface.

Staged, suites green and luacheck clean at every stage:

| Stage | Scope | Status |
|---|---|---|
| A | Chance-on-hit proc-pairing guild share (`ProcShare`) | Done |
| B | Greedy Scavenger + Goblin Merchant companions, loot-cycle engine, merchant-target mode | Done |
| C | `Decision.lua` affix / proc branches | Done |
| D-F | Affix core in `Protection.lua`, Events, panels, tooltip, bag display, bug report, tests | Done |

About 12,000 lines came out in total. Stage B was roughly 3,000 lines, including the whole
four-state loot-cycle engine (`IDLE` / `LOOTING` / `WAITING_MERCHANT` /
`SELLING`) that existed to swap the Scavenger for the Goblin Merchant at
bag-full. Two files were deleted outright and two suites' worth of
companion coverage went with them.

Things deliberately kept, each verified independent rather than assumed:
Fast Loot and auto-open containers (stock looting, self-gating), free-bag-slot
counting (minimap + bug report), the general-purpose `WC_Delay` timer, the
profession-cast spell set (Process Bags counters), and the decision core's
`junkOnly` parameter (a core concept with its own safety fixtures; nothing
sets it true now, but a greys-only mode is a plausible future use).

#### Two traps this surfaced

Both are the same shape: a flag or widget looks Project Ebonhold-owned
because of where it sits, not because of what it does.

1. `hideGreedyChat` / `hideGreedyBubbles` carried a WC-TRAP saying "do NOT
   delete these or the Companion read-sites". `Companion.lua` **was** the
   read-site, so the trap's premise died with it and the flags went.
2. `protectHiILvlCB` sat inside the affix widget run on the Protection
   panel, but `DB.automarkProtectHighILvl` also gates the Resilience and
   learned-recipe auto-mark scans, which survive. Deleting it with its
   neighbours would have left a live setting unreachable from the UI, so it
   was re-created outside the run with a comment recording why.

Reading a WC-TRAP's pointer rather than its headline is what caught both.

#### The kill switch (removed in the final stage)

The affix / chance-on-hit subsystem was already gated behind two
predicates, `peFeaturesActive()` and `peFeaturesVisible()`, at 22 sites
across 12 files. Both now hard-return false from a single auditable kill
switch in `WoWClearance_Protection.lua`:

```lua
WC_compCache.PE_SUBSYSTEM_ENABLED = false
```

The switch is the **first** statement in both predicates. In
`peFeaturesActive` that puts it ahead of the `peSurfacesSeen` latch, which
otherwise goes true once and sticks. In `peFeaturesVisible` it is repeated
rather than left to the delegation, so the UI gate does not depend on the
functional gate's body. `tests/test_affix_resilience.lua` pins all three
facts (switch present and `false`, first statement in each predicate);
both conditions were mutation-tested. All 13 suites pass.

**The dead subsystem is still deleted incrementally AFTER the port works,
not during.** The predicate bodies and the surrounding invariants are the
specification that deletion gets checked against, which is why the switch
is a switch and not a `rm`.

#### Consequence worth a decision later

Turning the subsystem off force-disables `protectChanceOnHitItems`, which
defaults ON. That setting is a *protection*, and its detector is generic:
`itemHasChanceOnHit` is a tooltip scan that matches ordinary weapon procs
(Felstriker, Frostguard and the like), not anything Ebonhold-specific.
What *is* Ebonhold-specific is its release path - the protection means
"keep this until you extract the proc at the Anvil", and off Ebonhold
there is no Anvil, so leaving it on would wedge every proc weapon in bags
with no way out. Disabling it is therefore correct as written.

The open question is a product one, not a port one: **should Forever have
a plain "never auto-sell a weapon with a chance-on-hit proc" protection,
with no extraction concept attached?** Until that is decided, chance-on-hit
weapons on Forever are covered only by the ordinary rules (quality
threshold, iLvl ceiling, equipped, Keep List, blacklist). No player is
regressed by this - WoWClearance has no installed base - but it is a real
reduction against what EbonClearance did.

### 3. Test mocks (done)

Two pieces, and the second turned out to be free.

**The locale code-token guard, re-framed rather than inverted.**
`tests/test_locale_integrity.lua` forbade `C_Timer` / `C_Container(` /
`C_Item.` / `C_AddOns.` as a "3.3.5a-safe" rule. It was already scoped to
the locale templates, and its real subject was never the engine: a
`C_Container(` inside a French translation string is a paste accident on any
client. So the framing went, the list stayed, and it gained the 3.3.5a
globals it never covered plus `CreateFrame(`.

**The Retail surface is declared with explicit member lists, which gives
the API-surface guard for free.**

luacheck's `read_globals` vouches for a global's EXISTENCE and nothing about
its members. Declared bare:

```lua
read_globals = { "C_Item" }
```

the call `C_Item.GetItemCooldownDuration(123)` lints clean, ships, and
returns nil at runtime. Declared with `fields`:

```lua
read_globals = { C_Item = { fields = { "GetItemInfo", ... } } }
```

luacheck reports `accessing undefined field` and the **existing CI lint gate
catches it**. No vendored member list, no generator, no second tool.

The sharp case is `C_EquipmentSet`, declared with its two real members and
deliberately WITHOUT `GetEquipmentSetItemIDs`. The namespace is present on
Forever and so are its siblings, but that member is not - measured, not
assumed - and it is what this addon's gear-set rescue cache was built on.
Reaching for it now produces a lint error rather than a silent nil.

**Rule for that block: a member goes in only when it has been seen on the
live client or in the `forever_api.json` baseline.** Adding one on the
strength of a wiki page or a third-party shim table defeats the guard.

The 3.3.5a globals stay declared alongside until work item 4 ports their
call sites; the two surfaces coexist during the migration.

`tests/test_api_surface.lua` (new, 11th suite) pins the mechanism. It loads
the real `.luacheckrc` as Lua and inspects the resulting table rather than
regex-matching it, asserts each namespace carries a non-empty `fields` list,
asserts the two measured-absent members are not listed, and asserts a member
that DOES exist still is - so the guard cannot pass vacuously in either
direction. Mutation-tested: degrading one namespace to a bare name fails two
checks.

### 4. Container and item layer

Roughly 190 call sites fed by roughly 23 `local X = X` upvalue-caching
lines at file tops. That is the chokepoint where the compatibility layer
goes.

Done. Two shapes of change, kept separate on purpose.

**Pure renames went through the cached-upvalue chokepoint.** Files that
already cached a global had the right-hand side repointed
(`local GetItemInfo = C_Item.GetItemInfo`); files that called it bare gained
a cache line, which is also this codebase's documented convention for hot
paths. One line per file per API, ~190 call sites unchanged.

**The two return-shape changes were converted at the call site**, not hidden
behind a shim that re-creates the old form:

- `GetContainerItemInfo` returned 7 positional values; the replacement
  returns a single table, or **nil for an empty slot**. All 19 call sites
  became an explicit table read with a nil guard. Field mapping, measured:
  `texture`->`iconFileID`, `itemCount`->`stackCount`, `locked`->`isLocked`,
  `quality`->`quality`.
- `GetSpellInfo` returned positional values; the replacement returns a
  table with no `rank` field at all. All 7 sites wanted the name, so one
  helper (`WC_compCache.spellName`) wraps the table read.

`IsSpellKnown` was neither: its replacement takes a spell bank and a pet
flag, so it became `WC_compCache.spellKnown` over
`C_SpellBook.IsSpellInSpellBook(id, Enum.SpellBookSpellBank.Player, false)`.

`GetNumPartyMembers` / `GetNumRaidMembers` are gone with no drop-in: the
replacements count the player where the old pair did not, so the four sites
became `IsInRaid()` / `IsInGroup()` predicates, which is what they were
actually asking.

#### Equipment sets (ported and measured, 2026-09-18)

All three 3.3.5a globals (`GetNumEquipmentSets`, `GetEquipmentSetInfo`,
`GetEquipmentSetItemIDs`) are nil. The replacements, measured against a real
saved set:

| Call | Returns |
|---|---|
| `C_EquipmentSet.GetEquipmentSetIDs()` | dense array of set IDs; IDs are **zero-based** (one saved set came back as `{ [1] = 0 }`) |
| `C_EquipmentSet.GetItemIDs(setID)` | table keyed by equipment **slot**, **sparse**; a 9-item set gave keys 5,6,7,8,9,10,15,16,18 |
| `C_EquipmentSet.GetEquipmentSetInfo(setID)` | **positional** values, not a table: `name, iconFileID, setID, isEquipped, ...` |

Two of those bit, and the first one nearly shipped.

**`GetItemIDs` is sparse, and the first port iterated it with `ipairs`.**
The intuition that this truncates understates it. The lowest slot key in the
measured set was **5**, so `ipairs` finds `nil` at index 1 and yields zero
iterations: not a partial protection failure but a total one, on every
character, with no error. Unprotected gear is gear this addon will sell.
`#t` is equally unsound here, reporting 10 for that 9-entry table. The call
site now uses `pairs` and `next()` and carries a `WC-TRAP:`.

The zero-based IDs are the trap's second door: `C_EquipmentSet.GetNumEquipmentSets`
exists, so `for i = 1, GetNumEquipmentSets()` reads as a tidy equivalent and
silently skips set 0, the only set a one-set character has.

`GetEquipmentSetInfo` returning positionally is worth knowing even though
nothing calls it: a `C_` prefix on this client does not imply the
table-returning convention that `C_Container.GetContainerItemInfo` and
`C_Spell.GetSpellInfo` established.

Unused slots are **absent** rather than stored as the 3.3.5a `0` sentinel.
`protectEquipmentSetItem`'s `> 1` guard is kept anyway: the sampled set had
no ignored slots, so whether an ignored slot still yields `1` is unmeasured,
and the check is free.

**A second bug fell out of this.** Removing the three dead globals from
`.luacheckrc` (they had been left declared, which made the "reaching for
`GetEquipmentSetItemIDs` is a lint error" guard vacuous for the bare
spelling) immediately failed the lint gate on
`WoWClearance_BugReport.lua:293`, which called bare `GetNumEquipmentSets`
behind an `and` guard. It had been reporting `Equipment Sets Saved: 0` on
every Forever client since the port began, which also meant the
"`Saved > 0` with an empty cache" hint documented directly above it could
never fire. It now reads `n/a` when the API is absent.

#### Positional-destructuring audit (done, clean)

The BarWarden-Forever port found a call site of its own reading position 7 of
`GetSpellInfo` as a spell ID when position 7 was `castingTime` - a bug that
predated its port and would have been silently "fixed" by moving to the table
form, hiding the fact it had ever been wrong. Worth checking rather than
assuming the 3.3.5a code was right.

Audited here against the 3.3.5a signature (1 name, 2 link, 3 quality,
4 iLvl, 5 minLevel, 6 type, 7 subType, 8 stackCount, 9 equipLoc, 10 texture,
11 sellPrice):

- **`GetItemInfo`, 143 uses, ~20 distinct destructuring shapes: all correct.**
  Every `_`-skipped position lines up with the field the variable is named
  after.
- **`GetSpellInfo`, 7 uses: all read position 1 only** (the spell name).
  Nothing touches the removed `rank` at position 2.

So the work item 4 rewrite is a pure mechanical mapping with no latent
positional bugs to preserve or accidentally paper over. That is a useful
thing to know *before* starting, because it means any behaviour change that
shows up afterwards came from the port, not from something that was already
broken.

Note for the rewrite: a shim table maps **names**, and cannot know which of
two overloads a call site needs. `GetItemIcon` is the example - both
`C_Item.GetItemIcon` and `C_Item.GetItemIconByID` exist, but only the former
is polymorphic over ID / link / name. That is an argument for converting at
the call site rather than republishing globals.

### 5. Options UI migration (done)

17 panels: one root plus 16 subcategories. Four things changed.

**Host frame.** `InterfaceOptionsFramePanelContainer` is absent;
`SettingsPanel.Container` replaces it (measured 665px beside a 199px
category list). Resolved through `NS.OptionsHost()` at call time rather than
captured at file load, because this addon's panel files run during
ADDON_LOADED and `SettingsPanel` may not be constructed yet. Falls back to
`UIParent` so a panel frame is never parented to nil, which would make
`CreateFrame` throw and take out the rest of the file.

**Registration.** `Settings.RegisterCanvasLayoutCategory` for the root, then
`Settings.RegisterCanvasLayoutSubcategory` per panel. Two rules that are easy
to get wrong, both from the BarWarden-Forever port's measurements:

- a subcategory takes the parent **category object**, not a `.parent` name
  string as on 3.3.5a;
- a subcategory must **not** also be passed to `RegisterAddOnCategory`, or
  every section lists itself as a separate addon in the sidebar.

Sidebar order is still call order, so the 15 ordered subcategories moved into
an explicit list in `WoWClearance_Events.lua` with the original grouping
rationale kept as a comment. Help still self-registers, because it loads
after Events per the `.toc` and so cannot join that list - which is also what
keeps it last in the sidebar.

**Opening a panel.** `Settings.OpenToCategory` takes a **category ID, not a
frame**, so `NS.RegisterOptionsSub` records a frame-name -> category-ID map
and `NS.OpenOptionsPanel(frameName)` reads it. That preserved the existing
calling convention, so the migration touched registration rather than the
~20 call sites that open panels by frame name.

**A WC-TRAP retired rather than ignored.** `NS.OpenOptionsPanel` and
`NS.OpenHelpEntry` each called `InterfaceOptionsFrame_OpenToCategory`
**twice**, with a marker saying not to dedupe: on 3.3.5a the first call only
registered the category and the second focused it. The trap's premise was a
bug in a function that no longer exists, and `Settings.OpenToCategory`
re-opens the panel if called twice. Single call now.

`InterfaceOptionsFrame:Hide()` became `SettingsPanel:Hide()`.

#### Test invariant, and a vacuous guard caught by mutation

A new check asserts every `WoWClearanceOptions*` frame a panel file creates
is registered somewhere - the failure mode is silent (the panel exists in
memory and simply never appears in the sidebar, with no error). 3.3.5a made
this greppable with one call per panel; the new shape splits it across a
root, an ordered list and one self-registration, so the check re-establishes
that.

The first version of it **passed the mutation test**, i.e. it was worthless:
the "is it registered" pattern `"NAME",` also matched the name inside
`CreateFrame("Frame", "NAME", parent)`, so every created frame looked
registered. Anchoring the list form to the start of a line fixed it. Worth
recording because the companion check ("did the scan find any frames at
all?") did **not** catch this - a guard can be non-vacuous in one direction
and vacuous in the other.

### 7. RealmComms: rebuilt on addon messages (2026-10-10)

The owner chose to keep "Stats - Server" and rebuild its transport. The
3.3.5a version posted chat TEXT with `SendChatMessage` on a hidden channel
joined by `JoinChannelByName`. On Forever that could not work: channel text
needs a hardware event, so a timer-driven send is blocked
(`ADDON_ACTION_BLOCKED`, `HasRestrictions` on `SendChatMessage`), and
`CHAT_MSG_CHANNEL` is secret in a chat lockdown, which the old receive path
compared unguarded. The Refresh button also joined without opt-in, and
opting out never left the channel.

Now: `C_ChatInfo.SendAddonMessage(prefix "WCLRS", ..., "CHANNEL", n)` on a
**temporary** custom channel (`JoinTemporaryChannel`), received on
`CHAT_MSG_ADDON` with `canaccessvalue` and `channel == "CHANNEL"` checks;
sends wait out `InChatMessagingLockdown`; the join waits while `/1` is
empty; opting out calls `LeaveChannelByName`; nothing joins or sends unless
`shareServerData` is on. Facts it rests on (wow-forever-api skill, chat
reference): addon messages on a custom channel deliver (2026-09-19); a
channel reaches **only your own underlying realm** (2026-10-07), so
"realm-wide" is one realm copy and `Success` comes back either way;
permanent channels keep their `/N` between sessions.

Still unmeasured: the join, the echo used by `/wc realmtest`, and the
lockdown behaviour on this transport. Shipping it on a live realm remains
the owner's call; it is default OFF and opt-in.

## API mapping

### Absent on Forever

These are the absent GLOBALS. Several have a namespaced replacement that
IS present, listed under "Replacements measured in-game" below - notably
`GetCoinTextureString`, whose replacement `C_CurrencyInfo.GetCoinTextureString`
is measured present and already in use. **"The global is absent" and "the
capability is absent" are different claims**, and a reader who stops at this
list will conflate them (lesson 13).

`GetItemInfo`, `GetContainerItemInfo`, `GetContainerNumSlots`,
`GetContainerItemLink`, `GetContainerItemID`,
`GetContainerNumFreeSlots`, `GetSpellInfo`, `GetSpellLink`,
`SendAddonMessage`, `GetAddOnMetadata`, `GetAddOnInfo`,
`GetNumSpellTabs`, `GetSpellTabInfo`, `GetNumPartyMembers`,
`GetNumRaidMembers`, `GetCoinTextureString`, `OpenColorPicker`,
`InterfaceOptions_AddCategory` (18 uses),
`InterfaceOptionsFrame_OpenToCategory` (6 uses), `InterfaceOptionsFrame`,
`InterfaceOptionsFramePanelContainer`, `OpacitySliderFrame` (2 uses).

### Verified present (the replacements)

`C_Container.GetContainerItemInfo` / `.GetContainerNumSlots` /
`.GetContainerItemLink` / `.GetContainerItemID` /
`.GetContainerNumFreeSlots` / `.UseContainerItem` /
`.PickupContainerItem`; `C_Item.GetItemInfo` / `.GetItemCount` /
`.GetItemInfoInstant`; `C_Spell.GetSpellInfo` / `.GetSpellLink` /
`.GetSpellCooldownDuration`; `C_ChatInfo.SendAddonMessage`;
`C_AddOns.GetAddOnMetadata` / `.GetAddOnInfo`;
`C_SpellBook.GetNumSpellBookSkillLines` / `.GetSpellBookSkillLineInfo`;
`C_EquipmentSet.GetNumEquipmentSets` / `.GetEquipmentSetInfo`;
`GetNumGroupMembers`, `IsInRaid`, `IsInGroup`; `SettingsPanel` (frame),
`ColorPickerFrame` (frame), `CreateSettingsListSearchCategoryInitializer`.

### Genuine gap

`C_EquipmentSet.GetEquipmentSetItemIDs` does **not** exist even though
the namespace does and the other two equipment-set calls do. This is a
real gap, not a capture artefact.

## Cleared

- **Menus.** The bag context menu's legacy `UIDropDownMenu` API is fully
  present: `UIDropDownMenu_Initialize` / `_CreateInfo` / `_AddButton` /
  `_SetWidth`, `ToggleDropDownMenu`, `CloseDropDownMenus`, and the
  `DropDownList1` frame. (`EasyMenu` is absent but unused here.)
  **Caveat:** these are Blizzard's legacy shims, deprecated on Mainline
  since 11.0. They work today; do not build new menu code on them, and
  expect to migrate to `MenuUtil` eventually.
  **Superseded (v0.6.0):** "present" was not "safe". On Forever,
  `UIDropDownMenu_*` writes shared globals and is a measured cause of
  `ADDON_ACTION_BLOCKED` on the action bars in combat, and an addon-opened
  `Menu` / `MenuUtil` menu crashed the client (both measured September 2026
  by the sister ports; wow-forever-api skill, taint reference). Every
  settings dropdown now uses the home-made `NS.MakeSelector`
  (`WoWClearance_PanelWidgets.lua`), and the dropdown globals are no longer
  declared in `.luacheckrc`, so reintroducing one fails the lint gate. Do
  not migrate to `MenuUtil` without a fresh in-game test.
- **Popups.** `StaticPopup_Show` and `StaticPopup_Hide` are present,
  covering 46 uses.
- **Secure code.** No `WrapScript` / `RunAttribute` /
  `RegisterStateDriver` / `initialConfigFunction` / `_onstate-*`. The
  three `SecureActionButtonTemplate` buttons only set `type` and
  `macrotext` attributes, which still works. (Forever has a Blizzard bug
  where secure snippets cannot compile; it does not affect us.)
- **No version-check trap.** The `select(4, GetBuildInfo()) >= 100000`
  idiom that breaks most Retail addons on Forever appears nowhere.

## In-game probe results (2026-09-18)

Captured on the live client with a throwaway `WCProbe` addon (build
**1.60.1.69913**, Interface 16001, `WOW_PROJECT_MAINLINE`). SavedVariables
**writes** work on Forever - only the read-back is broken - so a probe can
dump its findings to
`WTF/Account/<id>/SavedVariables/WCProbe.lua` and be read off disk.

### The blind spot is resolved: both are PRESENT

`forever_api.json` captured global functions, `C_*` namespaces and frames,
but not plain global tables, which is why these read as absent. They are not.

| Symbol | Result |
|---|---|
| `Settings` | **table** |
| `Settings.RegisterCanvasLayoutCategory` | **function** |
| `Settings.RegisterAddOnCategory` | **function** |
| `Settings.OpenToCategory` | **function** |
| `Settings.CreateCheckbox` | **function** |
| `SettingsPanel` | **table** |
| `MenuUtil` | **table** |
| `MenuUtil.CreateContextMenu` | **function** |

**Work item 5 is unblocked.** `Settings.RegisterCanvasLayoutCategory` is
the registration target, and `Settings.OpenToCategory` replaces
`InterfaceOptionsFrame_OpenToCategory`.

### Secrets: RESOLVED. Item and container data stay readable in combat

`C_Secrets` (table) and `issecretvalue` (function) both exist, so the
machinery is present. Out of combat, every field the decision path reads came
back **plain**: `itemID`, `hyperlink`, `quality`, `stackCount`, `isLocked`
from `C_Container.GetContainerItemInfo`, and name / link / quality / iLvl
from `C_Item.GetItemInfo`. Tooltip line text is a plain string too.

**And now measured in combat too**, under lockdown, on 2026-09-18 at
16:42:44 (build 1.60.1.69913):

| | |
|---|---|
| `verdict` | `valid - sampled under lockdown` |
| `inCombatLockdown` | `true` |
| `itemID` / `stackCount` / `quality` | `plain(number)` |
| `hyperlink` | `plain(string)` |
| `isLocked` / `hasNoValue` | `plain(boolean)` |
| `C_Item.GetItemInfo` name / link / quality / iLvl | all plain |
| `C_TooltipInfo` line text | `plain(string)` |

**The sell/keep/delete core is safe, in and out of combat.** The BAG_UPDATE
scanners and auto-delete-on-pickup keep evaluating under lockdown; they do
not silently stop.

#### Why this result is trustworthy where the first one was not

The first write-up here **overclaimed**: it sampled at `PLAYER_LOGIN`, out of
combat, and stated the result generally. The correction came from the
BarWarden-Forever port (same user, same build), which measured the
transition directly: **the secrecy gate follows `InCombatLockdown()`, not
`PLAYER_REGEN_DISABLED`,** and the two are about three seconds apart.
Sampling on the event shows everything unrestricted; sampling three seconds
later, under lockdown, flipped `ShouldAurasBeSecret()` /
`ShouldCooldownsBeSecret()` to true, made 109 of 109 probed spell IDs
secret, and made 40 of 40 `GetAuraDataByIndex` calls throw. Two earlier runs
there reported "not secret in combat" and were taken too early.

The sample above is only worth anything because it **proves it was under
lockdown when it read**: the probe fires on `PLAYER_REGEN_DISABLED`, defers
three seconds, and asserts `InCombatLockdown()` inside the sample body,
recording `DISCARDED` rather than a value if that fails. A result without
that guard is not evidence.

#### The wider conclusion

**Secrecy is scoped, not global.** Auras, cooldowns and unit stats sit behind
the gate; item and container data does not. That is evidence the disarmament
rules target combat *decision-making* rather than addon data access
generally.

The rule for this port: **do not infer that one subsystem is restricted
because another is, in either direction.** Measure the specific surface, and
re-check after a major content patch.

#### The gate predicates, and what they do NOT cover

A second lockdown run (2026-09-18 17:24:13, same guard, `verdict = valid`)
read the gate predicates themselves. They live on `C_Secrets`, not as bare
globals - an earlier probe here called them bare, got nothing, and the
silence was briefly written up as "these do not exist on this client". That
was a probe bug reported as a finding. Corrected:

    C_Secrets.ShouldAurasBeSecret()          true
    C_Secrets.ShouldCooldownsBeSecret()      true
    C_Secrets.ShouldSpellAuraBeSecret(6603)  true

All three true under lockdown, matching the BarWarden-Forever port's numbers
from a separately-tainted addon.

**And yet, in the same sample:**

    C_Item.GetItemCooldown -> start     plain(number)
                              duration  plain(number)
                              enable    plain(boolean)
    C_Spell.GetSpellCooldownDuration    plain(userdata)

So **`ShouldCooldownsBeSecret()` being true does not mean every
cooldown-shaped read is gated.** Item cooldowns come back as plain numbers,
and the spell-side duration object is a plain `userdata` - opaque, which is a
different thing from secret: Lua can hold it and pass it to a widget, it just
cannot read the number out.

The shape across every measurement so far: secrecy gates the **values an
addon could make combat decisions from** - aura data, the numeric state
behind a cooldown display - while leaving item-side reads and opaque handles
alone. That is consistent with the item/container result above and with the
BarWarden port's observation of a StatusBar visibly filling while
`GetValue()` stays 0.

Incidental: `enable` is a **boolean**, not 3.3.5a's 1/nil.

### Container item field list (work item 4)

`C_Container.GetContainerItemInfo(bag, slot)` returns a table with exactly:

```
hasLoot, hasNoValue, hyperlink, iconFileID, isBound, isFiltered,
isLocked, isReadable, itemID, itemName, quality, stackCount
```

Mapping from the 3.3.5a seven-value return, confirmed against the live
client rather than the wiki:

| 3.3.5a (positional) | Forever (table field) |
|---|---|
| `texture` | `iconFileID` |
| `itemCount` | `stackCount` |
| `locked` | `isLocked` |
| `quality` | `quality` |
| `readable` | `isReadable` |
| `lootable` | `hasLoot` |
| `link` | `hyperlink` |

`itemName`, `isBound`, `isFiltered` and `hasNoValue` are new and have no
3.3.5a counterpart. Note `hasNoValue` directly answers "would the vendor pay
for this", which the addon currently derives from `sellPrice`.

### Two findings that broke this addon on Forever (both now FIXED)

Both came from the BarWarden-Forever port's probe runs, were verified against
this codebase, and are fixed as of work item 6.

**1. `C_ChatInfo.RegisterAddonMessagePrefix` is mandatory, and its absence
fails silently.** On 3.3.5a, filtering `CHAT_MSG_ADDON` by prefix was the
whole job. On Forever the client never delivers the event for an unregistered
prefix. `WoWClearance_Comms.lua` said so explicitly in its own header ("No
RegisterAddonMessagePrefix (4.0+): filter CHAT_MSG_ADDON by prefix"), so a
pure API rename would have left the comms layer looking correct and doing
nothing: version alerts, guild share and the `WCLR1` transport all quiet, no
error.

**Fixed:** the prefix is registered at load, before the `CHAT_MSG_ADDON`
listener is attached, with the result recorded on `Comms.prefixRegistered`.
The test that asserted the ABSENCE of that call is inverted, with the reason
written at the assertion. Note this does NOT apply to
`WoWClearance_RealmComms.lua`, which rides a hidden chat channel rather than
addon messages; its "no prefix registration" assertions remain correct.

**2. `RegisterEvent` THROWS on an unknown event name, and the throw aborts
the rest of the file.** `WoWClearance_Events.lua` registers
`PARTY_MEMBERS_CHANGED`, which the BarWarden probe measured as **rejected**
on this client. That is not a silent degradation: the throw takes out every
registration after it in the same main chunk. `RAID_ROSTER_UPDATE`, which
looks equally retired, was measured as still **accepted** - so this cannot be
reasoned about from age, only measured. Known rejected:
`UNIT_COMBO_POINTS`, `PARTY_MEMBERS_CHANGED`, `RUNE_UPDATE`.

**Fixed:** both group events collapse into `GROUP_ROSTER_UPDATE`, which is
live on this client and covers party and raid. The channel is now chosen from
the group state (`IsInRaid()` / `IsInGroup()`) rather than from which event
fired. The old code's comment asserted that `GROUP_ROSTER_UPDATE` "is 4.0+
and must not be used here", which was exactly inverted.

Neither was caught by the headless suites - both needed the live client, and
both were reported rather than discovered here.

### Replacements measured in-game by the BarWarden port

- `OpacitySliderFrame` -> `ColorPickerFrame:GetColorAlpha()`, shown via
  `ColorPickerFrame:SetupColorPickerAndShow{r,g,b,opacity,hasOpacity,swatchFunc,opacityFunc,cancelFunc}`.
  **The alpha is NOT inverted** the way the 3.3.5a slider was (where 0 meant
  opaque), so a direct port of the old handler inverts every alpha.
- `InterfaceOptionsFramePanelContainer` -> `SettingsPanel.Container`,
  measured 665px wide beside a 199px category list. That is the width source
  `PanelInfra` needs.
- `InterfaceOptionsCheckButtonTemplate` still exists (so does
  `UICheckButtonTemplate`); both name their label `$parentText`.
- `Settings.OpenToCategory` is a **single** call. The 3.3.5a double-call was
  a workaround for a bug this client does not have; calling it twice re-opens
  the panel. This addon has 6 double-call sites.
- `RegisterCanvasLayoutSubcategory(parentCategory, frame, name)` takes the
  parent **category object**, not a `.parent` name string, and must not also
  be passed to `RegisterAddOnCategory` or every section lists as its own
  addon.
- `GetChecked()` returns a **boolean**, not 1/nil. (Checked: this codebase
  has no `== 1` comparisons, so it is unaffected.)

### Third-party libraries: reference only, never a dependency

`~/Downloads/WoWLibs/` holds ~98 retail libraries. **None of them
becomes a dependency of this addon.** "No external libraries, all Blizzard
APIs" is a standing project rule with its own decision record (see
`docs/ADDON_GUIDE.md` on not embedding Ace3), and nothing found here changes
that calculus: the useful content is a handful of API mappings, not
functionality worth taking a dependency for.

Two of the 98 declare Interface **16001**, i.e. they have actually been
touched for Forever rather than merely being retail-era:
`LibsAddonTools` and `LibMasterAddons`. The rest target Classic Era, BCC,
Mists or Midnight.

`LibMasterAddons` carries a compatibility section that redefines missing
Classic globals on top of their `C_` replacements. That is the same shim
layer work item 4 needs, so it is a useful cross-check on the mapping.

**Licensing: `LibMasterAddons` is `X-License: All Rights Reserved`.** No code
from it may be copied into this project. What is recorded below is the
API-to-API mapping - a fact about Blizzard's API surface, not that author's
expression - and the shims here will be written from scratch. Credit for
pointing at the mapping goes to that library.

| Absent global | Claimed replacement | Uses here |
|---|---|---|
| `GetCoinTextureString` | `C_CurrencyInfo.GetCoinTextureString` | 3 |
| `IsSpellKnown` | `C_SpellBook.IsSpellInSpellBook(id, Enum.SpellBookSpellBank.Player, false)` | 20 |
| `SendChatMessage` | `C_ChatInfo.SendChatMessage` | 7 |
| `GetSpellInfo` | `C_Spell.GetSpellInfo` (returns a table) | 24 |
| `GetItemInfo` | `C_Item.GetItemInfo` | 143 |
| `GetNumSpellTabs` | `C_SpellBook.GetNumSpellBookSkillLines` | - |
| `GetSpellTabInfo` | `C_SpellBook.GetSpellBookSkillLineInfo` (table) | - |
| `ChatFrame_AddMessageEventFilter` | `ChatFrameUtil.AddMessageEventFilter` | - |

`GetCoinTextureString` is the notable one: this document previously listed it
as absent with **no** replacement identified, and it is a work item 6 entry.

**Every row above is now MEASURED on the live client** (2026-09-18 17:23,
build 1.60.1.69913), not merely claimed:

    C_CurrencyInfo.GetCoinTextureString    function
       -> returned real gold/silver/copper markup for 12345 copper
    C_SpellBook.IsSpellInSpellBook         function
    Enum.SpellBookSpellBank                table
    C_ChatInfo.SendChatMessage             function
    C_ChatInfo.RegisterAddonMessagePrefix  function
    ChatFrameUtil                          table

The verification mattered: the library targets seven interface versions at
once and its own client detection misreads Forever as Vanilla (it tests the
build string for a leading `"1."`, and Forever builds are `1.60.x`), so its
Forever coverage was not assured on its own say-so.

**`C_Spell.GetSpellInfo` real field list**, read off the live client:

    castTime, iconID, maxRange, minRange, name, originalIconID, spellID

Two things follow:

- **There is no `rank` field**, confirmed. `GetSpellInfo`'s second return was
  `rank`; a shim returning literal `nil` there papers over a genuine removal
  rather than a rename. Audited here (see work item 4): all 7 call sites read
  position 1 only, so nothing in this addon touches it.
- **`originalIconID` exists and is not in the library's mapping.** There are
  now two icon fields to choose between, which a name-for-name shim table
  cannot tell you about.

#### CurseForge flavour IDs, and what actually ships for Forever

Searching CurseForge for Forever builds needs the right flavour filter, and
the obvious guess is wrong. Confirmed by following the site's own filter
links and checking which entry renders as the "toggle off" link:

| Flavour | `gameVersionTypeId` |
|---|---|
| Retail (Mainline) | 517 |
| Classic (Era) | 67408 |
| Classic TBC | 73246 |
| WotLK Classic | 73713 |
| Cataclysm Classic | 77522 |
| MoP Classic | 79434 |
| Titan Reforged Classic | 81212 |
| **Forever** | **88568** |

Under the true Forever filter, a search for "lib" returns **three** results:
`Lib's - Addon Tools` and `Lib's - Time Played` (both wutname1), and
`LibMasterAddons` (103 downloads). Two of those three are the same
libraries already sitting in the local `WoWLibs` folder, which is a useful
corroboration that the Forever library ecosystem is currently tiny.

**Do not read that as "Ace3 has no Forever build".** The query was a text
search for the substring "lib", and Ace3 / AceDB-3.0 / AceConfig-3.0 do not
contain it, so that search could never have surfaced them. Checking for a
specific library needs a name search or the `categories=libraries` facet
under `gameVersionTypeId=88568`, not this one.

All three Forever-flavoured libraries were obtained and inspected
(`LibsAddonTools`, `LibMasterAddons`, `Libs-TimePlayed`). Only
`LibMasterAddons` contains anything port-relevant - the global-to-`C_`
mapping table recorded above. `LibsAddonTools` declares Interface 16001 but
contains **no** Forever-specific handling at all: no compat shims, no client
detection, nothing keyed to the flavour. `Libs-TimePlayed` is a `/played`
tracker.

That is the second independent case of a TOC declaring 16001 without
evidence of Forever-specific work (the first being `LibMasterAddons`'s
client detection misreading Forever as Vanilla). **A declared interface
number is a statement of intent, not evidence of testing.**

Nothing found on CurseForge under the Forever flavour is a compatibility
shim for the removed 3.3.5a globals, a Settings-panel registration helper, a
dropdown-menu library, or a SavedVariables layer. Which is consistent with
the rule above: no external libraries here anyway.

### Stale contracts: audit headers, not just assertions

A 3.3.5a-derived codebase accumulates two shapes of claim that the port
silently inverts, and both fail in the safest-looking way.

**Assertions phrased as "does NOT use \<modern API\>".** Two were found
here, both passing happily while protecting a bug:

- `"comms has no 4.0 prefix-registration API"` - correct on 3.3.5a, where
  filtering `CHAT_MSG_ADDON` by prefix was the whole job. On Forever the
  absence it protected means the transport never fires.
- `"no 4.0 GROUP_ROSTER_UPDATE introduced"` - it was guarding a
  `PARTY_MEMBERS_CHANGED` registration that THROWS on this client and takes
  out the rest of the file.

Both were inverted rather than deleted, with the reason written at the
assertion.

**Headers that document the contract the code has stopped honouring.** This
is the more dangerous variant, raised by the BarWarden-Forever port after it
inverted a test body and left the file header above it still describing the
old rule. A corrected test under a stale header is how someone talks the test
back into its bug in good faith, citing the documentation directly above it.

Audited here. `WoWClearance_Comms.lua`'s header was the live case and was
fixed with the bug. Two more were stale rather than dangerous and are now
marked:

- `WoWClearance_RealmComms.lua` listed "No `C_Timer`" as a baked-in
  constraint. **`C_Timer` is present on Forever**, measured. The OnUpdate
  queue is kept because pacing under the anti-spam ceiling is the real
  requirement, but that is now a choice rather than a constraint, and the
  header said otherwise. That file is otherwise unported pending work item 7,
  so its notes are explicitly marked STILL TRUE / NO LONGER TRUE per line.
- `WoWClearance_QuickstartPanel.lua` claimed TOOLTIP is "the highest strata
  available", which is a 3.3.5a fact that has not been re-measured, and whose
  stated reason (host-addon Interface Options wrappers) no longer applies now
  the options UI is on the Settings API. Flagged rather than changed:
  reverting an untested escalation risks the original symptom.

**The rule: when inverting an assertion, grep the file header above it, and
grep the source file's header too.** A test and its documentation disagreeing
is worse than either being wrong alone.

### Method names: absence is usually a wrong guess

The BarWarden port nearly rewrote its bar engine after concluding three
StatusBar methods were missing; all three names had been guessed, and the
real API was `StatusBar:SetTimerDuration(duration[, interpolation, direction])`.
Before concluding a capability is gone, dump `getmetatable(frame).__index`
and grep it. Calling an API with no arguments harvests its usage string,
which names the expected types.

### Confirmed present / absent

Present: `C_Container`, `C_Item`, `C_Spell`, `C_SpellBook`, `C_AddOns`,
`C_ChatInfo`, `C_EquipmentSet`, `C_Timer`, `C_TooltipInfo` (with
`GetBagItem` / `GetItemByID`), `TooltipDataProcessor`, `GetNumGroupMembers`,
and the legacy shims `UIDropDownMenu_Initialize` / `_CreateInfo` /
`_AddButton`, `ToggleDropDownMenu`, `DropDownList1`, `StaticPopup_Show`,
`ColorPickerFrame`.

Absent as GLOBALS, as the baseline said: `InterfaceOptions_AddCategory`,
`InterfaceOptionsFrame`, `OpacitySliderFrame`, `OpenColorPicker`,
`GetCoinTextureString`.

**Re-audited 2026-09-20 against two instrument defects the sibling ports
found. All five verdicts survive, but not all for the same reason, and one
nearly flipped.**

*Defect 1, from DragonUI: a `_G[name] == nil` probe cannot tell "removed
from the client" from "its addon has not loaded yet", and 119 of the 349
shipped TOCs are LoadOnDemand* (both counts verified here). *Defect 2,
found here: the bare-global discriminator, run as a plain substring grep,
also matches methods (`self:Name(`) and suffixed function names
(`Prefix_Name`), which are different identifiers.*

| Name | Verdict | Why it survives |
|---|---|---|
| `InterfaceOptions_AddCategory`, `InterfaceOptionsFrame` | absent | zero hits in any layer; the Settings API migration is done and measured, so nothing rests on it |
| `OpacitySliderFrame` | absent | hits only in `Blizzard_ColorPickerFrame/Classic/`, which does not count under the variant-layer rule |
| `OpenColorPicker` | absent | **this is the one that nearly flipped** - see below |
| `GetCoinTextureString` | absent as a global | only in `APIDocumentationGenerated`, consistent with `C_CurrencyInfo.GetCoinTextureString` being the live form, measured and in use |

`OpenColorPicker` is worth writing out, because a plain grep appears to
refute the verdict with eight `Mainline/` hits and not one of them is the
bare global: five are suffixed function names
(`ChatUnitColor_OpenColorPicker`, `SpellColor_OpenColorPicker`,
`UIDropDownMenuButton_OpenColorPicker`, ...), two are a mixin method
(`ItemQualityColorOverrideMixin:OpenColorPicker`), and `function
OpenColorPicker` has zero hits anywhere. Anchored, the count is 0:

    grep -rnP '(?<![\w:.])OpenColorPicker\s*\(' --include='*.lua' \
      | grep -E '/(Mainline|Shared|Camelot)/'

Control, so the anchor is not merely suppressing everything: the same
pattern gives `JoinChannelByName` 0 and `JoinPermanentChannel` 3, which is
the known-correct split.

This is the kit-scanner masking bug in a mirror. That one matched names as
substrings and wrongly EXCLUDED them, flattering a count downward; this
wrongly INCLUDES them and flatters an absence into a presence. **The
presence direction is the dangerous one**, because a wrong absence is
caught the moment someone writes the call and it throws, whereas a wrong
presence ships and waits for a user.

One carve-out, so nobody over-applies defect 1: it concerns globals owned
by an addon TOC. It does **not** reach the genuine gap below, because
`C_EquipmentSet.GetEquipmentSetItemIDs` is a missing MEMBER of an
engine-provided `C_` namespace, and no load state can explain that.

Of those, only `GetCoinTextureString` has a namespaced replacement, and it
is present and in use: `C_CurrencyInfo.GetCoinTextureString`, measured live
2026-09-18 17:23, bound at `WoWClearance_StatsPanel.lua:19`. Do not read
its place on this list as "the capability is gone".

`C_EquipmentSet.GetEquipmentSetItemIDs` is the one **genuine gap** -
confirmed live, not a capture artefact - and note it is a missing MEMBER of
a namespace that exists, not a missing global. Its replacement is
`C_EquipmentSet.GetItemIDs`, which is present; see the equipment-set shape
measurements above for what it returns.

`C_TooltipInfo` being present matters beyond the API list: the addon's
tome / recipe / proc detection currently scans a hidden `GameTooltip`, and
`C_TooltipInfo.GetBagItem` is a structured replacement for that whole
mechanism.

## MEASURED 2026-09-20: the string-resolved surfaces

Run at last, after the measurement was lost twice. Results from the
in-game widget and event probes, build 1.60.1.69913.

| Surface | Result |
|---|---|
| plain frame `SetBackdrop` | **absent** - the method does not exist, the call throws |
| `BackdropTemplate` | present, supplies `SetBackdrop` |
| `SetColorTexture` | present |
| `SetTexture(r,g,b,a)` | "accepted (may still no-op)" - does NOT error, so a failure here is invisible |
| `SOUNDKIT` table | present. `IG_MAINMENU_OPTION_CHECKBOX_ON` = 856, `OFF` = 857 |
| `PlaySound("igMainMenuOptionCheckBoxOn")` | **THREW** - bad argument #1, wants an int32 |
| `PlaySound(SOUNDKIT.<id>)` | accepted, and audible |
| CreateFrame templates | **all 11 names present, 0 missing** across 88 sites |

Every prediction in the old version of this section held, and every one
was already fixed before the probe ran. The templates result is the one
that could not have been guessed: 11 distinct names across 88 sites, none
missing, so none of that surface ever needed touching.

`SetTexture(r,g,b,a)` is the subtle one and the only thing this run
changed. It does not error, so a silent no-op would never surface - a
divider that fails to draw looks exactly like a divider that was never
added. The three sites were converted to `SetColorTexture`, which the
probe confirms present, rather than left on a call that "may" work.

**Event names:** 16 of 17 accepted. `LEARNED_SPELL_IN_TAB` REJECTED, with
the client's own wording - "Attempt to register unknown event". That is
the name this port removed in v0.5.0 after it aborted a whole file, so the
removal is now confirmed against the live client rather than inferred.

**A capture note worth more than the results.** `/chatlog` was enabled and
`Logs/WoWChatLog.txt` was 0 bytes when copied out - the output exists only
in screenshots. The copy SUCCEEDED and held nothing, which is precisely
the failure `docs/INGAME_VERIFICATION.md` step 1.3 was written against
after the DragonUI port lost a capture the same way. The verify-the-copy
step caught it. Do not treat a successful `cp` as a captured result.

## Superseded: the original string-resolved-surfaces section

Reported by the BarWarden-Forever port, which lost an evening to three of
these in one sitting: `SetBackdrop` moved onto the `BackdropTemplate` mixin,
`SetTexture(r,g,b,a)` became `SetColorTexture`, and `PlaySound` takes a
numeric SoundKitID rather than a string cue. The first throws; the other two
fail silently and draw nothing. `CreateFrame` also throws on a missing XML
template, so one stale template name kills its whole file.

**Exposure here, counted (facts about this codebase, not about the client):**

| Surface | Sites | Risk if the report holds |
|---|---|---|
| `PlaySound("<cue>")` | 79 | silent no-op, or throw |
| `SetBackdrop` on a frame built with no `BackdropTemplate`, **unguarded** | 5 | **throws, killing the rest of each file** |
| `SetTexture(r,g,b,a)` | 3 | silent no-draw |
| `CreateFrame` template names | 88 sites, 11 distinct names | throws per missing name |

The five unguarded backdrop sites are `WoWClearance_HistoryWindow.lua:287`,
`WoWClearance_ListWidget.lua:370`, `WoWClearance_BagContextMenu.lua:88`,
`WoWClearance_ProcessBagsPanel.lua:1118` and `WoWClearance_BugReport.lua:952`.
Each creates a plain `CreateFrame("Frame", ...)` with no template and calls
`:SetBackdrop` a few lines later.

Note why this never looked systemic: two OTHER sites
(`WoWClearance_HelpPanel.lua:887`, `WoWClearance_QuickstartPanel.lua:66`)
already guard with `if frame.SetBackdrop then`. The guarded sites made the
unguarded ones invisible to a casual read.

**Nothing has been changed on the strength of the report.** `WCProbe_Widgets`
measures all four surfaces plus 17 event names in one pass (`/wcwidget`,
`/wcevents`). Fix from its output, per lesson 8.

## In-game verification 2026-09-20: what is now CONFIRMED WORKING

First substantial body of behaviour verified by actually playing, rather
than by reasoning about the source. Build 1.60.1.69913, combined bags on.

| Area | Status |
|---|---|
| Panels load, render, and navigate | confirmed |
| Bag highlighting (Keep/Sell borders) | confirmed |
| Alt+Right-Click menu names the correct item | confirmed |
| Shift-click inserts an item into a list | confirmed |
| Item-level overlay honours the font-size slider | confirmed |
| Quickstart applies its answers to the addon | confirmed, within the session only |
| Sold History shows no phantom external-delete rows | confirmed, see caveat |
| No "tome" wording anywhere in the UI | **WRONG as written, see below** |
| Minimap button clears other addons' buttons | confirmed |
| Standalone window: bags stay open, B works, resize reflows | confirmed |
| Settings shows ONE launcher entry, not seventeen | confirmed |
| Stats panels render and navigate | confirmed, numbers NOT verifiable |

**The "tome" row is WRONG as written, found 2026-09-20 by grepping what
the player can actually read.** The UI surfaces Chris looked at are clean:
the tooltip verdict labels never render the word (`tomeKindLabel` in
`WoWClearance_Tooltip.lua` is only ever compared against `"Recipe"` at
`:470` and `:479`, never displayed), and the locale templates contain zero
`tome` keys, so no localized string can carry it. But `/wc bugreport`,
which `CLAUDE.md` names explicitly as a player-facing surface, printed it
six times: `WoWClearance_BugReport.lua:252`, `:253`, `:1182`, `:1183`,
`:1196`, `:1197`. Commit `28b5ebf` changed the panels and never reached
the diagnostic dump. Fixed now.

The row's real failure is that it was the same evidence shape as the Sold
History row below - **an absence observed once, over the surfaces someone
happened to open** - and it was recorded as plain "confirmed" while the
Sold History row was honestly flagged. One of the two got the caveat it
deserved and the other did not, from the same session. That asymmetry is
the thing to watch for: a caveat applied to the row you were thinking
about does not protect the row you were not.

**Caveat on the Sold History row.** This is an absence, observed over one
session. It is consistent with the `GetItemCount` fix and is the outcome
that fix predicted, but "no false rows appeared while I was looking" is
weaker evidence than a positive result would be. The reasoning behind the
fix is solid - both inputs to the comparison were pinned at 0, so it read
`0 <= 0` and fired unconditionally - and the absence agrees with it. Treat
as confirmed-by-agreement rather than measured.

**The stats panels are a second feature the gate makes unverifiable.**
2026-09-20: the panels themselves render and navigate correctly. What they
CANNOT show is a correct number. Every figure on them is a lifetime
odometer read out of the saved DB, and the gate resets that DB at every
launch, so the panels will always display a single session's worth of
activity no matter how long the addon has been in use. There is nothing to
fix in the panel code; a passing render is the most that can be observed
until the gate lifts.

That makes two features whose CORRECTNESS is blocked rather than merely
inconvenient: the protection rules (Phase 4 below) and the stats
odometers. Both fail the same way - they read state that was supposed to
outlive the session.

**THE VENDOR PATH RUNS.** 2026-09-20: an item added to the Sell List was
sold on opening a merchant. That is the addon's headline feature working
end to end on this client, and it exercises the whole chain at once -
`NS.Decision.sell`, the `buildCtx` adapter reading live bag state, the
vendor loop, and `C_Container.UseContainerItem`. Every one of those was
ported blind.

**What it does NOT prove, and the distinction matters more than the
result.** This is a POSITIVE test: a thing marked to sell was sold. The
dangerous direction is the negative one - that items NOT marked stay
unsold, that the Keep List holds, that equipped gear and gear-set members
are refused. One correct sale says nothing about any of those, because a
sell path that sold *everything* would also pass this test.

The negative direction is Phase 4 of `docs/INGAME_VERIFICATION.md` and is
still deliberately unrun, for the reason recorded there: the
SavedVariables gate resets protection rules at every launch, so a
protection rule cannot be trusted to still be in effect when the vendor
runs. A Sell List entry made this session is gone next launch; a Keep List
entry protecting real gear is gone the same way.

**Still NOT verified:** Alt+Right-Click on the MAIN BANK BAG. Fixed in
718cf4b after the guard was found to test a Vanilla-only global, but it
needs a visit to a bank and has not had one. It is the last outstanding
item from the 2026-09-20 fix run.

**Still NOT verified, and not testable yet:** the sell and delete paths
themselves (Phase 4 of `docs/INGAME_VERIFICATION.md`). Deliberately not
run - the SavedVariables gate means protection rules reset every launch,
so there is no safe way to verify a protection rule against real gear.

## In-game run 2026-09-19: six measured failures

First real in-game execution of the port, build 1.60.1.69913. Protocol in
`docs/INGAME_VERIFICATION.md`, Phases 0 to 2 only. All six fixed in
`e5388cf`. **Three of the six fixes are now verified in-game** by the
2026-09-20 run recorded above: #1 (the load-order abort) by the panels
loading and navigating, #3 (`PlaySound`) by the audible probe, and #5
(the Quickstart tooltip arity) by Quickstart applying its answers. The
line that used to sit here said none of them was verified, which was
true when written and was left contradicting the table above it.
Failures #2, #4 and #6 remain unverified in-game: #2 is a gear guard
that only shows on the Process Bags path, #4 needs a tooltip hover
checked deliberately, and #6 is a lint-gate fix with no runtime surface.

| # | Failure | Effect |
|---|---|---|
| 1 | `.toc` loaded `PanelInfra` after 8 panels that call `NS.OptionsHost()` at file scope | 8 files aborted at load |
| 2 | `IsEquippedItem` / `IsEquippableItem` namespaced to `C_Item`, bare globals nil | decision core threw; **a gear guard failed open** |
| 3 | `PlaySound` takes a numeric SoundKitID, not a string cue | 79 sites |
| 4 | `OnTooltipSetItem` does not exist on this client | item tooltips entirely unannotated |
| 5 | `GameTooltip:SetText` arity, boolean in the alpha slot | Quickstart tooltips threw |
| 6 | `.luacheckrc` declared the two moved globals as bare names | gate vouched for nil at 0 warnings |

**The one that matters.** `WoWClearance_Process.lua:381` read
`if not skip and IsEquippedItem and IsEquippedItem(itemID) then`. That is
a protection guard, and the `X and X(...)` idiom makes a missing global
**fail open** rather than throw: equipped gear was never excluded from the
disenchant / mill / prospect queue, silently. Generalise it - wherever
that idiom sits in front of a destructive-action gate it inverts the
default. A WC-TRAP marks the site.

**Two corroborations of existing predictions.** The `PlaySound` string-cue
failure predicted in the string-resolved-surfaces section is confirmed,
and the predicted count of 79 sites was exact. The `.luacheckrc` finding
is a live instance of the class "What the tooling cannot verify" describes:
removing the two stale declarations immediately surfaced three further
call sites that grepping had missed.

**One cascade worth recording**, because it cost time to attribute: the
`PLAYER_REGEN_ENABLED` crash at `Events.lua:7483` had no independent
cause. `WC_compCache.rearmProcessButton` is defined at
`ProcessBagsPanel.lua:64`, eight lines past the line that aborted under
failure 1. One root cause, two unrelated-looking symptoms in different
files. On this client, attribute every nil-call to the load-order
question before treating it as its own bug.

### Process failures from the same run, which cost more than the bugs

1. **The chat-capture step was skipped.** `/chatlog` was never enabled, so
   `/wcwidget` and `/wcevents` printed to a chat frame and nowhere else.
   Those are the probes for the string-resolved surfaces, they write
   nothing to disk by design, and **that run is unrecoverable.** Phase 1
   must be redone.
2. **A copied artefact is not a kept result.** Measured on a sibling
   port's probe the same afternoon: a 37,401-byte capture written at
   15:00:14, the live file overwritten with a defaults state 36 seconds
   later, and the copy taken at 15:01:54 succeeded, existed, was a
   plausible 30,934 bytes, and contained one line reading `NOT RUN`. It
   was cited as evidence in a bug report. Verified here afterwards: the
   `.bak` generation had been consumed too, so both on-disk copies read
   `NOT RUN`.

   This qualifies the otherwise-sound rule that a saved artefact beats a
   retyped screenshot. On this client an artefact is better evidence only
   **after** it has been grepped for the field it should contain. Until
   then it is an unverified file, and an unverified file has already been
   cited for a result it did not hold. A chat log is worse still: it has
   no `.bak` to fall back on.

**`stylua` was not run.** It reformats roughly 1900 lines across 32 files
because the tree has drifted from its own `stylua.toml` and CI does not
check it, and that churn broke three static-pattern suites. Verified that
HEAD was already unformatted before any of this work, so the drift is
pre-existing. It is a separate cleanup and must not ride along in a fix.

## The fail-open idiom, and the two-step sweep that finds it

Measured 2026-09-19/20. Four instances in this port, so the method is worth
stating rather than rediscovering.

**The shape.** `X and X(...)` in front of a call is ordinary defensive code
when `X` exists. When `X` has been namespaced away it resolves to nil and
the guard converts a missing API into a **wrong answer** instead of an
error. Ours:

| Global | Now | What the guard did |
|---|---|---|
| `IsEquippedItem` | `C_Item.IsEquippedItem` | equipped-gear skip **failed open** - gear was never excluded from the Process queue |
| `GetItemCount` | `C_Item.GetItemCount` | external-delete detector compared `0 <= 0`, so it logged a deletion **every time** |
| `IsUsableItem` | `C_Item.IsUsableItem` | wrong-class Keep List self-heal silently never ran |
| `GetItemFamily` | `C_Item.GetItemFamily` | every bag read as generic in the stack-fit check |

**The sweep, both steps.**

1. Grep for the idiom across capitalised globals.
2. For each hit, grep **Blizzard's shipped source** for bare usage of that
   name. Zero bare usage means the global is gone.

Step 1 alone returns a list that looks clean, because the idiom is
legitimate wherever the name survives. All four above read like functions
that obviously still exist.

**Never use `wow_api_search` for step 2.** The Forever index has 0 globals,
so a namespaced-only result is the only thing it can return and proves
nothing about the bare name. `InCombatLockdown` is the counter-example: the
search returns only `C_RestrictedActions.InCombatLockdown`, while the bare
global appears 14 times in shipped source and is alive.

**The fix, WITH its precondition.** Bind the replacement to an upvalue and
call it **unguarded** - the guard is what produced the wrong answer.

> **This holds only when a replacement EXISTS.** Correction from the
> BarWarden-Forever port, which found `GetRuneType`: gone from this client
> with no namespaced equivalent at all. With nothing to bind, a fallback is
> the only option, and removing the guard turns a dormant no-op into a live
> error. Check that the replacement exists before applying the rule; if it
> does not, the guard is correct and the call site wants a recorded reason
> instead.

**A third outcome worth knowing about**, also from that port: a call site
can be *unreachable* rather than broken. Their `GetRuneType` sites are
never entered, because Death Knight is not a playable class on this server.
The shipped client does not reveal that - it still carries `RuneFrame.lua`
and lists `DEATHKNIGHT` in its character-create data. The character
creation screen was the discriminator, not a source grep. So "the API is
absent" and "the code runs" are separate questions, and a source grep
answers only the first.

## What the tooling cannot verify

Measured 2026-09-19. Every item here is a hole in a gate that reports
green, which is what makes them worth writing down.

**`tests/test_api_surface.lua` is the ONLY remaining check for the
moved-global class.** Do not retire it as redundant. Both tools that look
like they cover it do not:

- **luacheck** cannot see it, because the old 3.3.5a names are still
  declared in `read_globals` while the migration finishes. That is
  deliberate, not debt. A bare `GetItemInfo(...)` left at a call site
  lints clean at 0 warnings.
- **`wow_lua_lint`** cannot see it either. Its unknown-function check is
  OFF for Forever (it says so in its own output: upstream publishes no
  global function list for this client), and its known-removed-API check
  was measured against eight bare 3.3.5a globals that HAVE been
  namespaced here - `GetContainerNumSlots`, `GetContainerItemInfo`,
  `GetItemInfo`, `GetAddOnMetadata`, `IsAddOnLoaded`, `GetSpellInfo`,
  `SendAddonMessage`, `RegisterAddonMessagePrefix`. Result: **0 errors,
  0 warnings. Not one flagged.**

So a green luacheck run plus a green `wow_lua_lint` run says nothing
about whether the namespacing migration is finished.

**What `wow_lua_lint` DOES do on Forever**, measured the same day:
`event/unknown` fires by exact name (it caught both `RUNE_UPDATE` and an
invented name, and its message states the consequence), `taint/protected-call`
and `taint/combat-locked` fire, and `global-frame-name` fires. For event
names specifically it is the **better** gate than `wow_api_event_search`,
because there is no result list to misread.

**`wow_api_event_search` fuzzy-matches and does not say when there is no
exact hit.** `RUNE_UPDATE` returns real neighbours and no warning. Read
for an exact name, never for "the search returned something".

**The event index is derived from Blizzard's generated documentation, not
a shipped event list.** A miss means "not documented". That has predicted
client-absence correctly every time it has been tested in-game, which
makes it a strong prior and not a proof.

The general shape: these tools are strong evidence of presence and weak
evidence of absence.

## Hard release gate

> **MEASURED 2026-10-07: read-back WORKS on build 1.60.1.70245, account
> scope, across a real cold start.** The previous client process (started
> 17:29) exited; a new one (`WowB.exe`, started 21:22:02) launched, with
> `WTF/SavedVariables/Blizzard_GlueSavedVariables.lua` rotated at 21:21:50
> and rewritten at 21:22:30. After that launch the player read off the
> screen: Sell List entries still present, Sold History and Loot Log
> History entries from the previous session still present, Shift+L still
> bound. On disk the account file still carries `startedAt = 1790109381`
> (2026-09-22) plus that session's `soldHistory`, `lootHistory` and
> `lootLogKeyClaimed`. Snapshot:
> `~/Projects/.sv-evidence-20261007-212258-build70245-afterColdStart`.
>
> What this does NOT cover, stated so the gate is lifted knowingly:
> per-character scope (this addon has none of its own), and a
> corroborating independent addon on the same boundary (3.8 below asks for
> both). Whether that is enough to publish is the owner's call.
> **Decided 2026-11-14: published, from v0.8.0.**
>
> **LEAD 2026-10-07 (superseded by the measurement above): read-back
> appears to WORK on build 70170, account scope.**
>
> Found passively on disk, not by running a protocol. `AS.startedAt` is
> written as `time()` only when it is not already a number
> (`WoWClearance_Events.lua:601`). A launch that never read the file
> would therefore store the current wall-clock time. Both WoWClearance
> generations written on 2026-10-02 (21:05 and 21:16, build 70170, per
> the client error logs from the 20:49-20:54 launches) carry
> `startedAt = 1790109381`, which is **2026-09-22 22:36:21**. The same
> generations also carry the 2026-09-22 odometers (`totalCopper = 642`,
> `totalItemsSold = 20`).
>
> The only way a 2026-10-02 process writes a 2026-09-22 `time()` value is
> by reading it back. The boundary between them is not in doubt: the
> per-character Blizzard files show the 2026-09-22 session ending around
> 23:54, and the next writes are ten days later on a different build.
> This is the non-regenerable marker that Phase 3.1 asks for. It is a raw
> wall-clock value set once, not a timestamp rewritten on every save.
>
> The timing points at a client change. On **build 69913 at 2026-09-22
> 21:11**, the DragonUI port's discriminator probe (`DUISVDiscrim`, both
> scopes, both storage patterns) still read nil on every arm. WoWClearance
> itself started fresh at 22:36 the same evening. Build 70170 is the first
> build where anything has been seen to survive.
>
> Why this does not lift the gate yet:
>
> - It is one boundary, observed after the fact, with no marker set on
>   purpose.
> - It is account scope only, as everything from this addon is (see the
>   Scope section below).
> - The client is now on **1.60.1.70245** (updated 2026-10-07). A fix in
>   70170 could regress in 70245.
>
> To retire the gate: run Phase 3 of `docs/INGAME_VERIFICATION.md` on
> 70245 across a real cold start, with a Sell List marker, and run a
> both-scope instrument (the BarWarden port or `WCProbe_SavedVars`) on
> the same boundary. Evidence snapshot, taken with the 70245 client
> running and before its first flush:
> `~/Projects/.sv-evidence-20261007-173326-build70245-running`.
>
> **Side effect if read-back is confirmed.** The live save still holds
> `shareServerData = true` and `shareServerDataDefaultBumped = true`, both
> left by the pre-`557df65` forced default rather than chosen by the
> player. Current code seeds OFF only when the value is nil, so the old
> `true` now persists. With it set, opening the Server Stats panel joins
> the realm channel. No other install exists, so this affects only this
> machine's save. Turn the toggle off in the panel once.

> **STATUS 2026-09-19: CONFIRMED BROKEN on build 1.60.1.69913, by
> measurement across a real process boundary. The gate STANDS, and now it
> rests on evidence taken here rather than on a report inherited from the
> brief.** The 2026-09-18 "possibly fixed" reading is withdrawn: it came
> from a single per-character observation whose session boundary was never
> controlled, and the control everyone used to establish that boundary was
> itself defective (see below).
>
> Two addons whose code was **provably unchanged across the boundary**
> each held real content on disk before a cold start at 12:42:35 and had
> none of it afterwards:
>
> | Addon | Last generation before the boundary | After |
> |---|---|---|
> | `WCProbe_SavedVars` | flushed 12:39:41: account `nonce=619127`, perchar `nonce=216407`, both `writtenAt=12:14:30`, `runCount=1` | `runCount` still 1, fresh account `nonce=863849` - the prior values never came back |
> | `BarWarden` (per-char) | `.bak` 12:39:41, 14,444 B, `fromPreset` x15 | 5,723 B, `fromPreset` x0 |
>
> Both scopes. Both storage patterns (in-place mutation AND reassigning the
> global). Two separate authors, neither file touched. **Writing works;
> reading at launch does not.**
>
> The sibling port's run also carried an **on-screen** confirmation: its
> user read sliders at defaults and no starter layout before any file was
> parsed. Every other strand of today's evidence runs through somebody
> interpreting a file, so a reading taken off the screen is worth stating
> separately.
>
> **The new defaults are then flushed OVER the old save.** The relaunched
> session does not merely ignore the stored configuration, it replaces it.
> The per-character file in the table above is now the 5,723 byte defaults
> version on disk; the 14,444 byte original survives only as a `.bak`
> that the next flush rotates away. For a bag addon that is the whole
> argument for this gate, and it is stronger than "settings do not
> persist": protection rules that reset are dangerous, but protection
> rules that reset AND overwrite the saved copy cannot be recovered by
> quitting quickly, and nothing tells the player anything was lost.
>
> **Why "the instrument is simply broken" does not explain it.** Our probe
> has never successfully read back at any boundary, so on its own its nil
> is ambiguous. What removes the ambiguity is that its code did not change:
> `WCProbe_SavedVars.lua` is md5 `00d1b6b8fde8f4b4164c78b89bf135d1`, mtime
> 2026-09-18 21:06:15, verified identical before and after the boundary and
> again after the unrelated 12:53:54 install activity. BarWarden's files
> were likewise untouched. So the same binary produced a written file
> before and an absent read after, which a broken instrument does not do
> selectively.
>
> `DragonUIProbe` shows the same transition (`marker=12:14:30` in its
> `.bak`, `previousMarker=NONE` after) and is **consistent with** the
> result, but must NOT be cited as the proof: its Lua was replaced at
> 12:23:20 and again at 12:53:54, so the two readings come from different
> builds, and its earlier apparent read-back was in-memory retention across
> a `/reload` rather than a disk read. An earlier draft of this section
> leaned on it as the load-bearing evidence. It cannot carry that.
>
> Note what the files can and cannot show. The `NO TABLE` wording seen
> in-game is a chat-frame observation; the flushed file records only the
> post-bump state. Cite the counter and nonce, which the artefact proves,
> rather than the chat line, which it does not.
>
> Evidence preserved outside the live `WTF` tree, which keeps only two
> generations and rotates one away per flush:
>
>     ~/Projects/.sv-evidence-20260919/WTF-snapshot-123554
>     ~/Projects/.sv-evidence-20260919/WTF-snapshot-preColdStart-124419
>     ~/Projects/.sv-evidence-20260919/WTF-snapshot-postColdStart-124747
>
> Do **not** use BarWarden's `schemaVersion` to argue this: it reads 5 on
> both sides of the boundary, so it cannot distinguish a restored profile
> from a freshly built one.
>
> **Account scope cannot be tested by comparing files, and account scope
> is all WoWClearance declares.** The sibling port's account-scope file is
> 2,008 bytes on both sides of the boundary, and its contents differ in
> exactly one field: a regenerated `lastModified`. That is not
> persistence. It is an init path deterministically rebuilding an
> identical `Default` profile from its defaults table. Same inputs, same
> bytes. Verified here against the snapshots:
>
>     pre  12:39  2008 B  f6fa74c6d4f49f1dd7a40e554c915e00
>     post 12:45  2008 B  d53bf9f7c3f65fafcb692f4dfaa418b0
>     diff: ["lastModified"] = 1789812870 -> 1789814589, and nothing else
>
> Both obvious checks mislead, and **the more rigorous-feeling one is the
> more dangerous.** A size match reads as a pass, which at least looks
> like the kind of result worth double-checking. A hash mismatch reads as
> a real negative: "the file changed, so something was loaded and
> updated." That is a confident wrong conclusion drawn from a timestamp
> field. Someone re-testing this in six months will reach for `md5sum`
> precisely because it is the careful option, and the care is what makes
> it mislead them.
>
> The line that settles it needs no comparison at all. The post-boundary
> account file contains:
>
>     ["profiles"] = { ["Default"] = {
>         ["description"] = "Default starter profile",
>         ["data"] = { ["visual"] = { ["fontSize"] = 11,
>
> (elided to the two lines that matter; they are four lines apart at
> different depths in the real file.) `fontSize` is the shipped default,
> and the marker written before the boundary was 13.9414176940918. Reading
> that requires no baseline, no hash and no second file.
>
> Anyone re-testing `WoWClearanceDB` later needs a marker that CANNOT be
> regenerated from defaults: a random nonce, or real user data such as a
> Sell List entry.
>
> **Name the bad markers, not just the good ones**, because nobody picks a
> bad one on purpose. A version number, a build string, a schema version,
> a formatted timestamp, a profile called `Default`: every one of those
> LOOKS like a marker, and every one is reproduced identically by a
> rebuild. A tester who picks any of them gets the false pass this section
> warns about while believing they followed the advice. The test is not
> "did I write something down", it is "could this exact value have been
> reconstructed by code that never read my file". `WCProbe_SavedVars` happens to write `math.random`
> nonces, which is why 619127 / 216407 failing to come back is a result
> where a byte count would not have been one. Record that as luck, not
> design: nothing in the probe documents non-regenerability as the reason
> for choosing a nonce, and a probe written to stamp a version number or a
> build string would have produced the same false pass this section warns
> about. The next probe should pick its marker deliberately.
>
> Process boundary, established from OUTSIDE the client:
>
>     uptime -s            2026-09-19 11:17:45
>     WowB.exe PID 274980  lstart Sat Sep 19 12:42:35   (prior PID absent)
>
> **Why this took a full day to see, and the trap not to repeat:**
> `GetTime()` on this client counts from SYSTEM BOOT, not client launch.
> 12:43:09 minus the reported 5124.153s gives 11:17:44.847, matching boot
> to the decimal. Every probe's `isColdStart` control therefore reported
> "this is reload-level only" 34 seconds into a genuine cold start, and
> would do so for every session after the machine's first hour however
> often the client restarted. Three ports spent hours concluding
> "everything today is reload-level" while the capture that answered the
> question sat on disk mislabelled. **Nothing inside the client reliably
> separates a reload from a relaunch.** Establish the boundary externally and
> have the probe record the raw timer while declining to classify it.
> `ps -o lstart` on the running client is the direct check: the old PID is
> simply gone. The glue file's mtime works as a corroborator but is a
> LAUNCH marker, not an exit detector - it does not move when the client
> quits, only when the next one starts.

Forever has a Blizzard bug where the client **writes**
SavedVariables on exit and **never reads them back**. Every addon starts
from defaults each launch. This addon has 134 references to its saved
databases.

An install that forgets every protection rule at login is not a reduced
product, it is a dangerous one, because those rules are what stop it
selling things. And it does not merely forget them: the defaults it
starts from are written back over the saved copy on the next exit, so the
rules are destroyed rather than ignored, silently, leaving a well-formed
file behind.

Develop against it (the forever-addon-kit's `ForeverCompat` seeds and
`sv_bridge.py` are a dev-only workaround requiring a Python watcher on
the machine). **Do not ship publicly until Blizzard fixes it.**

### Ownership: the gate investigation moved 2026-09-19

**WoWClearance is no longer the primary instrument for this gate.** The
investigation moved to the BarWarden-Forever port on the scope argument
below. WoWClearance's role is now **corroboration on the account-level
path only**: a second, independently-authored implementation of the same
scope, which is genuine confirmation but not the main experiment.

`docs/INGAME_VERIFICATION.md` Phase 3 is marked accordingly and kept in
full, so that port can inherit the procedure - particularly the
outside-the-client process boundary in Phase 0 and the bad-marker list in
3.1 - rather than rebuild it.

**A limit on the existing evidence, recorded because it is easy to
over-read.** The gate is documented above as established across two
independently-authored addons. That is true, and it sounds broader than
it was: **the comparison was only ever made at account level**, because
WoWClearance has no other scope to offer. The existing evidence may
therefore be measuring something narrower than "SavedVariables are
destroyed".

This is **not a retraction**. The gate stands, it still blocks release,
and the measured facts behind it are unchanged: two addons whose code was
provably unchanged each lost their on-disk content across a real process
boundary. It is a statement about what has been *shown*, not about
whether the bug is real. Retiring the gate needs the primary instrument,
both scopes measured, and a corroborating addon on the same boundary.

### RESOLVED 2026-09-19: the failure is NOT scope-specific, and a reload reproduces it

Measured by the BarWarden-Forever port, which is the only instrument that
could answer it - it declares both scopes in one addon. Nonce
`70dd2c25e520c5f3`, written into both scopes in a single session:

| Scope | Marker | On disk before | After |
|---|---|---|---|
| Account | `profiles["probe-<nonce>"]` | 2,124 B | **nil** |
| Per-character | `frames.probeMarker` | 5,528 B | **nil** |

**Both die.** So per-character storage is no safer than account storage,
and the caveat recorded below - that the gate might have been measuring
something narrower than it claimed - resolves at no cost. WoWClearance
being account-only was never concealing a favourable per-character result;
there was nothing there to measure.

**A plain `/reload` reproduces it.** No process boundary, no `ps -o lstart`,
no quit to desktop. That makes re-testing a future build a 40-second check
rather than a full cold-start protocol, which matters because this gate
will need re-testing every time the client updates.

Two limits, stated rather than glossed. This measures a **reload**, not a
process restart, and the cold start was not re-measured with this nonce.
The separate cold-start measurement recorded above agrees with it, but that
is two boundaries and two measurements - neither claim covers the other.

The load-bearing step was **verifying the write on disk before trusting the
read**. Without it, absence afterwards demonstrates a failed write and says
nothing about read-back: a check that cannot fail, wearing a new costume.

### Scope: this addon cannot test the per-character half

WoWClearance declares **account scope only**:

    ## SavedVariables: WoWClearanceDB, WoWClearanceAccountDB

There is no `## SavedVariablesPerCharacter` line. Per-character data
lives inside the account table behind the DB proxy, so no per-character
file is ever written and its absence is not a fault.

The consequence matters for how the gate gets retired. **If the failure
turns out to be scope-specific, this addon can never show that**, because
it only has one scope to observe. The sibling bar addon declares both in
a single addon (`SavedVariables` plus `SavedVariablesPerCharacter`), so
it can discriminate account-level from per-character within one
write/read cycle with no cross-addon confound. That makes it the better
instrument for this particular question, and it is worth coordinating
with that port rather than re-deriving the answer here.

`WCProbe_SavedVars` also declares both scopes, so it has the same
advantage over the addon proper. A round-trip result from it does not
transfer to WoWClearance without stating which scope produced it.

**A lead, explicitly not a finding.** On disk 2026-09-19, the sibling
addon's account-level file is 2,008 bytes in both the live copy and the
`.bak`, while its per-character file grew from 5,695 to 15,517 bytes
across the same pair. **Nothing follows from this yet.** Growth between
sessions does not demonstrate a successful read-back, since the later
session could simply have generated more data, and equal byte counts do
not prove identical content, let alone a failed round trip. It is
precisely the shape of inference that went wrong three times on
2026-09-19. Treat it as a question worth designing a step around, not as
evidence. The account-scope trap documented above - identical size,
differing hash, one regenerated timestamp field - applies here in full.

### Correction: a distribution channel DOES exist

An earlier version of this section, inherited from the original brief and
never checked, said "no addon site has a Forever flavour yet, so there is
currently no distribution channel". **That is wrong.** CurseForge has a
Forever flavour, `gameVersionTypeId=88568`, verified here by following the
site's own filter links (see the flavour-ID table above). The
BarWarden-Forever port reports roughly 300 projects listed under it,
including Auctionator, BetterBags, Syndicator, Leatrix Plus and a
Forever-branded AtlasLoot; that count is their measurement, not one taken
here, but the existence of the flavour is confirmed independently.

This does not move the release gate, because the gate never rested on
distribution. **The SavedVariables bug is the whole of it, and it stands
alone**: an addon whose protection rules silently reset at every login is
dangerous regardless of how easy it is to publish.

What the correction does change: **packaging and release automation are not
blocked, only publishing is.** The release workflow can be brought up to
date whenever it is convenient rather than waiting on an upstream fix.
