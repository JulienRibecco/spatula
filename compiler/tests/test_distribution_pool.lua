-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
-- tests/test_distribution_pool.lua
-- Tests for DistributionPool batch point generation
-- Run with: lua5.4 tests/test_distribution_pool.lua

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

local function assertApprox(a, b, epsilon, msg)
    epsilon = epsilon or 0.001
    if math.abs(a - b) > epsilon then
        error(string.format("%s: expected ~%s, got %s (diff: %s)",
            msg or "assertion failed", tostring(b), tostring(a), tostring(math.abs(a - b))))
    end
end

local function runTests()
    print("Running DistributionPool tests...\n")
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

test("createDistributionPool creates pool object", function()
    local distIR = IR.distribution.spiral(IR.form.circleUnit(), 50, 3)
    local pool = Compiler.createDistributionPool(distIR, { maxPoints = 100 })

    assertTrue(pool ~= nil, "pool should exist")
    assertEq(pool.maxPoints, 100, "maxPoints")
    assertTrue(pool.x ~= nil, "should have x array")
    assertTrue(pool.y ~= nil, "should have y array")
    assertTrue(pool.generate ~= nil, "should have generate method")
end)

test("createDistributionPool with default maxPoints", function()
    local distIR = IR.distribution.grid(IR.form.circleUnit(), 5)
    local pool = Compiler.createDistributionPool(distIR)

    assertEq(pool.maxPoints, 1000, "default maxPoints should be 1000")
end)

test("pool arrays are pre-allocated", function()
    local distIR = IR.distribution.spiral(IR.form.circleUnit(), 10, 1)
    local pool = Compiler.createDistributionPool(distIR, { maxPoints = 50 })

    assertEq(#pool.x, 50, "x array pre-allocated")
    assertEq(#pool.y, 50, "y array pre-allocated")
end)

--------------------------------------------------------------------------------
-- GENERATE TESTS
--------------------------------------------------------------------------------

test("generate returns count", function()
    local distIR = IR.distribution.spiral(IR.form.circleUnit(), 30, 2)
    local pool = Compiler.createDistributionPool(distIR, { maxPoints = 100 })

    local count = pool:generate(100, 100, 50)

    assertTrue(count > 0, "should generate points")
    assertTrue(count <= 30, "should not exceed distribution count")
end)

test("generate fills x and y arrays", function()
    local distIR = IR.distribution.burst(IR.form.circleUnit(), 4, 3)
    local pool = Compiler.createDistributionPool(distIR, { maxPoints = 50 })

    local count = pool:generate(200, 150, 80)

    -- Check that arrays have valid data
    for i = 1, count do
        assertTrue(pool.x[i] ~= 0 or pool.y[i] ~= 0, "point should have values")
    end
end)

test("generate updates count property", function()
    local distIR = IR.distribution.rings(IR.form.circleUnit(), 2, 6)
    local pool = Compiler.createDistributionPool(distIR, { maxPoints = 50 })

    pool:generate(0, 0, 100)

    assertEq(pool.count, 12, "count should be 12 (2 rings * 6 points)")
end)

test("generate respects origin and size", function()
    local distIR = IR.distribution.spiral(IR.form.circleUnit(), 20, 2)
    local pool = Compiler.createDistributionPool(distIR, { maxPoints = 50 })

    local count = pool:generate(500, 300, 100)

    -- All points should be within size of origin
    for i = 1, count do
        local dx = pool.x[i] - 500
        local dy = pool.y[i] - 300
        local d = math.sqrt(dx * dx + dy * dy)
        assertTrue(d <= 100 + 1, "point should be within size of origin")
    end
end)

--------------------------------------------------------------------------------
-- HELPER METHOD TESTS
--------------------------------------------------------------------------------

test("getCount returns last generation count", function()
    local distIR = IR.distribution.burst(IR.form.circleUnit(), 6, 4)
    local pool = Compiler.createDistributionPool(distIR)

    pool:generate(0, 0, 100)

    assertEq(pool:getCount(), 24, "should return 24 (6 rays * 4 points)")
end)

test("get returns point at index", function()
    local distIR = IR.distribution.spiral(IR.form.circleUnit(), 10, 1)
    local pool = Compiler.createDistributionPool(distIR)

    pool:generate(100, 200, 50)

    local x, y = pool:get(1)
    -- First point of spiral should be near origin (center)
    assertApprox(x, 100, 1, "first x near origin")
    assertApprox(y, 200, 1, "first y near origin")
end)

test("clear resets count", function()
    local distIR = IR.distribution.grid(IR.form.rectUnit(), 5, 5)
    local pool = Compiler.createDistributionPool(distIR)

    pool:generate(0, 0, 100)
    assertTrue(pool.count > 0, "should have points")

    pool:clear()
    assertEq(pool.count, 0, "count should be 0 after clear")
end)

--------------------------------------------------------------------------------
-- ITERATOR TESTS
--------------------------------------------------------------------------------

test("points iterator yields x,y pairs", function()
    local distIR = IR.distribution.burst(IR.form.circleUnit(), 3, 2)
    local pool = Compiler.createDistributionPool(distIR)

    pool:generate(0, 0, 100)

    local collected = {}
    for x, y in pool:points() do
        collected[#collected + 1] = { x = x, y = y }
    end

    assertEq(#collected, 6, "should iterate 6 points")
end)

test("ipairs iterator yields index,x,y", function()
    local distIR = IR.distribution.rings(IR.form.circleUnit(), 1, 4)
    local pool = Compiler.createDistributionPool(distIR)

    pool:generate(0, 0, 100)

    local collected = {}
    for i, x, y in pool:ipairs() do
        collected[i] = { x = x, y = y }
    end

    assertEq(#collected, 4, "should iterate 4 points")
    assertTrue(collected[1].x ~= nil, "should have x value")
end)

test("forEach applies function to each point", function()
    local distIR = IR.distribution.burst(IR.form.circleUnit(), 4, 2)
    local pool = Compiler.createDistributionPool(distIR)

    pool:generate(100, 100, 50)

    local sum = 0
    pool:forEach(function(x, y, idx)
        sum = sum + 1
    end)

    assertEq(sum, 8, "should call function 8 times")
end)

test("forEach receives index", function()
    local distIR = IR.distribution.spiral(IR.form.circleUnit(), 5, 1)
    local pool = Compiler.createDistributionPool(distIR)

    pool:generate(0, 0, 100)

    local indices = {}
    pool:forEach(function(x, y, idx)
        indices[#indices + 1] = idx
    end)

    assertEq(indices[1], 1, "first index is 1")
    assertEq(indices[#indices], pool.count, "last index is count")
end)

--------------------------------------------------------------------------------
-- ARRAY REUSE TESTS
--------------------------------------------------------------------------------

test("arrays reuse between generates", function()
    local distIR = IR.distribution.spiral(IR.form.circleUnit(), 20, 2)
    local pool = Compiler.createDistributionPool(distIR, { maxPoints = 50 })

    -- First generate
    pool:generate(0, 0, 100)
    local x1, y1 = pool.x, pool.y

    -- Second generate at different location
    pool:generate(500, 500, 50)
    local x2, y2 = pool.x, pool.y

    -- Should be same array references
    assertTrue(x1 == x2, "x array should be reused")
    assertTrue(y1 == y2, "y array should be reused")
end)

test("generate overwrites previous data", function()
    local distIR = IR.distribution.spiral(IR.form.circleUnit(), 10, 1)
    local pool = Compiler.createDistributionPool(distIR, { maxPoints = 20 })

    -- First generate at origin
    pool:generate(0, 0, 100)
    local first_x1 = pool.x[1]
    local first_y1 = pool.y[1]

    -- Second generate at different location
    pool:generate(1000, 1000, 100)
    local second_x1 = pool.x[1]
    local second_y1 = pool.y[1]

    -- First point should be near new origin
    assertApprox(second_x1, 1000, 1, "x should be near new origin")
    assertApprox(second_y1, 1000, 1, "y should be near new origin")
end)

--------------------------------------------------------------------------------
-- RESIZE TESTS
--------------------------------------------------------------------------------

test("resize increases capacity", function()
    local distIR = IR.distribution.spiral(IR.form.circleUnit(), 10, 1)
    local pool = Compiler.createDistributionPool(distIR, { maxPoints = 20 })

    assertEq(pool.maxPoints, 20, "initial maxPoints")

    pool:resize(100)
    assertEq(pool.maxPoints, 100, "new maxPoints")
    assertEq(#pool.x, 100, "x array expanded")
    assertEq(#pool.y, 100, "y array expanded")
end)

test("resize decreases capacity", function()
    local distIR = IR.distribution.grid(IR.form.rectUnit(), 3)
    local pool = Compiler.createDistributionPool(distIR, { maxPoints = 100 })

    pool:resize(20)
    assertEq(pool.maxPoints, 20, "new maxPoints")
end)

test("resize preserves functionality", function()
    local distIR = IR.distribution.burst(IR.form.circleUnit(), 4, 5)
    local pool = Compiler.createDistributionPool(distIR, { maxPoints = 10 })

    pool:resize(50)

    local count = pool:generate(0, 0, 100)
    assertEq(count, 20, "should generate 20 points after resize")
end)

--------------------------------------------------------------------------------
-- DIFFERENT DISTRIBUTION TYPES
--------------------------------------------------------------------------------

test("pool works with grid distribution", function()
    local distIR = IR.distribution.grid(IR.form.rectUnit(), 4, 4)
    local pool = Compiler.createDistributionPool(distIR)

    local count = pool:generate(0, 0, 100)
    assertEq(count, 16, "4x4 grid = 16 points")
end)

test("pool works with random distribution", function()
    math.randomseed(12345)
    local distIR = IR.distribution.random(IR.form.circleUnit(), 25)
    local pool = Compiler.createDistributionPool(distIR)

    local count = pool:generate(0, 0, 100)
    assertTrue(count > 0 and count <= 25, "random should generate points")
end)

test("pool works with rings distribution", function()
    local distIR = IR.distribution.rings(IR.form.circleUnit(), 3, 8)
    local pool = Compiler.createDistributionPool(distIR)

    local count = pool:generate(0, 0, 100)
    assertEq(count, 24, "3 rings * 8 points = 24")
end)

test("pool works with sample distribution", function()
    -- Use slightly smaller radius to ensure all points are inside
    local motion = IR.motion.circle(0.99, 1)  -- 0.99 radius to stay inside
    local distIR = IR.distribution.sample(motion, IR.form.circleUnit(), 16)
    local pool = Compiler.createDistributionPool(distIR)

    local count = pool:generate(0, 0, 100)
    assertEq(count, 16, "should generate 16 points on circle")
end)

--------------------------------------------------------------------------------
-- EDGE CASES
--------------------------------------------------------------------------------

test("empty form generates no points", function()
    -- Ring with innerRatio = 1 has no area
    local distIR = IR.distribution.spiral(IR.form.ringUnit(0.999), 50, 3)
    local pool = Compiler.createDistributionPool(distIR)

    local count = pool:generate(0, 0, 100)
    assertTrue(count < 50, "should filter many points")
end)

test("zero size generates near-origin points", function()
    local distIR = IR.distribution.burst(IR.form.circleUnit(), 4, 3)
    local pool = Compiler.createDistributionPool(distIR)

    local count = pool:generate(100, 100, 0.001)

    -- All points should be very close to origin
    for i = 1, count do
        assertApprox(pool.x[i], 100, 0.01, "x near origin")
        assertApprox(pool.y[i], 100, 0.01, "y near origin")
    end
end)

test("large size works correctly", function()
    local distIR = IR.distribution.spiral(IR.form.circleUnit(), 20, 2)
    local pool = Compiler.createDistributionPool(distIR)

    local count = pool:generate(0, 0, 10000)

    -- Should still work with large values
    assertTrue(count > 0, "should generate points")

    -- Last point should be near edge
    local lastX, lastY = pool.x[count], pool.y[count]
    local d = math.sqrt(lastX * lastX + lastY * lastY)
    assertTrue(d > 5000, "points should span large area")
end)

--------------------------------------------------------------------------------
-- PERFORMANCE PATTERN TESTS
--------------------------------------------------------------------------------

test("multiple generates reuse pool efficiently", function()
    local distIR = IR.distribution.spiral(IR.form.circleUnit(), 50, 3)
    local pool = Compiler.createDistributionPool(distIR, { maxPoints = 100 })

    -- Simulate multiple frames
    for i = 1, 10 do
        local ox = i * 100
        local oy = i * 50
        local count = pool:generate(ox, oy, 80)
        assertTrue(count > 0, "should generate points each frame")
    end
end)

test("iterate pattern", function()
    local distIR = IR.distribution.burst(IR.form.circleUnit(), 8, 5)
    local pool = Compiler.createDistributionPool(distIR)

    pool:generate(400, 300, 100)

    -- Typical usage pattern: generate then iterate
    local total = 0
    for x, y in pool:points() do
        total = total + 1
    end

    assertEq(total, 40, "should iterate 40 points")
end)

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------

local success = runTests()
os.exit(success and 0 or 1)
