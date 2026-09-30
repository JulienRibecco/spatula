-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "bootstrap.lua")
-- tests/distribution_test.lua
-- Tests for Distribution module: spatial sampling, modifiers
-- Run with: lua5.4 tests/distribution_test.lua

package.path = package.path .. ";../?.lua;../?/init.lua"
package.preload["spatula.point"] = function() return require("point") end
package.preload["spatula.curve"] = function() return require("curve") end
package.preload["spatula.motion"] = function() return require("motion") end
package.preload["spatula.util"] = function() return require("util") end
package.preload["spatula.signal"] = function() return require("signal") end

local Distribution = require("distribution")
local Forms = require("forms")
local Motion = require("motion")
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
        error(string.format("%s: expected ~%s, got %s", msg or "assertion failed", tostring(b), tostring(a)))
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
    print("Running Distribution tests...\n")
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

-- Helper to collect points
local function collect()
    local points = {}
    local push = function(x, y)
        points[#points + 1] = {x = x, y = y}
    end
    return push, points
end

--------------------------------------------------------------------------------
-- SAMPLE-BASED DISTRIBUTION TESTS
--------------------------------------------------------------------------------

test("Distribution.sample creates distribution function", function()
    local dist = Distribution.sample(Motion.arc(1), 10)
    assertTrue(type(dist) == "function", "should return function")
end)

test("Distribution.sample generates points along motion", function()
    local dist = Distribution.sample(Motion.ray(0), 5)
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)

    dist(form, push)

    assertTrue(#points > 0, "should generate points")
    -- Points should be along x-axis (ray angle 0)
    for _, p in ipairs(points) do
        assertNear(p.y, 100, 1, "y should be ~100 for horizontal ray")
    end
end)

test("Distribution.sample respects form containment", function()
    local dist = Distribution.sample(Motion.ray(0), 100)  -- many points
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)

    dist(form, push)

    for _, p in ipairs(points) do
        assertTrue(form:contains(p.x, p.y),
            "all points should be inside form")
    end
end)

--------------------------------------------------------------------------------
-- SPATIAL DISTRIBUTION TESTS
--------------------------------------------------------------------------------

test("Distribution.grid generates grid of points", function()
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)
    Distribution.grid(form, 25, push)

    assertTrue(#points > 0, "should generate points")
    assertTrue(#points <= 25, "should not exceed requested count")
end)

test("Distribution.grid points are inside form", function()
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)
    Distribution.grid(form, 100, push)

    for _, p in ipairs(points) do
        assertTrue(form:contains(p.x, p.y),
            "grid point should be inside form")
    end
end)

test("Distribution.grid with rect form", function()
    local push, points = collect()
    local form = Forms.rect(100, 100, 100, 50)  -- ox, oy, hw, hh
    Distribution.grid(form, 100, push)

    assertTrue(#points > 0, "should generate points")
    for _, p in ipairs(points) do
        assertTrue(form:contains(p.x, p.y),
            "point should be inside rect")
    end
end)

test("Distribution.hexGrid generates hex pattern", function()
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)
    Distribution.hexGrid(form, 15, push)

    assertTrue(#points > 0, "should generate points")
end)

test("Distribution.hexGrid points are inside form", function()
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)
    Distribution.hexGrid(form, 10, push)

    for _, p in ipairs(points) do
        assertTrue(form:contains(p.x, p.y),
            "hex point should be inside form")
    end
end)

test("Distribution.random generates requested count", function()
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)
    Distribution.random(form, 20, push)

    assertEq(#points, 20, "should generate exactly 20 points")
end)

test("Distribution.random points are inside form", function()
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)
    Distribution.random(form, 50, push)

    for _, p in ipairs(points) do
        assertTrue(form:contains(p.x, p.y),
            "random point should be inside form")
    end
end)

test("Distribution.poisson generates well-spaced points", function()
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)
    Distribution.poisson(form, 10, push)

    assertTrue(#points > 0, "should generate points")

    -- Check minimum distance
    for i = 1, #points do
        for j = i + 1, #points do
            local dx = points[i].x - points[j].x
            local dy = points[i].y - points[j].y
            local dist = math.sqrt(dx*dx + dy*dy)
            assertTrue(dist >= 9, "poisson points should be spaced apart")
        end
    end
end)

test("Distribution.poisson points are inside form", function()
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)
    Distribution.poisson(form, 8, push)

    for _, p in ipairs(points) do
        assertTrue(form:contains(p.x, p.y),
            "poisson point should be inside form")
    end
end)

--------------------------------------------------------------------------------
-- COMPOSED DISTRIBUTION TESTS
--------------------------------------------------------------------------------

test("Distribution.perimeter generates edge points", function()
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)
    Distribution.perimeter(form, 16, push)

    assertEq(#points, 16, "should generate 16 points")

    -- All points should be on perimeter (distance = radius)
    for _, p in ipairs(points) do
        local dist = math.sqrt((p.x - 100)^2 + (p.y - 100)^2)
        assertNear(dist, 50, 1, "perimeter point should be at radius")
    end
end)

test("Distribution.spiral generates outward spiral", function()
    local dist = Distribution.spiral(20, 2)
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)

    dist(form, push)

    assertTrue(#points > 0, "should generate points")

    -- First point should be near center, last near edge
    local firstDist = math.sqrt((points[1].x - 100)^2 + (points[1].y - 100)^2)
    local lastDist = math.sqrt((points[#points].x - 100)^2 + (points[#points].y - 100)^2)
    assertTrue(lastDist > firstDist, "spiral should expand outward")
end)

test("Distribution.burst generates radial lines", function()
    local dist = Distribution.burst(4, 5)  -- 4 rays, 5 points each
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)

    dist(form, push)

    assertTrue(#points > 0, "should generate points")
    assertTrue(#points <= 20, "should not exceed 4*5 points")
end)

test("Distribution.rings generates concentric circles", function()
    local dist = Distribution.rings(3, 8)  -- 3 rings, 8 points each
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)

    dist(form, push)

    assertTrue(#points > 0, "should generate points")
end)

--------------------------------------------------------------------------------
-- MODIFIER TESTS
--------------------------------------------------------------------------------

test("Distribution.withJitter adds randomness", function()
    -- Create deterministic base
    local basePush, basePoints = collect()
    local form = Forms.circle(100, 100, 50)
    Distribution.grid(form, 16, basePush)

    -- Create jittered version
    local jitteredDist = Distribution.withJitter(
        function(f, push)
            Distribution.grid(f, 16, push)
        end,
        5  -- jitter amount
    )
    local jitPush, jitPoints = collect()
    jitteredDist(form, jitPush)

    -- Should have same count
    assertEq(#jitPoints, #basePoints, "jitter should preserve count")

    -- At least some points should be different (random)
    local different = 0
    for i = 1, math.min(#basePoints, #jitPoints) do
        if math.abs(basePoints[i].x - jitPoints[i].x) > 0.01 or
           math.abs(basePoints[i].y - jitPoints[i].y) > 0.01 then
            different = different + 1
        end
    end
    assertTrue(different > 0, "jitter should modify positions")
end)

test("Distribution.withFilter removes points", function()
    local form = Forms.circle(100, 100, 50)
    local filteredDist = Distribution.withFilter(
        function(f, push)
            Distribution.grid(f, 100, push)
        end,
        function(x, y)
            return x > 100  -- only right half
        end
    )
    local push, points = collect()
    filteredDist(form, push)

    for _, p in ipairs(points) do
        assertTrue(p.x > 100, "filtered points should be in right half")
    end
end)

test("Distribution.withIndex provides index to push", function()
    local form = Forms.circle(100, 100, 50)
    local indexedDist = Distribution.withIndex(
        function(f, push)
            Distribution.grid(f, 9, push)
        end
    )

    local points = {}
    local push = function(x, y, idx)
        points[#points + 1] = {x = x, y = y, idx = idx}
    end

    indexedDist(form, push)

    assertTrue(#points > 0, "should generate points")
    for i, p in ipairs(points) do
        assertEq(p.idx, i, "index should match position")
    end
end)

--------------------------------------------------------------------------------
-- FORM COMPATIBILITY TESTS
--------------------------------------------------------------------------------

test("Distribution works with rect form", function()
    local form = Forms.rect(100, 100, 75, 50)
    local push, points = collect()
    Distribution.grid(form, 50, push)

    assertTrue(#points > 0, "should work with rect")
end)

test("Distribution works with ellipse form", function()
    local form = Forms.ellipse(100, 100, 100, 50)
    local push, points = collect()
    Distribution.random(form, 20, push)

    assertEq(#points, 20, "should work with ellipse")
end)

test("Distribution works with ring form", function()
    local form = Forms.ring(100, 100, 50, 25)
    local push, points = collect()
    Distribution.random(form, 20, push)

    for _, p in ipairs(points) do
        assertTrue(form:contains(p.x, p.y),
            "point should be in ring")
    end
end)

--------------------------------------------------------------------------------
-- SIGNAL SUPPORT TESTS
--------------------------------------------------------------------------------

test("Distribution.grid with signal count", function()
    local form = Forms.circle(100, 100, 50)
    local push, points = collect()

    -- Use signal for count
    Distribution.grid(form, S("count", 16), push, { count = 25 })

    assertTrue(#points > 0, "should generate points")
    assertTrue(#points <= 25, "should respect signal count")
end)

test("Distribution.random with signal count", function()
    local form = Forms.circle(100, 100, 50)
    local push, points = collect()

    Distribution.random(form, S("n", 10), push, { n = 15 })

    assertEq(#points, 15, "should use ctx value for count")
end)

test("Distribution.hexGrid with signal spacing", function()
    local form = Forms.circle(100, 100, 50)
    local push1, points1 = collect()
    local push2, points2 = collect()

    Distribution.hexGrid(form, S("spacing", 10), push1, { spacing = 20 })
    Distribution.hexGrid(form, S("spacing", 10), push2, { spacing = 10 })

    -- Smaller spacing should generate more points
    assertTrue(#points2 > #points1, "smaller spacing should generate more points")
end)

test("Distribution with signal form parameters", function()
    -- Form with signal radius
    local form = Forms.circle(100, 100, S("r", 50))
    local push1, points1 = collect()
    local push2, points2 = collect()

    Distribution.random(form, 20, push1, { r = 50 })
    Distribution.random(form, 20, push2, { r = 25 })

    -- Smaller form should have points closer together
    local maxDist1 = 0
    local maxDist2 = 0
    for _, p in ipairs(points1) do
        local d = math.sqrt((p.x - 100)^2 + (p.y - 100)^2)
        maxDist1 = math.max(maxDist1, d)
    end
    for _, p in ipairs(points2) do
        local d = math.sqrt((p.x - 100)^2 + (p.y - 100)^2)
        maxDist2 = math.max(maxDist2, d)
    end

    assertTrue(maxDist2 < maxDist1, "smaller radius should constrain points")
end)

--------------------------------------------------------------------------------
-- EDGE CASES
--------------------------------------------------------------------------------

test("Distribution.grid with zero count", function()
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)
    Distribution.grid(form, 0, push)
    -- Should not error, may generate 0 or minimal points
end)

test("Distribution.random with zero count", function()
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)
    Distribution.random(form, 0, push)
    assertEq(#points, 0, "zero count should give zero points")
end)

test("Distribution.sample with single point", function()
    local dist = Distribution.sample(Motion.ray(0), 1)
    local push, points = collect()
    local form = Forms.circle(100, 100, 50)
    dist(form, push)
    -- Should work with single point
end)

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------

local success = runTests()
os.exit(success and 0 or 1)
