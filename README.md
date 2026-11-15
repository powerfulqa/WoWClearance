# WoWClearance

[![Licence](https://img.shields.io/badge/Licence-Source--Available-blue?style=for-the-badge)](LICENSE)
[![Client](https://img.shields.io/badge/WoW-Forever-orange?style=for-the-badge)](#requirements)
[![Downloads](https://img.shields.io/github/downloads/powerfulqa/WoWClearance/total?style=for-the-badge&label=Downloads)](https://github.com/powerfulqa/WoWClearance/releases)

**A bag manager for WoW: Forever.** It sells what you don't want when you visit a vendor, keeps what you do, and helps you delete or process the rest.

It works with no setup. A guided Quickstart takes one click, and there are detailed controls when you want them.

## Install

1. Download `WoWClearance.zip` from the [releases page](https://github.com/powerfulqa/WoWClearance/releases).
2. Unzip it into your AddOns folder, so you end up with `World of Warcraft/_forever_/Interface/AddOns/WoWClearance`.
3. Log in and type `/wc`.

A new character starts with safe defaults: grey items sell, Common and Uncommon gear below what you are wearing sells, and the gear you wear is always kept. Press **Open Quickstart** on the main page to pick a preset or answer a few questions.

To turn it off on one character, untick **Enable WoWClearance**, right-click the minimap button, or type `/wc disable`.

## What it does

### Sells at vendors

- **Grey items** sell at any vendor.
- **Rules per rarity** (Common, Uncommon, Rare, Epic). Each can sell gear below what you are wearing in that slot, or below an item level you set, and can be limited to BoE or BoP.
- **Sell Lists.** One per character and one for the whole account. Add an item with Alt+Right-Click, by name or ID, or in bulk by rarity.
- **Recipes you already know** can be sold, per rarity. Each character only sells what it has learned.
- **Repairs** your gear while it sells, from the guild bank if you choose.
- **Speed.** Set the time between sells, or use Fast Mode and Turbo Mode to clear full bags in seconds.
- **Two switches in Merchant Settings:** "Sell items at vendors" stops vendor selling altogether, and "Sell grey items" keeps your greys.

### Keeps what matters

- Gear you are wearing, and gear in your saved equipment sets.
- Gear with an appearance you haven't collected.
- Loot you can still trade to your group or refund.
- Recipes you haven't learned.
- Quest items and profession tools.
- Anything on your **Keep List**.
- Upgrades found in your bags, if you turn that on.

These stop the automatic rules only. An item on your Sell List, or one you chose **Allow Sell** for (Alt+Right-Click), still sells.

The game's own **Sell All Junk** button ignores your Keep List. WoWClearance sells your junk by itself, so you don't need that button.

### Tells you what will happen

Hover an item and its tooltip says **Keep**, **Will Sell**, **Will Delete** or **Won't Sell**, with the reason. Alt+Shift+Right-Click an item, or type `/wc sellinfo`, for a step-by-step explanation.

### Deletes, one press at a time

The game does not let addons delete items on their own. Put items on your **Delete List**, then press **Delete Next** (a button, or a key you bind) to delete one item per press.

In Delete Settings you can also have Delete Next remove grey items once the list is clear, and have unsellable PvP gear and unsellable known recipes added to the list for you. All of those are off until you turn them on.

### Processes your bags

**Process Bags** lists what you can Disenchant, Pick Lock or combine (stacks of motes and similar). Bind a key to **Process Next** and press it to work through them one at a time. Only the skills your character has are shown.

The same panel has **Fast Loot** and **auto-open containers**.

### Shows what you looted and sold

- **Loot Log** (`/wc loot`, Shift+L). What you looted, how many and what it is worth, for this session, this character or the whole account. The History view lists every pickup, including your group's.
- **Sold History** (`/wc history`). Everything sold or deleted, newest first, with the rule that decided it.
- **Statistics.** Gold made and looted, items by rarity, your best zones, gold per hour and the last 7 days.
- **Current Rules** (`/wc rules`). Every active rule in plain English.

### Highlights your bags

Optional coloured borders show which items will sell or be deleted, or are on a list. Item levels can show on bags, the character sheet and the vendor window. One switch on the Item Highlighting page, or `/wc highlight`, turns all of it on or off.

### Works with DaylightUI

With the DaylightUI addon installed:

- WoWClearance's windows, settings and Alt+Right-Click menu use its look. "Use DaylightUI look" on the main page turns that off.
- Its bags show the sell and delete borders, and get Delete List, Sell List, Account Sell List and Keep List groups.
- Its Alt+Right-Click menu carries the WoWClearance rows, so there is one menu instead of two.
- Items you Lock in its bags are never sold, deleted or processed. Items you mark "Sell as junk" are sold.
- Only one addon sells junk at a vendor: its junk sale waits while WoWClearance is selling junk ("Sell items at vendors" and "Sell grey items" both on).
- WoWClearance has a section in its options, a `/dui wc` command, a "Vendored" data text, and windows you can place with `/dui unlock`.

Bag addons that sort items into groups get the borders too.

### Also

- **Alt+Right-Click any bag item** to add it to a list, Allow Sell, see Sell Info or open Sold History.
- **Profiles.** List Profiles save your Sell and Keep lists. Settings Profiles save your selling settings, so alts can share them or keep their own.
- **Import / Export** shares lists or a settings pack as text.
- **Stats - Guild** and **Stats - Server** pool anonymous totals from players who opt in. Both are off by default and send nothing until you turn them on.
- **Update notice** when someone in your guild or group has a newer version.
- **Help** with a search box, in the settings.

## Commands

| Command | What it does |
|---------|--------------|
| `/wc` | Open the settings |
| `/wc enable`, `/wc disable`, `/wc status` | Turn WoWClearance on or off for this character, or check |
| `/wc loot` | Open the Loot Log |
| `/wc history` | Open Sold History |
| `/wc rules` | Show every active rule |
| `/wc sellinfo` | Explain why an item will or won't sell |
| `/wc highlight` | Turn all item highlighting on or off |
| `/wc profile list\|save\|load\|delete <name>` | List Profiles |
| `/wc sprofile list\|save\|use\|delete <name>` | Settings Profiles |
| `/wc clean` | Find items that are on more than one list (`apply` fixes them) |
| `/wc clean upgrades` | Find old "Upgrade" items on your Keep List (`apply` removes them) |
| `/wc minimap on\|off\|reset` | Show, hide or re-centre the minimap button |
| `/wc bugreport` | Make a report to paste into a bug report |

The main settings page lists every command, including the diagnostic ones, with a button to run each.

**Key bindings** (Key Bindings > WoWClearance): Loot Log (Shift+L by default, if that key is free), settings, turn on or off, Force Sell at the current vendor, Process Next and Delete Next.

## Requirements

- WoW: Forever (Interface 16001).
- No other addons or libraries needed.
- English only.

It is tested on client build 1.60.1.70245. It is an early release: please [report anything odd](https://github.com/powerfulqa/WoWClearance/issues), with the output of `/wc bugreport`.

## Where it came from

WoWClearance is a fork of [EbonClearance](https://github.com/powerfulqa/EbonClearance), the same author's bag manager for WoW 3.3.5a, rewritten for the Forever client. Features that only made sense on EbonClearance's home server were removed.

Ideas and bug reports from that community shaped it. Thanks in particular to Murlocked, ayres, "Perfect Bidoof", Zukii, Qvintus and everyone credited in [EbonClearance's README](https://github.com/powerfulqa/EbonClearance#readme).

Release notes are in [CHANGELOG.md](CHANGELOG.md). [NOTICE.md](NOTICE.md) records prior art and design lineage.

## Contributing

Developer documentation is under [docs/](docs/):

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): which file owns what, on one screen.
- [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md): the working rules, and the traps that have broken things before. Some API notes still describe the 3.3.5a original.
- [docs/PORT_STATUS.md](docs/PORT_STATUS.md): what the port changed, what is measured in game, and the porting lessons.

The addon is 36 `.lua` files, listed in load order in [WoWClearance.toc](WoWClearance.toc). Before opening a pull request, run:

```
luacheck WoWClearance_*.lua
lua5.1 tests/run_all.lua
```

Luacheck must stay at 0 warnings and all 10 test suites must pass. CI runs the same checks.

AI coding tools: read [AGENTS.md](AGENTS.md) first.

## Licence

WoWClearance is source-available under its own licence. You may use it, pass on untouched copies (addon packs included) and change your own copy for your own use. You may not share a changed copy, publish a fork or reuse its code in another addon; send fixes and features as pull requests instead. The author credit, the in-game byline and the `LICENSE` file must stay intact. Releases up to v0.8.3 stay under the earlier attribution licence. The [LICENSE](LICENSE) file has the full terms.
