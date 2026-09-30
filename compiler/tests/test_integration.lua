-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--------------------------------------------------------------------------------
-- SPATULA INTEGRATION TEST
-- Compares raw vs compiled: correctness and performance
--
-- Run from compiler/tests: lua5.4 test_integration.lua
--------------------------------------------------------------------------------

-- Setup paths (run from compiler/tests/)
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"

-- Must require compiled.lua FIRST - it patches Curve and Motion
local Compiled = require("spatula.compiled")
local Curve = require("spatula.curve")
local Motion = require("spatula.motion")

--------------------------------------------------------------------------------
-- TEST UTILITIES
--------------------------------------------------------------------------------

local EPSILON = 1e-6
local EVAL_COUNT = 10000

local function approxEqual(a, b, eps)
    eps = eps or EPSILON
    return math.abs(a - b) < eps
end

local function clock()
    return os.clock()
end

local function formatNum(n)
    return string.format("%.2f", n)
end

--------------------------------------------------------------------------------
-- TEST CASES
--------------------------------------------------------------------------------

local tests = {}

-- Curves
tests[#tests + 1] = {
    name = "Curve.sin(1, 100)",
    create = function() return Curve.sin(1, 100) end,
    isMotion = false,
}

tests[#tests + 1] = {
    name = "Curve.cos(0.5, 50)",
    create = function() return Curve.cos(0.5, 50) end,
    isMotion = false,
}

tests[#tests + 1] = {
    name = "Curve.add(sin, cos)",
    create = function()
        return Curve.add(Curve.sin(1, 100), Curve.cos(2, 50))
    end,
    isMotion = false,
}

tests[#tests + 1] = {
    name = "Curve.scale(sin, 2)",
    create = function()
        return Curve.scale(Curve.sin(1, 50), 2)
    end,
    isMotion = false,
}

tests[#tests + 1] = {
    name = "Curve.timeScale(sin, 0.5)",
    create = function()
        return Curve.timeScale(Curve.sin(1, 100), 0.5)
    end,
    isMotion = false,
}

-- Motions
tests[#tests + 1] = {
    name = "Motion.circle(100, 0.5)",
    create = function() return Motion.circle(100, 0.5) end,
    isMotion = true,
}

tests[#tests + 1] = {
    name = "Motion.ellipse(100, 60, 0.5)",
    create = function() return Motion.ellipse(100, 60, 0.5) end,
    isMotion = true,
}

tests[#tests + 1] = {
    name = "Motion.figure8(50, 1)",
    create = function() return Motion.figure8(50, 1) end,
    isMotion = true,
}

tests[#tests + 1] = {
    name = "Motion.shake(10, 5)",
    create = function() return Motion.shake(10, 5) end,
    isMotion = true,
}

tests[#tests + 1] = {
    name = "Motion.lissajous(0.5, 0.75, 60, 40, 0)",
    create = function() return Motion.lissajous(0.5, 0.75, 60, 40, 0) end,
    isMotion = true,
}

tests[#tests + 1] = {
    name = "Motion.hover(20, 2)",
    create = function() return Motion.hover(20, 2) end,
    isMotion = true,
}

tests[#tests + 1] = {
    name = "Motion.sway(30, 1)",
    create = function() return Motion.sway(30, 1) end,
    isMotion = true,
}

tests[#tests + 1] = {
    name = "Motion.bob(25, 1.5)",
    create = function() return Motion.bob(25, 1.5) end,
    isMotion = true,
}

tests[#tests + 1] = {
    name = "Motion.add(circle, shake)",
    create = function()
        return Motion.add(
            Motion.circle(50, 0.5),
            Motion.shake(5, 10)
        )
    end,
    isMotion = true,
}

tests[#tests + 1] = {
    name = "Motion.scale(circle, 2)",
    create = function()
        return Motion.scale(Motion.circle(50, 0.5), 2)
    end,
    isMotion = true,
}

tests[#tests + 1] = {
    name = "Motion.rotate(circle, linear)",
    create = function()
        return Motion.rotate(
            Motion.circle(50, 1),
            Curve.linear(0.1)
        )
    end,
    isMotion = true,
}

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------

print("=== Spatula Integration Test ===")
print(string.format("Testing %d compositions with %d evaluations each\n", #tests, EVAL_COUNT))

-- Reset any previous state
Compiled.reset()

-- Create all compositions (this registers them)
local compositions = {}
for i, test in ipairs(tests) do
    compositions[i] = test.create()
end

-- Generate test times
local times = {}
for i = 1, EVAL_COUNT do
    times[i] = (i - 1) / 60  -- 0, 1/60, 2/60, ...
end

--------------------------------------------------------------------------------
-- PHASE 1: Evaluate with RAW functions (before build)
--------------------------------------------------------------------------------

print("Phase 1: Evaluating with raw functions...")

local rawResults = {}
local rawTimes = {}

for i, test in ipairs(tests) do
    local fn = compositions[i]
    local results = {}
    local ctx = {}

    local t0 = clock()
    for j, t in ipairs(times) do
        if test.isMotion then
            local x, y = fn(t, ctx)
            results[j] = { x = x, y = y }
        else
            results[j] = fn(t, ctx)
        end
    end
    local elapsed = clock() - t0

    rawResults[i] = results
    rawTimes[i] = elapsed
end

--------------------------------------------------------------------------------
-- PHASE 2: Build (compile all)
--------------------------------------------------------------------------------

print("Phase 2: Compiling...")
-- Disable pooling for correctness test (pools use stepped time, not arbitrary t)
local buildStats = Compiled.build({ silent = true, pool = false })
print(string.format("  Compiled %d/%d in %.1fms\n",
    buildStats.compiled, buildStats.total, buildStats.time))

--------------------------------------------------------------------------------
-- PHASE 3: Evaluate with COMPILED functions (after build)
--------------------------------------------------------------------------------

print("Phase 3: Evaluating with compiled functions...")

local compiledResults = {}
local compiledTimes = {}

for i, test in ipairs(tests) do
    local fn = compositions[i]
    local results = {}
    local ctx = {}

    local t0 = clock()
    for j, t in ipairs(times) do
        if test.isMotion then
            local x, y = fn(t, ctx)
            results[j] = { x = x, y = y }
        else
            results[j] = fn(t, ctx)
        end
    end
    local elapsed = clock() - t0

    compiledResults[i] = results
    compiledTimes[i] = elapsed
end

--------------------------------------------------------------------------------
-- PHASE 4: Compare results
--------------------------------------------------------------------------------

print("\n=== Results ===\n")

local passed = 0
local failed = 0
local totalSpeedup = 0

for i, test in ipairs(tests) do
    local raw = rawResults[i]
    local compiled = compiledResults[i]
    local maxDiff = 0
    local allMatch = true

    for j = 1, #raw do
        if test.isMotion then
            local dx = math.abs(raw[j].x - compiled[j].x)
            local dy = math.abs(raw[j].y - compiled[j].y)
            maxDiff = math.max(maxDiff, dx, dy)
            if dx > EPSILON or dy > EPSILON then
                allMatch = false
            end
        else
            local diff = math.abs(raw[j] - compiled[j])
            maxDiff = math.max(maxDiff, diff)
            if diff > EPSILON then
                allMatch = false
            end
        end
    end

    local rawTime = rawTimes[i] * 1000
    local compiledTime = compiledTimes[i] * 1000
    local speedup = rawTime / compiledTime

    print(test.name)

    -- Show sample values
    if test.isMotion then
        print(string.format("  Raw:      (%s, %s) → (%s, %s) → (%s, %s)",
            formatNum(raw[1].x), formatNum(raw[1].y),
            formatNum(raw[math.floor(#raw/4)].x), formatNum(raw[math.floor(#raw/4)].y),
            formatNum(raw[math.floor(#raw/2)].x), formatNum(raw[math.floor(#raw/2)].y)))
        print(string.format("  Compiled: (%s, %s) → (%s, %s) → (%s, %s)",
            formatNum(compiled[1].x), formatNum(compiled[1].y),
            formatNum(compiled[math.floor(#compiled/4)].x), formatNum(compiled[math.floor(#compiled/4)].y),
            formatNum(compiled[math.floor(#compiled/2)].x), formatNum(compiled[math.floor(#compiled/2)].y)))
    else
        print(string.format("  Raw:      %s → %s → %s",
            formatNum(raw[1]), formatNum(raw[math.floor(#raw/4)]), formatNum(raw[math.floor(#raw/2)])))
        print(string.format("  Compiled: %s → %s → %s",
            formatNum(compiled[1]), formatNum(compiled[math.floor(#compiled/4)]), formatNum(compiled[math.floor(#compiled/2)])))
    end

    if allMatch then
        print(string.format("  Match: ✓ (max diff: %.6f)", maxDiff))
        passed = passed + 1
    else
        print(string.format("  Match: ✗ FAILED (max diff: %.6f)", maxDiff))
        failed = failed + 1
    end

    print(string.format("  Time: %.3fms → %.3fms (%.1fx %s)",
        rawTime, compiledTime, speedup,
        speedup > 1 and "faster" or "slower"))
    print()

    totalSpeedup = totalSpeedup + speedup
end

--------------------------------------------------------------------------------
-- SUMMARY
--------------------------------------------------------------------------------

print("=== Summary ===")
print(string.format("Tests: %d/%d passed", passed, passed + failed))
print(string.format("Average speedup: %.1fx", totalSpeedup / #tests))

if failed > 0 then
    print("\n✗ SOME TESTS FAILED")
    os.exit(1)
else
    print("\n✓ All tests passed!")
end
