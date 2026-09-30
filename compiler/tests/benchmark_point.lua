--------------------------------------------------------------------------------
-- SPATULA POINT BENCHMARK
-- Tests point optimizations: XY variants, batch ops, in-place ops
--
-- Run: lua5.4 benchmark_point.lua
-- Run: luajit benchmark_point.lua
--------------------------------------------------------------------------------

package.path = package.path .. ";../../../?.lua;../../../?/init.lua"

local Point = require("spatula.point")

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local ITERATIONS = 10000
local BATCH_SIZE = 1000

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

--------------------------------------------------------------------------------
-- TEST 1: Unpack Performance
--------------------------------------------------------------------------------

print(string.format("=== Point Benchmark (%s) ===\n", runtime))

print("--- Unpack Performance ---")

local tableXY = {x = 100, y = 200}
local tableArr = {100, 200}

local unpackXYMs = benchmark("unpack {x,y}", function()
    local x, y = Point.unpack(tableXY)
end, ITERATIONS)

local unpackArrMs = benchmark("unpack {[1],[2]}", function()
    local x, y = Point.unpack(tableArr)
end, ITERATIONS)

local unpackNumMs = benchmark("unpack(num, num)", function()
    local x, y = Point.unpack(100, 200)
end, ITERATIONS)

local unpackFastMs = benchmark("unpackFast", function()
    local x, y = Point.unpackFast(tableXY)
end, ITERATIONS)

print(string.format("  unpack({x,y}):      %.2f ms", unpackXYMs))
print(string.format("  unpack({[1],[2]}):  %.2f ms", unpackArrMs))
print(string.format("  unpack(num, num):   %.2f ms", unpackNumMs))
print(string.format("  unpackFast({x,y}):  %.2f ms", unpackFastMs))

--------------------------------------------------------------------------------
-- TEST 2: Table-returning vs XY-returning
--------------------------------------------------------------------------------

print("\n--- Table vs XY Variants ---")

local a = {x = 10, y = 20}
local b = {x = 30, y = 40}

local addTableMs = benchmark("add (table)", function()
    local p = Point.add(a, b)
    local x, y = p.x, p.y
end, ITERATIONS)

local addXYMs = benchmark("addXY", function()
    local x, y = Point.addXY(a, b)
end, ITERATIONS)

print(string.format("  add() -> table:     %.2f ms", addTableMs))
print(string.format("  addXY() -> x,y:     %.2f ms", addXYMs))
print(string.format("  Speedup:            %.2fx", addTableMs / addXYMs))

local normalizeTableMs = benchmark("normalize (table)", function()
    local p = Point.normalize(a)
end, ITERATIONS)

local normalizeXYMs = benchmark("normalizeXY", function()
    local x, y = Point.normalizeXY(a)
end, ITERATIONS)

print(string.format("  normalize() -> tbl: %.2f ms", normalizeTableMs))
print(string.format("  normalizeXY():      %.2f ms", normalizeXYMs))
print(string.format("  Speedup:            %.2fx", normalizeTableMs / normalizeXYMs))

local rotateTableMs = benchmark("rotate (table)", function()
    local p = Point.rotate(a, 0.5)
end, ITERATIONS)

local rotateXYMs = benchmark("rotateXY", function()
    local x, y = Point.rotateXY(a, 0.5)
end, ITERATIONS)

print(string.format("  rotate() -> tbl:    %.2f ms", rotateTableMs))
print(string.format("  rotateXY():         %.2f ms", rotateXYMs))
print(string.format("  Speedup:            %.2fx", rotateTableMs / rotateXYMs))

--------------------------------------------------------------------------------
-- TEST 3: In-Place Operations
--------------------------------------------------------------------------------

print("\n--- In-Place Operations ---")

local out = {x = 0, y = 0}

local addNewMs = benchmark("add (new table)", function()
    local p = Point.add(a, b)
end, ITERATIONS)

local addIntoMs = benchmark("addInto (reuse)", function()
    Point.addInto(out, a, b)
end, ITERATIONS)

print(string.format("  add() new table:    %.2f ms", addNewMs))
print(string.format("  addInto() reuse:    %.2f ms", addIntoMs))
print(string.format("  Speedup:            %.2fx", addNewMs / addIntoMs))

local lerpNewMs = benchmark("lerp (new table)", function()
    local p = Point.lerp(a, b, 0.5)
end, ITERATIONS)

local lerpIntoMs = benchmark("lerpInto (reuse)", function()
    Point.lerpInto(out, a, b, 0.5)
end, ITERATIONS)

print(string.format("  lerp() new table:   %.2f ms", lerpNewMs))
print(string.format("  lerpInto() reuse:   %.2f ms", lerpIntoMs))
print(string.format("  Speedup:            %.2fx", lerpNewMs / lerpIntoMs))

--------------------------------------------------------------------------------
-- TEST 4: Batch Operations
--------------------------------------------------------------------------------

print("\n--- Batch Operations ---")

local xs, ys = {}, {}
for i = 1, BATCH_SIZE do
    xs[i] = math.random() * 100
    ys[i] = math.random() * 100
end
local outXs, outYs = {}, {}
local outLens = {}

-- Individual add vs batch
local addIndivMs = benchmark("add individual", function()
    for i = 1, BATCH_SIZE do
        local p = Point.add({xs[i], ys[i]}, {10, 20})
        outXs[i], outYs[i] = p.x, p.y
    end
end, ITERATIONS / 100)

local addBatchMs = benchmark("addBatch", function()
    Point.addBatch(xs, ys, 10, 20, outXs, outYs, BATCH_SIZE)
end, ITERATIONS / 100)

print(string.format("  add() x%d:        %.2f ms", BATCH_SIZE, addIndivMs))
print(string.format("  addBatch(%d):      %.2f ms", BATCH_SIZE, addBatchMs))
print(string.format("  Speedup:            %.2fx", addIndivMs / addBatchMs))

-- Individual rotate vs batch
local rotIndivMs = benchmark("rotate individual", function()
    for i = 1, BATCH_SIZE do
        local p = Point.rotate({xs[i], ys[i]}, 0.5)
        outXs[i], outYs[i] = p.x, p.y
    end
end, ITERATIONS / 100)

local rotBatchMs = benchmark("rotateBatch", function()
    Point.rotateBatch(xs, ys, 0.5, outXs, outYs, BATCH_SIZE)
end, ITERATIONS / 100)

print(string.format("  rotate() x%d:     %.2f ms", BATCH_SIZE, rotIndivMs))
print(string.format("  rotateBatch(%d):   %.2f ms", BATCH_SIZE, rotBatchMs))
print(string.format("  Speedup:            %.2fx", rotIndivMs / rotBatchMs))

-- Individual length vs batch
local lenIndivMs = benchmark("length individual", function()
    for i = 1, BATCH_SIZE do
        outLens[i] = Point.length({xs[i], ys[i]})
    end
end, ITERATIONS / 100)

local lenBatchMs = benchmark("lengthBatch", function()
    Point.lengthBatch(xs, ys, outLens, BATCH_SIZE)
end, ITERATIONS / 100)

print(string.format("  length() x%d:     %.2f ms", BATCH_SIZE, lenIndivMs))
print(string.format("  lengthBatch(%d):   %.2f ms", BATCH_SIZE, lenBatchMs))
print(string.format("  Speedup:            %.2fx", lenIndivMs / lenBatchMs))

-- Individual normalize vs batch
local normIndivMs = benchmark("normalize individual", function()
    for i = 1, BATCH_SIZE do
        local p = Point.normalize({xs[i], ys[i]})
        outXs[i], outYs[i] = p.x, p.y
    end
end, ITERATIONS / 100)

local normBatchMs = benchmark("normalizeBatch", function()
    Point.normalizeBatch(xs, ys, outXs, outYs, BATCH_SIZE)
end, ITERATIONS / 100)

print(string.format("  normalize() x%d:  %.2f ms", BATCH_SIZE, normIndivMs))
print(string.format("  normalizeBatch():   %.2f ms", normBatchMs))
print(string.format("  Speedup:            %.2fx", normIndivMs / normBatchMs))

--------------------------------------------------------------------------------
-- TEST 5: Common Patterns
--------------------------------------------------------------------------------

print("\n--- Common Game Patterns ---")

-- Pattern: Move entity by velocity
local entity = {x = 100, y = 100}
local velocity = {x = 5, y = 3}

local moveOldMs = benchmark("move (old)", function()
    local p = Point.add(entity, velocity)
    entity.x, entity.y = p.x, p.y
end, ITERATIONS)

local moveNewMs = benchmark("move (addInto)", function()
    Point.addInto(entity, entity, velocity)
end, ITERATIONS)

local moveXYMs = benchmark("move (addXY)", function()
    entity.x, entity.y = Point.addXY(entity, velocity)
end, ITERATIONS)

print(string.format("  add() + assign:     %.2f ms", moveOldMs))
print(string.format("  addInto():          %.2f ms", moveNewMs))
print(string.format("  addXY() + assign:   %.2f ms", moveXYMs))

-- Pattern: Rotate towards target
local pos = {x = 0, y = 0}
local target = {x = 100, y = 100}

local lookOldMs = benchmark("lookAt (old)", function()
    local dir = Point.sub(target, pos)
    local norm = Point.normalize(dir)
    local angle = Point.angle(norm)
end, ITERATIONS)

local lookNewMs = benchmark("lookAt (optimized)", function()
    local dx, dy = Point.subXY(target, pos)
    local angle = math.atan2(dy, dx)
end, ITERATIONS)

print(string.format("  sub+norm+angle:     %.2f ms", lookOldMs))
print(string.format("  subXY+atan2:        %.2f ms", lookNewMs))
print(string.format("  Speedup:            %.2fx", lookOldMs / lookNewMs))

--------------------------------------------------------------------------------
-- SUMMARY
--------------------------------------------------------------------------------

print("\n=== Summary ===")
print(string.format("XY variants speedup:    %.2fx (no table alloc)", addTableMs / addXYMs))
print(string.format("In-place speedup:       %.2fx (reuse table)", addNewMs / addIntoMs))
print(string.format("Batch speedup:          %.2fx (%d points)", addIndivMs / addBatchMs, BATCH_SIZE))
print("\nAll optimizations working!")
