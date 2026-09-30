-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
-- tests/test_trigger_compiler.lua
-- Tests for Trigger IR compilation
-- Run with: lua5.4 tests/test_trigger_compiler.lua

package.path = package.path .. ";../../../?.lua;../../../?/init.lua"

local IR = require("spatula.compiler.ir")
local Compiler = require("spatula.compiler.compiler")

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
    print("Running Trigger Compiler tests...\n")
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
-- IR STRUCTURE TESTS
--------------------------------------------------------------------------------

test("IR.trigger.interval creates correct structure", function()
    local ir = IR.trigger.interval(0.5)
    assertEq(ir.op, "triggerInterval", "op")
    assertEq(ir.interval, 0.5, "interval")
    assertEq(ir.type, "timing", "type")
end)

test("IR.trigger.times creates correct structure", function()
    local ir = IR.trigger.times(5, 0.1)
    assertEq(ir.op, "triggerTimes", "op")
    assertEq(ir.n, 5, "n")
    assertEq(ir.interval, 0.1, "interval")
end)

test("IR.trigger.burst creates correct structure", function()
    local ir = IR.trigger.burst(3, 0.1, 1.0)
    assertEq(ir.op, "triggerBurst", "op")
    assertEq(ir.count, 3, "count")
    assertEq(ir.interval, 0.1, "interval")
    assertEq(ir.pause, 1.0, "pause")
end)

test("IR.trigger.selectAll creates correct structure", function()
    local ir = IR.trigger.selectAll()
    assertEq(ir.op, "selectAll", "op")
    assertEq(ir.type, "selection", "type")
end)

test("IR.trigger.selectRandom creates correct structure", function()
    local ir = IR.trigger.selectRandom(3)
    assertEq(ir.op, "selectRandom", "op")
    assertEq(ir.n, 3, "n")
end)

test("IR.trigger.selectFirst creates correct structure", function()
    local ir = IR.trigger.selectFirst(2)
    assertEq(ir.op, "selectFirst", "op")
    assertEq(ir.n, 2, "n")
end)

test("IR.trigger.selectLast creates correct structure", function()
    local ir = IR.trigger.selectLast(2)
    assertEq(ir.op, "selectLast", "op")
    assertEq(ir.n, 2, "n")
end)

test("IR.trigger.selectSequential creates correct structure", function()
    local ir = IR.trigger.selectSequential()
    assertEq(ir.op, "selectSequential", "op")
end)

--------------------------------------------------------------------------------
-- TIMING TESTS
--------------------------------------------------------------------------------

test("Compiled interval: fires at intervals", function()
    local timing = IR.trigger.interval(0.5)
    local selection = IR.trigger.selectAll()
    local trigger = Compiler.compileTrigger(timing, selection)

    local points = {{x = 1, y = 2}}
    local ctx = {}
    local fired = 0

    local action = function() fired = fired + 1 end

    -- First call should fire immediately (ctx._lastFire starts as -inf)
    trigger(points, 0, ctx, action)
    assertEq(fired, 1, "should fire at t=0")

    -- Before interval
    trigger(points, 0.3, ctx, action)
    assertEq(fired, 1, "shouldn't fire before interval")

    -- At interval
    trigger(points, 0.5, ctx, action)
    assertEq(fired, 2, "should fire at interval")

    -- At next interval
    trigger(points, 1.0, ctx, action)
    assertEq(fired, 3, "should fire at next interval")
end)

test("Compiled times: fires n times then stops", function()
    local timing = IR.trigger.times(3, 0.1)
    local selection = IR.trigger.selectAll()
    local trigger = Compiler.compileTrigger(timing, selection)

    local points = {{x = 1, y = 2}}
    local ctx = {}
    local fired = 0

    local action = function() fired = fired + 1 end

    trigger(points, 0, ctx, action)
    assertEq(fired, 1, "fire 1")

    trigger(points, 0.1, ctx, action)
    assertEq(fired, 2, "fire 2")

    trigger(points, 0.2, ctx, action)
    assertEq(fired, 3, "fire 3")

    trigger(points, 0.3, ctx, action)
    assertEq(fired, 3, "shouldn't fire 4th time")

    trigger(points, 0.4, ctx, action)
    assertEq(fired, 3, "still shouldn't fire")
end)

test("Compiled burst: fires burst then pauses", function()
    local timing = IR.trigger.burst(3, 0.1, 1.0)
    local selection = IR.trigger.selectAll()
    local trigger = Compiler.compileTrigger(timing, selection)

    local points = {{x = 1, y = 2}}
    local ctx = {}
    local fired = 0

    local action = function() fired = fired + 1 end

    -- First burst
    trigger(points, 0, ctx, action)
    assertEq(fired, 1, "burst fire 1")

    trigger(points, 0.1, ctx, action)
    assertEq(fired, 2, "burst fire 2")

    trigger(points, 0.2, ctx, action)
    assertEq(fired, 3, "burst fire 3")

    -- During pause
    trigger(points, 0.3, ctx, action)
    assertEq(fired, 3, "should be waiting")

    trigger(points, 0.5, ctx, action)
    assertEq(fired, 3, "still waiting")

    -- After pause, next burst starts
    trigger(points, 1.0, ctx, action)
    assertEq(fired, 4, "next burst fire 1")
end)

--------------------------------------------------------------------------------
-- SELECTION TESTS
--------------------------------------------------------------------------------

test("Compiled selectAll: calls action for all points", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectAll()
    local trigger = Compiler.compileTrigger(timing, selection)

    local points = {{x = 1, y = 10}, {x = 2, y = 20}, {x = 3, y = 30}}
    local ctx = {}
    local results = {}

    trigger(points, 0, ctx, function(x, y)
        results[#results + 1] = {x = x, y = y}
    end)

    assertEq(#results, 3, "should call for all points")
    assertEq(results[1].x, 1, "first x")
    assertEq(results[2].x, 2, "second x")
    assertEq(results[3].x, 3, "third x")
end)

test("Compiled selectFirst: calls action for first n points", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectFirst(2)
    local trigger = Compiler.compileTrigger(timing, selection)

    local points = {{x = 1, y = 10}, {x = 2, y = 20}, {x = 3, y = 30}}
    local ctx = {}
    local results = {}

    trigger(points, 0, ctx, function(x, y)
        results[#results + 1] = x
    end)

    assertEq(#results, 2, "should call for 2 points")
    assertEq(results[1], 1, "first")
    assertEq(results[2], 2, "second")
end)

test("Compiled selectLast: calls action for last n points", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectLast(2)
    local trigger = Compiler.compileTrigger(timing, selection)

    local points = {{x = 1, y = 10}, {x = 2, y = 20}, {x = 3, y = 30}}
    local ctx = {}
    local results = {}

    trigger(points, 0, ctx, function(x, y)
        results[#results + 1] = x
    end)

    assertEq(#results, 2, "should call for 2 points")
    assertEq(results[1], 2, "second to last")
    assertEq(results[2], 3, "last")
end)

test("Compiled selectRandom: calls action for n random points", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectRandom(2)
    local trigger = Compiler.compileTrigger(timing, selection)

    local points = {{x = 1, y = 10}, {x = 2, y = 20}, {x = 3, y = 30}, {x = 4, y = 40}}
    local ctx = {}
    local count = 0

    trigger(points, 0, ctx, function()
        count = count + 1
    end)

    assertEq(count, 2, "should call for 2 points")
end)

test("Compiled selectRandom with n > points returns all", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectRandom(10)
    local trigger = Compiler.compileTrigger(timing, selection)

    local points = {{x = 1, y = 10}, {x = 2, y = 20}}
    local ctx = {}
    local count = 0

    trigger(points, 0, ctx, function()
        count = count + 1
    end)

    assertEq(count, 2, "should only call for available points")
end)

test("Compiled selectSequential: cycles through points", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectSequential()
    local trigger = Compiler.compileTrigger(timing, selection)

    local points = {{x = 1, y = 10}, {x = 2, y = 20}, {x = 3, y = 30}}
    local ctx = {}
    local results = {}

    -- Call 5 times to see cycling - use larger gaps to avoid floating point issues
    for i = 0, 4 do
        trigger(points, i * 0.15, ctx, function(x)
            results[#results + 1] = x
        end)
    end

    assertEq(#results, 5, "should call 5 times")
    assertEq(results[1], 1, "first call")
    assertEq(results[2], 2, "second call")
    assertEq(results[3], 3, "third call")
    assertEq(results[4], 1, "cycles back to first")
    assertEq(results[5], 2, "continues cycle")
end)

--------------------------------------------------------------------------------
-- EDGE CASES
--------------------------------------------------------------------------------

test("Empty points array doesn't call action", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectAll()
    local trigger = Compiler.compileTrigger(timing, selection)

    local points = {}
    local ctx = {}
    local called = false

    trigger(points, 0, ctx, function()
        called = true
    end)

    assertFalse(called, "shouldn't call action on empty points")
end)

test("Points with array format work", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectAll()
    local trigger = Compiler.compileTrigger(timing, selection)

    -- Points as {x, y} instead of {x=x, y=y}
    local points = {{100, 200}, {300, 400}}
    local ctx = {}
    local results = {}

    trigger(points, 0, ctx, function(x, y)
        results[#results + 1] = {x = x, y = y}
    end)

    assertEq(#results, 2, "should handle array format")
    assertEq(results[1].x, 100, "first x")
    assertEq(results[1].y, 200, "first y")
end)

test("Action receives ctx, idx, total", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectAll()
    local trigger = Compiler.compileTrigger(timing, selection)

    local points = {{x = 1, y = 10}, {x = 2, y = 20}}
    local ctx = { myData = "test" }
    local received = {}

    trigger(points, 0, ctx, function(x, y, passedCtx, idx, total)
        received = {ctx = passedCtx, idx = idx, total = total}
    end)

    assertEq(received.ctx.myData, "test", "should pass ctx")
    assertEq(received.total, 2, "should pass total")
    assertTrue(received.idx >= 1 and received.idx <= 2, "should pass idx")
end)

--------------------------------------------------------------------------------
-- SOURCE GENERATION TESTS
--------------------------------------------------------------------------------

test("triggerToSource generates valid code", function()
    local timing = IR.trigger.interval(0.5)
    local selection = IR.trigger.selectAll()
    local source = Compiler.triggerToSource(timing, selection)

    assertTrue(source:find("function%(points, t, ctx, action%)"), "should have function signature")
    assertTrue(source:find("ctx._lastFire"), "should have timing state")
end)

test("triggerToSource for burst + random", function()
    local timing = IR.trigger.burst(3, 0.1, 1.0)
    local selection = IR.trigger.selectRandom(2)
    local source = Compiler.triggerToSource(timing, selection)

    assertTrue(source:find("_burstCount"), "should have burst state")
    assertTrue(source:find("random"), "should have random selection")
end)

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------

local success = runTests()
os.exit(success and 0 or 1)
