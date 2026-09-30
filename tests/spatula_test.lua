-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "bootstrap.lua")
-- tests/spatula_test.lua
-- Basic tests for Spatula primitives and compositions
-- Run with: cd survivor && love . --test
-- Or standalone: lua tests/spatula_test.lua (if lua is available)

-- Add parent directory to path so we can require spatula
package.path = package.path .. ";../?.lua;../spatula/?.lua"

local Curve = require("spatula.curve")
local Motion = require("spatula.motion")
local Point = require("spatula.point")

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

local function runTests()
    print("Running Spatula tests...\n")
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
-- CURVE TESTS
--------------------------------------------------------------------------------

test("Curve.const returns constant value", function()
    local c = Curve.const(5)
    assertEq(c(0, {}), 5)
    assertEq(c(100, {}), 5)
    assertEq(c(-10, {}), 5)
end)

test("Curve.linear returns t", function()
    local c = Curve.linear(1)
    assertNear(c(0, {}), 0)
    assertNear(c(0.5, {}), 0.5)
    assertNear(c(1, {}), 1)
end)

test("Curve.ramp interpolates from start to end over duration", function()
    local c = Curve.ramp(0, 10, 2)  -- 0 to 10 over 2 seconds
    assertNear(c(0, {}), 0)
    assertNear(c(1, {}), 5)
    assertNear(c(2, {}), 10)
end)

test("Curve.sin oscillates", function()
    local c = Curve.sin(1, 1)  -- 1 Hz, amplitude 1
    assertNear(c(0, {}), 0, 0.001)
    assertNear(c(0.25, {}), 1, 0.001)  -- quarter cycle = peak
    assertNear(c(0.5, {}), 0, 0.001)   -- half cycle = zero
    assertNear(c(0.75, {}), -1, 0.001) -- 3/4 cycle = trough
end)

test("Curve.easeIn starts slow", function()
    local c = Curve.easeIn(1, 2)  -- power 2
    assertNear(c(0, {}), 0)
    assertNear(c(0.5, {}), 0.25)  -- 0.5^2 = 0.25
    assertNear(c(1, {}), 1)
end)

test("Curve.easeOut ends slow", function()
    local c = Curve.easeOut(1, 2)  -- power 2
    assertNear(c(0, {}), 0)
    assertNear(c(0.5, {}), 0.75)  -- 1 - (0.5)^2 = 0.75
    assertNear(c(1, {}), 1)
end)

--------------------------------------------------------------------------------
-- CURVE COMPOSITION TESTS
--------------------------------------------------------------------------------

test("Curve.add combines two curves", function()
    local c = Curve.add(Curve.const(3), Curve.const(2))
    assertEq(c(0, {}), 5)
end)

test("Curve.mul multiplies two curves", function()
    local c = Curve.mul(Curve.const(3), Curve.const(2))
    assertEq(c(0, {}), 6)
end)

test("Curve.scale multiplies curve by constant", function()
    local c = Curve.scale(Curve.linear(1), 10)
    assertNear(c(0.5, {}), 5)
end)

test("Curve.sequence chains curves", function()
    local c = Curve.sequence({
        {Curve.const(1), 1},  -- value 1 for 1 second
        {Curve.const(2), 1},  -- value 2 for next second
    })
    assertNear(c(0.5, {}), 1, 0.001)
    assertNear(c(1.5, {}), 2, 0.001)
end)

--------------------------------------------------------------------------------
-- MOTION TESTS
--------------------------------------------------------------------------------

test("Motion.ray returns direction vector", function()
    local m = Motion.ray(0)  -- angle 0 = right
    local x, y = m(1, {})
    assertNear(x, 1, 0.001)
    assertNear(y, 0, 0.001)
end)

test("Motion.ray with angle points correctly", function()
    local m = Motion.ray(math.pi / 2)  -- angle 90° = down (in screen coords)
    local x, y = m(1, {})
    assertNear(x, 0, 0.001)
    assertNear(y, 1, 0.001)
end)

test("Motion.circle traces circular path", function()
    local m = Motion.circle(10, 1)  -- radius 10, 1 rotation/sec
    local x1, y1 = m(0, {})     -- t=0
    local x2, y2 = m(0.25, {})  -- t=0.25 (quarter turn)

    -- At t=0, should be at (10, 0)
    assertNear(x1, 10, 0.001)
    assertNear(y1, 0, 0.001)

    -- At t=0.25, should be at (0, 10) approximately
    assertNear(x2, 0, 0.001)
    assertNear(y2, 10, 0.001)
end)

test("Motion.scale multiplies motion output", function()
    local m = Motion.scale(Motion.ray(0), 5)
    local x, y = m(1, {})
    assertNear(x, 5, 0.001)
    assertNear(y, 0, 0.001)
end)

test("Motion.rotate rotates motion", function()
    local m = Motion.rotate(Motion.ray(0), math.pi / 2)  -- rotate 90°
    local x, y = m(1, {})
    assertNear(x, 0, 0.001)
    assertNear(y, 1, 0.001)  -- originally (1,0), rotated 90° = (0,1)
end)

--------------------------------------------------------------------------------
-- POINT TESTS
--------------------------------------------------------------------------------

test("Point.distance calculates correctly", function()
    local d = Point.distance({x = 0, y = 0}, {x = 3, y = 4})
    assertNear(d, 5, 0.001)  -- 3-4-5 triangle
end)

test("Point.angleTo returns correct angle", function()
    local a = Point.angleTo({x = 0, y = 0}, {x = 1, y = 0})
    assertNear(a, 0, 0.001)  -- pointing right = 0

    local b = Point.angleTo({x = 0, y = 0}, {x = 0, y = 1})
    assertNear(b, math.pi / 2, 0.001)  -- pointing down = π/2
end)

test("Point.normalize creates unit vector", function()
    local p = Point.normalize({3, 4})
    local len = math.sqrt(p.x * p.x + p.y * p.y)
    assertNear(len, 1, 0.001)
end)

test("Point.fromAngle creates correct vector", function()
    local p = Point.fromAngle(0, 5)  -- angle 0, length 5
    assertNear(p.x, 5, 0.001)
    assertNear(p.y, 0, 0.001)
end)

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------

local success = runTests()
os.exit(success and 0 or 1)
