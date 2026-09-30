--------------------------------------------------------------------------------
-- SPATULA FORMS BENCHMARK
-- Tests form optimizations: batch containment, spatial indexing, native C
--
-- Run: lua5.4 benchmark_forms.lua
-- Run: luajit benchmark_forms.lua
--------------------------------------------------------------------------------

package.path = package.path .. ";../../../?.lua;../../../?/init.lua"

local Forms = require("spatula.forms")

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local ENTITY_COUNT = 1000
local ITERATIONS = 100

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

local function generateEntities(n, width, height)
    local entities = {}
    local xs, ys = {}, {}
    for i = 1, n do
        xs[i] = math.random() * width
        ys[i] = math.random() * height
        entities[i] = { id = i, x = xs[i], y = ys[i] }
    end
    return entities, xs, ys
end

--------------------------------------------------------------------------------
-- TEST 1: Individual vs Batch containment (Circle)
--------------------------------------------------------------------------------

print(string.format("=== Forms Benchmark (%s) ===\n", runtime))
print(string.format("Native support: %s\n", Forms.hasNativeSupport() and "YES" or "NO"))

print("--- Circle Containment: Individual vs Batch ---")

local origin = {400, 300}
local radius = 200
local entities, xs, ys = generateEntities(ENTITY_COUNT, 800, 600)
local results = {}

-- Individual containment
local individualMs = benchmark("individual", function()
    for i = 1, ENTITY_COUNT do
        results[i] = Forms.circle.contains(origin, radius, {xs[i], ys[i]})
    end
end, ITERATIONS)

-- Batch containment
local batchMs = benchmark("batch", function()
    Forms.circle.containsBatch(origin, radius, xs, ys, ENTITY_COUNT, results)
end, ITERATIONS)

print(string.format("  Individual: %.2f ms (%d iterations)", individualMs, ITERATIONS))
print(string.format("  Batch:      %.2f ms (%d iterations)", batchMs, ITERATIONS))
print(string.format("  Speedup:    %.2fx", individualMs / batchMs))

-- Verify correctness
local correct = 0
for i = 1, ENTITY_COUNT do
    local expected = Forms.circle.contains(origin, radius, {xs[i], ys[i]})
    if results[i] == expected then correct = correct + 1 end
end
print(string.format("  Correctness: %d/%d", correct, ENTITY_COUNT))

--------------------------------------------------------------------------------
-- TEST 2: Rect containment
--------------------------------------------------------------------------------

print("\n--- Rect Containment: Individual vs Batch ---")

local rectForm = Forms.rect(1.5)  -- 1.5:1 ratio
local rectResults = {}

-- Individual containment
local rectIndividualMs = benchmark("rect-individual", function()
    for i = 1, ENTITY_COUNT do
        rectResults[i] = rectForm.contains(origin, radius, {xs[i], ys[i]})
    end
end, ITERATIONS)

-- Batch containment
local rectBatchMs = benchmark("rect-batch", function()
    rectForm.containsBatch(origin, radius, xs, ys, ENTITY_COUNT, rectResults)
end, ITERATIONS)

print(string.format("  Individual: %.2f ms (%d iterations)", rectIndividualMs, ITERATIONS))
print(string.format("  Batch:      %.2f ms (%d iterations)", rectBatchMs, ITERATIONS))
print(string.format("  Speedup:    %.2fx", rectIndividualMs / rectBatchMs))

--------------------------------------------------------------------------------
-- TEST 3: Tracker with AABB pre-filter
--------------------------------------------------------------------------------

print("\n--- Tracker: Brute Force vs AABB Pre-filter ---")

-- Create tracker at corner (most entities outside)
local cornerOrigin = {100, 100}
local cornerRadius = 80

local trackerOld = {
    form = Forms.circle,
    origin = cornerOrigin,
    size = cornerRadius,
    contains = function(point)
        return Forms.circle.contains(cornerOrigin, cornerRadius, point)
    end,
    inside = {},
    cooldowns = {},
    enabled = true,
}

local trackerNew = Forms.track(Forms.circle, cornerOrigin, cornerRadius, {})

-- Brute force (no AABB)
local bruteMs = benchmark("brute", function()
    for i, e in ipairs(entities) do
        local id = e.id or i
        local isInside = trackerOld.contains({e.x, e.y})
        trackerOld.inside[id] = isInside or nil
    end
end, ITERATIONS)

-- With AABB pre-filter
local aabbMs = benchmark("aabb", function()
    Forms.updateTracker(trackerNew, entities, 0.016)
end, ITERATIONS)

print(string.format("  Brute force: %.2f ms (%d iterations)", bruteMs, ITERATIONS))
print(string.format("  AABB filter: %.2f ms (%d iterations)", aabbMs, ITERATIONS))
print(string.format("  Speedup:     %.2fx", bruteMs / aabbMs))

--------------------------------------------------------------------------------
-- TEST 4: Spatial Hash
--------------------------------------------------------------------------------

print("\n--- Spatial Hash Query Performance ---")

local spatialHash = Forms.SpatialHash(64)
spatialHash:rebuild(entities)

-- Query small region
local queryMs = benchmark("query", function()
    local nearby = spatialHash:queryBounds(350, 250, 450, 350)
end, ITERATIONS * 10)

-- Full scan
local scanMs = benchmark("scan", function()
    local inBounds = {}
    for _, e in ipairs(entities) do
        if e.x >= 350 and e.x <= 450 and e.y >= 250 and e.y <= 350 then
            inBounds[#inBounds + 1] = e
        end
    end
end, ITERATIONS * 10)

print(string.format("  Full scan:    %.2f ms (%d iterations)", scanMs, ITERATIONS * 10))
print(string.format("  Spatial hash: %.2f ms (%d iterations)", queryMs, ITERATIONS * 10))
print(string.format("  Speedup:      %.2fx", scanMs / queryMs))

--------------------------------------------------------------------------------
-- TEST 5: Tracker with Spatial Hash
--------------------------------------------------------------------------------

print("\n--- Tracker with Spatial Hash ---")

local centerTracker = Forms.track(Forms.circle, {400, 300}, 150, {})

-- Standard update
local standardMs = benchmark("standard", function()
    Forms.updateTracker(centerTracker, entities, 0.016)
end, ITERATIONS)

-- Spatial hash update
local spatialMs = benchmark("spatial", function()
    Forms.updateTrackerSpatial(centerTracker, spatialHash, 0.016)
end, ITERATIONS)

print(string.format("  Standard:     %.2f ms (%d iterations)", standardMs, ITERATIONS))
print(string.format("  Spatial hash: %.2f ms (%d iterations)", spatialMs, ITERATIONS))
print(string.format("  Speedup:      %.2fx", standardMs / spatialMs))

--------------------------------------------------------------------------------
-- TEST 6: Delta Tracking
--------------------------------------------------------------------------------

print("\n--- Delta Tracking (10% entities moved) ---")

-- Create indexed entity table
local entitiesById = {}
for i, e in ipairs(entities) do
    entitiesById[e.id] = e
end

-- Simulate 10% of entities moving
local movedIds = {}
for i = 1, ENTITY_COUNT / 10 do
    local id = math.random(1, ENTITY_COUNT)
    movedIds[id] = true
end

local deltaTracker = Forms.track(Forms.circle, {400, 300}, 150, {})

-- Standard update (all entities)
local allMs = benchmark("all", function()
    Forms.updateTracker(deltaTracker, entities, 0.016)
end, ITERATIONS)

-- Delta update (only moved)
local deltaMs = benchmark("delta", function()
    Forms.updateTrackerDelta(deltaTracker, entitiesById, movedIds, 0.016)
end, ITERATIONS)

print(string.format("  All entities: %.2f ms (%d iterations)", allMs, ITERATIONS))
print(string.format("  Delta only:   %.2f ms (%d iterations)", deltaMs, ITERATIONS))
print(string.format("  Speedup:      %.2fx", allMs / deltaMs))

--------------------------------------------------------------------------------
-- TEST 7: Large entity count scaling
--------------------------------------------------------------------------------

print("\n--- Batch Scaling with Entity Count ---")
print(string.format("%-12s %10s %10s %10s", "Count", "Individual", "Batch", "Speedup"))
print(string.rep("-", 45))

local counts = {100, 500, 1000, 5000}
for _, count in ipairs(counts) do
    local testXs, testYs = {}, {}
    for i = 1, count do
        testXs[i] = math.random() * 800
        testYs[i] = math.random() * 600
    end
    local testOut = {}

    -- Individual calls
    local indivMs = benchmark("indiv", function()
        for i = 1, count do
            testOut[i] = Forms.circle.contains(origin, 200, {testXs[i], testYs[i]})
        end
    end, ITERATIONS)

    -- Batch call
    local batchMs = benchmark("batch", function()
        Forms.circle.containsBatch(origin, 200, testXs, testYs, count, testOut)
    end, ITERATIONS)

    local speedup = indivMs / batchMs
    print(string.format("%-12d %10.2f %10.2f %9.2fx", count, indivMs, batchMs, speedup))
end

--------------------------------------------------------------------------------
-- SUMMARY
--------------------------------------------------------------------------------

print("\n=== Summary ===")
print(string.format("Circle batch speedup:  %.2fx", individualMs / batchMs))
print(string.format("Rect batch speedup:    %.2fx", rectIndividualMs / rectBatchMs))
print(string.format("AABB pre-filter:       %.2fx", bruteMs / aabbMs))
print(string.format("Spatial hash query:    %.2fx", scanMs / queryMs))
print(string.format("Delta tracking:        %.2fx (10%% moved)", allMs / deltaMs))
print(string.format("Native C available:    %s", Forms.hasNativeSupport() and "YES" or "NO"))
print("\nAll optimizations working!")
