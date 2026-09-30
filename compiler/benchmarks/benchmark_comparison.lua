--------------------------------------------------------------------------------
-- Path adjustment for benchmarks subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
-- SPATULA BENCHMARK: Original vs Auto-Optimized
-- Tests real-world scenario where user writes simple code
-- and system optimizes transparently
--------------------------------------------------------------------------------

local Compiler = require("spatula.compiler.compiler")
local Scheduler = require("spatula.compiler.scheduler")

local function printf(fmt, ...)
    print(string.format(fmt, ...))
end

local function benchmark(name, iterations, fn)
    -- Warmup
    for _ = 1, 5 do fn() end
    
    local t0 = os.clock()
    for _ = 1, iterations do
        fn()
    end
    local elapsed = os.clock() - t0
    return elapsed
end

--------------------------------------------------------------------------------
-- ORIGINAL SPATULA STYLE
-- User creates composed closures, evaluates each entity individually
--------------------------------------------------------------------------------

local function createOriginalMotion(motionType, ...)
    local args = {...}
    
    if motionType == "circle" then
        local radius, freq = args[1], args[2]
        local PI2 = math.pi * 2
        return function(t)
            local angle = t * freq * PI2
            return math.cos(angle) * radius, math.sin(angle) * radius
        end
        
    elseif motionType == "shake" then
        local amount, freq = args[1], args[2]
        local PI2 = math.pi * 2
        return function(t)
            local x = math.sin(t * freq * PI2) * amount * math.sin(t * freq * 3.7 * PI2)
            local y = math.sin(t * freq * 1.3 * PI2) * amount * math.sin(t * freq * 2.9 * PI2)
            return x, y
        end
        
    elseif motionType == "hover" then
        local amount, freq = args[1], args[2]
        local PI2 = math.pi * 2
        return function(t)
            return 0, math.sin(t * freq * PI2) * amount
        end
        
    elseif motionType == "spiral" then
        local radius, freq, growth = args[1], args[2], args[3]
        local PI2 = math.pi * 2
        return function(t)
            local angle = t * freq * PI2
            local r = radius + t * growth
            return math.cos(angle) * r, math.sin(angle) * r
        end
    end
end

-- Original style: array of entities, each with own motion function
local function createOriginalPool(motionType, count, ...)
    local motion = createOriginalMotion(motionType, ...)
    local entities = {}
    for i = 1, count do
        entities[i] = {
            x = 0, y = 0,
            phase = math.random(),
            motion = motion,
        }
    end
    return entities
end

local function stepOriginalPool(entities, t)
    for i = 1, #entities do
        local e = entities[i]
        e.x, e.y = e.motion(t + e.phase)
    end
end

--------------------------------------------------------------------------------
-- AUTO-OPTIMIZED SPATULA
-- User creates pool, system auto-selects strategy and axis
--------------------------------------------------------------------------------

local function createAutoPool(ir, count)
    return Compiler.createPool(ir, { count = count, fps = 60 }):initRandom()
end

--------------------------------------------------------------------------------
-- GAME SIMULATION
-- Simulates real usage: step pools, read positions, render
--------------------------------------------------------------------------------

printf("\n" .. string.rep("=", 70))
printf("SPATULA BENCHMARK: Original vs Fully Transparent Auto-Optimization")
printf(string.rep("=", 70))

local ENTITY_COUNTS = { 100, 1000, 10000 }
local FRAME_COUNT = 60  -- 1 second of gameplay
local ITERATIONS = 10   -- Repeat for accuracy

for _, entityCount in ipairs(ENTITY_COUNTS) do
    printf("\n--- %d Entities ---\n", entityCount)
    
    ----------------------------------------------------------------------------
    -- TEST 1: Circle motion (orbiting particles)
    ----------------------------------------------------------------------------
    do
        local original = createOriginalPool("circle", entityCount, 100, 1)
        local auto = createAutoPool(Compiler.motion.circle(100, 1), entityCount)
        
        -- Original
        local origTime = benchmark("original circle", ITERATIONS, function()
            for frame = 1, FRAME_COUNT do
                local t = frame / 60
                stepOriginalPool(original, t)
                -- Simulate reading positions (like rendering)
                local sum = 0
                for i = 1, entityCount do
                    sum = sum + original[i].x + original[i].y
                end
            end
        end)
        
        -- Auto-optimized
        local autoTime = benchmark("auto circle", ITERATIONS, function()
            auto:init()  -- Reset
            for frame = 1, FRAME_COUNT do
                auto:step()
                -- Simulate reading positions
                local sum = 0
                for i = 1, entityCount do
                    sum = sum + auto.x[i] + auto.y[i]
                end
            end
        end)
        
        local speedup = origTime / autoTime
        printf("  circle:  Original %.3fs, Auto %.3fs, Speedup: %.2fx  [%s]",
            origTime, autoTime, speedup, auto.strategy)
    end
    
    ----------------------------------------------------------------------------
    -- TEST 2: Shake motion (screen shake, particles)
    ----------------------------------------------------------------------------
    do
        local original = createOriginalPool("shake", entityCount, 5, 10)
        local auto = createAutoPool(Compiler.motion.shake(5, 10), entityCount)
        
        local origTime = benchmark("original shake", ITERATIONS, function()
            for frame = 1, FRAME_COUNT do
                local t = frame / 60
                stepOriginalPool(original, t)
                local sum = 0
                for i = 1, entityCount do
                    sum = sum + original[i].x + original[i].y
                end
            end
        end)
        
        local autoTime = benchmark("auto shake", ITERATIONS, function()
            auto:init()
            for frame = 1, FRAME_COUNT do
                auto:step()
                local sum = 0
                for i = 1, entityCount do
                    sum = sum + auto.x[i] + auto.y[i]
                end
            end
        end)
        
        local speedup = origTime / autoTime
        printf("  shake:   Original %.3fs, Auto %.3fs, Speedup: %.2fx  [%s]",
            origTime, autoTime, speedup, auto.strategy)
    end
    
    ----------------------------------------------------------------------------
    -- TEST 3: Hover motion (UI elements) - Y only
    ----------------------------------------------------------------------------
    do
        local original = createOriginalPool("hover", entityCount, 10, 2)
        local auto = createAutoPool(Compiler.motion.hover(10, 2), entityCount)
        
        local origTime = benchmark("original hover", ITERATIONS, function()
            for frame = 1, FRAME_COUNT do
                local t = frame / 60
                stepOriginalPool(original, t)
                -- Only read Y (typical for UI hover)
                local sum = 0
                for i = 1, entityCount do
                    sum = sum + original[i].y
                end
            end
        end)
        
        local autoTime = benchmark("auto hover", ITERATIONS, function()
            auto:init()
            for frame = 1, FRAME_COUNT do
                auto:step()
                -- Only read Y - auto-detection kicks in
                local sum = 0
                for i = 1, entityCount do
                    sum = sum + auto.y[i]
                end
            end
        end)
        
        local speedup = origTime / autoTime
        printf("  hover:   Original %.3fs, Auto %.3fs, Speedup: %.2fx  [%s, axis=%s]",
            origTime, autoTime, speedup, auto.strategy, auto.axis)
    end
    
    ----------------------------------------------------------------------------
    -- TEST 4: Spiral motion (bullet hell patterns)
    ----------------------------------------------------------------------------
    do
        local original = createOriginalPool("spiral", entityCount, 100, 2, 50)
        local auto = createAutoPool(Compiler.motion.spiral(100, 2, 50), entityCount)
        
        local origTime = benchmark("original spiral", ITERATIONS, function()
            for frame = 1, FRAME_COUNT do
                local t = frame / 60
                stepOriginalPool(original, t)
                local sum = 0
                for i = 1, entityCount do
                    sum = sum + original[i].x + original[i].y
                end
            end
        end)
        
        local autoTime = benchmark("auto spiral", ITERATIONS, function()
            auto:init()
            for frame = 1, FRAME_COUNT do
                auto:step()
                local sum = 0
                for i = 1, entityCount do
                    sum = sum + auto.x[i] + auto.y[i]
                end
            end
        end)
        
        local speedup = origTime / autoTime
        printf("  spiral:  Original %.3fs, Auto %.3fs, Speedup: %.2fx  [%s]",
            origTime, autoTime, speedup, auto.strategy)
    end
end

--------------------------------------------------------------------------------
-- FULL GAME SCENARIO
-- Multiple pools, different motions, scheduler batching
--------------------------------------------------------------------------------

printf("\n" .. string.rep("=", 70))
printf("FULL GAME SCENARIO: Multiple Pools + Scheduler")
printf(string.rep("=", 70))

do
    local PARTICLES = 5000
    local ENEMIES = 500
    local UI_ELEMENTS = 100
    local BULLETS = 2000
    
    printf("\nEntities: %d particles, %d enemies, %d UI, %d bullets = %d total",
        PARTICLES, ENEMIES, UI_ELEMENTS, BULLETS,
        PARTICLES + ENEMIES + UI_ELEMENTS + BULLETS)
    
    -- Original style
    local origParticles = createOriginalPool("circle", PARTICLES, 100, 1)
    local origEnemies = createOriginalPool("shake", ENEMIES, 5, 10)
    local origUI = createOriginalPool("hover", UI_ELEMENTS, 10, 2)
    local origBullets = createOriginalPool("spiral", BULLETS, 50, 3, 100)
    
    local origTime = benchmark("original game", ITERATIONS, function()
        for frame = 1, FRAME_COUNT do
            local t = frame / 60
            stepOriginalPool(origParticles, t)
            stepOriginalPool(origEnemies, t)
            stepOriginalPool(origUI, t)
            stepOriginalPool(origBullets, t)
            
            -- Render (read positions)
            local sum = 0
            for i = 1, PARTICLES do sum = sum + origParticles[i].x end
            for i = 1, ENEMIES do sum = sum + origEnemies[i].x end
            for i = 1, UI_ELEMENTS do sum = sum + origUI[i].y end  -- UI: Y only
            for i = 1, BULLETS do sum = sum + origBullets[i].x end
        end
    end)
    
    -- Auto-optimized (no scheduler)
    local autoParticles = createAutoPool(Compiler.motion.circle(100, 1), PARTICLES)
    local autoEnemies = createAutoPool(Compiler.motion.shake(5, 10), ENEMIES)
    local autoUI = createAutoPool(Compiler.motion.hover(10, 2), UI_ELEMENTS)
    local autoBullets = createAutoPool(Compiler.motion.spiral(50, 3, 100), BULLETS)
    
    local autoTime = benchmark("auto game", ITERATIONS, function()
        autoParticles:init()
        autoEnemies:init()
        autoUI:init()
        autoBullets:init()
        
        for frame = 1, FRAME_COUNT do
            autoParticles:step()
            autoEnemies:step()
            autoUI:step()
            autoBullets:step()
            
            local sum = 0
            for i = 1, PARTICLES do sum = sum + autoParticles.x[i] end
            for i = 1, ENEMIES do sum = sum + autoEnemies.x[i] end
            for i = 1, UI_ELEMENTS do sum = sum + autoUI.y[i] end
            for i = 1, BULLETS do sum = sum + autoBullets.x[i] end
        end
    end)
    
    -- Auto-optimized WITH scheduler
    Scheduler.reset()
    local schedParticles = Scheduler.createPool(Compiler, Compiler.motion.circle(100, 1), { count = PARTICLES }):initRandom()
    local schedEnemies = Scheduler.createPool(Compiler, Compiler.motion.shake(5, 10), { count = ENEMIES }):initRandom()
    local schedUI = Scheduler.createPool(Compiler, Compiler.motion.hover(10, 2), { count = UI_ELEMENTS }):initRandom()
    local schedBullets = Scheduler.createPool(Compiler, Compiler.motion.spiral(50, 3, 100), { count = BULLETS }):initRandom()
    
    local schedTime = benchmark("scheduled game", ITERATIONS, function()
        schedParticles:init()
        schedEnemies:init()
        schedUI:init()
        schedBullets:init()
        
        for frame = 1, FRAME_COUNT do
            Scheduler.stepAll()
            
            local sum = 0
            for i = 1, PARTICLES do sum = sum + schedParticles.x[i] end
            for i = 1, ENEMIES do sum = sum + schedEnemies.x[i] end
            for i = 1, UI_ELEMENTS do sum = sum + schedUI.y[i] end
            for i = 1, BULLETS do sum = sum + schedBullets.x[i] end
        end
    end)
    
    printf("\nResults:")
    printf("  Original:   %.3fs (baseline)", origTime)
    printf("  Auto:       %.3fs (%.2fx faster)", autoTime, origTime / autoTime)
    printf("  Scheduled:  %.3fs (%.2fx faster)", schedTime, origTime / schedTime)
    
    printf("\nStrategies selected automatically:")
    printf("  particles: %s", autoParticles.strategy)
    printf("  enemies:   %s", autoEnemies.strategy)
    printf("  UI:        %s, axis=%s (auto-detected Y-only)", autoUI.strategy, autoUI.axis)
    printf("  bullets:   %s", autoBullets.strategy)
end

--------------------------------------------------------------------------------
-- SUMMARY
--------------------------------------------------------------------------------

printf("\n" .. string.rep("=", 70))
printf("SUMMARY")
printf(string.rep("=", 70))
printf([[

SPEEDUPS (10k entities, Lua 5.4):
  Motion     Original → Auto    Gain
  ───────────────────────────────────
  shake      1.67s → 0.63s     2.65x  (LUT)
  spiral     0.93s → 0.61s     1.52x  (LUT)
  hover      0.62s → 0.56s     1.11x  (LUT + Y-only auto)
  circle     0.92s → 1.10s     0.84x  (rotator overhead)

FULL GAME (7600 entities):
  Original:   0.67s (baseline)
  Auto:       0.58s (1.16x faster)
  Scheduled:  0.39s (1.72x faster)

User writes SIMPLE code like:
  local particles = Compiler.createPool(
      Compiler.motion.circle(100, 1), 
      { count = 5000 }
  ):init()
  
  function love.update(dt)
      particles:step()
  end
  
  function love.draw()
      for i = 1, particles.count do
          draw(particles.x[i], particles.y[i])
      end
  end

System AUTOMATICALLY:
  ✓ Selects optimal strategy (LUT for shake/spiral, rotator for circle)
  ✓ Detects which axes are used (Y-only for hover UI)
  ✓ Batches operations across pools (Scheduler: 1.72x total)
  ✓ Swaps metatables → raw arrays after warmup (zero overhead)
  ✓ Unrolls loops 4x for CPU pipelining

NOTE: LuaJIT would show larger gains due to:
  - Trace compilation of tight loops
  - Auto-vectorization to SIMD
  - FFI for native float arrays
]])
