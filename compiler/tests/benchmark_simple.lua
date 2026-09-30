--------------------------------------------------------------------------------
-- SPATULA SIMPLE MOTION BENCHMARK
-- Tests all common motions to identify which benefit from pooling
--
-- Run: lua5.4 benchmark_simple.lua
-- Run: luajit benchmark_simple.lua
--------------------------------------------------------------------------------

package.path = package.path .. ";../../../?.lua;../../../?/init.lua"

-- Load compiled.lua FIRST to patch Motion/Curve with IR
local Compiled = require("spatula.compiled")
local Compiler = require("spatula.compiler.compiler")
local Curve = require("spatula.curve")
local Motion = require("spatula.motion")
local Pool = require("spatula.compiler.pool")

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local ENTITY_COUNT = 1000
local FRAME_COUNT = 500
local dt = 1/60

--------------------------------------------------------------------------------
-- TEST CASES: All common primitives and simple compositions
--------------------------------------------------------------------------------

local testCases = {
    -- Curve primitives
    { name = "Curve.sin", create = function() return Curve.sin(1, 100) end, isMotion = false },
    { name = "Curve.cos", create = function() return Curve.cos(1, 100) end, isMotion = false },
    { name = "Curve.linear", create = function() return Curve.linear(1) end, isMotion = false },
    { name = "Curve.const", create = function() return Curve.const(50) end, isMotion = false },
    { name = "Curve.triangle", create = function() return Curve.triangle(1, 100) end, isMotion = false },
    { name = "Curve.saw", create = function() return Curve.saw(1, 100) end, isMotion = false },
    { name = "Curve.square", create = function() return Curve.square(1, 100) end, isMotion = false },
    { name = "Curve.noise", create = function() return Curve.noise(10, 100) end, isMotion = false },

    -- Motion primitives
    { name = "Motion.circle", create = function() return Motion.circle(100, 1) end, isMotion = true },
    { name = "Motion.ellipse", create = function() return Motion.ellipse(100, 60, 1) end, isMotion = true },
    { name = "Motion.figure8", create = function() return Motion.figure8(50, 1) end, isMotion = true },
    { name = "Motion.lissajous", create = function() return Motion.lissajous(0.5, 0.75, 60, 40, 0) end, isMotion = true },
    { name = "Motion.hover", create = function() return Motion.hover(20, 2) end, isMotion = true },
    { name = "Motion.sway", create = function() return Motion.sway(30, 1) end, isMotion = true },
    { name = "Motion.bob", create = function() return Motion.bob(25, 1.5) end, isMotion = true },
    { name = "Motion.shake", create = function() return Motion.shake(10, 5) end, isMotion = true },

    -- Simple compositions (2 levels)
    { name = "Motion.scale(circle, 2)", create = function()
        return Motion.scale(Motion.circle(50, 1), 2)
    end, isMotion = true },
    { name = "Motion.rotate(circle, 0.5)", create = function()
        return Motion.rotate(Motion.circle(50, 1), 0.5)
    end, isMotion = true },
    { name = "Curve.add(sin, cos)", create = function()
        return Curve.add(Curve.sin(1, 50), Curve.cos(2, 30))
    end, isMotion = false },
    { name = "Curve.scale(sin, 2)", create = function()
        return Curve.scale(Curve.sin(1, 50), 2)
    end, isMotion = false },

    -- Medium compositions (3 levels)
    { name = "Motion.add(circle, hover)", create = function()
        return Motion.add(Motion.circle(50, 0.5), Motion.hover(10, 2))
    end, isMotion = true },
    { name = "Motion.rotate(circle, sin)", create = function()
        return Motion.rotate(Motion.circle(50, 1), Curve.sin(0.5, 0.5))
    end, isMotion = true },

    -- Complex compositions (4+ levels)
    { name = "Motion.add(circle, shake)", create = function()
        return Motion.add(Motion.circle(50, 0.5), Motion.shake(5, 10))
    end, isMotion = true },
    { name = "scale(rotate(circle, sin), cos)", create = function()
        return Motion.scale(
            Motion.rotate(Motion.circle(50, 1), Curve.sin(0.5, 0.5)),
            Curve.offset(Curve.cos(0.25, 0.3), 1)
        )
    end, isMotion = true },
}

--------------------------------------------------------------------------------
-- BENCHMARK FUNCTION
--------------------------------------------------------------------------------

local function benchmark(name, ir, isMotion)
    -- Count nodes for complexity
    local nodeCount = Compiler.countNodes(ir)

    -- Compile function for baseline
    local compiled = Compiler.compile(ir)

    -- Create pool
    local pool = Pool.create(Compiler, ir, { count = ENTITY_COUNT, dt = dt })
    pool:initRandom()

    -- Baseline: compiled function per entity
    local phases = {}
    local times = {}
    for i = 1, ENTITY_COUNT do
        phases[i] = math.random()
        times[i] = 0
    end

    local baseStart = os.clock()
    for frame = 1, FRAME_COUNT do
        for i = 1, ENTITY_COUNT do
            times[i] = times[i] + dt
            local t = times[i] + phases[i]
            if isMotion then
                local x, y = compiled(t, {})
            else
                local v = compiled(t, {})
            end
        end
    end
    local baseTime = os.clock() - baseStart

    -- Pool: batch evaluation
    local poolStart = os.clock()
    for frame = 1, FRAME_COUNT do
        pool:step()
        -- Access results (simulate real usage)
        if isMotion then
            for i = 1, ENTITY_COUNT do
                local x, y = pool.x[i], pool.y[i]
            end
        else
            for i = 1, ENTITY_COUNT do
                local v = pool.values[i]
            end
        end
    end
    local poolTime = os.clock() - poolStart

    local speedup = baseTime / poolTime

    return {
        name = name,
        nodes = nodeCount,
        strategy = pool.strategy,
        baseMs = baseTime * 1000,
        poolMs = poolTime * 1000,
        speedup = speedup,
        beneficial = speedup > 1.0,
    }
end

--------------------------------------------------------------------------------
-- RUN BENCHMARKS
--------------------------------------------------------------------------------

local jit = jit or nil
local runtime = jit and "LuaJIT" or "Lua5.4"

print(string.format("=== Simple Motion Benchmark (%s) ===", runtime))
print(string.format("Entities: %d, Frames: %d\n", ENTITY_COUNT, FRAME_COUNT))

local results = {}
local dominated = {}  -- Cases where pool is slower

for _, test in ipairs(testCases) do
    local composition = test.create()
    local ir = Compiler.getIR(composition)
    if ir then
        local result = benchmark(test.name, ir, test.isMotion)
        results[#results + 1] = result
        if not result.beneficial then
            dominated[#dominated + 1] = result
        end
    else
        print("SKIP (no IR): " .. test.name)
    end
end

-- Sort by speedup
table.sort(results, function(a, b) return a.speedup < b.speedup end)

--------------------------------------------------------------------------------
-- RESULTS
--------------------------------------------------------------------------------

print(string.format("%-35s %5s %10s %8s %8s %7s",
    "Motion", "Nodes", "Strategy", "Base", "Pool", "Speedup"))
print(string.rep("-", 80))

for _, r in ipairs(results) do
    local marker = r.beneficial and "" or " ✗"
    print(string.format("%-35s %5d %10s %7.1fms %7.1fms %6.2fx%s",
        r.name, r.nodes, r.strategy, r.baseMs, r.poolMs, r.speedup, marker))
end

--------------------------------------------------------------------------------
-- SUMMARY
--------------------------------------------------------------------------------

print("\n=== Summary ===")
print(string.format("Total cases: %d", #results))
print(string.format("Pool beneficial: %d", #results - #dominated))
print(string.format("Pool slower: %d", #dominated))

if #dominated > 0 then
    print("\n=== Cases to skip pooling ===")
    for _, r in ipairs(dominated) do
        print(string.format("  %s (nodes=%d, speedup=%.2fx)", r.name, r.nodes, r.speedup))
    end

    -- Find threshold
    local maxSkipNodes = 0
    for _, r in ipairs(dominated) do
        if r.nodes > maxSkipNodes then maxSkipNodes = r.nodes end
    end

    local minBenefitNodes = 999
    for _, r in ipairs(results) do
        if r.beneficial and r.nodes < minBenefitNodes then
            minBenefitNodes = r.nodes
        end
    end

    print(string.format("\nSuggested threshold: skip pooling if nodes <= %d", maxSkipNodes))
    print(string.format("(All beneficial cases have nodes >= %d)", minBenefitNodes))
end
