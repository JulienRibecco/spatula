-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
-- tests/test_form_pool.lua
-- Tests for FormPool batch containment
-- Run with: lua5.4 tests/test_form_pool.lua

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
    print("Running FormPool tests...\n")
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

test("createFormPool creates pool object", function()
    local formIR = IR.form.circle(0, 0, 100)
    local pool = Compiler.createFormPool(formIR, { count = 100 })

    assertTrue(pool ~= nil, "pool should exist")
    assertEq(pool.count, 100, "count")
    assertTrue(pool.contains ~= nil, "should have contains function")
    assertTrue(pool.results ~= nil, "should have results array")
end)

test("createFormPool with default count", function()
    local formIR = IR.form.circle(0, 0, 100)
    local pool = Compiler.createFormPool(formIR)

    assertEq(pool.count, 100, "default count should be 100")
end)

test("single contains works", function()
    local formIR = IR.form.circle(0, 0, 100)
    local pool = Compiler.createFormPool(formIR)

    assertTrue(pool:contains(0, 0), "center inside")
    assertTrue(pool:contains(50, 0), "edge inside")
    assertFalse(pool:contains(150, 0), "outside")
end)

--------------------------------------------------------------------------------
-- BATCH CONTAINMENT TESTS
--------------------------------------------------------------------------------

test("containsBatch returns correct count", function()
    local formIR = IR.form.circle(0, 0, 100)
    local pool = Compiler.createFormPool(formIR, { count = 10 })

    local xs = {0, 50, 150, 25, 200}
    local ys = {0, 0, 0, 25, 0}

    local count = pool:containsBatch(xs, ys, 5)
    assertEq(count, 3, "3 points inside")
end)

test("containsBatch fills results array", function()
    local formIR = IR.form.circle(0, 0, 100)
    local pool = Compiler.createFormPool(formIR, { count = 10 })

    local xs = {0, 150, 50, 200, 25}
    local ys = {0, 0, 0, 0, 25}

    local count = pool:containsBatch(xs, ys, 5)
    assertEq(count, 3, "3 points inside")

    -- Check indices
    assertEq(pool.results[1], 1, "first inside is index 1")
    assertEq(pool.results[2], 3, "second inside is index 3")
    assertEq(pool.results[3], 5, "third inside is index 5")
end)

test("containsBatch with empty array", function()
    local formIR = IR.form.circle(0, 0, 100)
    local pool = Compiler.createFormPool(formIR)

    local count = pool:containsBatch({}, {}, 0)
    assertEq(count, 0, "no points")
end)

test("containsBatch with all inside", function()
    local formIR = IR.form.circle(0, 0, 100)
    local pool = Compiler.createFormPool(formIR)

    local xs = {0, 10, 20, 30}
    local ys = {0, 10, 20, 30}

    local count = pool:containsBatch(xs, ys, 4)
    assertEq(count, 4, "all inside")
end)

test("containsBatch with all outside", function()
    local formIR = IR.form.circle(0, 0, 100)
    local pool = Compiler.createFormPool(formIR)

    local xs = {200, 300, 400}
    local ys = {0, 0, 0}

    local count = pool:containsBatch(xs, ys, 3)
    assertEq(count, 0, "none inside")
end)

test("containsBatch with complex form", function()
    -- Donut: outer radius 100, inner radius 50
    local formIR = IR.form.ring(0, 0, 100, 50)
    local pool = Compiler.createFormPool(formIR)

    local xs = {0, 75, 25, 150}
    local ys = {0, 0, 0, 0}

    local count = pool:containsBatch(xs, ys, 4)
    -- 0,0 is in hole, 75,0 is in ring, 25,0 is in hole, 150,0 is outside
    assertEq(count, 1, "only one in ring")
    assertEq(pool.results[1], 2, "index 2 (75,0) is in ring")
end)

--------------------------------------------------------------------------------
-- BATCH BOOL TESTS
--------------------------------------------------------------------------------

test("containsBatchBool returns boolean array", function()
    local formIR = IR.form.circle(0, 0, 100)
    local pool = Compiler.createFormPool(formIR)

    local xs = {0, 150, 50}
    local ys = {0, 0, 0}

    local results = pool:containsBatchBool(xs, ys, 3)
    assertTrue(results[1], "first inside")
    assertFalse(results[2], "second outside")
    assertTrue(results[3], "third inside")
end)

test("containsBatchBool with preallocated array", function()
    local formIR = IR.form.circle(0, 0, 100)
    local pool = Compiler.createFormPool(formIR)

    local xs = {0, 150}
    local ys = {0, 0}
    local out = {}

    pool:containsBatchBool(xs, ys, 2, out)
    assertTrue(out[1], "first inside")
    assertFalse(out[2], "second outside")
end)

--------------------------------------------------------------------------------
-- HELPER METHOD TESTS
--------------------------------------------------------------------------------

test("getResultCount returns last batch count", function()
    local formIR = IR.form.circle(0, 0, 100)
    local pool = Compiler.createFormPool(formIR)

    pool:containsBatch({0, 150, 50}, {0, 0, 0}, 3)
    assertEq(pool:getResultCount(), 2, "2 inside")
end)

test("insideIter iterates over inside indices", function()
    local formIR = IR.form.circle(0, 0, 100)
    local pool = Compiler.createFormPool(formIR)

    pool:containsBatch({0, 150, 50, 200, 25}, {0, 0, 0, 0, 0}, 5)

    local collected = {}
    for idx in pool:insideIter() do
        collected[#collected + 1] = idx
    end

    assertEq(#collected, 3, "3 inside")
    assertEq(collected[1], 1, "first")
    assertEq(collected[2], 3, "second")
    assertEq(collected[3], 5, "third")
end)

--------------------------------------------------------------------------------
-- PERFORMANCE PATTERN TESTS
--------------------------------------------------------------------------------

test("reusing pool across frames", function()
    local formIR = IR.form.circle(0, 0, 100)
    local pool = Compiler.createFormPool(formIR, { count = 10 })

    -- Frame 1
    local count1 = pool:containsBatch({0, 150}, {0, 0}, 2)
    assertEq(count1, 1, "frame 1")

    -- Frame 2 - different entities
    local count2 = pool:containsBatch({0, 50, 75}, {0, 0, 0}, 3)
    assertEq(count2, 3, "frame 2")

    -- Results from frame 2, not frame 1
    assertEq(pool:getResultCount(), 3, "frame 2 count")
end)

test("large batch performance", function()
    local formIR = IR.form.circle(0, 0, 100)
    local pool = Compiler.createFormPool(formIR, { count = 1000 })

    -- Create 1000 entities
    local xs, ys = {}, {}
    for i = 1, 1000 do
        xs[i] = (i % 200) - 100  -- -100 to 99
        ys[i] = ((i * 7) % 200) - 100
    end

    local count = pool:containsBatch(xs, ys, 1000)
    assertTrue(count > 0, "some inside")
    assertTrue(count < 1000, "not all inside")
end)

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------

local success = runTests()
os.exit(success and 0 or 1)
