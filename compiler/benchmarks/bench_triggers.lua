-- benchmarks/bench_triggers.lua
-- Benchmark: Trigger compiled vs interpreted
-- Run with: lua5.4 benchmarks/bench_triggers.lua

package.path = package.path .. ";../../../?.lua;../../../?/init.lua"

local IR = require("spatula.compiler.ir")
local Compiler = require("spatula.compiler.compiler")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------

local ITERATIONS = 200000
local WARMUP = 5000

--------------------------------------------------------------------------------
-- INTERPRETED (CLOSURE-BASED) TRIGGERS
--------------------------------------------------------------------------------

-- Interval trigger with selectAll
local function makeIntervalSelectAll(interval)
    return function(points, t, ctx, action)
        ctx._lastFire = ctx._lastFire or -math.huge
        if t - ctx._lastFire < interval then return end
        ctx._lastFire = t
        local n = #points
        for i = 1, n do
            local p = points[i]
            action(p.x or p[1], p.y or p[2], ctx, i, n)
        end
    end
end

-- Interval trigger with selectRandom
local function makeIntervalSelectRandom(interval, selectCount)
    return function(points, t, ctx, action)
        ctx._lastFire = ctx._lastFire or -math.huge
        if t - ctx._lastFire < interval then return end
        ctx._lastFire = t
        local n = #points
        if n == 0 then return end
        local count = math.min(selectCount, n)
        for _ = 1, count do
            local idx = math.random(1, n)
            local p = points[idx]
            action(p.x or p[1], p.y or p[2], ctx, idx, n)
        end
    end
end

-- Burst trigger with selectAll
local function makeBurstSelectAll(burstCount, interval, pause)
    return function(points, t, ctx, action)
        ctx._burstCount = ctx._burstCount or 0
        ctx._lastFire = ctx._lastFire or -math.huge
        ctx._burstStart = ctx._burstStart or 0

        local inBurst = ctx._burstCount < burstCount
        if inBurst then
            if t - ctx._lastFire < interval then return end
            ctx._lastFire = t
            ctx._burstCount = ctx._burstCount + 1
        else
            if t - ctx._burstStart < pause then return end
            ctx._burstCount = 1
            ctx._burstStart = t
            ctx._lastFire = t
        end

        local n = #points
        for i = 1, n do
            local p = points[i]
            action(p.x or p[1], p.y or p[2], ctx, i, n)
        end
    end
end

-- Times trigger with selectSequential
local function makeTimesSelectSequential(maxTimes, interval)
    return function(points, t, ctx, action)
        ctx._fireCount = ctx._fireCount or 0
        if ctx._fireCount >= maxTimes then return end
        ctx._lastFire = ctx._lastFire or -math.huge
        if t - ctx._lastFire < interval then return end
        ctx._lastFire = t
        ctx._fireCount = ctx._fireCount + 1

        local n = #points
        if n == 0 then return end
        ctx._cursor = (ctx._cursor or 0) % n + 1
        local p = points[ctx._cursor]
        action(p.x or p[1], p.y or p[2], ctx, ctx._cursor, n)
    end
end

--------------------------------------------------------------------------------
-- BENCHMARK UTILITIES
--------------------------------------------------------------------------------

local function formatOps(ops)
    if ops >= 1e6 then
        return string.format("%.2fM", ops / 1e6)
    elseif ops >= 1e3 then
        return string.format("%.1fK", ops / 1e3)
    else
        return string.format("%.0f", ops)
    end
end

local function benchmark(fn, iterations, warmup)
    warmup = warmup or WARMUP

    -- Warmup
    for i = 1, warmup do fn() end

    -- Measure
    local start = os.clock()
    for i = 1, iterations do fn() end
    local elapsed = os.clock() - start

    local ops_per_sec = iterations / elapsed
    return elapsed, ops_per_sec
end

local function runComparison(name, interpretedFn, compiledFn, iterations)
    iterations = iterations or ITERATIONS

    io.write(string.format("  %-25s", name))
    io.flush()

    local _, interpOps = benchmark(interpretedFn, iterations)
    local _, compOps = benchmark(compiledFn, iterations)
    local speedup = compOps / interpOps

    print(string.format("  %10s ops/s  %10s ops/s  %5.2fx",
        formatOps(interpOps), formatOps(compOps), speedup))

    return interpOps, compOps, speedup
end

--------------------------------------------------------------------------------
-- TEST DATA
--------------------------------------------------------------------------------

-- Generate test points
local testPoints = {}
for i = 1, 20 do
    testPoints[i] = { x = i * 10, y = i * 5 }
end

-- Dummy action
local actionCount = 0
local function dummyAction(x, y, ctx, idx, n)
    actionCount = actionCount + 1
end

--------------------------------------------------------------------------------
-- BENCHMARKS
--------------------------------------------------------------------------------

print("=== Trigger Benchmarks ===")
print(string.format("  Iterations: %d, Warmup: %d\n", ITERATIONS, WARMUP))
print(string.format("  %-25s  %14s  %14s  %s", "Test", "Interpreted", "Compiled", "Speedup"))
print(string.rep("-", 70))

local results = {}

-- Interval + selectAll
do
    local interpTrigger = makeIntervalSelectAll(0.1)
    local compTrigger = Compiler.compileTrigger(
        IR.trigger.interval(0.1),
        IR.trigger.selectAll()
    )

    local t = 0
    local ctx1, ctx2 = {}, {}

    local interpOps, compOps, speedup = runComparison("Interval + selectAll", function()
        t = t + 0.11  -- Always fire
        interpTrigger(testPoints, t, ctx1, dummyAction)
    end, function()
        t = t + 0.11
        compTrigger(testPoints, t, ctx2, dummyAction)
    end)
    results[#results + 1] = { name = "Interval+selectAll", speedup = speedup }
end

-- Interval + selectRandom
do
    local interpTrigger = makeIntervalSelectRandom(0.1, 5)
    local compTrigger = Compiler.compileTrigger(
        IR.trigger.interval(0.1),
        IR.trigger.selectRandom(5)
    )

    local t = 0
    local ctx1, ctx2 = {}, {}

    local interpOps, compOps, speedup = runComparison("Interval + selectRandom(5)", function()
        t = t + 0.11
        interpTrigger(testPoints, t, ctx1, dummyAction)
    end, function()
        t = t + 0.11
        compTrigger(testPoints, t, ctx2, dummyAction)
    end)
    results[#results + 1] = { name = "Interval+selectRandom", speedup = speedup }
end

-- Burst + selectAll
do
    local interpTrigger = makeBurstSelectAll(3, 0.05, 0.5)
    local compTrigger = Compiler.compileTrigger(
        IR.trigger.burst(3, 0.05, 0.5),
        IR.trigger.selectAll()
    )

    local t = 0
    local ctx1, ctx2 = {}, {}

    local interpOps, compOps, speedup = runComparison("Burst(3) + selectAll", function()
        t = t + 0.06
        interpTrigger(testPoints, t, ctx1, dummyAction)
    end, function()
        t = t + 0.06
        compTrigger(testPoints, t, ctx2, dummyAction)
    end)
    results[#results + 1] = { name = "Burst+selectAll", speedup = speedup }
end

-- Times + selectSequential
do
    local interpTrigger = makeTimesSelectSequential(1000000, 0.1)
    local compTrigger = Compiler.compileTrigger(
        IR.trigger.times(1000000, 0.1),
        IR.trigger.selectSequential()
    )

    local t = 0
    local ctx1, ctx2 = {}, {}

    local interpOps, compOps, speedup = runComparison("Times + selectSequential", function()
        t = t + 0.11
        interpTrigger(testPoints, t, ctx1, dummyAction)
    end, function()
        t = t + 0.11
        compTrigger(testPoints, t, ctx2, dummyAction)
    end)
    results[#results + 1] = { name = "Times+selectSeq", speedup = speedup }
end

-- Interval + selectFirst
do
    local function makeIntervalSelectFirst(interval, n)
        return function(points, t, ctx, action)
            ctx._lastFire = ctx._lastFire or -math.huge
            if t - ctx._lastFire < interval then return end
            ctx._lastFire = t
            local count = math.min(n, #points)
            for i = 1, count do
                local p = points[i]
                action(p.x or p[1], p.y or p[2], ctx, i, #points)
            end
        end
    end

    local interpTrigger = makeIntervalSelectFirst(0.1, 3)
    local compTrigger = Compiler.compileTrigger(
        IR.trigger.interval(0.1),
        IR.trigger.selectFirst(3)
    )

    local t = 0
    local ctx1, ctx2 = {}, {}

    local interpOps, compOps, speedup = runComparison("Interval + selectFirst(3)", function()
        t = t + 0.11
        interpTrigger(testPoints, t, ctx1, dummyAction)
    end, function()
        t = t + 0.11
        compTrigger(testPoints, t, ctx2, dummyAction)
    end)
    results[#results + 1] = { name = "Interval+selectFirst", speedup = speedup }
end

print(string.rep("-", 70))

-- Calculate average speedup
local totalSpeedup = 0
for _, r in ipairs(results) do
    totalSpeedup = totalSpeedup + r.speedup
end
local avgSpeedup = totalSpeedup / #results

print(string.format("\n  Average speedup: %.2fx", avgSpeedup))
