-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for Rotator Module
-- Path adjustment for tests subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Run with: lua test_rotator_module.lua

local Rotator = require("spatula.compiler.strategies.incremental_rotator")

local function approxEq(a, b, eps)
    eps = eps or 0.001
    return math.abs(a - b) < eps
end

local Support = require("tests.support")
local test = Support.test
local benchmark = Support.benchmark

print("\n=== Rotator Module: Analysis ===\n")

test("analyze circle motion", function()
    local ir = {
        type = "motion",
        op = "xy",
        x = { op = "cos", freq = 1, amp = 100 },
        y = { op = "sin", freq = 1, amp = 100 }
    }
    
    local result = Rotator.analyze(ir)
    
    assert(result.canStep, "Should be steppable")
    assert(result.type == "circle", "Should be circle type")
    assert(result.params.freq == 1, "Should have freq 1")
    assert(result.params.radiusX == 100, "Should have radiusX 100")
end)

test("analyze hover motion", function()
    local ir = {
        type = "motion",
        op = "xy",
        x = { op = "const", value = 0 },
        y = { op = "sin", freq = 2, amp = 10 }
    }
    
    local result = Rotator.analyze(ir)
    
    assert(result.canStep, "Should be steppable")
    assert(result.type == "hover", "Should be hover type")
end)

test("analyze drift motion", function()
    local ir = {
        type = "motion",
        op = "xy",
        x = { op = "linear", speed = 10 },
        y = { op = "linear", speed = -5 }
    }
    
    local result = Rotator.analyze(ir)
    
    assert(result.canStep, "Should be steppable")
    assert(result.type == "drift", "Should be drift type")
end)

test("analyze sin curve", function()
    local ir = { op = "sin", freq = 2, amp = 50 }
    
    local result = Rotator.analyze(ir)
    
    assert(result.canStep, "Should be steppable")
    assert(result.type == "sinCurve", "Should be sinCurve type")
end)

test("reject stateful with hasStatefulNodes", function()
    local ir = {
        type = "motion",
        op = "xy",
        x = { op = "follow", target = {}, speed = 1 },
        y = { op = "const", value = 0 }
    }
    
    local function hasStateful(node)
        if not node then return false end
        if node.op == "follow" or node.op == "spring" then return true end
        for k, v in pairs(node) do
            if type(v) == "table" and hasStateful(v) then return true end
        end
        return false
    end
    
    local result = Rotator.analyze(ir, hasStateful)
    
    assert(not result.canStep, "Should not be steppable")
    assert(result.reason:match("stateful"), "Should mention stateful")
end)

print("\n=== Rotator Module: Circle ===\n")

test("circle rotator init", function()
    local rotator = Rotator.createCircle({ freq = 1, radiusX = 100, radiusY = 100 }, 1/60)
    
    local state = rotator.init(0)
    
    assert(approxEq(state.x, 100), "X should start at 100")
    assert(approxEq(state.y, 0), "Y should start at 0")
end)

test("circle rotator step", function()
    local rotator = Rotator.createCircle({ freq = 1, radiusX = 100, radiusY = 100 }, 1/60)
    
    local state = rotator.init(0)
    
    -- Step 15 times = 1/4 rotation
    for _ = 1, 15 do
        rotator.step(state)
    end
    
    -- Should be near (0, 100) after 1/4 rotation
    assert(approxEq(state.x, 0, 5), "X should be near 0")
    assert(approxEq(state.y, 100, 5), "Y should be near 100")
end)

test("circle rotator full rotation", function()
    local rotator = Rotator.createCircle({ freq = 1, radiusX = 100, radiusY = 100 }, 1/60)
    
    local state = rotator.init(0)
    local startX, startY = state.x, state.y
    
    -- 60 steps = 1 full rotation
    for _ = 1, 60 do
        rotator.step(state)
    end
    
    assert(approxEq(state.x, startX, 0.1), "X should return to start")
    assert(approxEq(state.y, startY, 0.1), "Y should return to start")
end)

test("circle rotator batch", function()
    local rotator = Rotator.createCircle({ freq = 1, radiusX = 100, radiusY = 100 }, 1/60)
    
    local states = {}
    for i = 1, 10 do
        states[i] = rotator.init((i - 1) / 10)
    end
    
    rotator.stepBatch(states, 10)
    
    -- All should have moved
    assert(not approxEq(states[1].x, 100), "State 1 should have moved")
end)

print("\n=== Rotator Module: Other Types ===\n")

test("hover rotator", function()
    local rotator = Rotator.createHover({ freq = 1, amplitude = 10 }, 1/60)
    
    local state = rotator.init(0)
    
    assert(approxEq(state.x, 0), "X should always be 0")
    assert(approxEq(state.y, 0), "Y should start at 0")
    
    for _ = 1, 15 do
        rotator.step(state)
    end
    
    assert(approxEq(state.x, 0), "X should still be 0")
    assert(approxEq(state.y, 10, 1), "Y should be near 10 (peak)")
end)

test("drift rotator", function()
    local rotator = Rotator.createDrift({ vx = 60, vy = 30 }, 1/60)
    
    local state = rotator.init(0)
    
    for _ = 1, 60 do
        rotator.step(state)
    end
    
    assert(approxEq(state.x, 60, 0.1), "X should be 60 after 1 sec")
    assert(approxEq(state.y, 30, 0.1), "Y should be 30 after 1 sec")
end)

test("sin curve rotator", function()
    local rotator = Rotator.createSinCurve({ freq = 1, amplitude = 1 }, 1/60)
    
    local state = rotator.init(0)
    
    assert(approxEq(state.value, 0), "Should start at 0")
    
    for _ = 1, 15 do
        rotator.step(state)
    end
    
    assert(approxEq(state.value, 1, 0.1), "Should be near 1 at 1/4")
end)

print("\n=== Rotator Module: Compile ===\n")

test("compile circle motion", function()
    local ir = {
        type = "motion",
        op = "xy",
        x = { op = "cos", freq = 2, amp = 50 },
        y = { op = "sin", freq = 2, amp = 50 }
    }
    
    local rotator = Rotator.compile(ir, { dt = 1/60 })
    
    assert(rotator, "Should compile")
    assert(rotator.type == "circle", "Should be circle type")
end)

test("compile returns nil for unsupported", function()
    local ir = {
        type = "motion",
        op = "complex",
        data = {}
    }
    
    local rotator = Rotator.compile(ir, { dt = 1/60 })
    
    assert(rotator == nil, "Should return nil")
end)

test("createStates helper", function()
    local rotator = Rotator.createCircle({ freq = 1, radiusX = 100, radiusY = 100 }, 1/60)
    
    local phases = { 0, 0.25, 0.5, 0.75 }
    local states = Rotator.createStates(rotator, 4, phases)
    
    assert(#states == 4, "Should have 4 states")
    assert(approxEq(states[1].x, 100), "State 1 at phase 0")
    assert(approxEq(states[2].y, 100, 1), "State 2 at phase 0.25")
    assert(approxEq(states[3].x, -100, 1), "State 3 at phase 0.5")
end)

print("\n=== All Rotator Module tests complete ===\n")

Support.finish()
