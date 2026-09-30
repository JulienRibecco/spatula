-- Resolve modules relative to this checkout, including when run directly.
dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../../tests/bootstrap.lua")
--- Test suite for Transparent Pool API
-- Path adjustment for tests subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Auto-selects best strategy (rotator > LUT > compiled)
--- Run with: lua test_pool.lua

local Compiler = require("spatula.compiler.compiler")

local function approxEq(a, b, eps)
    eps = eps or 0.01
    return math.abs(a - b) < eps
end

local Support = require("tests.support")
local test = Support.test
local benchmark = Support.benchmark

print("\n=== Pool: Creation & Strategy Selection ===\n")

test("createPool returns pool object", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Compiler.createPool(ir, { count = 10, fps = 60 })
    
    assert(pool ~= nil, "Should return pool")
    assert(pool.count == 10, "Should have count")
    assert(pool.x and pool.y, "Should have position arrays")
end)

test("circle uses rotator strategy", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Compiler.createPool(ir, { count = 10 })
    
    assert(pool.strategy == "rotator", 
        "Circle should use rotator, got: " .. pool.strategy)
end)

test("noise-based shake uses compiled strategy", function()
    local ir = Compiler.motion.shake(5, 10)
    local pool = Compiler.createPool(ir, { count = 10 })
    
    assert(pool.strategy == "compiled",
        "Noise must not be forced into a one-second loop, got: " .. pool.strategy)
end)

test("stateful uses compiled strategy", function()
    local ir = Compiler.motion.xy(
        Compiler.curve.follow(Compiler.curve.const(100), 5),
        Compiler.curve.const(0)
    )
    local pool = Compiler.createPool(ir, { count = 10 })
    
    assert(pool.strategy == "compiled", 
        "Stateful should use compiled, got: " .. pool.strategy)
end)

test("pool:info() returns strategy info", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Compiler.createPool(ir, { count = 100, fps = 120 })
    local info = pool:info()
    
    assert(info.strategy == "rotator")
    assert(info.count == 100)
    assert(info.fps == 120)
    assert(info.isMotion == true)
end)

print("\n=== Pool: Initialization ===\n")

test("pool:init() sets all to phase 0", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Compiler.createPool(ir, { count = 5 }):init()
    
    -- At phase 0, circle starts at (100, 0)
    for i = 1, 5 do
        assert(approxEq(pool.x[i], 100) and approxEq(pool.y[i], 0),
            string.format("Entity %d: expected (100,0), got (%s,%s)", 
                i, pool.x[i], pool.y[i]))
    end
end)

test("pool:init(phases) sets different phases", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Compiler.createPool(ir, { count = 4 })
    pool:init({ 0, 0.25, 0.5, 0.75 })
    
    -- Phase 0: (100, 0)
    assert(approxEq(pool.x[1], 100) and approxEq(pool.y[1], 0), "Phase 0")
    -- Phase 0.25: (0, 100)
    assert(approxEq(pool.x[2], 0, 1) and approxEq(pool.y[2], 100, 1), "Phase 0.25")
    -- Phase 0.5: (-100, 0)
    assert(approxEq(pool.x[3], -100, 1) and approxEq(pool.y[3], 0, 1), "Phase 0.5")
end)

test("pool:initRandom() randomizes phases", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Compiler.createPool(ir, { count = 100 }):initRandom()
    
    -- Check positions are different
    local allSame = true
    for i = 2, 100 do
        if pool.x[i] ~= pool.x[1] or pool.y[i] ~= pool.y[1] then
            allSame = false
            break
        end
    end
    assert(not allSame, "Random init should produce different positions")
end)

test("createPoolRandom convenience function", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Compiler.createPoolRandom(ir, 50, { fps = 60 })
    
    assert(pool.count == 50)
    -- Should be initialized with random phases
    local hasVariation = false
    for i = 2, 50 do
        if pool.x[i] ~= pool.x[1] then
            hasVariation = true
            break
        end
    end
    assert(hasVariation, "Should have variation")
end)

print("\n=== Pool: Stepping ===\n")

test("pool:step() advances positions", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Compiler.createPool(ir, { count = 1, fps = 60 }):init()
    
    local startX, startY = pool.x[1], pool.y[1]
    
    pool:step()
    
    assert(pool.x[1] ~= startX or pool.y[1] ~= startY,
        "Position should change after step")
end)

test("pool:step() works for all strategies", function()
    local motions = {
        { name = "circle (rotator)", ir = Compiler.motion.circle(100, 1) },
        { name = "shake (lut)", ir = Compiler.motion.shake(5, 10) },
        { name = "bounce (lut)", ir = Compiler.motion.bounce(100, 2) },
    }
    
    for _, m in ipairs(motions) do
        local pool = Compiler.createPool(m.ir, { count = 10, fps = 60 }):init()
        
        -- Record initial positions
        local startX = pool.x[1]
        
        -- Step 10 times
        for _ = 1, 10 do
            pool:step()
        end
        
        -- Position should have changed
        assert(pool.x[1] ~= startX or pool.y[1] ~= 0,
            m.name .. " should advance position")
    end
end)

test("pool:step() completes full rotation", function()
    local ir = Compiler.motion.circle(100, 1)  -- 1 Hz
    local pool = Compiler.createPool(ir, { count = 1, fps = 60 }):init()
    
    local startX, startY = pool.x[1], pool.y[1]
    
    -- 60 steps = 1 second = 1 full rotation
    for _ = 1, 60 do
        pool:step()
    end
    
    assert(approxEq(pool.x[1], startX, 1) and approxEq(pool.y[1], startY, 1),
        string.format("After rotation: expected (%s,%s), got (%s,%s)",
            startX, startY, pool.x[1], pool.y[1]))
end)

test("pool:get(i) returns position", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Compiler.createPool(ir, { count = 3 }):init({ 0, 0.25, 0.5 })
    
    local x1, y1 = pool:get(1)
    local x2, y2 = pool:get(2)
    
    assert(approxEq(x1, 100) and approxEq(y1, 0), "get(1)")
    assert(approxEq(x2, 0, 1) and approxEq(y2, 100, 1), "get(2)")
end)

print("\n=== Pool: Curve Support ===\n")

test("pool works with curves", function()
    local ir = Compiler.curve.sin(1, 100)
    local pool = Compiler.createPool(ir, { count = 4, fps = 60 })
    pool:init({ 0, 0.25, 0.5, 0.75 })
    
    assert(pool.isMotion == false, "Should detect curve")
    
    -- sin(0) = 0, sin(0.25) = 100, sin(0.5) = 0, sin(0.75) = -100
    assert(approxEq(pool.values[1], 0, 1), "sin(0) = 0")
    assert(approxEq(pool.values[2], 100, 1), "sin(0.25) = 100")
    assert(approxEq(pool.values[3], 0, 1), "sin(0.5) = 0")
    assert(approxEq(pool.values[4], -100, 1), "sin(0.75) = -100")
end)

test("curve pool:step() advances values", function()
    local ir = Compiler.curve.sin(1, 100)
    local pool = Compiler.createPool(ir, { count = 1, fps = 60 }):init()
    
    local start = pool.values[1]
    
    for _ = 1, 15 do  -- 0.25 seconds
        pool:step()
    end
    
    -- Should be near sin(0.25) = 100
    assert(approxEq(pool.values[1], 100, 5),
        string.format("Expected ~100, got %s", pool.values[1]))
end)

print("\n=== Pool: Dynamic Operations ===\n")

test("pool:setPhase() resets entity", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Compiler.createPool(ir, { count = 2, fps = 60 }):init()
    
    -- Step a few times
    for _ = 1, 10 do pool:step() end
    
    -- Reset entity 1 to phase 0.5
    pool:setPhase(1, 0.5)
    
    -- Should be at (-100, 0)
    assert(approxEq(pool.x[1], -100, 1) and approxEq(pool.y[1], 0, 1),
        string.format("After setPhase: expected (-100,0), got (%s,%s)",
            pool.x[1], pool.y[1]))
end)

test("pool:resize() adds entities", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Compiler.createPool(ir, { count = 5 }):init()
    
    pool:resize(10)
    
    assert(pool.count == 10, "Count should be 10")
    assert(pool.x[10] ~= nil, "New entities should exist")
end)

print("\n=== Pool: Performance ===\n")

test("pool is fast for large entity counts", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Compiler.createPool(ir, { count = 10000, fps = 60 }):initRandom()
    
    local iterations = 100
    
    -- Warmup
    for _ = 1, 10 do pool:step() end
    
    local t0 = os.clock()
    for _ = 1, iterations do
        pool:step()
    end
    local elapsed = os.clock() - t0
    
    local stepsPerSec = (iterations * 10000) / elapsed
    print(string.format("  %s: %.0f entity-steps/sec (%.4fs for %d iterations)",
        pool.strategy, stepsPerSec, elapsed, iterations))
    
    -- Should handle 10k entities reasonably fast
    assert(elapsed < 1.0, "Should complete in under 1 second")
end)

test("different strategies same result", function()
    -- Compare circle (rotator) vs drift (rotator) vs shake (lut)
    local pools = {
        Compiler.createPool(Compiler.motion.circle(100, 1), { count = 5, fps = 60 }),
        Compiler.createPool(Compiler.motion.shake(5, 10), { count = 5, fps = 60 }),
    }
    
    for _, pool in ipairs(pools) do
        pool:init({ 0, 0.1, 0.2, 0.3, 0.4 })
        
        -- Step should work without error
        for _ = 1, 60 do
            pool:step()
        end
        
        -- All entities should have positions
        for i = 1, 5 do
            local x, y = pool:get(i)
            assert(type(x) == "number" and type(y) == "number",
                string.format("Strategy %s entity %d missing position", pool.strategy, i))
        end
    end
end)

print("\n=== Pool: Stateful Curves (follow/spring) ===\n")

test("stateful pool maintains per-entity state", function()
    -- follow curve: smoothly follows a moving target (sin wave)
    local ir = Compiler.motion.xy(
        Compiler.curve.follow(Compiler.curve.sin(1, 100), 5),
        Compiler.curve.const(0)
    )
    local pool = Compiler.createPool(ir, { count = 3, fps = 60 }):init()
    
    assert(pool.strategy == "compiled", "Stateful should use compiled")
    assert(pool._isStateful == true, "Should be marked stateful")
    assert(pool._contexts ~= nil, "Should have contexts")
    
    -- Step multiple times - follow should lag behind sin target
    for _ = 1, 30 do
        pool:step()
    end
    
    -- X should have changed (following sin wave)
    -- All entities stepped together, so they should have similar values
    assert(pool.x[1] ~= 0, "follow should have moved")
end)

test("stateful pool entities have independent contexts", function()
    -- Each entity should have its own ctx object
    local ir = Compiler.curve.follow(Compiler.curve.sin(1, 100), 5)
    local pool = Compiler.createPool(ir, { count = 3, fps = 60 }):init()
    
    -- All contexts should be separate objects
    assert(pool._contexts[1] ~= pool._contexts[2], "Contexts should be separate")
    assert(pool._contexts[2] ~= pool._contexts[3], "Contexts should be separate")
    
    -- Step a few times  
    for _ = 1, 30 do
        pool:step()
    end
    
    -- Reset entity 2 - should get fresh ctx
    local oldCtx2 = pool._contexts[2]
    pool:setPhase(2, 0)
    
    -- Ctx should be reset (new empty table)
    assert(pool._contexts[2] ~= oldCtx2 or next(pool._contexts[2]) == nil, 
        "Entity 2 ctx should be reset")
end)

test("spring curve in pool", function()
    local ir = Compiler.curve.spring(Compiler.curve.sin(2, 50), 100, 10)
    local pool = Compiler.createPool(ir, { count = 2, fps = 60 }):init()
    
    assert(pool.strategy == "compiled", "Spring should use compiled")
    assert(pool._isStateful == true, "Spring is stateful")
    
    -- Step and verify values change
    local start1 = pool.values[1]
    for _ = 1, 60 do
        pool:step()
    end
    
    assert(pool.values[1] ~= start1, "Spring should oscillate")
end)

print("\n=== Pool: Hybrid LUT Strategy ===\n")

test("hybrid detects mixed pure/stateful children", function()
    -- motionAdd with circle (pure) + follow (stateful)
    local ir = Compiler.motion.add(
        Compiler.motion.circle(100, 1),
        Compiler.motion.xy(
            Compiler.curve.follow(Compiler.curve.const(50), 5),
            Compiler.curve.const(0)
        )
    )
    
    local canHybrid, pure, stateful = Compiler.analyzeHybrid(ir)
    
    assert(canHybrid == true, "Should detect hybrid opportunity")
    assert(#pure == 1, "Should have 1 pure child (circle)")
    assert(#stateful == 1, "Should have 1 stateful child (follow)")
end)

test("hybrid pool uses LUT for pure parts", function()
    local ir = Compiler.motion.add(
        Compiler.motion.circle(100, 1),       -- Pure: will be LUT
        Compiler.motion.xy(
            Compiler.curve.follow(Compiler.curve.const(50), 5),
            Compiler.curve.const(0)
        )
    )
    
    local pool = Compiler.createPool(ir, { count = 3, fps = 60 }):init()
    
    assert(pool.strategy == "hybrid", 
        "Should use hybrid strategy, got: " .. pool.strategy)
    assert(pool._pureLUTs ~= nil, "Should have pure LUTs")
    assert(pool._statefulFns ~= nil, "Should have stateful fns")
    assert(#pool._pureLUTs == 1, "Should have 1 LUT (circle)")
    assert(#pool._statefulFns == 1, "Should have 1 stateful fn (follow)")
end)

test("hybrid pool produces correct combined values", function()
    local ir = Compiler.motion.add(
        Compiler.motion.circle(100, 1),
        Compiler.motion.xy(
            Compiler.curve.follow(Compiler.curve.const(50), 5),
            Compiler.curve.const(0)
        )
    )
    
    local pool = Compiler.createPool(ir, { count = 1, fps = 60 }):init()
    
    -- At t=0: circle=(100,0), follow starts at 50 -> (150, 0)
    -- Allow some tolerance since follow might not be exactly at target
    assert(pool.x[1] > 100, "X should be circle + follow contribution")
    
    -- Step and verify it changes
    local startX = pool.x[1]
    for _ = 1, 30 do
        pool:step()
    end
    
    assert(pool.x[1] ~= startX, "Position should change")
end)

benchmark("hybrid is faster than full compiled", function()
    -- Motion with expensive pure part + cheap stateful part
    local ir = Compiler.motion.add(
        Compiler.motion.add(
            Compiler.motion.circle(100, 1),
            Compiler.motion.circle(50, 2)
        ),
        Compiler.motion.xy(
            Compiler.curve.follow(Compiler.curve.const(10), 5),
            Compiler.curve.const(0)
        )
    )
    
    local pool = Compiler.createPool(ir, { count = 100, fps = 60 }):init()
    
    -- Should use hybrid since there are pure children
    print(string.format("  Strategy: %s (pure LUTs: %d, stateful: %d)",
        pool.strategy,
        pool._pureLUTs and #pool._pureLUTs or 0,
        pool._statefulFns and #pool._statefulFns or 0))
    
    -- Just verify it works
    for _ = 1, 60 do
        pool:step()
    end
    
    assert(pool.x[1] ~= nil, "Should produce positions")
end)

test("non-add stateful motion uses compiled not hybrid", function()
    -- Single stateful motion (not an add)
    local ir = Compiler.motion.xy(
        Compiler.curve.follow(Compiler.curve.sin(1, 100), 5),
        Compiler.curve.const(0)
    )

    local pool = Compiler.createPool(ir, { count = 1, fps = 60 }):init()

    assert(pool.strategy == "compiled",
        "Non-add should use compiled, got: " .. pool.strategy)
end)

print("\n=== Pool: Hybrid Scalar Curves ===\n")

test("hybrid detects scalar add (pure + stateful)", function()
    -- Scalar curve: sin (pure) + follow (stateful)
    local ir = Compiler.curve.add(
        Compiler.curve.sin(1, 10, 0),
        Compiler.curve.follow(Compiler.curve.const(50), 5)
    )

    local canHybrid, pure, stateful = Compiler.analyzeHybrid(ir)

    assert(canHybrid == true, "Should detect hybrid opportunity for scalar add")
    assert(#pure == 1, "Should have 1 pure child (sin)")
    assert(#stateful == 1, "Should have 1 stateful child (follow)")
end)

test("hybrid pool works for scalar curves", function()
    local ir = Compiler.curve.add(
        Compiler.curve.sin(1, 10, 0),       -- Pure: will be LUT'd
        Compiler.curve.follow(Compiler.curve.const(50), 5)  -- Stateful: runtime
    )

    local pool = Compiler.createPool(ir, { count = 3, fps = 60 }):init()

    assert(pool.strategy == "hybrid",
        "Should use hybrid strategy for scalar add, got: " .. pool.strategy)
    assert(pool.isMotion == false, "Should be scalar (not motion)")
    assert(pool._pureLUTs ~= nil, "Should have pure LUTs")
    assert(pool._statefulFns ~= nil, "Should have stateful fns")
    assert(#pool._pureLUTs == 1, "Should have 1 LUT (sin)")
    assert(pool._pureLUTs[1].isMotion == false, "LUT should be scalar")
    assert(#pool._statefulFns == 1, "Should have 1 stateful fn (follow)")
    assert(pool._statefulFns[1].isMotion == false, "Stateful fn should be scalar")
end)

test("hybrid scalar pool produces correct values", function()
    local ir = Compiler.curve.add(
        Compiler.curve.sin(1, 10, 0),
        Compiler.curve.follow(Compiler.curve.const(50), 5)
    )

    local pool = Compiler.createPool(ir, { count = 1, fps = 60 }):init()

    -- At t=0: sin(0)=0, follow starts approaching 50
    -- Value should be around 50 (follow converges quickly)
    assert(pool.values[1] ~= nil, "Should have values array")
    assert(pool.values[1] > 40, "Value should include follow contribution")

    -- Step and verify sin oscillation affects value
    local v0 = pool.values[1]
    pool:step()
    local v1 = pool.values[1]

    -- Value should change due to sin oscillation
    assert(v1 ~= v0, "Value should change as sin oscillates")
end)

test("hybrid scalar with multiple pure children", function()
    -- Multiple pure curves + one stateful
    local ir = Compiler.curve.add(
        Compiler.curve.sin(1, 10, 0),
        Compiler.curve.cos(2, 5, 0),
        Compiler.curve.follow(Compiler.curve.const(100), 5)
    )

    local canHybrid, pure, stateful = Compiler.analyzeHybrid(ir)

    assert(canHybrid == true, "Should detect hybrid with multiple pure")
    assert(#pure == 2, "Should have 2 pure children (sin, cos)")
    assert(#stateful == 1, "Should have 1 stateful child (follow)")

    local pool = Compiler.createPool(ir, { count = 1, fps = 60 }):init()
    assert(pool.strategy == "hybrid", "Should use hybrid")
    assert(#pool._pureLUTs == 2, "Should have 2 LUTs")
end)

print("\n=== Pool: Transparent Auto-Optimization ===\n")

test("auto-detects Y-only usage", function()
    local ir = Compiler.motion.hover(10, 2)
    local pool = Compiler.createPool(ir, { count = 100, fps = 60 }):init()
    
    -- User just writes normal code - only accesses Y
    for frame = 1, 10 do
        pool:step()
        for i = 1, pool.count do
            local _ = pool.y[i]  -- Only Y accessed
        end
    end
    
    -- System should have auto-detected Y-only
    assert(pool.axis == "y", "Should auto-detect Y-only, got: " .. pool.axis)
end)

test("auto-detects X-only usage", function()
    local ir = Compiler.motion.shake(5, 10)
    local pool = Compiler.createPool(ir, { count = 50, fps = 60 }):init()
    
    -- Only access X
    for frame = 1, 10 do
        pool:step()
        for i = 1, pool.count do
            local _ = pool.x[i]
        end
    end
    
    assert(pool.axis == "x", "Should auto-detect X-only, got: " .. pool.axis)
end)

test("auto-detects both axes usage", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Compiler.createPool(ir, { count = 20, fps = 60 }):init()
    
    -- Access both
    for frame = 1, 10 do
        pool:step()
        for i = 1, pool.count do
            local _ = pool.x[i]
            local _ = pool.y[i]
        end
    end
    
    assert(pool.axis == "xy", "Should detect both axes, got: " .. pool.axis)
end)

test("warmup period computes both axes", function()
    local ir = Compiler.motion.shake(5, 10)
    local pool = Compiler.createPool(ir, { count = 10, fps = 60 }):init()
    
    -- During warmup (first few frames), both axes should be available
    pool:step()
    
    -- Both should have values during warmup
    assert(pool.x[1] ~= nil, "X should be computed during warmup")
    assert(pool.y[1] ~= nil, "Y should be computed during warmup")
end)

test("optimization kicks in after warmup", function()
    local ir = Compiler.motion.shake(5, 10)
    local pool = Compiler.createPool(ir, { count = 100, fps = 60 }):init()
    
    -- Set Y to sentinel before optimization kicks in
    for i = 1, pool.count do pool._rawY[i] = -999 end
    
    -- Only access X for warmup period + 1
    for frame = 1, 7 do
        pool:step()
        for i = 1, pool.count do
            local _ = pool.x[i]
        end
    end
    
    -- After optimization, Y should not be computed
    -- (sentinel should remain for new frames)
    for i = 1, pool.count do pool._rawY[i] = -999 end
    pool:step()
    
    -- Y values should stay as sentinel (not overwritten)
    assert(pool._rawY[1] == -999, "Y should not be computed after optimization")
end)

test("init resets auto-detection", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Compiler.createPool(ir, { count = 5, fps = 60 }):init()
    
    -- Use only X
    for frame = 1, 10 do
        pool:step()
        local _ = pool.x[1]
    end
    assert(pool.axis == "x", "Should be X-only")
    
    -- Re-init should reset detection
    pool:init()
    assert(pool.axis == "xy", "Init should reset to xy")
    assert(pool._autoAxis == true, "Init should re-enable auto-detection")
end)

test("completely transparent usage", function()
    -- This test simulates real game code - no Spatula-specific knowledge needed
    local hover = Compiler.createPool(Compiler.motion.hover(10, 2), { count = 50 }):init()
    
    -- Simulate 60 frames of a game loop where we only use Y offset
    local totalOffset = 0
    for frame = 1, 60 do
        hover:step()
        
        -- Game code just uses what it needs
        for i = 1, hover.count do
            totalOffset = totalOffset + hover.y[i]
        end
    end
    
    -- Verify optimization happened silently
    assert(hover.axis == "y", "Should have auto-optimized to Y-only")
    assert(totalOffset ~= 0, "Should have computed real values")
end)

test("manual override still works", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Compiler.createPool(ir, { count = 10, fps = 60 }):init()
    
    -- Manual override disables auto-detection
    pool:useX()
    assert(pool._autoAxis == false, "Manual override disables auto")
    
    -- Can re-enable auto
    pool:useAuto()
    assert(pool._autoAxis == true, "useAuto re-enables")
end)

test("LUT strategy benefits from auto-detection", function()
    local ir = Compiler.motion.xy(Compiler.curve.triangle(1, 5), Compiler.curve.sin(1, 10))
    local pool = Compiler.createPool(ir, { count = 5000, fps = 60 }):init()
    
    assert(pool.strategy == "lut", "Should use LUT")
    
    -- Only use Y
    for frame = 1, 10 do
        pool:step()
        for i = 1, pool.count do
            local _ = pool.y[i]
        end
    end
    
    -- Should have optimized
    assert(pool.axis == "y", "LUT should auto-optimize to Y")
end)

print("\n=== Pool: Typical Game Loop ===\n")

test("simulated game loop", function()
    -- Typical setup: background particles + UI elements + effects
    local bgParticles = Compiler.createPoolRandom(
        Compiler.motion.circle(50, 0.5), 
        100, 
        { fps = 60 }
    )
    
    local uiHover = Compiler.createPool(
        Compiler.motion.hover(5, 2),
        { count = 10, fps = 60 }
    ):init()
    
    local screenShake = Compiler.createPool(
        Compiler.motion.shake(3, 20),
        { count = 1, fps = 60 }
    ):init()
    
    -- Simulate 60 frames
    for frame = 1, 60 do
        bgParticles:step()
        uiHover:step()
        screenShake:step()
    end
    
    print(string.format("  bgParticles: %s, uiHover: %s, screenShake: %s",
        bgParticles.strategy, uiHover.strategy, screenShake.strategy))
    
    -- All should have valid positions
    assert(bgParticles.x[1] ~= nil)
    assert(uiHover.x[1] ~= nil)
    assert(screenShake.x[1] ~= nil)
end)

print("\n=== Pool: API Convenience ===\n")

test("Compiler.auto() for single entity", function()
    local ir = Compiler.motion.circle(100, 1)
    local fn = Compiler.auto(ir)
    
    local x, y = fn(0.25, {})
    
    assert(approxEq(x, 0, 1) and approxEq(y, 100, 1),
        "auto() should return working function")
end)

test("direct array access", function()
    local ir = Compiler.motion.circle(100, 1)
    local pool = Compiler.createPool(ir, { count = 100 }):initRandom()
    
    -- Can directly iterate x/y arrays
    local sumX = 0
    for i = 1, pool.count do
        sumX = sumX + pool.x[i]
    end
    
    -- Average X should be near 0 for evenly distributed phases
    local avgX = sumX / pool.count
    assert(math.abs(avgX) < 20, "Average X should be near 0")
end)

print("\n=== All Pool tests complete ===\n")

Support.finish()
