-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "bootstrap.lua")
-- tests/forms_test.lua
-- Tests for Forms module: geometric shapes, containment, combinators, tracking
-- Run with: lua5.4 tests/forms_test.lua

package.path = package.path .. ";../?.lua;../?/init.lua"
package.preload["spatula.point"] = function() return require("point") end
package.preload["spatula.util"] = function() return require("util") end
package.preload["spatula.signal"] = function() return require("signal") end

local Forms = require("forms")
local S = require("signal")

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
    print("Running Forms tests...\n")
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
-- CIRCLE TESTS
--------------------------------------------------------------------------------

test("circle:contains returns true for center", function()
    local c = Forms.circle(100, 100, 50)
    assertTrue(c:contains(100, 100))
end)

test("circle:contains returns true inside radius", function()
    local c = Forms.circle(100, 100, 50)
    assertTrue(c:contains(120, 100))
    assertTrue(c:contains(100, 130))
end)

test("circle:contains returns false outside radius", function()
    local c = Forms.circle(100, 100, 50)
    assertFalse(c:contains(200, 100))
    assertFalse(c:contains(100, 200))
end)

test("circle:contains edge case (exactly on boundary)", function()
    local c = Forms.circle(100, 100, 50)
    -- Point exactly on boundary should be inside (<=)
    assertTrue(c:contains(150, 100))
end)

test("circle:bounds returns correct extents", function()
    local c = Forms.circle(100, 100, 50)
    local minX, minY, maxX, maxY = c:bounds()
    assertEq(minX, 50, "minX")
    assertEq(minY, 50, "minY")
    assertEq(maxX, 150, "maxX")
    assertEq(maxY, 150, "maxY")
end)

test("circle:edge returns perimeter points", function()
    local c = Forms.circle(100, 100, 50)
    local count = 0
    for x, y in c:edge(8) do
        count = count + 1
        local dist = math.sqrt((x - 100)^2 + (y - 100)^2)
        assertNear(dist, 50, 0.01, "edge point should be on perimeter")
    end
    assertEq(count, 8, "should return 8 points")
end)

test("circle:random returns point inside", function()
    local c = Forms.circle(100, 100, 50)
    for _ = 1, 100 do
        local x, y = c:random()
        assertTrue(c:contains(x, y), "random point should be inside")
    end
end)

test("circle with signal radius", function()
    local c = Forms.circle(0, 0, S("radius", 50))
    -- Default radius = 50
    assertTrue(c:contains(30, 0))
    assertFalse(c:contains(60, 0))
    -- With ctx radius = 100
    assertTrue(c:contains(60, 0, { radius = 100 }))
    assertFalse(c:contains(110, 0, { radius = 100 }))
end)

test("circle with signal position", function()
    local c = Forms.circle(S("cx", 0), S("cy", 0), 50)
    -- Default position (0, 0)
    assertTrue(c:contains(30, 0))
    -- Moved to (100, 100)
    assertFalse(c:contains(30, 0, { cx = 100, cy = 100 }))
    assertTrue(c:contains(130, 100, { cx = 100, cy = 100 }))
end)

--------------------------------------------------------------------------------
-- RECT TESTS
--------------------------------------------------------------------------------

test("rect:contains returns true for center", function()
    local r = Forms.rect(100, 100, 50, 50)  -- square
    assertTrue(r:contains(100, 100))
end)

test("rect:contains respects dimensions", function()
    local r = Forms.rect(100, 100, 100, 50)  -- hw=100, hh=50
    assertTrue(r:contains(190, 100), "inside wide rect")
    assertFalse(r:contains(100, 160), "outside rect height")
end)

test("rect:bounds returns correct extents", function()
    local r = Forms.rect(100, 100, 100, 50)  -- hw=100, hh=50
    local minX, minY, maxX, maxY = r:bounds()
    assertEq(minX, 0, "minX")   -- 100 - 100
    assertEq(minY, 50, "minY")  -- 100 - 50
    assertEq(maxX, 200, "maxX") -- 100 + 100
    assertEq(maxY, 150, "maxY") -- 100 + 50
end)

test("rect:edge returns perimeter points", function()
    local r = Forms.rect(100, 100, 50, 50)
    local count = 0
    for x, y in r:edge(16) do
        count = count + 1
    end
    assertEq(count, 16, "should return 16 points")
end)

test("rect:random returns point inside", function()
    local r = Forms.rect(100, 100, 75, 50)
    for _ = 1, 100 do
        local x, y = r:random()
        assertTrue(r:contains(x, y), "random point should be inside")
    end
end)

test("rect with signal dimensions", function()
    local r = Forms.rect(100, 100, S("hw", 50), S("hh", 50))
    -- Default dimensions
    assertTrue(r:contains(140, 100))
    assertFalse(r:contains(160, 100))
    -- Larger dimensions
    assertTrue(r:contains(160, 100, { hw = 100 }))
end)

--------------------------------------------------------------------------------
-- RING TESTS
--------------------------------------------------------------------------------

test("ring:contains returns false for center", function()
    local ring = Forms.ring(100, 100, 100, 50)  -- outer=100, inner=50
    assertFalse(ring:contains(100, 100), "center should be outside ring")
end)

test("ring:contains returns true in annulus", function()
    local ring = Forms.ring(100, 100, 100, 50)  -- outer=100, inner=50
    assertTrue(ring:contains(175, 100), "in annulus")
    assertFalse(ring:contains(120, 100), "too close to center")
end)

test("ring:random returns point in annulus", function()
    local ring = Forms.ring(100, 100, 100, 50)
    for _ = 1, 100 do
        local x, y = ring:random()
        assertTrue(ring:contains(x, y), "random should be in ring")
    end
end)

test("ring with signal radii", function()
    local ring = Forms.ring(100, 100, S("outer", 100), S("inner", 50))
    -- Default: outer=100, inner=50
    assertTrue(ring:contains(175, 100))
    assertFalse(ring:contains(120, 100))
    -- Larger inner (smaller annulus)
    assertFalse(ring:contains(175, 100, { inner = 80 }))
end)

--------------------------------------------------------------------------------
-- ELLIPSE TESTS
--------------------------------------------------------------------------------

test("ellipse:contains with equal radii is circle", function()
    local e = Forms.ellipse(100, 100, 50, 50)
    assertTrue(e:contains(100, 100), "center")
    assertTrue(e:contains(140, 100), "inside")
    assertFalse(e:contains(200, 100), "outside")
end)

test("ellipse:contains with different radii", function()
    local e = Forms.ellipse(100, 100, 100, 50)  -- rx=100, ry=50
    assertTrue(e:contains(190, 100), "inside wide part")
    assertFalse(e:contains(100, 160), "outside narrow part")
end)

test("ellipse:bounds returns correct extents", function()
    local e = Forms.ellipse(100, 100, 100, 25)  -- rx=100, ry=25
    local minX, minY, maxX, maxY = e:bounds()
    assertEq(minX, 0, "minX")    -- 100 - 100
    assertEq(minY, 75, "minY")   -- 100 - 25
    assertEq(maxX, 200, "maxX")  -- 100 + 100
    assertEq(maxY, 125, "maxY")  -- 100 + 25
end)

--------------------------------------------------------------------------------
-- POLYGON TESTS
--------------------------------------------------------------------------------

test("polygon triangle contains center", function()
    local triangle = Forms.polygon(100, 100, 3, 50)
    assertTrue(triangle:contains(100, 100))
end)

test("polygon square contains inside points", function()
    local square = Forms.polygon(100, 100, 4, 50, math.pi/4)  -- rotated 45 degrees
    assertTrue(square:contains(100, 100), "center")
    assertTrue(square:contains(120, 120), "inside")
end)

test("polygon hexagon", function()
    local hex = Forms.polygon(100, 100, 6, 50)
    assertTrue(hex:contains(100, 100))
end)

--------------------------------------------------------------------------------
-- COMBINATOR TESTS
--------------------------------------------------------------------------------

test("union contains if in either form", function()
    local c = Forms.circle(100, 100, 50)
    local r = Forms.rect(100, 100, 50, 50)
    local combined = Forms.union(c, r)

    -- Center is in both
    assertTrue(combined:contains(100, 100), "center in both")
end)

test("union bounds encompasses both", function()
    local wide = Forms.rect(100, 100, 100, 50)  -- extends further in x
    local tall = Forms.rect(100, 100, 50, 100)  -- extends further in y
    local combined = Forms.union(wide, tall)

    local minX, minY, maxX, maxY = combined:bounds()
    assertEq(minX, 0, "minX from wide rect")
    assertEq(maxX, 200, "maxX from wide rect")
    assertEq(minY, 0, "minY from tall rect")
    assertEq(maxY, 200, "maxY from tall rect")
end)

test("intersect contains only if in both forms", function()
    local c = Forms.circle(100, 100, 50)
    local r = Forms.rect(100, 100, 50, 50)
    local combined = Forms.intersect(c, r)

    assertTrue(combined:contains(100, 100), "center in both")
    -- Corners of rect are outside circle, so intersection excludes them
end)

test("subtract removes inner from outer", function()
    local outer = Forms.circle(100, 100, 50)
    local inner = Forms.rect(100, 100, 25, 25)
    local donut = Forms.subtract(outer, inner)

    -- Center is inside rect, so subtracted
    assertFalse(donut:contains(100, 100), "center should be excluded")
    -- Edge of circle outside inner rect
    assertTrue(donut:contains(145, 100), "edge should be included")
end)

--------------------------------------------------------------------------------
-- TRACKER TESTS
--------------------------------------------------------------------------------

test("Forms.track creates tracker with correct properties", function()
    local c = Forms.circle(100, 100, 50)
    local tracker = Forms.track(c, {})
    assertTrue(tracker.enabled, "should be enabled by default")
    assertTrue(tracker.form ~= nil, "should have form")
end)

test("Forms.track contains function works", function()
    local c = Forms.circle(100, 100, 50)
    local tracker = Forms.track(c, {})
    assertTrue(tracker.contains(100, 100), "center should be inside")
    assertFalse(tracker.contains(200, 200), "far point should be outside")
end)

test("Forms.updateTracker fires onEnter", function()
    local entered = {}
    local c = Forms.circle(100, 100, 50)
    local tracker = Forms.track(c, {
        onEnter = function(e) entered[#entered + 1] = e.id end
    })

    local entities = {
        {id = 1, x = 100, y = 100},  -- inside
        {id = 2, x = 200, y = 200},  -- outside
    }

    Forms.updateTracker(tracker, entities, 0.016)
    assertEq(#entered, 1, "should fire onEnter for entity 1")
    assertEq(entered[1], 1, "should be entity 1")
end)

test("Forms.updateTracker fires onExit", function()
    local exited = {}
    local c = Forms.circle(100, 100, 50)
    local tracker = Forms.track(c, {
        onExit = function(e) exited[#exited + 1] = e.id end
    })

    local entities = {{id = 1, x = 100, y = 100}}

    -- First update - entity enters
    Forms.updateTracker(tracker, entities, 0.016)
    assertEq(#exited, 0, "no exit yet")

    -- Move entity outside
    entities[1].x = 200
    Forms.updateTracker(tracker, entities, 0.016)
    assertEq(#exited, 1, "should fire onExit")
end)

test("Forms.updateTracker whileInside with cooldown", function()
    local ticks = 0
    local c = Forms.circle(100, 100, 50)
    local tracker = Forms.track(c, {
        whileInside = {
            action = function() ticks = ticks + 1 end,
            cooldown = 0.1
        }
    })

    local entities = {{id = 1, x = 100, y = 100}}

    -- Multiple updates within cooldown
    Forms.updateTracker(tracker, entities, 0.05)
    assertEq(ticks, 1, "first tick immediate")

    Forms.updateTracker(tracker, entities, 0.05)
    assertEq(ticks, 1, "still in cooldown")

    Forms.updateTracker(tracker, entities, 0.1)
    assertEq(ticks, 2, "cooldown expired, tick again")
end)

test("Forms.updateTracker disabled tracker does nothing", function()
    local entered = {}
    local c = Forms.circle(100, 100, 50)
    local tracker = Forms.track(c, {
        onEnter = function(e) entered[#entered + 1] = e.id end,
        enabled = false
    })

    local entities = {{id = 1, x = 100, y = 100}}
    Forms.updateTracker(tracker, entities, 0.016)
    assertEq(#entered, 0, "disabled tracker should not fire")
end)

--------------------------------------------------------------------------------
-- BATCH CONTAINMENT TESTS
--------------------------------------------------------------------------------

test("circle:containsBatch returns correct results", function()
    local c = Forms.circle(100, 100, 50)
    local xs = {100, 120, 200, 100}
    local ys = {100, 100, 200, 140}
    local results = c:containsBatch(xs, ys, 4)

    assertTrue(results[1], "center should be inside")
    assertTrue(results[2], "near center should be inside")
    assertFalse(results[3], "far point should be outside")
    assertTrue(results[4], "edge point should be inside")
end)

test("rect:containsBatch returns correct results", function()
    local r = Forms.rect(100, 100, 50, 50)
    local xs = {100, 140, 200}
    local ys = {100, 140, 200}
    local results = r:containsBatch(xs, ys, 3)

    assertTrue(results[1], "center")
    assertTrue(results[2], "corner inside")
    assertFalse(results[3], "outside")
end)

--------------------------------------------------------------------------------
-- SPATIAL HASH TESTS (via opt module)
--------------------------------------------------------------------------------

test("SpatialHash insert and query", function()
    if not Forms.SpatialHash then
        print("    (skipped - SpatialHash not available)")
        return
    end

    local hash = Forms.SpatialHash(64)
    local e1 = {id = 1, x = 100, y = 100}
    local e2 = {id = 2, x = 500, y = 500}

    hash:insert(e1)
    hash:insert(e2)

    local nearby = hash:queryBounds(50, 50, 150, 150)
    assertEq(#nearby, 1, "should find 1 entity near (100,100)")
end)

test("SpatialHash remove", function()
    if not Forms.SpatialHash then
        print("    (skipped - SpatialHash not available)")
        return
    end

    local hash = Forms.SpatialHash(64)
    local e1 = {id = 1, x = 100, y = 100}
    hash:insert(e1)
    hash:remove(1)

    local nearby = hash:queryBounds(50, 50, 150, 150)
    assertEq(#nearby, 0, "should find 0 after remove")
end)

--------------------------------------------------------------------------------
-- DEFAULT QUERY FUNCTION TESTS
--------------------------------------------------------------------------------

test("Forms.setDefaultQueryFn sets global default", function()
    local queryCalled = false
    Forms.setDefaultQueryFn(function(minX, minY, maxX, maxY)
        queryCalled = true
        return {{ id = 1, x = 100, y = 100 }}
    end)

    local c = Forms.circle(100, 100, 50)
    local tracker = Forms.track(c, {
        onEnter = function() end
    })

    Forms.updateTracker(tracker, 0.016)
    assertEq(queryCalled, true, "default queryFn should be called")

    -- Cleanup
    Forms.setDefaultQueryFn(nil)
end)

test("Forms.track with queryFn stores it", function()
    local myQuery = function() return {} end
    local c = Forms.circle(100, 100, 50)
    local tracker = Forms.track(c, {
        queryFn = myQuery
    })
    assertEq(tracker.queryFn, myQuery, "queryFn should be stored")
end)

test("Forms.updateTracker uses tracker.queryFn over default", function()
    local defaultCalled = false
    local trackerCalled = false

    Forms.setDefaultQueryFn(function(minX, minY, maxX, maxY)
        defaultCalled = true
        return {}
    end)

    local c = Forms.circle(100, 100, 50)
    local tracker = Forms.track(c, {
        queryFn = function(minX, minY, maxX, maxY)
            trackerCalled = true
            return {{ id = 1, x = 100, y = 100 }}
        end,
        onEnter = function() end
    })

    Forms.updateTracker(tracker, 0.016)
    assertEq(trackerCalled, true, "tracker queryFn should be called")
    assertEq(defaultCalled, false, "default should NOT be called")

    -- Cleanup
    Forms.setDefaultQueryFn(nil)
end)

test("Forms.updateTracker uses default when no tracker.queryFn", function()
    local entered = {}
    Forms.setDefaultQueryFn(function(minX, minY, maxX, maxY)
        return {{ id = 1, x = 100, y = 100 }}
    end)

    local c = Forms.circle(100, 100, 50)
    local tracker = Forms.track(c, {
        -- No queryFn here
        onEnter = function(e) entered[#entered + 1] = e end
    })

    Forms.updateTracker(tracker, 0.016)
    assertEq(#entered, 1, "should enter via default queryFn")

    -- Cleanup
    Forms.setDefaultQueryFn(nil)
end)

test("Forms.updateTracker falls back to pull mode when no queryFn", function()
    -- Ensure no default is set
    Forms.setDefaultQueryFn(nil)

    local entered = {}
    local c = Forms.circle(100, 100, 50)
    local tracker = Forms.track(c, {
        onEnter = function(e) entered[#entered + 1] = e end
    })

    -- Pass entities list (pull mode)
    local entities = {{ id = 1, x = 100, y = 100 }}
    Forms.updateTracker(tracker, entities, 0.016)

    assertEq(#entered, 1, "pull mode should work when no queryFn")
end)

test("Forms.updateTracker spatial mode fires onEnter/onExit", function()
    local entered = {}
    local exited = {}
    local mockEntity = { id = 1, x = 100, y = 100 }
    local entityInRange = true

    local c = Forms.circle(100, 100, 50)
    local tracker = Forms.track(c, {
        queryFn = function(minX, minY, maxX, maxY)
            if entityInRange then
                return { mockEntity }
            else
                return {}
            end
        end,
        onEnter = function(e) entered[#entered + 1] = e end,
        onExit = function(e) exited[#exited + 1] = e end
    })

    -- Enter
    Forms.updateTracker(tracker, 0.016)
    assertEq(#entered, 1, "should enter")

    -- Exit (entity moves out of query range)
    entityInRange = false
    mockEntity.x = 200  -- Also outside form
    Forms.updateTracker(tracker, 0.016)
    assertEq(#exited, 1, "should exit")
end)

test("Forms.updateTracker spatial mode cleanup fires onExit", function()
    local exited = {}
    local mockEntity = { id = 1, x = 100, y = 100 }
    local entityVisible = true

    local c = Forms.circle(100, 100, 50)
    local tracker = Forms.track(c, {
        queryFn = function(minX, minY, maxX, maxY)
            if entityVisible then
                return { mockEntity }
            else
                return {}
            end
        end,
        onExit = function(e) exited[#exited + 1] = e end
    })

    -- Enter
    Forms.updateTracker(tracker, 0.016)

    -- Entity disappears from query
    entityVisible = false
    Forms.updateTracker(tracker, 0.016)

    assertEq(#exited, 1, "cleanup should fire onExit")
end)

--------------------------------------------------------------------------------
-- SIGNAL ACTIVE/GLOBAL CONTEXT TESTS
--------------------------------------------------------------------------------

test("S.setActive provides implicit context", function()
    local form = Forms.circle(S("x", 0), S("y", 0), S("r", 50))

    -- Without active context, uses defaults
    assertTrue(form:contains(0, 0), "center with defaults")

    -- Set active context
    S.setActive({ x = 100, y = 100, r = 50 })
    assertTrue(form:contains(100, 100), "center with active context")
    assertFalse(form:contains(0, 0), "origin now outside")

    -- Cleanup
    S.setActive(nil)
end)

test("S.setActive overrides previous", function()
    local form = Forms.circle(S("x", 0), S("y", 0), 50)

    S.setActive({ x = 100, y = 100 })
    assertTrue(form:contains(100, 100), "first active")

    S.setActive({ x = 200, y = 200 })
    assertTrue(form:contains(200, 200), "second active overrides")
    assertFalse(form:contains(100, 100), "first no longer active")

    S.setActive(nil)
end)

test("S.setGlobal provides frame-wide values", function()
    local form = Forms.circle(0, 0, S("globalRadius", 50))

    -- Without global, uses default
    assertTrue(form:contains(30, 0), "inside default radius")

    -- Set global
    S.setGlobal("globalRadius", 20)
    assertFalse(form:contains(30, 0), "now outside smaller radius")
    assertTrue(form:contains(10, 0), "inside smaller radius")

    -- Cleanup
    S.clearGlobals()
end)

test("explicit ctx overrides active context", function()
    local form = Forms.circle(S("x", 0), S("y", 0), 50)

    S.setActive({ x = 100, y = 100 })
    assertTrue(form:contains(100, 100), "uses active")

    -- Explicit ctx overrides active
    assertTrue(form:contains(200, 200, { x = 200, y = 200 }), "explicit overrides")

    S.setActive(nil)
end)

test("active context overrides globals", function()
    local form = Forms.circle(0, 0, S("r", 50))

    S.setGlobal("r", 100)
    assertTrue(form:contains(80, 0), "global radius 100")

    -- Active overrides global
    S.setActive({ r = 30 })
    assertFalse(form:contains(80, 0), "active radius 30 is smaller")
    assertTrue(form:contains(20, 0), "inside active radius")

    S.setActive(nil)
    S.clearGlobals()
end)

test("priority chain: explicit > active > global > default", function()
    local signal = S("val", 1)

    -- Default
    assertEq(signal(0), 1, "default")

    -- Global overrides default
    S.setGlobal("val", 2)
    assertEq(signal(0), 2, "global")

    -- Active overrides global
    S.setActive({ val = 3 })
    assertEq(signal(0), 3, "active")

    -- Explicit overrides active
    assertEq(signal(0, { val = 4 }), 4, "explicit")

    S.setActive(nil)
    S.clearGlobals()
end)

test("active context sees mid-frame updates", function()
    local form = Forms.circle(0, 0, S("r", 50))
    local entity = { r = 100 }

    S.setActive(entity)
    assertTrue(form:contains(80, 0), "inside radius 100")

    -- Mid-frame update
    entity.r = 30
    assertFalse(form:contains(80, 0), "now outside after entity update")
    assertTrue(form:contains(20, 0), "inside new radius")

    S.setActive(nil)
end)

--------------------------------------------------------------------------------
-- SIGNED DISTANCE TESTS
--------------------------------------------------------------------------------

test("circle:signedDistance positive inside, negative outside", function()
    local c = Forms.circle(100, 100, 50)

    -- Center is 50 units from edge (max positive)
    assertNear(c:signedDistance(100, 100), 50, 0.001, "center")

    -- 30 units from center = 20 units from edge
    assertNear(c:signedDistance(130, 100), 20, 0.001, "inside")

    -- Exactly on edge = 0
    assertNear(c:signedDistance(150, 100), 0, 0.001, "on edge")

    -- 10 units outside
    assertNear(c:signedDistance(160, 100), -10, 0.001, "outside")
end)

test("rect:signedDistance positive inside, negative outside", function()
    local r = Forms.rect(100, 100, 50, 30)  -- half-width 50, half-height 30

    -- Center: min distance to edge is 30 (to top/bottom)
    assertNear(r:signedDistance(100, 100), 30, 0.001, "center")

    -- 10 units from right edge
    assertNear(r:signedDistance(140, 100), 10, 0.001, "near right edge")

    -- On edge
    assertNear(r:signedDistance(150, 100), 0, 0.001, "on edge")

    -- 10 units outside (straight right)
    assertNear(r:signedDistance(160, 100), -10, 0.001, "outside right")

    -- Outside corner (diagonal distance)
    local cornerDist = r:signedDistance(160, 140)  -- 10 past right, 10 past top
    assertTrue(cornerDist < 0, "outside corner is negative")
    assertNear(cornerDist, -math.sqrt(200), 0.1, "corner distance")
end)

test("ellipse:signedDistance positive inside, negative outside", function()
    local e = Forms.ellipse(100, 100, 50, 50)  -- equal radii = circle

    -- At center
    assertTrue(e:signedDistance(100, 100) > 0, "center is positive")

    -- On edge (approximately)
    assertNear(e:signedDistance(150, 100), 0, 1, "on edge ~0")

    -- Outside
    assertTrue(e:signedDistance(160, 100) < 0, "outside is negative")
end)

test("ring:signedDistance handles inner and outer boundaries", function()
    local ring = Forms.ring(100, 100, 50, 20)  -- outer 50, inner 20

    -- Center (inside inner hole) - negative
    assertTrue(ring:signedDistance(100, 100) < 0, "center in hole is negative")
    assertNear(ring:signedDistance(100, 100), -20, 0.001, "center is 20 from inner edge")

    -- Midpoint of ring (35 from center) - positive
    local mid = ring:signedDistance(135, 100)
    assertTrue(mid > 0, "inside ring is positive")
    assertNear(mid, 15, 0.001, "midpoint is 15 from nearest edge")

    -- Outside outer - negative
    assertTrue(ring:signedDistance(160, 100) < 0, "outside outer is negative")
end)

--------------------------------------------------------------------------------
-- HYSTERESIS TRACKING TESTS
--------------------------------------------------------------------------------

test("Forms.track with hysteresis stores margins", function()
    local c = Forms.circle(100, 100, 50)
    local tracker = Forms.track(c, {
        enterMargin = 5,
        exitMargin = 10,
        onEnter = function() end
    })

    assertEq(tracker.enterMargin, 5, "enterMargin stored")
    assertEq(tracker.exitMargin, 10, "exitMargin stored")
    assertTrue(tracker.hasHysteresis, "hasHysteresis flag set")
end)

test("hysteresis: entity must be inside enterMargin to trigger enter", function()
    local c = Forms.circle(100, 100, 50)
    local entered = {}
    local tracker = Forms.track(c, {
        enterMargin = 10,
        exitMargin = 5,
        onEnter = function(e) entered[#entered + 1] = e end
    })

    -- Entity exactly on boundary (signedDistance = 0) - should NOT enter
    local onEdge = { id = 1, x = 150, y = 100 }
    Forms.updateTracker(tracker, { onEdge }, 0.016)
    assertEq(#entered, 0, "on boundary should not enter with enterMargin=10")

    -- Entity 5 inside (signedDistance = 5) - still < enterMargin, should NOT enter
    onEdge.x = 145
    Forms.updateTracker(tracker, { onEdge }, 0.016)
    assertEq(#entered, 0, "5 inside should not enter with enterMargin=10")

    -- Entity 15 inside (signedDistance = 15) - > enterMargin, should enter
    onEdge.x = 135
    Forms.updateTracker(tracker, { onEdge }, 0.016)
    assertEq(#entered, 1, "15 inside should enter with enterMargin=10")
end)

test("hysteresis: entity must be outside exitMargin to trigger exit", function()
    local c = Forms.circle(100, 100, 50)
    local exited = {}
    local tracker = Forms.track(c, {
        enterMargin = 5,
        exitMargin = 10,
        onEnter = function() end,
        onExit = function(e) exited[#exited + 1] = e end
    })

    -- Start inside (signedDistance = 40, well past enterMargin)
    local entity = { id = 1, x = 110, y = 100 }
    Forms.updateTracker(tracker, { entity }, 0.016)

    -- Move to boundary (signedDistance = 0) - should NOT exit (still > -exitMargin)
    entity.x = 150
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(#exited, 0, "on boundary should not exit with exitMargin=10")

    -- Move 5 outside (signedDistance = -5) - still > -exitMargin, should NOT exit
    entity.x = 155
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(#exited, 0, "5 outside should not exit with exitMargin=10")

    -- Move 15 outside (signedDistance = -15) - < -exitMargin, should exit
    entity.x = 165
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(#exited, 1, "15 outside should exit with exitMargin=10")
end)

test("hysteresis prevents flickering at boundary", function()
    local c = Forms.circle(100, 100, 50)
    local enters = 0
    local exits = 0
    local tracker = Forms.track(c, {
        enterMargin = 10,
        exitMargin = 10,
        onEnter = function() enters = enters + 1 end,
        onExit = function() exits = exits + 1 end
    })

    local entity = { id = 1, x = 100, y = 100 }  -- Start deep inside
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(enters, 1, "initial enter")

    -- Hover around the boundary - should NOT flicker
    entity.x = 148  -- 2 inside boundary
    Forms.updateTracker(tracker, { entity }, 0.016)
    entity.x = 152  -- 2 outside boundary
    Forms.updateTracker(tracker, { entity }, 0.016)
    entity.x = 148
    Forms.updateTracker(tracker, { entity }, 0.016)
    entity.x = 152
    Forms.updateTracker(tracker, { entity }, 0.016)

    -- Should still be only 1 enter, 0 exits (inside hysteresis band)
    assertEq(enters, 1, "no extra enters during boundary hover")
    assertEq(exits, 0, "no exits during boundary hover")

    -- Move far outside
    entity.x = 170
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(exits, 1, "exit when far outside")
end)

test("tracker without hysteresis uses simple containment", function()
    local c = Forms.circle(100, 100, 50)
    local enters = 0
    local tracker = Forms.track(c, {
        onEnter = function() enters = enters + 1 end
    })

    assertFalse(tracker.hasHysteresis, "no hysteresis flag")

    -- Entity exactly on boundary (signedDistance = 0) - should enter (contains=true on boundary)
    local entity = { id = 1, x = 150, y = 100 }
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(enters, 1, "on boundary enters without hysteresis")
end)

test("rect hysteresis works correctly", function()
    local r = Forms.rect(100, 100, 50, 50)
    local enters = 0
    local exits = 0
    local tracker = Forms.track(r, {
        enterMargin = 5,
        exitMargin = 5,
        onEnter = function() enters = enters + 1 end,
        onExit = function() exits = exits + 1 end
    })

    -- Deep inside
    local entity = { id = 1, x = 100, y = 100 }
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(enters, 1, "enters rect")

    -- Move to boundary
    entity.x = 150
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(exits, 0, "on boundary doesn't exit")

    -- Move outside margin
    entity.x = 160
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(exits, 1, "exits when past margin")
end)

--------------------------------------------------------------------------------
-- THROTTLE TRACKING TESTS
--------------------------------------------------------------------------------

test("Forms.track with throttle stores config", function()
    local c = Forms.circle(100, 100, 50)
    local tracker = Forms.track(c, {
        enterThrottle = 1.0,
        exitThrottle = 0.5,
        onEnter = function() end
    })

    assertEq(tracker.enterThrottle, 1.0, "enterThrottle stored")
    assertEq(tracker.exitThrottle, 0.5, "exitThrottle stored")
    assertTrue(tracker.hasThrottle, "hasThrottle flag set")
end)

test("throttle: enterThrottle prevents rapid re-entry", function()
    S.setGlobal("time", 0)

    local c = Forms.circle(100, 100, 50)
    local enters = 0
    local tracker = Forms.track(c, {
        enterThrottle = 1.0,  -- must wait 1s after exit to re-enter
        onEnter = function() enters = enters + 1 end,
        onExit = function() end
    })

    local entity = { id = 1, x = 100, y = 100 }

    -- Enter at t=0
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(enters, 1, "first enter")

    -- Exit at t=0.1
    S.setGlobal("time", 0.1)
    entity.x = 200
    Forms.updateTracker(tracker, { entity }, 0.016)

    -- Try to re-enter at t=0.2 (only 0.1s after exit, throttle is 1.0s)
    S.setGlobal("time", 0.2)
    entity.x = 100
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(enters, 1, "re-entry blocked by throttle")

    -- Re-enter at t=1.5 (1.4s after exit, past throttle)
    S.setGlobal("time", 1.5)
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(enters, 2, "re-entry allowed after throttle")

    S.clearGlobals()
end)

test("throttle: exitThrottle prevents rapid exit", function()
    S.setGlobal("time", 0)

    local c = Forms.circle(100, 100, 50)
    local exits = 0
    local tracker = Forms.track(c, {
        exitThrottle = 0.5,  -- must wait 0.5s after enter to exit
        onEnter = function() end,
        onExit = function() exits = exits + 1 end
    })

    local entity = { id = 1, x = 100, y = 100 }

    -- Enter at t=0
    Forms.updateTracker(tracker, { entity }, 0.016)

    -- Try to exit at t=0.1 (only 0.1s after enter, throttle is 0.5s)
    S.setGlobal("time", 0.1)
    entity.x = 200
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(exits, 0, "exit blocked by throttle")

    -- Exit at t=0.6 (0.6s after enter, past throttle)
    S.setGlobal("time", 0.6)
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(exits, 1, "exit allowed after throttle")

    S.clearGlobals()
end)

test("throttle: asymmetric throttles work (safe zone pattern)", function()
    S.setGlobal("time", 0)

    -- Safe zone: instant entry (0s), slow exit (2s)
    local c = Forms.circle(100, 100, 50)
    local enters = 0
    local exits = 0
    local tracker = Forms.track(c, {
        enterThrottle = 0,    -- instant entry
        exitThrottle = 2.0,   -- must stay inside 2s before can exit
        onEnter = function() enters = enters + 1 end,
        onExit = function() exits = exits + 1 end
    })

    local entity = { id = 1, x = 100, y = 100 }

    -- Enter at t=0
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(enters, 1, "instant entry")

    -- Try to exit at t=0.5
    S.setGlobal("time", 0.5)
    entity.x = 200
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(exits, 0, "can't exit yet (protected)")

    -- Try to exit at t=1.5
    S.setGlobal("time", 1.5)
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(exits, 0, "still can't exit (protected)")

    -- Exit at t=2.5
    S.setGlobal("time", 2.5)
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(exits, 1, "can exit now")

    -- Re-enter immediately (no enter throttle)
    S.setGlobal("time", 2.6)
    entity.x = 100
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(enters, 2, "instant re-entry")

    S.clearGlobals()
end)

test("throttle: tracker without throttle works normally", function()
    S.setGlobal("time", 0)

    local c = Forms.circle(100, 100, 50)
    local enters = 0
    local exits = 0
    local tracker = Forms.track(c, {
        onEnter = function() enters = enters + 1 end,
        onExit = function() exits = exits + 1 end
    })

    assertFalse(tracker.hasThrottle, "no throttle flag")

    local entity = { id = 1, x = 100, y = 100 }

    -- Rapid enter/exit/enter should work
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(enters, 1, "enter")

    entity.x = 200
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(exits, 1, "exit")

    entity.x = 100
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(enters, 2, "immediate re-enter works without throttle")

    S.clearGlobals()
end)

test("throttle: combined with hysteresis", function()
    S.setGlobal("time", 0)

    local c = Forms.circle(100, 100, 50)
    local enters = 0
    local exits = 0
    local tracker = Forms.track(c, {
        enterMargin = 5,
        exitMargin = 5,
        enterThrottle = 1.0,
        exitThrottle = 0.5,
        onEnter = function() enters = enters + 1 end,
        onExit = function() exits = exits + 1 end
    })

    assertTrue(tracker.hasHysteresis, "has hysteresis")
    assertTrue(tracker.hasThrottle, "has throttle")

    local entity = { id = 1, x = 100, y = 100 }

    -- Deep inside
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(enters, 1, "enters")

    -- Move to edge at t=0.1 (inside hysteresis band, exit blocked by throttle anyway)
    S.setGlobal("time", 0.1)
    entity.x = 152
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(exits, 0, "no exit (hysteresis + throttle)")

    -- Move far outside at t=0.6 (past exit throttle, past hysteresis)
    S.setGlobal("time", 0.6)
    entity.x = 200
    Forms.updateTracker(tracker, { entity }, 0.016)
    assertEq(exits, 1, "exits (past throttle and hysteresis)")

    S.clearGlobals()
end)

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------

local success = runTests()
os.exit(success and 0 or 1)
