-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "bootstrap.lua")
-- tests/field_test.lua
-- Tests for Field module: spatial signals, sampling, gradients, indexing
-- Run with: lua5.4 tests/field_test.lua

package.path = package.path .. ";../?.lua;../?/init.lua"
package.preload["spatula.point"] = function() return require("point") end
package.preload["spatula.curve"] = function() return require("curve") end
package.preload["spatula.util"] = function() return require("util") end
package.preload["spatula.signal"] = function() return require("signal") end

local Field = require("field")
local Curve = require("curve")
local Signal = require("signal")
local S = Signal

--------------------------------------------------------------------------------
-- TEST FRAMEWORK
--------------------------------------------------------------------------------

local tests = {}
local passed = 0
local failed = 0

local function test(name, fn)
    table.insert(tests, {name = name, fn = fn})
end

local function assertEq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(b), tostring(a)))
    end
end

local function assertNear(a, b, tolerance, msg)
    tolerance = tolerance or 0.0001
    if math.abs(a - b) > tolerance then
        error(string.format("%s: expected ~%s, got %s (diff: %s)", msg or "assertion failed", tostring(b), tostring(a), tostring(a - b)))
    end
end

local function assertTrue(cond, msg)
    if not cond then
        error(msg or "assertion failed: expected true")
    end
end

local function assertFalse(cond, msg)
    if cond then
        error(msg or "assertion failed: expected false")
    end
end

local function runTests()
    print("Running Field tests...\n")
    for _, t in ipairs(tests) do
        local ok, err = pcall(t.fn)
        if ok then
            passed = passed + 1
            print(string.format("  ✓ %s", t.name))
        else
            failed = failed + 1
            print(string.format("  ✗ %s", t.name))
            print(string.format("    %s", err))
        end
    end
    print(string.format("\n%d passed, %d failed", passed, failed))
    return failed == 0
end

--------------------------------------------------------------------------------
-- FIELD CREATION TESTS
--------------------------------------------------------------------------------

test("Field.new creates empty field", function()
    local f = Field.new()
    assertEq(f:count(), 0, "empty field should have 0 sources")
end)

test("Field.new with custom falloff string", function()
    local f = Field.new({falloff = "linear"})
    assertEq(f:count(), 0)
end)

test("Field.new with custom function falloff", function()
    local customFalloff = function(t) return 1 - t end
    local f = Field.new({falloff = customFalloff})
    assertEq(f:count(), 0)
end)

test("Field.new with blend mode", function()
    local f = Field.new({blend = "max"})
    assertEq(f:count(), 0)
end)

--------------------------------------------------------------------------------
-- SOURCE MANAGEMENT TESTS
--------------------------------------------------------------------------------

test("Field:add increases count", function()
    local f = Field.new()
    f:add({100, 100}, {radius = 50, value = 1})
    assertEq(f:count(), 1, "should have 1 source after add")
end)

test("Field:add with x,y syntax", function()
    local f = Field.new()
    f:add(100, 100, {radius = 50, value = 1})
    assertEq(f:count(), 1, "should have 1 source")
end)

test("Field:add returns source with id", function()
    local f = Field.new()
    local source = f:add({100, 100}, {radius = 50, value = 1})
    assertTrue(source.id ~= nil, "source should have id")
    assertEq(source.x, 100, "source x")
    assertEq(source.y, 100, "source y")
    assertEq(source.radius, 50, "source radius")
    assertEq(source.value, 1, "source value")
end)

test("Field:add multiple sources", function()
    local f = Field.new()
    f:add({0, 0}, {radius = 50})
    f:add({100, 100}, {radius = 50})
    f:add({200, 200}, {radius = 50})
    assertEq(f:count(), 3, "should have 3 sources")
end)

test("Field:remove decreases count", function()
    local f = Field.new()
    local s1 = f:add({0, 0}, {radius = 50})
    local s2 = f:add({100, 100}, {radius = 50})
    assertEq(f:count(), 2)

    f:remove(s1)
    assertEq(f:count(), 1, "should have 1 source after remove")
end)

test("Field:move updates source position", function()
    local f = Field.new()
    local s = f:add({0, 0}, {radius = 50})
    f:move(s, 100, 200)
    assertEq(s.x, 100, "x should be updated")
    assertEq(s.y, 200, "y should be updated")
end)

test("Field:clear removes all sources", function()
    local f = Field.new()
    f:add({0, 0}, {radius = 50})
    f:add({100, 100}, {radius = 50})
    f:clear()
    assertEq(f:count(), 0, "should be empty after clear")
end)

--------------------------------------------------------------------------------
-- SAMPLING TESTS
--------------------------------------------------------------------------------

test("Field:sample at source center returns full value", function()
    local f = Field.new({falloff = "linear"})
    f:add({100, 100}, {radius = 50, value = 1})
    local v = f:sample(100, 100)
    assertNear(v, 1, 0.01, "sample at center should be ~1")
end)

test("Field:sample outside radius returns base", function()
    local f = Field.new({falloff = "linear"})
    f:add({100, 100}, {radius = 50, value = 1})
    local v = f:sample(200, 200)  -- well outside radius
    assertNear(v, 0, 0.01, "sample outside should be base (0)")
end)

test("Field:sample linear falloff decreases with distance", function()
    local f = Field.new({falloff = "linear"})
    f:add({100, 100}, {radius = 100, value = 1})

    local v1 = f:sample(100, 100)  -- center
    local v2 = f:sample(150, 100)  -- halfway
    local v3 = f:sample(200, 100)  -- edge

    assertTrue(v1 > v2, "center should be stronger than halfway")
    assertTrue(v2 > v3 or math.abs(v2 - v3) < 0.01, "halfway should be >= edge")
end)

test("Field:sample with point table", function()
    local f = Field.new({falloff = "linear"})
    f:add({100, 100}, {radius = 50, value = 1})
    local v = f:sample({100, 100})
    assertNear(v, 1, 0.01, "sample with table should work")
end)

test("Field:sample empty field returns base", function()
    local f = Field.new()
    local v = f:sample(100, 100)
    assertEq(v, 0, "empty field should return base (0)")
end)

test("Field:sample with base value", function()
    local f = Field.new({base = 5})
    local v = f:sample(100, 100)
    assertEq(v, 5, "empty field should return base")
end)

test("Field:sample additive blend sums sources", function()
    local f = Field.new({falloff = "linear", blend = "add"})
    f:add({100, 100}, {radius = 50, value = 1})
    f:add({100, 100}, {radius = 50, value = 1})  -- same position
    local v = f:sample(100, 100)
    assertNear(v, 2, 0.1, "additive blend should sum")
end)

test("Field:sample max blend takes maximum", function()
    local f = Field.new({falloff = "linear", blend = "max"})
    f:add({100, 100}, {radius = 50, value = 0.5})
    f:add({100, 100}, {radius = 50, value = 1.0})
    local v = f:sample(100, 100)
    assertNear(v, 1.0, 0.01, "max blend should take maximum")
end)

--------------------------------------------------------------------------------
-- GRADIENT TESTS
--------------------------------------------------------------------------------

test("Field:gradient points toward source", function()
    local f = Field.new({falloff = "smooth"})
    f:add({200, 100}, {radius = 150, value = 1})  -- larger radius to ensure gradient sample points are inside

    local gx, gy = f:gradient(100, 100)  -- sample from left of source
    -- Gradient points toward INCREASING values (toward source center)
    assertTrue(gx > 0, "gradient x should point right toward source")
end)

test("Field:gradient empty field returns 0,0", function()
    local f = Field.new()
    local gx, gy = f:gradient(100, 100)
    assertEq(gx, 0, "empty gradient x")
    assertEq(gy, 0, "empty gradient y")
end)

--------------------------------------------------------------------------------
-- BATCH OPERATIONS TESTS
--------------------------------------------------------------------------------

test("Field:sampleBatch returns array of values", function()
    local f = Field.new({falloff = "linear"})
    f:add({100, 100}, {radius = 100, value = 1})

    local xs = {100, 150, 200, 250}
    local ys = {100, 100, 100, 100}
    local results = f:sampleBatch(xs, ys, 4)

    assertEq(#results, 4, "should return 4 values")
    assertTrue(results[1] > results[2], "closer should be stronger")
end)

--------------------------------------------------------------------------------
-- DECAY/UPDATE TESTS
--------------------------------------------------------------------------------

test("Field:update with decay reduces value", function()
    local f = Field.new({falloff = "linear", decay = 0.5})
    local s = f:add({100, 100}, {radius = 50, value = 1})

    f:update(1)  -- 1 second
    assertTrue(s.value < 1, "value should decrease after decay")
end)

test("Field:update deactivates decayed sources", function()
    local f = Field.new({falloff = "linear", decay = 10})
    local s = f:add({100, 100}, {radius = 50, value = 1})

    f:update(1)  -- should decay to ~0
    -- Field:update sets active = false but doesn't remove source
    assertFalse(s.active, "decayed source should be inactive")
    -- Inactive sources don't contribute to sampling
    assertNear(f:sample(100, 100), 0, 0.01, "inactive source shouldn't contribute")
end)

--------------------------------------------------------------------------------
-- SPATIAL INDEX TESTS
--------------------------------------------------------------------------------

test("Field:enableSpatialIndex creates index", function()
    local f = Field.new()
    -- Pass nil for auto-bounds, or explicit bounds {minX, minY, maxX, maxY}
    f:enableSpatialIndex()
    assertTrue(f._useSpatialIndex, "spatial index should be enabled")
end)

test("Field with spatial index samples correctly", function()
    local f = Field.new({falloff = "linear"})
    -- Enable with explicit bounds
    f:enableSpatialIndex({0, 0, 200, 200})

    f:add({100, 100}, {radius = 50, value = 1})
    local v = f:sample(100, 100)
    assertNear(v, 1, 0.1, "spatial index should not affect results")
end)

--------------------------------------------------------------------------------
-- FALLOFF TESTS
--------------------------------------------------------------------------------

test("Field.falloff.linear exists", function()
    assertTrue(Field.falloff.linear ~= nil, "linear falloff should exist")
end)

test("Field.falloff.smooth exists", function()
    assertTrue(Field.falloff.smooth ~= nil, "smooth falloff should exist")
end)

test("Field.falloff curves return values in expected range", function()
    local linear = Field.falloff.linear
    -- These are curves, so call with (t, ctx)
    local v0 = linear(0, {})
    local v1 = linear(1, {})
    assertNear(v0, 1, 0.01, "linear at 0 (center)")
    assertNear(v1, 0, 0.01, "linear at 1 (edge)")
end)

--------------------------------------------------------------------------------
-- COMBINATOR TESTS
--------------------------------------------------------------------------------

test("Field.combine adds two fields", function()
    local f1 = Field.new({falloff = "linear"})
    local f2 = Field.new({falloff = "linear"})

    f1:add({100, 100}, {radius = 50, value = 1})
    f2:add({100, 100}, {radius = 50, value = 1})

    local combined = Field.combine(f1, f2)
    local v = combined:sample(100, 100)

    assertNear(v, 2, 0.1, "combined field should add values")
end)

test("Field.mul multiplies two fields", function()
    local f1 = Field.new({falloff = "linear"})
    local f2 = Field.new({falloff = "linear"})

    f1:add({100, 100}, {radius = 50, value = 0.5})
    f2:add({100, 100}, {radius = 50, value = 0.5})

    local mulField = Field.mul(f1, f2)
    local v = mulField:sample(100, 100)

    assertNear(v, 0.25, 0.1, "mul field should multiply values")
end)

test("Field.invert inverts field (1-x)", function()
    local f = Field.new({falloff = "linear"})
    f:add({100, 100}, {radius = 50, value = 1})

    local inverted = Field.invert(f)
    local v = inverted:sample(100, 100)

    -- Field.invert does 1 - value, not negation
    -- At center, field samples 1, so inverted samples 0
    assertNear(v, 0, 0.1, "inverted should be 1 - value")
end)

--------------------------------------------------------------------------------
-- TRACKER TESTS
--------------------------------------------------------------------------------

test("Field.track creates tracker with threshold", function()
    local f = Field.new()
    f:add({100, 100}, {radius = 50, value = 1})

    local tracker = Field.track(f, ">", 0.5, {})
    assertTrue(tracker.threshold == 0.5, "threshold should be set")
    assertTrue(tracker.exitThreshold == 0.5, "exitThreshold defaults to threshold")
    assertTrue(tracker.field == f, "field should be stored")
end)

test("Field.track with exitThreshold for hysteresis", function()
    local f = Field.new()
    f:add({100, 100}, {radius = 50, value = 1})

    local tracker = Field.track(f, ">", 0.5, { exitThreshold = 0.3 })
    assertEq(tracker.threshold, 0.5, "threshold")
    assertEq(tracker.exitThreshold, 0.3, "exitThreshold")
end)

test("Field.track with queryFn stores it", function()
    local f = Field.new()
    local queryFn = function(x, y, r) return {} end

    local tracker = Field.track(f, ">", 0.5, { queryFn = queryFn })
    assertTrue(tracker.queryFn == queryFn, "queryFn should be stored")
end)

test("Field.updateTracker pull mode fires onEnter", function()
    local f = Field.new({ falloff = "linear" })
    f:add({100, 100}, {radius = 50, value = 1})

    local entered = {}
    local tracker = Field.track(f, ">", 0.5, {
        onEnter = function(e) entered[#entered + 1] = e end
    })

    local entities = {{ id = 1, x = 100, y = 100 }}
    Field.updateTracker(tracker, entities, 0.016)

    assertEq(#entered, 1, "onEnter should fire once")
    assertEq(entered[1].id, 1, "entity should match")
end)

test("Field.updateTracker pull mode fires onExit", function()
    local f = Field.new({ falloff = "linear" })
    f:add({100, 100}, {radius = 50, value = 1})

    local exited = {}
    local tracker = Field.track(f, ">", 0.5, {
        onExit = function(e) exited[#exited + 1] = e end
    })

    -- Enter first
    local entities = {{ id = 1, x = 100, y = 100 }}
    Field.updateTracker(tracker, entities, 0.016)

    -- Move out
    entities[1].x = 200
    Field.updateTracker(tracker, entities, 0.016)

    assertEq(#exited, 1, "onExit should fire once")
end)

test("Field.updateTracker pull mode hysteresis prevents flicker", function()
    local f = Field.new({ falloff = "linear" })
    f:add({100, 100}, {radius = 50, value = 1})

    local enterCount = 0
    local exitCount = 0
    local tracker = Field.track(f, ">", 0.5, {
        exitThreshold = 0.3,
        onEnter = function() enterCount = enterCount + 1 end,
        onExit = function() exitCount = exitCount + 1 end
    })

    -- Entity at center (value ~1.0) - enters
    local entities = {{ id = 1, x = 100, y = 100 }}
    Field.updateTracker(tracker, entities, 0.016)
    assertEq(enterCount, 1, "should enter at high value")

    -- Move to edge where value is ~0.4 (between thresholds)
    -- With linear falloff at ~80% radius, value is ~0.2
    -- Actually let's move to ~60% radius where value is ~0.4
    entities[1].x = 130  -- ~30 units = 60% of 50 radius
    Field.updateTracker(tracker, entities, 0.016)

    -- Should NOT exit because 0.4 > exitThreshold(0.3)
    assertEq(exitCount, 0, "hysteresis should prevent exit")
    assertEq(enterCount, 1, "should not re-enter")
end)

test("Field.updateTracker push mode with queryFn", function()
    local f = Field.new({ falloff = "linear" })
    f:add({100, 100}, {radius = 50, value = 1})

    local entered = {}
    local mockEntities = {
        { id = 1, x = 100, y = 100 },  -- inside
        { id = 2, x = 200, y = 200 },  -- outside
    }

    local tracker = Field.track(f, ">", 0.5, {
        queryFn = function(x, y, r)
            -- Return entities "near" the source
            local result = {}
            for _, e in ipairs(mockEntities) do
                local dx, dy = e.x - x, e.y - y
                if dx*dx + dy*dy <= r*r then
                    result[#result + 1] = e
                end
            end
            return result
        end,
        onEnter = function(e) entered[#entered + 1] = e end
    })

    Field.updateTracker(tracker, 0.016)

    assertEq(#entered, 1, "only entity inside should enter")
    assertEq(entered[1].id, 1, "entity 1 should enter")
end)

test("Field.updateTracker push mode cleanup fires onExit", function()
    local f = Field.new({ falloff = "linear" })
    f:add({100, 100}, {radius = 50, value = 1})

    local exited = {}
    local mockEntity = { id = 1, x = 100, y = 100 }
    local entityVisible = true

    local tracker = Field.track(f, ">", 0.5, {
        queryFn = function(x, y, r)
            if entityVisible then
                return { mockEntity }
            else
                return {}
            end
        end,
        onExit = function(e) exited[#exited + 1] = e end
    })

    -- Enter
    Field.updateTracker(tracker, 0.016)

    -- Entity moves out of query range AND out of field
    entityVisible = false
    mockEntity.x = 200  -- far from field
    Field.updateTracker(tracker, 0.016)

    assertEq(#exited, 1, "cleanup should fire onExit")
end)

test("Field.updateTracker push mode dedupes across sources", function()
    local f = Field.new({ falloff = "linear" })
    -- Two overlapping sources
    f:add({100, 100}, {radius = 50, value = 1})
    f:add({120, 100}, {radius = 50, value = 1})

    local enterCount = 0
    local mockEntity = { id = 1, x = 110, y = 100 }  -- in range of both

    local tracker = Field.track(f, ">", 0.5, {
        queryFn = function(x, y, r)
            local dx, dy = mockEntity.x - x, mockEntity.y - y
            if dx*dx + dy*dy <= r*r then
                return { mockEntity }
            end
            return {}
        end,
        onEnter = function() enterCount = enterCount + 1 end
    })

    Field.updateTracker(tracker, 0.016)

    assertEq(enterCount, 1, "entity should only enter once despite multiple sources")
end)

test("Field.updateTracker whileInside with cooldown", function()
    local f = Field.new({ falloff = "linear" })
    f:add({100, 100}, {radius = 50, value = 1})

    local actionCount = 0
    local tracker = Field.track(f, ">", 0.5, {
        whileInside = {
            cooldown = 0.1,
            action = function() actionCount = actionCount + 1 end
        }
    })

    local entities = {{ id = 1, x = 100, y = 100 }}

    -- First update - enters and fires action (cooldown starts at 0)
    Field.updateTracker(tracker, entities, 0.05)
    assertEq(actionCount, 1, "action fires on enter")

    -- Second update - cooldown not elapsed
    Field.updateTracker(tracker, entities, 0.05)
    assertEq(actionCount, 1, "action should not fire yet")

    -- Third update - cooldown elapsed
    Field.updateTracker(tracker, entities, 0.1)
    assertEq(actionCount, 2, "action should fire again")
end)

test("Field.setDefaultQueryFn sets global default", function()
    local f = Field.new({ falloff = "linear" })
    f:add({100, 100}, {radius = 50, value = 1})

    local queryCalled = false
    Field.setDefaultQueryFn(function(x, y, r)
        queryCalled = true
        return {{ id = 1, x = 100, y = 100 }}
    end)

    local tracker = Field.track(f, ">", 0.5, {
        onEnter = function() end
    })

    Field.updateTracker(tracker, 0.016)
    assertEq(queryCalled, true, "default queryFn should be called")

    -- Cleanup
    Field.setDefaultQueryFn(nil)
end)

test("Field.updateTracker uses tracker.queryFn over default", function()
    local f = Field.new({ falloff = "linear" })
    f:add({100, 100}, {radius = 50, value = 1})

    local defaultCalled = false
    local trackerCalled = false

    Field.setDefaultQueryFn(function(x, y, r)
        defaultCalled = true
        return {}
    end)

    local tracker = Field.track(f, ">", 0.5, {
        queryFn = function(x, y, r)
            trackerCalled = true
            return {{ id = 1, x = 100, y = 100 }}
        end,
        onEnter = function() end
    })

    Field.updateTracker(tracker, 0.016)
    assertEq(trackerCalled, true, "tracker queryFn should be called")
    assertEq(defaultCalled, false, "default should NOT be called when tracker has queryFn")

    -- Cleanup
    Field.setDefaultQueryFn(nil)
end)

test("Field.updateTracker uses default when no tracker.queryFn", function()
    local f = Field.new({ falloff = "linear" })
    f:add({100, 100}, {radius = 50, value = 1})

    local entered = {}
    Field.setDefaultQueryFn(function(x, y, r)
        return {{ id = 1, x = 100, y = 100 }}
    end)

    local tracker = Field.track(f, ">", 0.5, {
        -- No queryFn here
        onEnter = function(e) entered[#entered + 1] = e end
    })

    Field.updateTracker(tracker, 0.016)
    assertEq(#entered, 1, "should enter via default queryFn")

    -- Cleanup
    Field.setDefaultQueryFn(nil)
end)

test("Field.updateTracker falls back to pull mode when no queryFn", function()
    local f = Field.new({ falloff = "linear" })
    f:add({100, 100}, {radius = 50, value = 1})

    -- Ensure no default is set
    Field.setDefaultQueryFn(nil)

    local entered = {}
    local tracker = Field.track(f, ">", 0.5, {
        onEnter = function(e) entered[#entered + 1] = e end
    })

    -- Pass entities list (pull mode)
    local entities = {{ id = 1, x = 100, y = 100 }}
    Field.updateTracker(tracker, entities, 0.016)

    assertEq(#entered, 1, "pull mode should work when no queryFn")
end)

--------------------------------------------------------------------------------
-- SIGNAL SUPPORT TESTS
--------------------------------------------------------------------------------

test("Field:sample with signal radius", function()
    local f = Field.new({falloff = "linear"})
    f:add({100, 100}, {radius = S("r", 50), value = 1})

    -- Default radius = 50, point at edge
    local v1 = f:sample(150, 100)  -- 50 units away
    assertNear(v1, 0, 0.1, "at default edge should be ~0")

    -- With ctx radius = 100, point at halfway
    local v2 = f:sample(150, 100, { r = 100 })
    assertTrue(v2 > 0.3, "with larger radius should be inside")
end)

test("Field:sample with signal value", function()
    local f = Field.new({falloff = "linear"})
    f:add({100, 100}, {radius = 50, value = S("intensity", 1)})

    -- Default value = 1
    local v1 = f:sample(100, 100)
    assertNear(v1, 1, 0.1, "default intensity")

    -- With ctx intensity = 2
    local v2 = f:sample(100, 100, { intensity = 2 })
    assertNear(v2, 2, 0.1, "ctx intensity")
end)

test("Field:sample with signal position", function()
    local f = Field.new({falloff = "linear"})
    f:add({S("sx", 100), S("sy", 100)}, {radius = 50, value = 1})

    -- Default position (100, 100)
    local v1 = f:sample(100, 100)
    assertNear(v1, 1, 0.1, "at default source center")

    -- Move source via ctx
    local v2 = f:sample(100, 100, { sx = 200, sy = 200 })
    assertNear(v2, 0, 0.1, "source moved away via ctx")

    -- Sample at new source position
    local v3 = f:sample(200, 200, { sx = 200, sy = 200 })
    assertNear(v3, 1, 0.1, "at new source center")
end)

test("Field:sample with signal base", function()
    local f = Field.new({base = S("baseVal", 0)})

    local v1 = f:sample(100, 100)
    assertEq(v1, 0, "default base")

    local v2 = f:sample(100, 100, { baseVal = 5 })
    assertEq(v2, 5, "ctx base value")
end)

test("Field:gradient with ctx", function()
    local f = Field.new({falloff = "smooth"})
    f:add({S("sx", 200), 100}, {radius = 150, value = 1})

    -- Default: source at (200, 100)
    local gx1, gy1 = f:gradient({100, 100})
    assertTrue(gx1 > 0, "gradient points right toward default source")

    -- Move source to (50, 100) via ctx
    local gx2, gy2 = f:gradient({100, 100}, nil, { sx = 50 })
    assertTrue(gx2 < 0, "gradient points left toward moved source")
end)

test("Field:sampleBatch with ctx", function()
    local f = Field.new({falloff = "linear"})
    f:add({100, 100}, {radius = S("r", 50), value = 1})

    local xs = {100, 150, 200}
    local ys = {100, 100, 100}

    -- Default radius = 50
    local results1 = f:sampleBatch(xs, ys, 3)
    assertNear(results1[1], 1, 0.1, "center")
    assertNear(results1[2], 0, 0.1, "edge with default radius")
    assertNear(results1[3], 0, 0.1, "outside")

    -- With larger radius
    local results2 = f:sampleBatch(xs, ys, 3, nil, { r = 150 })
    assertTrue(results2[2] > 0.5, "now inside with larger radius")
end)

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------

local success = runTests()
os.exit(success and 0 or 1)
