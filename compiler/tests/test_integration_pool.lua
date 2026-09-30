-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--------------------------------------------------------------------------------
-- SPATULA POOL INTEGRATION TEST
-- Tests auto-pooling: identical motions → shared pool → batch evaluation
--
-- Run from compiler/tests: lua5.4 test_integration_pool.lua
--------------------------------------------------------------------------------

-- Setup paths (run from compiler/tests/)
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"

-- Load raw motion module BEFORE compiled patches it
local RawMotion = require("spatula.motion")

-- Create raw motion function for baseline (before patching)
local sin, cos = math.sin, math.cos
local PI2 = math.pi * 2
local function rawCircle(radius, speed)
    return function(t, ctx)
        local angle = t * speed * PI2
        return cos(angle) * radius, sin(angle) * radius
    end
end

-- Now require compiled.lua - it patches Motion
local Compiled = require("spatula.compiled")
local Motion = require("spatula.motion")  -- Now returns instrumented version

--------------------------------------------------------------------------------
-- TEST UTILITIES
--------------------------------------------------------------------------------

local ENTITY_COUNT = 1000
local FRAME_COUNT = 1000

local function clock()
    return os.clock()
end

--------------------------------------------------------------------------------
-- TEST: Auto-pooling of identical motions
--------------------------------------------------------------------------------

print("=== Spatula Pool Integration Test ===")
print(string.format("Testing %d entities, %d frames\n", ENTITY_COUNT, FRAME_COUNT))

--------------------------------------------------------------------------------
-- TEST CASES: Simple to Complex
--------------------------------------------------------------------------------

local Curve = require("curve")

local testCases = {
    {
        name = "circle (simple)",
        rawFn = rawCircle(100, 0.5),
        createMotion = function() return Motion.circle(100, 0.5) end,
    },
    {
        name = "figure8 (lissajous)",
        rawFn = (function()
            local sin = math.sin
            local PI2 = math.pi * 2
            return function(t, ctx)
                local x = sin(t * 1 * PI2) * 50
                local y = sin(t * 2 * PI2) * 50
                return x, y
            end
        end)(),
        createMotion = function() return Motion.figure8(50, 1) end,
    },
    {
        name = "shake (noise)",
        rawFn = (function()
            -- Simplified noise approximation
            local function noise(t, seed)
                local x = t * 10 + seed
                return math.sin(x * 1.1) * 0.3 + math.sin(x * 2.3) * 0.3 + math.sin(x * 4.7) * 0.2
            end
            return function(t, ctx)
                return noise(t, 0) * 10, noise(t, 12345) * 10
            end
        end)(),
        createMotion = function() return Motion.shake(10, 5) end,
    },
    {
        name = "rotate(circle, linear) - complex",
        rawFn = (function()
            local sin, cos = math.sin, math.cos
            local PI2 = math.pi * 2
            return function(t, ctx)
                -- Inner circle
                local angle = t * 0.5 * PI2
                local ix, iy = cos(angle) * 50, sin(angle) * 50
                -- Rotation angle
                local rot = t * 0.1
                local c, s = cos(rot), sin(rot)
                return ix * c - iy * s, ix * s + iy * c
            end
        end)(),
        createMotion = function()
            return Motion.rotate(Motion.circle(50, 0.5), Curve.linear(0.1))
        end,
    },
    {
        name = "add(circle, shake) - composition",
        rawFn = (function()
            local sin, cos = math.sin, math.cos
            local PI2 = math.pi * 2
            local function noise(t, seed)
                local x = t * 50 + seed
                return math.sin(x * 1.1) * 0.3 + math.sin(x * 2.3) * 0.3 + math.sin(x * 4.7) * 0.2
            end
            return function(t, ctx)
                local cx, cy = cos(t * 0.5 * PI2) * 50, sin(t * 0.5 * PI2) * 50
                local sx, sy = noise(t, 0) * 5, noise(t, 12345) * 5
                return cx + sx, cy + sy
            end
        end)(),
        createMotion = function()
            return Motion.add(Motion.circle(50, 0.5), Motion.shake(5, 10))
        end,
    },
    {
        name = "scale(rotate(circle, sin), cos) - deep",
        rawFn = (function()
            local sin, cos = math.sin, math.cos
            local PI2 = math.pi * 2
            return function(t, ctx)
                -- Inner circle
                local angle = t * 1 * PI2
                local ix, iy = cos(angle) * 50, sin(angle) * 50
                -- Rotation by sin curve
                local rot = sin(t * 0.5 * PI2) * 0.5
                local c, s = cos(rot), sin(rot)
                local rx, ry = ix * c - iy * s, ix * s + iy * c
                -- Scale by cos curve
                local scale = 1 + cos(t * 0.25 * PI2) * 0.5
                return rx * scale, ry * scale
            end
        end)(),
        createMotion = function()
            return Motion.scale(
                Motion.rotate(Motion.circle(50, 1), Curve.sin(0.5, 0.5)),
                Curve.offset(Curve.cos(0.25, 0.5), 1)
            )
        end,
    },
}

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------

local dt = 1/60
local results = {}

for _, test in ipairs(testCases) do
    print(string.format("--- %s ---", test.name))

    -- Phase 1: Baseline (raw function)
    local baseEntities = {}
    for i = 1, ENTITY_COUNT do
        baseEntities[i] = { phase = math.random(), t = 0 }
    end

    local baseTime = clock()
    for frame = 1, FRAME_COUNT do
        for i = 1, ENTITY_COUNT do
            local e = baseEntities[i]
            e.t = e.t + dt
            local x, y = test.rawFn(e.t + e.phase, {})
        end
    end
    local baseElapsed = clock() - baseTime

    -- Phase 2: Pooled
    Compiled.reset()

    local pooledEntities = {}
    for i = 1, ENTITY_COUNT do
        pooledEntities[i] = {
            motion = test.createMotion():withPhase(math.random()),
        }
    end

    Compiled.build({ silent = true })

    local pool = Compiled._poolsList[1]
    if not pool then
        print("  ERROR: No pool created!")
        goto continue
    end

    local poolTime = clock()
    for frame = 1, FRAME_COUNT do
        pool:step()
        for i = 1, ENTITY_COUNT do
            local x, y = pool.x[i], pool.y[i]
        end
    end
    local poolElapsed = clock() - poolTime

    local speedup = baseElapsed / poolElapsed
    results[#results + 1] = { name = test.name, speedup = speedup, strategy = pool.strategy }

    print(string.format("  Baseline: %.1fms | Pool (%s): %.1fms | Speedup: %.2fx",
        baseElapsed * 1000, pool.strategy, poolElapsed * 1000, speedup))

    ::continue::
end

--------------------------------------------------------------------------------
-- SUMMARY
--------------------------------------------------------------------------------

print("\n=== Summary ===")
print(string.format("%-40s %10s %10s", "Motion", "Strategy", "Speedup"))
print(string.rep("-", 62))

local totalSpeedup = 0
for _, r in ipairs(results) do
    print(string.format("%-40s %10s %9.2fx", r.name, r.strategy, r.speedup))
    totalSpeedup = totalSpeedup + r.speedup
end

print(string.rep("-", 62))
print(string.format("%-40s %10s %9.2fx", "Average", "", totalSpeedup / #results))

--------------------------------------------------------------------------------
-- TEST: Verify correctness (spot check)
--------------------------------------------------------------------------------

print("\n=== Correctness Check ===")

Compiled.reset()

-- Create two entities with same motion, different phases
local m1 = Motion.circle(100, 1):withPhase(0)
local m2 = Motion.circle(100, 1):withPhase(0.25)

Compiled.build({ silent = true })

-- After build, they should be in the same pool
-- Step forward and check positions differ (different phases)
Compiled.step(dt)

local x1, y1 = m1(0, {})
local x2, y2 = m2(0, {})

print(string.format("Entity 1 (phase=0):    (%.2f, %.2f)", x1, y1))
print(string.format("Entity 2 (phase=0.25): (%.2f, %.2f)", x2, y2))

-- They should be different (different phases)
local diff = math.abs(x1 - x2) + math.abs(y1 - y2)
if diff > 0.01 then
    print("✓ Different phases produce different positions")
else
    print("✗ Phases not working correctly")
end
