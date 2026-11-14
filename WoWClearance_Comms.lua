-- WoWClearance_Comms.lua
-- Addon-to-addon comms for WoWClearance.
--
-- Modeled on a proven 3.3.5a version-gossip pattern: broadcast a version
-- request on a group channel, peers reply by whisper, nudge once per
-- session. (Neutral framing per repo rule; no third-party addon named.)
--
-- Transport notes (post-port):
--   * RegisterAddonMessagePrefix is MANDATORY. On 3.3.5a, filtering
--     CHAT_MSG_ADDON by prefix was the entire job and this file's header used
--     to say so. On Forever the client never DELIVERS CHAT_MSG_ADDON for an
--     unregistered prefix, so without the call below this whole layer - the
--     version gossip and the guild share that rides on it - loads cleanly and
--     never fires. No error, no symptom. See the registration at the bottom.
--   * SendAddonMessage channels: PARTY / RAID / GUILD / BATTLEGROUND / WHISPER.
--   * The group event is GROUP_ROSTER_UPDATE (the event-hub wiring in
--     WoWClearance_Events.lua). PARTY_MEMBERS_CHANGED is REJECTED by this
--     client, and RegisterEvent throws on an unknown name.
local NS = select(2, ...)
local SendAddonMessage = C_ChatInfo.SendAddonMessage
local L = NS.L

local Comms = {}
NS.Comms = Comms

local VER_MAJ_FACTOR = 1000000
local VER_MIN_FACTOR = 1000
local VER_COMPONENT_MAX = 1000

-- Encode "v?MAJOR.MINOR.PATCH" as MAJOR*1000000 + MINOR*1000 + PATCH so peers
-- compare numerically. A plain string compare breaks at two digits
-- ("2.10.0" < "2.9.0" lexically); numeric encoding fixes that. Each component
-- must be < 1000; anything malformed returns nil and is ignored upstream.
-- Anchored at both ends: the string is untrusted (any player can whisper it)
-- and is printed in the update notice, so trailing text must not ride along.
function Comms.parseVersion(str)
    if type(str) ~= "string" then
        return nil
    end
    local s = str:gsub("^[vV]", "")
    local maj, min, pat = s:match("^(%d+)%.(%d+)%.(%d+)$")
    maj, min, pat = tonumber(maj), tonumber(min), tonumber(pat)
    if not (maj and min and pat) then
        return nil
    end
    if maj >= VER_COMPONENT_MAX or min >= VER_COMPONENT_MAX or pat >= VER_COMPONENT_MAX then
        return nil
    end
    return maj * VER_MAJ_FACTOR + min * VER_MIN_FACTOR + pat
end

-- ---- transport ----------------------------------------------------------
local PREFIX = "WCLR1" -- short, distinctive; trailing 1 = protocol version
local SEP = "\t" -- field separator; never appears in version strings or links

local handlers = {} -- msgType -> fn(payload, sender, channel)
local lastSendAt = {} -- throttle key -> GetTime() of last send
local SEND_THROTTLE_S = 30

function Comms.RegisterHandler(msgType, fn)
    handlers[msgType] = fn
end

-- Throttle key per (message type, destination) so unrelated message types to
-- the same peer never share a bucket (e.g. a version reply must not
-- throttle-drop a guild-data reply to the same player).
local function throttleKey(msgType, channel, target)
    return (channel == "WHISPER") and (msgType .. ":WHISPER:" .. tostring(target))
        or (msgType .. ":" .. channel)
end

-- True when Send with the same (msgType, destination) would go out rather
-- than be throttle-dropped. Reply handlers whose payload is expensive to
-- build (GuildShare aggregation) check this FIRST - otherwise a
-- request storm makes every opted-in client pay the full payload build per
-- request while the throttle silently discards the reply.
function Comms.CanSend(msgType, channel, target)
    local last = lastSendAt[throttleKey(msgType, channel, target)]
    return not (last and (GetTime() - last) < SEND_THROTTLE_S)
end

local SEND_OK = (Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success) or 0
local sendsSincePrune = 0

function Comms.Send(msgType, payload, channel, target)
    local now = GetTime()
    local key = throttleKey(msgType, channel, target)
    if lastSendAt[key] and (now - lastSendAt[key]) < SEND_THROTTLE_S then
        return
    end
    -- Boss fights and other chat lockdowns refuse addon messages. Skip
    -- without starting the throttle window, so a later trigger can send.
    if C_ChatInfo.InChatMessagingLockdown() then
        return
    end
    local result = SendAddonMessage(PREFIX, msgType .. SEP .. tostring(payload), channel, target)
    -- Only a message that went out starts the window; a throttled or
    -- refused one may be retried by the next trigger.
    if result == nil or result == SEND_OK then
        lastSendAt[key] = now
    end
    -- One throttle entry per whisper target: drop expired ones now and then
    -- so a long session with many whisperers does not grow the table forever.
    sendsSincePrune = sendsSincePrune + 1
    if sendsSincePrune >= 100 then
        sendsSincePrune = 0
        for k, t in pairs(lastSendAt) do
            if (now - t) >= SEND_THROTTLE_S then
                lastSendAt[k] = nil
            end
        end
    end
end

-- The group chat type for addon messages: INSTANCE_CHAT in a dungeon-finder
-- style instance group, else RAID or PARTY; nil when not grouped.
function Comms.GroupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    end
end

-- Register the prefix BEFORE listening, so no delivery window is missed.
-- Guarded rather than assumed: a failure here is worth a diagnostic, because
-- the symptom of not registering is silence rather than an error, and silence
-- is indistinguishable from "nobody else is running the addon".
if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    local ok, registered = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    Comms.prefixRegistered = (ok and registered ~= false) and true or false
else
    Comms.prefixRegistered = false
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(self, event, prefix, message, channel, sender)
    if prefix ~= PREFIX then
        return -- cheap early-out: unrelated addon traffic costs one compare
    end
    -- Chat payloads can be secret during a chat lockdown; reading one throws.
    if not NS.CanRead(message, sender) then
        return
    end
    local msgType, payload = message:match("^(.-)" .. SEP .. "(.*)$")
    if not msgType then
        return
    end
    local fn = handlers[msgType]
    if fn then
        pcall(fn, payload, sender, channel) -- a bad payload must not raise an error per message
    end
end)

-- ---- version-check consumer ---------------------------------------------
local RELEASE_URL = "https://github.com/powerfulqa/WoWClearance/releases/latest"
-- Green clickable link shown in the nudge. The "wcupdate" hyperlink type is
-- custom; the SetItemRef hook below catches the click and shows a copyable
-- popup (the 3.3.5a client cannot open a browser, so copy-and-paste is the
-- most a click can offer).
local RELEASE_LINK = "|cff33ff33|Hwcupdate:latest|h[Click here]|h|r"
local NUDGE_DELAY_S = 3
local versionNudgeShown = false -- once per session
-- v2.66.1 iter (Serv report): remember the highest peer version we've
-- seen this session so the Main panel can display "Latest available:
-- vX.Y.Z" next to the update-alert toggle. The chat nudge only fires
-- once per session, so a player who joined after the nudge could
-- otherwise miss the info.
local highestPeerVersionStr = nil
local highestPeerVersionInt = 0

local function myVersionStr()
    return NS.GetVersion and NS.GetVersion() or nil
end

-- "First Surname": the spelling the server uses for message senders and
-- whisper targets on Forever. UnitName gives only the first name, which
-- other players can share, so it never matches a sender.
local function playerName()
    return GetUnitName("player", true)
end

local function showVersionNudge(peerVerStr)
    if versionNudgeShown then
        return
    end
    versionNudgeShown = true
    NS.PrintNicef(
        L["|cffffff00Update available: %s|r (you have %s). %s"],
        peerVerStr,
        tostring(myVersionStr()),
        RELEASE_LINK
    )
end

-- Copy window shown when the player clicks the green release link. The
-- client cannot launch a browser, so the URL is shown for Ctrl+C in the
-- shared kit copy window. The default SetItemRef ignores unknown link types,
-- so the handler below is the only one for the custom "wcupdate" link.
local function showUpdateLink()
    NS.Kit.ShowCopy("WoWClearanceCopy", L["WoWClearance: Update"], RELEASE_URL, 440, 140)
end

-- Intercept clicks on our custom "wcupdate" link.
--
-- WC-TRAP, REWRITTEN v0.5.4. The old trap said SetItemRef must be REPLACED
-- and must never become a hook. That was correct on 3.3.5a, where the stock
-- handler passed unknown link types to ItemRefTooltip:SetHyperlink and
-- errored with "Unknown link type". Its PREMISE no longer holds on Forever,
-- so the instruction no longer follows from it.
--
-- Blizzard_UIPanels_Game/Mainline/ItemRef.lua:6 now reads:
--     function SetItemRef(link, text, button, frame)
--         local response = LinkUtil.ProcessLink(link, text, contextData);
--         if response == LinkProcessorResponse.Handled then return; end
-- and Blizzard_SharedXML/LinkUtil.lua:198 exposes
-- LinkUtil.RegisterLinkHandler(linkType, handlerFunction) where linkType is
-- a plain string key. An unregistered type simply has no handler; it does
-- not error. Blizzard's own addons register custom types this way.
--
-- WHY THIS MATTERS BEYOND TIDINESS: replacing the global makes this addon a
-- TAINT SOURCE. Measured by the BarWarden-Forever port, whose taint.log
-- showed execution tainted while reading global SetItemRef, with our line
-- as the read site - and both addons were replacing it, each capturing the
-- other's replacement as "orig" depending on load order. Registering a
-- handler removes us from that chain entirely.
--
-- The 3.3.5a replacement is KEPT as a fallback for any client without
-- LinkUtil, and is still a replacement rather than a hook there, for the
-- original reason. Do not collapse the two branches.
local WC_UPDATE_LINK_TYPE = "wcupdate"

if LinkUtil and LinkUtil.RegisterLinkHandler then
    -- RegisterLinkHandler asserts on a duplicate, so guard. A /reload
    -- re-runs this file while the registration from the previous load is
    -- still present.
    if not (LinkUtil.IsLinkHandlerRegistered and LinkUtil.IsLinkHandlerRegistered(WC_UPDATE_LINK_TYPE)) then
        LinkUtil.RegisterLinkHandler(WC_UPDATE_LINK_TYPE, function()
            showUpdateLink()
            return LinkProcessorResponse and LinkProcessorResponse.Handled or nil
        end)
    end
else
    local origSetItemRef = SetItemRef
    function SetItemRef(link, text, button, chatFrame)
        if type(link) == "string" and link:sub(1, 9) == "wcupdate:" then
            showUpdateLink()
            return
        end
        if origSetItemRef then
            return origSetItemRef(link, text, button, chatFrame)
        end
    end
end

-- Decide whether a peer's advertised version should trigger a nudge.
local function considerPeerVersion(verStr, sender)
    if not WoWClearanceDB or not WoWClearanceDB.versionAlerts then
        return
    end
    if sender and sender == playerName() then
        return -- ignore our own broadcast echoed back
    end
    local peerInt = Comms.parseVersion(verStr)
    local myInt = Comms.parseVersion(myVersionStr() or "")
    if not peerInt or not myInt then
        return
    end
    -- Sanity cap: ignore an absurd version (e.g. a troll whispering v99.99.99).
    -- parseVersion only accepts bare "vX.Y.Z", so a spoof can name a version
    -- but cannot put its own text or links into the notice.
    local myMaj = math.floor(myInt / VER_MAJ_FACTOR)
    local peerMaj = math.floor(peerInt / VER_MAJ_FACTOR)
    if peerMaj > myMaj + 1 then
        return
    end
    if peerInt > myInt then
        -- Track the highest peer version we've seen this session so the
        -- Main panel can display it next to the update-alert toggle.
        -- Same major-version sanity cap already applied above.
        if peerInt > highestPeerVersionInt then
            highestPeerVersionInt = peerInt
            highestPeerVersionStr = verStr
        end
        if NS.Delay then
            NS.Delay(NUDGE_DELAY_S, function()
                showVersionNudge(verStr)
            end)
        end
    end
end

-- Exposed for the Main panel (WoWClearance_MainPanel.lua) to render
-- next to the "Tell me when an update is available" toggle. Returns
-- the version string of the highest-version peer we've seen this
-- session, or nil if no peer has advertised a newer version than ours.
Comms.GetLatestPeerVersion = function()
    return highestPeerVersionStr
end

-- Exposed so the realm-wide share (NS.ServerShare) can feed peer versions it
-- overhears on the realm channel into the same nudge/spoof-cap/once-per-session
-- logic, reusing the release path unchanged. Still gated by versionAlerts inside.
Comms.NotePeerVersion = considerPeerVersion

-- A VERQ carries the sender's version (learn it directly) AND asks us to
-- reply: whisper our version straight back to the requester.
Comms.RegisterHandler("VERQ", function(payload, sender, channel)
    considerPeerVersion(payload, sender)
    if WoWClearanceDB and WoWClearanceDB.versionAlerts and sender and sender ~= playerName() then
        local v = myVersionStr()
        if v then
            Comms.Send("VERR", v, "WHISPER", sender)
        end
    end
end)

-- A VERR is a direct reply carrying the replier's version.
Comms.RegisterHandler("VERR", function(payload, sender, channel)
    considerPeerVersion(payload, sender)
end)

-- ---- self-test diagnostic (/wc commtest) --------------------------------
-- Lets a solo player verify two things without a second client:
--   1. the wire: does this server actually deliver addon messages? (a guild
--      addon message echoes back to the sender on stock 3.3.5a)
--   2. the logic: does a higher peer version produce one nudge, and does the
--      opt-out toggle suppress it?
local commtestToken = nil
local commtestEchoed = false

-- A ping we sent comes back to us (self-echo on GUILD) or a peer answers PONG.
Comms.RegisterHandler("PING", function(payload, sender, channel)
    if commtestToken and payload == commtestToken then
        commtestEchoed = true
        NS.PrintNicef(L["Comms relay OK: message delivered (echo from %s)."], tostring(sender))
    end
    -- If a real peer pinged us, answer so their test can pass too.
    if sender and sender ~= playerName() then
        Comms.Send("PONG", payload, "WHISPER", sender)
    end
end)

Comms.RegisterHandler("PONG", function(payload, sender, channel)
    if commtestToken and payload == commtestToken then
        commtestEchoed = true
        NS.PrintNicef(L["Comms relay OK: reply received from %s."], tostring(sender))
    end
end)

function Comms.RunSelfTest()
    local myVer = NS.GetVersion and NS.GetVersion() or "unknown"
    NS.PrintNicef(L["Comms self-test. Your version: %s (parsed %s)."],
        myVer, tostring(Comms.parseVersion(myVer)))

    -- 1. Wire relay check (needs a guild; bypasses the normal send throttle).
    if GetGuildInfo("player") then
        commtestToken = tostring(GetTime())
        commtestEchoed = false
        SendAddonMessage(PREFIX, "PING" .. SEP .. commtestToken, "GUILD")
        NS.PrintNicef(L["Sent a guild ping; waiting for it to echo back..."])
        NS.Delay(3, function()
            if not commtestEchoed then
                NS.PrintNicef(L["Comms relay inconclusive: no echo in 3s. The game may not echo your own guild messages, or addon messages are filtered. Confirm with a second player."])
            end
        end)
    else
        NS.PrintNicef(L["Not in a guild, skipping the wire echo test. Join any guild to test message delivery."])
    end

    -- 2. Logic + UX check: simulate a higher-version peer through the real path.
    versionNudgeShown = false -- reset so the test is repeatable
    highestPeerVersionStr = nil
    highestPeerVersionInt = 0
    local myInt = Comms.parseVersion(myVer)
    if myInt then
        local maj = math.floor(myInt / 1000000)
        local min = math.floor((myInt % 1000000) / 1000)
        local fakeVer = string.format("v%d.%d.%d", maj, min + 1, 0)
        local alertsOn = WoWClearanceDB and WoWClearanceDB.versionAlerts
        NS.PrintNicef(L["Simulating a peer on %s. Alerts are %s; %s."],
            fakeVer,
            alertsOn and L["ON"] or L["OFF"],
            alertsOn and L["an Update available line should appear in ~3s"] or L["no nudge expected (toggle is off)"])
        considerPeerVersion(fakeVer, "CommTest")
    end
end

-- Send-trigger entry point. Called by the event hub in WoWClearance_Events.lua
-- with "GUILD" or Comms.GroupChannel(). Gated + throttled internally.
function Comms.FireVersionProbe(channel)
    if not WoWClearanceDB or not WoWClearanceDB.versionAlerts then
        return
    end
    local v = myVersionStr()
    if not v then
        return
    end
    Comms.Send("VERQ", v, channel)
end
