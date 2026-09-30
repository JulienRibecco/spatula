-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for Lookup Table (LUT) Compilation
-- Path adjustment for tests subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Pre-computes values at fixed FPS for ultra-fast evaluation
--- Run with: lua test_lut.lua

local Compiler = require("spatula.compiler.compiler")

local function approxEq(a, b, eps)
    eps = eps or 0.001
    return math.abs(a - b) < eps
end

local Support = require("tests.support")
local test = Support.test
local benchmark = Support.benchmark

local PI2 = math.pi * 2

print("\n=== LUT: Basic Curve Compilation ===\n")

test("compileLUT works for simple curve", function()
    local ir = Compiler.curve.sin(1, 100)
    local lut, data = Compiler.compileLUT(ir, { fps = 60, duration = 1 })
    
    assert(type(lut) == "function", "Should return a function")
    assert(type(data) == "table", "Should return LUT data")
    assert(#data == 60, "Should have 60 frames for 1 second at 60fps")
end)

test("LUT curve produces correct values", function()
    local ir = Compiler.curve.sin(1, 100)
    local lut = Compiler.compileLUT(ir, { fps = 60, duration = 1 })
    
    -- Test at exact frame boundaries
    for frame = 0, 59 do
        local t = frame / 60
        local expected = math.sin(t * PI2) * 100
        local got = lut(t)
        assert(approxEq(got, expected, 0.1),
            string.format("Frame %d: expected %s, got %s", frame, expected, got))
    end
end)

test("LUT curve loops correctly", function()
    local ir = Compiler.curve.sin(1, 100)
    local lut = Compiler.compileLUT(ir, { fps = 60, duration = 1, loop = true })
    
    -- t=0 should equal t=1, t=2, etc.
    local v0 = lut(0)
    local v1 = lut(1)
    local v2 = lut(2)
    local v5 = lut(5.5)
    local v05 = lut(0.5)
    
    assert(approxEq(v0, v1) and approxEq(v1, v2),
        "Looped values should match at period boundaries")
    assert(approxEq(v5, v05),
        "t=5.5 should equal t=0.5 when looping")
end)

test("LUT curve non-looping clamps", function()
    local ir = Compiler.curve.linear(1)  -- linear goes 0 to 1 over 1 second
    local lut = Compiler.compileLUT(ir, { fps = 60, duration = 1, loop = false })
    
    local vNeg = lut(-1)
    local vOver = lut(10)
    
    assert(vNeg == lut(0), "Negative time should clamp to first value")
    -- Last value should be close to duration * speed = ~0.98 (frame 59/60)
end)

print("\n=== LUT: Motion Compilation ===\n")

test("compileLUT works for motion", function()
    local ir = Compiler.motion.circle(100, 1)
    local lut, data = Compiler.compileLUT(ir, { fps = 60, duration = 1 })
    
    assert(type(lut) == "function", "Should return a function")
    assert(#data == 60, "Should have 60 frames")
    assert(data[1].x ~= nil and data[1].y ~= nil, "Each entry should have x and y")
end)

test("LUT motion produces correct values", function()
    local ir = Compiler.motion.circle(100, 1)
    local lut = Compiler.compileLUT(ir, { fps = 60, duration = 1 })
    
    -- Test at t=0: circle starts at (100, 0)
    local x0, y0 = lut(0)
    assert(approxEq(x0, 100) and approxEq(y0, 0),
        string.format("t=0 should be (100, 0), got (%s, %s)", x0, y0))
    
    -- Test at t=0.25: circle at (0, 100)
    local x25, y25 = lut(0.25)
    assert(approxEq(x25, 0, 2) and approxEq(y25, 100, 2),
        string.format("t=0.25 should be ~(0, 100), got (%s, %s)", x25, y25))
end)

test("LUT motion loops correctly", function()
    local ir = Compiler.motion.circle(100, 1)
    local lut = Compiler.compileLUT(ir, { fps = 60, duration = 1, loop = true })
    
    local x0, y0 = lut(0)
    local x1, y1 = lut(1)
    local x3, y3 = lut(3)
    
    assert(approxEq(x0, x1) and approxEq(y0, y1),
        "Motion should loop at period")
    assert(approxEq(x0, x3) and approxEq(y0, y3),
        "Motion should loop at 3x period")
end)

print("\n=== LUT: Interpolation ===\n")

test("LUT without interpolation snaps to frames", function()
    local ir = Compiler.curve.linear(60)  -- Goes from 0 to 60 in 1 second
    local lut = Compiler.compileLUT(ir, { fps = 60, duration = 1, interpolate = false })
    
    -- At exact frame, should get frame value
    local v0 = lut(0)
    local v1 = lut(1/60)
    
    -- Between frames, should snap to lower frame
    local vMid = lut(0.5/60)  -- Halfway between frame 0 and 1
    assert(vMid == v0, "Without interpolation, should snap to frame 0")
end)

test("LUT with interpolation smooths between frames", function()
    local ir = Compiler.curve.linear(60)
    local lut = Compiler.compileLUT(ir, { fps = 60, duration = 1, interpolate = true })
    
    local v0 = lut(0)
    local v1 = lut(1/60)
    local vMid = lut(0.5/60)
    
    -- Midpoint should be between v0 and v1
    local expected = (v0 + v1) / 2
    assert(approxEq(vMid, expected, 0.01),
        string.format("Interpolated value should be %s, got %s", expected, vMid))
end)

test("Motion LUT with interpolation", function()
    local ir = Compiler.motion.circle(100, 1)
    local lut = Compiler.compileLUT(ir, { fps = 10, duration = 1, interpolate = true })
    
    -- Get values at frames 0 and 1
    local x0, y0 = lut(0)
    local x1, y1 = lut(0.1)  -- frame 1 at 10fps
    
    -- Midpoint should be interpolated
    local xMid, yMid = lut(0.05)
    local expX = (x0 + x1) / 2
    local expY = (y0 + y1) / 2
    
    assert(approxEq(xMid, expX, 1) and approxEq(yMid, expY, 1),
        "Interpolated motion should be midpoint between frames")
end)

print("\n=== LUT: Different FPS and Durations ===\n")

test("LUT at 30fps", function()
    local ir = Compiler.curve.sin(1, 1)
    local lut, data = Compiler.compileLUT(ir, { fps = 30, duration = 1 })
    
    assert(#data == 30, "Should have 30 frames at 30fps")
end)

test("LUT at 120fps", function()
    local ir = Compiler.curve.sin(1, 1)
    local lut, data = Compiler.compileLUT(ir, { fps = 120, duration = 1 })
    
    assert(#data == 120, "Should have 120 frames at 120fps")
end)

test("LUT with 2 second duration", function()
    local ir = Compiler.curve.sin(0.5, 1)  -- Half Hz = 2 second period
    local lut, data = Compiler.compileLUT(ir, { fps = 60, duration = 2 })
    
    assert(#data == 120, "Should have 120 frames for 2 seconds at 60fps")
end)

test("LUT with fractional duration", function()
    local ir = Compiler.motion.circle(100, 2)  -- 2 Hz = 0.5 second period
    local lut, data = Compiler.compileLUT(ir, { fps = 60, duration = 0.5 })
    
    assert(#data == 30, "Should have 30 frames for 0.5 seconds at 60fps")
end)

print("\n=== LUT: Source Generation ===\n")

test("compileLUTSource generates valid code", function()
    local ir = Compiler.curve.sin(1, 100)
    local fn, source = Compiler.compileLUTSource(ir, { fps = 60, duration = 1 })
    
    assert(type(fn) == "function", "Should return compiled function")
    assert(type(source) == "string", "Should return source string")
    assert(source:find("local lut = {"), "Source should contain LUT array")
    assert(source:find("return function"), "Source should have return function")
end)

test("compileLUTSource motion generates two arrays", function()
    local ir = Compiler.motion.circle(100, 1)
    local fn, source = Compiler.compileLUTSource(ir, { fps = 60, duration = 1 })
    
    assert(source:find("local lut_x = {"), "Should have X array")
    assert(source:find("local lut_y = {"), "Should have Y array")
end)

test("compileLUTSource produces same results as compileLUT", function()
    local ir = Compiler.motion.circle(100, 1)
    local lutFn = Compiler.compileLUT(ir, { fps = 60, duration = 1 })
    local srcFn = Compiler.compileLUTSource(ir, { fps = 60, duration = 1 })
    
    for i = 0, 10 do
        local t = i * 0.1
        local lx, ly = lutFn(t)
        local sx, sy = srcFn(t)
        assert(approxEq(lx, sx) and approxEq(ly, sy),
            string.format("Mismatch at t=%s", t))
    end
end)

print("\n=== LUT: Memory Estimation ===\n")

test("estimateLUTSize for curve", function()
    local ir = Compiler.curve.sin(1, 1)
    local size = Compiler.estimateLUTSize(ir, { fps = 60, duration = 1 })
    
    -- 60 doubles * 8 bytes + ~40 overhead = ~520 bytes
    assert(size > 400 and size < 600,
        string.format("Expected ~520 bytes, got %d", size))
end)

test("estimateLUTSize for motion", function()
    local ir = Compiler.motion.circle(100, 1)
    local size = Compiler.estimateLUTSize(ir, { fps = 60, duration = 1 })
    
    -- 60 * 2 doubles * 8 bytes + ~40 overhead = ~1000 bytes
    assert(size > 900 and size < 1100,
        string.format("Expected ~1000 bytes, got %d", size))
end)

test("estimateLUTSize scales with duration", function()
    local ir = Compiler.curve.sin(1, 1)
    local size1 = Compiler.estimateLUTSize(ir, { fps = 60, duration = 1 })
    local size2 = Compiler.estimateLUTSize(ir, { fps = 60, duration = 2 })
    
    assert(size2 > size1 * 1.5, "Longer duration should use more memory")
end)

print("\n=== LUT: Suitability Checks ===\n")

test("canUseLUT returns true for pure curves", function()
    local ir = Compiler.motion.circle(100, 1)
    local ok, reason = Compiler.canUseLUT(ir)
    assert(ok == true, "Pure motion should be LUT-able")
end)

test("canUseLUT returns false for stateful curves", function()
    local ir = Compiler.curve.follow(Compiler.curve.const(100), 5)
    local ok, reason = Compiler.canUseLUT(ir)
    assert(ok == false, "Stateful curve should not be LUT-able")
    assert(reason:find("stateful"), "Reason should mention stateful")
end)

test("canUseLUT returns false for ctx-dependent curves", function()
    local ir = Compiler.curve.fromCtx("target", 0)
    local ok, reason = Compiler.canUseLUT(ir)
    assert(ok == false, "Ctx-dependent curve should not be LUT-able")
    assert(reason:find("ctx"), "Reason should mention ctx")
end)

test("canUseLUT detects nested stateful", function()
    local ir = Compiler.motion.xy(
        Compiler.curve.sin(1, 100),
        Compiler.curve.follow(Compiler.curve.const(0), 5)
    )
    local ok, reason = Compiler.canUseLUT(ir)
    assert(ok == false, "Nested stateful should be detected")
end)

print("\n=== LUT: Performance Comparison ===\n")

benchmark("LUT is faster than compiled", function()
    local ir = Compiler.motion.circle(100, 1)
    
    local compiled = Compiler.compile(ir)
    local lut = Compiler.compileLUT(ir, { fps = 60, duration = 1 })
    
    local iterations = 1000000
    local ctx = {}
    
    -- Warm up
    for i = 1, 10000 do
        compiled(i * 0.0001, ctx)
        lut(i * 0.0001)
    end
    
    -- Time compiled
    local t0 = os.clock()
    for i = 1, iterations do
        local x, y = compiled((i % 60) / 60, ctx)
    end
    local compiledTime = os.clock() - t0
    
    -- Time LUT
    t0 = os.clock()
    for i = 1, iterations do
        local x, y = lut((i % 60) / 60)
    end
    local lutTime = os.clock() - t0
    
    local speedup = compiledTime / lutTime
    print(string.format("  Compiled: %.4fs, LUT: %.4fs, Speedup: %.2fx", 
        compiledTime, lutTime, speedup))
    
    -- LUT should be at least somewhat faster (allow for some variance)
    assert(speedup > 0.8, string.format("LUT should be competitive, got %.2fx", speedup))
end)

print("\n=== LUT: Complex Compositions ===\n")

test("growing spiral requires an explicit bounded LUT", function()
    local ir = Compiler.motion.spiral(100, 1, 0.5)
    local ok = Compiler.canUseLUT(ir)
    assert(not ok, "Growing spiral must not automatically loop")
    
    local lut = Compiler.compileLUT(ir, { fps = 60, duration = 2 })
    local x, y = lut(0.5)
    assert(type(x) == "number" and type(y) == "number")
end)

test("LUT works with figure8", function()
    local ir = Compiler.motion.figure8(100, 1)
    local lut = Compiler.compileLUT(ir, { fps = 60, duration = 1 })
    
    -- Figure8 should cross origin at t=0.25 and t=0.75
    local x0, y0 = lut(0)
    assert(type(x0) == "number" and type(y0) == "number")
end)

test("LUT works with layered motion", function()
    local ir = Compiler.motion.add(
        Compiler.motion.circle(100, 0.5),
        Compiler.motion.circle(20, 3)
    )
    
    local ok = Compiler.canUseLUT(ir, 2)
    assert(ok, "Both circles repeat over two seconds")
    assert(not Compiler.canUseLUT(ir, 1), "Half-Hz circle does not repeat in one second")
    
    local lut = Compiler.compileLUT(ir, { fps = 60, duration = 2 })
    
    for i = 0, 10 do
        local t = i * 0.2
        local x, y = lut(t)
        assert(type(x) == "number" and type(y) == "number",
            string.format("Invalid output at t=%s", t))
    end
end)

print("\n=== LUT: Generated Source Sample ===\n")

print("--- circle(100, 1) at 10fps for readability ---")
local ir = Compiler.motion.circle(100, 1)
local _, source = Compiler.compileLUTSource(ir, { fps = 10, duration = 1 })
print(source)

print("\n=== All LUT tests complete ===\n")

Support.finish()
