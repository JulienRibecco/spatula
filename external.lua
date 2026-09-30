--- spatula.external - External API integrations (Twitch, Discord, etc.)
--- @module spatula.external
---
--- Provides Stream-compatible wrappers for external data sources.
--- Uses OSC as the transport layer - external bridges send data via UDP.
---
--- Usage:
---   1. Start the bridge: python tools/twitch_bridge.py --channel sodapoppin
---   2. In Spatula:
---      local External = require("spatula.external")
---      local twitch = External.twitch(8080)
---      -- In update loop:
---      External.update(twitch)
---      local msg = External.getMessage(twitch)
---      local rate = External.getRate(twitch)

local OSC = require("spatula.osc")
local Stream = require("spatula.stream")

local External = {}

--------------------------------------------------------------------------------
-- TWITCH CHAT
--------------------------------------------------------------------------------

--- Create a Twitch chat receiver
--- @param port number OSC port (default 8080)
--- @return table Twitch receiver instance
function External.twitch(port)
    port = port or 8080
    return {
        _type = "twitch",
        osc = OSC.new(port),
        lastMessage = "",
        lastUser = "",
        messageCount = 0,
        messageRate = 0,
        messages = {},  -- Ring buffer of recent messages
        maxMessages = 50,
    }
end

--- Update Twitch receiver (call each frame)
--- @param tw table Twitch receiver
function External.updateTwitch(tw)
    OSC.update(tw.osc)

    local msg = OSC.get(tw.osc, "/twitch/message", nil)
    if msg and msg ~= tw.lastMessage then
        tw.lastMessage = msg
        tw.lastUser = OSC.get(tw.osc, "/twitch/user", "")

        -- Add to ring buffer
        table.insert(tw.messages, {
            text = msg,
            user = tw.lastUser,
            time = love and love.timer.getTime() or os.time()
        })
        if #tw.messages > tw.maxMessages then
            table.remove(tw.messages, 1)
        end
    end

    tw.messageCount = OSC.get(tw.osc, "/twitch/count", 0)
    tw.messageRate = OSC.get(tw.osc, "/twitch/rate", 0)
end

--- Get latest message
--- @param tw table Twitch receiver
--- @return string, string Message text and username
function External.getMessage(tw)
    return tw.lastMessage, tw.lastUser
end

--- Get message rate (messages per second)
--- @param tw table Twitch receiver
--- @return number Messages per second
function External.getRate(tw)
    return tw.messageRate
end

--- Get message count
--- @param tw table Twitch receiver
--- @return number Total message count
function External.getCount(tw)
    return tw.messageCount
end

--- Get recent messages
--- @param tw table Twitch receiver
--- @param n number|nil Number of messages (default all)
--- @return table Array of {text, user, time}
function External.getMessages(tw, n)
    n = n or #tw.messages
    local result = {}
    local start = math.max(1, #tw.messages - n + 1)
    for i = start, #tw.messages do
        result[#result + 1] = tw.messages[i]
    end
    return result
end

--- Create a Stream from Twitch message rate
--- @param tw table Twitch receiver
--- @return table Stream
function External.twitchRateStream(tw)
    return {
        sample = function(t, ctx)
            return tw.messageRate
        end,
        delta = nil,
        events = nil
    }
end

--- Create a Stream that fires events on new messages
--- @param tw table Twitch receiver
--- @return table Stream with events
function External.twitchMessageStream(tw)
    local lastCount = tw.messageCount

    return {
        sample = function(t, ctx)
            return tw.messageCount
        end,
        delta = nil,
        events = function(t, ctx, window)
            local count = tw.messageCount
            if count > lastCount then
                local diff = count - lastCount
                lastCount = count
                local i = 0
                return function()
                    i = i + 1
                    if i <= diff then
                        return t
                    end
                    return nil
                end
            end
            return function() return nil end
        end
    }
end

--------------------------------------------------------------------------------
-- GENERIC OSC SOURCE
--------------------------------------------------------------------------------

--- Create a generic OSC receiver for any external bridge
--- @param port number OSC port
--- @param addresses table|nil List of addresses to track
--- @return table OSC receiver
function External.osc(port, addresses)
    return {
        _type = "osc",
        osc = OSC.new(port),
        addresses = addresses or {},
    }
end

--- Update generic OSC receiver
--- @param receiver table OSC receiver
function External.updateOSC(receiver)
    OSC.update(receiver.osc)
end

--- Get value from OSC address
--- @param receiver table OSC receiver
--- @param address string OSC address
--- @param default any Default value
--- @return any Value
function External.getOSC(receiver, address, default)
    return OSC.get(receiver.osc, address, default)
end

--- Create a Stream from an OSC address
--- @param receiver table OSC receiver
--- @param address string OSC address
--- @param default number Default value
--- @return table Stream
function External.oscStream(receiver, address, default)
    default = default or 0
    return {
        sample = function(t, ctx)
            return OSC.get(receiver.osc, address, default)
        end,
        delta = nil,
        events = nil
    }
end

--------------------------------------------------------------------------------
-- UNIFIED UPDATE
--------------------------------------------------------------------------------

--- Update any external receiver
--- @param receiver table External receiver
function External.update(receiver)
    if receiver._type == "twitch" then
        External.updateTwitch(receiver)
    elseif receiver._type == "osc" then
        External.updateOSC(receiver)
    end
end

--------------------------------------------------------------------------------
-- STREAM FACTORIES
--------------------------------------------------------------------------------

--- Create a Stream from any external source
--- @param receiver table External receiver
--- @param key string What to stream ("rate", "count", "message", or OSC address)
--- @return table Stream
function External.stream(receiver, key)
    if receiver._type == "twitch" then
        if key == "rate" then
            return External.twitchRateStream(receiver)
        elseif key == "count" or key == "message" then
            return External.twitchMessageStream(receiver)
        end
    elseif receiver._type == "osc" then
        return External.oscStream(receiver, key, 0)
    end

    -- Fallback: constant zero
    return Stream.fromCurve(function() return 0 end)
end

return External
