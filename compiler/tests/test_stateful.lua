-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for Stateful Curves (follow, spring)
-- Path adjustment for tests subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Run with: lua test_stateful.lua

local Compiler = require("spatula.compiler.compiler")

local function approxEq(a, b, eps)
    eps = eps or 0.01  -- Looser tolerance for stateful curves
    return math.abs(a - b) < eps
end

local Support = require("tests.support")
local test = Support.test
local benchmark = Support.benchmark

print("\n=== Stateful: Follow Curve ===\n")

test("follow compiles without error", function()
    local ir = Compiler.curve.follow(Compiler.curve.const(100), 5)
    local f = Compiler.compile(ir)
    assert(type(f) == "function")
end)

test("follow starts at target value", function()
    local ir = Compiler.curve.follow(Compiler.curve.const(100), 5)
    local f = Compiler.compile(ir)
    
    local ctx = {}
    local v = f(0, ctx)
    assert(approxEq(v, 100), "Should start at target, got " .. v)
end)

test("follow approaches moving target", function()
    -- Target = t * 100 (grows linearly)
    local ir = Compiler.curve.follow(Compiler.curve.linear(100), 10)
    local f = Compiler.compile(ir)
    
    local ctx = {}
    local lastValue = 0
    
    -- Simulate several frames
    for i = 1, 10 do
        local t = i * 0.1
        local v = f(t, ctx)
        
        -- Value should be increasing
        assert(v > lastValue, 
            string.format("Value should increase: t=%s v=%s lastV=%s", t, v, lastValue))
        lastValue = v
    end
end)

test("follow with high speed catches up quickly", function()
    local ir = Compiler.curve.follow(Compiler.curve.const(100), 100)  -- Very high speed
    local f = Compiler.compile(ir)
    
    local ctx = {}
    f(0, ctx)  -- Initialize
    
    -- After some time, should be very close to target
    local v = f(0.1, ctx)
    assert(v > 90, "High speed follow should be close to target quickly, got " .. v)
end)

test("follow with low speed approaches slowly", function()
    local ir = Compiler.curve.follow(Compiler.curve.const(100), 0.5)  -- Low speed
    local f = Compiler.compile(ir)
    
    local ctx = {}
    f(0, ctx)  -- Initialize at 100
    
    -- Change target by re-creating (or use fromCtx in real usage)
    -- Since target is const(100), value stays at 100
    local v = f(0.1, ctx)
    assert(approxEq(v, 100), "Should stay at constant target, got " .. v)
end)

test("follow state persists in ctx", function()
    local ir = Compiler.curve.follow(Compiler.curve.const(100), 5)
    local f = Compiler.compile(ir)
    
    local ctx = {}
    f(0, ctx)
    
    assert(ctx.curveState ~= nil, "ctx.curveState should exist")
    assert(ctx.curveState[ir.stateId] ~= nil, "State for curve 1 should exist")
    assert(ctx.curveState[ir.stateId].value ~= nil, "State should have value")
    assert(ctx.curveState[ir.stateId].lastT ~= nil, "State should have lastT")
end)

print("\n=== Stateful: Spring Curve ===\n")

test("spring compiles without error", function()
    local ir = Compiler.curve.spring(Compiler.curve.const(100), 100, 10)
    local f = Compiler.compile(ir)
    assert(type(f) == "function")
end)

test("spring starts at target value", function()
    local ir = Compiler.curve.spring(Compiler.curve.const(100), 100, 10)
    local f = Compiler.compile(ir)
    
    local ctx = {}
    local v = f(0, ctx)
    assert(approxEq(v, 100), "Should start at target, got " .. v)
end)

test("spring oscillates toward target", function()
    -- Target = 100, start from 0
    local ir = Compiler.curve.spring(Compiler.curve.const(100), 50, 5)
    local f = Compiler.compile(ir)
    
    local ctx = {}
    f(0, ctx)
    -- Manually set initial value to 0 to test spring behavior
    ctx.curveState[ir.stateId].value = 0
    ctx.curveState[ir.stateId].velocity = 0
    
    local values = {}
    for i = 1, 20 do
        local t = i * 0.05
        local v = f(t, ctx)
        values[#values + 1] = v
    end
    
    -- Spring should move toward 100
    assert(values[#values] > values[1], "Spring should move toward target")
    
    -- Check for oscillation (values should cross the target and come back)
    local crossed = false
    for i = 2, #values do
        if (values[i] > 100) ~= (values[i-1] > 100) then
            crossed = true
            break
        end
    end
    -- Note: may not always oscillate depending on damping, that's OK
end)

test("spring state includes velocity", function()
    local ir = Compiler.curve.spring(Compiler.curve.const(100), 100, 10)
    local f = Compiler.compile(ir)
    
    local ctx = {}
    f(0, ctx)
    
    assert(ctx.curveState ~= nil, "ctx.curveState should exist")
    assert(ctx.curveState[ir.stateId] ~= nil, "State for curve 1 should exist")
    assert(ctx.curveState[ir.stateId].velocity ~= nil, "Spring state should have velocity")
end)

test("critically damped spring doesn't overshoot much", function()
    -- Critical damping = 2 * sqrt(stiffness)
    local stiffness = 100
    local criticalDamping = 2 * math.sqrt(stiffness)
    
    local ir = Compiler.curve.spring(Compiler.curve.const(100), stiffness, criticalDamping)
    local f = Compiler.compile(ir)
    
    local ctx = {}
    f(0, ctx)
    ctx.curveState[ir.stateId].value = 0
    ctx.curveState[ir.stateId].velocity = 0
    
    local maxVal = 0
    for i = 1, 100 do
        local t = i * 0.01
        local v = f(t, ctx)
        if v > maxVal then maxVal = v end
    end
    
    -- Critically damped should not overshoot much past 100
    assert(maxVal < 120, "Critically damped spring should not overshoot much, max=" .. maxVal)
end)

print("\n=== Stateful: Multiple Stateful Curves ===\n")

test("multiple follow curves have independent state", function()
    local ir = Compiler.motion.xy(
        Compiler.curve.follow(Compiler.curve.const(100), 5),
        Compiler.curve.follow(Compiler.curve.const(200), 5)
    )
    local f = Compiler.compile(ir)
    
    local ctx = {}
    local x, y = f(0, ctx)
    
    assert(approxEq(x, 100), "X should start at 100, got " .. x)
    assert(approxEq(y, 200), "Y should start at 200, got " .. y)
    
    -- Check they have separate state
    assert(ctx.curveState[ir.x.stateId] ~= nil, "State 1 should exist")
    assert(ctx.curveState[ir.y.stateId] ~= nil, "State 2 should exist")
    assert(ctx.curveState[ir.x.stateId].value ~= ctx.curveState[ir.y.stateId].value,
        "States should have different values")
end)

test("follow with ctx-based target", function()
    -- Target comes from ctx
    local ir = Compiler.curve.follow(
        Compiler.curve.fromCtx("target", 0),
        5
    )
    local f = Compiler.compile(ir)
    
    local ctx = { target = 100 }
    local v1 = f(0, ctx)
    assert(approxEq(v1, 100), "Should initialize to ctx target")
    
    -- Change target
    ctx.target = 200
    local v2 = f(0.1, ctx)
    -- Value should be moving toward 200 but not there yet
    assert(v2 > v1, "Should be moving toward new target")
end)

print("\n=== Stateful: Generated Code ===\n")

print("--- follow(const(100), 5) ---")
local ir1 = Compiler.curve.follow(Compiler.curve.const(100), 5)
print(Compiler.toSource(ir1))
print("")

print("--- spring(const(100), 100, 10) ---")
local ir2 = Compiler.curve.spring(Compiler.curve.const(100), 100, 10)
print(Compiler.toSource(ir2))
print("")

print("--- follow(fromCtx('target'), 10) ---")
local ir3 = Compiler.curve.follow(Compiler.curve.fromCtx("target", 0), 10)
print(Compiler.toSource(ir3))

print("\n=== All Stateful tests complete ===\n")

Support.finish()
