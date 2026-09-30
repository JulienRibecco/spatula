-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for Segment and Sequence
-- Path adjustment for tests subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Run with: lua test_segment.lua

local Compiler = require("spatula.compiler.compiler")

local function approxEq(a, b, eps)
    eps = eps or 0.01
    return math.abs(a - b) < eps
end

local Support = require("tests.support")
local test = Support.test
local benchmark = Support.benchmark

print("\n=== Segment: Curve ===\n")

test("segment creates valid IR", function()
    local ir = Compiler.curve.segment(Compiler.curve.sin(1, 1), 0, 1)
    assert(ir.op == "segment", "Should be segment op")
    assert(ir.start == 0, "Start should be 0")
    assert(ir.duration == 1, "Duration should be 1")
end)

test("segment compiles", function()
    local ir = Compiler.curve.segment(Compiler.curve.sin(1, 1), 0, 1)
    local fn = Compiler.compile(ir)
    assert(type(fn) == "function", "Should compile to function")
end)

test("segment returns 0 before start", function()
    local ir = Compiler.curve.segment(Compiler.curve.const(5), 1, 1)  -- active [1, 2)
    local fn = Compiler.compile(ir)
    
    assert(fn(0, {}) == 0, "Should be 0 at t=0")
    assert(fn(0.5, {}) == 0, "Should be 0 at t=0.5")
    assert(fn(0.99, {}) == 0, "Should be 0 at t=0.99")
end)

test("segment returns curve value during window", function()
    local ir = Compiler.curve.segment(Compiler.curve.const(5), 1, 1)  -- active [1, 2)
    local fn = Compiler.compile(ir)
    
    assert(fn(1, {}) == 5, "Should be 5 at t=1")
    assert(fn(1.5, {}) == 5, "Should be 5 at t=1.5")
    assert(fn(1.99, {}) == 5, "Should be 5 at t=1.99")
end)

test("segment returns 0 after window", function()
    local ir = Compiler.curve.segment(Compiler.curve.const(5), 1, 1)  -- active [1, 2)
    local fn = Compiler.compile(ir)
    
    assert(fn(2, {}) == 0, "Should be 0 at t=2")
    assert(fn(3, {}) == 0, "Should be 0 at t=3")
end)

test("segment time is local to window", function()
    -- sin starts at 0 in segment, so sin(0) = 0
    local ir = Compiler.curve.segment(Compiler.curve.sin(1, 1), 1, 1)
    local fn = Compiler.compile(ir)
    
    -- At t=1, local time is 0, sin(0) = 0
    assert(approxEq(fn(1, {}), 0), "Should be ~0 at window start")
    
    -- At t=1.25, local time is 0.25
    local expected = math.sin(0.25 * 2 * math.pi)
    assert(approxEq(fn(1.25, {}), expected), "Should follow sin curve")
end)

print("\n=== Segment: Motion ===\n")

test("motion segment creates valid IR", function()
    local ir = Compiler.motion.segment(Compiler.motion.circle(100, 1), 0, 1)
    assert(ir.op == "motionSegment", "Should be motionSegment op")
    assert(ir.type == "motion", "Should be motion type")
end)

test("motion segment compiles", function()
    local ir = Compiler.motion.segment(Compiler.motion.circle(100, 1), 0, 1)
    local fn = Compiler.compile(ir)
    assert(type(fn) == "function", "Should compile to function")
end)

test("motion segment returns (0,0) outside window", function()
    local ir = Compiler.motion.segment(Compiler.motion.circle(100, 1), 1, 1)
    local fn = Compiler.compile(ir)
    
    local x, y = fn(0, {})
    assert(x == 0 and y == 0, "Should be (0,0) before window")
    
    x, y = fn(2, {})
    assert(x == 0 and y == 0, "Should be (0,0) after window")
end)

test("motion segment returns motion value in window", function()
    local ir = Compiler.motion.segment(Compiler.motion.circle(100, 1), 1, 1)
    local fn = Compiler.compile(ir)
    
    -- At t=1, local time is 0, circle at t=0 is (100, 0)
    local x, y = fn(1, {})
    assert(approxEq(x, 100) and approxEq(y, 0), 
        string.format("Should be ~(100,0) at window start, got (%.2f, %.2f)", x, y))
end)

print("\n=== Sequence: Curve ===\n")

test("sequence creates add of segments", function()
    local ir = Compiler.curve.sequence(
        { Compiler.curve.const(1), 1 },
        { Compiler.curve.const(2), 1 }
    )
    assert(ir.op == "add", "Should be add op")
    assert(#ir.children == 2, "Should have 2 children")
    assert(ir.children[1].op == "segment", "Children should be segments")
end)

test("sequence compiles", function()
    local ir = Compiler.curve.sequence(
        { Compiler.curve.const(1), 1 },
        { Compiler.curve.const(2), 1 }
    )
    local fn = Compiler.compile(ir)
    assert(type(fn) == "function", "Should compile")
end)

test("sequence plays curves in order", function()
    local ir = Compiler.curve.sequence(
        { Compiler.curve.const(1), 1 },  -- t=0-1: value 1
        { Compiler.curve.const(2), 1 },  -- t=1-2: value 2
        { Compiler.curve.const(3), 1 }   -- t=2-3: value 3
    )
    local fn = Compiler.compile(ir)
    
    assert(fn(0.5, {}) == 1, "Should be 1 during first segment")
    assert(fn(1.5, {}) == 2, "Should be 2 during second segment")
    assert(fn(2.5, {}) == 3, "Should be 3 during third segment")
end)

test("sequence has zero outside total duration", function()
    local ir = Compiler.curve.sequence(
        { Compiler.curve.const(1), 1 },
        { Compiler.curve.const(2), 1 }
    )
    local fn = Compiler.compile(ir)
    
    -- After both segments (total 2s)
    assert(fn(2.5, {}) == 0, "Should be 0 after all segments")
end)

test("sequence with sin curves", function()
    local ir = Compiler.curve.sequence(
        { Compiler.curve.sin(1, 10), 0.5 },   -- sin for 0.5s
        { Compiler.curve.sin(2, 20), 0.5 }    -- faster sin for 0.5s
    )
    local fn = Compiler.compile(ir)
    
    -- First segment: sin at t=0.25 (local time)
    local v1 = fn(0.25, {})
    local expected1 = 10 * math.sin(0.25 * 2 * math.pi)
    assert(approxEq(v1, expected1), "First segment should follow first sin")
    
    -- Second segment: at t=0.75, local time is 0.25
    local v2 = fn(0.75, {})
    local expected2 = 20 * math.sin(0.25 * 2 * 2 * math.pi)
    assert(approxEq(v2, expected2), "Second segment should follow second sin")
end)

print("\n=== Sequence: Motion ===\n")

test("motion sequence compiles", function()
    local ir = Compiler.motion.sequence(
        { Compiler.motion.drift(100, 0), 1 },
        { Compiler.motion.drift(-100, 0), 1 }
    )
    local fn = Compiler.compile(ir)
    assert(type(fn) == "function", "Should compile")
end)

test("motion sequence plays in order", function()
    local ir = Compiler.motion.sequence(
        { Compiler.motion.drift(100, 0), 1 },   -- move right
        { Compiler.motion.drift(0, 100), 1 }    -- move down
    )
    local fn = Compiler.compile(ir)
    
    -- First segment: drift right at t=0.5, local t=0.5, x = 50
    local x1, y1 = fn(0.5, {})
    assert(approxEq(x1, 50) and approxEq(y1, 0), 
        string.format("Should be moving right, got (%.2f, %.2f)", x1, y1))
    
    -- Second segment: at t=1.5, local t=0.5, y = 50
    local x2, y2 = fn(1.5, {})
    assert(approxEq(x2, 0) and approxEq(y2, 50),
        string.format("Should be moving down, got (%.2f, %.2f)", x2, y2))
end)

print("\n=== Sequence: Practical Patterns ===\n")

test("patrol pattern: left-right-left", function()
    local ir = Compiler.motion.sequence(
        { Compiler.motion.drift(100, 0), 1 },   -- right
        { Compiler.motion.drift(-100, 0), 2 },  -- left (longer)
        { Compiler.motion.drift(100, 0), 1 }    -- right
    )
    local fn = Compiler.compile(ir)
    
    -- At t=0.5: moving right, x = 50
    local x, y = fn(0.5, {})
    assert(x > 0, "Should be right of start")
    
    -- At t=2: moving left, local t=1, x = -100
    x, y = fn(2, {})
    assert(x < 0, "Should be left")
end)

test("sequence works with pool", function()
    local ir = Compiler.motion.sequence(
        { Compiler.motion.circle(50, 1), 1 },
        { Compiler.motion.drift(100, 0), 1 }
    )
    
    local pool = Compiler.createPool(ir, { count = 10, duration = 2 }):init()
    
    -- Initial position (circle at t=0)
    local x0, y0 = pool.x[1], pool.y[1]
    assert(approxEq(x0, 50) and approxEq(y0, 0), 
        string.format("Initial should be (50,0), got (%.2f, %.2f)", x0, y0))
    
    -- Step to middle of first segment (t=0.5)
    for _ = 1, 30 do
        pool:step()
    end
    
    -- Circle at t=0.5 should be around (0, 50)
    local x1, y1 = pool.x[1], pool.y[1]
    assert(not (approxEq(x1, 50) and approxEq(y1, 0)), 
        "Should have moved from initial position")
end)

print("\n=== Lerp: Curve ===\n")

test("curve lerp creates valid IR", function()
    local a = Compiler.curve.const(0)
    local b = Compiler.curve.const(10)
    local t = Compiler.curve.sin(1, 0.5, 0)  -- oscillates 0-1
    local ir = Compiler.curve.lerp(a, b, t)
    assert(ir.op == "add", "Lerp should be built from add")
end)

test("curve lerp compiles", function()
    local a = Compiler.curve.const(0)
    local b = Compiler.curve.const(10)
    local t = Compiler.curve.linear(1)  -- 0 to 1 over 1 second
    local ir = Compiler.curve.lerp(a, b, t)
    local fn = Compiler.compile(ir)
    assert(type(fn) == "function", "Should compile")
end)

test("curve lerp interpolates correctly", function()
    local a = Compiler.curve.const(0)
    local b = Compiler.curve.const(100)
    local t = Compiler.curve.linear(1)  -- t goes 0 to 1 over 1 second
    local ir = Compiler.curve.lerp(a, b, t)
    local fn = Compiler.compile(ir)
    
    -- At t=0, lerp factor is 0, result is a = 0
    assert(approxEq(fn(0, {}), 0), "At t=0, should be 0")
    
    -- At t=0.5, lerp factor is 0.5, result is 50
    assert(approxEq(fn(0.5, {}), 50), "At t=0.5, should be 50")
    
    -- At t=1, lerp factor is 1, result is b = 100
    assert(approxEq(fn(1, {}), 100), "At t=1, should be 100")
end)

test("curve lerp with dynamic curves", function()
    local a = Compiler.curve.sin(1, 10)   -- oscillates -10 to 10
    local b = Compiler.curve.sin(2, 20)   -- oscillates -20 to 20, faster
    local t = Compiler.curve.const(0.5)   -- constant 50% blend
    local ir = Compiler.curve.lerp(a, b, t)
    local fn = Compiler.compile(ir)
    
    -- At any time, should be average of a and b
    local v = fn(0.25, {})
    local expectedA = 10 * math.sin(0.25 * 2 * math.pi)
    local expectedB = 20 * math.sin(0.25 * 2 * 2 * math.pi)
    local expected = 0.5 * expectedA + 0.5 * expectedB
    assert(approxEq(v, expected), string.format("Expected %.2f, got %.2f", expected, v))
end)

print("\n=== Lerp: Motion ===\n")

test("motion lerp compiles", function()
    local a = Compiler.motion.circle(100, 1)
    local b = Compiler.motion.circle(50, 2)
    local t = Compiler.curve.sin(0.5, 0.5, 0)  -- oscillates around 0.5
    local ir = Compiler.motion.lerp(a, b, t)
    local fn = Compiler.compile(ir)
    assert(type(fn) == "function", "Should compile")
end)

test("motion lerp blends motions", function()
    local a = Compiler.motion.drift(100, 0)   -- moves right
    local b = Compiler.motion.drift(0, 100)   -- moves down
    local t = Compiler.curve.const(0.5)       -- 50% blend
    local ir = Compiler.motion.lerp(a, b, t)
    local fn = Compiler.compile(ir)
    
    -- At t=1, drift(100,0) = (100,0), drift(0,100) = (0,100)
    -- 50% blend = (50, 50)
    local x, y = fn(1, {})
    assert(approxEq(x, 50) and approxEq(y, 50),
        string.format("Expected (50,50), got (%.2f, %.2f)", x, y))
end)

print("\n=== All Segment/Sequence/Lerp tests complete ===\n")

Support.finish()
