-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for LUT Module
-- Path adjustment for tests subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Run with: lua test_lut_module.lua

local LUT = require("spatula.compiler.strategies.lut")

local function approxEq(a, b, eps)
    eps = eps or 0.01
    return math.abs(a - b) < eps
end

local Support = require("tests.support")
local test = Support.test
local benchmark = Support.benchmark

-- Simple compile function for testing
local function mockCompile(ir)
    if ir.op == "sin" then
        local freq = ir.freq or 1
        local amp = ir.amp or 1
        return function(t)
            return math.sin(t * freq * math.pi * 2) * amp
        end
    elseif ir.op == "cos" then
        local freq = ir.freq or 1
        local amp = ir.amp or 1
        return function(t)
            return math.cos(t * freq * math.pi * 2) * amp
        end
    elseif ir.op == "xy" and ir.type == "motion" then
        local xFn = mockCompile(ir.x)
        local yFn = mockCompile(ir.y)
        return function(t, ctx)
            return xFn(t), yFn(t)
        end
    else
        return function(t) return 0 end
    end
end

-- Mock hasStatefulNodes
local function hasStateful(node)
    if not node then return false end
    if node.op == "follow" or node.op == "spring" then return true end
    for k, v in pairs(node) do
        if type(v) == "table" and hasStateful(v) then return true end
    end
    return false
end

print("\n=== LUT Module: Analysis ===\n")

test("canUse returns true for pure curves", function()
    local ir = { op = "sin", freq = 1, amp = 100 }
    assert(LUT.canUse(ir, hasStateful), "Sin should be LUT-able")
end)

test("canUse returns false for stateful", function()
    local ir = { op = "follow", target = {}, speed = 1 }
    assert(not LUT.canUse(ir, hasStateful), "Follow should not be LUT-able")
end)

test("estimateSize for curve", function()
    local ir = { op = "sin", freq = 1 }
    local size = LUT.estimateSize(ir, { fps = 60, duration = 1 })
    
    -- 60 frames * 1 value * 8 bytes = 480
    assert(size == 480, "Should be 480 bytes, got " .. size)
end)

test("estimateSize for motion", function()
    local ir = { type = "motion", op = "xy", x = {}, y = {} }
    local size = LUT.estimateSize(ir, { fps = 60, duration = 1 })
    
    -- 60 frames * 2 values * 8 bytes = 960
    assert(size == 960, "Should be 960 bytes, got " .. size)
end)

print("\n=== LUT Module: Compile ===\n")

test("compile sin curve", function()
    local ir = { op = "sin", freq = 1, amp = 100 }
    
    local lut, data = LUT.compile(ir, mockCompile, { fps = 60, duration = 1 })
    
    assert(lut, "Should return lookup function")
    assert(data, "Should return LUT data")
    assert(#data == 60, "Should have 60 frames")
end)

test("LUT lookup matches compiled", function()
    local ir = { op = "sin", freq = 1, amp = 100 }
    local compiled = mockCompile(ir)
    
    local lut = LUT.compile(ir, mockCompile, { fps = 60, duration = 1 })
    
    -- Test at various times
    for _, t in ipairs({ 0, 0.25, 0.5, 0.75 }) do
        local expected = compiled(t)
        local actual = lut(t)
        assert(approxEq(expected, actual, 2), 
            string.format("At t=%.2f: expected %.2f, got %.2f", t, expected, actual))
    end
end)

test("compile motion", function()
    local ir = {
        type = "motion",
        op = "xy",
        x = { op = "cos", freq = 1, amp = 100 },
        y = { op = "sin", freq = 1, amp = 100 }
    }
    
    local lut, data = LUT.compile(ir, mockCompile, { fps = 60, duration = 1 })
    
    local x, y = lut(0)
    assert(approxEq(x, 100), "X at t=0 should be 100")
    assert(approxEq(y, 0), "Y at t=0 should be 0")
    
    x, y = lut(0.25)
    assert(approxEq(x, 0, 2), "X at t=0.25 should be ~0")
    assert(approxEq(y, 100, 2), "Y at t=0.25 should be ~100")
end)

test("LUT loops correctly", function()
    local ir = { op = "sin", freq = 1, amp = 100 }
    
    local lut = LUT.compile(ir, mockCompile, { fps = 60, duration = 1 })
    
    local v0 = lut(0)
    local v1 = lut(1)
    local v2 = lut(2)
    
    assert(approxEq(v0, v1, 2), "t=0 and t=1 should match")
    assert(approxEq(v0, v2, 2), "t=0 and t=2 should match")
end)

print("\n=== LUT Module: Batch ===\n")

test("compileBatch for curve", function()
    local ir = { op = "sin", freq = 1, amp = 100 }
    
    local batchFn, frameCount, lutData = LUT.compileBatch(ir, mockCompile, { fps = 60 })
    
    assert(batchFn, "Should return batch function")
    assert(frameCount == 60, "Should have 60 frames")
    assert(lutData.x, "Should have x data")
end)

test("batch function evaluates correctly", function()
    local ir = { op = "sin", freq = 1, amp = 100 }
    
    local batchFn, _, _ = LUT.compileBatch(ir, mockCompile, { fps = 60 })
    
    local times = { 0, 0.25, 0.5, 0.75 }
    local phases = { 0, 0, 0, 0 }
    local out = { 0, 0, 0, 0 }
    
    batchFn(times, phases, 4, out)
    
    assert(approxEq(out[1], 0, 2), "t=0 should be 0")
    assert(approxEq(out[2], 100, 2), "t=0.25 should be 100")
    assert(approxEq(out[3], 0, 2), "t=0.5 should be 0")
    assert(approxEq(out[4], -100, 2), "t=0.75 should be -100")
end)

test("batch with phases", function()
    local ir = { op = "sin", freq = 1, amp = 100 }
    
    local batchFn, _, _ = LUT.compileBatch(ir, mockCompile, { fps = 60 })
    
    local times = { 0, 0, 0, 0 }
    local phases = { 0, 0.25, 0.5, 0.75 }
    local out = { 0, 0, 0, 0 }
    
    batchFn(times, phases, 4, out)
    
    assert(approxEq(out[1], 0, 2), "phase=0 should be 0")
    assert(approxEq(out[2], 100, 2), "phase=0.25 should be 100")
end)

test("batch motion", function()
    local ir = {
        type = "motion",
        op = "xy",
        x = { op = "cos", freq = 1, amp = 100 },
        y = { op = "sin", freq = 1, amp = 100 }
    }
    
    local batchFn, frameCount, lutData = LUT.compileBatch(ir, mockCompile, { fps = 60 })
    
    assert(lutData.y, "Motion should have y data")
    
    local times = { 0, 0.25 }
    local phases = { 0, 0 }
    local outX = { 0, 0 }
    local outY = { 0, 0 }
    
    batchFn(times, phases, 2, outX, outY)
    
    assert(approxEq(outX[1], 100, 2), "X at t=0 should be 100")
    assert(approxEq(outY[1], 0, 2), "Y at t=0 should be 0")
end)

print("\n=== LUT Module: Source Generation ===\n")

test("toSource generates valid Lua", function()
    local ir = { op = "sin", freq = 1, amp = 100 }
    
    local source = LUT.toSource(ir, mockCompile, { fps = 60, duration = 1 })
    
    assert(source:match("local lut"), "Should have lut table")
    assert(source:match("return function"), "Should return function")
    assert(source:match("floor"), "Should use floor")
end)

test("toSource compiles and runs", function()
    local ir = { op = "sin", freq = 1, amp = 100 }
    
    local source = LUT.toSource(ir, mockCompile, { fps = 60, duration = 1 })
    
    local fn = load(source)()
    
    assert(fn, "Should compile to function")
    assert(approxEq(fn(0), 0, 2), "fn(0) should be 0")
    assert(approxEq(fn(0.25), 100, 2), "fn(0.25) should be 100")
end)

print("\n=== LUT Module: Hybrid Analysis ===\n")

test("analyzeHybrid with mixed children", function()
    local ir = {
        op = "motionAdd",
        children = {
            { op = "sin", freq = 1, amp = 10 },
            { op = "follow", target = {}, speed = 1 },
            { op = "cos", freq = 2, amp = 5 }
        }
    }
    
    local canHybrid, pure, stateful = LUT.analyzeHybrid(ir, hasStateful)
    
    assert(canHybrid, "Should support hybrid")
    assert(#pure == 2, "Should have 2 pure children")
    assert(#stateful == 1, "Should have 1 stateful child")
end)

test("analyzeHybrid rejects all-pure", function()
    local ir = {
        op = "motionAdd",
        children = {
            { op = "sin", freq = 1, amp = 10 },
            { op = "cos", freq = 2, amp = 5 }
        }
    }
    
    local canHybrid, _, _ = LUT.analyzeHybrid(ir, hasStateful)
    
    assert(not canHybrid, "All-pure should not need hybrid")
end)

print("\n=== All LUT Module tests complete ===\n")

Support.finish()
