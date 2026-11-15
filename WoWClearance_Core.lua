-- WoWClearance_Core - provenance, fingerprint, and shared junk-drawer state.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/WoWClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Owns the chunks that have no dependencies on anything else in the addon:
--
--   * Provenance globals (WOWCLEARANCE_* and __WoWClearance_* writes
--     required by LICENSE §2(d)).
--   * The WC_Fingerprint salted djb2 helper. Exposed as NS.Fingerprint.
--   * The WC_compCache junk-drawer table. Exposed as NS.compCache.
--
-- ADDON_VERSION, WC_GetVersion, the watermark write, and the API cached
-- upvalues live in WoWClearance_Events.lua.
--
-- This file loads FIRST per the .toc, so anything it puts on NS is reachable
-- to every other split file's main chunk at load.

local NS = select(2, ...)

-- Provenance. Mirrored into globals so the origin/author are visible to any
-- /run introspection, addon-management tool, or crash trace. LICENSE section
-- 2(d) requires these globals to be preserved in any derivative. The
-- double-underscore-prefix-with-addon-name form follows a convention shared
-- elsewhere in the 3.3.5a addon ecosystem; see NOTICE.md for the prior-art
-- acknowledgement. WOWCLEARANCE_IDENT is set inline (no local) because the
-- display-name string only appears in this one assignment; ADDON_AUTHOR and
-- ADDON_URL stay as locals because the settings byline in
-- WoWClearance_Events.lua reads them via NS.ADDON_AUTHOR / NS.ADDON_URL.
local ADDON_AUTHOR = "Serv"
local ADDON_URL = "https://github.com/powerfulqa/WoWClearance"
_G["WOWCLEARANCE_IDENT"] = "WoWClearance"
_G["WOWCLEARANCE_AUTHOR"] = ADDON_AUTHOR
_G["WOWCLEARANCE_ORIGIN"] = ADDON_URL
_G["__WoWClearance_origin"] = ADDON_URL
_G["__WoWClearance_author"] = ADDON_AUTHOR
NS.ADDON_AUTHOR = ADDON_AUTHOR
NS.ADDON_URL = ADDON_URL

-- Salted, deterministic 24-bit hash. Not cryptographic; the goal is trivial
-- verifiability of WoWClearance origin in any derivative work. The salt
-- below is a deliberately visible signature: anyone with our source has it,
-- but to use our fingerprint format they must either (a) carry the salt
-- verbatim - which is the evidence - or (b) re-implement and diverge from
-- the canonical export format, also detectable. Do NOT "clean up" or
-- refactor the salt string away; its presence in code is the point. See
-- docs/ADDON_GUIDE.md "Fingerprint and watermark" for the full convention.
-- The salt lives inside the function body (not at module scope) only so it
-- doesn't consume a main-chunk local slot - Lua 5.1 caps that at 200.
local function WC_Fingerprint(payload)
    local SALT = "WoWClearance|Serv|powerfulqa|2026"
    local s = (payload or "") .. "|" .. SALT
    local h = 5381
    for i = 1, #s do
        -- djb2 step, folded to 24 bits so the printed form fits in 6 hex chars.
        h = ((h * 33) + string.byte(s, i)) % 16777216
    end
    return string.format("%06x", h)
end
NS.Fingerprint = WC_Fingerprint

-- Set-membership helper. Single canonical definition for the addon; the
-- consuming files (Vendor, Process, Tooltip, BagContextMenu, BagDisplay,
-- Events) bind it as `local IsInSet = NS.IsInSet` at file head so the
-- per-call cost is one local read, identical to the previous file-local
-- function pattern. Centralising the definition fixes the Stage 7
-- regression where one of the split files silently dropped its local
-- copy: `tests/test_perf_guardrails.lua` Test 65 still enforces the
-- per-file invariant via the `local IsInSet = ...` import line.
--
-- Strict semantics: only `true` or `1` count as membership. The pre-
-- unification BagDisplay and Vendor copies used a more permissive
-- `~= nil` check, but DB / ADB only ever stores `true` (verified by
-- audit), so the strict version is a no-op semantic narrowing on
-- current data and a safety improvement against hand-edited
-- SavedVariables.
function NS.IsInSet(setTable, itemID)
    if not itemID or not setTable then
        return false
    end
    local v = setTable[itemID]
    return (v == true) or (v == 1)
end

-- Search box matcher shared by the Loot Log and Sold History windows.
-- Returns nil for an empty search, else match(...) that is true when any
-- string argument matches any term. Terms are split on "||" (either one).
-- A term in double quotes must equal the whole string ("Linen Cloth" skips
-- "Bolt of Linen Cloth"); any other term matches anywhere. Case does not
-- matter, and an item link is matched by the name inside its brackets.
function NS.SearchMatcher(text)
    if type(text) ~= "string" then
        return nil
    end
    local terms = {}
    for raw in (text .. "||"):gmatch("(.-)||") do
        local t = raw:lower():match("^%s*(.-)%s*$")
        local exact = t:match('^"(.*)"$')
        if exact then
            terms[#terms + 1] = { exact, true }
        elseif t ~= "" then
            terms[#terms + 1] = { t, false }
        end
    end
    if #terms == 0 then
        return nil
    end
    return function(...)
        for i = 1, select("#", ...) do
            local s = select(i, ...)
            if type(s) == "string" then
                s = (s:match("|h%[(.-)%]|h") or s):lower()
                for _, term in ipairs(terms) do
                    if term[2] then
                        if s == term[1] then
                            return true
                        end
                    elseif s:find(term[1], 1, true) then
                        return true
                    end
                end
            end
        end
        return false
    end
end

-- True when every non-nil argument is readable (shared kit; canaccessvalue
-- takes ONE value, so chat handlers pass payload and sender through here).
NS.CanRead = NS.Kit.CanRead

-- Shared cross-file cache table. Colocated on a single table to keep the
-- main-chunk local count down (Lua 5.1 caps that at 200; see
-- docs/ADDON_GUIDE.md).
local WC_compCache = {
    -- Loot-generating profession spells. UNIT_SPELLCAST_SUCCEEDED matches
    -- against this set to drive the Process Bags lifetime cast counters.
    PROF_LOOT_SPELLS = {
        ["Disenchant"] = true,
        ["Milling"] = true,
        ["Prospecting"] = true,
        ["Pick Lock"] = true,
        ["Opening"] = true, -- lockpick + engineering container open
    },
    -- v2.10.0 bind-type cache. Drives the per-rarity bindFilter rule
    -- ("any" / "boe" / "bop") in WC_IsSellable. Holds the item's bind TYPE
    -- only (Enum.ItemBind via GetItemInfo), which is fixed per itemID.
    -- Whether a given COPY is bound is read live in getBindType and never
    -- stored here. Populated lazily by WC_compCache.itemBindType. Entries
    -- are never invalidated;
    -- the cache resets naturally on /reload because it lives in this
    -- module-local table and isn't persisted.
    bindCache = {},
    -- v2.44.0: Resilience-detection cache. PvP gear on most servers
    -- has Resilience as a stat line and `sellPrice = 0` (unsellable
    -- at vendors). Murlocked asked for an option to auto-mark such
    -- items for deletion. Like the bind cache, the property
    -- is stable per itemID (an item either has the stat or doesn't),
    -- so we cache lazily and never need to invalidate. Filled by
    -- WC_compCache.itemHasResilience.
    resilienceCache = {},
    -- Tome caches. Two tables because the two properties decay at
    -- different rates:
    --   * tomeCache - is-a-tome boolean. Stable per itemID (an item
    --     that teaches a spell ALWAYS teaches that spell), so the
    --     entry never needs invalidation. Filled lazily by
    --     WC_compCache.itemIsTome.
    --   * tomeIsKnownCache - has-player-learned-the-spell boolean.
    --     Character-state-sensitive: flips false -> true the moment
    --     the player right-clicks a recipe or trains a spell. The
    --     LEARNED_SPELL_IN_TAB / SPELLS_CHANGED handler wipes this
    --     table so the next lookup re-scans the tooltip for the
    --     "Already known" line (ITEM_SPELL_KNOWN). Filled lazily by
    --     WC_compCache.playerKnowsTomeSpell.
    tomeCache = {},
    tomeIsKnownCache = {},
    -- v2.22.0 Process-mode cache. Maps itemID to one of
    -- "Disenchant" | "Mill" | "Prospect" | "none", or nil if not yet
    -- scanned. Stable property per itemID. Filled lazily by the
    -- can* helpers below.
    processCache = {},
    -- v2.59.0 openable-container cache, corrected in v2.59.3. Maps itemID
    -- to "never" (tooltip shows neither ITEM_OPENABLE nor LOCKED - e.g.
    -- Hearthstones, potions, non-container gear). "never" IS stable per
    -- itemID and short-circuits the auto-open scan with zero API calls.
    -- The "openable" state is DELIBERATELY NOT cached: multiple instances
    -- of the same lockbox itemID can be in different lock states, and
    -- GetContainerItemInfo's `locked` field is unreliable for never-picked
    -- lockboxes in 3.3.5a - it flips true only when the item is mid-cast
    -- (Pick Lock actively targeting THIS slot). Caching "openable" caused
    -- an auto-open loop when a picked box poisoned the cache for still-
    -- locked instances of the same itemID (Serv report, v2.59.3). Filled
    -- lazily by WC_IsOpenable in WoWClearance_Events.lua.
    openableCache = {},
    -- Vendor cycle gate. Set to true while the worker frame is processing
    -- the sell/delete queue, false otherwise. Multiple cross-cutting
    -- paths read it as a "skip while a vendor cycle is mid-flight"
    -- guard (BAG_UPDATE handlers, auto-open driver). Lives on
    -- WC_compCache, shared by every file that needs it.
    vendorRunning = false,
    -- Baseline-protected itemIDs: profession tools the player needs to
    -- keep around to perform their profession (fishing poles, mining
    -- picks, the engineering Arclight Spanner, skinning knife, blacksmith
    -- hammer). Reported by user Monrad after WC auto-sold their tools
    -- through a White-rule sweep. Mirrors the v2.13.x quest-item narrowing
    -- design: this safety net vetoes qualityPass (auto-rule sweeps) but
    -- NOT whitelistPass (explicit Sell List entries) - the user's lists
    -- are authoritative. ADB.allowedItems[itemID] also bypasses the
    -- safety net for the per-item Allow Sell override case.
    --
    -- Item IDs are WoW WotLK 3.3.5a standard. Project Ebonhold custom
    -- profession tools (if any) need to be added by the user via Keep
    -- List or Allow Sell override.
    baselineProtectedIDs = {
        -- Fishing poles (all are itemSubType "Fishing Poles" weapons
        -- equipped in main hand for fishing).
        [6256]  = true, -- Fishing Pole
        [6365]  = true, -- Strong Fishing Pole
        [6366]  = true, -- Darkwood Fishing Pole
        [6367]  = true, -- Big Iron Fishing Pole
        [12225] = true, -- Blump Family Fishing Pole
        [19022] = true, -- Nat Pagle's Extreme Angler FC-5000
        [19970] = true, -- Arcanite Fishing Pole
        [25979] = true, -- Seth's Graphite Fishing Pole
        [44050] = true, -- Mastercraft Kalu'ak Fishing Pole
        [45858] = true, -- Bone Fishing Pole
        [46337] = true, -- Staats' Fishing Pole
        -- Mining picks (required to mine nodes; the basic Mining Pick
        -- 2901 is the trigger Monrad reported).
        [2901]  = true, -- Mining Pick
        [20723] = true, -- Brann's Trusty Pick
        [40772] = true, -- Hammer Pick
        [40892] = true, -- Mammoth Mining Pick
        -- Engineering tool (required to use some Engineering devices;
        -- Monrad reported the Arclight Spanner specifically).
        [6219]  = true, -- Arclight Spanner
        -- Skinning Knife (required to skin corpses).
        [7005]  = true, -- Skinning Knife
        -- Blacksmith Hammer (required for some Blacksmithing recipes).
        [5956]  = true, -- Blacksmith Hammer
    },
    -- Auto-open containers combat-deferred announce flag. The driver bails
    -- early on InCombatLockdown() because UseContainerItem on a lockbox
    -- triggers an "Opening" cast that gets interrupted by damage. Without a
    -- signal, deferral looks identical to the addon being broken. This flag
    -- gates a one-shot "[WC] Deferred N container(s) until out of combat."
    -- chat line per combat instance and is cleared on PLAYER_REGEN_ENABLED.
    combatDeferredAnnounced = false,
}
-- Mirror the junk-drawer table onto the addon namespace. Same table; both
-- names alias the same memory. WoWClearance_Events.lua re-binds this as its own
-- module-local `WC_compCache` upvalue so existing call sites keep working
-- without churn. Stage 1 of the file split established this alias; Stage 2
-- moved the declaration into Core.
-- Spell name lookup (port work item 4).
--
-- 3.3.5a's GetSpellInfo returned positional values with the name at 1.
-- C_Spell.GetSpellInfo returns a TABLE, and its real field list - measured
-- on the live client - is castTime, iconID, maxRange, minRange, name,
-- originalIconID, spellID. Note there is NO `rank`: position 2 of the old
-- return was removed outright, not renamed, so a shim handing back nil there
-- would hide a genuine removal.
--
-- Every call site in this addon wants the name and nothing else, so this
-- wraps the table read once instead of destructuring it at each site.
-- Returns nil when the spell DB is not ready yet, which callers already
-- handle with an `or "<fallback>"`.
--
-- Memoised: the hub calls this on every player cast, and the API builds a
-- new table per call. Bounded by the distinct spells seen in a session.
local spellNames = {}
function WC_compCache.spellName(id)
    local name = id and spellNames[id]
    if name then
        return name
    end
    local info = id and C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
    name = info and info.name
    if name then
        spellNames[id] = name
    end
    return name
end

-- Spell-known lookup (port work item 4 / 6).
--
-- 3.3.5a: IsSpellKnown(spellID). That global does not exist on Forever, and
-- the replacement is NOT a rename - it takes a spell bank and a pet flag:
--     C_SpellBook.IsSpellInSpellBook(id, Enum.SpellBookSpellBank.Player, false)
-- Both the function and the Enum were verified present on the live client.
--
-- Used by Process Bags to detect the player's professions (Disenchant /
-- Milling / Prospecting / Pick Lock). A false negative here silently hides
-- those modes rather than erroring, so the nil-guards matter: if the API is
-- missing we return false and Process Bags reports no professions, which is
-- the documented pre-existing behaviour on cores lacking the old global.
function WC_compCache.spellKnown(id)
    if not id then
        return false
    end
    local fn = C_SpellBook and C_SpellBook.IsSpellInSpellBook
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
    if not fn or not bank then
        return false
    end
    local ok, known = pcall(fn, id, bank, false)
    return (ok and known) and true or false
end

NS.compCache = WC_compCache
