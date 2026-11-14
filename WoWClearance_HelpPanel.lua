-- WoWClearance_HelpPanel - in-game FAQ + reference panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Curated three-section reference panel: troubleshooting FAQ, sell-
-- decision gate explanations, and tooltip-label meanings. Entries live
-- in a file-scope WC_HELP_ENTRIES table; section markers in the list
-- drive the build's section grouping + collapsible state.
--
-- Design spec: docs/specs/2026-05-26-help-faq-panel-design.md
--
-- Cross-file dependencies (resolved lazily at call time):
--   * NS.compCache (WC_compCache.initPanel, setPanelWidth, etc.)
--   * NS.DB         (per-character SavedVariables, captured at OnShow)
--   * NS.MakeHeader / NS.MakeLabel (panel-text primitives)
--   * NS.FitScrollContent (scroll-content height fitter)
--   * (scroll-wrapping is handled inside WC_compCache.initPanel, not called directly here)

local NS = select(2, ...)
local WC_compCache = NS.compCache

-- v2.74.0 readability pass. Pixels between an entry's question and its
-- answer. Used by BOTH the answer's anchor and the entry-height maths in
-- apply(); they must agree or entries overlap in the y-walk.
local ANSWER_GAP = NS.Kit.HELP.answerGap
local L = NS.L

-- ---------------------------------------------------------------------------
-- WC_HELP_ENTRIES
-- ---------------------------------------------------------------------------
-- Ordered flat list. Two entry kinds:
--   * Section marker: { section = "<key>", title = "<display>" }
--   * Content entry:  { q = "<question/topic>", a = "<answer>", panel = "<frameName>" }
-- The build callback walks this list; section markers set the current
-- collapse-state group, content entries render between markers.
-- panel field is optional - when present, an `Open <name>` button
-- jumps to that Interface Options panel.
-- Built lazily (as a function, not a load-time table). Rebuilt on each panel
-- show / search / OpenHelpEntry - cheap (~18 entries), never a per-frame path.
-- Deliberately left visible even though their text mentions PE features:
--   * tshoot-allow-sell-gate - it lists three protection triggers and one of
--     them (tome / recipe) is still live, so the entry still answers the
--     question. Over-listing a trigger is far better than hiding a working
--     explanation.
--   * what-does-ec-do, session-loot, rule-summary and friends - incidental
--     prose mentions inside otherwise generic entries.

local function WC_buildHelpEntries()
    local entries = {
    -- ===================================================================
    -- Section 1: Getting started
    -- ===================================================================
    { section = "gettingStarted", title = L["Getting started"] },

    {
        id = "what-does-ec-do",
        q = L["What does WoWClearance do?"],
        a = L["WoWClearance is a bag manager. When you visit a vendor, it auto-sells your junk and old gear, and protects anything important (gear you're wearing, upgrades, quest items). It can also delete items you don't want, and bulk-disenchant items or open lockboxes."],
        panel = nil,
    },
    {
        id = "first-steps-quickstart",
        q = L["I just installed this. Where do I start?"],
        a = L["The fastest path is the |cffb6ffb6Quickstart|r panel - the Open Quickstart button on the Main panel. Pick one of the four presets (Recommended / Cautious / Farmer / Power) for a one-click setup, or answer a few short questions for a tailored config. Either way only changes |cffffd870settings|r - your Sell, Keep, and Delete lists are never touched. Fresh installs open Quickstart automatically on first login."],
        panel = "WoWClearanceOptionsQuickstart",
    },
    {
        id = "first-steps",
        q = L["I want to set things up manually. What should I do?"],
        a = L["Out of the box, WoWClearance auto-sells grey junk every time you visit a vendor. To go further without Quickstart:\n1) Open Merchant Settings and turn on the rarities you want auto-sold (White / Green / Blue / Epic).\n2) Alt+Right-Click any item you never want sold to put it on your Keep List.\n3) Alt+Right-Click any item you always want sold to put it on your Sell List.\nVisit a merchant and it just works."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "what-are-the-lists",
        q = L["What are the Sell, Keep, and Delete lists?"],
        a = L["Three lists that give you fine control over what happens at a vendor. Sell List: items you always want vendored. Keep List: items you never want touched. Delete List: items you remove with Delete Next (a key or the Delete List button). The Keep List wins over the Sell List, and both win over the automatic quality rules. Add to any list by Alt+Right-Click on a bag item, or on the panel use the Add item box (type an item ID, or a name to add matching items from your bags). Each row shows the item's icon and a quality-colored name; hover it for the tooltip, and use Show: to filter the list by rarity."],
        panel = nil,
    },
    {
        id = "auto-delete-on-pickup",
        q = L["How do I delete items?"],
        a = L["Press |cffb6ffb6Delete Next|r on the Delete List panel, or bind a key to it (Esc menu > Options > Keybindings > WoWClearance > Delete next Delete List item). Each press deletes one item from your Delete List. This game only lets you delete items yourself, so WoWClearance cannot delete them on its own or at a vendor. Delete List items are also never sold."],
        panel = "WoWClearanceOptionsDeletion",
    },
    {
        id = "gate-auto-delete-grey",
        q = L["What does 'Mark grey items for deletion' do?"],
        a = L["Off by default. When on, Delete Next also deletes grey (poor-quality) items once your Delete List is clear, cheapest first, to free bag space. You lose the few copper they would sell for. Never touches keep-listed items, equipped gear, or quest items."],
        panel = "WoWClearanceOptionsDeletionSettings",
    },
    {
        id = "gate-warn-conflicting-addons",
        q = L["What does 'Warn about conflicting addons' do?"],
        a = L["On by default (on the main WoWClearance panel). When another addon that deletes items is loaded and 'Allow items to be deleted' is on, a popup at login points it out. Running both can make items disappear unexpectedly, so turn one of them off. Off = no popup; use it if you run both on purpose."],
        panel = "WoWClearanceOptionsMain",
    },
    {
        id = "see-item-decision",
        q = L["How do I see what will happen to an item?"],
        a = L["Hover any bag item with WoWClearance enabled and the tooltip shows what the addon will do: 'Keep', 'Will Sell', 'Will Delete', or 'Won't Sell' with a reason. For a full step-by-step, Alt+Right-Click the item and pick 'Sell Info' (or Alt+Shift+Right-Click, or type /wc sellinfo)."],
        panel = nil,
    },
    {
        id = "sell-info-menu",
        q = L["What does 'Sell Info' on the right-click menu do?"],
        a = L["Alt+Right-Click a bag item and choose |cffb6ffb6Sell Info|r to open a copyable popup with a step-by-step trace of how WoWClearance decided to keep, sell, or delete that exact item. It lists each check (sell price, your lists, quality rule, known-recipe rule, recipe protection) with a + or - and ends with the final verdict. Ctrl+A then Ctrl+C to copy the whole trace for a bug report. Same readout as /wc sellinfo, for the item you clicked. Use it whenever an item isn't doing what you expected at a vendor."],
        panel = nil,
    },
    {
        id = "slash-commands",
        q = L["What are the slash commands?"],
        a = L["/wc opens the settings. /wc help prints the full command list. /wc sellinfo explains why a bag item will or won't sell. /wc loot opens the Loot Log window. /wc history shows what was sold/deleted and why. /wc bugreport opens a diagnostic snapshot. /wc clean finds items appearing on multiple lists. /wcdebug shows a bag scan summary."],
        panel = nil,
    },
    {
        id = "stats-overview",
        q = L["What does the Stats panel show?"],
        a = L["The Stats panel tracks lifetime totals from using WoWClearance: money earned, gold looted, items sold, items deleted, repairs and repair cost, and Net (money earned plus gold looted, minus repairs). It also shows current-session gold-per-hour (sales plus looted gold) and your best gold-per-hour record (with the zone and date). |cffb6ffb6Last 7 Days|r lists each day's net gold and how many items were sold, deleted and looted, across all your characters. Gold looted counts coin taken from a loot window. Reset Session clears the session deltas; Reset Lifetime wipes the lifetime totals (with a confirmation popup). Stats don't include items bought back from vendors."],
        panel = "WoWClearanceOptionsStats",
    },
    {
        id = "tooltip-extras",
        q = L["What are the Bank and Sold / Looted lines on item tooltips?"],
        a = L["|cffb6ffb6Bank: N|r shows how many of that item are in your bank. It only appears when you have some there.\n\n|cffb6ffb6Sold: N   Looted: N|r shows how many you have sold and looted with WoWClearance, across all your characters. Turn it off with 'Show how many you've sold and looted' on the Item Highlighting page."],
        panel = "WoWClearanceOptionsCharacter",
    },
    {
        id = "stats-character-vs-account",
        q = L["Character view vs Account view in the Stats panel?"],
        a = L["The toggle at the top of the Stats panel picks which totals to show. |cffb6ffb6Character|r shows just the currently logged-in character's lifetime totals - the original behaviour. |cffb6ffb6Account|r shows the same fields summed across every character on this account that has used WoWClearance.\n\nAccount totals start at zero on v2.38.1 install and count forward; older per-character history stays on each character's own Character view. The Account view's Best Gold/Hour ribbon names which character set the record.\n\n|cffffd870Reset Lifetime|r is view-aware: in Character view it clears just this character; in Account view it clears just the account ledger, leaving every character's own totals intact."],
        panel = "WoWClearanceOptionsStats",
    },
    {
        id = "stats-city-filter",
        q = L["Why don't my sales in cities count on the Top Zones list?"],
        a = L["Selling mailboxed items in a capital city (Dalaran, Stormwind, Orgrimmar, Ironforge, Darnassus, The Exodar, Thunder Bluff, Undercity, Silvermoon, Shattrath) isn't farming, so those coppers no longer land on the Top Zones leaderboard. Your total gold earned is unaffected - only the per-zone breakdown skips cities. Sub-town hubs with mailboxes (Booty Bay, Ratchet, Everlook, etc.) still count because their surrounding zones are farmable."],
        panel = "WoWClearanceOptionsStats",
    },
    {
        id = "session-loot",
        q = L["What is the Loot Log window?"],
        a = L["A window that lists what you've looted and how much. It counts what you actually loot - and ignores items you buy from a vendor, take from the mailbox, withdraw from the bank, or receive from quests.\n\nOpen it with the |cffb6ffb6Loot Log|r button on the main settings page or the Stats panel, by typing /wc loot, or with a key you bind under Key Bindings > WoWClearance.\n\nEach row shows how many you looted, that stack's vendor value (quantity x sell price), and that value's share of your total looted gold - so you can see which drops actually earn and which are dead weight (a worthless drop shows a grey dash and 0%, the cue to filter or delete it). Sort by Name, Count, or Gold (click again to flip the order) - Count and Gold differ when a high-volume drop is low-value. Use Show: to filter by rarity and the Search box to find an item by name, and drag the bottom-right corner to resize. Click a row to show only that item; click it again to show everything. In the Search box, put a name in \"quotes\" to match it exactly, and use || to search for more than one thing (wool || silk). Filtering rebases the totals, so narrowing to Epics shows each Epic's share of your Epics.\n\n|cffb6ffb6Right-click a row to hide that item|r - hidden items drop out of the list AND the totals, so the remaining shares rebase (handy when a high-volume filler like cloth is skewing the percentages); the |cffb6ffb6Unhide All|r button restores them. Hold |cffb6ffb6Alt|r and hover a row for a plain-English read on what WoWClearance will do with that item.\n\nFour views: |cffb6ffb6Session|r (looted since login; resets on /reload or Reset Session Stats), |cffb6ffb6Character|r (this character's lifetime), |cffb6ffb6Account|r (a running total across all your characters), and |cffb6ffb6History|r (one line per pickup, with who looted it; hover for when). The first three are tallied per item, so the window stays light no matter how long you farm. Clear wipes whichever view you're looking at."],
        panel = "WoWClearanceOptionsStats",
    },
    {
        id = "loot-history",
        q = L["What does the Loot Log History view show?"],
        a = L["One line per item picked up: who looted it, what, and how many. Hover a line to see when. It covers your own loot on every character, plus what group members loot when the game shows it in chat. Newest first by default; the Sort buttons (Time, Name, Count, Gold) change the order. It keeps the last 20,000 pickups and is saved between sessions. Search matches player names as well as items. The time list next to the search box shows only the last hour, day, 7 days or 30 days. Clear wipes the history."],
        panel = "WoWClearanceOptionsStats",
    },
    {
        id = "junk-button",
        q = L["Does Blizzard's Sell All Junk button follow my Keep List?"],
        a = L["No. The game's own Sell All Junk button at a vendor sells every grey item, including greys on your Keep List. WoWClearance can't change that button. To keep a grey safe, don't press it - while WoWClearance is on, it sells your junk at the vendor by itself and follows your Keep List."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "forever-protections",
        q = L["What do the appearance and trade protections keep?"],
        a = L["Two rules on the Keep Settings page, both on by default.\n\n|cffb6ffb6Keep gear with an appearance you haven't collected|r keeps gear whose look you don't have in your Appearances collection yet.\n\n|cffb6ffb6Keep loot you can still trade or refund|r keeps an item while you can still return it to the vendor for a full refund, or trade it to someone from the group you looted it with.\n\nBoth only stop the automatic sell rules. An item on your Sell List, or one you Allow-Sold with Alt+Right-Click, still sells."],
        panel = "WoWClearanceOptionsBlacklistSettings",
    },
    {
        id = "compartment",
        q = L["Can I open WoWClearance without the minimap button?"],
        a = L["Yes. WoWClearance is listed under the small numbered addon button next to the clock (only when it is enabled for all characters). Left-click it to open settings, right-click to turn WoWClearance on or off. You can also type /wc."],
        panel = "WoWClearanceOptionsMain",
    },
    {
        id = "guild-sharing",
        q = L["What is the Stats - Guild panel?"],
        a = L["Stats - Guild pools data from guildmates (and group members) who also run WoWClearance and have opted in: their best farming zones, combined totals, and most-sold items. It is anonymous by default and guild/group only - nothing is shared server-wide.\n\nTwo boxes on the panel: 'Share my farming data with my guild' turns your sharing on (off by default), and 'Show my name with my shared data' optionally attaches your name (only available while sharing is on).\n\nThe view is a live snapshot taken when you open the panel or click Refresh - it is not saved, so it reflects whoever is online and sharing right now. Your own lifetime stats keep growing as usual; the guild view just re-pools everyone's current totals each time you look."],
        panel = "WoWClearanceOptionsGuild",
    },
    {
        id = "server-stats",
        q = L["What is the Stats - Server panel?"],
        a = L["Stats - Server is a live, anonymous 'odometer' for the whole realm: the combined gold vendored, items sold, items deleted, and items processed by everyone running WoWClearance who is online and sharing right now, plus the realm's busiest farming zones and most-sold items, and a count of how many users are sharing. It never shows names and is not a ranking - just community totals for fun.\n\nSharing is off by default; tick 'Share my totals with the realm' on the panel if you want to join in.\n\nThis uses a private chat channel, which takes one of your 10 chat-channel slots while sharing is on. Turning sharing off leaves it. You only see players on your own realm, even if you see others in town. The numbers reflect who is online and sharing at that moment, not an all-time server record, so they rise and fall as people log in and out.\n\nSharing also puts you on the realm channel, so your normal update alerts (the version-check toggle on the main page) will then tell you about a newer WoWClearance seen anywhere on the realm, not just your guild or group."],
        panel = "WoWClearanceOptionsServer",
    },
    {
        id = "what-are-profiles",
        q = L["What are List Profiles? (and how are they different from Quickstart?)"],
        a = L["List profiles are named snapshots of your |cffb6ffb6Sell List|r and |cffb6ffb6Keep List|r. Save your current lists as a profile, then later swap to a different one in a single click. Quickstart presets are different: they configure the addon's |cffffd870behaviour|r (speed, auto-sell rules, protections) but never touch your lists. For per-character behaviour, see Settings Profiles. Slash commands: /wc profile save <name>, /wc profile load <name>, /wc profile list, /wc profile delete <name>."],
        panel = "WoWClearanceOptionsProfiles",
    },
    {
        id = "what-are-settings-profiles",
        q = L["What are Settings Profiles?"],
        a = L["A settings profile holds a character's selling behaviour: rarity rules, protections, recipe settings, deletion toggles, and vendor speed. Each character picks one on the Settings Profiles panel. Characters on the same profile share it live - change a setting on one and every character using that profile follows. To give one character its own settings, save a new profile there and press Use. Item lists, stats, looting, and visual options are not part of a settings profile. Slash command: /wc sprofile."],
        panel = "WoWClearanceOptionsSettingsProfiles",
    },
    {
        id = "what-is-import-export",
        q = L["What does Import/Export do?"],
        a = L["Import/Export packs your WoWClearance setup into a copyable text string you can share with another character or another player. Export writes a single list (pick Character or Account Sell List) into the export box; copy it with Ctrl+C. Import reads a pasted string and applies it, merging or replacing. Tick 'Full settings pack' to export your per-rarity merchant rules plus all four lists (Sell, Account Sell, Keep, Delete) in one string. Other settings aren't in the pack - to carry your full selling behaviour between characters, use Settings Profiles instead."],
        panel = "WoWClearanceOptionsImportExport",
    },
    {
        id = "version-update-alert",
        q = L["How do I know when there's a new version?"],
        a = L['If another WoWClearance user in your guild or group has a newer version, you get one chat line at login telling you an update is available, with the download link. The newest version seen also shows on the main WoWClearance panel, under the "Tell me when an update is available" box, so you can check it any time. Turn the chat line off with that box. WoWClearance cannot check for updates on its own; it learns the latest version from other players running it.'],
        panel = nil,
    },

    -- ===================================================================
    -- Section 2: Troubleshooting
    -- ===================================================================
    { section = "troubleshooting", title = L["Troubleshooting"] },

    {
        id = "tshoot-not-working",
        q = L["Why isn't the addon doing anything?"],
        a = L["The most common cause is that the master Enable toggle got switched off (a right-click on the minimap button toggles it). When WoWClearance is disabled, it stops selling, looting, and annotating tooltips - but the |cffb6ffb6Sell-border tint|r on bag items is a separate setting, so the addon still |cffffd870looks|r active when it isn't. Three ways to turn it back on: tick the |cffb6ffb6Enable WoWClearance|r checkbox at the top of the panel below, right-click the WoWClearance minimap icon, or type |cffffff00/wc enable|r in chat. Use |cffffff00/wc status|r if you just want to check the current state."],
        panel = "WoWClearanceOptionsMain",
    },
    {
        id = "tshoot-why-not-selling",
        q = L["Why isn't this item selling?"],
        a = L["Alt+Shift+Right-Click the item, or type /wc sellinfo. WoWClearance opens a copyable popup listing each check and tells you which one is keeping the item. Usually one of the protection toggles is catching it - the panel below has all of them."],
        panel = "WoWClearanceOptionsBlacklistSettings",
    },
    {
        id = "tshoot-allow-sell-gate",
        q = L["Why does Alt+Right-Click only show 'Allow Sell' on some items?"],
        a = L["That item is |cffffb84dprotected|r, so the menu hides the Sell / Keep / Delete rows until you consciously unlock it. Protection triggers on a recipe while 'Keep unlearned recipes' (or 'Keep them even after you learn them') is on. Click |cffb6ffb6Allow Sell|r to lift the protection for that item, then the full menu opens. Recipes are a special case: if you've turned on 'Sell recipes you already know' for that rarity, learned recipes of that rarity skip the gate and show the normal menu - so a Blue recipe still shows Allow Sell until you tick Blue under Sell recipes you already know."],
        panel = "WoWClearanceOptionsBlacklistSettings",
    },
    {
        id = "tshoot-equipped-keep",
        q = L["WoWClearance keeps adding my equipped gear to the Keep List."],
        a = L["By default, WoWClearance protects gear you're currently wearing so you don't accidentally sell it. Untick 'Keep gear you're wearing' in the panel below to turn this off."],
        panel = "WoWClearanceOptionsBlacklistSettings",
    },
    {
        id = "tshoot-upgrade-keep",
        q = L["Items keep appearing on the Keep List as 'Keep (upgrade)' that I want to sell."],
        a = L["WoWClearance auto-adds items with a higher item level than what you're currently wearing in that slot, so you don't accidentally vendor a useful piece. Old entries (gear you've since replaced) clean up automatically. To turn off the auto-add entirely, untick 'Keep looted upgrades' in the panel below."],
        panel = "WoWClearanceOptionsBlacklistSettings",
    },
    {
        id = "tshoot-per-char-lists",
        q = L["Why are my Sell / Keep / Delete lists different on each character?"],
        a = L["Each character has its own Sell, Keep, and Delete lists - what you set up on one character won't affect another. For items you want every character to vendor, use the Account Sell List."],
        panel = nil,
    },
    {
        id = "share-sell-list-across-chars",
        q = L["How do I share a Sell List across all my characters?"],
        a = L["Open the Account Sell List panel below. Items added there are shared across every character and combined with each character's own list when you visit a merchant."],
        panel = "WoWClearanceOptionsAccountWhitelist",
    },
    {
        id = "merchant-auto-sell",
        q = L["Does WoWClearance sell automatically, or do I click?"],
        a = L["Automatically. The moment you open a merchant, it starts selling your junk and anything your rules mark 'Will Sell'. No clicking. Selling is paced by the sell-speed setting so it doesn't overload the vendor."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "merchant-force-sell",
        q = L["How do I make it sell right now?"],
        a = L["Just open an allowed merchant and it sells on its own. To trigger a pass by hand (say you changed a setting mid-visit), bind a key to 'Force sell at current merchant' under Key Bindings > WoWClearance. A merchant has to be open for it to do anything."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "merchant-buyback",
        q = L["I sold something by accident - can I get it back?"],
        a = L["Yes. The vendor's Buyback tab holds the last 12 items you sold this visit - click one to buy it back for what it sold for, before you close the merchant. Accidents are rare: WoWClearance never sells Keep-listed items, gear you're wearing, or protected items."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "tshoot-bag-borders",
        q = L["The bag-slot border colors aren't showing."],
        a = L["They're off by default. Tick 'Show borders' in the panel below, then turn on the categories you want colored (Delete, Keep, Account Sell, Character Sell, Junk, Rule). With a bag addon that sorts items into groups, items that will sell or be deleted also get their own \"WoWClearance: Sell\" and \"WoWClearance: Delete\" groups."],
        panel = "WoWClearanceOptionsCharacter",
    },
    {
        id = "tshoot-item-level-overlay",
        q = L["Show item levels on your gear slots"],
        a = L["Tick 'Show item level on slots' in the panel below to paint the iLvl in the bottom-right corner of every equippable item. The setting has 3 sub-toggles: bags (default on when the master flips on), character sheet & inspect, and merchant. Consumables and quest items are skipped. Quality-coloured."],
        panel = "WoWClearanceOptionsCharacter",
    },
    {
        id = "tshoot-disable-per-char",
        q = L["How do I disable WoWClearance on one specific character?"],
        a = L["Three ways: untick the |cffb6ffb6Enable WoWClearance|r checkbox at the top of the Main panel, right-click the minimap button on that character, or type |cffffff00/wc disable|r in chat. The setting is per-character; other characters stay enabled. Type |cffffff00/wc status|r any time to check the current state."],
        panel = "WoWClearanceOptionsMain",
    },
    {
        id = "tshoot-sellinfo",
        q = L["How do I see exactly why a bag item will or won't sell?"],
        a = L["Alt+Shift+Right-Click the item, or type /wc sellinfo. WoWClearance opens a copyable popup with the full step-by-step decision. Ctrl+A then Ctrl+C to copy it for a bug report. The verdict is at the top so you see the answer without scrolling; common rejection reasons include a 'Tip:' phrase naming the panel + toggle you can flip to make the item sellable."],
        panel = nil,
    },
    {
        id = "bugreport-sections",
        q = L["What's in the /wc bugreport window?"],
        a = L["Everything the addon knows about your current session that helps diagnose a report: Issue Summary flags at the top, current settings, sell rules, delete list preview with item names, recent auto-mark events, silent refusals (list adds that were blocked by cross-list conflicts), recent sold + recent deleted, toggles you changed this session, last-event timestamps, cache sizes, proc pairings shared this session (v2.53.0), and your loaded-addon list. Resize the window if the report is long. Ctrl+A then Ctrl+C to copy it for a bug report."],
        panel = nil,
    },
    {
        id = "session-history",
        q = L["What did WoWClearance just sell or delete? (/wc history)"],
        a = L["Opens the Sold History window: everything the addon has sold or deleted on this character, newest first, each line showing the item, how many, and the rule that decided it (Sell List, Auto-sell by rarity, Junk, Delete List, and so on). It is saved between sessions and keeps the last 5,000 sales and 5,000 deletes, so nothing is lost during a long farm. It also records deletes that happened OUTSIDE WoWClearance (you dragging an item off your bags, or another addon) so a missing item can always be traced - those lines say so and never count in your stats.\n\nUse the All / Sold / Deleted buttons, the Show: rarity filter, the time list (last hour, day, 7 days or 30 days) and the search box to narrow a busy list (they all combine), and the Copy button to grab it for a bug report. Click a line to show only that item; click again to show everything. The search box takes \"quotes\" for an exact name and || for more than one thing.\n\nThree ways in: the |cffb6ffb6Sold History|r button on the main panel, /wc history, or Alt+Right-Click any bag item and pick Sold History. Entries from an earlier day show their date. The Clear button wipes it. For the full step-by-step on a specific item still in your bags, use /wc sellinfo instead."],
        panel = nil,
    },
    {
        id = "frame-spike",
        q = L["The game stuttered. Was it WoWClearance? (/wc spike)"],
        a = L["Type /wc spike for a copyable list of frame hitches the addon actually contributed to. The window shows the worst hitches of the session (biggest first, so one big freeze is never pushed out by small ones) and the most recent ones (newest first). Each line shows how long the frame took, which part of the addon was busiest (bag update, vendor cycle, or tooltip), and how much of the frame was the addon's own work - for example 'WC 44 of 260 ms (17%)'. A low share means the stutter came from something else. If the list is empty right after a stutter, that's the answer too: the addon wasn't doing heavy work during any slow frame. Session-only - it clears on /reload. Use /wc perf for the addon's steady-state memory and CPU instead."],
        panel = nil,
    },
    {
        id = "sell-list-vs-tome-protection",
        q = L["Why didn't my recipe on the Sell List actually sell?"],
        a = L["Before v2.51.2 the recipe-protection HARD veto required BOTH Sell List entry AND Alt+Right-Click -> Allow Sell to release. Since v2.51.2, adding to the Sell List is enough on its own. If you're on v2.51.2 or later and a recipe on your Sell List still isn't selling, run /wc sellinfo on it: the trace will tell you which check is catching it (Delete List, Keep List, no vendor value, etc.)."],
        panel = nil,
    },
    {
        id = "tshoot-keep-list-hides-process",
        q = L["My herbs / ore aren't showing in Process Bags."],
        a = L["Items on the Keep List are intentionally hidden from Process Bags' lists - the Keep List wins over everything, including bulk processing. If you've added an item to the Keep List (manually or by auto-protect rules), it won't appear here. Open the panel below to remove items from the Keep List and they'll show up in Process Bags again."],
        panel = "WoWClearanceOptionsBlacklist",
    },

    -- ===================================================================
    -- Section 3: Sell decision gates
    -- ===================================================================
    { section = "gates", title = L["How sell decisions work"] },

    {
        id = "gate-order-of-checks",
        q = L["Order of checks"],
        a = L["When you visit a vendor, WoWClearance walks every bag item through these checks in order:\n1) Has a vendor price?\n2) Grey, on the Sell List, or matches a quality rule?\n3) Currently equipped?\n4) On the Keep List?\n5) A recipe?\nThe first 'no, keep it' stops the chain; the first 'yes, sell it' queues the item."],
        panel = nil,
    },
    {
        id = "gate-grey-items",
        q = L["Grey items sell by default"],
        a = L["Grey items (poor quality junk) sell at vendors, whatever your other settings say, as long as the item has a vendor price. Turn off 'Sell grey items' in Merchant Settings to keep them."],
        panel = nil,
    },
    {
        id = "gate-vendor-price",
        q = L["Items must have a vendor price"],
        a = L["WoWClearance never auto-sells items with no vendor price - the vendor wouldn't pay for them. If you want items like this gone, use the Delete List instead."],
        panel = "WoWClearanceOptionsDeletion",
    },
    {
        id = "gate-sell-speed",
        q = L["Time between sells (sell speed)"],
        a = L["How long WoWClearance waits between each vendored item. Lower = faster; the readout under the slider shows the resulting 'sells per second'. The default 0.1s is safe on most realms. Fast Mode and Turbo Mode (below) override or multiply this for an even quicker clear. A very fast pace can occasionally trip a realm's anti-spam disconnect; raise the interval if vendoring disconnects you."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "gate-quality-rules",
        q = L["Quality rules (White / Green / Blue / Epic)"],
        a = L["Separate auto-sell rules per rarity, in Merchant Settings. Each can be turned on or off independently, with its own item-level threshold to decide which items of that rarity get vendored."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "gate-fixed-vs-equipped-ilvl",
        q = L["Fixed iLvl cap vs. Use equipped iLvl"],
        a = L["Two ways to decide which items get auto-sold per rarity. 'Fixed iLvl cap': sells anything at or below the number you set. 'Use equipped iLvl': sells anything lower than what you're currently wearing in that slot. Empty slots are skipped in the second mode, so you won't lose gear meant for an empty slot. The cap is a HARD ceiling: nothing auto-sells an item of that rarity above it. Only your explicit Sell List or Alt+Right-Click Allow Sell can override it. Set the cap to protect your high-end gear."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "gate-bind-type",
        q = L["Bind-type filter"],
        a = L["An extra restriction per rarity: Any (sells both trade-able and soulbound), BoE only (only sells trade-able items), or BoP only (only sells soulbound). Items without any bind line (consumables, reagents) are only included when set to 'Any'."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "gate-daylight-look",
        q = L["Use DaylightUI look"],
        a = L["With DaylightUI installed, WoWClearance's windows, settings and Alt+Right-Click menu use its look. Turn it off on the main settings page and type /reload to go back to the normal look. Whatever this is set to, items you Lock in DaylightUI's bags are never sold, items marked Sell as junk are sold, and DaylightUI's junk sale waits while WoWClearance sells at vendors."],
        panel = "WoWClearanceOptionsMain",
    },
    {
        id = "gate-item-highlighting",
        q = L["Item highlighting"],
        a = L["One switch for all item highlighting. Off hides every bag border and item level, and greys out their options. Your choices are kept for when you turn it back on. Type /wc highlight to flip it from chat."],
        panel = "WoWClearanceOptionsCharacter",
    },
    {
        id = "gate-sell-at-vendor",
        q = L["Sell items at vendors"],
        a = L["When on, WoWClearance sells your junk and rule matches each time you talk to a vendor. Turn it off if another addon sells for you. Repair and the Force Sell key still work."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "gate-sell-greys",
        q = L["Sell grey items"],
        a = L["When on, every grey item that a vendor buys is sold. Turn it off to keep greys. Greys on your Sell List still sell."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "gate-repair",
        q = L["Repair gear while selling"],
        a = L["When on, WoWClearance pays to repair your gear at every merchant visit that has a repair option. Saves the manual click. Only repairs from your own gold by default; turn on 'Repair from guild bank' below to spend guild funds when available."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "gate-guild-bank-repair",
        q = L["Repair from guild bank"],
        a = L["When on AND 'Repair gear while selling' is also on, WoWClearance prefers guild-bank funds for the repair (when you have guild-repair permission) and falls back to your own gold if the guild bank can't cover it. No effect when 'Repair gear while selling' is off."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "gate-keep-bags-open",
        q = L["Keep bags open after a vendor"],
        a = L["When on, your bags stay open after WoWClearance finishes its sell + delete sweep at a merchant. Useful if you want to review what got sold or pick something up to buy back. When off, bags close on their own once the cycle finishes."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "gate-fast-mode",
        q = L["Fast Mode"],
        a = L["Speeds up the sell cycle (0.05s between items instead of the default 0.1s) and raises the per-visit cap from 80 to 160 items. Useful when you have full bags of grey junk and want them gone in seconds. The faster pace can occasionally disconnect on laggy realms; turn it off if you see disconnects after vendoring."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "gate-turbo-mode",
        q = L["Turbo Mode"],
        a = L["Pops 4 items off the queue per cycle instead of 1, so a full bag empties in seconds. Combine with Fast Mode (0.05s interval) for the fastest possible clear - bag-clear in under two seconds with full bags. Default off. Like Fast Mode, the faster cycle can disconnect on laggy realms; turn it off if you see disconnects. The 'About N sells per second' readout under the slider always reflects what the current combination will do."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "gate-equipped-never-sells",
        q = L["Currently-equipped items never sell"],
        a = L["Even when on the Sell List, WoWClearance won't vendor anything you're currently wearing. Unequip first if you want it sold. Turn on 'Keep gear sets' if you also want gear from Blizzard's Equipment Manager protected."],
        panel = "WoWClearanceOptionsBlacklistSettings",
    },
    {
        id = "gate-keep-list-blocks",
        q = L["Keep List blocks selling"],
        a = L["Items on the Keep List are protected from every auto-sell rule. The Keep List always wins - even if the same item is also on the Sell List, the Keep List blocks it. Add items by Alt+Right-Click or via the Keep List panel."],
        panel = "WoWClearanceOptionsBlacklist",
    },
    {
        id = "gate-automark-known-recipes",
        q = L["Auto-mark unsellable known recipes for deletion"],
        a = L["Off by default. Some soulbound recipes have no vendor price (some low-rank Cooking recipes, some Lockpicking / Skinning schematics), so the vendor refuses them and 'Sell known recipes' can't move them. Turn this on and learned recipes with no vendor price go onto your Delete List instead (one chat line per item). Needs 'Sell known recipes' on in Merchant Settings - this is a companion to it, for the vendor-refused ones. Recipes you don't know yet are never touched. Sellable recipes still sell normally. Keep List / equipped / quest / gear-set items stay safe."],
        panel = "WoWClearanceOptionsDeletionSettings",
    },
    {
        id = "gate-tome-recipe",
        q = L["Recipe protection"],
        a = L["Plans, Schematics, Patterns, Recipes, and mount scrolls are protected from auto-sell so you don't accidentally vendor a learnable spell. Alt+Right-Click 'Allow Sell' to override. 'Protect all recipes' decides whether already-learned items are also protected (useful for saving spares for the auction house or alts)."],
        panel = "WoWClearanceOptionsBlacklistSettings",
    },
    {
        id = "gate-sell-known-recipes",
        q = L["Sell recipes you already know"],
        a = L["Off by default. When you turn it on (on the Merchant Settings panel), profession recipes this character has ALREADY learned are auto-sold at vendors, gated per rarity (White / Green / Blue / Epic). Each rarity also has a bind-type dropdown (Any / BoE only / BoP only), so you can sell known Green BoE patterns but keep all BoP ones for alts, etc. Recipes you have not learned yet are never sold. Learn-state is checked per character, so each alt only sells the recipes it knows. If 'Keep them even after you learn them' (recipe protection, in Keep Settings) is on, it wins and nothing recipe-like sells."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "gate-quest-items",
        q = L["Quest item safety net"],
        a = L["Quest items never auto-sell from a quality rule, even when the rule matches. You can still manually add a quest item to the Sell List if you really want it gone - your direct action overrides the safety net."],
        panel = nil,
    },
    {
        id = "gate-profession-tools",
        q = L["Profession tool safety net"],
        a = L["Fishing poles, mining picks, the Skinning Knife, the Blacksmith Hammer, and the Arclight Spanner are always protected from auto-sell. Add one to the Sell List manually if you have a duplicate to vendor."],
        panel = nil,
    },
    {
        id = "gate-delete-list",
        q = L["Delete List path"],
        a = L["Items on the Delete List are deleted one per press of Delete Next (when 'Allow items to be deleted' is on). They are never sold. The same recipe protections apply on the delete path - use Alt+Right-Click 'Allow Sell' to override."],
        panel = "WoWClearanceOptionsDeletion",
    },
    {
        id = "gate-auto-mark-resilience",
        q = L["Auto-mark PvP gear for deletion"],
        a = L["Some PvP gear with Resilience can't be vendored (no sell price), so unwanted pieces just sit in your bags. Turn this on and WoWClearance scans your bags for items with a Resilience tooltip line AND no vendor price, and adds them to the Delete List automatically.\n\nResilience items that DO have a vendor price are left alone - they'll sell through your normal rules instead, so you keep the gold.\n\nFrom there, Delete Next removes the marked items like any other Delete List item. The toggle needs 'Allow items to be deleted' on. Items already on the Keep List are skipped so you can still keep a specific piece if needed."],
        panel = "WoWClearanceOptionsDeletionSettings",
    },
    {
        id = "gate-announce-auto-delete",
        q = L["Announce deletions in chat"],
        a = L["When Delete Next deletes an item, or WoWClearance auto-marks a piece of unsellable Resilience gear for deletion, it normally prints one chat line per event so you can see what just happened. Turn this off if you find the chat noise unwelcome.\n\nThe toggle silences only those two lines; the manual vendor-cycle summary, the session stats, and the lifetime totals are unaffected, and your Delete List itself still tracks every destroyed item.\n\nA per-rarity filter sits under the master toggle: pick which rarities (Poor / Common / Uncommon / Rare / Epic) should still print. Master off silences everything; master on lets each rarity's tick decide - so you can see Rare + Epic deletions but silence the Greens and Greys that flood the chat while farming."],
        panel = "WoWClearanceOptionsDeletionSettings",
    },

    -- ===================================================================
    -- Section 4: Tooltip labels
    -- ===================================================================
    { section = "labels", title = L["Tooltip labels"] },

    {
        id = "label-keep",
        q = L["Keep"],
        a = L["Plain 'Keep' (no parens) means you manually added this item to your Keep List, either via Alt+Right-Click or the Keep List panel."],
        panel = "WoWClearanceOptionsBlacklist",
    },
    {
        id = "label-keep-equipped",
        q = L["Keep (equipped)"],
        a = L["WoWClearance auto-added this item because you're currently wearing it. The protection lasts as long as it's equipped."],
        panel = "WoWClearanceOptionsBlacklistSettings",
    },
    {
        id = "label-keep-upgrade",
        q = L["Keep (upgrade)"],
        a = L["WoWClearance auto-added this item because its item level is higher than what you're wearing in that slot. If you replace your gear, old entries clean up automatically."],
        panel = "WoWClearanceOptionsBlacklistSettings",
    },
    {
        id = "label-keep-gear-set",
        q = L["Keep (in gear set)"],
        a = L["WoWClearance auto-added this item because it's part of a saved gear set in Blizzard's Equipment Manager. Useful for off-spec gear you carry in your bags."],
        panel = "WoWClearanceOptionsBlacklistSettings",
    },
    {
        id = "label-keep-auto",
        q = L["Keep (auto)"],
        a = L["An older auto-tag from before WoWClearance v2.12.0. Works the same as the more specific 'Keep (equipped/upgrade/gear set)' tags, but the exact origin was lost during an addon upgrade."],
        panel = "WoWClearanceOptionsBlacklist",
    },
    {
        id = "label-keep-quest",
        q = L["Keep (quest item)"],
        a = L["WoWClearance flagged this as a quest item. Quality rules won't auto-sell it. If you really want it gone, add it to the Sell List manually."],
        panel = nil,
    },
    {
        id = "label-keep-prof-tool",
        q = L["Keep (profession tool)"],
        a = L["Profession tool like a fishing pole or mining pick. Always protected. Use Alt+Right-Click 'Allow Sell' to vendor a duplicate."],
        panel = nil,
    },
    {
        id = "label-new-tome-recipe",
        q = L["Keep (new Recipe) / Keep (new Recipe)"],
        a = L["A recipe you haven't learned yet. Protected so you can learn it - just right-click the item. Turn off recipe protection in Keep Settings if you'd rather sell them."],
        panel = "WoWClearanceOptionsBlacklistSettings",
    },
    {
        id = "label-tome-have",
        q = L["Keep (learned recipe)"],
        a = L["A recipe you've already learned. Only shows up when 'Keep them even after you learn them' is turned on. Useful if you save spares for the auction house or alts."],
        panel = "WoWClearanceOptionsBlacklistSettings",
    },
    {
        id = "label-already-known",
        q = L["Already known by this character"],
        a = L["A grey line under the WC verdict. Appears on any recipe your character has already learned, even when recipe protection is off. Quick visual cue when you're deciding whether to vendor a duplicate or save it for an alt."],
        panel = nil,
    },
    {
        id = "label-will-sell",
        q = L["Will Sell"],
        a = L["Item is on your Sell List. WoWClearance will vendor it the next time you visit a merchant."],
        panel = "WoWClearanceOptionsWhitelist",
    },
    {
        id = "label-will-sell-account",
        q = L["Will Sell (your Account List)"],
        a = L["Item is on your Account Sell List (shared across all characters). Will vendor at the next merchant visit."],
        panel = "WoWClearanceOptionsAccountWhitelist",
    },
    {
        id = "label-will-sell-char",
        q = L["Will Sell (your Character List)"],
        a = L["Item is on this character's Sell List. Will vendor at the next merchant visit."],
        panel = "WoWClearanceOptionsWhitelist",
    },
    {
        id = "label-will-sell-junk",
        q = L["Will Sell (junk)"],
        a = L["Grey item with a vendor price. Always sells regardless of other settings."],
        panel = nil,
    },
    {
        id = "label-will-sell-quality-rule",
        q = L["Will Sell (Blue, lower than equipped), etc."],
        a = L["A quality rule matched. The text in parentheses tells you which one. 'Lower than equipped' means the rule is set to compare against your currently-worn iLvl. 'iLvl X, cap N' means a fixed iLvl cap matched."],
        panel = "WoWClearanceOptionsMerchant",
    },
    {
        id = "label-will-delete",
        q = L["Will Delete"],
        a = L["Item is on the Delete List, and deletion is on. Delete Next (a key or the Delete List button) will delete it."],
        panel = "WoWClearanceOptionsDeletion",
    },
    {
        id = "label-wont-sell-equipped",
        q = L["Won't Sell (equipped)"],
        a = L["Item is on the Sell List but you're currently wearing it. Unequip first if you want it sold."],
        panel = nil,
    },
    {
        id = "label-wont-sell-no-value",
        q = L["Won't Sell (no value)"],
        a = L["Item is on the Sell List but it has no vendor price. WoWClearance can't sell items vendors won't buy. Try the Delete List if you want it gone."],
        panel = "WoWClearanceOptionsDeletion",
    },

    -- ===================================================================
    -- Section 5: Process Bags
    -- ===================================================================
    { section = "processBags", title = L["Process Bags"] },

    {
        id = "process-bags-overview",
        q = L["What does Process Bags do?"],
        a = L["Process Bags is a bulk processor for materials in your bags. Open it from /wc, pick a mode (Disenchant or Pick Locks), and the panel shows every item that qualifies. Click the Cast button on the panel to process the current item; click again for the next one. The addon respects the spell's cooldown and skips items that don't qualify. Useful for turning a stack of green drops into Enchant dust without 30 manual right-clicks. Note: items on your Keep List are intentionally hidden from this panel."],
        panel = "WoWClearanceOptionsProcessBags",
    },
    {
        id = "process-combat-arming",
        q = L["Why won't the Process Bags skip arrow or list clicks work in combat?"],
        a = L["That's a game restriction, not a setting. Aiming Process Next at a different item rewrites a protected macro button, and the game blocks that change during combat for every addon. Leave combat and the panel catches up on its own - your click isn't lost, it just applies once the fight ends. Casting the already-armed item still works in combat."],
        panel = "WoWClearanceOptionsProcessBags",
    },
    {
        id = "process-skill-toggles",
        q = L["Can I stop Process Bags from using one skill?"],
        a = L["Yes. The checkboxes at the top of the Process Bags panel let you pick which skills the keybind acts on. Untick Pick Lock, for example, and Process Next keeps disenchanting but leaves your lockboxes alone. Only skills your character can do are shown, so a character without Enchanting never sees Disenchant. Your choices are saved per character."],
        panel = "WoWClearanceOptionsProcessBags",
    },
    {
        id = "process-disenchant",
        q = L["Disenchant mode"],
        a = L["Requires the Enchanting profession. The panel lists eligible Uncommon (Green) and Rare (Blue) Weapons / Armor. Click the Cast button to disenchant the current item into dust, essences, and shards; click again for the next one. Items without Enchanting eligibility are skipped."],
        panel = "WoWClearanceOptionsProcessBags",
    },
    {
        id = "process-mill",
        mode = "Mill",
        q = L["Mill mode"],
        a = L["Requires the Inscription profession. The panel lists stacks of 5+ herbs. Click the Cast button to mill the current stack into pigments; click again for the next stack. Stacks smaller than 5 are skipped."],
        panel = "WoWClearanceOptionsProcessBags",
    },
    {
        id = "process-prospect",
        mode = "Prospect",
        q = L["Prospect mode"],
        a = L["Requires the Jewelcrafting profession. The panel lists stacks of 5+ ore. Click the Cast button to prospect the current stack into gems and rare prospects; click again for the next stack. Stacks smaller than 5 are skipped."],
        panel = "WoWClearanceOptionsProcessBags",
    },
    {
        id = "process-picklocks",
        q = L["Pick Locks mode"],
        a = L["Requires the Rogue Pick Lock ability. The panel lists lockboxes (Junkboxes, Mageweave Pouches, Heavy Junkboxes, etc.). Click the Cast button to open the current lockbox; click again for the next one."],
        panel = "WoWClearanceOptionsProcessBags",
    },
    {
        id = "process-keybind",
        q = L["Can I keep casting without using the mouse?"],
        a = L["Yes. Open |cffffd870Esc menu > Options > Keybindings|r, find the |cffb6ffb6WoWClearance|r section, and bind |cffb6ffb6Process Next|r to a key. Each press fires one cast (WoW doesn't auto-repeat keybinds, so holding the key does nothing - press it again for the next item).\n\nThe queue runs in a fixed order: |cffb6ffb6Disenchant|r first, then |cffb6ffb6Pick Locks|r. Within each section items sort by quality (Disenchant) or name.\n\nUse the |cffb6ffb6>|r arrow next to the Cast button to skip past every remaining entry of the current mode and jump to the next mode (handy when you want to open lockboxes before clearing Disenchant junk). See the |cffffd870swirl|r entry for why the button briefly stays inert between casts."],
        panel = "WoWClearanceOptionsProcessBags",
    },
    {
        id = "process-missing-items",
        q = L["Why isn't an item in Process Bags?"],
        a = L["Process Bags skips items on your Keep List, gear you are wearing, items you told it to ignore, items above the highest rarity you set for disenchanting, and soulbound items unless you allow them in the Process Bags settings. To process one of these, take it off the Keep List or the ignore list, or change those settings."],
        panel = "WoWClearanceOptionsProcessBags",
    },
    {
        id = "process-cooldown-swirl",
        q = L["What's the swirl on the Process Next button?"],
        a = L["A short post-click lockout that lasts the spell's cast time, with a 1.5 second floor. While the swirl is up the Process Next button is intentionally inert - if you click during the cast or global cooldown the |cffffd870/cast|r line would silently no-op and the follow-up |cffffd870/use|r would |cffffb84dequip|r the item instead of processing it. Wait for the swirl to clear, then click again. The floor covers casts shorter than the global cooldown."],
        panel = "WoWClearanceOptionsProcessBags",
    },
    {
        id = "process-convert",
        q = L["Convert mode (Crystallized / Motes)"],
        a = L["Any stack of 10+ Crystallized Fire (or Crystallized Earth / Air / Water / Shadow / Life) shows up in the Convert section of Process Bags. Click Process Next (or use the keybind) and WoWClearance right-clicks the stack, which the game converts to 1 Eternal of the same school. Same flow for the BC-era 10-stack Motes (Mote of Fire / Earth / Air / Water / Life / Mana / Shadow), which condense to Primals. No profession required.\n\nThe game's security model doesn't let an addon fire this automatically (the OnUse casts a server-side spell, which is taint-restricted), so it goes through the same one-click-per-cast secure button as Disenchant.\n\nTo opt a specific itemID out of the Convert queue, add it to your Keep List / Sell List / Delete List - the standard Process Bags vetoes apply."],
        panel = "WoWClearanceOptionsProcessBags",
    },

    -- ===================================================================
    -- Section 6: Looting
    -- ===================================================================
    {
        id = "scav-auto-open",
        q = L["Auto-open lootable containers"],
        a = L["When on, WoWClearance opens lootable containers sitting in your bags (gift bags, treasure pouches, and similar) so you don't have to right-click each one. Lockboxes that need a key or a lockpick are skipped, and it pauses during combat. Set it on the Process Bags panel."],
        panel = "WoWClearanceOptionsProcessBags",
    },
    {
        id = "scav-fast-loot",
        q = L["Fast Loot (instant corpse looting)"],
        a = L["Speeds up looting from corpses, fishing, gift bags, dungeons, and mailboxes by draining the loot window the instant it opens. It uses your game's |cffffff00Auto Loot|r setting, so turn Auto Loot on for the full effect. Set it on the Process Bags panel."],
        panel = "WoWClearanceOptionsProcessBags",
    },
    -- ===================================================================
    -- Section 7: Reporting bugs
    -- ===================================================================
    { section = "discord", title = L["Reporting bugs"] },

    {
        id = "rule-summary",
        q = L["What rules does WC currently have configured?"],
        a = L["The Main panel has a 'Current Rules' button next to 'Open Quickstart' that opens a plain-English summary of every active toggle + the order WC uses to decide DELETE / SELL / KEEP for each item. The same window is reachable from /wc rules. Useful for spotting accidentally-disabled rules, or pasting the summary into a bug report when asking for help."],
        panel = "WoWClearanceOptionsMain",
    },
    {
        id = "gate-minimap-button",
        q = L["Hide the WoWClearance minimap button"],
        a = L["The Main panel has a 'Show the WoWClearance minimap button' checkbox. Turn it off if the button clashes with another minimap addon (some magnifier and minimap-replacement addons hook the Minimap frame in ways that conflict). WoWClearance still works the same way with the button hidden - open the settings via /wc, the LDB launcher (Bazooka, Titan Panel, ChocolateBar), or your key binding. /wc minimap on / off / reset is the slash-command equivalent (reset re-centres the button to its default angle)."],
        panel = "WoWClearanceOptionsMain",
    },
    {
        id = "bug-report-flow",
        q = L["Found a bug? Here's how to report it"],
        a = L["1) Type /wc bugreport. WoWClearance opens a window with a diagnostic snapshot.\n2) Click in the window, press Ctrl+A to select all, then Ctrl+C to copy.\n3) Click the button below to copy the link to WoWClearance's issues page on GitHub.\n4) Open the link in your browser, start a new issue, and paste the report."],
        url = "https://github.com/powerfulqa/WoWClearance/issues",
    },
    {
        id = "bug-report-contents",
        q = L["What does /wc bugreport include?"],
        a = L["Your character name, addon version, current Sell / Keep / Delete list sizes, the last few bag-scan results, and your protection settings. No personal info, no full settings dump - just enough context to reproduce the issue."],
        panel = nil,
    },
    {
        id = "bug-dm-vs-thread",
        q = L["Direct message vs. the thread"],
        a = L["Post in the thread - other players hit the same bugs and the public answer helps everyone."],
        panel = nil,
    },
    {
        id = "bug-process-debug",
        q = L["Process Bags missing items?"],
        a = L["If an item you expect is missing from Process Bags, run |cffffff00/wc processdebug|r. A copyable window opens listing every Process Bags gate: which profession spells the client recognises, every bag slot's scan result, and the buildProcessSummary entry counts. Paste that into a bug report so we can see which step fails."],
        panel = nil,
    },
    }
    -- Drop any section marker left with nothing under it, so a section
    -- whose entries were all removed doesn't render as a lone clickable
    -- header with an empty body. Generic, so a future section that empties
    -- out is covered without another edit.
    -- Entries for a Process Bags mode this client lacks (Forever has no
    -- Milling or Prospecting) are dropped by the same data-driven check the
    -- panels use, so they return by themselves if a build adds the skill.
    local exists = NS.compCache.processModeExists
    local kept = {}
    for _, e in ipairs(entries) do
        if not (e.mode and exists and not exists(e.mode)) then
            kept[#kept + 1] = e
        end
    end
    entries = kept
    local out = {}
    for i = 1, #entries do
        local e = entries[i]
        if e.section then
            local nxt = entries[i + 1]
            if nxt and not nxt.section then
                out[#out + 1] = e
            end
        else
            out[#out + 1] = e
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Frame creation
-- ---------------------------------------------------------------------------
local HelpPanel = CreateFrame("Frame", "WoWClearanceOptionsHelp", NS.OptionsHost())
HelpPanel.name = "Help"
HelpPanel.parent = "WoWClearance"

-- NS.OpenHelpEntry(entryId): deep-link from a settings panel into the
-- Help panel at a specific entry. Settings panels register [?] icons
-- via NS.AddHelpIcon (WoWClearance_PanelWidgets.lua); the icon's
-- OnClick calls this function with the entry's stable id.
--
-- Behaviour (v2.48.0 BarWarden-style port):
--   1. Find the section that owns this entry (walk WC_HELP_ENTRIES) and
--      set DB.helpSectionsCollapsed[ownerSection] = false so the section
--      auto-expands when the panel renders.
--   2. Open the Help category via NS.OpenOptionsPanel. This fires OnShow
--      synchronously and refreshLayout positions widgets. (Pre-port this
--      was a deliberate DOUBLE call, a 3.3.5a focus workaround; Forever's
--      Settings.OpenToCategory is a single call and calling it twice
--      re-opens the panel.)
--   3. Increment HelpPanel._scrollGeneration and capture it in a closure.
--      Every deferred pass checks its captured generation and no-ops if
--      a subsequent OpenHelpEntry has superseded it.
--   4. Two-pass deferred scroll (BarWarden pattern from Options_Help.lua
--      lines 559-564, timings adjusted for WC's FitScrollContent tick
--      chain): first pass at 0.15s runs after the 0.1s FitScrollContent
--      tick; second pass at 0.6s runs after the 0.5s tick has settled
--      the outer scroll range fully. Both passes call the entry frame's
--      Flash() method (UIFrameFlash on the BACKGROUND flash Texture)
--      so the pulse works regardless of the question text color.
--
-- If entryId is nil or no matching entry exists, the panel still opens
-- (no scroll / flash). Safe failure mode for typos and stale ids.
--
-- Returns the ENTRY FRAME (not the q FontString), so callers can invoke
-- widget.Flash() directly. The frame carries q + a + optional button as
-- children, plus a BACKGROUND flash Texture used by UIFrameFlash.
local function findEntryWidget(entryId)
    if not entryId then
        return nil
    end
    local items = HelpPanel._helpItems
    if not items then
        return nil
    end
    for _, item in ipairs(items) do
        if item.kind == "entry" and item.id == entryId then
            return item.widget
        end
    end
    return nil
end

function NS.OpenHelpEntry(entryId)
    local target = _G["WoWClearanceOptionsHelp"]
    if not target or not NS.OpenOptionsPanel then
        return
    end

    -- Find the owning section so it's expanded BEFORE the panel renders.
    if entryId and NS.DB then
        local ownerSection = nil
        for _, entry in ipairs(WC_buildHelpEntries()) do
            if entry.section then
                ownerSection = entry.section
            elseif entry.id == entryId then
                break
            end
        end
        if ownerSection then
            NS.DB.helpSectionsCollapsed = NS.DB.helpSectionsCollapsed or {}
            NS.DB.helpSectionsCollapsed[ownerSection] = false
        end
    end

    -- Single call. The old WC-TRAP here said "do NOT dedupe" because on
    -- 3.3.5a the first call sometimes landed on the parent category; that
    -- trap is retired rather than ignored, since the function it guarded no
    -- longer exists and the replacement re-opens the panel if called twice.
    -- Still fires OnShow + refreshLayout synchronously.
    NS.OpenOptionsPanel("WoWClearanceOptionsHelp")

    if not entryId or not NS.Delay then
        return
    end

    -- Generation counter: a subsequent OpenHelpEntry supersedes any
    -- in-flight scroll/flash from this call. Prevents rapid-click
    -- whiplash on spam [?] icons.
    HelpPanel._scrollGeneration = (HelpPanel._scrollGeneration or 0) + 1
    local gen = HelpPanel._scrollGeneration

    -- Scroll math: current + (scrollTop - widgetTop). Works from any
    -- starting scroll because widget:GetTop() already reflects the
    -- current scroll. Also fires the entry's Flash() so the blue pulse
    -- draws the eye to the target after the scroll lands.
    local function doScroll()
        if HelpPanel._scrollGeneration ~= gen then
            return
        end
        local widget = findEntryWidget(entryId)
        if not widget then
            return
        end
        local scrollFrame = _G["WoWClearanceOptionsHelpScroll"]
        if not scrollFrame or not scrollFrame.SetVerticalScroll then
            return
        end
        if not widget.GetTop or not scrollFrame.GetTop then
            return
        end
        local widgetTop = widget:GetTop()
        local scrollTop = scrollFrame:GetTop()
        if not widgetTop or not scrollTop then
            return
        end
        local currentScroll = scrollFrame.GetVerticalScroll and scrollFrame:GetVerticalScroll() or 0
        local offset = currentScroll + (scrollTop - widgetTop)
        if offset < 0 then
            offset = 0
        end
        local range = scrollFrame.GetVerticalScrollRange and scrollFrame:GetVerticalScrollRange() or 0
        if offset > range then
            offset = range
        end
        scrollFrame:SetVerticalScroll(offset)
        if widget.Flash then
            widget.Flash()
        end
    end

    -- Two-pass scroll. First pass at 0.15s runs after the 0.1s
    -- FitScrollContent tick has set an initial outer scroll range.
    -- Second pass at 0.6s runs after the 0.5s tick has settled the
    -- range fully (needed when MULTIPLE sections are expanded and the
    -- target Y depends on all of them settling). Both gated by the
    -- generation counter.
    NS.Delay(0.15, doScroll)
    NS.Delay(0.6, doScroll)
end

-- Apply the v2.32.x list-panel chrome backdrop to a frame. Matches the
-- Sell / Keep / Delete / Process Bags / Profiles scroll-area wrappers:
-- UI-Tooltip-Border edge at edgeSize=12 with the warm brown border tint
-- used by every other chrome-wrapped surface in the addon.
local function applyChromeBackdrop(frame)
    if not frame or not frame.SetBackdrop then
        return
    end
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.6)
    frame:SetBackdropBorderColor(0.4, 0.35, 0.25, 1)
end

HelpPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    if not DB then
        return
    end

    -- Per-character collapse state. Default: troubleshooting expanded,
    -- gates + labels collapsed so a first-time visitor doesn't see a
    -- wall of reference content. Stored under PER_CHAR_FIELDS so the
    -- v2.34.0 partition migrates it correctly (matches the
    -- processCollapsedModes precedent).
    if type(DB.helpSectionsCollapsed) ~= "table" then
        DB.helpSectionsCollapsed = {
            gettingStarted = true,
            troubleshooting = true,
            gates = true,
            labels = true,
            processBags = true,
            discord = true,
        }
    end
    -- Defensive defaults for individual keys (handles partial saves).
    -- Default: every section starts collapsed. The visitor sees the
    -- list of section headers and clicks the one they're interested in,
    -- rather than scrolling past a wall of expanded content. Existing
    -- per-character collapse toggles are preserved (only keys missing
    -- from the saved table get the collapsed default).
    for _, key in ipairs({ "gettingStarted", "troubleshooting", "gates", "labels", "processBags", "discord" }) do
        if type(DB.helpSectionsCollapsed[key]) ~= "boolean" then
            DB.helpSectionsCollapsed[key] = true
        end
    end

    -- ---------------------------------------------------------------
    -- refreshLayout (v2.48.0): BarWarden-style y-accumulator walk.
    -- ---------------------------------------------------------------
    -- Single-pass layout over panel._helpItems. Each item is either:
    --   { kind = "section", widget = headerButton, section, title }
    --   { kind = "entry",   widget = entryFrame,   section, id, apply }
    -- Where entryFrame carries q + a + optional button + BACKGROUND
    -- flash Texture as children. entry.apply(textW) re-sets the q/a
    -- widths and recomputes the frame height at the current viewport
    -- width; called every refreshLayout so the answer text reflows on
    -- Interface Options frame resize (BarWarden Options_Help.lua:436).
    --
    -- Section headers anchor to chrome directly with cumulative y (no
    -- prevFull chaining), so a hidden entry never strands the ones
    -- below it. Search filter: sections with a matching entry force-
    -- expand; non-matching entries hide; non-matching sections hide.
    local function refreshLayout(panel)
        local items = panel._helpItems
        local chrome = panel._helpChromeContent
        if not items or not chrome then
            return
        end
        local DB2 = NS.DB
        if not DB2 then
            return
        end
        local collapsed = DB2.helpSectionsCollapsed or {}

        -- Search filter (unchanged from v2.46.0 behaviour).
        local query = panel._helpSearch or ""
        local searching = query ~= ""
        local matchById, sectionHasMatch = {}, {}
        if searching then
            local searchText = panel._helpEntrySearch or {}
            local entrySection = panel._helpEntrySection or {}
            for id, text in pairs(searchText) do
                if text:find(query, 1, true) then
                    matchById[id] = true
                    local sec = entrySection[id]
                    if sec then
                        sectionHasMatch[sec] = true
                    end
                end
            end
        end

        -- Viewport-width reflow: read the live chrome width so wrapped
        -- text tracks the actual viewport instead of a fixed guess.
        -- BarWarden Options_Help.lua:459.
        local w = chrome:GetWidth()
        if not w or w < 100 then
            w = 500
        end
        local textW = w - 8 -- entries sit at x=4 with 4px right margin

        local y = -4
        local currentSection
        local currentSectionShown = true
        local currentSectionCollapsed = false
        local HEADER_H = 22
        local HEADER_GAP = 6
        -- v2.74.0: 10 -> 16. With answers now leaded and multi-paragraph, a
        -- 10px gap made consecutive entries run together; the entry boundary
        -- has to read as bigger than the gap inside an entry.
        local ENTRY_GAP = NS.Kit.HELP.entryGap

        for _, item in ipairs(items) do
            if item.kind == "section" then
                currentSection = item.section
                currentSectionShown = (not searching) or (sectionHasMatch[currentSection] == true)
                if not currentSectionShown then
                    item.widget:Hide()
                else
                    currentSectionCollapsed = (not searching) and (collapsed[currentSection] == true)
                    -- Gold section header. |cffffd870 matches BarWarden's
                    -- Options_Help.lua:390. Instant Show/Hide on click.
                    item.widget:SetText(string.format(
                        NS.Kit.COLOR.section .. "%s %s|r",
                        currentSectionCollapsed and "+" or "-",
                        item.title
                    ))
                    item.widget:SetWidth(w - 8)
                    item.widget:ClearAllPoints()
                    item.widget:SetPoint("TOPLEFT", chrome, "TOPLEFT", 4, y)
                    item.widget:Show()
                    y = y - HEADER_H - HEADER_GAP
                end
            else
                local hideForSearch = searching and item.id and not matchById[item.id]
                if not currentSectionShown or currentSectionCollapsed or hideForSearch then
                    item.widget:Hide()
                else
                    if item.setQuery then
                        item.setQuery(query)
                    end
                    item.apply(textW)
                    item.widget:ClearAllPoints()
                    item.widget:SetPoint("TOPLEFT", chrome, "TOPLEFT", 16, y)
                    item.widget:Show()
                    y = y - item.widget:GetHeight() - ENTRY_GAP
                end
            end
        end

        -- No-match state: shown only when searching with zero hits.
        local noResults = panel._helpNoResults
        if noResults then
            if searching and not next(sectionHasMatch) then
                noResults:ClearAllPoints()
                noResults:SetPoint("TOPLEFT", chrome, "TOPLEFT", 4, y)
                noResults:Show()
                y = y - (noResults:GetStringHeight() or 20) - 4
            else
                noResults:Hide()
            end
        end

        -- Direct height set: y-accumulator already knows the total extent,
        -- no FitScrollContent tick needed for chrome/chromeOuter. Outer
        -- scrollContent still needs FitScrollContent so the panel's own
        -- scroll frame reports the correct GetVerticalScrollRange.
        local totalH = math.max(1, -y + 8)
        chrome:SetHeight(totalH)
        local chromeOuter = chrome:GetParent()
        if chromeOuter then
            chromeOuter:SetHeight(totalH + 12)
            local scrollContent = chromeOuter:GetParent()
            if scrollContent and NS.FitScrollContent then
                NS.FitScrollContent(scrollContent, chromeOuter)
            end
        end
    end

    WC_compCache.initPanel(self, function()
        refreshLayout(self)
    end, function(s, content)
        -- Heading. Y offset -16 matches the Keep List / Sell List /
        -- Delete List heading pattern (MakeHeader anchors at TOPLEFT
        -- 16,y - the y passed in is the gap from the panel's top
        -- edge). Without a y arg, the heading butts right against the
        -- panel's top edge and the whole stack reads as misaligned
        -- relative to the other Interface Options sub-panels.
        local heading = NS.MakeHeader and NS.MakeHeader(content, L["Help / Troubleshooting"], -16)
            or content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        if not NS.MakeHeader then
            heading:SetPoint("TOPLEFT", content, "TOPLEFT", 16, -16)
            heading:SetText(L["Help / Troubleshooting"])
        end

        local intro = NS.MakeLabel(
            content,
            L["Common issues, sell-decision gates, and tooltip label meanings. Click a section header to expand / collapse."],
            16,
            -44
        )

        -- Keyword search. Filters the FAQ to entries whose question or
        -- answer contains the typed text; matching sections auto-expand and
        -- non-matching entries hide. An empty box restores the normal
        -- collapsible view. The query lives on the panel so refreshLayout
        -- (which also runs on section-header clicks) can read it.
        local searchLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        searchLabel:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -10)
        searchLabel:SetText(L["Search help:"])
        local searchBox = CreateFrame("EditBox", "WoWClearanceHelpSearchBox", content, "InputBoxTemplate")
        searchBox:SetAutoFocus(false)
        searchBox:SetHeight(20)
        searchBox:SetPoint("TOPLEFT", searchLabel, "BOTTOMLEFT", 6, -4)
        WC_compCache.setPanelWidth(searchBox, 60)
        searchBox:SetScript("OnTextChanged", function(box)
            s._helpSearch = (box:GetText() or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
            refreshLayout(s)
        end)
        searchBox:SetScript("OnEscapePressed", function(box)
            box:SetText("")
            box:ClearFocus()
        end)
        s._helpSearchBox = searchBox

        -- Chrome-wrapped content area for the FAQ entries. Uses Keep
        -- List's two-anchor pattern (TOPLEFT to prev widget's BOTTOMLEFT,
        -- TOPRIGHT to extend out to the panel's standard 16px right
        -- margin) so the chrome sits symmetrically inside the menu
        -- frame instead of having a small left margin and a large
        -- right margin. intro is MakeLabel(..., 16, ...) so its right
        -- edge is at WC_PANEL_WIDTH - 16; +24 on the TOPRIGHT offset
        -- pushes chromeOuter's right out to WC_PANEL_WIDTH + 8 (= 16
        -- from panel.right), matching Keep List's listUI extent.
        -- chromeOuter doesn't need its own setPanelWidth because the
        -- anchors trace back to intro, which IS registered for resize.
        -- Y offset -52 (was -12) clears the search row inserted below the
        -- intro. Both anchors trace to `intro` (same frame, same Y) so the
        -- top edge stays level - no skew from referencing the short search
        -- box.
        local chromeOuter = CreateFrame("Frame", nil, content, "BackdropTemplate")
        chromeOuter:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -52)
        chromeOuter:SetPoint("TOPRIGHT", intro, "BOTTOMRIGHT", 24, -52)
        chromeOuter:SetHeight(400) -- temporary; refreshLayout's FitScrollContent recomputes
        applyChromeBackdrop(chromeOuter)

        -- v2.36.x scroll viewport extension + scrollbar relocation.
        --
        -- The problem: WC_WrapPanelInScrollFrame anchors the scroll frame
        -- at BOTTOMRIGHT (-26, 6), so its viewport ends at panel.right - 26.
        -- WoW's ScrollFrame scissor-clips its scroll child to that viewport,
        -- which means chromeOuter (extending to panel.right - 16, matching
        -- Keep List's listUI extent) has its rightmost 10px CLIPPED OFF.
        -- The brown border on the right side never renders.
        --
        -- The fix: extend this panel's scroll frame to BOTTOMRIGHT (-4, 6)
        -- so the viewport ends at panel.right - 4. chromeOuter at
        -- panel.right - 16 is now fully inside the viewport (no clip).
        -- Then re-anchor the scrollbar so its left edge sits at the
        -- chrome's right edge, occupying the strip between the chrome
        -- and panel.right.
        --
        -- Other scroll-wrapped panels (MainPanel, MerchantPanel, etc.)
        -- don't need this because their content widgets sit at most at
        -- panel.right - 40 (via setPanelWidth(widget, 16)), well inside
        -- the default viewport - the Help panel is unusual in extending
        -- its chrome to Keep List's panel.right - 16 extent.
        local scrollName = (s:GetName() or "WoWClearanceOptionsHelp") .. "Scroll"
        local scrollFrame = _G[scrollName]
        local scrollBar = _G[scrollName .. "ScrollBar"]
        if scrollFrame and scrollBar then
            scrollFrame:ClearAllPoints()
            scrollFrame:SetPoint("TOPLEFT", 0, 0)
            scrollFrame:SetPoint("BOTTOMRIGHT", -4, 6)

            -- Scrollbar: anchor so sb.left sits at chrome.right (= panel.right
            -- - 16). With scroll.right at panel.right - 4, an offset of +2
            -- on TOPRIGHT puts sb.right at panel.right - 2 (small inset from
            -- panel edge) and sb.left at panel.right - 18 (2px to the right
            -- of chrome.right).
            scrollBar:ClearAllPoints()
            scrollBar:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", 2, -20)
            scrollBar:SetPoint("BOTTOMRIGHT", scrollFrame, "BOTTOMRIGHT", 2, 16)
        end

        -- Inner padding frame for the actual widgets so the chrome
        -- backdrop edges aren't directly against the FontStrings. 6px
        -- inset matches Process Bags' inner ScrollFrame pattern (small
        -- gap inside the brown UI-Tooltip-Border, not a deep margin).
        local chrome = CreateFrame("Frame", nil, chromeOuter)
        chrome:SetPoint("TOPLEFT", chromeOuter, "TOPLEFT", 6, -6)
        chrome:SetPoint("BOTTOMRIGHT", chromeOuter, "BOTTOMRIGHT", -6, 6)
        s._helpChromeContent = chrome

        -- Shown by refreshLayout when a search matches nothing.
        local noResults = chrome:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        WC_compCache.setPanelWidth(noResults, 4)
        noResults:SetJustifyH("LEFT")
        if noResults.SetWordWrap then
            noResults:SetWordWrap(true)
        end
        noResults:SetText(L["No help entries match your search."])
        noResults:Hide()
        s._helpNoResults = noResults

        -- v2.48.0 BarWarden-style item build. Two item kinds:
        --   * section: standalone Button widget with gold text +
        --     +/- glyph, hover flips gold -> white -> gold, OnClick
        --     toggles DB.helpSectionsCollapsed[section].
        --   * entry:   Frame carrying q + a + optional button + a
        --     BACKGROUND flash Texture. entry.apply(textW) reflows
        --     the wrapped text and recomputes the frame height at
        --     the current viewport width.
        local items = {}
        local currentSection = nil
        for _, entry in ipairs(WC_buildHelpEntries()) do
            if entry.section then
                local hdr = CreateFrame("Button", nil, chrome)
                hdr:SetHeight(22)
                hdr:RegisterForClicks("LeftButtonUp")
                local fs = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                fs:SetPoint("LEFT", hdr, "LEFT", 0, 0)
                fs:SetPoint("RIGHT", hdr, "RIGHT", 0, 0)
                fs:SetJustifyH("LEFT")
                hdr:SetFontString(fs)
                hdr:SetText("")
                -- Hover: gold -> white -> gold. Vertex tint on the
                -- FontString overrides the inline |cffffd870 color
                -- only for the duration of the hover; refreshLayout
                -- re-sets the full inline-colored text on the next
                -- collapse toggle. |cffffd870 = RGB (1, 0.845, 0.44).
                hdr:SetScript("OnEnter", function()
                    fs:SetTextColor(1, 1, 1)
                end)
                hdr:SetScript("OnLeave", function()
                    fs:SetTextColor(1, 0.845, 0.44)
                end)
                local sectionKey = entry.section
                hdr:SetScript("OnClick", function()
                    local db = NS.DB
                    if not db then
                        return
                    end
                    db.helpSectionsCollapsed = db.helpSectionsCollapsed or {}
                    db.helpSectionsCollapsed[sectionKey] =
                        db.helpSectionsCollapsed[sectionKey] ~= true
                    refreshLayout(s)
                    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
                end)
                items[#items + 1] = {
                    kind = "section",
                    widget = hdr,
                    section = sectionKey,
                    title = entry.title,
                }
                currentSection = sectionKey
            else
                -- Entry frame. Owns a BACKGROUND flash Texture (blue
                -- 0.30/0.56/1.0 alpha 0.25, initial alpha 0) so
                -- UIFrameFlash gives the deep-link pulse without
                -- touching the question text (BarWarden pattern from
                -- Options_Help.lua:410).
                local e = CreateFrame("Frame", nil, chrome)
                e:SetWidth(500) -- placeholder; apply() re-sets on every refreshLayout

                local flash = e:CreateTexture(nil, "BACKGROUND")
                flash:SetAllPoints()
                -- v0.5.8: SetColorTexture, not SetTexture(r,g,b,a). The in-game widget
                -- probe reports SetTexture with colour args as "accepted (may still
                -- no-op)" on this client - it does not error, so nothing would ever have
                -- told us whether this line drew. SetColorTexture is confirmed present and
                -- is the call that means what this line intends. A divider that silently
                -- fails to draw is invisible in exactly the way a missing divider is.
                flash:SetColorTexture(0.30, 0.56, 1.0, 0.25)
                flash:SetAlpha(0)
                e.flash = flash
                e.Flash = function()
                    if UIFrameFlash then
                        UIFrameFlash(flash, 0.25, 0.45, 1.4, false, 0, 0.35)
                    end
                end

                -- Question in light blue |cff4db8ff (BarWarden's
                -- Options_Help.lua:420). Anchored to entry frame's
                -- TOPLEFT; width re-applied in apply().
                local qfs = e:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                qfs:SetPoint("TOPLEFT", e, "TOPLEFT", 0, 0)
                qfs:SetJustifyH("LEFT")
                if qfs.SetWordWrap then
                    qfs:SetWordWrap(true)
                end
                qfs:SetText(NS.Kit.COLOR.question .. (entry.q or "") .. "|r")

                -- Answer below the question. v2.74.0 widened the gap from 3
                -- to 7 so the question reads as a heading rather than as the
                -- first line of the answer. ANSWER_GAP is shared with the
                -- height maths in apply() below - change both or entries
                -- overlap.
                local afs = e:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                afs:SetPoint("TOPLEFT", qfs, "BOTTOMLEFT", 0, -ANSWER_GAP)
                afs:SetJustifyH("LEFT")
                if afs.SetWordWrap then
                    afs:SetWordWrap(true)
                end
                -- v2.74.0: leading. Several answers are long, and at the
                -- default zero spacing they render as a solid block that is
                -- genuinely hard to read. 3px between wrapped lines costs a
                -- little height and buys a lot of legibility. GetStringHeight
                -- accounts for spacing, so apply()'s maths still holds.
                if afs.SetSpacing then
                    afs:SetSpacing(NS.Kit.HELP.spacing)
                end
                afs:SetText(entry.a or "")

                -- Search index (unchanged from v2.46.0).
                s._helpEntrySearch = s._helpEntrySearch or {}
                s._helpEntrySection = s._helpEntrySection or {}
                s._helpEntrySearch[entry.id] = ((entry.q or "") .. " " .. (entry.a or "")):lower()
                s._helpEntrySection[entry.id] = currentSection

                -- Optional per-entry button: URL (copy popup) or panel
                -- (open Interface Options sub-panel). Anchored INSIDE
                -- the entry frame at BOTTOMRIGHT of the answer so the
                -- entry stays atomic in the y-walk. apply() folds the
                -- button height into the entry's total height.
                local btn = nil
                if entry.url then
                    local urlValue = entry.url
                    btn = CreateFrame("Button", nil, e, "UIPanelButtonTemplate")
                    btn:SetSize(180, 22)
                    btn:SetText(entry.urlLabel or L["Copy link"])
                    btn:SetScript("OnClick", function()
                        -- The client cannot open a browser: show the URL
                        -- in the shared copy window for Ctrl+C.
                        NS.Kit.ShowCopy("WoWClearanceCopy", L["WoWClearance: Link"], urlValue, 440, 140)
                    end)
                elseif entry.panel then
                    local panelKey = entry.panel
                    btn = CreateFrame("Button", nil, e, "UIPanelButtonTemplate")
                    btn:SetSize(180, 22)
                    btn:SetText(L["Open Settings"])
                    -- Resolve target panel name late so renames don't
                    -- require updating the help table. Refresh on
                    -- hover in case the panel was created after the
                    -- Help panel built.
                    local function refreshLabel()
                        local target = _G[panelKey]
                        if target and target.name then
                            btn:SetText(L["Open "] .. target.name)
                        end
                    end
                    refreshLabel()
                    btn:SetScript("OnEnter", refreshLabel)
                    btn:SetScript("OnLeave", refreshLabel)
                    btn:SetScript("OnClick", function()
                        if NS.OpenOptionsPanel then
                            NS.OpenOptionsPanel(panelKey)
                        end
                    end)
                end
                if btn then
                    btn:SetPoint("TOPRIGHT", afs, "BOTTOMRIGHT", 0, -6)
                end

                -- apply(textW): re-set q/a widths and recompute the
                -- entry's total height. Called by refreshLayout every
                -- pass so the wrapped text tracks the live viewport
                -- width. GetStringHeight fallback (or 12) mirrors
                -- BarWarden Options_Help.lua:440.
                -- While searching, matched words show in yellow (the filter
                -- above already hides entries without a match).
                e.setQuery = function(query)
                    if e.lastQuery == query then
                        return
                    end
                    e.lastQuery = query
                    local blue = NS.Kit.COLOR.question
                    qfs:SetText(blue .. NS.Kit.Highlight(entry.q or "", query, nil, blue) .. "|r")
                    afs:SetText(NS.Kit.Highlight(entry.a or "", query))
                end
                e.apply = function(tw)
                    e:SetWidth(tw)
                    qfs:SetWidth(tw)
                    afs:SetWidth(tw)
                    local qh = qfs:GetStringHeight() or 12
                    local ah = afs:GetStringHeight() or 12
                    local bh = btn and 28 or 0 -- 22 button + 6 gap
                    e:SetHeight(qh + ANSWER_GAP + ah + bh)
                end

                items[#items + 1] = {
                    kind = "entry",
                    widget = e,
                    section = currentSection,
                    id = entry.id,
                    apply = e.apply,
                    setQuery = e.setQuery,
                }
            end
        end
        s._helpItems = items

        -- Reflow on scroll-frame OnSizeChanged: wrapped answer text
        -- retracks the live viewport width instead of clipping past
        -- the right edge (BarWarden pattern from Options_Help.lua:492).
        local scrollName2 = (s:GetName() or "WoWClearanceOptionsHelp") .. "Scroll"
        local hostScroll = _G[scrollName2]
        if hostScroll and hostScroll.HookScript then
            hostScroll:HookScript("OnSizeChanged", function()
                refreshLayout(s)
            end)
        end

        refreshLayout(s)
    end, true)
end)

-- Help self-registers rather than joining the ordered block in
-- WoWClearance_Events.lua, because this file loads AFTER Events (see the
-- .toc) and so cannot be in that list. Registering here keeps Help at the
-- bottom of the sidebar, which is where it has always sat.
-- v0.5.4: not registered as a Settings sub-category any more. Help is
-- reachable from the standalone window's sidebar, which is the only host
-- that does not close the player's bags.
