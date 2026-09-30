-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for Annotated Closures and Introspection
-- Path adjustment for tests subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Run with: lua test_annotated.lua

local Compiler = require("spatula.compiler.compiler")

local function approxEq(a, b, eps)
    eps = eps or 0.0001
    return math.abs(a - b) < eps
end

local Support = require("tests.support")
local test = Support.test
local benchmark = Support.benchmark

print("\n=== Annotated Closures: Basic Annotation ===\n")

test("annotate attaches IR to function", function()
    local fn = function(t, ctx) return t * 100 end
    local ir = Compiler.curve.linear(100)
    
    local wrapped = Compiler.annotate(fn, ir)
    
    assert(wrapped._ir ~= nil, "IR should be attached")
    assert(wrapped._ir.op == "linear", "IR should be linear")
    
    -- Should still be callable
    local result = wrapped(1, {})
    assert(result == 100, "Wrapper should call original function")
end)

test("hasIR detects annotated functions", function()
    local fn = function() return 1 end
    local annotated = Compiler.annotate(fn, Compiler.curve.const(1))
    
    local plain = function() end
    
    assert(Compiler.hasIR(annotated) == true, "Should detect annotated function")
    assert(Compiler.hasIR(plain) == false, "Should not detect plain function")
end)

test("getIR retrieves attached IR", function()
    local fn = function() end
    local wrapped = Compiler.annotate(fn, Compiler.curve.sin(2, 50))
    
    local ir = Compiler.getIR(wrapped)
    assert(ir ~= nil, "Should retrieve IR")
    assert(ir.op == "sin", "Should be sin")
    assert(ir.freq == 2, "Should have freq 2")
    assert(ir.amp == 50, "Should have amp 50")
end)

print("\n=== Annotated Closures: Compilation ===\n")

test("fromClosure compiles annotated function", function()
    -- Simulate what Spatula would do
    local originalFn = function(t, ctx)
        return math.cos(t * 2 * math.pi * 2) * 100, math.sin(t * 2 * math.pi * 2) * 100
    end
    local original = Compiler.annotate(originalFn, Compiler.motion.circle(100, 2))
    
    local compiled = Compiler.fromClosure(original)
    
    -- Should produce same results
    for i = 0, 10 do
        local t = i * 0.1
        local ox, oy = original(t, {})
        local cx, cy = compiled(t, {})
        assert(approxEq(ox, cx) and approxEq(oy, cy),
            string.format("Mismatch at t=%s", t))
    end
end)

test("fromClosure errors on non-annotated function", function()
    local plain = function() end
    
    local ok, err = pcall(function()
        Compiler.fromClosure(plain)
    end)
    
    assert(not ok, "Should error on non-annotated function")
    assert(err:find("no embedded IR") or err:find("IR"), "Error should mention missing IR")
end)

test("fromClosureOptimized applies optimizations", function()
    -- Create a function with an IR that has optimization opportunities
    local fn = function(t, ctx)
        return (math.sin(t * math.pi * 2) * 1 + 0)
    end
    local wrapped = Compiler.annotate(fn, Compiler.curve.add(
        Compiler.curve.mul(Compiler.curve.sin(1, 1), Compiler.curve.const(1)),
        Compiler.curve.const(0)
    ))
    
    local compiled = Compiler.fromClosureOptimized(wrapped)
    
    -- Should work correctly
    for i = 0, 10 do
        local t = i * 0.1
        local expected = math.sin(t * 2 * math.pi)
        local got = compiled(t, {})
        assert(approxEq(expected, got),
            string.format("Mismatch at t=%s: expected=%s got=%s", t, expected, got))
    end
end)

print("\n=== Annotated Factory ===\n")

test("createAnnotatedFactory creates working factory", function()
    -- Simulate creating an annotated Spatula function
    local circleFactory = Compiler.createAnnotatedFactory(
        "circle",
        -- Original closure factory
        function(radius, speed)
            return function(t, ctx)
                local angle = t * speed * math.pi * 2
                return math.cos(angle) * radius, math.sin(angle) * radius
            end
        end,
        -- IR factory
        function(radius, speed)
            return Compiler.motion.circle(radius, speed)
        end
    )
    
    local circle = circleFactory(100, 2)
    
    -- Should be callable
    local x, y = circle(0, {})
    assert(approxEq(x, 100) and approxEq(y, 0), "Circle should work at t=0")
    
    -- Should have IR
    assert(Compiler.hasIR(circle), "Should have IR attached")
    
    -- Should compile
    local compiled = Compiler.fromClosure(circle)
    local cx, cy = compiled(0, {})
    assert(approxEq(cx, 100) and approxEq(cy, 0), "Compiled should work")
end)

print("\n=== Introspection: Node Counting ===\n")

test("countNodes counts simple IR", function()
    local ir = Compiler.curve.sin(1, 1)
    assert(Compiler.countNodes(ir) == 1, "Single node should count as 1")
end)

test("countNodes counts nested IR", function()
    local ir = Compiler.curve.add(
        Compiler.curve.sin(1, 1),
        Compiler.curve.cos(1, 1)
    )
    assert(Compiler.countNodes(ir) == 3, "add(sin, cos) should be 3 nodes")
end)

test("countNodes counts motion IR", function()
    local ir = Compiler.motion.circle(100, 2)
    -- circle = xy(cos, sin) = 3 nodes
    assert(Compiler.countNodes(ir) == 3, "circle should be 3 nodes")
end)

test("countNodes counts complex IR", function()
    local ir = Compiler.motion.spiral(100, 1, 0.5)
    -- spiral = scale(xy(cos, sin), offset(linear, 1))
    -- = scale(3, offset(linear, 1))
    -- = scale(3, 2) = 6 nodes total
    local count = Compiler.countNodes(ir)
    assert(count >= 5, "spiral should have at least 5 nodes, got " .. count)
end)

print("\n=== Introspection: Stateful Detection ===\n")

test("hasStatefulNodes detects follow", function()
    local ir = Compiler.curve.follow(Compiler.curve.const(100), 5)
    assert(Compiler.hasStatefulNodes(ir) == true, "Should detect follow")
end)

test("hasStatefulNodes detects spring", function()
    local ir = Compiler.curve.spring(Compiler.curve.const(100), 100, 10)
    assert(Compiler.hasStatefulNodes(ir) == true, "Should detect spring")
end)

test("hasStatefulNodes returns false for stateless", function()
    local ir = Compiler.motion.circle(100, 2)
    assert(Compiler.hasStatefulNodes(ir) == false, "circle should not be stateful")
end)

test("hasStatefulNodes detects nested stateful", function()
    local ir = Compiler.motion.xy(
        Compiler.curve.sin(1, 1),
        Compiler.curve.follow(Compiler.curve.const(100), 5)
    )
    assert(Compiler.hasStatefulNodes(ir) == true, "Should detect nested follow")
end)

print("\n=== Introspection: Summary ===\n")

test("summarize returns correct info", function()
    local ir = Compiler.motion.circle(100, 2)
    local summary = Compiler.summarize(ir)
    
    assert(summary.nodeCount == 3, "Should have 3 nodes")
    assert(summary.hasState == false, "Should not be stateful")
    assert(summary.ops["xy"] == 1, "Should have 1 xy op")
    assert(summary.ops["cos"] == 1, "Should have 1 cos op")
    assert(summary.ops["sin"] == 1, "Should have 1 sin op")
end)

test("summarize detects stateful in summary", function()
    local ir = Compiler.curve.follow(Compiler.curve.linear(100), 5)
    local summary = Compiler.summarize(ir)
    
    assert(summary.hasState == true, "Should detect stateful")
    assert(summary.ops["follow"] == 1, "Should have 1 follow op")
end)

print("\n=== Practical Usage Example ===\n")

test("complete workflow: annotate -> compile -> use", function()
    -- Step 1: Create annotated Spatula-style functions
    local function createCircle(radius, speed)
        local fn = function(t, ctx)
            local angle = t * speed * math.pi * 2
            return math.cos(angle) * radius, math.sin(angle) * radius
        end
        return Compiler.annotate(fn, Compiler.motion.circle(radius, speed))
    end
    
    local function createSpiral(radius, speed, growth)
        local fn = function(t, ctx)
            local angle = t * speed * math.pi * 2
            local scale = 1 + t * growth
            return math.cos(angle) * radius * scale, math.sin(angle) * radius * scale
        end
        return Compiler.annotate(fn, Compiler.motion.spiral(radius, speed, growth))
    end
    
    -- Step 2: Use normally
    local circle = createCircle(100, 2)
    local x1, y1 = circle(0.25, {})
    
    -- Step 3: Check if it can be optimized
    assert(Compiler.hasIR(circle), "Should have IR")
    local summary = Compiler.summarize(Compiler.getIR(circle))
    assert(not summary.hasState, "Circle should not be stateful")
    
    -- Step 4: Compile for hot path
    local compiledCircle = Compiler.fromClosure(circle)
    local x2, y2 = compiledCircle(0.25, {})
    
    -- Step 5: Verify results match
    assert(approxEq(x1, x2) and approxEq(y1, y2), "Results should match")
    
    print("  Original circle(0.25): (" .. x1 .. ", " .. y1 .. ")")
    print("  Compiled circle(0.25): (" .. x2 .. ", " .. y2 .. ")")
end)

print("\n=== Generated Code Sample ===\n")

print("-- If Spatula annotated Motion.spiral(100, 1, 0.5):")
local spiralIR = Compiler.motion.spiral(100, 1, 0.5)
print("-- Node count: " .. Compiler.countNodes(spiralIR))
print("-- Stateful: " .. tostring(Compiler.hasStatefulNodes(spiralIR)))
print("")
print(Compiler.toSource(spiralIR))

print("\n=== All Annotated tests complete ===\n")

Support.finish()
