-- WoWClearance_BugReport - diagnostic snapshot builder + display frame.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8 of the multi-stage file split tracked in docs/CODE_REVIEW.md
-- item 4. Smallest self-contained UI cluster: ~430 LOC of pure formatting
-- code with one external call site (the bug-report button on the main
-- settings panel) and read-only access to a handful of DB / cache fields.
--
-- Exposed as NS.ShowBugReport for the button to call.
--
-- Cross-file dependencies read inline:
--   * NS.DB / NS.ADB             - captured at function entry
--   * NS.PrintNice / PrintNicef  - chat output
--   * NS.GetVersion              - exposed by WoWClearance_Events.lua
--   * NS.GetFreeBagSlots         - exposed by WoWClearance_Events.lua
--   * NS.EnsureDB                - called once before reading DB fields

local NS = select(2, ...)
local GetNumAddOns = C_AddOns.GetNumAddOns
local IsAddOnLoaded = C_AddOns.IsAddOnLoaded
local GetAddOnMetadata = C_AddOns.GetAddOnMetadata
local GetAddOnInfo = C_AddOns.GetAddOnInfo
local GetItemInfo = C_Item.GetItemInfo
local GetContainerItemID = C_Container.GetContainerItemID
local GetContainerItemLink = C_Container.GetContainerItemLink
local GetContainerNumSlots = C_Container.GetContainerNumSlots
local WC_compCache = NS.compCache
local L = NS.L
-- v2.38.3: bound where used so Test 65 (bind-IsInSet invariant) stays
-- satisfied for the /wc processdebug per-slot blacklist gate.
local IsInSet = NS.IsInSet

-- Bug report diagnostic snapshot
-- v2.51.0: item-name resolver used by every "list of item IDs" section
-- in the bug report (Delete List Preview, Recent Sold, Recent Deleted,
-- Silent Refusals, Auto-Mark Events). GetItemInfo returns nil at
-- report-build time for items not in the client's session cache
-- (previous sessions' Delete-List entries the user hasn't hovered), so
-- v2.50.3's Delete List Preview printed "item:ID" for every row - the
-- format the fallback branch produces. This resolver primes the client
-- cache via NS.scanTooltip:SetHyperlink (synchronous for
-- already-client-cached items) then retries GetItemInfo, falling back
-- to the raw id only if the client genuinely has no data yet.
--
-- Return: item link (with color code + brackets) when possible, else
-- plain name, else "item:ID". Never nil.
local function WC_ResolveItemLabel(id)
    if not id then
        return "?"
    end
    local name, link = GetItemInfo(id)
    if link then
        return link
    end
    if name then
        return name
    end
    -- Prime the cache. SetHyperlink is a no-op for items the client
    -- already has data for; for items it doesn't, it fires an async
    -- fetch (GET_ITEM_INFO_RECEIVED). We retry synchronously in case
    -- the priming completed the cache lookup on this frame.
    local st = NS.scanTooltip
    if st and st.SetHyperlink then
        pcall(st.SetOwner, st, UIParent, "ANCHOR_NONE")
        pcall(st.ClearLines, st)
        pcall(st.SetHyperlink, st, "item:" .. id)
        name, link = GetItemInfo(id)
        if link then
            return link
        end
        if name then
            return name
        end
    end
    return "item:" .. id
end

local function WC_CopperToPlainText(copper)
    if not copper or copper <= 0 then
        return "0"
    end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop = copper % 100
    if gold > 0 then
        return string.format("%dg %ds %dc", gold, silver, cop)
    elseif silver > 0 then
        return string.format("%ds %dc", silver, cop)
    else
        return string.format("%dc", cop)
    end
end

local function WC_BuildBugReport()
    local DB = NS.DB
    local ADB = NS.ADB
    NS.EnsureDB()
    local lines = {}
    local function add(s)
        lines[#lines + 1] = s
    end

    local version = NS.GetVersion()
    local player = GetUnitName("player", true) or "Unknown"
    local realm = GetRealmName() or "Unknown"
    local dateStr = date("%Y-%m-%d %H:%M")
    local className = UnitClass and UnitClass("player") or "Unknown"
    local level = UnitLevel and UnitLevel("player") or 0
    local locale = GetLocale and GetLocale() or "Unknown"

    add("=== WoWClearance Bug Report ===")
    add("Version: " .. version)
    -- Watermark: deterministic hash of `WoWClearance@<version>`. Matches
    -- _G.__WoWClearance_watermark; surfaced here so a report can be tied
    -- back to a specific build, and so a modified / repackaged copy is
    -- visible (the hash would not match the canonical value for that
    -- version). See docs/ADDON_GUIDE.md "Fingerprint and watermark".
    add("Watermark: " .. tostring(_G.__WoWClearance_watermark or "(missing)"))
    add("Character: " .. player .. " - " .. realm)
    add("Class / Level: " .. className .. " / " .. tostring(level))
    add("Locale: " .. tostring(locale))
    add("Date: " .. dateStr)
    add("")

    -- v2.51.0 Issue Summary section: rules-based flags surfaced at the
    -- top so a reviewer sees "here's what looks off" before scrolling.
    -- Every flag is a HYPOTHESIS not a diagnosis - the sections below
    -- have the raw data to confirm. Flags fire on additive conditions;
    -- absence of a flag doesn't mean absence of an issue.
    add("--- Issue Summary ---")
    do
        local flags = {}
        -- Destructive toggle: Delete Next also takes greys.
        if DB.markGreyForDeletion then
            flags[#flags + 1] = "! Mark Grey for Deletion is ON - Delete Next also deletes grey items"
        end
        -- Cross-list conflicts imply a stale state that /wc clean should resolve.
        local conflictCount = 0
        if DB.deleteList and DB.blacklist then
            for id in pairs(DB.deleteList) do
                if DB.blacklist[id] then
                    conflictCount = conflictCount + 1
                end
            end
        end
        if conflictCount > 0 then
            flags[#flags + 1] = string.format(
                "! %d cross-list conflict(s) - item(s) on Keep + Delete simultaneously; run /wc clean apply",
                conflictCount)
        end
        -- enableDeletion off but delete list populated - user disabled the flow
        -- but items are still queued. Not a bug on its own, but if they report
        -- "delete isn't working" this is the answer.
        local delListCount = 0
        if DB.deleteList then
            for _ in pairs(DB.deleteList) do delListCount = delListCount + 1 end
        end
        if not DB.enableDeletion and delListCount > 0 then
            flags[#flags + 1] = string.format(
                "* enableDeletion OFF but %d item(s) queued on Delete List - flow is paused",
                delListCount)
        end
        if delListCount > 200 then
            flags[#flags + 1] = string.format(
                "* Delete List large (%d items) - review with /wc clean or the Delete Settings panel",
                delListCount)
        end
        -- Silent refusals imply the auto-protect sync tried to Keep-Add items
        -- that were already on the Delete List. The v2.50.2 shirt-loss root
        -- cause pattern - always worth investigating when count > 0.
        local refusals = NS.silentRefusalLog or {}
        if #refusals > 0 then
            flags[#flags + 1] = string.format(
                "! %d silent refusal(s) this session - Keep-Add refused because item was on a conflicting list (see Silent Refusals section)",
                #refusals)
        end
        -- Third-party auto-delete addon detected. Comment neutral per repo rules.
        if NS.HasConflictingDeleteAddon and NS.HasConflictingDeleteAddon() then
            flags[#flags + 1] = "! Third-party auto-delete addon detected"
        end
        -- Toggles changed this session - reviewer needs to know user isn't at defaults.
        local diffs = NS.ToggleDiffSinceLogin and NS.ToggleDiffSinceLogin() or {}
        if #diffs > 0 then
            flags[#flags + 1] = string.format(
                "* %d watched toggle(s) changed since login - see Toggles Changed This Session section",
                #diffs)
        end
        if #flags == 0 then
            add("  (no red-flag conditions detected)")
        else
            for i = 1, #flags do
                add("  " .. flags[i])
            end
        end
    end
    add("")

    -- v2.13.1 Live State section. Captures the runtime context at the
    -- exact moment of report. Useful for diagnosing merchant-mode
    -- target-vs-npc mismatches, combat-deferral cases, and "addon not
    -- doing anything" reports where the cause is a live unit / frame
    -- state the static settings can't show.
    add("--- Live State ---")
    add("In Combat: " .. tostring(InCombatLockdown and InCombatLockdown() or false))
    add("Mounted: " .. tostring(IsMounted and IsMounted() or false))
    local targetExists = UnitExists and UnitExists("target")
    add("Target: " .. ((targetExists and UnitName("target")) or "(none)"))
    local npcExists = UnitExists and UnitExists("npc")
    add("NPC (interact): " .. ((npcExists and UnitName("npc")) or "(none)"))
    local merchantOpen = MerchantFrame and MerchantFrame:IsShown() or false
    add("Merchant Open: " .. tostring(merchantOpen))
    local totalBagSlots = 0
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        totalBagSlots = totalBagSlots + (GetContainerNumSlots(bag) or 0)
    end
    add("Free Bags: " .. tostring(NS.GetFreeBagSlots()) .. " / " .. tostring(totalBagSlots))
    add("")

    add("--- Settings ---")
    -- v2.72.0: name the settings profile these values come from (the
    -- selling-behaviour fields below are per-profile now).
    add("Settings Profile: " .. tostring(DB.activeSettingsProfile or "Default"))
    add("Enabled: " .. tostring(DB.enabled))
    add("Repair Gear: " .. tostring(DB.repairGear))
    add("Repair via Guild Bank: " .. tostring(DB.repairUseGuildBank))
    add("Keep Bags Open: " .. tostring(DB.keepBagsOpen))
    add("Enable Deletion: " .. tostring(DB.enableDeletion))
    -- v2.50.3: destructive-side toggles that materially change what a
    -- "Marked for delete" or "Will Delete" chat line MEANS. Reports were
    -- ambiguous without these (Bizzaro v2.50.1: tooltip said Will Delete
    -- but nothing destroyed). Since v0.6.0 every delete is a Delete Next
    -- press; the game refuses automatic deletes.
    add("Mark Grey for Deletion: " .. tostring(DB.markGreyForDeletion))
    add("Announce Deletions in Chat: " .. tostring(DB.announceAutoDelete ~= false))
    add("Warn about Conflicting Addons: " .. tostring(DB.warnConflictingAddons ~= false))
    add("Vendor Interval: " .. tostring(DB.vendorInterval))
    add("Max Items Per Run: " .. tostring(DB.maxItemsPerRun))
    add("Fast Mode: " .. tostring(DB.fastMode))
    add("Turbo Mode: " .. tostring(DB.turboMode))
    -- v2.10.0 / v2.11.0 / v2.13.0 auto-protect family - omitting these
    -- left a blind spot in earlier reports for "why is X being kept?"
    -- diagnostics where the auto-protect path was the answer.
    add("Auto-Add Equipped: " .. tostring(DB.autoAddEquipped))
    add("Auto-Protect Upgrades: " .. tostring(DB.autoProtectUpgrades))
    add("Auto-Protect Equipment Sets: " .. tostring(DB.autoProtectEquipmentSets))
    add("Protect Unlearned Recipes: " .. tostring(DB.protectUnlearnedTomes))
    add("Protect All Recipes: " .. tostring(DB.protectAllTomes))
    add("Protect Uncollected Appearances: " .. tostring(DB.protectUncollectedAppearances))
    add("Protect Tradeable Loot: " .. tostring(DB.protectTradeableLoot))
    add("Sell Known Recipes: " .. tostring(DB.sellKnownRecipes))
    if DB.sellKnownRecipes then
        local rq = DB.sellKnownRecipeQualities or {}
        add(string.format(
            "  Recipe qualities (W/G/B/E): %s/%s/%s/%s",
            tostring(rq[1] == true),
            tostring(rq[2] == true),
            tostring(rq[3] == true),
            tostring(rq[4] == true)
        ))
        local rb = DB.sellKnownRecipeBindFilter or {}
        add(string.format(
            "  Recipe bind filter (W/G/B/E): %s/%s/%s/%s",
            tostring(rb[1] or "any"),
            tostring(rb[2] or "any"),
            tostring(rb[3] or "any"),
            tostring(rb[4] or "any")
        ))
    end
    -- v2.30.x: the per-character allowlist feature was decommissioned;
    -- DB.enableOnlyListedChars is force-disabled in EnsureDB and the
    -- bug report no longer surfaces the legacy fields.
    add("")

    add("--- Looting ---")
    add("Auto-Open Containers: " .. tostring(DB.autoOpenContainers))
    add("Fast Loot: " .. tostring(DB.fastLoot))
    add("")

    -- v2.13.1 Runtime State section. Snapshots in-flight signals so a
    -- report can pinpoint "why isn't this working" cases without requiring
    -- a /reload or chat-log scrape.
    add("--- Runtime State ---")
    -- v2.50.3: equipment-set diagnostic counters. `Saved` is the number of
    -- sets the Blizzard Equipment Manager knows about; `Members Cached`
    -- reflects WC_compCache.equipmentSetIDs (v2.50.2 shirt-loss rescue
    -- cache). A stale-or-empty cache with Saved > 0 hints that the
    -- EQUIPMENT_SETS_CHANGED handler didn't fire this session and the
    -- Layer 2 rescue is degraded.
    -- Reads "n/a" rather than 0 when the API is missing. The previous form
    -- was `(GetNumEquipmentSets and GetNumEquipmentSets()) or 0` against the
    -- bare 3.3.5a global, which is nil on Forever - so this line reported a
    -- confident "0" on every client, and the Saved > 0 hint above could never
    -- fire. A diagnostic that cannot distinguish "none saved" from "cannot
    -- tell" is worse than one that admits it does not know.
    local setsSaved = "n/a"
    if C_EquipmentSet and C_EquipmentSet.GetNumEquipmentSets then
        setsSaved = C_EquipmentSet.GetNumEquipmentSets() or 0
    end
    local setsCached = 0
    if WC_compCache.equipmentSetIDs then
        for _ in pairs(WC_compCache.equipmentSetIDs) do
            setsCached = setsCached + 1
        end
    end
    add("Equipment Sets Saved: " .. tostring(setsSaved))
    add("Equipment-Set Members Cached: " .. tostring(setsCached))
    add("")

    add("--- Sell Rules ---")
    add("Quality Rules:")
    for q = 1, 4 do
        local r = DB.qualityRules and DB.qualityRules[q] or {}
        local rarityName = (q == 1) and "White" or (q == 2) and "Green" or (q == 3) and "Blue" or "Epic"
        local capStr = (r.maxILvl and r.maxILvl > 0) and tostring(r.maxILvl) or "no cap"
        local bindStr = tostring(r.bindFilter or "any")
        add(
            string.format(
                "  %s: enabled=%s, max iLvl=%s, useEquipped=%s, bind=%s",
                rarityName,
                tostring(r.enabled),
                capStr,
                tostring(r.useEquippedILvl),
                bindStr
            )
        )
    end
    add("Active Profile: " .. tostring(DB.activeProfileName))
    add("Sell List Items: " .. tostring(NS.CountItems(DB.whitelist)))
    add("Account Sell List Items: " .. tostring(ADB and NS.CountItems(ADB.whitelist) or 0))
    add("Keep List Items: " .. tostring(NS.CountItems(DB.blacklist)))
    add("Delete List Items: " .. tostring(NS.CountItems(DB.deleteList)))
    add("")

    -- v2.13.1 Auto-Protected Breakdown. Walks DB.blacklistAuto and groups
    -- entries by origin tag so a user reporting "my Keep list is huge,
    -- why?" can see at a glance which auto-protect path is responsible.
    -- Legacy entries (v2.10.0 / v2.11.0 stamped a boolean true rather
    -- than a string tag) bucket separately so they're visible for the
    -- /wc clean upgrades workflow.
    if type(DB.blacklistAuto) == "table" then
        local cWorn, cUpgrade, cSet, cLegacy = 0, 0, 0, 0
        for _, tag in pairs(DB.blacklistAuto) do
            if tag == "equipped" then
                cWorn = cWorn + 1
            elseif tag == "upgrade" then
                cUpgrade = cUpgrade + 1
            elseif tag == "set" then
                cSet = cSet + 1
            elseif tag == true then
                cLegacy = cLegacy + 1
            end
        end
        local total = cWorn + cUpgrade + cSet + cLegacy
        if total > 0 then
            add("--- Auto-Protected Breakdown ---")
            add("Equipped (Worn): " .. cWorn)
            add("Upgrade: " .. cUpgrade)
            add("Set: " .. cSet)
            if cLegacy > 0 then
                add("Legacy (untagged): " .. cLegacy)
            end
            add("Total auto-tagged: " .. total)
            add("")
        end
    end

    add("--- Profiles ---")
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
        local wlCount = NS.CountItems(DB.whitelistProfiles[names[i]])
        local blCount = DB.blacklistProfiles[names[i]] and NS.CountItems(DB.blacklistProfiles[names[i]]) or 0
        local tag = (names[i] == DB.activeProfileName) and " (active)" or ""
        add(names[i] .. " (" .. wlCount .. " sell, " .. blCount .. " keep)" .. tag)
    end
    add("")

    add("--- Stats ---")
    add("Total Money Made: " .. WC_CopperToPlainText(DB.totalCopper or 0))
    add("Total Items Sold: " .. tostring(DB.totalItemsSold or 0))
    add("Total Items Deleted: " .. tostring(DB.totalItemsDeleted or 0))
    add("Total Repairs: " .. tostring(DB.totalRepairs or 0))
    add("Total Repair Cost: " .. WC_CopperToPlainText(DB.totalRepairCopper or 0))
    add("")

    -- Capability flags. The bag-rendering layer and auction-pricing source
    -- can interact (or fail to interact) with WC's hooks and integrations;
    -- capturing which capabilities are present disambiguates "bag
    -- decoration missing" / "tooltip overlaps" reports without a
    -- follow-up. Generic flags so the report doesn't depend on specific
    -- third-party addon names.
    add("--- Environment Capabilities ---")
    local hostBagUI = (_G.Bagnon ~= nil) or (_G.BagnonFrame ~= nil) or (_G.ArkInventory ~= nil) or (_G.ElvUI ~= nil) or (_G.DaylightUI ~= nil)
    add("Host bag UI detected: " .. (hostBagUI and "yes" or "no"))
    -- v2.49.2: neutral-framed conflict flag. The Loaded Addons dump
    -- below lists specific folder names; this line is the pre-filtered
    -- yes/no for scanning.
    add(
        "Third-party auto-delete addon detected: "
            .. ((NS.HasConflictingDeleteAddon and NS.HasConflictingDeleteAddon()) and "yes" or "no")
    )
    add(
        "Host bag-UI category API: "
            .. (WC_compCache.refreshHostCategories and "hooked" or "absent")
    )
    add("LibItemSearch: " .. (_G.LibStub and _G.LibStub("LibItemSearch-1.0", true) and "yes" or "no"))
    add(
        "Auction pricing source: "
            .. ((
                _G.Auctionator
                and _G.Auctionator.API
                and _G.Auctionator.API.v1
                and _G.Auctionator.API.v1.GetAuctionPriceByItemID
            ) and "detected" or "absent")
    )

    add("")
    add("--- Bag Display ---")
    add("Sell-border tint enabled: " .. (DB.sellBorderEnabled and "yes" or "no"))
    if DB.sellBorderCategories then
        -- v2.30.x: per-category sell-border colours replaced the
        -- single DB.sellBorderColor. Dump each category's enable +
        -- colour so bug reports surface user-customised tint state.
        local catOrder = { "delete", "accountSell", "charSell", "junk", "rule" }
        for _, key in ipairs(catOrder) do
            local entry = DB.sellBorderCategories[key]
            if entry and entry.color then
                local c = entry.color
                add(
                    string.format(
                        "  %-12s enabled=%s  r=%.2f g=%.2f b=%.2f a=%.2f",
                        key,
                        entry.enabled and "yes" or "no ",
                        c.r or 0,
                        c.g or 0,
                        c.b or 0,
                        c.a or 0
                    )
                )
            end
        end
    end
    local decoratedCount = 0
    if WC_compCache.sellBorderButtons then
        for _ in pairs(WC_compCache.sellBorderButtons) do
            decoratedCount = decoratedCount + 1
        end
    end
    add("Decorated slot buttons (this session): " .. tostring(decoratedCount))
    add("Host bag-UI border hook installed: " .. (WC_compCache._hostBagBorderHookInstalled and "yes" or "no"))

    add("")
    add("--- Allow Lists ---")
    local allowedItemCount = 0
    if ADB and ADB.allowedItems then
        for _ in pairs(ADB.allowedItems) do
            allowedItemCount = allowedItemCount + 1
        end
    end
    add("Per-item allow list: " .. tostring(allowedItemCount))
    add("Auto-mark PvP gear (Resilience) for deletion: " .. (DB.autoMarkResilience and "yes" or "no"))
    add("Auto-mark unsellable known recipes for deletion: " .. (DB.autoMarkKnownUnsellableRecipes and "yes" or "no"))
    add("")
    -- v2.50.3: Delete List preview + cross-list conflict summary. The
    -- delete list can grow to hundreds of items over time (Bizzaro:
    -- 714) so we don't dump the whole thing - just the first 15
    -- itemIDs with names for a "what does WC think is queued for
    -- destruction?" read. Cross-list conflict count flags legacy
    -- pre-WC_FindAddConflict data where an itemID is on both
    -- deleteList AND blacklist; v2.50.2's destruction-side rescue
    -- honours the blacklist, so a non-zero count is not a bug BUT
    -- indicates the user should run /wc clean apply.
    add("--- Delete List Preview ---")
    if DB.deleteList then
        local ids = {}
        for id in pairs(DB.deleteList) do
            if type(id) == "number" then
                ids[#ids + 1] = id
            end
        end
        table.sort(ids)
        local previewMax = 15
        local shown = math.min(previewMax, #ids)
        for i = 1, shown do
            local id = ids[i]
            -- v2.51.0: resolver primes the client cache via
            -- NS.scanTooltip so items not seen this session
            -- can still resolve to names / links.
            add(string.format("  [%d] %s", id, WC_ResolveItemLabel(id)))
        end
        if #ids > previewMax then
            add(string.format("  ... and %d more (total %d)", #ids - previewMax, #ids))
        elseif #ids == 0 then
            add("  (empty)")
        end
        local conflicts = 0
        if DB.blacklist then
            for id in pairs(DB.deleteList) do
                if DB.blacklist[id] then
                    conflicts = conflicts + 1
                end
            end
        end
        add("Cross-list conflicts (also on Keep List): "
            .. tostring(conflicts)
            .. (conflicts > 0 and " - run /wc clean apply to reconcile" or ""))
    else
        add("  (deleteList not initialised)")
    end
    add("")

    -- v2.50.3: recent auto-mark events. Ring buffer of the last N items
    -- runAutoMarkResilience wrote to deleteList
    -- this session. Directly answers "did WC mark my item, and when /
    -- why?" without needing the user's chat log to survive as evidence.
    -- Empty on a fresh session or when neither auto-mark scan has fired.
    add("--- Recent Auto-Mark Events ---")
    local log = NS.autoMarkLog or {}
    if #log == 0 then
        add("  (none this session)")
    else
        for i = 1, #log do
            local e = log[i]
            add(string.format("  [%s] %d %s - %s",
                tostring(e.loggedAt),
                tonumber(e.itemID) or 0,
                tostring(e.itemName),
                tostring(e.reason)))
        end
    end
    add("")

    -- v2.51.0: silent refusals from WC_AddItemToList's quiet-mode
    -- cross-list conflict guard. The auto-protect sync (equipped
    -- gear, upgrade scan, equipment sets) uses quiet=true so the
    -- refusal returns false with zero chat output - this ring buffer
    -- is the audit trail. Root cause of the v2.50.2 shirt-loss bug.
    add("--- Silent Refusals (Add rejected by cross-list conflict) ---")
    do
        local refusals = NS.silentRefusalLog or {}
        if #refusals == 0 then
            add("  (none this session)")
        else
            for i = 1, #refusals do
                local e = refusals[i]
                add(string.format("  [%s] %d %s - tried '%s' but item is on '%s' (caller: %s)",
                    tostring(e.loggedAt),
                    tonumber(e.itemID) or 0,
                    tostring(e.itemName),
                    tostring(e.targetList),
                    tostring(e.conflictList),
                    tostring(e.caller)))
            end
        end
    end
    add("")

    -- v2.51.0: recent-sold ring buffer. Answers "which specific items
    -- did WC sell in the last vendor visit / manual sell burst?" -
    -- lifetime totals answer "how many", not "which".
    add("--- Recent Sold (this session) ---")
    -- v2.68.1: the session logs are RING buffers - at the 5000 cap the
    -- array order rotates, so a tail slice by index would interleave old
    -- and new entries. Order by the per-entry `seq` instead and take the
    -- newest `cap`, printed oldest-first like before.
    local function newestBySeq(t, cap)
        local all = {}
        for i = 1, #t do
            all[i] = t[i]
        end
        table.sort(all, function(a, b)
            return (a.seq or 0) > (b.seq or 0)
        end)
        local n = math.min(cap, #all)
        local slice = {}
        for i = n, 1, -1 do
            slice[#slice + 1] = all[i]
        end
        return slice
    end
    do
        local rs = NS.recentSoldLog or {}
        local cap = NS.bugReportRecentMax or 20
        if #rs == 0 then
            add("  (none this session)")
        else
            -- The full session log can hold thousands now; the report shows
            -- only the newest `cap` so it stays short. The full list lives
            -- in the Sold History window (/wc history).
            local slice = newestBySeq(rs, cap)
            if #rs > #slice then
                add(string.format("  (newest %d of %d - full list in /wc history)", #slice, #rs))
            end
            for i = 1, #slice do
                local e = slice[i]
                add(string.format("  [%s] %d x%d %s (%s, %s) - %s",
                    tostring(e.loggedAt),
                    tonumber(e.itemID) or 0,
                    tonumber(e.count) or 1,
                    tostring(e.itemName),
                    tostring(e.path),
                    WC_CopperToPlainText(e.copper or 0),
                    tostring(e.reason or "?")))
            end
        end
    end
    add("")

    -- v2.51.0: recent-deleted ring buffer. Distinguishes auto-delete
    -- (auto-delete-on-pickup fired between BAG_UPDATE ticks) from
    -- vendor-cycle delete-queue actions. When a user says "it deleted
    -- something", the source tag says which flow.
    add("--- Recent Deleted (this session) ---")
    do
        local rd = NS.recentDeletedLog or {}
        local cap = NS.bugReportRecentMax or 20
        if #rd == 0 then
            add("  (none this session)")
        else
            local slice = newestBySeq(rd, cap)
            if #rd > #slice then
                add(string.format("  (newest %d of %d - full list in /wc history)", #slice, #rd))
            end
            for i = 1, #slice do
                local e = slice[i]
                add(string.format("  [%s] %d x%d %s (%s) - %s",
                    tostring(e.loggedAt),
                    tonumber(e.itemID) or 0,
                    tonumber(e.count) or 1,
                    tostring(e.itemName),
                    tostring(e.source),
                    tostring(e.reason or "?")))
            end
        end
    end
    add("")

    -- v2.70.0 (competitive-review A4): items SAVED by drain-time
    -- re-validation - the worker re-checked the rules right before the
    -- destructive call and a mid-run settings change vetoed it. Rare;
    -- ring-capped at 200; ordered by seq like the sibling logs.
    add("--- Recent Saved (rules changed mid-run) ---")
    do
        local rv = NS.recentSavedLog or {}
        local cap = NS.bugReportRecentMax or 20
        if #rv == 0 then
            add("  (none this session)")
        else
            local slice = newestBySeq(rv, cap)
            for i = 1, #slice do
                local e = slice[i]
                add(string.format("  [%s] %d x%d %s (%s) - %s",
                    tostring(e.loggedAt),
                    tonumber(e.itemID) or 0,
                    tonumber(e.count) or 1,
                    tostring(e.itemName),
                    tostring(e.kind),
                    tostring(e.reason or "?")))
            end
        end
    end
    add("")

    -- v2.59.4: Process Bags cast log. Fills the visibility gap in the
    -- previous ring buffers - Recent Sold covered vendor sells, Recent
    -- Deleted covered auto-delete + vendor-cycle deletes, but the
    -- Disenchant / Milling / Prospecting / Pick Lock / Convert casts
    -- had no per-item trace. Answers "what did I DE this session, did
    -- it include something I needed?" without back-and-forth.
    add("--- Recent Processed (this session) ---")
    do
        local rp = NS.recentProcessedLog or {}
        local cap = NS.bugReportRecentMax or 20
        if #rp == 0 then
            add("  (none this session)")
        else
            local startI = math.max(1, #rp - cap + 1)
            if startI > 1 then
                add(string.format("  (newest %d of %d)", #rp - startI + 1, #rp))
            end
            for i = startI, #rp do
                local e = rp[i]
                add(string.format("  [%s] %d x%d %s (%s)",
                    tostring(e.loggedAt),
                    tonumber(e.itemID) or 0,
                    tonumber(e.count) or 1,
                    tostring(e.itemName),
                    tostring(e.mode or e.spellName or "?")))
            end
        end
    end
    add("")

    -- Frame-spike rings (session-only): the worst frames of the session
    -- (severity-sorted, v2.76.0) then the most recent, with WC's share
    -- of each frame so the report proves whose stutter it was. Answers
    -- "the player reports a stutter - was WC the cause, and where?".
    -- The same frame can appear in both sections (the rings share
    -- entries); timestamps disambiguate.
    do
        local function spikeLine(e)
            local ms = tonumber(e.ms) or 0
            local ecMs = tonumber(e.ecMs) or 0
            local pct = ms > 0 and math.min(100, ecMs / ms * 100) or 0
            -- Mirror of /wc spike: when WC's total rounds to 0 ms, don't name
            -- an WC phase as busiest (raw English - bugreport convention).
            local busiest = ecMs < 0.5 and "something else" or tostring(e.dominant or "?")
            return string.format("  [%s] %.0f ms - %s - WC %.0f ms (%.0f%%) (bag %.0f / vendor %.0f / tooltip %.0f ms, %.0f FPS)",
                tostring(e.loggedAt),
                ms,
                busiest,
                ecMs,
                pct,
                tonumber(e.bagMs) or 0,
                tonumber(e.vendorMs) or 0,
                tonumber(e.tipMs) or 0,
                tonumber(e.fps) or 0)
        end
        add("--- Worst Frame Hitches (this session) ---")
        local wh = NS.worstSpikeLog or {}
        if #wh == 0 then
            add("  (none this session)")
        else
            for i = 1, #wh do
                add(spikeLine(wh[i]))
            end
        end
        add("")
        add("--- Recent Frame Hitches (this session) ---")
        local rh = NS.recentSpikeLog or {}
        if #rh == 0 then
            add("  (none this session)")
        else
            for i = 1, #rh do
                add(spikeLine(rh[i]))
            end
        end
    end
    add("")

    -- v2.51.0: watched-toggle diff since PLAYER_LOGIN. Snapshot was
    -- taken right after EnsureDB seeded defaults, so this section only
    -- shows toggles the user actively flipped this session. Empty on
    -- a fresh login when nothing was changed.
    add("--- Toggles Changed This Session ---")
    do
        local diffs = NS.ToggleDiffSinceLogin and NS.ToggleDiffSinceLogin() or {}
        if #diffs == 0 then
            add("  (none this session)")
        else
            for i = 1, #diffs do
                local d = diffs[i]
                add(string.format("  %s: %s -> %s",
                    tostring(d.key),
                    tostring(d.before),
                    tostring(d.now)))
            end
        end
    end
    add("")

    -- v2.51.0: last-run event timestamps. Answers "did BAG_UPDATE fire
    -- this session? did EQUIPMENT_SETS_CHANGED? when was the last
    -- vendor visit?" - a nil / "never" reading is diagnostic on its
    -- own (subsystem hasn't run despite being enabled).
    add("--- Last Event Times ---")
    do
        local ts = NS.lastEventAt or {}
        local order = {
            { "bagUpdate",             "Last BAG_UPDATE" },
            { "equipmentSetsChanged",  "Last EQUIPMENT_SETS_CHANGED" },
            { "merchantShow",          "Last MERCHANT_SHOW" },
            { "merchantClosed",        "Last MERCHANT_CLOSED" },
            { "vendorRunStart",        "Last vendor cycle StartRun" },
            { "autoMarkResilience",    "Last runAutoMarkResilience" },
            { "autoMarkKnownRecipe",   "Last runAutoMarkKnownUnsellableRecipes" },
        }
        for i = 1, #order do
            local k, label = order[i][1], order[i][2]
            local v = ts[k]
            -- Stamps are epoch integers (formatted here, not at stamp time);
            -- tolerate legacy string values from a mid-session upgrade.
            if type(v) == "number" then
                v = date("%H:%M:%S", v)
            end
            add(string.format("  %s: %s", label, tostring(v or "(never)")))
        end
    end
    add("")

    -- v2.51.0: session cache stats. Large caches with mostly-'any'
    -- entries suggest a scan-time issue (bind detection race, tooltip
    -- not populated at scan time). Empty caches suggest the paths that
    -- populate them haven't been exercised - which is diagnostic when
    -- the user reports "detection isn't working".
    add("--- Cache Stats ---")
    do
        local cc = NS.compCache or {}
        local function sizeOf(t)
            if type(t) ~= "table" then
                return 0
            end
            local n = 0
            for _ in pairs(t) do n = n + 1 end
            return n
        end
        local function countBindTypes(t)
            if type(t) ~= "table" then
                return 0, 0, 0
            end
            local boe, bop, any = 0, 0, 0
            for _, v in pairs(t) do
                if v == "boe" then
                    boe = boe + 1
                elseif v == "bop" then
                    bop = bop + 1
                elseif v == "any" then
                    any = any + 1
                end
            end
            return boe, bop, any
        end
        local boe, bop, anyBind = countBindTypes(cc.bindCache)
        add(string.format("  bindCache: %d (boe=%d bop=%d any=%d)",
            sizeOf(cc.bindCache), boe, bop, anyBind))
        add(string.format("  processCache: %d", sizeOf(cc.processCache)))
        add(string.format("  equipmentSetIDs: %d", sizeOf(cc.equipmentSetIDs)))
    end
    add("")

    add("--- Bags ---")
    add("Free Slots: " .. tostring(NS.GetFreeBagSlots()))

    -- v2.37.0: installed addons section. Walks GetNumAddOns() and
    -- lists every LOADED addon by title + version. Maintainer can
    -- spot bag-management / vendor / loot addons that may race with
    -- WC's hooks, which makes "the addon isn't doing X" reports
    -- diagnosable from the first read rather than after a back-and-
    -- forth about the user's setup. Disabled addons are excluded -
    -- they're not running and can't conflict.
    add("")
    add("--- Loaded Addons ---")
    local n = GetNumAddOns and GetNumAddOns() or 0
    if n == 0 then
        add("(GetNumAddOns unavailable)")
    else
        local entries = {}
        for i = 1, n do
            local name, title = GetAddOnInfo(i)
            local loaded = IsAddOnLoaded and IsAddOnLoaded(i)
            if loaded then
                local meta = GetAddOnMetadata and GetAddOnMetadata(i, "Version") or nil
                local rawTitle = (title and title ~= "") and title or (name or "?")
                -- Strip Blizzard's colour escapes so the report stays
                -- pasteable into plain-text contexts.
                local cleanTitle = rawTitle:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                entries[#entries + 1] = {
                    name = name or "?",
                    title = cleanTitle,
                    version = meta or "",
                }
            end
        end
        table.sort(entries, function(a, b) return a.name < b.name end)
        if #entries == 0 then
            add("(no addons reported as loaded)")
        else
            -- v2.51.0: partition into "Potentially Relevant" (bag /
            -- vendor / loot / auction / mail / tooltip / error-handling
            -- addons that could interact with WC's surfaces) vs.
            -- "Other". Substring match on the addon's identifier and
            -- title, case-folded. Not exhaustive; picks the categories
            -- that have historically caused conflict reports.
            local KEYWORDS = {
                "bag", "bagn", "vend", "sell", "loot", "junk", "clean",
                "auc", "mail", "post", "auto", "delete", "trash",
                "tip", "tooltip", "item", "container",
                "bug", "err", "log",
                "prof", "craft",
            }
            local function looksRelevant(e)
                local hay = ((e.name or "") .. " " .. (e.title or "")):lower()
                for i = 1, #KEYWORDS do
                    if hay:find(KEYWORDS[i], 1, true) then
                        return true
                    end
                end
                return false
            end
            local relevant, other = {}, {}
            for _, e in ipairs(entries) do
                if looksRelevant(e) then
                    relevant[#relevant + 1] = e
                else
                    other[#other + 1] = e
                end
            end
            local function printOne(e)
                if e.version ~= "" then
                    add("  " .. e.name .. " (" .. e.title .. ") v" .. e.version)
                else
                    add("  " .. e.name .. " (" .. e.title .. ")")
                end
            end
            add("Loaded: " .. tostring(#entries)
                .. " (" .. tostring(#relevant) .. " potentially relevant, "
                .. tostring(#other) .. " other)")
            if #relevant > 0 then
                add("  Potentially Relevant (bag / vendor / loot / auction / tooltip / error):")
                for _, e in ipairs(relevant) do
                    printOne(e)
                end
            end
            if #other > 0 then
                add("  Other:")
                for _, e in ipairs(other) do
                    printOne(e)
                end
            end
        end
    end

    return table.concat(lines, "\n")
end

-- Every copy view (bug report, rules, dumps, Sold History, URLs) uses the
-- shared kit window, the same one RaidLootController shows. It opens
-- without keyboard focus so it can stay up while you play; clicking the
-- text selects all of it for one Ctrl+C. DIALOG strata + Raise keeps it
-- above the Settings panel and the WoWClearance window (both HIGH).
local function WC_ShowCopyFrame(titleText, bodyText, chatHint)
    NS.Kit.ShowCopy("WoWClearanceCopy", titleText or "WoWClearance", bodyText or "", 560, 400)
    if chatHint then
        NS.PrintNice(chatHint)
    end
end

local function WC_ShowBugReport()
    WC_ShowCopyFrame(
        "WoWClearance: " .. L["Bug Report"],
        WC_BuildBugReport(),
        L["Bug report generated. Copy the text from the window."]
    )
end

-- v2.44.0: rule summary in plain English. Triggered by /wc rules.
-- Surfaces the actual order of operations WoWClearance uses to
-- decide DELETE vs SELL vs KEEP for each bag item, alongside the
-- player's currently active toggles. Asked for by ch (the addon
-- author) as a one-stop reference for understanding why a specific
-- item went the way it did - complements /wc sellinfo's per-item
-- trace by showing the whole rule book at a glance.
local function WC_BuildRuleSummary()
    local DB = NS.DB
    local lines = {}
    local function add(s)
        lines[#lines + 1] = s
    end
    local function onoff(v)
        return v and "|cff00ff00ON|r" or "|cffff4444OFF|r"
    end
    local function yesno(v, yesLabel, noLabel)
        if v then
            return "|cff00ff00" .. (yesLabel or "yes") .. "|r"
        else
            return "|cffff4444" .. (noLabel or "no") .. "|r"
        end
    end

    add("=== WoWClearance Rule Summary ===")
    add("Generated: " .. (date and date("%Y-%m-%d %H:%M:%S") or "?"))
    add("Player: " .. (GetUnitName("player", true) or "?") .. "-" .. (GetRealmName() or "?"))
    add("Addon: " .. (NS.GetVersion and NS.GetVersion() or "?"))
    add("")
    add("Master switch: " .. onoff(DB and DB.enabled ~= false))

    add("")
    add("--- How WoWClearance handles each item in your bags ---")
    add("")
    add("Step 1: Should I DELETE this?")
    add("  Yes, if ALL of these apply:")
    add("    - The item is on your Delete List, AND")
    add("    - 'Allow items to be deleted' is on (currently " .. onoff(DB.enableDeletion) .. ")")
    add("")
    add("  Extras:")
    add("    - Deleting happens only when you press Delete Next (key or Delete List button),")
    add("      one item per press. 'Mark grey items for deletion' (" .. onoff(DB.markGreyForDeletion) .. ")")
    add("      lets it take grey items too, cheapest first.")
    add("    - 'Auto-mark PvP gear (Resilience)' (" .. onoff(DB.autoMarkResilience) .. ") adds items")
    add("      with Resilience to your Delete List automatically.")
    add("    - 'Auto-mark unsellable known recipes for deletion' ("
        .. onoff(DB.autoMarkKnownUnsellableRecipes) .. ") adds learned")
    add("      profession recipes with no vendor value to the Delete List. Requires Sell Known Recipes.")
    add("")
    add("Step 2: Should I SELL this?  ('Sell items at vendors' is " .. onoff(DB.sellAtVendor ~= false) .. ")")
    add("  Yes, if ANY ONE of the reasons below matches (the rules don't")
    add("  cancel each other - each one independently triggers a sell):")
    add("    - It's grey junk with a vendor price ('Sell grey items' is " .. onoff(DB.sellGreys ~= false) .. ")")
    add("    - It's on your Sell List or Account Sell List")
    add("    - It matches a quality rule:")
    if DB and DB.qualityRules then
        local qNames = { "White", "Green", "Blue", "Epic" }
        for q = 1, 4 do
            local r = DB.qualityRules[q]
            local enabled = r and r.enabled
            local mode
            if r and r.useEquippedILvl then
                -- Spell out the consequence: this mode only sells items below
                -- your currently-worn gear, so higher-iLvl drops are kept. A
                -- player expecting "sell all of this rarity" hits this and
                -- thinks nothing sells (see the rank/quality FAQ).
                mode = "equipped iLvl - keeps upgrades"
            elseif r and r.maxILvl and r.maxILvl > 0 then
                mode = "max iLvl " .. tostring(r.maxILvl)
            else
                mode = "no cap - sells all"
            end
            local bind = (r and r.bindType) or "any"
            add(string.format(
                "        %s: %s  (%s, bind: %s)",
                qNames[q],
                yesno(enabled, "ON", "OFF"),
                mode,
                bind
            ))
        end
    end
    add("    - It's a profession recipe you already know, and")
    add("      'Sell recipes you already know' is " .. onoff(DB.sellKnownRecipes))
    add("")
    add("  ...AND NOTHING blocks it:")
    add("    - You're currently wearing it -> keep")
    add("    - It's on your Keep List -> keep")
    add("    - It's a quest item (quality rules only) -> keep")
    add("    - It belongs to a saved equipment set ("
        .. onoff(DB.autoProtectEquipmentSets) .. ") -> keep")
    add("    - It's locked in your bag addon -> keep")
    add("    - Its appearance isn't collected yet, and 'Keep gear with an")
    add("      appearance you haven't collected' is " .. onoff(DB.protectUncollectedAppearances) .. " -> keep")
    add("    - You can still trade or refund it, and 'Keep loot you can")
    add("      still trade or refund' is " .. onoff(DB.protectTradeableLoot) .. " -> keep")
    add("      (both unless it's on your Sell List or you chose 'Allow Sell')")
    add("    - It's an unlearned recipe, and")
    add("      'Keep unlearned recipes' is " .. onoff(DB.protectUnlearnedTomes) .. " -> keep")
    add("")
    add("Step 3: Otherwise, keep it (default).")
    add("")
    add("--- Your current settings at a glance ---")
    add("  Master switch:                            " .. onoff(DB and DB.enabled ~= false))
    add("  Allow deleting (Delete Next):             " .. onoff(DB.enableDeletion))
    add("  Mark grey items for deletion:             " .. onoff(DB.markGreyForDeletion))
    add("  Auto-mark PvP gear (Resilience):          " .. onoff(DB.autoMarkResilience))
    add("  Auto-mark unsellable known recipes:       " .. onoff(DB.autoMarkKnownUnsellableRecipes))
    add("  Keep gear you're wearing:                 " .. onoff(DB.autoAddEquipped))
    add("  Keep upgrades found in bags:              " .. onoff(DB.autoProtectUpgrades))
    add("  Keep items in saved equipment sets:       " .. onoff(DB.autoProtectEquipmentSets))
    add("  Keep unlearned recipes:                   " .. onoff(DB.protectUnlearnedTomes))
    add("  Keep all recipes (even learned):          " .. onoff(DB.protectAllTomes))
    add("  Keep uncollected appearances:             " .. onoff(DB.protectUncollectedAppearances))
    add("  Keep loot you can trade or refund:        " .. onoff(DB.protectTradeableLoot))
    add("  Sell recipes you already know:            " .. onoff(DB.sellKnownRecipes))
    local sellCount = 0
    if DB.whitelist then
        for _ in pairs(DB.whitelist) do
            sellCount = sellCount + 1
        end
    end
    local keepCount = 0
    if DB.blacklist then
        for _ in pairs(DB.blacklist) do
            keepCount = keepCount + 1
        end
    end
    local delCount = 0
    if DB.deleteList then
        for _ in pairs(DB.deleteList) do
            delCount = delCount + 1
        end
    end
    local acctSellCount = 0
    if NS.ADB and NS.ADB.whitelist then
        for _ in pairs(NS.ADB.whitelist) do
            acctSellCount = acctSellCount + 1
        end
    end
    add("")
    add(string.format("  Sell List entries:           %d", sellCount))
    add(string.format("  Account Sell List entries:   %d", acctSellCount))
    add(string.format("  Keep List entries:           %d", keepCount))
    add(string.format("  Delete List entries:         %d", delCount))
    add("")
    add("--- See more ---")
    add("  /wc sellinfo  - per-item trace (or Alt+Shift+Right-Click on a bag item)")
    add("  /wc bugreport - full diagnostic dump")

    return table.concat(lines, "\n")
end

local function WC_ShowRuleSummary()
    WC_ShowCopyFrame(
        "WoWClearance: " .. L["Current Rules"],
        WC_BuildRuleSummary(),
        L["Rule summary generated. Copy the text from the window."]
    )
end

-- v2.38.3: one-shot diagnostic for the Process Bags engine. Triggered
-- by /wc processdebug. Surfaces every gate that decides whether an
-- item shows up in the Disenchant / Mill / Prospect / Lockpick list,
-- so a player whose herbs/ores don't appear can paste the dump and
-- we can pinpoint which layer is failing on their setup (custom
-- profession spell IDs, tooltip-marker variance, IsSpellKnown
-- behaviour on different cores, etc.). Mirrors the
-- dump's pattern: pure plain-text, copy-paste-friendly, single
-- generate-and-show call (no recording over time).
local function WC_BuildProcessDebugDump()
    local lines = {}
    local function add(s)
        lines[#lines + 1] = s
    end
    add("=== WoWClearance Process Bags Debug Dump ===")
    add("Generated: " .. (date and date("%Y-%m-%d %H:%M:%S") or "?"))
    add("Player: " .. (GetUnitName("player", true) or "?") .. "-" .. (GetRealmName() or "?"))
    add("Class: " .. (UnitClass and (UnitClass("player")) or "?") .. " / Level " .. tostring(UnitLevel and UnitLevel("player") or "?"))
    add("Locale: " .. (GetLocale and GetLocale() or "?"))
    add("Addon: " .. (NS.GetVersion and NS.GetVersion() or "?"))
    add("")

    local cc = NS.compCache
    if not cc then
        add("ERROR: NS.compCache is nil; addon not fully loaded.")
        return table.concat(lines, "\n")
    end

    add("--- Spell knowledge gates ---")
    local function spellRow(label, id)
        local name = WC_compCache.spellName(id) or "<C_Spell.GetSpellInfo nil>"
        local known = WC_compCache.spellKnown(id) and "yes" or "no"
        add(string.format("  %-12s id=%-6d  IsSpellKnown=%s  GetSpellInfo='%s'", label, id, known, name))
    end
    spellRow("Disenchant", cc.SPELL_DISENCHANT or 13262)
    spellRow("Milling", cc.SPELL_MILLING or 51005)
    spellRow("Prospecting", cc.SPELL_PROSPECTING or 31252)
    spellRow("Pick Lock", cc.SPELL_PICK_LOCK or 1804)
    add("")

    add("--- Tooltip marker globals ---")
    add(string.format("  ITEM_MILLABLE     = '%s'", tostring(ITEM_MILLABLE)))
    add(string.format("  ITEM_PROSPECTABLE = '%s'", tostring(ITEM_PROSPECTABLE)))
    add(string.format("  ITEM_SOULBOUND    = '%s'", tostring(ITEM_SOULBOUND)))
    add(string.format("  LOCKED            = '%s'", tostring(LOCKED)))
    add(string.format("  ITEM_SPELL_KNOWN  = '%s'", tostring(ITEM_SPELL_KNOWN)))
    add("")

    local DB = NS.DB
    if not DB then
        add("ERROR: NS.DB is nil; cannot evaluate per-slot gates.")
        return table.concat(lines, "\n")
    end
    local ignored = DB.processIgnored or {}
    local maxQ = DB.processMaxDEQuality or 4
    add(string.format("--- Settings ---"))
    add(string.format("  processMaxDEQuality   = %d", maxQ))
    add(string.format("  processIncludeSoulbound = %s", tostring(DB.processIncludeSoulbound == true)))
    add(string.format("  lockpickEnabled         = %s", tostring(DB.lockpickEnabled == true)))
    local ignCount = 0
    for _ in pairs(ignored) do
        ignCount = ignCount + 1
    end
    add(string.format("  processIgnored entries  = %d", ignCount))
    add("")

    -- v2.38.3: processCache state. If a stack-of-5 Prospectable item is
    -- in bags but the panel shows no Prospect section, the cache having
    -- "none" for that itemID is the smoking gun for a tooltip-not-ready
    -- race that wrote a poisoned entry during early /reload scan.
    add("--- processCache state (per-itemID classification cache) ---")
    if cc.processCache then
        local entries = {}
        for id, v in pairs(cc.processCache) do
            entries[#entries + 1] = string.format("    id=%-6d -> '%s'", id, tostring(v))
        end
        table.sort(entries)
        if #entries == 0 then
            add("  (empty)")
        else
            add(string.format("  %d entry/entries:", #entries))
            for _, line in ipairs(entries) do
                add(line)
            end
        end
    else
        add("  (cc.processCache is nil)")
    end
    add("")

    add("--- Bag walk (every non-empty slot) ---")
    local rowCount, herbOrOreShown = 0, 0
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local itemID = GetContainerItemID(bag, slot)
            local link = GetContainerItemLink(bag, slot)
            -- v2.38.3: direct call (NOT `(API and API(args))`) so the
            -- multi-return texture/count/locked/quality/... reaches
            -- us. The parenthesised guard form discarded everything
            -- past the first return value, so count was always nil
            -- and the filter rejected every slot.
            local cInfo = C_Container.GetContainerItemInfo(bag, slot)
            local count = cInfo and cInfo.stackCount
            if itemID and link and count and count > 0 then
                rowCount = rowCount + 1
                local itemString = link:match("item[%-?%d:]+") or "?"
                -- v2.38.3: direct call (no parens) so the multi-return
                -- (name, link, quality, ...) doesn't collapse to a single
                -- value. The original `(API and API(args))` form silently
                -- discarded everything past the first return so quality
                -- was always nil and the dump always showed q=?. Same
                -- class of bug as the count variant fixed above.
                local _, _, quality = GetItemInfo(itemID)
                local equippable = (C_Item.IsEquippableItem and C_Item.IsEquippableItem(itemID)) and "Y" or "N"
                local equipped = (C_Item.IsEquippedItem and C_Item.IsEquippedItem(itemID)) and "Y" or "N"
                local ignoredHit = ignored[itemString] and "Y" or "N"
                local blacklisted = (IsInSet and DB.blacklist and IsInSet(DB.blacklist, itemID)) and "Y" or "N"
                local ttResult = cc.processTooltipHasLine and cc.processTooltipHasLine(bag, slot, itemID) or "?"
                local canDE = cc.canDisenchant and cc.canDisenchant(itemID) and "Y" or "N"
                local canM = cc.canMill and cc.canMill(bag, slot, itemID) and "Y" or "N"
                local canP = cc.canProspect and cc.canProspect(bag, slot, itemID) and "Y" or "N"
                add(string.format(
                    "  b%d s%-2d id=%-6d q=%s ct=%-3d ttScan=%-8s DE=%s M=%s P=%s | ign=%s bl=%s eq=%s | %s",
                    bag, slot, itemID, tostring(quality or "?"), count, ttResult, canDE, canM, canP,
                    ignoredHit, blacklisted, equipped, link
                ))
                -- v2.38.3: dump tooltip lines for the most suspicious
                -- slots, capped at 3 dumps to keep output short:
                --   (a) any slot where ttScan returned Mill or Prospect
                --       - confirms what PE's actual tooltip line says
                --   (b) any non-equippable, low-quality, stack>=5 slot
                --       where ttScan returned 'none' - that's the
                --       cache-poisoning candidate (herbs/ores that
                --       the engine thinks aren't processable)
                local interesting = (ttResult == "Mill" or ttResult == "Prospect")
                    or (
                        ttResult == "none"
                        and equippable == "N"
                        and (quality or 0) <= 1
                        and count >= 5
                    )
                if interesting and herbOrOreShown < 3 then
                    herbOrOreShown = herbOrOreShown + 1
                    add(string.format("    -- tooltip dump for b%d s%d (%s, ttScan=%s):", bag, slot, link, ttResult))
                    if cc.scanBagItem and NS.scanTooltip then
                        -- v2.38.3: route through the shared helper that
                        -- enforces SetOwner before SetBagItem. The bug
                        -- this diagnostic surfaced (silent zero-line
                        -- SetBagItem when ownership was lost) is now
                        -- fixed structurally - the helper re-establishes
                        -- ownership every call.
                        cc.scanBagItem(bag, slot)
                        local numLines = NS.scanTooltip.NumLines and NS.scanTooltip:NumLines() or -1
                        add(string.format("       NumLines() = %d", numLines))
                        for i = 1, 30 do
                            local lineFS = WC_compCache.scanLines[i]
                            if not lineFS then
                                add(string.format("       L%-2d: <FontString not registered>", i))
                                break
                            end
                            local txt = lineFS:GetText()
                            if txt == nil then
                                add(string.format("       L%-2d: <nil>", i))
                            elseif txt == "" then
                                add(string.format("       L%-2d: <empty string>", i))
                            else
                                add(string.format("       L%-2d: '%s'", i, txt))
                            end
                            if i >= numLines and numLines > 0 then
                                break
                            end
                        end
                    else
                        add("       (NS.scanTooltip is nil)")
                    end
                end
            end
        end
    end
    if rowCount == 0 then
        add("  (no items in bags)")
    end
    add("")
    add(string.format("--- Summary ---"))
    if cc.buildProcessSummary then
        local results = cc.buildProcessSummary() or {}
        local byMode = {}
        for _, e in ipairs(results) do
            byMode[e.mode] = (byMode[e.mode] or 0) + 1
        end
        add(string.format("  buildProcessSummary entries: %d", #results))
        for mode, n in pairs(byMode) do
            add(string.format("    %s: %d", mode, n))
        end
    else
        add("  ERROR: buildProcessSummary helper missing")
    end
    return table.concat(lines, "\n")
end

local function WC_ShowProcessDebugDump()
    WC_ShowCopyFrame(
        "WoWClearance: " .. L["Process Bags Debug Dump"],
        WC_BuildProcessDebugDump(),
        L["Process debug dump generated. Copy the text from the window."]
    )
end

-- v2.44.12: scan-tooltip diagnostic. A server's tooltip enrichment may
-- or may not fire on hidden tooltips depending on its tooltip-hook
-- pattern. When a reported item silently sells, this dump shows EXACTLY
-- what WC's scan tooltip sees vs what the live tooltip would show.
-- Output sections:
--   * Item context (link, itemID, baseName, equipLoc, quality, ilvl)
--   * Raw scan-tooltip lines 1-30 (the source-of-truth for every
--     WC_compCache.scanBagItem-backed predicate)
local function WC_BuildScanDebugDump(bag, slot)
    local lines = {}
    local function add(s)
        lines[#lines + 1] = s
    end
    add(string.format("=== WoWClearance Scan Tooltip Debug (bag %d slot %d) ===", bag, slot))
    add("Version: " .. (NS.GetVersion and NS.GetVersion() or "unknown"))
    add(string.format("Date: %s", date and date("%Y-%m-%d %H:%M") or "?"))
    add("")
    local itemID = GetContainerItemID and GetContainerItemID(bag, slot)
    local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
    if not itemID then
        add("ERROR: no item in bag " .. bag .. " slot " .. slot .. ".")
        return table.concat(lines, "\n")
    end
    local baseName, _, quality, ilvl, _, _, _, _, equipLoc = GetItemInfo(itemID)
    local cInfo = C_Container.GetContainerItemInfo(bag, slot)
    local count = cInfo and cInfo.stackCount
    add("--- Item Context ---")
    add("link:     " .. tostring(link))
    add("itemID:   " .. tostring(itemID))
    add("baseName: " .. tostring(baseName))
    add("count:    " .. tostring(count))
    add("quality:  " .. tostring(quality))
    add("ilvl:     " .. tostring(ilvl))
    add("equipLoc: " .. tostring(equipLoc))
    add("")
    add("--- Scan Tooltip Lines (after scanBagItem) ---")
    if WC_compCache.scanBagItem then
        WC_compCache.scanBagItem(bag, slot)
        local empty = true
        for i = 1, 30 do
            local fs = WC_compCache.scanLines[i]
            local txt = fs and fs.GetText and fs:GetText()
            if txt and txt ~= "" then
                add(string.format("  [%d] %s", i, txt))
                empty = false
            end
        end
        if empty then
            add("  (no text lines populated - SetBagItem returned an empty tooltip)")
        end
    else
        add("ERROR: WC_compCache.scanBagItem missing.")
    end
    add("")
    add("--- Detection Results ---")
    return table.concat(lines, "\n")
end

local function WC_ShowScanDebugDump(bag, slot)
    WC_ShowCopyFrame(
        "WoWClearance: " .. L["Scan Tooltip Debug"],
        WC_BuildScanDebugDump(bag, slot),
        L["Scan debug dump generated. Copy the text from the window."]
    )
end

NS.ShowBugReport = WC_ShowBugReport
NS.ShowProcessDebugDump = WC_ShowProcessDebugDump
NS.ShowScanDebugDump = WC_ShowScanDebugDump
NS.ShowRuleSummary = WC_ShowRuleSummary
-- v2.49.1: expose the generic copy-window helper so callers outside
-- WoWClearance_BugReport.lua (e.g. NS.ShowAutolearnPeek in Events.lua)
-- can render their own state dumps into a copyable frame instead of
-- flooding the chat window. Signature: (titleText, bodyText, chatHint).
NS.ShowCopyFrame = WC_ShowCopyFrame
