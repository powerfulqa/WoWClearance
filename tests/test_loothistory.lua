#!/usr/bin/env lua
-- Runtime tests for the per-pickup loot history (WoWClearance_Loot/WoWClearance_LootHistory.lua).
-- Run: lua tests/test_loothistory.lua
-- Loads the chunk in isolation with stub globals and drives the parser, the
-- ring buffer and the CHAT_MSG_LOOT handler directly.

-- Forever: UnitName gives the first name only; senders and GetUnitName(unit,
-- true) carry the surname. Another player may share the first name.
_G.UnitName = function() return "Self", "Surname" end
_G.GetUnitName = function() return "Self Surname" end
_G.GetRealmName = function() return "Some Realm" end
_G.Ambiguate = function(name) return (name:gsub("%-SomeRealm$", "")) end
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
_G.time = function() return 1791000000 end
local accessible = true
-- canaccessvalue takes one value; "SecretBob" stands for a secret sender.
_G.canaccessvalue = function(v) return accessible and v ~= "SecretBob" end
-- enUS client strings.
_G.LOOT_ITEM = "%s receives loot: %s."
_G.LOOT_ITEM_MULTIPLE = "%s receives loot: %sx%d."

local NS = { ADB = {}, compCache = {} }
assert(loadfile("WoWClearance_Kit.lua"))("WoWClearance", NS) -- NS.Kit, loaded first as in the .toc
assert(loadfile("WoWClearance_Core.lua"))("WoWClearance", NS) -- NS.CanRead
NS.ADB, NS.compCache = {}, {}
-- The Loot module reads the core namespace from its own table (.core).
assert(loadfile("WoWClearance_Loot/WoWClearance_LootHistory.lua"))("WoWClearance_Loot", { core = NS })
local LH = NS.LootHistory

local fails = 0
local function ok(name, cond)
    if cond then print("PASS  " .. name) else print("FAIL  " .. name); fails = fails + 1 end
end
local function eq(name, a, b) ok(name .. " (" .. tostring(a) .. ")", a == b) end

local LINK = "|cff1eff00|Hitem:2589::::::::|h[Linen Cloth]|h|r"

-- Parser: multiple, single, own line, junk.
local who, id, n = LH.ParseGroupLoot("Bob receives loot: " .. LINK .. "x3.")
eq("multiple: looter", who, "Bob")
eq("multiple: itemID", id, 2589)
eq("multiple: qty", n, 3)
who, id, n = LH.ParseGroupLoot("Bob-OtherRealm receives loot: " .. LINK .. ".")
eq("single: cross-realm looter", who, "Bob-OtherRealm")
eq("single: qty defaults to 1", n, 1)
ok("own 'You receive' line is not parsed", LH.ParseGroupLoot("You receive loot: " .. LINK .. ".") == nil)
ok("non-item line is not parsed", LH.ParseGroupLoot("Bob receives loot: 5 Silver.") == nil)
ok("non-string is not parsed", LH.ParseGroupLoot(nil) == nil)

-- A positional format with the item BEFORE the name: the parser must not
-- depend on capture order.
local pats = { LH.FormatToPattern("Beute (%2$sx%3$d) erhalten von %1$s.") }
who, id, n = LH.ParseGroupLoot("Beute (" .. LINK .. "x2) erhalten von Anna.", pats)
eq("positional: looter", who, "Anna")
eq("positional: itemID", id, 2589)
eq("positional: qty", n, 2)

-- Event handler: group member logged with own realm appended; own name and
-- unreadable (secret) payloads skipped.
-- The event is registered on the Loot module's frame and routed here; the
-- core hub no longer handles loot events (v0.9.0).
local fh = assert(io.open("WoWClearance_Loot/WoWClearance_LootCapture.lua", "r"))
local ev = fh:read("*a")
fh:close()
fh = assert(io.open("WoWClearance_Events.lua", "r"))
local hub = fh:read("*a")
fh:close()
ok("loot module registers CHAT_MSG_LOOT", ev:find('f:RegisterEvent("CHAT_MSG_LOOT")', 1, true) ~= nil)
ok("loot module routes CHAT_MSG_LOOT to LootHistory", ev:find("NS.LootHistory.OnChatMsgLoot(...)", 1, true) ~= nil)
ok("core hub no longer registers CHAT_MSG_LOOT", hub:find('RegisterEvent("CHAT_MSG_LOOT")', 1, true) == nil)
local function handler(_, _, text, sender) LH.OnChatMsgLoot(text, sender) end
local function newest()
    if LH.Count() == 0 then return nil end
    local t, id2, n2, who2 = LH.Get(LH.SlotAt(1))
    return { t = t, id = id2, n = n2, who = who2 }
end
handler(nil, "CHAT_MSG_LOOT", "Bob receives loot: " .. LINK .. "x3.", "Bob")
local e = newest()
eq("handler: who gets own realm", e and e.who, "Bob-SomeRealm")
eq("handler: qty", e and e.n, 3)
eq("handler: time stamped", e and e.t, 1791000000)
ok("handler: marks the window dirty", NS.compCache.lootWindowDirty == true)
handler(nil, "CHAT_MSG_LOOT", "Self Surname receives loot: " .. LINK .. ".", "Self Surname")
eq("handler: own name skipped", NS.ADB.lootHistory.writes, 1)
accessible = false
handler(nil, "CHAT_MSG_LOOT", "Bob receives loot: " .. LINK .. ".", "Bob")
eq("handler: secret payload skipped", NS.ADB.lootHistory.writes, 1)
accessible = true
handler(nil, "CHAT_MSG_LOOT", "Bob receives loot: " .. LINK .. ".", "SecretBob")
eq("handler: secret sender skipped", NS.ADB.lootHistory.writes, 1)

-- Own loot via Add with no looter: stamped as the player.
LH.Add(4306, 2)
eq("Add: defaults to the player", newest().who, "Self Surname-SomeRealm")
LH.Add(nil, 1)
LH.Add(4306, 0)
eq("Add: rejects bad input", NS.ADB.lootHistory.writes, 2)

-- Ring: at the cap the oldest is overwritten in place, and readers still
-- see newest first.
LH.Clear()
eq("Clear resets writes", NS.ADB.lootHistory.writes, 0)
LH.MAX = 3
for i = 1, 5 do LH.Add(i, 1) end
local seen = {}
for k = 1, LH.Count() do
    local _, x = LH.Get(LH.SlotAt(k))
    seen[#seen + 1] = x
end
eq("ring keeps MAX entries", #seen, 3)
eq("ring newest first [1]", seen[1], 5)
eq("ring newest first [3]", seen[3], 3)
local slots = 0
for _ in pairs(NS.ADB.lootHistory.e) do slots = slots + 1 end
eq("ring storage never exceeds MAX", slots, 3)

-- Storage is packed: one string per entry, looter names stored once.
local packed = NS.ADB.lootHistory.e[LH.SlotAt(1)]
ok("entry is a packed string", type(packed) == "string" and packed:match("^%d+:5:1:%d+$") ~= nil)
eq("looter name stored once", #NS.ADB.lootHistory.names, 1)

-- A saved table from a fresh login decodes back to the same entries.
local saved = NS.ADB.lootHistory
NS.ADB = { lootHistory = { v = 2, writes = saved.writes, e = saved.e, names = saved.names } }
local _, reloadedID, _, reloadedWho = LH.Get(LH.SlotAt(1))
eq("reload decodes newest itemID", reloadedID, 5)
eq("reload decodes looter", reloadedWho, "Self Surname-SomeRealm")

-- The first-cut v1 shape migrates, oldest first, keeping newest-first order.
LH.MAX = 20000
NS.ADB = { lootHistory = { writes = 2, entries = {
    { t = 100, id = 11, n = 1, who = "Ann-SomeRealm" },
    { t = 200, id = 22, n = 4, who = "Bob-SomeRealm" },
} } }
eq("v1 migrates entry count", LH.Count(), 2)
local t1, id1, n1, w1 = LH.Get(LH.SlotAt(1))
eq("v1 newest itemID", id1, 22)
eq("v1 newest qty", n1, 4)
eq("v1 newest looter", w1, "Bob-SomeRealm")
eq("v1 newest time", t1, 200)
eq("v1 store is now v2", NS.ADB.lootHistory.v, 2)

-- v0.7.0: the shared search matcher (Core) behind the Loot Log and Sold
-- History search boxes.
local SM = NS.SearchMatcher
ok("matcher: empty search is nil", SM("") == nil and SM("  ") == nil and SM(nil) == nil)
local m = SM("linen")
ok("matcher: substring, any case", m("Bolt of Linen Cloth") == true)
ok("matcher: no hit", m("Wool Cloth") == false)
ok("matcher: link matched by its name", m(LINK) == true)
ok("matcher: link markup never matches", SM("hitem")(LINK) == false)
m = SM('"Linen Cloth"')
ok("matcher: quoted is exact", m(LINK) == true and m("Bolt of Linen Cloth") == false)
m = SM("wool || silk")
ok("matcher: || is either", m("Silk Cloth") == true and m("Wool Cloth") == true and m("Linen Cloth") == false)
ok("matcher: any argument may match", SM("vendor")("Linen Cloth", "Auto-sell (vendor junk)") == true)
ok("matcher: non-string arguments skipped", SM("x")(nil, 5) == false)

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURE(S)"))
os.exit(fails == 0 and 0 or 1)
