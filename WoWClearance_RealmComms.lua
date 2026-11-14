-- WoWClearance_RealmComms.lua
-- Realm-wide addon comms: addon messages on a private custom chat channel.
--
-- SIBLING of NS.Comms, not a replacement: NS.Comms is the guild / group /
-- whisper transport. NS.RealmComms keeps the same RegisterHandler / Send
-- shape, minus channel/target (there is one destination: the realm channel).
--
-- v0.6.0 rebuild for WoW: Forever. The 3.3.5a version posted chat TEXT with
-- SendChatMessage on a hidden channel, because 3.3.5a addon messages could
-- not reach a channel. On Forever that path cannot work: SendChatMessage on a
-- channel needs a hardware event, so a send from a timer is blocked
-- (ADDON_ACTION_BLOCKED), and channel text is secret during a boss fight.
-- What is measured to work instead (wow-forever-api skill, chat reference):
--   * C_ChatInfo.SendAddonMessage on a CUSTOM channel is delivered
--     (2026-09-19). Game channels (General, Trade) swallow it.
--   * The prefix must be registered, or CHAT_MSG_ADDON never arrives.
--   * A channel reaches only your own underlying realm. "Realm-wide" means
--     one copy of the megaserver's realms, and Success is returned either way.
--   * The game keeps permanent channel numbers between sessions; a custom
--     channel joined before General took /1 and kept it, so typing /1 wrote
--     into it. Hence: a TEMPORARY channel, and never joined while /1 is empty.
--
-- Joined only when the player opted in (shareServerData), from the Stats -
-- Server panel, and left when they opt out. Nothing joins or sends at login.
local NS = select(2, ...)
local SendAddonMessage = C_ChatInfo.SendAddonMessage
local L = NS.L

local RealmComms = {}
NS.RealmComms = RealmComms

local PREFIX = "WCLRS" -- distinct from NS.Comms' "WCLR1"
local CHANNEL_NAME = "wowclearance" -- private; must not collide with other addons' channels
local SEP = "\t"
local SEND_DELAY = 0.15 -- pace queued sends; our traffic is one line per request/reply
local MAX_QUEUE = 100
local MAX_WIRE = 255 -- longer addon messages are cut at 255 bytes without an error
local SEND_OK = (Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success) or 0

local handlers = {} -- msgType -> fn(payload, sender)
local sendQueue = {}
local nextSendTime = 0

-- Our channel's number, or nil when not in it. Looked up by name on every
-- use: channel numbers shift when a lower one is left.
local function channelIndex()
    local id = GetChannelName(CHANNEL_NAME)
    return (type(id) == "number" and id > 0) and id or nil
end

function RealmComms.RegisterHandler(msgType, fn)
    handlers[msgType] = fn
end

function RealmComms.IsJoined()
    return channelIndex() ~= nil
end

-- Join the private channel and keep it out of the chat windows. Called only
-- from the player's own clicks (the sharing checkbox, opening the panel,
-- Refresh, /wc realmtest), never from a timer: a join from a timer is
-- unmeasured on Forever. Skips while no game channel holds /1, so ours
-- never takes the number the player types into; the next click retries.
function RealmComms.Join()
    if channelIndex() or GetChannelName(1) == 0 then
        return
    end
    JoinTemporaryChannel(CHANNEL_NAME)
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        RemoveChatWindowChannel(i, CHANNEL_NAME)
    end
end

-- Opting out leaves the channel and drops anything still queued.
function RealmComms.Leave()
    wipe(sendQueue)
    if channelIndex() then
        LeaveChannelByName(CHANNEL_NAME)
    end
end

-- Queue one message. Never joins: only an opted-in player is in the channel,
-- and a send while not joined is dropped.
function RealmComms.Send(msgType, payload)
    if not channelIndex() then
        return
    end
    local wire = tostring(msgType) .. SEP .. tostring(payload)
    if #wire > MAX_WIRE then
        return -- single-message transport; the consumer caps its payload
    end
    if #sendQueue >= MAX_QUEUE then
        table.remove(sendQueue, 1)
    end
    sendQueue[#sendQueue + 1] = wire
end

C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_ADDON")
-- The join completes a moment after JoinTemporaryChannel. Its notice is the
-- point where the channel exists: keep it out of the chat windows there, and
-- send the first request (one sent before the join was dropped).
frame:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
frame:SetScript("OnEvent", function(self, event, prefix, text, channel, sender, _, _, _, _, baseName)
    if event == "CHAT_MSG_CHANNEL_NOTICE" then
        -- prefix = notice type (can be secret in a lockdown); baseName is
        -- documented NeverSecret.
        if type(baseName) == "string" and baseName:lower() == CHANNEL_NAME then
            for i = 1, (NUM_CHAT_WINDOWS or 10) do
                RemoveChatWindowChannel(i, CHANNEL_NAME)
            end
            if NS.CanRead(prefix) and prefix == "YOU_JOINED" and NS.ServerShare and NS.ServerShare.RequestNow then
                NS.ServerShare.RequestNow()
            end
        end
        return
    end
    if prefix ~= PREFIX or channel ~= "CHANNEL" then
        return
    end
    -- Payloads can be secret during a chat lockdown; reading one throws.
    if not NS.CanRead(text, sender) then
        return
    end
    local msgType, payload = text:match("^(.-)" .. SEP .. "(.*)$")
    local fn = msgType and handlers[msgType]
    if fn then
        pcall(fn, payload, sender)
    end
end)

frame:SetScript("OnUpdate", function()
    if #sendQueue == 0 then
        return
    end
    local now = GetTime()
    if now < nextSendTime then
        return
    end
    -- Boss fights refuse addon messages: keep the queue and wait.
    if C_ChatInfo.InChatMessagingLockdown() then
        return
    end
    local idx = channelIndex()
    if not idx then
        wipe(sendQueue) -- left the channel; nobody to send to
        return
    end
    local result = SendAddonMessage(PREFIX, sendQueue[1], "CHANNEL", tostring(idx))
    if result == nil or result == SEND_OK then
        table.remove(sendQueue, 1)
        nextSendTime = now + SEND_DELAY
    elseif result == Enum.SendAddonMessageResult.AddonMessageThrottle
        or result == Enum.SendAddonMessageResult.ChannelThrottle
    then
        nextSendTime = now + 1 -- throttled: keep it and back off
    else
        table.remove(sendQueue, 1) -- refused for good; do not block the queue
        nextSendTime = now + SEND_DELAY
    end
end)

-- ---- self-test diagnostic (/wc realmtest) -------------------------------
-- A solo player can check the transport with no second client: a message on
-- the channel comes back to its sender.
local selfTestToken = nil
local selfTestEchoed = false

RealmComms.RegisterHandler("RPNG", function(payload, sender)
    if selfTestToken and payload == selfTestToken then
        selfTestEchoed = true
        NS.PrintNicef(L["Realm channel OK: message echoed back (from %s)."], tostring(sender))
    end
end)

function RealmComms.RunSelfTest()
    if not (WoWClearanceDB and WoWClearanceDB.shareServerData) then
        NS.PrintNice(L["Turn on sharing in Stats - Server first."])
        return
    end
    RealmComms.Join()
    NS.PrintNicef(
        L["Realm channel self-test. Joined: %s, channel index: %s."],
        RealmComms.IsJoined() and L["yes"] or L["no"],
        tostring(channelIndex())
    )
    selfTestToken = tostring(GetTime())
    selfTestEchoed = false
    RealmComms.Send("RPNG", selfTestToken)
    NS.PrintNicef(L["Sent a channel ping; waiting for it to echo back..."])
    if NS.Delay then
        NS.Delay(3, function()
            if not selfTestEchoed then
                NS.PrintNicef(
                    L["Realm channel test inconclusive: no echo in 3s. Try /reload, or you may be in too many chat channels (10 max)."]
                )
            end
        end)
    end
end
