-- WoWClearance_LootHistory.lua
-- Persisted per-pickup loot history: what was looted, when, and by whom.
--
-- The Loot Log's Session / Character / Account views are AGGREGATES (one
-- count per itemID). This file adds the event log behind the fourth view,
-- "History": one entry per pickup, newest first, kept account-wide so every
-- character's loot shows in one place.
--
-- Two sources feed it:
--   * Your own loot: WC_BumpLoot in the event hub calls LootHistory.Add with
--     the bag-delta count, so auto-loot, pet loot and AOE loot all land here
--     exactly as they land in the aggregate views.
--   * Group members: CHAT_MSG_LOOT lines naming someone else. Parsed with
--     patterns built from the client's own LOOT_ITEM* format strings, so it
--     works in every client language. Lines about YOU are skipped on
--     purpose - the bag-delta path already counted them, and counting both
--     would double every own pickup.
--
-- Storage (v2): ADB.lootHistory = { v = 2, writes = N, e = {...}, names = {...} }.
-- Each entry is ONE packed string "time:itemID:qty:nameIndex", and looter
-- names are stored once in `names`. A table per entry cost ~90 bytes each
-- in the saved file; the packed form is about half that, and 20000 of them
-- are parsed at login and written at logout.
--
-- The ring follows the Sold History discipline: the write slot is
-- ((writes - 1) % MAX) + 1, so at the cap the oldest entry is overwritten
-- in place, never table.remove'd. In memory the strings are decoded ONCE
-- into parallel number arrays, so reading 20000 entries allocates nothing.
-- Readers ask for slots newest first (SlotAt) and never rely on array order.
--
-- `names` only grows (distinct looters seen); Clear resets it.
--
-- Only worth having because SavedVariables read-back works on this client
-- from build 70170 on (see the hard release gate in docs/PORT_STATUS.md).
-- On a build where it does not, this log silently restarts every launch.
local NS = select(2, ...)

local LootHistory = {}
NS.LootHistory = LootHistory

LootHistory.MAX = 20000

-- Decoded in-memory mirror of the saved ring (index = ring slot).
local T, I, N, W = {}, {}, {}, {}
local nameIndex = {} -- name -> index into h.names
local loadedFrom -- the saved table the mirror was built from

local function decode(h)
    wipe(T)
    wipe(I)
    wipe(N)
    wipe(W)
    wipe(nameIndex)
    for i, name in ipairs(h.names) do
        nameIndex[name] = i
    end
    for slot, packed in pairs(h.e) do
        -- Saved data is untrusted: a non-string entry is skipped, not fatal.
        local t, id, n, w
        if type(packed) == "string" then
            t, id, n, w = packed:match("^(%d+):(%d+):(%d+):(%d+)$")
        end
        if t then
            T[slot], I[slot], N[slot], W[slot] = tonumber(t), tonumber(id), tonumber(n), tonumber(w)
        end
    end
    loadedFrom = h
end

local function store()
    local ADB = NS.ADB
    if not ADB then
        return nil
    end
    local h = ADB.lootHistory
    -- A damaged write cursor would make every later Append throw; restart
    -- the cursor rather than lose the entries.
    if type(h) == "table" and h.v == 2 and type(h.writes) ~= "number" then
        h.writes = 0
    end
    if type(h) ~= "table" or h.v ~= 2 or type(h.e) ~= "table" or type(h.names) ~= "table" then
        -- New, or the first-cut v1 shape ({entries = {{t,id,n,who}}, writes}).
        -- Re-append v1 entries oldest first so their order survives.
        local old = type(h) == "table" and h or nil
        h = { v = 2, writes = 0, e = {}, names = {} }
        ADB.lootHistory = h
        loadedFrom = nil
        if old and type(old.entries) == "table" and (old.writes or 0) > 0 then
            local count = math.min(old.writes, LootHistory.MAX)
            for k = count - 1, 0, -1 do
                local e = old.entries[((old.writes - 1 - k) % LootHistory.MAX) + 1]
                if type(e) == "table" and e.t and e.id and e.n then
                    LootHistory.Append(h, e.t, e.id, e.n, e.who or "?")
                end
            end
        end
    end
    if loadedFrom ~= h then
        decode(h)
    end
    return h
end

local function ownRealm()
    local realm = GetRealmName and GetRealmName() or ""
    -- Chat names carry the realm with spaces and hyphens stripped.
    return (realm:gsub("[%s%-]", ""))
end

-- "First Surname-Realm" for the player, so own and group entries share one
-- format (chat names carry the surname; UnitName alone drops it).
function LootHistory.PlayerFullName()
    return (GetUnitName("player", true) or "?") .. "-" .. ownRealm()
end

-- Low-level append into a v2 table; keeps the decoded mirror in step when
-- it is the live one.
function LootHistory.Append(h, t, itemID, qty, who)
    local w = nameIndex[who]
    if not w or h.names[w] ~= who then
        h.names[#h.names + 1] = who
        w = #h.names
        nameIndex[who] = w
    end
    h.writes = h.writes + 1
    local slot = ((h.writes - 1) % LootHistory.MAX) + 1
    h.e[slot] = string.format("%d:%d:%d:%d", t, itemID, qty, w)
    T[slot], I[slot], N[slot], W[slot] = t, itemID, qty, w
end

-- Append one pickup. `who` is "Name-Realm"; a bare "Name" is assumed to be
-- on the player's realm (that is how the client prints same-realm names).
function LootHistory.Add(itemID, qty, who)
    itemID = tonumber(itemID)
    qty = tonumber(qty) or 1
    if not itemID or qty <= 0 then
        return
    end
    local h = store()
    if not h then
        return
    end
    who = who or LootHistory.PlayerFullName()
    if not who:find("-", 1, true) then
        who = who .. "-" .. ownRealm()
    end
    LootHistory.Append(h, time(), itemID, qty, who)
    if NS.compCache then
        NS.compCache.lootWindowDirty = true
    end
end

-- Number of stored entries.
function LootHistory.Count()
    local h = store()
    return h and math.min(h.writes, LootHistory.MAX) or 0
end

-- Ring slot of the k-th newest entry (k = 1 is the newest).
function LootHistory.SlotAt(k)
    local h = store()
    return h and ((h.writes - k) % LootHistory.MAX) + 1
end

-- time, itemID, qty, looter name for a slot. Allocates nothing.
function LootHistory.Get(slot)
    local h = loadedFrom
    if not h or not I[slot] then
        return nil
    end
    return T[slot], I[slot], N[slot], h.names[W[slot]] or "?"
end

function LootHistory.Clear()
    local h = store()
    if h then
        wipe(h.e)
        wipe(h.names)
        h.writes = 0
        decode(h)
    end
end

-- ---- group loot from chat ------------------------------------------------

-- Turn a client format string such as "%s receives loot: %sx%d." into a
-- Lua pattern with one capture per placeholder. Positional forms ("%1$s")
-- used by some languages are flattened first; the parser below does not
-- depend on capture order, only on capture shape.
function LootHistory.FormatToPattern(fmt)
    local p = fmt:gsub("%%%d+%$", "%%")
    p = p:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
    return "^" .. p .. "$"
end

-- MULTIPLE forms first: the single form's trailing "(.+)" would also match a
-- "...x2." line and read the count as part of the item.
local LOOT_FORMAT_NAMES = {
    "LOOT_ITEM_MULTIPLE",
    "LOOT_ITEM_PUSHED_MULTIPLE",
    "LOOT_ITEM_BONUS_ROLL_MULTIPLE",
    "LOOT_ITEM",
    "LOOT_ITEM_PUSHED",
    "LOOT_ITEM_BONUS_ROLL",
}

local patterns
local function getPatterns()
    if not patterns then
        patterns = {}
        for _, name in ipairs(LOOT_FORMAT_NAMES) do
            -- Only LOOT_ITEM and LOOT_ITEM_MULTIPLE are confirmed in shipped
            -- source on this client; a missing string just drops its form.
            local fmt = _G[name]
            if type(fmt) == "string" then
                patterns[#patterns + 1] = LootHistory.FormatToPattern(fmt)
            end
        end
    end
    return patterns
end

-- Parse a loot line about SOMEONE ELSE. Returns looter, itemID, qty, or nil
-- when the line is not one of the "<name> receives ..." forms (which also
-- rejects every "You receive ..." line, since those use other strings).
function LootHistory.ParseGroupLoot(text, pats)
    if type(text) ~= "string" then
        return nil
    end
    for _, pat in ipairs(pats or getPatterns()) do
        local caps = { text:match(pat) }
        if caps[1] then
            local who, itemID, qty
            for _, c in ipairs(caps) do
                local id = c:match("|Hitem:(%d+)")
                if id then
                    itemID = tonumber(id)
                elseif c:match("^%d+$") then
                    qty = tonumber(c)
                else
                    who = c
                end
            end
            if who and itemID then
                return who, itemID, qty or 1
            end
        end
    end
    return nil
end

-- CHAT_MSG_LOOT handler. Registered on the event hub's frame in
-- WoWClearance_Events.lua (one event frame per addon), which calls this.
function LootHistory.OnChatMsgLoot(text, sender)
    -- Chat payloads can be secret on this client; Blizzard's own chat
    -- filters check canaccessvalue before reading them, and so do we.
    if not NS.CanRead(text, sender) then
        return
    end
    local who, itemID, qty = LootHistory.ParseGroupLoot(text)
    if not who then
        return
    end
    -- Belt and braces: never log a line naming the player, whatever form it
    -- took. Own loot comes from the bag-delta path.
    if Ambiguate(who, "none") == GetUnitName("player", true) then
        return
    end
    LootHistory.Add(itemID, qty, who)
end
