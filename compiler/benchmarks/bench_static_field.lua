-- benchmarks/bench_static_field.lua
-- Benchmark: StaticField compiled vs closure-based field sampling
-- Run with: lua5.4 benchmarks/bench_static_field.lua

package.path = package.path .. ";../../../?.lua;../../../?/init.lua"

local IR = require("spatula.compiler.ir")
local Compiler = require("spatula.compiler.compiler")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------

local ITERATIONS = 200000
local WARMUP = 5000

--------------------------------------------------------------------------------
-- INTERPRETED (CLOSURE-BASED) FIELD SAMPLING
--------------------------------------------------------------------------------

local sqrt, exp, sin, max, min = math.sqrt, math.exp, math.sin, math.max, math.min
local PI = 3.141592653589793

-- Falloff functions (closure-based, matching Field.falloff)
local falloffs = {
    linear = function(t) return 1 - t end,
    smooth = function(t) return (1 - t) * (1 - t) end,
    spike = function(t) local v = 1 - t; return v * v * v * v end,
    gaussian = function(t) return exp(-3 * t * t) end,
    constant = function(t) return 1 end,
    ring = function(t) return sin(t * PI) end,
}

-- Single source field sampler via closure
local function makeSingleSourceSampler(ox, oy, radius, value, falloffFn)
    return function(x, y)
        local dx, dy = x - ox, y - oy
        local d = sqrt(dx * dx + dy * dy)
        if d >= radius then return 0 end
        return falloffFn(d / radius) * value
    end
end

-- Multi-source field sampler with add blend
local function makeMultiSourceSamplerAdd(sources, falloffFn)
    return function(x, y)
        local result = 0
        for i = 1, #sources do
            local src = sources[i]
            local dx, dy = x - src.x, y - src.y
            local d = sqrt(dx * dx + dy * dy)
            if d < src.radius then
                result = result + falloffFn(d / src.radius) * src.value
            end
        end
        return result
    end
end

-- Multi-source field sampler with max blend
local function makeMultiSourceSamplerMax(sources, falloffFn)
    return function(x, y)
        local result = 0
        for i = 1, #sources do
            local src = sources[i]
            local dx, dy = x - src.x, y - src.y
            local d = sqrt(dx * dx + dy * dy)
            if d < src.radius then
                local v = falloffFn(d / src.radius) * src.value
                if v > result then result = v end
            end
        end
        return result
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

-- Random test points for sampling
math.randomseed(12345)
local testPoints = {}
for i = 1, 1000 do
    testPoints[i] = {
        x = (math.random() - 0.5) * 400 + 100,
        y = (math.random() - 0.5) * 400 + 100
    }
end

--------------------------------------------------------------------------------
-- BENCHMARKS
--------------------------------------------------------------------------------

print("=== StaticField Benchmarks ===")
print(string.format("  Iterations: %d, Warmup: %d\n", ITERATIONS, WARMUP))
print(string.format("  %-25s  %14s  %14s  %s", "Test", "Interpreted", "Compiled", "Speedup"))
print(string.rep("-", 70))

local results = {}

-- Single source with smooth falloff
do
    local interpFn = makeSingleSourceSampler(100, 100, 80, 1, falloffs.smooth)
    local compFn = Compiler.compileStaticField(IR.field.static({
        sources = {{ x = 100, y = 100, radius = 80, value = 1, falloff = IR.falloff.smooth() }}
    }))

    local idx = 1
    local interpOps, compOps, speedup = runComparison("Single (smooth)", function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return interpFn(p.x, p.y)
    end, function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return compFn(p.x, p.y)
    end)
    results[#results + 1] = { name = "Single (smooth)", speedup = speedup }
end

-- Single source with linear falloff
do
    local interpFn = makeSingleSourceSampler(100, 100, 80, 1, falloffs.linear)
    local compFn = Compiler.compileStaticField(IR.field.static({
        sources = {{ x = 100, y = 100, radius = 80, value = 1, falloff = IR.falloff.linear() }}
    }))

    local idx = 1
    local interpOps, compOps, speedup = runComparison("Single (linear)", function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return interpFn(p.x, p.y)
    end, function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return compFn(p.x, p.y)
    end)
    results[#results + 1] = { name = "Single (linear)", speedup = speedup }
end

-- Single source with gaussian falloff
do
    local interpFn = makeSingleSourceSampler(100, 100, 80, 1, falloffs.gaussian)
    local compFn = Compiler.compileStaticField(IR.field.static({
        sources = {{ x = 100, y = 100, radius = 80, value = 1, falloff = IR.falloff.gaussian(3) }}
    }))

    local idx = 1
    local interpOps, compOps, speedup = runComparison("Single (gaussian)", function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return interpFn(p.x, p.y)
    end, function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return compFn(p.x, p.y)
    end)
    results[#results + 1] = { name = "Single (gaussian)", speedup = speedup }
end

-- Single source with ring falloff
do
    local interpFn = makeSingleSourceSampler(100, 100, 80, 1, falloffs.ring)
    local compFn = Compiler.compileStaticField(IR.field.static({
        sources = {{ x = 100, y = 100, radius = 80, value = 1, falloff = IR.falloff.ring() }}
    }))

    local idx = 1
    local interpOps, compOps, speedup = runComparison("Single (ring)", function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return interpFn(p.x, p.y)
    end, function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return compFn(p.x, p.y)
    end)
    results[#results + 1] = { name = "Single (ring)", speedup = speedup }
end

-- 3 sources with add blend
do
    local sources = {
        { x = 50, y = 50, radius = 60, value = 1 },
        { x = 150, y = 100, radius = 70, value = 0.8 },
        { x = 100, y = 150, radius = 50, value = 1.2 },
    }
    local interpFn = makeMultiSourceSamplerAdd(sources, falloffs.smooth)
    local compFn = Compiler.compileStaticField(IR.field.static({
        sources = {
            { x = 50, y = 50, radius = 60, value = 1, falloff = IR.falloff.smooth() },
            { x = 150, y = 100, radius = 70, value = 0.8, falloff = IR.falloff.smooth() },
            { x = 100, y = 150, radius = 50, value = 1.2, falloff = IR.falloff.smooth() },
        },
        blend = "add"
    }))

    local idx = 1
    local interpOps, compOps, speedup = runComparison("3 sources (add)", function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return interpFn(p.x, p.y)
    end, function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return compFn(p.x, p.y)
    end)
    results[#results + 1] = { name = "3 sources (add)", speedup = speedup }
end

-- 5 sources with add blend
do
    local sources = {
        { x = 50, y = 50, radius = 60, value = 1 },
        { x = 150, y = 100, radius = 70, value = 0.8 },
        { x = 100, y = 150, radius = 50, value = 1.2 },
        { x = 200, y = 50, radius = 55, value = 0.9 },
        { x = 0, y = 100, radius = 65, value = 1.1 },
    }
    local interpFn = makeMultiSourceSamplerAdd(sources, falloffs.smooth)

    local irSources = {}
    for i, s in ipairs(sources) do
        irSources[i] = { x = s.x, y = s.y, radius = s.radius, value = s.value, falloff = IR.falloff.smooth() }
    end
    local compFn = Compiler.compileStaticField(IR.field.static({
        sources = irSources,
        blend = "add"
    }))

    local idx = 1
    local interpOps, compOps, speedup = runComparison("5 sources (add)", function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return interpFn(p.x, p.y)
    end, function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return compFn(p.x, p.y)
    end, ITERATIONS / 2)
    results[#results + 1] = { name = "5 sources (add)", speedup = speedup }
end

-- 10 sources with max blend
do
    local sources = {}
    for i = 1, 10 do
        sources[i] = {
            x = (i - 1) * 30,
            y = ((i - 1) % 3) * 50,
            radius = 40 + (i % 5) * 10,
            value = 0.5 + (i % 3) * 0.3
        }
    end
    local interpFn = makeMultiSourceSamplerMax(sources, falloffs.smooth)

    local irSources = {}
    for i, s in ipairs(sources) do
        irSources[i] = { x = s.x, y = s.y, radius = s.radius, value = s.value, falloff = IR.falloff.smooth() }
    end
    local compFn = Compiler.compileStaticField(IR.field.static({
        sources = irSources,
        blend = "max"
    }))

    local idx = 1
    local interpOps, compOps, speedup = runComparison("10 sources (max)", function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return interpFn(p.x, p.y)
    end, function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return compFn(p.x, p.y)
    end, ITERATIONS / 4)
    results[#results + 1] = { name = "10 sources (max)", speedup = speedup }
end

-- Constant falloff (no computation)
do
    local interpFn = makeSingleSourceSampler(100, 100, 80, 1, falloffs.constant)
    local compFn = Compiler.compileStaticField(IR.field.static({
        sources = {{ x = 100, y = 100, radius = 80, value = 1, falloff = IR.falloff.constant() }}
    }))

    local idx = 1
    local interpOps, compOps, speedup = runComparison("Single (constant)", function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return interpFn(p.x, p.y)
    end, function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return compFn(p.x, p.y)
    end)
    results[#results + 1] = { name = "Single (constant)", speedup = speedup }
end

print(string.rep("-", 70))

-- Calculate average speedup
local totalSpeedup = 0
for _, r in ipairs(results) do
    totalSpeedup = totalSpeedup + r.speedup
end
local avgSpeedup = totalSpeedup / #results

print(string.format("\n  Average speedup: %.2fx", avgSpeedup))
