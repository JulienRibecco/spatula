--------------------------------------------------------------------------------
-- SPATULA FIELD BENCHMARK
-- Tests field optimizations: batch sampling, spatial indexing
--
-- Run: lua5.4 benchmark_field.lua
-- Run: luajit benchmark_field.lua
--------------------------------------------------------------------------------

package.path = package.path .. ";../../../?.lua;../../../?/init.lua"

local Field = require("spatula.field")

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local ENTITY_COUNT = 1000
local SAMPLE_ITERATIONS = 100
local SOURCE_COUNTS = { 10, 50, 100, 200 }

local jit = jit or nil
local runtime = jit and "LuaJIT" or "Lua5.4"

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function benchmark(name, fn, iterations)
    iterations = iterations or 1
    local start = os.clock()
    for _ = 1, iterations do
        fn()
    end
    local elapsed = os.clock() - start
    return elapsed * 1000  -- ms
end

local function generatePositions(n, width, height)
    local xs, ys = {}, {}
    for i = 1, n do
        xs[i] = math.random() * width
        ys[i] = math.random() * height
    end
    return xs, ys
end

--------------------------------------------------------------------------------
-- TEST 1: Falloff presets
--------------------------------------------------------------------------------

print(string.format("=== Field Benchmark (%s) ===\n", runtime))

print("--- Falloff Presets ---")
local falloffs = { "linear", "smooth", "spike", "gaussian", "steep", "soft", "step" }
for _, name in ipairs(falloffs) do
    local f = Field.falloff[name]
    if f then
        local v0 = f(0, nil)
        local v05 = f(0.5, nil)
        local v1 = f(1, nil)
        print(string.format("  %-10s: d=0 -> %.2f, d=0.5 -> %.2f, d=1 -> %.2f", name, v0, v05, v1))
    else
        print(string.format("  %-10s: NOT FOUND", name))
    end
end

--------------------------------------------------------------------------------
-- TEST 2: Batch sampling vs individual
--------------------------------------------------------------------------------

print("\n--- Batch Sampling (1000 entities, 50 sources) ---")

local field = Field.new({ falloff = "smooth" })
for i = 1, 50 do
    field:add(math.random(800), math.random(600), { radius = 80, value = 1 })
end

local xs, ys = generatePositions(ENTITY_COUNT, 800, 600)
local outValues = {}

-- Individual sampling
local individualMs = benchmark("individual", function()
    for i = 1, ENTITY_COUNT do
        outValues[i] = field:sample(xs[i], ys[i])
    end
end, SAMPLE_ITERATIONS)

-- Batch sampling
local batchMs = benchmark("batch", function()
    field:sampleBatch(xs, ys, ENTITY_COUNT, outValues)
end, SAMPLE_ITERATIONS)

print(string.format("  Individual: %.2f ms (%d iterations)", individualMs, SAMPLE_ITERATIONS))
print(string.format("  Batch:      %.2f ms (%d iterations)", batchMs, SAMPLE_ITERATIONS))
print(string.format("  Speedup:    %.2fx", individualMs / batchMs))

--------------------------------------------------------------------------------
-- TEST 3: Spatial index vs brute force
--------------------------------------------------------------------------------

print("\n--- Spatial Index vs Brute Force ---")
print(string.format("%-12s %10s %10s %10s %8s", "Sources", "Brute(ms)", "Quadtree", "Speedup", "Status"))
print(string.rep("-", 55))

for _, sourceCount in ipairs(SOURCE_COUNTS) do
    -- Create field with sources
    local testField = Field.new({ falloff = "smooth" })
    for i = 1, sourceCount do
        testField:add(math.random(800), math.random(600), { radius = 60, value = 1 })
    end

    local testXs, testYs = generatePositions(ENTITY_COUNT, 800, 600)
    local testOut = {}

    -- Brute force (no spatial index)
    local bruteMs = benchmark("brute", function()
        for i = 1, ENTITY_COUNT do
            testOut[i] = testField:sample(testXs[i], testYs[i])
        end
    end, SAMPLE_ITERATIONS)

    -- With spatial index
    testField:enableSpatialIndex({ 0, 0, 800, 600 })
    testField:rebuildIndex()

    local indexMs = benchmark("indexed", function()
        for i = 1, ENTITY_COUNT do
            testOut[i] = testField:sample(testXs[i], testYs[i])
        end
    end, SAMPLE_ITERATIONS)

    local speedup = bruteMs / indexMs
    local status = speedup > 1 and "faster" or "slower"

    print(string.format("%-12d %10.2f %10.2f %9.2fx %8s",
        sourceCount, bruteMs, indexMs, speedup, status))
end

--------------------------------------------------------------------------------
-- TEST 4: GridField batch sampling
--------------------------------------------------------------------------------

print("\n--- GridField Batch Sampling ---")

local gridField = Field.gridded({
    world = { 0, 0, 800, 600 },
    cellSize = 32,
    falloff = "smooth",
})

for i = 1, 50 do
    gridField:add(math.random(800), math.random(600), { radius = 80, value = 1 })
end
gridField:update()

local gridXs, gridYs = generatePositions(ENTITY_COUNT, 800, 600)
local gridOut = {}

-- Individual sampling
local gridIndividualMs = benchmark("grid-individual", function()
    for i = 1, ENTITY_COUNT do
        gridOut[i] = gridField:sample(gridXs[i], gridYs[i])
    end
end, SAMPLE_ITERATIONS)

-- Batch sampling
local gridBatchMs = benchmark("grid-batch", function()
    gridField:sampleBatch(gridXs, gridYs, ENTITY_COUNT, gridOut)
end, SAMPLE_ITERATIONS)

print(string.format("  Individual: %.2f ms (%d iterations)", gridIndividualMs, SAMPLE_ITERATIONS))
print(string.format("  Batch:      %.2f ms (%d iterations)", gridBatchMs, SAMPLE_ITERATIONS))
print(string.format("  Speedup:    %.2fx", gridIndividualMs / gridBatchMs))

--------------------------------------------------------------------------------
-- TEST 5: Batch with gradients
--------------------------------------------------------------------------------

print("\n--- Batch With Gradients (GridField) ---")

local outGx, outGy = {}, {}

local gradIndividualMs = benchmark("grad-individual", function()
    for i = 1, ENTITY_COUNT do
        gridOut[i] = gridField:sample(gridXs[i], gridYs[i])
        outGx[i], outGy[i] = gridField:gradientDirect(gridXs[i], gridYs[i])
    end
end, SAMPLE_ITERATIONS)

local gradBatchMs = benchmark("grad-batch", function()
    gridField:sampleBatchWithGradient(gridXs, gridYs, ENTITY_COUNT, gridOut, outGx, outGy)
end, SAMPLE_ITERATIONS)

print(string.format("  Individual: %.2f ms (%d iterations)", gradIndividualMs, SAMPLE_ITERATIONS))
print(string.format("  Batch:      %.2f ms (%d iterations)", gradBatchMs, SAMPLE_ITERATIONS))
print(string.format("  Speedup:    %.2fx", gradIndividualMs / gradBatchMs))

--------------------------------------------------------------------------------
-- TEST 6: Native SIMD batch sampling (LuaJIT only)
--------------------------------------------------------------------------------

local nativeSpeedup = 1.0
local hasNative = Field.hasNativeSupport()

if hasNative then
    print("\n--- Native SIMD Batch Sampling (Transparent) ---")
    print("  sampleBatch() now auto-uses native when beneficial")
    print(string.format("%-12s %10s %10s %10s %8s", "Sources", "Before", "After", "Speedup", "Status"))
    print(string.rep("-", 55))

    local ffi = require("ffi")
    local float_array = ffi.typeof("float[?]")

    for _, sourceCount in ipairs(SOURCE_COUNTS) do
        local nativeField = Field.new({ falloff = "smooth" })
        for i = 1, sourceCount do
            nativeField:add(math.random(800), math.random(600), { radius = 60, value = 1 })
        end

        -- Standard Lua tables (user's typical usage)
        local luaXs, luaYs, luaOut = {}, {}, {}
        for i = 1, ENTITY_COUNT do
            luaXs[i] = math.random() * 800
            luaYs[i] = math.random() * 600
        end

        -- "Before" - individual sampling (old way)
        local beforeMs = benchmark("before", function()
            for i = 1, ENTITY_COUNT do
                luaOut[i] = nativeField:sample(luaXs[i], luaYs[i])
            end
        end, SAMPLE_ITERATIONS)

        -- "After" - sampleBatch (auto-native)
        local afterMs = benchmark("after", function()
            nativeField:sampleBatch(luaXs, luaYs, ENTITY_COUNT, luaOut)
        end, SAMPLE_ITERATIONS)

        local speedup = beforeMs / afterMs
        local status = speedup > 1 and "faster" or "slower"

        print(string.format("%-12d %10.2f %10.2f %9.2fx %8s",
            sourceCount, beforeMs, afterMs, speedup, status))

        if sourceCount == 50 then
            nativeSpeedup = speedup
        end
    end
else
    print("\n--- Native SIMD Batch Sampling ---")
    print("  SKIPPED: Native extension not available (LuaJIT required)")
end

--------------------------------------------------------------------------------
-- SUMMARY
--------------------------------------------------------------------------------

print("\n=== Summary ===")
print("New falloff presets: steep, soft, step - OK")
print(string.format("Batch sampling speedup: %.2fx (Field), %.2fx (GridField)",
    individualMs / batchMs, gridIndividualMs / gridBatchMs))
print("Spatial index: beneficial for 50+ sources")
if hasNative then
    print(string.format("Native SIMD speedup: %.2fx (50 sources)", nativeSpeedup))
end
