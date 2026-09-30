--[[
    Spatula Visual Benchmark

    Shows multiple motion types with their optimization strategies.
    Verifies FFI/native acceleration is working for each.

    Run with: love love_test benchmark
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
local ENTITIES_PER_MOTION = 5000
local COLUMN_WIDTH = 200
local ROW_HEIGHT = 200

-- Motion definitions to benchmark
local motionDefs = {
    {
        name = "Circle",
        ir = function() return Compiler.motion.circle(80, 0.5) end,
        expected = "rotator",
    },
    {
        name = "Ellipse",
        ir = function() return Compiler.motion.ellipse(80, 50, 0.5) end,
        expected = "rotator",
    },
    {
        name = "Shake",
        ir = function() return Compiler.motion.shake(30, 8) end,
        expected = "lut",
    },
    {
        name = "Figure-8",
        -- figure8(size, speed) - 60px size, 0.5 Hz
        ir = function() return Compiler.motion.figure8(60, 0.5) end,
        expected = "lut",
    },
    {
        name = "Lissajous",
        -- lissajous(freqX, freqY, ampX, ampY, phase) - 3:2 ratio, 60x40px
        ir = function() return Compiler.motion.lissajous(0.5, 0.75, 60, 40, 0) end,
        expected = "lut",
    },
    {
        name = "Orbit",
        ir = function()
            return Compiler.motion.add(
                Compiler.motion.circle(50, 0.3),
                Compiler.motion.circle(20, 1.2)
            )
        end,
        expected = "rotator or lut",
    },
    {
        name = "Hover",
        ir = function() return Compiler.motion.hover(40, 4) end,
        expected = "lut",
    },
    {
        name = "Sway",
        ir = function() return Compiler.motion.sway(50, 0.8) end,
        expected = "lut",
    },
    {
        name = "Bob",
        ir = function() return Compiler.motion.bob(40, 1.5) end,
        expected = "lut",
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

    print("\n=== Spatula Benchmark Results ===")
    print(string.format("FFI: %s", Pool.useFFI and "ON" or "off"))
    print("")

    for i, def in ipairs(motionDefs) do
        local ir = def.ir()
        local pool = Pool.create(Compiler, ir, {
            count = ENTITIES_PER_MOTION,
            fps = 60
        })

        -- Random phases for visual spread
        local phases = {}
        for j = 1, ENTITIES_PER_MOTION do
            phases[j] = math.random() * math.pi * 2
        end
        pool:init(phases)

        local info = pool:info()
        local hasFFI = pool._posX ~= nil
        local matchesExpected = string.find(def.expected, info.strategy) ~= nil

        -- Log results
        local status = matchesExpected and "OK" or "MISMATCH"
        local x1, y1 = pool:get(1)
        print(string.format("[%s] %-12s strategy=%-10s FFI=%-3s pos[1]=(%.1f, %.1f)",
            status,
            def.name,
            info.strategy,
            pool._useFFI and "yes" or "no",
            x1 or 0, y1 or 0
        ))

        benchmarks[i] = {
            name = def.name,
            expected = def.expected,
            pool = pool,
            strategy = info.strategy,
            useFFI = pool._useFFI or false,
            hasFFIArrays = pool._posX ~= nil,
            -- Grid position
            col = ((i - 1) % 3),
            row = math.floor((i - 1) / 3),
        }
    end

    print("")
    print(string.format("Total: %d motions, %d entities each, %d total",
        #motionDefs, ENTITIES_PER_MOTION, #motionDefs * ENTITIES_PER_MOTION))
    print("=================================\n")
end

function love.load()
    screenW, screenH = love.graphics.getDimensions()
    love.graphics.setBackgroundColor(0.08, 0.08, 0.12)

    math.randomseed(os.time())
    initBenchmarks()

    lastTime = love.timer.getTime()
end

function love.update(dt)
    if paused then return end

    local t0 = love.timer.getTime()

    -- Step all pools
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
        "Spatula Benchmark | FPS: %.0f | Step: %.3fms | FFI: %s",
        fps, totalStepTime * 1000,
        Pool.useFFI and "ON" or "off"
    ), 10, 10)
    love.graphics.print(string.format(
        "Entities per motion: %d | Total: %d | [R]eset [SPACE]pause",
        ENTITIES_PER_MOTION, #benchmarks * ENTITIES_PER_MOTION
    ), 10, 28)

    -- Draw each benchmark
    local startY = 60
    local startX = 30

    for _, bench in ipairs(benchmarks) do
        local cx = startX + bench.col * COLUMN_WIDTH + COLUMN_WIDTH / 2
        local cy = startY + bench.row * ROW_HEIGHT + ROW_HEIGHT / 2

        -- Draw boundary
        love.graphics.setColor(0.2, 0.2, 0.3)
        love.graphics.rectangle("line",
            startX + bench.col * COLUMN_WIDTH,
            startY + bench.row * ROW_HEIGHT,
            COLUMN_WIDTH - 10, ROW_HEIGHT - 30)

        -- Draw label
        love.graphics.setColor(1, 1, 1)
        love.graphics.print(bench.name, startX + bench.col * COLUMN_WIDTH + 5, startY + bench.row * ROW_HEIGHT + 2)

        -- Strategy indicator with expected comparison
        local stratColor = {0.5, 0.5, 0.5}
        local matchesExpected = string.find(bench.expected, bench.strategy) ~= nil

        if bench.strategy == "rotator" then
            stratColor = {0.2, 1, 0.4}  -- Green for best
        elseif bench.strategy == "lut" then
            stratColor = {0.4, 0.8, 1}  -- Blue for good
        elseif bench.strategy == "compiled" then
            stratColor = {1, 0.8, 0.3}  -- Yellow for fallback
        end

        love.graphics.setColor(stratColor)
        local statusIcon = matchesExpected and "OK" or "??"
        local ffiStatus = bench.hasFFIArrays and "[FFI]" or ""
        love.graphics.print(string.format("%s %s %s", statusIcon, bench.strategy, ffiStatus),
            startX + bench.col * COLUMN_WIDTH + 5,
            startY + bench.row * ROW_HEIGHT + 16)

        -- Draw entities
        love.graphics.setColor(stratColor[1], stratColor[2], stratColor[3], 0.7)
        love.graphics.setPointSize(2)

        local points = {}
        local pool = bench.pool

        -- Use appropriate access method based on strategy
        if pool._posX and pool._useFFI then
            -- FFI direct access
            for i = 0, pool.count - 1 do
                points[#points + 1] = cx + pool._posX[i]
                points[#points + 1] = cy + pool._posY[i]
            end
        else
            -- Lua table access
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
