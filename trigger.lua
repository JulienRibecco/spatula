--- Spatula Trigger Module
--- @module spatula.trigger
---
--- ============================================================================
--- Trigger = timing × selection → action
--- ============================================================================
---
--- Triggers have TWO independent axes:
---
---   TIMING:     When to fire
---               interval, probability, once, burst, times
---
---   SELECTION:  Which points to act on
---               all, random, sequential, first, last, where
---
--- These compose independently:
---
---   timing.interval(0.5) + select.random(3)
---   → every 0.5 seconds, pick 3 random points
---
---   timing.burst(5, 0.1, 2) + select.sequential()
---   → burst of 5 shots, 0.1s apart, then wait 2s, cycling through points
---
--- ============================================================================

local Util = require("spatula.util")
local floor, min, max = Util.floor, Util.min, Util.max
local random = Util.random

local Trigger = {}

-- Reusable index array for random selection
local indexPool = {}

--------------------------------------------------------------------------------
-- SELECTION STRATEGIES
-- Given a list of points, which ones to act on?
-- Returns an iterator factory: fn(points) → iterator
--------------------------------------------------------------------------------

Trigger.select = {}

function Trigger.select.all()
    return function(points)
        local i = 0
        return function()
            i = i + 1
            if i <= #points then
                local p = points[i]
                return i, p.x, p.y
            end
        end
    end
end

function Trigger.select.random(n)
    n = n or 1
    -- Reuse index array from pool
    local indices = table.remove(indexPool) or {}

    return function(points)
        local len = #points
        local count = min(n, len)

        -- Fisher-Yates partial shuffle: O(n) instead of O(n*k)
        -- Fill indices 1..len
        for i = 1, len do
            indices[i] = i
        end

        -- Shuffle first 'count' elements
        for i = 1, count do
            local j = i + floor(random() * (len - i + 1))
            indices[i], indices[j] = indices[j], indices[i]
        end

        local i = 0
        return function()
            i = i + 1
            if i <= count then
                local idx = indices[i]
                local p = points[idx]
                return idx, p.x, p.y
            else
                -- Return array to pool when done
                indexPool[#indexPool + 1] = indices
            end
        end
    end
end

function Trigger.select.sequential()
    local cur = 0
    return function(points)
        cur = (cur % #points) + 1
        local called = false
        return function()
            if not called then
                called = true
                local p = points[cur]
                return cur, p.x, p.y
            end
        end
    end
end

function Trigger.select.first(n)
    n = n or 1
    return function(points)
        local i = 0
        return function()
            i = i + 1
            if i <= n and i <= #points then
                local p = points[i]
                return i, p.x, p.y
            end
        end
    end
end

function Trigger.select.last(n)
    n = n or 1
    return function(points)
        local start = max(1, #points - n + 1)
        local i = start - 1
        return function()
            i = i + 1
            if i <= #points then
                local p = points[i]
                return i, p.x, p.y
            end
        end
    end
end

function Trigger.select.where(predicate)
    return function(points)
        local i = 0
        return function()
            while true do
                i = i + 1
                if i > #points then return nil end
                local p = points[i]
                if predicate(p, i) then
                    return i, p.x, p.y
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- TIMING STRATEGIES
-- When should the trigger fire?
-- Returns: fn(t, dt, ctx) → bool
--
-- All timing strategies accept an optional clockStream parameter.
-- If provided, time is sampled from the stream instead of wall-clock.
-- This enables tempo-synced, text-position-synced, or externally-controlled timing.
--------------------------------------------------------------------------------

Trigger.timing = {}

-- Helper: extract time from clock stream or use wall-clock
local function getClockTime(clockStream, t, dt, ctx)
    if not clockStream then
        return t
    end
    -- Stream interface: { sample = fn(t, ctx) → value }
    if type(clockStream.sample) == "function" then
        return clockStream.sample(t, ctx)
    end
    -- Direct curve: fn(t, ctx) → value or {t, dt}
    if type(clockStream) == "function" then
        local result = clockStream(t, ctx)
        if type(result) == "table" and result.t then
            return result.t
        end
        return result or t
    end
    return t
end

function Trigger.timing.interval(sec, clockStream)
    local last = -sec
    return function(t, dt, ctx)
        local effectiveT = getClockTime(clockStream, t, dt, ctx)
        if effectiveT - last >= sec then
            last = effectiveT
            return true
        end
        return false
    end
end

function Trigger.timing.probability(ch)
    return function()
        return random() < ch
    end
end

function Trigger.timing.once(delay, clockStream)
    local fired = false
    return function(t, dt, ctx)
        local effectiveT = getClockTime(clockStream, t, dt, ctx)
        if not fired and effectiveT >= delay then
            fired = true
            return true
        end
        return false
    end
end

function Trigger.timing.times(n, interval, clockStream)
    local count = 0
    local last = -interval
    return function(t, dt, ctx)
        local effectiveT = getClockTime(clockStream, t, dt, ctx)
        if count < n and effectiveT - last >= interval then
            last = effectiveT
            count = count + 1
            return true
        end
        return false
    end
end

function Trigger.timing.burst(burstCount, burstInterval, burstDelay, clockStream)
    local inBurst = false
    local burstRemaining = 0
    local lastBurst = -burstDelay
    local lastFire = 0

    return function(t, dt, ctx)
        local effectiveT = getClockTime(clockStream, t, dt, ctx)
        if not inBurst then
            if effectiveT - lastBurst >= burstDelay then
                inBurst = true
                burstRemaining = burstCount
                lastBurst = effectiveT
            else
                return false
            end
        end

        if inBurst and burstRemaining > 0 then
            if burstRemaining == burstCount or effectiveT - lastFire >= burstInterval then
                lastFire = effectiveT
                burstRemaining = burstRemaining - 1
                if burstRemaining == 0 then
                    inBurst = false
                end
                return true
            end
        end

        return false
    end
end

-- Event-based timing: fires when stream produces events
-- Useful for beat detection, word boundaries, etc.
function Trigger.timing.onEvent(eventStream)
    local lastEventTime = -1
    return function(t, dt, ctx)
        if not eventStream or not eventStream.events then
            return false
        end
        for eventTime in eventStream.events(t, ctx, dt) do
            if eventTime > lastEventTime then
                lastEventTime = eventTime
                return true
            end
        end
        return false
    end
end

-- Phase-based timing: fires when phase crosses threshold
-- Useful for tempo sync (fires on beat 1, etc.)
function Trigger.timing.onPhase(clockStream, threshold)
    threshold = threshold or 0
    local lastPhase = nil
    return function(t, dt, ctx)
        local phase = getClockTime(clockStream, t, dt, ctx)
        -- Normalize to 0-1
        local normPhase = phase % 1

        if lastPhase == nil then
            lastPhase = normPhase
            return false
        end

        -- Check if we crossed the threshold
        local crossed = (lastPhase < threshold and normPhase >= threshold) or
                        (lastPhase > normPhase and normPhase >= threshold)  -- wrap-around
        lastPhase = normPhase
        return crossed
    end
end

--------------------------------------------------------------------------------
-- TRIGGER OBJECT
-- Combines timing + selection + action into an updatable unit.
--------------------------------------------------------------------------------

function Trigger.new(cfg)
    return {
        select = cfg.select or Trigger.select.all(),
        timing = cfg.timing or Trigger.timing.interval(1),
        action = cfg.action or function() end,
        batchAction = cfg.batchAction,  -- Optional: fn(results, count, t, dt)
        enabled = cfg.enabled ~= false,
        -- Preallocated context for reuse
        _ctx = { idx = 0, total = 0, t = 0, dt = 0 },
        -- Preallocated batch results
        _batch = cfg.batchAction and {} or nil,
    }
end

function Trigger.update(tr, points, t, dt, ctx)
    if not tr.enabled then return end
    local total = #points
    if total == 0 then return end

    if not tr.timing(t, dt, ctx) then return end

    -- Batch mode: collect all selected points, call once
    if tr.batchAction then
        local batch = tr._batch
        local count = 0
        for idx, x, y in tr.select(points, ctx) do
            count = count + 1
            local entry = batch[count]
            if not entry then
                entry = {}
                batch[count] = entry
            end
            entry.idx = idx
            entry.x = x
            entry.y = y
        end
        if count > 0 then
            tr.batchAction(batch, count, t, dt)
        end
        return
    end

    -- Standard mode: reuse context table
    local actionCtx = tr._ctx
    actionCtx.total = total
    actionCtx.t = t
    actionCtx.dt = dt

    for idx, x, y in tr.select(points, ctx) do
        actionCtx.idx = idx
        tr.action(x, y, actionCtx)
    end
end

--------------------------------------------------------------------------------
-- LOAD OPTIMIZATIONS
--------------------------------------------------------------------------------

local ok, opt = pcall(require, "opt")
if ok and opt.patchTrigger then
    opt.patchTrigger(Trigger)
end

return Trigger
