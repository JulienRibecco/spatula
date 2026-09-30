-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for Dead Code Elimination (DCE) and Constant Propagation
-- Path adjustment for tests subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Run with: lua test_dce.lua

local Compiler = require("spatula.compiler.compiler")

local function approxEq(a, b, eps)
    eps = eps or 0.0001
    return math.abs(a - b) < eps
end

local Support = require("tests.support")
local test = Support.test
local benchmark = Support.benchmark

print("\n=== DCE: Scale Identity Operations ===\n")

test("scale(x, 0) -> const(0)", function()
    local ir = Compiler.curve.scale(Compiler.curve.sin(1, 100), 0)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "const" and opt.value == 0,
        "Expected const(0), got op=" .. tostring(opt.op))
end)

test("scale(x, 1) -> x", function()
    local ir = Compiler.curve.scale(Compiler.curve.sin(1, 100), 1)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin",
        "Expected sin, got op=" .. tostring(opt.op))
end)

test("scale(const(5), 3) -> const(15)", function()
    local ir = Compiler.curve.scale(Compiler.curve.const(5), 3)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "const" and opt.value == 15,
        "Expected const(15), got op=" .. tostring(opt.op) .. " value=" .. tostring(opt.value))
end)

print("\n=== DCE: Offset Identity Operations ===\n")

test("offset(x, 0) -> x", function()
    local ir = Compiler.curve.offset(Compiler.curve.sin(1, 100), 0)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin",
        "Expected sin, got op=" .. tostring(opt.op))
end)

test("offset(const(5), 3) -> const(8)", function()
    local ir = Compiler.curve.offset(Compiler.curve.const(5), 3)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "const" and opt.value == 8,
        "Expected const(8), got op=" .. tostring(opt.op) .. " value=" .. tostring(opt.value))
end)

print("\n=== DCE: Negation Operations ===\n")

test("neg(const(5)) -> const(-5)", function()
    local ir = Compiler.curve.neg(Compiler.curve.const(5))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "const" and opt.value == -5,
        "Expected const(-5), got op=" .. tostring(opt.op) .. " value=" .. tostring(opt.value))
end)

test("neg(neg(x)) -> x", function()
    local ir = Compiler.curve.neg(Compiler.curve.neg(Compiler.curve.sin(1, 1)))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin",
        "Expected sin (double negation removed), got op=" .. tostring(opt.op))
end)

print("\n=== DCE: Absolute Value Operations ===\n")

test("abs(const(-5)) -> const(5)", function()
    local ir = Compiler.curve.abs(Compiler.curve.const(-5))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "const" and opt.value == 5,
        "Expected const(5), got op=" .. tostring(opt.op) .. " value=" .. tostring(opt.value))
end)

print("\n=== DCE: Power Operations ===\n")

test("pow(const(2), 3) -> const(8)", function()
    local ir = Compiler.curve.pow(Compiler.curve.const(2), 3)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "const" and opt.value == 8,
        "Expected const(8), got op=" .. tostring(opt.op) .. " value=" .. tostring(opt.value))
end)

test("pow(x, 1) -> x", function()
    local ir = Compiler.curve.pow(Compiler.curve.sin(1, 1), 1)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin",
        "Expected sin, got op=" .. tostring(opt.op))
end)

test("pow(x, 0) -> const(1)", function()
    local ir = Compiler.curve.pow(Compiler.curve.sin(1, 1), 0)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "const" and opt.value == 1,
        "Expected const(1), got op=" .. tostring(opt.op))
end)

print("\n=== DCE: Add Operations ===\n")

test("add(const(2), const(3)) -> const(5)", function()
    local ir = Compiler.curve.add(Compiler.curve.const(2), Compiler.curve.const(3))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "const" and opt.value == 5,
        "Expected const(5), got op=" .. tostring(opt.op))
end)

test("add(x, const(0)) -> x", function()
    local ir = Compiler.curve.add(Compiler.curve.sin(1, 1), Compiler.curve.const(0))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin",
        "Expected sin (removed +0), got op=" .. tostring(opt.op))
end)

test("add(const(0), x) -> x", function()
    local ir = Compiler.curve.add(Compiler.curve.const(0), Compiler.curve.sin(1, 1))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin",
        "Expected sin (removed 0+), got op=" .. tostring(opt.op))
end)

test("add(const(2), x, const(3)) -> add(x, const(5))", function()
    local ir = Compiler.curve.add(
        Compiler.curve.const(2),
        Compiler.curve.sin(1, 1),
        Compiler.curve.const(3)
    )
    local opt = Compiler.optimize(ir)
    assert(opt.op == "add" and #opt.children == 2,
        "Expected add with 2 children (constants merged)")
    
    -- Find the constant child
    local hasConst5 = false
    for _, c in ipairs(opt.children) do
        if c.op == "const" and c.value == 5 then
            hasConst5 = true
        end
    end
    assert(hasConst5, "Expected merged constant 5")
end)

print("\n=== DCE: Mul Operations ===\n")

test("mul(const(2), const(3)) -> const(6)", function()
    local ir = Compiler.curve.mul(Compiler.curve.const(2), Compiler.curve.const(3))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "const" and opt.value == 6,
        "Expected const(6), got op=" .. tostring(opt.op))
end)

test("mul(x, const(0)) -> const(0)", function()
    local ir = Compiler.curve.mul(Compiler.curve.sin(1, 1), Compiler.curve.const(0))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "const" and opt.value == 0,
        "Expected const(0) (multiplication by zero), got op=" .. tostring(opt.op))
end)

test("mul(x, const(1)) -> x", function()
    local ir = Compiler.curve.mul(Compiler.curve.sin(1, 1), Compiler.curve.const(1))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin",
        "Expected sin (removed *1), got op=" .. tostring(opt.op))
end)

test("mul(const(2), x, const(3)) -> mul(x, const(6))", function()
    local ir = Compiler.curve.mul(
        Compiler.curve.const(2),
        Compiler.curve.sin(1, 1),
        Compiler.curve.const(3)
    )
    local opt = Compiler.optimize(ir)
    assert(opt.op == "mul" and #opt.children == 2,
        "Expected mul with 2 children (constants merged)")
end)

print("\n=== DCE: Sub Operations ===\n")

test("sub(const(10), const(3)) -> const(7)", function()
    local ir = Compiler.curve.sub(Compiler.curve.const(10), Compiler.curve.const(3))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "const" and opt.value == 7,
        "Expected const(7), got op=" .. tostring(opt.op))
end)

test("sub(x, const(0)) -> x", function()
    local ir = Compiler.curve.sub(Compiler.curve.sin(1, 1), Compiler.curve.const(0))
    local opt = Compiler.optimize(ir)
    assert(opt.op == "sin",
        "Expected sin (removed -0), got op=" .. tostring(opt.op))
end)

print("\n=== DCE: Motion Operations ===\n")

test("motionScale(motion, 0) -> zero motion", function()
    local ir = Compiler.motion.scale(Compiler.motion.circle(100, 1), 0)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "xy",
        "Expected xy (zeroed motion), got op=" .. tostring(opt.op))
    assert(opt.x.op == "const" and opt.x.value == 0,
        "Expected x to be const(0)")
    assert(opt.y.op == "const" and opt.y.value == 0,
        "Expected y to be const(0)")
end)

test("motionScale(motion, 1) -> motion", function()
    local ir = Compiler.motion.scale(Compiler.motion.circle(100, 1), 1)
    local opt = Compiler.optimize(ir)
    assert(opt.op == "xy",
        "Expected xy (original motion), got op=" .. tostring(opt.op))
end)

print("\n=== DCE: Nested Optimizations ===\n")

test("nested: scale(offset(const(5), 3), 2) -> const(16)", function()
    local ir = Compiler.curve.scale(
        Compiler.curve.offset(Compiler.curve.const(5), 3),
        2
    )
    local opt = Compiler.optimize(ir)
    assert(opt.op == "const" and opt.value == 16,
        "Expected const(16), got op=" .. tostring(opt.op) .. " value=" .. tostring(opt.value))
end)

test("nested: add(scale(const(2), 3), const(4)) -> const(10)", function()
    local ir = Compiler.curve.add(
        Compiler.curve.scale(Compiler.curve.const(2), 3),
        Compiler.curve.const(4)
    )
    local opt = Compiler.optimize(ir)
    assert(opt.op == "const" and opt.value == 10,
        "Expected const(10), got op=" .. tostring(opt.op) .. " value=" .. tostring(opt.value))
end)

print("\n=== DCE: Correctness Verification ===\n")

test("optimized circle produces same results", function()
    local ir = Compiler.motion.circle(100, 2)
    local unopt = Compiler.compile(ir)
    local opt = Compiler.compileOptimized(ir)
    
    for i = 0, 10 do
        local t = i * 0.1
        local ux, uy = unopt(t, {})
        local ox, oy = opt(t, {})
        assert(approxEq(ux, ox) and approxEq(uy, oy),
            string.format("Mismatch at t=%s", t))
    end
end)

test("optimized complex expression produces same results", function()
    -- A complex expression with many optimization opportunities
    local ir = Compiler.curve.add(
        Compiler.curve.scale(Compiler.curve.sin(1, 1), 2),
        Compiler.curve.offset(Compiler.curve.const(0), 5),  -- should become const(5)
        Compiler.curve.mul(
            Compiler.curve.cos(1, 1),
            Compiler.curve.const(1)  -- should be eliminated
        )
    )
    
    local unopt = Compiler.compile(ir)
    local opt = Compiler.compileOptimized(ir)
    
    for i = 0, 10 do
        local t = i * 0.1
        local uv = unopt(t, {})
        local ov = opt(t, {})
        assert(approxEq(uv, ov),
            string.format("Mismatch at t=%s: unopt=%s opt=%s", t, uv, ov))
    end
end)

print("\n=== DCE: Generated Code Comparison ===\n")

print("--- Before optimization: scale(add(const(5), const(3)), 2) ---")
local ir1 = Compiler.curve.scale(
    Compiler.curve.add(Compiler.curve.const(5), Compiler.curve.const(3)),
    2
)
print("Unoptimized IR: op=" .. ir1.op)
print(Compiler.toSource(ir1))

print("\n--- After optimization ---")
local opt1 = Compiler.optimize(ir1)
print("Optimized IR: op=" .. opt1.op .. " value=" .. tostring(opt1.value))
print(Compiler.toSource(opt1))

print("\n--- Complex: mul(sin, const(1)) + offset(const(0), 10) ---")
local ir2 = Compiler.curve.add(
    Compiler.curve.mul(Compiler.curve.sin(1, 50), Compiler.curve.const(1)),
    Compiler.curve.offset(Compiler.curve.const(0), 10)
)
print("Before:")
print(Compiler.toSource(ir2))
print("\nAfter:")
print(Compiler.toSource(Compiler.optimize(ir2)))

print("\n=== All DCE tests complete ===\n")

Support.finish()
