#!/usr/bin/env lua
-- API-surface invariants (port work item 3).
--
-- Run from repo root:    lua5.1 tests/test_api_surface.lua
--
-- The problem this guards against: luacheck's `read_globals` vouches for a
-- global's EXISTENCE and nothing about its members. Declared as a bare name,
--
--     read_globals = { "C_Item" }
--
-- the call `C_Item.GetItemCooldownDuration(123)` - a member that does not
-- exist on WoW: Forever - lints clean, ships, and returns nil at runtime.
-- That is the class of bug that cost this addon its gear-set rescue cache,
-- via C_EquipmentSet.GetEquipmentSetItemIDs: the NAMESPACE is present on
-- this client and so are its other two members, but that one is not.
--
-- Declared with `fields`, luacheck reports "accessing undefined field" and
-- the existing CI lint gate catches it for free - no vendored member list,
-- no generator, no second tool.
--
-- This suite pins that the declarations keep their teeth. It loads the real
-- .luacheckrc as Lua (it is a Lua chunk) and inspects the resulting table,
-- rather than regex-matching the source, so a reformat cannot fool it.
--
-- Version-agnostic loader: 5.1 uses loadstring+setfenv, 5.2+ uses load with
-- an _ENV argument. Same approach as tests/test_dbproxy.lua.
--
-- DO NOT RETIRE THIS SUITE AS REDUNDANT. Measured 2026-09-19: it is the
-- ONLY remaining check for the moved-global class on Forever. Both of the
-- tools that look like they cover it do not:
--
--   * luacheck saw none of it while the old 3.3.5a names were declared
--     in read_globals. The moved names were removed from .luacheckrc once
--     the migration finished, so a bare GetItemInfo(...) now warns; this
--     suite stays as the check that does not depend on that config.
--   * wow_lua_lint cannot see it either. Its unknown-function check is
--     OFF for this client - it says so in its own output, because upstream
--     publishes no global function list for Forever - and its
--     known-removed-API check was measured against eight bare 3.3.5a
--     globals that HAVE been namespaced here (GetContainerNumSlots,
--     GetContainerItemInfo, GetItemInfo, GetAddOnMetadata, IsAddOnLoaded,
--     GetSpellInfo, SendAddonMessage, RegisterAddonMessagePrefix).
--     Result: 0 errors, 0 warnings. Not one was flagged.
--
-- So a green luacheck run plus a green wow_lua_lint run says nothing at
-- all about whether the namespacing migration is finished. This suite is
-- the thing that says it. See docs/PORT_STATUS.md.

local fails = 0
local function check(name, ok, msg)
    if ok then
        print("PASS  " .. name)
    else
        print("FAIL  " .. name)
        if msg then
            print("      " .. msg)
        end
        fails = fails + 1
    end
end

local fh = assert(io.open(".luacheckrc", "r"), "cannot open .luacheckrc")
local src = fh:read("*a")
fh:close()

-- Evaluate .luacheckrc in a sandbox and recover its assignments.
local env = {}
local chunk, err
if setfenv then
    chunk, err = loadstring(src, "luacheckrc")
    if chunk then
        setfenv(chunk, env)
    end
else
    chunk, err = load(src, "luacheckrc", "t", env)
end
assert(chunk, "could not parse .luacheckrc: " .. tostring(err))
local ok, runErr = pcall(chunk)
assert(ok, "could not evaluate .luacheckrc: " .. tostring(runErr))

local rg = env.read_globals
check("read_globals table recovered from .luacheckrc", type(rg) == "table",
    "expected .luacheckrc to assign a read_globals table")

-- Namespaces that MUST carry an explicit member list. A bare entry here is
-- the silent-failure shape this whole suite exists to prevent.
local MUST_HAVE_FIELDS = {
    "C_Container", "C_Item", "C_Spell", "C_SpellBook", "C_AddOns",
    "C_ChatInfo", "C_CurrencyInfo", "C_TooltipInfo", "C_EquipmentSet",
    "C_Timer", "Settings", "ChatFrameUtil",
    "C_TransmogCollection",
}
-- v0.5.7: look in BOTH tables. A namespace whose member the addon WRITES
-- has to live in `globals` rather than `read_globals` - a read_globals
-- fields list wins over a writable declaration of the same name, so
-- declaring it in both leaves the write flagged read-only. ChatFrameUtil is
-- that case (InsertLink is replaced to capture shift-clicked links).
--
-- The invariant this test protects is UNCHANGED: never a bare name, always
-- an explicit member list, so luacheck cannot vouch for a member this
-- client lacks. Which table carries it is a luacheck mechanic, not a
-- weakening of the rule.
-- Dropdowns: UIDropDownMenu_* is a measured action-bar taint source on
-- Forever and an addon-opened Menu / MenuUtil menu crashed the client. Keeping
-- them undeclared makes the luacheck gate reject any reintroduction.
do
    local banned = {}
    for _, name in ipairs(rg) do
        if type(name) == "string" and (name:find("^UIDropDownMenu") or name == "CloseDropDownMenus") then
            banned[#banned + 1] = name
        end
    end
    for name in pairs(rg) do
        if name == "MenuUtil" or name == "Menu" then
            banned[#banned + 1] = name
        end
    end
    check("no dropdown / Menu API declared (use NS.MakeSelector)", #banned == 0,
        "declared: " .. table.concat(banned, ", "))
end

local gl = env.globals
for _, ns in ipairs(MUST_HAVE_FIELDS) do
    local entry = (type(rg) == "table" and rg[ns]) or (type(gl) == "table" and gl[ns]) or nil
    check(ns .. " declared with an explicit member list",
        type(entry) == "table" and type(entry.fields) == "table" and #entry.fields > 0,
        ns .. " must be declared as { fields = { ... } }, not as a bare name. A bare "
            .. "name lets luacheck pass any member access, including ones this client "
            .. "does not have.")
end

-- Members MEASURED absent on WoW: Forever. Each one is a live bug waiting to
-- happen, so none may appear in its namespace's field list.
local MUST_NOT_LIST = {
    { ns = "C_EquipmentSet", member = "GetEquipmentSetItemIDs",
      why = "absent on this client though the namespace and its other two members exist; "
         .. "this is the member the gear-set rescue cache was built on" },
    { ns = "C_Item", member = "GetItemCooldownDuration",
      why = "does not exist; C_Item.GetItemCooldown is the real one, and there is no "
         .. "item-shaped duration-object call" },
}
for _, bad in ipairs(MUST_NOT_LIST) do
    local entry = type(rg) == "table" and rg[bad.ns] or nil
    local listed = false
    if type(entry) == "table" and type(entry.fields) == "table" then
        for _, f in ipairs(entry.fields) do
            if f == bad.member then
                listed = true
            end
        end
    end
    check(bad.ns .. " does NOT declare " .. bad.member, not listed,
        bad.ns .. "." .. bad.member .. " " .. bad.why .. ". Declaring it re-opens the hole.")
end

-- The guard must not be vacuous: prove the field lists are actually narrower
-- than "anything", by confirming a member we DO use is present while the
-- known-absent sibling is not.
do
    local eq = type(rg) == "table" and rg.C_EquipmentSet or nil
    local hasReal = false
    if type(eq) == "table" and type(eq.fields) == "table" then
        for _, f in ipairs(eq.fields) do
            if f == "GetEquipmentSetInfo" then
                hasReal = true
            end
        end
    end
    check("C_EquipmentSet still declares the members that DO exist", hasReal,
        "the guard is only meaningful if the list is accurate in both directions - "
            .. "omitting real members would push call sites into false lint failures "
            .. "and invite someone to drop the fields table entirely.")
end

-- ---------------------------------------------------------------------------
-- Moved-global bindings (port work item 4 / 6).
-- ---------------------------------------------------------------------------
-- Each of these 3.3.5a globals is ABSENT on WoW: Forever and lives in a C_
-- namespace now. A file that calls one bare gets nil at runtime, and because
-- the calls sit on the vendor and delete paths the failure is quiet and
-- expensive rather than loud.
--
-- luacheck now warns on a bare call too (the old names are no longer
-- declared in .luacheckrc), but only while nobody re-adds one there. This
-- check notices either way.
--
-- A call site passes if EITHER it is namespaced at the point of use
-- (`C_Container.GetContainerItemInfo(...)`) OR the file binds the name from
-- its namespace at file scope (`local GetItemInfo = C_Item.GetItemInfo`),
-- which is this codebase's cached-upvalue convention for hot paths.
do
    local MOVED = {
        { "GetContainerItemInfo", "C_Container" }, { "GetContainerNumSlots", "C_Container" },
        { "GetContainerItemLink", "C_Container" }, { "GetContainerItemID", "C_Container" },
        { "GetContainerNumFreeSlots", "C_Container" }, { "UseContainerItem", "C_Container" },
        { "PickupContainerItem", "C_Container" }, { "GetItemInfo", "C_Item" },
        { "GetSpellInfo", "C_Spell" }, { "IsSpellKnown", "C_SpellBook" },
        { "SendAddonMessage", "C_ChatInfo" }, { "SendChatMessage", "C_ChatInfo" },
        { "GetCoinTextureString", "C_CurrencyInfo" }, { "GetAddOnMetadata", "C_AddOns" },
        { "GetAddOnInfo", "C_AddOns" }, { "IsAddOnLoaded", "C_AddOns" },
        { "GetNumAddOns", "C_AddOns" },
        { "GetNumEquipmentSets", "C_EquipmentSet" },
        { "GetEquipmentSetInfo", "C_EquipmentSet" },
    }
    -- Removed outright with no drop-in replacement, so any reappearance is a
    -- porting mistake rather than a rename:
    --   * GetNumPartyMembers / GetNumRaidMembers - GetNumGroupMembers plus
    --     IsInRaid / IsInGroup carry different semantics (the old pair
    --     excluded the player from the count).
    --   * GetEquipmentSetItemIDs - measured absent in BOTH spellings: the
    --     bare global is nil and C_EquipmentSet has no such member. The
    --     replacement is GetEquipmentSetIDs + GetItemIDs, which is a
    --     different call shape, not a rename. This is the member the
    --     gear-set rescue cache was originally built on.
    local GONE = { "GetNumPartyMembers", "GetNumRaidMembers", "GetEquipmentSetItemIDs" }

    local tocFh = assert(io.open("WoWClearance.toc", "r"), "cannot open WoWClearance.toc")
    local files = {}
    for line in tocFh:lines() do
        local f = line:match("^(WoWClearance_[%w_]+%.lua)%s*$")
        if f and not f:find("Locale_") then
            files[#files + 1] = f
        end
    end
    tocFh:close()
    check("toc yielded a source list to scan", #files > 10,
        "expected the .toc to list the shipped .lua files; got " .. #files)

    local unbound, resurrected = {}, {}
    for _, f in ipairs(files) do
        local fh = io.open(f, "r")
        if fh then
            local raw = fh:read("*a")
            fh:close()
            -- Strip comment lines so a WC-TRAP naming an API cannot false-positive.
            local code = {}
            for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
                if not line:match("^%s*%-%-") then
                    code[#code + 1] = line
                end
            end
            code = table.concat(code, "\n")
            for _, pair in ipairs(MOVED) do
                local fn, ns = pair[1], pair[2]
                -- A bare call: name followed by "(" and not preceded by a dot
                -- (which would make it namespaced) or a word character.
                local bare = code:find("[^%.%w]" .. fn .. "%(") or code:find("^" .. fn .. "%(")
                if bare then
                    local bound = code:find("\nlocal " .. fn .. " = " .. ns .. "%." .. fn)
                        or code:find("^local " .. fn .. " = " .. ns .. "%." .. fn)
                    if not bound then
                        unbound[#unbound + 1] = f .. ":" .. fn
                    end
                end
            end
            for _, fn in ipairs(GONE) do
                if code:find("[^%.%w]" .. fn .. "%(") then
                    resurrected[#resurrected + 1] = f .. ":" .. fn
                end
            end
        end
    end
    check("every moved 3.3.5a global is namespaced or bound from its C_ namespace",
        #unbound == 0,
        "these call a moved global bare, with no `local <name> = C_<ns>.<name>` binding in the "
            .. "file - it resolves to nil on Forever and fails quietly: "
            .. table.concat(unbound, ", "))
    check("no call site resurrects a removed group-count global",
        #resurrected == 0,
        "GetNumPartyMembers / GetNumRaidMembers are gone; GetNumGroupMembers + IsInRaid / "
            .. "IsInGroup replace them and count the player differently: "
            .. table.concat(resurrected, ", "))
end

print()

-- ---------------------------------------------------------------------------
-- v0.5.8: player-facing prose must not hardcode a client-relative threshold.
-- ---------------------------------------------------------------------------
-- Suggested by the BarWarden-Forever port after all three ports found the
-- same species of defect on the same day: prose asserting a fact about the
-- client that had expired, each caught by a screenshot rather than a test.
--
-- Ours was "Protect iLvl 200+ items from auto-mark" sitting beside a gate
-- that had moved to 80. The LABEL now formats from the constant, so those
-- two cannot drift - this check stops a NEW hardcoded one appearing, in the
-- prose where generating from the constant is not natural.
--
-- Scoped deliberately: only strings that already talk about item level, and
-- only a standalone number. A blanket "no digits in prose" would fire on
-- every colour code (|cffffd200 contains 200) and be turned off within a
-- week.
do
    local threshold
    do
        local fh = io.open("WoWClearance_Events.lua", "r")
        if fh then
            local src = fh:read("*a")
            fh:close()
            threshold = src:match("local WC_AUTOMARK_PROTECT_ILVL = (%d+)")
        end
    end
    check("the iLvl gate constant is still findable", threshold ~= nil,
        "this check reads WC_AUTOMARK_PROTECT_ILVL out of WoWClearance_Events.lua. "
            .. "If it was renamed or moved, update the pattern here rather than deleting "
            .. "the check - a silently unfindable constant makes every assertion below vacuous.")

    local offenders, scanned = {}, 0
    if threshold then
        local tocFh = io.open("WoWClearance.toc", "r")
        if tocFh then
            for line in tocFh:lines() do
                local f = line:match("^(WoWClearance[%w_]*%.lua)%s*$")
                if f and not f:match("Locale") then
                    local sf = io.open(f, "r")
                    if sf then
                        local src = sf:read("*a")
                        sf:close()
                        for lit in src:gmatch('L%["([^"]*)"%]') do
                            scanned = scanned + 1
                            local mentionsILvl = lit:lower():find("ilvl") or lit:lower():find("item level")
                            if mentionsILvl and lit:find("%f[%d]" .. threshold .. "%f[%D]") then
                                offenders[#offenders + 1] = f .. ": " .. lit:sub(1, 60)
                            end
                        end
                    end
                end
            end
            tocFh:close()
        end
    end

    -- Non-vacuity floor, per the rule this repo learned the hard way: an
    -- empty input set satisfies every "nothing is missing" assertion.
    check("prose scan actually read some player-facing strings", scanned > 200,
        "only " .. tostring(scanned) .. " L[] literals found. The check below passes "
            .. "trivially over an empty set, so a low count means the extractor broke, "
            .. "not that the addon is clean.")

    check("no player-facing string hardcodes the iLvl gate value",
        #offenders == 0,
        "these strings mention item level AND embed " .. tostring(threshold) .. " literally, "
            .. "so they will state the wrong number the moment the gate moves: "
            .. table.concat(offenders, " | ")
            .. ". Format from NS.AUTOMARK_PROTECT_ILVL instead, as the Keep Settings label does.")
end


if fails > 0 then
    io.stderr:write("RESULT: " .. fails .. " test(s) failed\n")
    os.exit(1)
end
print("RESULT: all tests passed")
os.exit(0)