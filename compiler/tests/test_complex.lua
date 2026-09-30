local unpack = table.unpack or unpack
-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for Complex Compositions
-- Path adjustment for tests subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Ensures compiler handles deeply nested and intricate IR trees
--- Run with: lua test_complex.lua

local Compiler = require("spatula.compiler.compiler")

local function approxEq(a, b, eps)
    eps = eps or 0.0001
    return math.abs(a - b) < eps
end

local Support = require("tests.support")
local test = Support.test
local benchmark = Support.benchmark

local PI = math.pi
local PI2 = PI * 2

print("\n=== Complex: Deep Nesting ===\n")

test("10-level nested scale", function()
    -- scale(scale(scale(...scale(sin)...)))
    local ir = Compiler.curve.sin(1, 1)
    for i = 1, 10 do
        ir = Compiler.curve.scale(ir, 1.1)
    end
    
    local compiled = Compiler.compile(ir)
    local expected = math.sin(0.5 * PI2) * (1.1 ^ 10)
    local got = compiled(0.5, {})
    
    assert(approxEq(got, expected, 0.001),
        string.format("Expected %s, got %s", expected, got))
end)

test("10-level nested offset", function()
    local ir = Compiler.curve.const(0)
    for i = 1, 10 do
        ir = Compiler.curve.offset(ir, 1)
    end
    
    local compiled = Compiler.compile(ir)
    local got = compiled(0, {})
    
    assert(got == 10, "Expected 10, got " .. got)
end)

test("alternating scale/offset nesting", function()
    -- offset(scale(offset(scale(sin, 2), 5), 3), 10)
    local ir = Compiler.curve.sin(1, 1)
    ir = Compiler.curve.scale(ir, 2)
    ir = Compiler.curve.offset(ir, 5)
    ir = Compiler.curve.scale(ir, 3)
    ir = Compiler.curve.offset(ir, 10)
    
    local compiled = Compiler.compile(ir)
    
    for i = 0, 10 do
        local t = i * 0.1
        local base = math.sin(t * PI2)
        local expected = ((base * 2 + 5) * 3) + 10
        local got = compiled(t, {})
        assert(approxEq(got, expected),
            string.format("Mismatch at t=%s: expected=%s got=%s", t, expected, got))
    end
end)

test("deeply nested timeScale", function()
    -- timeScale(timeScale(timeScale(sin, 2), 3), 4) = sin at 24x speed
    local ir = Compiler.curve.sin(1, 1)
    ir = Compiler.curve.timeScale(ir, 2)
    ir = Compiler.curve.timeScale(ir, 3)
    ir = Compiler.curve.timeScale(ir, 4)
    
    local compiled = Compiler.compile(ir)
    
    for i = 0, 10 do
        local t = i * 0.01
        local expected = math.sin(t * 24 * PI2)
        local got = compiled(t, {})
        assert(approxEq(got, expected),
            string.format("Mismatch at t=%s", t))
    end
end)

print("\n=== Complex: Wide Trees (Many Children) ===\n")

test("add with 20 children", function()
    local children = {}
    for i = 1, 20 do
        children[i] = Compiler.curve.const(i)
    end
    local ir = Compiler.curve.add(unpack(children))
    
    local compiled = Compiler.compile(ir)
    local expected = (20 * 21) / 2  -- sum 1..20 = 210
    local got = compiled(0, {})
    
    assert(got == expected, "Expected " .. expected .. ", got " .. got)
end)

test("mul with 10 children", function()
    local children = {}
    for i = 1, 10 do
        children[i] = Compiler.curve.const(1.1)
    end
    local ir = Compiler.curve.mul(unpack(children))
    
    local compiled = Compiler.compile(ir)
    local expected = 1.1 ^ 10
    local got = compiled(0, {})
    
    assert(approxEq(got, expected, 0.0001),
        string.format("Expected %s, got %s", expected, got))
end)

test("add of 10 different wave types", function()
    local ir = Compiler.curve.add(
        Compiler.curve.sin(1, 0.1),
        Compiler.curve.cos(1.5, 0.1),
        Compiler.curve.sin(2, 0.1),
        Compiler.curve.cos(2.5, 0.1),
        Compiler.curve.sin(3, 0.1),
        Compiler.curve.cos(3.5, 0.1),
        Compiler.curve.sin(4, 0.1),
        Compiler.curve.cos(4.5, 0.1),
        Compiler.curve.sin(5, 0.1),
        Compiler.curve.cos(5.5, 0.1)
    )
    
    local compiled = Compiler.compile(ir)
    
    -- Verify it produces reasonable values
    for i = 0, 20 do
        local t = i * 0.05
        local v = compiled(t, {})
        assert(v >= -1 and v <= 1, 
            string.format("Value out of range at t=%s: %s", t, v))
    end
end)

test("motionAdd with 5 motions", function()
    local ir = Compiler.motion.add(
        Compiler.motion.circle(20, 1),
        Compiler.motion.circle(15, 2),
        Compiler.motion.circle(10, 3),
        Compiler.motion.circle(5, 5),
        Compiler.motion.drift(10, 5)
    )
    
    local compiled = Compiler.compile(ir)
    
    -- Should compile and run
    for i = 0, 10 do
        local t = i * 0.1
        local x, y = compiled(t, {})
        assert(type(x) == "number" and type(y) == "number",
            string.format("Invalid output at t=%s", t))
    end
end)

print("\n=== Complex: Mixed Operations ===\n")

test("complex curve: mul(add(sin, cos), scale(triangle, noise))", function()
    local ir = Compiler.curve.mul(
        Compiler.curve.add(
            Compiler.curve.sin(1, 1),
            Compiler.curve.cos(2, 0.5)
        ),
        Compiler.curve.scale(
            Compiler.curve.triangle(3, 1),
            Compiler.curve.noise(0.5, 42)
        )
    )
    
    local compiled = Compiler.compile(ir)
    
    -- Should compile and produce consistent results
    local v1 = compiled(0.5, {})
    local v2 = compiled(0.5, {})
    assert(v1 == v2, "Should be deterministic")
end)

test("motion with curve-based scaling and rotation", function()
    local ir = Compiler.motion.rotate(
        Compiler.motion.scale(
            Compiler.motion.circle(100, 1),
            Compiler.curve.add(
                Compiler.curve.const(1),
                Compiler.curve.sin(0.5, 0.3)
            )
        ),
        Compiler.curve.linear(0.5)  -- Slowly rotating
    )
    
    local compiled = Compiler.compile(ir)
    
    for i = 0, 10 do
        local t = i * 0.1
        local x, y = compiled(t, {})
        -- Should stay roughly within bounds
        local dist = math.sqrt(x*x + y*y)
        assert(dist < 200, string.format("Distance too large at t=%s: %s", t, dist))
    end
end)

test("layered motion composition", function()
    -- Base orbit + wobble + shake + drift
    local ir = Compiler.motion.add(
        Compiler.motion.circle(100, 0.5),           -- slow orbit
        Compiler.motion.scale(
            Compiler.motion.hover(20, 2),            -- wobble
            Compiler.curve.sin(0.25, 0.5, 0)         -- pulsing intensity
        ),
        Compiler.motion.shake(3, 15),               -- high-freq shake
        Compiler.motion.drift(5, 2)                 -- slow drift
    )
    
    local compiled = Compiler.compile(ir)
    local nodeCount = Compiler.countNodes(ir)
    
    print(string.format("  Layered motion: %d nodes", nodeCount))
    
    for i = 0, 20 do
        local t = i * 0.1
        local x, y = compiled(t, {})
        assert(type(x) == "number" and type(y) == "number")
    end
end)

print("\n=== Complex: Time Manipulation ===\n")

test("nested time operations", function()
    -- loop(timeScale(timeOffset(sin, 1), 2), 3)
    local ir = Compiler.curve.loop(
        Compiler.curve.timeScale(
            Compiler.curve.timeOffset(
                Compiler.curve.sin(1, 1),
                1
            ),
            2
        ),
        3
    )
    
    local compiled = Compiler.compile(ir)
    
    -- Verify looping behavior
    local v0 = compiled(0, {})
    local v3 = compiled(3, {})
    local v6 = compiled(6, {})
    
    assert(approxEq(v0, v3) and approxEq(v3, v6),
        "Loop should repeat every 3 seconds")
end)

test("delayed composition", function()
    local ir = Compiler.curve.add(
        Compiler.curve.delay(Compiler.curve.sin(1, 1), 1),
        Compiler.curve.delay(Compiler.curve.sin(1, 1), 2),
        Compiler.curve.delay(Compiler.curve.sin(1, 1), 3)
    )
    
    local compiled = Compiler.compile(ir)
    
    -- Before any delay, all should be 0
    assert(compiled(0.5, {}) == 0, "All delayed at t=0.5")
    
    -- After first delay kicks in
    local v1_5 = compiled(1.5, {})
    assert(v1_5 ~= 0, "First delay should be active at t=1.5")
end)

print("\n=== Complex: Stateful + Stateless Mix ===\n")

test("follow chasing a circle", function()
    -- Follow the X component of a circle
    local ir = Compiler.curve.follow(
        Compiler.curve.scale(
            Compiler.curve.cos(1, 1),
            100
        ),
        5
    )
    
    local compiled = Compiler.compile(ir)
    local ctx = {}
    
    local values = {}
    for i = 0, 50 do
        local t = i * 0.05
        values[#values + 1] = compiled(t, ctx)
    end
    
    -- Should be smoothly following the cosine
    -- Check it's not just static
    local hasVariation = false
    for i = 2, #values do
        if math.abs(values[i] - values[i-1]) > 0.1 then
            hasVariation = true
            break
        end
    end
    assert(hasVariation, "Follow should be tracking the moving target")
end)

test("spring with oscillating target", function()
    local ir = Compiler.curve.spring(
        Compiler.curve.sin(0.5, 100),  -- Target oscillates
        200,  -- High stiffness
        10    -- Moderate damping
    )
    
    local compiled = Compiler.compile(ir)
    local ctx = {}
    
    -- Should track with some lag
    for i = 0, 30 do
        local t = i * 0.1
        local v = compiled(t, ctx)
        assert(type(v) == "number" and v == v,  -- not NaN
            string.format("Invalid value at t=%s: %s", t, v))
    end
end)

test("motion with mixed stateful and stateless curves", function()
    local ir = Compiler.motion.xy(
        Compiler.curve.follow(
            Compiler.curve.cos(0.5, 100),
            10
        ),
        Compiler.curve.add(
            Compiler.curve.sin(1, 50),
            Compiler.curve.spring(
                Compiler.curve.const(0),
                100, 5
            )
        )
    )
    
    local compiled = Compiler.compile(ir)
    local ctx = {}
    
    assert(Compiler.hasStatefulNodes(ir), "Should detect stateful nodes")
    
    for i = 0, 20 do
        local t = i * 0.1
        local x, y = compiled(t, ctx)
        assert(type(x) == "number" and type(y) == "number")
    end
end)

print("\n=== Complex: Optimization Stress Test ===\n")

test("highly optimizable expression", function()
    -- This should collapse to almost nothing
    local ir = Compiler.curve.add(
        Compiler.curve.scale(Compiler.curve.const(10), 0),  -- -> 0
        Compiler.curve.mul(
            Compiler.curve.const(5),
            Compiler.curve.const(1)  -- mul identity
        ),
        Compiler.curve.offset(
            Compiler.curve.scale(Compiler.curve.const(3), 2),  -- -> 6
            0  -- offset identity
        ),
        Compiler.curve.neg(Compiler.curve.neg(Compiler.curve.const(1)))  -- -> 1
    )
    -- Expected: 0 + 5 + 6 + 1 = 12
    
    local optimized = Compiler.optimize(ir)
    local compiled = Compiler.compileOptimized(ir)
    
    local got = compiled(0, {})
    assert(got == 12, "Expected 12, got " .. got)
    
    -- After optimization, should be a single const node
    assert(optimized.op == "const" and optimized.value == 12,
        "Should optimize to const(12), got op=" .. optimized.op)
end)

test("partial optimization with runtime components", function()
    -- Mix of compile-time and runtime
    local ir = Compiler.curve.add(
        Compiler.curve.scale(Compiler.curve.const(5), 2),  -- -> const(10)
        Compiler.curve.mul(Compiler.curve.sin(1, 1), Compiler.curve.const(1)),  -- -> sin
        Compiler.curve.offset(Compiler.curve.const(0), 0)  -- -> const(0)
    )
    -- Expected: 10 + sin(t) + 0 = 10 + sin(t)
    
    local compiled = Compiler.compileOptimized(ir)
    
    for i = 0, 10 do
        local t = i * 0.1
        local expected = 10 + math.sin(t * PI2)
        local got = compiled(t, {})
        assert(approxEq(got, expected),
            string.format("Mismatch at t=%s", t))
    end
end)

print("\n=== Complex: CSE Stress Test ===\n")

test("many shared subexpressions", function()
    -- Create 10 curves all using the same timeScale
    local scaled = Compiler.curve.timeScale(Compiler.curve.sin(1, 1), 10)
    local children = {}
    for i = 1, 10 do
        children[i] = Compiler.curve.offset(scaled, i)
    end
    local ir = Compiler.curve.add(unpack(children))
    
    local source = Compiler.toSource(ir)
    
    -- Count how many times "t * 10" appears as an assignment
    local count = 0
    for _ in source:gmatch("local _v%d+ = t %* 10") do
        count = count + 1
    end
    
    -- Should only compute t * 10 once!
    assert(count == 1, 
        "CSE should share t*10, found " .. count .. " assignments")
    
    local compiled = Compiler.compile(ir)
    local got = compiled(0.25, {})
    
    -- Verify correctness: 10 * sin(0.25 * 10 * 2π) + (1+2+...+10)
    local base = math.sin(0.25 * 10 * PI2)
    local expected = base * 10 + 55  -- 55 = sum of offsets
    assert(approxEq(got, expected),
        string.format("Expected %s, got %s", expected, got))
end)

test("shared angle in complex motion", function()
    -- Multiple motions with same frequency should share angle
    local ir = Compiler.motion.add(
        Compiler.motion.circle(100, 2),
        Compiler.motion.scale(Compiler.motion.circle(50, 2), 0.5),
        Compiler.motion.rotate(Compiler.motion.circle(25, 2), PI/4)
    )
    
    local source = Compiler.toSource(ir)
    
    -- Count angle assignments for freq=2 (= 12.566...)
    local count = 0
    for _ in source:gmatch("local _v%d+ = t %* 12%.566") do
        count = count + 1
    end
    
    assert(count == 1,
        "CSE should share angle for freq=2, found " .. count .. " assignments")
end)

print("\n=== Complex: Ctx Integration ===\n")

test("complex ctx-based reactive motion", function()
    local ir = Compiler.motion.xy(
        Compiler.curve.add(
            Compiler.curve.fromCtx("player.x", 0),
            Compiler.curve.mul(
                Compiler.curve.sin(2, 20),
                Compiler.curve.fromCtx("intensity", 1)
            )
        ),
        Compiler.curve.add(
            Compiler.curve.fromCtx("player.y", 0),
            Compiler.curve.mul(
                Compiler.curve.cos(2, 20),
                Compiler.curve.fromCtx("intensity", 1)
            )
        )
    )
    
    local compiled = Compiler.compile(ir)
    
    -- Test with varying ctx
    local ctx1 = { player = { x = 100, y = 200 }, intensity = 0.5 }
    local x1, y1 = compiled(0.25, ctx1)
    
    local ctx2 = { player = { x = 300, y = 400 }, intensity = 2 }
    local x2, y2 = compiled(0.25, ctx2)
    
    -- Positions should be different
    assert(x1 ~= x2 and y1 ~= y2, "Different ctx should give different results")
    
    -- Check approximate values
    assert(approxEq(x1, 100 + math.sin(0.25 * 2 * PI2) * 20 * 0.5, 0.01))
end)

print("\n=== Complex: Edge Cases ===\n")

test("empty add/mul", function()
    -- These shouldn't crash
    local ir1 = { op = "add", children = {} }
    local ir2 = { op = "mul", children = {} }
    
    -- After optimization
    local opt1 = Compiler.optimize(ir1)
    local opt2 = Compiler.optimize(ir2)
    
    -- add() should become 0, mul() should become 1
    assert(opt1.op == "const" and opt1.value == 0, "Empty add should be 0")
    assert(opt2.op == "const" and opt2.value == 1, "Empty mul should be 1")
end)

test("single-child add/mul", function()
    local ir1 = Compiler.curve.add(Compiler.curve.sin(1, 1))
    local ir2 = Compiler.curve.mul(Compiler.curve.cos(1, 1))
    
    local opt1 = Compiler.optimize(ir1)
    local opt2 = Compiler.optimize(ir2)
    
    -- Should unwrap to just the child
    assert(opt1.op == "sin", "Single-child add should unwrap")
    assert(opt2.op == "cos", "Single-child mul should unwrap")
end)

test("very small and very large values", function()
    local ir = Compiler.curve.add(
        Compiler.curve.const(1e-10),
        Compiler.curve.const(1e10)
    )
    
    local compiled = Compiler.compileOptimized(ir)
    local got = compiled(0, {})
    
    assert(approxEq(got, 1e10, 1), "Should handle extreme values")
end)

test("negative frequencies and amplitudes", function()
    local ir = Compiler.motion.xy(
        Compiler.curve.sin(-2, -50),
        Compiler.curve.cos(-3, -100)
    )
    
    local compiled = Compiler.compile(ir)
    
    for i = 0, 10 do
        local t = i * 0.1
        local x, y = compiled(t, {})
        local ex = math.sin(t * -2 * PI2) * -50
        local ey = math.cos(t * -3 * PI2) * -100
        assert(approxEq(x, ex) and approxEq(y, ey))
    end
end)

print("\n=== Complex: Generated Code Samples ===\n")

print("--- Layered motion (orbit + wobble + shake + drift) ---")
local layeredIR = Compiler.motion.add(
    Compiler.motion.circle(100, 0.5),
    Compiler.motion.scale(Compiler.motion.hover(20, 2), Compiler.curve.sin(0.25, 0.5, 0)),
    Compiler.motion.shake(3, 15),
    Compiler.motion.drift(5, 2)
)
print("Node count: " .. Compiler.countNodes(layeredIR))
print(Compiler.toSource(layeredIR))
print("")

print("--- Follow chasing circle X ---")
local followIR = Compiler.curve.follow(
    Compiler.curve.scale(Compiler.curve.cos(1, 1), 100),
    5
)
print("Stateful: " .. tostring(Compiler.hasStatefulNodes(followIR)))
print(Compiler.toSource(followIR))

print("\n=== All Complex tests complete ===\n")

Support.finish()
