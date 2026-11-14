-- Headless WoW API stub for the RUNTIME suites (port work item 3).
--
-- The runtime suites load real addon source under stock lua5.1. Since the
-- port, those files bind cached upvalues at file scope:
--
--     local GetContainerItemInfo = C_Container.GetContainerItemInfo
--
-- which throws "attempt to index global 'C_Container' (a nil value)" outside
-- the game, at LOAD time, before any test body runs. The 3.3.5a globals never
-- did this: an undefined global is nil, and `local X = X` binding nil is
-- harmless. Namespaced APIs turn a missing API into a load-time crash.
--
-- So the namespaces have to exist here even though nothing calls them. Each
-- member is a function returning nil, which is what a headless environment
-- honestly is: the API is present, it just has no game behind it. The pure
-- cores under test never call these; the adapters that would are not exercised.
--
-- Kept in lockstep with .luacheckrc's field lists ON PURPOSE: that file is the
-- single record of which members this addon believes exist on WoW: Forever,
-- and tests/test_api_surface.lua pins that those lists stay honest. If you add
-- a member there, add it here.
--
-- dofile'd rather than require'd because the suites run from the repo root as
-- separate processes and do not set package.path.

local function nilfn() return nil end

local function ns(members)
    local t = {}
    for _, name in ipairs(members) do
        t[name] = nilfn
    end
    return t
end

C_Container = ns({
    "GetContainerItemInfo", "GetContainerNumSlots", "GetContainerItemLink",
    "GetContainerItemID", "GetContainerNumFreeSlots", "UseContainerItem",
    "PickupContainerItem",
})
C_Item = ns({
    "GetItemInfo", "GetItemCount", "IsEquippedItem", "IsEquippableItem",
    "IsUsableItem", "GetItemFamily", "RequestLoadItemDataByID",
    "GetCurrentItemLevel", "GetDetailedItemLevelInfo", "CanBeRefunded",
    "DoesItemExist",
})
C_TransmogCollection = ns({ "GetItemInfo", "PlayerHasTransmogItemModifiedAppearance", "PlayerCanCollectSource" })
ItemLocation = ns({ "CreateEmpty" })
C_Spell = ns({
    "GetSpellInfo",
})
C_SpellBook = ns({
    "IsSpellInSpellBook",
})
C_AddOns = ns({ "GetAddOnMetadata", "GetAddOnInfo", "IsAddOnLoaded", "GetNumAddOns" })
C_ChatInfo = ns({ "SendAddonMessage", "RegisterAddonMessagePrefix", "SendChatMessage", "InChatMessagingLockdown" })
C_CurrencyInfo = ns({ "GetCoinTextureString" })
C_TooltipInfo = ns({
    "GetBagItem",
})
C_EquipmentSet = ns({
    "GetNumEquipmentSets", "GetEquipmentSetInfo", "GetEquipmentSetIDs", "GetItemIDs",
})
C_Timer = ns({
    "After",
})

-- Group-state predicates. GetNumPartyMembers / GetNumRaidMembers are gone;
-- these are the replacements and several modules read them at load or in
-- early branches. Default to "solo", the quietest answer.
function IsInRaid() return false end
function IsInGroup() return false end
function GetNumGroupMembers() return 0 end

Enum = Enum or {}
Enum.SpellBookSpellBank = Enum.SpellBookSpellBank or { Player = 0, Pet = 1 }
