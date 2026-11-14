#!/usr/bin/env lua
-- Unit + static tests for the realm-wide "Stats - Server" odometer.
-- Run: lua tests/test_servershare.lua
-- Loads WoWClearance_ServerShare.lua in isolation with a stub NS.RealmComms
-- (it registers SREQ/SDAT handlers at load) + stubs for the helpers it uses.

local rhandlers = {}
local sent = {}
local noted = {} -- NS.Comms.NotePeerVersion calls
local fakeNow = 1000
local function clearSent() for i = #sent, 1, -1 do sent[i] = nil end end

_G.GetTime = function() return fakeNow end
-- Forever: UnitName gives the first name only; senders and GetUnitName(unit,
-- true) carry the surname. Another player may share the first name.
_G.UnitName = function() return "Self", "Surname" end
_G.GetUnitName = function() return "Self Surname" end
_G.GetItemInfo = function(id) return "Item" .. tostring(id) end

local NS = {
    RealmComms = {
        RegisterHandler = function(t, fn) rhandlers[t] = fn end,
        -- NOTE: realm sends take (msgType, payload) ONLY - no channel/target.
        -- The absence of a target is what proves replies go channel-wide, not
        -- as a whisper storm aimed at one player.
        Send = function(t, payload) sent[#sent + 1] = { t = t, payload = payload } end,
        Join = function() end,
    },
    Comms = {
        NotePeerVersion = function(v, s) noted[#noted + 1] = { v = v, s = s } end,
    },
    GuildShare = {
        topZones = function(map, n)
            local arr = {}
            for name, c in pairs(map or {}) do arr[#arr + 1] = { name = name, copper = c } end
            table.sort(arr, function(a, b) return a.copper > b.copper end)
            while #arr > (n or 5) do arr[#arr] = nil end
            return arr
        end,
    },
    Delay = function(_, fn) if fn then fn() end end, -- fire scheduled replies synchronously
    GetVersion = function() return "v2.58.0" end,
    compCache = {},
}
-- WoW API namespace stubs. Since the port, addon files bind
-- `local X = C_Namespace.X` at file scope, which throws outside the
-- game before any test body runs. See tests/wow_stub.lua.
dofile("tests/wow_stub.lua")

local chunk = assert(loadfile("WoWClearance_ServerShare.lua"))
chunk("WoWClearance", NS)
local ss = NS.ServerShare

local fails = 0
local function ok(name, cond)
    if cond then print("PASS  " .. name) else print("FAIL  " .. name); fails = fails + 1 end
end
local function eq(name, a, b) ok(name .. " (" .. tostring(a) .. ")", a == b) end

-- ---- codec round-trip ----
local p = ss.encodePayload(
    { cop = 999, sold = 12, del = 5, proc = 3 },
    { { name = "Barrens", copper = 200 } },
    { { id = 4306, name = "Silk Cloth", count = 7 } },
    "v2.58.0"
)
ok("payload has totals", p:find("t:", 1, true) ~= nil)
ok("payload has ver", p:find("ver:v2.58.0", 1, true) ~= nil)
ok("payload has zones", p:find("z:", 1, true) ~= nil)
ok("payload has items", p:find("i:", 1, true) ~= nil)
ok("payload under 255", #p < 255)
local d = ss.decodePayload(p)
eq("decode cop", d.cop, 999)
eq("decode sold", d.sold, 12)
eq("decode del", d.del, 5)
eq("decode proc", d.proc, 3)
eq("decode ver", d.ver, "v2.58.0")
eq("decode zone name", d.zones[1].name, "Barrens")
eq("decode zone copper", d.zones[1].copper, 200)
eq("decode item id", d.items[1].id, 4306)
eq("decode item name", d.items[1].name, "Silk Cloth")
eq("decode item count", d.items[1].count, 7)

-- ---- keyed aggregate via the SDAT handler ----
WoWClearanceDB = {
    totalCopper = 100, totalItemsSold = 10, totalItemsDeleted = 2,
    processCastCounts = { Disenchant = 3 }, soldItemCounts = { [4306] = 5 },
    copperByZone = { Barrens = 100 },
}
NS.compCache.serverPeers = nil
fakeNow = 5000
rhandlers.SDAT(ss.encodePayload({ cop = 1000, sold = 20, del = 4, proc = 1 },
    { { name = "Barrens", copper = 500 } }, { { id = 4306, name = "Silk Cloth", count = 8 } }, "v2.58.0"), "Alaric")
rhandlers.SDAT(ss.encodePayload({ cop = 2000, sold = 30, del = 6, proc = 2 },
    { { name = "Durotar", copper = 300 } }, {}, "v2.58.0"), "Brynn")
local agg = ss.GetAggregate()
eq("agg userCount", agg.userCount, 2)
eq("agg sum cop", agg.totalCopper, 3000)
eq("agg sum sold", agg.itemsSold, 50)
eq("agg sum del", agg.itemsDeleted, 10)
eq("agg sum proc", agg.itemsProcessed, 3)
eq("agg top zone name", agg.zones[1].name, "Barrens")
eq("agg top zone copper", agg.zones[1].copper, 500)
eq("agg top item count", agg.items[1].count, 8)

-- re-send from the SAME sender must NOT double-count (latest-wins keyed store)
rhandlers.SDAT(ss.encodePayload({ cop = 1000, sold = 20, del = 4, proc = 1 }, {}, {}, nil), "Alaric")
local agg2 = ss.GetAggregate()
eq("userCount after re-send (no dupe)", agg2.userCount, 2)
eq("sum cop after re-send (no dupe)", agg2.totalCopper, 3000)

-- spoof containment: an absurd contributor is dropped by the sanity cap
rhandlers.SDAT(ss.encodePayload({ cop = 9e14, sold = 0, del = 0, proc = 0 }, {}, {}, nil), "Spoofer")
eq("spoofed contributor rejected", ss.GetAggregate().userCount, 2)

-- ---- SREQ responder behaviour (privacy + anti-storm) ----
-- opt-in OFF: no reply
WoWClearanceDB.shareServerData = false
clearSent()
fakeNow = fakeNow + 100
rhandlers.SREQ("v2.58.0", "Other")
ok("no reply when opted out", #sent == 0)
-- opted out: Refresh neither joins nor sends
local joins = 0
NS.RealmComms.Join = function() joins = joins + 1 end
fakeNow = fakeNow + 1000
ss.RequestNow()
ok("Refresh while opted out sends nothing", #sent == 0 and joins == 0)
NS.RealmComms.Join = function() end
-- an absurd zone or item count is dropped like an absurd total
rhandlers.SDAT(ss.encodePayload({ cop = 1, sold = 1, del = 0, proc = 0 }, { { name = "The Barrens", copper = 5e12 } }, {}, nil), "ZoneSpoofer")
ok("absurd zone copper rejected", NS.compCache.serverPeers["ZoneSpoofer"] == nil)

-- opt-in ON: exactly one SDAT, sent channel-wide (no target field)
WoWClearanceDB.shareServerData = true
clearSent()
fakeNow = fakeNow + 100
rhandlers.SREQ("v2.58.0", "Other")
ok("one reply when opted in", #sent == 1)
ok("reply is SDAT", sent[1] and sent[1].t == "SDAT")
ok("reply is channel-wide (no whisper target)", sent[1] and sent[1].target == nil)

-- self-skip: no reply to our own request
clearSent()
fakeNow = fakeNow + 100
rhandlers.SREQ("v2.58.0", "Self Surname")
ok("no self-reply", #sent == 0)
-- a different player who shares our first name is a real peer
clearSent()
fakeNow = fakeNow + 100
rhandlers.SREQ("v2.58.0", "Self")
ok("first-name-only sender is not us", #sent == 1)

-- responder floor: a burst of requests yields at most one reply
clearSent()
fakeNow = fakeNow + 100
rhandlers.SREQ("v2.58.0", "Other")
rhandlers.SREQ("v2.58.0", "Other2") -- same instant, within REPLY_FLOOR
ok("responder floor bounds bursts to one reply", #sent == 1)

-- ---- version piggyback ----
for i = #noted, 1, -1 do noted[i] = nil end
fakeNow = fakeNow + 100
rhandlers.SREQ("v2.99.0", "PeerX")
local sreqVer = false
for _, e in ipairs(noted) do if e.v == "v2.99.0" then sreqVer = true end end
ok("SREQ version feeds NotePeerVersion", sreqVer)
for i = #noted, 1, -1 do noted[i] = nil end
rhandlers.SDAT(ss.encodePayload({ cop = 1, sold = 0, del = 0, proc = 0 }, {}, {}, "v3.00.0"), "PeerY")
local sdatVer = false
for _, e in ipairs(noted) do if e.v == "v3.00.0" then sdatVer = true end end
ok("SDAT version feeds NotePeerVersion", sdatVer)

-- ---- anonymity: sender never appears in the displayed aggregate ----
NS.compCache.serverPeers = nil
fakeNow = fakeNow + 100
rhandlers.SDAT(ss.encodePayload({ cop = 100, sold = 1, del = 0, proc = 0 },
    { { name = "Barrens", copper = 100 } }, {}, nil), "SecretSenderName")
local flat = {}
local function flatten(t)
    for k, v in pairs(t) do
        flat[#flat + 1] = tostring(k)
        if type(v) == "table" then flatten(v) else flat[#flat + 1] = tostring(v) end
    end
end
flatten(ss.GetAggregate())
ok("sender name not in displayed aggregate", table.concat(flat, "|"):find("SecretSenderName", 1, true) == nil)

-- ---- TTL: stale sharers drop out of the count ----
NS.compCache.serverPeers = nil
fakeNow = 20000
rhandlers.SDAT(ss.encodePayload({ cop = 100, sold = 0, del = 0, proc = 0 }, {}, {}, nil), "Fresh")
eq("stored while fresh", ss.GetAggregate().userCount, 1)
fakeNow = 20000 + 1300 -- past the 1200s TTL
eq("expired after TTL", ss.GetAggregate().userCount, 0)

-- ---- static-pattern invariants (scan live code, not comments) ----
local function readCode(path)
    local fh = assert(io.open(path, "r"))
    local s = fh:read("*a")
    fh:close()
    local out = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        local t = line:match("^%s*(.-)%s*$") or ""
        if t:sub(1, 2) ~= "--" then out[#out + 1] = line end
    end
    return table.concat(out, "\n")
end

local share = readCode("WoWClearance_ServerShare.lua")
ok("exposes NS.ServerShare", share:find("NS.ServerShare", 1, true) ~= nil)
ok("uses NS.RealmComms transport", share:find("NS.RealmComms", 1, true) ~= nil)
ok("registers SREQ", share:find('"SREQ"', 1, true) ~= nil)
ok("registers SDAT", share:find('"SDAT"', 1, true) ~= nil)
ok("reply gated on shareServerData", share:find("shareServerData", 1, true) ~= nil)
ok("exposes InjectTestPeers diagnostic", share:find("function ServerShare.InjectTestPeers", 1, true) ~= nil)
ok("per-contributor sanity cap present", share:find("COPPER_CAP", 1, true) ~= nil)
ok("no 4.0 group event", not share:find("GROUP_ROSTER_UPDATE", 1, true))
ok("share: no RegisterAddonMessagePrefix", not share:find("RegisterAddonMessagePrefix", 1, true))

local rc = readCode("WoWClearance_RealmComms.lua")
-- v0.6.0 rebuild: addon messages on a temporary custom channel. Chat TEXT
-- (SendChatMessage) on a channel needs a hardware event on Forever, so a
-- timer-driven send is blocked; addon messages on a custom channel are
-- measured to deliver. These pin the new transport and keep the old one out.
ok("RealmComms registers its addon-message prefix (mandatory on Forever)",
    rc:find("C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)", 1, true) ~= nil)
ok("RealmComms sends addon messages on the channel",
    rc:find('SendAddonMessage(PREFIX, sendQueue[1], "CHANNEL"', 1, true) ~= nil)
ok("RealmComms never posts chat text", not rc:find("SendChatMessage(", 1, true))
ok("RealmComms joins a TEMPORARY channel (permanent ones keep /N between sessions)",
    rc:find("JoinTemporaryChannel(CHANNEL_NAME)", 1, true) ~= nil and not rc:find("JoinChannelByName", 1, true))
ok("RealmComms waits while /1 is empty before joining", rc:find("GetChannelName(1) == 0", 1, true) ~= nil)
ok("RealmComms leaves the channel on opt-out", rc:find("LeaveChannelByName(CHANNEL_NAME)", 1, true) ~= nil
    and readCode("WoWClearance_ServerStatsPanel.lua"):find("NS.RealmComms.Leave()", 1, true) ~= nil)
do
    local sendFn = rc:match("function RealmComms%.Send%((.-)\nend\n") or ""
    ok("RealmComms.Send never joins on its own", #sendFn > 0 and not sendFn:find("Join", 1, true))
end
ok("RealmComms reads only CHANNEL messages it may access",
    rc:find('channel ~= "CHANNEL"', 1, true) ~= nil and rc:find("NS.CanRead(text, sender)", 1, true) ~= nil)
ok("RealmComms waits out chat lockdown", rc:find("C_ChatInfo.InChatMessagingLockdown()", 1, true) ~= nil)
ok("RealmComms has RunSelfTest", rc:find("function RealmComms.RunSelfTest", 1, true) ~= nil)
ok("RealmComms: no chunking", not rc:find("MAX_CHUNK", 1, true))

local panel = readCode("WoWClearance_ServerStatsPanel.lua")
ok("panel reads aggregate", panel:find("GetAggregate", 1, true) ~= nil)
ok("panel opt-in writes shareServerData", panel:find("shareServerData", 1, true) ~= nil)
ok("panel does not self-register", panel:find("RegisterOptionsSub", 1, true) == nil)

local events = readCode("WoWClearance_Events.lua")
ok("server panel is in the sidebar order (WC_PANEL_ORDER, Window.lua)",
    readCode("WoWClearance_Window.lua"):find('"WoWClearanceOptionsServer",', 1, true) ~= nil)
ok("Events seeds shareServerData default", events:find("WoWClearanceDB.shareServerData == nil", 1, true) ~= nil)

-- ---- realm sharing must stay OFF and silent until the player asks --------
--
-- Three checks, two of them ABSENCE-shaped, so they get a non-vacuity guard
-- first. Without it an unread or renamed source satisfies both negatives
-- perfectly, which is this project family's characteristic failure (see the
-- locale-coverage suite, which passed over an empty set for its whole life).
-- The guard asserts something that MUST be present in a correctly-read
-- Events.lua, so a failure to load shows up here rather than as two
-- reassuring greens below.
ok(
    "non-vacuity: Events source actually read (floor for the two negatives)",
    #events > 100000 and events:find("function WC_Delay", 1, true) ~= nil
)

-- The seed itself. Pinned to the literal `= false` rather than to "a seed
-- exists", because the v2.59.1 default-ON seed ALSO satisfied "a seed
-- exists" and is precisely what this is here to stop coming back.
ok(
    "shareServerData is seeded OFF, not ON",
    events:find("WoWClearanceDB.shareServerData = false", 1, true) ~= nil
        and events:find("WoWClearanceDB.shareServerData = true", 1, true) == nil
)

-- The migration marker is gone for good. It could never work on this client:
-- SavedVariables never read back, so the marker meant to make the default-ON
-- bump one-shot was itself erased every launch, re-firing the bump and
-- overriding the player's opt-out every time.
ok(
    "the default-ON migration marker is not reintroduced",
    events:find("shareServerDataDefaultBumped = true", 1, true) == nil
)

-- v0.6.0: a forced opt-in left by the old default-ON code (marked by the
-- old migration marker) is turned off once, and the marker removed.
do
    local i = events:find("if WoWClearanceDB.shareServerDataDefaultBumped ~= nil then", 1, true)
    local block = i and events:sub(i, i + 200) or ""
    ok(
        "a forced opt-in from the old default-ON code is turned off once",
        block:find("WoWClearanceDB.shareServerData = false", 1, true) ~= nil
            and block:find("WoWClearanceDB.shareServerDataDefaultBumped = nil", 1, true) ~= nil
    )
end

-- No login-time join or broadcast. Forever is a LIVE Blizzard realm, so an
-- automatic channel join on PLAYER_LOGIN is a decision taken on the player's
-- behalf. The panel toggle is the only path that may join.
ok(
    "Events never joins the realm channel or broadcasts on login",
    events:find("RealmComms.Join", 1, true) == nil
        and events:find("ServerShare.RequestNow", 1, true) == nil
)

-- v2.59.5: receiver-side city filter. Pre-v2.59.5 peers still send city
-- entries; decode must drop them so no city enters the realm aggregate.
-- Stub isCityZone with a minimal set (encode/decode roundtrip above ran
-- with the nil-safe guard = false, i.e. filter disabled, cleanly).
NS.compCache.isCityZone = function(name) return name == "Dalaran" or name == "Orgrimmar" end
local dCity = ss.decodePayload(ss.encodePayload(
    { cop = 10000, sold = 1, del = 0, proc = 0 },
    { { name = "Dalaran", copper = 5000 }, { name = "Icecrown", copper = 3000 }, { name = "Orgrimmar", copper = 2000 } },
    {},
    "v2.59.5"
))
eq("realm decode drops Dalaran", (function() for _, z in ipairs(dCity.zones) do if z.name == "Dalaran" then return "PRESENT" end end return "DROPPED" end)(), "DROPPED")
eq("realm decode drops Orgrimmar", (function() for _, z in ipairs(dCity.zones) do if z.name == "Orgrimmar" then return "PRESENT" end end return "DROPPED" end)(), "DROPPED")
eq("realm decode keeps Icecrown", (function() for _, z in ipairs(dCity.zones) do if z.name == "Icecrown" then return "PRESENT" end end return "DROPPED" end)(), "PRESENT")
ok("ServerShare decode has isCityZone guard on zones parse",
    share:find('prefix == "z"', 1, true) ~= nil
        and share:find("not isCityZone(name)", 1, true) ~= nil)

print()
if fails > 0 then io.stderr:write("RESULT: " .. fails .. " test(s) failed\n"); os.exit(1) end
print("RESULT: all tests passed")
os.exit(0)
