-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for Time Manipulation Operations
-- Path adjustment for tests subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Run with: lua test_time_ops.lua

local Compiler = require("spatula.compiler.compiler")

local function approxEq(a, b, eps)
    eps = eps or 0.01
    return math.abs(a - b) < eps
end

local Support = require("tests.support")
local test = Support.test
local benchmark = Support.benchmark

print("\n=== timeScale: Number vs Curve ===\n")

test("timeScale with number", function()
    local ir = Compiler.curve.timeScale(Compiler.curve.linear(1), 2)
    assert(ir.op == "timeScaleConst", "Should be timeScaleConst")
    
    local fn = Compiler.compile(ir)
    assert(approxEq(fn(1, {}), 2), "linear(t*2) at t=1 should be 2")
end)

test("timeScale with const curve", function()
    local ir = Compiler.curve.timeScale(Compiler.curve.linear(1), Compiler.curve.const(2))
    assert(ir.op == "timeScaleCurve", "Should be timeScaleCurve")
    
    local fn = Compiler.compile(ir)
    assert(approxEq(fn(1, {}), 2), "linear(t*2) at t=1 should be 2")
end)

test("timeScale with dynamic curve", function()
    -- Speed starts slow, accelerates
    local speedCurve = Compiler.curve.linear(1)  -- speed = t
    local ir = Compiler.curve.timeScale(Compiler.curve.linear(1), speedCurve)
    
    local fn = Compiler.compile(ir)
    -- At t=2, speed is 2, so effective time is 2*2=4, linear(4)=4
    assert(approxEq(fn(2, {}), 4), "At t=2, linear(t*t) should be 4")
end)

print("\n=== timeOffset: Number vs Curve ===\n")

test("timeOffset with number", function()
    local ir = Compiler.curve.timeOffset(Compiler.curve.linear(1), 5)
    assert(ir.op == "timeOffsetConst", "Should be timeOffsetConst")
    
    local fn = Compiler.compile(ir)
    assert(approxEq(fn(0, {}), 5), "linear(t+5) at t=0 should be 5")
end)

test("timeOffset with const curve", function()
    local ir = Compiler.curve.timeOffset(Compiler.curve.linear(1), Compiler.curve.const(5))
    assert(ir.op == "timeOffsetCurve", "Should be timeOffsetCurve")
    
    local fn = Compiler.compile(ir)
    assert(approxEq(fn(0, {}), 5), "linear(t+5) at t=0 should be 5")
end)

test("timeOffset with dynamic curve", function()
    -- Offset grows over time
    local offsetCurve = Compiler.curve.linear(1)  -- offset = t
    local ir = Compiler.curve.timeOffset(Compiler.curve.linear(1), offsetCurve)
    
    local fn = Compiler.compile(ir)
    -- At t=2, offset is 2, so linear(2+2) = 4
    assert(approxEq(fn(2, {}), 4), "At t=2, linear(t+t) should be 4")
end)

print("\n=== remap: General Time Substitution ===\n")

test("remap basic", function()
    local linear = Compiler.curve.linear(1)
    local doubled = Compiler.curve.linear(2)
    local ir = Compiler.curve.remap(linear, doubled)
    
    local fn = Compiler.compile(ir)
    -- linear(doubled(t)) = linear(2t) = 2t
    assert(approxEq(fn(0.5, {}), 1), "linear(2*0.5) should be 1")
    assert(approxEq(fn(1, {}), 2), "linear(2*1) should be 2")
end)

test("remap with sin time", function()
    -- Make linear oscillate by remapping time through sin
    local linear = Compiler.curve.linear(1)
    local sinTime = Compiler.curve.sin(1, 1)  -- oscillates -1 to 1
    local ir = Compiler.curve.remap(linear, sinTime)
    
    local fn = Compiler.compile(ir)
    -- At t=0.25, sin = 1, so linear(1) = 1
    assert(approxEq(fn(0.25, {}), 1), "linear(sin(0.25)) should be ~1")
end)

test("remap for reverse playback", function()
    -- Reverse: play curve from t=1 backwards to t=0
    local forward = Compiler.curve.linear(1)
    local reverseTime = Compiler.curve.sub(Compiler.curve.const(1), Compiler.curve.linear(1))
    local ir = Compiler.curve.remap(forward, reverseTime)
    
    local fn = Compiler.compile(ir)
    -- At t=0, reverseTime=1, linear(1)=1
    -- At t=1, reverseTime=0, linear(0)=0
    assert(approxEq(fn(0, {}), 1), "Reversed at t=0 should be 1")
    assert(approxEq(fn(1, {}), 0), "Reversed at t=1 should be 0")
end)

print("\n=== pingpong ===\n")

test("pingpong basic", function()
    local ir = Compiler.curve.pingpong(Compiler.curve.linear(1), 2)
    local fn = Compiler.compile(ir)
    
    -- Duration is one leg: 0 → 2 → 0 over 4 seconds.
    assert(approxEq(fn(0, {}), 0), "pingpong at t=0 should be 0")
    assert(approxEq(fn(1, {}), 1), "pingpong at t=1 should be 1")
    assert(approxEq(fn(2, {}), 2), "pingpong at t=2 should be 2 (peak)")
end)

test("pingpong repeats", function()
    local ir = Compiler.curve.pingpong(Compiler.curve.linear(1), 2)
    local fn = Compiler.compile(ir)
    
    -- Return leg, then second cycle.
    assert(approxEq(fn(3, {}), 1), "pingpong at t=3 should be 1")
    assert(approxEq(fn(4, {}), 0), "pingpong at t=4 should be 0")
    assert(approxEq(fn(6, {}), 2), "pingpong at t=6 should be 2 (second peak)")
end)

test("pingpong with different duration", function()
    local ir = Compiler.curve.pingpong(Compiler.curve.linear(1), 4)
    local fn = Compiler.compile(ir)
    
    -- Should go 0 → 4 → 0 over 8 seconds.
    assert(approxEq(fn(0, {}), 0), "pingpong at t=0 should be 0")
    assert(approxEq(fn(2, {}), 2), "pingpong at t=2 should be 2")
    assert(approxEq(fn(4, {}), 4), "pingpong at t=4 should be 4 (peak)")
    assert(approxEq(fn(8, {}), 0), "pingpong at t=8 should be 0")
end)

test("pingpong with sin", function()
    local ir = Compiler.curve.pingpong(Compiler.curve.sin(1, 10), 2)
    local fn = Compiler.compile(ir)
    
    -- sin pingponged: plays forward for 2s, backward for 2s
    -- At t=0 and t=4: sin(0) = 0
    -- At t=0.5: pingpong time = 0.5, sin(0.5) = 10*sin(π) = 0
    -- At t=0.25: pingpong time = 0.25, sin(0.25) = 10*sin(π/2) = 10
    assert(approxEq(fn(0, {}), 0), "sin(0) should be 0")
    assert(approxEq(fn(4, {}), 0), "pingpong returns to sin(0)")
    assert(approxEq(fn(0.25, {}), 10), "pingpong at t=0.25 should be at sin peak")
end)

print("\n=== Practical Use Cases ===\n")

test("bouncing animation (pingpong position)", function()
    -- Y position bounces up and down
    local bounce = Compiler.motion.xy(
        Compiler.curve.const(0),
        Compiler.curve.pingpong(Compiler.curve.linear(100), 1)  -- 0→100→0 over 2s
    )
    
    local fn = Compiler.compile(bounce)
    
    local x0, y0 = fn(0, {})
    local x1, y1 = fn(1, {})
    local x2, y2 = fn(2, {})
    
    assert(approxEq(y0, 0), "Start at y=0")
    assert(approxEq(y1, 100), "Peak at y=100")
    assert(approxEq(y2, 0), "Return to y=0")
end)

test("wobbly time (sin-based time scale)", function()
    -- Circle with wobbly speed
    local wobble = Compiler.curve.add(Compiler.curve.const(1), Compiler.curve.sin(2, 0.3))
    local wobblyCircle = Compiler.motion.xy(
        Compiler.curve.timeScale(Compiler.curve.cos(1, 100), wobble),
        Compiler.curve.timeScale(Compiler.curve.sin(1, 100), wobble)
    )
    
    local fn = Compiler.compile(wobblyCircle)
    local x, y = fn(0, {})
    
    -- Should still start at (100, 0) like a normal circle
    assert(approxEq(x, 100), "X should start at 100")
    assert(approxEq(y, 0), "Y should start at 0")
end)

test("time-based easing via remap", function()
    -- Ease-in: slow start, fast end
    -- Use t^2 as time curve
    local easeInTime = Compiler.curve.pow(Compiler.curve.linear(1), 2)
    local eased = Compiler.curve.remap(Compiler.curve.linear(1), easeInTime)
    
    local fn = Compiler.compile(eased)
    
    -- At t=0.5, eased time = 0.25, so value = 0.25
    assert(approxEq(fn(0.5, {}), 0.25), "Ease-in at t=0.5 should be 0.25")
    assert(approxEq(fn(1, {}), 1), "Ease-in at t=1 should be 1")
end)

print("\n=== All Time Operations tests complete ===\n")

Support.finish()
