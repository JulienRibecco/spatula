--[[
    Spatula Complex Composition Benchmark

    Shows advanced motion compositions:
    - Layered motions (orbit + wobble + shake)
    - Modulated motions (pulsing radius, breathing)
    - Blended motions (lerp between patterns)
    - Nested compositions

    Run with: love love_test benchmark_complex
]]

-- Add compiler to path
local basePath = love.filesystem.getSource()
package.path = package.path
    .. ";" .. basePath .. "/../compiler/?.lua"
    .. ";" .. basePath .. "/../compiler/?/init.lua"
    .. ";" .. basePath .. "/../compiler/strategies/?.lua"
    .. ";" .. basePath .. "/../compiler/pool/?.lua"

local Compiler = require("compiler")
local Pool = require("pool")

-- Configuration
local ENTITIES_PER_MOTION = 3000
local COLUMN_WIDTH = 220
local ROW_HEIGHT = 220

-- Rotation acceleration (radians/sec²) - rotation speeds up over time
local ROT_SLOW = 0.1
local ROT_MED = 0.15
local ROT_FAST = 0.25

-- Helper: accelerating rotation (angle = speed * t²)
local function accelRotation(speed)
    return Compiler.curve.mul(
        Compiler.curve.linear(speed),  -- speed * t
        Compiler.curve.linear(1)       -- * t = speed * t²
    )
end

-- Complex motion definitions (all rotating)
local motionDefs = {
    -- 1. Pulsing Circle: radius oscillates with sin wave
    {
        name = "Pulsing Circle",
        ir = function()
            return Compiler.motion.rotate(
                Compiler.motion.scale(
                    Compiler.motion.circle(1, 0.5),  -- unit circle at 0.5 Hz
                    Compiler.curve.add(
                        Compiler.curve.const(60),     -- base radius 60
                        Compiler.curve.sin(2, 30)     -- +/- 30 at 2 Hz
                    )
                ),
                accelRotation(ROT_SLOW)  -- accelerating rotation
            )
        end,
        desc = "circle + sin radius + rot",
    },

    -- 2. Spiral Outward: circle that expands over time
    {
        name = "Spiral Out",
        ir = function()
            return Compiler.motion.rotate(
                Compiler.motion.scale(
                    Compiler.motion.circle(1, 1),     -- 1 Hz rotation
                    Compiler.curve.linear(40)         -- radius grows 40px/sec
                ),
                accelRotation(ROT_MED)
            )
        end,
        desc = "circle * linear + rot",
    },

    -- 3. Wobbly Orbit: big circle + small fast wobble
    {
        name = "Wobbly Orbit",
        ir = function()
            return Compiler.motion.rotate(
                Compiler.motion.add(
                    Compiler.motion.circle(50, 0.3),  -- slow outer orbit
                    Compiler.motion.circle(15, 3)    -- fast inner wobble
                ),
                accelRotation(ROT_SLOW)
            )
        end,
        desc = "circle + circle + rot",
    },

    -- 4. Breathing Figure-8: figure-8 with pulsing amplitude
    {
        name = "Breathing 8",
        ir = function()
            return Compiler.motion.rotate(
                Compiler.motion.scale(
                    Compiler.motion.figure8(1, 0.5),  -- unit figure-8
                    Compiler.curve.add(
                        Compiler.curve.const(50),
                        Compiler.curve.sin(1.5, 20)   -- breathe at 1.5 Hz
                    )
                ),
                accelRotation(ROT_MED)
            )
        end,
        desc = "figure8 * breathing + rot",
    },

    -- 5. Orbit with Trail: ellipse + drift
    {
        name = "Drifting Ellipse",
        ir = function()
            return Compiler.motion.rotate(
                Compiler.motion.add(
                    Compiler.motion.ellipse(40, 25, 0.8),
                    Compiler.motion.drift(10, 5)      -- slow drift
                ),
                accelRotation(ROT_FAST)
            )
        end,
        desc = "ellipse + drift + rot",
    },

    -- 6. Complex Lissajous: 3:4 ratio with modulated phase
    {
        name = "Lissajous 3:4",
        ir = function()
            return Compiler.motion.rotate(
                Compiler.motion.lissajous(0.75, 1, 55, 45, math.pi/4),
                accelRotation(ROT_SLOW)
            )
        end,
        desc = "lissajous 3:4 + rot",
    },

    -- 7. Shaky Circle: circle with high-freq noise
    {
        name = "Shaky Circle",
        ir = function()
            return Compiler.motion.rotate(
                Compiler.motion.add(
                    Compiler.motion.circle(45, 0.4),
                    Compiler.motion.shake(8, 15)      -- subtle shake
                ),
                accelRotation(ROT_MED)
            )
        end,
        desc = "circle + shake + rot",
    },

    -- 8. Hovering Bounce: vertical bounce + horizontal sway
    {
        name = "Float & Sway",
        ir = function()
            return Compiler.motion.rotate(
                Compiler.motion.xy(
                    Compiler.curve.sin(0.7, 40),      -- horizontal sway
                    Compiler.curve.add(
                        Compiler.curve.sin(1.2, 30),  -- main bounce
                        Compiler.curve.sin(2.4, 10)  -- secondary bounce
                    )
                ),
                accelRotation(ROT_SLOW)
            )
        end,
        desc = "sway + bounce + rot",
    },

    -- 9. Petal Pattern: rotated lissajous creating flower
    {
        name = "Petal Pattern",
        ir = function()
            return Compiler.motion.rotate(
                Compiler.motion.lissajous(0.5, 1.5, 50, 50, 0),
                accelRotation(ROT_FAST)  -- faster rotation for petal effect
            )
        end,
        desc = "lissajous 1:3 + rot",
    },

    -- 10. Damped Orbit: circle with decreasing radius (simulated)
    {
        name = "Pulse Wave",
        ir = function()
            return Compiler.motion.rotate(
                Compiler.motion.scale(
                    Compiler.motion.circle(1, 2),
                    Compiler.curve.mul(
                        Compiler.curve.sin(0.5, 50),  -- base pulse
                        Compiler.curve.add(
                            Compiler.curve.const(1),
                            Compiler.curve.sin(3, 0.3)  -- modulation
                        )
                    )
                ),
                accelRotation(ROT_MED)
            )
        end,
        desc = "circle * mod sin + rot",
    },

    -- 11. Infinity Loop: symmetric lemniscate (figure-8 on its side)
    {
        name = "Infinity",
        ir = function()
            return Compiler.motion.rotate(
                Compiler.motion.xy(
                    Compiler.curve.sin(0.5, 55),           -- x = sin(t)
                    Compiler.curve.sin(1.0, 35, math.pi/2) -- y = sin(2t), phase shifted
                ),
                accelRotation(ROT_SLOW)
            )
        end,
        desc = "lemniscate + rot",
    },

    -- 12. Heartbeat: sharp bounce pattern using abs(sin)
    {
        name = "Heartbeat",
        ir = function()
            return Compiler.motion.rotate(
                Compiler.motion.xy(
                    Compiler.curve.sin(1.5, 15),           -- subtle x wobble
                    Compiler.curve.mul(
                        Compiler.curve.sin(3, 1),          -- fast oscillation
                        Compiler.curve.abs(Compiler.curve.sin(1.5, 45))  -- envelope
                    )
                ),
                accelRotation(ROT_MED)
            )
        end,
        desc = "heartbeat + rot",
    },
}

-- State
local benchmarks = {}
local screenW, screenH
local paused = false
local frameCount = 0
local lastTime = 0
local fps = 0
local totalStepTime = 0

-- Initialize all benchmarks
local function initBenchmarks()
    benchmarks = {}

    print("\n=== Complex Composition Benchmark ===")
    print(string.format("FFI: %s", Pool.useFFI and "ON" or "off"))
    print("")

    for i, def in ipairs(motionDefs) do
        local ok, ir = pcall(def.ir)
        if not ok then
            print(string.format("[ERROR] %s: %s", def.name, ir))
        else
            local pool = Pool.create(Compiler, ir, {
                count = ENTITIES_PER_MOTION,
                fps = 60,
                duration = 2  -- 2 second LUT for complex motions
            })

            -- Random phases for visual spread
            local phases = {}
            for j = 1, ENTITIES_PER_MOTION do
                phases[j] = math.random() * math.pi * 2
            end
            pool:init(phases)

            local info = pool:info()
            print(string.format("[%s] %-18s %s",
                info.strategy,
                def.name,
                def.desc))

            benchmarks[i] = {
                name = def.name,
                desc = def.desc,
                pool = pool,
                strategy = info.strategy,
                col = ((i - 1) % 4),
                row = math.floor((i - 1) / 4),
            }
        end
    end

    print("")
    print(string.format("Total: %d compositions, %d entities each, %d total",
        #benchmarks, ENTITIES_PER_MOTION, #benchmarks * ENTITIES_PER_MOTION))
    print("=====================================\n")
end

function love.load()
    screenW, screenH = love.graphics.getDimensions()
    love.graphics.setBackgroundColor(0.05, 0.05, 0.08)

    math.randomseed(os.time())
    initBenchmarks()

    lastTime = love.timer.getTime()
end

function love.update(dt)
    if paused then return end

    local t0 = love.timer.getTime()
    for _, bench in ipairs(benchmarks) do
        bench.pool:step()
    end
    totalStepTime = love.timer.getTime() - t0

    -- FPS calculation
    frameCount = frameCount + 1
    local now = love.timer.getTime()
    if now - lastTime >= 1.0 then
        fps = frameCount / (now - lastTime)
        frameCount = 0
        lastTime = now
    end
end

function love.draw()
    -- Draw header
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(string.format(
        "Complex Compositions | FPS: %.0f | Step: %.3fms | FFI: %s",
        fps, totalStepTime * 1000,
        Pool.useFFI and "ON" or "off"
    ), 10, 10)
    love.graphics.print(string.format(
        "Entities: %d per motion, %d total | [R]eset [SPACE]pause",
        ENTITIES_PER_MOTION, #benchmarks * ENTITIES_PER_MOTION
    ), 10, 28)

    -- Draw each benchmark
    local startY = 55
    local startX = 20

    for _, bench in ipairs(benchmarks) do
        local cx = startX + bench.col * COLUMN_WIDTH + COLUMN_WIDTH / 2
        local cy = startY + bench.row * ROW_HEIGHT + ROW_HEIGHT / 2

        -- Draw boundary
        love.graphics.setColor(0.15, 0.15, 0.2)
        love.graphics.rectangle("fill",
            startX + bench.col * COLUMN_WIDTH,
            startY + bench.row * ROW_HEIGHT,
            COLUMN_WIDTH - 8, ROW_HEIGHT - 8)
        love.graphics.setColor(0.25, 0.25, 0.35)
        love.graphics.rectangle("line",
            startX + bench.col * COLUMN_WIDTH,
            startY + bench.row * ROW_HEIGHT,
            COLUMN_WIDTH - 8, ROW_HEIGHT - 8)

        -- Draw label
        love.graphics.setColor(1, 1, 1, 0.9)
        love.graphics.print(bench.name, startX + bench.col * COLUMN_WIDTH + 4, startY + bench.row * ROW_HEIGHT + 2)

        -- Strategy indicator
        local stratColor = {0.5, 0.5, 0.5}
        if bench.strategy == "rotator" then
            stratColor = {0.3, 1, 0.5}
        elseif bench.strategy == "lut" then
            stratColor = {0.4, 0.8, 1}
        elseif bench.strategy == "compiled" then
            stratColor = {1, 0.7, 0.3}
        elseif bench.strategy == "hybrid" then
            stratColor = {1, 0.5, 0.8}
        end

        love.graphics.setColor(stratColor[1], stratColor[2], stratColor[3], 0.7)
        love.graphics.print(bench.strategy,
            startX + bench.col * COLUMN_WIDTH + 4,
            startY + bench.row * ROW_HEIGHT + 14)

        -- Draw entities
        love.graphics.setColor(stratColor[1], stratColor[2], stratColor[3], 0.6)
        love.graphics.setPointSize(2)

        local points = {}
        local pool = bench.pool

        -- Use appropriate access method
        if pool._posX and pool._useFFI then
            for i = 0, pool.count - 1 do
                points[#points + 1] = cx + pool._posX[i]
                points[#points + 1] = cy + pool._posY[i]
            end
        else
            for i = 1, pool.count do
                local x, y = pool:get(i)
                points[#points + 1] = cx + x
                points[#points + 1] = cy + y
            end
        end

        if #points > 0 then
            love.graphics.points(points)
        end
    end
end

function love.keypressed(key)
    if key == "r" then
        initBenchmarks()
    elseif key == "space" then
        paused = not paused
    elseif key == "escape" then
        love.event.quit()
    end
end
