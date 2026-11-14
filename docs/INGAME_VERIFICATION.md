# In-game verification protocol

Status: **written 2026-09-19. PARTIALLY RUN the same day.**

Phases 0 to 2 were run against build 1.60.1.69913 and found six real
failures, all since fixed (commit `e5388cf`). Phase 3's question (does saved
data survive a cold start?) was answered on build 1.60.1.70245 on
2026-10-07: yes, account scope, read off the screen and confirmed on disk.
Phase 4 (sell and delete against real gear) and Phase 5 have NOT been run
as written. Findings live in `docs/PORT_STATUS.md`, not here.

Two process failures from that run are worth more than the bugs, and both
are now corrected in the steps below:

1. **Step 0.4 was skipped**, so `/chatlog` was never enabled and the
   `/wcwidget` and `/wcevents` output went to a chat frame and nowhere
   else. That run is unrecoverable and Phase 1 must be redone.
2. **Copying an artefact out was treated as keeping it.** See the box in
   step 1.3: on this client a saved file can be overwritten with a
   defaults state within a minute, and the copy still succeeds.

This is a protocol for a human at the keyboard, not a test suite. Every
static check that could be automated has been: 18/18 registered event
names and 100% of the `C_*` members declared in `.luacheckrc` are verified
present on Forever, twelve invariant suites pass, and the lint gate sits
at 0 warnings. What remains cannot be reached from outside the client.

Run the phases in order. Phase 3 was written for a client that destroyed
saved settings; on build 70245 it no longer does, but back up first anyway,
since a later build could regress. Phase 4 destroys items; it says so where
it starts.

**Phase 4 is now known to be more dangerous than first written.** The
equipped-gear skip in the Process Bags queue was failing open on this
client (see PORT_STATUS). It is fixed, but that fix is unverified
in-game, so treat Phase 4's throwaway-character rule as mandatory rather
than cautious.

**Read `docs/PORT_STATUS.md` "Porting lessons" before starting.** Several
steps below exist only because a previous session got the answer wrong in
a way that looked right.

## Environment, as measured 2026-09-19

| Thing | Value |
|---|---|
| Client root | `/mnt/Games/World of Warcraft/_forever_` |
| Executable | `WowB.exe`, build 1.60.1.69913, Interface 16001 |
| Account SavedVariables | `WTF/Account/<account>/SavedVariables/` |
| Lua error captures | `Errors/` under the client root |
| Chat log target | `Logs/WoWChatLog.txt` (does not exist yet) |
| WoWClearance installed? | **Yes**, since 2026-09-19. Phase 2 refreshes it. |

WoWClearance declares two SavedVariables, both **account scope**:
`WoWClearanceDB` and `WoWClearanceAccountDB`. There is no
`## SavedVariablesPerCharacter` line. Per-character data lives inside the
account table behind the DB proxy, so a per-character file will never
appear and its absence is not a fault.

Addons install as plain copies. Editing the repo changes nothing in the
game. Every install step below is an explicit copy, and every one ends by
checking the installed copy rather than the repo.

### The probe addons, and where each one puts its output

This table is load-bearing. Three of the five write **nothing to disk**,
so their results exist only in the chat frame until you capture them.

| Probe | Commands | Output |
|---|---|---|
| `WCProbe` | `/wcprobe`, `/wcprobecombat` | SavedVariables: `WCProbeDB` |
| `WCProbe_SavedVars` | (automatic) | SavedVariables: `WCSVProbeDB`, `WCSVProbeCharDB` |
| `WCProbe_Widgets` | `/wcwidget`, `/wcevents` | **chat frame only** |
| `WCProbe_EquipmentSet` | `/wceqprobe`, `/wcevprobe` | **chat frame only** |
| `WCProbe_ColorPicker` | `/wccpprobe` | **chat frame only** |

The three chat-only probes declare no `## SavedVariables` line at all.
`WCProbe_Widgets.lua:13` is the single output path, a
`DEFAULT_CHAT_FRAME:AddMessage` behind a local `say()` helper.

**Do not read meaning into a missing SavedVariables file for those
three.** It cannot exist by design. Their measurements may have been
taken repeatedly and read and lost; what is true is only the weaker
claim, that nothing durable records them, so no statement in this repo
can be traced back to a run of them. This is the third instance of the
same mistake in this port: file-absence treated as evidence that an event
never happened. Establish the mechanism before reading meaning into a
missing artefact.

---

## Phase 0: setup and the process boundary

Do this first and keep the terminal open. Every later phase that claims
"across a relaunch" depends on it, and every chat-only probe depends on
0.4.

**Nothing inside the client can distinguish a reload from a relaunch.**
`GetTime()` on Forever counts from system boot, not client launch. An
in-client cold-start check reported "reload-level only" 34 seconds into a
genuine cold start and cost three sessions several hours. Do not add one
back, and do not trust `isColdStart` in any existing probe capture.

### 0.1 Record the boot time

    uptime -s

Expected: a timestamp. Write it down.

### 0.2 Record the running client's launch time

    ps -o pid=,lstart= -C WowB.exe

Expected: one PID and its start time, or empty if the client is not
running. Write the PID down.

Failure: if you see two PIDs, a previous client did not exit. Close both
before continuing, or every later boundary claim is worthless.

### 0.3 After any relaunch, re-run 0.2 and confirm the PID CHANGED

Expected: a different PID, with a later `lstart`.

Failure: same PID means you did a `/reload`, not a relaunch. Any Phase 3
result taken across it is void. The mtime of
`WTF/SavedVariables/Blizzard_GlueSavedVariables.lua` corroborates, but it
is a LAUNCH marker, not an exit detector: it does not move when the client
quits, only when the next one starts.

### 0.4 Turn on chat capture BEFORE running any probe

Three of the five probes print to chat and nowhere else. Chat scrolls
away and does not survive a `/reload`.

In-game:

    /chatlog

Expected: the client confirms logging is on, and
`Logs/WoWChatLog.txt` appears under the client root. Verify from the
terminal before trusting it:

    ls -la "/mnt/Games/World of Warcraft/_forever_/Logs/WoWChatLog.txt"

Failure: no file. Do not run a chat-only probe until this works, or you
will be transcribing from the screen, which is how measurements get lost.

**Do not transcribe probe output by hand.** The whole point of this step
is that the record outlives the session.

---

## Phase 1: the string-resolved surfaces

**Run this first.** It is not the most important phase - Phase 3 is the
release gate - but it is the prerequisite for interpreting everything
after it.

Five **unguarded** `SetBackdrop` sites throw if the reported behaviour
holds, and on this client a throw aborts the rest of the file. A
partially-executed file makes every later observation ambiguous between
"this feature is broken" and "the file died before reaching it". Measure
the surface first so the later phases have an unambiguous baseline.

This phase is also **independent of the install**: it uses a standalone
probe, so it can run before WoWClearance is in the client at all.

These surfaces are the highest-risk unmeasured items in the port, because
luacheck and `wow_lua_lint` are both structurally blind to them: the
argument is a string, so no static tool can tell a valid cue from an
invented one.

Counted exposure in this codebase (facts about our source, not about the
client): 79 `PlaySound("<cue>")` sites, 5 **unguarded** `SetBackdrop`
sites, 3 `SetTexture(r,g,b,a)` sites, 88 `CreateFrame` template sites
across 11 distinct names.

### 1.1 Confirm chat capture is on

Step 0.4 must have been done and verified. If `Logs/WoWChatLog.txt` does
not exist, stop and fix that first.

### 1.2 Run the probe

    /wcwidget
    /wcevents

Expected: output scrolls in the chat frame covering all four surfaces
plus 17 event names.

### 1.3 Copy the log out, then PROVE the copy contains the result

    cp "/mnt/Games/World of Warcraft/_forever_/Logs/WoWChatLog.txt" \
       "~/Projects/.ingame-$(date +%Y%m%d-%H%M%S)-widgets.txt"

Then, before treating the run as done, grep the **copy** for a string the
probe actually emits:

    grep -c 'SetBackdrop' ~/Projects/.ingame-*-widgets.txt

**A copy that does not contain it is a FAILED RUN, not a negative
result.** Re-run the probe while the client is still up, which is cheap.

> **Copying an artefact out is not the same as keeping the result.**
> Measured on this client 2026-09-19: a sibling port's probe wrote a
> 37,401-byte capture at 15:00:14 and the live file was overwritten with
> a defaults state 36 seconds later. The copy taken at 15:01:54 succeeded,
> existed, and was a plausible 30,934 bytes - and contained one verdict
> line reading "NOT RUN" and none of the reported fields. It was cited as
> evidence in a bug report. Confirmed here afterwards: by then the `.bak`
> generation had been consumed too, so both copies on disk read "NOT RUN"
> and the result was unrecoverable.
>
> Nothing detectable failed. `cp` returned success, the file existed, and
> the size looked like a real capture rather than an empty one.
>
> **A chat log is worse in one respect: it has no `.bak` generation to
> fall back on.** If the grep above returns 0 there is nothing to recover.
> Verify while the client is still running.

### 1.4 Check the five unguarded SetBackdrop sites by hand

The probe measures the API. These are the specific call sites that would
die. They need WoWClearance installed, so **return to this step after
Phase 2** and record the result here.

| File | Line | Reach it by |
|---|---|---|
| `WoWClearance_HistoryWindow.lua` | 287 | `/wc history` |
| `WoWClearance_ListWidget.lua` | 370 | opening any list panel |
| `WoWClearance_BagContextMenu.lua` | 88 | right-clicking a bag item |
| `WoWClearance_ProcessBagsPanel.lua` | 1118 | the Process Bags panel |
| `WoWClearance_BugReport.lua` | 952 | `/wc bugreport` |

Expected: each appears WITH a visible border and background.
Failure, loud: a Lua error naming `SetBackdrop`.
Failure, quiet: the frame appears with no border. Note it; the API
exists but did nothing.

Note why this looked non-systemic: two other sites
(`WoWClearance_HelpPanel.lua:887`, `WoWClearance_QuickstartPanel.lua:66`)
already guard with `if frame.SetBackdrop then`, which made the unguarded
five invisible to a casual read.

### 1.5 Sound

Trigger any action that should play a sound (opening a panel, arming the
sell button). Also needs Phase 2 first.

Expected: audible.
Failure: silence with no error. `PlaySound` taking a numeric SoundKitID
rather than a string cue fails silently, so silence IS the result. 79
sites share this fate; confirm one and assume the rest.

**Do not fix anything during this phase.** Record and move on. Fixes come
after the pass, per porting lesson 8.

---

## Phase 2: install, and load integrity

Nothing after this matters if the addon does not load cleanly. On this
client a load failure is often **partial and silent**, which is worse than
a crash: a throw aborts the rest of the file, so the addon appears to work
while a chunk of it never ran.

### 2.1 Install

    rm -rf "/mnt/Games/World of Warcraft/_forever_/Interface/AddOns/WoWClearance"
    mkdir -p "/mnt/Games/World of Warcraft/_forever_/Interface/AddOns/WoWClearance"
    cp ~/Projects/WoWClearance/WoWClearance*.lua \
       ~/Projects/WoWClearance/WoWClearance.toc \
       ~/Projects/WoWClearance/Bindings.xml \
       "/mnt/Games/World of Warcraft/_forever_/Interface/AddOns/WoWClearance/"

### 2.2 Verify the copy landed, from the INSTALL directory

    ls "/mnt/Games/World of Warcraft/_forever_/Interface/AddOns/WoWClearance/" | wc -l

Expected: 37 (35 `.lua` + `.toc` + `Bindings.xml`).

Never confirm an install by reading the repo. Editing the repo changes
nothing in the game, and this has wasted time before.

### 2.3 Clear the error log so anything you see is from this run

    mv "/mnt/Games/World of Warcraft/_forever_/Errors" \
       "/mnt/Games/World of Warcraft/_forever_/Errors.before-wc-$(date +%H%M%S)"

### 2.4 Enable Lua errors before logging in

At the character screen or in-game:

    /console scriptErrors 1

Without this, throws are swallowed and this phase reports a false pass.

### 2.5 Log in and check the load

    /wc help

- Expected: the help text prints.
- Failure: the command is unknown. `WoWClearance_Events.lua` did not
  finish loading. Check `Errors/` and the chat frame.

### 2.6 Check for partial loads, which is the real risk

    /wc spike
    /wc history
    /wc bugreport

Each lives in a different file. A command that is unknown while `/wc help`
works means that specific file aborted partway.

Expected: all three respond.
Failure looks like: one unknown command, no error on screen, everything
else fine.

### 2.7 Read the error log

    ls "/mnt/Games/World of Warcraft/_forever_/Errors/"
    cat "/mnt/Games/World of Warcraft/_forever_/Errors/"*.txt | head -50

Expected: empty.

Record every error with its file and line. An `attempt to call a nil
value` here is the signature of the Phase 1 surfaces, not of a missing
`C_*` member - those are all verified present.

### 2.8 Return to steps 1.4 and 1.5

They need the addon installed. Do them now and record the results under
Phase 1 where they belong.

---

## Phase 3: the SavedVariables release gate (CORROBORATION ONLY)

> **UPDATE 2026-09-19: a plain `/reload` reproduces the failure.** Measured
> by the sibling bar-addon port across both scopes. So Phase 0's process
> boundary is NOT required to observe the gate - it is required only to
> distinguish a reload from a cold start, which is a separate question.
> Re-testing a future build is a 40-second check: set the marker, `/reload`,
> look. Keep the full procedure below for the cold-start half.
>
> **Ownership moved 2026-09-19. This addon is no longer the primary
> instrument for the gate.** The investigation belongs to the sibling
> bar-addon port (named in `docs/PORT_STATUS.md`), because it declares
> `SavedVariables` **and** `SavedVariablesPerCharacter` in one addon and
> can therefore discriminate account-level from per-character inside a
> single write/read cycle. WoWClearance declares account scope only and
> structurally cannot test the other path. See step 3.7.

**Run this phase only as a second witness, and only for the
ACCOUNT-LEVEL path.** That is still a real role: WoWClearance is an
independently-authored implementation of the same scope, so a matching
result here is genuine corroboration rather than a repeat measurement.
It is no longer the main experiment.

What that changes in practice:

- **Do not run this phase to answer the gate.** The primary run happens
  in the sibling port. Run it when that port asks for a second witness on
  the account path, or when you are already here for Phases 1, 2, 4 or 5
  and it costs little.
- **Record which scope produced every result.** A result from here is an
  account-level result and nothing more. Labelling it that way is the
  whole value of the corroboration.
- **Do not retire or relax the gate on the strength of this phase
  alone.** It still blocks release, and see 3.8.

The gate remains the only thing blocking a release, and the reason
`CLAUDE.md` says do not publish. The phase sits third because it needs
the addon installed (Phase 2) and an unambiguous load baseline (Phase 1).

The procedure below is kept in full deliberately. It is the
best-developed version of this protocol and the sibling port should
inherit it rather than rebuild it - in particular Phase 0's
outside-the-client process boundary and the bad-marker list in 3.1.

> **DESTRUCTIVE.** This phase deliberately causes saved settings to be
> overwritten, and on this client the overwrite is the expected result.
> Back up before starting. Do not run it on a WoW account whose other
> addon settings you care about, because the client rewrites every
> addon's file on exit, not just ours.

### 3.0 Back up first. Do not skip.

    cp -a "/mnt/Games/World of Warcraft/_forever_/WTF" \
          "~/Projects/.sv-evidence-$(date +%Y%m%d-%H%M%S)-preRun"

Expected: a complete copy. Verify it is non-empty before continuing.

The live `WTF` tree keeps only two generations (`X.lua` and `X.lua.bak`)
and rotates one away per flush, so a third launch destroys the evidence
of the first. Snapshot outside the tree or lose it.

### 3.1 Choose a marker that CANNOT be regenerated from defaults

This is the step people get wrong, and getting it wrong produces a
confident false PASS.

**Bad markers, every one of which looks like a good one:** a version
number, a build string, a schema version, a formatted timestamp, a
profile named `Default`, a file size, an md5 of the whole file. Each is
reproduced byte-identically by an init path that never read your file. A
previous session reached "the file changed, so it was loaded and updated"
from a differing hash, when the only field that differed was a
regenerated `lastModified`.

**Good markers:** a random nonce, or real user data that no defaults
table contains. For WoWClearance the natural one is a **Sell List entry
for a specifically named item**, because nothing in `EnsureDB` can invent
it.

The test is not "did I write something down". It is "could this exact
value have been reconstructed by code that never read my file".

**A worked example, reproducible on disk right now.** The sibling bar
addon's two account-scope generations differ by exactly one field:

    5c5
    < ["lastModified"] = 1789814753,
    ---
    > ["lastModified"] = 1789815787,

Everything else is byte-identical, `fontSize` still at its shipped
default. Size matches; md5 does not. A tester reaching for `md5sum`
because it is the careful option concludes "the file changed, so
something was loaded and updated" - and nothing survived. That is a full
rebuild wearing a fresh timestamp.

This is why the marker rule is about non-regenerability and not about
rigour. The more rigorous-feeling check is the one that misleads.

### 3.2 Set the marker in-game

1. `/wc` to open the panel.
2. Add a distinctive item to the **Sell List** (any junk item works; note
   its exact name).
3. Also change one numeric setting away from its default and note both
   the setting and the value.

Expected: the panel confirms both.

### 3.3 Exit the client cleanly and capture

Quit via the game menu, not a kill. Then:

    cd "/mnt/Games/World of Warcraft/_forever_/WTF/Account/<account>/SavedVariables"
    ls -la | grep -i clearance
    grep -n "<your item name>" WoWClearanceDB.lua

Expected: the file exists and **contains your item name**. Writing is
known to work on this client, so a failure here is a different and new
bug, and means the rest of the phase cannot be interpreted.

Snapshot the tree again to a timestamped directory before relaunching.

### 3.4 Relaunch and confirm the boundary

Start the client. Run 0.2 and confirm the PID changed. Do not proceed on
a `/reload`.

### 3.5 Read the verdict OFF THE SCREEN, before touching any file

Log in, `/wc`, and look at the Sell List.

- **Marker present** - the gate may have lifted. Do not celebrate yet;
  go to 3.6, because an in-memory carry-over across a fast relaunch has
  fooled this test before.
- **Marker absent, list empty** - the gate stands, as currently
  documented.

An on-screen reading is worth capturing separately because every other
strand of evidence runs through somebody interpreting a file.

### 3.6 Confirm from disk, then confirm the overwrite

Exit cleanly again and:

    grep -n "<your item name>" WoWClearanceDB.lua
    grep -n "<your item name>" WoWClearanceDB.lua.bak

Expected if the gate stands: absent from the live file, and present only
in the `.bak`. That is the destructive half of the bug - the defaults
were flushed **over** the saved copy. It is the reason this is a release
gate rather than an annoyance, because a player cannot recover by
quitting quickly and gets no signal anything was lost.

Failure to distinguish: if the marker is in BOTH, you did not cross a
process boundary. Return to Phase 0.

> **`.bak` is the previous SAVE, not the previous SESSION.** Established
> 2026-09-19 by the sibling bar-addon port and verified here: Blizzard's
> own SavedVariables carry `.bak` files too (`Blizzard_CombatLog.lua.bak`
> and five others), and nothing on this machine touches those. The client
> rotates the previous file to `.bak` on every save. No external tool, no
> schedule.
>
> Two consequences, and the second is the one that will bite:
>
> 1. **A `.lua` / `.bak` pair establishes no process boundary by itself.**
>    A `/reload` saves. The pair may span a reload rather than a relaunch.
>    The boundary in this phase comes from Phase 0's PID check, never
>    from the existence of a `.bak`.
> 2. **Do not `/reload` between 3.2 and 3.6.** Every save rotates a
>    generation, and only two are kept. One stray reload rotates your
>    marker-bearing save out of `.bak` and off disk entirely, and you
>    will then read "marker in neither file" as a result when it is
>    actually an erased control. If you reload by accident, restart the
>    phase from 3.2.

### 3.7 This phase does NOT distinguish account from per-character scope

Stated plainly because it is a real limit, not an oversight: WoWClearance
declares account scope only, so **Phase 3 can only ever observe the
account half.** If the client's failure turns out to be scope-specific,
nothing in this phase can reveal that.

Two instruments on this machine carry both scopes in one addon and can
discriminate within a single write/read cycle:

- `WCProbe_SavedVars` (`WCSVProbeDB` + `WCSVProbeCharDB`), which writes
  to disk and needs no chat capture
- the sibling bar addon, which declares both and is the cleaner
  instrument because it is real usage rather than a probe

Per-character files live under
`WTF/Account/<account>/<realm>/<character>/SavedVariables/`, not the
account `SavedVariables/` directory. On this install that is
`70/Serv-Aszune/`. Looking for a per-character WoWClearance file there
and not finding one is expected and means nothing.

If you want the scope question answered, run one of those two alongside
Phase 3 on the same boundary and record which scope each result came
from.

### 3.8 What a green result here does and does not mean

A marker that survives proves read-back worked **for this addon, in
account scope, on this one boundary**. It does not clear the gate on its
own, and since the ownership move it cannot: this phase is corroboration,
and the account path is the only one it reaches.

**A limit on the existing evidence, worth stating because it is easy to
over-read.** The gate was established across two independently-authored
addons, which sounds broader than it was: the comparison was only ever
made at **account level**, because this addon has no other scope to
offer. So the existing evidence may be measuring something narrower than
"SavedVariables are destroyed". That is **not** a retraction. The gate
stands and still blocks release. It is a statement about what has been
shown, not about whether the bug is real.

Retiring the gate needs the primary instrument, both scopes, and at
least one corroborating addon on the same boundary. This phase can
supply the third of those and nothing else.

---

## Phase 4: the sell and delete path

> **DESTRUCTIVE AND IRREVERSIBLE. Items sold or deleted here are gone.**
>
> Run this on a character holding nothing you would mind losing. The
> combination that makes this sharper than normal: Phase 3 establishes
> that protection rules **reset to defaults at every launch**, so a Keep
> List or Sell List entry set earlier may not be in effect after a
> relaunch. Set protection rules and test them **in the same session**,
> and re-verify them on screen immediately before any sell.
>
> Do not run this phase at all if Phase 3 showed the gate standing and
> you are testing on a character with real gear. There is no safe way to
> verify a protection rule on a client that forgets protection rules.
> Declining to run this phase is a legitimate outcome of it.

### 4.1 Preparation

1. Use a throwaway or low-value character.
2. Note its exact bag contents and money before starting.
3. Confirm `/wc` shows the addon ENABLED.

### 4.2 Verify the tooltip verdict before selling anything

Hover items in the bag.

Expected: a WoWClearance line reading `Will Sell`, `Won't Sell`, `Keep`
or `Will Delete`.

This is the read-only half of the decision core and it is the safest
thing to check. `NS.Decision.sell(ctx)` is already covered by
`tests/test_decision.lua` under stock Lua, so a mismatch between the
tooltip and the test fixtures means the **adapter** (`buildCtx`, which
reads live client state) is wrong, not the decision logic. That
distinction is what makes this step worth doing.

Failure: no line, or a verdict that contradicts the item's obvious
status (a grey item not marked sellable).

### 4.3 Equipment-set protection, the measured path

Save an equipment set in-game containing an item that is also in your
bags. Hover that item.

Expected: protected, NOT marked `Will Sell`.

This path was measured against a real saved set on 2026-09-18, so a
failure here is a regression against a recorded result rather than a new
unknown. `C_EquipmentSet.GetItemIDs` is the correct member name on this
client; `GetEquipmentSetItemIDs` does not exist and
`tests/test_api_surface.lua` pins that.

`WCProbe_EquipmentSet` (`/wceqprobe`, `/wcevprobe`) covers the same API
independently. It is **chat-only**, so step 0.4 must be on and you must
copy the log out afterwards as in 1.3.

### 4.4 The vendor path

At a merchant, with only worthless items in bags:

1. Open the merchant.
2. Arm and trigger the sell.

Expected: only items the tooltip marked `Will Sell` are sold. Money
increases. The Sold History (`/wc history`) lists exactly what went.

Failure, the one that matters: anything sold that was marked `Keep`,
`Won't Sell`, or protected by an equipment set. **Stop immediately and
record the item, its verdict, and the full history entry.** That is a
gear-loss bug and outranks everything else in this document.

### 4.5 The delete path

Only after 4.4 is clean, and only with genuinely worthless items.

Expected: only items marked `Will Delete` are deleted, and the delete
rescue vetoes fire (an item on the Sell List that is also in a protected
category should NOT be deleted).

The v2.50.2 shirt-loss incident and the v2.51.2 / v2.59.10
Sell-List-vs-tome incidents are golden regressions in
`tests/test_decision.lua`. If any reproduces in-game while the fixture
passes, the adapter is wrong.

---

## Phase 5: secure frame, panels, comms

Lower priority. Run if Phases 0 to 4 leave time.

### 5.1 The secure action button, OUT OF COMBAT

`WoWClearance_ProcessBagsPanel.lua:1188` creates a
`SecureActionButtonTemplate` button driven by `SetAttribute("type","macro")`
plus `macrotext`.

Open the Process Bags panel out of combat and click Process Next.

Expected: it casts.

This doubles as a cross-repo data point. A sibling port's static reading
of the shipped UI source suggests secure **snippet compilation** is broken
on Forever via a TOC load-order asymmetry, while ordinary attribute values
are unaffected. Our button sets no code-string attribute, so it should
work. If it does NOT, that reading is incomplete and the sibling ports
need to know.

**Test out of combat.** This panel has a known combat-lockdown fragility
(two in-game bugs on v2.37.x where the build callback aborted partway), so
an in-combat failure is our own inherited bug and proves nothing about the
client.

### 5.2 Panels

Open each: Main, Help, Quickstart, Process Bags, Stats, Sold History.

Expected: each renders, and resizing the options window reflows widgets
rather than freezing them at build-time width.

`WCProbe_ColorPicker` (`/wccpprobe`) covers the colour-picker API
separately. **Chat-only**: step 0.4 on, copy the log out afterwards.

### 5.3 Comms

`C_ChatInfo.RegisterAddonMessagePrefix` is **mandatory** on this client;
without it `CHAT_MSG_ADDON` is never delivered and the transport fails
silently. It is registered before the listener attaches, and
`tests/test_comms_version.lua` pins that.

    /wc commtest

Expected: a response. Silence is the documented failure mode, so silence
here means check the prefix registration, not the message format.

Note `C_ChatInfo.SendAddonMessage` carries `secretArguments: NotAllowed`
on Forever.

---

## Phase 6: the v0.6.0 Forever-review fixes

Every fix below is pinned by a test, but each rests on client behaviour
that only the game can confirm. Install first (Phase 2) and grep the
install directory for `WC_secureLocked` to prove the copy is current.

### 6.1 First login after the surname key change

Before logging in, note one Keep List and one Delete List entry.

Expected: both lists are intact after login. On disk,
`WoWClearanceDB.chars` gains a `"First Surname-Realm"` key and still holds
the old `"First-Realm"` one (it is copied, never moved).

### 6.2 Delete confirm answers only our own popup (throwaway items only)

Put a cheap grey on the Delete List and let auto-delete remove it away
from a vendor. Within a few seconds, drag a DIFFERENT throwaway item out of
your bags onto the ground.

Expected: Blizzard's delete popup stays up for you to answer. WoWClearance
must never type the confirm word or click Yes on it. If it does, stop and
report: that is the bug this fix exists for.

### 6.3 Own delete of a rare item

Put a throwaway green or blue on the Delete List and let it delete.

Record which happens: the item leaves the bags with no popup, a popup
appears and WoWClearance confirms it, or the item stays. Whatever happens,
`Total deleted` must only rise if the item actually left. Also note any
`ADDON_ACTION_BLOCKED` naming WoWClearance. This answers whether
`DeleteCursorItem` from addon code needs the popup on Forever.

### 6.4 Combat checks

- `DeleteCursorItem` in combat: with auto-delete on, loot a Delete-List
  item mid-fight. Record whether it is deleted, silently kept, or blocked.
  The WC-TRAP at the auto-delete scan rests on 3.3.5a behaviour.
- Settings window: open Process Bags, enter combat, try to drag, resize,
  close and switch panels. Expected: none of them act, one chat line
  explains, and `Logs/taint.log` shows no blocked call.
- Dropdowns: `/console taintLog 2`, open each settings dropdown (Merchant
  bind filters, Process Bags "Disenchant up to", the list "Show:" filter,
  the Loot Log and Sold History rarity filters), then fight something.
  Expected: no `ADDON_ACTION_BLOCKED` on the action bars. Also check each
  list opens above its window and closes on a click elsewhere.

### 6.5 Loot and money

- Fast Loot: turn it on and Blizzard's auto-loot off, loot a corpse.
  Expected: everything not bind-on-pickup is looted.
- Guild repair as guild leader, with "repair from guild bank" on.
  Expected: the guild bank pays.

### 6.6 Small UI fixes

- Help: "Open Quickstart" shows the floating Quickstart window.
- Options > Keybindings: Process Next is in the WoWClearance section.
- Alt+Right-Click a bank item opens the WoWClearance menu for that item.
- A comparison tooltip (Shift over gear) shows the WoWClearance line on
  every hover, not just the first.

### 6.7 Stats - Server transport (needs two characters on the same realm)

Tick "Share my totals with the realm" on both. Expected: each sees the
other in the user count, `/wc realmtest` reports an echo, and the channel
`wowclearance` is not listed in any chat tab. Untick on one: it leaves the
channel (`/chatlist`). Record `JoinTemporaryChannel` behaviour and whether
the channel number is below General's.

---

## Closing out: capture everything before quitting

    cp "/mnt/Games/World of Warcraft/_forever_/Logs/WoWChatLog.txt" \
       "~/Projects/.ingame-$(date +%Y%m%d-%H%M%S)-full.txt"
    cp -a "/mnt/Games/World of Warcraft/_forever_/Errors" \
          "~/Projects/.ingame-$(date +%Y%m%d-%H%M%S)-errors"

Both are overwritten or rotated by a later session.

**Then verify the copies before quitting**, per 1.3 - a successful `cp` of
a file that no longer holds the result is the documented failure here, not
a hypothetical one:

    grep -c 'WoWClearance' ~/Projects/.ingame-*-full.txt

Zero means the run was not captured. Re-run it rather than recording a
negative result.

---

## What this pass CANNOT settle, even if every step is green

State these limits in any write-up. A green run is weaker evidence than
it feels.

1. **One machine, one build, one account.** Every result is
   `1.60.1.69913` on this install. Forever is under active development
   and the SavedVariables behaviour in particular is an upstream bug that
   can change under you.
2. **A passing Phase 3 does not clear the release gate, and cannot.**
   Since the 2026-09-19 ownership move this phase is corroboration on the
   account path only; the primary instrument is the sibling bar-addon
   port, which carries both scopes. Note also that the existing evidence,
   though drawn from two independently-authored addons, was only ever
   compared at account level. Retiring the gate needs the primary
   instrument, both scopes, and a corroborating addon on the same
   boundary.
3. **Absence of a Lua error is not proof a path ran.** The two worst
   failure modes on this client are both silent: a throw aborts the rest
   of a file, and `PlaySound` / `SetTexture` do nothing without
   complaining. Phase 2.6 samples this; it does not exhaust it.
4. **Phase 4 samples the decision core, it does not cover it.** The
   fixtures in `tests/test_decision.lua` are the coverage. In-game
   testing verifies the **adapter** between live client state and those
   fixtures, and only for the handful of items in your bags on the day.
5. **Nothing here tests a second player.** Comms, guild share and realm
   share need two clients. `/wc commtest` exercises the local half only.
6. **The event-name and `C_*` audits behind this document are static.**
   They establish that every name is *documented* for this client. The
   index derives events from Blizzard's generated documentation rather
   than a shipped event list, so documented-absence has been a reliable
   predictor of client-absence, not a proof of it.
7. **An uncaptured probe result is not a result.** Three of the five
   probes print to chat and nowhere else. If step 0.4 was skipped, treat
   those phases as not run rather than as passed.

## After the run

Record results in `docs/PORT_STATUS.md`, not here. This file is the
method; that file is the record. Keep them separate, because a protocol
that accumulates findings stops being runnable.

Cite what an artefact proves rather than what was on screen at the time,
except in step 3.5, where the on-screen reading is the point and should
be recorded as such.

**Qualify that rule on this client.** "A saved artefact beats a retyped
screenshot" is sound in general and unreliable here, because a saved file
can be overwritten with a defaults state within a minute of being written
and the copy still succeeds. An artefact is better evidence than a
screenshot ONLY once it has been grepped for the field it is supposed to
contain. Until then it is an unverified file, and on this client an
unverified file has already been cited as evidence for a result it did
not hold.
