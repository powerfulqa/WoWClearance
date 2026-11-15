-- test_decision.lua - RUNTIME tests for the pure sell-decision core.
--
-- v2.71.0 (decision-classifier Stage 1). Unlike the static-pattern suites,
-- this loads WoWClearance_Decision.lua under stock lua5.1 and exercises
-- NS.Decision.sell(ctx) with fixture contexts - the addon's first runtime
-- coverage of the sell logic. Fixtures cover every reason token plus the
-- golden regression cases from the two field incidents (the v2.57.2
-- ilvl-ceiling near item-loss; the v2.51.2/v2.59.10 Sell-List-vs-tome
-- drift) and the v2.49.0 knownProcPass-only case.
--
-- Run from the repo root: lua tests/test_decision.lua

local fails = 0
local function check(name, ok, why)
    if ok then
        print("PASS  " .. name)
    else
        fails = fails + 1
        print("FAIL  " .. name)
        if why then
            print("      " .. why)
        end
    end
end

-- Load the decision module in isolation. It only touches NS at load time;
-- the WoW-API upvalues at its head resolve to nil here, which is fine -
-- the pure core never calls them and these tests never call buildCtx.
-- WoW API namespace stubs. Since the port, addon files bind
-- `local X = C_Namespace.X` at file scope, which throws outside the
-- game before any test body runs. See tests/wow_stub.lua.
dofile("tests/wow_stub.lua")

local chunk = assert(loadfile("WoWClearance_Decision.lua"), "cannot load WoWClearance_Decision.lua (run from repo root)")
local NS = {}
chunk("WoWClearance", NS)
local D = NS.Decision
check("module loads and exposes Decision.sell", D ~= nil and type(D.sell) == "function")

local function thunkFalse()
    return false
end
local function thunkNil()
    return nil
end

-- Sentinel for "override this fixture field to nil" - a literal nil in the
-- overrides table would be invisible to pairs().
local NIL = {}

-- Baseline fixture: a plain grey vendor-trash item with a sell price and
-- every feature toggle off. Overrides layer per-case deltas on top.
local function makeCtx(o)
    local ctx = {
        junkOnly = false,
        itemID = 1000,
        count = 1,
        locked = false,
        link = "item:1000",
        quality = 0,
        ilvl = 10,
        equipLoc = "",
        sellPrice = 10,
        whitelistedChar = false,
        whitelistedAccount = false,
        blacklisted = false,
        equipped = false,
        isQuestItem = false,
        baselineProtected = false,
        allowedItem = false,
        qualityRule = nil,
        affixMinSellRank = 0,
        affixAllowExactDupes = false,
        keepBoeAffixDupes = false,
        keepBoeBelowRankFloor = false,
        sellKnownRecipes = false,
        sellKnownRecipeQuality = false,
        recipeBindFilter = "any",
        sellChanceOnHitKnown = false,
        protectChanceOnHitItems = false,
        protectAffixedRareItems = false,
        protectAllTomes = false,
        protectUnlearnedTomes = false,
        protectUncollectedAppearances = false,
        protectTradeableLoot = false,
        uncollectedAppearance = thunkFalse,
        tradeable = thunkFalse,
        bindType = function()
            return "any"
        end,
        downgradeVsEquipped = thunkFalse,
        affixData = thunkNil,
        saleWithinCeiling = function()
            return true
        end,
        hasChanceOnHit = thunkFalse,
        chanceProcLine = thunkNil,
        hasExtractedProc = thunkFalse,
        isExtractableWeaponSlot = thunkFalse,
        isTome = thunkFalse,
        tomeKind = function()
            return "Tome"
        end,
        knowsTomeSpell = thunkFalse,
        affixDescKnown = thunkFalse,
        affixRankKnown = thunkFalse,
        affixFamilyKnown = thunkFalse,
        manualAffixAllow = thunkFalse,
    }
    for k, v in pairs(o or {}) do
        if v == NIL then
            ctx[k] = nil
        else
            ctx[k] = v
        end
    end
    return ctx
end

local function sellsAs(ctx, wantToken)
    local verdict, token = D.sell(ctx)
    return verdict == "sell" and token == wantToken,
        string.format("got verdict=%s token=%s, wanted sell/%s", tostring(verdict), tostring(token), tostring(wantToken))
end
local function keepsAs(ctx, wantToken)
    local verdict, token = D.sell(ctx)
    return verdict == "keep" and token == wantToken,
        string.format("got verdict=%s token=%s, wanted keep/%s", tostring(verdict), tostring(token), tostring(wantToken))
end
local function isNone(ctx)
    local verdict, token = D.sell(ctx)
    return verdict == "none", string.format("got verdict=%s token=%s, wanted none", tostring(verdict), tostring(token))
end

-- ---- empty / locked -------------------------------------------------------
check("empty slot -> none/empty", select(1, (function()
    local v, t = D.sell({ itemID = nil })
    return v == "none" and t == "empty"
end)()))
check("locked slot -> none/locked", (function()
    local v, t = D.sell(makeCtx({ locked = true }))
    return v == "none" and t == "locked"
end)())

-- ---- grey-always-sold invariant (WC-TRAP) ----------------------------------
check("grey with price sells as junk", sellsAs(makeCtx(), "junk"))
check("grey with no price -> none", isNone(makeCtx({ sellPrice = 0 })))
check("grey sells under junkOnly even with lists disabled by junkOnly",
    sellsAs(makeCtx({ junkOnly = true, whitelistedChar = true }), "junk"))
-- "Sell grey items" toggle: off keeps greys, nil (old saves) reads as on,
-- and a grey on the Sell List still sells (explicit intent wins).
check("sellGreys=false keeps a grey", isNone(makeCtx({ sellGreys = false })))
check("sellGreys=nil still sells a grey as junk", sellsAs(makeCtx({ sellGreys = nil }), "junk"))
check("sellGreys=false: Sell-Listed grey still sells",
    sellsAs(makeCtx({ sellGreys = false, whitelistedChar = true }), "whitelist_char"))
-- Host bag UI "sell as junk" mark: sells as junk at any quality (with a
-- price), under the same "Sell grey items" switch. Its lock arrives as blacklisted (the adapter
-- folds it in), so a locked marked item is kept.
check("hostMarkedJunk sells a green as junk",
    sellsAs(makeCtx({ quality = 2, hostMarkedJunk = true }), "junk"))
-- With "Sell grey items" off the host sells its own junk, so we must not.
check("hostMarkedJunk does not sell with sellGreys=false",
    isNone(makeCtx({ quality = 2, sellGreys = false, hostMarkedJunk = true })))
check("hostMarkedJunk with no price -> none",
    isNone(makeCtx({ quality = 2, hostMarkedJunk = true, sellPrice = 0 })))
check("locked (blacklisted) marked junk is kept", (function()
    local v, t = D.sell(makeCtx({ hostMarkedJunk = true, blacklisted = true }))
    return v == "keep" and t == "blacklist"
end)())

-- ---- quality rules ---------------------------------------------------------
local greenGear = { quality = 2, ilvl = 40, equipLoc = "INVTYPE_CHEST" }
check("rarity rule cap 0 sells everything of the rarity",
    sellsAs(makeCtx({ quality = 2, ilvl = 40, equipLoc = "", qualityRule = { enabled = true, maxILvl = 0 } }), "quality"))
check("cap > 0: under-cap equippable sells",
    sellsAs(makeCtx({ quality = greenGear.quality, ilvl = 40, equipLoc = greenGear.equipLoc,
        qualityRule = { enabled = true, maxILvl = 50 } }), "quality"))
check("cap > 0: over-cap equippable does not sell",
    isNone(makeCtx({ quality = 2, ilvl = 60, equipLoc = "INVTYPE_CHEST", qualityRule = { enabled = true, maxILvl = 50 } })))
check("cap > 0: no-equipLoc item (trade good) is protected",
    isNone(makeCtx({ quality = 2, ilvl = 60, equipLoc = "", qualityRule = { enabled = true, maxILvl = 50 } })))
check("useEquippedILvl mode follows the downgrade thunk",
    sellsAs(makeCtx({ quality = 2, ilvl = 40, equipLoc = "INVTYPE_CHEST",
        qualityRule = { enabled = true, useEquippedILvl = true },
        downgradeVsEquipped = function() return true end }), "quality"))
check("bind filter mismatch vetoes the rule match",
    isNone(makeCtx({ quality = 2, ilvl = 40, equipLoc = "INVTYPE_CHEST",
        qualityRule = { enabled = true, maxILvl = 0, bindFilter = "bop" } })))
check("bind filter match keeps the rule match",
    sellsAs(makeCtx({ quality = 2, ilvl = 40, equipLoc = "INVTYPE_CHEST",
        qualityRule = { enabled = true, maxILvl = 0, bindFilter = "bop" },
        bindType = function() return "bop" end }), "quality"))

-- ---- lists + safety nets ---------------------------------------------------
check("character Sell List sells as whitelist_char",
    sellsAs(makeCtx({ quality = 2, whitelistedChar = true }), "whitelist_char"))
check("account Sell List sells as whitelist_account",
    sellsAs(makeCtx({ quality = 2, whitelistedAccount = true }), "whitelist_account"))
check("quest item vetoes the auto-rule sweep",
    isNone(makeCtx({ quality = 2, isQuestItem = true, qualityRule = { enabled = true, maxILvl = 0 } })))
check("quest item on the Sell List still sells (user intent overrides)",
    sellsAs(makeCtx({ quality = 2, isQuestItem = true, whitelistedChar = true }), "whitelist_char"))
check("baseline profession tool vetoes the sweep",
    isNone(makeCtx({ quality = 1, baselineProtected = true, qualityRule = { enabled = true, maxILvl = 0 } })))
check("Allow Sell bypasses the baseline-tool veto",
    sellsAs(makeCtx({ quality = 1, baselineProtected = true, allowedItem = true,
        qualityRule = { enabled = true, maxILvl = 0 } }), "quality"))
check("equipped item keeps even when whitelisted",
    keepsAs(makeCtx({ quality = 2, whitelistedChar = true, equipped = true }), "equipped"))
check("Keep List (blacklist) wins over every sell signal",
    keepsAs(makeCtx({ quality = 2, whitelistedChar = true, blacklisted = true }), "blacklist"))

-- ---- tome protection -------------------------------------------------------
local function tomeCtx(o)
    local base = {
        quality = 3,
        ilvl = 50,
        equipLoc = "",
        qualityRule = { enabled = true, maxILvl = 0 },
        isTome = function()
            return true
        end,
    }
    for k, v in pairs(o or {}) do
        base[k] = v
    end
    return makeCtx(base)
end
check("protectAllTomes keeps a rule-matched tome",
    keepsAs(tomeCtx({ protectAllTomes = true }), "tomeProtected"))
check("protectUnlearnedTomes keeps an unlearned tome",
    keepsAs(tomeCtx({ protectUnlearnedTomes = true }), "tomeUnlearned"))
check("protectUnlearnedTomes releases a learned tome",
    sellsAs(tomeCtx({ protectUnlearnedTomes = true, knowsTomeSpell = function() return true end }), "quality"))
check("GOLDEN (v2.51.2/v2.59.10 Mooncloth): Sell List releases the tome veto even with a rule match",
    sellsAs(tomeCtx({ protectAllTomes = true, whitelistedChar = true }), "whitelist_char"))
check("Sell Known Recipes overrides protectAllTomes for a learned recipe",
    sellsAs(tomeCtx({ protectAllTomes = true, sellKnownRecipes = true, sellKnownRecipeQuality = true,
        tomeKind = function() return "Recipe" end, knowsTomeSpell = function() return true end }), "recipe"))
check("recipe bind filter vetoes a mismatched recipe",
    isNone(tomeCtx({ sellKnownRecipes = true, sellKnownRecipeQuality = true, qualityRule = NIL,
        tomeKind = function() return "Recipe" end, knowsTomeSpell = function() return true end,
        recipeBindFilter = "bop" })))

-- ---- Forever protections (v0.6.0) -------------------------------------------
-- Same release shape as the tome veto: they stop the auto rules only.
local function gearCtx(o)
    local base = {
        quality = 2,
        ilvl = 40,
        equipLoc = "INVTYPE_CHEST",
        qualityRule = { enabled = true, maxILvl = 0 },
    }
    for k, v in pairs(o or {}) do
        base[k] = v
    end
    return makeCtx(base)
end
local thunkTrue = function() return true end
check("uncollected appearance keeps rule-matched gear",
    keepsAs(gearCtx({ protectUncollectedAppearances = true, uncollectedAppearance = thunkTrue }), "appearance"))
check("collected appearance still sells by rule",
    sellsAs(gearCtx({ protectUncollectedAppearances = true }), "quality"))
check("appearance protection off: rule-matched gear sells",
    sellsAs(gearCtx({ uncollectedAppearance = thunkTrue }), "quality"))
check("Sell List releases the appearance veto",
    sellsAs(gearCtx({ protectUncollectedAppearances = true, uncollectedAppearance = thunkTrue, whitelistedChar = true }), "whitelist_char"))
check("Allow Sell releases the appearance veto",
    sellsAs(gearCtx({ protectUncollectedAppearances = true, uncollectedAppearance = thunkTrue, allowedItem = true }), "quality"))
check("a host junk mark releases the appearance veto (rule also matches)",
    sellsAs(gearCtx({ protectUncollectedAppearances = true, uncollectedAppearance = thunkTrue, hostMarkedJunk = true }), "junk"))
check("a host junk mark releases the tradeable veto (rule also matches)",
    sellsAs(gearCtx({ protectTradeableLoot = true, tradeable = thunkTrue, hostMarkedJunk = true }), "junk"))
check("a host junk mark releases the tome veto (rule also matches)",
    sellsAs(tomeCtx({ protectAllTomes = true, hostMarkedJunk = true }), "junk"))
check("tradeable loot keeps rule-matched gear",
    keepsAs(gearCtx({ protectTradeableLoot = true, tradeable = thunkTrue }), "tradeable"))
check("Sell List releases the tradeable veto",
    sellsAs(gearCtx({ protectTradeableLoot = true, tradeable = thunkTrue, whitelistedAccount = true }), "whitelist_account"))
check("WC-TRAP grey-always-sold survives both protections",
    sellsAs(makeCtx({ quality = 0, protectUncollectedAppearances = true, uncollectedAppearance = thunkTrue,
        protectTradeableLoot = true, tradeable = thunkTrue }), "junk"))

-- ---- merchant mode (junkOnly) + sell-price gates ----------------------------
-- Runtime companions to the static pins in test_perf_guardrails: every
-- positive signal except isJunk must honour junkOnly (Windrunner Legguards
-- report). The affix / proc companions went with those signals; the two
-- below are the survivors and still guard the junkOnly contract.
check("junkOnly: quality rule does not fire at a disallowed merchant",
    isNone(makeCtx({ junkOnly = true, quality = 2, ilvl = 40, equipLoc = "INVTYPE_CHEST",
        qualityRule = { enabled = true, maxILvl = 0 } })))
check("junkOnly: Sell List does not fire at a disallowed merchant",
    isNone(makeCtx({ junkOnly = true, quality = 2, whitelistedChar = true })))

-- ---- delete eligibility (v2.71.3, classifier Stage 4) -----------------------
-- Decision.deleteEligible(ctx): the Delete-List destruction gate. The
-- v2.50.2 rescue vetoes (Keep List / ACCOUNT Sell List / equipped) are the
-- load-bearing part - auto-mark writes to deleteList without the cross-list
-- conflict guard, so later Keep intent must rescue at destruction time.
check("module exposes Decision.deleteEligible", type(D.deleteEligible) == "function")
local function delAs(ctx, wantEligible, wantToken)
    local eligible, token = D.deleteEligible(ctx)
    return eligible == wantEligible and token == wantToken,
        string.format("got eligible=%s token=%s, wanted %s/%s",
            tostring(eligible), tostring(token), tostring(wantEligible), tostring(wantToken))
end
local function deletable(o)
    o = o or {}
    o.onDeleteList = (o.onDeleteList == nil) and true or o.onDeleteList
    if o.affixDisposable == nil then
        o.affixDisposable = thunkFalse
    end
    return makeCtx(o)
end
check("empty slot -> false/empty", delAs(deletable({ itemID = NIL }), false, "empty"))
check("not on Delete List -> false/notOnList", delAs(deletable({ onDeleteList = false }), false, "notOnList"))
check("listed grey item is eligible", delAs(deletable(), true, "deleteList"))
check("GOLDEN (v2.50.2 shirt-loss): Keep List rescues a listed item",
    delAs(deletable({ blacklisted = true }), false, "keepList"))
check("account Sell List rescues a listed item",
    delAs(deletable({ whitelistedAccount = true }), false, "sellList"))
check("character Sell List does NOT rescue (deliberate asymmetry)",
    delAs(deletable({ whitelistedChar = true }), true, "deleteList"))
check("equipped rescues a listed item",
    delAs(deletable({ equipped = true }), false, "equipped"))
check("locked slot is skipped this tick",
    delAs(deletable({ locked = true }), false, "locked"))

print()
if fails > 0 then
    io.stderr:write("RESULT: " .. fails .. " test(s) failed\n")
    os.exit(1)
else
    print("RESULT: all tests passed")
    os.exit(0)
end
