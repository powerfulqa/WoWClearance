-- WoWClearance_LootCapture - loot tracking for the optional Loot module.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- WoWClearance_Loot is a separate addon that depends on WoWClearance. It
-- holds everything that records or shows what you LOOT, as opposed to what
-- WoWClearance sells or deletes: the Loot Log and its history, looted coin,
-- gold per hour and the top farming zones. Turn it off in the AddOn list
-- (or from WoWClearance's main page) and the core addon runs without it.
--
-- Data stays in WoWClearanceDB / WoWClearanceAccountDB (the core addon's
-- saved variables, schema seeded by its EnsureDB), so switching the module
-- off and on loses nothing and needs no migration.
--
-- The core addon's namespace is reached through C_AddOns.GetAddOnLocalTable,
-- which works because WoWClearance.toc sets AllowAddOnTableAccess. Every
-- module file reads it from this addon's own table (`own.core`), which this
-- file, loaded first, fills in.
--
-- Core hooks this file sets (each is nil-checked at the core call site, so
-- the core runs unchanged when the module is off):
--   WC_compCache.scanLootDelta()   - BAG_UPDATE flush: record looted items
--   WC_compCache.onSoldCopper(c)   - a sale landed: zone total + GPH record
--   WC_compCache.onResetSession()  - Reset Session Stats was pressed

local own = select(2, ...)
local NS = C_AddOns and C_AddOns.GetAddOnLocalTable and C_AddOns.GetAddOnLocalTable("WoWClearance")
if type(NS) ~= "table" or not NS.compCache then
    print("|cff66ccffWoWClearance Loot:|r could not reach WoWClearance. Update both addons together.")
    return
end
own.core = NS

local WC_compCache = NS.compCache
local L = NS.L
local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetContainerItemID = C_Container.GetContainerItemID

-- Looted coin this session (the core session table holds the sold side).
NS.session.lootCopper = 0

-- Session loot ledger. Keyed by itemID -> total quantity looted this
-- session. In-memory only (clears on /reload and Reset Session). This is
-- an AGGREGATE, not an event log: storage is one small integer per
-- distinct item, so it stays bounded no matter how long the farm runs.
local lootSession = {}
NS.lootSession = lootSession

function WC_compCache.onResetSession()
    NS.session.lootCopper = 0
    -- Wipe in place so references held by the loot window stay valid.
    wipe(lootSession)
end

-- Clear one scope of the loot ledger. Wipes in place so existing table
-- references stay valid.
function NS.ClearLoot(scope)
    if scope == "account" then
        local AS = NS.ADB and NS.ADB.accountStats
        if AS and AS.lootedItemCounts then
            wipe(AS.lootedItemCounts)
        end
    elseif scope == "history" then
        if NS.LootHistory then
            NS.LootHistory.Clear()
        end
    elseif scope == "character" then
        if NS.DB and NS.DB.lootedItemCounts then
            wipe(NS.DB.lootedItemCounts)
        end
    else
        wipe(lootSession)
    end
end

-- v2.35.x session rate + best-record stamp. Returns the session
-- copper/hour (sold + looted coin), or nil in the first 10 s. Called after
-- a vendor run, on looted coin, and by the Loot panel's 1Hz tick, so a
-- record is kept with the panel closed.
function NS.StampBestGPH()
    local DB, ADB = NS.DB, NS.ADB
    local startedAt = NS.session.startedAt or 0
    local elapsed = (startedAt > 0) and (GetTime() - startedAt) or 0
    -- 10-second floor: a shorter window extrapolates to absurd rates.
    if not (DB and elapsed >= 10) then
        return nil
    end
    local sessionGPH = math.floor(((NS.session.copper + NS.session.lootCopper) / elapsed) * 3600)
    -- Best-update gate: 5 minutes of session AND new high. Compared
    -- against both records independently so a character-best update
    -- doesn't require an account-best, and vice versa.
    if elapsed >= 300 then
        local zone = GetRealZoneText()
        local zoneText = (zone and zone ~= "") and zone or "Unknown"
        local nowTime = time()
        if sessionGPH > (DB.bestGPH or 0) then
            DB.bestGPH = sessionGPH
            DB.bestGPHAt = nowTime
            DB.bestGPHZone = zoneText
        end
        local AS = ADB and ADB.accountStats
        if AS and sessionGPH > (AS.bestGPH or 0) then
            AS.bestGPH = sessionGPH
            AS.bestGPHAt = nowTime
            AS.bestGPHZone = zoneText
            AS.bestGPHChar = GetUnitName("player", true) or ""
        end
    end
    return sessionGPH
end

-- v2.37.0: add a sale's copper to the current zone's lifetime total
-- ("Unknown" when the zone text isn't ready, e.g. mid-load), then stamp the
-- gold-per-hour record. City sales are skipped (v2.59.5): vendoring
-- mailboxed items in a capital is not farming. Wallet totals are bumped by
-- the core separately, so they stay accurate.
function WC_compCache.onSoldCopper(copper)
    if not copper or copper <= 0 then
        return
    end
    local zone = GetRealZoneText and GetRealZoneText() or nil
    if not zone or zone == "" then
        zone = "Unknown"
    end
    if not WC_compCache.isCityZone(zone) then
        WC_compCache.bumpStatBucket("copperByZone", zone, copper)
    end
    NS.StampBestGPH()
end

-- Loot tracker bump. Writes the session ledger plus the per-character and
-- account-wide running totals. Aggregate per itemID, so it never grows
-- into an event log; the per-pickup log is LootHistory.
local function bumpLoot(itemID, qty)
    if not itemID then
        return
    end
    qty = qty or 1
    if qty <= 0 then
        return
    end
    lootSession[itemID] = (lootSession[itemID] or 0) + qty
    local DB, ADB = NS.DB, NS.ADB
    if DB then
        DB.lootedItemCounts = DB.lootedItemCounts or {}
        DB.lootedItemCounts[itemID] = (DB.lootedItemCounts[itemID] or 0) + qty
    end
    if ADB and ADB.accountStats then
        ADB.accountStats.lootedItemCounts = ADB.accountStats.lootedItemCounts or {}
        ADB.accountStats.lootedItemCounts[itemID] = (ADB.accountStats.lootedItemCounts[itemID] or 0) + qty
    end
    -- Per-pickup history (who/when). Own loot only; group members' loot
    -- arrives from chat in WoWClearance_LootHistory.lua.
    if NS.LootHistory then
        NS.LootHistory.Add(itemID, qty)
    end
    -- v2.50.1: mark the Loot Log window for refresh. Its OnUpdate rebuilds
    -- on this flag (throttled) instead of unconditionally every second, so
    -- an open window costs nothing while no new loot is arriving.
    WC_compCache.lootWindowDirty = true
end

-- Loot capture. We track NET BAG INCREASES rather than parsing
-- CHAT_MSG_LOOT, because a pet or AOE loot source can drop its haul straight
-- into your bags without firing a "you receive loot" chat line. A bag-delta
-- scan catches every source uniformly. Summing per itemID across all bags
-- means moving or splitting stacks nets to zero; only genuine increases are
-- recorded.
--
-- Runs from the core's BAG_UPDATE debounce flush, so it costs one bag walk
-- per settled burst. To avoid counting non-loot inflows (vendor buys,
-- bank or mail withdrawals, trade, auction, crafting output), the scan only
-- DIFFS when no transactional window is open; while one is open it just
-- re-baselines the snapshot.
local lootBagSnapshot = {}
local lootSnapshotReady = false

-- Frame NAMES (not refs) for the windows through which items legitimately
-- enter bags without being "loot". Looked up via _G at call time because
-- several are load-on-demand - and a table of frame refs with nil holes
-- would make ipairs stop at the first nil (the v2.46.0 bug where mailbox
-- takes were counted). QuestFrame / GossipFrame cover quest rewards and
-- gossip-vendor grants.
local LOOT_TXN_FRAMES = {
    "MerchantFrame",
    "BankFrame",
    "GuildBankFrame",
    "MailFrame",
    "OpenMailFrame",
    "TradeFrame",
    "AuctionHouseFrame",
    "ProfessionsFrame",
    "QuestFrame",
    "GossipFrame",
}

local function transactionWindowOpen()
    for i = 1, #LOOT_TXN_FRAMES do
        local f = _G[LOOT_TXN_FRAMES[i]]
        if f and f.IsShown and f:IsShown() then
            return true
        end
    end
    return false
end

-- v0.7.0: coin picked up from loot windows. Money gained between a loot
-- window opening (LOOT_READY) and 2 s after it closes is loot coin: the
-- money update can land just after LOOT_CLOSED under auto-loot. Reading
-- the money total instead of the loot slots or the chat line keeps this
-- free of localized text. Gains while a transaction window is open never
-- count. Coin from loot that skips the loot window entirely is not seen.
local lootMoneyBase, lootMoneyUntil
local function lootMoneyEvent(event)
    local now = GetTime()
    if event == "LOOT_READY" then
        lootMoneyBase = GetMoney()
        lootMoneyUntil = math.huge
    elseif event == "LOOT_CLOSED" then
        if lootMoneyUntil then
            lootMoneyUntil = now + 2
        end
    elseif event == "PLAYER_MONEY" then
        local base, money = lootMoneyBase, GetMoney()
        lootMoneyBase = money
        if base and money > base and now <= (lootMoneyUntil or 0) and not transactionWindowOpen() then
            local gain = money - base
            NS.session.lootCopper = NS.session.lootCopper + gain
            WC_compCache.bumpStat("totalLootCopper", gain)
            NS.StampBestGPH()
        end
    end
end

-- Fresh { itemID = totalCount } snapshot across the backpack, bags 1-4 and
-- the reagent bag. Used only outside a flush frame.
local function buildBagSnapshot()
    local snap = {}
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local id = GetContainerItemID(bag, slot)
            if id then
                local cInfo = C_Container.GetContainerItemInfo(bag, slot)
                local count = cInfo and cInfo.stackCount
                snap[id] = (snap[id] or 0) + (count or 1)
            end
        end
    end
    return snap
end

-- v2.49.0: equipped snapshot for the unequip guard. Unequipping a worn item
-- moves it from an equipment slot to a bag slot, which shows as a positive
-- bag delta. Comparing equipped items across scans detects "was equipped
-- last scan, isn't now" and subtracts it before crediting loot. v2.68.1:
-- double-buffered, so this always-on path allocates nothing per burst.
local lootEquippedSnapshot = {}
local lootEquippedSpare = {}
local lootUnequippedScratch = {}
local function buildEquippedSnapshot(into)
    wipe(into)
    for slot = 1, 19 do
        local id = GetInventoryItemID("player", slot)
        if id then
            into[id] = (into[id] or 0) + 1
        end
    end
    return into
end

-- Diff current bags against the last snapshot and record positive deltas as
-- looted. The first call after login / reload only baselines (existing bag
-- contents are not "loot").
function WC_compCache.scanLootDelta()
    if NS.IsAddonEnabledForChar and not NS.IsAddonEnabledForChar() then
        return
    end
    -- Skip while an item is on the cursor: a bag reorganise picks an item
    -- up (count drops) then drops it back (count returns). Leaving the
    -- snapshot untouched until the cursor clears nets the round trip to zero.
    if CursorHasItem and CursorHasItem() then
        return
    end
    -- v2.59.0: reuse the core flush's shared {itemID = count} map when
    -- inside a flush (saves a second bag walk). The shared map is never
    -- mutated after build, so keeping it as the next baseline is safe.
    local sharedSnap = WC_compCache.currentFlushSnapshot()
    local snap = sharedSnap and sharedSnap.counts or buildBagSnapshot()
    if not lootSnapshotReady or transactionWindowOpen() then
        lootBagSnapshot = snap
        buildEquippedSnapshot(lootEquippedSnapshot)
        lootSnapshotReady = true
        return
    end
    local equippedNow = buildEquippedSnapshot(lootEquippedSpare)
    local unequipped = lootUnequippedScratch
    wipe(unequipped)
    for id, prevEq in pairs(lootEquippedSnapshot) do
        local nowEq = equippedNow[id] or 0
        if nowEq < prevEq then
            unequipped[id] = prevEq - nowEq
        end
    end
    -- Delete List items count as loot: nothing deletes them on arrival
    -- (v0.6.0, the game refuses automatic deletes).
    for id, count in pairs(snap) do
        local prev = lootBagSnapshot[id] or 0
        if count > prev then
            local netDelta = (count - prev) - (unequipped[id] or 0)
            if netDelta > 0 then
                bumpLoot(id, netDelta)
            end
        end
    end
    lootBagSnapshot = snap
    lootEquippedSpare = lootEquippedSnapshot
    lootEquippedSnapshot = equippedNow
end

-- Default key for the Loot Log: Shift+L. Claimed ONCE per account
-- (ADB.lootLogKeyClaimed) and only when both sides are free - the Loot Log
-- has no key yet AND nothing else uses Shift+L - so it never overwrites a
-- binding, and a player who later unbinds it does not get it back. Run a few
-- seconds after login: saving the binding set before the client has loaded
-- it could write over the player's bindings. SetBinding is blocked in
-- combat, so a combat login just tries next login.
local function claimLootLogKey()
    local ADB = NS.ADB
    if not ADB or ADB.lootLogKeyClaimed or InCombatLockdown() then
        return
    end
    ADB.lootLogKeyClaimed = true
    if GetBindingKey("WOWCLEARANCE_TOGGLE_LOOTLOG") then
        return
    end
    local current = GetBindingAction("SHIFT-L")
    if current and current ~= "" then
        return
    end
    if SetBinding("SHIFT-L", "WOWCLEARANCE_TOGGLE_LOOTLOG") then
        SaveBindings(GetCurrentBindingSet())
        NS.PrintNice(L["Shift+L now opens the Loot Log. Change it under Key Bindings > WoWClearance."])
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("LOOT_READY")
f:RegisterEvent("LOOT_CLOSED")
f:RegisterEvent("PLAYER_MONEY")
-- Loot Log History: group members' loot lines (WoWClearance_LootHistory.lua).
f:RegisterEvent("CHAT_MSG_LOOT")
f:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_LOOT" then
        if NS.LootHistory then
            NS.LootHistory.OnChatMsgLoot(...)
        end
    elseif event == "PLAYER_LOGIN" then
        NS.Delay(5, claimLootLogKey)
        -- Decode the saved Loot Log history (up to 20,000 entries, ~10 ms)
        -- now, not inside the first bag update that records a pickup.
        NS.Delay(6, function()
            if NS.LootHistory and NS.LootHistory.Count then
                NS.LootHistory.Count()
            end
        end)
    else
        lootMoneyEvent(event)
    end
end)
