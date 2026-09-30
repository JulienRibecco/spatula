-- benchmarks/bench_forms.lua
-- Benchmark: Form containment compiled vs interpreted
-- Run with: lua5.4 benchmarks/bench_forms.lua

package.path = package.path .. ";../../../?.lua;../../../?/init.lua"

local IR = require("spatula.compiler.ir")
local Compiler = require("spatula.compiler.compiler")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------

local ITERATIONS = 500000
local WARMUP = 10000

--------------------------------------------------------------------------------
-- INTERPRETED (CLOSURE-BASED) FORMS
--------------------------------------------------------------------------------

-- Circle containment via closure
local function makeCircleContains(ox, oy, r)
    local r2 = r * r
    return function(x, y)
        local dx = x - ox
        local dy = y - oy
        return dx * dx + dy * dy <= r2
    end
end

-- Rectangle containment via closure
local function makeRectContains(ox, oy, hw, hh)
    return function(x, y)
        return math.abs(x - ox) <= hw and math.abs(y - oy) <= hh
    end
end

-- Ring containment via closure
local function makeRingContains(ox, oy, outerR, innerR)
    local outer2 = outerR * outerR
    local inner2 = innerR * innerR
    return function(x, y)
        local dx = x - ox
        local dy = y - oy
        local d2 = dx * dx + dy * dy
        return d2 <= outer2 and d2 >= inner2
    end
end

-- Union of two forms
local function makeUnion(form1, form2)
    return function(x, y)
        return form1(x, y) or form2(x, y)
    end
end

-- Intersection of two forms
local function makeIntersect(form1, form2)
    return function(x, y)
        return form1(x, y) and form2(x, y)
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

-- Generate random test points
math.randomseed(12345)
local testPoints = {}
for i = 1, 1000 do
    testPoints[i] = {
        x = (math.random() - 0.5) * 300,
        y = (math.random() - 0.5) * 300
    }
end

--------------------------------------------------------------------------------
-- BENCHMARKS
--------------------------------------------------------------------------------

print("=== Form Containment Benchmarks ===")
print(string.format("  Iterations: %d, Warmup: %d\n", ITERATIONS, WARMUP))
print(string.format("  %-25s  %14s  %14s  %s", "Test", "Interpreted", "Compiled", "Speedup"))
print(string.rep("-", 70))

local results = {}

-- Circle
do
    local interpCircle = makeCircleContains(0, 0, 100)
    local compCircle = Compiler.compileForm(IR.form.circle(0, 0, 100))

    local idx = 1
    local interpOps, compOps, speedup = runComparison("Circle", function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return interpCircle(p.x, p.y)
    end, function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return compCircle(p.x, p.y)
    end)
    results[#results + 1] = { name = "Circle", speedup = speedup }
end

-- Rectangle
do
    local interpRect = makeRectContains(0, 0, 100, 80)
    local compRect = Compiler.compileForm(IR.form.rect(0, 0, 100, 80))

    local idx = 1
    local interpOps, compOps, speedup = runComparison("Rectangle", function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return interpRect(p.x, p.y)
    end, function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return compRect(p.x, p.y)
    end)
    results[#results + 1] = { name = "Rectangle", speedup = speedup }
end

-- Ring
do
    local interpRing = makeRingContains(0, 0, 100, 50)
    local compRing = Compiler.compileForm(IR.form.ring(0, 0, 100, 50))

    local idx = 1
    local interpOps, compOps, speedup = runComparison("Ring", function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return interpRing(p.x, p.y)
    end, function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return compRing(p.x, p.y)
    end)
    results[#results + 1] = { name = "Ring", speedup = speedup }
end

-- Union of two circles
do
    local circle1 = makeCircleContains(-50, 0, 80)
    local circle2 = makeCircleContains(50, 0, 80)
    local interpUnion = makeUnion(circle1, circle2)

    local compUnion = Compiler.compileForm(IR.form.union(
        IR.form.circle(-50, 0, 80),
        IR.form.circle(50, 0, 80)
    ))

    local idx = 1
    local interpOps, compOps, speedup = runComparison("Union (2 circles)", function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return interpUnion(p.x, p.y)
    end, function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return compUnion(p.x, p.y)
    end)
    results[#results + 1] = { name = "Union", speedup = speedup }
end

-- Intersection (circle and rect)
do
    local circle = makeCircleContains(0, 0, 100)
    local rect = makeRectContains(0, 0, 80, 80)
    local interpIntersect = makeIntersect(circle, rect)

    local compIntersect = Compiler.compileForm(IR.form.intersect(
        IR.form.circle(0, 0, 100),
        IR.form.rect(0, 0, 80, 80)
    ))

    local idx = 1
    local interpOps, compOps, speedup = runComparison("Intersect (circle+rect)", function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return interpIntersect(p.x, p.y)
    end, function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return compIntersect(p.x, p.y)
    end)
    results[#results + 1] = { name = "Intersect", speedup = speedup }
end

-- Complex: Ring with intersect
do
    local ring = makeRingContains(0, 0, 100, 30)
    local rect = makeRectContains(0, 0, 90, 90)
    local interpComplex = makeIntersect(ring, rect)

    local compComplex = Compiler.compileForm(IR.form.intersect(
        IR.form.ring(0, 0, 100, 30),
        IR.form.rect(0, 0, 90, 90)
    ))

    local idx = 1
    local interpOps, compOps, speedup = runComparison("Complex (ring+rect)", function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return interpComplex(p.x, p.y)
    end, function()
        local p = testPoints[idx]
        idx = idx % 1000 + 1
        return compComplex(p.x, p.y)
    end)
    results[#results + 1] = { name = "Complex", speedup = speedup }
end

print(string.rep("-", 70))

-- Calculate average speedup
local totalSpeedup = 0
for _, r in ipairs(results) do
    totalSpeedup = totalSpeedup + r.speedup
end
local avgSpeedup = totalSpeedup / #results

print(string.format("\n  Average speedup: %.2fx", avgSpeedup))
