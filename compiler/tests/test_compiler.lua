-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for Spatula Compiler
-- Path adjustment for tests subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Run with: lua test_compiler.lua

local Compiler = require("spatula.compiler.compiler")

local function approxEq(a, b, eps)
    eps = eps or 0.0001
    return math.abs(a - b) < eps
end

local Support = require("tests.support")
local test = Support.test
local benchmark = Support.benchmark

print("\n=== Curve Primitives ===\n")

test("const", function()
    local ir = Compiler.curve.const(42)
    local f = Compiler.compile(ir)
    assert(f(0, {}) == 42)
    assert(f(100, {}) == 42)
end)

test("linear", function()
    local ir = Compiler.curve.linear(2)
    local f = Compiler.compile(ir)
    assert(approxEq(f(0, {}), 0))
    assert(approxEq(f(1, {}), 2))
    assert(approxEq(f(0.5, {}), 1))
end)

test("sin", function()
    local ir = Compiler.curve.sin(1, 1, 0)
    local f = Compiler.compile(ir)
    assert(approxEq(f(0, {}), 0))
    assert(approxEq(f(0.25, {}), 1))
    assert(approxEq(f(0.5, {}), 0))
    assert(approxEq(f(0.75, {}), -1))
end)

test("cos", function()
    local ir = Compiler.curve.cos(1, 1, 0)
    local f = Compiler.compile(ir)
    assert(approxEq(f(0, {}), 1))
    assert(approxEq(f(0.25, {}), 0))
    assert(approxEq(f(0.5, {}), -1))
end)

test("sin with amplitude", function()
    local ir = Compiler.curve.sin(1, 5, 0)
    local f = Compiler.compile(ir)
    assert(approxEq(f(0.25, {}), 5))
    assert(approxEq(f(0.75, {}), -5))
end)

test("triangle", function()
    local ir = Compiler.curve.triangle(1, 1)
    local f = Compiler.compile(ir)
    assert(approxEq(f(0, {}), -1))
    assert(approxEq(f(0.25, {}), 0))
    assert(approxEq(f(0.5, {}), 1))
end)

test("saw", function()
    local ir = Compiler.curve.saw(1, 1)
    local f = Compiler.compile(ir)
    assert(approxEq(f(0, {}), -1))
    assert(approxEq(f(0.5, {}), 0))
    assert(approxEq(f(0.99, {}), 0.98, 0.02))
end)

test("noise deterministic", function()
    local ir = Compiler.curve.noise(1, 42)
    local f = Compiler.compile(ir)
    local v1 = f(0.5, {})
    local v2 = f(0.5, {})
    assert(v1 == v2, "noise should be deterministic")
end)

print("\n=== Curve Combinators ===\n")

test("add", function()
    local ir = Compiler.curve.add(
        Compiler.curve.const(10),
        Compiler.curve.const(5)
    )
    local f = Compiler.compile(ir)
    assert(f(0, {}) == 15)
end)

test("mul", function()
    local ir = Compiler.curve.mul(
        Compiler.curve.const(3),
        Compiler.curve.const(4)
    )
    local f = Compiler.compile(ir)
    assert(f(0, {}) == 12)
end)

test("sub", function()
    local ir = Compiler.curve.sub(
        Compiler.curve.const(10),
        Compiler.curve.const(3)
    )
    local f = Compiler.compile(ir)
    assert(f(0, {}) == 7)
end)

test("scale const", function()
    local ir = Compiler.curve.scale(Compiler.curve.linear(1), 5)
    local f = Compiler.compile(ir)
    assert(approxEq(f(2, {}), 10))
end)

test("offset const", function()
    local ir = Compiler.curve.offset(Compiler.curve.linear(1), 100)
    local f = Compiler.compile(ir)
    assert(approxEq(f(5, {}), 105))
end)

test("neg", function()
    local ir = Compiler.curve.neg(Compiler.curve.const(7))
    local f = Compiler.compile(ir)
    assert(f(0, {}) == -7)
end)

test("abs", function()
    local ir = Compiler.curve.abs(Compiler.curve.sin(1, 1))
    local f = Compiler.compile(ir)
    assert(f(0.25, {}) >= 0)
    assert(f(0.75, {}) >= 0)
end)

test("pow const", function()
    local ir = Compiler.curve.pow(Compiler.curve.linear(1), 2)
    local f = Compiler.compile(ir)
    assert(approxEq(f(3, {}), 9))
end)

test("clamp", function()
    local ir = Compiler.curve.clamp(Compiler.curve.linear(1), 0, 5)
    local f = Compiler.compile(ir)
    assert(f(-10, {}) == 0)
    assert(f(3, {}) == 3)
    assert(f(100, {}) == 5)
end)

test("timeScale", function()
    local ir = Compiler.curve.timeScale(Compiler.curve.linear(1), 2)
    local f = Compiler.compile(ir)
    assert(approxEq(f(1, {}), 2))  -- t=1 becomes t=2
end)

test("loop", function()
    local ir = Compiler.curve.loop(Compiler.curve.linear(1), 3)
    local f = Compiler.compile(ir)
    assert(approxEq(f(0, {}), 0))
    assert(approxEq(f(2.5, {}), 2.5))
    assert(approxEq(f(3, {}), 0))
    assert(approxEq(f(4, {}), 1))
end)

print("\n=== Motion Primitives ===\n")

test("motion.xy", function()
    local ir = Compiler.motion.xy(
        Compiler.curve.const(10),
        Compiler.curve.const(20)
    )
    local f = Compiler.compile(ir)
    local x, y = f(0, {})
    assert(x == 10)
    assert(y == 20)
end)

test("motion.circle", function()
    local ir = Compiler.motion.circle(100, 1)
    local f = Compiler.compile(ir)
    
    local x0, y0 = f(0, {})
    assert(approxEq(x0, 100))
    assert(approxEq(y0, 0))
    
    local x25, y25 = f(0.25, {})
    assert(approxEq(x25, 0))
    assert(approxEq(y25, 100))
    
    local x50, y50 = f(0.5, {})
    assert(approxEq(x50, -100))
    assert(approxEq(y50, 0))
end)

test("motion.ellipse", function()
    local ir = Compiler.motion.ellipse(200, 50, 1)
    local f = Compiler.compile(ir)
    
    local x0, y0 = f(0, {})
    assert(approxEq(x0, 200))
    assert(approxEq(y0, 0))
    
    local x25, y25 = f(0.25, {})
    assert(approxEq(x25, 0))
    assert(approxEq(y25, 50))
end)

test("motion.drift", function()
    local ir = Compiler.motion.drift(10, 5)
    local f = Compiler.compile(ir)
    
    local x0, y0 = f(0, {})
    assert(approxEq(x0, 0))
    assert(approxEq(y0, 0))
    
    local x1, y1 = f(1, {})
    assert(approxEq(x1, 10))
    assert(approxEq(y1, 5))
end)

test("motion.hover", function()
    local ir = Compiler.motion.hover(10, 1)
    local f = Compiler.compile(ir)
    local x, y = f(0, {})
    -- Just check it doesn't error
    assert(type(x) == "number" and type(y) == "number")
end)

print("\n=== Motion Combinators ===\n")

test("motion.add", function()
    local ir = Compiler.motion.add(
        Compiler.motion.drift(10, 0),
        Compiler.motion.drift(0, 5)
    )
    local f = Compiler.compile(ir)
    
    local x, y = f(1, {})
    assert(approxEq(x, 10))
    assert(approxEq(y, 5))
end)

test("motion.scale const", function()
    local ir = Compiler.motion.scale(Compiler.motion.drift(10, 5), 2)
    local f = Compiler.compile(ir)
    
    local x, y = f(1, {})
    assert(approxEq(x, 20))
    assert(approxEq(y, 10))
end)

test("motion.scale curve", function()
    -- Scale by t (grows linearly)
    local ir = Compiler.motion.scale(
        Compiler.motion.circle(1, 1),
        Compiler.curve.linear(1)
    )
    local f = Compiler.compile(ir)
    
    -- At t=0, scale=0, so x,y should be 0
    local x0, y0 = f(0, {})
    assert(approxEq(x0, 0))
    assert(approxEq(y0, 0))
    
    -- At t=1 full revolution, scale=1
    local x1, y1 = f(1, {})
    assert(approxEq(x1, 1))  -- cos(2π) * 1 = 1
    assert(approxEq(y1, 0))
end)

test("motion.rotate const", function()
    local ir = Compiler.motion.rotate(
        Compiler.motion.drift(1, 0),
        math.pi / 2  -- 90 degrees
    )
    local f = Compiler.compile(ir)
    
    local x, y = f(1, {})
    assert(approxEq(x, 0))
    assert(approxEq(y, 1))
end)

test("motion.mix const", function()
    local ir = Compiler.motion.mix(
        Compiler.motion.drift(10, 0),
        Compiler.motion.drift(0, 10),
        0.5
    )
    local f = Compiler.compile(ir)
    
    local x, y = f(1, {})
    assert(approxEq(x, 5))
    assert(approxEq(y, 5))
end)

print("\n=== Complex Compositions ===\n")

test("spiral", function()
    local ir = Compiler.motion.spiral(100, 1, 1)
    local f = Compiler.compile(ir)
    
    -- At t=0, scale factor = 1, position = (100, 0)
    local x0, y0 = f(0, {})
    assert(approxEq(x0, 100))
    assert(approxEq(y0, 0))
    
    -- At t=1, scale factor = 2, full revolution, position = (200, 0)
    local x1, y1 = f(1, {})
    assert(approxEq(x1, 200))
    assert(approxEq(y1, 0))
end)

test("figure8", function()
    local ir = Compiler.motion.figure8(100, 1)
    local f = Compiler.compile(ir)
    
    -- Just verify it doesn't error
    local x, y = f(0.5, {})
    assert(type(x) == "number" and type(y) == "number")
end)

test("outward (unit spiral)", function()
    local ir = Compiler.motion.outward(1)
    local f = Compiler.compile(ir)
    
    -- At t=0: (0, 0)
    local x0, y0 = f(0, {})
    assert(approxEq(x0, 0))
    assert(approxEq(y0, 0))
    
    -- At t=1: (1, 0) after full revolution
    local x1, y1 = f(1, {})
    assert(approxEq(x1, 1))
    assert(approxEq(y1, 0))
end)

test("bounce", function()
    local ir = Compiler.motion.bounce(100, 1)
    local f = Compiler.compile(ir)
    
    -- y should always be positive (absolute sin)
    local _, y25 = f(0.25, {})
    local _, y75 = f(0.75, {})
    assert(y25 >= 0)
    assert(y75 >= 0)
end)

print("\n=== Source Code Generation ===\n")

test("toSource generates valid code", function()
    local ir = Compiler.motion.circle(100, 2)
    local source = Compiler.toSource(ir)
    assert(type(source) == "string")
    assert(#source > 50)
    assert(source:find("return function"))
    assert(source:find("sin"))
    assert(source:find("cos"))
end)

print("\n=== Debug Output ===\n")

print("Generated code for Motion.circle(100, 2):")
print("-----------------------------------------")
local ir = Compiler.motion.circle(100, 2)
local source = Compiler.toSource(ir)
print(source)
print("-----------------------------------------\n")

print("Generated code for Motion.spiral(100, 1, 0.5):")
print("-----------------------------------------")
ir = Compiler.motion.spiral(100, 1, 0.5)
source = Compiler.toSource(ir)
print(source)
print("-----------------------------------------\n")

print("\n=== Performance Comparison (if LÖVE available) ===\n")

-- Simulate the composed version
local function composedCircle(radius, speed)
    local function curvecos(freq, amp)
        return function(t, ctx)
            return math.cos(t * freq * 6.283185307179586) * amp
        end
    end
    local function curvesin(freq, amp)
        return function(t, ctx)
            return math.sin(t * freq * 6.283185307179586) * amp
        end
    end
    local cx = curvecos(speed, radius)
    local cy = curvesin(speed, radius)
    return function(t, ctx)
        return cx(t, ctx), cy(t, ctx)
    end
end

local composed = composedCircle(100, 2)
local compiled = Compiler.compile(Compiler.motion.circle(100, 2))

-- Quick perf test
local iterations = 100000
local ctx = {}

local startComposed = os.clock()
for i = 1, iterations do
    composed(i * 0.001, ctx)
end
local endComposed = os.clock()

local startCompiled = os.clock()
for i = 1, iterations do
    compiled(i * 0.001, ctx)
end
local endCompiled = os.clock()

print(string.format("Composed: %.4fs for %d iterations", endComposed - startComposed, iterations))
print(string.format("Compiled: %.4fs for %d iterations", endCompiled - startCompiled, iterations))
print(string.format("Speedup:  %.2fx", (endComposed - startComposed) / (endCompiled - startCompiled)))

print("\n=== All tests complete ===\n")

Support.finish()
