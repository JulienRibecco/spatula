-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for Common Subexpression Elimination (CSE)
-- Path adjustment for tests subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Run with: lua test_cse.lua

local Compiler = require("spatula.compiler.compiler")

local function approxEq(a, b, eps)
    eps = eps or 0.0001
    return math.abs(a - b) < eps
end

local Support = require("tests.support")
local test = Support.test
local benchmark = Support.benchmark

local function countPattern(str, pattern)
    local count = 0
    for _ in str:gmatch(pattern) do
        count = count + 1
    end
    return count
end

print("\n=== CSE: Time Expression Deduplication ===\n")

test("timeScale with same factor shares variable", function()
    -- shake uses timeScale(noise, 10) for both X and Y
    local ir = Compiler.motion.shake(5, 10)
    local source = Compiler.toSource(ir)
    
    -- Should only have ONE "t * 10" assignment
    local timeScaleCount = countPattern(source, "local _v%d+ = t %* 10")
    assert(timeScaleCount == 1, 
        "Expected 1 timeScale assignment, got " .. timeScaleCount .. "\n" .. source)
end)

test("multiple timeOffsets with same offset share variable", function()
    -- Two curves with same time offset
    local ir = Compiler.motion.xy(
        Compiler.curve.timeOffset(Compiler.curve.sin(1, 1), 5),
        Compiler.curve.timeOffset(Compiler.curve.cos(1, 1), 5)
    )
    local source = Compiler.toSource(ir)
    
    local timeOffsetCount = countPattern(source, "local _v%d+ = t %+ 5")
    assert(timeOffsetCount == 1,
        "Expected 1 timeOffset assignment, got " .. timeOffsetCount .. "\n" .. source)
end)

test("different timeScale factors get separate variables", function()
    local ir = Compiler.motion.xy(
        Compiler.curve.timeScale(Compiler.curve.sin(1, 1), 2),
        Compiler.curve.timeScale(Compiler.curve.cos(1, 1), 3)
    )
    local source = Compiler.toSource(ir)
    
    -- Should have two different assignments
    local t2Count = countPattern(source, "t %* 2")
    local t3Count = countPattern(source, "t %* 3")
    assert(t2Count == 1 and t3Count == 1,
        "Expected separate variables for t*2 and t*3\n" .. source)
end)

print("\n=== CSE: Angle Expression Deduplication ===\n")

test("circle shares angle between sin/cos", function()
    local ir = Compiler.motion.circle(100, 2)
    local source = Compiler.toSource(ir)
    
    -- Should have ONE angle computation
    local angleCount = countPattern(source, "local _v%d+ = t %* [%d%.]+")
    assert(angleCount == 1,
        "Expected 1 angle assignment for circle, got " .. angleCount .. "\n" .. source)
    
    -- Both sin and cos should use the same variable
    assert(source:match("cos%(_v1%)") and source:match("sin%(_v1%)"),
        "sin and cos should use same angle variable\n" .. source)
end)

test("ellipse with same speed shares angle", function()
    local ir = Compiler.motion.ellipse(200, 100, 3)
    local source = Compiler.toSource(ir)
    
    local angleCount = countPattern(source, "local _v%d+ = t %* [%d%.]+")
    assert(angleCount == 1,
        "Expected 1 angle assignment for ellipse, got " .. angleCount .. "\n" .. source)
end)

test("different frequencies get separate angles", function()
    -- hover uses different frequencies for X and Y
    local ir = Compiler.motion.hover(10, 1)
    local source = Compiler.toSource(ir)
    
    -- Should have TWO angle computations (different freqs)
    local angleCount = countPattern(source, "local _v%d+ = t %* [%d%.]+")
    assert(angleCount == 2,
        "Expected 2 angle assignments for hover (different freqs), got " .. angleCount .. "\n" .. source)
end)

print("\n=== CSE: Loop Expression Deduplication ===\n")

test("multiple loops with same duration share variable", function()
    local ir = Compiler.motion.xy(
        Compiler.curve.loop(Compiler.curve.sin(1, 1), 3),
        Compiler.curve.loop(Compiler.curve.cos(1, 1), 3)
    )
    local source = Compiler.toSource(ir)
    
    -- Pattern: "t % 3" - need to escape % as %%
    local loopCount = countPattern(source, "local _v%d+ = t %% 3")
    assert(loopCount == 1,
        "Expected 1 loop assignment, got " .. loopCount .. "\n" .. source)
end)

print("\n=== CSE: Complex Compositions ===\n")

test("spiral shares angle computation", function()
    local ir = Compiler.motion.spiral(100, 1, 0.5)
    local source = Compiler.toSource(ir)
    
    -- Should have ONE angle for the underlying circle
    local angleCount = countPattern(source, "local _v%d+ = t %* 6%.28")
    assert(angleCount == 1,
        "Expected 1 angle assignment in spiral\n" .. source)
end)

test("outward (unit spiral) shares angle", function()
    local ir = Compiler.motion.outward(2)
    local source = Compiler.toSource(ir)
    
    -- mul(cos, linear) and mul(sin, linear) should share the angle
    local angleCount = countPattern(source, "local _v%d+ = t %* [%d%.]+")
    assert(angleCount == 1,
        "Expected 1 angle assignment in outward\n" .. source)
end)

test("figure8 shares X frequency angle", function()
    -- figure8 = lissajous(speed, speed*2, size, size, 0)
    -- X uses freq=speed, Y uses freq=speed*2
    -- So they should have DIFFERENT angles
    local ir = Compiler.motion.figure8(100, 1)
    local source = Compiler.toSource(ir)
    
    -- Should have 2 different angles (freq 1 and freq 2)
    local angleCount = countPattern(source, "local _v%d+ = t %* [%d%.]+")
    assert(angleCount == 2,
        "Expected 2 angle assignments in figure8 (different freqs)\n" .. source)
end)

print("\n=== CSE: Correctness Verification ===\n")

test("CSE doesn't change computation results", function()
    -- Compile with CSE
    local ir = Compiler.motion.shake(5, 10)
    local compiled = Compiler.compile(ir)
    
    -- Manual computation (what the unoptimized version would produce)
    local function manual(t)
        local st = t * 10
        local nx = (math.sin(st * 1.0 + 0) * 0.5 + 
                    math.sin(st * 2.3 + 0) * 0.3 + 
                    math.sin(st * 5.7 + 0) * 0.2) * 5
        local ny = (math.sin(st * 1.0 + 12345) * 0.5 + 
                    math.sin(st * 2.3 + 24690) * 0.3 + 
                    math.sin(st * 5.7 + 37035) * 0.2) * 5
        return nx, ny
    end
    
    for i = 1, 100 do
        local t = i * 0.01
        local cx, cy = compiled(t, {})
        local mx, my = manual(t)
        assert(approxEq(cx, mx) and approxEq(cy, my),
            string.format("Mismatch at t=%s: compiled=(%s,%s) manual=(%s,%s)",
                t, cx, cy, mx, my))
    end
end)

test("circle correctness preserved with CSE", function()
    local ir = Compiler.motion.circle(100, 2)
    local compiled = Compiler.compile(ir)
    
    for i = 0, 4 do
        local t = i * 0.25
        local x, y = compiled(t, {})
        local angle = t * 2 * math.pi * 2
        local ex, ey = math.cos(angle) * 100, math.sin(angle) * 100
        assert(approxEq(x, ex) and approxEq(y, ey),
            string.format("Circle mismatch at t=%s", t))
    end
end)

print("\n=== CSE: Generated Code Samples ===\n")

print("--- shake(5, 10) - Before CSE would have duplicate t*10 ---")
print(Compiler.toSource(Compiler.motion.shake(5, 10)))
print("")

print("--- circle(100, 2) - Shares angle between sin/cos ---")
print(Compiler.toSource(Compiler.motion.circle(100, 2)))
print("")

print("--- nested timeScale - Both share t*10 ---")
local nested = Compiler.motion.xy(
    Compiler.curve.timeScale(Compiler.curve.sin(1, 50), 10),
    Compiler.curve.timeScale(Compiler.curve.cos(1, 50), 10)
)
print(Compiler.toSource(nested))

print("\n=== All CSE tests complete ===\n")

Support.finish()
