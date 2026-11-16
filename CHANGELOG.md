# Changelog

WoWClearance's own release history. This project is a fork of
EbonClearance ported from WoW 3.3.5a to WoW: Forever; EbonClearance's
release history is in [its own changelog](https://github.com/powerfulqa/EbonClearance/blob/master/CHANGELOG.md).
Version numbers there belong to that project and do not continue into
this one.

### Unreleased

**Licence version 3.** No change to the addon itself.

- The licence now forbids using the addon to train, fine-tune or evaluate AI models, adding it to AI datasets or indexes, and having AI agents copy or port its code into other software, without the author's written permission. AI help with using or debugging your own copy, or with a pull request, is still fine.
- Copies obtained under licence version 2 stay under version 2.

### v0.8.5

A Process Bags fix for rogues.

- **Process Next moves on after a Pick Lock.** After you pick a lockbox,
  the selection now drops to the next box. Before, it could stay on the
  box you had opened, so the next press did nothing.

### v0.8.4

A licence change. No changes to how the addon works.

- **New licence: Source-Available Licence, version 2.** You may still
  use WoWClearance freely, pass on untouched copies (addon packs
  included) and change your own copy for your own use. You may no longer
  share a changed copy, publish a fork or reuse its code in another
  addon. Send fixes and features as pull requests instead.
- **Credits stay in every copy.** The author line, the in-game byline,
  the provenance globals, `LICENSE` and `AGENTS.md` must stay intact,
  private copies included.
- **Earlier releases are not affected.** v0.8.3 and before stay under
  the earlier attribution licence.
- `AGENTS.md`, `README.md`, `NOTICE.md` and the contributor docs now
  match the new terms.

### v0.8.3

A cleanup release from a full audit of the addon. Fixes only.

- **Junk marks always sell.** An item you mark as junk in DaylightUI's
  bags now sells even when it is a recipe, has an appearance you have not
  collected, or is still tradeable. Before, turning on a sell rule for
  its quality made it stop selling.
- **New characters keep their worn gear.** Every character now gets its
  equipped gear added to the Keep List on first login. Before, only the
  first character on the account did.
- **Delete Next is safer.** It no longer offers a grey item that is in an
  equipment set. The red delete border now shows only on items Delete
  Next will really take.
- **Vendor runs.** The "Talk to the merchant again" line is gone: the
  addon already sells the rest by itself. Reopening a merchant quickly no
  longer breaks the summary.
- **Auto-open containers** tries once and waits when your bags are full,
  instead of retrying several times a second.
- **Process Bags.** The button now stays locked for the whole cast.
- **Guild stats.** Shared stats are only sent to guild and group
  requests, never to a whisper. Best gold/hour is now recorded with the
  Stats window closed, and the right value is shared.
- **Settings window.**
  - The "Open/close settings" key now closes the window too.
  - The minimap button box shows its real state.
  - Delete Settings follows a profile switch.
  - Removing an item in a list panel updates bag borders at once.
  - A list holding an item the game cannot find no longer refreshes all
    session or hides your tooltip.
  - Opening the game's Options first no longer builds every panel.
- **Item levels** show in the inspect window, and stay on the right items
  in combined bags.
- **Recipes** are no longer left unprotected after hovering one before
  its tooltip finished loading.
- `/wc clean upgrades` now agrees with the automatic cleanup when you
  wield a two-handed weapon, and `/wc rules` shows each rule's bind
  filter.
- **Smoother play.** Less work on every spell cast, bag change, vendor
  visit and Help search.
- **Help.** New entry for "Protect high item level gear from auto-mark".

### v0.8.2

- **Fix: junk not sold with DaylightUI.** With "Sell grey items" off,
  WoWClearance did not sell junk but still stopped DaylightUI's own junk
  sale, so junk was never sold. DaylightUI's sale now waits only while
  WoWClearance is selling junk itself.

### v0.8.1

- **Fix: Process Next did nothing.** Pressing Process Next in Process
  Bags (the button or its key) cast nothing, for Pick Lock, Disenchant
  and Convert alike. It works again.

### v0.8.0

The first public release.

- **Sell items at vendors.** A new switch in Merchant Settings turns off
  selling at vendors. Repair and the Force Sell key still work.
- **Sell grey items.** A new switch in Merchant Settings keeps your grey
  items. Greys on your Sell List still sell.
- **Item highlighting switch.** One switch at the top of Item Highlighting
  turns every bag border and item level off and greys out their options.
  Your choices are kept. `/wc highlight` does the same from chat.
- **DaylightUI.** With DaylightUI installed:
  - WoWClearance's windows, settings and Alt+Right-Click menu use its look
    ("Use DaylightUI look" on the main page turns that off).
  - Its bags show the sell and delete borders, and get Delete List, Sell
    List, Account Sell List and Keep List groups.
  - Its Alt+Right-Click menu carries the WoWClearance rows, so there is
    one menu instead of two.
  - Items you Lock in its bags are never sold, deleted or processed, and
    items you mark "Sell as junk" are sold.
  - Only one addon sells at a vendor: its junk sale waits while
    WoWClearance sells.
  - WoWClearance has its own section in its options, a `/dui wc` command,
    a "Vendored" data text, and windows you can place with `/dui unlock`.
- **Cleaner tooltips.** The blue "WoWClearance:" label is gone from item
  tooltips.
- **Reporting bugs.** The Help panel now links to the issues page on
  GitHub.
- **Quickstart.** Two new questions cover the vendor and grey switches,
  and presets turn vendor selling on. Border and item level answers turn
  item highlighting on with them. The fixed item level cap now defaults to
  ten below your level; the old defaults were above every item in the
  game and would have sold all Uncommon and Rare gear.
- **Help and wording tidy-up.** Out-of-date Help answers are corrected,
  three tooltip labels gain a Help entry (new appearance, tradeable,
  locked), and Current Rules lists the appearance and trade protections.
- **Fix: colour rows on Item Highlighting.** Long labels no longer run
  under the colour swatches.

### v0.7.0

- **Last 7 Days.** The Stats panel lists each day's net gold and how many
  items were sold, deleted and looted, across all your characters.
- **Gold looted and Net.** Coin taken from loot windows is now counted.
  Net shows money earned plus gold looted, minus repairs. Session
  gold-per-hour now includes looted gold too.
- **Time filter.** The Loot Log History view and Sold History can show
  only the last hour, day, 7 days or 30 days.
- **Click to filter.** Click a row in the Loot Log or Sold History to show
  only that item; click again to show everything.
- **Better search.** Put a name in "quotes" to match it exactly, and use
  `||` to search for more than one thing (`wool || silk`).
- **Tooltip lines.** Item tooltips show `Bank: N` when you have some in
  the bank, and how many you have sold and looted across all characters
  (turn that off on the Item Highlighting page).
- **Rings in sorting bag addons.** Bag addons that sort items into groups
  now get the coloured rings on their item buttons too.
- **Loot Log and Sold History match your bag addon's window opacity.**
- **Minimap button** uses the standard minimap button library when
  another addon has loaded it, so button trays show its real tooltip.

### v0.6.3

- **Fix: right-click on bag items works again.** Using or selling an item
  with a plain right-click could be blocked with "WoWClearance tried to
  call the protected function". Alt+Right-Click and Alt+Shift+Right-Click
  still work, on bags and the bank.
- **Merchants that buy nothing.** Selling stops at once with "This merchant
  doesn't buy items. Selling stopped." instead of trying every item.
- **Busy sales are retried.** Items the game dropped as "Object is busy"
  get another try, up to three times per visit.
- **Sell and Delete groups.** Bag addons that sort items into sections
  get "WoWClearance: Sell" and "WoWClearance: Delete" groups where rings
  can't be drawn.
- **Minimap button** stays where a button tray put it.

### v0.6.2

- The minimap button no longer has a black disc spilling past its gold ring.

### v0.6.1

- **One look with RaidLootController.** Chat lines now start with
  "WoWClearance:" instead of "[WoWClearance]", and item tooltips show
  "WoWClearance:" once with the other lines indented under it.
- **Shared copy window.** The bug report, rules, dumps, Help links and the
  update link all open the same copy window. Click the text, then Ctrl+C.
- **Minimap button.** New tooltip layout with the click hints last, and
  the button no longer runs code every frame when you are not dragging it.
- **Coin icon everywhere.** The settings window now uses the same coin icon
  as the minimap button and the addon list.
- **Version from the addon list.** The version shown in game comes from the
  .toc, and the addon list title no longer repeats it.
- **How button.** Slash commands that need more typing show How instead
  of Run, and print what to type (opening chat from the addon tainted it).
- **Fix:** messages from other players are checked for readability one value
  at a time, so a hidden sender no longer slips through.

### v0.6.0

Not released. The SavedVariables bug appears fixed from client build
70170 (see `docs/PORT_STATUS.md`), so data that outlives a session is
worth building again.

- **Loot Log History.** A fourth view lists every pickup with when, who,
  what and how many: your own loot on every character, plus what group
  members loot when the game shows it in chat. Keeps the last 20,000 and
  is saved between sessions.
- **Two new protections**, on by default: keep gear with an appearance you
  haven't collected, and keep loot you can still trade or refund. They stop
  the automatic sell rules only; the Sell List and Allow Sell still sell.
- **The reagent bag is now included.** Every bag walk stopped at bag 4, so
  tints, lists, auto-delete and Process Bags never saw the reagent bag.
- **Bound state is read per copy.** One worn copy of a bind-on-equip item
  used to mark every copy as bind-on-pickup for the session, so a "BoP
  only" rule could sell a tradeable copy.
- **Process Bags cast tracking works again.** The cast event's payload
  changed shape on this client; the cast counts, the cast log and the Pick
  Lock follow-up never fired.
- **Item levels are the copy's real level**, on both the bag item and the
  equipped item it is compared with.
- **Addon compartment entry** on the minimap's addon list button.
- **Sold History is saved between sessions**, per character: the last
  5,000 sales and 5,000 deletes. Entries from an earlier day show their
  date.
- **Shift+L opens the Loot Log** by default. Set once at first login, and
  only if Shift+L is free and the Loot Log has no key yet.
- **Help** explains that Blizzard's Sell All Junk button ignores the Keep
  List.
- Faster: bag tooltips no longer rebuild the verdict five times a second
  while hovered, hidden bag buttons are no longer repainted, and the Loot
  Log asks the client for missing item data directly.
- **Safer delete confirm.** WoWClearance only answers the delete popup for
  the exact item it just picked up, within a second. Before, after one
  auto-delete it could confirm a popup you raised yourself for a
  different item still on the Delete List.
- **Recipe and tome detection** reads the item's class from game data and
  no longer remembers "not a tome" after a blank tooltip.
- **Gear whose appearance data is still loading is kept**, not sold.
- **Fast Loot works again.** It read the wrong loot-slot value and skipped
  every item.
- **Guild repair works for guild leaders**, and never claims more than the
  guild bank holds.
- **Guild and server stats no longer count you twice.** Your own messages
  were not recognised as yours, because the game names you with your
  surname.
- **Copying a link from Help** no longer breaks Enter and Escape in the
  game's own popups.
- **English only.** The French and German translations and `/wc locale`
  are removed in this version.
- **New dropdowns.** Every settings dropdown is now WoWClearance's own. The
  game's old dropdowns could get your action bars blocked in combat after
  you had used one.
- **Update notice and guild stats ignore fake messages.** The update notice
  only shows a plain version number, and guild stats only count answers to
  your own request, once per player, with sane numbers. The name shown is
  always the real sender's.
- **Fixes:** the Help panel's Open Quickstart button no longer traps
  Quickstart inside the settings window; Process Next now sits with the
  other WoWClearance keybindings; the Help panel border shows; comparison
  tooltips keep the WoWClearance line; Alt+Right-Click works on bank items.
- **Characters with the same first name keep separate lists.** Saved
  per-character data now uses your full name with surname. Your existing
  lists are copied over on first login.
- **Addon messages wait out boss fights** and retry after a refused send
  instead of going quiet for 30 seconds. Version checks and guild stats
  also reach dungeon-finder groups.
- **The settings window stays put in combat while Process Bags is open**
  (the game refuses to move or close it then); a chat line says why.
- **Stats - Server works on this game.** It now talks over addon messages
  on a private channel (the old chat-text method could never send here and
  errored in boss fights). It joins only once you tick sharing, leaves when
  you untick, and Refresh does nothing until you opt in. It reaches players
  on your own realm only.
- **Deleting is now a key or button press.** This game blocks addons from
  deleting items by themselves (auto-delete got stuck with the item on
  your cursor). Bind "Delete next Delete List item" under Keybindings, or
  press Delete Next on the Delete List panel: each press removes one item.
  "Auto-delete on pickup", "Auto-delete grey items on loot" and deleting at
  a vendor are gone; Delete List items are no longer sold either.
- **The game's delete popup is yours to answer.** WoWClearance used to click
  Yes on it for you; the game blocks that, so the popup now waits for you.
- **Combat safety:** Process Bags can't be opened in combat (the game won't
  let it move), and its cast button no longer changes state mid-fight.
- **Mark grey items for deletion** (Delete Settings, off by default): Delete
  Next also removes grey items once your Delete List is clear, cheapest
  first.
- **Delete Next on blue, epic and quest items** now leaves the game's
  confirm popup up for you to click Yes (it used to close at once).
- **Characters sharing a first name** no longer inherit each other's lists
  after the save-slot change: the copy happens once per old save.
- **Level-locked upgrades stay protected.** Gear you are too low to wear
  kept losing its "Keep (upgrade)" mark and could then be sold.
- **"Protect iLvl 80+ items from auto-mark" works** and also guards
  equipment-set, worn and quest items from the PvP-gear auto-mark.
- **Fixes:** Alt+Right-Click on bank items, crafted and auction items no
  longer counted as loot, gold totals count only what actually sold, the
  first Stats - Server refresh after opting in, item levels on the buyback
  tab, the lockbox reminder after combat, and a broken saved Loot Log no
  longer stops loot recording.
- **Faster:** WoWClearance no longer runs its own tooltip lines on its
  hidden scans, Process Bags reads soulbound from the bag, the Loot Log
  history loads after login, and Sold History redraws faster.
- **Tidier panels:** labels keep their gold colour, the Merchant rules and
  list filters line up with the new dropdowns, every window title reads
  "WoWClearance: ...", close buttons sit in the same place, menus share one
  look, small buttons are easier to click, and the Profiles pages scroll
  instead of cutting off on a small window.
- **Help search highlights what you typed** in yellow, in the questions
  and answers it keeps.
- **The sell info and bug report windows** no longer hide their first line
  under the title.
- **Your own deletes are counted only once the item is gone.** A delete the
  game refused no longer shows up in the totals or Sold History.
- **Help and Process Bags text** no longer mention Milling or Prospecting,
  which this game does not have, and point to the right menus.

### v0.5.0

Not released. First in-game measurements against the live client. One of
them found the addon would have died on its own first load.

- **Fixed a load-breaking bug: `LEARNED_SPELL_IN_TAB` was registered bare.**
  An in-game event probe on build 1.60.1.69913 measured that event as
  REJECTED. `RegisterEvent` throws on an unknown event name and the
  uncaught throw aborts the rest of the chunk, so registering it at line
  7301 of a 7,720-line file silently discarded `SPELLS_CHANGED`,
  `PLAYER_REGEN_ENABLED`, `LOOT_READY`, `GROUP_ROSTER_UPDATE` and ~400
  further lines of top-level code. Fast Loot, the combat-exit wake, the
  tome-cache invalidation and the version gossip were all gone, with no
  error after the first. This is the **third** instance of a failure class
  the project had already documented twice and never swept for; the
  forever-addon-kit README names this very event as its worked example.
- **The rejected-event guard is now a class, not a one-off.**
  `tests/test_comms_version.lua` checked only `PARTY_MEMBERS_CHANGED`, and
  passed the entire time `LEARNED_SPELL_IN_TAB` was registered. It now
  walks a list of four measured-rejected names; adding to that list is
  cheap, removing from it requires a fresh in-game measurement.
- **Swept every registered event name, which had never been done.** All 18
  events this addon registers were checked against a Forever-flavour event
  index. The one that was fixed was the only bad name. The sweep also
  established why nothing caught it: `RegisterEvent` takes a string, so
  `luacheck` cannot distinguish a real event from an invented one. A file
  registering `"THIS_EVENT_DOES_NOT_EXIST_ANYWHERE"` passes our gate at 0
  warnings / 0 errors. That is structural rather than a config gap, and it
  is now recorded as porting lesson 15 and in the luacheck section of
  `CLAUDE.md`: a gate that passes because it cannot see looks exactly like
  a gate that passed because the code is correct.
- **The release gate now states the failure correctly.** It is not that
  settings fail to persist. The relaunched client starts from defaults and
  then flushes those defaults back OVER the saved copy, so the previous
  configuration is destroyed rather than ignored, silently, leaving a
  well-formed file. For a bag addon that is the whole argument: protection
  rules that reset are dangerous, but rules that reset AND overwrite
  cannot be recovered by quitting quickly and give the player no signal
  anything was lost. `CLAUDE.md`'s banner said "silently reset", which
  understated it.
- **Documented the re-test trap, because the obvious check fails.**
  Account scope cannot be verified by comparing files: an init path that
  deterministically rebuilds an identical default profile produces the
  same size on both sides of a cold start, differing only in a
  regenerated timestamp. A size check reads as a pass; a hash check reads
  as "something changed", which is true, worthless, and looks like a real
  negative result, so the more rigorous-feeling check is the more
  misleading one. Whoever re-tests this when Blizzard ships a fix needs a
  marker that cannot be regenerated from defaults. The section now names
  the BAD markers too (version number, build string, schema version,
  formatted timestamp), since nobody picks one of those on purpose.
  Mutation-tested: reinstating the registration fails exactly one check.
- **`tests/test_locale_coverage.lua` had never actually run.** Its key
  extractor called `load("return " .. literal)()`, but in Lua 5.1 `load`
  takes a reader function, not a string. The call threw, the surrounding
  pcall swallowed it, zero keys were extracted, and the two
  forward-coverage checks then iterated an empty set and reported PASS. CI
  runs lua5.1, so the project's "systematic backstop" against untranslated
  strings had been green and empty since v2.61.0.
- **19 real translation gaps were sitting behind it**, now added to both
  `_frFR` and `_deDE` as empty slots that fall back to English, per the
  templates' existing convention. Mostly Help / FAQ answers, the
  Quickstart turbo-vendoring line, and two Keep / Delete panel headers.
- **A non-vacuity floor guards it from here.** The suite now fails if the
  extractor finds implausibly few keys. Mutation-tested by restoring the
  original bug: the three real checks still PASS and only the floor
  catches it, which is exactly how this survived so long.
- **The SavedVariables release gate is CONFIRMED rather than inherited.**
  The 2026-09-18 "possibly fixed" reading is withdrawn. Across a real cold
  start at 12:42:35, two addons whose code was provably unchanged each
  lost on-disk content: this project's probe (account `nonce=619127`,
  per-character `216407`) and a sibling port's shipping addon (14,444 B
  with 15 preset markers down to 5,723 B with none). Both scopes, both
  storage patterns. Writing works; reading at launch does not.
- **The control that hid it for a day is recorded as a porting lesson.**
  `GetTime()` on this client counts from SYSTEM BOOT, not client launch,
  so every probe's cold-start control reported "reload-level only" 34
  seconds into a genuine fresh process. Three ports reasoned from it for
  hours. Nothing inside the client separates a reload from a relaunch;
  establish the boundary externally.
- **Two porting lessons added**, including the one that prompted this
  release's doc sweep: a retraction is a message, an assertion is an
  object, and only objects get read later. Its in-tree instance is fixed
  in the same pass - `GetCoinTextureString` was corrected in one place
  while two summaries still listed it as absent, conflating "the global is
  gone" with "the capability is gone".

luacheck stays at 0 warnings; all 11 suites pass.

### v0.4.0

Not released. Port work item 2 complete; the addon still does not run on
WoW: Forever.

- **The Project Ebonhold affix and chance-on-hit subsystem is gone.**
  `WoWClearance_Protection.lua` drops from 2,690 lines to about 400. Out
  went random-affix parsing, the engraving-spell catalog, the chunked
  spellbook scanner, chance-on-hit detection and its pairing tables, the
  Anvil bridge, and the proc-text suggester. What remains there is the
  realm-agnostic part: the shared bind-type / Resilience tooltip walk and
  the tome / recipe detection helpers.
- **The decision core is affix-free.** `Decision.sell` loses the
  rank-floor, owned-dupe and extracted-proc sell signals, the affix and
  chance-on-hit keep blocks, and the iLvl-ceiling gate that served only
  the affix sell paths. `Decision.deleteEligible` loses its affix veto.
  Every non-Ebonhold protection is untouched.
- **Roughly 12,000 lines removed across the three stages**, including
  eight diagnostic slash commands, ten settings, four account-DB tables,
  two bag tints, 34 Help entries, and the affix questions in Quickstart.
- **One setting was rescued rather than removed.** The "Protect iLvl 200+
  items from auto-mark" checkbox sat inside the affix widget run, but its
  setting also gates the Resilience and learned-recipe auto-marks, which
  survive. It is re-created outside that run so it stays reachable.
- **Test suites: 13 down to 10.** `test_affix_resilience.lua` and
  `test_proc_suggester.lua` were entirely about the removed subsystem.
  Where an invariant still had meaning it was rewritten rather than
  dropped, so the "helpers stay on WC_compCache" rule now pins the seven
  surviving Protection helpers.
- **Two API findings from a parallel Forever port were verified against
  this codebase and recorded**, both of which a rename alone would have
  missed: `C_ChatInfo.RegisterAddonMessagePrefix` is mandatory (without it
  the comms layer loads clean and never fires), and `RegisterEvent` throws
  on an unknown event, which aborts the rest of the file -
  `WoWClearance_Events.lua` registers `PARTY_MEMBERS_CHANGED`, measured as
  rejected on this client.
- **The earlier "secrets do not reach item data" claim is corrected** to
  out-of-combat only. The probe sampled at `PLAYER_LOGIN`; the secrecy
  gate follows `InCombatLockdown()`, about three seconds later. The probe
  now has a lockdown sampler that asserts it is actually under lockdown
  before recording.

luacheck stays at 0 warnings; all 10 suites pass.

### v0.3.0

Not released. Port work item 2, stages A and B; the addon still does not
run on WoW: Forever.

- **Project Ebonhold removal changed from "switch off" to surgical
  deletion**, on the maintainer's call. The v0.2.0 kill switch is now
  temporary scaffolding that keeps the features off while the code comes
  out in stages; it goes with the last of the affix surface.
- **Stage A: the chance-on-hit proc-pairing guild share is gone.** It
  pooled itemID-to-affix-spellID pairings between guildmates so a player
  inherited other people's Anvil extractions. Forever has no Anvil, so
  there is nothing to pool. Removed `WoWClearance_ProcShare.lua`, its
  suite, the Guild panel opt-in and refresh button, the
  `shareChanceProcs` setting, `/wc procsharetest`, the post-login pull,
  and the bug report's proc-pairing section.
- **Stage B: both companion pets are gone**, and with them the loot-cycle
  engine built around them. Deleted `WoWClearance_Companion.lua` (chat and
  speech-bubble filtering) and `WoWClearance_ScavengerPanel.lua`, plus the
  pet-tick engine, summon / dismiss / resummon paths, the bag-full swap
  cycle and its watchdog, the four-state loot-cycle machine, the mount
  dismiss-and-restore handler, and the loot-silence stuck detector.
- **Every vendor is now allowed.** The "Sell at" merchant-target dropdown
  and `DB.merchantMode` are removed: all three modes existed only to
  include or exclude the Goblin Merchant, so without it they collapsed to
  one answer.
- **Settings removed:** summon toggle and delay, summon-only-out-of-combat,
  re-summon after loading screens, auto-loot cycle, bag-full threshold,
  companion name overrides, and the chat / bubble mute flags. Quickstart
  loses Q2, Q6 and Q12; Help loses its Scavenger section and three
  companion entries; the bug report loses its Scavenger and swap-diagnostic
  sections; the "Target Goblin Merchant" keybinding is gone.
- **Kept, and each verified independent rather than assumed:** Fast Loot
  and auto-open lootable containers (stock looting behaviour that never
  touched the pet path), free-bag-slot counting, the shared delay timer,
  the profession-cast counters, and the decision core's `junkOnly`
  parameter.
- **Two tests were inverted rather than deleted**, because "it stays gone"
  is the invariant now: Quickstart must not reintroduce the three companion
  questions (their settings no longer exist, so a restored question would
  write nothing), and the two looting toggles must stay on the Process Bags
  panel - they only survived this release because v2.74.0 had already moved
  them off the companion panel.
- **In-game API probe run against the live client** (build 1.60.1.69913).
  It resolves the two planning blind spots and the outstanding safety
  question: `Settings` and `MenuUtil` are both present, so the options-UI
  migration is unblocked; and bag, item and tooltip data are **not** secret
  on Forever, so the sell/keep/delete core is safe as designed. Full
  results, including the container-field mapping for the item layer, are in
  `docs/PORT_STATUS.md`.

Net effect: about 3,500 lines removed across two stages. luacheck stays at
0 warnings; all 12 suites pass.

### v0.2.0

Not released. Port work item 2; the addon still does not run on WoW:
Forever.

- **Project Ebonhold subsystem switched off.** `peFeaturesActive()` and
  `peFeaturesVisible()` now both hard-return false from a single kill
  switch, `WC_compCache.PE_SUBSYSTEM_ENABLED`, in
  `WoWClearance_Protection.lua`. Forever has no affix system, no Anvil
  and no extraction, so every affix and chance-on-hit surface had nothing
  to act on. This hides affix protection and its dupe / rank / BoE
  controls, the iLvl auto-mark shield, the Known Affix and Needed Affix
  bag tints, chance-on-hit guild sharing, the merchant-target dropdown
  (every vendor is allowed instead), the Scavenger panel, the affix
  diagnostics, and the matching Help and Quickstart entries.
- **Chance-on-hit protection is disabled, not merely hidden.** It means
  "keep this until you extract the proc", and with no extraction there is
  no release path, so leaving it on would wedge every proc weapon in bags
  permanently. Chance-on-hit weapons are now covered by the ordinary
  rules only (quality threshold, iLvl ceiling, equipped, Keep List,
  blacklist). Whether Forever should get a plain proc-weapon protection
  with no extraction concept attached is an open product question,
  recorded in `docs/PORT_STATUS.md`.
- **The switch is the first statement in both predicates.** In
  `peFeaturesActive` that puts it ahead of the `peSurfacesSeen` latch,
  which otherwise goes true once and sticks. In `peFeaturesVisible` it is
  repeated rather than left to the delegation, so the UI gate cannot be
  re-enabled by a change to the functional gate's body.
- **Three new invariants** in `tests/test_affix_resilience.lua` pin the
  switch's presence, its value, and its position in each predicate. Both
  positional checks were mutation-tested. The subsystem's code is
  deliberately left in place: its bodies and tests are the specification
  the eventual incremental deletion gets checked against.

All 13 invariant suites pass.

### v0.1.0

Not released. Repository bootstrap and rebrand only; the addon does not
yet run on WoW: Forever.

- **Forked from EbonClearance v2.77.1.** Fresh repository with no shared
  git history. Working tree copied, not cloned, so this is not a
  GitHub fork of the upstream project.
- **Rebranded to WoWClearance.** All 38 `.lua` source files renamed, plus
  the `.toc`. Identifiers moved across the board: the `EC_` local prefix
  to `WC_`, the `EC-TRAP:` marker to `WC-TRAP:`, the slash commands `/ec`
  and `/ecdebug` to `/wc` and `/wcdebug`, the SavedVariables
  `EbonClearanceDB` / `EbonClearanceAccountDB` to `WoWClearanceDB` /
  `WoWClearanceAccountDB`, the `Bindings.xml` binding names, and the
  provenance globals (`WOWCLEARANCE_IDENT` / `_AUTHOR` / `_ORIGIN`,
  `__WoWClearance_origin` / `_author` / `_watermark`).
- **Wire and export identifiers rebranded.** Addon-message prefix
  `ECLR1` to `WCLR1`, profile export prefix `EC:` to `WC:`, settings-pack
  prefix `EC_PACK_V1` to `WC_PACK_V1`, realm chat channel
  `ebonclearance` to `wowclearance`. The two projects cannot cross-talk
  or mis-parse each other's export strings.
- **Fingerprint salt rebranded**, so WoWClearance and EbonClearance
  produce different watermarks for the same payload.
- **Target client declared as WoW: Forever.** `## Interface:` moved from
  30300 to 16001. The addon is still written against 3.3.5a APIs and
  will not function on Forever until the container, item and options
  layers are ported.
- **Relicensed and re-noticed.** `LICENSE` restates the source-available
  attribution terms for this fork and records the lineage. `NOTICE.md`
  was rewritten rather than carried over: the original's competitive
  timeline and public-history claims belong to EbonClearance and are not
  restated here. Inherited community credit is preserved.
- **Version reset to v0.1.0** to signal pre-release status.

All 13 invariant suites pass unchanged after the rebrand.
