--- spatula.stream - Unified abstraction for time-varying external data
--- @module spatula.stream
---
--- Stream provides a common interface for heterogeneous input sources:
--- - Clocks (realtime, tempo, text position)
--- - External inputs (OSC, file, MIDI)
--- - Audio analysis (beats, envelopes)
---
--- All streams can be wired to timing strategies for cross-domain sync.
---
--- Stream interface:
---   sample(t, ctx) → value       -- Current value (required)
---   delta(t, ctx) → value        -- Change since last sample (optional)
---   events(t, ctx, window) → iter -- Discrete events in window (optional)

local Stream = {}

--------------------------------------------------------------------------------
-- FACTORIES
--------------------------------------------------------------------------------

--- Wrap a curve as a stream
--- @param curve function Curve f(t, ctx) → value
--- @return table Stream
function Stream.fromCurve(curve)
    return {
        sample = curve,
        delta = nil,
        events = nil
    }
end

--- Wrap a clock {t, dt} output as a stream
--- Handles both table {t, dt} and scalar returns
--- @param clockCurve function Clock curve
--- @return table Stream with sample and delta
function Stream.fromClock(clockCurve)
    return {
        sample = function(t, ctx)
            local c = clockCurve(t, ctx)
            if type(c) == "table" then
                return c.t or 0
            end
            return c or 0
        end,
        delta = function(t, ctx)
            local c = clockCurve(t, ctx)
            if type(c) == "table" then
                return c.dt or 0
            end
            return 0
        end,
        events = nil
    }
end

--- Auto-wrap any input as a stream
--- Detects clocks ({t, dt} tables) vs plain curves
--- @param input function|table Input curve or clock
--- @return table Stream
function Stream.from(input)
    if type(input) ~= "function" then
        -- Constant value
        return {
            sample = function() return input or 0 end,
            delta = nil,
            events = nil
        }
    end

    -- Probe to detect clock vs curve
    local ok, result = pcall(input, 0, {})
    if ok and type(result) == "table" and result.t ~= nil then
        return Stream.fromClock(input)
    end

    return Stream.fromCurve(input)
end

--------------------------------------------------------------------------------
-- EVENT STREAMS
--------------------------------------------------------------------------------

--- Create stream from beat/pulse curve with threshold crossing detection
--- @param curve function Curve that outputs 0-1 pulse values
--- @param threshold number|nil Crossing threshold (default 0.5)
--- @return table Stream with events
function Stream.fromPulse(curve, threshold)
    threshold = threshold or 0.5
    local lastAbove = false
    local lastCrossTime = -1

    return {
        sample = curve,
        delta = nil,
        events = function(t, ctx, window)
            local v = curve(t, ctx)
            local above = v >= threshold

            if above and not lastAbove then
                lastAbove = true
                lastCrossTime = t
                -- Return iterator yielding this crossing
                local yielded = false
                return function()
                    if not yielded then
                        yielded = true
                        return t
                    end
                    return nil
                end
            end

            lastAbove = above
            -- Empty iterator
            return function() return nil end
        end
    }
end

--- Create stream from integer-crossing curve (fires when floor(value) changes)
--- Useful for text word index, beat counters, etc.
--- @param curve function Curve that outputs incrementing values
--- @return table Stream with events on integer crossings
function Stream.fromCounter(curve)
    local lastInt = nil

    return {
        sample = curve,
        delta = nil,
        events = function(t, ctx, window)
            local v = curve(t, ctx)
            local currentInt = math.floor(v)

            if lastInt == nil then
                lastInt = currentInt
                return function() return nil end
            end

            if currentInt ~= lastInt then
                local crossed = currentInt
                lastInt = currentInt
                local yielded = false
                return function()
                    if not yielded then
                        yielded = true
                        return t, crossed
                    end
                    return nil
                end
            end

            return function() return nil end
        end
    }
end

--------------------------------------------------------------------------------
-- COMBINATORS
--------------------------------------------------------------------------------

--- Map stream values through a function
--- @param stream table Source stream
--- @param fn function Transform function
--- @return table New stream
function Stream.map(stream, fn)
    return {
        sample = function(t, ctx)
            return fn(stream.sample(t, ctx))
        end,
        delta = stream.delta and function(t, ctx)
            return fn(stream.delta(t, ctx))
        end or nil,
        events = stream.events
    }
end

--- Scale stream values
--- @param stream table Source stream
--- @param scale number Scale factor
--- @return table New stream
function Stream.scale(stream, scale)
    return Stream.map(stream, function(v) return v * scale end)
end

--- Offset stream values
--- @param stream table Source stream
--- @param offset number Offset to add
--- @return table New stream
function Stream.offset(stream, offset)
    return Stream.map(stream, function(v) return v + offset end)
end

--- Quantize stream to discrete steps
--- @param stream table Source stream
--- @param steps number Number of steps
--- @return table New stream
function Stream.quantize(stream, steps)
    return Stream.map(stream, function(v)
        return math.floor(v * steps) / steps
    end)
end

--- Clamp stream values to range
--- @param stream table Source stream
--- @param min number Minimum value
--- @param max number Maximum value
--- @return table New stream
function Stream.clamp(stream, min, max)
    return Stream.map(stream, function(v)
        return math.max(min, math.min(max, v))
    end)
end

--- Combine two streams with a binary function
--- @param streamA table First stream
--- @param streamB table Second stream
--- @param fn function Binary combiner
--- @return table New stream
function Stream.combine(streamA, streamB, fn)
    return {
        sample = function(t, ctx)
            return fn(streamA.sample(t, ctx), streamB.sample(t, ctx))
        end,
        delta = nil,
        events = nil
    }
end

--- Merge events from multiple streams
--- @param ... table Streams to merge
--- @return table New stream with merged events
function Stream.mergeEvents(...)
    local streams = {...}

    return {
        sample = streams[1] and streams[1].sample or function() return 0 end,
        delta = nil,
        events = function(t, ctx, window)
            local iterators = {}
            for _, s in ipairs(streams) do
                if s.events then
                    iterators[#iterators + 1] = s.events(t, ctx, window)
                end
            end

            local current = 1
            return function()
                while current <= #iterators do
                    local result = iterators[current]()
                    if result then
                        return result
                    end
                    current = current + 1
                end
                return nil
            end
        end
    }
end

--------------------------------------------------------------------------------
-- UTILITIES
--------------------------------------------------------------------------------

--- Check if input looks like a stream
--- @param input any Value to check
--- @return boolean
function Stream.isStream(input)
    return type(input) == "table" and type(input.sample) == "function"
end

--- Get sample value, auto-wrapping if needed
--- @param input any Stream, curve, or value
--- @param t number Time
--- @param ctx table Context
--- @return number Value
function Stream.sample(input, t, ctx)
    if Stream.isStream(input) then
        return input.sample(t, ctx)
    elseif type(input) == "function" then
        local result = input(t, ctx)
        if type(result) == "table" and result.t then
            return result.t
        end
        return result or 0
    end
    return input or 0
end

return Stream
