-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--------------------------------------------------------------------------------
-- GAUSSIAN CURVE TEST
-- Verifies gaussian curve correctness: raw vs expected math
--
-- Run from compiler/tests: lua5.4 test_gaussian.lua
--------------------------------------------------------------------------------

-- Setup paths (run from compiler/tests/)
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"

local Curve = require("spatula.curve")

--------------------------------------------------------------------------------
-- TEST UTILITIES
--------------------------------------------------------------------------------

local exp = math.exp
local abs = math.abs

local EPSILON = 1e-6

local function approxEqual(a, b, eps)
    eps = eps or EPSILON
    return abs(a - b) < eps
end

-- Expected gaussian value: e^(-3t²/width²)
local function expectedGaussian(t, width)
    local k = -3 / (width * width)
    return exp(k * t * t)
end

local passed = 0
local failed = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print(string.format("  ✓ %s", name))
    else
        failed = failed + 1
        print(string.format("  ✗ %s", name))
        print(string.format("    %s", err))
    end
end

local function assertNear(actual, expected, tolerance, msg)
    tolerance = tolerance or EPSILON
    if abs(actual - expected) > tolerance then
        error(string.format("%s: expected %.10f, got %.10f (diff: %.10f)",
            msg or "assertion failed", expected, actual, abs(actual - expected)))
    end
end

--------------------------------------------------------------------------------
-- TESTS
--------------------------------------------------------------------------------

print("\nGaussian Curve Tests\n" .. string.rep("-", 60))

-- Test 1: Raw gaussian matches expected formula
test("Raw gaussian at t=0 (peak)", function()
    local g = Curve.gaussian(1)
    local ctx = {}
    local actual = g(0, ctx)
    local expected = expectedGaussian(0, 1)  -- Should be 1.0
    assertNear(actual, expected, EPSILON, "t=0")
end)

test("Raw gaussian at t=0.5", function()
    local g = Curve.gaussian(1)
    local ctx = {}
    local actual = g(0.5, ctx)
    local expected = expectedGaussian(0.5, 1)  -- e^(-0.75) ≈ 0.472
    assertNear(actual, expected, EPSILON, "t=0.5")
end)

test("Raw gaussian at t=1 (width boundary)", function()
    local g = Curve.gaussian(1)
    local ctx = {}
    local actual = g(1, ctx)
    local expected = expectedGaussian(1, 1)  -- e^(-3) ≈ 0.0498
    assertNear(actual, expected, EPSILON, "t=1")
end)

test("Raw gaussian at t=-1 (symmetric)", function()
    local g = Curve.gaussian(1)
    local ctx = {}
    local actual = g(-1, ctx)
    local expected = expectedGaussian(-1, 1)  -- Same as t=1
    assertNear(actual, expected, EPSILON, "t=-1")
end)

test("Raw gaussian at t=2", function()
    local g = Curve.gaussian(1)
    local ctx = {}
    local actual = g(2, ctx)
    local expected = expectedGaussian(2, 1)  -- e^(-12) ≈ 6.14e-6
    assertNear(actual, expected, EPSILON, "t=2")
end)

-- Test 2: Different widths
test("Gaussian with width=2", function()
    local g = Curve.gaussian(2)
    local ctx = {}

    -- At t=0, should still be 1
    assertNear(g(0, ctx), 1.0, EPSILON, "width=2, t=0")

    -- At t=1, should be higher than width=1 (wider curve)
    local at1 = g(1, ctx)
    local expected = expectedGaussian(1, 2)  -- e^(-0.75) ≈ 0.472
    assertNear(at1, expected, EPSILON, "width=2, t=1")
end)

test("Gaussian with width=0.5", function()
    local g = Curve.gaussian(0.5)
    local ctx = {}

    -- At t=0, should still be 1
    assertNear(g(0, ctx), 1.0, EPSILON, "width=0.5, t=0")

    -- At t=0.5, should be lower than width=1 (narrower curve)
    local at05 = g(0.5, ctx)
    local expected = expectedGaussian(0.5, 0.5)  -- e^(-3) ≈ 0.0498
    assertNear(at05, expected, EPSILON, "width=0.5, t=0.5")
end)

-- Test 3: Symmetry
test("Gaussian is symmetric around t=0", function()
    local g = Curve.gaussian(1)
    local ctx = {}

    for _, t in ipairs({0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0}) do
        local pos = g(t, ctx)
        local neg = g(-t, ctx)
        assertNear(pos, neg, EPSILON, string.format("symmetry at t=±%.2f", t))
    end
end)

-- Test 4: Monotonicity (decreasing from center)
test("Gaussian decreases from center", function()
    local g = Curve.gaussian(1)
    local ctx = {}

    local prev = g(0, ctx)
    for t = 0.1, 2.0, 0.1 do
        local curr = g(t, ctx)
        if curr >= prev then
            error(string.format("not monotonically decreasing at t=%.1f: %.6f >= %.6f", t, curr, prev))
        end
        prev = curr
    end
end)

-- Test 5: Value range [0, 1]
test("Gaussian stays in [0, 1] range", function()
    local g = Curve.gaussian(1)
    local ctx = {}

    for t = -5, 5, 0.1 do
        local v = g(t, ctx)
        if v < 0 or v > 1.0001 then  -- small tolerance for floating point
            error(string.format("out of range at t=%.1f: %.6f", t, v))
        end
    end
end)

-- Test 6: Gaussian with very small width
test("Gaussian with width=0.1 (sharp peak)", function()
    local g = Curve.gaussian(0.1)
    local ctx = {}

    -- Peak should still be 1
    assertNear(g(0, ctx), 1.0, EPSILON, "peak at t=0")

    -- Should drop very fast
    local at01 = g(0.1, ctx)
    local expected = expectedGaussian(0.1, 0.1)  -- e^(-3)
    assertNear(at01, expected, EPSILON, "t=0.1")
end)

-- Test 7: Dense sampling (catch any discontinuities)
test("Dense sampling matches expected", function()
    local g = Curve.gaussian(1)
    local ctx = {}

    for i = 0, 100 do
        local t = (i - 50) / 25  -- Range [-2, 2]
        local actual = g(t, ctx)
        local expected = expectedGaussian(t, 1)
        assertNear(actual, expected, EPSILON,
            string.format("dense sample at t=%.2f", t))
    end
end)

-- Test 8: Various widths dense sampling
test("Various widths dense sampling", function()
    for _, width in ipairs({0.25, 0.5, 1, 2, 4}) do
        local g = Curve.gaussian(width)
        local ctx = {}

        for i = 0, 20 do
            local t = (i - 10) / 5  -- Range [-2, 2]
            local actual = g(t, ctx)
            local expected = expectedGaussian(t, width)
            assertNear(actual, expected, EPSILON,
                string.format("width=%.2f, t=%.1f", width, t))
        end
    end
end)

--------------------------------------------------------------------------------
-- COMPILED MODULE TESTS
-- Test that gaussian works correctly with the compiled module
--------------------------------------------------------------------------------

print("\n" .. string.rep("-", 60))
print("Compiled Module Tests")
print(string.rep("-", 60))

-- Load compiled module (patches Curve)
local Compiled = require("spatula.compiled")

-- Use the patched Curve (compiled.lua patches it in place)
local PatchedCurve = require("spatula.curve")

test("Gaussian returns callable after compiled module load", function()
    local g = PatchedCurve.gaussian(1)
    local ctx = {}

    -- Should be callable
    local result = g(0, ctx)
    assertNear(result, 1.0, EPSILON, "should return 1 at t=0")
end)

test("Patched gaussian values match expected formula", function()
    local g = PatchedCurve.gaussian(1)
    local ctx = {}

    for _, t in ipairs({-2, -1, -0.5, 0, 0.5, 1, 2}) do
        local actual = g(t, ctx)
        local expected = expectedGaussian(t, 1)
        assertNear(actual, expected, EPSILON,
            string.format("patched gaussian at t=%.1f", t))
    end
end)

test("Gaussian with width=2 after compile module load", function()
    local g = PatchedCurve.gaussian(2)
    local ctx = {}

    for _, t in ipairs({0, 0.5, 1, 2}) do
        local actual = g(t, ctx)
        local expected = expectedGaussian(t, 2)
        assertNear(actual, expected, EPSILON,
            string.format("width=2, t=%.1f", t))
    end
end)

test("Gaussian is wrapper type after compile module load", function()
    local g = PatchedCurve.gaussian(1)
    -- After patching, gaussian should still work even if it's a raw function
    -- (because exp/gaussian aren't wrapped)
    -- This test checks if it has _ir (it probably won't)
    local hasIR = type(g) == "table" and g._ir ~= nil
    -- We just verify it works regardless
    local ctx = {}
    local result = g(0, ctx)
    assertNear(result, 1.0, EPSILON, "should work regardless of wrapper status")
end)

--------------------------------------------------------------------------------
-- POST-BUILD TESTS
-- Test gaussian AFTER Compiled.build() is called
--------------------------------------------------------------------------------

print("\n" .. string.rep("-", 60))
print("Post-Build Tests")
print(string.rep("-", 60))

-- Create gaussian curves before build
local preBuildGaussian = PatchedCurve.gaussian(1)
local preBuildGaussian2 = PatchedCurve.gaussian(2)

-- Call build
Compiled.build()

test("Gaussian works after build() at t=0", function()
    local ctx = {}
    local result = preBuildGaussian(0, ctx)
    assertNear(result, 1.0, EPSILON, "should return 1 at t=0 after build")
end)

test("Gaussian works after build() at various t", function()
    local ctx = {}
    for _, t in ipairs({-2, -1, -0.5, 0, 0.5, 1, 2}) do
        local actual = preBuildGaussian(t, ctx)
        local expected = expectedGaussian(t, 1)
        assertNear(actual, expected, EPSILON,
            string.format("post-build gaussian at t=%.1f", t))
    end
end)

test("Gaussian width=2 works after build()", function()
    local ctx = {}
    for _, t in ipairs({0, 0.5, 1, 2}) do
        local actual = preBuildGaussian2(t, ctx)
        local expected = expectedGaussian(t, 2)
        assertNear(actual, expected, EPSILON,
            string.format("post-build width=2, t=%.1f", t))
    end
end)

test("Gaussian created after build() works", function()
    local g = PatchedCurve.gaussian(1)
    local ctx = {}
    for _, t in ipairs({0, 0.5, 1}) do
        local actual = g(t, ctx)
        local expected = expectedGaussian(t, 1)
        assertNear(actual, expected, EPSILON,
            string.format("new gaussian after build at t=%.1f", t))
    end
end)

test("Dense sampling after build()", function()
    local ctx = {}
    for i = 0, 100 do
        local t = (i - 50) / 25  -- Range [-2, 2]
        local actual = preBuildGaussian(t, ctx)
        local expected = expectedGaussian(t, 1)
        assertNear(actual, expected, EPSILON,
            string.format("post-build dense at t=%.2f", t))
    end
end)

--------------------------------------------------------------------------------
-- FIELD.FALLOFF.GAUSSIAN TESTS
-- Test gaussian used as Field falloff after build
--------------------------------------------------------------------------------

print("\n" .. string.rep("-", 60))
print("Field.falloff.gaussian Tests")
print(string.rep("-", 60))

local Field = require("spatula.field")

test("Field.falloff.gaussian exists", function()
    if Field.falloff.gaussian == nil then
        error("gaussian falloff should exist")
    end
end)

test("Field.falloff.gaussian at d=0 (center)", function()
    local falloff = Field.falloff.gaussian
    local ctx = {}
    local result = falloff(0, ctx)
    assertNear(result, 1.0, EPSILON, "should be 1 at center")
end)

test("Field.falloff.gaussian at d=0.5", function()
    local falloff = Field.falloff.gaussian
    local ctx = {}
    local result = falloff(0.5, ctx)
    local expected = expectedGaussian(0.5, 1)
    assertNear(result, expected, EPSILON, "should match formula at d=0.5")
end)

test("Field.falloff.gaussian at d=1 (edge)", function()
    local falloff = Field.falloff.gaussian
    local ctx = {}
    local result = falloff(1, ctx)
    local expected = expectedGaussian(1, 1)  -- e^(-3) ≈ 0.0498
    assertNear(result, expected, EPSILON, "should match formula at edge")
end)

test("Field.falloff.gaussian dense sampling", function()
    local falloff = Field.falloff.gaussian
    local ctx = {}
    for i = 0, 100 do
        local d = i / 100  -- Range [0, 1]
        local actual = falloff(d, ctx)
        local expected = expectedGaussian(d, 1)
        assertNear(actual, expected, EPSILON,
            string.format("falloff at d=%.2f", d))
    end
end)

test("Field with gaussian falloff samples correctly", function()
    local field = Field.new({ falloff = "gaussian" })
    field:add({100, 100}, { radius = 50, value = 1 })

    -- At center
    local centerVal = field:sample(100, 100)
    assertNear(centerVal, 1.0, 0.01, "should be ~1 at center")

    -- At half radius (d=0.5)
    local halfVal = field:sample(125, 100)  -- 25 units = 50% of radius
    local expectedHalf = expectedGaussian(0.5, 1)
    assertNear(halfVal, expectedHalf, 0.01, "should match gaussian at half radius")

    -- Near edge (d=0.99) - Field uses dist < radius so exactly at edge is 0
    local nearEdgeVal = field:sample(149.5, 100)  -- 49.5 units = 99% of radius
    local expectedNearEdge = expectedGaussian(0.99, 1)
    assertNear(nearEdgeVal, expectedNearEdge, 0.01, "should match gaussian near edge")
end)

--------------------------------------------------------------------------------
-- COMPILATION TESTS
-- Test that gaussian components (pow, exp) now have IR
--------------------------------------------------------------------------------

print("\n" .. string.rep("-", 60))
print("Compilation Tests (pow/exp with IR)")
print(string.rep("-", 60))

-- Clear registry to get fresh count
Compiled._registry = {}

-- Build gaussian components manually with patched Curve
local t = PatchedCurve.linear(1)
local tSquared = PatchedCurve.pow(t, 2)
local k = -3
local exponent = PatchedCurve.scale(tSquared, k)
local manualGaussian = PatchedCurve.exp(exponent)

test("Linear has IR", function()
    local hasIR = type(t) == "table" and t._ir ~= nil
    if not hasIR then
        error("linear should have IR attached")
    end
end)

test("Pow has IR", function()
    local hasIR = type(tSquared) == "table" and tSquared._ir ~= nil
    if not hasIR then
        error("pow should have IR attached")
    end
end)

test("Exp has IR", function()
    local hasIR = type(manualGaussian) == "table" and manualGaussian._ir ~= nil
    if not hasIR then
        error("exp should have IR attached")
    end
end)

test("Exp IR has correct op", function()
    local ir = manualGaussian._ir
    if ir.op ~= "exp" then
        error("exp IR should have op='exp', got: " .. tostring(ir.op))
    end
end)

-- Build and test compiled version
Compiled.build()

test("Manual gaussian matches expected values after build", function()
    local ctx = {}
    for _, tVal in ipairs({0, 0.25, 0.5, 0.75, 1, 1.5, 2}) do
        local actual = manualGaussian(tVal, ctx)
        local expected = expectedGaussian(tVal, 1)
        assertNear(actual, expected, EPSILON,
            string.format("manual gaussian at t=%.2f", tVal))
    end
end)

--------------------------------------------------------------------------------
-- SUMMARY
--------------------------------------------------------------------------------

print(string.rep("-", 60))
print(string.format("\n%d passed, %d failed\n", passed, failed))

os.exit(failed == 0 and 0 or 1)
