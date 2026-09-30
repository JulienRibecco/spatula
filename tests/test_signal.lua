-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "bootstrap.lua")
-- tests/test_signal.lua
-- Tests for Signal: a Curve that reads from ctx

package.path = package.path .. ";../?.lua;../?/init.lua"
package.preload["spatula.util"] = function() return require("util") end
package.preload["spatula.curve"] = function() return require("curve") end
package.preload["spatula.signal"] = function() return require("signal") end

local Signal = require("signal")
local Motion = require("motion")
local Curve = require("curve")

-- Test framework
local passed, failed = 0, 0
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

local function eq(a, b, eps)
    eps = eps or 0.0001
    return math.abs(a - b) < eps
end

print("\n=== Signal User API Tests ===\n")

test("Signal.new returns a function", function()
    local s = Signal.new("speed")
    assert(type(s) == "function")
end)

test("Signal callable shorthand", function()
    local s = Signal("speed")
    assert(type(s) == "function")
end)

test("Signal reads from ctx", function()
    local s = Signal("speed")
    local v = s(0, { speed = 42 })
    assert(v == 42)
end)

test("Signal uses default when key missing", function()
    local s = Signal("speed", 10)
    local v = s(0, { other = 5 })
    assert(v == 10)
end)

test("Signal default is 0 if not specified", function()
    local s = Signal("speed")
    local v = s(0, { other = 5 })
    assert(v == 0)
end)

test("Signal works with nil ctx", function()
    local s = Signal("speed", 25)
    local v = s(0, nil)
    assert(v == 25)
end)

test("Signal works with no ctx argument", function()
    local s = Signal("speed", 30)
    local v = s(0)
    assert(v == 30)
end)

test("Signal reads explicit false/0 values from ctx", function()
    local s = Signal("enabled", 1)
    local v = s(0, { enabled = 0 })
    assert(v == 0)
end)

test("Signal ignores time parameter", function()
    local s = Signal("value", 5)
    local v1 = s(0, { value = 10 })
    local v2 = s(100, { value = 10 })
    local v3 = s(999, { value = 10 })
    assert(v1 == 10 and v2 == 10 and v3 == 10)
end)

print("\n=== Signal LFO (Curve as Value) Tests ===\n")

test("Signal auto-evaluates curve from ctx (LFO)", function()
    -- Set a curve (LFO) as the signal value
    local lfo = Curve.sin(1, 10)  -- sin with freq=1, amp=10
    local s = Signal("wobble")

    -- When wobble is a curve, it should be auto-evaluated with (t, ctx)
    local v0 = s(0, { wobble = lfo })      -- sin(0) * 10 = 0
    local v25 = s(0.25, { wobble = lfo })  -- sin(0.25 * 2*PI) * 10 = 10

    assert(eq(v0, 0), "At t=0, sin should be 0, got " .. v0)
    assert(eq(v25, 10), "At t=0.25, sin should be 10, got " .. v25)
end)

test("Signal auto-evaluates curve from globals (LFO)", function()
    local lfo = Curve.sin(1, 5)
    Signal.setGlobal("globalLFO", lfo)

    local s = Signal("globalLFO")
    local v0 = s(0)      -- sin(0) * 5 = 0
    local v25 = s(0.25)  -- sin(0.25 * 2*PI) * 5 = 5

    assert(eq(v0, 0), "Global LFO at t=0 should be 0, got " .. v0)
    assert(eq(v25, 5), "Global LFO at t=0.25 should be 5, got " .. v25)

    Signal.clearGlobals()
end)

test("Signal auto-evaluates curve from active context (LFO)", function()
    local lfo = Curve.linear(2)  -- returns t * 2

    Signal.setActive({ myLFO = lfo })

    local s = Signal("myLFO")
    local v0 = s(0)    -- 0 * 2 = 0
    local v1 = s(1)    -- 1 * 2 = 2
    local v5 = s(5)    -- 5 * 2 = 10

    assert(eq(v0, 0), "At t=0, linear(2) should be 0, got " .. v0)
    assert(eq(v1, 2), "At t=1, linear(2) should be 2, got " .. v1)
    assert(eq(v5, 10), "At t=5, linear(2) should be 10, got " .. v5)

    Signal.setActive(nil)
end)

test("Signal still works with regular values", function()
    local s = Signal("value", 0)

    -- Static number
    assert(s(0, { value = 42 }) == 42, "Static number should work")

    -- From globals
    Signal.setGlobal("value", 100)
    assert(s(0) == 100, "Global static value should work")

    Signal.clearGlobals()
end)

print("\n=== Signal + Motion Composition Tests ===\n")

-- NOTE: Interpreted Motion/Curve modules expect numeric constants.
-- Signal composition works at the COMPILER level, not interpreted level.
-- These tests verify Signal works with curve combinators that support functions.

test("Motion.scale with Signal factor", function()
    -- scale accepts a curve/function as factor
    local m = Motion.scale(Motion.circle(50, 1), Signal("scale", 1))
    local x1, y1 = m(0, { scale = 2 })
    -- At t=0, circle(50,1) gives (50, 0), scaled by 2 = (100, 0)
    assert(eq(x1, 100))
    assert(eq(y1, 0))
end)

test("Motion.mix with Signal factor", function()
    local m = Motion.mix(
        Motion.circle(50, 1),
        Motion.circle(100, 1),
        Signal("blend", 0.5)
    )
    local x, y = m(0, { blend = 0 })
    -- blend=0 means 100% first motion: (50, 0)
    assert(eq(x, 50))
end)

test("Motion.rotate with Signal angle", function()
    local m = Motion.rotate(Motion.drift(1, 0), Signal("angle", 0))
    local x, y = m(1, { angle = math.pi / 2 })
    -- drift(1,0) at t=1 gives (1,0), rotated 90deg = (0, 1)
    assert(eq(x, 0, 0.001))
    assert(eq(y, 1, 0.001))
end)

print("\n=== Signal + Curve Composition Tests ===\n")

test("Curve.scale with Signal factor", function()
    local c = Curve.scale(Curve.linear(1), Signal("mult", 1))
    local v = c(5, { mult = 3 })
    -- linear(1)(5) = 5, scaled by 3 = 15
    assert(eq(v, 15))
end)

test("Curve.offset with Signal amount", function()
    local c = Curve.offset(Curve.const(10), Signal("off", 0))
    local v = c(0, { off = 5 })
    assert(eq(v, 15))
end)

print("\n=== Compiler IR Tests ===\n")

-- Test compiler IR
package.path = package.path .. ";../compiler/?.lua;../compiler/?/init.lua"
local IR = require("ir")
local Compiler = require("compiler")

test("IR.curve.signal creates valid node", function()
    local node = IR.curve.signal("speed", 100)
    assert(node.op == "fromCtx")
    assert(node.key == "speed")
    assert(node.default == 100)
end)

test("IR.curve.S shorthand works", function()
    local node = IR.curve.S("radius")
    assert(node.op == "fromCtx")
    assert(node.key == "radius")
    assert(node.default == 0)
end)

test("Compiled signal reads values and evaluates LFOs with the original context", function()
    local fn = Compiler.compile(IR.curve.signal("speed", 50))
    assert(eq(fn(0, {}), 50))
    assert(eq(fn(0, {speed = 12}), 12))
    local ctx = {factor = 3, speed = function(t, context) return t * context.factor end}
    assert(eq(fn(2, ctx), 6))
end)

-- NOTE: Signals in sin/cos freq/amp require dynamic emission (not yet implemented)
-- For now, signals work in combinators (scale, offset, mix) but not in sin/cos params

test("Compiled motion with signal in scale", function()
    -- Use signal in scale combinator, which works
    local ir = IR.motion.scale(
        IR.motion.circle(50, 1),
        IR.curve.signal("scale", 1)
    )
    local fn = Compiler.compile(ir)
    local x1, y1 = fn(0, { scale = 2 })
    -- circle(50,1) at t=0 gives (50, 0), scaled by 2
    assert(eq(x1, 100))
    assert(eq(y1, 0))
end)

test("Compiled signal uses default when ctx missing", function()
    local ir = IR.curve.signal("value", 42)
    local fn = Compiler.compile(ir)
    local v = fn(0, {})
    assert(eq(v, 42))
end)

test("Compiled mixed literal and signal", function()
    local ir = IR.motion.xy(
        IR.curve.signal("x", 0),
        IR.curve.const(100)
    )
    local fn = Compiler.compile(ir)
    local x, y = fn(0, { x = 50 })
    assert(eq(x, 50))
    assert(eq(y, 100))
end)

print("\n=== Form Signal Tests ===\n")

test("Form circle with signal radius", function()
    local ir = IR.form.circle(0, 0, IR.curve.signal("radius", 50))
    local code = Compiler.formToSource(ir)
    assert(code:find("ctx.radius or 50"))
end)

test("Form rect with signal dimensions", function()
    local ir = IR.form.rect(
        IR.curve.signal("ox", 0),
        IR.curve.signal("oy", 0),
        IR.curve.signal("hw", 100),
        IR.curve.signal("hh", 50)
    )
    local code = Compiler.formToSource(ir)
    assert(code:find("ctx.ox or 0"))
    assert(code:find("ctx.hw or 100"))
end)

test("Compiled form with signal works", function()
    local ir = IR.form.circle(
        IR.curve.signal("cx", 0),
        IR.curve.signal("cy", 0),
        IR.curve.signal("r", 100)
    )
    local fn = Compiler.compileForm(ir)
    -- Point at (50, 0) should be in circle centered at (0,0) with radius 100
    assert(fn(50, 0, { cx = 0, cy = 0, r = 100 }) == true)
    -- Same point should be outside if radius is smaller
    assert(fn(50, 0, { cx = 0, cy = 0, r = 30 }) == false)
end)

print("\n=== Trigger Signal Tests ===\n")

test("Trigger interval with signal", function()
    -- triggerToSource takes (timingIR, selectionIR) - two args
    local timing = IR.trigger.interval(IR.curve.signal("freq", 1))
    local selection = IR.trigger.selectAll()
    local code = Compiler.triggerToSource(timing, selection)
    assert(code:find("ctx.freq or 1"))
end)

test("Trigger burst with signal count", function()
    local timing = IR.trigger.burst(
        IR.curve.signal("count", 5),
        0.1,
        0.5
    )
    local selection = IR.trigger.selectAll()
    local code = Compiler.triggerToSource(timing, selection)
    assert(code:find("ctx.count or 5"))
end)

test("Selection with signal n", function()
    local timing = IR.trigger.times(3, 1)
    local selection = IR.trigger.selectRandom(IR.curve.signal("n", 1))
    local code = Compiler.triggerToSource(timing, selection)
    assert(code:find("ctx.n or 1"))
end)

print("\n=== Distribution Signal Tests ===\n")

test("Distribution sample with signal count", function()
    -- Distribution uses unit forms (circleUnit, rectUnit, etc.)
    local motion = IR.motion.circle(1, 1)  -- radius 1, freq 1 for unit circle
    local form = IR.form.circleUnit()
    local ir = IR.distribution.sample(motion, form, IR.curve.signal("count", 10))
    local fn = Compiler.compileDistribution(ir)
    -- Basic test that it compiles and works
    local outX, outY = {}, {}
    local count = fn(0, 0, 100, outX, outY, { count = 5 })
    assert(count == 5)
end)

test("Distribution grid with signal cols/rows", function()
    local form = IR.form.rectUnit()
    local ir = IR.distribution.grid(
        form,
        IR.curve.signal("cols", 3),
        IR.curve.signal("rows", 3)
    )
    local fn = Compiler.compileDistribution(ir)
    local outX, outY = {}, {}
    -- With cols=3, rows=3, should get up to 9 points (filtered by form)
    local count = fn(0, 0, 100, outX, outY, { cols = 3, rows = 3 })
    assert(count <= 9)
end)

test("Compiled distribution with signal works", function()
    local motion = IR.motion.circle(1, 1)
    local form = IR.form.circleUnit()
    local ir = IR.distribution.sample(motion, form, IR.curve.signal("n", 5))
    local fn = Compiler.compileDistribution(ir)
    local outX, outY = {}, {}
    -- With n=5, should get 5 points
    local count = fn(0, 0, 100, outX, outY, { n = 5 })
    assert(count == 5)
    -- With n=3, should get 3 points
    count = fn(0, 0, 100, outX, outY, { n = 3 })
    assert(count == 3)
end)

print("\n=== Field Signal Tests ===\n")

test("StaticField with signal source position", function()
    local ir = IR.field.static({
        sources = {
            { x = IR.curve.signal("srcX", 0), y = IR.curve.signal("srcY", 0), radius = 100, value = 1 }
        }
    })
    local code = Compiler.staticFieldToSource(ir)
    assert(code:find("ctx.srcX or 0"))
    assert(code:find("ctx.srcY or 0"))
end)

test("StaticField with signal radius and value", function()
    local ir = IR.field.static({
        sources = {
            { x = 0, y = 0, radius = IR.curve.signal("r", 50), value = IR.curve.signal("v", 1) }
        }
    })
    local code = Compiler.staticFieldToSource(ir)
    assert(code:find("ctx.r or 50"))
    assert(code:find("ctx.v or 1"))
end)

test("StaticField with signal base", function()
    local ir = IR.field.static({
        base = IR.curve.signal("base", 0.5),
        sources = {
            { x = 0, y = 0, radius = 100, value = 1 }
        }
    })
    local code = Compiler.staticFieldToSource(ir)
    assert(code:find("ctx.base or 0.5"))
end)

test("Compiled field with signal works", function()
    local ir = IR.field.static({
        sources = {
            { x = IR.curve.signal("fx", 0), y = 0, radius = 100, value = 1 }
        }
    })
    local fn = Compiler.compileStaticField(ir)
    -- Sample at (0,0) with source at (0,0) - should be high
    local v1 = fn(0, 0, { fx = 0 })
    assert(v1 > 0.9)  -- At center
    -- Sample at (0,0) with source at (200,0) - should be 0 (out of range)
    local v2 = fn(0, 0, { fx = 200 })
    assert(v2 == 0)
end)

print("\n" .. string.rep("-", 40))
print(string.format("%d passed, %d failed", passed, failed))

if failed > 0 then
    os.exit(1)
end
