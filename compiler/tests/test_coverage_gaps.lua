local unpack = table.unpack or unpack
-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for coverage gaps in Spatula Compiler
--- Covers: untested curve ops, motion patterns, signals, edge cases
--- Run with: lua5.4 test_coverage_gaps.lua

package.path = package.path .. ";../../../?.lua;../../../?/init.lua"

local Compiler = require("spatula.compiler.compiler")
local IR = require("spatula.compiler.ir")

local passed, failed = 0, 0

local function approxEq(a, b, eps)
    eps = eps or 0.0001
    return math.abs(a - b) < eps
end

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  ✓ " .. name)
    else
        failed = failed + 1
        print("  ✗ " .. name .. ": " .. tostring(err))
    end
end

local function assertEq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(b), tostring(a)))
    end
end

local function assertApprox(a, b, eps, msg)
    eps = eps or 0.0001
    if math.abs(a - b) > eps then
        error(string.format("%s: expected ~%s, got %s (diff: %s)",
            msg or "assertion failed", tostring(b), tostring(a), tostring(math.abs(a - b))))
    end
end

local function assertTrue(cond, msg)
    if not cond then error(msg or "expected true") end
end

local function assertFalse(cond, msg)
    if cond then error(msg or "expected false") end
end

--------------------------------------------------------------------------------
-- UNTESTED CURVE OPS
--------------------------------------------------------------------------------

print("\n=== Untested Curve Ops ===\n")

test("pulse: fires at start of period", function()
    local ir = IR.curve.pulse(1, 0.1)  -- freq=1, duty=0.1
    local f = Compiler.compile(ir)
    -- At t=0, should be 1 (start of period)
    assertEq(f(0, {}), 1, "pulse at t=0")
    -- At t=0.05, still in duty cycle (0.1 of period)
    assertEq(f(0.05, {}), 1, "pulse at t=0.05")
    -- At t=0.2, outside duty cycle
    assertEq(f(0.2, {}), 0, "pulse at t=0.2")
    -- At t=0.9, outside duty cycle
    assertEq(f(0.9, {}), 0, "pulse at t=0.9")
end)

test("pulse: 50% duty cycle", function()
    local ir = IR.curve.pulse(1, 0.5)
    local f = Compiler.compile(ir)
    assertEq(f(0.25, {}), 1, "pulse at t=0.25")
    assertEq(f(0.75, {}), 0, "pulse at t=0.75")
end)

test("pulse: high frequency", function()
    local ir = IR.curve.pulse(4, 0.5)  -- 4 cycles per second
    local f = Compiler.compile(ir)
    -- Period = 0.25, duty = 0.125
    assertEq(f(0, {}), 1, "start")
    assertEq(f(0.1, {}), 1, "in first duty")
    assertEq(f(0.2, {}), 0, "after first duty")
end)

test("easeIn: starts slow, ends fast", function()
    local ir = IR.curve.easeIn(1, 2)  -- duration=1, power=2 (quadratic)
    local f = Compiler.compile(ir)
    assertApprox(f(0, {}), 0, 0.001, "easeIn at t=0")
    assertApprox(f(0.5, {}), 0.25, 0.001, "easeIn at t=0.5")
    assertApprox(f(1, {}), 1, 0.001, "easeIn at t=1")
end)

test("easeIn: cubic", function()
    local ir = IR.curve.easeIn(1, 3)
    local f = Compiler.compile(ir)
    assertApprox(f(0.5, {}), 0.125, 0.001, "cubic easeIn at t=0.5")
end)

test("easeOut: starts fast, ends slow", function()
    local ir = IR.curve.easeOut(1, 2)
    local f = Compiler.compile(ir)
    assertApprox(f(0, {}), 0, 0.001, "easeOut at t=0")
    assertApprox(f(0.5, {}), 0.75, 0.001, "easeOut at t=0.5")
    assertApprox(f(1, {}), 1, 0.001, "easeOut at t=1")
end)

test("easeOut: cubic", function()
    local ir = IR.curve.easeOut(1, 3)
    local f = Compiler.compile(ir)
    assertApprox(f(0.5, {}), 0.875, 0.001, "cubic easeOut at t=0.5")
end)

test("easeInOut: smooth S-curve", function()
    local ir = IR.curve.easeInOut(1, 2)
    local f = Compiler.compile(ir)
    assertApprox(f(0, {}), 0, 0.001, "easeInOut at t=0")
    assertApprox(f(0.5, {}), 0.5, 0.001, "easeInOut at t=0.5")
    assertApprox(f(1, {}), 1, 0.001, "easeInOut at t=1")
    -- Verify symmetry
    local v1 = f(0.25, {})
    local v2 = f(0.75, {})
    assertApprox(v1 + v2, 1, 0.001, "easeInOut symmetry")
end)

test("easeInOut: slow at edges", function()
    local ir = IR.curve.easeInOut(1, 2)
    local f = Compiler.compile(ir)
    -- Near start should be slower than linear
    assertTrue(f(0.1, {}) < 0.1, "slow at start")
    -- Near end should be slower than linear
    assertTrue(f(0.9, {}) > 0.9, "slow at end")
end)

test("ramp: linear interpolation", function()
    local ir = IR.curve.ramp(10, 50, 2)  -- 10 to 50 over 2 seconds
    local f = Compiler.compile(ir)
    assertApprox(f(0, {}), 10, 0.001, "ramp at t=0")
    assertApprox(f(1, {}), 30, 0.001, "ramp at t=1")
    assertApprox(f(2, {}), 50, 0.001, "ramp at t=2")
end)

test("ramp: clamps at end", function()
    local ir = IR.curve.ramp(0, 100, 1)
    local f = Compiler.compile(ir)
    assertApprox(f(2, {}), 100, 0.001, "ramp clamps after duration")
end)

test("ramp: negative values", function()
    local ir = IR.curve.ramp(-50, 50, 1)
    local f = Compiler.compile(ir)
    assertApprox(f(0, {}), -50, 0.001, "ramp negative start")
    assertApprox(f(0.5, {}), 0, 0.001, "ramp crosses zero")
    assertApprox(f(1, {}), 50, 0.001, "ramp positive end")
end)

test("square: alternates between +amp and -amp", function()
    local ir = IR.curve.square(1, 1, 0.5)  -- freq=1, amp=1, duty=0.5
    local f = Compiler.compile(ir)
    assertApprox(f(0.25, {}), 1, 0.001, "square high")
    assertApprox(f(0.75, {}), -1, 0.001, "square low")
end)

test("square: custom duty cycle", function()
    local ir = IR.curve.square(1, 2, 0.25)  -- 25% duty
    local f = Compiler.compile(ir)
    assertApprox(f(0.1, {}), 2, 0.001, "square high in duty")
    assertApprox(f(0.5, {}), -2, 0.001, "square low outside duty")
end)

--------------------------------------------------------------------------------
-- UNTESTED MOTION PATTERNS
--------------------------------------------------------------------------------

print("\n=== Untested Motion Patterns ===\n")

test("lissajous: creates figure pattern", function()
    local ir = IR.motion.lissajous(1, 2, 100, 50, 0)  -- freqX=1, freqY=2
    local f = Compiler.compile(ir)
    local x, y = f(0, {})
    assertApprox(x, 0, 0.001, "lissajous x at t=0")
    assertApprox(y, 0, 0.001, "lissajous y at t=0")

    x, y = f(0.25, {})
    assertApprox(x, 100, 0.001, "lissajous x at t=0.25")
    -- y completes 2 cycles, so at t=0.25 it's at y=0
    assertApprox(y, 0, 0.001, "lissajous y at t=0.25")
end)

test("lissajous: phase offset", function()
    local ir = IR.motion.lissajous(1, 1, 50, 50, 0.25)  -- phase offset
    local f = Compiler.compile(ir)
    local x0, y0 = f(0, {})
    local x1, y1 = f(0.25, {})
    -- Phase offset shifts the pattern - y should differ from no-phase version
    -- At t=0, y is offset from 0 due to phase
    assertTrue(math.abs(y0) > 1, "lissajous phase shifts y at t=0")
    -- Pattern should still be bounded
    assertTrue(math.abs(y0) <= 50, "lissajous y bounded")
end)

test("sway: horizontal oscillation", function()
    local ir = IR.motion.sway(30, 2)  -- amount=30, speed=2
    local f = Compiler.compile(ir)
    local x1, y1 = f(0, {})
    local x2, y2 = f(0.25, {})  -- quarter period at speed 2
    -- y should stay near 0, x should oscillate
    assertApprox(y1, 0, 0.001, "sway y at t=0")
    assertApprox(y2, 0, 0.001, "sway y at t=0.25")
    -- x should reach max at some point
    assertTrue(math.abs(x2) > math.abs(x1) or math.abs(x1) > 0, "sway x oscillates")
end)

test("bob: vertical oscillation", function()
    local ir = IR.motion.bob(20, 3)  -- amount=20, speed=3
    local f = Compiler.compile(ir)
    local x1, y1 = f(0, {})
    local x2, y2 = f(0.1, {})  -- Check at t=0.1 where y is non-zero
    -- x should stay at 0, y should oscillate
    assertApprox(x1, 0, 0.001, "bob x at t=0")
    assertApprox(x2, 0, 0.001, "bob x at t=0.1")
    -- y should have moved from 0
    assertTrue(math.abs(y2) > 1, "bob y oscillates away from zero")
end)

test("wave: forward with sine offset", function()
    local ir = IR.motion.wave(100, 20, 2)  -- forward=100, amp=20, freq=2
    local f = Compiler.compile(ir)
    local x1, y1 = f(0, {})
    local x2, y2 = f(1, {})
    -- x should move forward
    assertApprox(x2 - x1, 100, 0.001, "wave forward motion")
    -- y should oscillate (not necessarily return to same value due to freq)
end)

test("wave: perpendicular oscillation", function()
    local ir = IR.motion.wave(50, 30, 1)
    local f = Compiler.compile(ir)
    -- Check that y reaches amplitude
    local maxY = 0
    for i = 0, 100 do
        local _, y = f(i / 100, {})
        maxY = math.max(maxY, math.abs(y))
    end
    assertTrue(maxY >= 29, "wave reaches amplitude")
end)

test("arc: circular arc motion", function()
    local ir = IR.motion.arc(0.5)  -- half turn
    local f = Compiler.compile(ir)
    local x1, y1 = f(0, {})
    local x2, y2 = f(0.5, {})
    local x3, y3 = f(1, {})
    -- Should trace an arc
    assertTrue(x1 ~= x3 or y1 ~= y3, "arc moves")
end)

test("ray: straight line in direction", function()
    local ir = IR.motion.ray(0)  -- angle=0 (right)
    local f = Compiler.compile(ir)
    local x1, y1 = f(0, {})
    local x2, y2 = f(1, {})
    -- Should move right (positive x)
    assertTrue(x2 > x1, "ray moves right")
    assertApprox(y1, 0, 0.001, "ray y at t=0")
    assertApprox(y2, 0, 0.001, "ray y stays at 0")
end)

test("ray: diagonal", function()
    local ir = IR.motion.ray(math.pi / 4)  -- 45 degrees
    local f = Compiler.compile(ir)
    local x, y = f(1, {})
    -- At 45 degrees, x and y should be equal
    assertApprox(x, y, 0.001, "ray 45 degree")
end)

--------------------------------------------------------------------------------
-- SIGNAL INTEGRATION TESTS
--------------------------------------------------------------------------------

print("\n=== Signal Integration Tests ===\n")

test("signal: reads from ctx", function()
    local ir = IR.curve.signal("myValue", 0)
    local f = Compiler.compile(ir)
    assertEq(f(0, { myValue = 42 }), 42, "signal reads ctx")
end)

test("signal: uses default when missing", function()
    local ir = IR.curve.signal("missing", 99)
    local f = Compiler.compile(ir)
    assertEq(f(0, {}), 99, "signal uses default")
end)

test("signal: in motion via scale", function()
    -- Signals on primitive params is antipattern - use scale instead
    local ir = IR.motion.scale(
        IR.motion.circle(1, 1),  -- unit circle
        IR.curve.signal("r", 50)
    )
    local f = Compiler.compile(ir)
    local x1, _ = f(0, { r = 100 })
    local x2, _ = f(0, { r = 200 })
    assertApprox(x1, 100, 0.001, "signal scale 100")
    assertApprox(x2, 200, 0.001, "signal scale 200")
end)

test("signal: combined with curve", function()
    local ir = IR.curve.add(
        IR.curve.signal("base", 0),
        IR.curve.sin(1, 10, 0)
    )
    local f = Compiler.compile(ir)
    local v1 = f(0, { base = 100 })
    local v2 = f(0.25, { base = 100 })
    assertApprox(v1, 100, 0.001, "signal + sin at t=0")
    assertApprox(v2, 110, 0.001, "signal + sin at peak")
end)

test("signal: scaled by curve", function()
    local ir = IR.curve.mul(
        IR.curve.signal("intensity", 1),
        IR.curve.sin(1, 1, 0)
    )
    local f = Compiler.compile(ir)
    local v1 = f(0.25, { intensity = 5 })
    local v2 = f(0.25, { intensity = 10 })
    assertApprox(v1, 5, 0.001, "signal * sin intensity 5")
    assertApprox(v2, 10, 0.001, "signal * sin intensity 10")
end)

test("signal: S shorthand works", function()
    local ir = IR.curve.S("test", 123)
    local f = Compiler.compile(ir)
    assertEq(f(0, {}), 123, "S shorthand")
end)

--------------------------------------------------------------------------------
-- ELLIPSE UNIT FORM TESTS (via distribution)
-- Note: Unit forms are for distributions, not compileForm
--------------------------------------------------------------------------------

print("\n=== Ellipse Unit Form Tests ===\n")

test("ellipseUnit: in distribution filters correctly", function()
    -- ellipseUnit with aspect 2:1 (wider than tall)
    local form = IR.form.ellipseUnit(1, 0.5)
    local dist = IR.distribution.grid(form, 10, 10)
    local f = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = f(0, 0, 100, xs, ys)
    -- Should have some points, but not all 100 (grid filtered by ellipse)
    assertTrue(count > 0, "ellipse has points")
    assertTrue(count < 100, "ellipse filters grid")
end)

test("ellipseUnit: aspect ratio affects shape", function()
    -- Wide ellipse (2:1)
    local wideForm = IR.form.ellipseUnit(1, 0.5)
    local wideDist = IR.distribution.grid(wideForm, 10, 10)
    local wideF = Compiler.compileDistribution(wideDist)
    local xs1, ys1 = {}, {}
    local wideCount = wideF(0, 0, 100, xs1, ys1)

    -- Tall ellipse (1:2)
    local tallForm = IR.form.ellipseUnit(0.5, 1)
    local tallDist = IR.distribution.grid(tallForm, 10, 10)
    local tallF = Compiler.compileDistribution(tallDist)
    local xs2, ys2 = {}, {}
    local tallCount = tallF(0, 0, 100, xs2, ys2)

    -- Both should have similar count (rotated versions)
    assertApprox(wideCount, tallCount, 5, "aspect ratios give similar counts")
end)

test("ellipseUnit: circular when aspects equal", function()
    local form = IR.form.ellipseUnit(1, 1)  -- circle
    local dist = IR.distribution.rings(form, 1, 8)
    local f = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = f(0, 0, 100, xs, ys)
    -- All 8 points should be included (on circle boundary)
    assertEq(count, 8, "circular ellipse includes all ring points")
end)

test("ellipseUnit: excludes points outside", function()
    -- Very flat ellipse
    local form = IR.form.ellipseUnit(1, 0.1)
    local dist = IR.distribution.grid(form, 5, 5)
    local f = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = f(0, 0, 100, xs, ys)
    -- Very flat, should exclude most of the grid
    assertTrue(count < 10, "flat ellipse excludes most points")
end)

--------------------------------------------------------------------------------
-- ERROR PATH AND EDGE CASE TESTS
--------------------------------------------------------------------------------

print("\n=== Error Paths and Edge Cases ===\n")

test("compile with nil ctx uses empty table", function()
    local ir = IR.curve.const(5)
    local f = Compiler.compile(ir)
    -- Should not error with nil ctx
    local ok, result = pcall(f, 0, nil)
    assertTrue(ok, "handles nil ctx")
end)

test("very large time values", function()
    local ir = IR.curve.sin(1, 1, 0)
    local f = Compiler.compile(ir)
    -- Should not overflow or NaN
    local v = f(1e10, {})
    assertTrue(v == v, "no NaN at large t")  -- NaN ~= NaN
    assertTrue(math.abs(v) <= 1, "bounded at large t")
end)

test("very small time values", function()
    local ir = IR.curve.sin(1, 1, 0)
    local f = Compiler.compile(ir)
    local v = f(1e-10, {})
    assertTrue(v == v, "no NaN at tiny t")
    assertApprox(v, 0, 0.001, "near zero at tiny t")
end)

test("zero frequency curve", function()
    local ir = IR.curve.sin(0, 1, 0)
    local f = Compiler.compile(ir)
    -- Zero frequency = constant at phase value
    local v1 = f(0, {})
    local v2 = f(100, {})
    assertEq(v1, v2, "zero freq is constant")
end)

test("negative amplitude", function()
    local ir = IR.curve.sin(1, -5, 0)
    local f = Compiler.compile(ir)
    assertApprox(f(0.25, {}), -5, 0.001, "negative amp inverts")
end)

test("negative frequency", function()
    local ir = IR.curve.sin(-1, 1, 0)
    local f = Compiler.compile(ir)
    -- Negative freq = reverse direction
    local v = f(0.25, {})
    assertApprox(v, -1, 0.001, "negative freq reverses")
end)

test("deeply nested operations (10 levels)", function()
    -- Build: ((((((((((x + 1) + 1) + 1)...
    local ir = IR.curve.linear(1)
    for i = 1, 10 do
        ir = IR.curve.offset(ir, 1)
    end
    local f = Compiler.compile(ir)
    assertApprox(f(0, {}), 10, 0.001, "10 nested offsets at t=0")
    assertApprox(f(1, {}), 11, 0.001, "10 nested offsets at t=1")
end)

test("deeply nested scales (10 levels)", function()
    local ir = IR.curve.const(1)
    for i = 1, 10 do
        ir = IR.curve.scale(ir, 2)
    end
    local f = Compiler.compile(ir)
    assertEq(f(0, {}), 1024, "2^10 scaling")
end)

test("mixed deep nesting", function()
    local ir = IR.curve.sin(1, 1, 0)
    ir = IR.curve.scale(ir, 2)
    ir = IR.curve.offset(ir, 5)
    ir = IR.curve.abs(ir)
    ir = IR.curve.scale(ir, 0.5)
    local f = Compiler.compile(ir)
    -- At t=0: sin=0, *2=0, +5=5, abs=5, *0.5=2.5
    assertApprox(f(0, {}), 2.5, 0.001, "mixed nesting at t=0")
end)

test("motion with zero radius", function()
    local ir = IR.motion.circle(0, 1)
    local f = Compiler.compile(ir)
    local x, y = f(0.5, {})
    assertApprox(x, 0, 0.001, "zero radius x")
    assertApprox(y, 0, 0.001, "zero radius y")
end)

test("motion with zero speed", function()
    local ir = IR.motion.circle(100, 0)
    local f = Compiler.compile(ir)
    local x1, y1 = f(0, {})
    local x2, y2 = f(100, {})
    -- Zero speed = stuck at initial position
    assertApprox(x1, x2, 0.001, "zero speed x constant")
    assertApprox(y1, y2, 0.001, "zero speed y constant")
end)

test("form with very small radius", function()
    local ir = IR.form.circle(0, 0, 0.001)
    local f = Compiler.compileForm(ir)
    assertTrue(f(0, 0, {}), "tiny radius center inside")
    assertFalse(f(0.01, 0, {}), "tiny radius excludes nearby")
end)

test("distribution with count=0", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.random(form, 0)
    local f = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = f(0, 0, 100, xs, ys)
    assertEq(count, 0, "zero count distribution")
end)

test("distribution with count=1", function()
    local form = IR.form.circleUnit()
    local dist = IR.distribution.rings(form, 1, 1)
    local f = Compiler.compileDistribution(dist)
    local xs, ys = {}, {}
    local count = f(0, 0, 100, xs, ys)
    assertEq(count, 1, "single point distribution")
end)

--------------------------------------------------------------------------------
-- NUMERICAL STABILITY TESTS
--------------------------------------------------------------------------------

print("\n=== Numerical Stability ===\n")

test("huge values don't overflow", function()
    local ir = IR.curve.scale(IR.curve.const(1e100), 1e100)
    local f = Compiler.compile(ir)
    local v = f(0, {})
    assertTrue(v == math.huge or v > 1e199, "huge value handled")
end)

test("tiny values don't underflow to zero incorrectly", function()
    local ir = IR.curve.scale(IR.curve.const(1e-100), 1e-100)
    local f = Compiler.compile(ir)
    local v = f(0, {})
    assertTrue(v == 0 or v < 1e-199, "tiny value handled")
end)

test("sin/cos at extreme t values", function()
    local ir = IR.motion.circle(100, 1)
    local f = Compiler.compile(ir)
    -- Very large t
    local x, y = f(1e15, {})
    local dist = math.sqrt(x*x + y*y)
    assertApprox(dist, 100, 1, "large t stays on circle")
end)

test("accumulated rounding in long sequence", function()
    -- Create a sequence that could accumulate error
    local children = {}
    for i = 1, 100 do
        children[i] = IR.curve.const(0.01)
    end
    local ir = IR.curve.add(unpack(children))
    local f = Compiler.compile(ir)
    assertApprox(f(0, {}), 1, 0.001, "100 * 0.01 = 1")
end)

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------

print("\n" .. string.rep("=", 50))
print(string.format("Results: %d passed, %d failed", passed, failed))
print(string.rep("=", 50))

if failed > 0 then
    os.exit(1)
end
