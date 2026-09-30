-- benchmarks/bench_distributions.lua
-- Benchmark: Distribution compiled vs interpreted
-- Run with: lua5.4 benchmarks/bench_distributions.lua

package.path = package.path .. ";../../../?.lua;../../../?/init.lua"

local IR = require("spatula.compiler.ir")
local Compiler = require("spatula.compiler.compiler")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------

local ITERATIONS = 50000
local WARMUP = 2000

--------------------------------------------------------------------------------
-- INTERPRETED (CLOSURE-BASED) DISTRIBUTIONS
--------------------------------------------------------------------------------

local sin, cos, abs, random = math.sin, math.cos, math.abs, math.random
local PI2 = 6.283185307179586

-- Spiral distribution via closures
local function makeSpiralDistribution(formContains, count, turns)
    local countM1 = math.max(1, count - 1)
    return function(ox, oy, size, outX, outY)
        local n = 0
        for i = 0, count - 1 do
            local t = i / countM1
            local angle = t * turns * PI2
            local r = t * size
            local px = ox + cos(angle) * r
            local py = oy + sin(angle) * r
            if formContains(ox, oy, size, px, py) then
                n = n + 1
                outX[n] = px
                outY[n] = py
            end
        end
        return n
    end
end

-- Grid distribution via closures
local function makeGridDistribution(formContains, cols, rows)
    return function(ox, oy, size, outX, outY)
        local n = 0
        local step = (size * 2) / math.max(cols, rows)
        local startX = ox - size + step / 2
        local startY = oy - size + step / 2

        for row = 0, rows - 1 do
            for col = 0, cols - 1 do
                local px = startX + col * step
                local py = startY + row * step
                if formContains(ox, oy, size, px, py) then
                    n = n + 1
                    outX[n] = px
                    outY[n] = py
                end
            end
        end
        return n
    end
end

-- Burst distribution via closures
local function makeBurstDistribution(formContains, rays, pointsPerRay)
    return function(ox, oy, size, outX, outY)
        local n = 0
        for ray = 0, rays - 1 do
            local angle = ray * PI2 / rays
            for pt = 1, pointsPerRay do
                local r = (pt / pointsPerRay) * size
                local px = ox + cos(angle) * r
                local py = oy + sin(angle) * r
                if formContains(ox, oy, size, px, py) then
                    n = n + 1
                    outX[n] = px
                    outY[n] = py
                end
            end
        end
        return n
    end
end

-- Rings distribution via closures
local function makeRingsDistribution(formContains, ringCount, pointsPerRing)
    return function(ox, oy, size, outX, outY)
        local n = 0
        for ring = 1, ringCount do
            local r = (ring / ringCount) * size
            for pt = 0, pointsPerRing - 1 do
                local angle = pt * PI2 / pointsPerRing
                local px = ox + cos(angle) * r
                local py = oy + sin(angle) * r
                if formContains(ox, oy, size, px, py) then
                    n = n + 1
                    outX[n] = px
                    outY[n] = py
                end
            end
        end
        return n
    end
end

-- Form containment functions (closure-based, relative to origin/size)
local function circleContains(ox, oy, size, px, py)
    local dx = px - ox
    local dy = py - oy
    return dx * dx + dy * dy <= size * size
end

local function rectContains(ox, oy, size, px, py)
    return abs(px - ox) <= size and abs(py - oy) <= size
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
-- PRE-ALLOCATED OUTPUT ARRAYS
--------------------------------------------------------------------------------

local outX = {}
local outY = {}
for i = 1, 1000 do
    outX[i] = 0
    outY[i] = 0
end

--------------------------------------------------------------------------------
-- BENCHMARKS
--------------------------------------------------------------------------------

print("=== Distribution Benchmarks ===")
print(string.format("  Iterations: %d, Warmup: %d\n", ITERATIONS, WARMUP))
print(string.format("  %-25s  %14s  %14s  %s", "Test", "Interpreted", "Compiled", "Speedup"))
print(string.rep("-", 70))

local results = {}

-- Spiral (100 points, 3 turns) with circle form
do
    local interpDist = makeSpiralDistribution(circleContains, 100, 3)
    local compDist = Compiler.compileDistribution(
        IR.distribution.spiral(IR.form.circleUnit(), 100, 3)
    )

    local interpOps, compOps, speedup = runComparison("Spiral (100 pts, circle)", function()
        return interpDist(200, 200, 100, outX, outY)
    end, function()
        return compDist(200, 200, 100, outX, outY)
    end)
    results[#results + 1] = { name = "Spiral (circle)", speedup = speedup }
end

-- Spiral with rect form
do
    local interpDist = makeSpiralDistribution(rectContains, 100, 3)
    local compDist = Compiler.compileDistribution(
        IR.distribution.spiral(IR.form.rectUnit(), 100, 3)
    )

    local interpOps, compOps, speedup = runComparison("Spiral (100 pts, rect)", function()
        return interpDist(200, 200, 100, outX, outY)
    end, function()
        return compDist(200, 200, 100, outX, outY)
    end)
    results[#results + 1] = { name = "Spiral (rect)", speedup = speedup }
end

-- Grid (10x10) with circle form
do
    local interpDist = makeGridDistribution(circleContains, 10, 10)
    local compDist = Compiler.compileDistribution(
        IR.distribution.grid(IR.form.circleUnit(), 10, 10)
    )

    local interpOps, compOps, speedup = runComparison("Grid (10x10, circle)", function()
        return interpDist(200, 200, 100, outX, outY)
    end, function()
        return compDist(200, 200, 100, outX, outY)
    end)
    results[#results + 1] = { name = "Grid (circle)", speedup = speedup }
end

-- Grid (10x10) with rect form
do
    local interpDist = makeGridDistribution(rectContains, 10, 10)
    local compDist = Compiler.compileDistribution(
        IR.distribution.grid(IR.form.rectUnit(), 10, 10)
    )

    local interpOps, compOps, speedup = runComparison("Grid (10x10, rect)", function()
        return interpDist(200, 200, 100, outX, outY)
    end, function()
        return compDist(200, 200, 100, outX, outY)
    end)
    results[#results + 1] = { name = "Grid (rect)", speedup = speedup }
end

-- Burst (8 rays, 10 points/ray)
do
    local interpDist = makeBurstDistribution(circleContains, 8, 10)
    local compDist = Compiler.compileDistribution(
        IR.distribution.burst(IR.form.circleUnit(), 8, 10)
    )

    local interpOps, compOps, speedup = runComparison("Burst (8x10, circle)", function()
        return interpDist(200, 200, 100, outX, outY)
    end, function()
        return compDist(200, 200, 100, outX, outY)
    end)
    results[#results + 1] = { name = "Burst", speedup = speedup }
end

-- Rings (4 rings, 12 points/ring)
do
    local interpDist = makeRingsDistribution(circleContains, 4, 12)
    local compDist = Compiler.compileDistribution(
        IR.distribution.rings(IR.form.circleUnit(), 4, 12)
    )

    local interpOps, compOps, speedup = runComparison("Rings (4x12, circle)", function()
        return interpDist(200, 200, 100, outX, outY)
    end, function()
        return compDist(200, 200, 100, outX, outY)
    end)
    results[#results + 1] = { name = "Rings", speedup = speedup }
end

-- Large spiral (500 points)
do
    local interpDist = makeSpiralDistribution(circleContains, 500, 5)
    local compDist = Compiler.compileDistribution(
        IR.distribution.spiral(IR.form.circleUnit(), 500, 5)
    )

    local interpOps, compOps, speedup = runComparison("Spiral (500 pts)", function()
        return interpDist(200, 200, 100, outX, outY)
    end, function()
        return compDist(200, 200, 100, outX, outY)
    end, ITERATIONS / 5)  -- Fewer iterations for large test
    results[#results + 1] = { name = "Spiral (500)", speedup = speedup }
end

print(string.rep("-", 70))

-- Calculate average speedup
local totalSpeedup = 0
for _, r in ipairs(results) do
    totalSpeedup = totalSpeedup + r.speedup
end
local avgSpeedup = totalSpeedup / #results

print(string.format("\n  Average speedup: %.2fx", avgSpeedup))
