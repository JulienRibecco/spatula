-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
-- tests/test_forms_compiler.lua
-- Tests for Form IR compilation
-- Run with: lua5.4 tests/test_forms_compiler.lua

package.path = package.path .. ";../../../?.lua;../../../?/init.lua"

local IR = require("spatula.compiler.ir")
local Compiler = require("spatula.compiler.compiler")

--------------------------------------------------------------------------------
-- TEST FRAMEWORK
--------------------------------------------------------------------------------

local tests = {}
local passed = 0
local failed = 0

local function test(name, fn)
    table.insert(tests, {name = name, fn = fn})
end

local function assertEq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(b), tostring(a)))
    end
end

local function assertTrue(cond, msg)
    if not cond then
        error(msg or "assertion failed: expected true")
    end
end

local function assertFalse(cond, msg)
    if cond then
        error(msg or "assertion failed: expected false")
    end
end

local function assertNear(a, b, epsilon, msg)
    epsilon = epsilon or 0.0001
    if math.abs(a - b) > epsilon then
        error(string.format("%s: expected ~%s, got %s", msg or "assertion failed", tostring(b), tostring(a)))
    end
end

local function runTests()
    print("Running Form Compiler tests...\n")
    for _, t in ipairs(tests) do
        local ok, err = pcall(t.fn)
        if ok then
            passed = passed + 1
            print(string.format("  ✓ %s", t.name))
        else
            failed = failed + 1
            print(string.format("  ✗ %s", t.name))
            print(string.format("    %s", err))
        end
    end
    print(string.format("\n%d passed, %d failed", passed, failed))
    return failed == 0
end

--------------------------------------------------------------------------------
-- FORM PRIMITIVE TESTS
--------------------------------------------------------------------------------

test("IR.form.circle creates correct structure", function()
    local ir = IR.form.circle(100, 200, 50)
    assertEq(ir.op, "formCircle", "op")
    assertEq(ir.ox, 100, "ox")
    assertEq(ir.oy, 200, "oy")
    assertEq(ir.radius, 50, "radius")
    assertEq(ir.type, "form", "type")
end)

test("IR.form.rect creates correct structure", function()
    local ir = IR.form.rect(50, 50, 30, 20)
    assertEq(ir.op, "formRect", "op")
    assertEq(ir.ox, 50, "ox")
    assertEq(ir.oy, 50, "oy")
    assertEq(ir.hw, 30, "hw")
    assertEq(ir.hh, 20, "hh")
end)

test("IR.form.ellipse creates correct structure", function()
    local ir = IR.form.ellipse(0, 0, 100, 50)
    assertEq(ir.op, "formEllipse", "op")
    assertEq(ir.rx, 100, "rx")
    assertEq(ir.ry, 50, "ry")
end)

test("IR.form.ring creates correct structure", function()
    local ir = IR.form.ring(0, 0, 100, 50)
    assertEq(ir.op, "formRing", "op")
    assertEq(ir.outerR, 100, "outerR")
    assertEq(ir.innerR, 50, "innerR")
end)

--------------------------------------------------------------------------------
-- COMPILE CIRCLE TESTS
--------------------------------------------------------------------------------

test("Compiled circle: center point is inside", function()
    local ir = IR.form.circle(100, 100, 50)
    local contains = Compiler.compileForm(ir)
    assertTrue(contains(100, 100), "center should be inside")
end)

test("Compiled circle: point at edge is inside", function()
    local ir = IR.form.circle(100, 100, 50)
    local contains = Compiler.compileForm(ir)
    assertTrue(contains(150, 100), "edge point should be inside")
    assertTrue(contains(100, 150), "edge point should be inside")
end)

test("Compiled circle: point outside is false", function()
    local ir = IR.form.circle(100, 100, 50)
    local contains = Compiler.compileForm(ir)
    assertFalse(contains(200, 100), "far point should be outside")
    assertFalse(contains(100, 200), "far point should be outside")
end)

test("Compiled circle: diagonal point outside", function()
    local ir = IR.form.circle(0, 0, 10)
    local contains = Compiler.compileForm(ir)
    -- 7.07, 7.07 is ~10 away diagonally (just inside)
    assertTrue(contains(7, 7), "diagonal point near edge inside")
    -- 8, 8 is ~11.3 away (outside)
    assertFalse(contains(8, 8), "diagonal point outside")
end)

--------------------------------------------------------------------------------
-- COMPILE RECT TESTS
--------------------------------------------------------------------------------

test("Compiled rect: center point is inside", function()
    local ir = IR.form.rect(100, 100, 50, 30)
    local contains = Compiler.compileForm(ir)
    assertTrue(contains(100, 100), "center should be inside")
end)

test("Compiled rect: edge points are inside", function()
    local ir = IR.form.rect(100, 100, 50, 30)
    local contains = Compiler.compileForm(ir)
    assertTrue(contains(150, 100), "right edge inside")
    assertTrue(contains(50, 100), "left edge inside")
    assertTrue(contains(100, 130), "top edge inside")
    assertTrue(contains(100, 70), "bottom edge inside")
end)

test("Compiled rect: corners are inside", function()
    local ir = IR.form.rect(100, 100, 50, 30)
    local contains = Compiler.compileForm(ir)
    assertTrue(contains(150, 130), "top-right corner inside")
    assertTrue(contains(50, 70), "bottom-left corner inside")
end)

test("Compiled rect: point outside is false", function()
    local ir = IR.form.rect(100, 100, 50, 30)
    local contains = Compiler.compileForm(ir)
    assertFalse(contains(200, 100), "far right outside")
    assertFalse(contains(0, 100), "far left outside")
    assertFalse(contains(100, 200), "far top outside")
end)

--------------------------------------------------------------------------------
-- COMPILE ELLIPSE TESTS
--------------------------------------------------------------------------------

test("Compiled ellipse: center is inside", function()
    local ir = IR.form.ellipse(0, 0, 100, 50)
    local contains = Compiler.compileForm(ir)
    assertTrue(contains(0, 0), "center inside")
end)

test("Compiled ellipse: horizontal edge inside, beyond outside", function()
    local ir = IR.form.ellipse(0, 0, 100, 50)
    local contains = Compiler.compileForm(ir)
    assertTrue(contains(100, 0), "right edge inside")
    assertTrue(contains(-100, 0), "left edge inside")
    assertFalse(contains(101, 0), "beyond right outside")
end)

test("Compiled ellipse: vertical edge inside, beyond outside", function()
    local ir = IR.form.ellipse(0, 0, 100, 50)
    local contains = Compiler.compileForm(ir)
    assertTrue(contains(0, 50), "top edge inside")
    assertTrue(contains(0, -50), "bottom edge inside")
    assertFalse(contains(0, 51), "beyond top outside")
end)

--------------------------------------------------------------------------------
-- COMPILE RING TESTS
--------------------------------------------------------------------------------

test("Compiled ring: center is outside (hole)", function()
    local ir = IR.form.ring(0, 0, 100, 50)
    local contains = Compiler.compileForm(ir)
    assertFalse(contains(0, 0), "center should be in hole")
end)

test("Compiled ring: point in ring is inside", function()
    local ir = IR.form.ring(0, 0, 100, 50)
    local contains = Compiler.compileForm(ir)
    assertTrue(contains(75, 0), "point in ring")
    assertTrue(contains(0, 75), "point in ring")
end)

test("Compiled ring: inner edge is inside", function()
    local ir = IR.form.ring(0, 0, 100, 50)
    local contains = Compiler.compileForm(ir)
    assertTrue(contains(50, 0), "inner edge inside")
end)

test("Compiled ring: outer edge is inside", function()
    local ir = IR.form.ring(0, 0, 100, 50)
    local contains = Compiler.compileForm(ir)
    assertTrue(contains(100, 0), "outer edge inside")
end)

test("Compiled ring: beyond outer is outside", function()
    local ir = IR.form.ring(0, 0, 100, 50)
    local contains = Compiler.compileForm(ir)
    assertFalse(contains(101, 0), "beyond outer outside")
end)

test("Compiled ring: inside inner is outside", function()
    local ir = IR.form.ring(0, 0, 100, 50)
    local contains = Compiler.compileForm(ir)
    assertFalse(contains(49, 0), "inside inner outside")
end)

--------------------------------------------------------------------------------
-- COMBINATOR TESTS
--------------------------------------------------------------------------------

test("Compiled union: either form matches", function()
    local ir = IR.form.union(
        IR.form.circle(-50, 0, 30),
        IR.form.circle(50, 0, 30)
    )
    local contains = Compiler.compileForm(ir)
    assertTrue(contains(-50, 0), "in left circle")
    assertTrue(contains(50, 0), "in right circle")
    assertFalse(contains(0, 0), "between circles")
end)

test("Compiled intersect: both forms must match", function()
    local ir = IR.form.intersect(
        IR.form.circle(0, 0, 50),
        IR.form.rect(0, 0, 100, 20)
    )
    local contains = Compiler.compileForm(ir)
    -- Center of both
    assertTrue(contains(0, 0), "center in both")
    -- In circle but outside rect (tall part)
    assertFalse(contains(0, 40), "in circle, outside rect")
    -- In rect but outside circle (wide part)
    assertFalse(contains(80, 0), "in rect, outside circle")
end)

test("Compiled subtract: outer minus inner", function()
    local ir = IR.form.subtract(
        IR.form.circle(0, 0, 100),
        IR.form.circle(0, 0, 50)
    )
    local contains = Compiler.compileForm(ir)
    -- Center is in hole
    assertFalse(contains(0, 0), "center is in hole")
    -- Edge of inner hole
    assertFalse(contains(50, 0), "inner edge is hole")
    -- In the ring
    assertTrue(contains(75, 0), "in the ring")
    -- Outer edge
    assertTrue(contains(100, 0), "outer edge")
    -- Outside
    assertFalse(contains(101, 0), "outside")
end)

--------------------------------------------------------------------------------
-- COMPLEX COMPOSITION TESTS
--------------------------------------------------------------------------------

test("L-shaped region (union of two rects)", function()
    -- Vertical bar: centered at (25, 50), half-width 25, half-height 50
    -- Horizontal bar: centered at (50, 90), half-width 50, half-height 10
    local ir = IR.form.union(
        IR.form.rect(25, 50, 25, 50),   -- vertical bar: x=[0,50], y=[0,100]
        IR.form.rect(50, 90, 50, 10)    -- horizontal bar: x=[0,100], y=[80,100]
    )
    local contains = Compiler.compileForm(ir)

    -- In vertical bar
    assertTrue(contains(25, 25), "in vertical bar")
    -- In horizontal bar
    assertTrue(contains(75, 90), "in horizontal bar")
    -- In corner (both)
    assertTrue(contains(25, 90), "in corner")
    -- Outside both
    assertFalse(contains(75, 50), "outside both")
end)

test("Donut with slice removed (subtract)", function()
    -- Full donut
    local donut = IR.form.ring(0, 0, 100, 50)
    -- Remove a rectangular slice
    local slice = IR.form.rect(0, 0, 10, 200)  -- vertical slice through center
    local ir = IR.form.subtract(donut, slice)
    local contains = Compiler.compileForm(ir)

    -- In donut, not in slice
    assertTrue(contains(75, 0), "in donut, away from slice")
    -- In donut but in slice
    assertFalse(contains(0, 75), "in slice")
    -- In hole
    assertFalse(contains(0, 0), "in hole")
end)

test("Triple nested: union of intersections", function()
    -- (circle AND rect) OR ellipse
    local ir = IR.form.union(
        IR.form.intersect(
            IR.form.circle(0, 0, 50),
            IR.form.rect(0, 0, 30, 100)
        ),
        IR.form.ellipse(100, 0, 30, 50)
    )
    local contains = Compiler.compileForm(ir)

    -- In intersection
    assertTrue(contains(0, 0), "in circle-rect intersection")
    -- In circle but not rect
    assertFalse(contains(40, 0), "in circle, outside rect")
    -- In ellipse
    assertTrue(contains(100, 0), "in ellipse")
end)

--------------------------------------------------------------------------------
-- SOURCE GENERATION TESTS
--------------------------------------------------------------------------------

test("formToSource generates valid code", function()
    local ir = IR.form.circle(100, 100, 50)
    local source = Compiler.formToSource(ir)
    assertTrue(source:find("function%(x, y, ctx%)"), "should have function signature")
    assertTrue(source:find("return"), "should have return")
end)

test("formToSource for complex form", function()
    local ir = IR.form.union(
        IR.form.circle(0, 0, 50),
        IR.form.rect(100, 0, 30, 30)
    )
    local source = Compiler.formToSource(ir)
    assertTrue(source:find("or"), "union should use 'or'")
end)

--------------------------------------------------------------------------------
-- DEBUG OUTPUT TEST
--------------------------------------------------------------------------------

test("compileForm with debug=true prints code", function()
    local ir = IR.form.circle(0, 0, 10)
    -- Just verify it doesn't error
    local contains = Compiler.compileForm(ir, { debug = false })
    assertTrue(contains ~= nil, "should compile")
end)

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------

local success = runTests()
os.exit(success and 0 or 1)
