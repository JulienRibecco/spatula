-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "bootstrap.lua")
-- tests/trigger_test.lua
-- Tests for Trigger module: timing, selection, events
-- Run with: lua5.4 tests/trigger_test.lua

package.path = package.path .. ";../?.lua;../?/init.lua"
package.preload["spatula.point"] = function() return require("point") end
package.preload["spatula.curve"] = function() return require("curve") end
package.preload["spatula.util"] = function() return require("util") end

local Trigger = require("trigger")

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
    print("Running Trigger tests...\n")
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
-- TIMING TESTS
--------------------------------------------------------------------------------

test("Trigger.timing.interval fires at regular intervals", function()
    local timing = Trigger.timing.interval(0.5)

    -- Interval starts with last = -0.5, so first call fires immediately
    assertTrue(timing(0), "first call should fire (last starts at -interval)")
    assertFalse(timing(0.3), "shouldn't fire before next interval")
    assertTrue(timing(0.5), "should fire at interval")
    assertFalse(timing(0.6), "shouldn't fire immediately after")
    assertTrue(timing(1.0), "should fire at next interval")
end)

test("Trigger.timing.once fires exactly once", function()
    local timing = Trigger.timing.once(0.5)

    assertFalse(timing(0.3), "shouldn't fire before delay")
    assertTrue(timing(0.5), "should fire at delay")
    assertFalse(timing(0.6), "shouldn't fire again")
    assertFalse(timing(1.0), "shouldn't fire again")
end)

test("Trigger.timing.probability fires randomly", function()
    local timing = Trigger.timing.probability(0.5)

    -- Run many times, should fire roughly half
    local fires = 0
    for _ = 1, 100 do
        if timing(0) then fires = fires + 1 end
    end

    assertTrue(fires > 20, "should fire some times")
    assertTrue(fires < 80, "shouldn't fire all times")
end)

test("Trigger.timing.times fires n times then stops", function()
    local timing = Trigger.timing.times(3, 0.1)

    assertTrue(timing(0), "fire 1")
    assertTrue(timing(0.1), "fire 2")
    assertTrue(timing(0.2), "fire 3")
    assertFalse(timing(0.3), "shouldn't fire 4th time")
    assertFalse(timing(0.4), "shouldn't fire 5th time")
end)

test("Trigger.timing.burst fires burst then waits", function()
    local timing = Trigger.timing.burst(3, 0.1, 1.0)

    -- First burst
    assertTrue(timing(0), "burst fire 1")
    assertTrue(timing(0.1), "burst fire 2")
    assertTrue(timing(0.2), "burst fire 3")
    assertFalse(timing(0.3), "burst complete, waiting")
    assertFalse(timing(0.5), "still waiting")

    -- Next burst after delay
    assertTrue(timing(1.0), "next burst fire 1")
end)

--------------------------------------------------------------------------------
-- SELECTION TESTS
--------------------------------------------------------------------------------

test("Trigger.select.all returns all points", function()
    local selector = Trigger.select.all()
    local points = {{x=1, y=10}, {x=2, y=20}, {x=3, y=30}}

    local count = 0
    for idx, x, y in selector(points) do
        count = count + 1
    end
    assertEq(count, 3, "should return all points")
end)

test("Trigger.select.random returns n points", function()
    local selector = Trigger.select.random(2)
    local points = {{x=1, y=10}, {x=2, y=20}, {x=3, y=30}, {x=4, y=40}}

    local count = 0
    for idx, x, y in selector(points) do
        count = count + 1
    end
    assertEq(count, 2, "should return 2 points")
end)

test("Trigger.select.random with n > points returns all", function()
    local selector = Trigger.select.random(10)
    local points = {{x=1, y=10}, {x=2, y=20}}

    local count = 0
    for idx, x, y in selector(points) do
        count = count + 1
    end
    assertEq(count, 2, "should return all available")
end)

test("Trigger.select.sequential cycles through points", function()
    local selector = Trigger.select.sequential()
    local points = {{x=1, y=10}, {x=2, y=20}, {x=3, y=30}}

    -- First call
    local x1
    for idx, x, y in selector(points) do
        x1 = x
        break
    end

    -- Second call
    local x2
    for idx, x, y in selector(points) do
        x2 = x
        break
    end

    -- Third call
    local x3
    for idx, x, y in selector(points) do
        x3 = x
        break
    end

    assertEq(x1, 1, "first call")
    assertEq(x2, 2, "second call")
    assertEq(x3, 3, "third call")
end)

test("Trigger.select.first returns first n", function()
    local selector = Trigger.select.first(2)
    local points = {{x=1, y=10}, {x=2, y=20}, {x=3, y=30}}

    local xs = {}
    for idx, x, y in selector(points) do
        xs[#xs + 1] = x
    end

    assertEq(#xs, 2, "should return 2")
    assertEq(xs[1], 1, "first")
    assertEq(xs[2], 2, "second")
end)

test("Trigger.select.last returns last n", function()
    local selector = Trigger.select.last(2)
    local points = {{x=1, y=10}, {x=2, y=20}, {x=3, y=30}}

    local xs = {}
    for idx, x, y in selector(points) do
        xs[#xs + 1] = x
    end

    assertEq(#xs, 2, "should return 2")
    assertEq(xs[1], 2, "second to last")
    assertEq(xs[2], 3, "last")
end)

test("Trigger.select.where filters by predicate", function()
    local selector = Trigger.select.where(function(p)
        return p.x > 1
    end)
    local points = {{x=1, y=10}, {x=2, y=20}, {x=3, y=30}}

    local count = 0
    for idx, x, y in selector(points) do
        count = count + 1
        assertTrue(x > 1, "filtered point should have x > 1")
    end
    assertEq(count, 2, "should return 2 filtered points")
end)

--------------------------------------------------------------------------------
-- TRIGGER CREATION TESTS
--------------------------------------------------------------------------------

test("Trigger.new creates trigger with config", function()
    local trigger = Trigger.new({
        timing = Trigger.timing.interval(0.1),
        select = Trigger.select.all(),
        action = function() end
    })

    assertTrue(trigger.timing ~= nil, "should have timing")
    assertTrue(trigger.select ~= nil, "should have select")
    assertTrue(trigger.action ~= nil, "should have action")
    assertTrue(trigger.enabled, "should be enabled by default")
end)

test("Trigger.new with defaults", function()
    local trigger = Trigger.new({})

    assertTrue(trigger.timing ~= nil, "should have default timing")
    assertTrue(trigger.select ~= nil, "should have default select")
end)

test("Trigger.update fires action on points", function()
    local fired = {}
    local trigger = Trigger.new({
        timing = Trigger.timing.interval(0.1),
        select = Trigger.select.all(),
        action = function(x, y, ctx)
            fired[#fired + 1] = {x = x, y = y}
        end
    })

    local points = {{x=100, y=200}, {x=300, y=400}}

    -- Update at t=0, fires immediately (interval starts ready)
    Trigger.update(trigger, points, 0, 0.05, {})
    assertEq(#fired, 2, "should fire immediately on first update")
    assertEq(fired[1].x, 100, "first point x")
    assertEq(fired[2].x, 300, "second point x")

    -- Update at t=0.05, shouldn't fire (interval not reached)
    Trigger.update(trigger, points, 0.05, 0.05, {})
    assertEq(#fired, 2, "shouldn't fire before next interval")

    -- Update at t=0.1, should fire again
    Trigger.update(trigger, points, 0.1, 0.05, {})
    assertEq(#fired, 4, "should fire at next interval")
end)

test("Trigger.update with selection", function()
    local fired = {}
    local trigger = Trigger.new({
        timing = Trigger.timing.interval(0.1),
        select = Trigger.select.first(1),
        action = function(x, y, ctx)
            fired[#fired + 1] = x
        end
    })

    local points = {{x=1, y=0}, {x=2, y=0}, {x=3, y=0}}
    Trigger.update(trigger, points, 0.1, 0.05, {})

    assertEq(#fired, 1, "should only select first")
    assertEq(fired[1], 1, "should be first point")
end)

test("Trigger.update respects enabled flag", function()
    local fired = 0
    local trigger = Trigger.new({
        timing = Trigger.timing.interval(0.1),
        select = Trigger.select.all(),
        action = function() fired = fired + 1 end,
        enabled = false
    })

    Trigger.update(trigger, {{x=1, y=0}}, 0.1, 0.05, {})
    assertEq(fired, 0, "disabled trigger shouldn't fire")
end)

test("Trigger.update with empty points doesn't fire", function()
    local fired = 0
    local trigger = Trigger.new({
        timing = Trigger.timing.interval(0.1),
        select = Trigger.select.all(),
        action = function() fired = fired + 1 end
    })

    Trigger.update(trigger, {}, 0.1, 0.05, {})
    assertEq(fired, 0, "empty points shouldn't fire action")
end)

test("Trigger.update batch mode", function()
    local batchResults = nil
    local batchCount = 0
    local trigger = Trigger.new({
        timing = Trigger.timing.interval(0.1),
        select = Trigger.select.all(),
        batchAction = function(batch, count, t, dt)
            batchResults = batch
            batchCount = count
        end
    })

    local points = {{x=1, y=10}, {x=2, y=20}}
    Trigger.update(trigger, points, 0.1, 0.05, {})

    assertEq(batchCount, 2, "batch should have 2 entries")
    assertEq(batchResults[1].x, 1, "first batch entry")
    assertEq(batchResults[2].x, 2, "second batch entry")
end)

--------------------------------------------------------------------------------
-- INTEGRATION TESTS
--------------------------------------------------------------------------------

test("Multiple updates accumulate correctly", function()
    local count = 0
    local trigger = Trigger.new({
        timing = Trigger.timing.interval(0.1),
        select = Trigger.select.all(),
        action = function() count = count + 1 end
    })

    local points = {{x=1, y=0}}

    -- First update fires immediately (interval starts ready)
    Trigger.update(trigger, points, 0, 0.05, {})     -- t=0
    assertEq(count, 1, "first fire at t=0")

    Trigger.update(trigger, points, 0.05, 0.05, {})  -- t=0.05
    assertEq(count, 1, "no fire, waiting")

    Trigger.update(trigger, points, 0.1, 0.05, {})   -- t=0.1
    assertEq(count, 2, "second fire")

    Trigger.update(trigger, points, 0.15, 0.05, {})  -- t=0.15
    assertEq(count, 2, "no fire, waiting")

    Trigger.update(trigger, points, 0.2, 0.05, {})   -- t=0.2
    assertEq(count, 3, "third fire")
end)

test("Action receives context", function()
    local receivedCtx = nil
    local trigger = Trigger.new({
        timing = Trigger.timing.interval(0.1),
        select = Trigger.select.all(),
        action = function(x, y, ctx)
            receivedCtx = ctx
        end
    })

    Trigger.update(trigger, {{x=1, y=0}}, 0.1, 0.05, {})

    assertTrue(receivedCtx ~= nil, "should receive context")
    assertTrue(receivedCtx.idx ~= nil, "context should have idx")
    assertTrue(receivedCtx.total ~= nil, "context should have total")
end)

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------

local success = runTests()
os.exit(success and 0 or 1)
