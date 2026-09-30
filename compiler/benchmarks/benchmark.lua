--- Benchmark: Composed vs Compiled vs LUT Spatula functions
-- Path adjustment for benchmarks subdirectory
package.path = package.path .. ";../../../?.lua;../../../?/init.lua"
--- Run with: lua benchmark.lua

local Compiler = require("spatula.compiler.compiler")

--------------------------------------------------------------------------------
-- Simulated "original" composed versions (as Spatula currently works)
--------------------------------------------------------------------------------

local PI2 = 6.283185307179586

local function composedCircle(radius, speed)
    local function curvecos(freq, amp)
        return function(t, ctx) return math.cos(t * freq * PI2) * amp end
    end
    local function curvesin(freq, amp)
        return function(t, ctx) return math.sin(t * freq * PI2) * amp end
    end
    local function motionXY(cx, cy)
        return function(t, ctx) return cx(t, ctx), cy(t, ctx) end
    end
    return motionXY(curvecos(speed, radius), curvesin(speed, radius))
end

local function composedSpiral(radius, speed, growth)
    local function curvecos(freq, amp)
        return function(t, ctx) return math.cos(t * freq * PI2) * amp end
    end
    local function curvesin(freq, amp)
        return function(t, ctx) return math.sin(t * freq * PI2) * amp end
    end
    local function curveLinear(s)
        return function(t, ctx) return t * s end
    end
    local function curveOffset(c, amt)
        return function(t, ctx) return c(t, ctx) + amt end
    end
    local function motionXY(cx, cy)
        return function(t, ctx) return cx(t, ctx), cy(t, ctx) end
    end
    local function motionScale(m, factor)
        return function(t, ctx)
            local f = factor(t, ctx)
            local x, y = m(t, ctx)
            return x * f, y * f
        end
    end
    local base = motionXY(curvecos(speed, radius), curvesin(speed, radius))
    local scaleFactor = curveOffset(curveLinear(growth), 1)
    return motionScale(base, scaleFactor)
end

local function composedHover(amount, speed)
    local function curvesin(freq, amp, phase)
        phase = phase or 0
        return function(t, ctx) return math.sin(t * freq * PI2 + phase) * amp end
    end
    local function motionXY(cx, cy)
        return function(t, ctx) return cx(t, ctx), cy(t, ctx) end
    end
    return motionXY(
        curvesin(speed, amount),
        curvesin(speed * 1.3 + math.pi/6, amount)
    )
end

local function composedShake(intensity, speed)
    local function noise(scale, seed)
        return function(t)
            return (math.sin(t * 1.0 + seed) * 0.5 + 
                    math.sin(t * 2.3 + seed * 2) * 0.3 + 
                    math.sin(t * 5.7 + seed * 3) * 0.2) * scale
        end
    end
    local function timeScale(c, factor)
        return function(t, ctx) return c(t * factor, ctx) end
    end
    local function motionXY(cx, cy)
        return function(t, ctx) return cx(t, ctx), cy(t, ctx) end
    end
    return motionXY(
        timeScale(noise(intensity, 0), speed),
        timeScale(noise(intensity, 12345), speed)
    )
end

local function composedFigure8(size, speed)
    local function curvesin(freq, amp, phase)
        phase = phase or 0
        return function(t, ctx) return math.sin(t * freq * PI2 + phase) * amp end
    end
    local function motionXY(cx, cy)
        return function(t, ctx) return cx(t, ctx), cy(t, ctx) end
    end
    return motionXY(curvesin(speed, size), curvesin(speed * 2, size, 0))
end

local function composedEllipse(rx, ry, speed)
    local function curvecos(freq, amp)
        return function(t, ctx) return math.cos(t * freq * PI2) * amp end
    end
    local function curvesin(freq, amp)
        return function(t, ctx) return math.sin(t * freq * PI2) * amp end
    end
    local function motionXY(cx, cy)
        return function(t, ctx) return cx(t, ctx), cy(t, ctx) end
    end
    return motionXY(curvecos(speed, rx), curvesin(speed, ry))
end

local function composedBounce(height, speed)
    local function curvesin(freq, amp)
        return function(t, ctx) return math.sin(t * freq * PI2) * amp end
    end
    local function curveAbs(c)
        return function(t, ctx) return math.abs(c(t, ctx)) end
    end
    local function motionXY(cx, cy)
        return function(t, ctx) return cx(t, ctx), cy(t, ctx) end
    end
    return motionXY(
        function() return 0 end,
        curveAbs(curvesin(speed, height))
    )
end

--------------------------------------------------------------------------------
-- Benchmark runner
--------------------------------------------------------------------------------

local function benchmark(name, composed, compiledIR, iterations)
    iterations = iterations or 1000000
    local ctx = {}
    
    -- Compile
    local compiled = Compiler.compile(compiledIR)
    
    -- Create LUT if possible
    local lutFn = nil
    local canLUT = Compiler.canUseLUT(compiledIR)
    if canLUT then
        lutFn = Compiler.compileLUT(compiledIR, { fps = 60, duration = 1 })
    end
    
    -- Warmup
    for i = 1, 10000 do
        composed((i % 60) / 60, ctx)
        compiled((i % 60) / 60, ctx)
        if lutFn then lutFn((i % 60) / 60) end
    end
    
    -- Time composed
    local t0 = os.clock()
    for i = 1, iterations do
        composed((i % 60) / 60, ctx)
    end
    local composedTime = os.clock() - t0
    
    -- Time compiled
    t0 = os.clock()
    for i = 1, iterations do
        compiled((i % 60) / 60, ctx)
    end
    local compiledTime = os.clock() - t0
    
    -- Time LUT
    local lutTime = nil
    if lutFn then
        t0 = os.clock()
        for i = 1, iterations do
            lutFn((i % 60) / 60)
        end
        lutTime = os.clock() - t0
    end
    
    local compSpeedup = composedTime / compiledTime
    local lutSpeedup = lutFn and (composedTime / lutTime) or nil
    
    if lutFn then
        print(string.format("%-20s | Composed: %6.2fs | Compiled: %6.2fs (%5.2fx) | LUT: %6.2fs (%5.2fx)", 
            name, composedTime, compiledTime, compSpeedup, lutTime, lutSpeedup))
    else
        print(string.format("%-20s | Composed: %6.2fs | Compiled: %6.2fs (%5.2fx) | LUT: N/A", 
            name, composedTime, compiledTime, compSpeedup))
    end
    
    return compSpeedup, lutSpeedup
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

print("")
print("=============================================================================")
print("Spatula Compiler Benchmark")
print("=============================================================================")
print("Iterations per test: 1,000,000")
print("-----------------------------------------------------------------------------")
print("")

local results = {}

results[#results + 1] = { benchmark("circle(100, 2)", 
    composedCircle(100, 2), 
    Compiler.motion.circle(100, 2)) }

results[#results + 1] = { benchmark("spiral(100, 1, 0.5)", 
    composedSpiral(100, 1, 0.5), 
    Compiler.motion.spiral(100, 1, 0.5)) }

results[#results + 1] = { benchmark("hover(10, 1)", 
    composedHover(10, 1), 
    Compiler.motion.hover(10, 1)) }

results[#results + 1] = { benchmark("shake(5, 10)", 
    composedShake(5, 10), 
    Compiler.motion.shake(5, 10)) }

results[#results + 1] = { benchmark("figure8(100, 1)", 
    composedFigure8(100, 1), 
    Compiler.motion.figure8(100, 1)) }

results[#results + 1] = { benchmark("ellipse(200, 50, 1)", 
    composedEllipse(200, 50, 1), 
    Compiler.motion.ellipse(200, 50, 1)) }

results[#results + 1] = { benchmark("bounce(100, 2)", 
    composedBounce(100, 2), 
    Compiler.motion.bounce(100, 2)) }

-- Calculate averages
local compSum, lutSum, lutCount = 0, 0, 0
for _, r in ipairs(results) do
    compSum = compSum + r[1]
    if r[2] then
        lutSum = lutSum + r[2]
        lutCount = lutCount + 1
    end
end

print("")
print("-----------------------------------------------------------------------------")
print(string.format("Average compiled speedup: %.2fx", compSum / #results))
if lutCount > 0 then
    print(string.format("Average LUT speedup:      %.2fx (vs composed)", lutSum / lutCount))
    print(string.format("LUT vs Compiled:          %.2fx additional speedup", (lutSum / lutCount) / (compSum / #results)))
end
print("=============================================================================")

print("")
print("Memory usage (LUT at 60fps, 1 second duration):")
print(string.format("  circle:  %4d bytes (~%.1f KB for 1000 entities)", 
    Compiler.estimateLUTSize(Compiler.motion.circle(100, 1)),
    Compiler.estimateLUTSize(Compiler.motion.circle(100, 1)) / 1024))
print(string.format("  spiral:  %4d bytes", Compiler.estimateLUTSize(Compiler.motion.spiral(100, 1, 0.5))))
print(string.format("  shake:   %4d bytes", Compiler.estimateLUTSize(Compiler.motion.shake(5, 10))))

print("")
print("When to use each approach:")
print("  Composed:  Development, debugging, rapid iteration")
print("  Compiled:  Production, stateful curves, ctx-dependent")
print("  LUT:       Fixed-fps games, pure periodic motions, maximum performance")

print("")
print("=============================================================================")
print("Batch Evaluation (10,000 entities)")
print("=============================================================================")
print("")

local function benchmarkBatch(name, compiledIR)
    local n = 10000
    local iterations = 100
    
    local singleFn = Compiler.compile(compiledIR)
    local batchFn = Compiler.compileBatchEval(compiledIR, { preallocate = true, withPhase = true })
    local batchLUT = nil
    if Compiler.canUseLUT(compiledIR) then
        batchLUT = Compiler.compileBatchLUT(compiledIR, { fps = 60, duration = 1, preallocate = true })
    end
    
    -- Setup arrays
    local ts = {}
    local phases = {}
    local outX, outY = {}, {}
    for i = 1, n do
        ts[i] = 0
        phases[i] = (i - 1) / n
        outX[i] = 0
        outY[i] = 0
    end
    local ctx = {}
    
    -- Warmup
    for _ = 1, 5 do
        for i = 1, n do singleFn(ts[i] + phases[i], ctx) end
        batchFn(ts, phases, n, outX, outY)
        if batchLUT then batchLUT(ts, phases, n, outX, outY) end
    end
    
    -- Time individual
    local t0 = os.clock()
    for _ = 1, iterations do
        for i = 1, n do
            outX[i], outY[i] = singleFn(ts[i] + phases[i], ctx)
        end
    end
    local singleTime = os.clock() - t0
    
    -- Time batch
    t0 = os.clock()
    for _ = 1, iterations do
        batchFn(ts, phases, n, outX, outY)
    end
    local batchTime = os.clock() - t0
    
    -- Time batch LUT
    local lutTime = nil
    if batchLUT then
        t0 = os.clock()
        for _ = 1, iterations do
            batchLUT(ts, phases, n, outX, outY)
        end
        lutTime = os.clock() - t0
    end
    
    if lutTime then
        print(string.format("%-20s | Individual: %5.2fs | Batch: %5.2fs (%4.2fx) | BatchLUT: %5.2fs (%4.2fx)",
            name, singleTime, batchTime, singleTime/batchTime, lutTime, singleTime/lutTime))
    else
        print(string.format("%-20s | Individual: %5.2fs | Batch: %5.2fs (%4.2fx) | BatchLUT: N/A",
            name, singleTime, batchTime, singleTime/batchTime))
    end
    
    return singleTime/batchTime, lutTime and singleTime/lutTime or nil
end

local batchResults = {}
batchResults[#batchResults + 1] = { benchmarkBatch("circle", Compiler.motion.circle(100, 2)) }
batchResults[#batchResults + 1] = { benchmarkBatch("spiral", Compiler.motion.spiral(100, 1, 0.5)) }
batchResults[#batchResults + 1] = { benchmarkBatch("shake", Compiler.motion.shake(5, 10)) }

print("")
print("Note: With LuaJIT, batch speedups are typically 2-5x higher due to trace compilation.")

print("")
print("=============================================================================")
print("Incremental Rotator (10,000 entities, fixed timestep)")
print("=============================================================================")
print("")
print("Rotator uses rotation matrices: no trig per frame, just 4 mul + 2 add")
print("")

local function benchmarkRotator(name, compiledIR)
    local n = 10000
    local iterations = 100
    
    local compiled = Compiler.compile(compiledIR)
    local rotator, err = Compiler.compileRotator(compiledIR, { fps = 60 })
    
    if not rotator then
        print(string.format("%-20s | Cannot step: %s", name, err))
        return nil
    end
    
    -- Setup
    local states = Compiler.createRotatorStates(rotator, n, nil)
    local ctx = {}
    
    -- Warmup
    for _ = 1, 5 do
        for i = 1, n do compiled(i * 0.001, ctx) end
        rotator.stepBatch(states, n)
    end
    
    -- Time compiled (individual calls)
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
    print(string.format("%-20s | Compiled: %5.2fs | Rotator: %5.2fs | Speedup: %4.2fx",
        name, compiledTime, rotatorTime, speedup))
    
    return speedup
end

benchmarkRotator("circle", Compiler.motion.circle(100, 1))
benchmarkRotator("ellipse", Compiler.motion.ellipse(200, 50, 1))
benchmarkRotator("drift", Compiler.motion.drift(60, 30))

print("")
print("Rotator advantages:")
print("  - No memory overhead (unlike LUT)")
print("  - No trig calls per frame")
print("  - Maintains accuracy over thousands of frames")
print("  - Works at any timestep (just change dt)")

print("")
print("=============================================================================")
print("Generated Code Samples")
print("=============================================================================")
print("")
print("--- Compiled: circle(100, 2) ---")
print(Compiler.toSource(Compiler.motion.circle(100, 2)))
print("")
print("--- LUT: circle(100, 1) at 10fps ---")
local _, lutSrc = Compiler.compileLUTSource(Compiler.motion.circle(100, 1), { fps = 10, duration = 1 })
print(lutSrc)
print("")

print("--- Batch eval with phase (circle, 10k entities) ---")
local _, batchSrc = Compiler.compileBatchEval(Compiler.motion.circle(100, 1), { withPhase = true, preallocate = true })
print(batchSrc)
print("")

print("--- Batch LUT (shared LUT, 10fps for readability) ---")
local _, batchLutSrc = Compiler.compileBatchLUT(Compiler.motion.circle(100, 1), { fps = 10, duration = 1, preallocate = true })
print(batchLutSrc)
print("")

print("--- Rotator (conceptual - actual code is closures) ---")
print([[
-- Precomputed at compile time:
local cosD = cos(freq * dt * 2π)  -- rotation delta
local sinD = sin(freq * dt * 2π)

-- Per frame, per entity (no trig!):
local newX = x * cosD - y * sinD  -- 2 mul, 1 sub
local newY = x * sinD + y * cosD  -- 2 mul, 1 add
]])
