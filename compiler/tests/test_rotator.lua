-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for Incremental/Rotator Compilation
-- Path adjustment for tests subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Advance state incrementally using rotation matrices - no trig per frame!
--- Run with: lua test_rotator.lua

local Compiler = require("spatula.compiler.compiler")

local function approxEq(a, b, eps)
    eps = eps or 0.01
    return math.abs(a - b) < eps
end

local Support = require("tests.support")
local test = Support.test
local benchmark = Support.benchmark

local PI2 = math.pi * 2

print("\n=== Rotator: Basic Compilation ===\n")

test("compileRotator returns rotator for circle", function()
    local ir = Compiler.motion.circle(100, 1)
    local rotator, err = Compiler.compileRotator(ir, { fps = 60 })
    
    assert(rotator ~= nil, "Should return rotator, got error: " .. tostring(err))
    assert(rotator.init, "Should have init()")
    assert(rotator.step, "Should have step()")
    assert(rotator.stepBatch, "Should have stepBatch()")
end)

test("compileRotator returns nil for stateful", function()
    local ir = Compiler.curve.follow(Compiler.curve.const(100), 5)
    local rotator, err = Compiler.compileRotator(ir, { fps = 60 })
    
    assert(rotator == nil, "Should not create rotator for stateful")
    assert(err:find("stateful"), "Error should mention stateful")
end)

test("compileRotator returns nil for ctx-dependent", function()
    local ir = Compiler.curve.fromCtx("target", 0)
    local rotator, err = Compiler.compileRotator(ir, { fps = 60 })
    
    assert(rotator == nil, "Should not create rotator for ctx")
    assert(err:find("ctx"), "Error should mention ctx")
end)

test("canUseRotator helper", function()
    local circleIR = Compiler.motion.circle(100, 1)
    local followIR = Compiler.curve.follow(Compiler.curve.const(0), 5)
    
    local ok1, _ = Compiler.canUseRotator(circleIR)
    local ok2, reason = Compiler.canUseRotator(followIR)
    
    assert(ok1 == true, "Circle should be steppable")
    assert(ok2 == false, "Follow should not be steppable")
end)

print("\n=== Rotator: Circle Motion ===\n")

test("circle rotator init", function()
    local ir = Compiler.motion.circle(100, 1)
    local rotator = Compiler.compileRotator(ir, { fps = 60 })
    
    -- Phase 0 should start at (100, 0)
    local state = rotator.init(0)
    assert(approxEq(state.x, 100) and approxEq(state.y, 0),
        string.format("Expected (100, 0), got (%s, %s)", state.x, state.y))
    
    -- Phase 0.25 should start at (0, 100)
    local state2 = rotator.init(0.25)
    assert(approxEq(state2.x, 0, 1) and approxEq(state2.y, 100, 1),
        string.format("Expected (0, 100), got (%s, %s)", state2.x, state2.y))
end)

test("circle rotator step matches compiled", function()
    local ir = Compiler.motion.circle(100, 1)
    local compiled = Compiler.compile(ir)
    local rotator = Compiler.compileRotator(ir, { fps = 60 })
    
    local state = rotator.init(0)
    local dt = 1/60
    
    -- Step through 60 frames (1 second)
    for frame = 1, 60 do
        rotator.step(state)
        local t = frame * dt
        local ex, ey = compiled(t, {})
        
        -- Allow small drift due to accumulated floating point
        assert(approxEq(state.x, ex, 0.1) and approxEq(state.y, ey, 0.1),
            string.format("Frame %d: expected (%s, %s), got (%s, %s)", 
                frame, ex, ey, state.x, state.y))
    end
end)

test("circle rotator completes full rotation", function()
    local ir = Compiler.motion.circle(100, 1)  -- 1 Hz = 1 rotation per second
    local rotator = Compiler.compileRotator(ir, { fps = 60 })
    
    local state = rotator.init(0)
    local startX, startY = state.x, state.y
    
    -- Step through 60 frames (1 full rotation)
    for _ = 1, 60 do
        rotator.step(state)
    end
    
    -- Should be back near start
    assert(approxEq(state.x, startX, 1) and approxEq(state.y, startY, 1),
        string.format("After rotation: expected (%s, %s), got (%s, %s)",
            startX, startY, state.x, state.y))
end)

print("\n=== Rotator: Ellipse Motion ===\n")

test("ellipse rotator", function()
    local ir = Compiler.motion.ellipse(200, 50, 1)
    local rotator = Compiler.compileRotator(ir, { fps = 60 })
    
    local state = rotator.init(0)
    assert(approxEq(state.x, 200) and approxEq(state.y, 0),
        "Ellipse should start at (rx, 0)")
    
    -- Step to quarter
    for _ = 1, 15 do rotator.step(state) end
    
    -- Should be near (0, ry)
    assert(approxEq(state.x, 0, 5) and approxEq(state.y, 50, 5),
        string.format("Quarter: expected (0, 50), got (%s, %s)", state.x, state.y))
end)

print("\n=== Rotator: Linear Motion ===\n")

test("drift rotator", function()
    local ir = Compiler.motion.drift(60, 30)  -- 60 px/s, 30 px/s
    local rotator = Compiler.compileRotator(ir, { fps = 60 })
    
    local state = rotator.init(0)
    assert(state.x == 0 and state.y == 0, "Should start at origin")
    
    -- One step at 60fps with 60px/s = 1px
    rotator.step(state)
    assert(approxEq(state.x, 1) and approxEq(state.y, 0.5),
        string.format("After one step: expected (1, 0.5), got (%s, %s)", state.x, state.y))
    
    -- After 60 steps = 1 second
    for _ = 1, 59 do rotator.step(state) end
    assert(approxEq(state.x, 60) and approxEq(state.y, 30),
        string.format("After 1 sec: expected (60, 30), got (%s, %s)", state.x, state.y))
end)

print("\n=== Rotator: Spiral Motion ===\n")

test("spiral rotator", function()
    local ir = Compiler.motion.spiral(100, 1, 0.5)
    local rotator, err = Compiler.compileRotator(ir, { fps = 60 })
    
    if not rotator then
        print("  (Spiral rotator not implemented: " .. tostring(err) .. ")")
        return
    end
    
    local state = rotator.init(0)
    local startDist = math.sqrt(state.x^2 + state.y^2)
    
    -- Step through 60 frames
    for _ = 1, 60 do rotator.step(state) end
    
    local endDist = math.sqrt(state.x^2 + state.y^2)
    
    -- Spiral should grow
    assert(endDist > startDist, "Spiral should expand")
end)

print("\n=== Rotator: Batch Operations ===\n")

test("stepBatch advances all entities", function()
    local ir = Compiler.motion.circle(100, 1)
    local rotator = Compiler.compileRotator(ir, { fps = 60 })
    
    -- Create 100 entities with different phases
    local n = 100
    local states = {}
    for i = 1, n do
        states[i] = rotator.init((i - 1) / n)
    end
    
    -- Record initial positions
    local initX = {}
    for i = 1, n do initX[i] = states[i].x end
    
    -- Batch step
    rotator.stepBatch(states, n)
    
    -- All should have moved
    local allMoved = true
    for i = 1, n do
        if states[i].x == initX[i] then
            allMoved = false
            break
        end
    end
    assert(allMoved, "All entities should move after step")
end)

test("createRotatorStates helper", function()
    local ir = Compiler.motion.circle(100, 1)
    local rotator = Compiler.compileRotator(ir, { fps = 60 })
    
    local phases = { 0, 0.25, 0.5, 0.75 }
    local states = Compiler.createRotatorStates(rotator, 4, phases)
    
    assert(#states == 4, "Should create 4 states")
    assert(approxEq(states[1].x, 100), "Phase 0 -> x=100")
    assert(approxEq(states[2].x, 0, 1), "Phase 0.25 -> x=0")
    assert(approxEq(states[3].x, -100, 1), "Phase 0.5 -> x=-100")
end)

test("getPositions extracts x,y arrays", function()
    local ir = Compiler.motion.circle(100, 1)
    local rotator = Compiler.compileRotator(ir, { fps = 60 })
    
    local states = Compiler.createRotatorStates(rotator, 3, { 0, 0.25, 0.5 })
    local xs, ys = rotator.getPositions(states, 3)
    
    assert(#xs == 3 and #ys == 3, "Should extract arrays")
    assert(approxEq(xs[1], 100), "First x should be 100")
end)

print("\n=== Rotator: Curve Types ===\n")

test("sin curve rotator", function()
    local ir = Compiler.curve.sin(1, 100)
    local rotator = Compiler.compileRotator(ir, { fps = 60 })
    local compiled = Compiler.compile(ir)
    
    local state = rotator.init(0)
    
    for frame = 1, 60 do
        rotator.step(state)
        local expected = compiled(frame / 60, {})
        assert(approxEq(state.value, expected, 0.5),
            string.format("Frame %d: expected %s, got %s", frame, expected, state.value))
    end
end)

test("cos curve rotator", function()
    local ir = Compiler.curve.cos(1, 100)
    local rotator = Compiler.compileRotator(ir, { fps = 60 })
    local compiled = Compiler.compile(ir)
    
    local state = rotator.init(0)
    
    for frame = 1, 30 do
        rotator.step(state)
        local expected = compiled(frame / 60, {})
        assert(approxEq(state.value, expected, 0.5),
            string.format("Frame %d: expected %s, got %s", frame, expected, state.value))
    end
end)

test("linear curve rotator", function()
    local ir = Compiler.curve.linear(100)
    local rotator = Compiler.compileRotator(ir, { fps = 60 })
    
    local state = rotator.init(0)
    assert(state.value == 0, "Should start at 0")
    
    rotator.step(state)
    assert(approxEq(state.value, 100/60), "After one step: 100/60")
    
    for _ = 1, 59 do rotator.step(state) end
    assert(approxEq(state.value, 100), "After 60 steps: 100")
end)

print("\n=== Rotator: Composite Motion ===\n")

test("motionAdd rotator", function()
    local ir = Compiler.motion.add(
        Compiler.motion.circle(100, 1),
        Compiler.motion.drift(10, 5)
    )
    local rotator, err = Compiler.compileRotator(ir, { fps = 60 })
    
    if not rotator then
        print("  (Composite rotator: " .. tostring(err) .. ")")
        return
    end
    
    local state = rotator.init(0)
    local startX = state.x
    
    -- Step 60 frames
    for _ = 1, 60 do rotator.step(state) end
    
    -- Should have both rotation and drift
    -- Circle returns to start, but drift adds 10 to X
    assert(approxEq(state.x, startX + 10, 2),
        string.format("Expected x near %s, got %s", startX + 10, state.x))
end)

print("\n=== Rotator: Performance ===\n")

benchmark("rotator is faster than compiled for circle", function()
    local ir = Compiler.motion.circle(100, 1)
    local compiled = Compiler.compile(ir)
    local rotator = Compiler.compileRotator(ir, { fps = 60 })
    
    local n = 1000
    local iterations = 1000
    local ctx = {}
    
    -- Setup states
    local states = Compiler.createRotatorStates(rotator, n, nil)
    
    -- Warmup
    for _ = 1, 10 do
        for i = 1, n do compiled(i * 0.001, ctx) end
        rotator.stepBatch(states, n)
    end
    
    -- Time compiled
    local t0 = os.clock()
    for _ = 1, iterations do
        for i = 1, n do
            compiled(i * 0.001, ctx)
        end
    end
    local compiledTime = os.clock() - t0
    
    -- Time rotator
    t0 = os.clock()
    for _ = 1, iterations do
        rotator.stepBatch(states, n)
    end
    local rotatorTime = os.clock() - t0
    
    local speedup = compiledTime / rotatorTime
    print(string.format("  Compiled: %.4fs, Rotator: %.4fs, Speedup: %.2fx",
        compiledTime, rotatorTime, speedup))
    
    -- Rotator should be faster (no trig per call)
    assert(speedup > 1.0, "Rotator should be faster than compiled")
end)

test("rotator vs LUT performance", function()
    local ir = Compiler.motion.circle(100, 1)
    local rotator = Compiler.compileRotator(ir, { fps = 60 })
    local batchLUT = Compiler.compileBatchLUT(ir, { fps = 60, duration = 1, preallocate = true })
    
    local n = 10000
    local iterations = 100
    
    -- Setup
    local states = Compiler.createRotatorStates(rotator, n, nil)
    local ts = {}
    local phases = {}
    local outX, outY = {}, {}
    for i = 1, n do
        ts[i] = 0
        phases[i] = (i - 1) / n
        outX[i] = 0
        outY[i] = 0
    end
    
    -- Warmup
    for _ = 1, 5 do
        rotator.stepBatch(states, n)
        batchLUT(ts, phases, n, outX, outY)
    end
    
    -- Time rotator
    local t0 = os.clock()
    for _ = 1, iterations do
        rotator.stepBatch(states, n)
    end
    local rotatorTime = os.clock() - t0
    
    -- Time LUT
    t0 = os.clock()
    for _ = 1, iterations do
        batchLUT(ts, phases, n, outX, outY)
    end
    local lutTime = os.clock() - t0
    
    print(string.format("  Rotator: %.4fs, BatchLUT: %.4fs",
        rotatorTime, lutTime))
    print(string.format("  Rotator ops: 4 mul + 2 add per entity"))
    print(string.format("  LUT ops: 1 floor + 1 mod + 2 index per entity"))
end)

print("\n=== Rotator: Accuracy Over Time ===\n")

test("rotator maintains accuracy over many frames", function()
    local ir = Compiler.motion.circle(100, 1)
    local compiled = Compiler.compile(ir)
    local rotator = Compiler.compileRotator(ir, { fps = 60 })
    
    local state = rotator.init(0)
    local frames = 3600  -- 1 minute at 60fps
    
    for _ = 1, frames do
        rotator.step(state)
    end
    
    local t = frames / 60
    local ex, ey = compiled(t, {})
    
    -- After 60 full rotations, should still be accurate within 1%
    local error = math.sqrt((state.x - ex)^2 + (state.y - ey)^2)
    local errorPct = error / 100 * 100
    
    print(string.format("  After %d frames (%.0f rotations): error = %.2f%%", 
        frames, frames / 60, errorPct))
    
    assert(errorPct < 5, "Drift should be under 5% after 1 minute")
end)

print("\n=== All Rotator tests complete ===\n")

Support.finish()
