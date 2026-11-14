# WoWClearance

[![Licence](https://img.shields.io/badge/Licence-Source--Available-blue?style=for-the-badge)](LICENSE)
[![Status](https://img.shields.io/badge/Status-Early%20release-orange?style=for-the-badge)](docs/PORT_STATUS.md)

**Full bags, every quest hub, every farm session. WoWClearance handles the chore.**

WoWClearance is a bag manager for **WoW: Forever**. It sells what you don't want when you visit a merchant, keeps what you do, and can delete or process the rest. Zero config to start, one click for a guided setup, deep controls when you want them. No external libraries.

It is a fork of [EbonClearance](https://github.com/powerfulqa/EbonClearance), the same author's bag manager for WoW 3.3.5a, ported to the Forever client.

## Status

**Early release.** It is tested in game on client build 1.60.1.70245, and settings are saved between sessions on that build. Much of the addon still has only light in-game testing. Progress and open items are tracked in [docs/PORT_STATUS.md](docs/PORT_STATUS.md).

## Installation

1. Download `WoWClearance.zip` from the [GitHub releases page](https://github.com/powerfulqa/WoWClearance/releases).
2. Unzip it into your Forever client's AddOns folder, so you end up with `World of Warcraft/_forever_/Interface/AddOns/WoWClearance`.
3. Log in and type `/wc` to open the settings.

To install from source instead, copy `WoWClearance.toc`, `Bindings.xml`, `LICENSE`, `AGENTS.md` and every `WoWClearance_*.lua` file into that folder.

New characters start with sensible defaults: Common and Uncommon gear below your equipped item level sells at the vendor, and the gear you wear is always kept. Tune from there, or press **Open Quickstart** on the main page for a guided setup.

To skip an alt, untick **Enable WoWClearance** on the main page, right-click the minimap button, or type `/wc disable`. `/wc status` shows the current state.

## How it sells

- **DaylightUI.** With DaylightUI installed:
  - WoWClearance's windows, settings and Alt+Right-Click menu take on its look. Turn it off with "Use DaylightUI look" on the main settings page (takes a /reload).
  - Its bags show the sell/delete borders and get Delete / Sell / Account Sell / Keep List groups. Its Alt+Right-Click menu carries the WoWClearance rows.
  - Items you Lock in its bags are never sold, deleted or processed. Items you mark "Sell as junk" are sold.
  - Only one addon sells at a vendor: while WoWClearance's vendor selling is on, DaylightUI's junk sale waits.
  - WoWClearance has its own section in DaylightUI's options, a `/dui wc` command, a "Vendored" data text, and its windows can be placed with `/dui unlock`.
- **Junk sells by default.** Grey items sell at any merchant. Turn off "Sell grey items" in Merchant Settings to keep them, or "Sell items at vendors" to stop selling at vendors altogether.
- **Rules per rarity** (Common / Uncommon / Rare / Epic). Each can cap at your equipped item level in that slot, or at a fixed item level, and can be limited to BoE only or BoP only.
- **Sell, Keep and Delete lists.** A Sell List per character plus an account-wide one, a Keep List and a Delete List. Add items by name or ID, by Shift-Click or drag, or in bulk by quality.
- **Sell recipes you already know.** Opt-in, per rarity, with a bind-type filter. Each character only sells recipes it has learned.
- **Vendor speed.** Choose the time between sells, or turn on Fast Mode and Turbo Mode to clear full bags in seconds.
- **Auto-repair** while selling, with an option to pay from the guild bank.
- **The tooltip says what will happen** to an item before you visit a vendor. `/wc sellinfo` and **Sell Info** in the Alt+Right-Click menu explain why an item will or won't sell.

## What it protects

- **Gear you're wearing**, and gear in your saved equipment sets.
- **Upgrades found in your bags.**
- **Gear with an appearance you haven't collected.** On by default.
- **Loot you can still trade or refund.** On by default.
- **Recipes you haven't learned**, with an option to keep them after you learn them too.
- **Quest items.**

The protections stop the automatic sell rules. Your Sell List and **Allow Sell** (Alt+Right-Click on an item) still sell a protected item when you ask for it.

Blizzard's own **Sell All Junk** button at the vendor ignores the Keep List. While WoWClearance is on it sells your junk by itself, so you don't need that button.

## Deleting

Items on your Delete List are deleted during the vendor run at a merchant. **Delete Settings** has a master switch for this (on by default) and these extras, all off until you turn them on:

- Delete items on your Delete List the moment you loot them.
- Delete grey items the moment you loot them (skips your Keep List, worn gear and quest items, and waits while a merchant is open).
- Mark PvP gear (Resilience) and unsellable recipes you already know for deletion.

Deleting is a key or button press (Delete Next), one item per press: this game does not let addons delete items on their own. Each delete is announced in chat; you can turn that off.

If another addon that deletes items is also running, WoWClearance warns you at login. You can turn the warning off.

## Process Bags

Disenchant and Pick Lock from one panel. Bind a key to **Process Next** and press it to work through your bags one item at a time. Only the skills your character has are shown; Milling and Prospecting do not exist on Forever, so they never appear. Choose which skills to use, the highest rarity to disenchant, and whether to include soulbound items. Right-click a row to skip that item.

The panel also has two looting options: **Fast Loot** (instant corpse looting) and **auto-open lootable containers** in your bags.

## Windows and panels

- **Loot Log** (`/wc loot`, **Shift+L**, or the Loot Log buttons). Everything you've looted, how many, its vendor value and its share of the gold in view. Sort by name, count or gold, filter by rarity, or search (`"quotes"` for an exact name, `||` for either). Click a row to show only that item. Right-click a row to hide an item from the totals; **Unhide All** brings it back. Hold Alt and hover a row to see what WoWClearance will do with that item. Four views:
  - **Session** (since login), **Character** (this character's lifetime), **Account** (all your characters).
  - **History**: one line per pickup, with who looted what and how many. It covers your characters and the loot of group members that the game shows in chat. Hover for the time. Sort by Time, Name, Count or Gold, and show only the last hour, day, 7 days or 30 days. Keeps the last 20,000 pickups and is saved between sessions.
- **Sold History** (`/wc history`, the main-page button, or Alt+Right-Click any bag item). Everything sold or deleted, newest first, with the rule that decided it. Deletes made outside WoWClearance are listed too, so a missing item can always be traced. Filter by All / Sold / Deleted, by rarity and by time (last hour to last 30 days), search, click a line to show only that item, and **Copy** the view. Saved per character between sessions: the last 5,000 sales and 5,000 deletes. Entries from an earlier day show their date.
- **Current Rules** (`/wc rules`). A plain-English list of every active rule and the order they apply in.
- **Item Highlighting.** Coloured borders on bag items: Delete, Keep, Account Sell, Character Sell, Junk and Rule match, each with its own colour. Optional item levels on bags, the character sheet and inspect, and the merchant window; item levels show each copy's real level. Rings also show in bag addons that sort items into groups, which get **WoWClearance: Sell** and **WoWClearance: Delete** groups too. You can also show the item ID in tooltips. Item tooltips show **Bank: N** when the bank holds some, and how many you have sold and looted across all characters.
- **Statistics.** Lifetime and session totals side by side: gold made, gold looted, net after repairs, items sold and deleted by quality, top 5 sold and deleted items, Process Bags totals, repairs, gold per hour, your best gold-earning zones, and the last 7 days (net gold and items sold, deleted and looted each day, across all characters).
- **Stats - Guild.** Pooled farming stats from guild and group members who opt in. Off by default, anonymous unless a member turns on **Show my name**.
- **Stats - Server.** A realm-wide, anonymous total of what WoWClearance users are clearing. **Off by default.** Nothing is sent unless you tick **Share my totals with the realm** on that panel. It never connects at login: with sharing on, it joins a private channel only when you tick the box or open the Stats - Server panel, and leaves it when you untick. It reaches players on your own realm only.
- **List Profiles** save and load your Sell and Keep lists. **Settings Profiles** save your selling settings under a name, so alts can share them or keep their own.
- **Import / Export** shares lists or a full settings pack as a text string.
- **Quickstart** asks a few questions and sets things up for you.
- **Help / FAQ** with a search box.

## Other touches

- **Alt+Right-Click any bag item** for quick actions: add to a Sell, Keep or Delete list, Allow Sell, Sell Info, and Sold History.
- **Minimap button.** Left-click: settings. Middle-click: Process Bags. Right-click: turn on or off for this character.
- **Addon list button.** WoWClearance is also in the minimap's addon list (Left: settings, Right: on or off), so you can hide the minimap button and keep access.
- **Update notice.** When someone in your guild or group has a newer version, you get one chat line and the newest version shows on the main page. On by default; you can turn it off.
- **Language.** English only in this version.

## Slash Commands

| Command | Description |
|---------|-------------|
| `/wc` | Open the settings |
| `/wc status` | Show whether WoWClearance is on or off for this character |
| `/wc enable` | Turn WoWClearance on for this character |
| `/wc disable` | Turn WoWClearance off for this character |
| `/wc loot` | Open the Loot Log |
| `/wc history` | Open Sold History |
| `/wc highlight` | Turn all item highlighting (bag borders and item levels) on or off |
| `/wc rules` | Show every active rule and the order they apply in |
| `/wc sellinfo [bag slot]` | Explain why an item will or won't sell (also Alt+Shift+Right-Click on the item) |
| `/wc profile list` | Show your saved List Profiles |
| `/wc profile save\|load\|delete <name>` | Save, load or delete a List Profile |
| `/wc sprofile list` | Show your Settings Profiles and how many characters use each |
| `/wc sprofile save\|use\|delete <name>` | Save, switch to or delete a Settings Profile (users of a deleted one go back to Default) |
| `/wc clean` | Find items that are on more than one list |
| `/wc clean apply` | Fix them (Keep List wins, then Delete List, then Sell List) |
| `/wc clean upgrades` | Find old "Upgrade" items on your Keep List that are no longer upgrades |
| `/wc clean upgrades apply` | Remove them (asks first) |
| `/wc minimap on\|off\|reset` | Show, hide or re-centre the minimap button |
| `/wc bugreport` | Make a report you can copy into a bug report |
| `/wc perf` | Show WoWClearance's memory, CPU, cache and list sizes |
| `/wc spike` | Show the worst frame hitches WoWClearance was part of |
| `/wc processdebug [clear]` | Diagnose missing Process Bags items; `clear` forces a fresh scan |
| `/wc scandebug <bag> <slot>` | Show the hidden tooltip lines for one bag slot |
| `/wc commtest` | Check that addon messages work (works solo) |
| `/wc guildtest` | Preview Stats - Guild with pretend members (works solo) |
| `/wc realmtest` | Check the realm-wide sharing channel (works solo) |
| `/wc servertest` | Preview Stats - Server with pretend sharers (works solo) |
| `/wc help` | Point to the command list on the main settings page |
| `/wcdebug` | Print debug info and scan your bags |

Every command is also on the main settings page, with a button to run it.

## Key Bindings

Under Key Bindings > WoWClearance:

- **Open/close Loot Log** - **Shift+L** by default. It is set once, at your first login, and only if Shift+L is free.
- **Open/close settings**
- **Toggle enabled**
- **Force sell at current merchant**
- **Process Next** (Process Bags)

## Requirements

- WoW: Forever (Interface 16001).
- No external libraries.

## For Contributors

Developer documentation lives under [docs/](docs/):

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) is a one-screen map of which file owns what.
- [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md) is the prescriptive guide: architecture, naming, the state machine, UI patterns, and the gotchas that have broken things before. Some of its API notes still describe the 3.3.5a original.
- [docs/PORT_STATUS.md](docs/PORT_STATUS.md) records what the Forever port changed, what is measured in game, and the porting lessons. Read its lessons before assuming anything about this client.
- [docs/CODE_REVIEW.md](docs/CODE_REVIEW.md) lists known follow-up cleanups.

The addon ships as 34 `.lua` files, listed in load order in [WoWClearance.toc](WoWClearance.toc); the event hub is `WoWClearance_Events.lua`. A Luacheck config ([.luacheckrc](.luacheckrc)) and a StyLua config ([stylua.toml](stylua.toml)) are checked in. Before opening a PR, run:

```
stylua --check *.lua
luacheck WoWClearance_*.lua
lua tests/run_all.lua
```

`tests/run_all.lua` runs all 12 test suites. CI uses Lua 5.1, so use `lua5.1` locally to match it. Luacheck must stay at 0 warnings.

The Project Ebonhold features of EbonClearance (affixes, chance-on-hit protection, the Anvil and extraction, the Greedy Scavenger and Goblin Merchant companions) do not exist on Forever and were removed in the port. See [docs/PORT_STATUS.md](docs/PORT_STATUS.md) work item 2.

## Thanks

Feature ideas and bug reports from the Project Ebonhold community shaped EbonClearance, and WoWClearance inherits them. Selected community-driven changes:

- **Auto-delete on pickup** - suggested by Sanavesa.
- **Auto-mark PvP gear (Resilience) for deletion** - requested by Murlocked, for cleaning up bag-clutter after farming.
- **Class-restriction self-heal on the Keep-Upgrade sweep** (Druids no longer accumulate bows, Mages no longer accumulate relics) - reported by Murlocked.
- **Auto-mark unsellable affix dupes for deletion** - requested by Broyo.
- **Announce auto-delete / auto-mark in chat** toggle - requested by ayres.
- **2H-narrowing on the upgrade / downgrade predicates** (1H weapons and offhands compare correctly against an equipped 2H instead of misfiring on the locked-empty offhand slot) - reported by "Perfect Bidoof" and Zukii.
- **Hard iLvl ceiling on the affix-sell paths** (a rare high-iLvl item can't sneak past a rarity cap just because its affix is a known dupe) - near item-loss report from Bizzaro.
- **Quickstart Q13 default label fix + Stats-Guild "Sold by Quality" alignment** - reported by Qvintus.

## Changelog

Per-release notes live in [CHANGELOG.md](CHANGELOG.md). For prior-art acknowledgement and the design lineage, see [NOTICE.md](NOTICE.md).

## Notice

WoWClearance ships in a niche where similar inventory-management addons exist for the same private server. [NOTICE.md](NOTICE.md) documents prior art and convergent patterns honestly: which structural elements (the source-available licence shape, the provenance globals form) are adopted from conventions already present in the 3.3.5a addon ecosystem, and which (the fingerprint and watermark mechanism) are specific to this project. Read it before drawing conclusions about influence in either direction.

## Licence

This project is distributed under the WoWClearance Source-Available Attribution Licence. You may use, modify, and redistribute the addon (including in private-server addon-pack bundles) provided you preserve the author credit, the in-game byline, the provenance globals, and the LICENSE file itself, and you do not silently rebrand the addon name, the `/wc` slash command, the SavedVariable names, or the `WC:` import/export prefix. Forks under a new name are welcome as long as attribution to the original author and source URL is preserved. See the [LICENSE](LICENSE) file for the full terms.
