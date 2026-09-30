-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
-- tests/test_trigger_pool.lua
-- Tests for TriggerPool multi-instance management
-- Run with: lua5.4 tests/test_trigger_pool.lua

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
    print("Running TriggerPool tests...\n")
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
-- POOL CREATION TESTS
--------------------------------------------------------------------------------

test("createTriggerPool creates pool object", function()
    local timing = IR.trigger.interval(0.5)
    local selection = IR.trigger.selectAll()
    local pool = Compiler.createTriggerPool(timing, selection, { count = 5 })

    assertTrue(pool ~= nil, "pool should exist")
    assertEq(pool.count, 5, "count")
    assertTrue(pool.trigger ~= nil, "should have trigger function")
    assertTrue(pool.contexts ~= nil, "should have contexts")
    assertEq(#pool.contexts, 5, "should have 5 contexts")
end)

test("createTriggerPool with default count", function()
    local timing = IR.trigger.interval(0.5)
    local selection = IR.trigger.selectAll()
    local pool = Compiler.createTriggerPool(timing, selection)

    assertEq(pool.count, 1, "default count should be 1")
end)

--------------------------------------------------------------------------------
-- INDEPENDENT CONTEXT TESTS
--------------------------------------------------------------------------------

test("each instance has independent context", function()
    local timing = IR.trigger.interval(0.5)
    local selection = IR.trigger.selectAll()
    local pool = Compiler.createTriggerPool(timing, selection, { count = 3 })

    local points = {{x = 1, y = 2}}
    local fired = {0, 0, 0}

    -- Fire instance 1 at t=0
    pool:update(1, points, 0, function() fired[1] = fired[1] + 1 end)

    -- Fire instance 2 at t=0.1 (should also fire - first call)
    pool:update(2, points, 0.1, function() fired[2] = fired[2] + 1 end)

    -- Instance 3 not yet called
    assertEq(fired[1], 1, "instance 1 fired")
    assertEq(fired[2], 1, "instance 2 fired")
    assertEq(fired[3], 0, "instance 3 not fired")
end)

test("instances maintain separate timing state", function()
    local timing = IR.trigger.interval(0.5)
    local selection = IR.trigger.selectAll()
    local pool = Compiler.createTriggerPool(timing, selection, { count = 2 })

    local points = {{x = 1, y = 2}}
    local fired = {0, 0}

    -- Instance 1 fires at t=0
    pool:update(1, points, 0, function() fired[1] = fired[1] + 1 end)
    assertEq(fired[1], 1, "i1 first fire")

    -- Instance 2 fires at t=0.3
    pool:update(2, points, 0.3, function() fired[2] = fired[2] + 1 end)
    assertEq(fired[2], 1, "i2 first fire")

    -- Instance 1 at t=0.4 - hasn't reached 0.5 interval yet
    pool:update(1, points, 0.4, function() fired[1] = fired[1] + 1 end)
    assertEq(fired[1], 1, "i1 waiting")

    -- Instance 1 at t=0.5 - fires
    pool:update(1, points, 0.5, function() fired[1] = fired[1] + 1 end)
    assertEq(fired[1], 2, "i1 second fire")

    -- Instance 2 at t=0.5 - hasn't reached 0.8 yet
    pool:update(2, points, 0.5, function() fired[2] = fired[2] + 1 end)
    assertEq(fired[2], 1, "i2 still waiting")

    -- Instance 2 at t=0.8 - fires
    pool:update(2, points, 0.8, function() fired[2] = fired[2] + 1 end)
    assertEq(fired[2], 2, "i2 second fire")
end)

--------------------------------------------------------------------------------
-- UPDATE ALL TESTS
--------------------------------------------------------------------------------

test("updateAll fires all instances", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectAll()
    local pool = Compiler.createTriggerPool(timing, selection, { count = 3 })

    local points = {{x = 1, y = 2}}
    local firedInstances = {}

    pool:updateAll(points, 0, function(x, y, ctx, instanceIdx)
        firedInstances[instanceIdx] = true
    end)

    assertTrue(firedInstances[1], "instance 1 fired")
    assertTrue(firedInstances[2], "instance 2 fired")
    assertTrue(firedInstances[3], "instance 3 fired")
end)

test("updateAll passes instance index", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectAll()
    local pool = Compiler.createTriggerPool(timing, selection, { count = 2 })

    local points = {{x = 100, y = 200}}
    local results = {}

    pool:updateAll(points, 0, function(x, y, ctx, instanceIdx)
        results[instanceIdx] = {x = x, y = y}
    end)

    assertEq(results[1].x, 100, "instance 1 x")
    assertEq(results[2].x, 100, "instance 2 x")
end)

--------------------------------------------------------------------------------
-- UPDATE EACH TESTS
--------------------------------------------------------------------------------

test("updateEach uses per-instance points", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectAll()
    local pool = Compiler.createTriggerPool(timing, selection, { count = 2 })

    local pointsArray = {
        {{x = 10, y = 20}},
        {{x = 30, y = 40}}
    }
    local results = {}

    pool:updateEach(pointsArray, 0, function(x, y, ctx, instanceIdx)
        results[instanceIdx] = {x = x, y = y}
    end)

    assertEq(results[1].x, 10, "instance 1 uses its points")
    assertEq(results[2].x, 30, "instance 2 uses its points")
end)

--------------------------------------------------------------------------------
-- RESET TESTS
--------------------------------------------------------------------------------

test("reset clears single instance state", function()
    local timing = IR.trigger.interval(0.5)
    local selection = IR.trigger.selectAll()
    local pool = Compiler.createTriggerPool(timing, selection, { count = 2 })

    local points = {{x = 1, y = 2}}
    local fired = {0, 0}

    -- Both fire at t=0
    pool:update(1, points, 0, function() fired[1] = fired[1] + 1 end)
    pool:update(2, points, 0, function() fired[2] = fired[2] + 1 end)

    -- Reset instance 1
    pool:reset(1)

    -- At t=0.1, instance 1 fires again (reset), instance 2 doesn't
    pool:update(1, points, 0.1, function() fired[1] = fired[1] + 1 end)
    pool:update(2, points, 0.1, function() fired[2] = fired[2] + 1 end)

    assertEq(fired[1], 2, "instance 1 fired again after reset")
    assertEq(fired[2], 1, "instance 2 still waiting")
end)

test("resetAll clears all instance states", function()
    local timing = IR.trigger.interval(0.5)
    local selection = IR.trigger.selectAll()
    local pool = Compiler.createTriggerPool(timing, selection, { count = 2 })

    local points = {{x = 1, y = 2}}
    local fired = {0, 0}

    -- Both fire at t=0
    pool:update(1, points, 0, function() fired[1] = fired[1] + 1 end)
    pool:update(2, points, 0, function() fired[2] = fired[2] + 1 end)

    -- Reset all
    pool:resetAll()

    -- At t=0.1, both fire again
    pool:update(1, points, 0.1, function() fired[1] = fired[1] + 1 end)
    pool:update(2, points, 0.1, function() fired[2] = fired[2] + 1 end)

    assertEq(fired[1], 2, "instance 1 fired again")
    assertEq(fired[2], 2, "instance 2 fired again")
end)

--------------------------------------------------------------------------------
-- CONTEXT ACCESS TESTS
--------------------------------------------------------------------------------

test("getContext returns instance context", function()
    local timing = IR.trigger.interval(0.5)
    local selection = IR.trigger.selectAll()
    local pool = Compiler.createTriggerPool(timing, selection, { count = 2 })

    local ctx1 = pool:getContext(1)
    local ctx2 = pool:getContext(2)

    assertTrue(ctx1 ~= nil, "context 1 exists")
    assertTrue(ctx2 ~= nil, "context 2 exists")
    assertTrue(ctx1 ~= ctx2, "contexts are different")
end)

test("context persists between updates", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectAll()
    local pool = Compiler.createTriggerPool(timing, selection, { count = 1 })

    local points = {{x = 1, y = 2}}

    -- Fire to populate context
    pool:update(1, points, 0, function() end)

    local ctx = pool:getContext(1)
    assertTrue(ctx._lastFire ~= nil, "context has timing state")
end)

--------------------------------------------------------------------------------
-- RESIZE TESTS
--------------------------------------------------------------------------------

test("resize increases count", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectAll()
    local pool = Compiler.createTriggerPool(timing, selection, { count = 2 })

    assertEq(pool.count, 2, "initial count")

    pool:resize(5)
    assertEq(pool.count, 5, "new count")
    assertEq(#pool.contexts, 5, "contexts expanded")

    -- New instances should work
    local points = {{x = 1, y = 2}}
    local fired = false
    pool:update(5, points, 0, function() fired = true end)
    assertTrue(fired, "new instance works")
end)

test("resize decreases count", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectAll()
    local pool = Compiler.createTriggerPool(timing, selection, { count = 5 })

    pool:resize(2)
    assertEq(pool.count, 2, "new count")

    -- Old contexts should be removed (nil)
    assertTrue(pool.contexts[3] == nil, "context 3 removed")
end)

--------------------------------------------------------------------------------
-- SELECTION PATTERN TESTS
--------------------------------------------------------------------------------

test("selectRandom with pool", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectRandom(2)
    local pool = Compiler.createTriggerPool(timing, selection, { count = 1 })

    local points = {{x = 1, y = 1}, {x = 2, y = 2}, {x = 3, y = 3}, {x = 4, y = 4}}
    local count = 0

    pool:update(1, points, 0, function()
        count = count + 1
    end)

    assertEq(count, 2, "selected 2 random points")
end)

test("selectSequential with pool", function()
    local timing = IR.trigger.interval(0.1)
    local selection = IR.trigger.selectSequential()
    local pool = Compiler.createTriggerPool(timing, selection, { count = 1 })

    local points = {{x = 1, y = 1}, {x = 2, y = 2}, {x = 3, y = 3}}
    local selected = {}

    -- First update
    pool:update(1, points, 0, function(x) selected[#selected + 1] = x end)
    -- Second update
    pool:update(1, points, 0.15, function(x) selected[#selected + 1] = x end)
    -- Third update
    pool:update(1, points, 0.3, function(x) selected[#selected + 1] = x end)

    assertEq(#selected, 3, "3 updates")
    assertEq(selected[1], 1, "first point")
    assertEq(selected[2], 2, "second point")
    assertEq(selected[3], 3, "third point")
end)

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------

local success = runTests()
os.exit(success and 0 or 1)
