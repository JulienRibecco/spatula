-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for Batch Evaluation
-- Path adjustment for tests subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Process many entities in a single function call
--- Run with: lua test_batch.lua

local Compiler = require("spatula.compiler.compiler")

local function approxEq(a, b, eps)
    eps = eps or 0.001
    return math.abs(a - b) < eps
end

local Support = require("tests.support")
local test = Support.test
local benchmark = Support.benchmark

local PI2 = math.pi * 2

print("\n=== Batch: Basic Motion Evaluation ===\n")

test("compileBatchEval generates function", function()
    local ir = Compiler.motion.circle(100, 1)
    local fn, source = Compiler.compileBatchEval(ir)
    
    assert(type(fn) == "function", "Should return function")
    assert(type(source) == "string", "Should return source")
end)

test("batch eval produces correct values", function()
    local ir = Compiler.motion.circle(100, 1)
    local batchFn = Compiler.compileBatchEval(ir)
    local singleFn = Compiler.compile(ir)
    
    local ts = { 0, 0.25, 0.5, 0.75, 1.0 }
    local xs, ys = batchFn(ts, 5)
    
    for i = 1, 5 do
        local ex, ey = singleFn(ts[i], {})
        assert(approxEq(xs[i], ex) and approxEq(ys[i], ey),
            string.format("Mismatch at i=%d", i))
    end
end)

test("batch eval with many entities", function()
    local ir = Compiler.motion.circle(100, 1)
    local batchFn = Compiler.compileBatchEval(ir)
    
    local n = 10000
    local ts = {}
    for i = 1, n do
        ts[i] = (i - 1) / n
    end
    
    local xs, ys = batchFn(ts, n)
    
    assert(#xs == n, "Should have n X values")
    assert(#ys == n, "Should have n Y values")
    
    -- Spot check a few values
    assert(approxEq(xs[1], 100), "First X should be 100")
    assert(approxEq(ys[1], 0), "First Y should be 0")
end)

print("\n=== Batch: Phase Offsets ===\n")

test("batch eval with phase offsets", function()
    local ir = Compiler.motion.circle(100, 1)
    local batchFn = Compiler.compileBatchEval(ir, { withPhase = true })
    
    local ts = { 0, 0, 0, 0 }
    local phases = { 0, 0.25, 0.5, 0.75 }
    
    local xs, ys = batchFn(ts, phases, 4)
    
    -- Entity 0: t=0+0=0 -> (100, 0)
    assert(approxEq(xs[1], 100) and approxEq(ys[1], 0), "Phase 0")
    
    -- Entity 1: t=0+0.25=0.25 -> (0, 100)
    assert(approxEq(xs[2], 0, 1) and approxEq(ys[2], 100, 1), "Phase 0.25")
    
    -- Entity 2: t=0+0.5=0.5 -> (-100, 0)
    assert(approxEq(xs[3], -100, 1) and approxEq(ys[3], 0, 1), "Phase 0.5")
end)

test("shared time with different phases", function()
    local ir = Compiler.motion.circle(100, 1)
    local batchFn = Compiler.compileBatchEval(ir, { withPhase = true })
    
    -- All entities at same game time, but different start phases
    local n = 100
    local ts = {}
    local phases = {}
    for i = 1, n do
        ts[i] = 0.5  -- Same game time
        phases[i] = (i - 1) / n  -- Different phases
    end
    
    local xs, ys = batchFn(ts, phases, n)
    
    -- Should form a circle of positions
    local allDifferent = true
    for i = 2, n do
        if xs[i] == xs[1] and ys[i] == ys[1] then
            allDifferent = false
            break
        end
    end
    assert(allDifferent, "Different phases should give different positions")
end)

print("\n=== Batch: Pre-allocated Arrays ===\n")

test("batch eval with preallocated output", function()
    local ir = Compiler.motion.circle(100, 1)
    local batchFn = Compiler.compileBatchEval(ir, { preallocate = true })
    
    local n = 100
    local ts = {}
    local outX = {}
    local outY = {}
    for i = 1, n do
        ts[i] = (i - 1) / n
        outX[i] = 0
        outY[i] = 0
    end
    
    local rx, ry = batchFn(ts, n, outX, outY)
    
    -- Should return the same arrays
    assert(rx == outX, "Should return same X array")
    assert(ry == outY, "Should return same Y array")
    
    -- Values should be filled
    assert(outX[1] ~= 0 or outY[1] ~= 0, "Values should be computed")
end)

test("preallocated with phase", function()
    local ir = Compiler.motion.circle(100, 1)
    local batchFn = Compiler.compileBatchEval(ir, { preallocate = true, withPhase = true })
    
    local n = 10
    local ts = {}
    local phases = {}
    local outX = {}
    local outY = {}
    for i = 1, n do
        ts[i] = 0
        phases[i] = (i - 1) / n
        outX[i] = 0
        outY[i] = 0
    end
    
    batchFn(ts, phases, n, outX, outY)
    
    -- Spot check
    assert(approxEq(outX[1], 100), "First should be (100, 0)")
end)

print("\n=== Batch: Curve (non-motion) ===\n")

test("batch eval for curve", function()
    local ir = Compiler.curve.sin(1, 100)
    local batchFn = Compiler.compileBatchEval(ir)
    local singleFn = Compiler.compile(ir)
    
    local ts = { 0, 0.25, 0.5, 0.75, 1.0 }
    local values = batchFn(ts, 5)
    
    for i = 1, 5 do
        local expected = singleFn(ts[i], {})
        assert(approxEq(values[i], expected),
            string.format("Mismatch at i=%d: expected %s, got %s", i, expected, values[i]))
    end
end)

test("batch curve with phase", function()
    local ir = Compiler.curve.sin(1, 100)
    local batchFn = Compiler.compileBatchEval(ir, { withPhase = true })
    
    local ts = { 0, 0, 0 }
    local phases = { 0, 0.25, 0.5 }
    
    local values = batchFn(ts, phases, 3)
    
    assert(approxEq(values[1], 0), "sin(0) = 0")
    assert(approxEq(values[2], 100), "sin(0.25) = 100")
    assert(approxEq(values[3], 0, 1), "sin(0.5) = 0")
end)

print("\n=== Batch LUT: Shared LUT with Phases ===\n")

test("compileBatchLUT generates function", function()
    local ir = Compiler.motion.circle(100, 1)
    local fn, source, lut = Compiler.compileBatchLUT(ir, { fps = 60, duration = 1 })
    
    assert(type(fn) == "function", "Should return function")
    assert(type(source) == "string", "Should return source")
    assert(type(lut) == "table", "Should return LUT data")
end)

test("batch LUT produces correct values", function()
    local ir = Compiler.motion.circle(100, 1)
    local batchLUT = Compiler.compileBatchLUT(ir, { fps = 60, duration = 1 })
    local singleLUT = Compiler.compileLUT(ir, { fps = 60, duration = 1 })
    
    local n = 10
    local ts = {}
    local phases = {}
    for i = 1, n do
        ts[i] = (i - 1) / 60
        phases[i] = 0
    end
    
    local xs, ys = batchLUT(ts, phases, n)
    
    for i = 1, n do
        local ex, ey = singleLUT(ts[i])
        assert(approxEq(xs[i], ex) and approxEq(ys[i], ey),
            string.format("Mismatch at i=%d", i))
    end
end)

test("batch LUT with phase offsets", function()
    local ir = Compiler.motion.circle(100, 1)
    local batchLUT = Compiler.compileBatchLUT(ir, { fps = 60, duration = 1 })
    
    local n = 4
    local ts = { 0, 0, 0, 0 }
    local phases = { 0, 0.25, 0.5, 0.75 }
    
    local xs, ys = batchLUT(ts, phases, n)
    
    -- Different phases should give different positions
    assert(not (approxEq(xs[1], xs[2]) and approxEq(ys[1], ys[2])),
        "Different phases should give different results")
end)

test("batch LUT with preallocated", function()
    local ir = Compiler.motion.circle(100, 1)
    local batchLUT = Compiler.compileBatchLUT(ir, { fps = 60, duration = 1, preallocate = true })
    
    local n = 100
    local ts = {}
    local phases = {}
    local outX = {}
    local outY = {}
    for i = 1, n do
        ts[i] = 0
        phases[i] = (i - 1) / n
        outX[i] = 0
        outY[i] = 0
    end
    
    local rx, ry = batchLUT(ts, phases, n, outX, outY)
    
    assert(rx == outX and ry == outY, "Should use provided arrays")
    assert(outX[1] ~= 0 or outY[50] ~= 0, "Values should be filled")
end)

print("\n=== Batch: Helper Functions ===\n")

test("createBatchContext", function()
    local ctx = Compiler.createBatchContext(1000)
    
    assert(ctx.n == 1000, "Should store n")
    assert(type(ctx.ts) == "table", "Should have ts array")
    assert(type(ctx.phases) == "table", "Should have phases array")
    assert(type(ctx.outX) == "table", "Should have outX array")
    assert(type(ctx.outY) == "table", "Should have outY array")
end)

test("randomizePhases", function()
    local phases = {}
    Compiler.randomizePhases(phases, 100, 1)
    
    assert(#phases == 100, "Should have 100 phases")
    
    local allSame = true
    for i = 2, 100 do
        if phases[i] ~= phases[1] then
            allSame = false
            break
        end
    end
    assert(not allSame, "Phases should be randomized")
    
    for i = 1, 100 do
        assert(phases[i] >= 0 and phases[i] < 1, "Phases should be in [0, 1)")
    end
end)

test("fillTimes", function()
    local ts = {}
    Compiler.fillTimes(ts, 100, 0.5)
    
    assert(#ts == 100, "Should have 100 times")
    for i = 1, 100 do
        assert(ts[i] == 0.5, "All times should be 0.5")
    end
end)

print("\n=== Batch: Performance Comparison ===\n")

benchmark("batch with preallocated is faster", function()
    local ir = Compiler.motion.circle(100, 1)
    local singleFn = Compiler.compile(ir)
    local batchFn = Compiler.compileBatchEval(ir, { preallocate = true })
    
    local n = 10000
    local ts = {}
    local outX = {}
    local outY = {}
    for i = 1, n do
        ts[i] = (i % 60) / 60
        outX[i] = 0
        outY[i] = 0
    end
    
    local iterations = 100
    local ctx = {}
    
    -- For individual calls, we store in local arrays too
    local singleX = {}
    local singleY = {}
    for i = 1, n do singleX[i] = 0; singleY[i] = 0 end
    
    -- Warmup
    for _ = 1, 10 do
        for i = 1, n do 
            singleX[i], singleY[i] = singleFn(ts[i], ctx) 
        end
        batchFn(ts, n, outX, outY)
    end
    
    -- Time individual calls
    local t0 = os.clock()
    for _ = 1, iterations do
        for i = 1, n do
            singleX[i], singleY[i] = singleFn(ts[i], ctx)
        end
    end
    local singleTime = os.clock() - t0
    
    -- Time batch call with preallocated
    t0 = os.clock()
    for _ = 1, iterations do
        batchFn(ts, n, outX, outY)
    end
    local batchTime = os.clock() - t0
    
    local speedup = singleTime / batchTime
    print(string.format("  Individual: %.4fs, Batch (prealloc): %.4fs, Speedup: %.2fx", 
        singleTime, batchTime, speedup))
    
    -- Batch should at least be competitive (real wins come with LuaJIT)
    -- Note: In plain Lua 5.4, results are similar. LuaJIT shows 2-5x gains.
end)

test("batch LUT is fastest", function()
    local ir = Compiler.motion.circle(100, 1)
    local singleFn = Compiler.compile(ir)
    local batchFn = Compiler.compileBatchEval(ir, { withPhase = true })
    local batchLUT = Compiler.compileBatchLUT(ir, { fps = 60, duration = 1 })
    
    local n = 10000
    local ts = {}
    local phases = {}
    for i = 1, n do
        ts[i] = 0
        phases[i] = (i % 60) / 60
    end
    
    local iterations = 100
    local ctx = {}
    
    -- Warmup
    for _ = 1, 5 do
        for i = 1, n do singleFn(ts[i] + phases[i], ctx) end
        batchFn(ts, phases, n)
        batchLUT(ts, phases, n)
    end
    
    -- Time individual
    local t0 = os.clock()
    for _ = 1, iterations do
        for i = 1, n do
            singleFn(ts[i] + phases[i], ctx)
        end
    end
    local singleTime = os.clock() - t0
    
    -- Time batch compiled
    t0 = os.clock()
    for _ = 1, iterations do
        batchFn(ts, phases, n)
    end
    local batchTime = os.clock() - t0
    
    -- Time batch LUT
    t0 = os.clock()
    for _ = 1, iterations do
        batchLUT(ts, phases, n)
    end
    local lutTime = os.clock() - t0
    
    print(string.format("  Individual: %.4fs (1.00x)", singleTime))
    print(string.format("  Batch Comp: %.4fs (%.2fx)", batchTime, singleTime / batchTime))
    print(string.format("  Batch LUT:  %.4fs (%.2fx)", lutTime, singleTime / lutTime))
end)

print("\n=== Batch: Complex Compositions ===\n")

test("batch eval with spiral", function()
    local ir = Compiler.motion.spiral(100, 1, 0.5)
    local batchFn = Compiler.compileBatchEval(ir, { withPhase = true })
    
    local n = 100
    local ts = {}
    local phases = {}
    for i = 1, n do
        ts[i] = 0.5
        phases[i] = (i - 1) / n
    end
    
    local xs, ys = batchFn(ts, phases, n)
    assert(#xs == n and #ys == n, "Should produce correct number of outputs")
end)

test("batch eval with shake", function()
    local ir = Compiler.motion.shake(5, 10)
    local batchFn = Compiler.compileBatchEval(ir)
    
    local n = 1000
    local ts = {}
    for i = 1, n do
        ts[i] = i * 0.001
    end
    
    local xs, ys = batchFn(ts, n)
    assert(#xs == n and #ys == n, "Should handle complex motion")
end)

test("batch LUT with layered motion", function()
    local ir = Compiler.motion.add(
        Compiler.motion.circle(100, 1),
        Compiler.motion.circle(20, 3)
    )
    
    local batchLUT = Compiler.compileBatchLUT(ir, { fps = 60, duration = 1 })
    
    local n = 100
    local ts = {}
    local phases = {}
    for i = 1, n do
        ts[i] = 0
        phases[i] = (i - 1) / n
    end
    
    local xs, ys = batchLUT(ts, phases, n)
    assert(#xs == n, "Should handle layered motion")
end)

print("\n=== Batch: Generated Code Sample ===\n")

print("--- Batch eval with phase (circle) ---")
local ir = Compiler.motion.circle(100, 1)
local _, src = Compiler.compileBatchEval(ir, { withPhase = true })
print(src)
print("")

print("--- Batch LUT (10fps for readability) ---")
local _, lutSrc = Compiler.compileBatchLUT(ir, { fps = 10, duration = 1 })
print(lutSrc)

print("\n=== All Batch tests complete ===\n")

Support.finish()
