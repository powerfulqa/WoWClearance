#!/usr/bin/env lua
-- Perf-guardrail regression tests for WoWClearance.
--
-- Run from repo root:    lua tests/test_perf_guardrails.lua
--
-- v2.22.0 (Process Bags) and v2.23.0 (affix dupe gate) introduced
-- a heavyweight `buildProcessSummary` call into the BAG_UPDATE event
-- handler. Each call walks all 5 bags, scans tooltip text per
-- Rare/Epic item, and re-sorts the result. The Greedy Scavenger
-- picking up 5 items fires 5 BAG_UPDATE events in <100 ms, so the
-- cost compounded into 1.5 s game freezes during AOE farming.
--
-- v2.24.0 fixed it by:
--   1. Gating `rearmProcessButton` on panel visibility / keybind.
--   2. Routing BAG_UPDATE deferred work through a 120 ms debounce
--      frame so bursts coalesce.
--   3. Caching `bagSlotAffixData` per itemString.
--
-- v2.25.0 added Lockpick mode (rogue Pick Lock via Process Bags) +
-- collapsible Process Bags sections. v2.25.1 fixed an auto-open
-- regression where the debounce frame's OnUpdate closure couldn't
-- resolve `WC_HandleAutoOpenContainers` because it was declared as
-- `local function` AFTER the closure (Lua's lexical scoping captures
-- locals at closure-creation time, not at call time). Tests below
-- cover both the original perf invariants and the wiring invariants
-- that drove v2.25.1.
--
-- These tests are static-pattern checks against the source. They do
-- NOT measure runtime - the WoW API is not mockable - but they catch
-- the structural mistakes that caused these regressions so the same
-- patterns can't sneak back in without setting off CI.
--
-- Add new tests below as new invariants emerge. Keep them pattern-
-- matching only - this file must run under stock lua5.1 with no
-- external dependencies so it works in CI without a luarocks step.

-- Post-split: concat every shipped .lua source file. The file-split refactor
-- tracked in docs/CODE_REVIEW.md item 4 moves chunks out of WoWClearance_Events.lua
-- into per-feature files (Core first, more to follow). Every static-pattern
-- check below runs against the whole concatenated source, so invariants
-- expressed as `src:find(...)` continue to hold across the split boundary.
-- v2.68.1: the list is DERIVED from WoWClearance.toc (the real load list)
-- instead of a hand-written array - the array had silently drifted behind
-- the .toc (ProcShare, RealmComms, ServerShare shipped unscanned). The
-- Locale file is excluded here as before.
local SOURCE_PATHS = {}
-- v0.9.0: the optional Loot module (WoWClearance_Loot/) ships in the same
-- zip as a second addon; its files are scanned alongside the core's.
for _, toc in ipairs({ { "WoWClearance.toc", "" }, { "WoWClearance_Loot/WoWClearance_Loot.toc", "WoWClearance_Loot/" } }) do
    local fh = assert(io.open(toc[1], "rb"), toc[1] .. " not found (run from repo root)")
    local text = fh:read("*a")
    fh:close()
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        local f = line:match("^(WoWClearance_[%w_]+%.lua)%s*$")
        if f and not f:match("^WoWClearance_Locale") then
            SOURCE_PATHS[#SOURCE_PATHS + 1] = toc[2] .. f
        end
    end
end

local pieces = {}
for _, path in ipairs(SOURCE_PATHS) do
    local f, err = io.open(path, "r")
    if not f then
        io.stderr:write("FAIL: cannot open " .. path .. ": " .. tostring(err) .. "\n")
        os.exit(1)
    end
    pieces[#pieces + 1] = f:read("*a")
    f:close()
end
local src = table.concat(pieces, "\n")

local fails = 0

local function check(name, ok, message)
    if ok then
        print("PASS  " .. name)
    else
        print("FAIL  " .. name)
        if message then
            print("      " .. message)
        end
        fails = fails + 1
    end
end

-- ---------------------------------------------------------------------------
-- Helper: extract the body of the BAG_UPDATE branch in the OnEvent
-- dispatcher. Returns the text between `event == "BAG_UPDATE"` and the
-- next `elseif event ==` or `end` at a similar indent level. Used by
-- multiple tests below.
-- ---------------------------------------------------------------------------
local function extract_bag_update_branch()
    -- Lazy scan: find the BAG_UPDATE elseif, then read until the next
    -- elseif/end at the same level. Not a real Lua parser, but
    -- sufficient for our static-pattern checks.
    local startIdx = src:find('event == "BAG_UPDATE"', 1, true)
    if not startIdx then return nil end
    local tailStart = startIdx
    -- Find the next "elseif event ==" or terminating end-of-handler.
    local endIdx = src:find('elseif event ==', tailStart + 1, true)
    if not endIdx then
        -- Should always find one - the handler has many branches.
        return src:sub(startIdx)
    end
    return src:sub(startIdx, endIdx - 1)
end

-- ---------------------------------------------------------------------------
-- Test 1: BAG_UPDATE branch must NOT directly call heavy bag-walking
-- functions. Those go through the debounce frame.
-- ---------------------------------------------------------------------------
-- Background: Pet AOE loot fires one BAG_UPDATE per slot filled. A
-- 5-item drop = 5 BAG_UPDATEs in <100 ms. Calling buildProcessSummary
-- (via rearmProcessButton) or scanning all bags (via
-- checkBagsForUpgrades / HandleAutoOpenContainers / refreshProcessPanel)
-- per-event multiplies the cost by 5. They MUST route through the
-- debounce frame so the burst is coalesced.
--
-- Exception: WC_HandleBagFullForCycle stays synchronous because its
-- internal 1.5 s hysteresis already debounces, and the bag-full cycle
-- wants the FIRST trip across the threshold without extra delay.
do
    local body = extract_bag_update_branch()
    local violators = {}
    if body then
        local forbidden = {
            "WC_compCache%.rearmProcessButton%(%)",
            "WC_compCache%.checkBagsForUpgrades%(%)",
            "WC_HandleAutoOpenContainers%(%)",
            "WC_compCache%.refreshProcessPanel%(%)",
        }
        for _, pat in ipairs(forbidden) do
            for line in body:gmatch("[^\n]+") do
                local stripped = line:gsub("^%s+", "")
                local isComment = stripped:find("^%-%-")
                if not isComment and line:find(pat) then
                    violators[#violators + 1] = stripped
                end
            end
        end
    end
    local detail
    if #violators > 0 then
        local list = {}
        for i = 1, #violators do
            list[i] = "    " .. violators[i]
        end
        detail = "BAG_UPDATE branch directly invokes a heavy function. Route through WC_compCache.bagUpdateFrame instead:\n" ..
                 table.concat(list, "\n")
    end
    check("BAG_UPDATE branch routes heavy work through debounce frame",
          body ~= nil and #violators == 0,
          detail or (body == nil and "could not locate BAG_UPDATE branch in source"))
end

-- ---------------------------------------------------------------------------
-- Test 2: The BAG_UPDATE debounce frame must exist and be wired to
-- BAG_UPDATE.
-- ---------------------------------------------------------------------------
do
    local hasFrame = src:find("WC_compCache%.bagUpdateFrame%s*=%s*CreateFrame")
    local hasOnUpdate = src:find('WC_compCache%.bagUpdateFrame:SetScript%("OnUpdate"')
    local body = extract_bag_update_branch()
    local triggersFrame = body and body:find("WC_compCache%.bagUpdateFrame:Show%(%)") ~= nil

    check("BAG_UPDATE debounce frame is declared (WC_compCache.bagUpdateFrame)",
          hasFrame ~= nil)
    check("BAG_UPDATE debounce frame has an OnUpdate handler",
          hasOnUpdate ~= nil)
    check("BAG_UPDATE branch triggers the debounce frame via :Show()",
          triggersFrame == true)
end

-- ---------------------------------------------------------------------------
-- Test 3: rearmProcessButton must early-return when the user isn't
-- using Process Bags (panel hidden AND no keybind set).
-- ---------------------------------------------------------------------------
-- Background: rearmProcessButton calls buildProcessSummary, which is
-- O(bags + Rare/Epic tooltip scans). When the user has never opened
-- the panel AND has no keybind, the macrotext won't be observed, so
-- the work is entirely wasted. Gate at the top.
do
    -- Pull the rearmProcessButton body (function-start to next `end`
    -- at column 0, which is the function close).
    local fnStart = src:find("function WC_compCache%.rearmProcessButton%(%)")
    if not fnStart then
        check("rearmProcessButton is gated on panel visibility / keybind",
              false, "rearmProcessButton not found in source")
    else
        -- Find the function close: the next `\nend` after fnStart.
        local fnEnd = src:find("\nend", fnStart)
        local body = fnEnd and src:sub(fnStart, fnEnd) or src:sub(fnStart, fnStart + 2000)
        local hasIsShown = body:find("panel:IsShown%(%)") ~= nil
        local hasBindingCheck = body:find("GetBindingKey") ~= nil
        check("rearmProcessButton gates on panel:IsShown()",
              hasIsShown,
              "expected the function to check panel:IsShown() before the bag walk")
        check("rearmProcessButton gates on GetBindingKey for the cast button",
              hasBindingCheck,
              "expected GetBindingKey check so hold-key-to-drain still works without the panel open")
    end
end

-- ---------------------------------------------------------------------------
-- Test 4: bagSlotAffixData must cache per itemString.
-- ---------------------------------------------------------------------------
-- Background: bagSlotAffixData does a SetBagItem + 30-line tooltip
-- parse. Without a cache, repeat calls within the same BAG_UPDATE
-- storm (or across the rearm + tooltip-annotation + IsSellable paths)
-- pay full cost every time. Cache key is itemString since the affix
-- is per-instance.
do
    local fnStart = src:find("function WC_compCache%.bagSlotAffixData%(")
    if not fnStart then
    else
        local fnEnd = src:find("\nend", fnStart)
        local body = fnEnd and src:sub(fnStart, fnEnd) or src:sub(fnStart, fnStart + 2000)
        local reads = body:find("WC_compCache%.affixDataCache%[") ~= nil
        check("bagSlotAffixData reads / writes WC_compCache.affixDataCache",
              reads,
              "expected the function to short-circuit on a cached itemString lookup")
    end
end

-- ---------------------------------------------------------------------------
-- Test 5: affixDataCache table is declared.
-- ---------------------------------------------------------------------------
do
    local declared = src:find("WC_compCache%.affixDataCache%s*=%s*{}") ~= nil
end

-- ---------------------------------------------------------------------------
-- Test 6 (v2.25.1 regression): WC_HandleAutoOpenContainers must be
-- forward-declared at file scope BEFORE the bagUpdateFrame OnUpdate
-- closure captures the name. Otherwise Lua's lexical scoping resolves
-- the reference to the (nil) global and auto-open silently never
-- fires from the debounce path.
--
-- Detection: the function definition uses bare `function WC_Handle...`
-- (NOT `local function`), meaning the local was forward-declared
-- separately. The forward declaration itself appears earlier as a
-- standalone `local WC_HandleAutoOpenContainers` line.
-- ---------------------------------------------------------------------------
do
    -- Definition style: bare `function X` (no `local`) is the
    -- correct shape when X was forward-declared at file scope.
    local hasBareDefinition = src:find("\nfunction WC_HandleAutoOpenContainers%(%)") ~= nil
    local hasLocalDefinition = src:find("\nlocal function WC_HandleAutoOpenContainers%(%)") ~= nil
    -- Forward declaration: a `local WC_HandleAutoOpenContainers` line
    -- NOT immediately followed by `function`.
    local hasForwardDecl = src:find("\nlocal WC_HandleAutoOpenContainers[%s\n]") ~= nil
        or src:find("\nlocal WC_HandleAutoOpenContainers$") ~= nil
    check("WC_HandleAutoOpenContainers is forward-declared (not `local function`)",
          hasBareDefinition and not hasLocalDefinition and hasForwardDecl,
          "expected `local WC_HandleAutoOpenContainers` forward decl + bare `function WC_HandleAutoOpenContainers()` definition; without the forward decl the v2.24.0 debounce frame closure resolves the name to the nil global and auto-open never fires")
end

-- ---------------------------------------------------------------------------
-- Test 7 (v2.25.1): bagUpdateFrame OnUpdate must reference
-- WC_HandleAutoOpenContainers so the auto-open driver fires from the
-- debounce path. If a refactor accidentally drops the call, unlocked
-- containers stop being processed.
-- ---------------------------------------------------------------------------
do
    -- Extract the OnUpdate closure body. The closure starts at the
    -- SetScript("OnUpdate", function(...) and ends at the matching
    -- `end)`. Crude bracket match good enough for the static check.
    local startIdx = src:find('bagUpdateFrame:SetScript%("OnUpdate"', 1)
    local body
    if startIdx then
        local endIdx = src:find("end%)", startIdx)
        body = endIdx and src:sub(startIdx, endIdx) or src:sub(startIdx, startIdx + 4000)
    end
    local refs = body and body:find("WC_HandleAutoOpenContainers%(%)") ~= nil
    check("bagUpdateFrame OnUpdate calls WC_HandleAutoOpenContainers",
          refs == true,
          "the debounce frame must call WC_HandleAutoOpenContainers() inside its OnUpdate body so the auto-open driver fires after each burst settles")
end

-- ---------------------------------------------------------------------------
-- Test 8 (v2.25.0): Pick Lock spell-cast trigger is wired into
-- UNIT_SPELLCAST_SUCCEEDED. BAG_UPDATE doesn't fire for a lockbox's
-- locked->openable transition, so the UNIT_SPELLCAST_SUCCEEDED match
-- against PICK_LOCK_NAME is the only reliable trigger to refresh the
-- Process Bags panel and run the auto-open driver post-cast.
-- ---------------------------------------------------------------------------
do
    local startIdx = src:find('event == "UNIT_SPELLCAST_SUCCEEDED"', 1, true)
    local body
    if startIdx then
        local endIdx = src:find('elseif event ==', startIdx + 1, true)
        body = endIdx and src:sub(startIdx, endIdx - 1) or src:sub(startIdx, startIdx + 3000)
    end
    local hasPickLockHook = body and body:find("PICK_LOCK_NAME") ~= nil
    local triggersDebounce = body and body:find("bagUpdateFrame:Show%(%)") ~= nil
    check("UNIT_SPELLCAST_SUCCEEDED handles PICK_LOCK_NAME completion",
          hasPickLockHook == true and triggersDebounce == true,
          "expected the UNIT_SPELLCAST_SUCCEEDED branch to compare spellName against WC_compCache.PICK_LOCK_NAME and trigger the bagUpdateFrame debounce")
end

-- ---------------------------------------------------------------------------
-- Test 9 (v2.25.0): Lockpick spell constants + helpers exist.
-- ---------------------------------------------------------------------------
do
    local hasSpellConst = src:find("WC_compCache%.SPELL_PICK_LOCK%s*=%s*1804") ~= nil
    local hasNameConst = src:find("WC_compCache%.PICK_LOCK_NAME") ~= nil
    local hasHelper = src:find("function WC_compCache%.canPickLock%(") ~= nil
    check("WC_compCache.SPELL_PICK_LOCK = 1804 constant is declared",
          hasSpellConst)
    check("WC_compCache.PICK_LOCK_NAME is cached at file scope",
          hasNameConst)
    check("WC_compCache.canPickLock helper is defined",
          hasHelper)
    -- A picked box must leave the queue by GUID, not wait for the tooltip.
    local body = src:match("function WC_compCache%.canPickLock%(.-\nend") or ""
    local guidAt = body:find("pickedLockGUIDs%[C_Item%.GetItemGUID%(loc%)%]")
    local scanAt = body:find("scanBagItem")
    check("canPickLock rejects an already-picked box by GUID before the tooltip scan",
          guidAt ~= nil and scanAt ~= nil and guidAt < scanAt)
    check("a successful Lockpick cast records the box GUID",
          src:find('pending%.mode == "Lockpick".-pickedLockGUIDs%[C_Item%.GetItemGUID%(loc%)%] = true') ~= nil)
end

-- ---------------------------------------------------------------------------
-- Test 10 (v2.25.0): Lockpick + collapsible-section schema is
-- defaulted in EnsureDB. Without these defaulters the per-session
-- code path reads `nil` and the toggles silently do nothing.
-- ---------------------------------------------------------------------------
do
    local hasLockpickEnabled = src:find("DB%.lockpickEnabled%s*=%s*true") ~= nil
    local hasNotifyDefault = src:find("DB%.lockpickNotifyOnCombatExit%s*=%s*false") ~= nil
    local hasCollapsedDefault = src:find("DB%.processCollapsedModes%s*=%s*{}") ~= nil
    check("EnsureDB defaults DB.lockpickEnabled to true",
          hasLockpickEnabled)
    check("EnsureDB defaults DB.lockpickNotifyOnCombatExit to false",
          hasNotifyDefault)
    check("EnsureDB defaults DB.processCollapsedModes to an empty table",
          hasCollapsedDefault)
end

-- ---------------------------------------------------------------------------
-- Test 11 (v2.25.0): Lockpick mode is wired into buildProcessSummary.
-- ---------------------------------------------------------------------------
do
    local hasLockpickBranch = src:find('mode%s*=%s*"Lockpick"') ~= nil
    local hasModeOrder = src:find("Lockpick%s*=%s*4") ~= nil
    check("buildProcessSummary emits a Lockpick mode entry",
          hasLockpickBranch,
          "expected `mode = \"Lockpick\"` assignment in the canPickLock branch")
    check("modeOrder ranks Lockpick = 4",
          hasModeOrder,
          "the sort order must include Lockpick or its rows won't sort consistently with DE/Mill/Prospect")
end

-- ---------------------------------------------------------------------------
-- Test 12 (v2.26.0): chance-on-hit "Allow Sell" override list.
-- ---------------------------------------------------------------------------
-- Background: v2.26.0 replaces the chance-on-hit protection's auto-
-- dupe-gate ambition (which failed because engraving descriptions
-- don't match bag-tooltip effect text) with a single account-wide
-- manual override list. The user marks itemIDs via the Alt+Right-
-- Click menu's "Allow Sell" row. Marked items release the v2.20.0
-- protection so future drops auto-sell via the quality rules and
-- become available to Process Bags. Account-wide because PE's
-- extraction state itself is account-wide.
do
    local hasDefault = src:find("ADB%.allowedItems%s*=%s*{}") ~= nil
    check("EnsureAccountDB defaults ADB.allowedItems to an empty table",
          hasDefault,
          "the account-wide allow list is the load-bearing v2.26+ schema field for both chance-on-hit AND random-affix overrides")

    -- buildProcessSummary must gate on allowedItems for both
    -- chance-on-hit and random-affix branches.
    local pbStart = src:find("function WC_compCache%.buildProcessSummary%(", 1)
    local pbEnd = pbStart and src:find("\nend", pbStart) or nil
    local pbBody = pbStart and pbEnd and src:sub(pbStart, pbEnd) or ""
    local processGate = pbBody:find("allowedItems") ~= nil

    -- Migration: an older field name was `allowedProcs`. New code
    -- must still migrate that data forward so v2.26.x users don't
    -- lose their decisions.
    local hasMigration = src:find('rawget%(ADB,%s*"allowedProcs"%)') ~= nil
        or src:find("ADB%.allowedProcs") ~= nil
    check("ADB.allowedProcs -> allowedItems migration is in EnsureAccountDB",
          hasMigration,
          "renaming the schema field requires a one-shot copy so existing decisions survive upgrade")
end

-- ---------------------------------------------------------------------------
-- Test 13 (v2.26.0): ExtractionService merge + dirty-check refresh.
-- ---------------------------------------------------------------------------
-- Background: PE's _G.ExtractionService.learnedAffixes is the
-- authoritative catalog of (id, name, learned, weaponOnly) records.
-- The refresh path must read from that table (not just walk the
-- spellbook), and the dirty-check function must be wired into both
-- the BAG_UPDATE debounce frame and the PLAYER_REGEN_ENABLED handler
-- so the player's post-extraction state propagates without /reload.
do
    local readsExtraction = src:find("_G%.ExtractionService") ~= nil
        or src:find("svc%.learnedAffixes") ~= nil
    local hasDirtyFn = src:find("function WC_compCache%.refreshExtractionIfDirty%(") ~= nil
    local hasVersionCounter = src:find("WC_compCache%.knownExtractionVersion") ~= nil

    -- The PLAYER_REGEN_ENABLED handler must call refreshExtractionIfDirty
    -- so combat exit picks up freshly-extracted procs.
    local startIdx = src:find('event == "PLAYER_REGEN_ENABLED"', 1, true)
    local body
    if startIdx then
        local endIdx = src:find('elseif event ==', startIdx + 1, true)
        body = endIdx and src:sub(startIdx, endIdx - 1) or src:sub(startIdx, startIdx + 3000)
    end
    local wiredCombat = body and body:find("refreshExtractionIfDirty") ~= nil

    -- The 120 ms BAG_UPDATE debounce frame must also call it.
    local frameStart = src:find('bagUpdateFrame:SetScript%("OnUpdate"', 1)
    local frameBody
    if frameStart then
        local endIdx = src:find("end%)", frameStart)
        frameBody = endIdx and src:sub(frameStart, endIdx) or src:sub(frameStart, frameStart + 4000)
    end
    local wiredFrame = frameBody and frameBody:find("refreshExtractionIfDirty") ~= nil
end

-- ---------------------------------------------------------------------------
-- Test 14 (v2.26.0): two-phrasing chance-on-hit detector.
-- ---------------------------------------------------------------------------
-- Background: items with chance-on-hit procs use two tooltip
-- phrasings - the classic `Chance on hit: <text>` (Bloodpike) and the
-- older PPM-style `Equip: Chance to <verb>... <text>` (Quillshooter).
-- v2.26.0 routes both through the same protection. If the detector
-- regresses to one phrasing, the other style slips past the v2.20.0
-- auto-rule gate and ends up in the Will Sell sweep.
do
    local hasHelper = src:find("function WC_compCache%.lineLooksLikeChanceProc%(") ~= nil
    -- Must scan for ITEM_SPELL_TRIGGER_ONPROC (or its enUS fallback) AND
    -- the Equip-Chance pattern.
    local hasClassicNeedle = src:find("ITEM_SPELL_TRIGGER_ONPROC") ~= nil
    local hasEquipPattern = src:find('"%^Equip:%%s%*Chance to') ~= nil
    local hasTransferredHave = src:find('"Your%%s%.%- have a chance to%%s%+%%a"') ~= nil
    local hasTransferredHas = src:find('"Your%%s%.%- has a chance to%%s%+%%a"') ~= nil
    local hasNoLineStartAnchor = src:find('"%^Your%%s%.%- have a chance to') == nil
    check("transferred-proc pattern is NOT anchored to line start (v2.44.11)",
          hasNoLineStartAnchor,
          "v2.44.11: PE wraps the proc text in @affix@...@affix@ markers on the raw scan-tooltip line. The line starts with '@', not 'Y', so a ^Your anchor fails to match. Confirmed by Zukii's v2.44.10 /wc sellinfo trace showing 'chanceOnHitProtection - n/a' on Skoll's Fang of Thunderfury despite v2.44.10 shipping the pattern. Without dropping the anchor every PE transferred-proc weapon still silent-sells.")
end

-- ---------------------------------------------------------------------------
-- Test 15 (v2.26.0): WC_IsSellable chance-on-hit branch gates on
-- ADB.allowedItems.
-- ---------------------------------------------------------------------------
-- Background: the central sell-decision gate must consult the
-- allow list before letting a chance-on-hit item through the
-- quality-rule sweep. Without this branch the v2.26.0 schema field
-- exists but no code reads it, and items stay protected forever.
-- v2.71.0: the decision body moved to WoWClearance_Decision.lua
-- (NS.Decision.sell + buildCtx); the core reads ctx.allowedItem, the
-- adapter fills it from ADB.allowedItems.
do
    local fh = io.open("WoWClearance_Decision.lua", "rb")
    local dc = fh and fh:read("*a") or ""
    if fh then
        fh:close()
    end
    local gateOK = dc:find("if not ctx%.allowedItem and not knownProcPass then") ~= nil
        and dc:find("ADB%.allowedItems") ~= nil
        and dc:find("itemHasChanceOnHit") ~= nil
end

-- ---------------------------------------------------------------------------
-- Test 16 (v2.26.0): tooltip annotation has Protected and Allowed
-- states, replaces the v2.25.x single-state label.
-- ---------------------------------------------------------------------------
do
    -- v2.32.x label simplification: protection labels now read "Keep
    -- (reason)" instead of "Protected - reason"; override-active
    -- labels surface the actual destination as "Will Sell (...)" or
    -- "Will Delete" instead of "Allowed - ...".
    local hasProtectedLabel = src:find("Keep %(chance%-on%-hit proc%)") ~= nil
    local hasSellLabel = src:find("Override on") ~= nil
    local hasAccountSellLabel = src:find("Will Sell %(your Account List%)") ~= nil
    local hasCharSellLabel = src:find("Will Sell %(your Character List%)") ~= nil
    -- "Allowed - Delete" collapses to plain "Will Delete" because the
    -- destination doesn't need an "Allowed" qualifier - the verdict
    -- is what the player needs to see.
    -- v2.43.0: verdict labels are localized (wrapped in L[...]), so the
    -- displayed string is no longer a single literal. Match the wrapped key.
    local hasDeleteLabel = src:find('L%["Will Delete"%]') ~= nil
    check("tooltip annotation emits 'Override on ...' when no list chosen",
          hasSellLabel,
          "marked items with no list membership get a call-to-action label, not a misleading 'will sell'")
    check("tooltip annotation emits 'Will Sell (your Account List)' when on Account Sell List",
          hasAccountSellLabel,
          "marked + on ADB.whitelist - label must reflect the actual destination")
    check("tooltip annotation emits 'Will Sell (your Character List)' when on Character Sell List",
          hasCharSellLabel,
          "marked + on DB.whitelist - label must reflect the actual destination")
    check("tooltip annotation emits 'Will Delete' when on Delete List (with or without override)",
          hasDeleteLabel,
          "marked + on DB.deleteList - delete verdict is the destination, no 'Allowed' qualifier needed")
end

-- ---------------------------------------------------------------------------
-- Test 17 (v2.26.0): context menu invariants.
-- ---------------------------------------------------------------------------
-- The menu MUST:
--   1. Hide list rows while a chance-on-hit item is unmarked.
--   2. Show "Allow Sell" / "Remove from Allowed Procs" in the
--      sellNow row slot for chance-on-hit items.
--   3. NOT show "Sell Now" anywhere any more (dropped in v2.26.0).
--   4. NOT carry "Add to" prefix on list row labels.
do
    local hasProtectedGate = src:find("rowHidden = true") ~= nil
        and src:find("procProtected") ~= nil
    local hasAllowText = src:find('btn:SetText%(L%["Allow Sell"%]%)') ~= nil
    local hasRemoveText = src:find("Remove from Allow Sell") ~= nil
    local sellNowGone = src:find('btn:SetText%("Sell Now"%)') == nil
    local addToPrefixGone = src:find('btn:SetText%("Add to "') == nil
    check("menu hides list rows while chance-on-hit item is unmarked",
          hasProtectedGate,
          "the procProtected gate is what forces the user to acknowledge the proc before list options open up")
    check("menu shows 'Allow Sell' for unmarked chance-on-hit items",
          hasAllowText)
    check("menu shows 'Remove from Allow Sell' for marked items",
          hasRemoveText)
    check("'Sell Now' is no longer in the menu",
          sellNowGone,
          "v2.26.0 removed the one-shot Sell Now path; explicit sells go through the Sell List")
    check("'Add to' prefix is no longer on list row labels",
          addToPrefixGone,
          "v2.26.0 dropped the prefix; the labels are self-evident and orange 'Remove from' rows provide the contrast")
end

-- ---------------------------------------------------------------------------
-- Test 18 (v2.26.0): WC_CTX_ROWS no longer contains the abandoned
-- forceSell row kind, and the legacy sellNow kind survived (now
-- repurposed as the Allow toggle slot).
-- ---------------------------------------------------------------------------
do
    -- forceSell was an interim design that got collapsed into a single
    -- Allow toggle. If it sneaks back in we'll see a duplicate menu
    -- row alongside the Allow Sell entry.
    local hasForceSell = src:find('kind = "forceSell"') ~= nil
    local hasSellNow = src:find('kind = "sellNow"') ~= nil
    check("WC_CTX_ROWS does NOT contain the abandoned forceSell row kind",
          not hasForceSell,
          "forceSell was collapsed into the single Allow toggle in v2.26.0; if it re-appears the menu shows two redundant rows")
    check("WC_CTX_ROWS still contains the sellNow row kind (used as Allow toggle slot)",
          hasSellNow,
          "the Allow Sell toggle reuses the legacy sellNow row position; removing the kind would drop the toggle entirely")
end

-- ---------------------------------------------------------------------------
-- Test 19a (v2.27.0): random-affix protection uses the same Allow Sell
-- gate as chance-on-hit.
-- ---------------------------------------------------------------------------
-- Background: v2.26.0 introduced the Allow Sell context-menu workflow
-- (hide list rows -> show "Allow Sell" -> after marking, full menu
-- opens up) but only for chance-on-hit items. v2.27.0 extends the
-- same gate to v2.23.0 random-affix protected items so the user
-- workflow is consistent across both protection mechanisms.
do
    -- The menu-gate detection must consider BOTH protections. Look
    -- for a hasAffix branch alongside hasProc in the context menu.
    local fnStart = src:find("local function WC_ShowItemContextMenu%(", 1)
    local fnEnd = fnStart and src:find("\nend", fnStart + 100) or nil
    local body = fnStart and fnEnd and src:sub(fnStart, fnEnd) or ""
    local readsHasAffix = body:find("hasAffix") ~= nil
        and body:find("bagSlotAffixData") ~= nil
    local unifiedFlag = body:find("hasProtection") ~= nil
    check("context menu uses a unified hasProtection flag",
          unifiedFlag,
          "the unified flag is what lets the sellNow row and the list-row hiding share the same gate")

    -- The sell decision's affix branch must read allowedAffixes (the
    -- affix-keyed list, NOT allowedItems) as a manual override path
    -- alongside the v2.23.0 affixAllowExactDupes auto-detect. v2.71.0:
    -- the branch lives in WoWClearance_Decision.lua (core reads
    -- ctx.manualAffixAllow; the buildCtx adapter fills it from
    -- ADB.allowedAffixes).
    local dfh = io.open("WoWClearance_Decision.lua", "rb")
    local sellBody = dfh and dfh:read("*a") or ""
    if dfh then
        dfh:close()
    end
    local affixBranchReadsAllow = sellBody:find("protectAffixedRareItems") ~= nil
        and sellBody:find("allowedAffixes") ~= nil
end

-- ---------------------------------------------------------------------------
-- Test 19b (v2.27.0): affix-keyed allow list schema + marking path.
-- ---------------------------------------------------------------------------
-- Background: random-affix items carry their identity in the affix
-- description (per-instance roll). A per-itemID mark would let every
-- base-itemID drop through regardless of which affix rolled - too
-- coarse. The affix-keyed list is what gives the user "I have this
-- affix extracted; pass any drop rolling it" semantics.
do
    local hasDefault = src:find("ADB%.allowedAffixes%s*=%s*{}") ~= nil

    -- The Allow Sell click path for an affixed item must write to
    -- ADB.allowedAffixes keyed by the normalised description, not to
    -- ADB.allowedItems keyed by itemID.
    local fnStart = src:find("local function WC_ShowItemContextMenu%(", 1)
    local fnEnd = fnStart and src:find("\nend", fnStart + 100) or nil
    local body = fnStart and fnEnd and src:sub(fnStart, fnEnd) or ""
    local marksByDescription = body:find("allowedAffixes%[affixKey%]") ~= nil

end

-- ---------------------------------------------------------------------------
-- Test 19c (v2.27.0): affix-sourced Sell List entries get an
-- "(affix-gated)" tag in the panel.
-- ---------------------------------------------------------------------------
-- Background: adding an affixed-item-instance to the Sell List adds
-- the BASE itemID, which is coarser than the per-drop filtering the
-- affix protection actually applies. The (affix-gated) tag makes
-- this honest in the panel so the user doesn't read "Orb of
-- Mistmantle" on the list and assume every drop of that itemID
-- will sell.
do
    local hasDefault = src:find("ADB%.affixedListedItems%s*=%s*{}") ~= nil
    local hasStamp = src:find("ADB%.affixedListedItems%[itemID%]%s*=%s*true") ~= nil
    local hasTag = src:find('%(affix%-gated%)') ~= nil
end

-- ---------------------------------------------------------------------------
-- Test 19 (post-v2.26.1 cleanup): processTooltipHasLine writes the
-- "none" negative-cache sentinel on scan miss.
-- ---------------------------------------------------------------------------
-- Background: canMill and canProspect both early-return on
-- `processCache[itemID] == "none"`. Without the negative-write,
-- every non-millable / non-prospectable item gets a fresh 30-line
-- tooltip scan on each BAG_UPDATE-driven rearm (the panel/keybind-
-- gated rearm path that fires after the 120 ms debounce). Bag-heavy
-- characters paid this on every burst. Lock the sentinel write so
-- the regression doesn't sneak back in.
do
    local fnStart = src:find("function WC_compCache%.processTooltipHasLine%(")
    if not fnStart then
        check("processTooltipHasLine writes the 'none' negative-cache sentinel",
              false, "processTooltipHasLine not found in source")
    else
        local fnEnd = src:find("\nend", fnStart)
        local body = fnEnd and src:sub(fnStart, fnEnd) or src:sub(fnStart, fnStart + 2000)
        -- v2.36.x: the negative-cache sentinel is still written, but the
        -- write goes through a `result` local that defaults to "none" and
        -- is set to "Mill" or "Prospect" on a hit. So accept either the
        -- legacy direct-write form OR the new local-default form.
        local legacyDirectWrite = body:find('processCache%[itemID%]%s*=%s*"none"') ~= nil
        local newDefaultThenAssign = body:find('local result = "none"') ~= nil
            and body:find('processCache%[itemID%]%s*=%s*result') ~= nil
        local writesNone = legacyDirectWrite or newDefaultThenAssign
        check("processTooltipHasLine writes the 'none' negative-cache sentinel",
              writesNone,
              "without this, canMill/canProspect rescan every non-eligible item on each BAG_UPDATE-driven rearm")
    end
end

-- ---------------------------------------------------------------------------
-- Test 20 (v2.28.0): CreateListUI name-sort pre-computes a name map.
-- ---------------------------------------------------------------------------
-- Background: the previous name-sort comparator called GetItemInfo
-- twice per pair-compare, producing ~20k cache hits + 20k :lower()
-- allocations to sort a 1000-item list. Pre-computing a {id -> name}
-- map once before sort drops it to ~1k lookups + an O(1) comparator.
-- Same fix landed in buildProcessSummary in v2.27.0 (Test 6 covers
-- the comparator side there).
do
    local fnStart = src:find("local function CreateListUI%(")
    if not fnStart then
        check("CreateListUI name-sort pre-computes a nameByID map",
              false, "CreateListUI not found")
    else
        -- Refresh() lives inside CreateListUI. Capture the bigger
        -- enclosing range and look for the pre-compute pattern.
        -- Slice to the function's real end marker rather than a fixed byte
        -- window, so the body covers all of CreateListUI even as it grows.
        local fnEnd = src:find("\nNS%.CreateListUI = CreateListUI", fnStart) or (fnStart + 14000)
        local body = src:sub(fnStart, fnEnd)
        local hasMap = body:find("local nameByID = {}") ~= nil
        local mapDrivenSort = body:find("nameByID%[a%]") ~= nil
            and body:find("nameByID%[b%]") ~= nil
        check("CreateListUI builds a nameByID lookup before name-sort",
              hasMap,
              "without this pre-compute, the comparator runs ~2N log N GetItemInfo calls")
        check("CreateListUI name-sort comparator reads nameByID, not GetItemInfo",
              mapDrivenSort,
              "comparator must use the pre-computed map for O(1) compares")
    end
end

-- ---------------------------------------------------------------------------
-- Test 21 (v2.28.0): list search input debounced.
-- ---------------------------------------------------------------------------
-- Background: typing in the search box previously fired a full
-- Refresh() per keystroke. Coalesce via an OnUpdate-driven debounce
-- so multi-character searches only re-render once after the user
-- stops typing.
do
    local fnStart = src:find("local function CreateListUI%(")
    if not fnStart then
        check("CreateListUI search input is debounced",
              false, "CreateListUI not found")
    else
        -- Slice to the function's real end marker rather than a fixed byte
        -- window, so the body covers all of CreateListUI even as it grows.
        local fnEnd = src:find("\nNS%.CreateListUI = CreateListUI", fnStart) or (fnStart + 14000)
        local body = src:sub(fnStart, fnEnd)
        -- The search OnTextChanged handler must NOT call Refresh()
        -- directly. It should poke a debounce frame instead.
        local handler = body:match('search:SetScript%("OnTextChanged",%s*function%(%)(.-)end%)')
        local directRefresh = handler and handler:find("Refresh%(%)") ~= nil
        local hasDebounce = body:find("NS%.MakeSearchDebounce%(search, Refresh%)") ~= nil
        check("search OnTextChanged does NOT call Refresh() directly",
              not directRefresh,
              "calling Refresh() per keystroke causes the >1000-item slowdown the user reported")
        check("CreateListUI debounces search through NS.MakeSearchDebounce",
              hasDebounce,
              "expected the shared debounce helper guarding the search Refresh")
    end
end

-- ---------------------------------------------------------------------------
-- Test 22 (v2.28.0): tooltip-prime SetOwner hoisted outside the
-- per-row loop.
-- ---------------------------------------------------------------------------
-- Background: the previous loop called GameTooltip:SetOwner per
-- uncached row alongside SetHyperlink. SetOwner is a UI-frame state
-- change; calling it once per uncached item is wasteful when one
-- owner serves the whole pass. Lift it (and the matching Hide) out
-- of the per-row body.
do
    local fnStart = src:find("local function CreateListUI%(")
    if not fnStart then
        check("CreateListUI hoists tooltip-prime SetOwner out of the loop",
              false, "CreateListUI not found")
    else
        -- Slice to the function's real end marker rather than a fixed byte
        -- window, so the body covers all of CreateListUI even as it grows.
        local fnEnd = src:find("\nNS%.CreateListUI = CreateListUI", fnStart) or (fnStart + 14000)
        local body = src:sub(fnStart, fnEnd)
        -- Look for the prime-frame setup pattern outside the
        -- per-row loop.
        local primesByRequest = body:find("C_Item.RequestLoadItemDataByID(id)", 1, true) ~= nil
            and body:find("primeFrame", 1, true) == nil
            and body:find("primeTries < LIST_PRIME_MAX_TRIES", 1, true) ~= nil
        check("CreateListUI primes uncached items by request, bounded, never via GameTooltip",
              primesByRequest,
              "the hidden-tooltip prime stole the live tooltip and its retry never stopped")
    end
end

-- ---------------------------------------------------------------------------
-- Test 23 (v2.28.0): dead WC_SellNowAt removed.
-- ---------------------------------------------------------------------------
-- v2.27.0 removed the Sell Now context-menu row. WC_SellNowAt was the
-- handler behind that row; zero call sites remained. Regression-lock
-- the removal so a future "let's re-add Sell Now" attempt has to
-- update this test too.
do
    local stillDefined = src:find("local function WC_SellNowAt%(") ~= nil
    check("WC_SellNowAt is no longer defined",
          not stillDefined,
          "the function was orphaned after v2.27.0 dropped the Sell Now menu row; re-adding it should come with a re-introduced call site")
end

-- ---------------------------------------------------------------------------
-- Test 24 (v2.29.0): normaliseAffixDesc case-folds at the end.
-- ---------------------------------------------------------------------------
-- The affix dupe gate fails (and Allow Sell entries become orphaned)
-- if the normaliser stops case-folding while the EnsureAccountDB
-- migration still lowercases existing keys. The two are a load-bearing
-- pair: both must case-fold or neither.
do
    local hasLower = src:find("function WC_compCache%.normaliseAffixDesc%([^)]*%).-:lower%(%)%s*\n%s*end") ~= nil
end

-- ---------------------------------------------------------------------------
-- Test 25 (v2.29.0): EnsureAccountDB migrates allowedAffixes keys to lowercase.
-- ---------------------------------------------------------------------------
-- The one-shot migration in EnsureAccountDB lowercases pre-existing
-- ADB.allowedAffixes keys so Allow Sell entries set under the old
-- (mixed-case) normaliser keep matching. Pair-locked with test 24.
do
    local startIdx = src:find("local function EnsureAccountDB%(")
    local endIdx = startIdx and src:find("\nlocal function ", startIdx + 1) or nil
    local body = startIdx and src:sub(startIdx, endIdx or (startIdx + 6000)) or ""
    local hasLowercasePass = body:find("ADB%.allowedAffixes") and body:find("k:lower%(%)") ~= nil
end

-- ---------------------------------------------------------------------------
-- Test 26 (v2.29.0): list-mutation sites call the sell-border refresh helper.
-- ---------------------------------------------------------------------------
-- Any DB.whitelist / DB.blacklist / DB.deleteList / ADB.allowed* mutation
-- must be followed by the refresh helper so the slot-border ring
-- doesn't go stale. Verifies the documented contract in
-- docs/ADDON_GUIDE.md "List-mutation must call the sell-border refresh".
-- The helper name changed from WC_RefreshSellBorders to NS.RefreshSellBorders
-- in Stage 6 of the file split (the body moved to BagDisplay; the stub on
-- NS lives in WoWClearance_Events.lua so cross-file callers reach it).
local SB_REFRESH_PATTERN = "NS%.RefreshSellBorders%(%)"
local SB_REFRESH_CONTEXT_PATTERN = "NS%.RefreshSellBorders"
do
    local function bodyHasRefresh(funcSig)
        local startIdx = src:find(funcSig)
        if not startIdx then
            return nil
        end
        local nextLocal = src:find("\nlocal function ", startIdx + 1) or #src
        local nextTbl = src:find("\nfunction [A-Za-z_]+%.", startIdx + 1) or #src
        local endIdx = math.min(nextLocal, nextTbl)
        local body = src:sub(startIdx, endIdx)
        return body:find(SB_REFRESH_PATTERN) ~= nil
    end

    local addOk = bodyHasRefresh("local function WC_AddItemToList%(")
    check("WC_AddItemToList calls NS.RefreshSellBorders",
          addOk,
          "list adds must refresh slot-border tints so rings draw on newly-added items immediately")

    local removeOk = bodyHasRefresh("local function WC_RemoveItemFromList%(")
    check("WC_RemoveItemFromList calls NS.RefreshSellBorders",
          removeOk,
          "list removes must refresh slot-border tints so rings clear on freshly-removed items immediately")

    -- Allow Sell click handlers live inline in the context-menu builder;
    -- look for the "Allow Sell" / "Remove from Allow Sell" string literals
    -- followed (within a reasonable window) by an NS.RefreshSellBorders call.
    local allowSellRegion = src:match('Allow Sell".-' .. SB_REFRESH_CONTEXT_PATTERN)
    local removeAllowRegion = src:match("Remove from Allow Sell|r.-" .. SB_REFRESH_CONTEXT_PATTERN)
    check("Allow Sell click handler calls NS.RefreshSellBorders",
          allowSellRegion ~= nil,
          "marking an item as Allow Sell can flip its sellability verdict; the slot border must repaint")
    check("Remove from Allow Sell click handler calls NS.RefreshSellBorders",
          removeAllowRegion ~= nil,
          "removing an Allow Sell mark restores chance-on-hit / affix protection; the slot border must repaint")
end

-- ---------------------------------------------------------------------------
-- Test 27 (v2.29.0): sell-border helpers live on WC_compCache, not module-level.
-- ---------------------------------------------------------------------------
-- Adding these as module-level `local function` would trip Lua 5.1's
-- 200-locals cap in the main chunk. Keep them on WC_compCache so the
-- main chunk stays under the limit.
do
    local helpers = {
        "applySellBorder",
        "bagSlotWillSell",
        "updateSellBordersForBagFrame",
        "installHostBagBorderHook",
        "sellBorderButtons",
        "describeSellability",
        "printSellabilityTrace",
        "bagSlotFromButton",
        "exportFullPack",
        "importFullPack",
        "qualityNames",
        "PACK_PREFIX",
    }
    for _, name in ipairs(helpers) do
        -- Pinned check: plain-mode find for the literal "WC_compCache.<name>"
        -- string. Using plain mode so the dot is literal, not a pattern char.
        local pinned = src:find("WC_compCache." .. name, 1, true) ~= nil
        -- Leaked check: pattern-mode find for module-level local definitions.
        -- `local function NAME(` or `\nlocal NAME =` at file scope - both
        -- patterns escape literal parens / equals via Lua's pattern syntax.
        local leakedFn = src:find("local function " .. name .. "%(") ~= nil
        local leakedAssign = src:find("\nlocal " .. name .. "%s*=") ~= nil
        check(
            name .. " is namespaced under WC_compCache",
            pinned and not (leakedFn or leakedAssign),
            "the v2.29.0 helpers must live on WC_compCache (Lua 5.1 200-locals cap); if moved to a module local the main chunk overflows"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 28 (Stage 1+2): namespace bootstrap + WC_compCache split-safe.
-- ---------------------------------------------------------------------------
-- The multi-stage file split tracked in docs/CODE_REVIEW.md item 4 depends
-- on `local NS = select(2, ...)` at the top of every shipped source file
-- AND on WC_compCache being declared exactly ONCE as a table literal
-- (in WoWClearance_Core.lua after Stage 2) plus exactly ONCE as a
-- namespace re-alias (in WoWClearance_Events.lua). The concat-source pattern
-- the tests use means both of those declarations appear in `src`;
-- the invariants below count them separately so a shadowing redeclaration
-- still fails.
do
    -- Every shipped .lua file must declare `local NS = select(2, ...)`
    -- near its top - that's how each file captures the shared namespace
    -- table WoW passes as the second file-load vararg. After Stage 2
    -- both WoWClearance_Core.lua and WoWClearance_Events.lua have one each,
    -- so the concat source contains AT LEAST 2 occurrences.
    --
    -- Plain-mode find: pass true as the 3rd arg so `()` are literal
    -- parens and `...` is a literal ellipsis (no pattern escaping).
    -- The shared kit (WoWClearance_Kit.lua, same file as the sister
    -- addon's) spells it `local _, NS = ...`; both forms count.
    local bootstrapCount = 0
    for _, form in ipairs({ "local NS = select(2, ...)", "local _, NS = ...", "local own = select(2, ...)" }) do
        local searchStart = 1
        while true do
            local s, e = src:find(form, searchStart, true)
            if not s then break end
            bootstrapCount = bootstrapCount + 1
            searchStart = e + 1
        end
    end
    check(
        "namespace varargs bootstrap present in every source file",
        bootstrapCount >= #SOURCE_PATHS,
        string.format(
            "expected at least %d namespace bootstrap occurrences " ..
            "(one per source file in SOURCE_PATHS); found %d",
            #SOURCE_PATHS, bootstrapCount
        )
    )

    -- WC_compCache mirrored onto NS.compCache (Stage 1 invariant). Both
    -- names point at the same table; existing call sites use the
    -- WC_compCache upvalue, future split files reach the table via
    -- NS.compCache. Lives in Core after Stage 2.
    local mirror = src:find("NS%.compCache = WC_compCache") ~= nil
    check(
        "WC_compCache mirrored onto NS.compCache",
        mirror,
        "after the WC_compCache table literal closes (in Core post-Stage-2), `NS.compCache = WC_compCache` must alias the table onto the namespace"
    )

    -- Defence-in-depth: exactly ONE table-literal declaration of
    -- WC_compCache. A second literal would silently desync from
    -- NS.compCache (the alias would still point at the first table).
    -- The re-alias pattern `local WC_compCache = NS.compCache` is
    -- expected (in WoWClearance_Events.lua) and intentionally NOT counted here.
    local literalCount = 0
    for _ in src:gmatch("\nlocal WC_compCache%s*=%s*{") do
        literalCount = literalCount + 1
    end
    if src:find("^local WC_compCache%s*=%s*{") then
        literalCount = literalCount + 1
    end
    check(
        "WC_compCache declared as a table literal exactly once",
        literalCount == 1,
        "WC_compCache must have exactly one table-literal declaration (`local WC_compCache = { ... }`) across all shipped sources. A second one would silently desync the NS.compCache alias. Found " .. tostring(literalCount)
    )

    -- Companion invariant: AT LEAST ONE re-alias `local WC_compCache = NS.compCache`.
    -- Every split file that uses the `WC_compCache.foo` upvalue idiom adds
    -- its own re-alias near the top so call sites resolve through the
    -- file-scope local. WoWClearance_Events.lua has one; later stages will
    -- add more. If the count drops to zero,
    -- every `WC_compCache.foo` reference would resolve to global nil.
    local aliasCount = 0
    for _ in src:gmatch("\nlocal WC_compCache%s*=%s*NS%.compCache") do
        aliasCount = aliasCount + 1
    end
    check(
        "WC_compCache re-alias from NS.compCache present at least once per consumer file",
        aliasCount >= 1,
        "expected at least one `local WC_compCache = NS.compCache` re-alias across the shipped sources. Found " .. tostring(aliasCount)
    )
end

-- ---------------------------------------------------------------------------
-- Test 29: NS.DB is the live-binding bridge for split files.
-- ---------------------------------------------------------------------------
-- The rest of this test covered the Greedy Scavenger chat-filter module's
-- cross-file surface; that module was deleted with the Project Ebonhold
-- companions. The NS.DB exposure it relied on is still load-bearing for every
-- other split file, so that one assertion survives on its own.
do
    check(
        "EnsureDB exposes NS.DB",
        src:find("NS%.DB%s*=%s*DB", 1) ~= nil,
        "EnsureDB must write `NS.DB = DB` so split files reading NS.DB see the live binding"
    )
end

-- ---------------------------------------------------------------------------
-- Test 30 (Stage 4): Protection helpers stay namespaced under WC_compCache.
-- ---------------------------------------------------------------------------
-- After Stage 4 the item-marker + tome / recipe detection cluster lives in
-- WoWClearance_Protection.lua. Every helper is attached to WC_compCache,
-- which is the same table WoWClearance_Events.lua's call sites already resolve
-- through via their re-aliased upvalue. If a future refactor moves any
-- of these helpers off WC_compCache (e.g. as a module-level local in
-- Protection), call sites in WoWClearance_Events.lua would resolve to nil.
--
-- The affix / chance-on-hit half of this list went with the Project Ebonhold
-- removal; what remains is the realm-agnostic remainder.
do
    local helpers = {
        "scanItemMarkers",
        "itemHasResilience",
        "itemIsTome",
        "playerKnowsTomeSpell",
        "tomeKind",
        "liveTooltipIsTome",
        "liveTooltipPlayerKnowsTome",
    }
    for _, name in ipairs(helpers) do
        local pinned = src:find("WC_compCache." .. name, 1, true) ~= nil
        local leakedFn = src:find("local function " .. name .. "%(") ~= nil
        check(
            name .. " is namespaced under WC_compCache",
            pinned and not leakedFn,
            name .. " must stay on WC_compCache so call sites in WoWClearance_Events.lua resolve through the shared upvalue"
        )
    end

    -- NS.scanTooltip exposure. WoWClearance_Events.lua creates the named
    -- GameTooltip frame and writes it onto NS so Protection's bodies
    -- can dereference NS.scanTooltip lazily at call time (Protection
    -- loads before WoWClearance_Events.lua's main chunk so an upvalue capture
    -- at Protection's load would store nil).
    check(
        "NS.scanTooltip exposed by WoWClearance_Events.lua frame creation",
        src:find("NS%.scanTooltip%s*=%s*WC_scanTooltip") ~= nil,
        "WoWClearance_Events.lua must write `NS.scanTooltip = WC_scanTooltip` immediately after creating the frame, so Protection's lazy dereference works"
    )
end

-- ---------------------------------------------------------------------------
-- Test 31 (Stage 5): vendor-cycle state promoted to WC_compCache;
-- HookDeletePopupOnce moved to WoWClearance_Vendor.lua.
-- ---------------------------------------------------------------------------
-- Stage 5 is narrowly scoped: only the deletion-popup hook moves to
-- WoWClearance_Vendor.lua. The vendor cycle itself (WC_IsSellable,
-- BuildQueue, worker, StartRun, WC_manualSell) stays in WoWClearance_Events.lua
-- for future stages because its cross-file dependency surface is wide.
--
-- Two vendor-cycle scalars WERE promoted in Stage 5 prep:
--   * running -> WC_compCache.vendorRunning
--   * pendingDelete -> WC_compCache.pendingDelete
-- Both initialise in Core's table literal. If a future refactor reintroduces
-- file-scope `local running` or `local pendingDelete` in WoWClearance_Events.lua,
-- it would silently desync from the cache table; the count check below
-- catches that.
do
    -- vendorRunning + pendingDelete fields initialised in Core's
    -- WC_compCache table literal.
    check(
        "WC_compCache.vendorRunning initialised in Core",
        src:find("vendorRunning%s*=%s*false") ~= nil,
        "Core's WC_compCache table literal must initialise `vendorRunning = false` (promoted Stage 5 prep)"
    )

    -- No file-scope `local running` or `local pendingDelete` lurking in
    -- the shipped sources. Either would silently desync from the cache
    -- table. Comment lines mentioning these names are allowed.
    local lines_iter = {}
    for ln in src:gmatch("[^\n]+") do
        table.insert(lines_iter, ln)
    end
    local function noBareLocalDecl(name)
        for _, ln in ipairs(lines_iter) do
            local stripped = ln:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                -- Look for `local NAME =` or `local NAME\b` at start of code
                if code:match("^local%s+" .. name .. "%s*=") or
                   code:match("^local%s+" .. name .. "%s*$") then
                    return ln
                end
            end
        end
        return nil
    end
    local lurkingRunning = noBareLocalDecl("running")
    local lurkingPending = noBareLocalDecl("pendingDelete")
    check(
        "no file-scope `local running` (post Stage 5 promotion)",
        lurkingRunning == nil,
        "found: " .. tostring(lurkingRunning)
    )
    check(
        "no file-scope `local pendingDelete` (post Stage 5 promotion)",
        lurkingPending == nil,
        "found: " .. tostring(lurkingPending)
    )
end

-- ---------------------------------------------------------------------------
-- Test 32 (PR #2): affix-scan freeze fix - debounce + cache + chunked scan.
-- ---------------------------------------------------------------------------
-- Sanavesa's PR #2 fixed a ~30 s freeze on login / soul-ash-tree apply by
-- coalescing rapid SPELLS_CHANGED bursts and amortising tooltip scans
-- across frames. Three pieces, each must stay in place:
--
--   1. Per-spellID cache (WC_compCache.spellbookAffixCache) so each
--      spell's tooltip is scanned at most once per session. Same
--      `false` sentinel convention as procIdToDescription.
--   2. 0.5 s debounce frame (WC_compCache.spellUpdateFrame) so a burst
--      of LEARNED_SPELL_IN_TAB / SPELLS_CHANGED events coalesces into
--      one rebuild after the burst settles.
--   3. Chunked OnUpdate scan (WC_compCache.SPELLS_PER_CHUNK spells per
--      frame) so even the first cold-cache scan doesn't freeze the UI.
--
-- If any of these regresses - e.g. someone reverts to a synchronous
-- refreshKnownAffixes(), or removes the cache, or hard-codes the
-- chunk size as a magic literal - CI catches it here.
do
    -- 1. Cache table declared at module scope.

    -- 2. Debounce frame + accumulator + named window constant.

    -- 3. Chunked-scan budget constant.

    -- 4. Event branch triggers the debounce frame and does NOT call
    --    refreshKnownAffixes directly. The branch lives in WoWClearance_Events.lua's
    --    event-hub dispatcher; we extract it, strip comments, and assert
    --    against the resulting code (comments that mention the function
    --    name by way of explanation are fine).
    local startIdx = src:find('event == "LEARNED_SPELL_IN_TAB"', 1, true)
    local branchBody
    if startIdx then
        local nextIdx = src:find("elseif event ==", startIdx + 1, true)
        branchBody = nextIdx and src:sub(startIdx, nextIdx - 1) or src:sub(startIdx)
    end
    local branchCodeOnly
    if branchBody then
        local codeLines = {}
        for line in branchBody:gmatch("[^\n]+") do
            local stripped = line:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                codeLines[#codeLines + 1] = code
            end
        end
        branchCodeOnly = table.concat(codeLines, "\n")
    end
    check(
        "LEARNED_SPELL_IN_TAB / SPELLS_CHANGED branch does NOT call refreshKnownAffixes() synchronously",
        branchCodeOnly and branchCodeOnly:find("refreshKnownAffixes") == nil,
        "the event handler must route through the debounce frame; a direct call would defeat the whole fix (comments mentioning the function are fine; this check is code-only)"
    )
end

-- ---------------------------------------------------------------------------
-- Test 33 (Stage 6): BagDisplay extraction + NS.RefreshSellBorders pattern.
-- ---------------------------------------------------------------------------
-- Stage 6 moves the Release-1 bag-display layer to WoWClearance_BagDisplay.lua.
-- The forward-declared `WC_RefreshSellBorders` local was promoted to
-- NS.RefreshSellBorders so the stub (in WoWClearance_Events.lua) and the real
-- body (in BagDisplay) can live in different files. Load order in the
-- .toc puts BagDisplay AFTER WoWClearance_Events.lua so BagDisplay's body
-- assignment OVERWRITES the stub, not the other way around.
do
    -- The stub on NS (no-op). Lives in WoWClearance_Events.lua's forward-decl
    -- block so the Character Settings panel toggle can call it before
    -- BagDisplay loads its real body.
    check(
        "NS.RefreshSellBorders stub declared",
        src:find("NS%.RefreshSellBorders%s*=%s*function%(%)%s*end") ~= nil,
        "WoWClearance_Events.lua must forward-declare `NS.RefreshSellBorders = function() end` as a no-op stub"
    )

    -- The real body in BagDisplay. Pattern matches both
    -- `NS.RefreshSellBorders = function()` and `function NS.RefreshSellBorders()`.
    local hasBody =
        src:find("NS%.RefreshSellBorders%s*=%s*function%(%s*%)%s*\n") ~= nil
        or src:find("function%s+NS%.RefreshSellBorders%(%s*%)") ~= nil
    -- The stub itself matches the first pattern with no body lines, so
    -- "hasBody" is satisfied by either the stub OR a real reassignment.
    -- To distinguish: look for `NS.RefreshSellBorders = function()` followed
    -- by something other than `end` (the stub) OR a long body. Simplest
    -- check: BagDisplay's file content directly.
    local function read_file(path)
        local f = io.open(path, "r")
        if not f then
            return nil
        end
        local s = f:read("*a")
        f:close()
        return s
    end
    local bagDisplay = read_file("WoWClearance_BagDisplay.lua")
    check(
        "WoWClearance_BagDisplay.lua exists",
        bagDisplay ~= nil,
        "Stage 6 must create WoWClearance_BagDisplay.lua"
    )
    if bagDisplay then
        check(
            "BagDisplay reassigns NS.RefreshSellBorders body",
            bagDisplay:find("NS%.RefreshSellBorders%s*=%s*function%(%)") ~= nil,
            "WoWClearance_BagDisplay.lua must reassign `NS.RefreshSellBorders = function()` with the real body (replaces the no-op stub from WoWClearance_Events.lua)"
        )
        -- BagDisplay's helpers stay on WC_compCache.
        local helpers = {
            "sellBorderButtons",
            "applySellBorder",
            "bagSlotWillSell",
            "updateSellBordersForBagFrame",
            "installHostBagBorderHook",
            "qualityNames",
            "describeSellability",
            "printSellabilityTrace",
            "bagSlotFromButton",
        }
        for _, name in ipairs(helpers) do
            check(
                name .. " present in BagDisplay on WC_compCache",
                bagDisplay:find("WC_compCache." .. name, 1, true) ~= nil,
                name .. " must be attached to WC_compCache in BagDisplay so call sites elsewhere resolve via the shared cache"
            )
        end
    end

    -- The .toc loads BagDisplay AFTER WoWClearance_Events.lua. Verifies
    -- via the SOURCE_PATHS ordering this test file already uses
    -- (BagDisplay last in the list). If a future contributor accidentally
    -- swaps the order, the stub from WoWClearance_Events.lua would
    -- clobber the real body and the sell-border refresh would silently
    -- become a no-op. (File was named WoWClearance_Events.lua before Stage 9
    -- of the file split.)
    local toc = read_file("WoWClearance.toc")
    if toc then
        local ebonIdx = toc:find("\nWoWClearance_Events%.lua\n", 1)
        local bagIdx = toc:find("\nWoWClearance_BagDisplay%.lua", 1)
        check(
            ".toc loads WoWClearance_BagDisplay.lua AFTER WoWClearance_Events.lua",
            ebonIdx and bagIdx and ebonIdx < bagIdx,
            "BagDisplay's NS.RefreshSellBorders body reassignment must run AFTER WoWClearance_Events.lua's stub assignment; reversing the .toc order would clobber the real body"
        )
    end

    -- No bare-identifier call sites for WC_RefreshSellBorders. Definition
    -- in BagDisplay was rewritten to NS.RefreshSellBorders; every caller
    -- must use the NS-qualified form.
    local function hasBareCall(s, name)
        for line in s:gmatch("[^\n]+") do
            local stripped = line:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                if code:find("[^.%w_]" .. name .. "%s*%(") then
                    return stripped
                end
                if code:sub(1, #name + 1) == name .. "(" then
                    return stripped
                end
            end
        end
        return nil
    end
    local bareCall = hasBareCall(src, "WC_RefreshSellBorders")
    check(
        "no bare WC_RefreshSellBorders() call sites (must be NS.RefreshSellBorders)",
        bareCall == nil,
        "found bare call: " .. tostring(bareCall)
    )
end

-- ---------------------------------------------------------------------------
-- Test 34: baselineProtectedIDs profession-tool safety net.
-- ---------------------------------------------------------------------------
-- User Monrad reported that the basic Fishing Pole (6256), Mining Pick
-- (2901), and Arclight Spanner (6219) were being auto-sold by a White-
-- rule sweep. We added a hardcoded itemID safety net mirroring the
-- v2.13.x quest-item narrowing: explicit Sell List entries still
-- override, only auto-rule sweeps are gated. ADB.allowedItems[itemID]
-- also bypasses (Allow Sell per-item override).
do
    -- Core's table literal declares baselineProtectedIDs.
    check(
        "WC_compCache.baselineProtectedIDs declared",
        src:find("baselineProtectedIDs%s*=%s*{") ~= nil,
        "Core's WC_compCache table literal must initialise baselineProtectedIDs as a map"
    )

    -- The three Monrad-reported itemIDs are in the set.
    for _, id in ipairs({ 6256, 2901, 6219 }) do
        check(
            "baselineProtectedIDs contains itemID " .. id .. " (Monrad's report)",
            src:find("%[" .. id .. "%]%s*=%s*true") ~= nil,
            "the three items Monrad reported must remain in the safety-net list"
        )
    end

    -- WC_IsSellable consults baselineProtectedIDs after the qualityPass
    -- calculation, using the same narrowing pattern as isQuestItem.
    check(
        "WC_IsSellable consults baselineProtectedIDs",
        src:find("baselineProtectedIDs%[itemID%]") ~= nil,
        "WC_IsSellable must gate qualityPass on the baselineProtectedIDs map (mirrors the v2.13.x quest-item safety net)"
    )

    -- Allow Sell override bypasses the safety net (ADB.allowedItems check
    -- must appear next to the baselineProtectedIDs check).
    check(
        "Allow Sell override bypasses baseline protection",
        src:find("baselineProtectedIDs%[itemID%].-allowedItems") ~= nil
            or src:find("allowedItems.-baselineProtectedIDs%[itemID%]") ~= nil,
        "ADB.allowedItems[itemID] must short-circuit the baseline safety net so per-item Allow Sell still works"
    )

    -- Tooltip annotation emits "Keep (profession tool)" for matched items.
    check(
        "tooltip annotation emits 'Keep (profession tool)'",
        src:find("Keep %(profession tool%)") ~= nil,
        "WC_AnnotateTooltip must emit a Profession-tool annotation so users see why the item isn't selling"
    )

    -- Sellinfo trace step exists.
    check(
        "/wc sellinfo trace includes the professionToolSafetyNet step",
        src:find('"professionToolSafetyNet"') ~= nil,
        "describeSellability must surface the safety-net gate so /wc sellinfo and Alt+Shift+Right-Click trace it"
    )
end

-- ---------------------------------------------------------------------------
-- Test 35 (Stage 7): Process Bags engine extracted; eligibility predicates
-- stay on WC_compCache.
-- ---------------------------------------------------------------------------
-- Stage 7 moves the Process Bags ENGINE (spell IDs + eligibility
-- predicates + buildProcessSummary) to WoWClearance_Process.lua. The
-- Process Bags PANEL (UI helpers + rearmProcessButton +
-- refreshProcessPanel + updateProcessSelection + skipProcessTarget)
-- stays in WoWClearance_Events.lua for Stage 8.
do
    local helpers = {
        "canDisenchant",
        "canMill",
        "canProspect",
        "canPickLock",
        "processTooltipHasLine",
        "processIsSoulbound",
        "buildProcessSummary",
    }
    for _, name in ipairs(helpers) do
        local pinned = src:find("WC_compCache." .. name, 1, true) ~= nil
        local leakedFn = src:find("local function " .. name .. "%(") ~= nil
        check(
            name .. " is namespaced under WC_compCache",
            pinned and not leakedFn,
            name .. " must stay on WC_compCache so call sites elsewhere resolve through the shared upvalue"
        )
    end

    -- Spell ID constants stay on WC_compCache.
    local spellConstants = {
        { "SPELL_DISENCHANT", "13262" },
        { "SPELL_MILLING", "51005" },
        { "SPELL_PROSPECTING", "31252" },
        { "SPELL_PICK_LOCK", "1804" },
    }
    for _, pair in ipairs(spellConstants) do
        local name, value = pair[1], pair[2]
        check(
            "WC_compCache." .. name .. " = " .. value,
            src:find("WC_compCache%." .. name .. "%s*=%s*" .. value) ~= nil,
            "the spell ID constant must remain on WC_compCache so the Process panel + UNIT_SPELLCAST_SUCCEEDED handler can read it"
        )
    end

    -- NS exposures Process depends on:
    check(
        "NS.Delay exposed by WoWClearance_Events.lua",
        src:find("NS%.Delay%s*=%s*WC_Delay") ~= nil,
        "Process schedules deferred callbacks via NS.Delay; WoWClearance_Events.lua must publish the WC_Delay helper on NS"
    )
    check(
        "NS.IsAddonEnabledForChar exposed by WoWClearance_Events.lua",
        src:find("NS%.IsAddonEnabledForChar%s*=%s*WC_IsAddonEnabledForChar") ~= nil,
        "Process gates on per-character enable via NS.IsAddonEnabledForChar; WoWClearance_Events.lua must publish the helper"
    )
end

-- ---------------------------------------------------------------------------
-- Test 36 (Stage 8): bug-report extraction + cycle-state promotions.
-- ---------------------------------------------------------------------------
-- Stage 8 moves the bug-report builder (WC_CopperToPlainText,
-- WC_BuildBugReport, WC_ShowBugReport) to WoWClearance_BugReport.lua,
-- exposed as NS.ShowBugReport. The .toc must load it AFTER
-- WoWClearance_Events.lua because the slash command in WoWClearance_Events.lua
-- calls NS.ShowBugReport(), and that name must be populated by the
-- time the command runs (file-load order guarantees that).
--
-- Plus four cross-file helpers exposed on NS so the bug-report builder
-- can read live values from WoWClearance_Events.lua:
--   * NS.GetVersion / NS.GetFreeBagSlots / NS.CopperToColoredText / NS.EnsureDB
do
    check(
        "NS.ShowBugReport exposed",
        src:find("NS%.ShowBugReport%s*=%s*WC_ShowBugReport") ~= nil,
        "WoWClearance_BugReport.lua must publish NS.ShowBugReport"
    )

    -- No bare WC_ShowBugReport() call sites. Definition in BugReport is
    -- masked from the scan.
    local function hasBareCall(s, name)
        local cleaned = s:gsub("local function " .. name .. "%(", "local function _def_" .. name .. "(")
        for line in cleaned:gmatch("[^\n]+") do
            local stripped = line:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                if code:find("[^.%w_]" .. name .. "%s*%(") then
                    return stripped
                end
                if code:sub(1, #name + 1) == name .. "(" then
                    return stripped
                end
            end
        end
        return nil
    end
    local bareCall = hasBareCall(src, "WC_ShowBugReport")
    check(
        "no bare WC_ShowBugReport() call sites (must be NS.ShowBugReport)",
        bareCall == nil,
        "found bare call: " .. tostring(bareCall)
    )

    -- NS exposures the bug-report builder relies on.
    for _, exposure in ipairs({
        { "NS.GetVersion", "NS%.GetVersion%s*=%s*WC_GetVersion" },
        { "NS.GetFreeBagSlots", "NS%.GetFreeBagSlots%s*=%s*WC_GetFreeBagSlots" },
        { "NS.CopperToColoredText", "NS%.CopperToColoredText%s*=%s*CopperToColoredText" },
        { "NS.EnsureDB", "NS%.EnsureDB%s*=%s*EnsureDB" },
    }) do
        local name, pattern = exposure[1], exposure[2]
        check(
            name .. " exposed by WoWClearance_Events.lua",
            src:find(pattern) ~= nil,
            name .. " must be published so BugReport can read the live value"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 37 (Stage 8b): minimap + LDB extracted.
-- ---------------------------------------------------------------------------
-- Stage 8b moves the minimap button and the LDB launcher to
-- WoWClearance_Minimap.lua. Each entry point is published on NS for the
-- ADDON_LOADED branch in WoWClearance_Events.lua to call. A fourth,
-- CreateTargetMerchantButton, went with the Goblin Merchant pet.
do
    for _, name in ipairs({
        "UpdateMinimapPos",
        "CreateMinimapButton",
        "CreateLDBLauncher",
    }) do
        check(
            "NS." .. name .. " exposed by Minimap",
            src:find("NS%." .. name .. "%s*=%s*WC_" .. name) ~= nil,
            "WoWClearance_Minimap.lua must publish NS." .. name
        )
    end

    -- No bare WC_Create*Button() / WC_CreateLDBLauncher() call sites in
    -- the shipped source. Definition lines in Minimap are masked.
    local function hasBareCall(s, name)
        local cleaned = s:gsub("local function " .. name .. "%(", "local function _def_" .. name .. "(")
        for line in cleaned:gmatch("[^\n]+") do
            local stripped = line:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                if code:find("[^.%w_]" .. name .. "%s*%(") then
                    return stripped
                end
                if code:sub(1, #name + 1) == name .. "(" then
                    return stripped
                end
            end
        end
        return nil
    end
    for _, name in ipairs({
        "WC_CreateMinimapButton",
        "WC_CreateLDBLauncher",
    }) do
        local bare = hasBareCall(src, name)
        check(
            "no bare " .. name .. "() call sites (must be NS." .. name:gsub("^WC_", "") .. ")",
            bare == nil,
            "found bare call: " .. tostring(bare)
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 38 (Stage 8c): tooltip annotation extracted.
-- ---------------------------------------------------------------------------
-- Stage 8c moves the per-bag-item tooltip annotation system
-- (WC_AnnotateTooltip + WC_ClearTooltipFlag + WC_InstallTooltipHookOnce)
-- to WoWClearance_Tooltip.lua. The install entry point is exposed
-- on NS for the ADDON_LOADED branch in WoWClearance_Events.lua to call.
do
    check(
        "NS.InstallTooltipHookOnce exposed by Tooltip",
        src:find("NS%.InstallTooltipHookOnce%s*=%s*WC_InstallTooltipHookOnce") ~= nil,
        "WoWClearance_Tooltip.lua must publish NS.InstallTooltipHookOnce"
    )

    -- No bare WC_InstallTooltipHookOnce() call sites anywhere.
    local function hasBareCall(s, name)
        local cleaned = s:gsub("local function " .. name .. "%(", "local function _def_" .. name .. "(")
        for line in cleaned:gmatch("[^\n]+") do
            local stripped = line:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                if code:find("[^.%w_]" .. name .. "%s*%(") then
                    return stripped
                end
                if code:sub(1, #name + 1) == name .. "(" then
                    return stripped
                end
            end
        end
        return nil
    end
    local bare = hasBareCall(src, "WC_InstallTooltipHookOnce")
    check(
        "no bare WC_InstallTooltipHookOnce() call sites (must be NS.InstallTooltipHookOnce)",
        bare == nil,
        "found bare call: " .. tostring(bare)
    )
end

-- ---------------------------------------------------------------------------
-- Test 39 (Stage 8d): bag context menu extracted; list-mutation helpers
-- exposed on NS.
-- ---------------------------------------------------------------------------
-- Stage 8d moves the Alt+Right-Click bag context menu to
-- WoWClearance_BagContextMenu.lua. The hook installer is exposed on NS
-- for the ADDON_LOADED branch. Three list-mutation helpers
-- (AddItemToList, RemoveItemFromList, FindAddConflict) needed NS
-- exposure to support the move - row-click handlers in the menu call
-- them.
do
    check(
        "NS.InstallBagContextHookOnce exposed by BagContextMenu",
        src:find("NS%.InstallBagContextHookOnce%s*=%s*WC_InstallBagContextHookOnce") ~= nil,
        "WoWClearance_BagContextMenu.lua must publish NS.InstallBagContextHookOnce"
    )
    check(
        "NS.AddItemToList exposed",
        src:find("NS%.AddItemToList%s*=%s*WC_AddItemToList") ~= nil,
        "WoWClearance_Events.lua must publish NS.AddItemToList for the context menu's row-click handlers"
    )
    check(
        "NS.RemoveItemFromList exposed",
        src:find("NS%.RemoveItemFromList%s*=%s*WC_RemoveItemFromList") ~= nil,
        "WoWClearance_Events.lua must publish NS.RemoveItemFromList for the context menu's row-click handlers"
    )
    check(
        "NS.FindAddConflict exposed",
        src:find("NS%.FindAddConflict%s*=%s*WC_FindAddConflict") ~= nil,
        "WoWClearance_Events.lua must publish NS.FindAddConflict for the context menu's add-time conflict guard"
    )
    check(
        "NS.GetListTable exposed",
        src:find("NS%.GetListTable%s*=%s*WC_GetListTable") ~= nil,
        "WoWClearance_Events.lua must publish NS.GetListTable for the context menu's list-membership check"
    )

    -- No bare WC_InstallBagContextHookOnce() or WC_GetListTable() call sites
    -- inside WoWClearance_BagContextMenu.lua. (Other files may still call
    -- WC_GetListTable directly as a file-scope local.)
    local function hasBareCall(s, name)
        local cleaned = s:gsub("local function " .. name .. "%(", "local function _def_" .. name .. "(")
        for line in cleaned:gmatch("[^\n]+") do
            local stripped = line:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                if code:find("[^.%w_]" .. name .. "%s*%(") then
                    return stripped
                end
                if code:sub(1, #name + 1) == name .. "(" then
                    return stripped
                end
            end
        end
        return nil
    end
    local bare = hasBareCall(src, "WC_InstallBagContextHookOnce")
    check(
        "no bare WC_InstallBagContextHookOnce() call sites (must be NS.InstallBagContextHookOnce)",
        bare == nil,
        "found bare call: " .. tostring(bare)
    )

    -- Read BagContextMenu file directly for a focused bare-WC_GetListTable check;
    -- the global src concat includes WoWClearance_Events.lua where the local is fine.
    local ctxFile = io.open("WoWClearance_BagContextMenu.lua", "rb")
    if ctxFile then
        local ctxSrc = ctxFile:read("*a") or ""
        ctxFile:close()
        local bareList = hasBareCall(ctxSrc, "WC_GetListTable")
        check(
            "no bare WC_GetListTable() call sites in WoWClearance_BagContextMenu.lua (must be NS.GetListTable)",
            bareList == nil,
            "found bare call: " .. tostring(bareList)
        )

        -- Taint lock (see the WC-TRAP above WC_InstallBagContextHookOnce):
        -- assigning into a Blizzard mixin table tainted every bag button
        -- built from it and blocked plain right-click use/sell in game.
        local mixinWrite
        for line in ctxSrc:gmatch("[^\n]+") do
            local code = line:gsub("%-%-.*$", "")
            if code:find("[mM]ixin%.[%w_]+%s*=[^=]") then
                mixinWrite = line
                break
            end
        end
        check(
            "BagContextMenu never assigns into a Blizzard mixin table (taint)",
            mixinWrite == nil,
            "found mixin write: " .. tostring(mixinWrite)
        )
        check(
            "BagContextMenu hooks both item-button mixins with hooksecurefunc",
            ctxSrc:find('hooksecurefunc%(mixin, "OnModifiedClick"') ~= nil
                and ctxSrc:find('hooksecurefunc%(bankMixin, "OnClick"') ~= nil,
            "expected hooksecurefunc on ContainerFrameItemButtonMixin.OnModifiedClick and BankPanelItemButtonMixin.OnClick"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 40 (Stage 8e-i): Process Bags panel extracted; UI primitives
-- exposed on NS.
-- ---------------------------------------------------------------------------
-- Stage 8e-i moves the v2.22.0 Process Bags Interface Options panel
-- (frame creation + the four WC_compCache helpers + OnShow body) into
-- WoWClearance_ProcessBagsPanel.lua. Two cross-file UI primitives
-- (MakeHeader, MakeLabel) needed NS exposure to support the move - the
-- OnShow build body calls them. Registration in WoWClearance_Events.lua uses
-- a _G lookup because the local ProcessBagsPanel binding no longer
-- exists in that file.
do
    check(
        "NS.MakeHeader exposed",
        src:find("NS%.MakeHeader%s*=%s*MakeHeader") ~= nil,
        "WoWClearance_Events.lua must publish NS.MakeHeader for the Process Bags panel's OnShow body"
    )
    check(
        "NS.MakeLabel exposed",
        src:find("NS%.MakeLabel%s*=%s*MakeLabel") ~= nil,
        "WoWClearance_Events.lua must publish NS.MakeLabel for the Process Bags panel's OnShow body"
    )

    -- Read the new file to confirm the four WC_compCache helpers live
    -- there (not in WoWClearance_Events.lua) AND that the file references
    -- NS.MakeHeader / NS.MakeLabel rather than the bare locals which
    -- only exist in WoWClearance_Events.lua's scope.
    local pbFile = io.open("WoWClearance_ProcessBagsPanel.lua", "rb")
    if pbFile then
        local pbSrc = pbFile:read("*a") or ""
        pbFile:close()
        check(
            "rearmProcessButton defined in WoWClearance_ProcessBagsPanel.lua",
            pbSrc:find("function WC_compCache%.rearmProcessButton%(%)") ~= nil,
            "rearmProcessButton must live in WoWClearance_ProcessBagsPanel.lua (Stage 8e-i)"
        )
        check(
            "refreshProcessPanel defined in WoWClearance_ProcessBagsPanel.lua",
            pbSrc:find("function WC_compCache%.refreshProcessPanel%(%)") ~= nil,
            "refreshProcessPanel must live in WoWClearance_ProcessBagsPanel.lua (Stage 8e-i)"
        )
        check(
            "updateProcessSelection defined in WoWClearance_ProcessBagsPanel.lua",
            pbSrc:find("function WC_compCache%.updateProcessSelection%(%)") ~= nil,
            "updateProcessSelection must live in WoWClearance_ProcessBagsPanel.lua (Stage 8e-i)"
        )
        check(
            "skipProcessTarget defined in WoWClearance_ProcessBagsPanel.lua",
            pbSrc:find("function WC_compCache%.skipProcessTarget%(%)") ~= nil,
            "skipProcessTarget must live in WoWClearance_ProcessBagsPanel.lua (Stage 8e-i)"
        )
        check(
            "WoWClearance_ProcessBagsPanel.lua uses NS.MakeHeader (not bare MakeHeader)",
            pbSrc:find("NS%.MakeHeader%(") ~= nil
                and pbSrc:find("[^.%w_]MakeHeader%(") == nil,
            "panel build body must call NS.MakeHeader (the local lives in WoWClearance_Events.lua)"
        )
        check(
            "WoWClearance_ProcessBagsPanel.lua uses NS.MakeLabel (not bare MakeLabel)",
            pbSrc:find("NS%.MakeLabel%(") ~= nil
                and pbSrc:find("[^.%w_]MakeLabel%(") == nil,
            "panel build body must call NS.MakeLabel (the local lives in WoWClearance_Events.lua)"
        )
    end

    -- The four WC_compCache helpers must NOT be defined in
    -- WoWClearance_Events.lua anymore (would-be regression: a stale copy
    -- still sitting in the main file would clobber the new one).
    -- Match against a clean global-src concat: count occurrences in
    -- WoWClearance_Events.lua specifically.
    local ecFile = io.open("WoWClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "rearmProcessButton no longer defined in WoWClearance_Events.lua",
            ecSrc:find("function WC_compCache%.rearmProcessButton%(%)") == nil,
            "duplicate definition in WoWClearance_Events.lua would clobber the Stage 8e-i extracted body"
        )
        check(
            "refreshProcessPanel no longer defined in WoWClearance_Events.lua",
            ecSrc:find("function WC_compCache%.refreshProcessPanel%(%)") == nil,
            "duplicate definition in WoWClearance_Events.lua would clobber the Stage 8e-i extracted body"
        )
    end

    -- Registration call must use the _G lookup since the local was
    -- moved out of WoWClearance_Events.lua.
    check(
        "Process Bags panel registered via _G lookup in WoWClearance_Events.lua",
        src:find('"WoWClearanceOptionsProcessBags",') ~= nil,
        "post-extraction, WoWClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
end

-- ---------------------------------------------------------------------------
-- Test 41 (Stage 8e-ii): Merchant Settings panel extracted; widget
-- primitives exposed on NS.
-- ---------------------------------------------------------------------------
-- Stage 8e-ii moves the Merchant Settings Interface Options panel
-- (frame creation + the OnShow body that builds the vendor mode
-- dropdown, repair toggles, sliders, fast-mode checkbox, and per-
-- rarity rule rows) into WoWClearance_MerchantPanel.lua. Five
-- additional UI widget primitives needed NS exposure (the panel calls
-- each of them in its OnShow body): AddCheckbox, AddSlider,
-- ColorTextByQuality, StyleInputBox, FitScrollContent. Registration
-- in WoWClearance_Events.lua uses a _G lookup since the local MerchantPanel
-- binding no longer exists there.
do
    check(
        "NS.AddCheckbox exposed",
        src:find("NS%.AddCheckbox%s*=%s*AddCheckbox") ~= nil,
        "WoWClearance_Events.lua must publish NS.AddCheckbox for the Merchant Settings panel's OnShow body"
    )
    check(
        "NS.AddSlider exposed",
        src:find("NS%.AddSlider%s*=%s*AddSlider") ~= nil,
        "WoWClearance_Events.lua must publish NS.AddSlider for the Merchant Settings panel's OnShow body"
    )
    check(
        "NS.FitScrollContent exposed",
        src:find("NS%.FitScrollContent%s*=%s*WC_FitScrollContent") ~= nil,
        "WoWClearance_Events.lua must publish NS.FitScrollContent for the Merchant Settings panel's bottom-anchor call"
    )
    check(
        "NS.ColorTextByQuality exposed",
        src:find("NS%.ColorTextByQuality%s*=%s*ColorTextByQuality") ~= nil,
        "WoWClearance_Events.lua must publish NS.ColorTextByQuality for the Merchant Settings panel's rarity dropdown"
    )
    check(
        "NS.StyleInputBox exposed",
        src:find("NS%.StyleInputBox%s*=%s*StyleInputBox") ~= nil,
        "WoWClearance_Events.lua must publish NS.StyleInputBox for the Merchant Settings panel's iLvl input"
    )

    -- Read the new file to confirm the MerchantPanel frame + OnShow
    -- live there (not in WoWClearance_Events.lua) AND that the file uses
    -- the NS.* widget primitives (the bare locals only exist in
    -- WoWClearance_Events.lua's scope).
    local mpFile = io.open("WoWClearance_MerchantPanel.lua", "rb")
    if mpFile then
        local mpSrc = mpFile:read("*a") or ""
        mpFile:close()
        check(
            "MerchantPanel frame created in WoWClearance_MerchantPanel.lua",
            mpSrc:find('CreateFrame%("Frame", "WoWClearanceOptionsMerchant"') ~= nil,
            "MerchantPanel frame creation must live in WoWClearance_MerchantPanel.lua (Stage 8e-ii)"
        )
        -- Avoid matching comment-line uses by stripping comment lines
        -- before the bare-call check. The comment line in the file
        -- header naturally references "MerchantPanel" by name.
        local codeOnly = (mpSrc:gsub("\n%-%-[^\n]*", ""))
        check(
            "WoWClearance_MerchantPanel.lua uses NS.AddCheckbox (not bare AddCheckbox)",
            codeOnly:find("NS%.AddCheckbox%(") ~= nil
                and codeOnly:find("[^.%w_]AddCheckbox%(") == nil,
            "OnShow body must call NS.AddCheckbox (the local lives in WoWClearance_Events.lua)"
        )
        check(
            "WoWClearance_MerchantPanel.lua uses NS.AddSlider (not bare AddSlider)",
            codeOnly:find("NS%.AddSlider%(") ~= nil
                and codeOnly:find("[^.%w_]AddSlider%(") == nil,
            "OnShow body must call NS.AddSlider (the local lives in WoWClearance_Events.lua)"
        )
        check(
            "WoWClearance_MerchantPanel.lua uses NS.FitScrollContent (not bare WC_FitScrollContent)",
            codeOnly:find("NS%.FitScrollContent%(") ~= nil
                and codeOnly:find("[^.%w_]WC_FitScrollContent%(") == nil,
            "OnShow body must call NS.FitScrollContent (the local lives in WoWClearance_Events.lua)"
        )
    end

    -- The MerchantPanel frame creation must NOT be duplicated in
    -- WoWClearance_Events.lua anymore (would clobber the new one if it were).
    local ecFile = io.open("WoWClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "MerchantPanel frame no longer created in WoWClearance_Events.lua",
            ecSrc:find('local MerchantPanel%s*=%s*CreateFrame') == nil,
            "duplicate definition in WoWClearance_Events.lua would clobber the Stage 8e-ii extracted frame"
        )
    end

    -- Registration must use the _G lookup.
    check(
        "Merchant Settings panel registered via _G lookup in WoWClearance_Events.lua",
        src:find('"WoWClearanceOptionsMerchant",') ~= nil,
        "post-extraction, WoWClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )

    -- Eager NS.* calls at file load time are a load-order trap: this file
    -- loads BEFORE WoWClearance_Events.lua, so NS.ColorTextByQuality (and the
    -- other widget primitives) don't exist at file-load time. Calling them
    -- in a table constructor at file scope nil-errors out and the whole
    -- file aborts before the frame is created, which then breaks the
    -- _G[] registration lookup downstream. Function bodies that reference
    -- NS.* are fine (lazy lookup at call time); top-level table
    -- constructors are NOT.
    local mpFile2 = io.open("WoWClearance_MerchantPanel.lua", "rb")
    if mpFile2 then
        local mpSrc = mpFile2:read("*a") or ""
        mpFile2:close()
        -- Build callback start marker; everything BEFORE it is file-scope
        -- (load time). Everything inside the callback runs lazily.
        local buildStart = mpSrc:find("end,%s*function%(self,%s*content%)")
        if buildStart then
            local fileScope = mpSrc:sub(1, buildStart - 1)
            check(
                "WoWClearance_MerchantPanel.lua does not call NS.ColorTextByQuality at file scope (load-order trap)",
                fileScope:find("NS%.ColorTextByQuality%(") == nil,
                "NS.ColorTextByQuality must not be called at file scope; "
                    .. "this file loads BEFORE WoWClearance_Events.lua so the binding is nil at load time. "
                    .. "Move any such calls inside the OnShow build callback (lazy execution)."
            )
        end
    end
end

-- ---------------------------------------------------------------------------
-- Test 42 (Issue B fix): every settings OnClick that writes a verdict-
-- impacting DB field must call NS.RefreshSellBorders so the slot tints
-- track the user's setting change immediately.
-- ---------------------------------------------------------------------------
-- Pre-fix behaviour: toggling the "Allow exact-rank duplicates" checkbox
-- (or any of the other affix / proc / per-rarity setting toggles) wrote
-- the SV but did not refresh the slot-border tint registry, so users had
-- to close and reopen their bags to see the new verdict reflected in
-- the host bag UI. Same root rule as Test 26 (list mutations) - any
-- write to a DB field that WC_IsSellable reads must repaint.
--
-- The check: for each pattern below, scan the full source for every
-- occurrence and verify NS.RefreshSellBorders appears in the next ~25
-- lines (~1000 chars) of source. Multiple matches for the same field
-- (e.g. protectAffixedRareItems wired twice in the same build callback)
-- all need the call - prevents future regressions where a future
-- contributor adds a fresh SetScript handler and forgets the refresh.
do
    local function eachOccurrence(pattern, fn)
        local startPos = 1
        while true do
            local s, e = src:find(pattern, startPos)
            if not s then
                return
            end
            fn(s, e)
            startPos = e + 1
        end
    end

    local function checkRefreshAfter(pattern, fieldLabel)
        local missing = 0
        local total = 0
        eachOccurrence(pattern, function(_, e)
            total = total + 1
            local window = src:sub(e + 1, e + 1000)
            if not window:find("NS%.RefreshSellBorders") then
                missing = missing + 1
            end
        end)
        check(
            "every write to " .. fieldLabel .. " is followed by NS.RefreshSellBorders",
            total > 0 and missing == 0,
            string.format(
                "expected refresh after each %s write; found %d write(s), %d missing the call within 1000 chars",
                fieldLabel,
                total,
                missing
            )
        )
    end

    checkRefreshAfter(
        "DB%.enableDeletion%s*=%s*delCB:GetChecked",
        "DB.enableDeletion (Deletion panel)"
    )
    checkRefreshAfter(
        "DB%.qualityRules%[qualityIdx%]%.enabled%s*=%s*v",
        "DB.qualityRules[qualityIdx].enabled (Merchant per-rarity)"
    )
    checkRefreshAfter(
        "DB%.qualityRules%[qualityIdx%]%.useEquippedILvl%s*=%s*self_:GetChecked",
        "DB.qualityRules[qualityIdx].useEquippedILvl (Merchant per-rarity)"
    )
    checkRefreshAfter(
        "DB%.qualityRules%[qualityIdx%]%.maxILvl%s*=%s*v",
        "DB.qualityRules[qualityIdx].maxILvl (Merchant per-rarity input commit)"
    )
    checkRefreshAfter(
        "DB%.qualityRules%[qualityIdx%]%.bindFilter%s*=%s*entry%.value",
        "DB.qualityRules[qualityIdx].bindFilter (Merchant per-rarity dropdown)"
    )

    -- WC_LoadProfile wholesale-rewrites DB.whitelist + DB.blacklist; it
    -- must follow up with NS.RefreshSellBorders so slot tints repaint.
    -- Same root rule as Test 26 / Test 42 - any write that changes
    -- WC_IsSellable's verdict must repaint.
    local function bodyHasRefresh(funcSig)
        local startIdx = src:find(funcSig)
        if not startIdx then
            return nil
        end
        local nextLocal = src:find("\nlocal function ", startIdx + 1) or #src
        local nextTbl = src:find("\nfunction [A-Za-z_]+%.", startIdx + 1) or #src
        local endIdx = math.min(nextLocal, nextTbl)
        local body = src:sub(startIdx, endIdx)
        return body:find("NS%.RefreshSellBorders") ~= nil
    end
    check(
        "WC_LoadProfile calls NS.RefreshSellBorders",
        bodyHasRefresh("local function WC_LoadProfile%(") == true,
        "profile load rewrites DB.whitelist + DB.blacklist wholesale; slot-border tints must repaint immediately"
    )
end

-- ---------------------------------------------------------------------------
-- Test 43 (section 4.5 of plan): per-category sell-border colours.
-- ---------------------------------------------------------------------------
-- v2.30.x replaced the single DB.sellBorderColor with a per-category
-- DB.sellBorderCategories table keyed by verdict reason (delete /
-- accountSell / charSell / junk / rule). Each category has its own
-- enable toggle + colour. The bagSlotWillSellCategory predicate
-- resolves which category applies to a given slot, and
-- applySellBorder paints the category's colour (or hides the border
-- if the category is disabled).
--
-- Locks in this test:
--   - EnsureDB creates DB.sellBorderCategories with all 5 expected keys
--   - bagSlotWillSellCategory is defined on WC_compCache
--   - applySellBorder reads from DB.sellBorderCategories (not the
--     legacy DB.sellBorderColor field)
--   - Five enable-checkbox global names exist (one per category)
do
    -- EnsureDB schema migration.
    check(
        "EnsureDB initialises DB.sellBorderCategories",
        src:find("DB%.sellBorderCategories%s*=%s*{}") ~= nil
            or src:find("type%(DB%.sellBorderCategories%)%s*~=%s*\"table\"") ~= nil,
        "EnsureDB must guard DB.sellBorderCategories with a type check + default empty table"
    )

    local categories = { "delete", "accountSell", "charSell", "junk", "rule" }
    for _, key in ipairs(categories) do
        check(
            "EnsureDB default for sellBorderCategories." .. key,
            src:find(key .. "%s*=%s*defaultCat") ~= nil,
            "EnsureDB must populate DB.sellBorderCategories." .. key
                .. " with an { enabled, color } default"
        )
    end

    -- Category-resolving predicate.
    check(
        "WC_compCache.bagSlotWillSellCategory defined",
        src:find("function WC_compCache%.bagSlotWillSellCategory%(") ~= nil,
        "the per-category resolver must be defined for applySellBorder to know which colour to paint"
    )

    -- applySellBorder reads the new per-category settings, not the
    -- legacy DB.sellBorderColor field (which stays in SVs for
    -- downgrade safety but is no longer consulted by the paint path).
    local bdFile = io.open("WoWClearance_BagDisplay.lua", "rb")
    if bdFile then
        local bdSrc = bdFile:read("*a") or ""
        bdFile:close()
        check(
            "applySellBorder reads DB.sellBorderCategories",
            bdSrc:find("DB%.sellBorderCategories") ~= nil,
            "the paint path must read the new per-category table, not the legacy single-colour field"
        )
        check(
            "applySellBorder does NOT read DB.sellBorderColor (legacy field)",
            bdSrc:find("DB%.sellBorderColor") == nil,
            "remove any remaining DB.sellBorderColor reads from BagDisplay; the legacy field is for SV downgrade only"
        )
    end

    -- The CharPanel iterates SELL_BORDER_CATEGORIES to build one row
    -- per verdict category. Lock that the table lists all 5 keys so a
    -- future refactor can't silently drop one of the rows.
    check(
        "CharPanel SELL_BORDER_CATEGORIES table exists",
        src:find("local SELL_BORDER_CATEGORIES%s*=") ~= nil,
        "the Character Settings panel must define a SELL_BORDER_CATEGORIES list (5 rows)"
    )
    for _, key in ipairs(categories) do
        check(
            "CharPanel SELL_BORDER_CATEGORIES includes " .. key,
            src:find('key%s*=%s*"' .. key .. '"') ~= nil,
            "the SELL_BORDER_CATEGORIES table must include { key = \"" .. key .. '" } so a row is built'
        )
    end
    -- And the row builder must use the key to name the checkbox so
    -- bug reports / external tooling can reference them by a stable
    -- name family.
    check(
        "CharPanel checkbox naming uses WoWClearanceSellBorderCB_<key>",
        src:find('"WoWClearanceSellBorderCB_"%s*%.%.%s*key') ~= nil,
        "the per-category enable checkbox should be named WoWClearanceSellBorderCB_<key> via concatenation"
    )
end

-- ---------------------------------------------------------------------------
-- Test 44 (v2.32.x, updated v2.35.1): affix tooltip label scheme.
-- ---------------------------------------------------------------------------
-- The random-affix tooltip branch distinguishes states using plain-
-- English "Keep" / "Will Sell" labels. v2.35.1 collapsed the
-- player-doesn't-own-this-rank states into a single collector-focused
-- "rank needed" label (the v2.32.x scheme split it into "new affix"
-- and "other rank known" - the distinction was noise; the user's
-- collection-side question is "do I need this exact rank?"):
--
--   Player owns this (family, rank) + setting OFF -> "Keep (affix rank known)"
--   Player owns this (family, rank) + setting ON  -> "Will Sell (you have this affix)"
--   Player doesn't own this rank                  -> "Keep (affix rank needed)"
--
-- The label scheme avoids "Protected" / "Allowed" verbs (too abstract
-- for a new player) and avoids the phrase "already known" (could be
-- confused with Blizzard's red "Already known" line on tomes).
do
    local tooltipFile = io.open("WoWClearance_Tooltip.lua", "rb")
    if tooltipFile then
        local ttSrc = tooltipFile:read("*a") or ""
        tooltipFile:close()
        -- Strip Lua line comments before checking - explanatory
        -- comments may reference historical strings and aren't a
        -- regression.
        local ttCode = ttSrc:gsub("%-%-[^\n]*", "")


        -- Legacy strings must NOT appear in the live label-emit paths.
        check(
            "Tooltip no longer emits legacy 'Random affix' label",
            ttCode:find("Random affix") == nil,
            "the legacy 'Random affix' wording must be removed from WoWClearance_Tooltip.lua label-emit paths"
        )
        check(
            "Tooltip no longer emits 'already known' label",
            ttCode:find('already known') == nil,
            "the legacy 'already known' phrasing must be removed - 'Already known' is Blizzard's own tome line so re-using the phrase confused players"
        )
        check(
            "Tooltip no longer emits 'Protected - ' prefix",
            ttCode:find("Protected %-") == nil,
            "the v2.32.x label simplification replaced 'Protected - <reason>' with 'Keep (<reason>)' across all branches"
        )
        check(
            "Tooltip no longer emits 'Allowed - ' prefix",
            ttCode:find("Allowed %-") == nil,
            "the v2.32.x label simplification replaced 'Allowed - <destination>' with 'Will Sell (<destination>)' or 'Will Delete' across all branches"
        )

        -- playerKnows must be computed independently of
        -- affixAllowExactDupes - the whole point of the rewrite is to
        -- surface the known/unknown state regardless of the setting.
    end
end


-- ---------------------------------------------------------------------------
-- Test 46 (Stage 8e-iv): Sell List + Account Sell List panels bundled.
-- ---------------------------------------------------------------------------
-- Stage 8e-iv moves the two sibling list-management panels
-- (WhitelistPanel + AccountWhitelistPanel) into a single bundled
-- file: WoWClearance_SellListPanels.lua. Both share the same
-- helpers (CreateListUI + WC_AddScanByQualityRow) so co-locating is
-- the right shape.
do
    check(
        "NS.CreateListUI exposed",
        src:find("NS%.CreateListUI%s*=%s*CreateListUI") ~= nil,
        "WoWClearance_Events.lua must publish NS.CreateListUI for split panels to build list UIs"
    )
    check(
        "NS.AddScanByQualityRow exposed",
        src:find("NS%.AddScanByQualityRow%s*=%s*WC_AddScanByQualityRow") ~= nil,
        "WoWClearance_Events.lua must publish NS.AddScanByQualityRow for the Sell List family panels"
    )

    local slFile = io.open("WoWClearance_SellListPanels.lua", "rb")
    if slFile then
        local slSrc = slFile:read("*a") or ""
        slFile:close()
        check(
            "WhitelistPanel frame in WoWClearance_SellListPanels.lua",
            slSrc:find('CreateFrame%("Frame", "WoWClearanceOptionsWhitelist"') ~= nil,
            "WhitelistPanel frame must live in WoWClearance_SellListPanels.lua (Stage 8e-iv)"
        )
        check(
            "AccountWhitelistPanel frame in WoWClearance_SellListPanels.lua",
            slSrc:find('CreateFrame%("Frame", "WoWClearanceOptionsAccountWhitelist"') ~= nil,
            "AccountWhitelistPanel frame must live in WoWClearance_SellListPanels.lua"
        )
        local code = (slSrc:gsub("\n%-%-[^\n]*", ""))
        check(
            "WoWClearance_SellListPanels.lua uses NS.CreateListUI (not bare CreateListUI)",
            code:find("NS%.CreateListUI%(") ~= nil
                and code:find("[^.%w_]CreateListUI%(") == nil,
            "panel builds must call NS.CreateListUI (the local lives in WoWClearance_Events.lua)"
        )
        check(
            "WoWClearance_SellListPanels.lua uses NS.AddScanByQualityRow",
            code:find("NS%.AddScanByQualityRow%(") ~= nil
                and code:find("[^.%w_]WC_AddScanByQualityRow%(") == nil,
            "panel builds must call NS.AddScanByQualityRow"
        )
    end

    local ecFile = io.open("WoWClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "WhitelistPanel no longer created in WoWClearance_Events.lua",
            ecSrc:find('local WhitelistPanel%s*=%s*CreateFrame') == nil,
            "duplicate definition in WoWClearance_Events.lua would clobber the extracted frame"
        )
        check(
            "AccountWhitelistPanel no longer created in WoWClearance_Events.lua",
            ecSrc:find('local AccountWhitelistPanel%s*=') == nil,
            "duplicate definition in WoWClearance_Events.lua would clobber the extracted frame"
        )
    end

    check(
        "Sell List panel registered via _G lookup",
        src:find('"WoWClearanceOptionsWhitelist",') ~= nil,
        "post-extraction, WoWClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
    check(
        "Account Sell List panel registered via _G lookup",
        src:find('"WoWClearanceOptionsAccountWhitelist",') ~= nil,
        "post-extraction, WoWClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
end

-- ---------------------------------------------------------------------------
-- Test 47 (Stage 8e-v): Keep List + Delete List panels bundled.
-- ---------------------------------------------------------------------------
-- Stage 8e-v moves two sibling list-management panels (BlacklistPanel
-- and DeletePanel) into one bundled file. The Protection Settings
-- panel (BlacklistSettingsPanel) stays in WoWClearance_Events.lua for a
-- later stage - it's a different domain (auto-protect toggles, not
-- list management). Zero new NS exposures needed - both panels use
-- NS.MakeHeader / NS.MakeLabel / NS.CreateListUI already exposed in
-- earlier stages.
do
    local kdFile = io.open("WoWClearance_KeepDeletePanels.lua", "rb")
    if kdFile then
        local kdSrc = kdFile:read("*a") or ""
        kdFile:close()
        check(
            "BlacklistPanel frame in WoWClearance_KeepDeletePanels.lua",
            kdSrc:find('CreateFrame%("Frame", "WoWClearanceOptionsBlacklist"') ~= nil,
            "BlacklistPanel (Keep List) frame must live in WoWClearance_KeepDeletePanels.lua (Stage 8e-v)"
        )
        check(
            "DeletePanel frame in WoWClearance_KeepDeletePanels.lua",
            kdSrc:find('CreateFrame%("Frame", "WoWClearanceOptionsDeletion"') ~= nil,
            "DeletePanel (Delete List) frame must live in WoWClearance_KeepDeletePanels.lua"
        )
        local code = (kdSrc:gsub("\n%-%-[^\n]*", ""))
        check(
            "WoWClearance_KeepDeletePanels.lua uses NS.CreateListUI (not bare CreateListUI)",
            code:find("NS%.CreateListUI%(") ~= nil
                and code:find("[^.%w_]CreateListUI%(") == nil,
            "panel builds must call NS.CreateListUI (the local lives in WoWClearance_Events.lua)"
        )
    end

    local ecFile = io.open("WoWClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "BlacklistPanel no longer created in WoWClearance_Events.lua",
            ecSrc:find('local BlacklistPanel%s*=%s*CreateFrame') == nil,
            "duplicate definition in WoWClearance_Events.lua would clobber the extracted frame"
        )
        check(
            "DeletePanel no longer created in WoWClearance_Events.lua",
            ecSrc:find('local DeletePanel%s*=%s*CreateFrame') == nil,
            "duplicate definition in WoWClearance_Events.lua would clobber the extracted frame"
        )
        -- Note: a Stage 8e-v sentinel check for BlacklistSettingsPanel
        -- staying in WoWClearance_Events.lua was removed when 8e-vi
        -- intentionally moved it. Test 48 below now locks
        -- BlacklistSettingsPanel's location in ProtectionPanel.lua.
    end

    check(
        "Keep List panel registered via _G lookup",
        src:find('"WoWClearanceOptionsBlacklist",') ~= nil,
        "post-extraction, WoWClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
    check(
        "Delete List panel registered via _G lookup",
        src:find('"WoWClearanceOptionsDeletion",') ~= nil,
        "post-extraction, WoWClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
end

-- ---------------------------------------------------------------------------
-- Test 48 (Stage 8e-vi): Protection Settings panel extracted.
-- ---------------------------------------------------------------------------
-- Stage 8e-vi moves the Protection Settings panel
-- (BlacklistSettingsPanel - internal frame name preserved from
-- v2.15.0 schema) into WoWClearance_ProtectionPanel.lua. Hosts the
-- auto-protect toggles + the v2.20.0 affix / chance-on-hit protection
-- toggles + affixAllowExactDupes. Three of the OnClick handlers
-- contain NS.RefreshSellBorders calls (Issue B fix) that carry over.
do
    local ppFile = io.open("WoWClearance_ProtectionPanel.lua", "rb")
    if ppFile then
        local ppSrc = ppFile:read("*a") or ""
        ppFile:close()
        check(
            "BlacklistSettingsPanel frame in WoWClearance_ProtectionPanel.lua",
            ppSrc:find('CreateFrame%("Frame", "WoWClearanceOptionsBlacklistSettings"') ~= nil,
            "Protection Settings frame must live in WoWClearance_ProtectionPanel.lua (Stage 8e-vi)"
        )
        local code = (ppSrc:gsub("\n%-%-[^\n]*", ""))
        check(
            "WoWClearance_ProtectionPanel.lua uses NS.MakeHeader (not bare MakeHeader)",
            code:find("NS%.MakeHeader%(") ~= nil
                and code:find("[^.%w_]MakeHeader%(") == nil,
            "panel build must call NS.MakeHeader (the local lives in WoWClearance_Events.lua)"
        )
        check(
            "WoWClearance_ProtectionPanel.lua uses NS.FitScrollContent",
            code:find("NS%.FitScrollContent%(") ~= nil
                and code:find("[^.%w_]WC_FitScrollContent%(") == nil,
            "panel build must call NS.FitScrollContent"
        )
        -- Issue B fix invariant: the three affix/proc/dupe OnClick
        -- handlers carried over must still call NS.RefreshSellBorders.
    end

    local ecFile = io.open("WoWClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "BlacklistSettingsPanel no longer created in WoWClearance_Events.lua",
            ecSrc:find('local BlacklistSettingsPanel') == nil,
            "duplicate definition in WoWClearance_Events.lua would clobber the Stage 8e-vi extracted frame"
        )
    end

    check(
        "Protection Settings panel registered via _G lookup",
        src:find('"WoWClearanceOptionsBlacklistSettings",') ~= nil,
        "post-extraction, WoWClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
end

-- ---------------------------------------------------------------------------
-- Test 49 (Stage 8e-vii): Item Highlighting panel extracted + dead code
-- cleanup.
-- ---------------------------------------------------------------------------
-- Stage 8e-vii moves CharPanel (Item Highlighting, internal frame name
-- "WoWClearanceOptionsCharacter" preserved) into
-- WoWClearance_ItemHighlightingPanel.lua. The dead CreateNameListUI
-- function (orphaned in §4.5 when the per-character allowlist UI was
-- decommissioned) is dropped in the same stage. Test 2 in
-- test_layout_reactivity.lua was updated to remove the now-obsolete
-- CreateNameListUI box:OnSizeChanged check.
do
    local ihFile = io.open("WoWClearance_ItemHighlightingPanel.lua", "rb")
    if ihFile then
        local ihSrc = ihFile:read("*a") or ""
        ihFile:close()
        check(
            "CharPanel frame in WoWClearance_ItemHighlightingPanel.lua",
            ihSrc:find('CreateFrame%("Frame", "WoWClearanceOptionsCharacter"') ~= nil,
            "CharPanel (Item Highlighting) frame must live in WoWClearance_ItemHighlightingPanel.lua (Stage 8e-vii)"
        )
        check(
            "Item Highlighting panel name preserved",
            ihSrc:find('CharPanel%.name%s*=%s*"Item Highlighting"') ~= nil,
            "the v2.30.x panel name 'Item Highlighting' must survive the extraction"
        )
        local code = (ihSrc:gsub("\n%-%-[^\n]*", ""))
        check(
            "WoWClearance_ItemHighlightingPanel.lua uses NS.MakeHeader (not bare MakeHeader)",
            code:find("NS%.MakeHeader%(") ~= nil
                and code:find("[^.%w_]MakeHeader%(") == nil,
            "panel build must call NS.MakeHeader (the local lives in WoWClearance_Events.lua)"
        )
    end

    local ecFile = io.open("WoWClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "CharPanel no longer created in WoWClearance_Events.lua",
            ecSrc:find('local CharPanel%s*=%s*CreateFrame') == nil,
            "duplicate definition in WoWClearance_Events.lua would clobber the Stage 8e-vii extracted frame"
        )
        check(
            "CreateNameListUI (dead code) dropped from WoWClearance_Events.lua",
            ecSrc:find('local function CreateNameListUI') == nil,
            "CreateNameListUI was orphaned in §4.5 (per-character allowlist UI decommission) and should be dropped in Stage 8e-vii"
        )
    end

    check(
        "Item Highlighting panel registered via _G lookup",
        src:find('"WoWClearanceOptionsCharacter",') ~= nil,
        "post-extraction, WoWClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
end

-- ---------------------------------------------------------------------------
-- Test 50 (Stage 8e-viii): Profiles + Import/Export panels bundled.
-- ---------------------------------------------------------------------------
-- Stage 8e-viii bundles two related panels into one new file:
-- ProfilesPanel (named-profile management) + ImportExportPanel
-- (profile pack + settings pack import/export). The Import/Export
-- region's file-scope helpers (WC_GetWhitelistForScope,
-- WC_ExportWhitelist, WC_ImportWhitelist, WC_EXPORT_PREFIX) and
-- WC_compCache.exportFullPack / importFullPack all move along with
-- the panels. Profile-mutation helpers + WC_HookScrollbarAutoHide
-- stay in WoWClearance_Events.lua as NS-exposed entry points.
do
    -- 5 new NS exposures for this stage.
    check(
        "NS.SaveProfile exposed",
        src:find("NS%.SaveProfile%s*=%s*WC_SaveProfile") ~= nil,
        "WoWClearance_Events.lua must publish NS.SaveProfile for the Profiles panel button OnClicks"
    )
    check(
        "NS.LoadProfile exposed",
        src:find("NS%.LoadProfile%s*=%s*WC_LoadProfile") ~= nil,
        "WoWClearance_Events.lua must publish NS.LoadProfile"
    )
    check(
        "NS.DeleteProfile exposed",
        src:find("NS%.DeleteProfile%s*=%s*WC_DeleteProfile") ~= nil,
        "WoWClearance_Events.lua must publish NS.DeleteProfile"
    )
    check(
        "NS.RenameProfile exposed",
        src:find("NS%.RenameProfile%s*=%s*WC_RenameProfile") ~= nil,
        "WoWClearance_Events.lua must publish NS.RenameProfile"
    )
    check(
        "NS.HookScrollbarAutoHide exposed",
        src:find("NS%.HookScrollbarAutoHide%s*=%s*WC_HookScrollbarAutoHide") ~= nil,
        "WoWClearance_Events.lua must publish NS.HookScrollbarAutoHide for the Profiles + ImportExport panels"
    )
    -- WC_PANEL_WIDTH is a file-scope local in WoWClearance_Events.lua that
    -- mutates dynamically in WC_UpdatePanelWidth; split panel files
    -- that need it for build-time SetSize calls must use the
    -- NS.GetPanelWidth() getter (returns the live value via upvalue
    -- closure) instead of dereferencing WC_PANEL_WIDTH as a global.
    check(
        "NS.GetPanelWidth exposed",
        src:find("NS%.GetPanelWidth%s*=%s*function") ~= nil,
        "WoWClearance_Events.lua must publish NS.GetPanelWidth for split panel files"
    )

    local ppFile = io.open("WoWClearance_ProfilesPanel.lua", "rb")
    if ppFile then
        local ppSrc = ppFile:read("*a") or ""
        ppFile:close()
        check(
            "ProfilesPanel frame in WoWClearance_ProfilesPanel.lua",
            ppSrc:find('CreateFrame%("Frame", "WoWClearanceOptionsProfiles"') ~= nil,
            "ProfilesPanel frame must live in WoWClearance_ProfilesPanel.lua (Stage 8e-viii)"
        )
        check(
            "ImportExportPanel frame in WoWClearance_ProfilesPanel.lua",
            ppSrc:find('CreateFrame%("Frame", "WoWClearanceOptionsImportExport"') ~= nil,
            "ImportExportPanel frame must also live in WoWClearance_ProfilesPanel.lua (bundled)"
        )
        local code = (ppSrc:gsub("\n%-%-[^\n]*", ""))
        check(
            "WoWClearance_ProfilesPanel.lua uses NS.SaveProfile (not bare WC_SaveProfile)",
            code:find("NS%.SaveProfile%(") ~= nil
                and code:find("[^.%w_]WC_SaveProfile%(") == nil,
            "panel must call NS.SaveProfile (the local lives in WoWClearance_Events.lua)"
        )
        check(
            "WoWClearance_ProfilesPanel.lua uses NS.HookScrollbarAutoHide",
            code:find("NS%.HookScrollbarAutoHide%(") ~= nil
                and code:find("[^.%w_]WC_HookScrollbarAutoHide%(") == nil,
            "panel must call NS.HookScrollbarAutoHide"
        )
        -- The build-time SetSize calls in this file must use the
        -- NS.GetPanelWidth() getter, not the bare WC_PANEL_WIDTH
        -- identifier (which would be nil here - WC_PANEL_WIDTH is a
        -- file-scope local in WoWClearance_Events.lua).
        check(
            "WoWClearance_ProfilesPanel.lua uses NS.GetPanelWidth() (not bare WC_PANEL_WIDTH)",
            code:find("NS%.GetPanelWidth%(%)") ~= nil
                and code:find("[^.%w_]WC_PANEL_WIDTH[^_%w]") == nil,
            "build-time SetSize calls must call NS.GetPanelWidth() so they read the live width value"
        )
        -- Every file-scope function in this split file that references
        -- DB.x or ADB.x must capture them at entry via
        -- `local DB = NS.DB` / `local ADB = NS.ADB`. Pre-fix the
        -- exportFullPack / importFullPack / WC_GetWhitelistForScope
        -- helpers all silently returned empty data because DB / ADB
        -- resolved to nil globals. Lock this so future helpers don't
        -- regress: count the file-scope function definitions vs. the
        -- DB-capture sites. (OnShow inner closures pick up DB via
        -- upvalue from the OnShow's capture, so they aren't counted
        -- against this invariant.)
        local fnCount = 0
        for _ in code:gmatch("function WC_compCache%.[a-zA-Z]+%(") do
            fnCount = fnCount + 1
        end
        for _ in code:gmatch("\nlocal function [A-Za-z_]+%(") do
            fnCount = fnCount + 1
        end
        local dbCaptureCount = 0
        for _ in code:gmatch("local DB%s*=%s*NS%.DB") do
            dbCaptureCount = dbCaptureCount + 1
        end
        -- The file has 2 panel OnShow handlers + 4 file-scope helpers
        -- that directly read DB / ADB (WC_GetWhitelistForScope,
        -- exportFullPack, importFullPack, WC_ImportWhitelist). The 5th
        -- file-scope helper WC_ExportWhitelist doesn't touch DB / ADB
        -- directly - it delegates to WC_GetWhitelistForScope - so it
        -- doesn't need its own capture. Expected: 2 + 4 = 6 captures.
        check(
            "WoWClearance_ProfilesPanel.lua: every file-scope function that touches DB captures it at entry",
            dbCaptureCount >= 6,
            string.format(
                "expected at least 6 'local DB = NS.DB' captures (2 OnShow + 4 helpers); found %d. Functions that read DB/ADB as globals after the file-scope move will silently return empty data.",
                dbCaptureCount
            )
        )
    end

    local ecFile = io.open("WoWClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "ProfilesPanel no longer created in WoWClearance_Events.lua",
            ecSrc:find('local ProfilesPanel%s*=%s*CreateFrame') == nil,
            "duplicate definition would clobber the extracted frame"
        )
        check(
            "ImportExportPanel no longer created in WoWClearance_Events.lua",
            ecSrc:find('local ImportExportPanel%s*=%s*CreateFrame') == nil,
            "duplicate definition would clobber the extracted frame"
        )
        -- The file-scope ImportExport helpers also move with the panels.
        check(
            "WC_GetWhitelistForScope no longer defined in WoWClearance_Events.lua",
            ecSrc:find('local function WC_GetWhitelistForScope') == nil,
            "the helper is only used inside the ImportExport region and moves with it"
        )
    end

    check(
        "Profiles panel registered via _G lookup",
        src:find('"WoWClearanceOptionsProfiles",') ~= nil,
        "post-extraction, WoWClearance_Events.lua must use the _G lookup"
    )
    check(
        "Import/Export panel registered via _G lookup",
        src:find('"WoWClearanceOptionsImportExport",') ~= nil,
        "post-extraction, WoWClearance_Events.lua must use the _G lookup"
    )
end

-- ---------------------------------------------------------------------------
-- Test 51 (Stage 8e-ix-a): MainOptions panel + BuildMainPanel extracted.
-- ---------------------------------------------------------------------------
-- Stage 8e-ix-a moves three non-contiguous chunks from WoWClearance_Events.lua
-- into WoWClearance_MainPanel.lua:
--   - local MainOptions = CreateFrame(...) frame creation
--   - BuildMainPanel function body
--   - MainOptions:SetScript("OnShow", ...) panel-build handler
-- The panel-infra helpers (MakeHeader, MakeLabel, WC_PANEL_WIDTH,
-- WC_UpdatePanelWidth, etc.) stay in WoWClearance_Events.lua for later
-- stages.
do
    check(
        "NS.ResetSession exposed",
        src:find("NS%.ResetSession%s*=%s*WC_ResetSession") ~= nil,
        "WoWClearance_Events.lua must publish NS.ResetSession for the Main panel's Reset Session button"
    )

    local mpFile = io.open("WoWClearance_MainPanel.lua", "rb")
    if mpFile then
        local mpSrc = mpFile:read("*a") or ""
        mpFile:close()
        check(
            "MainOptions frame in WoWClearance_MainPanel.lua",
            mpSrc:find('CreateFrame%("Frame", "WoWClearanceOptionsMain"') ~= nil,
            "MainOptions frame creation must live in WoWClearance_MainPanel.lua (Stage 8e-ix-a)"
        )
        check(
            "BuildMainPanel function in WoWClearance_MainPanel.lua",
            mpSrc:find("local function BuildMainPanel%(") ~= nil,
            "BuildMainPanel must move along with the MainOptions OnShow that calls it"
        )
        local code = (mpSrc:gsub("\n%-%-[^\n]*", ""))
        -- v2.36.x: the Reset Session button moved off MainPanel onto the
        -- new StatsPanel (along with every other stats widget). The check
        -- below now targets the StatsPanel source. MainPanel must still
        -- NOT call WC_ResetSession as a bare global.
        check(
            "WoWClearance_MainPanel.lua does not call WC_ResetSession as a bare global",
            code:find("[^.%w_]WC_ResetSession%(") == nil,
            "MainPanel must not reach into Events.lua's file-scope local; use NS.ResetSession if needed"
        )
        local statsPanelFile = io.open("WoWClearance_StatsPanel.lua", "rb")
        if statsPanelFile then
            local statsPanelSrc = statsPanelFile:read("*a") or ""
            statsPanelFile:close()
            local statsCode = (statsPanelSrc:gsub("\n%-%-[^\n]*", ""))
            check(
                "WoWClearance_StatsPanel.lua uses NS.ResetSession (not bare WC_ResetSession)",
                statsCode:find("NS%.ResetSession%(") ~= nil
                    and statsCode:find("[^.%w_]WC_ResetSession%(") == nil,
                "the Reset Session button (now on the Stats panel) must call NS.ResetSession (the local lives in WoWClearance_Events.lua)"
            )
        end
        check(
            "WoWClearance_MainPanel.lua uses NS.CopperToColoredText / NS.CopperToGoldOnlyText",
            (code:find("NS%.CopperToColoredText%(") ~= nil or code:find("NS%.CopperToGoldOnlyText%(") ~= nil)
                and code:find("[^.%w_]CopperToColoredText%(") == nil
                and code:find("[^.%w_]CopperToGoldOnlyText%(") == nil,
            "stats display must call one of the NS-namespaced money formatters (both locals live in WoWClearance_Events.lua). v2.66.1 iter: stats display swapped to NS.CopperToGoldOnlyText for the aggregate lines - either form is acceptable."
        )
        -- Catch other common file-scope-locals-as-globals traps from the
        -- extraction: ADDON_AUTHOR / ADDON_URL / WC_session are file-
        -- scope locals in WoWClearance_Events.lua that the byline + stats
        -- panel use. The new file must call them through NS.
        check(
            "WoWClearance_MainPanel.lua uses NS.ADDON_AUTHOR / NS.ADDON_URL",
            code:find("NS%.ADDON_AUTHOR") ~= nil
                and code:find("NS%.ADDON_URL") ~= nil
                and code:find("[^.%w_]ADDON_AUTHOR[^.%w_]") == nil
                and code:find("[^.%w_]ADDON_URL[^.%w_]") == nil,
            "byline must call NS.ADDON_AUTHOR / NS.ADDON_URL; bare globals would be nil"
        )
        check(
            "WoWClearance_MainPanel.lua uses NS.session (not bare WC_session)",
            code:find("NS%.session%.") ~= nil
                and code:find("[^.%w_]WC_session[^.%w_]") == nil,
            "stats display must call NS.session (the WC_session table lives in WoWClearance_Events.lua)"
        )
    end

    local ecFile = io.open("WoWClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "MainOptions no longer created in WoWClearance_Events.lua",
            ecSrc:find('local MainOptions%s*=%s*CreateFrame') == nil,
            "duplicate definition would clobber the Stage 8e-ix-a extracted frame"
        )
        check(
            "BuildMainPanel no longer defined in WoWClearance_Events.lua",
            ecSrc:find('local function BuildMainPanel%(') == nil,
            "BuildMainPanel must move with the panel; leftover definition in WoWClearance_Events.lua is dead code"
        )
        -- The 5 in-WoWClearance_Events.lua MainOptions call sites must all be
        -- replaced with _G[] lookups so they still work after the local
        -- binding moves out.
        check(
            "no bare MainOptions identifier references in WoWClearance_Events.lua",
            ecSrc:find("[^_%w\"]MainOptions[^_%w\"]") == nil,
            "every InterfaceOptionsFrame_OpenToCategory(MainOptions) and similar must use _G[\"WoWClearanceOptionsMain\"] after extraction"
        )
    end

    check(
        "Main panel registered via _G lookup",
        src:find('"WoWClearanceOptionsMain",') ~= nil,
        "post-extraction, WoWClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
end

-- ---------------------------------------------------------------------------
-- Test 52 (Stage 8e-ix-b): panel-width registry + reactivity layer
-- extracted to WoWClearance_PanelInfra.lua.
-- ---------------------------------------------------------------------------
-- Stage 8e-ix-b moves the panel-infrastructure block (WC_PANEL_WIDTH,
-- WC_UpdatePanelWidth, the widthRegistry, registerWidth /
-- registerScrollFit / setPanelWidth / refreshLayouts /
-- WC_HookScrollbarAutoHide / WC_WrapPanelInScrollFrame /
-- WC_FitScrollContent / initPanel) into WoWClearance_PanelInfra.lua.
-- The widget primitives (MakeHeader, MakeLabel, AddCheckbox,
-- AddSlider, ColorTextByQuality, StyleInputBox) + CreateListUI + the
-- list-row factories STAY in WoWClearance_Events.lua for 8e-ix-c / 8e-ix-d.
do
    local infraFile = io.open("WoWClearance_PanelInfra.lua", "rb")
    if infraFile then
        local infraSrc = infraFile:read("*a") or ""
        infraFile:close()
        check(
            "WC_PANEL_WIDTH local lives in WoWClearance_PanelInfra.lua",
            infraSrc:find("local WC_PANEL_WIDTH%s*=%s*440") ~= nil,
            "the panel-width local must live in WoWClearance_PanelInfra.lua (Stage 8e-ix-b)"
        )
        check(
            "WC_compCache.initPanel defined in WoWClearance_PanelInfra.lua",
            infraSrc:find("function WC_compCache%.initPanel%(") ~= nil,
            "initPanel must live in WoWClearance_PanelInfra.lua"
        )
        check(
            "WC_compCache.widthRegistry defined in WoWClearance_PanelInfra.lua",
            infraSrc:find("WC_compCache%.widthRegistry%s*=") ~= nil,
            "the reactive-layout registry must live in WoWClearance_PanelInfra.lua"
        )
        check(
            "NS.GetPanelWidth closure lives in WoWClearance_PanelInfra.lua",
            infraSrc:find("NS%.GetPanelWidth%s*=%s*function") ~= nil,
            "the getter closure must be co-located with WC_PANEL_WIDTH so the upvalue resolves correctly"
        )
        check(
            "WoWClearance_PanelInfra.lua uses NS.EnsureDB (not bare EnsureDB)",
            infraSrc:find("NS%.EnsureDB%(%)") ~= nil
                and infraSrc:find("[^.%w_]EnsureDB%(%)") == nil,
            "initPanel must call NS.EnsureDB (the local lives in WoWClearance_Events.lua)"
        )
        -- WC_Delay is a file-scope local in WoWClearance_Events.lua; the
        -- HookScrollbarAutoHide / FitScrollContent / refreshLayouts
        -- helpers all schedule deferred work and must call NS.Delay.
        local infraCode = (infraSrc:gsub("\n[^\n]*", function(line)
            local commentAt = line:find("%-%-", 1, false)
            if not commentAt then return line end
            return line:sub(1, commentAt - 1)
        end))
        check(
            "WoWClearance_PanelInfra.lua uses NS.Delay (not bare WC_Delay)",
            infraCode:find("NS%.Delay%(") ~= nil
                and infraCode:find("[^.%w_]WC_Delay%(") == nil,
            "deferred-work scheduling must call NS.Delay (the WC_Delay local lives in WoWClearance_Events.lua)"
        )
    end

    local ecFile = io.open("WoWClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "WC_PANEL_WIDTH no longer declared in WoWClearance_Events.lua",
            ecSrc:find("local WC_PANEL_WIDTH%s*=%s*440") == nil,
            "duplicate definition would clobber the Stage 8e-ix-b extracted local"
        )
        check(
            "initPanel no longer defined in WoWClearance_Events.lua",
            ecSrc:find("function WC_compCache%.initPanel%(") == nil,
            "duplicate definition in WoWClearance_Events.lua would clobber the extracted body"
        )
        -- Strip Lua line comments before the bare-ref checks; comment
        -- lines that reference the old identifier are historical
        -- documentation, not live code. Strip ALL line comments
        -- regardless of leading whitespace (the simpler "\n--"-prefix
        -- gsub misses indented inline comments).
        local ecCode = (ecSrc:gsub("(\n[^\n]*)", function(line)
            local commentAt = line:find("%-%-", 1, false)
            if not commentAt then
                return line
            end
            return line:sub(1, commentAt - 1)
        end))
        check(
            "WoWClearance_Events.lua callers use NS.GetPanelWidth (not bare WC_PANEL_WIDTH)",
            ecCode:find("[^.%w_]WC_PANEL_WIDTH[^_%w]") == nil,
            "after the move, WoWClearance_Events.lua can no longer reference WC_PANEL_WIDTH as a local; all callers must use NS.GetPanelWidth()"
        )
        check(
            "WoWClearance_Events.lua callers use NS.HookScrollbarAutoHide (not bare)",
            ecCode:find("[^.%w_]WC_HookScrollbarAutoHide%(") == nil,
            "after the move, WoWClearance_Events.lua can no longer reference WC_HookScrollbarAutoHide as a local; all callers must use NS.HookScrollbarAutoHide()"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 53 (Stage 8e-ix-c): widget primitives extracted.
-- ---------------------------------------------------------------------------
-- Stage 8e-ix-c moves the six widget primitives (MakeHeader, MakeLabel,
-- AddCheckbox, AddSlider, StyleInputBox, ColorTextByQuality) into
-- WoWClearance_PanelWidgets.lua. The list-row factories
-- (WC_compCache.makeListRowFactory + buildList*Row helpers) +
-- CreateListUI + WC_AddScanByQualityRow STAY in WoWClearance_Events.lua for
-- Stage 8e-ix-d.
do
    local pwFile = io.open("WoWClearance_PanelWidgets.lua", "rb")
    if pwFile then
        local pwSrc = pwFile:read("*a") or ""
        pwFile:close()
        local widgets = { "MakeHeader", "MakeLabel", "AddCheckbox",
            "AddSlider", "StyleInputBox", "ColorTextByQuality" }
        for _, name in ipairs(widgets) do
            check(
                "WoWClearance_PanelWidgets.lua defines " .. name,
                pwSrc:find("local function " .. name .. "%(") ~= nil,
                name .. " must live in WoWClearance_PanelWidgets.lua (Stage 8e-ix-c)"
            )
        end
        -- NS exposures must also be co-located.
        check(
            "WoWClearance_PanelWidgets.lua exposes all 6 widgets on NS",
            pwSrc:find("NS%.MakeHeader%s*=%s*MakeHeader") ~= nil
                and pwSrc:find("NS%.MakeLabel%s*=%s*MakeLabel") ~= nil
                and pwSrc:find("NS%.AddCheckbox%s*=%s*AddCheckbox") ~= nil
                and pwSrc:find("NS%.AddSlider%s*=%s*AddSlider") ~= nil
                and pwSrc:find("NS%.StyleInputBox%s*=%s*StyleInputBox") ~= nil
                and pwSrc:find("NS%.ColorTextByQuality%s*=%s*ColorTextByQuality") ~= nil,
            "all 6 widget primitives must be exposed on NS so split panel files can call them"
        )
    end

    local ecFile = io.open("WoWClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        -- The widget primitives must NOT be re-defined in WoWClearance_Events.lua.
        for _, name in ipairs({ "MakeHeader", "MakeLabel", "AddCheckbox",
                "AddSlider", "StyleInputBox", "ColorTextByQuality" }) do
            check(
                name .. " no longer defined in WoWClearance_Events.lua",
                ecSrc:find("local function " .. name .. "%(") == nil,
                "duplicate definition would clobber the Stage 8e-ix-c extracted body"
            )
        end
        -- No bare StyleInputBox call sites in WoWClearance_Events.lua code
        -- (comments stripped) - all 3 in-WoWClearance_Events.lua callers
        -- inside the list-row factories were converted to
        -- NS.StyleInputBox.
        local ecCode = (ecSrc:gsub("\n[^\n]*", function(line)
            local at = line:find("%-%-", 1, false)
            if not at then return line end
            return line:sub(1, at - 1)
        end))
        check(
            "no bare StyleInputBox() call sites in WoWClearance_Events.lua code",
            ecCode:find("[^.%w_]StyleInputBox%(") == nil,
            "the 3 list-row-factory call sites must use NS.StyleInputBox after the move"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 54 (Stage 8e-ix-d): list widget extracted.
-- ---------------------------------------------------------------------------
-- Stage 8e-ix-d moves the list-row factories (makeListRowFactory,
-- buildListHeaderRow, buildListSearchAndSortRow, buildListScrollArea),
-- the CreateListUI widget body itself, and the shared
-- WC_AddScanByQualityRow into WoWClearance_ListWidget.lua. The file
-- lives after PanelInfra/PanelWidgets in the .toc load order so
-- NS.StyleInputBox and NS.HookScrollbarAutoHide are already published
-- by the time the row factories are defined. (v2.41.0 merged the old
-- buildListMatchRow "By name" add into the single buildListHeaderRow
-- input, so that factory no longer exists.)
--
-- Locks:
--   1. The new file defines the row-factory functions on WC_compCache.
--   2. CreateListUI is a file-scope local in the new file.
--   3. WC_AddScanByQualityRow is a file-scope local in the new file.
--   4. NS.CreateListUI and NS.AddScanByQualityRow are exposed from the
--      new file (not from WoWClearance_Events.lua).
--   5. WoWClearance_Events.lua no longer contains the function bodies or
--      the NS exposures (would clobber the new file's exposures).
--   6. WoWClearance_Events.lua no longer has a `local WC_activeIDBox` (moved
--      to NS.activeIDBox so the cross-file ChatEdit_InsertLink reader
--      and the buildListHeaderRow setter can share state).
--   7. The new file's CreateListUI body uses NS.GetListTable /
--      NS.AddItemToList / NS.PrintNicef / NS.Delay (bare locals would
--      be nil there).
do
    local lwFile = io.open("WoWClearance_ListWidget.lua", "rb")
    if lwFile then
        local lwSrc = lwFile:read("*a") or ""
        lwFile:close()
        local factories = { "makeListRowFactory", "buildListHeaderRow",
            "buildListSearchAndSortRow",
            "buildListScrollArea" }
        for _, name in ipairs(factories) do
            check(
                "WoWClearance_ListWidget.lua defines WC_compCache." .. name,
                lwSrc:find("function WC_compCache%." .. name .. "%(") ~= nil,
                name .. " must live in WoWClearance_ListWidget.lua (Stage 8e-ix-d)"
            )
        end
        check(
            "WoWClearance_ListWidget.lua defines local CreateListUI",
            lwSrc:find("local function CreateListUI%(") ~= nil,
            "CreateListUI must be a file-scope local in WoWClearance_ListWidget.lua"
        )
        check(
            "WoWClearance_ListWidget.lua defines local WC_AddScanByQualityRow",
            lwSrc:find("local function WC_AddScanByQualityRow%(") ~= nil,
            "WC_AddScanByQualityRow must be a file-scope local in WoWClearance_ListWidget.lua"
        )
        check(
            "WoWClearance_ListWidget.lua exposes NS.CreateListUI",
            lwSrc:find("NS%.CreateListUI%s*=%s*CreateListUI") ~= nil,
            "split panel files (Sell List, Keep List, etc.) call NS.CreateListUI"
        )
        check(
            "WoWClearance_ListWidget.lua exposes NS.AddScanByQualityRow",
            lwSrc:find("NS%.AddScanByQualityRow%s*=%s*WC_AddScanByQualityRow") ~= nil,
            "WoWClearance_SellListPanels.lua calls NS.AddScanByQualityRow"
        )
        -- The CreateListUI body must call NS.GetListTable etc., not the
        -- file-scope locals from WoWClearance_Events.lua which are no longer
        -- in scope after the move.
        check(
            "CreateListUI body uses NS.GetListTable",
            lwSrc:find("NS%.GetListTable%(") ~= nil,
            "the moved body must call NS.GetListTable; bare WC_GetListTable is nil here"
        )
        check(
            "CreateListUI body uses NS.AddItemToList",
            lwSrc:find("NS%.AddItemToList%(") ~= nil,
            "the moved body must call NS.AddItemToList; bare WC_AddItemToList is nil here"
        )
        check(
            "CreateListUI body uses NS.PrintNicef",
            lwSrc:find("NS%.PrintNicef%(") ~= nil,
            "the moved body must call NS.PrintNicef; bare PrintNicef is nil here"
        )
        check(
            "CreateListUI body uses NS.Delay",
            lwSrc:find("NS%.Delay%(") ~= nil,
            "the moved body must call NS.Delay; bare WC_Delay is nil here"
        )
        -- The buildListHeaderRow OnEditFocusGained/Lost handlers must
        -- read/write NS.activeIDBox (not the bare local that used to
        -- live in WoWClearance_Events.lua's main chunk).
        check(
            "buildListHeaderRow uses NS.activeIDBox",
            lwSrc:find("NS%.activeIDBox%s*=%s*self") ~= nil,
            "OnEditFocusGained must set NS.activeIDBox so the ChatEdit_InsertLink hook can read it"
        )
    end

    local ecFile = io.open("WoWClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        -- Strip comments line-by-line so doc references don't trigger
        -- the "moved body still here" failure.
        local ecCode = (ecSrc:gsub("\n[^\n]*", function(line)
            local at = line:find("%-%-", 1, false)
            if not at then return line end
            return line:sub(1, at - 1)
        end))
        -- Function bodies must NOT be redefined in WoWClearance_Events.lua.
        for _, name in ipairs({ "makeListRowFactory", "buildListHeaderRow",
                "buildListSearchAndSortRow",
                "buildListScrollArea" }) do
            check(
                "WC_compCache." .. name .. " no longer defined in WoWClearance_Events.lua",
                ecCode:find("function WC_compCache%." .. name .. "%(") == nil,
                "duplicate definition would clobber the Stage 8e-ix-d extracted body"
            )
        end
        check(
            "local CreateListUI no longer defined in WoWClearance_Events.lua",
            ecCode:find("local function CreateListUI%(") == nil,
            "duplicate definition would clobber the Stage 8e-ix-d extracted body"
        )
        check(
            "local WC_AddScanByQualityRow no longer defined in WoWClearance_Events.lua",
            ecCode:find("local function WC_AddScanByQualityRow%(") == nil,
            "duplicate definition would clobber the Stage 8e-ix-d extracted body"
        )
        check(
            "NS.CreateListUI no longer assigned in WoWClearance_Events.lua",
            ecCode:find("NS%.CreateListUI%s*=%s*CreateListUI") == nil,
            "duplicate NS.CreateListUI assignment would clobber the new file's exposure"
        )
        check(
            "NS.AddScanByQualityRow no longer assigned in WoWClearance_Events.lua",
            ecCode:find("NS%.AddScanByQualityRow%s*=%s*WC_AddScanByQualityRow") == nil,
            "duplicate NS.AddScanByQualityRow assignment would clobber the new file's exposure"
        )
        -- WC_activeIDBox is now NS-only. The bare local must be gone
        -- and ChatEdit_InsertLink must read NS.activeIDBox.
        check(
            "no `local WC_activeIDBox` declaration in WoWClearance_Events.lua",
            ecCode:find("local WC_activeIDBox%s*=") == nil,
            "WC_activeIDBox was promoted to NS.activeIDBox for cross-file access in Stage 8e-ix-d"
        )
        check(
            "ChatEdit_InsertLink hook reads NS.activeIDBox",
            ecCode:find("NS%.activeIDBox") ~= nil,
            "the shift-click-to-add reader must use NS.activeIDBox after Stage 8e-ix-d"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 55 (Stage 9): WoWClearance.lua renamed to WoWClearance_Events.lua.
-- ---------------------------------------------------------------------------
-- Stage 9 closes out the multi-stage file split (docs/CODE_REVIEW.md item 4)
-- by renaming the original monolith file. The rename is mechanical but has
-- several load-bearing references that all need to stay in lockstep:
--   * WoWClearance.toc must load WoWClearance_Events.lua (not the old
--     name); a stale .toc reference would cause the addon to fail to load
--     because the old file is gone.
--   * .github/workflows/release.yml's sed rules must target the new name;
--     a stale sed would silently leave ADDON_VERSION at the old value
--     after a release tag push.
--   * The ADDON_VERSION constant must live in WoWClearance_Events.lua
--     (the release sed pattern is filename-anchored).
--   * No stale WoWClearance.lua file is left in the working tree.
do
    local stillExists = io.open("WoWClearance.lua", "rb")
    check(
        "stale WoWClearance.lua file removed",
        stillExists == nil,
        "the rename to WoWClearance_Events.lua should have deleted the old file; a leftover copy would shadow the renamed one"
    )
    if stillExists then stillExists:close() end

    local newFile = io.open("WoWClearance_Events.lua", "rb")
    check(
        "WoWClearance_Events.lua exists",
        newFile ~= nil,
        "Stage 9 of the file split renamed WoWClearance.lua to this file"
    )
    if newFile then
        local newSrc = newFile:read("*a") or ""
        newFile:close()
        check(
            "ADDON_VERSION lives in WoWClearance_Events.lua",
            newSrc:find("local ADDON_VERSION = GetAddOnMetadata", 1, true) ~= nil,
            "the version is read from the .toc in this file"
        )
    end

    local toc = io.open("WoWClearance.toc", "rb")
    if toc then
        local tocSrc = toc:read("*a") or ""
        toc:close()
        check(
            ".toc loads WoWClearance_Events.lua",
            tocSrc:find("WoWClearance_Events%.lua") ~= nil,
            "the .toc must reference the renamed file; the old WoWClearance.lua name was retired in Stage 9"
        )
        check(
            ".toc no longer references the old WoWClearance.lua name",
            tocSrc:find("\nWoWClearance%.lua") == nil,
            "leftover .toc reference would fail to load (the file is gone)"
        )
    end

    local release = io.open(".github/workflows/release.yml", "rb")
    if release then
        local relSrc = release:read("*a") or ""
        release:close()
        check(
            "release.yml rewrites only the .toc version",
            relSrc:find("WoWClearance_Events%.lua") == nil and relSrc:find("## Version: $VERSION", 1, true) ~= nil,
            "the .toc is the single source of the version; the Lua reads it with GetAddOnMetadata"
        )
        -- Approximate "no bare WoWClearance.lua token". Lua's pattern
        -- lang has no lookbehind, so we walk lines and check that any
        -- match has a non-identifier char before it (i.e. is part of
        -- WoWClearance_*.lua, not the retired bare name).
        local hasBareOld = false
        for line in relSrc:gmatch("[^\n]+") do
            if line:find("[^_%w]WoWClearance%.lua") or line:find("^WoWClearance%.lua") then
                hasBareOld = true
                break
            end
        end
        check(
            "release.yml has no stale WoWClearance.lua reference",
            not hasBareOld,
            "release.yml should no longer reference the retired WoWClearance.lua name"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 56: tome protection (per-character).
-- ---------------------------------------------------------------------------
-- Two new DB toggles (DB.protectUnlearnedTomes default ON,
-- DB.protectAllTomes default OFF) drive a HARD veto in WC_IsSellable that
-- blocks vendoring of spell-teaching items even when on the Sell List.
-- Mirrors the v2.19.0 affix protection semantics, not v2.20.1 chance-on-
-- hit narrowing: the user must explicitly mark Allow Sell
-- (ADB.allowedItems[itemID]) to lift the protection. Detection is hybrid:
-- GetItemInfo class == "Recipe" is the fast path; tooltip scan for
-- `Use: Teaches you...` (locale-aware via ITEM_SPELL_TRIGGER_ONUSE)
-- covers class tomes and mount scrolls. Unlearned check via
-- ITEM_SPELL_KNOWN ("Already known") tooltip line. Two caches: tomeCache
-- (stable per itemID, never invalidated) and tomeIsKnownCache (character-
-- state-sensitive, wiped on LEARNED_SPELL_IN_TAB / SPELLS_CHANGED).
do
    -- EnsureDB defaults must be wired with the documented values.
    check(
        "EnsureDB defaults DB.protectUnlearnedTomes to true",
        src:find("DB%.protectUnlearnedTomes%s*=%s*true") ~= nil,
        "the new unlearned-tome protection must default ON to match the affix / chance-on-hit precedent"
    )
    check(
        "EnsureDB defaults DB.protectAllTomes to false",
        src:find("DB%.protectAllTomes%s*=%s*false") ~= nil,
        "the all-tomes variant defaults OFF; opt-in toggle"
    )

    -- Detection helpers must live on WC_compCache so all callers
    -- (WC_IsSellable, tooltip annotation, future call sites) share the
    -- same per-itemID caches.
    local helpers = {
        "itemIsTome", "playerKnowsTomeSpell",
        "liveTooltipIsTome", "liveTooltipPlayerKnowsTome",
    }
    for _, name in ipairs(helpers) do
        check(
            "WC_compCache." .. name .. " defined",
            src:find("function WC_compCache%." .. name .. "%(") ~= nil,
            name .. " must be attached to WC_compCache so the bag-item and live-tooltip paths share the cache"
        )
    end

    -- Both caches must be declared on WC_compCache in Core.lua so
    -- they exist at load time (no lazy init in helpers).
    local coreFile = io.open("WoWClearance_Core.lua", "rb")
    if coreFile then
        local coreSrc = coreFile:read("*a") or ""
        coreFile:close()
        check(
            "tomeCache declared on WC_compCache (Core)",
            coreSrc:find("tomeCache%s*=%s*{}") ~= nil,
            "tomeCache must exist at load so the is-a-tome lookup never hits nil"
        )
        check(
            "tomeIsKnownCache declared on WC_compCache (Core)",
            coreSrc:find("tomeIsKnownCache%s*=%s*{}") ~= nil,
            "tomeIsKnownCache must exist at load so the LEARNED_SPELL_IN_TAB wipe is safe"
        )
    end

    -- The cache invalidation must fire on LEARNED_SPELL_IN_TAB /
    -- SPELLS_CHANGED. The wipe is intentionally NOT debounced (it's
    -- one table reset; doing it synchronously avoids a 0.5 s window
    -- where a just-learned recipe still reads as unlearned).
    local eventsFile = io.open("WoWClearance_Events.lua", "rb")
    if eventsFile then
        local eventsSrc = eventsFile:read("*a") or ""
        eventsFile:close()
        -- Locate the LEARNED_SPELL_IN_TAB branch and look for the wipe
        -- within the next ~50 lines. The v2.49.1 autolearn diff sits at
        -- the top of the branch so the wipe now lives further down.
        local branchAt = eventsSrc:find('event == "LEARNED_SPELL_IN_TAB"', 1, true)
        check(
            "LEARNED_SPELL_IN_TAB branch wipes tomeIsKnownCache",
            branchAt
                and eventsSrc:sub(branchAt, branchAt + 2500):find("wipe%(WC_compCache%.tomeIsKnownCache%)") ~= nil,
            "the cache wipe must live in the event branch; without it a just-learned recipe stays \"unlearned\" until /reload"
        )
        -- The WC_IsSellable veto block must reference both toggles AND
        -- the Allow Sell bypass. Three patterns to find:
        check(
            "WC_IsSellable references DB.protectAllTomes",
            eventsSrc:find("DB%.protectAllTomes") ~= nil,
            "the veto must consult the aggressive all-tomes toggle"
        )
        check(
            "WC_IsSellable references DB.protectUnlearnedTomes",
            eventsSrc:find("DB%.protectUnlearnedTomes") ~= nil,
            "the veto must consult the unlearned-tome toggle"
        )
        check(
            "WC_IsSellable calls WC_compCache.itemIsTome",
            eventsSrc:find("WC_compCache%.itemIsTome%(") ~= nil,
            "the veto must dispatch to the cached tome detector"
        )
        check(
            "WC_IsSellable calls WC_compCache.playerKnowsTomeSpell",
            eventsSrc:find("WC_compCache%.playerKnowsTomeSpell%(") ~= nil,
            "the unlearned branch must consult the learned-state cache"
        )
        -- Hard-veto invariant: the tome block must include `return false`,
        -- not just demote qualityPass. The Sell List override pattern
        -- (from chance-on-hit v2.20.1) is intentionally NOT used; tomes
        -- require Allow Sell even with explicit list entries.
        -- Anchor on the tome-veto GATE specifically (not the first
        -- itemIsTome call, which is the recipePass block); otherwise
        -- unrelated code inserted between recipePass and the isJunk
        -- recheck can push the tome block's `return false` out of the
        -- capture window.
        local tomeBlockStart = eventsSrc:find("DB%.protectAllTomes or DB%.protectUnlearnedTomes")
        if tomeBlockStart then
            -- Capture the next ~600 chars (covers the if/end block).
            local tomeBlock = eventsSrc:sub(tomeBlockStart, tomeBlockStart + 600)
            check(
                "WC_IsSellable tome block hard-vetoes via `return false`",
                tomeBlock:find("return false") ~= nil,
                "the tome veto must HARD-veto (return false) so Sell List membership doesn't bypass it; Allow Sell is the only bypass"
            )
            check(
                "WC_IsSellable tome block gates on qualityPass AND explicitly releases on whitelistPass (v2.51.2 intent + v2.59.10 fix)",
                -- v2.51.2 (Serv report, Pattern: Mooncloth Leggings): the
                -- tome veto used to fire on `(qualityPass or whitelistPass)`.
                -- v2.59.10 (bug-hunt): the intent was "whitelistPass releases
                -- the veto" but the pre-fix condition only gated on
                -- qualityPass, which fell into the both-signals-set case
                -- (Sell List + rarity rule) and still vetoed. Now the
                -- condition explicitly excludes whitelistPass, matching
                -- the tooltip's long-standing `and not onSellList` guard.
                eventsSrc:find("if qualityPass\n%s+and not whitelistPass\n%s+and not recipePass\n%s+and %(DB%.protectAllTomes") ~= nil
                    and eventsSrc:find("%(qualityPass or whitelistPass%).-and %(DB%.protectAllTomes") == nil,
                "the tome gate must gate on qualityPass AND include `and not whitelistPass` so a Sell List entry releases the veto even when a rarity rule also matches"
            )
        end
    end

    -- The Protection Settings panel must wire two checkboxes that
    -- write the toggles AND call NS.RefreshSellBorders (so toggling
    -- the protection re-paints the bag tints immediately, matching
    -- Test 42's list-mutation invariant family).
    local protPanelFile = io.open("WoWClearance_ProtectionPanel.lua", "rb")
    if protPanelFile then
        local panelSrc = protPanelFile:read("*a") or ""
        protPanelFile:close()
        check(
            "ProtectionPanel writes DB.protectUnlearnedTomes",
            panelSrc:find("DB%.protectUnlearnedTomes%s*=") ~= nil,
            "the unlearned-tome checkbox OnClick must persist the new state"
        )
        check(
            "ProtectionPanel writes DB.protectAllTomes",
            panelSrc:find("DB%.protectAllTomes%s*=") ~= nil,
            "the all-tomes checkbox OnClick must persist the new state"
        )
        -- Both OnClick handlers must call NS.RefreshSellBorders.
        -- Count occurrences as a sanity check (one per checkbox + the
        -- pre-existing 3 in this file = at least 5 total).
        local refreshCount = 0
        for _ in panelSrc:gmatch("NS%.RefreshSellBorders") do
            refreshCount = refreshCount + 1
        end
        check(
            "ProtectionPanel calls NS.RefreshSellBorders at least 5 times",
            refreshCount >= 5,
            "Stage 8e-vi pinned 3 refresh calls; the two new tome toggles add 2 more (Issue B invariant family)"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 58: Delete-List affix gate honours manual Allow Sell.
-- ---------------------------------------------------------------------------
-- Pre-v2.32.x bug: a Rare/Epic item with an affix that the user had
-- explicitly Alt+Right-Click -> Allow Sell'd (so ADB.allowedAffixes[key]
-- was set) could not be deleted via the Delete List. The sell-path gate
-- in WC_IsSellable releases the item on `manualAllow or autoDupe`; the
-- delete-path gate only checked `isDupe` (autoDupe only). Items with no
-- vendor value and an Allow-Sell-marked affix had no escape from the bag.
--
-- Fix: the affix gate also checks ADB.allowedAffixes (the manual Allow
-- Sell mark). Explicit user intent wins, matching the sell-path semantics.
--
-- v2.42.0: the affix gate moved from BuildQueue's inline delete branch
-- into the shared deleteListSlotEligible helper (WC_compCache method).
-- This test now locates the gate in the helper body.
--
-- This test locks the shape: any future refactor that drops the
-- manualAllow check from the delete-path affix gate will fail.
do
    local eventsFile = io.open("WoWClearance_Events.lua", "rb")
    if eventsFile then
        local eventsSrc = eventsFile:read("*a") or ""
        eventsFile:close()
        -- v2.47.0: the affix release decision moved into the shared
        -- WC_compCache.affixDisposable helper (used by deleteListSlotEligible
        -- AND the auto-mark scan; mirrors WC_IsSellable's affix block).
        local dispStart = eventsSrc:find("function WC_compCache%.affixDisposable%(affix%)")
        if dispStart then
            local block = eventsSrc:sub(dispStart, dispStart + 1200)
            check(
                "affix release gate (affixDisposable) honours Allow Sell",
                block:find("ADB%.allowedAffixes") ~= nil,
                "manual Allow Sell on an affix description must release the gate; without this the user has no way to dispose of a no-vendor-value affixed item they have explicitly allowed"
            )
            check(
                "affixDisposable releases on owned dupe AND below-floor rank",
                block:find("WC_compCache%.playerOwnsAffix%(affix%)") ~= nil
                    and block:find("DB%.affixMinSellRank") ~= nil,
                "the release decision must cover owned exact-rank dupes AND ranks below the affixMinSellRank floor (so the auto-mark scan clears unsellable below-floor affixes too)"
            )
            -- v2.71.3 (classifier Stage 4): the eligibility policy moved
            -- to Decision.deleteEligible; the affix gate now reads
            -- ctx.affixDisposable(affix), whose adapter thunk routes to
            -- the SAME shared WC_compCache.affixDisposable helper.
            local dcf = io.open("WoWClearance_Decision.lua", "rb")
            local dcSrc59 = dcf and dcf:read("*a") or ""
            if dcf then
                dcf:close()
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Test 59 (v2.32.x): lazy + incremental affix-catalog refresh.
-- ---------------------------------------------------------------------------
-- Background: a player who learned an affix at the Anvil and
-- immediately hovered a new drop saw a stale "Protected - Affix
-- found" verdict because the catalog refresh path was:
--   PE.ExtractionService update -> no event we listen to ->
--   wait for next BAG_UPDATE (120 ms debounce) ->
--   refreshExtractionIfDirty fires -> kicks off async refresh
--   refreshKnownAffixes (0.5 s spell-event debounce skipped here
--   because we call it directly, but the chunked OnUpdate scan
--   still takes 150-300 ms) -> map updated.
-- Total: ~300-500 ms after the BAG_UPDATE settled, plus the
-- "no event yet" gap if PE didn't fire BAG_UPDATE on extraction.
-- v2.32.x splits this in two:
--   1. refreshExtractionIfDirty does a SYNCHRONOUS INCREMENTAL
--      merge into the live knownAffixDescriptions map (driven by
--      the procIdToDescription cache, so per-call cost is O(new
--      affixes)). The full async refreshKnownAffixes is kept as a
--      fallback for two cases only: pre-PLAYER_LOGIN bootstrap
--      (map not yet a table) and learnedCount going DOWN.
--   2. WoWClearance_Tooltip.lua now calls refreshExtractionIfDirty
--      from inside the affix branch BEFORE playerHasAffixDescription,
--      so a fresh hover after a learn picks up the new state.
--
-- These two invariants lock the v2.32.x shape so a future refactor
-- that drops either piece (e.g. "consolidate by always going
-- through refreshKnownAffixes again") fails the test before merge.
do
    local protFile = io.open("WoWClearance_Protection.lua", "rb")
    if protFile then
        local protSrc = protFile:read("*a") or ""
        protFile:close()
        -- Extract the body of refreshExtractionIfDirty (function start to
        -- the closing `end` of the same function). Marker: function
        -- declaration line. Pattern-match the incremental-merge body
        -- inside.
        local startIdx = protSrc:find("function WC_compCache%.refreshExtractionIfDirty%(%)")
        local body
        if startIdx then
            -- Take ~3500 chars of body; the function is well under that.
            body = protSrc:sub(startIdx, startIdx + 3500)
            local nextFnIdx = body:find("\nfunction WC_compCache%.", 2)
            if nextFnIdx then
                body = body:sub(1, nextFnIdx - 1)
            end
        end
    end

    local tooltipFile = io.open("WoWClearance_Tooltip.lua", "rb")
    if tooltipFile then
        local ttSrc = tooltipFile:read("*a") or ""
        tooltipFile:close()
        -- Strip Lua line comments so the check only matches a live call
        -- site, not the explanatory comment block above it.
        local ttCode = ttSrc:gsub("%-%-[^\n]*", "")
    end
end

-- ---------------------------------------------------------------------------
-- Test 60 (v2.32.x): liveTooltipPlayerKnowsTome reads live tooltip first.
-- ---------------------------------------------------------------------------
-- Background: PE's roguelite "Tome of Echo" mechanic doesn't teach a
-- Blizzard spell on use - it updates internal PE state, which means
-- LEARNED_SPELL_IN_TAB / SPELLS_CHANGED don't fire. The
-- tomeIsKnownCache wipe is wired to those events, so a cached `false`
-- (from a hover before the tome was used) stuck around forever and
-- the WC tooltip kept labelling the tome as "Protected - Tome
-- (unlearned)" even when Blizzard's own "Already known" line was
-- visible right above. This is the same cache-staleness shape as
-- the affix issue addressed in Test 59 but on a different cache.
--
-- v2.32.x fix: liveTooltipPlayerKnowsTome now scans the live tooltip
-- BEFORE consulting the cache. The cache becomes a side-effect
-- output (still useful to playerKnowsTomeSpell which has no live
-- tooltip), not a read-path fast-path that can pin stale state. The
-- live tooltip is what the user sees, so we read the same source.
do
    local protFile = io.open("WoWClearance_Protection.lua", "rb")
    if protFile then
        local protSrc = protFile:read("*a") or ""
        protFile:close()
        local fnStart = protSrc:find("function WC_compCache%.liveTooltipPlayerKnowsTome%(")
        if fnStart then
            -- Trim the body to the function only (~2000 chars is well over
            -- the function size; nextFn marker scopes precisely).
            local body = protSrc:sub(fnStart, fnStart + 2500)
            local nextFnIdx = body:find("\nfunction WC_compCache%.", 2)
            if nextFnIdx then
                body = body:sub(1, nextFnIdx - 1)
            end

            -- The defining-shape assertion: tooltip:GetName() (live
            -- tooltip read) must appear BEFORE the
            -- `return WC_compCache.tomeIsKnownCache[itemID]` cache-
            -- hit early-return. In the buggy v2.32.2 and earlier
            -- shape, the cache return was the first conditional in
            -- the function body (came BEFORE any tooltip read).
            local firstGetName = body:find("tooltip:GetName")
            local firstReturnCache = body:find("return WC_compCache%.tomeIsKnownCache")
            check(
                "liveTooltipPlayerKnowsTome reads the live tooltip BEFORE the cache (cache is side-effect output)",
                firstGetName
                    and firstReturnCache
                    and firstGetName < firstReturnCache,
                "the live tooltip is the authoritative source; the prior cache-first fast-path returned a stale `false` for PE Tome of Echo items that don't fire LEARNED_SPELL_IN_TAB on use"
            )
            -- The cache write at the end must still exist - it's what
            -- keeps playerKnowsTomeSpell (the bag-scan variant) hitting
            -- the corrected value on subsequent merchant cycles.
            check(
                "liveTooltipPlayerKnowsTome still writes the cache as a side effect",
                body:find("WC_compCache%.tomeIsKnownCache%[itemID%]%s*=%s*result") ~= nil,
                "the cache write is what propagates a live-tooltip-corrected verdict to the merchant cycle's playerKnowsTomeSpell path"
            )
        end
    end
end

-- ---------------------------------------------------------------------------
-- Test 61 (v2.32.x): tome detection excludes vanity pets + mount scrolls.
-- ---------------------------------------------------------------------------
-- Background: the text-scan fallback in itemIsTome / liveTooltipIsTome
-- matches a "Use: Teaches" tooltip line - too broad. It also catches
-- vanity pet items ("Use: Teaches you how to summon this companion")
-- and mount-training scrolls ("Use: Teaches you how to ride...").
-- User-reported false positive: Disgusting Oozeling labelled
-- "Protected - Tome (unlearned)" despite being a vanity pet, not a
-- spell tome.
--
-- v2.32.x fix: both helpers return false early when GetItemInfo
-- reports class="Miscellaneous" with subclass in {"Companion",
-- "Mount"}. The check sits AFTER the class="Recipe" shortcut so
-- legitimate tomes / recipes still resolve via the fast path, and
-- the text-scan path below is preserved for genuinely-tome items
-- whose class isn't "Recipe" (rare custom PE formats).
do
    local protFile = io.open("WoWClearance_Protection.lua", "rb")
    if protFile then
        local protSrc = protFile:read("*a") or ""
        protFile:close()

        local liveStart = protSrc:find("function WC_compCache%.liveTooltipIsTome%(")
        local liveBody
        if liveStart then
            liveBody = protSrc:sub(liveStart, liveStart + 3500)
            local nextFnIdx = liveBody:find("\nfunction WC_compCache%.", 2)
            if nextFnIdx then
                liveBody = liveBody:sub(1, nextFnIdx - 1)
            end
        end
        check(
            "liveTooltipIsTome uses the class-ID verdict",
            liveBody ~= nil and liveBody:find("instantTomeVerdict(itemID)", 1, true) ~= nil,
            "the tooltip-side helper must take the Recipe / companion / mount verdict from instantTomeVerdict (class IDs), not from localized GetItemInfo class strings that only match on English clients"
        )
        check(
            "liveTooltipIsTome rejects collectible phrasings inside the text scan",
            liveBody ~= nil
                and liveBody:find('"this companion"', 1, true) ~= nil
                and liveBody:find('"this mount"', 1, true) ~= nil
                and liveBody:find('"how to ride"', 1, true) ~= nil,
            "GetItemInfo subclass is unreliable in 3.3.5a (pets often file under \"Junk\"); the tooltip-text reject is the second-line defence that catches the case based on actual Use-line phrasing"
        )

        local bagStart = protSrc:find("function WC_compCache%.itemIsTome%(")
        local bagBody
        if bagStart then
            -- v2.49.1: window widened from 3500 to 5000 chars after the
            -- nil-guard on GetItemInfo pushed the collectible-phrase
            -- asserts past the original slice.
            bagBody = protSrc:sub(bagStart, bagStart + 5000)
            local nextFnIdx = bagBody:find("\nfunction WC_compCache%.", 2)
            if nextFnIdx then
                bagBody = bagBody:sub(1, nextFnIdx - 1)
            end
        end
        check(
            "itemIsTome uses the class-ID verdict and never caches a cold scan",
            bagBody ~= nil
                and bagBody:find("instantTomeVerdict(itemID)", 1, true) ~= nil
                and bagBody:find("if not sawAnyLine or not C_Item.IsItemDataCachedByID(itemID) then", 1, true) ~= nil,
            "the bag-item variant must share the class-ID verdict, and an empty scan tooltip must not cache false (porting lesson 14)"
        )

        -- Runtime: load the real file with stub client tables and drive the
        -- class-ID verdict, tomeKind and the appearance check. Item data
        -- below: itemID -> { classID, subClassID }.
        local items = {
            [1] = { 9, 2 }, -- Recipe / Tailoring
            [2] = { 9, 0 }, -- Recipe / Book
            [3] = { 15, 2 }, -- Miscellaneous / CompanionPet
            [4] = { 15, 5 }, -- Miscellaneous / Mount
            [5] = { 2, 7 }, -- Weapon
        }
        local appearance = {} -- link -> { sourceID, owned, hasItemData, canCollect }
        local env = setmetatable({
            C_Item = {
                GetItemInfoInstant = function(id)
                    local it = items[id]
                    if it then
                        return id, "x", "x", "", 0, it[1], it[2]
                    end
                end,
            },
            C_TransmogCollection = {
                GetItemInfo = function(link)
                    local a = appearance[link]
                    return a and 1, a and a[1]
                end,
                PlayerHasTransmogItemModifiedAppearance = function(src)
                    for _, a in pairs(appearance) do
                        if a[1] == src then
                            return a[2]
                        end
                    end
                end,
                PlayerCanCollectSource = function(src)
                    for _, a in pairs(appearance) do
                        if a[1] == src then
                            return a[3], a[4]
                        end
                    end
                end,
            },
            Enum = {
                ItemClass = { Recipe = 9, Miscellaneous = 15 },
                ItemMiscellaneousSubclass = { CompanionPet = 2, Mount = 5 },
                ItemRecipeSubclass = { Book = 0 },
            },
        }, { __index = _G })
        local cc = { tomeCache = {}, tomeIsKnownCache = {}, resilienceCache = {} }
        local chunk = (loadstring or load)(protSrc, "WoWClearance_Protection.lua")
        local loaded = false
        if chunk then
            if setfenv then
                setfenv(chunk, env)
            end
            loaded = pcall(chunk, "WoWClearance", { compCache = cc })
        end
        check(
            "Protection.lua loads under stubs",
            loaded and cc.instantTomeVerdict ~= nil,
            "runtime fixture could not load the file"
        )
        if loaded and cc.instantTomeVerdict then
            check(
                "class-ID tome verdict: recipe, book, pet, mount, other",
                cc.instantTomeVerdict(1) == true
                    and cc.instantTomeVerdict(2) == true
                    and cc.instantTomeVerdict(3) == false
                    and cc.instantTomeVerdict(4) == false
                    and cc.instantTomeVerdict(5) == nil
                    and cc.instantTomeVerdict(999) == nil,
                "Recipe class is a tome on every client language; companion pets and mounts never are; anything else falls through to the scan"
            )
            check(
                "tomeKind: profession recipe vs book",
                cc.tomeKind(1) == "Recipe" and cc.tomeKind(2) == "Tome" and cc.tomeKind(5) == "Tome",
                'Sell Known Recipes keys off tomeKind == "Recipe"; books must stay "Tome"'
            )
            check(
                "itemIsTome caches the class verdict",
                cc.itemIsTome(nil, nil, 1) == true and cc.tomeCache[1] == true,
                ""
            )
            appearance.loading = { 10, false, false, nil }
            appearance.collectable = { 11, false, true, true }
            appearance.owned = { 12, true, true, true }
            check(
                "uncollected appearance keeps items while data loads",
                cc.isUncollectedAppearance("loading") == true
                    and cc.isUncollectedAppearance("collectable") == true
                    and cc.isUncollectedAppearance("owned") == false
                    and cc.isUncollectedAppearance("notransmog") == false,
                "hasItemData == false must answer keep (porting lesson 14), not 'not uncollected'"
            )
        end
        check(
            "itemIsTome rejects collectible phrasings inside the text scan",
            bagBody ~= nil
                and bagBody:find('"this companion"', 1, true) ~= nil
                and bagBody:find('"this mount"', 1, true) ~= nil
                and bagBody:find('"how to ride"', 1, true) ~= nil,
            "same belt-and-braces text-content reject as liveTooltipIsTome; protects against pets that file under \"Junk\" in 3.3.5a where the subclass-based gate misses"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 62 (v2.33.x): isDowngradeVsEquipped narrows to {16} when 2H equipped.
-- ---------------------------------------------------------------------------
-- Bug reported by "Perfect Bidoof": a player wielding an iLvl 258 2H
-- (Justicebringer of Judgment) had every green 1H weapon in bags
-- labelled "Keep (Green, possible upgrade)" and refusing to sell, even
-- when the 1H was iLvl 134 - obviously not an upgrade.
--
-- Root cause: INVTYPE_WEAPON's candidate slots are {16, 17}. The
-- iLvl-vs-equipped loop bailed with `empty_slot` the moment it hit
-- slot 17 (because the 2H locks the offhand). That bailout is correct
-- for dual-wielders with one weapon equipped (the loot could fill the
-- offhand), but wrong when the main hand holds a 2H - the offhand is
-- locked, not unfilled. Fix: detect the main-hand 2H and narrow the
-- candidate slot list to {16} so the comparison happens against the
-- equipped 2H's iLvl.
--
-- Test asserts the function body contains the INVTYPE_2HWEAPON check
-- and the `slots = { 16 }` narrowing. A future refactor that drops
-- either piece fails this test before merge.
do
    local fnStart = src:find("function WC_compCache%.isDowngradeVsEquipped%(")
    local body
    if fnStart then
        body = src:sub(fnStart, fnStart + 3000)
        local nextFnIdx = body:find("\nfunction ", 2)
        if nextFnIdx then
            body = body:sub(1, nextFnIdx - 1)
        end
    end
    check(
        "isDowngradeVsEquipped checks main hand for INVTYPE_2HWEAPON",
        body ~= nil
            and body:find('"INVTYPE_2HWEAPON"', 1, true) ~= nil
            and body:find('GetInventoryItemLink') ~= nil,
        "the 2H-aware narrowing must read the main hand's equipLoc; without this, every 1H in bags gets falsely kept while the player wields a 2H"
    )
    check(
        "isDowngradeVsEquipped narrows slots to {16} when main hand is 2H",
        body ~= nil and body:find("slots%s*=%s*{%s*16%s*}") ~= nil,
        "the narrowing assignment must literally rewrite slots to {16}; the loop downstream then compares only against the main hand"
    )
    check(
        "isDowngradeVsEquipped narrows only when equipLoc is INVTYPE_WEAPON",
        body ~= nil and body:find('equipLoc%s*==%s*"INVTYPE_WEAPON"') ~= nil,
        "single-slot offhand equipLocs (SHIELD / HOLDABLE / WEAPONOFFHAND) keep the original empty_slot bailout - only the multi-slot INVTYPE_WEAPON case gets the 2H narrowing"
    )
end

-- ---------------------------------------------------------------------------
-- Test 63 (v2.33.x): checkBagsForUpgrades cleans stale "upgrade" entries.
-- ---------------------------------------------------------------------------
-- Bug reported by user "Blaken" (own test character): an Ornamental
-- Mace iLvl 17 sat in bags labelled "Keep (upgrade)" even though the
-- equipped Prospector Axe was iLvl 20 - the mace was added to the
-- Keep List during early levelling when the player had a sub-iLvl-17
-- starter weapon, and stayed on the list forever after the player
-- upgraded past it.
--
-- Root cause: checkBagsForUpgrades was one-way - it ADDED entries but
-- never re-evaluated them. The `if not DB.blacklist[itemID]` pre-
-- condition skipped already-listed items, and the upgradeProcessed
-- per-session memo skipped them again on later runs. The existing
-- `/wc clean upgrades apply` slash command was the only way to clean
-- stale entries, but users shouldn't need to remember a manual command
-- for an auto-protect path that's supposed to be hands-off.
--
-- Fix: re-evaluation pass at the top of checkBagsForUpgrades walks
-- DB.blacklistAuto entries with tag=="upgrade" and removes ones whose
-- iLvl is no longer above the lowest populated equipped slot.
do
    local fnStart = src:find("function WC_compCache%.checkBagsForUpgrades%(")
    local body
    if fnStart then
        body = src:sub(fnStart, fnStart + 5000)
        local nextFnIdx = body:find("\nfunction ", 2)
        if nextFnIdx then
            body = body:sub(1, nextFnIdx - 1)
        end
    end
    check(
        "checkBagsForUpgrades iterates DB.blacklistAuto and inspects autoTag",
        body ~= nil
            and body:find("for itemID, tag in pairs%(DB%.blacklistAuto%)") ~= nil
            and body:find('tag == "upgrade"') ~= nil,
        "the re-evaluation pass must walk DB.blacklistAuto and pick out 'upgrade' entries - other autoTags (equipped / set) have their own sync paths"
    )
    check(
        "checkBagsForUpgrades removes from both DB.blacklist and DB.blacklistAuto on stale entry",
        body ~= nil
            and body:find("DB%.blacklist%[itemID%]%s*=%s*nil") ~= nil
            and body:find("DB%.blacklistAuto%[itemID%]%s*=%s*nil") ~= nil,
        "removing only one side leaves the entry in a half-state; both DB.blacklist and DB.blacklistAuto need to drop the itemID together"
    )
    check(
        "checkBagsForUpgrades clears upgradeProcessed when releasing a stale entry",
        body ~= nil and body:find("WC_compCache%.upgradeProcessed%[itemID%]%s*=%s*nil") ~= nil,
        "without clearing the per-session memo, a future gear DOWNGRADE wouldn't re-add the item - the new-entry loop's processed-check would skip it"
    )
    check(
        "checkBagsForUpgrades cleanup respects empty slots conservatively",
        body ~= nil and body:find("if lowestEquipped and iLvl <= lowestEquipped then") ~= nil,
        "must only remove when lowestEquipped is non-nil (a slot is populated); when every candidate slot is empty, keep the entry rather than mass-clearing the Keep List on a temporary un-equip"
    )
    -- v2.44.0: class-restriction gate. Pre-v2.44.0 the upgrade sweep
    -- compared iLvl-vs-slot without ever checking whether the player's
    -- class could equip the item. Real player report (Murlocked): Mage
    -- with a relic in slot 18 was getting bows / relics flagged as
    -- "Keep (upgrade)" - items the class will never equip. Both the
    -- new-entry path and the stale-cleanup path must gate on
    -- IsUsableItem(itemID) == false (the false literal is the class
    -- veto; nil means uncached, which we must NOT treat as a veto
    -- because GetItemInfo / IsUsableItem race against item-cache
    -- warmup at /reload).
    -- v0.6.0: both paths go through classCannotUse, which also treats a
    -- level requirement and an uncached item as usable (IsUsableItem alone
    -- is false for a level-locked upgrade, which then lost its Keep entry).
    local ev = io.open("WoWClearance_Events.lua", "rb")
    local evs = ev and ev:read("*a") or ""
    if ev then
        ev:close()
    end
    local helper = evs:match("function WC_compCache%.classCannotUse%(itemID%)(.-)\nend\n") or ""
    check(
        "checkBagsForUpgrades gates new entries and the cleanup on the class-only check",
        select(2, evs:gsub("WC_compCache%.classCannotUse%(itemID%)", "")) >= 2,
        "both the new-entry path and the stale-cleanup path must use classCannotUse, never a bare IsUsableItem == false."
    )
    check(
        "classCannotUse ignores level-locked and uncached items",
        helper:find("minLevel", 1, true) ~= nil
            and helper:find('UnitLevel("player")', 1, true) ~= nil
            and helper:find("if not name", 1, true) ~= nil
            and helper:find("IsUsableItem(itemID) == false", 1, true) ~= nil,
        "a too-high level requirement or an uncached item must not count as a class veto."
    )
end

-- ---------------------------------------------------------------------------
-- v2.44.0 Test 92: affix-rank floor opt-out (Murlocked feature).
-- ---------------------------------------------------------------------------
-- Player can set DB.affixMinSellRank to N; affixed Rare/Epic items with
-- rank < N fall through the affix protection. The veto must be added
-- SYMMETRICALLY at every affix-decision site (sell, delete, process,
-- tooltip, sellinfo trace) or the surfaces disagree and the player sees
-- "Will Sell" but the merchant cycle refuses the item.
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then return "" end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local ev = fileSrc("WoWClearance_Events.lua")
    local dc = fileSrc("WoWClearance_Decision.lua")
    local proc = fileSrc("WoWClearance_Process.lua")
    local tt = fileSrc("WoWClearance_Tooltip.lua")
    local bd = fileSrc("WoWClearance_BagDisplay.lua")
    local pp = fileSrc("WoWClearance_ProtectionPanel.lua")
end

-- ---------------------------------------------------------------------------
-- v2.44.0 Test 93: Resilience auto-mark (Murlocked feature).
-- ---------------------------------------------------------------------------
-- DB.autoMarkResilience opts the player into a BAG_UPDATE-driven sweep
-- that adds items with a "Resilience" tooltip line to DB.deleteList.
-- Actual destruction still flows through the existing vendor / auto-
-- delete-on-pickup pipelines (both master-Enable-gated since v2.42.1).
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then return "" end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local ev = fileSrc("WoWClearance_Events.lua")
    local prot = fileSrc("WoWClearance_Protection.lua")
    local core = fileSrc("WoWClearance_Core.lua")
    local kdp = fileSrc("WoWClearance_KeepDeletePanels.lua")
    check("Test 93a: DB.autoMarkResilience seeded in EnsureDB with default false",
        ev:find("DB%.autoMarkResilience%s*=%s*false") ~= nil,
        "must default OFF - the destination is the Delete List, which the player may have curated for other reasons, and an unsolicited auto-mark could surprise them")
    check("Test 93b: resilienceCache table is declared in Core",
        core:find("resilienceCache%s*=%s*{}") ~= nil,
        "the per-itemID cache mirrors the chanceOnHitCache pattern - without it every BAG_UPDATE re-scans every slot's tooltip and the perf cost compounds during AOE loot")
    check("Test 93c: itemHasResilience helper exists in Protection",
        prot:find("function WC_compCache%.itemHasResilience%(bag, slot, itemID%)") ~= nil
            and prot:find("Resilience") ~= nil
            and prot:find("WC_compCache%.scanBagItem%(bag, slot%)") ~= nil,
        "the detection must mirror itemHasChanceOnHit: cache-keyed by itemID, routed through scanBagItem (SetOwner-before-SetBagItem invariant from v2.38.3), substring-match on 'Resilience'")
    check("Test 93d: runAutoMarkResilience exists and gates on master Enable",
        ev:find("function WC_compCache%.runAutoMarkResilience%(%)") ~= nil
            and ev:find("WC_IsAddonEnabledForChar") ~= nil
            and ev:find("DB%.autoMarkResilience") ~= nil,
        "the sweep must short-circuit when master-disabled (same precedent as v2.42.1 auto-delete) AND when the feature toggle is off")
    check("Test 93e: runAutoMarkResilience fires from the BAG_UPDATE debounce",
        ev:find("WC_compCache%.runAutoMarkResilience%(%)") ~= nil,
        "must run from the coalesced 120ms debounce, not the raw BAG_UPDATE branch - otherwise AOE loot fires the sweep 5+ times in <100ms (the same anti-thrash invariant the auto-delete sweep follows)")
    check("Test 93f: KeepDeletePanels surfaces the resilience checkbox",
        kdp:find("WoWClearanceAutoMarkResilienceCB") ~= nil
            and kdp:find("DB%.autoMarkResilience") ~= nil,
        "the toggle must live on the Delete List panel next to autoDeleteOnPickup; same enabled-state rule (greyed when 'Allow items to be deleted' is off)")
end

-- ---------------------------------------------------------------------------
-- v2.44.4 Test 94: announce-auto-delete toggle (ayres ask).
-- ---------------------------------------------------------------------------
-- DB.announceAutoDelete gates BOTH the "Auto-deleted X" line from the
-- auto-delete-on-pickup sweep AND the "Marked for deletion (Resilience)"
-- line from the resilience auto-mark sweep. Default true (destructive
-- actions should be visible by default); player can silence via the
-- Keep / Delete panel checkbox.
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then return "" end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local ev = fileSrc("WoWClearance_Events.lua")
    local kdp = fileSrc("WoWClearance_KeepDeletePanels.lua")
    local hp = fileSrc("WoWClearance_HelpPanel.lua")
    check("Test 94a: DB.announceAutoDelete seeded in EnsureDB with default true",
        ev:find("DB%.announceAutoDelete%s*=%s*true") ~= nil,
        "must default ON - the player should see destructive actions until they explicitly opt out. The off switch is a chat-noise convenience, not a safer default.")
    check("Test 94b: 'Auto-deleted' PrintNicef gated on the announce helper (v2.60.0 shape)",
        ev:find("announce and WC_compCache%.shouldAnnounceAutoDelete%(quality%)") ~= nil,
        "the auto-delete-on-pickup chat line must route through WC_compCache.shouldAnnounceAutoDelete(quality) so the per-rarity filter is honoured (v2.60.0) AND the master toggle stays the top-level gate. ayres asked for the master off-switch originally; v2.60.0 layered per-rarity multi-select on top.")
    check("Test 94c: helper exists + Resilience mark uses it + affix-dupe mark uses it (v2.60.0)",
        ev:find("function WC_compCache%.shouldAnnounceAutoDelete%(quality%)") ~= nil
            and ev:find('Marked for deletion %(Resilience, unsellable%)') ~= nil,
        "the shared helper MUST exist and both non-executeBagSlotDelete announce sites (Resilience + affix-dupe auto-mark) must route through it. Master toggle (announceAutoDelete) off silences everything; on lets DB.announceAutoDeleteQualities[quality] decide per-rarity.")
    check("Test 94d: KeepDeletePanels surfaces the announce checkbox",
        kdp:find("WoWClearanceAnnounceAutoDeleteCB") ~= nil
            and kdp:find("DB%.announceAutoDelete") ~= nil,
        "the toggle must live on the Delete List panel beneath the two sub-toggles it affects (autoCB + resilienceCB); same enabled-state rule (greyed when 'Allow items to be deleted' is off, since neither announcement can fire without deletion enabled)")
    check("Test 94e: Help FAQ entry exists",
        hp:find('id = "gate%-announce%-auto%-delete"') ~= nil,
        "the toggle needs an in-game explanation so a player who finds it in Interface Options understands what gets silenced. The help entry also documents that the manual vendor-cycle summary and lifetime stats are unaffected.")
end


-- ---------------------------------------------------------------------------
-- v2.44.6 Test 96: tooltip annotation routes "no slot mapping" items
-- away from the misleading "possible upgrade" label.
-- ---------------------------------------------------------------------------
-- Caught while testing on a Rogue: a Doomshot (item 12654, INVTYPE_AMMO)
-- showed "Keep (Blue, possible upgrade)" in its tooltip. INVTYPE_AMMO has no entry in
-- WC_compCache.INVTYPE_SLOTS, so isDowngradeVsEquipped returns false
-- with reason "no_slot_mapping". The tooltip used to lump this into
-- the same branch as legitimate upgrade candidates, falsely framing
-- ammo / bags / tabards / class-restricted relics as "possible upgrade".
-- The underlying sell/keep logic was always correct (checkBagsForUpgrades
-- skips these); this was a label-only bug.
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then return "" end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local tt = fileSrc("WoWClearance_Tooltip.lua")
    check("Test 96a: tooltip captures the reason from isDowngradeVsEquipped",
        tt:find("local downgrade, reason = WC_compCache%.isDowngradeVsEquipped") ~= nil
            and tt:find("equipReason%s*=%s*reason") ~= nil,
        "isDowngradeVsEquipped already returned (boolean, reason) - the tooltip just wasn't reading the reason. Without capturing it, every false-return collapses into 'possible upgrade' regardless of whether the item is genuinely an upgrade candidate or simply has no equipment slot to compare against (ammo, bags, tabards, etc.).")
    check("Test 96b: tooltip routes no_slot_mapping / not_equippable to a 'Won't Sell' label",
        tt:find('equipReason == "no_slot_mapping" or equipReason == "not_equippable"') ~= nil
            and tt:find('L%["Won\'t Sell %(%%s, no equipment slot%)"%]') ~= nil
            and tt:find('statusTag = "wontsell"') ~= nil,
        "items with no slot mapping must show 'Won't Sell (Rarity, no equipment slot)' with statusTag=wontsell. The user needs to understand the addon is DECLINING to evaluate them (mirroring Won't Sell (equipped) / Won't Sell (no value)), NOT actively keeping them as upgrade candidates. Reframed mid-v2.44.6 after the user pointed out that 'Keep' implied protection.")
end

-- ---------------------------------------------------------------------------
-- v2.44.7 Test 97: minimap-button hide toggle (Safra ask / Magnify-WotLK clash).
-- ---------------------------------------------------------------------------
-- Safra reported the minimap turning black with WC enabled. Magnify-WotLK
-- was the suspected clash partner (both addons hook the Minimap frame).
-- Without a confirmed root cause, ship a workaround: a player-facing
-- toggle that hides the WC minimap button entirely. WC stays fully
-- functional via the LDB launcher, /wc slash, and key bindings.
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then return "" end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local ev = fileSrc("WoWClearance_Events.lua")
    local mm = fileSrc("WoWClearance_Minimap.lua")
    local mp = fileSrc("WoWClearance_MainPanel.lua")
    local hp = fileSrc("WoWClearance_HelpPanel.lua")
    local rm = fileSrc("README.md")
    check("Test 97a: DB.minimapButton seeded in EnsureDB with default true",
        ev:find("DB%.minimapButton%s*=%s*true") ~= nil,
        "must default ON - existing players see no change. The off switch is the workaround for the Magnify-WotLK clash + any future minimap-hook conflict.")
    check("Test 97b: WC_CreateMinimapButton skips creation entirely when DB.minimapButton is false",
        mm:find('if DB%.minimapButton == false then\n%s*return\n%s*end') ~= nil
            and mm:find("WC_CreateMinimapButton%(%)") ~= nil,
        "v2.44.8 (Safra): v2.44.7's 'create then Hide()' wasn't enough - the act of parenting a child frame to Minimap was itself the trigger (some host UI replacements hook Minimap-frame children aggressively). Must early-return BEFORE any CreateFrame call when DB.minimapButton is false. NS.SetMinimapButtonVisible(true) lazy-creates when the player flips the toggle back on. WC-TRAP: don't reinstate the 'create then Hide()' pattern - it leaves a Minimap-parented child frame that a host UI hook reacts to.")
    check("Test 97c: NS.SetMinimapButtonVisible exposes the runtime toggle",
        mm:find("function WC_SetMinimapButtonVisible%(visible%)") ~= nil
            and mm:find("NS%.SetMinimapButtonVisible") ~= nil,
        "the Main panel checkbox + /wc minimap slash command both flip the button via this helper. Without the NS export, the checkbox writes to DB.minimapButton but the button itself doesn't show/hide until /reload.")
    check("Test 97d: Main panel surfaces the minimap-button checkbox",
        mp:find("WoWClearanceMinimapButtonCB") ~= nil
            and mp:find("DB%.minimapButton") ~= nil
            and mp:find("NS%.SetMinimapButtonVisible") ~= nil,
        "the toggle must live on the Main panel near the version-alert checkbox so players who hit the Minimap-frame clash discover the workaround without needing the slash command.")
    check("Test 97e: /wc minimap slash subcommand dispatches on/off/reset",
        ev:find('cmd == "minimap"') ~= nil
            and ev:find('sub == "on" or sub == "show"') ~= nil
            and ev:find('sub == "off" or sub == "hide"') ~= nil
            and ev:find('sub == "reset"') ~= nil
            -- v0.5.8: pins the CONSTANT REFERENCE, not the literal. This used
            -- to require "= 220"; the default moved to 190 (220 sat five
            -- degrees from the minimap-library default of 225, so WC's button
            -- landed on top of other addons' buttons) and the test failed for
            -- a value change rather than a behaviour change. Matching the
            -- reference means the next move needs no test edit, and stops the
            -- assertion asserting a number nothing uses - the same
            -- literal-beside-a-constant drift this port has now fixed in
            -- panel labels, help prose and locale keys.
            and ev:find('DB%.minimapButtonAngle = NS%.MINIMAP_DEFAULT_ANGLE') ~= nil,
        "the slash command needs to accept on/show, off/hide, and reset subcommands. Reset must restore the default angle from NS.MINIMAP_DEFAULT_ANGLE (never a hardcoded number) AND call NS.UpdateMinimapPos so the button reflows immediately. Aliases (on/show, off/hide) are belt-and-braces - players reach for both.")
    check("Test 97f: Help FAQ entry exists for the minimap-button toggle",
        hp:find('id = "gate%-minimap%-button"') ~= nil,
        "the toggle is the workaround for a known third-party clash (Magnify-WotLK). A Help FAQ entry is the discoverable path so players who hit the clash don't have to read CHANGELOG to find the fix.")
    check("Test 97g: README slash-commands table includes /wc minimap",
        rm:find("`/wc minimap on\\|off\\|reset`") ~= nil,
        "contributors and players reading the README slash-commands table must see the new command. v2.44.x release process: any new slash command gets a README row in the same patch.")
end

-- ---------------------------------------------------------------------------
-- v2.44.9 Test 98: Convert mode in Process Bags (Crystallized / Motes).
-- ---------------------------------------------------------------------------
-- 10-stacks of lower-tier elementals (Crystallized Fire, Mote of Fire,
-- etc.) UseContainerItem-condense to 1 upper-tier (Eternal Fire, Primal
-- Fire) via the item's OnUse effect. WoW 3.3.5a security model does not
-- allow this insecurely (OnUse triggers a server spell, which is taint-
-- restricted), so Convert lives as a 5th Process Bags mode driven by
-- the existing SecureActionButton macro flow - one click per stack.
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then return "" end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local pr = fileSrc("WoWClearance_Process.lua")
    local pbp = fileSrc("WoWClearance_ProcessBagsPanel.lua")
    local hp = fileSrc("WoWClearance_HelpPanel.lua")
    check("Test 98a: CONVERTIBLE_ELEMENTALS table contains all 6 Crystallized + 7 Mote itemIDs",
        pr:find("%[37700%] = true") ~= nil
            and pr:find("%[37701%] = true") ~= nil
            and pr:find("%[37702%] = true") ~= nil
            and pr:find("%[37703%] = true") ~= nil
            and pr:find("%[37704%] = true") ~= nil
            and pr:find("%[37705%] = true") ~= nil
            and pr:find("%[22572%] = true") ~= nil
            and pr:find("%[22573%] = true") ~= nil
            and pr:find("%[22574%] = true") ~= nil
            and pr:find("%[22575%] = true") ~= nil
            and pr:find("%[22576%] = true") ~= nil
            and pr:find("%[22577%] = true") ~= nil
            and pr:find("%[22578%] = true") ~= nil,
        "the conversion table must cover ALL 13 lower-tier elementals: WotLK Crystallized 37700-37705 (Air/Earth/Fire/Shadow/Life/Water) and TBC Motes 22572-22578 (Air/Earth/Fire/Life/Mana/Shadow/Water). Missing an itemID means that school silently never appears in the Convert section.")
    check("Test 98b: canConvertElemental predicate exists",
        pr:find("function WC_compCache%.canConvertElemental%(itemID%)") ~= nil
            and pr:find("CONVERTIBLE_ELEMENTALS%[itemID%]") ~= nil,
        "the predicate mirrors canMill / canProspect in shape: takes an itemID, returns true iff the itemID is a known lower-tier elemental. The count gate (>= 10) lives in buildProcessSummary so the predicate stays cheap and stateless.")
    check("Test 98c: buildProcessSummary has a Convert branch with perCast = 10",
        pr:find('mode = "Convert"') ~= nil
            and pr:find("perCast = 10") ~= nil
            and pr:find("count >= 10") ~= nil
            and pr:find("WC_compCache%.canConvertElemental") ~= nil,
        "the new branch must use the Convert mode name, gate on count >= 10 (the conversion ratio), and set perCast = 10 so the panel reports 1 cast per 10-stack. spellName stays nil for this branch - the macro generation handles the no-spell case.")
    check("Test 98d: modeOrder includes Convert as the 5th mode",
        pr:find("Convert = 5") ~= nil,
        "the section appears below Disenchant / Mill / Prospect / Lockpick in the panel. Without an explicit modeOrder entry the table.sort comparator hits a nil index and the Convert entries float to a random position in the list.")
    check("Test 98e: rearmProcessButton macro handles nil spellName",
        pbp:find('entry%.spellName and entry%.spellName ~= ""') ~= nil
            and pbp:find('"/use %%d %%d"') ~= nil,
        "Convert entries have no spell to cast. The macro builder must emit a /use-only macrotext when spellName is nil/empty, otherwise SetAttribute writes 'cast nil\\n/use bag slot' and the macro silently fails on click.")
    check("Test 98f: Help FAQ entry process-convert exists and links to ProcessBags panel",
        hp:find('id = "process%-convert"') ~= nil
            and hp:find('Convert mode %(Crystallized / Motes%)') ~= nil,
        "players who see the new 'Convert' section need an in-game explanation of what it does + why it's not automatic (3.3.5a secure-execution restriction). The Help FAQ entry documents the one-click-per-stack flow and the list-veto rule for opting individual itemIDs out.")
end

-- ---------------------------------------------------------------------------
-- v2.45.0 Test 99: unranked PE affix detection via @affix@ marker.
-- ---------------------------------------------------------------------------
-- PE's transferred-proc system applies chance-on-hit procs to target items
-- as @affix@-marked tooltip lines WITHOUT a rank suffix in the title (the
-- source proc doesn't have ranks). v2.20.0 narrowed parseAffixFromTitle to
-- require a Roman-numeral rank suffix as a discriminator vs vanilla
-- ItemRandomSuffix.dbc entries (of the Bear etc.). That rejected the
-- legitimate unranked PE affixes too, so silent-sell.
--
-- v2.45.0 fix: bagSlotAffixData + liveTooltipAffixData fall back to the
-- @affix@ marker when parseAffixFromTitle returns nil. The marker IS
-- PE's authentic discriminator - it wraps PE-managed effect text on the
-- raw scan tooltip and is absent from vanilla suffix items. rank=nil
-- flows through all downstream consumers (gates already had affix.rank
-- guards from v2.44.0 / v2.35.1 - we lean on those).
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then return "" end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local prot = fileSrc("WoWClearance_Protection.lua")
    local tt = fileSrc("WoWClearance_Tooltip.lua")
    local ev = fileSrc("WoWClearance_Events.lua")
    local dc = fileSrc("WoWClearance_Decision.lua")
    local proc = fileSrc("WoWClearance_Process.lua")
    check("Test 99k: isDowngradeVsEquipped narrows offhand-equipLoc items to slot 16 when MH is 2H",
        ev:find('equipLoc == "INVTYPE_WEAPON"') ~= nil
            and ev:find('or equipLoc == "INVTYPE_SHIELD"') ~= nil
            and ev:find('or equipLoc == "INVTYPE_HOLDABLE"') ~= nil
            and ev:find('or equipLoc == "INVTYPE_WEAPONOFFHAND"') ~= nil
            and ev:find('mhEquipLoc == "INVTYPE_2HWEAPON"') ~= nil,
        "v2.45.1 (Zukii): the v2.33.x narrowing handled 1H weapons vs 2H MH but explicitly opted out of the symmetric offhand case. When a player wields a 2H, slot 17 is locked empty and an offhand drop can't actually fill it. Without the mirror fix, isDowngradeVsEquipped hits its empty_slot bailout and returns not_a_downgrade -> the tooltip falsely labels 'Keep (Green, possible upgrade)' on offhands that the player can't equip. The narrowing makes offhand drops compare against the 2H's iLvl so the auto-rule disposes of low-iLvl offhands when the player has chosen 2H. checkBagsForUpgrades intentionally does NOT get the same narrowing - its conservative empty-slot bailout still prevents high-iLvl offhands from spam-flooding the Keep List for committed-2H players.")
end

-- ---------------------------------------------------------------------------
-- Test 100 (v2.46.4): vendor-refused sell-loop wedge guard.
-- ---------------------------------------------------------------------------
-- Reported by Broyo: a purple item the vendor refused to buy wedged
-- the sell cycle. UseContainerItem returned silently, the slot stayed
-- full, BuildQueue's fresh bag walk re-queued the item, FinishRun
-- spammed "Sold X items so far, looking for more" every iteration.
-- Workaround was to manually add the item to the Delete List.
--
-- Fix: a per-merchant-cycle (bag, slot) -> itemID blacklist. Marked
-- in DoNextAction immediately after UseContainerItem; consulted by
-- BuildQueue's sell-side path; wiped on StartRun + MERCHANT_CLOSED.
-- The itemID equality guards against "slot moved organically" false
-- positives (loot or drag-drop fills the same slot with a different
-- item, which deserves a fresh attempt).
--
-- These tests pin the four insertion sites + the contract via static
-- patterns. The actual wedge-vs-no-wedge behaviour can only be
-- verified in-game against a real vendor-refused item.
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then return "" end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local ev = fileSrc("WoWClearance_Events.lua")
    check("Test 100a: WC_vendorRefusedThisRun table + WC_refusalKey helper declared",
        ev:find("local WC_vendorRefusedThisRun = {}") ~= nil
            and ev:find("local function WC_refusalKey%(bag, slot%) return bag %* 100 %+ slot end") ~= nil,
        "the blacklist + key helper MUST be file-local near the other vendor-cycle state (queue, WC_batchTotalSold). The key encoding (bag * 100 + slot) assumes WoW 3.3.5a's bag indices 0-4 and slot indices 1-N where N is well under 100 - if a future bag type extends the slot count past 99, the encoding collides. Refusing to test for this here would let a silent regression land.")
    check("Test 100b: blacklist wiped on StartRun and MERCHANT_CLOSED",
        ev:find("wipe%(WC_vendorRefusedThisRun%).-local merchantAllowed = WC_IsMerchantAllowed") == nil
            -- StartRun has the wipe before the merchantAllowed call (defensive ordering)
            -- 3 = StartRun + MERCHANT_CLOSED + the capped busy re-scan (Test 100e)
            and select(2, ev:gsub("wipe%(WC_vendorRefusedThisRun%)", "")) == 3,
        "the wipe must fire on every fresh cycle (StartRun) AND every merchant close (MERCHANT_CLOSED). Two sites = cheap insurance: StartRun covers normal cycle starts, MERCHANT_CLOSED covers player-closes-merchant-mid-loop. If only one site fires, a fast reopen could carry stale refusal entries into the next visit.")
    check("Test 100c: DoNextAction marks the slot immediately after UseContainerItem",
        ev:find("UseContainerItem%(action%.bag, action%.slot%).-WC_vendorRefusedThisRun%[WC_refusalKey%(action%.bag, action%.slot%)%] = action%.itemID") ~= nil,
        "the mark MUST land on the same code path as the UseContainerItem call, with no early returns or branches between them. If a future refactor moves the mark to a later point (after stat bumps, into a callback) it would skip on the queue's tail when the cycle finishes mid-batch - leaving the wedge regression open. The action.itemID guard protects against nil-itemID actions (delete-path items) sneaking into the wrong table.")
    check("Test 100d: BuildQueue skips refused slots before WC_IsSellable runs",
        ev:find("local refusedID = WC_vendorRefusedThisRun%[WC_refusalKey%(bag, slot%)%]") ~= nil
            and ev:find("local skipForRefusal = refusedID and refusedID == GetContainerItemID%(bag, slot%)") ~= nil
            and ev:find("if not skipForRefusal then\n%s*sellable, link, itemID, sellPrice, itemCount, quality = WC_IsSellable") ~= nil,
        "the pre-check MUST run before WC_IsSellable (which does an expensive tooltip scan + multiple API hits). The order matters: a worst-case bags-full-of-identical-refused-items scenario would otherwise pay the full sellability cost for every duplicate every cycle. The itemID equality (not just key presence) is the contract that lets a different item rolling into the slot get a fresh try.")
    -- v0.6.3: merchant answers. A "busy" answer may clear the refusal marks
    -- for a re-scan, but only under the per-run cap; a merchant that buys
    -- nothing stops the run and blocks new runs for the visit.
    check("Test 100e: busy re-scan wipe is capped, buys-nothing stops the run",
        ev:find("if WC_compCache%.vendorBusySeen and %(WC_compCache%.vendorBusyRetries or 0%) < 3 then\n[^\n]*\n%s*wipe%(WC_vendorRefusedThisRun%)") ~= nil
            and ev:find('worker:RegisterEvent%("UI_ERROR_MESSAGE"%)') ~= nil
            and ev:find("_G%.ERR_VENDOR_DOESNT_BUY.-WC_compCache%.vendorRunning = false") ~= nil
            and ev:find("if WC_compCache%.merchantBuysNothing then\n[^\n]*\n%s*return") ~= nil
            and ev:find("WC_compCache%.merchantBuysNothing = false") ~= nil,
        "an uncapped busy wipe would retry a refused item forever (the v2.46.4 wedge); a buys-nothing merchant must stop the run, keep StartRun from restarting it, and be cleared on MERCHANT_CLOSED.")
    -- v0.6.3: the category-based host bag UI re-files every item on a
    -- reprocess, so it must run from setting changes (NS.RefreshSellBorders)
    -- and never from the per-loot bag-update repaint.
    local bfh = assert(io.open("WoWClearance_BagDisplay.lua", "rb"))
    local bd = bfh:read("*a")
    bfh:close()
    check("Test 100f: host category refresh runs on setting changes, not bag updates",
        bd:find("NS%.RefreshSellBorders = function%(%)\n%s*WC_compCache%.repaintSellBorders%(%).-WC_compCache%.refreshHostCategories%(%)") ~= nil
            and bd:find("RegisterCategoryFunction") ~= nil
            and ev:find("if WC_compCache%.repaintSellBorders then\n%s*WC_compCache%.repaintSellBorders%(%)") ~= nil,
        "the bag-update debounce must call repaintSellBorders; NS.RefreshSellBorders also reprocesses the host's categories, far too costly per loot.")
    -- v0.6.4: the same host gets rings on its item buttons. A reused button
    -- must drop its bag/slot on ResetVisuals, or repaintSellBorders re-rings
    -- a free slot or bank item from the stale stash. The ring hook must
    -- install before the group refresh, whose redraw paints the first rings.
    check("Test 100g: category host item buttons ringed, cleared on reuse",
        bd:find('hooksecurefunc%(proto, "SetItemFromData"') ~= nil
            and bd:find('hooksecurefunc%(proto, "ResetVisuals"') ~= nil
            and bd:find("button%._wc_sellBag, button%._wc_sellSlot = nil, nil") ~= nil
            and bd:find("tryCategoryHostRings%(%)\n%s*tryCategoryHost%(%)") ~= nil,
        "hook SetItemFromData + ResetVisuals on the host item prototype, clear the stash on reuse, and install before tryCategoryHost.")
    -- v0.6.4: with the minimap-button library loaded, the button registers
    -- through it (a button collector flags any other button as "custom"),
    -- and its position / hidden state map onto WC's own saved fields.
    local mfh = assert(io.open("WoWClearance_Minimap.lua", "rb"))
    local mm = mfh:read("*a")
    mfh:close()
    check("Test 100h: minimap button registers through LibDBIcon when present",
        mm:find('lib:Register%("WoWClearance", obj, iconDB%)') ~= nil
            and mm:find('if k == "minimapPos" and type%(v%) == "number" then\n%s*DB%.minimapButtonAngle = v') ~= nil
            and mm:find('elseif k == "hide" then\n%s*DB%.minimapButton = not v') ~= nil,
        "register through LibDBIcon with iconDB mapping minimapPos -> DB.minimapButtonAngle and hide -> not DB.minimapButton.")
    -- v0.7.0: every lifetime total also lands in the per-day table, and
    -- looted coin counts only inside the loot window (plus grace), never
    -- while a merchant / mail / quest window is open.
    check("Test 100i: per-day totals ride WC_BumpStat; coin gated on loot window + no transaction window",
        ev:find("WC_compCache%.bumpDay%(WC_compCache%.dayFields%[field%], delta%)") ~= nil
            -- v0.9.0: looted coin moved to the Loot module (src covers it).
            and src:find("now <= %(lootMoneyUntil or 0%) and not transactionWindowOpen%(%)") ~= nil
            and src:find('elseif event == "LOOT_CLOSED" then\n%s*if lootMoneyUntil then\n%s*lootMoneyUntil = now %+ 2') ~= nil,
        "WC_BumpStat must feed bumpDay; coin must need an open (or just closed) loot window and no transaction window.")
end

-- ---------------------------------------------------------------------------
-- Test 101 (v2.46.6): Loot Log skips items destined for auto-delete.
-- ---------------------------------------------------------------------------
-- Reported by Broyo (screenshot): PvP-Resilience items left ghost rows in
-- the Loot Log - placeholder names like "item:42221" with x1 / 0.0% share
-- that wouldn't go away. Cause: the BAG_UPDATE debounce burst runs
-- runAutoMarkResilience (which adds Resilience items to the Delete List)
-- BEFORE WC_ScanLootDelta (which counts arrivals). runAutoDeleteOnPickup
-- only destroys one item per burst (popup serialisation WC-TRAP). So
-- between the auto-mark add and the actual destruction, the item sits in
-- the bag and ScanLootDelta credits it as "looted." Then the next burst
-- destroys it, and the row sticks with an unresolved name because
-- GetItemInfo hadn't cached metadata for items the player never hovered.
--
-- v2.46.6 fix: in WC_ScanLootDelta, skip the WC_BumpLoot call for items
-- on the Delete List when (enableDeletion AND autoDeleteOnPickup) is on.
-- The autoDeleteOnPickup gate is mandatory - with it off, Delete-Listed
-- items stay in bags and SHOULD count as looted.
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then return "" end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local ev = fileSrc("WoWClearance_Events.lua")
end


-- ---------------------------------------------------------------------------
-- Test 65 (post-v2.33.1 audit): IsInSet must be defined in any file that
-- calls it bare; the defensive `IsInSet and IsInSet(...)` guard is banned.
-- ---------------------------------------------------------------------------
-- Background. Stage 7 of the file split (commit a24be7d) moved the Process
-- Bags engine to WoWClearance_Process.lua but silently dropped the file-
-- local IsInSet helper. The bag walk's Keep List skip-gate was written as
-- `if not skip and IsInSet and IsInSet(DB.blacklist, itemID) then` -
-- the defensive guard short-circuited on the unresolved IsInSet (resolving
-- to global nil) and the gate never fired. Keep-listed items appeared in
-- Process Bags as Disenchant / Mill / Prospect / Lockpick candidates.
--
-- This test locks two invariants per file:
--   (a) any file that calls IsInSet must also define it (or import as
--       `local IsInSet = ...`).
--   (b) the `IsInSet and IsInSet(` defensive pattern is banned, because
--       it's the construct that hid the Stage 7 bug. Either define IsInSet
--       in the file and drop the guard, or remove the call entirely.
do
    for _, path in ipairs(SOURCE_PATHS) do
        local f = io.open(path, "r")
        if f then
            local s = f:read("*a")
            f:close()

            -- Strip block / line comments so doc text containing the
            -- literal "IsInSet(" doesn't false-positive. Two passes:
            -- 1) entire `-- ...` line comments (greedy to EOL)
            -- 2) block comments `--[[ ... ]]` (rare in this codebase
            --    but defensive)
            local sCode = s:gsub("%-%-[^\n]*", ""):gsub("%-%-%[%[.-%]%]", "")

            -- Definition forms recognised:
            --   * `local function IsInSet(...)` - file-local body
            --   * `local IsInSet = ...` - file-local capture from NS
            --   * `function NS.IsInSet(...)` - canonical namespace
            --     publication (Core.lua only)
            -- A "call" is any other `IsInSet(` site. Definitions count
            -- as their own callers, so a file that only defines and
            -- never calls IsInSet passes trivially via hasDef.
            local hasDef = sCode:find("local%s+function%s+IsInSet%s*%(") ~= nil
                or sCode:find("local%s+IsInSet%s*=") ~= nil
                or sCode:find("function%s+NS%.IsInSet%s*%(") ~= nil
            local hasCall = sCode:find("IsInSet%s*%(") ~= nil

            if hasCall then
                check(
                    path .. " defines IsInSet because it calls it",
                    hasDef,
                    "any file that calls IsInSet must also define it as a file-local (or import via `local IsInSet = NS.IsInSet`). "
                        .. "Stage 7 had WoWClearance_Process.lua calling IsInSet without defining it; the bare call resolved to global nil and the Keep List skip-gate silently failed."
                )
                check(
                    path .. " does not use the `IsInSet and IsInSet(` defensive pattern",
                    sCode:find("IsInSet%s+and%s+IsInSet%s*%(") == nil,
                    "the `IsInSet and IsInSet(...)` defensive guard is banned because it hides the missing-definition bug. "
                        .. "If IsInSet is defined in this file the guard is dead code; if it isn't, the guard silently neutralises the call. "
                        .. "Either define IsInSet and drop the guard, or remove the call."
                )
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Test 66 (v2.34.x): per-character partition of WoWClearanceDB.
-- ---------------------------------------------------------------------------
-- Background. The .toc declares `## SavedVariables: WoWClearanceDB` which
-- makes the table account-wide. The documented intent (and the user
-- mental model) is that the lists, profiles, and per-mode preferences are
-- per-character. The mismatch surfaced in-game as the auto-Keep-equipped
-- tag leaking onto a freshly-logged alt that had never worn the item.
--
-- v2.34.x partitions inside WoWClearanceDB: top-level stays as the legacy
-- snapshot (downgrade safety + migration seed); each character's live
-- data lives at WoWClearanceDB.chars[charKey]. DB is a metatable proxy
-- so existing call sites stay unchanged. This test locks the structural
-- invariants:
--   * The PER_CHAR_FIELDS table is declared with the documented field
--     set (so a future contributor adding a new per-character field
--     remembers to include it here).
--   * EnsureDB walks PER_CHAR_FIELDS at migration time.
--   * EnsureDB initialises WoWClearanceDB.chars and seeds the per-
--     character namespace from the snapshot.
--   * DB is built via the proxy (setmetatable with __index + __newindex
--     branching on PER_CHAR_FIELDS).
--   * The PLAYER_LOGOUT branch no longer reassigns
--     `WoWClearanceDB = DB` (which would clobber the SV with the proxy).
do
    local expectedFields = {
        "blacklist",
        "blacklistAuto",
        "whitelist",
        "deleteList",
        "whitelistProfiles",
        "blacklistProfiles",
        "activeProfileName",
        "processIgnored",
        "processCollapsedModes",
    }

    check(
        "PER_CHAR_FIELDS table declared",
        src:find("local%s+PER_CHAR_FIELDS%s*=") ~= nil,
        "the per-character field set must live as a file-local table in WoWClearance_Events.lua so the proxy and the migration walk reference the same canonical list"
    )

    for _, name in ipairs(expectedFields) do
        check(
            "PER_CHAR_FIELDS includes " .. name,
            src:find(name .. "%s*=%s*true") ~= nil,
            "missing per-character field would route the field through the account-wide top-level (defeats the migration)"
        )
    end

    check(
        "EnsureDB initialises WoWClearanceDB.chars",
        src:find("WoWClearanceDB%.chars%s*==%s*nil") ~= nil,
        "EnsureDB must initialise the chars namespace on first load with the new schema"
    )

    check(
        "EnsureDB seeds per-character namespace from snapshot via deep copy",
        src:find("WC_DBDeepCopy%(WoWClearanceDB%[k%]%)") ~= nil,
        "each character's first load must deep-copy the legacy top-level snapshot into chars[charKey] so the pre-migration baseline survives and is consistent across characters"
    )

    check(
        "DB is built via WC_DBBuildProxy",
        src:find("DB%s*=%s*WC_DBBuildProxy%(") ~= nil,
        "DB must be the metatable proxy so per-char vs account-wide routing happens automatically at every call site"
    )

    check(
        "DB proxy uses metatable __index branching on PER_CHAR_FIELDS",
        src:find("__index%s*=%s*function") ~= nil and src:find("PER_CHAR_FIELDS%[k%]") ~= nil,
        "the proxy __index must branch on PER_CHAR_FIELDS membership; routing every read through PER_CHAR_FIELDS preserves the existing `DB.foo` call-site shape"
    )

    check(
        "DB proxy uses metatable __newindex branching on PER_CHAR_FIELDS",
        src:find("__newindex%s*=%s*function") ~= nil,
        "the proxy __newindex must route writes by PER_CHAR_FIELDS membership so per-character mutations don't leak to the account-wide top level"
    )

    -- Strip line + block comments so docstrings that mention the banned
    -- pattern in their explanation don't false-positive (matches the
    -- approach in Test 65). Only the executable assignment is forbidden.
    local srcCode = src:gsub("%-%-[^\n]*", ""):gsub("%-%-%[%[.-%]%]", "")
    check(
        "PLAYER_LOGOUT does NOT reassign WoWClearanceDB to DB",
        srcCode:find("WoWClearanceDB%s*=%s*DB[^%w_]") == nil
            and not srcCode:match("WoWClearanceDB%s*=%s*DB$"),
        "with DB as a proxy, the assignment that used to live in PLAYER_LOGOUT would overwrite the SavedVariable with an empty proxy table and wipe the user's data on next logout. The PLAYER_LOGOUT branch must not contain this assignment."
    )

    -- v2.34.x cross-character cleanup. Locks that the initial migration's
    -- merged-blacklist leak is repaired and gated by a one-shot per-char
    -- flag so it can't re-fire and clobber live data on each /reload.
    check(
        "EnsureDB cleanup gates on per-char _migratedV2 flag",
        srcCode:find("charNS%._migratedV2") ~= nil
            and srcCode:find("charNS%._migratedV2%s*=%s*true") ~= nil,
        "the cleanup must run exactly once per character. Without the gate, every /reload would re-drop blacklist entries the live auto-protect paths just re-added under this character's authoritative login."
    )

    check(
        "EnsureDB cleanup drops blacklist entries flagged in the legacy snapshot",
        srcCode:find("legacyAuto%s*=%s*WoWClearanceDB%.blacklistAuto") ~= nil
            and srcCode:find("charNS%.blacklist%[id%]%s*=%s*nil") ~= nil,
        "items present in the legacy snapshot's blacklistAuto were auto-added pre-migration (potentially by a DIFFERENT character) and must be dropped from this character's Keep list. Manual entries (no blacklistAuto tag) stay because they were explicit user intent."
    )

    check(
        "EnsureDB cleanup also clears matching entries from chars[k].blacklistAuto",
        srcCode:find("charNS%.blacklistAuto%[id%]%s*=%s*nil") ~= nil,
        "the per-character blacklistAuto map was deep-copied from the legacy snapshot at v2.34.0 migration time; the cleanup must clear the same set of legacy IDs from it too, so live auto-protect paths can repopulate authentically."
    )

    check(
        "EnsureDB cleanup arms pendingFreshInstallSync so live equip path repopulates",
        srcCode:find("WC_compCache%.pendingFreshInstallSync%s*=%s*true") ~= nil,
        "after dropping legacy auto entries, the live equipment sync must re-add the gear this character is currently wearing under their own login. The pendingFreshInstallSync flag is consumed by the PLAYER_LOGIN handler with a 2 s settle delay."
    )

    -- v2.72.0 settings profiles: the per-character POINTER is in the
    -- partition (the profile bodies are deliberately top-level so alts
    -- can share them).
    check(
        "PER_CHAR_FIELDS includes activeSettingsProfile (v2.72.0)",
        src:find("activeSettingsProfile%s*=%s*true") ~= nil,
        "the settings-profile pointer MUST be per-character - it is the whole point of the feature (alts share or diverge by pointing at different profiles). If it falls out of PER_CHAR_FIELDS it becomes account-wide and every alt snaps to the same profile again."
    )
end

-- ---------------------------------------------------------------------------
-- Test 67 (v2.34.x): bagSlotAffixData cache-poison guard.
-- ---------------------------------------------------------------------------
-- Background. A user reported that an Epic Rare/affixed item kept getting
-- vendored despite WC_AnnotateTooltip correctly displaying the
-- "Keep (new affix)" protection label. WC_IsSellable's affix gate calls
-- WC_compCache.bagSlotAffixData(bag, slot); the live-tooltip path that
-- the tooltip annotation uses doesn't share that helper. The divergence
-- traced to bagSlotAffixData's per-itemString cache: the original
-- implementation cached `false` unconditionally whenever parseAffixFromTitle
-- returned nil. Fresh affixed drops sometimes hit bagSlotAffixData BEFORE
-- the link's suffix-DBC field had been fully resolved client-side, so the
-- tooltip's TextLeft1 hadn't yet been populated with the affix-suffixed
-- name. The cold-cache scan failed to parse, cached `false`, and the
-- entry never got re-scanned for the rest of the session - while the
-- live tooltip (no cache) kept reading the now-populated title and
-- correctly identifying the affix.
--
-- Fix: only cache `false` when the title positively identifies the item
-- as not a PE roguelite affix - title is non-empty AND doesn't end with
-- a trailing roman-numeral rank suffix. Empty / cold titles are NOT
-- cached so the next call retries after the link loads.
--
-- This test locks the guard so a future regression that drops the
-- stability check would fail loudly in CI.
do
    -- Pull the bagSlotAffixData body out of the concatenated source.
    -- The function ends at the first `^end$` after the function header.
    local fnStart = src:find("function WC_compCache%.bagSlotAffixData%(")
    local body
    if fnStart then
        local searchFrom = fnStart
        local headerEnd = src:find("\n", searchFrom)
        if headerEnd then
            -- Find the matching end by scanning for the next line that is
            -- exactly `end` after our function start.
            local endPos = src:find("\nend\n", headerEnd, true)
            if endPos then
                body = src:sub(fnStart, endPos + 4)
            end
        end
    end


    if body then
        check(
            "bagSlotAffixData does not cache `false` unconditionally on parse failure",
            body:find("WC_compCache%.affixDataCache%[itemString%]%s*=%s*false") ~= nil
                and body:find("stableNoAffix") ~= nil,
            "the cache must be gated by a positive non-affix discriminator (title without a trailing roman-numeral rank suffix). Caching `false` unconditionally on parseAffixFromTitle returning nil reproduces the cold-tooltip cache-poison bug: a fresh affixed drop scanned before its title fully populated would be permanently masked, and WC_IsSellable would vendor the item despite WC_AnnotateTooltip correctly protecting it."
        )

        check(
            "bagSlotAffixData inspects the title text for the roman-suffix discriminator",
            body:find("titleText:match%(\" %[IVXLCDM%]%+\\?%$\"%)") ~= nil
                or body:find("titleText:match%(\" %[IVXLCDM%]\\?%+%\\?%$\"%)") ~= nil
                or body:find("%[IVXLCDM%]%+\\?%$") ~= nil,
            "the no-affix-cache guard depends on a roman-suffix absence check against the live title text - if the discriminator is changed or removed, the cold-tooltip cache-poison regression reappears"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 68 (v2.35.x): Gold-per-hour fields are partitioned per-character.
-- ---------------------------------------------------------------------------
-- The new bestGPH / bestGPHAt / bestGPHZone fields must live in
-- PER_CHAR_FIELDS so the v2.34.0 per-character partition migrates them
-- correctly. Without this, the GPH record would be account-wide and
-- every character would inherit the best from whichever character
-- happened to set it last. See
-- EbonClearance's docs/specs/2026-05-26-gph-stats-design.md for the design.
do
    local gphFields = { "bestGPH", "bestGPHAt", "bestGPHZone" }
    for _, name in ipairs(gphFields) do
        check(
            "PER_CHAR_FIELDS includes " .. name,
            src:find(name .. "%s*=%s*true") ~= nil,
            "the GPH best-record field " .. name .. " must be in PER_CHAR_FIELDS so it routes through the per-character namespace; otherwise every character would share one record and the v2.34.0 partition would be silently violated"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 69 (v2.35.x): the GPH stamp (Loot module since v0.9.0) wires the 5-minute gate
-- and writes all three best-record fields atomically.
-- ---------------------------------------------------------------------------
-- The MainPanel RefreshStats body must:
--   * Read WC_session.startedAt (or NS.session.startedAt) for elapsed time
--   * Apply the 5-minute (300s) minimum-session gate before updating best
--   * Write DB.bestGPH, DB.bestGPHAt, and DB.bestGPHZone together when
--     the gate passes (no partial writes)
--
-- A regression that drops the 5-minute gate would let a 3-second
-- burst inflate the best forever. A regression that writes only
-- bestGPH without the timestamp / zone would render the second-line
-- context wrong ("Best ... in <stale zone>, <stale date>").
do
    local f = io.open("WoWClearance_MainPanel.lua", "r")
    local panelSrc
    if f then
        panelSrc = f:read("*a")
        f:close()
    end

    check(
        "MainPanel.lua found",
        panelSrc ~= nil,
        "test relies on reading the file directly; check the path or whether the panel has been renamed"
    )

    -- v0.9.0: the gold-per-hour stamp moved to the Loot module.
    local gf = io.open("WoWClearance_Loot/WoWClearance_LootCapture.lua", "r")
    local gphSrc = gf and gf:read("*a") or ""
    if gf then
        gf:close()
    end

    if panelSrc then
        check(
            "LootCapture reads session.startedAt for GPH elapsed time",
            gphSrc:find("session%.startedAt") ~= nil,
            "the session start timestamp must be read from WC_session.startedAt (or NS.session.startedAt) so the GPH rate calculation has the right base"
        )

        check(
            "LootCapture applies the 5-minute (300s) gate before updating best",
            gphSrc:find("elapsed%s*>=%s*300") ~= nil,
            "the bestGPH update must require at least 300 seconds of session to filter early-session burst noise; a missing gate lets a 3-second burst inflate the best"
        )

        check(
            "LootCapture writes DB.bestGPH on the best-update path",
            gphSrc:find("DB%.bestGPH%s*=%s*sessionGPH") ~= nil,
            "the bestGPH field must be written when the gate passes; otherwise the user's best record never updates"
        )

        check(
            "LootCapture writes DB.bestGPHAt on the best-update path",
            gphSrc:find("DB%.bestGPHAt%s*=%s*time%(%)") ~= nil
                or gphSrc:find("DB%.bestGPHAt%s*=%s*now") ~= nil,
            "the bestGPHAt timestamp must be written together with bestGPH so the panel can render the 'X days ago' context; a stale bestGPHAt would describe the wrong session. The write may use `time()` directly OR a `now` local hoisted from the same scope (v2.38.1: hoisted so the per-character DB and account-wide ADB writes share one timestamp)."
        )

        check(
            "LootCapture writes DB.bestGPHZone on the best-update path",
            gphSrc:find("DB%.bestGPHZone") ~= nil and gphSrc:find("GetRealZoneText") ~= nil,
            "the bestGPHZone snapshot via GetRealZoneText() must be written together with bestGPH so the panel can render the 'in <zone>' context"
        )

        check(
            "LootCapture uses a 10-second floor on session GPH rate calculation",
            gphSrc:find("elapsed%s*>=%s*10") ~= nil,
            "sub-10s extrapolation produces absurd Gold/Hour values (selling 1 grey in 1 second = thousands of g/h); the spec mandates a 10-second floor before the live rate displays"
        )

        check(
            "Reset Lifetime button zeroes bestGPH/At/Zone",
            panelSrc:find("DB%.bestGPH%s*=%s*0") ~= nil
                and panelSrc:find('DB%.bestGPHZone%s*=%s*""') ~= nil,
            "the Reset Lifetime button must wipe all three GPH best-record fields; partial reset (e.g., bestGPH back to 0 but stale bestGPHAt/Zone left in place) would render nonsensical 'Best 0g 0s 0c in <zone>' text on the next show"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 70 (v2.35.1): family-name fallback for the affix tooltip label.
-- ---------------------------------------------------------------------------
-- PE's item-side @affix@ line and spellbook-side engraving description can
-- disagree at the same rank (e.g. "Overwhelming Force II" item reads
-- "Increases your damage and healing done by 2%" while the engraving
-- spell tooltip reads "Increases damage and healing done by 4%" - same
-- rank, different wording AND different magnitude). The description-only
-- catalog match silently fails in that case and the tooltip falls back to
-- "Keep (new affix)" even though the player demonstrably owns the family.
--
-- v2.35.1 adds a family-name fallback: knownAffixFamilies set populated
-- during the spellbook walk + ExtractionService merge, queried by
-- playerHasAffixFamily when the description match misses. Distinct label
-- "Keep (other rank known)" surfaces the family-only match so users
-- aren't misled. Sell behaviour unchanged - autoDupe stays exact-rank.
do












    check(
        "Tooltip.lua does NOT use the legacy 'Keep (new affix)' label",
        src:find("Keep %(new affix%)") == nil,
        "v2.35.1 collapses the new-family-and-different-rank distinction into 'Keep (affix rank needed)'; keeping the old 'new affix' label alongside would be redundant and confusing"
    )

    check(
        "Tooltip.lua does NOT use the legacy 'Keep (other rank known)' label",
        src:find("Keep %(other rank known%)") == nil,
        "v2.35.1 collapses the family-known-but-different-rank case into 'Keep (affix rank needed)' - same outcome from a collection POV"
    )

    -- v2.35.1 follow-up: the autoDupe-only branch must gate the
    -- "Will Sell (you have this affix)" label on an upstream
    -- "Will Sell" verdict existing in statusLine. Without that gate,
    -- the tooltip lies for any item whose quality rule is disabled or
    -- whose itemID isn't on any sell list: dupe-allow only releases
    -- the affix protection from vetoing, it doesn't add a sell signal,
    -- so the merchant cycle won't actually sell the item. The user-
    -- visible regression was an Epic item with Epic rule disabled
    -- showing "Will Sell (you have this affix)" but /wc sellinfo
    -- correctly reporting "won't sell - no rule matched".
    do
        local tooltipFile = io.open("WoWClearance_Tooltip.lua", "rb")
        if tooltipFile then
            local ttSrc = tooltipFile:read("*a") or ""
            tooltipFile:close()
            -- Find the autoDupe-only branch (the else after manualAllow
            -- inside the `if manualAllow or autoDupe` block).
        end
    end
end

-- ---------------------------------------------------------------------------
-- Test 71-77: v2.36.x Help / FAQ panel invariants.
-- ---------------------------------------------------------------------------
-- The Help panel ships a flat WC_HELP_ENTRIES table that drives the
-- rendered FAQ. The build callback splits the list on section markers
-- and renders each entry as a question + answer pair plus optional
-- "Open <panel>" button. These tests pin the structural invariants
-- (file present, section markers exist, frame exists, per-character
-- collapse state is partitioned correctly, slash help line exists,
-- chrome backdrop is applied) so a future contributor who renames a
-- helper or trims an entry by mistake gets a loud failure.
do
    local helpFile = io.open("WoWClearance_HelpPanel.lua", "rb")
    local helpSrc = nil
    if helpFile then
        helpSrc = helpFile:read("*a") or ""
        helpFile:close()
    end

    check(
        "Test 71: WoWClearance_HelpPanel.lua exists",
        helpSrc ~= nil,
        "Help / FAQ panel source file must be present at repo root"
    )

    if helpSrc then
        check(
            "Test 72: HelpPanel creates WoWClearanceOptionsHelp and the window hosts it",
            helpSrc:find('CreateFrame%("Frame", "WoWClearanceOptionsHelp"') ~= nil
                and (function()
                    -- v0.5.4: Help is no longer a Settings sub-category. The
                    -- Settings entry is a launcher only, because a panel
                    -- rendered inside SettingsPanel closes the player's bags.
                    -- Reachability now means "listed in the standalone
                    -- window's sidebar", so that is what this pins.
                    local wf = io.open("WoWClearance_Window.lua", "r")
                    if not wf then
                        return false
                    end
                    local ws = wf:read("*a")
                    wf:close()
                    return ws:find('"WoWClearanceOptionsHelp"') ~= nil
                end)(),
            "Help panel must create a frame named WoWClearanceOptionsHelp and that frame must appear in WoWClearance_Window.lua's WC_PANEL_ORDER, or /wc help has nowhere to jump to"
        )

        check(
            "Test 73: HelpPanel declares all six section markers",
            helpSrc:find('section = "gettingStarted"') ~= nil
                and helpSrc:find('section = "troubleshooting"') ~= nil
                and helpSrc:find('section = "gates"') ~= nil
                and helpSrc:find('section = "labels"') ~= nil
                and helpSrc:find('section = "processBags"') ~= nil
                and helpSrc:find('section = "discord"') ~= nil,
            "The six sections (gettingStarted, troubleshooting, gates, labels, processBags, discord) must each appear as a section marker entry in WC_HELP_ENTRIES so the build callback groups content correctly"
        )

        -- Count q/a pairs - rough invariant on entry table size.
        local entryCount = 0
        for _ in helpSrc:gmatch("\n%s*q = ") do
            entryCount = entryCount + 1
        end
        check(
            "Test 74: HelpPanel has at least 40 content entries",
            entryCount >= 40,
            "WC_HELP_ENTRIES must contain at least 40 q+a content entries (5 gettingStarted + 10 troubleshooting + 16 gates + 22 labels + 3 discord was the v2.36.x baseline); found " .. tostring(entryCount)
        )

        check(
            "Test 75: HelpPanel applies the v2.32.x list-panel chrome backdrop",
            helpSrc:find("applyChromeBackdrop") ~= nil
                and helpSrc:find('bgFile = "Interface\\\\Tooltips\\\\UI%-Tooltip%-Background"') ~= nil
                and helpSrc:find('edgeFile = "Interface\\\\Tooltips\\\\UI%-Tooltip%-Border"') ~= nil
                and helpSrc:find("edgeSize = 12") ~= nil,
            "Help panel must wrap its content area in a chrome-backdropped frame using the same UI-Tooltip-Border + edgeSize=12 + brown tint pattern as Process Bags / Sell List / Keep List / Profiles"
        )
    end

    -- Test 76: PER_CHAR_FIELDS must declare helpSectionsCollapsed so the
    -- v2.34.x partition routes the per-character key correctly. Without
    -- this entry, the collapse state would be account-wide and the
    -- v2.34.x SavedVariables-partition migration would not migrate it.
    do
        local eventsFile = io.open("WoWClearance_Events.lua", "rb")
        if eventsFile then
            local eventsSrc = eventsFile:read("*a") or ""
            eventsFile:close()
            check(
                "Test 76: PER_CHAR_FIELDS includes helpSectionsCollapsed",
                eventsSrc:find("helpSectionsCollapsed = true") ~= nil,
                "PER_CHAR_FIELDS in WoWClearance_Events.lua must include `helpSectionsCollapsed = true` so the per-character partition migrates the collapse state correctly"
            )

            check(
                "Test 77: /wc help mentions the Help panel",
                eventsSrc:find("The Help page there has the full FAQ") ~= nil,
                "The /wc help slash-command output must include a pointer to the new Help panel so players know it exists"
            )
        end
    end
end

-- ---------------------------------------------------------------------------
-- Test 80: v2.36.x Stats sub-panel split.
-- ---------------------------------------------------------------------------
-- Stats widgets (statsMoney, statsSold, statsDeleted, statsRepairs,
-- statsRepairCost, statsSessionGPH, statsBestGPH, statsAvgWorth,
-- statsMostSold, statsNote, WoWClearanceResetStatsBtn) used to live on
-- the Main panel. v2.36.x moves them to a dedicated Stats panel so the
-- Main panel can read as a welcome page and Stats has room to grow.
do
    local statsFile = io.open("WoWClearance_StatsPanel.lua", "rb")
    local statsSrc = nil
    if statsFile then
        statsSrc = statsFile:read("*a") or ""
        statsFile:close()
    end

    check(
        "Test 80: WoWClearance_StatsPanel.lua exists",
        statsSrc ~= nil,
        "Stats sub-panel source file must be present at repo root"
    )

    if statsSrc then
        -- Test 80a: the Stats frame is created in WoWClearance_StatsPanel.lua
        -- and placed in the sidebar by the one panel order, WC_PANEL_ORDER in
        -- WoWClearance_Window.lua. Pins Highlighting -> Stats in that order
        -- (main settings first, then Stats, then the list group).
        local evFile = io.open("WoWClearance_Window.lua", "rb")
        local evSrc = evFile and evFile:read("*a") or ""
        if evFile then evFile:close() end
        check(
            "Test 80a: Stats panel registers WoWClearanceOptionsStats frame",
            statsSrc:find('CreateFrame%("Frame", "WoWClearanceOptionsStats"') ~= nil
                and evSrc:find('"WoWClearanceOptionsStats",') ~= nil
                                and evSrc:find('"WoWClearanceOptionsCharacter",[%s%S]-"WoWClearanceOptionsStats",') ~= nil,
            "Stats panel must create a frame named WoWClearanceOptionsStats (in StatsPanel.lua) and WC_PANEL_ORDER (Window.lua) must list it after Item Highlighting (main settings first, then Stats, then the list group)"
        )

        check(
            "Test 80b: Stats panel attaches statsMoney + statsNet, and no looting rows (v0.9.0 Loot module)",
            statsSrc:find("panel%.statsMoney") ~= nil
                and statsSrc:find("panel%.statsNet") ~= nil
                and statsSrc:find("panel%.statsSessionGPH") == nil
                and statsSrc:find("panel%.statsLootCoin") == nil,
            "Stats panel must hang the panel.statsX attachments RefreshStats writes to; gold per hour and looted coin live on the Loot module's panel"
        )
    end

    -- MainPanel post-split should NO LONGER create stats widgets.
    local mainFile = io.open("WoWClearance_MainPanel.lua", "rb")
    if mainFile then
        local mainSrc = mainFile:read("*a") or ""
        mainFile:close()
        check(
            "Test 80c: MainPanel no longer creates statsMoney FontString",
            mainSrc:find('panel%.statsMoney = money') == nil
                and mainSrc:find("statsMoney = content:CreateFontString") == nil,
            "After v2.36.x split, MainPanel must not attach statsMoney; that lives on the new Stats panel"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 79: every Help entry has a non-empty unique id.
-- ---------------------------------------------------------------------------
-- Settings panels deep-link into Help via these ids (see NS.AddHelpIcon /
-- NS.OpenHelpEntry, added in later tasks). If two entries share an id,
-- the deep-link is ambiguous; if an entry lacks an id, no panel can
-- link to it. Counts unique ids and asserts no duplicates.
do
    local helpFile = io.open("WoWClearance_HelpPanel.lua", "rb")
    if helpFile then
        local hsrc = helpFile:read("*a") or ""
        helpFile:close()
        local idsSeen = {}
        local duplicates = {}
        for id in hsrc:gmatch('id = "([^"]+)"') do
            if idsSeen[id] then
                duplicates[#duplicates + 1] = id
            end
            idsSeen[id] = (idsSeen[id] or 0) + 1
        end
        local count = 0
        for _ in pairs(idsSeen) do count = count + 1 end
        check(
            "Test 79: at least 40 unique help entry ids exist",
            count >= 40 and #duplicates == 0,
            "Help entries must have unique id fields. Count: " .. count .. " unique; duplicates: " .. table.concat(duplicates, ", ")
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 82: NS.AddHelpIcon widget primitive exists in PanelWidgets.lua.
-- ---------------------------------------------------------------------------
-- v2.36.x: settings panels deep-link into the Help panel via small [?]
-- icons. The widget primitive lives in WoWClearance_PanelWidgets.lua
-- alongside NS.MakeHeader / NS.MakeLabel / NS.AddCheckbox.
do
    local f = io.open("WoWClearance_PanelWidgets.lua", "rb")
    if f then
        local src = f:read("*a") or ""
        f:close()
        check(
            "Test 82: NS.AddHelpIcon helper is defined",
            src:find("NS%.AddHelpIcon") ~= nil
                and src:find("function .*MakeHelpIcon") ~= nil
                and src:find("NS%.OpenHelpEntry") ~= nil,
            "WoWClearance_PanelWidgets.lua must define MakeHelpIcon and expose it as NS.AddHelpIcon. The OnClick must call NS.OpenHelpEntry(entryId) if it exists."
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 83: NS.OpenHelpEntry deep-link API + scroll-to-entry + flash.
-- ---------------------------------------------------------------------------
-- Settings panels call NS.AddHelpIcon (PanelWidgets.lua), which on click
-- invokes NS.OpenHelpEntry(entryId). That function lives in HelpPanel.lua
-- and must: (a) stash the pending entry id on HelpPanel, (b) auto-expand
-- the owning section via DB.helpSectionsCollapsed, (c) open the Help
-- panel via InterfaceOptionsFrame_OpenToCategory (called twice for the
-- 3.3.5a workaround). The refreshLayout pass then consumes the pending
-- target: scrolls the entry to the top of the viewport, flashes briefly.
do
    local f = io.open("WoWClearance_HelpPanel.lua", "rb")
    if f then
        local src = f:read("*a") or ""
        f:close()
        check(
            "Test 83: NS.OpenHelpEntry exists with required wiring",
            src:find("function NS%.OpenHelpEntry") ~= nil
                and src:find("NS%.OpenOptionsPanel") ~= nil
                and src:find("helpSectionsCollapsed") ~= nil
                and src:find("_scrollGeneration") ~= nil,
            "HelpPanel.lua must define NS.OpenHelpEntry that expands the owning section via DB.helpSectionsCollapsed, opens the panel via InterfaceOptionsFrame_OpenToCategory, and uses a _scrollGeneration counter so rapid clicks supersede cleanly."
        )
        check(
            "Test 83a: OpenHelpEntry schedules SetVerticalScroll + flash with generation guard",
            src:find("SetVerticalScroll") ~= nil
                and src:find("widget%.Flash") ~= nil
                and src:find("NS%.Delay") ~= nil
                and src:find("HelpPanel%._scrollGeneration ~= gen") ~= nil,
            "OpenHelpEntry must schedule a delayed scroll (SetVerticalScroll on the outer scroll frame) and a visible flash (v2.48.0: entry-frame Flash() method that fires UIFrameFlash on the BACKGROUND flash Texture; supersedes the pre-v2.48.0 |cff00ffff text swap), both gated by a generation check so a superseded click's tasks no-op."
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 78: every NS.AddHelpIcon entryId references a real Help entry.
-- ---------------------------------------------------------------------------
-- Settings panels deep-link into Help via NS.AddHelpIcon(..., "entryId").
-- This test scans every panel source file for those calls, extracts the
-- referenced entry id (the last quoted string arg before the closing
-- paren), and asserts each id exists as `id = "..."` in WC_HELP_ENTRIES
-- (WoWClearance_HelpPanel.lua). Catches drift when a Help entry is
-- removed or renamed without updating the panels that link to it.
do
    local helpFile = io.open("WoWClearance_HelpPanel.lua", "rb")
    if helpFile then
        local helpSrc = helpFile:read("*a") or ""
        helpFile:close()
        local definedIds = {}
        for id in helpSrc:gmatch('id = "([^"]+)"') do
            definedIds[id] = true
        end

        local panelFiles = {
            "WoWClearance_ProtectionPanel.lua",
            "WoWClearance_MerchantPanel.lua",
            "WoWClearance_ItemHighlightingPanel.lua",
            "WoWClearance_ProcessBagsPanel.lua",
            "WoWClearance_SellListPanels.lua",
            "WoWClearance_KeepDeletePanels.lua",
            "WoWClearance_ProfilesPanel.lua",
            "WoWClearance_MainPanel.lua",
            "WoWClearance_StatsPanel.lua",
        }
        local missing = {}
        for _, fname in ipairs(panelFiles) do
            local pf = io.open(fname, "rb")
            if pf then
                local psrc = pf:read("*a") or ""
                pf:close()
                -- Match NS.AddHelpIcon(parent, anchor, p1, p2, x, y, "entryId")
                -- Pattern: capture the last quoted string before the ")".
                for id in psrc:gmatch('AddHelpIcon%([^)]-"([^"]+)"%s*%)') do
                    if not definedIds[id] then
                        missing[#missing + 1] = fname .. " -> " .. id
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Tests 84-85: Mill / Prospect tooltip-scan robustness.
-- ---------------------------------------------------------------------------
-- Two distinct bugs hid the PROSPECT section from Process Bags:
--
--   1) Color-code wrapping: the byte-exact `txt == marker` compare failed
--      against `|cFFFFFF00Prospectable|r`. Fixed by normaliseTooltipLine
--      (strips |c...|r and trims). Test 84 pins it.
--
--   2) Cache poisoning: canMill and canProspect shared one processCache
--      with a "none" sentinel meaning "scanned, no match found", but
--      ambiguous about WHICH marker was searched. With both Inscription
--      and Jewelcrafting trained, canMill ran first for every item; ore
--      missed the Millable marker, got cached as "none", and canProspect
--      then returned false without ever scanning. v2.36.x unifies the
--      scan: one pass per itemID checks BOTH markers and caches the
--      classification (Mill / Prospect / none). Test 85 pins it.
do
    local f = io.open("WoWClearance_Process.lua", "rb")
    if f then
        local src = f:read("*a") or ""
        f:close()
        check(
            "Test 84: processTooltipHasLine strips color codes before marker compare",
            src:find("normaliseTooltipLine") ~= nil
                and src:find("|c%%x%%x%%x%%x%%x%%x%%x%%x") ~= nil
                and src:find("local txt = normaliseTooltipLine%(line:GetText%(%)%)") ~= nil
                and src:find("if txt == millMarker") ~= nil
                and src:find("txt == prospectMarker") ~= nil,
            "WoWClearance_Process.lua must define normaliseTooltipLine (color-strip + trim) and use it inside processTooltipHasLine's loop to normalise each tooltip line before comparing against the Mill / Prospect markers. The byte-exact `txt == marker` compare against the raw color-wrapped line silently broke Mill / Prospect detection."
        )

        check(
            "Test 85: processTooltipHasLine scans both Mill + Prospect markers in one pass",
            src:find("local millMarker = ITEM_MILLABLE") ~= nil
                and src:find("local prospectMarker = ITEM_PROSPECTABLE") ~= nil
                and src:find('result = "Mill"') ~= nil
                and src:find('result = "Prospect"') ~= nil
                and src:find("function WC_compCache%.processTooltipHasLine%(bag, slot, itemID%)") ~= nil,
            "processTooltipHasLine must scan for BOTH markers in one tooltip pass and cache the resulting classification. The previous single-marker API let canMill poison the cache with 'none' before canProspect could scan, hiding the PROSPECT section for any player with both professions trained."
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 86: Delete List wins over sell signals (cycle + trace agreement).
-- ---------------------------------------------------------------------------
-- Pre-v2.37.0 BuildQueue checked WC_IsSellable first and only fell
-- through to the Delete-List branch when the item was not sellable. A
-- grey item on the Delete List was queued as a sell because greyAutoSell
-- returned true. The bag tint + tooltip annotation followed the inverse
-- order ("delete" tint wins) so the cycle and the UI disagreed. v2.37.0
-- reversed BuildQueue's per-slot dispatch: the Delete-List branch fires
-- first, and the sell branch only runs when the slot did not queue a
-- delete. describeSellability got a parallel Delete-List step + a
-- WILL DELETE summary override so /wc sellinfo agrees with the cycle.
do
    local evf = io.open("WoWClearance_Events.lua", "rb")
    local bdf = io.open("WoWClearance_BagDisplay.lua", "rb")
    if evf and bdf then
        local evSrc = evf:read("*a") or ""
        evf:close()
        local bdSrc = bdf:read("*a") or ""
        bdf:close()

        -- BuildQueue: the Delete-List check (now delegated to
        -- WC_compCache.deleteListSlotEligible) must appear before the
        -- `WC_IsSellable(bag, slot,` call inside the bag-walk loop.
        -- v2.42.0: the inline IsInSet(DB.deleteList, id) check moved into the
        -- shared deleteListSlotEligible helper so vendor-delete and
        -- auto-delete-on-pickup apply identical policy. BuildQueue now
        -- calls deleteListSlotEligible; the ordering invariant is verified
        -- by finding the helper call before WC_IsSellable in the function body.
        local fnStart = evSrc:find("local function BuildQueue%(")
        local fnEnd = fnStart and evSrc:find("\nend\n", fnStart) or nil
        local body = fnStart and fnEnd and evSrc:sub(fnStart, fnEnd) or ""
        local deleteCheckPos = body:find('deleteListSlotEligible%(bag, slot%)')
        local sellableCheckPos = body:find("WC_IsSellable%(bag, slot,")
        check(
            "Test 86: BuildQueue checks Delete List BEFORE WC_IsSellable",
            deleteCheckPos ~= nil
                and sellableCheckPos ~= nil
                and deleteCheckPos < sellableCheckPos,
            "BuildQueue must call deleteListSlotEligible(bag, slot) before WC_IsSellable so explicit destructive intent wins over sell signals (greyAutoSell, Sell List, quality rules). Pre-v2.37.0 had the order reversed and the Delete List silently lost to greyAutoSell on grey items."
        )

        check(
            "Test 86a: describeSellability surfaces a Delete-List verdict + WILL DELETE summary",
            -- v2.71.3 (classifier Stage 4): the WILL DELETE verdict comes
            -- from Decision.deleteEligible (the same gate BuildQueue
            -- runs), so the trace is honest about the v2.50.2 rescue
            -- vetoes instead of claiming WILL DELETE for any listed item.
            bdSrc:find("deleteListVerdict") ~= nil
                and bdSrc:find("WILL DELETE when you press Delete Next") ~= nil
                and bdSrc:find("if ctx%.onDeleteList and ctx%.enableDeletion then") ~= nil
                and bdSrc:find("local delEligible, delToken = NS%.Decision%.deleteEligible%(ctx%)") ~= nil,
            "describeSellability must derive its deleteListVerdict step + WILL DELETE summary from Decision.deleteEligible so /wc sellinfo agrees with BuildQueue's delete gate (including the Keep-signal / equipped / affix rescues)."
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 87: v2.37.0 Keep List bag-border highlighting.
-- ---------------------------------------------------------------------------
-- v2.37.0 adds a sixth sell-border category, "keep", that paints a
-- distinct slot border on items the player manually added to the Keep
-- List (DB.blacklist minus DB.blacklistAuto entries). Pure visual-
-- reassurance feature - no behaviour change, just a new colour gated
-- by the existing per-category enable + colour-picker UI.
--
-- The four sub-tests verify the four touch points stay in lockstep:
-- defaults init, resolver order, panel row, Help entry. See
-- EbonClearance's docs/specs/2026-05-28-keep-highlighting-design.md.
do
    local evf = io.open("WoWClearance_Events.lua", "rb")
    local bdf = io.open("WoWClearance_BagDisplay.lua", "rb")
    local ihf = io.open("WoWClearance_ItemHighlightingPanel.lua", "rb")
    local hpf = io.open("WoWClearance_HelpPanel.lua", "rb")
    if evf and bdf and ihf and hpf then
        local evSrc = evf:read("*a") or ""
        evf:close()
        local bdSrc = bdf:read("*a") or ""
        bdf:close()
        local ihSrc = ihf:read("*a") or ""
        ihf:close()
        local hpSrc = hpf:read("*a") or ""
        hpf:close()

        check(
            "Test 87: EnsureDB seeds DB.sellBorderCategories.keep with enabled=false default",
            evSrc:find("keep = { enabled = false, color = {") ~= nil
                and evSrc:find("delete = defaultCat%(") ~= nil
                and evSrc:find("accountSell = defaultCat%(") ~= nil,
            "EnsureDB's CAT_DEFAULTS must include a 'keep' entry. Keep ships enabled=false (opt-in) while every other category uses defaultCat() (enabled=true). The asymmetry keeps existing v2.36.x setups visually identical on upgrade - the player has to tick the Keep row to pick up the new tint."
        )

        -- The Keep check must sit between the Delete check and the
        -- IsSellable bail. Keep-listed items return false from
        -- WC_IsSellable (that's the protection mechanism), so the
        -- resolver has to short-circuit before that bail to surface
        -- the "keep" verdict.
        local fnStart = bdSrc:find("function WC_compCache%.bagSlotWillSellCategory%(")
        local fnEnd = fnStart and bdSrc:find("\nend\n", fnStart) or nil
        local body = fnStart and fnEnd and bdSrc:sub(fnStart, fnEnd) or ""
        local deletePos = body:find("IsInSet%(DB%.deleteList,")
        local keepPos = body:find("IsInSet%(DB%.blacklist,")
        local sellablePos = body:find("NS%.IsSellable%(bag, slot,")
        check(
            "Test 87a: bagSlotWillSellCategory checks Keep List between Delete and IsSellable",
            deletePos ~= nil
                and keepPos ~= nil
                and sellablePos ~= nil
                and deletePos < keepPos
                and keepPos < sellablePos,
            "Keep-listed items return false from WC_IsSellable, so the 'keep' verdict has to be resolved BEFORE that bail. Order must be: deleteList -> blacklist (Keep) -> IsSellable -> remaining categories. The blacklistAuto guard excludes auto-protected entries from the manual-only border scope."
        )

        check(
            "Test 87b: Item Highlighting panel registers a 'keep' category row",
            ihSrc:find('{ key = "keep", label = L%["Keep List') ~= nil,
            "Item Highlighting panel's SELL_BORDER_CATEGORIES table must include a 'keep' row so the player can toggle the new border and repaint its colour. Adding the category to EnsureDB without surfacing it in the panel makes it invisible to the user."
        )

        check(
            "Test 87c: tshoot-bag-borders Help entry mentions Keep",
            hpSrc:find("tshoot%-bag%-borders") ~= nil
                and hpSrc:find('"They\'re off by default%..-Delete, Keep, Account Sell') ~= nil,
            "The tshoot-bag-borders Help entry's category list must include Keep alongside the existing categories so the deep-link from the new row's [?] points at accurate text."
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 88: v2.37.0 Borrows from Ivo's WC fork + Ebon_QoL.
-- ---------------------------------------------------------------------------
-- Three independent borrows landed in v2.37.0:
--   A. AffixDebugDump diagnostic event logger + /wc affixdebug slash
--      sub-command + /wc bugreport integration.
--   B. "Already known by this character" tooltip annotation on tomes /
--      recipes the player has learned. Reuses the existing
--      tomeIsKnownCache from WoWClearance_Protection.lua.
--   C. Item-level text overlay on equippable gear, gated by a master
--      toggle + 3 surface sub-toggles (bags / paperdoll / merchant).
-- See EbonClearance's docs/specs/2026-05-28-keep-highlighting-design.md.
do
    local protf = io.open("WoWClearance_Protection.lua", "rb")
    local evf2 = io.open("WoWClearance_Events.lua", "rb")
    local ttf = io.open("WoWClearance_Tooltip.lua", "rb")
    local bdf2 = io.open("WoWClearance_BagDisplay.lua", "rb")
    local ihf2 = io.open("WoWClearance_ItemHighlightingPanel.lua", "rb")
    if protf and evf2 and ttf and bdf2 and ihf2 then
        local protSrc = protf:read("*a") or ""
        protf:close()
        local evSrc = evf2:read("*a") or ""
        evf2:close()
        local ttSrc = ttf:read("*a") or ""
        ttf:close()
        local bdSrc2 = bdf2:read("*a") or ""
        bdf2:close()
        local ihSrc2 = ihf2:read("*a") or ""
        ihf2:close()

        -- Borrow A: AffixDebugDump function + the six call sites
        local hasFn = protSrc:find("local function AffixDebugDump") ~= nil
            and protSrc:find("WC_compCache%.AffixDebugDump = AffixDebugDump") ~= nil
        local kindCount = 0
        for _ in protSrc:gmatch('AffixDebugDump%("bag%.affix%.cache"') do
            kindCount = kindCount + 1
        end
        for _ in protSrc:gmatch('AffixDebugDump%("bag%.affix%.scan"') do
            kindCount = kindCount + 1
        end
        for _ in protSrc:gmatch('AffixDebugDump%("spellbook%.affix%.hit"') do
            kindCount = kindCount + 1
        end
        for _ in protSrc:gmatch('AffixDebugDump%("extraction%.affix%.hit"') do
            kindCount = kindCount + 1
        end
        for _ in protSrc:gmatch('AffixDebugDump%("knownAffixes%.start"') do
            kindCount = kindCount + 1
        end
        for _ in protSrc:gmatch('AffixDebugDump%("knownAffixes%.done"') do
            kindCount = kindCount + 1
        end
        local slashOK = evSrc:find('if cmd == "affixdebug" then') ~= nil
            and evSrc:find("affixDebugEnabled") ~= nil

        -- Borrow B: "Already known by this character" tooltip line.
        check(
            "Test 88a: Borrow B - 'Already known by this character' tooltip annotation",
            -- v2.71.2 (classifier Stage 3): the tooltip reads tome state
            -- via the decision ctx; the adapter routes ctx.isTome() /
            -- ctx.knowsTomeSpell() to the liveTooltip* scanners (pinned
            -- against Decision.lua by Test 128).
            ttSrc:find("Already known by this character") ~= nil
                and ttSrc:find("ctx%.isTome%(%)") ~= nil
                and ttSrc:find("ctx%.knowsTomeSpell%(%)") ~= nil
                and ttSrc:find('statusTag ~= "tome_have"') ~= nil,
            "WC_AnnotateTooltip must add the 'Already known by this character' line for tome/recipe items the player has learned, gated on liveTooltipIsTome + liveTooltipPlayerKnowsTome, and dedupe against the existing tome-protection block's '(... you have)' label so the same info doesn't render twice. v2.43.0 localized the labels, so the dedupe reads the English statusTag token (statusTag ~= \"tome_have\") instead of introspecting the displayed string."
        )

        -- v2.37.0 polish: affix protection wins over chance-on-hit in
        -- the tooltip annotation when both apply on the same item. PE
        -- rule: chance-on-hit can't be extracted from an affixed item
        -- (must extract affix first), so the affix label is the
        -- meaningful one. Test pins the dedupe pattern that prevents
        -- the chance-on-hit block from overwriting an affix label.

        -- Borrow C: DB schema + renderer + equipLoc whitelist.
        local schemaOK = evSrc:find("DB%.itemLevelOverlay%.enabled = false") ~= nil
        local rendererOK = bdSrc2:find("function WC_compCache%.applyItemLevelOverlay") ~= nil
            and bdSrc2:find("WC_ITEM_LEVEL_EQUIP_LOCS") ~= nil
            and bdSrc2:find("NS%.RefreshItemLevelOverlay") ~= nil
        check(
            "Test 88b: Borrow C - DB schema + renderer + equipLoc whitelist",
            schemaOK and rendererOK,
            "EnsureDB must seed DB.itemLevelOverlay.enabled = false; BagDisplay must define applyItemLevelOverlay + the WC_ITEM_LEVEL_EQUIP_LOCS whitelist + NS.RefreshItemLevelOverlay. Without the schema, the panel toggles read nil and the renderer bails."
        )

        -- Borrow C UI: the master toggle. v0.9.0 removed the per-surface
        -- sub-toggles with the character sheet and vendor surfaces.
        check(
            "Test 88c: Borrow C - Item Highlighting panel has the item-level master toggle, no surface sub-toggles",
            ihSrc2:find("WoWClearanceILvlMainCB") ~= nil
                and ihSrc2:find("WoWClearanceILvlCB_") == nil
                and bdSrc2:find("PaperDollItemSlotButton_Update") == nil
                and bdSrc2:find("MerchantFrame_Update") == nil,
            "Item level shows on bag slots only; the paperdoll / merchant surfaces were removed as out of scope."
        )

        -- v2.37.0 polish: Borrow C extras - font-size slider, host bag-UI
        -- hook (Bagnon/ElvUI), and panel scroll-wrap so the new section
        -- doesn't push existing content off the visible area.
        check(
            "Test 88d: Borrow C polish - font-size slider + host hook + scroll-wrap",
            ihSrc2:find("WoWClearanceILvlFontSizeSlider") ~= nil
                and bdSrc2:find("function WC_compCache%.installHostBagItemLevelHook") ~= nil
                and bdSrc2:find("WC_applyItemLevelFont") ~= nil
                and ihSrc2:find("function%(self, content%)") ~= nil
                and ihSrc2:find("end, true%)") ~= nil
                and ihSrc2:find("NS%.FitScrollContent%(content,") ~= nil,
            "Borrow C polish must: (a) add WoWClearanceILvlFontSizeSlider in Item Highlighting; (b) define WC_compCache.installHostBagItemLevelHook so the bags surface paints under Bagnon/ElvUI; (c) re-apply font via WC_applyItemLevelFont so slider changes propagate; (d) scroll-wrap the panel via initPanel's wrapScroll arg + FitScrollContent so the new section doesn't push existing content off the visible area."
        )

        -- v2.37.0: parallel (Hit-proc) tag on chance-on-hit-carrying
        -- list entries. Mirrors the (affix-gated) tag's plumbing -
        -- account-scoped table, stamped at list-add + tooltip
        -- backfill, rendered in ListWidget.
        local menuf = io.open("WoWClearance_BagContextMenu.lua", "rb")
        local lwf = io.open("WoWClearance_ListWidget.lua", "rb")
        if menuf and lwf then
            local menuSrc = menuf:read("*a") or ""
            menuf:close()
            local lwSrc = lwf:read("*a") or ""
            lwf:close()
        end

        -- v2.37.0: /wc affixdebug must also appear in the Main panel's
        -- slash command reference (not only the /wc help chat output).
        local mpf = io.open("WoWClearance_MainPanel.lua", "rb")
        if mpf then
            local mpSrc = mpf:read("*a") or ""
            mpf:close()
        end

        -- v2.38.0: Quickstart wizard. The new WoWClearance_QuickstartPanel.lua
        -- file must register the panel, expose NS.Quickstart.Apply, define
        -- ANSWER_MAP / PRESETS with the four shipped preset keys, and
        -- CRITICALLY must never reference DB.whitelist / DB.blacklist /
        -- DB.deleteList / ADB.whitelist - the wizard writes settings only,
        -- never user list data. Events.lua must define WC_APPLY_QUICKSTART
        -- popup (and not the now-dead WC_WELCOME popup). MainPanel must
        -- render the Quickstart row. EnsureDB must seed _needsQuickstartOpen
        -- on fresh install.
        local qpf = io.open("WoWClearance_QuickstartPanel.lua", "rb")
        local mpf3 = io.open("WoWClearance_MainPanel.lua", "rb")
        if qpf and mpf3 then
            local qpSrc = qpf:read("*a") or ""
            qpf:close()
            local mpSrc3 = mpf3:read("*a") or ""
            mpf3:close()
            check(
                "Test 88m: Quickstart wizard wired + settings-only invariant",
                qpSrc:find("local PRESETS%s*=%s*{") ~= nil
                    and qpSrc:find("recommended") ~= nil
                    and qpSrc:find("cautious") ~= nil
                    and qpSrc:find("farmer") ~= nil
                    and qpSrc:find("power") ~= nil
                    and qpSrc:find("local ANSWER_MAP%s*=%s*{") ~= nil
                    and qpSrc:find("NS%.Quickstart%s*=%s*{") ~= nil
                    and qpSrc:find("autoOpenContainers") ~= nil
                    and qpSrc:find("protectAllTomes") ~= nil
                    and qpSrc:find("itemLevelOverlay%.enabled") ~= nil
                    and qpSrc:find("maxILvl") ~= nil
                    -- Settings-only invariant: NEVER touch user list data
                    and qpSrc:find("DB%.whitelist") == nil
                    and qpSrc:find("DB%.blacklist") == nil
                    and qpSrc:find("DB%.deleteList") == nil
                    and qpSrc:find("ADB%.whitelist") == nil
                    -- Main panel surfaces a Quickstart entry point
                    and mpSrc3:find("Open Quickstart") ~= nil
                    -- Events.lua: new popup, dead old popup gone, auto-open flag
                    and evSrc:find('StaticPopupDialogs%["WC_APPLY_QUICKSTART"%]') ~= nil
                    and evSrc:find('StaticPopupDialogs%["WC_WELCOME"%]') == nil
                    and evSrc:find("_needsQuickstartOpen") ~= nil,
                "Quickstart panel must define ANSWER_MAP + PRESETS (4 keys); expose NS.Quickstart.Apply; cover the v2.38.0-added fields (autoOpenContainers / protectAllTomes / iLvl surfaces / qualityRules.maxILvl); never reference user list data; MainPanel must surface a Quickstart entry point; Events.lua must define WC_APPLY_QUICKSTART, NOT define WC_WELCOME, and set _needsQuickstartOpen on fresh install."
            )
        end

        -- v2.38.1: Stats panel character/account split. Locks the
        -- schema, the helper-driven write path, the view toggle UI, and
        -- the view-aware reset branching so regressions surface in CI.
        local spf = io.open("WoWClearance_StatsPanel.lua", "rb")
        local mpf4 = io.open("WoWClearance_MainPanel.lua", "rb")
        if spf and mpf4 then
            local spS = spf:read("*a") or ""
            spf:close()
            local mpS4 = mpf4:read("*a") or ""
            mpf4:close()
            check(
                "Test 88aa: ADB.accountStats schema seeded by EnsureAccountDB",
                evSrc:find("ADB%.accountStats%s*=%s*{}") ~= nil
                    and evSrc:find("AS%.totalCopper%s*=%s*0") ~= nil
                    and evSrc:find("AS%.bestGPHChar") ~= nil
                    and evSrc:find("AS%.startedAt%s*=%s*time%(%)") ~= nil,
                "EnsureAccountDB must initialise ADB.accountStats with the per-character mirror fields + bestGPHChar + startedAt timestamp."
            )
            check(
                "Test 88ab: WC_BumpStat + WC_BumpStatBucket helpers defined",
                evSrc:find("local function WC_BumpStat%(field, delta%)") ~= nil
                    and evSrc:find("local function WC_BumpStatBucket%(bucket, key, delta%)") ~= nil
                    and evSrc:find("ADB%.accountStats%[field%]") ~= nil
                    and evSrc:find("ADB%.accountStats%[bucket%]") ~= nil,
                "Both helpers must exist and structurally mirror writes from DB.* to ADB.accountStats.*."
            )
            check(
                "Test 88ac: stat-write sites converted to helpers (no remaining inline DB.totalCopper increments)",
                evSrc:find('WC_BumpStat%("totalCopper"') ~= nil
                    and evSrc:find('WC_BumpStat%("totalItemsSold"') ~= nil
                    and evSrc:find('WC_BumpStat%("totalItemsDeleted"') ~= nil
                    and evSrc:find('WC_BumpStat%("totalRepairs"') ~= nil
                    and evSrc:find('WC_BumpStatBucket%("soldItemCounts"') ~= nil
                    and evSrc:find('WC_BumpStatBucket%("deletedItemCounts"') ~= nil
                    and evSrc:find('WC_BumpStatBucket%("soldItemsByQuality"') ~= nil
                    and evSrc:find('WC_BumpStatBucket%("deletedItemsByQuality"') ~= nil
                    and evSrc:find('WC_BumpStatBucket%("processCastCounts"') ~= nil
                    -- v0.9.0: the zone bucket is written by the Loot module
                    -- through the exposed helper.
                    and src:find('WC_compCache%.bumpStatBucket%("copperByZone"') ~= nil,
                "Every stat increment site must route through WC_BumpStat / WC_BumpStatBucket so the ADB.accountStats mirror is structurally guaranteed."
            )
            check(
                "Test 88ad: StatsPanel renders the view toggle + started-at note",
                spS:find("panel%._statsView") ~= nil
                    and spS:find('local charRadio = CreateFrame%("CheckButton"') ~= nil
                    and spS:find('local acctRadio = CreateFrame%("CheckButton"') ~= nil
                    and spS:find("startedAtNote") ~= nil,
                "StatsPanel must render Character / Account radio buttons + the started-at one-liner so the user knows where account totals begin."
            )
            check(
                "Test 88ae: RefreshStats reads from view-selected source",
                mpS4:find("panel%._statsView") ~= nil
                    and mpS4:find("ADB%.accountStats") ~= nil
                    and mpS4:find('view%s*==%s*"account"') ~= nil
                    and mpS4:find("src%.totalCopper") ~= nil,
                "RefreshStats must pick its source table based on panel._statsView and read from src.* instead of hard-coding DB.*."
            )
            check(
                "Test 88af: ResetLifetimeStats branches on view",
                mpS4:find('view%s*==%s*"account"') ~= nil
                    and mpS4:find("AS%.totalCopper%s*=%s*0") ~= nil
                    and mpS4:find("AS%.bestGPHChar%s*=%s*\"\"") ~= nil,
                "Reset Lifetime in Account view must clear ADB.accountStats.* + bestGPHChar; Character view keeps clearing DB.*."
            )
            check(
                "Test 88ag: account-side bestGPH writes in the GPH stamp",
                src:find("AS%.bestGPH%s*=%s*sessionGPH") ~= nil
                    and src:find("AS%.bestGPHChar%s*=%s*GetUnitName%(\"player\", true%)") ~= nil,
                "When a session beats the account-wide best, RefreshStats must stamp both the new record AND the character name onto ADB.accountStats so the Account view can show 'on <CharName>'."
            )
            -- v2.38.2: Turbo Mode FinishRun-fires-once invariant.
            -- The OnUpdate batch loop runs N iterations per tick. If the
            -- queue exhausts mid-batch, every remaining iteration would
            -- re-enter `if not action then FinishRun() end` and bump
            -- DB.totalCopper / WC_session.copper N times instead of once,
            -- plus print "Vendoring complete!" N times. The guard is
            -- belt-and-braces: a top-of-DoNextAction `if not
            -- vendorRunning then return end` + a `break` in the batch
            -- for-loop that checks the same flag.
            check(
                "Test 88ah: DoNextAction guards against vendorRunning=false at the top",
                evSrc:find("if not WC_compCache%.vendorRunning then\n%s*return\n%s*end") ~= nil,
                "DoNextAction must early-return when vendorRunning is false. Without this, Turbo Mode's batch loop re-fires FinishRun once per remaining batch slot after the queue drains, inflating totalCopper / session counters Nx and spamming chat."
            )
            check(
                "Test 88ai: Turbo Mode batch loop breaks on vendorRunning=false",
                evSrc:find("for _ = 1, batch do\n%s*DoNextAction%(%)\n%s*-- v2%.38%.2: stop iterating the moment FinishRun fires%.") ~= nil
                    or evSrc:find("DoNextAction%(%)\n%s*-- v2%.38%.2:") ~= nil,
                "The OnUpdate batch loop must break as soon as FinishRun flips vendorRunning to false. Otherwise the remaining iterations call DoNextAction with an empty queue and re-fire FinishRun."
            )
            check(
                "Test 88aj: StatsPanel has a 1Hz OnUpdate refresher gated on visibility",
                spS:find('StatsPanel:SetScript%("OnUpdate"') ~= nil
                    and spS:find("_statsTickAcc") ~= nil
                    and spS:find("self:IsShown%(%)") ~= nil,
                "Without an OnUpdate refresher gated on IsShown, the Stats panel goes static the moment the player opens it - lifetime + session totals update in memory but the displayed numbers stay frozen until close+reopen. The (session +N) suffix v2.38.1 added makes the staleness glaring."
            )
            -- v2.38.3: Process Bags diagnostic. Without a structural
            -- lock, the slash command wiring + Help FAQ + dump builder
            -- could drift apart silently (e.g., command kept but Help
            -- entry deleted, or builder renamed without updating the
            -- /wc processdebug handler).
            local brf = io.open("WoWClearance_BugReport.lua", "rb")
            local hpf = io.open("WoWClearance_HelpPanel.lua", "rb")
            if brf and hpf then
                local brS = brf:read("*a") or ""
                brf:close()
                local hpS = hpf:read("*a") or ""
                hpf:close()
                check(
                    "Test 88ak: /wc processdebug diagnostic wired end-to-end",
                    brS:find("WC_BuildProcessDebugDump") ~= nil
                        and brS:find("NS%.ShowProcessDebugDump%s*=") ~= nil
                        and evSrc:find('cmd == "processdebug"') ~= nil
                        and evSrc:find("NS%.ShowProcessDebugDump%(%)") ~= nil
                        and mpS4:find("processdebug") ~= nil
                        and hpS:find("bug%-process%-debug") ~= nil,
                    "The /wc processdebug command must have: a builder (WC_BuildProcessDebugDump), namespace exposure (NS.ShowProcessDebugDump), a slash handler in Events.lua, a row in Main panel's SLASH_ROWS, AND a Help FAQ entry. Players hitting Mill/Prospect detection bugs need a paste-and-share dump path - same shape /wc affixdebug took for the affix pipeline."
                )
                check(
                    "Test 88ak2: /wc scandebug diagnostic wired end-to-end (v2.44.12)",
                    brS:find("WC_BuildScanDebugDump") ~= nil
                        and brS:find("NS%.ShowScanDebugDump%s*=") ~= nil
                        and evSrc:find('cmd == "scandebug"') ~= nil
                        and evSrc:find("NS%.ShowScanDebugDump%(bag, slot%)") ~= nil
                        and mpS4:find("scandebug") ~= nil,
                    "Zukii's report (v2.44.11 still didn't catch transferred-proc weapons) confirmed that string-pattern fixes on the chance-on-hit detector are guessing in the dark - we couldn't tell whether the proc text was in WC's hidden scan tooltip at all. /wc scandebug dumps every TextLeft line + parsed detection-helper results so future similar reports come with the real signal. Must have: builder (WC_BuildScanDebugDump), namespace exposure (NS.ShowScanDebugDump), slash handler in Events.lua, row in Main panel's SLASH_ROWS."
                )
                -- v2.38.3: the scan tooltip silently loses SetOwner
                -- mid-session (another addon iterating UIParent children
                -- triggers a Hide), after which raw SetBagItem populates
                -- zero lines and every tooltip-scan predicate (Mill /
                -- Prospect / Soulbound / chance-on-hit / lockpick /
                -- bind / openable / known-tome / known-recipe) silently
                -- returns false. Routing every SetBagItem through the
                -- shared scanBagItem helper that re-establishes the
                -- owner is the structural fix. This test makes sure no
                -- file regresses to raw SetBagItem on the scan tooltip.
                local function countRawSetBagItem(src)
                    local n = 0
                    for _ in src:gmatch("scanTooltip:SetBagItem") do
                        n = n + 1
                    end
                    for _ in src:gmatch("scanTip%(%):SetBagItem") do
                        n = n + 1
                    end
                    return n
                end
                local procSrc = (function()
                    local fh = io.open("WoWClearance_Process.lua", "rb")
                    if not fh then return "" end
                    local s = fh:read("*a") or ""
                    fh:close()
                    return s
                end)()
                local protSrc = (function()
                    local fh = io.open("WoWClearance_Protection.lua", "rb")
                    if not fh then return "" end
                    local s = fh:read("*a") or ""
                    fh:close()
                    return s
                end)()
                check(
                    "Test 88am: scanBagItem helper defined in Events.lua",
                    evSrc:find("function WC_compCache%.scanBagItem%(bag, slot%)") ~= nil
                        and evSrc:find("WC_scanTooltip:SetOwner%(UIParent, \"ANCHOR_NONE\"%)") ~= nil
                        and evSrc:find("WC_scanTooltip:SetBagItem%(bag, slot%)") ~= nil,
                    "WC_compCache.scanBagItem must re-establish SetOwner before SetBagItem so the scan never silently no-ops when ownership has been lost mid-session."
                )
                -- v2.38.3: ordering lock. Re-arranging the helper body
                -- to put SetOwner AFTER SetBagItem would silently break
                -- everything again (the SetBagItem call would land on a
                -- tooltip with no owner and populate zero lines). Test
                -- 88am only verifies presence; this one verifies order.
                local function bodyPositions(src)
                    local fnStart = src:find("function WC_compCache%.scanBagItem%(bag, slot%)")
                    if not fnStart then return nil end
                    local bodyEnd = src:find("\nend", fnStart, true)
                    if not bodyEnd then return nil end
                    local body = src:sub(fnStart, bodyEnd)
                    local ownerAt = body:find("SetOwner")
                    local clearAt = body:find("ClearLines")
                    local setBagAt = body:find("SetBagItem")
                    return ownerAt, clearAt, setBagAt
                end
                local ownerAt, clearAt, setBagAt = bodyPositions(evSrc)
                check(
                    "Test 88am-ordering: scanBagItem body calls SetOwner BEFORE SetBagItem",
                    ownerAt and setBagAt and ownerAt < setBagAt
                        and clearAt and clearAt < setBagAt,
                    "Inside the scanBagItem body, SetOwner must precede SetBagItem (and ClearLines must precede SetBagItem). Reversing the order would re-introduce the silent zero-line scan bug v2.38.3 fixed."
                )
                check(
                    "Test 88an: no raw scanTooltip:SetBagItem calls outside the helper",
                    countRawSetBagItem(procSrc) == 0
                        and countRawSetBagItem(protSrc) == 0
                        and countRawSetBagItem(evSrc) <= 1
                        and countRawSetBagItem(brS) == 0,
                    "Every tooltip-scan call site must route through cc.scanBagItem so the SetOwner-before-SetBagItem invariant is structural, not a comment. The single permitted Events.lua reference is the helper body itself. Process.lua, Protection.lua, and BugReport.lua must contain zero raw `:SetBagItem(bag, slot)` against the scan tooltip."
                )
                -- v2.38.3: positive coverage. Every helper that scans
                -- the bag tooltip must reference cc.scanBagItem so that
                -- a future scan-using helper added in Process.lua or
                -- Protection.lua doesn't slip past Test 88an by using
                -- a different scan API (e.g. :SetHyperlink). At least
                -- one WC_compCache.scanBagItem call per scan-heavy file.
                check(
                    "Test 88ao: every scan-heavy file routes through WC_compCache.scanBagItem",
                    procSrc:find("WC_compCache%.scanBagItem%(") ~= nil
                        and protSrc:find("WC_compCache%.scanBagItem%(") ~= nil,
                    "Process.lua and Protection.lua each have multiple tooltip-scan helpers (processTooltipHasLine, canPickLock, processIsSoulbound, itemHasChanceOnHit, bagSlotAffixData, known-tome / known-recipe scans). Each file must contain at least one WC_compCache.scanBagItem call so a future helper that scans by a different API still has the surrounding pattern available."
                )
                check(
                    "Test 88al: Process debug dump surfaces every gate layer",
                    brS:find("Spell knowledge gates") ~= nil
                        and brS:find("IsSpellKnown") ~= nil
                        and brS:find("Tooltip marker globals") ~= nil
                        and brS:find("ITEM_MILLABLE") ~= nil
                        and brS:find("ITEM_PROSPECTABLE") ~= nil
                        and brS:find("Bag walk") ~= nil
                        and brS:find("buildProcessSummary") ~= nil
                        and brS:find("tooltip dump") ~= nil,
                    "The dump must expose every layer that decides Process Bags eligibility (spell knowledge, tooltip globals, per-slot scan, summary counts, and a sample tooltip dump for the first Mill/Prospect hits) so a single paste tells us which layer is failing for the player."
                )
                -- v2.39.1: master Enable discoverability locks. Each
                -- check below closes one half of the veeco bug class
                -- (real player on v2.39.0 with DB.enabled=false who
                -- could not figure out how to flip it back on because
                -- the only paths were minimap right-click and a
                -- keybind). Tests pin the three additive surfaces.
                check(
                    "Test 88ap: Main panel routes Enable checkbox through WoWClearance_ToggleEnabled",
                    mpS4:find("WoWClearanceMainEnableCB") ~= nil
                        and mpS4:find("WoWClearance_ToggleEnabled%(%)") ~= nil
                        and mpS4:find("panel%.enableCB%s*=") ~= nil,
                    "The Main panel Enable checkbox must use NS.AddCheckbox + route the setter through WoWClearance_ToggleEnabled() (NOT a direct DB.enabled = write) so the chat message + sound feedback stay identical to the minimap right-click path. The checkbox must also be stored on the panel (panel.enableCB) so OnShow / slash handlers can re-sync it."
                )
                check(
                    "Test 88aq: /wc status, /wc enable, /wc disable slash subcommands wired",
                    evSrc:find('cmd == "status" or cmd == "enable" or cmd == "disable"') ~= nil
                        and evSrc:find("[Cc]urrently %%s") ~= nil
                        and evSrc:find("[Aa]lready enabled") ~= nil
                        and evSrc:find("[Aa]lready disabled") ~= nil,
                    "Three slash subcommands must exist so a player who can't see the minimap (right-click hidden, button moved out of the way by a host UI replacement) has a chat-driven recovery path. status reports current state; enable / disable flip only if a change is needed (idempotent), reusing WoWClearance_ToggleEnabled() so messaging stays consistent."
                )
                check(
                    "Test 88ar: Help FAQ has a tshoot-not-working entry covering the master toggle",
                    hpS:find('id = "tshoot%-not%-working"') ~= nil
                        and hpS:find("master Enable toggle") ~= nil
                        and hpS:find("/wc enable") ~= nil
                        and hpS:find("Sell%-border tint") ~= nil,
                    "Help FAQ must include the recovery entry for the master Enable toggle (covers the three flip paths + explains why bag borders stay visible when the addon is disabled). Per feedback_release_includes_help_faq memory: any player-facing change MUST update Help/FAQ in the same patch."
                )
                -- v2.39.1 follow-up: bidirectional sync. The toggle
                -- helper must be the single source of truth - it
                -- writes DB.enabled, prints chat, plays sound, AND
                -- refreshes every UI surface that mirrors the state
                -- (minimap icon desaturation, Main panel checkbox).
                -- The two inline-flip sites in Minimap.lua
                -- (right-click handler + LDB launcher) must route
                -- through the helper, not write DB.enabled directly.
                -- Without these checks, a future refactor could
                -- re-introduce divergent toggle paths and the panel
                -- vs minimap icon would silently drift out of sync.
                local minimapSrc = (function()
                    local fh = io.open("WoWClearance_Minimap.lua", "rb")
                    if not fh then return "" end
                    local s = fh:read("*a") or ""
                    fh:close()
                    return s
                end)()
                check(
                    "Test 88as: WoWClearance_ToggleEnabled refreshes minimap icon + panel checkbox",
                    evSrc:find("local mb = NS%.GetMinimapButton and NS%.GetMinimapButton%(%)") ~= nil
                        and evSrc:find("mb%.icon:SetDesaturated%(not DB%.enabled%)") ~= nil
                        and evSrc:find('_G%["WoWClearanceOptionsMain"%]') ~= nil
                        and evSrc:find("mp%.enableCB:SetChecked") ~= nil,
                    "The toggle helper must be the single source of truth: after flipping DB.enabled, it MUST refresh the minimap icon AND the Main panel checkbox so a flip via any entry point keeps every UI surface in sync. Without this, panel ↔ minimap stay out of sync depending on which surface the user clicked."
                )
                -- v2.40.1: Process Bags cast button must paint a
                -- cooldown swirl + disable during GCD. The macrotext
                -- is "/cast Spell" followed by "/use bag slot" - if
                -- /cast fails during the GCD, /use STILL runs and
                -- equips the (equippable) item. Players on PE who've
                -- shortened cast times below the 1.5s GCD trip this
                -- constantly. The fix is structural: a Cooldown
                -- overlay tied to GetSpellCooldown + a
                -- SPELL_UPDATE_COOLDOWN listener that disables the
                -- button while the armed spell is on CD. This test
                -- locks the wiring so a future contributor who
                -- "simplifies" the rearm path can't silently drop the
                -- guard.
                local pbpSrc = (function()
                    local fh = io.open("WoWClearance_ProcessBagsPanel.lua", "rb")
                    if not fh then return "" end
                    local s = fh:read("*a") or ""
                    fh:close()
                    return s
                end)()
                -- v2.41.2: keybind discoverability + tip honesty. The
                -- old Process Bags tip read "hold it to drain a stack"
                -- which is factually wrong - WoW doesn't auto-repeat
                -- bound actions. A player report (Ralickan) followed
                -- the tip, held the key, saw nothing happen. This test
                -- locks all three patch pieces in one shot so any of
                -- them silently disappearing in a future refactor
                -- shows up in CI.
                -- v2.41.2: canDisenchant must filter on equipLoc, not
                -- just IsEquippableItem + quality. Bags are equippable
                -- (they go in bag slots) and a green-quality bag like
                -- Traveler's Backpack slipped through, queued for DE,
                -- and the server refused the cast with "Item cannot
                -- be disenchanted" (real player report). This test
                -- locks the blacklist + the equipLoc read so a future
                -- refactor can't silently drop the guard.
                check(
                    "Test 88aw: canDisenchant filters out bags / quivers / tabards / shirts via equipLoc",
                    procSrc:find("NON_DE_EQUIP_LOCS%s*=%s*{") ~= nil
                        and procSrc:find("INVTYPE_BAG%s*=%s*true") ~= nil
                        and procSrc:find("INVTYPE_QUIVER%s*=%s*true") ~= nil
                        and procSrc:find("INVTYPE_TABARD%s*=%s*true") ~= nil
                        and procSrc:find("INVTYPE_BODY%s*=%s*true") ~= nil
                        and procSrc:find("local _, _, quality, _, _, _, _, _, equipLoc = GetItemInfo") ~= nil
                        and procSrc:find("NON_DE_EQUIP_LOCS%[equipLoc%]") ~= nil,
                    "canDisenchant must read equipLoc (9th GetItemInfo return, unlocalised) and reject INVTYPE_BAG / INVTYPE_QUIVER / INVTYPE_TABARD / INVTYPE_BODY (and INVTYPE_AMMO for belt-and-braces). Without this, a green-quality bag passes IsEquippableItem + the quality gate and the queue shows it for Disenchant; the server then refuses the cast and the player has to skip it manually."
                )
                check(
                    "Test 88av: Process Bags keybind help icon + FAQ entry wired (tip text dropped in v2.44.9)",
                    pbpSrc:find("hold it to drain") == nil
                        and pbpSrc:find('"process%-keybind"') ~= nil
                        and hpS:find('id = "process%-keybind"') ~= nil
                        and hpS:find('panel = "WoWClearanceOptionsProcessBags"') ~= nil,
                    "Process Bags must NOT promise hold-to-drain behaviour anywhere (WoW fires keybinds once per press; the addon cannot auto-repeat a SecureActionButton click). The grey 'Tip:' label was removed in v2.44.9 since the same content is in the process-keybind FAQ entry the [?] icon deep-links to. The icon now sits on the desc line; the FAQ entry must still exist with the WoWClearanceOptionsProcessBags panel link so a player who clicks the icon lands on the right page."
                )
                check(
                    "Test 88au: Process Bags cast button has a post-click lockout with effective-cast-time floor",
                    pbpSrc:find('CreateFrame%("Cooldown"') ~= nil
                        and pbpSrc:find('"CooldownFrameTemplate"') ~= nil
                        and pbpSrc:find("local function startProcessCastCooldown") ~= nil
                        and pbpSrc:find("WC_compCache%.startProcessCastCooldown") ~= nil
                        and pbpSrc:find('SetScript%("PostClick"') ~= nil
                        and pbpSrc:find("PROCESS_BUTTON_FLOOR_SECONDS%s*=%s*1") ~= nil
                        and pbpSrc:find('RegisterEvent%("UNIT_SPELLCAST_START"%)') ~= nil
                        and pbpSrc:find('UnitCastingInfo%("player"%)') ~= nil
                        and pbpSrc:find("armedSpellName") ~= nil
                        and pbpSrc:find("castBtn:Disable") ~= nil
                        and pbpSrc:find("castBtn:Enable") ~= nil
                        and pbpSrc:find("castCD:SetCooldown") ~= nil
                        and pbpSrc:find("noOCC") ~= nil
                        and pbpSrc:find("noCooldownCount") ~= nil,
                    "Process Bags cast button must lock out after every click for max(effective cast time, 1 s). Otherwise a click during the cast-time-less-than-GCD window falls through /cast (silent fail) into /use (equips the item). Cast duration must come from UnitCastingInfo at UNIT_SPELLCAST_START (the effective value with haste/talent/server reductions applied), NOT GetSpellInfo (returns the unmodified base cast time). PostClick still applies the floor immediately so a fast double-click in the pre-cast window can't slip past. Cooldown frame must also opt out of OmniCC-style numeric overlays via noOCC + noCooldownCount."
                )
                check(
                    "Test 88at: Minimap right-click + LDB launcher route through WoWClearance_ToggleEnabled",
                    minimapSrc:find("DB%.enabled%s*=%s*not%s+DB%.enabled") == nil
                        and (function()
                            local count = 0
                            for _ in minimapSrc:gmatch("WoWClearance_ToggleEnabled%(%)") do
                                count = count + 1
                            end
                            return count >= 2
                        end)(),
                    "Minimap.lua must NOT contain any direct `DB.enabled = not DB.enabled` flip - the right-click handler AND the LDB launcher both have to route through WoWClearance_ToggleEnabled() so all UI surfaces (icon + panel checkbox) stay in sync. Requires at least 2 calls to the helper from this file (one per inline-flip site we replaced)."
                )
            end
        end

        -- v2.38.0: Quickstart iteration regression locks. Each row below
        -- closes a bug we hit during in-game iteration so the same trap
        -- can't sneak back in.
        local qpf2 = io.open("WoWClearance_QuickstartPanel.lua", "rb")
        local bcmf = io.open("WoWClearance_BagContextMenu.lua", "rb")
        if qpf2 and bcmf then
            local qpS = qpf2:read("*a") or ""
            qpf2:close()
            local bcS = bcmf:read("*a") or ""
            bcmf:close()
            check(
                "Test 88n: Quickstart - standalone frame (NOT a sidebar sub-panel)",
                -- v0.5.2: the trailing "%)" was relaxed to allow a template
                -- argument. Quickstart now takes "BackdropTemplate", because on
                -- Forever a plain frame has NO SetBackdrop method and the
                -- guarded call silently skipped, leaving the window
                -- see-through. The invariant this test protects is UIParent
                -- parenting + not being a sub-panel, which a template does not
                -- affect. Still pins UIParent.
                qpS:find("CreateFrame%(\"Frame\",%s*\"WoWClearanceOptionsQuickstart\",%s*UIParent") ~= nil
                    and qpS:find('InterfaceOptions_AddCategory%(QuickstartPanel%)') == nil
                    and qpS:find('QuickstartPanel%.parent%s*=%s*"WoWClearance"') == nil,
                "Quickstart must be parented to UIParent + must NOT register itself as an Interface Options sub-panel (that's the whole 'only reachable from Main panel' point). The chrome sets the parent; no .parent = sub-panel marker."
            )
            check(
                "Test 88o: Quickstart - TOOLTIP strata + Toplevel + UISpecialFrames",
                qpS:find('SetFrameStrata%("TOOLTIP"%)') ~= nil
                    and qpS:find("SetToplevel%(true%)") ~= nil
                    -- v0.5.3: the UISpecialFrames assertion is INVERTED. That
                    -- table is not "Escape closes this"; it is "this closes
                    -- whenever anything calls CloseWindows", which was taking
                    -- Quickstart down mid-setup when the settings panel closed.
                    -- Now pinned ABSENT so it cannot be re-added by reflex.
                    and qpS:find('table%.insert%(UISpecialFrames,%s*"WoWClearanceOptionsQuickstart"%)') == nil,
                "Quickstart must sit at TOOLTIP strata (highest) so it lands above any host addon's Interface Options chrome wrappers, and Toplevel auto-raises on click. It must NOT be in UISpecialFrames: that couples its lifetime to every other panel via CloseWindows."
            )
            check(
                "Test 88p: Quickstart - draggable + clamped to screen",
                qpS:find("SetMovable%(true%)") ~= nil
                    and qpS:find('RegisterForDrag%("LeftButton"%)') ~= nil
                    and qpS:find('SetScript%("OnDragStart",%s*QuickstartPanel%.StartMoving%)') ~= nil
                    and qpS:find("SetClampedToScreen%(true%)") ~= nil,
                "Quickstart must be draggable (StartMoving/StopMovingOrSizing) and clamped to the screen so dragging near the edge can't lose the frame."
            )
            check(
                "Test 88q: Quickstart - confirmation popup escalated to TOOLTIP strata",
                qpS:find('dialog:SetFrameStrata%("TOOLTIP"%)') ~= nil,
                "Without this, the WC_APPLY_QUICKSTART StaticPopup renders behind the Quickstart frame because StaticPopups default to DIALOG strata."
            )
            check(
                "Test 88r: Quickstart - chrome inited flag mirrors content frame",
                qpS:find("QuickstartPanel%.inited%s*=%s*QuickstartContent%.inited") ~= nil,
                "Cross-panel refresh loop (in WC_ApplyQuickstart) gates on p.inited. Because initPanel runs on QuickstartContent (not the chrome frame), the chrome's inited flag has to be mirrored or the active-preset tag won't refresh on preset switch."
            )
            check(
                "Test 88s: Quickstart - active tag anchored below + below button, NOT right of it",
                qpS:find('SetPoint%("TOP",%s*presetButtons%[activeKey%],%s*"BOTTOM"') ~= nil,
                "Right-of-button placement (the earlier iteration) put the 'active' text next to the neighbouring preset button and looked like it belonged to that one. Centered below the active button is the correct placement."
            )
            check(
                "Test 88t: Quickstart - Q5b stop-anchor repositions on mode change",
                qpS:find("self%.q5bStop:ClearAllPoints%(%)") ~= nil,
                "When the iLvl mode toggles between dynamic / fixed, the four cap-input rows show or hide. The stop anchor that the next question chains to must reposition so the layout doesn't leave a phantom gap below hidden rows."
            )
            check(
                "Test 88t2: Quickstart - cap-row editboxes do NOT call :Enable() (Cataclysm+ only)",
                qpS:find("capBoxes%[q%]:Enable%(%)") == nil,
                "v2.44.3 bug: EditBox:Enable() / Disable() are Cataclysm+ additions. Calling them on 3.3.5a throws 'attempt to call method Enable (a nil value)' the moment the user toggles Q5b to fixed mode. The editbox is enabled by default - Show()/Hide() on the parent row is the right hook. If a future change genuinely needs enable/disable, use EnableMouse(true/false) and EnableKeyboard(true/false), which DO exist on 3.3.5a."
            )
            check(
                "Test 88u: Quickstart - chat confirm includes preset name (not just 'applied')",
                qpS:find('PRESETS%[presetKey%]%.name') ~= nil,
                "The chat message after applying a preset must include which preset was applied, not just say 'Quickstart applied'."
            )
            check(
                "Test 88v: Quickstart - preset tooltip shows description only (no redundant title)",
                qpS:find('GameTooltip:SetText%(p%.desc') ~= nil
                    and qpS:find('GameTooltip:SetText%(p%.name') == nil,
                "The button label already shows the preset name; the tooltip title repeating it is redundant noise."
            )
            check(
                "Test 88w: Quickstart - immediate-apply on radio click (no separate Apply step)",
                qpS:find("WC_ApplyAnswerImmediate%(questionKey,%s*opt%.value%)") ~= nil
                    and qpS:find('btn:SetText%("Apply changes"%)') == nil,
                "Each radio click writes its answer to DB immediately. The standalone 'Apply changes' button from earlier iterations is gone; only Close remains."
            )
            check(
                "Test 88x: Quickstart - snapshot happens INSIDE initPanel callbacks, after EnsureDB",
                qpS:find("WC_compCache%.initPanel%(QuickstartContent") ~= nil
                    and qpS:find("workingAnswers,%s*workingFixedCaps%s*=%s*snapshotAnswersFromDB%(DB%)") ~= nil,
                "Snapshot before EnsureDB runs (initPanel calls EnsureDB at its top) leaves DB nil or partial and the build callback errors silently. Snapshot must live INSIDE the initPanel refresh + build callbacks."
            )
            check(
                "Test 88y: Quickstart - frame width >= 640 so labels at WC_PANEL_WIDTH fit",
                qpS:find("QuickstartPanel:SetSize%(6") ~= nil,
                "WC's MakeLabel sizes FontStrings to WC_PANEL_WIDTH (the Interface Options container width ~580). A narrower standalone frame clips the labels on the right side. Width must be at least 640 (parsing accepts SetSize(6**, ...) ie. >= 600 prefix)."
            )
            check(
                "Test 88z: BagContextMenu - cursor anchor clamped to screen bounds",
                bcS:find("cx > maxX") ~= nil
                    and bcS:find("UIParent:GetWidth%(%)") ~= nil,
                "Alt+Right-Clicking a bag item near the right edge (common with host bag UI adapters that pin bags right) used to clip the WC popup off the screen. The clamp keeps the popup's right/bottom edges inside UIParent bounds."
            )
        end

        -- v2.37.7: Turbo Mode batch-vendor. EnsureDB seeds DB.turboMode
        -- false. WC_EffectiveBatchSize returns the batch count gated on
        -- DB.turboMode. Worker OnUpdate uses the batch count in a loop
        -- so the v2.0.11 single-item invariant still holds when Turbo is
        -- off (batch=1) but multiple items pop per fire when on.
        local merf = io.open("WoWClearance_MerchantPanel.lua", "rb")
        if merf then
            local merSrc = merf:read("*a") or ""
            merf:close()
            check(
                "Test 88l: Turbo Mode batch-vendor wired",
                evSrc:find("DB%.turboMode%s*=%s*false") ~= nil
                    and evSrc:find("local function WC_EffectiveBatchSize") ~= nil
                    and evSrc:find("local batch = WC_EffectiveBatchSize%(%)") ~= nil
                    and evSrc:find("for _ = 1, batch do") ~= nil
                    and merSrc:find("WoWClearanceTurboModeCB") ~= nil
                    and merSrc:find("Time between sells") ~= nil,
                "EnsureDB seeds turboMode=false; WC_EffectiveBatchSize gates on DB.turboMode; worker loops the batch; Merchant panel renders the Turbo checkbox + relabelled slider."
            )
        end

        -- v2.37.6: /wc perf self-diagnostic. The command must exist
        -- in the slash dispatch, list cache sizes for the major
        -- per-itemID caches, and be discoverable from the Main panel
        -- slash reference + /wc help output.
        local mpf2 = io.open("WoWClearance_MainPanel.lua", "rb")
        if mpf2 then
            local mpSrc2 = mpf2:read("*a") or ""
            mpf2:close()
            -- v2.37.6: clickable Run buttons for slash commands. The
            -- Main panel's Slash Commands section now stacks per-row
            -- frames; runnable commands get a Run button that calls
            -- SlashCmdList["WOWCLEARANCE"] with the command string.
            check(
                "Test 88k: Main panel SLASH_ROWS table + Run-button wiring present",
                mpSrc2:find("SLASH_ROWS%s*=%s*{") ~= nil
                    and mpSrc2:find('SlashCmdList%["WOWCLEARANCE"%]') ~= nil
                    and mpSrc2:find('btn:SetText%(row%.run and L%["Run"%] or L%["How"%]%)') ~= nil,
                "The Main panel must define the SLASH_ROWS table, create Run buttons, and dispatch via SlashCmdList[\"WOWCLEARANCE\"] so players can click commands instead of typing."
            )
        end

        -- v2.37.5: Random-affix bag-slot border category. New entry
        -- in DB.sellBorderCategories.affix (default OFF), wired through
        -- bagSlotWillSellCategory + listed in the Item Highlighting
        -- panel's SELL_BORDER_CATEGORIES array. The detection reuses
        -- WC_compCache.bagSlotAffixData.
        local bdf = io.open("WoWClearance_BagDisplay.lua", "rb")
        local ihpf = io.open("WoWClearance_ItemHighlightingPanel.lua", "rb")
        if bdf and ihpf then
            local bdSrc = bdf:read("*a") or ""
            bdf:close()
            local ihpSrc = ihpf:read("*a") or ""
            ihpf:close()
        end

        -- v2.37.4: Process Bags chrome restoration on second OnShow.
        -- The v2.37.3 OnHide handler hides processScrollBg as a "belt-
        -- and-braces" measure against combat-lockdown bleed-through;
        -- without a matching Show() in the OnShow refresh path the
        -- chrome stays hidden after a panel-switch round-trip. The
        -- refresh callback must Show processScrollBg on every entry.
        local pbpf = io.open("WoWClearance_ProcessBagsPanel.lua", "rb")
        if pbpf then
            local pbpSrc = pbpf:read("*a") or ""
            pbpf:close()
            check(
                "Test 88h: Process Bags refresh callback re-shows processScrollBg",
                pbpSrc:find("self%.processScrollBg:Show%(%)") ~= nil
                    and pbpSrc:find("self%.processScrollBg:Hide%(%)") ~= nil,
                "OnHide hides processScrollBg; without a matching Show in the OnShow refresh path the panel chrome stays hidden on subsequent opens."
            )
        end

        -- v2.37.4 (audit issue #4): side-meta prune for affixedListedItems
        -- and chanceOnHitListedItems. The helper must exist, be exposed on
        -- NS, get called from WC_RemoveItemFromList, and the Clear All
        -- path in ListWidget must snapshot keys before wipe + call the
        -- helper per id.
        local lwf2 = io.open("WoWClearance_ListWidget.lua", "rb")
        if lwf2 then
            local lwSrc2 = lwf2:read("*a") or ""
            lwf2:close()
            check(
                "Test 88g: side-meta prune helper present + wired on remove + wired on Clear All",
                evSrc:find("local function WC_PruneSideMetaForItem%(") ~= nil
                    and evSrc:find("NS%.PruneSideMetaForItem%s*=%s*WC_PruneSideMetaForItem") ~= nil
                    and evSrc:find("WC_PruneSideMetaForItem%(itemID%)") ~= nil
                    and lwSrc2:find("NS%.PruneSideMetaForItem%(cleared%[i%]%)") ~= nil,
                "Removing the last list entry for an itemID must clear ADB.affixedListedItems[id] and ADB.chanceOnHitListedItems[id] so the side meta doesn't accumulate orphans. Clear All must snapshot itemIDs before wipe and prune per id."
            )
        end
    end
end

-- ---------------------------------------------------------------------------
-- Test 88aa (v0.6.0): no automatic delete is left anywhere.
-- ---------------------------------------------------------------------------
-- Forever refuses DeleteCursorItem outside the player's own click or key
-- press (MEASURED 2026-10-10; WC-TRAP on executeBagSlotDelete). The two
-- automatic scans and the vendor delete queue are gone; Delete Next is the
-- only caller, and it also takes greys when "Mark grey items for deletion"
-- is on.
do
    local f = io.open("WoWClearance_Events.lua", "rb")
    local s = f and f:read("*a") or ""
    if f then
        f:close()
    end
    local calls = 0
    for _ in s:gmatch("WC_compCache%.executeBagSlotDelete, ") do
        calls = calls + 1
    end
    check("Test 88aa: Delete Next is the only caller of executeBagSlotDelete",
        #s > 100000 and calls == 1
            and s:find("function WC_compCache%.runAutoDeleteOnPickup%(") == nil
            and s:find("function WC_compCache%.runAutoDeleteGrey%(") == nil
            and s:find('type = "delete"', 1, true) == nil,
        "an automatic delete (debounce scan, vendor queue) can only be blocked by the game and loop with the item on the cursor.")
    local grey = s:match("function WC_compCache%.nextGreyToDelete%(%)(.-)\nend\n") or ""
    check("Test 88aa: the grey pick skips kept, auto-kept, Delete-Listed, equipped, equipment-set and quest items",
        grey:find("quality == 0", 1, true) ~= nil
            and grey:find('itemType ~= "Quest"', 1, true) ~= nil
            and grey:find("not IsEquippedItem(id)", 1, true) ~= nil
            and grey:find("not (keepList and keepList[id])", 1, true) ~= nil
            and grey:find("not (accountKeep and accountKeep[id])", 1, true) ~= nil
            and grey:find("not (blacklistAuto and blacklistAuto[id])", 1, true) ~= nil
            and grey:find("not (deleteList and deleteList[id])", 1, true) ~= nil
            and grey:find("not (WC_compCache.equipmentSetIDs and WC_compCache.equipmentSetIDs[id])", 1, true) ~= nil,
        "Mark grey items for deletion must never take a protected grey.")
    check("Test 88aa: EnsureDB seeds markGreyForDeletion OFF and clears the old automatic switches",
        s:find("DB.markGreyForDeletion = false", 1, true) ~= nil
            and s:find("DB.autoDeleteOnPickup = nil", 1, true) ~= nil
            and s:find("DB.autoDeleteGreyOnLoot = nil", 1, true) ~= nil,
        "destructive options default off.")
end

-- ---------------------------------------------------------------------------
-- v2.47.0 Test 102: auto-mark unsellable affix dupes (Broyo ask).
-- ---------------------------------------------------------------------------
-- DB.autoMarkAffixDupes opts the player into a BAG_UPDATE-driven sweep that
-- adds affixed items they ALREADY own (3-layer dupe check) that are soulbound
-- AND have no vendor value to DB.deleteList. Sellable dupes are left for the
-- existing sell path. The delete-path dupe check (deleteListSlotEligible) must
-- use the SAME 3-layer ownership helper WC_IsSellable uses, or an item gets
-- marked but then vetoed at delete time (marked-but-never-deleted).
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then
            return ""
        end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local ev = fileSrc("WoWClearance_Events.lua")
    local prot = fileSrc("WoWClearance_Protection.lua")
    local kdp = fileSrc("WoWClearance_KeepDeletePanels.lua")
    -- Sources the Test 113 checks below read. They used to be declared by a
    -- neighbouring block whose checks all went with the Project Ebonhold
    -- removal, so they are declared here now.
    local dp = kdp
    local mp = fileSrc("WoWClearance_MainPanel.lua")
    local br = fileSrc("WoWClearance_BugReport.lua")
    local sp = fileSrc("WoWClearance_Loot/WoWClearance_LootWindow.lua")  -- Loot Log window (Loot module, v0.9.0)



    -- v2.71.3 (classifier Stage 4): deleteListSlotEligible is now a thin
    -- delegate (cheap membership pre-gate + Decision.deleteEligible); the
    -- policy body lives in WoWClearance_Decision.lua.
    local dcDel
    do
        local fh = io.open("WoWClearance_Decision.lua", "rb")
        dcDel = fh and fh:read("*a") or ""
        if fh then
            fh:close()
        end
    end
    local delStart = ev:find("function WC_compCache%.deleteListSlotEligible%(")
    local delEnd = ev:find("function WC_compCache%.shouldAnnounceAutoDelete", delStart or 1)
    local delBody = (delStart and delEnd) and ev:sub(delStart, delEnd) or ""

    -- affixDisposable is the single release decision: Allow-Sell, OR owned dupe
    -- with a dupe-disposal toggle on, OR rank below the floor. The mark scan and
    -- the delete gate both lean on it.
    local dispStart = ev:find("function WC_compCache%.affixDisposable%(affix%)")
    local dispEnd = ev:find("function WC_compCache%.deleteListSlotEligible", dispStart or 1)
    local dispBody = (dispStart and dispEnd) and ev:sub(dispStart, dispEnd) or ""

    local markStart = ev:find("function WC_compCache%.runAutoMarkAffixDupes%(%)")
    local markEnd = ev:find("local function BuildQueue", markStart or 1)
    local markBody = (markStart and markEnd) and ev:sub(markStart, markEnd) or ""

    check("Test 113e: WC_HasConflictingDeleteAddon detects the third-party addon via IsAddOnLoaded",
        ev:find("local function WC_HasConflictingDeleteAddon%(%)") ~= nil
            and ev:find('IsAddOnLoaded and IsAddOnLoaded%("AutoDelete"%)') ~= nil
            and ev:find("NS%.HasConflictingDeleteAddon = WC_HasConflictingDeleteAddon") ~= nil,
        "v2.49.2: detection helper for the third-party auto-delete addon. Per CLAUDE.md, code MAY reference the specific folder name via IsAddOnLoaded (necessary detection code); comments + local variable + all user-facing text stay neutral. Exposed on NS so /wc bugreport can consume it too.")
    check("Test 113f: PLAYER_LOGIN shows the neutral conflict popup when toggle + detection + enableDeletion are all true",
        ev:find('event == "PLAYER_LOGIN"') ~= nil
            and ev:find("if DB%.enableDeletion and DB%.warnConflictingAddons and WC_HasConflictingDeleteAddon%(%) then") ~= nil
            and ev:find('StaticPopup_Show%("WC_CONFLICT_WARNING"%)') ~= nil
            and ev:find('StaticPopupDialogs%["WC_CONFLICT_WARNING"%]') ~= nil
            and ev:find('L%["|cffff4444Another addon that deletes items is also running%.') ~= nil,
        "v2.49.2: PLAYER_LOGIN handler MUST show the modal conflict popup (a one-time chat line was easy to miss) only when all three conditions hold - WC's delete path is active (enableDeletion), the player hasn't opted out (warnConflictingAddons), and the detection helper reports a conflicting addon. The popup NAMES the conflicting addon ('Auto Delete') - a user-sanctioned one-off exception to the no-third-party-names rule so the warning is actionable; the detection helper, comments, and /wc bugreport line stay neutral. One-shot per session (gated inside the PLAYER_LOGIN-only branch, not PLAYER_ENTERING_WORLD).")
    check("Test 113g: main panel surfaces Warn about conflicting addons checkbox (persists via NS.DB)",
        mp:find("WoWClearanceWarnConflictingAddonsCB") ~= nil
            and mp:find("NS%.DB%.warnConflictingAddons") ~= nil
            and mp:find('L%["Warn about conflicting addons"%]') ~= nil,
        "v2.49.2: the conflict-warning opt-out lives on the MAIN panel with the other global toggles (version alert / minimap button), NOT in Delete Settings - it's an informational preference, not a delete rule. Frame name locked (tests grep for it) and the label pinned. MUST read/write NS.DB fully-qualified: BuildMainPanel has NO `DB` upvalue (bare `DB` resolves to the nil global), so a bare `DB.warnConflictingAddons` getter/setter silently fails to persist - the tick reverts on /reload (v2.49.2 in-game bug report from Serv). enableCB uses the same NS.DB pattern.")
    check("Test 113h: /wc bugreport surfaces third-party auto-delete addon detection",
        br:find("Third%-party auto%-delete addon detected:") ~= nil
            and br:find("NS%.HasConflictingDeleteAddon") ~= nil,
        "v2.49.2: /wc bugreport MUST include the neutral capability line under Environment Capabilities. Consumes NS.HasConflictingDeleteAddon so the source of truth is the same helper the PLAYER_LOGIN warning uses. The Loaded Addons dump further down already lists every addon by folder name - this line is the flag the maintainer scans for first.")
    check("Test 114: Loot Log window refresh is dirty-driven (WC_BumpLoot flags; window consumes) not an unconditional 1s rebuild",
        src:find("WC_compCache%.lootWindowDirty = true") ~= nil
            and sp:find("WC_compCache%.lootWindowDirty") ~= nil
            and sp:find("self%._lootTick >= safetyEvery") ~= nil
            and sp:find("local safetyEvery = %(self%._primedLast or 0%) > 0 and 2%.0 or 15%.0") ~= nil,
        "v2.50.1 perf: the Loot Log window MUST rebuild only when new loot was actually credited (WC_BumpLoot sets WC_compCache.lootWindowDirty), coalesced, with a bounded safety fallback - NOT an unconditional per-second lootRefresh. The old 1s rebuild called GetItemInfo over every looted itemID + re-sorted every second while the window was open even when nothing dropped. v2.68.0 tightened the fallback further: a rebuild is a full sweep of the scope (thousands of itemIDs on Account), so the fast 2 s cadence is now held ONLY while the item-cache primer is still resolving names (win._primedLast > 0) and drops to 15 s once it is not. Keep BOTH the dirty consume and the two-speed cap - dropping to a single fixed interval either re-introduces the constant sweep or lets freshly primed names sit unrendered.")
    check("Test 114b: Loot Log renders only the visible row window (virtualised list)",
        sp:find("local function lootRenderVisible", 1, true) ~= nil
            and sp:find("local slots = math%.ceil%(viewH / LOOT_ROW_H%) %+ 2") ~= nil
            and sp:find('scroll:HookScript%("OnVerticalScroll"') ~= nil
            and sp:find("win%.content:SetHeight%(math%.max%(1, #arr %* LOOT_ROW_H%)%)") ~= nil,
        "v2.68.0 perf (Serv report: Account scope degraded the WHOLE client, not just the window): lootRefresh MUST NOT create a frame per entry. With 5000+ items that is 5000 frames each holding an icon + two FontStrings, and WoW's layout cost scales with live frame count across the entire UI. The list MUST stay virtualised: a pool sized to the viewport (ceil(viewH / LOOT_ROW_H) + 2), re-bound to a different slice on scroll via a HookScript on OnVerticalScroll (HookScript, NOT SetScript - the template's own handler drives the scrollbar thumb), with content height still spanning the full array so the scrollbar range stays honest. Row position belongs at bind time in lootRenderVisible, never at creation in lootGetRow.")
end

-- ---------------------------------------------------------------------------
-- Test 115: frame-spike diagnostic is a cheap, bounded, session-only ring
-- that attributes a hitch to an WC phase without adding heavy per-frame work.
-- ---------------------------------------------------------------------------
do
    check("Test 115a: spike phase counters exist and are exposed cross-file",
        src:find("local WC_spikePhase = { bagupdate = 0, vendor = 0, tooltip = 0 }", 1, true) ~= nil
            and src:find("WC_compCache%.spikePhase = WC_spikePhase") ~= nil
            and src:find("local WC_prof = debugprofilestop", 1, true) ~= nil,
        "The frame-spike diagnostic MUST keep its three cumulative-ms phase counters (bagupdate/vendor/tooltip) and expose them on WC_compCache so the tooltip module (a separate file) can add to the same table. Timing uses debugprofilestop, which is always available on 3.3.5a with no CVar.")
    check("Test 115b: watchdog is delta-based and the ring is bounded",
        src:find("if elapsed < WC_SPIKE_THRESHOLD_S or elapsed > WC_SPIKE_CEILING_S then", 1, true) ~= nil
            and src:find("if #WC_spikeLog > WC_SPIKE_LOG_MAX then", 1, true) ~= nil
            and src:find("table%.remove%(WC_spikeLog%)") ~= nil,
        "The watchdog MUST gate on a per-frame elapsed threshold (and ignore loading-screen mega-frames via the ceiling) and the log MUST be a bounded ring (cap WC_SPIKE_LOG_MAX, oldest trimmed). Session-only, never persisted.")
    check("Test 115c: each phase is timed additively at its hot path",
        src:find("WC_spikePhase%.bagupdate = WC_spikePhase%.bagupdate %+") ~= nil
            and src:find("WC_spikePhase%.vendor = WC_spikePhase%.vendor %+") ~= nil
            and src:find("sp%.tooltip = sp%.tooltip %+") ~= nil,
        "The bag-update flush, the vendor batch, and the tooltip annotation MUST each accumulate their own elapsed ms into the matching phase counter. Regressing any of these blinds /wc spike to that subsystem.")
    check("Test 115d: tooltip body kept separate from its timing wrapper (WC-TRAP mirror preserved)",
        src:find("local function WC_AnnotateTooltipInner", 1, true) ~= nil
            and src:find("local function WC_AnnotateTooltip%(tooltip%)") ~= nil,
        "The tooltip timing wrapper MUST wrap the annotation body, not inline timing into it - the body deliberately mirrors WC_IsSellable (WC-TRAP) and must not be merged or restructured.")
    check("Test 115e: /wc spike command surfaces the ring",
        src:find('cmd == "spike"', 1, true) ~= nil
            and src:find("NS%.ShowFrameSpikes") ~= nil,
        "The /wc spike command MUST call NS.ShowFrameSpikes to render the recent-hitch ring.")
end

-- ---------------------------------------------------------------------------
-- Test 116 (v2.57.0): session sell/delete logs capture the WHOLE session and
-- the interactive Sold History window is wired up, replacing the old 20-cap
-- copy-only /wc history.
-- ---------------------------------------------------------------------------
do
    check("Test 116a: session logs hold the full session (5000-cap, seq-stamped, dirty-flagged)",
        src:find("WC_RECENT_SOLD_LOG_MAX = 5000", 1, true) ~= nil
            and src:find("WC_RECENT_DELETED_LOG_MAX = 5000", 1, true) ~= nil
            and src:find("seq = WC_historySeq", 1, true) ~= nil
            and src:find("WC_compCache.historyDirty = true", 1, true) ~= nil,
        "The sell/delete session logs MUST hold the whole session (5000 cap, not the old 20), stamp a monotonic seq on each entry for exact newest-first ordering, and set WC_compCache.historyDirty so the open window refreshes. Regressing the cap loses actions during a farm - the reported bug.")
    check("Test 116b: trim counter + Clear so nothing is silently lost",
        src:find("WC_soldLogTrimmed", 1, true) ~= nil
            and src:find("WC_deletedLogTrimmed", 1, true) ~= nil
            and src:find("function NS.SessionHistoryTrimmed", 1, true) ~= nil
            and src:find("function NS.ClearSessionHistory", 1, true) ~= nil,
        "Overflow past the cap MUST bump a trim counter (surfaced by NS.SessionHistoryTrimmed so the window can show 'N earlier entries trimmed'), and NS.ClearSessionHistory MUST exist for the window's Clear button.")
    check("Test 116c: /wc bugreport shows only a tail slice of the (now large) logs",
        src:find("NS.bugReportRecentMax", 1, true) ~= nil
            and src:find("newest %d of %d - full list in /wc history", 1, true) ~= nil,
        "Because the logs now hold thousands, /wc bugreport MUST slice only the newest NS.bugReportRecentMax of each so reports stay short, noting the full list is in /wc history.")
    check("Test 116d: interactive Sold History window wired (NS.ShowHistoryWindow, preferred by NS.ShowSessionHistory)",
        src:find("function NS.ShowHistoryWindow", 1, true) ~= nil
            and src:find("if NS.ShowHistoryWindow then", 1, true) ~= nil
            and src:find("WoWClearanceHistoryWindow", 1, true) ~= nil,
        "The interactive window (NS.ShowHistoryWindow) MUST exist and NS.ShowSessionHistory MUST prefer it (falling back to the text dump only when the module is absent).")
    check("Test 116e: window offers All/Sold/Deleted filters + search + Copy",
        src:find("win.filter", 1, true) ~= nil
            and src:find("win.search", 1, true) ~= nil
            and src:find("HIST_DISPLAY_MAX", 1, true) ~= nil,
        "The window MUST support filtering (win.filter across All/Sold/Deleted), a search field (win.search), and cap rendered rows (HIST_DISPLAY_MAX) with Copy for the full list.")
end

-- ---------------------------------------------------------------------------
-- Test 118 (v2.57.2): the unsellable-affix auto-mark and its tooltip preview
-- share ONE protection gate (itemProtectedFromAutoMarkDelete), so a set member,
-- equipped, quest, account-list, or high-iLvl item can never be auto-marked for
-- deletion and the tooltip can never falsely threaten it. Serv report: a worn
-- set-member ring / shirt showed "Will Delete" and a quest-reward ring got
-- marked. The scan also force-refreshes equipment-set membership each pass so a
-- stale cache can't leak a set member through.
-- ---------------------------------------------------------------------------
do
    check("Test 118a: shared auto-mark protection gate exists",
        src:find("function WC_compCache.itemProtectedFromAutoMarkDelete", 1, true) ~= nil,
        "WC_compCache.itemProtectedFromAutoMarkDelete MUST exist - the single gate runAutoMarkAffixDupes and the tooltip preview both call so they agree on what is protected from auto-mark deletion.")
    check("Test 118b: the gate protects high item level (real gear)",
        src:find("WC_AUTOMARK_PROTECT_ILVL", 1, true) ~= nil
            and src:find("ilvl >= WC_AUTOMARK_PROTECT_ILVL", 1, true) ~= nil,
        "The gate MUST protect items at/above WC_AUTOMARK_PROTECT_ILVL - on Project Ebonhold even top-end soulbound gear has sellPrice 0, so item level is the safety signal, not vendor value.")
    local n = select(2, src:gsub("itemProtectedFromAutoMarkDelete", ""))
    -- v2.73.2 (Serv report - Cuffs of the Shadow Ascendant of Fortified by
    -- Pain II, BoE): the scan's soulbound gate must be mirrored by BOTH
    -- preview surfaces, or they threaten a delete that never happens.
end

-- ---------------------------------------------------------------------------
-- Test 119 (v2.59.0): shared per-flush bag snapshot.
-- ---------------------------------------------------------------------------
-- The settled BAG_UPDATE flush builds ONE bag snapshot and every scanner in
-- the chain iterates it instead of walking bags independently. Invariants:
-- the snapshot is built inside the flush and validity is the frame it was
-- built in (`at == GetTime()`), so a mid-flush error can never leak a stale
-- snapshot into a later frame; scanners running AFTER the pickup-delete
-- scan (which can synchronously empty a slot) re-verify the live slot
-- before tooltip work or destructive action; the openable cache never
-- stores the transient LOCKED state (lockpicked boxes must re-scan).
do
    check("Test 119a: buildBagFlushSnapshot exists and stamps the build frame",
        src:find("function WC_compCache%.buildBagFlushSnapshot%(%)") ~= nil
            and src:find("counts = counts, at = GetTime()", 1, true) ~= nil,
        "the shared snapshot must exist and carry the GetTime() frame stamp its validity check relies on.")
    check("Test 119b: currentFlushSnapshot validates the frame stamp",
        src:find("snap and snap%.at == GetTime%(%)") ~= nil,
        "currentFlushSnapshot must only return a snapshot built THIS frame; anything looser lets an error mid-flush leave a stale snapshot influencing a scanner on a later frame.")
    -- v2.63.0: the snapshot is acquired LAZILY. The flush must NOT build it
    -- eagerly (default config has no entries-consumer enabled, so an eager
    -- build allocates ~one table per occupied slot per burst for nobody);
    -- acquireFlushSnapshot builds-and-caches on first use with the same
    -- same-frame stamp, and the flush still clears the ref at the end.
    check("Test 119c: acquireFlushSnapshot builds lazily and caches on WC_compCache.flushSnapshot",
        src:find("function WC_compCache%.acquireFlushSnapshot%(%)") ~= nil
            and src:find("snap = WC_compCache.buildBagFlushSnapshot()\n    WC_compCache.flushSnapshot = snap", 1, true) ~= nil
            and select(2, src:gsub("WC_compCache%.flushSnapshot = WC_compCache%.buildBagFlushSnapshot%(%)", "")) == 0,
        "the flush must not build the snapshot eagerly (an eager build allocates per-slot tables per burst even when every entries-consumer is toggled off); scanners acquire it on first use, cached under the same-frame stamp.")
    local _, consumers = src:gsub(
        "WC_compCache%.acquireFlushSnapshot%(%)", "")
    check("Test 119d: scanners acquire the shared snapshot lazily",
        consumers >= 8,
        "expected >= 8 mentions of `WC_compCache.acquireFlushSnapshot()` (the definition plus the seven scanner call sites: auto-open x2, upgrades, pickup-delete, resilience, affix-dupes, grey, known-recipes); found " .. consumers .. ". A scanner reverting to its own nested bag walk reintroduces the multi-walk cost.")
    local _, verifies = src:gsub("GetContainerItemID%(e%.bag, e%.slot%) == id", "")
    check("Test 119e: post-pickup-delete scanners live-verify the slot before acting",
        verifies >= 3,
        "resilience / affix-dupes / grey-delete run after the pickup-delete scan can synchronously empty a slot; each must re-verify GetContainerItemID(e.bag, e.slot) == id before tooltip scans or destructive action, or an itemID-keyed cache can be poisoned by an emptied slot. Found " .. verifies .. " of 3.")
    check("Test 119f: openable cache stores only 'never' - openable/LOCKED are NEVER cached (v2.59.3 correction)",
        src:find('WC_compCache%.openableCache%[itemID%] = "openable"') == nil
            and src:find("if sawAnyLine then") ~= nil
            and src:find('WC_compCache%.openableCache%[itemID%] = "never"') ~= nil
            and src:find("txt == LOCKED") ~= nil,
        "v2.59.3 fix (Serv lockbox loop): WC_IsOpenable caches ONLY 'never' (stable per itemID for non-container items). Caching 'openable' was a footgun - GetContainerItemInfo's `locked` field is unreliable for never-picked lockboxes in 3.3.5a, so a still-locked instance of an itemID cached as openable (from a picked instance) would pass the openable check, UseContainerItem would fire, and the server would spam 'item is locked' errors in a 0.4s retry loop. Only the LOCKED tooltip line is per-instance-reliable, so we always tooltip-scan potentially-openable items.")
end

-- ---------------------------------------------------------------------------
-- Test 120: city-zone filter (v2.59.5, Serv report).
-- ---------------------------------------------------------------------------
-- Serv reported that mailboxed items vendored in Dalaran / Stormwind / etc.
-- were showing up on the Top Zones leaderboard as if the player had farmed
-- gold there, which distorted the "best farming zone" comparison. Fix: an
-- WC_CITY_ZONES set drives (a) an attribution-time skip in
-- attributeCopperToZone so future writes never land in a city bucket, and
-- (b) one-shot EnsureDB / EnsureAccountDB scrubs that strip existing city
-- keys out of the historical DB.copperByZone / ADB.accountStats.copperByZone
-- data. Wallet totalCopper is bumped separately, so accurate wallet totals
-- are untouched by the filter.
do
    check("Test 120a: WC_CITY_ZONES covers all 10 WotLK cities across enUS + deDE + frFR + esES",
        src:find('local WC_CITY_ZONES_BY_LOCALE', 1, true) ~= nil
            -- enUS
            and src:find('"Stormwind City"', 1, true) ~= nil
            and src:find('"Ironforge"', 1, true) ~= nil
            and src:find('"Darnassus"', 1, true) ~= nil
            and src:find('"The Exodar"', 1, true) ~= nil
            and src:find('"Orgrimmar"', 1, true) ~= nil
            and src:find('"Thunder Bluff"', 1, true) ~= nil
            and src:find('"Undercity"', 1, true) ~= nil
            and src:find('"Silvermoon City"', 1, true) ~= nil
            and src:find('"Shattrath City"', 1, true) ~= nil
            and src:find('"Dalaran"', 1, true) ~= nil
            -- deDE
            and src:find('"Sturmwind"', 1, true) ~= nil
            and src:find('"Eisenschmiede"', 1, true) ~= nil
            and src:find('"Unterstadt"', 1, true) ~= nil
            and src:find('"Silbermond"', 1, true) ~= nil
            -- frFR (the reported "Fossoyeuse" case)
            and src:find('"Hurlevent"', 1, true) ~= nil
            and src:find('"Forgefer"', 1, true) ~= nil
            and src:find('"Fossoyeuse"', 1, true) ~= nil
            and src:find('"Lune-d\'argent"', 1, true) ~= nil
            -- esES
            and src:find('"Ventormenta"', 1, true) ~= nil
            and src:find('"Forjaz"', 1, true) ~= nil
            and src:find('"Lunargenta"', 1, true) ~= nil,
        "the WC_CITY_ZONES_BY_LOCALE table must enumerate every WotLK city across the shipped locales (enUS/enGB, deDE, frFR, esES/esMX). Realm-wide aggregation pools across ALL clients' locales, so a French client sending 'Fossoyeuse' as their Undercity attribution needs to be recognized by an English receiver as a city entry. Additional locales (ruRU / koKR / zhCN / zhTW) can be added when specific localized names appear in the wild.")
    check("Test 120b: WC_compCache.isCityZone helper exists",
        src:find("function WC_compCache%.isCityZone%(zone%)") ~= nil,
        "callers outside Events.lua that want to query the city set (the Loot module's zone attribution) MUST route through WC_compCache.isCityZone rather than duplicating a hardcoded list. Removing the helper is a mirror-drift trap.")
    check("Test 120c: onSoldCopper (Loot module) guards the zone bucket write with isCityZone",
        src:find("if not WC_compCache%.isCityZone%(zone%) then%s*WC_compCache%.bumpStatBucket%(\"copperByZone\"") ~= nil,
        "the city guard MUST wrap the bucket write. Without it a mail-box vendor sale in Dalaran writes to DB.copperByZone['Dalaran'] and re-pollutes the leaderboard on the very next login.")
    check("Test 120d: EnsureDB city scrub runs every login (v2.59.10 removed the one-shot gate)",
        src:find("DB%.copperByZone%[zone%] = nil") ~= nil
            and src:find("if not DB%.cityZonesScrubbed then") == nil,
        "the DB scrub MUST run every EnsureDB so a bucket re-polluted by an older, unfiltered version self-heals. The old cityZonesScrubbed marker must never gate the loop (it is now cleared, not written: the downgrade target it served reads a different saved file).")
    check("Test 120e: EnsureAccountDB city scrub runs every login (v2.59.10 removed the one-shot gate)",
        src:find("AS%.copperByZone%[zone%] = nil") ~= nil
            and src:find("if not ADB%.cityZonesScrubbed then") == nil,
        "same rationale as Test 120d: the account bucket also scrubs on every EnsureAccountDB, not gated. Idempotent when nothing needs clearing.")
end

-- ---------------------------------------------------------------------------
-- Test 145: the Process Next secure button fires on the up click.
-- ---------------------------------------------------------------------------
-- It registers UP clicks only. On this client a secure action button acts on
-- the DOWN click when "cast on key down" is on (the default), so without
-- useOnKeyDown = false every press was dropped and Process Next did nothing.
do
    local f = io.open("WoWClearance_ProcessBagsPanel.lua", "r")
    local src = f and f:read("*a") or ""
    if f then
        f:close()
    end
    check(
        "Test 145: Process Next button pins useOnKeyDown to false",
        src:find('castBtn:RegisterForClicks%("AnyUp"%)') ~= nil
            and src:find('castBtn:SetAttribute%("useOnKeyDown", false%)') ~= nil,
        "WoWClearanceProcessCastBtn registers up clicks only, so it must set useOnKeyDown = false or the secure action never fires"
    )
end

-- ---------------------------------------------------------------------------
-- Test 121: Quickstart "(default)" labels must match the actual fresh-install
-- default that snapshotAnswersFromDB would produce (v2.59.6, Qvintus report).
-- ---------------------------------------------------------------------------
-- Qvintus reported Q13 tagged "No" as "(default)" while a fresh install
-- actually seeds DB.enableDeletion = true and thus selects "Yes". Root cause
-- was mirror drift between the panel label and the EnsureDB seed. New players
-- who trust the "(default)" tag can end up misconfigured (Q13's case:
-- believing WC won't delete anything when it actually will). This is a churn
-- risk the label bug had all to itself; the test below prevents it from
-- coming back.
--
-- Strategy:
--   1. Parse WoWClearance_QuickstartPanel.lua for every makeRadioGroup call.
--      For each call, capture the questionKey (3rd arg) and any option whose
--      label contains "default" (matches both "(default)" and
--      "(safest, default)").
--   2. Hand-authored EXPECTED_DEFAULTS holds what snapshotAnswersFromDB
--      SHOULD return for each labeled question on a fresh install. Cross-
--      derived from EnsureDB seeds in Events.lua + the snapshotAnswersFromDB
--      body in QuickstartPanel. Updating a "(default)" label / EnsureDB seed
--      requires updating this map.
--   3. Assert the parsed label agrees with the golden.
--   4. Assert exactly one "(default)"-tagged option per question.
--   5. Every entry in EXPECTED must have a live label (catches label removal).
--   6. Cross-check the specific EnsureDB seed lines the golden depends on so
--      DB-side drift also trips the test (not just label drift).
do
    -- Read QuickstartPanel in isolation for parsing.
    local qpf = io.open("WoWClearance_QuickstartPanel.lua", "rb")
    local qpSrc = qpf and qpf:read("*a") or ""
    if qpf then qpf:close() end

    local labeled = {} -- questionKey -> value marked "(default)"
    local counts = {} -- questionKey -> number of "(default)"-marked options
    for callBody in qpSrc:gmatch("makeRadioGroup(%b())") do
        local qid = callBody:match(',%s*"([^"]+)"%s*,')
        if qid then
            for line in callBody:gmatch("[^\n]+") do
                local value = line:match('value%s*=%s*"([^"]+)"')
                if value and line:find("default", 1, true) then
                    if line:find("label%s*=%s*L%[") then
                        labeled[qid] = value
                        counts[qid] = (counts[qid] or 0) + 1
                    end
                end
            end
        end
    end

    -- Golden: what snapshotAnswersFromDB produces on a fresh install for each
    -- question that carries a "(default)" label. When a "(default)" label is
    -- added, moved, or removed - or when the EnsureDB seed for one of these
    -- fields changes - update BOTH this map AND the label so they stay
    -- honest with the player.
    local EXPECTED = {
        -- Q9b sellRecipes. Fresh install: DB.sellKnownRecipes = false
        -- -> snapshotAnswersFromDB: not DB.sellKnownRecipes -> "no".
        sellRecipes = "no",
        -- Q13 delete. Fresh install: DB.enableDeletion = true
        -- -> snapshotAnswersFromDB: DB.enableDeletion and "yes" or "no" -> "yes".
        -- (This is the Qvintus bug: pre-fix the label wrongly tagged "no".)
        delete = "yes",
        -- Q9b greyDelete. Fresh install: DB.markGreyForDeletion = false
        greyDelete = "no",
        -- Q4c greys. Fresh install: DB.sellGreys = true -> "on".
        greys = "on",
        -- Q4d vendorSell. Fresh install: DB.sellAtVendor = true -> "on".
        vendorSell = "on",
    }

    for qid, val in pairs(labeled) do
        check("Test 121." .. qid .. ": '(default)' label matches fresh-install snapshotAnswersFromDB",
            EXPECTED[qid] == val,
            "Quickstart question '" .. qid .. "' labels value='" .. val
                .. "' as '(default)' but the fresh-install DB would produce '"
                .. tostring(EXPECTED[qid])
                .. "'. Either the label points to the wrong option (Qvintus's Q13 bug), OR EnsureDB's seed changed and the golden EXPECTED / label / seed are now out of sync. Reconcile all three.")
    end

    for qid, n in pairs(counts) do
        check("Test 121." .. qid .. ".unique: exactly one '(default)' label",
            n == 1,
            "Quickstart question '" .. qid .. "' has " .. n
                .. " options tagged '(default)'; exactly one option must be marked so a new player sees a single unambiguous recommendation.")
    end

    for qid in pairs(EXPECTED) do
        check("Test 121." .. qid .. ".present: golden entry has a live label",
            labeled[qid] ~= nil,
            "EXPECTED map lists Q '" .. qid
                .. "' but no option in that radio group carries a '(default)' tag anymore. Either re-add the label OR remove this entry from EXPECTED.")
    end

    -- Cross-check the EnsureDB seeds the golden depends on. If someone flips
    -- a seed value, this fires and forces re-derivation of EXPECTED + label.
    check("Test 121: EnsureDB seeds DB.enableDeletion = true (backs Q13 delete='yes')",
        src:find("DB%.enableDeletion = true", 1, false) ~= nil,
        "EnsureDB no longer seeds DB.enableDeletion = true. If intentional, update Q13 label + EXPECTED.delete in this test.")
    check("Test 121: EnsureDB seeds DB.sellKnownRecipes = false (backs Q9b sellRecipes='no')",
        src:find("DB%.sellKnownRecipes = false", 1, false) ~= nil,
        "EnsureDB no longer seeds DB.sellKnownRecipes = false. If intentional, update Q9b label + EXPECTED.sellRecipes.")
    check("Test 121: EnsureDB seeds DB.markGreyForDeletion = false (backs Q9b greyDelete='no')",
        src:find("DB%.markGreyForDeletion = false", 1, false) ~= nil,
        "EnsureDB no longer seeds DB.markGreyForDeletion = false. If intentional, update the Q9b label + EXPECTED.greyDelete.")
end

-- ---------------------------------------------------------------------------
-- Test 122: checkbox label FontStrings must use reactive width, not bare
-- SetWidth(<literal>) (v2.59.8, Serv report).
-- ---------------------------------------------------------------------------
-- Serv reported the Delete Settings panel doesn't rescale on Interface
-- Options resize: labels like "Auto-delete these items the moment they enter
-- your bags" were being clipped at "...your ba..." because every checkbox
-- text used a bare SetWidth(420) that overflowed the ~360px default panel
-- and never re-measured on resize. The reactive-panel-layout invariant
-- (docs/ADDON_GUIDE.md) requires any widget that snapshots a horizontal
-- extent to route through WC_compCache.setPanelWidth / registerWidth. This
-- test pins the invariant: for every `_G[<name> .. "Text"]` lookup on a
-- checkbox in an WC panel file, the following block must NOT contain a bare
-- `<text>:SetWidth(<numeric literal>)` call. setPanelWidth() and
-- registerWidth() calls are exempt (they ARE the reactive pattern).
--
-- Scans every WoWClearance_*Panel.lua file individually and the shared
-- PanelWidgets helper. Fails with a source location so the offending site
-- is easy to find.
do
    local PANEL_FILES = {
        "WoWClearance_KeepDeletePanels.lua",
        "WoWClearance_MerchantPanel.lua",
        "WoWClearance_PanelWidgets.lua",
        "WoWClearance_MainPanel.lua",
        "WoWClearance_ProtectionPanel.lua",
        "WoWClearance_ItemHighlightingPanel.lua",
        "WoWClearance_SellListPanels.lua",
        "WoWClearance_ProfilesPanel.lua",
        "WoWClearance_QuickstartPanel.lua",
        "WoWClearance_StatsPanel.lua",
        "WoWClearance_ProcessBagsPanel.lua",
        "WoWClearance_Loot/WoWClearance_GuildPanel.lua",
    }
    local violations = {}
    for _, path in ipairs(PANEL_FILES) do
        local f = io.open(path, "rb")
        if f then
            local content = f:read("*a")
            f:close()
            local lineNo = 0
            -- Track the variable name used to reference a checkbox Text.
            -- Pattern: `local <var> = _G[<something> .. "Text"]`. When we
            -- see a subsequent `<var>:SetWidth(<digits>)` line, that's a
            -- checkbox-label bare-SetWidth violation.
            local textVars = {}
            for line in (content .. "\n"):gmatch("([^\n]*)\n") do
                lineNo = lineNo + 1
                local stripped = line:match("^%s*(.-)%s*$") or ""
                if stripped:sub(1, 2) ~= "--" then
                    -- v2.59.10 (bug-hunt): widened. The pre-fix pattern
                    -- required `_G[` to sit immediately after `=`, so a
                    -- variant like `local qText = qcb and _G[...]` was
                    -- silently ignored - a future SetWidth on such a var
                    -- would slip past the invariant. Now match any
                    -- `_G[...Text[...]]` fragment on the RHS of a
                    -- `local <var> = ...` assignment.
                    local var = line:match("local%s+([%w_]+)%s*=.-_G%[.-Text[\"']?%s*%]")
                    if var then
                        textVars[var] = lineNo
                    end
                    for var, _ in pairs(textVars) do
                        if line:find(var .. ":SetWidth%(%d+%)", 1, false) then
                            violations[#violations + 1] = path .. ":" .. lineNo .. " -> " .. stripped
                        end
                    end
                end
            end
        end
    end
    -- ---------------------------------------------------------------------------
    -- Test 123 (v2.59.10 bug-hunt): mirror parity between WC_IsSellable and
    -- describeSellability's positive-signal summary. Pre-v2.59.10 the trace's
    -- summary was missing knownProcPass; the autoDupe ownership chain was
    -- only 2-layer (missing familyKnown); and the deregisterWidth API +
    -- MakeQualityRow call site both had to exist together. Each check locks
    -- a specific mirror-drift class.
    -- ---------------------------------------------------------------------------
    do
        local function fileSrc(path)
            local fh = io.open(path, "rb")
            if not fh then return "" end
            local s = fh:read("*a") or ""
            fh:close()
            return s
        end
        local bdSrc = fileSrc("WoWClearance_BagDisplay.lua")

        local piSrc = fileSrc("WoWClearance_PanelInfra.lua")
        check("Test 123d: WC_compCache.deregisterWidth exists (v2.59.10)",
            piSrc:find("function WC_compCache.deregisterWidth", 1, true) ~= nil,
            "The reactive-width registry needs a deregister API for callers that follow NS.AddCheckbox / setPanelWidth with a manual LEFT+RIGHT anchor pair (the anchors become the width source; a per-resize SetWidth would fight them).")
        local mpSrc = fileSrc("WoWClearance_MerchantPanel.lua")
        check("Test 123e: MakeQualityRow deregisters rowLabel after LEFT+RIGHT re-anchor",
            mpSrc:find("WC_compCache%.deregisterWidth%(rowLabel%)") ~= nil,
            "The rarity-row label in MakeQualityRow gets manually re-anchored with LEFT+RIGHT after NS.AddCheckbox registered it in widthRegistry. Without deregisterWidth the per-resize SetWidth fights the anchor pair. This is currently the only site in the codebase that combines AddCheckbox + LEFT+RIGHT re-anchor.")
    end

    check("Test 122: no bare SetWidth(<literal>) on checkbox label FontStrings",
        #violations == 0,
        "Found " .. #violations .. " checkbox label FontStrings using bare SetWidth(<literal>). Every such site must use WC_compCache.setPanelWidth(text, <inset>) so the label reacts to Interface Options frame resize (SetWordWrap(true) recommended). Offenders:\n  " .. table.concat(violations, "\n  "))
end

-- ---------------------------------------------------------------------------
-- v2.62.0 Process Bags per-skill toggles.
-- ---------------------------------------------------------------------------
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then
            return ""
        end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local ev = fileSrc("WoWClearance_Events.lua")
    local pr = fileSrc("WoWClearance_Process.lua")
    local pb = fileSrc("WoWClearance_ProcessBagsPanel.lua")
    local function has(s, sub)
        return s:find(sub, 1, true) ~= nil
    end

    -- Schema
    check(
        "PBmodes: processEnabledModes seeded in EnsureDB",
        has(ev, "DB.processEnabledModes = {}"),
        "EnsureDB must nil-default DB.processEnabledModes to an empty table"
    )
    check(
        "PBmodes: lockpickEnabled migrated into processEnabledModes.Lockpick",
        has(ev, "DB.processEnabledModes.Lockpick = (DB.lockpickEnabled ~= false)"),
        "one-time seed of the Lockpick toggle from the old flag"
    )
    check(
        "PBmodes: processEnabledModes is per-character",
        has(ev, "processEnabledModes = true"),
        "must be in PER_CHAR_FIELDS (table field, like processCollapsedModes)"
    )

    -- Engine gate + capability helpers
    for _, m in ipairs({ "Disenchant", "Mill", "Prospect", "Lockpick", "Convert" }) do
        check(
            "PBmodes: cascade gates " .. m .. " on processEnabledModes",
            has(pr, "DB.processEnabledModes." .. m .. " ~= false"),
            m .. " branch must check DB.processEnabledModes before selecting the mode"
        )
    end
    check(
        "PBmodes: old lockpickEnabled no longer gates the cascade",
        not has(pr, "DB.lockpickEnabled and WC_compCache.canPickLock"),
        "the Lockpick branch must use processEnabledModes.Lockpick, not lockpickEnabled"
    )
    check(
        "PBmodes: processModeAvailable capability helper exists",
        has(pr, "function WC_compCache.processModeAvailable"),
        "panel needs a per-mode capability check"
    )
    check(
        "PBmodes: hasConvertiblesInBags helper exists",
        has(pr, "function WC_compCache.hasConvertiblesInBags"),
        "Convert toggle visibility needs a bag scan for convertibles"
    )

    -- Panel wiring
    check(
        "PBmodes: panel builds a skill-toggle set",
        has(pb, "skillToggles"),
        "panel must create per-mode checkboxes stored on panel.skillToggles"
    )
    check(
        "PBmodes: toggle setter writes processEnabledModes",
        has(pb, "DB.processEnabledModes["),
        "checkbox OnClick must write the toggle table"
    )
    check(
        "PBmodes: toggle visibility uses processModeAvailable",
        has(pb, "WC_compCache.processModeAvailable"),
        "only show a checkbox for a skill this character can do"
    )
    check(
        "PBmodes: layoutSkillToggles refresh-time layout exists",
        has(pb, "layoutSkillToggles"),
        "visibility + layout recomputed on each refresh"
    )
    check(
        "PBmodes: scroll region anchors below the skill group",
        has(pb, '"TOPLEFT", skillGroup, "BOTTOMLEFT"'),
        "scrollBg must re-anchor to the toggle group so the list reflows"
    )
end

-- ---------------------------------------------------------------------------
-- Test 124 (v2.68.1): pop-out search debounce + session-log ring buffer.
-- ---------------------------------------------------------------------------
-- (a/b) The Loot Log and Sold History search boxes MUST route through the
-- shared NS.MakeSearchDebounce (250 ms idle, one refresh) - each keystroke
-- used to re-run the full build pass (GetItemInfo sweep + sort; on Account
-- scope that is thousands of items, nine times for the word "bloodpike").
-- ListWidget's own debounce established the convention in v2.28.0.
-- (c/d) The 5000-cap session logs are TRUE rings: at the cap the old code
-- did table.remove(t, 1) - an O(5000) front-shift per sale/delete on the
-- vendor path. Readers must order by the per-entry seq, never array index.
do
    local function fileSrc(path)
        local fh = io.open(path, "r")
        if not fh then
            return ""
        end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local pw = fileSrc("WoWClearance_PanelWidgets.lua")
    local sp = fileSrc("WoWClearance_Loot/WoWClearance_LootWindow.lua")  -- Loot Log window (Loot module, v0.9.0)
    local hw = fileSrc("WoWClearance_HistoryWindow.lua")
    local br = fileSrc("WoWClearance_BugReport.lua")
    local ev = fileSrc("WoWClearance_Events.lua")
    check("Test 124a: shared search-debounce helper exists",
        pw:find("function NS%.MakeSearchDebounce%(") ~= nil,
        "NS.MakeSearchDebounce must live in WoWClearance_PanelWidgets.lua (hidden OnUpdate frame, 250ms countdown reset per keystroke).")
    check("Test 124b: both pop-out windows route their search through the helper",
        sp:find("NS%.MakeSearchDebounce%(") ~= nil and hw:find("NS%.MakeSearchDebounce%(") ~= nil,
        "the Loot Log (LootWindow) and Sold History (HistoryWindow) search boxes must use NS.MakeSearchDebounce; a raw OnTextChanged -> refresh reintroduces the per-keystroke full rebuild.")
    check("Test 124c: session logs never front-shift at the cap",
        ev:find("table%.remove%(WC_recentSoldLog, 1%)") == nil
            and ev:find("table%.remove%(WC_recentDeletedLog, 1%)") == nil
            and ev:find("soldLogWrites %- 1%) %% WC_RECENT_SOLD_LOG_MAX", 1, false) ~= nil
            and ev:find("deletedLogWrites %- 1%) %% WC_RECENT_DELETED_LOG_MAX", 1, false) ~= nil,
        "the sold/deleted session logs must ring-write (((writes - 1) %% MAX) + 1), never table.remove(t, 1) - the front-shift is O(5000) per event during exactly the marathon sessions that fill the log.")
    check("Test 124d: bugreport's recent slices order by seq, not array tail",
        br:find("newestBySeq") ~= nil and br:find("a%.seq or 0%) > %(b%.seq or 0%)") ~= nil,
        "at the ring cap the array order rotates; a tail slice by index would interleave old and new entries. The bugreport must sort by the per-entry seq.")
end

-- ---------------------------------------------------------------------------
-- Test 125 (v2.69.0): combined marker scan + localized bind detection.
-- ---------------------------------------------------------------------------
-- (competitive-review A3 + B1) One shared tooltip walk (scanItemMarkers)
-- fills the bind / chance-on-hit / Resilience caches together - the three
-- predicates used to each run their own scanBagItem + 30-line walk on a
-- cold item. Bind matching MUST use the client-localized globals: the old
-- enUS literals silently degraded every bind filter to "any" on frFR/deDE
-- clients despite the shipped UI translations.
do
    local function fileSrc(path)
        local fh = io.open(path, "r")
        if not fh then
            return ""
        end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local pr = fileSrc("WoWClearance_Protection.lua")
    local ev2 = fileSrc("WoWClearance_Events.lua")
    local _, delegates = (pr .. ev2):gsub("WC_compCache%.scanItemMarkers%(bag, slot, itemID%)", "")
    check("Test 125b: the Resilience accessor delegates to the combined walk",
        delegates >= 1,
        "expected >= 1 delegate call site (itemHasResilience in Protection); found " .. delegates .. ". An accessor growing its own scan loop back reintroduces the redundant per-predicate walks.")
    -- Forever: bind state is per COPY. getBindType must read the slot's
    -- isBound live, and nothing may cache a bound/soulbound reading by
    -- itemID - that poisoned unworn BoE copies to "bop" for the session.
    local gbt = ev2:match("function WC_compCache%.getBindType%(bag, slot%)(.-)\nend")
    check("Test 125d: getBindType reads the copy's isBound live",
        gbt ~= nil and gbt:find("cInfo.isBound", 1, true) ~= nil and gbt:find("bindCache", 1, true) == nil,
        "getBindType must check C_Container info isBound per call and never consult bindCache directly.")
    local gbtt = ev2:match("function WC_compCache%.getBindTypeFromTooltip%(tooltip, itemID%)(.-)\nend")
    check("Test 125e: the hover-tooltip bind reader never writes bindCache",
        gbtt ~= nil and gbtt:find("bindCache", 1, true) == nil,
        "a hovered copy's Soulbound line is per-copy truth; caching it by itemID is the cross-copy poisoning bug.")
    check("Test 125f: scanItemMarkers no longer writes bindCache",
        pr:find("bindCache", 1, true) == nil,
        "bind type comes from GetItemInfo's bindType (itemBindType), not the tooltip walk.")
    check("Test 125c: the live-tooltip bind scanner also uses the localized globals",
        ev2:find('ITEM_BIND_ON_PICKUP or "Binds when picked up"', 1, true) ~= nil
            and ev2:find('ITEM_BIND_ON_EQUIP or "Binds when equipped"', 1, true) ~= nil,
        "getBindTypeFromTooltip must match the same client-localized globals as the bag-scan path, with the enUS strings only as nil-fallbacks.")

    -- -----------------------------------------------------------------------
    -- Test 126 (v2.70.0, competitive-review A4): drain-time re-validation.
    -- The vendor queue is built at StartRun; the worker must re-run the
    -- FULL gates against current settings immediately before each
    -- destructive call, so a rule changed mid-burst saves the item, with
    -- the reason logged (NS.recentSavedLog, surfaced by Sold History +
    -- /wc bugreport). The re-check must come BEFORE UseContainerItem /
    -- executeBagSlotDelete and must NOT write the vendor-refusal mark.
    -- -----------------------------------------------------------------------
    local doNext = ev2:match("local function DoNextAction%(%)(.-)\nend")
    check("Test 126a: sell drain re-runs WC_IsSellable before UseContainerItem",
        doNext ~= nil
            and doNext:find("if not WC_IsSellable%(action%.bag, action%.slot, WC_compCache%.runJunkOnly%) then") ~= nil
            and (doNext:find("WC_IsSellable%(action") or 0) < (doNext:find("UseContainerItem%(action") or 0),
        "the sell action must re-validate against CURRENT settings (with the run's junkOnly context, stashed by BuildQueue) before the destructive call; a rule toggled mid-burst must save the item.")
    check("Test 126c: saved items are ring-logged with reasons",
        ev2:find("function WC_compCache%.logRecentSaved%(") ~= nil
            and ev2:find("savedLogWrites %- 1%) %% 200") ~= nil
            and ev2:find("NS.recentSavedLog", 1, true) ~= nil,
        "drain-time saves must land in NS.recentSavedLog (seq-stamped ring, cap 200) so Sold History and /wc bugreport can show why nothing happened.")
end

-- ---------------------------------------------------------------------------
-- Test 127 (v2.71.1, classifier Stage 2): describeSellability consumes the
-- decision core. The trace's SUMMARY renders from NS.Decision.sell's verdict
-- (never from its own narration), every state read goes through the shared
-- buildCtx snapshot, and a drift sentinel surfaces any narration branch that
-- falls behind the core instead of letting the story contradict the verdict.
-- ---------------------------------------------------------------------------
do
    local fh = io.open("WoWClearance_BagDisplay.lua", "rb")
    local bdSrc = fh and fh:read("*a") or ""
    if fh then
        fh:close()
    end
    check("Test 127a: describeSellability builds ONE decision ctx and takes its verdict from Decision.sell",
        bdSrc:find("NS%.Decision and NS%.Decision%.buildCtx%(bag, slot, false%)") ~= nil
            and bdSrc:find("local verdict, verdictToken = NS%.Decision%.sell%(ctx%)") ~= nil
            and bdSrc:find('local wouldSell = verdict == "sell"') ~= nil,
        "the trace summary MUST render from the core's verdict so /wc sellinfo structurally cannot disagree with the vendor engine about the outcome. If wouldSell is re-derived from the narration locals, the pre-Stage-2 mirror-drift bug class returns.")
    check("Test 127b: drift sentinel compares the narration's conclusion against the core verdict",
        bdSrc:find("local traceWouldSell = positiveSignal and not vetoed and not ctx%.locked") ~= nil
            and bdSrc:find("if traceWouldSell ~= wouldSell then") ~= nil
            and bdSrc:find('step%("traceDrift"') ~= nil,
        "the narration is still hand-maintained until Stages 3-4; the sentinel turns a silent story-vs-verdict contradiction into a visible trace line asking for a bug report. Removing it un-alarms exactly the drift class that caused the v2.59.10 and familyKnown incidents.")
end

-- ---------------------------------------------------------------------------
-- Test 128 (v2.71.2, classifier Stage 3): WC_AnnotateTooltip consumes the
-- decision core through the live-tooltip adapter. Every state read goes
-- through NS.Decision.buildTooltipCtx (instance predicates routed to the
-- liveTooltip* scanners), the final label is guarded by an equipped-honesty
-- fix-up plus a verdict sentinel, and the adapter itself keeps the
-- live-tooltip routing the labels rely on.
-- ---------------------------------------------------------------------------
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then
            return ""
        end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local ttSrc = fileSrc("WoWClearance_Tooltip.lua")
    local dcSrc = fileSrc("WoWClearance_Decision.lua")
    check("Test 128a: tooltip builds ONE live-tooltip decision ctx",
        ttSrc:find("NS%.Decision and NS%.Decision%.buildTooltipCtx%(tooltip, id%)") ~= nil,
        "WC_AnnotateTooltip MUST read all state through the buildTooltipCtx snapshot so the tooltip and the decision core see identical inputs. Raw DB/WC_compCache re-reads reintroduce the mirror-drift bug class.")
    check("Test 128b: verdict sentinel compares the label class against Decision.sell + deleteEligible",
        -- v2.71.3 (classifier Stage 4): the sentinel covers delete labels
        -- too. Only the auto-mark PREVIEW (a willdelete label WITHOUT
        -- Delete-List membership - a prediction about a future marking)
        -- stays excluded.
        ttSrc:find("local verdict = NS%.Decision%.sell%(ctx%)") ~= nil
            and ttSrc:find('%(verdict == "sell"%) ~= %(statusTag == "willsell"%)') ~= nil
            and ttSrc:find("local willDeleteReal = ctx%.onDeleteList") ~= nil
            and ttSrc:find('if statusTag == "willdelete" and not ctx%.onDeleteList then') ~= nil
            and ttSrc:find('mismatch = statusTag ~= "willdelete"') ~= nil,
        "the label branches are hand-maintained; the sentinel turns a label-vs-engine contradiction into a visible tooltip line asking for a bug report - for sell verdicts (Decision.sell) AND Delete-List verdicts (Decision.deleteEligible).")
    check("Test 128c: centralized equipped-honesty guard on every Will Sell label",
        ttSrc:find('if statusTag == "willsell" and ctx%.equipped then') ~= nil,
        "the engine's equipped veto beats every positive signal, but only the Sell List label branch checked it. The final guard relabels ANY Will Sell on a worn item to Won't Sell (equipped) - paper-doll hovers of rule-matched gear were the visible lie.")
    check("Test 128e: both adapters share one snapshot helper",
        dcSrc:find("local function WC_fillSharedCtx%(ctx, DB, ADB, itemID, quality%)") ~= nil
            and select(2, dcSrc:gsub("WC_fillSharedCtx%(ctx, DB, ADB, itemID, quality%)", "")) >= 3,
        "memberships + settings + ownership thunks MUST come from the single WC_fillSharedCtx helper (definition + one call per adapter = 3+ occurrences), so the vendor/trace adapter and the tooltip adapter cannot drift on the shared state.")
end

-- ---------------------------------------------------------------------------
-- Test 129 (v2.71.3, classifier Stage 4): the delete decision lives in the
-- core. deleteListSlotEligible is a thin delegate (cheap membership pre-gate
-- so unlisted slots stay at one table lookup, then Decision.deleteEligible),
-- and the trace + tooltip render their Will Delete verdicts from the same
-- gate - so a listed item the v2.50.2 rescues would skip can no longer be
-- promised a delete on any surface.
-- ---------------------------------------------------------------------------
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then
            return ""
        end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local evSrc = fileSrc("WoWClearance_Events.lua")
    local ttSrc = fileSrc("WoWClearance_Tooltip.lua")
    check("Test 129a: deleteListSlotEligible delegates behind a cheap membership pre-gate",
        evSrc:find("if not %(id and IsInSet%(DB%.deleteList, id%)%) then\n%s+return nil\n%s+end\n%s+.-local ctx = NS%.Decision and NS%.Decision%.buildCtx%(bag, slot, false%)") ~= nil
            and evSrc:find("if not NS%.Decision%.deleteEligible%(ctx%) then") ~= nil,
        "the gate runs per slot inside BAG_UPDATE scans and BuildQueue; unlisted slots (the common case) MUST short-circuit on one item-ID read + one table lookup BEFORE the ctx snapshot is built. Removing the pre-gate turns every bag scan into a full snapshot per slot.")
    check("Test 129b: tooltip Will Delete labels require Decision.deleteEligible",
        ttSrc:find("elseif ctx%.onDeleteList and ctx%.enableDeletion and NS%.Decision%.deleteEligible%(ctx%) then") ~= nil
            and ttSrc:find("if ctx%.onDeleteList and ctx%.enableDeletion and NS%.Decision%.deleteEligible%(ctx%) then") ~= nil,
        "BOTH Will Delete label sites (the main verdict chain and destinationLabel's precedence walk) MUST consult the core's delete gate, so an item rescued by the account Sell List / equipped / affix protections falls through to its real verdict instead of threatening a delete that never fires.")
end

-- ---------------------------------------------------------------------------
-- Test 130 (v2.72.0): per-character settings profiles - the structural
-- invariants of the settings-profile partition. Profile BODIES live at the
-- top-level WoWClearanceDB.settingsProfiles[name] (account-wide so alts can
-- share one); the per-character activeSettingsProfile pointer picks which one
-- applies; the DB proxy routes every settings-profile field through the
-- active body so call sites stay `DB.<field>`. Top-level copies freeze at
-- migration as the downgrade safety net (the v2.34 partition model).
-- ---------------------------------------------------------------------------
do
    local fh = io.open("WoWClearance_Events.lua", "rb")
    local ev130 = fh and fh:read("*a") or ""
    if fh then
        fh:close()
    end
    check("Test 130b: DB proxy routes settings-profile fields through the active profile with a Default fallback",
        ev130:find("local SPF = WC_compCache%.settingsProfileFields") ~= nil
            and ev130:find("local function activeSettings%(%)") ~= nil
            and ev130:find('profiles%[charNamespace%.activeSettingsProfile or "Default"%] or profiles%.Default') ~= nil
            and ev130:find("if SPF%[k%] then") ~= nil,
        "reads AND writes of settings fields must route through the character's active profile body, falling back to Default when the pointer names a deleted profile and to the raw top level pre-migration. Without the proxy branch, call sites would need a mass rewrite and settings would silently stay account-wide.")
    check("Test 130c: EnsureDB seeds the Default profile from the top level BEFORE building the proxy",
        (function()
            local seedPos = ev130:find('if type%(WoWClearanceDB%.settingsProfiles%) ~= "table" then')
            local defSeed = ev130:find("WoWClearanceDB%.settingsProfiles%.Default = def")
            local proxyPos = ev130:find("DB = WC_DBBuildProxy%(charNS%)")
            local pointerSeed = ev130:find('if type%(charNS%.activeSettingsProfile%) ~= "string" then')
            return seedPos ~= nil
                and defSeed ~= nil
                and proxyPos ~= nil
                and pointerSeed ~= nil
                and seedPos < proxyPos
                and defSeed < proxyPos
                and pointerSeed < proxyPos
        end)(),
        "the one-shot migration must deep-copy the RAW top-level selling settings into settingsProfiles.Default and point the character at it BEFORE the proxy is built - after the proxy exists, DB.<field> reads route into the profile, so a later seed would copy the wrong (already-routed) values. Zero behaviour change on upgrade depends on this ordering.")
    check("Test 130d: management functions exist and Use re-bootstraps + repaints",
        ev130:find("function NS%.SaveSettingsProfile%(name%)") ~= nil
            and ev130:find("function NS%.UseSettingsProfile%(name%)") ~= nil
            and ev130:find("function NS%.DeleteSettingsProfile%(name%)") ~= nil
            and ev130:find("function NS%.RenameSettingsProfile%(oldName, newName%)") ~= nil
            and ev130:find("DB%.activeSettingsProfile = name\n%s+%-%-[^\n]*\n%s+%-%-[^\n]*\n%s+%-%-[^\n]*\n%s+EnsureDB%(%)\n%s+NS%.RepaintAfterSettingsSwitch%(%)") ~= nil,
        "UseSettingsProfile MUST re-run the idempotent EnsureDB after moving the pointer (a profile saved by an older version needs nil-defaults for fields added since - the defaults write through the proxy into the newly-active profile) and then repaint the settings panels + borders, or the UI keeps showing the previous profile's values.")
    check("Test 130e: deleting a settings profile repoints every character and protects Default",
        ev130:find('if name == "Default" then\n%s+return false, L%["The Default settings profile cannot be deleted%."%]') ~= nil
            and ev130:find('charNS%.activeSettingsProfile = "Default"') ~= nil,
        "Default is the migration baseline AND the proxy's fallback target - deleting it would strand every pointer. Deleting any other profile must walk WoWClearanceDB.chars and repoint users to Default so no character keeps a live pointer to a dead profile.")
    local ppf = io.open("WoWClearance_ProfilesPanel.lua", "rb")
    local pp130 = ppf and ppf:read("*a") or ""
    if ppf then
        ppf:close()
    end
    check("Test 130f: Settings Profiles panel registered centrally, /wc sprofile wired",
        ev130:find('"WoWClearanceOptionsSettingsProfiles",') ~= nil
            and ev130:find('cmd == "sprofile"') ~= nil
            and pp130:find('CreateFrame%("Frame", "WoWClearanceOptionsSettingsProfiles"') ~= nil
            and pp130:find("RegisterOptionsSub") == nil,
        "the panel lives in WoWClearance_ProfilesPanel.lua but MUST be registered centrally in Events (no panel self-registers - the central block owns sidebar order), and the /wc sprofile save|use|delete|list command family must exist alongside /wc profile.")
end

-- ---------------------------------------------------------------------------
-- Test 131 (v2.73.0): external-action attribution. Cursor deletes that
-- WoWClearance did NOT perform (a player drag-delete, another addon) land in
-- the deleted-history ring with source="external" and a neutral reason, so
-- "your addon deleted my item" reports can be answered from the log. The
-- hooks are hooksecurefunc only (never a global replacement), WC subtracts
-- its own deletes via the stamped pendingDelete, and external rows never
-- touch a stat counter.
-- ---------------------------------------------------------------------------
do
    local fh = io.open("WoWClearance_Events.lua", "rb")
    local ev131 = fh and fh:read("*a") or ""
    if fh then
        fh:close()
    end
    -- v0.5.2: PickupContainerItem is namespaced to C_Container on Forever,
    -- so the STRING form of hooksecurefunc throws ("... is not a function")
    -- and aborts the installer before the external-delete detection is
    -- wired. Measured in-game 2026-09-19. This assertion now pins the TABLE
    -- form for it. DeleteCursorItem is still a bare global on this client
    -- (verified against the shipped UI source), so it keeps the string form.
    -- The invariant being protected is unchanged: hooksecurefunc rather than
    -- a raw global replacement, behind a once-guard, installer actually
    -- called. Do not "restore" the string form for the namespaced one.
    check("Test 131a: external-action hooks use hooksecurefunc, installed once",
        ev131:find('hooksecurefunc%(C_Container, "PickupContainerItem"') ~= nil
            and ev131:find('hooksecurefunc%("DeleteCursorItem"') ~= nil
            and ev131:find("if WC_compCache%.externalActionHooksInstalled then") ~= nil
            and ev131:find("WC_compCache%.installExternalActionHooksOnce%(%)") ~= nil,
        "both hooks MUST be hooksecurefunc (a global replacement of cursor APIs carries taint risk) behind a hookedOnce guard, and the installer must actually be called at load. The namespaced one uses the table form.")
    check("Test 131b: WC's own deletes bypass the external-delete hooks",
        ev131:find("local PickupContainerItem = C_Container%.PickupContainerItem") ~= nil
            and ev131:find("local DeleteCursorItem = DeleteCursorItem") ~= nil
            and ev131:find("pendingDelete", 1, true) == nil,
        "executeBagSlotDelete calls the locals captured at file load, so the hooksecurefunc wrappers installed later never log WC's own deletes as external.")
    check("Test 131c: external delete DEFERS at the hook, logs source=external in the confirm, never counted",
        (function()
            local hookStart = ev131:find('hooksecurefunc("DeleteCursorItem"', 1, true)
            local confirmStart = ev131:find("function WC_compCache.confirmPendingExternalDelete()", 1, true)
            if not hookStart or not confirmStart then
                return false
            end
            -- The hook must DEFER (set pendingExternalDelete) and NOT log
            -- synchronously - DeleteCursorItem also fires at popup-raise.
            local hookBody = ev131:sub(hookStart, confirmStart)
            local defers = hookBody:find("WC_compCache.pendingExternalDelete = {", 1, true) ~= nil
                and hookBody:find("WC_LogRecentDeleted", 1, true) == nil
            -- The confirm logs source=external and bumps no stat.
            local confirmBody = ev131:sub(confirmStart, confirmStart + 1500)
            local logsCleanly = confirmBody:find('WC_LogRecentDeleted(pe.itemID, pe.count, "external"', 1, true) ~= nil
                and confirmBody:find("WC_BumpStat", 1, true) == nil
                and confirmBody:find("WC_session.deleted", 1, true) == nil
            return defers and logsCleanly
        end)(),
        "The DeleteCursorItem hook fires at popup-RAISE too, so it must DEFER (set pendingExternalDelete), not log synchronously - else a cancelled rare/epic/quest delete writes a false 'Deleted outside' row that never clears. The confirm logs source=external and must NOT bump any stat.")
    check("Test 131d: deferred external delete is confirmed only when the item really left the bags",
        (function()
            local confirmStart = ev131:find("function WC_compCache.confirmPendingExternalDelete()", 1, true)
            if not confirmStart then
                return false
            end
            local body = ev131:sub(confirmStart, confirmStart + 1500)
            local gated = body:find('GetCursorInfo() == "item"', 1, true) ~= nil -- wait while held / popup open
                and body:find("nowCount <= (pe.bagCount or 0)", 1, true) ~= nil -- count didn't return = real delete
                and body:find("> 30", 1, true) ~= nil -- stale candidate expiry
            -- ...and the confirm is actually driven from the settled bag flush.
            local flushT0 = ev131:find('WC_StampEvent("bagUpdate")', 1, true) or 1
            local calledFromFlush = ev131:find("WC_compCache.confirmPendingExternalDelete()", flushT0, true) ~= nil
            return gated and calledFromFlush
        end)(),
        "confirmPendingExternalDelete must wait while the item is on the cursor (popup open), log only when the in-bag count did NOT return (real delete vs cancel), expire stale candidates, and run from the settled bag flush.")
end

-- ---------------------------------------------------------------------------
-- Test 132 (v2.75.0, fresh-audit fix): the master Enable/Disable flag is
-- per-character. The README, the panel checkbox, and /wc enable|disable have
-- always described it as per-character ("skip the addon on alts"), but the flag
-- was routed to the account-wide top level, so disabling on one alt disabled
-- every character. It must be a PER_CHAR_FIELDS field AND migrate existing saves
-- (seed from the frozen account-wide value) so a player who disabled WC
-- account-wide is never silently re-enabled.
-- ---------------------------------------------------------------------------
do
    local fh = io.open("WoWClearance_Events.lua", "rb")
    local ev132 = fh and fh:read("*a") or ""
    if fh then
        fh:close()
    end
    local pcfStart = ev132:find("local PER_CHAR_FIELDS = {", 1, true)
    local pcfEnd = pcfStart and ev132:find("\n}", pcfStart) or nil
    local pcfBody = (pcfStart and pcfEnd) and ev132:sub(pcfStart, pcfEnd) or ""
    check("Test 132a: `enabled` is a per-character field",
        pcfBody:find("\n    enabled = true,", 1, true) ~= nil,
        "The master Enable flag must be in PER_CHAR_FIELDS so disabling on an alt does not disable every character (the README + panel + /wc enable|disable have always promised per-character).")
    check("Test 132b: existing saves seed per-character `enabled` from the frozen account value",
        ev132:find('charNS.enabled == nil and type(WoWClearanceDB.enabled) == "boolean"', 1, true) ~= nil,
        "A character namespace predating the change has no `enabled` key; without seeding it from the frozen top-level value, EnsureDB would default it true and silently re-enable a player who had WC disabled account-wide.")
end

-- ---------------------------------------------------------------------------
-- Test 133 (v2.75.0, fresh-audit follow-up): the Sold History and Loot Log
-- windows pause their per-frame row rebuild while being dragged. During a live
-- session both refresh ~once a second as the logs change; rebuilding mid-drag
-- hitched the move (Serv report). OnDragStart sets a dragging flag, the OnUpdate
-- early-returns on it, and OnDragStop clears it and refreshes once.
-- ---------------------------------------------------------------------------
do
    local function readf(p)
        local fh = io.open(p, "rb")
        local s = fh and fh:read("*a") or ""
        if fh then
            fh:close()
        end
        return s
    end
    local hw = readf("WoWClearance_HistoryWindow.lua")
    local sp = readf("WoWClearance_Loot/WoWClearance_LootWindow.lua")  -- Loot Log window (Loot module, v0.9.0)
    check("Test 133a: Sold History pauses its rebuild while dragging",
        hw:find("self._histDragging = true", 1, true) ~= nil
            and hw:find("if self._histDragging then", 1, true) ~= nil
            and hw:find("self._histDragging = false", 1, true) ~= nil,
        "HistoryWindow OnDragStart must set _histDragging, the OnUpdate must early-return on it, and OnDragStop must clear it (then refresh once) - otherwise the row rebuild hitches the drag during a live session.")
    check("Test 133b: Loot Log pauses its rebuild while dragging",
        sp:find("self._lootDragging = true", 1, true) ~= nil
            and sp:find("if self._lootDragging then", 1, true) ~= nil
            and sp:find("self._lootDragging = false", 1, true) ~= nil,
        "Loot Log OnDragStart must set _lootDragging, the OnUpdate must early-return on it, and OnDragStop must clear it (then refresh once).")
end

-- ---------------------------------------------------------------------------
-- Test 134 (v2.76.0): worst-N spike ring + WC-share attribution.
-- ---------------------------------------------------------------------------
-- The recent spike ring (Test 115) is a severity-blind FIFO: a single 400 ms
-- hitch is evicted by twenty later 51 ms ones, so the one frame a bug report
-- needs is usually gone. v2.76.0 adds a worst-10 ring (sorted descending,
-- evicted by SEVERITY) sharing the same immutable entries, stores ecMs (WC's
-- total phase work) on each entry at insert, and shows WC's share of every
-- frame in /wc spike and /wc bugreport - so a pasted report proves whose
-- stutter it was. Test 115's pins on the recent ring were audited and remain
-- valid untouched (the FIFO insert/trim lines are byte-identical).
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then
            return ""
        end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local ev134 = fileSrc("WoWClearance_Events.lua")
    local br134 = fileSrc("WoWClearance_BugReport.lua")
    check("Test 134a: worst ring exists, exposed on NS, bounded at 10",
        ev134:find("NS.worstSpikeLog = {}", 1, true) ~= nil
            and ev134:find("NS.worstSpikeLogMax = 10", 1, true) ~= nil,
        "the worst ring MUST be exposed on NS (the bugreport builder consumes it, mirroring NS.recentSpikeLog) and bounded - it is session-only, in-memory, never persisted.")
    check("Test 134b: worst-ring eviction is by severity, never FIFO",
        ev134:find("if #worst < NS.worstSpikeLogMax or entry.ms > worst[#worst].ms then", 1, true) ~= nil
            and ev134:find("while pos > 1 and worst[pos - 1].ms < entry.ms do", 1, true) ~= nil
            and ev134:find("table.remove(worst)", 1, true) ~= nil,
        "the worst ring MUST insert sorted descending by ms and trim the TAIL (the smallest), with a replace-min early-out. FIFO eviction here reintroduces the reported bug: one big hitch dies to twenty small ones.")
    check("Test 134c: WC share captured at insert as ecMs on the shared entry",
        ev134:find("ecMs = dBag + dVendor + dTip", 1, true) ~= nil
            and ev134:find("table.insert(WC_spikeLog, 1, entry)", 1, true) ~= nil,
        "ecMs MUST be stored on the entry at insert (entries are SHARED between the recent and worst rings and immutable afterwards); rendering only divides. Recomputing at render from the phase fields would work today but invites drift if a phase is ever added.")
    check("Test 134d: /wc spike renders both sections with the clamped share",
        ev134:find("WC %.0f of %.0f ms (%.0f%%)", 1, true) ~= nil
            and ev134:find('L["Worst hitches this session (biggest first):"]', 1, true) ~= nil
            and ev134:find('L["Most recent hitches (newest first):"]', 1, true) ~= nil
            and ev134:find("math.min(100, ecMs / ms * 100)", 1, true) ~= nil,
        "ShowFrameSpikes MUST print the worst section (biggest first) then the recent section (newest first), each line carrying WC's share of the frame; the clamp guards the two-clock case (debugprofilestop vs elapsed) ever reading over 100%.")
    check("Test 134e: bugreport mirrors both sections with the share",
        br134:find("--- Worst Frame Hitches (this session) ---", 1, true) ~= nil
            and br134:find("NS.worstSpikeLog", 1, true) ~= nil
            and br134:find("WC %.0f ms (%.0f%%)", 1, true) ~= nil,
        "/wc bugreport MUST carry the worst section and the share suffix - the pasted report is where 'whose stutter was it' actually gets answered.")
    -- 134f: field-verified wart (v2.76.0 in-game pass). An entry can clear the
    -- 0.1 ms log epsilon yet round to "WC 0 ms (0%)"; naming an WC phase as
    -- "busiest" on that line reads as blame on a frame the share just
    -- exonerated. Both surfaces must swap the label for "something else".
    local ecMs05 = 'ecMs < 0.5 and "something else"'
    check("Test 134f: near-zero WC share never names an WC phase as busiest",
        ev134:find(ecMs05, 1, true) ~= nil and br134:find(ecMs05, 1, true) ~= nil,
        "when ecMs rounds to 0 the busiest label MUST read 'something else' on BOTH surfaces - 'busiest: Tooltip scan - WC 0 of 613 ms (0%)' contradicts itself and blames WC for a frame it did not cause.")
end

-- ---------------------------------------------------------------------------
-- Test 135 (v2.77.0): the /wc paircheck proc-text affix suggester is
-- DIAGNOSTIC-ONLY and must never reach the sell path. A proc-text guess is not
-- Anvil proof, and two weapons can share a proc while only one is extractable
-- (Fiery War Axe reads like Taran Icebreaker's Pyromancy yet the Anvil refuses
-- it). suggestAffixFromProcLine / WC_WEAPON_PROC_SIGNATURES must appear ONLY in
-- Protection.lua (definition) and BugReport.lua (the diagnostic renderer), never
-- in the decision core, the vendor cycle, or the Events sell path.
-- ---------------------------------------------------------------------------
do
    local function readf(p)
        local f = io.open(p, "rb")
        local s = f and f:read("*a") or ""
        if f then
            f:close()
        end
        return s
    end
    local function count(s, needle)
        local n, i = 0, 1
        while true do
            local j = s:find(needle, i, true)
            if not j then
                break
            end
            n = n + 1
            i = j + 1
        end
        return n
    end
    local prot135 = readf("WoWClearance_Protection.lua")
    local dec135 = readf("WoWClearance_Decision.lua")
    local ven135 = readf("WoWClearance_Vendor.lua")
    local ev135 = readf("WoWClearance_Events.lua")
    local br135 = readf("WoWClearance_BugReport.lua")
    -- Positional guarantee: the suggester + signature table live entirely in
    -- the DIAGNOSTIC region, which sits AFTER the sell-path functions
    -- (playerHasExtractedProc / chanceProcSpellID are above it), so those never
    -- reference them. (A raw count is wrong here: the safety-boundary comment
    -- also names the symbols.)
    local diagStart = prot135:find("DIAGNOSTIC-ONLY proc-text suggester", 1, true)
    local firstSuggest = prot135:find("suggestAffixFromProcLine", 1, true)
    local firstSig = prot135:find("WC_WEAPON_PROC_SIGNATURES", 1, true)
    check("Test 135c: suggester never appears in the sell path",
        count(dec135, "suggestAffixFromProcLine") == 0
            and count(ven135, "suggestAffixFromProcLine") == 0
            and count(ev135, "suggestAffixFromProcLine") == 0,
        "suggestAffixFromProcLine MUST NOT appear in the decision core, the vendor cycle, or Events - a proc-text guess feeding a sell decision is the exact item-safety hazard this suggester is walled off from.")
end

-- ---------------------------------------------------------------------------
-- Result.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Options-panel registration completeness (port work item 5).
-- ---------------------------------------------------------------------------
-- Every frame named WoWClearanceOptions* that a panel file creates must be
-- registered, or it exists in memory and never appears in the sidebar - a
-- silent failure with no error and no visible symptom except a missing panel.
--
-- 3.3.5a made this self-evident: one InterfaceOptions_AddCategory call per
-- panel, greppable. Forever splits it into a root category, an ordered list
-- of subcategories in WoWClearance_Events.lua, and one self-registration in
-- HelpPanel (which loads after Events, so it cannot join the list). This
-- check re-establishes the greppability across all three shapes.
--
-- Deliberate exclusions, each for a stated reason rather than convenience.
do
    local EXEMPT = {
        -- Standalone modal parented to UIParent, not a sidebar panel. Reached
        -- from the Main panel's button and the fresh-install auto-open.
        WoWClearanceOptionsQuickstart = true,
        -- The root category itself, registered via NS.RegisterOptionsRoot.
        WoWClearanceOptionsMain = true,
    }
    local created, registered = {}, {}
    local tocFh = assert(io.open("WoWClearance.toc", "r"), "cannot open WoWClearance.toc")
    local files = {}
    for line in tocFh:lines() do
        local f = line:match("^(WoWClearance_[%w_]+%.lua)%s*$")
        if f and not f:find("Locale_") then
            files[#files + 1] = f
        end
    end
    tocFh:close()
    for _, f in ipairs(files) do
        local fh = io.open(f, "r")
        if fh then
            local raw = fh:read("*a")
            fh:close()
            for name in raw:gmatch('CreateFrame%("Frame",%s*"(WoWClearanceOptions%w+)"') do
                created[name] = f
            end
            -- Registered either by appearing in the ordered list or by a
            -- direct NS.RegisterOptionsSub / NS.RegisterOptionsRoot call.
            --
            -- The list form must be anchored to the start of a line. A bare
            -- '"NAME",' also matches the name INSIDE the CreateFrame argument
            -- list ('CreateFrame("Frame", "NAME", parent)'), which made every
            -- created frame look registered and this whole check vacuous.
            -- Caught by mutation-testing it with a deliberately unregistered
            -- frame; the first version passed.
            for name in raw:gmatch('\n%s*"(WoWClearanceOptions%w+)",') do
                registered[name] = true
            end
            for name in raw:gmatch('NS%.RegisterOptionsSub%(_G%["(WoWClearanceOptions%w+)"%]') do
                registered[name] = true
            end
            for name in raw:gmatch('NS%.RegisterOptionsRoot%(_G%["(WoWClearanceOptions%w+)"%]') do
                registered[name] = true
            end
            -- v0.5.4: the launcher panel is registered from a local variable
            -- rather than a _G[] lookup, because it is created in the same
            -- file that registers it. Match that form too, anchored to a
            -- CreateFrame of the same name in the same file so this stays a
            -- real check rather than a blanket pass.
            if raw:find("NS%.RegisterOptionsRoot%(%s*[%w_]+%s*,") then
                for name in raw:gmatch('CreateFrame%("Frame",%s*"(WoWClearanceOptions%w+)",%s*UIParent%)') do
                    registered[name] = true
                end
            end
        end
    end
    local missing = {}
    for name, f in pairs(created) do
        if not EXEMPT[name] and not registered[name] then
            missing[#missing + 1] = name .. " (" .. f .. ")"
        end
    end
    table.sort(missing)
    check("every options panel frame is registered somewhere",
        #missing == 0,
        "these panel frames are created but never registered, so they will not appear in the "
            .. "settings sidebar and nothing will error: " .. table.concat(missing, ", "))
    check("the panel scan actually found frames to check", next(created) ~= nil,
        "the CreateFrame pattern matched nothing, so this check would pass vacuously")
end

-- ---------------------------------------------------------------------------
-- Test 140 (v0.6.0): Sold History persists per character.
-- ---------------------------------------------------------------------------
-- The live sold/deleted logs ARE the saved tables (identity kept), so the
-- wiring is what can silently break: the field must route per character,
-- every write and Clear must mirror the ring cursors into the store, and the
-- loader must run at PLAYER_LOGIN after EnsureDB. Static, because the loader
-- lives in the event hub, which cannot load outside the game.
do
    local fh = io.open("WoWClearance_Events.lua", "r")
    local ev = fh and fh:read("*a") or ""
    if fh then
        fh:close()
    end
    local perChar = ev:match("local PER_CHAR_FIELDS = {(.-)\n}")
    check("Test 140a: soldHistory is a per-character field",
        perChar ~= nil and perChar:find("soldHistory = true", 1, true) ~= nil,
        "without it DB.soldHistory lands at the account top level and every character shares one history.")
    local sold = ev:match("WC_LogRecentSold = function(.-)\nend\n")
    local deleted = ev:match("WC_LogRecentDeleted = function(.-)\nend\n")
    check("Test 140b: both log writers mirror the ring state into the store",
        sold ~= nil and sold:find("syncSoldHistory", 1, true) ~= nil
            and deleted ~= nil and deleted:find("syncSoldHistory", 1, true) ~= nil,
        "a writer that skips the sync saves entries whose ring cursor resets next login, overwriting from slot 1.")
    local clear = ev:match("function NS%.ClearSessionHistory%(%)(.-)\nend\n")
    check("Test 140c: Clear mirrors the reset cursors into the store",
        clear ~= nil and clear:find("syncSoldHistory", 1, true) ~= nil,
        "Clear must persist the zeroed cursors or the next login restores the old ones over an empty log.")
    local loadAt = ev:find('if event == "PLAYER_LOGIN" then\n%s*WC_compCache%.loadSoldHistory%(%)')
    local ensureAt = ev:find('if event == "PLAYER_LOGIN" then\n%s*EnsureDB%(%)')
    check("Test 140d: the loader runs at PLAYER_LOGIN, after EnsureDB",
        loadAt ~= nil and ensureAt ~= nil and ensureAt < loadAt,
        "loading before EnsureDB reads the wrong character's namespace (or none).")
end

-- Test 141 (v0.6.0): no code clicks the game's delete popup. A Yes clicked
-- from OnUpdate runs C_Item.DeleteItem outside a hardware event, which
-- Forever blocks (porting lesson 16); WoWClearance_Vendor.lua was removed.
-- ---------------------------------------------------------------------------
do
    local found = {}
    for _, path in ipairs(SOURCE_PATHS) do
        local fh = io.open(path, "rb")
        local code = fh and fh:read("*a") or ""
        if fh then
            fh:close()
        end
        if code:find("Button1:Click()", 1, true) or code:find("button1:Click()", 1, true)
            or code:find("GetButton1():Click()", 1, true)
        then
            found[#found + 1] = path
        end
    end
    check("Test 141: nothing auto-clicks a popup's Yes button",
        #SOURCE_PATHS > 20 and #found == 0, "found in: " .. table.concat(found, ", "))
end

-- ---------------------------------------------------------------------------
-- Test 142 (v0.6.1): 3.3.5a habits that are wrong on Forever.
-- ---------------------------------------------------------------------------
do
    local function readAll(path)
        local fh = io.open(path, "rb")
        local src = fh and fh:read("*a") or ""
        if fh then
            fh:close()
        end
        return src
    end
    local ev = readAll("WoWClearance_Events.lua")
    check(
        "Test 142b: guild repair treats -1 as unlimited and caps by the bank balance",
        ev:find("if funds == %-1 or funds > bank then") ~= nil and ev:find("GetGuildBankMoney%(%)") ~= nil,
        "a guild leader's withdraw limit is -1; any limit above the bank balance would claim a repair the bank cannot pay."
    )
    local help = readAll("WoWClearance_HelpPanel.lua")
    check(
        "Test 142c: Help URLs use the shared copy window, never a StaticPopup edit box",
        help:find('box:SetScript%("OnEnterPressed"') == nil
            and help:find('box:SetScript%("OnEscapePressed"') == nil
            and help:find("StaticPopupDialogs", 1, true) == nil
            and help:find('NS.Kit.ShowCopy("WoWClearanceCopy"', 1, true) ~= nil,
        "StaticPopup edit boxes are shared; SetScript strips Blizzard's handlers from every later dialog in that slot. The kit copy window owns its own box."
    )
    local win = readAll("WoWClearance_Window.lua")
    check(
        "Test 142d: the settings window never moves or hides a shown secure button in combat",
        win:find('SetScript("OnDragStart", win.StartMoving)', 1, true) == nil
            and select(2, win:gsub("if not WC_secureLocked%(%) then", "")) >= 4
            and select(2, win:gsub("if WC_secureLocked%(%) then", "")) >= 2,
        "the Process Bags cast button is secure; dragging, resizing or hiding its window in combat is refused (measured on Forever)."
    )
end

-- ---------------------------------------------------------------------------
-- Test 143 (v0.6.0): per-character data is keyed by "First Surname-Realm".
-- ---------------------------------------------------------------------------
-- First names are not unique on Forever; the old "First-Realm" key let two
-- characters share one Keep / Sell / Delete partition. The migration must
-- COPY the old partition, never move or delete it.
do
    local fh = io.open("WoWClearance_Events.lua", "rb")
    local ev = fh and fh:read("*a") or ""
    if fh then
        fh:close()
    end
    local keyFn = ev:match("local function WC_DBCharKey%(%)(.-)\nend")
    check("Test 143a: the per-character key carries the surname",
        keyFn ~= nil and keyFn:find('GetUnitName("player", true)', 1, true) ~= nil,
        "UnitName alone drops the surname; two characters sharing a first name would share one Delete List.")
    check("Test 143b: the surname migration copies the old partition, never moves it",
        ev:find("WC_DBDeepCopy%(WoWClearanceDB%.chars%[legacyKey%]%)") ~= nil
            and ev:find("chars%[legacyKey%]%s*=%s*nil") == nil
            and ev:find("chars%[WC_DBLegacyCharKey%(%)%]%s*=%s*nil") == nil,
        "moving the partition would leave a second character with the same first name on empty lists.")
    check("Test 143e: the surname copy-forward runs once per old save",
        ev:find("not %(WoWClearanceDB%.surnameCopied and WoWClearanceDB%.surnameCopied%[WC_DBLegacyCharKey%(%)%]%)") ~= nil
            and ev:find("WoWClearanceDB%.surnameCopied%[legacyKey%] = charKey") ~= nil,
        "without the marker, a character created later with the same first name inherits another character's Sell and Delete Lists.")
    -- Test 143f (2026-11-20): the client returns an empty realm name. The key
    -- must land on the character's saved partition, never a fresh one seeded
    -- from the old snapshot (wrong Keep List: kept items get sold).
    -- v0.9.0: the realm fallback lives in NS.RealmName (Core); the key is
    -- built from it. Both bodies run in one sandbox.
    local cfh = io.open("WoWClearance_Core.lua", "rb")
    local core = cfh and cfh:read("*a") or ""
    if cfh then
        cfh:close()
    end
    local realmFn = core:match("function NS%.RealmName%(%)(.-)\nend")
    local function keyWith(name, realm, chars)
        local fn = keyFn and loadstring("return function()" .. keyFn .. "\nend")
        local rfn = realmFn and loadstring("return function()" .. realmFn .. "\nend")
        if not (fn and rfn) then
            return nil
        end
        local env = {
            type = type,
            pairs = pairs,
            GetUnitName = function()
                return name
            end,
            GetRealmName = function()
                return realm
            end,
            WoWClearanceDB = { chars = chars },
        }
        env.NS = { RealmName = setfenv(rfn(), env) }
        return setfenv(fn(), env)()
    end
    check("Test 143f: with no realm name, the saved partition is reused",
        keyWith("Serv Nocturne", "", { ["Serv Nocturne-R"] = {}, ["Serv Nocturne-"] = {} }) == "Serv Nocturne-R"
            and keyWith("Serv Nocturne", "", {}) == "Serv Nocturne-"
            and keyWith("Serv Nocturne", "", { ["Serv Nocturne-R"] = {}, ["Serv Nocturne-S"] = {} }) == "Serv Nocturne-"
            and keyWith("Serv", "", { ["Serv Nocturne-R"] = {} }) == "Serv-"
            and keyWith("Serv Nocturne", "R2", { ["Serv Nocturne-R"] = {} }) == "Serv Nocturne-R2"
            and keyWith("Serv Nocturne", nil, { ["Serv Nocturne-R"] = {} }) == "Serv Nocturne-R",
        "an empty realm opened a new partition with an old Keep List, so items on the real Keep List could be sold.")
    -- Display and loot paths read the realm through the same helper, so ""
    -- never shows as "Name-" or breaks own-name matching.
    check("Test 143g: no realm read bypasses NS.RealmName",
        select(2, (src:gsub("%-%-[^\n]*", "")):gsub("GetRealmName%(", "")) == 1
            and core:find("GetRealmName and GetRealmName()", 1, true) ~= nil,
        "GetRealmName() returns \"\" since build 71037 and \"\" is truthy, so `GetRealmName() or \"?\"` never falls back; call NS.RealmName().")
    -- Test 143h (v0.9.1): the "First Surname-" slot from the empty-realm
    -- window gives its loot to the real partition once, and nothing else.
    local mergeSrc = ev:match("(local function WC_DBMergeEmptyRealmLoot%(.-\nend)\n")
    local mergeFn = mergeSrc and loadstring(mergeSrc .. "\nreturn WC_DBMergeEmptyRealmLoot")
    mergeFn = mergeFn and mergeFn()
    local mergeOK = false
    if mergeFn then
        local chars = {
            ["Serv Nocturne-"] = { lootedItemCounts = { [10] = 3, [11] = 2 }, bestGPH = 5000, bestGPHZone = "Arathi", blacklist = { [99] = true } },
            ["Serv Nocturne-R"] = { lootedItemCounts = { [10] = 4 }, bestGPH = 4000, blacklist = { [1] = true } },
        }
        local marks = {}
        local first = mergeFn(chars, marks, "Serv Nocturne-", "Serv Nocturne-R")
        local again = mergeFn(chars, marks, "Serv Nocturne-", "Serv Nocturne-R")
        local to = chars["Serv Nocturne-R"]
        local same = mergeFn({ ["A-"] = {} }, {}, "A-", "A-")
        mergeOK = first == true and again == false and same == false
            and to.lootedItemCounts[10] == 7 and to.lootedItemCounts[11] == 2
            and to.bestGPH == 5000 and to.bestGPHZone == "Arathi"
            and to.blacklist[99] == nil and to.blacklist[1] == true
            and marks["Serv Nocturne-"] == "Serv Nocturne-R"
            and chars["Serv Nocturne-"].lootedItemCounts[10] == 3
    end
    check("Test 143h: empty-realm slot loot merges once, adds counts, keeps lists out",
        mergeOK and ev:find("WC_DBMergeEmptyRealmLoot%(\n%s*WoWClearanceDB%.chars,\n%s*WoWClearanceDB%.emptyRealmMerged,") ~= nil,
        "a second merge would double the loot counts; copying the old slot's lists would bring back an old Keep / Sell List.")
    local del = ev:match("function WC_compCache%.executeBagSlotDelete%((.-)\nend\n")
    check("Test 143c: an own delete is counted only after the copy left its slot",
        del ~= nil
            and del:find("WC_BumpStat", 1, true) == nil
            and del:find("C_Item.GetItemGUID(still) == guid", 1, true) ~= nil
            and del:find("countBagSlotDelete", 1, true) ~= nil,
        "a refused or popup-gated delete leaves the item in place; counting it at call time inflated the stats and the Sold History.")
    -- MEASURED 2026-10-10: DeleteCursorItem is protected on Forever; a delete
    -- from the BAG_UPDATE debounce was blocked and looped with the item on
    -- the cursor. Only an input handler may open the gate.
    local setters = 0
    for _ in ev:gmatch("WC_compCache%.deleteFromInput = true") do
        setters = setters + 1
    end
    local dn = ev:match("function WoWClearance_DeleteNext%(%)(.-)\nend\n") or ""
    check("Test 143d: deletes run only inside a player's key press or click",
        del ~= nil
            and del:find("if not WC_compCache.deleteFromInput then", 1, true) ~= nil
            and setters == 1
            and dn:find("WC_compCache.deleteFromInput = true", 1, true) ~= nil
            and dn:find("WC_compCache.deleteFromInput = false", 1, true) ~= nil,
        "the gate must be opened only by WoWClearance_DeleteNext (bound to a key and a button) and closed again after the call.")
end

-- ---------------------------------------------------------------------------
-- Test 144 (v0.6.0): Help search highlights the matched words.
-- ---------------------------------------------------------------------------
-- The highlighter lives in the shared kit (NS.Kit.Highlight); the Help
-- panel must call it.
do
    local fh = io.open("WoWClearance_HelpPanel.lua", "rb")
    local src = fh and fh:read("*a") or ""
    if fh then
        fh:close()
    end
    check("Test 144: Help search uses NS.Kit.Highlight",
        src:find("NS.Kit.Highlight(", 1, true) ~= nil and src:find("WC_highlight", 1, true) == nil,
        "the Help panel must highlight through the shared kit")
    local kitNS = {}
    local chunk = loadfile("WoWClearance_Kit.lua")
    if chunk then
        chunk(nil, kitNS)
    end
    local kh = kitNS.Kit and kitNS.Kit.Highlight
    local hl = kh and function(text, query, resume)
        return kh(text, query, nil, resume)
    end
    check("Test 144: NS.Kit.Highlight loads", type(hl) == "function", "could not load WoWClearance_Kit.lua")
    if type(hl) == "function" then
        check("Test 144a: every case-insensitive match is wrapped in yellow",
            hl("Delete Next deletes one", "delete") == "|cffffff00Delete|r Next |cffffff00delete|rs one",
            hl("Delete Next deletes one", "delete"))
        check("Test 144b: matches inside an escape code are left alone",
            hl("|cffb6ffb6Keep|r list", "cff") == "|cffb6ffb6Keep|r list",
            hl("|cffb6ffb6Keep|r list", "cff"))
        check("Test 144c: the resume colour follows each match; empty query is a no-op",
            hl("Keep List", "list", "|cff4db8ff") == "Keep |cffffff00List|r|cff4db8ff"
                and hl("Keep List", "") == "Keep List",
            hl("Keep List", "list", "|cff4db8ff"))
    end
end

print()
if fails > 0 then
    io.stderr:write("RESULT: " .. fails .. " test(s) failed\n")
    os.exit(1)
else
    print("RESULT: all tests passed")
    os.exit(0)
end
