#!/usr/bin/env lua
-- Unit + static tests for guild-share encode/decode/merge.
-- Run: lua tests/test_guildshare.lua
-- Loads the chunk in isolation with a stub NS.Comms (it registers handlers at load).

local handlers = {}
local sent = {}
local function clearSent() for i = #sent, 1, -1 do sent[i] = nil end end
local NS = {
    Comms = {
        RegisterHandler = function(t, fn) handlers[t] = fn end,
        Send = function(t, payload, channel, target) sent[#sent + 1] = { t = t, payload = payload, channel = channel, target = target } end,
        GroupChannel = function() end,
    },
    Delay = function() end,
    compCache = {},
}
-- Forever: UnitName gives the first name only; senders and GetUnitName(unit,
-- true) carry the surname. Another player may share the first name.
_G.UnitName = function() return "Self", "Surname" end
_G.GetUnitName = function() return "Self Surname" end
local fakeNow = 1000
_G.GetTime = function() return fakeNow end
-- WoW API namespace stubs. Since the port, addon files bind
-- `local X = C_Namespace.X` at file scope, which throws outside the
-- game before any test body runs. See tests/wow_stub.lua.
dofile("tests/wow_stub.lua")

local chunk = assert(loadfile("WoWClearance_GuildShare.lua"))
chunk("WoWClearance", NS)
local gs = NS.GuildShare

local fails = 0
local function ok(name, cond)
    if cond then print("PASS  " .. name) else print("FAIL  " .. name); fails = fails + 1 end
end
local function eq(name, a, b) ok(name .. " (" .. tostring(a) .. ")", a == b) end

-- topZones: sort desc, cap to n
local top = gs.topZones({ ["Durotar"] = 50, ["Barrens"] = 200, ["Mulgore"] = 10 }, 2)
eq("topZones count", #top, 2)
eq("topZones[1] name", top[1].name, "Barrens")
eq("topZones[1] copper", top[1].copper, 200)

-- encode/decode round-trip
local payload = gs.encodePayload({ { name = "Barrens", copper = 200 } }, { totalCopper = 999, itemsSold = 12, bestGPH = 3456 })
ok("payload has stats", payload:find("stats:", 1, true) ~= nil)
ok("payload has zones", payload:find("zones:", 1, true) ~= nil)
local dec = gs.decodePayload(payload)
eq("decode totalCopper", dec.stats.totalCopper, 999)
eq("decode itemsSold", dec.stats.itemsSold, 12)
eq("decode bestGPH", dec.stats.bestGPH, 3456)
eq("decode zone name", dec.zones[1].name, "Barrens")
eq("decode zone copper", dec.zones[1].copper, 200)

-- cap to 5 zones + skip delimiter-bad names
local many = {}
for i = 1, 9 do many[i] = { name = "Zone" .. i, copper = i * 10 } end
many[10] = { name = "Bad=Zone", copper = 5 }
local capped = gs.encodePayload(many, { totalCopper = 0, itemsSold = 0, bestGPH = 0 })
local dc = gs.decodePayload(capped)
ok("capped to <= 5 zones", #dc.zones <= 5)
ok("delimiter zone skipped", capped:find("Bad=Zone", 1, true) == nil)
ok("payload under 255 bytes", #capped < 255)

-- merge: pool two replies
local agg = gs.newAggregate()
gs.mergeReply(agg, gs.decodePayload(gs.encodePayload({ { name = "Barrens", copper = 100 } }, { totalCopper = 100, itemsSold = 5, bestGPH = 1000 })))
gs.mergeReply(agg, gs.decodePayload(gs.encodePayload({ { name = "Barrens", copper = 50 } }, { totalCopper = 200, itemsSold = 3, bestGPH = 2000 })))
eq("merge memberCount", agg.memberCount, 2)
eq("merge Barrens copper", agg.zones["Barrens"].copper, 150)
eq("merge Barrens contributors", agg.zones["Barrens"].contributors, 2)
eq("merge totalCopper", agg.totalCopper, 300)
eq("merge totalItems", agg.totalItems, 8)
eq("merge bestGPH (max)", agg.bestGPH, 2000)

-- ---- transport handler behavior (privacy-critical paths) ----
WoWClearanceDB = { copperByZone = { Barrens = 100 }, totalCopper = 100, soldItemsByQuality = { 5 }, bestGPH = 50 }

-- opt-in OFF: a GREQ from someone else produces no reply
WoWClearanceDB.shareGuildData = false
clearSent()
handlers.GREQ("", "Other", "GUILD")
ok("no reply when opted out", #sent == 0)

-- opt-in ON: a GREQ from someone else produces exactly one GDAT whisper to them
WoWClearanceDB.shareGuildData = true
clearSent()
handlers.GREQ("", "Other", "GUILD")
ok("one reply when opted in", #sent == 1)
ok("reply is GDAT", sent[1] and sent[1].t == "GDAT")
ok("reply is a whisper to requester", sent[1] and sent[1].channel == "WHISPER" and sent[1].target == "Other")

-- a GREQ that appears to come from ourselves produces no reply
clearSent()
handlers.GREQ("", "Self Surname", "GUILD")
ok("no self-reply", #sent == 0)

-- GDAT is anyone's whisper: nothing merges unless we asked.
NS.compCache.guildAgg = nil
WoWClearanceDB.shareGuildData = false -- keep self out of the counts below
local gdatPayload = gs.encodePayload({ { name = "Barrens", copper = 100 } }, { totalCopper = 100, itemsSold = 5, bestGPH = 50 })
handlers.GDAT(gdatPayload, "SecretSenderName", "WHISPER")
eq("unsolicited GDAT ignored", gs.GetAggregate().memberCount, 0)

-- After our request: merges once per sender, and the sender name is never stored
_G.GetGuildInfo = function() return "Guild" end
gs.RequestNow()
handlers.GDAT(gdatPayload, "SecretSenderName", "WHISPER")
handlers.GDAT(gdatPayload, "SecretSenderName", "WHISPER")
local a = gs.GetAggregate()
eq("GDAT merged memberCount (one per sender)", a.memberCount, 1)
eq("GDAT merged zone copper", a.zones["Barrens"].copper, 100)
local flat = {}
local function flatten(t)
    for k, v in pairs(t) do
        flat[#flat + 1] = tostring(k)
        if type(v) == "table" then flatten(v) else flat[#flat + 1] = tostring(v) end
    end
end
flatten(a)
ok("sender name not stored in aggregate", table.concat(flat, "|"):find("SecretSenderName", 1, true) == nil)

-- absurd numbers are dropped; a claimed name shows as the real sender
handlers.GDAT(gs.encodePayload({}, { totalCopper = 1e15, itemsSold = 1, bestGPH = 1 }), "Liar", "WHISPER")
eq("absurd totals dropped", gs.GetAggregate().memberCount, 1)
handlers.GDAT(gs.encodePayload({}, { totalCopper = 1, itemsSold = 1, bestGPH = 9999 }, nil, "Famous Player"), "Real Sender", "WHISPER")
local named = gs.GetAggregate()
ok("claimed name replaced by real sender", named.contributors["Real Sender"] and not named.contributors["Famous Player"])
eq("best GPH holder is the real sender", named.bestGPHName, "Real Sender")
handlers.GDAT(gdatPayload, "Self Surname", "WHISPER")
eq("own whisper never merged", gs.GetAggregate().memberCount, 2)
fakeNow = fakeNow + 31
handlers.GDAT(gdatPayload, "Latecomer", "WHISPER")
eq("reply after the request window ignored", gs.GetAggregate().memberCount, 2)
WoWClearanceDB.shareGuildData = true

-- items now carry id + name; 5th encode arg is a per-rarity count map
local pItems = gs.encodePayload(
    { { name = "Barrens", copper = 200 } },
    { totalCopper = 1, itemsSold = 1, bestGPH = 1 },
    { { id = 4306, name = "Silk Cloth", count = 7 }, { id = 2589, name = "Linen Cloth", count = 3 } },
    "Alaric",
    { [0] = 10, [2] = 5 }
)
ok("payload has items section", pItems:find("items:", 1, true) ~= nil)
ok("payload encodes id~name", pItems:find("4306~Silk Cloth=7", 1, true) ~= nil)
ok("payload has qual section", pItems:find("qual:", 1, true) ~= nil)
local dItems = gs.decodePayload(pItems)
eq("decode item count", #dItems.items, 2)
eq("decode item id", dItems.items[1].id, 4306)
eq("decode item name", dItems.items[1].name, "Silk Cloth")
eq("decode item count val", dItems.items[1].count, 7)
eq("decode quality poor", dItems.quality[0], 10)
eq("decode quality uncommon", dItems.quality[2], 5)
eq("decode name", dItems.name, "Alaric")
eq("decode still has zone", dItems.zones[1].name, "Barrens")

-- backward compat: 2-arg encode (no items/name/quality)
local dNo = gs.decodePayload(gs.encodePayload({ { name = "Barrens", copper = 5 } }, { totalCopper = 0, itemsSold = 0, bestGPH = 0 }))
eq("no items -> empty", #dNo.items, 0)

-- merge pools items by id (keeping name) and sums quality
local aItems = gs.newAggregate()
gs.mergeReply(aItems, gs.decodePayload(gs.encodePayload({}, { totalCopper = 0, itemsSold = 0, bestGPH = 0 }, { { id = 4306, name = "Silk Cloth", count = 5 } }, nil, { [2] = 4 })))
gs.mergeReply(aItems, gs.decodePayload(gs.encodePayload({}, { totalCopper = 0, itemsSold = 0, bestGPH = 0 }, { { id = 4306, name = "Silk Cloth", count = 2 } }, nil, { [2] = 1 })))
eq("merged item pooled by id", aItems.items[4306].count, 7)
eq("merged item keeps name", aItems.items[4306].name, "Silk Cloth")
eq("merged item contributors", aItems.items[4306].contributors, 2)
eq("merged quality summed", aItems.quality[2], 5)

-- best-GPH holder name: tracked when the top holder consented; nil if anonymous
local aGPH = gs.newAggregate()
gs.mergeReply(aGPH, gs.decodePayload(gs.encodePayload({}, { totalCopper = 0, itemsSold = 0, bestGPH = 1000 }, nil, "Alaric")))
eq("bestGPH name = consenting holder", aGPH.bestGPHName, "Alaric")
gs.mergeReply(aGPH, gs.decodePayload(gs.encodePayload({}, { totalCopper = 0, itemsSold = 0, bestGPH = 5000 }, nil)))
eq("bestGPH name cleared when higher holder is anonymous", aGPH.bestGPHName, nil)

-- ---- static-pattern invariants (scan live code, not comments) ----
local function readCode(p)
    local fh = assert(io.open(p, "r"))
    local s = fh:read("*a")
    fh:close()
    local out = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        local t = line:match("^%s*(.-)%s*$") or ""
        if t:sub(1, 2) ~= "--" then out[#out + 1] = line end
    end
    return table.concat(out, "\n")
end
local share = readCode("WoWClearance_GuildShare.lua")
ok("exposes NS.GuildShare", share:find("NS.GuildShare", 1, true) ~= nil)
ok("exposes InjectTestPeers diagnostic", share:find("function GuildShare.InjectTestPeers", 1, true) ~= nil)
ok("uses NS.Comms transport", share:find("NS.Comms", 1, true) ~= nil)
ok("reply gated on shareGuildData", share:find("shareGuildData", 1, true) ~= nil)
ok("registers GREQ", share:find('"GREQ"', 1, true) ~= nil)
ok("registers GDAT", share:find('"GDAT"', 1, true) ~= nil)
ok("zone cap constant present", share:find("MAX_ZONES", 1, true) ~= nil)
ok("no 4.0 group event", not share:find("GROUP_ROSTER_UPDATE", 1, true))
-- v2.59.5: RequestNow must include the local player in the freshly-reset
-- aggregate. Pre-fix the GREQ self-skip meant the viewer's own totals never
-- entered the panel they were looking at. Matches ServerShare's RequestNow
-- self-include pattern (same rationale, different transport).
ok("RequestNow seeds self into aggregate when opted in",
    share:find("function GuildShare.RequestNow", 1, true) ~= nil
        and share:find("GuildShare.mergeReply(GuildShare.GetAggregate(), GuildShare.decodePayload(localPayload()))", 1, true) ~= nil)
local panel = readCode("WoWClearance_GuildPanel.lua")
ok("panel reads aggregate", panel:find("GetAggregate", 1, true) ~= nil)
ok("panel opt-in writes shareGuildData", panel:find("shareGuildData", 1, true) ~= nil)
-- v2.39.x: GuildPanel now loads before Events.lua so registration is
-- centralised in Events.lua alongside Stats - Personal. The panel must
-- NOT self-register; Events.lua must contain the AddCategory call.
ok("panel does not self-register", panel:find("RegisterOptionsSub", 1, true) == nil)
-- The sidebar order lives in one place: WC_PANEL_ORDER in Window.lua.
local window = readCode("WoWClearance_Window.lua")
ok("guild panel is in the sidebar order", window:find('"WoWClearanceOptionsGuild",', 1, true) ~= nil)

-- v2.59.5: receiver-side city filter. A pre-v2.59.5 peer still has city
-- entries in DB.copperByZone and sends them unchanged, so decode must
-- drop city-named zones before they enter the aggregate. Stub isCityZone
-- with a minimal set; the filter is nil-safe (guarded by an `and` chain)
-- so encode/decode above have run cleanly without it.
NS.compCache.isCityZone = function(name) return name == "Dalaran" or name == "Stormwind City" end
local dCity = gs.decodePayload(gs.encodePayload(
    { { name = "Dalaran", copper = 5000 }, { name = "Icecrown", copper = 3000 }, { name = "Stormwind City", copper = 2000 } },
    { totalCopper = 10000, itemsSold = 1, bestGPH = 100 }
))
eq("city Dalaran dropped at decode", (function() for _, z in ipairs(dCity.zones) do if z.name == "Dalaran" then return "PRESENT" end end return "DROPPED" end)(), "DROPPED")
eq("city Stormwind City dropped at decode", (function() for _, z in ipairs(dCity.zones) do if z.name == "Stormwind City" then return "PRESENT" end end return "DROPPED" end)(), "DROPPED")
eq("non-city Icecrown kept at decode", (function() for _, z in ipairs(dCity.zones) do if z.name == "Icecrown" then return "PRESENT" end end return "DROPPED" end)(), "PRESENT")
ok("decode has isCityZone guard on zones parse",
    share:find("prefix == \"zones\"", 1, true) ~= nil
        and share:find("not isCityZone(name)", 1, true) ~= nil)

print()
if fails > 0 then io.stderr:write("RESULT: " .. fails .. " test(s) failed\n"); os.exit(1) end
print("RESULT: all tests passed")
os.exit(0)
