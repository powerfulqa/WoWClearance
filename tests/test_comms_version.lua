#!/usr/bin/env lua
-- Unit + static-pattern tests for WoWClearance comms / version logic.
-- Run from repo root:  lua tests/test_comms_version.lua
--
-- parseVersion is pure Lua, so unlike the other suites we LOAD the comms
-- chunk in isolation (stubbing only CreateFrame) and call it for real.

-- Minimal stub so WoWClearance_Comms.lua loads: any method on a frame is a no-op.
local function makeFrame()
    return setmetatable({}, { __index = function() return function() end end })
end
_G.CreateFrame = function() return makeFrame() end
-- The comms module also defines a StaticPopup dialog and replaces SetItemRef
-- at load time (for the clickable update link), so provide the table it indexes.
_G.StaticPopupDialogs = {}

-- Load with the addon vararg shape WoW uses: (addonName, NS).
-- NS.L mirrors WoWClearance_Locale.lua's passthrough (the real addon loads
-- the locale layer first), so file-scope L["..."] lookups resolve to English.
local NS = { L = setmetatable({}, { __index = function(_, k)
    return k
end }) }
-- WoW API namespace stubs. Since the port, addon files bind
-- `local X = C_Namespace.X` at file scope, which throws outside the
-- game before any test body runs. See tests/wow_stub.lua.
dofile("tests/wow_stub.lua")
-- Controllable transport: Comms binds SendAddonMessage at load, so swap it in
-- before the chunk runs. nextResult is what the "client" answers.
local sends, nextResult, lockdown, fakeNow = 0, 0, false, 1000
C_ChatInfo.SendAddonMessage = function()
    sends = sends + 1
    return nextResult
end
C_ChatInfo.InChatMessagingLockdown = function()
    return lockdown
end
_G.GetTime = function()
    return fakeNow
end

local chunk = assert(loadfile("WoWClearance_Comms.lua"))
chunk("WoWClearance", NS)

local fails = 0
local function eq(name, got, want)
    if got == want then
        print("PASS  " .. name)
    else
        print("FAIL  " .. name .. "  (got " .. tostring(got) .. ", want " .. tostring(want) .. ")")
        fails = fails + 1
    end
end
local function ok(name, cond)
    eq(name, cond and true or false, true)
end

local pv = NS.Comms.parseVersion
eq("v2.10.0 encodes", pv("v2.10.0"), 2 * 1000000 + 10 * 1000 + 0)
eq("v2.38.4 encodes", pv("v2.38.4"), 2 * 1000000 + 38 * 1000 + 4)
ok("v2.10.0 > v2.9.0 (lexical-bug guard)", pv("v2.10.0") > pv("v2.9.0"))
eq("no-v prefix still parses", pv("2.9.0"), 2 * 1000000 + 9 * 1000 + 0)
eq("malformed -> nil", pv("v99.banana"), nil)
eq("missing patch -> nil", pv("2.3"), nil)
eq("non-string -> nil", pv(nil), nil)
eq("component >= 1000 -> nil (cap)", pv("v1000.0.0"), nil)
-- The peer string is printed in the update notice: trailing text (colour
-- codes, a fake link) must reject the whole string, not ride along.
eq("trailing text -> nil", pv("v0.7.0 |cffff0000click here|r"), nil)
eq("trailing link -> nil", pv("0.7.0|Hitem:1|h[x]|h"), nil)

-- ---- Send: the throttle window starts only when a message went out ----
local send = NS.Comms.Send
lockdown = true
send("T1", "x", "GUILD")
eq("lockdown: nothing sent", sends, 0)
lockdown = false
nextResult = 3 -- AddonMessageThrottle
send("T1", "x", "GUILD")
send("T1", "x", "GUILD")
eq("refused send does not start the window (retried)", sends, 2)
nextResult = 0
send("T1", "x", "GUILD")
send("T1", "x", "GUILD")
eq("successful send starts the window", sends, 3)
fakeNow = fakeNow + 31
send("T1", "x", "GUILD")
eq("window expires after 30 s", sends, 4)

-- ---- static-pattern invariants (scan live code, not comments) ----
-- Whole-line comments are stripped first so an explanatory comment that
-- names a forbidden 4.0+ API (to document it is NOT used) doesn't trip the
-- absence checks below. Mirrors the whole-line-comment handling in
-- tests/test_no_addon_references.lua.
local function readCode(p)
    local fh = assert(io.open(p, "r"))
    local s = fh:read("*a")
    fh:close()
    local out = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        local stripped = line:match("^%s*(.-)%s*$") or ""
        if stripped:sub(1, 2) ~= "--" then
            out[#out + 1] = line
        end
    end
    return table.concat(out, "\n")
end

local comms = readCode("WoWClearance_Comms.lua")
ok("comms uses numeric version encoding", comms:find("1000000", 1, true) ~= nil)
-- INVERTED BY THE PORT. This asserted the ABSENCE of
-- RegisterAddonMessagePrefix, which was correct on 3.3.5a where filtering
-- CHAT_MSG_ADDON by prefix was the whole job. On Forever the client never
-- DELIVERS CHAT_MSG_ADDON for an unregistered prefix, so the absence this
-- test used to protect is now the bug: the transport would load cleanly and
-- never fire, with no error and no symptom.
ok("comms registers its addon message prefix", comms:find("RegisterAddonMessagePrefix", 1, true) ~= nil)
ok("prefix registration happens before the listener", (function()
    local reg = comms:find("RegisterAddonMessagePrefix", 1, true)
    local listen = comms:find('RegisterEvent("CHAT_MSG_ADDON")', 1, true)
    return reg ~= nil and listen ~= nil and reg < listen
end)())
ok("comms defines NS.Comms", comms:find("NS.Comms", 1, true) ~= nil)
ok("comms gates on versionAlerts", comms:find("versionAlerts", 1, true) ~= nil)
ok("comms exposes RunSelfTest", comms:find("function Comms.RunSelfTest", 1, true) ~= nil)

local events = readCode("WoWClearance_Events.lua")
-- ALSO INVERTED. The hub used to register PARTY_MEMBERS_CHANGED +
-- RAID_ROSTER_UPDATE and this asserted GROUP_ROSTER_UPDATE was NOT used.
-- On Forever, GROUP_ROSTER_UPDATE is the live event covering both cases and
-- PARTY_MEMBERS_CHANGED is REJECTED - and RegisterEvent THROWS on an unknown
-- name, with the uncaught throw aborting the rest of the chunk. So the old
-- assertion protected a line that would have killed every registration after
-- it in a 7,000-line file.
--
-- RAID_ROSTER_UPDATE is still accepted by this client, but is no longer
-- needed: one event now covers party and raid, and the channel is chosen
-- from the group state instead of from which event fired.
ok("hub registers GROUP_ROSTER_UPDATE", events:find("GROUP_ROSTER_UPDATE", 1, true) ~= nil)
ok("hub no longer registers the rejected PARTY_MEMBERS_CHANGED",
    not events:find('RegisterEvent("PARTY_MEMBERS_CHANGED")', 1, true))

-- Generalised from the one-off above, because PARTY_MEMBERS_CHANGED was NOT
-- the only instance. LEARNED_SPELL_IN_TAB was still registered bare at the
-- time that assertion was written and passing: a guard naming one member of
-- a class does not cover the class, and nobody swept for the others.
--
-- Every name here has been MEASURED rejected on WoW: Forever, not guessed.
-- LEARNED_SPELL_IN_TAB by the in-game event probe (build 1.60.1.69913); the
-- rest by the forever-addon-kit and sibling-port probes. Registering any of
-- them throws, and the uncaught throw aborts the rest of the chunk - so one
-- bad name silently discards every registration and every top-level
-- statement after it, with no error beyond the first.
--
-- Adding a name here is cheap. Do NOT remove one without a fresh in-game
-- measurement showing this client now accepts it: absence from this list
-- reads as "safe to register".
local REJECTED_EVENTS = {
    "PARTY_MEMBERS_CHANGED",
    "LEARNED_SPELL_IN_TAB",
    "UNIT_COMBO_POINTS",
    "RUNE_UPDATE",
}
for _, ev in ipairs(REJECTED_EVENTS) do
    ok(
        "hub does not register the measured-rejected " .. ev,
        not events:find('RegisterEvent("' .. ev .. '")', 1, true)
    )
end

-- Non-vacuity. Every check above is negative, so an empty or unreadable
-- source would satisfy all of them and report green. Pin that the hub was
-- actually read and that a known-good event IS registered in the expected
-- form, or the block above establishes nothing.
ok("event source was actually read (the guards above are not vacuous)", #events > 10000)
ok("hub registers the accepted SPELLS_CHANGED",
    events:find('RegisterEvent("SPELLS_CHANGED")', 1, true) ~= nil)

print()
if fails > 0 then
    io.stderr:write("RESULT: " .. fails .. " test(s) failed\n")
    os.exit(1)
end
print("RESULT: all tests passed")
os.exit(0)
