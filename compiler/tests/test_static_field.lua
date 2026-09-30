-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
-- tests/test_static_field.lua
-- Tests for StaticField compilation
-- Run with: lua5.4 tests/test_static_field.lua

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

local function assertApprox(a, b, epsilon, msg)
    epsilon = epsilon or 0.001
    if math.abs(a - b) > epsilon then
        error(string.format("%s: expected ~%s, got %s (diff: %s)",
            msg or "assertion failed", tostring(b), tostring(a), tostring(math.abs(a - b))))
    end
end

local function runTests()
    print("Running StaticField tests...\n")
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
-- IR CREATION TESTS
--------------------------------------------------------------------------------

test("IR.falloff constructors create valid IR", function()
    local linear = IR.falloff.linear()
    assertEq(linear.op, "falloffLinear", "linear op")
    assertEq(linear.type, "falloff", "linear type")

    local smooth = IR.falloff.smooth()
    assertEq(smooth.op, "falloffSmooth", "smooth op")

    local spike = IR.falloff.spike()
    assertEq(spike.op, "falloffSpike", "spike op")

    local gaussian = IR.falloff.gaussian(5)
    assertEq(gaussian.op, "falloffGaussian", "gaussian op")
    assertEq(gaussian.k, 5, "gaussian k")

    local step = IR.falloff.step(0.3)
    assertEq(step.op, "falloffStep", "step op")
    assertEq(step.threshold, 0.3, "step threshold")

    local power = IR.falloff.power(3)
    assertEq(power.op, "falloffPower", "power op")
    assertEq(power.n, 3, "power n")
end)

test("IR.field.static creates valid IR", function()
    local fieldIR = IR.field.static({
        sources = {
            { x = 100, y = 100, radius = 50, value = 1, falloff = IR.falloff.smooth() }
        },
        blend = "add",
        base = 0
    })

    assertEq(fieldIR.op, "fieldStatic", "op")
    assertEq(fieldIR.type, "field", "type")
    assertEq(#fieldIR.sources, 1, "source count")
    assertEq(fieldIR.blend, "add", "blend")
    assertEq(fieldIR.base, 0, "base")
end)

test("IR.field.static uses defaults", function()
    local fieldIR = IR.field.static({})

    assertEq(#fieldIR.sources, 0, "empty sources")
    assertEq(fieldIR.blend, "add", "default blend")
    assertEq(fieldIR.base, 0, "default base")
end)

--------------------------------------------------------------------------------
-- COMPILATION TESTS
--------------------------------------------------------------------------------

test("compileStaticField returns function", function()
    local fieldIR = IR.field.static({
        sources = {
            { x = 0, y = 0, radius = 100, value = 1, falloff = IR.falloff.smooth() }
        }
    })

    local fn = Compiler.compileStaticField(fieldIR)
    assertTrue(type(fn) == "function", "should return function")
end)

test("compileStaticField errors on wrong IR type", function()
    local curveIR = IR.curve.const(1)

    local ok, err = pcall(Compiler.compileStaticField, curveIR)
    assertFalse(ok, "should error on wrong IR type")
end)

test("compiled field returns base outside sources", function()
    local fieldIR = IR.field.static({
        sources = {
            { x = 0, y = 0, radius = 50, value = 1, falloff = IR.falloff.smooth() }
        },
        base = 0.5
    })

    local fn = Compiler.compileStaticField(fieldIR)

    local value = fn(1000, 1000)  -- Far from source
    assertEq(value, 0.5, "should return base value")
end)

test("compiled field returns max at source center", function()
    local fieldIR = IR.field.static({
        sources = {
            { x = 100, y = 100, radius = 50, value = 2, falloff = IR.falloff.smooth() }
        },
        base = 0
    })

    local fn = Compiler.compileStaticField(fieldIR)

    local value = fn(100, 100)  -- At center
    assertApprox(value, 2, 0.001, "should return value at center")
end)

test("compiled field uses falloff", function()
    local fieldIR = IR.field.static({
        sources = {
            { x = 0, y = 0, radius = 100, value = 1, falloff = IR.falloff.linear() }
        },
        base = 0
    })

    local fn = Compiler.compileStaticField(fieldIR)

    -- At center: linear falloff = (1 - 0) * value = 1
    assertApprox(fn(0, 0), 1, 0.001, "center value")

    -- At 50% radius: linear falloff = (1 - 0.5) * value = 0.5
    assertApprox(fn(50, 0), 0.5, 0.001, "50% radius value")

    -- At edge: linear falloff = (1 - 1) * value = 0 (but we're outside)
    -- Actually at 99% to be inside
    assertApprox(fn(99, 0), 0.01, 0.01, "near edge value")
end)

--------------------------------------------------------------------------------
-- FALLOFF TESTS
--------------------------------------------------------------------------------

test("linear falloff", function()
    local fieldIR = IR.field.static({
        sources = {{ x = 0, y = 0, radius = 100, value = 1, falloff = IR.falloff.linear() }}
    })
    local fn = Compiler.compileStaticField(fieldIR)

    assertApprox(fn(0, 0), 1, 0.001, "center")
    assertApprox(fn(50, 0), 0.5, 0.001, "50%")
    assertApprox(fn(75, 0), 0.25, 0.001, "75%")
end)

test("smooth falloff", function()
    local fieldIR = IR.field.static({
        sources = {{ x = 0, y = 0, radius = 100, value = 1, falloff = IR.falloff.smooth() }}
    })
    local fn = Compiler.compileStaticField(fieldIR)

    assertApprox(fn(0, 0), 1, 0.001, "center")
    -- At 50%: (1 - 0.5)^2 = 0.25
    assertApprox(fn(50, 0), 0.25, 0.001, "50%")
end)

test("spike falloff", function()
    local fieldIR = IR.field.static({
        sources = {{ x = 0, y = 0, radius = 100, value = 1, falloff = IR.falloff.spike() }}
    })
    local fn = Compiler.compileStaticField(fieldIR)

    assertApprox(fn(0, 0), 1, 0.001, "center")
    -- At 50%: (1 - 0.5)^4 = 0.0625
    assertApprox(fn(50, 0), 0.0625, 0.001, "50%")
end)

test("constant falloff", function()
    local fieldIR = IR.field.static({
        sources = {{ x = 0, y = 0, radius = 100, value = 1, falloff = IR.falloff.constant() }}
    })
    local fn = Compiler.compileStaticField(fieldIR)

    -- Constant is always 1 * value within radius
    assertApprox(fn(0, 0), 1, 0.001, "center")
    assertApprox(fn(50, 0), 1, 0.001, "50%")
    assertApprox(fn(99, 0), 1, 0.001, "99%")
end)

test("gaussian falloff", function()
    local fieldIR = IR.field.static({
        sources = {{ x = 0, y = 0, radius = 100, value = 1, falloff = IR.falloff.gaussian(3) }}
    })
    local fn = Compiler.compileStaticField(fieldIR)

    assertApprox(fn(0, 0), 1, 0.001, "center (e^0 = 1)")
    -- At 50%: e^(-3 * 0.25) = e^-0.75 ≈ 0.472
    assertApprox(fn(50, 0), math.exp(-0.75), 0.001, "50%")
end)

test("step falloff", function()
    local fieldIR = IR.field.static({
        sources = {{ x = 0, y = 0, radius = 100, value = 1, falloff = IR.falloff.step(0.5) }}
    })
    local fn = Compiler.compileStaticField(fieldIR)

    assertApprox(fn(0, 0), 1, 0.001, "inside step")
    assertApprox(fn(49, 0), 1, 0.001, "just inside step")
    assertApprox(fn(51, 0), 0, 0.001, "just outside step")
    assertApprox(fn(99, 0), 0, 0.001, "outside step")
end)

test("power falloff", function()
    local fieldIR = IR.field.static({
        sources = {{ x = 0, y = 0, radius = 100, value = 1, falloff = IR.falloff.power(3) }}
    })
    local fn = Compiler.compileStaticField(fieldIR)

    assertApprox(fn(0, 0), 1, 0.001, "center")
    -- At 50%: (1 - 0.5)^3 = 0.125
    assertApprox(fn(50, 0), 0.125, 0.001, "50%")
end)

test("inverse falloff", function()
    local fieldIR = IR.field.static({
        sources = {{ x = 0, y = 0, radius = 100, value = 1, falloff = IR.falloff.inverse() }}
    })
    local fn = Compiler.compileStaticField(fieldIR)

    -- Inverse = d (grows outward)
    assertApprox(fn(0, 0), 0, 0.001, "center")
    assertApprox(fn(50, 0), 0.5, 0.001, "50%")
end)

test("ring falloff", function()
    local fieldIR = IR.field.static({
        sources = {{ x = 0, y = 0, radius = 100, value = 1, falloff = IR.falloff.ring() }}
    })
    local fn = Compiler.compileStaticField(fieldIR)

    -- Ring = sin(d * pi), peaks at d=0.5
    assertApprox(fn(0, 0), 0, 0.001, "center (sin 0)")
    assertApprox(fn(50, 0), 1, 0.001, "50% (sin pi/2)")
end)

--------------------------------------------------------------------------------
-- MULTIPLE SOURCE TESTS
--------------------------------------------------------------------------------

test("multiple sources blend with add", function()
    local fieldIR = IR.field.static({
        sources = {
            { x = 0, y = 0, radius = 100, value = 0.5, falloff = IR.falloff.constant() },
            { x = 0, y = 0, radius = 100, value = 0.3, falloff = IR.falloff.constant() }
        },
        blend = "add"
    })
    local fn = Compiler.compileStaticField(fieldIR)

    assertApprox(fn(0, 0), 0.8, 0.001, "sum of values")
end)

test("multiple sources blend with max", function()
    local fieldIR = IR.field.static({
        sources = {
            { x = 0, y = 0, radius = 100, value = 0.5, falloff = IR.falloff.constant() },
            { x = 0, y = 0, radius = 100, value = 0.8, falloff = IR.falloff.constant() }
        },
        blend = "max"
    })
    local fn = Compiler.compileStaticField(fieldIR)

    assertApprox(fn(0, 0), 0.8, 0.001, "max of values")
end)

test("multiple sources blend with min", function()
    local fieldIR = IR.field.static({
        sources = {
            { x = 0, y = 0, radius = 100, value = 0.5, falloff = IR.falloff.constant() },
            { x = 50, y = 0, radius = 100, value = 0.3, falloff = IR.falloff.constant() }
        },
        blend = "min",
        base = 1  -- Start with 1, take min with each source
    })
    local fn = Compiler.compileStaticField(fieldIR)

    -- At (25, 0): within both sources
    local value = fn(25, 0)
    assertApprox(value, 0.3, 0.001, "min of values")
end)

test("sources at different positions", function()
    local fieldIR = IR.field.static({
        sources = {
            { x = 0, y = 0, radius = 50, value = 1, falloff = IR.falloff.constant() },
            { x = 200, y = 0, radius = 50, value = 2, falloff = IR.falloff.constant() }
        }
    })
    local fn = Compiler.compileStaticField(fieldIR)

    assertApprox(fn(0, 0), 1, 0.001, "first source")
    assertApprox(fn(200, 0), 2, 0.001, "second source")
    assertApprox(fn(100, 0), 0, 0.001, "between sources")
end)

--------------------------------------------------------------------------------
-- SOURCE CODE GENERATION
--------------------------------------------------------------------------------

test("staticFieldToSource generates valid Lua", function()
    local fieldIR = IR.field.static({
        sources = {
            { x = 100, y = 100, radius = 50, value = 1, falloff = IR.falloff.smooth() }
        }
    })

    local source = Compiler.staticFieldToSource(fieldIR)
    assertTrue(type(source) == "string", "should return string")
    assertTrue(source:find("function") ~= nil, "should contain function")
    assertTrue(source:find("sqrt") ~= nil, "should contain sqrt")
end)

test("staticFieldToSource output can be loaded", function()
    local fieldIR = IR.field.static({
        sources = {
            { x = 0, y = 0, radius = 100, value = 1, falloff = IR.falloff.linear() }
        }
    })

    local source = Compiler.staticFieldToSource(fieldIR)
    local fn = load(source)()

    assertApprox(fn(0, 0), 1, 0.001, "center value")
    assertApprox(fn(50, 0), 0.5, 0.001, "50% value")
end)

--------------------------------------------------------------------------------
-- EDGE CASES
--------------------------------------------------------------------------------

test("empty sources field returns base", function()
    local fieldIR = IR.field.static({
        sources = {},
        base = 0.75
    })
    local fn = Compiler.compileStaticField(fieldIR)

    assertEq(fn(0, 0), 0.75, "any point returns base")
    assertEq(fn(1000, -500), 0.75, "any point returns base")
end)

test("source with zero radius", function()
    local fieldIR = IR.field.static({
        sources = {
            { x = 0, y = 0, radius = 0.001, value = 1, falloff = IR.falloff.constant() }
        }
    })
    local fn = Compiler.compileStaticField(fieldIR)

    -- Only exact center would be inside
    assertApprox(fn(0, 0), 1, 0.001, "at center")
    assertApprox(fn(1, 0), 0, 0.001, "just outside")
end)

test("very large coordinates", function()
    local fieldIR = IR.field.static({
        sources = {
            { x = 10000, y = 10000, radius = 100, value = 1, falloff = IR.falloff.smooth() }
        }
    })
    local fn = Compiler.compileStaticField(fieldIR)

    assertApprox(fn(10000, 10000), 1, 0.001, "at center")
    assertApprox(fn(0, 0), 0, 0.001, "far away")
end)

test("negative coordinates", function()
    local fieldIR = IR.field.static({
        sources = {
            { x = -100, y = -100, radius = 50, value = 1, falloff = IR.falloff.constant() }
        }
    })
    local fn = Compiler.compileStaticField(fieldIR)

    assertApprox(fn(-100, -100), 1, 0.001, "at center")
    assertApprox(fn(0, 0), 0, 0.001, "at origin")
end)

test("negative value", function()
    local fieldIR = IR.field.static({
        sources = {
            { x = 0, y = 0, radius = 100, value = -0.5, falloff = IR.falloff.constant() }
        },
        base = 1
    })
    local fn = Compiler.compileStaticField(fieldIR)

    assertApprox(fn(0, 0), 0.5, 0.001, "base + negative value")
end)

--------------------------------------------------------------------------------
-- DEBUG MODE
--------------------------------------------------------------------------------

test("debug option prints code", function()
    local fieldIR = IR.field.static({
        sources = {
            { x = 0, y = 0, radius = 50, value = 1, falloff = IR.falloff.smooth() }
        }
    })

    -- Just check it doesn't error with debug on
    local fn = Compiler.compileStaticField(fieldIR, { debug = false })
    assertTrue(fn ~= nil, "should compile with debug")
end)

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------

local success = runTests()
os.exit(success and 0 or 1)
