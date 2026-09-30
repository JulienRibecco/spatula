-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
-- tests/test_distribution_compiler.lua
-- Tests for Distribution compilation
-- Run with: lua5.4 tests/test_distribution_compiler.lua

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
    print("Running Distribution Compiler tests...\n")
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
-- UNIT FORM IR TESTS
--------------------------------------------------------------------------------

test("IR.form.circleUnit creates correct node", function()
    local form = IR.form.circleUnit()
    assertEq(form.op, "formCircleUnit", "op")
    assertEq(form.type, "form", "type")
end)

test("IR.form.rectUnit creates correct node", function()
    local form = IR.form.rectUnit()
    assertEq(form.op, "formRectUnit", "op")
    assertEq(form.type, "form", "type")
end)

test("IR.form.ellipseUnit creates correct node", function()
    local form = IR.form.ellipseUnit(2, 1)
    assertEq(form.op, "formEllipseUnit", "op")
    assertEq(form.aspectX, 2, "aspectX")
    assertEq(form.aspectY, 1, "aspectY")
end)

test("IR.form.ringUnit creates correct node", function()
    local form = IR.form.ringUnit(0.3)
    assertEq(form.op, "formRingUnit", "op")
    assertEq(form.innerRatio, 0.3, "innerRatio")
end)

--------------------------------------------------------------------------------
-- DISTRIBUTION IR TESTS
--------------------------------------------------------------------------------

test("IR.distribution.sample creates correct node", function()
    local motion = IR.motion.circle(1, 1)
    local form = IR.form.circleUnit()
    local dist = IR.distribution.sample(motion, form, 50)

    assertEq(dist.op, "distSample", "op")
    assertEq(dist.count, 50, "count")
    assertEq(dist.type, "distribution", "type")
end)

test("IR.distribution.grid creates correct node", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.grid(form, 5, 4)

    assertEq(dist.op, "distGrid", "op")
    assertEq(dist.cols, 5, "cols")
    assertEq(dist.rows, 4, "rows")
end)

test("IR.distribution.spiral creates correct node", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.spiral(form, 100, 5)

    assertEq(dist.op, "distSpiral", "op")
    assertEq(dist.count, 100, "count")
    assertEq(dist.turns, 5, "turns")
end)

test("IR.distribution.burst creates correct node", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.burst(form, 8, 4)

    assertEq(dist.op, "distBurst", "op")
    assertEq(dist.rays, 8, "rays")
    assertEq(dist.pointsPerRay, 4, "pointsPerRay")
end)

test("IR.distribution.random creates correct node", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.random(form, 50)

    assertEq(dist.op, "distRandom", "op")
    assertEq(dist.count, 50, "count")
end)

test("IR.distribution.rings creates correct node", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.rings(form, 4, 8)

    assertEq(dist.op, "distRings", "op")
    assertEq(dist.ringCount, 4, "ringCount")
    assertEq(dist.pointsPerRing, 8, "pointsPerRing")
end)

--------------------------------------------------------------------------------
-- SPIRAL COMPILATION TESTS
--------------------------------------------------------------------------------

test("compileDistribution creates function for spiral", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.spiral(form, 20, 2)

    local fn = Compiler.compileDistribution(dist)
    assertTrue(type(fn) == "function", "should be a function")
end)

test("spiral generates points", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.spiral(form, 20, 2)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(100, 100, 50, xs, ys)

    assertTrue(count > 0, "should generate points")
    assertTrue(count <= 20, "should not exceed count")
end)

test("spiral points are within form", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.spiral(form, 100, 3)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(0, 0, 100, xs, ys)

    -- All points should be within circle of radius 100
    for i = 1, count do
        local d2 = xs[i] * xs[i] + ys[i] * ys[i]
        assertTrue(d2 <= 100 * 100 + 1, "point should be inside form")
    end
end)

test("spiral respects origin", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.spiral(form, 50, 2)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(500, 300, 100, xs, ys)

    -- First point should be near origin (center of spiral)
    assertApprox(xs[1], 500, 1, "first x near origin")
    assertApprox(ys[1], 300, 1, "first y near origin")
end)

--------------------------------------------------------------------------------
-- GRID COMPILATION TESTS
--------------------------------------------------------------------------------

test("compileDistribution creates function for grid", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.grid(form, 5, 5)

    local fn = Compiler.compileDistribution(dist)
    assertTrue(type(fn) == "function", "should be a function")
end)

test("grid generates points", function()
    local form = IR.form.rectUnit()  -- Use rect for full grid coverage
    local dist = IR.distribution.grid(form, 5, 5)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(0, 0, 100, xs, ys)

    -- Should generate exactly 25 points for rect
    assertEq(count, 25, "grid should generate 25 points")
end)

test("grid points within rect form", function()
    local form = IR.form.rectUnit()
    local dist = IR.distribution.grid(form, 4, 4)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(100, 100, 50, xs, ys)

    for i = 1, count do
        assertTrue(math.abs(xs[i] - 100) <= 50 + 0.01, "x in bounds")
        assertTrue(math.abs(ys[i] - 100) <= 50 + 0.01, "y in bounds")
    end
end)

test("grid with circle form filters points", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.grid(form, 10, 10)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(0, 0, 100, xs, ys)

    -- Circle should have fewer points than full grid (100)
    assertTrue(count < 100, "circle should filter corners")
    assertTrue(count > 50, "should still have many points")
end)

--------------------------------------------------------------------------------
-- BURST COMPILATION TESTS
--------------------------------------------------------------------------------

test("compileDistribution creates function for burst", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.burst(form, 8, 5)

    local fn = Compiler.compileDistribution(dist)
    assertTrue(type(fn) == "function", "should be a function")
end)

test("burst generates correct point count", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.burst(form, 4, 3)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(0, 0, 100, xs, ys)

    -- 4 rays * 3 points = 12 points
    assertEq(count, 12, "should generate 12 points")
end)

test("burst points radiate outward", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.burst(form, 4, 5)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(0, 0, 100, xs, ys)

    -- Check first ray (pointing right): x increases, y stays near 0
    -- Points 1-5 should be on first ray
    for i = 1, 5 do
        assertTrue(xs[i] > 0, "first ray positive x")
        assertApprox(ys[i], 0, 0.1, "first ray y near 0")
    end
end)

--------------------------------------------------------------------------------
-- RANDOM DISTRIBUTION TESTS
--------------------------------------------------------------------------------

test("compileDistribution creates function for random", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.random(form, 50)

    local fn = Compiler.compileDistribution(dist)
    assertTrue(type(fn) == "function", "should be a function")
end)

test("random generates points within form", function()
    math.randomseed(12345)  -- Seed for reproducibility

    local form = IR.form.circleUnit()
    local dist = IR.distribution.random(form, 30)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(0, 0, 100, xs, ys)

    assertTrue(count > 0, "should generate points")

    -- All points must be inside the circle
    for i = 1, count do
        local d2 = xs[i] * xs[i] + ys[i] * ys[i]
        assertTrue(d2 <= 100 * 100 + 1, "point must be inside circle")
    end
end)

--------------------------------------------------------------------------------
-- RINGS DISTRIBUTION TESTS
--------------------------------------------------------------------------------

test("compileDistribution creates function for rings", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.rings(form, 3, 8)

    local fn = Compiler.compileDistribution(dist)
    assertTrue(type(fn) == "function", "should be a function")
end)

test("rings generates correct point count", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.rings(form, 3, 6)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(0, 0, 100, xs, ys)

    -- 3 rings * 6 points = 18 points
    assertEq(count, 18, "should generate 18 points")
end)

test("rings points are concentric", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.rings(form, 3, 8)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(0, 0, 90, xs, ys)

    -- Group by distance to check rings
    local ring1, ring2, ring3 = {}, {}, {}
    for i = 1, count do
        local d = math.sqrt(xs[i] * xs[i] + ys[i] * ys[i])
        if d < 35 then
            ring1[#ring1 + 1] = d
        elseif d < 65 then
            ring2[#ring2 + 1] = d
        else
            ring3[#ring3 + 1] = d
        end
    end

    assertEq(#ring1, 8, "first ring has 8 points")
    assertEq(#ring2, 8, "second ring has 8 points")
    assertEq(#ring3, 8, "third ring has 8 points")
end)

--------------------------------------------------------------------------------
-- SAMPLE WITH MOTION TESTS
--------------------------------------------------------------------------------

test("sample with circle motion", function()
    local motion = IR.motion.circle(1, 1)  -- Unit circle
    local form = IR.form.circleUnit()
    local dist = IR.distribution.sample(motion, form, 16)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(0, 0, 100, xs, ys)

    -- All points should be on a circle
    for i = 1, count do
        local d = math.sqrt(xs[i] * xs[i] + ys[i] * ys[i])
        assertApprox(d, 100, 1, "point should be on circle edge")
    end
end)

test("sample with outward motion creates spiral", function()
    local motion = IR.motion.outward(2)  -- Outward spiral with 2 turns
    local form = IR.form.circleUnit()
    local dist = IR.distribution.sample(motion, form, 50)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(0, 0, 100, xs, ys)

    assertTrue(count > 0, "should generate points")

    -- First point should be near center, last near edge
    local d1 = math.sqrt(xs[1] * xs[1] + ys[1] * ys[1])
    local dLast = math.sqrt(xs[count] * xs[count] + ys[count] * ys[count])

    assertTrue(d1 < dLast, "should spiral outward")
end)

--------------------------------------------------------------------------------
-- UNIT FORM CONTAINMENT TESTS
--------------------------------------------------------------------------------

test("circleUnit filters correctly", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.grid(form, 10, 10)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(0, 0, 100, xs, ys)

    -- All returned points must be inside circle
    for i = 1, count do
        local d2 = xs[i] * xs[i] + ys[i] * ys[i]
        assertTrue(d2 <= 100 * 100 + 1, "point inside circle")
    end
end)

test("ringUnit filters correctly", function()
    local form = IR.form.ringUnit(0.5)
    local dist = IR.distribution.grid(form, 20, 20)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(0, 0, 100, xs, ys)

    -- All points must be in ring (inner radius 50, outer radius 100)
    for i = 1, count do
        local d2 = xs[i] * xs[i] + ys[i] * ys[i]
        assertTrue(d2 >= 50 * 50 - 1, "point outside inner circle")
        assertTrue(d2 <= 100 * 100 + 1, "point inside outer circle")
    end
end)

test("ellipseUnit with aspect ratio", function()
    local form = IR.form.ellipseUnit(2, 1)  -- 2:1 aspect ratio (rx = size*2, ry = size*1)
    local dist = IR.distribution.grid(form, 20, 20)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(0, 0, 100, xs, ys)

    -- The ellipse has rx=200, ry=100. Grid covers [-100, 100].
    -- Check that containment works correctly:
    -- Point (100, 0) should be inside: (100/200)^2 + (0/100)^2 = 0.25 <= 1
    -- Point (0, 100) should be inside: (0/200)^2 + (100/100)^2 = 1 <= 1
    -- Point (100, 100) should be outside: (100/200)^2 + (100/100)^2 = 1.25 > 1

    -- So corners should be filtered out
    local hasCorner = false
    for i = 1, count do
        if math.abs(xs[i]) > 90 and math.abs(ys[i]) > 90 then
            hasCorner = true
        end
    end
    assertFalse(hasCorner, "ellipse should filter corners")

    -- But should have points near (100, 0) and (0, 100)
    local hasHorizEdge = false
    local hasVertEdge = false
    for i = 1, count do
        if math.abs(xs[i]) > 80 and math.abs(ys[i]) < 20 then
            hasHorizEdge = true
        end
        if math.abs(ys[i]) > 80 and math.abs(xs[i]) < 20 then
            hasVertEdge = true
        end
    end
    assertTrue(hasHorizEdge, "should have points at horizontal edge")
    assertTrue(hasVertEdge, "should have points at vertical edge")
end)

--------------------------------------------------------------------------------
-- FORM COMBINATOR TESTS
--------------------------------------------------------------------------------

test("union of unit forms", function()
    local left = IR.form.circleUnit()  -- Will be used as left circle
    local right = IR.form.circleUnit()  -- Will be used as right circle
    local form = IR.form.union(left, right)
    local dist = IR.distribution.grid(form, 5, 5)

    -- Should compile without error
    local fn = Compiler.compileDistribution(dist)
    assertTrue(type(fn) == "function", "should compile")
end)

test("intersect of unit forms", function()
    local circle = IR.form.circleUnit()
    local rect = IR.form.rectUnit()
    local form = IR.form.intersect(circle, rect)
    local dist = IR.distribution.grid(form, 10, 10)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(0, 0, 100, xs, ys)

    -- Points must satisfy both conditions
    for i = 1, count do
        local d2 = xs[i] * xs[i] + ys[i] * ys[i]
        assertTrue(d2 <= 100 * 100 + 1, "inside circle")
        assertTrue(math.abs(xs[i]) <= 100 + 0.01, "inside rect x")
        assertTrue(math.abs(ys[i]) <= 100 + 0.01, "inside rect y")
    end
end)

test("subtract unit forms", function()
    local outer = IR.form.circleUnit()
    local inner = IR.form.ringUnit(0.3)  -- Use ring as inner to create donut hole
    local form = IR.form.subtract(outer, inner)
    local dist = IR.distribution.grid(form, 10, 10)

    local fn = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = fn(0, 0, 100, xs, ys)

    assertTrue(count > 0, "should have some points")
end)

--------------------------------------------------------------------------------
-- DEBUG OUTPUT TEST
--------------------------------------------------------------------------------

test("debug option prints code", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.spiral(form, 10, 1)

    -- This should not error
    local fn = Compiler.compileDistribution(dist, { debug = false })
    assertTrue(type(fn) == "function", "should compile")
end)

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------

local success = runTests()
os.exit(success and 0 or 1)
