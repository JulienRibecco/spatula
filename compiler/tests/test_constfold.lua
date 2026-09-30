-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for Constant Folding Optimizations
-- Path adjustment for tests subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Run with: lua test_constfold.lua

local Compiler = require("spatula.compiler.compiler")

local Support = require("tests.support")
local test = Support.test
local benchmark = Support.benchmark

local function isConst(ir)
    return ir and ir.op == "const"
end

print("\n=== Constant Folding: Scale ===\n")

test("scale(const(2), 3) -> const(6)", function()
    local ir = Compiler.curve.scale(Compiler.curve.const(2), 3)
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 6, "Should be 6, got " .. tostring(opt.value))
end)

test("scale(x, 0) -> const(0)", function()
    local ir = Compiler.curve.scale(Compiler.curve.sin(1, 1), 0)
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 0, "Should be 0")
end)

test("scale(x, 1) -> x", function()
    local ir = Compiler.curve.scale(Compiler.curve.sin(1, 1), 1)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin", "Should be sin, got " .. tostring(opt.op))
end)

test("scale(scale(x, 2), 3) -> scale(x, 6)", function()
    local ir = Compiler.curve.scale(Compiler.curve.scale(Compiler.curve.sin(1, 1), 2), 3)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "scaleConst", "Should be scaleConst")
    assert(opt.factor == 6, "Factor should be 6, got " .. tostring(opt.factor))
    assert(opt.curve.op == "sin", "Inner should be sin")
end)

print("\n=== Constant Folding: Offset ===\n")

test("offset(const(2), 3) -> const(5)", function()
    local ir = Compiler.curve.offset(Compiler.curve.const(2), 3)
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 5, "Should be 5")
end)

test("offset(x, 0) -> x", function()
    local ir = Compiler.curve.offset(Compiler.curve.sin(1, 1), 0)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin", "Should be sin")
end)

test("offset(offset(x, 2), 3) -> offset(x, 5)", function()
    local ir = Compiler.curve.offset(Compiler.curve.offset(Compiler.curve.sin(1, 1), 2), 3)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "offsetConst", "Should be offsetConst")
    assert(opt.amount == 5, "Amount should be 5, got " .. tostring(opt.amount))
    assert(opt.curve.op == "sin", "Inner should be sin")
end)

print("\n=== Constant Folding: Add ===\n")

test("add(const(2), const(3)) -> const(5)", function()
    local ir = Compiler.curve.add(Compiler.curve.const(2), Compiler.curve.const(3))
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 5, "Should be 5")
end)

test("add(x, const(0)) -> x", function()
    local ir = Compiler.curve.add(Compiler.curve.sin(1, 1), Compiler.curve.const(0))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin", "Should be sin, got " .. tostring(opt.op))
end)

test("add(const(0), x) -> x", function()
    local ir = Compiler.curve.add(Compiler.curve.const(0), Compiler.curve.sin(1, 1))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin", "Should be sin")
end)

test("add(x, y, const(2), const(3)) -> add(x, y, const(5))", function()
    local ir = Compiler.curve.add(
        Compiler.curve.sin(1, 1),
        Compiler.curve.cos(1, 1),
        Compiler.curve.const(2),
        Compiler.curve.const(3)
    )
    local opt = Compiler.optimize(ir)
    assert(opt.op == "add", "Should still be add")
    
    -- Find the const child
    local constChild = nil
    local nonConstCount = 0
    for _, child in ipairs(opt.children) do
        if isConst(child) then
            constChild = child
        else
            nonConstCount = nonConstCount + 1
        end
    end
    assert(constChild and constChild.value == 5, "Constants should be folded to 5")
    assert(nonConstCount == 2, "Should have 2 non-const children")
end)

print("\n=== Constant Folding: Mul ===\n")

test("mul(const(2), const(3)) -> const(6)", function()
    local ir = Compiler.curve.mul(Compiler.curve.const(2), Compiler.curve.const(3))
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 6, "Should be 6")
end)

test("mul(x, const(0)) -> const(0)", function()
    local ir = Compiler.curve.mul(Compiler.curve.sin(1, 1), Compiler.curve.const(0))
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 0, "Should be 0")
end)

test("mul(x, const(1)) -> x", function()
    local ir = Compiler.curve.mul(Compiler.curve.sin(1, 1), Compiler.curve.const(1))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin", "Should be sin")
end)

print("\n=== Constant Folding: Sub ===\n")

test("sub(const(5), const(3)) -> const(2)", function()
    local ir = Compiler.curve.sub(Compiler.curve.const(5), Compiler.curve.const(3))
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 2, "Should be 2")
end)

test("sub(x, const(0)) -> x", function()
    local ir = Compiler.curve.sub(Compiler.curve.sin(1, 1), Compiler.curve.const(0))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin", "Should be sin")
end)

test("sub(const(0), x) -> neg(x)", function()
    local ir = Compiler.curve.sub(Compiler.curve.const(0), Compiler.curve.sin(1, 1))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "neg", "Should be neg")
    assert(opt.curve.op == "sin", "Inner should be sin")
end)

print("\n=== Constant Folding: Neg/Abs/Pow ===\n")

test("neg(const(5)) -> const(-5)", function()
    local ir = Compiler.curve.neg(Compiler.curve.const(5))
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == -5, "Should be -5")
end)

test("neg(neg(x)) -> x", function()
    local ir = Compiler.curve.neg(Compiler.curve.neg(Compiler.curve.sin(1, 1)))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin", "Should be sin")
end)

test("abs(const(-5)) -> const(5)", function()
    local ir = Compiler.curve.abs(Compiler.curve.const(-5))
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 5, "Should be 5")
end)

test("pow(const(2), 3) -> const(8)", function()
    local ir = Compiler.curve.pow(Compiler.curve.const(2), 3)
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 8, "Should be 8")
end)

test("pow(x, 1) -> x", function()
    local ir = Compiler.curve.pow(Compiler.curve.sin(1, 1), 1)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin", "Should be sin")
end)

test("pow(x, 0) -> const(1)", function()
    local ir = Compiler.curve.pow(Compiler.curve.sin(1, 1), 0)
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 1, "Should be 1")
end)

print("\n=== Constant Folding: Time Manipulation ===\n")

test("timeScale(x, 1) -> x", function()
    local ir = Compiler.curve.timeScale(Compiler.curve.sin(1, 1), 1)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin", "Should be sin")
end)

test("timeScale(const(5), 2) -> const(5)", function()
    local ir = Compiler.curve.timeScale(Compiler.curve.const(5), 2)
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 5, "Should be 5")
end)

test("timeScale(timeScale(x, 2), 3) -> timeScale(x, 6)", function()
    local ir = Compiler.curve.timeScale(Compiler.curve.timeScale(Compiler.curve.sin(1, 1), 2), 3)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "timeScaleConst", "Should be timeScaleConst")
    assert(opt.factor == 6, "Factor should be 6")
end)

test("timeOffset(x, 0) -> x", function()
    local ir = Compiler.curve.timeOffset(Compiler.curve.sin(1, 1), 0)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin", "Should be sin")
end)

test("timeOffset(const(5), 2) -> const(5)", function()
    local ir = Compiler.curve.timeOffset(Compiler.curve.const(5), 2)
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 5, "Should be 5")
end)

test("timeOffset(timeOffset(x, 2), 3) -> timeOffset(x, 5)", function()
    local ir = Compiler.curve.timeOffset(Compiler.curve.timeOffset(Compiler.curve.sin(1, 1), 2), 3)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "timeOffsetConst", "Should be timeOffsetConst")
    assert(opt.offset == 5, "Offset should be 5")
end)

print("\n=== Constant Folding: Loop/Delay ===\n")

test("loop(const(5), 1) -> const(5)", function()
    local ir = Compiler.curve.loop(Compiler.curve.const(5), 1)
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 5, "Should be 5")
end)

test("delay(const(5), 1) -> const(5)", function()
    local ir = Compiler.curve.delay(Compiler.curve.const(5), 1)
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 5, "Should be 5")
end)

print("\n=== Constant Folding: Clamp ===\n")

test("clamp(const(5), 0, 3) -> const(3)", function()
    local ir = Compiler.curve.clamp(Compiler.curve.const(5), 0, 3)
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 3, "Should be 3 (clamped)")
end)

test("clamp(const(-5), 0, 3) -> const(0)", function()
    local ir = Compiler.curve.clamp(Compiler.curve.const(-5), 0, 3)
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 0, "Should be 0 (clamped)")
end)

print("\n=== Constant Folding: Motion ===\n")

test("motionScale(m, 1) -> m", function()
    local ir = Compiler.motion.scale(Compiler.motion.circle(100, 1), 1)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "xy", "Should be xy (circle)")
end)

test("motionScale(m, 0) -> xy(0, 0)", function()
    local ir = Compiler.motion.scale(Compiler.motion.circle(100, 1), 0)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "xy", "Should be xy")
    assert(isConst(opt.x), "X should be const")
    assert(opt.x.value == 0, "X should be 0")
end)

test("motionScale(motionScale(m, 2), 3) -> motionScale(m, 6)", function()
    local ir = Compiler.motion.scale(Compiler.motion.scale(Compiler.motion.circle(100, 1), 2), 3)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "motionScaleConst", "Should be motionScaleConst")
    assert(opt.factor == 6, "Factor should be 6")
end)

print("\n=== Constant Folding: Complex Expressions ===\n")

test("scale(offset(const(2), 3), 2) -> const(10)", function()
    local ir = Compiler.curve.scale(
        Compiler.curve.offset(Compiler.curve.const(2), 3),
        2
    )
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 10, "Should be 10: (2+3)*2")
end)

test("add(scale(const(2), 3), offset(const(1), 2)) -> const(9)", function()
    local ir = Compiler.curve.add(
        Compiler.curve.scale(Compiler.curve.const(2), 3),  -- 6
        Compiler.curve.offset(Compiler.curve.const(1), 2)  -- 3
    )
    local opt = Compiler.optimize(ir)
    assert(isConst(opt), "Should be const")
    assert(opt.value == 9, "Should be 9: 6+3")
end)

test("deep nesting collapses correctly", function()
    -- scale(scale(scale(x, 2), 3), 4) -> scale(x, 24)
    local ir = Compiler.curve.scale(
        Compiler.curve.scale(
            Compiler.curve.scale(Compiler.curve.sin(1, 1), 2),
            3
        ),
        4
    )
    local opt = Compiler.optimize(ir)
    assert(opt.op == "scaleConst", "Should be scaleConst")
    assert(opt.factor == 24, "Factor should be 24: 2*3*4")
end)

print("\n=== All Constant Folding tests complete ===\n")

Support.finish()
