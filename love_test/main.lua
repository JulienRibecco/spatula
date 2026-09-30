--[[
    Spatula Pool Benchmark

    Controls:
    - UP/DOWN: Add/remove 1000 entities
    - R: Reset entities
    - SPACE: Pause/resume
    - T: Run tests

    Run with: love love_test
]]

-- Check for test/benchmark mode
local args = arg or {}
for _, v in ipairs(args) do
    if v == "benchmark" then
        require("benchmark")
        return
    elseif v == "complex" or v == "benchmark_complex" then
        require("benchmark_complex")
        return
    end
end

-- Add compiler to path (LÖVE uses the project dir as cwd)
local basePath = love.filesystem.getSource()
package.path = package.path
    .. ";" .. basePath .. "/../compiler/?.lua"
    .. ";" .. basePath .. "/../compiler/?/init.lua"
    .. ";" .. basePath .. "/../compiler/strategies/?.lua"
    .. ";" .. basePath .. "/../compiler/pool/?.lua"

local Compiler = require("compiler")
local Pool = require("pool")

-- Configuration
local INITIAL_ENTITIES = 5000
local ENTITY_STEP = 1000
local MAX_ENTITIES = 200000  -- Can go much higher with mesh batching

-- State
local pools = {}
local paused = false
local screenW, screenH
local centerX, centerY

-- Rendering
local mesh = nil
local meshCapacity = 0
local vertices = {}  -- Reusable vertex buffer

-- Stats
local frameCount = 0
local lastTime = 0
local fps = 0
local stepTime = 0
local drawTime = 0

-- Create a pool of entities with circular motion
local function createPool(count, radius, freq)
    radius = radius or 200
    freq = freq or 0.5

    local pool = Pool.create(Compiler, Compiler.motion.circle(radius, freq), {
        count = count,
        fps = 60
    })

    -- Deterministic phases for consistent results
    local phases = {}
    for i = 1, count do
        phases[i] = (i / count) * math.pi * 2
    end
    pool:init(phases)

    return pool
end

-- Reset all pools
local function resetPools()
    pools = {}

    -- Create main pool with fixed parameters
    pools[1] = createPool(INITIAL_ENTITIES, 200, 0.5)
end

-- Add more entities
local function addEntities(count)
    local currentCount = 0
    for _, p in ipairs(pools) do
        currentCount = currentCount + p.count
    end

    if currentCount + count > MAX_ENTITIES then
        count = MAX_ENTITIES - currentCount
    end

    if count > 0 then
        -- Vary radius slightly for visual distinction
        local radius = 150 + (#pools * 30)
        local newPool = createPool(count, radius, 0.5)
        pools[#pools + 1] = newPool
    end
end

-- Remove entities
local function removeEntities(count)
    while count > 0 and #pools > 0 do
        local lastPool = pools[#pools]
        if lastPool.count <= count then
            count = count - lastPool.count
            pools[#pools] = nil
        else
            -- Can't partially remove from a pool, just remove the whole thing
            pools[#pools] = nil
            break
        end
    end

end

-- Count total entities
local function getTotalEntities()
    local total = 0
    for _, p in ipairs(pools) do
        total = total + p.count
    end
    return total
end

-- Ensure mesh has enough capacity
local function ensureMeshCapacity(count)
    if count <= meshCapacity then return end

    -- Round up to next power of 2 for fewer reallocations
    local newCapacity = 1024
    while newCapacity < count do
        newCapacity = newCapacity * 2
    end

    -- Create mesh with points draw mode
    -- Vertex format: {x, y, r, g, b, a}
    mesh = love.graphics.newMesh(
        {{"VertexPosition", "float", 2}, {"VertexColor", "byte", 4}},
        newCapacity,
        "points",
        "dynamic"
    )
    meshCapacity = newCapacity

    -- Pre-allocate vertex table
    vertices = {}
    for i = 1, newCapacity do
        vertices[i] = {0, 0, 102, 204, 255, 204}  -- x, y, r, g, b, a (0.4, 0.8, 1.0, 0.8)
    end
end

function love.load()
    screenW, screenH = love.graphics.getDimensions()
    centerX, centerY = screenW / 2, screenH / 2

    love.graphics.setBackgroundColor(0.1, 0.1, 0.15)

    resetPools()

    lastTime = love.timer.getTime()
end

function love.update(dt)
    if paused then return end

    local t0 = love.timer.getTime()

    -- Step all pools
    for _, p in ipairs(pools) do
        p:step()
    end

    stepTime = love.timer.getTime() - t0

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
    local t0 = love.timer.getTime()

    local totalEntities = getTotalEntities()
    ensureMeshCapacity(totalEntities)

    -- Update vertex positions directly from FFI arrays (0-indexed)
    local idx = 1
    for _, pool in ipairs(pools) do
        local px, py = pool._posX, pool._posY
        local count = pool.count
        for i = 0, count - 1 do
            local v = vertices[idx]
            v[1] = centerX + px[i]
            v[2] = centerY + py[i]
            idx = idx + 1
        end
    end

    -- Upload to mesh and draw
    if totalEntities > 0 then
        mesh:setVertices(vertices, 1, totalEntities)
        mesh:setDrawRange(1, totalEntities)
        love.graphics.setPointSize(2)
        love.graphics.setColor(1, 1, 1)
        love.graphics.draw(mesh)
    end

    drawTime = love.timer.getTime() - t0

    -- Draw UI
    love.graphics.setColor(1, 1, 1)

    local lines = {
        string.format("FPS: %.1f", fps),
        string.format("Entities: %dk", totalEntities / 1000),
        string.format("Step: %.3f ms | Draw: %.2f ms", stepTime * 1000, drawTime * 1000),
        string.format("FFI: %s", Pool.useFFI and "ON" or "off"),
        "",
        "UP/DOWN - Add/remove 1k entities",
        "R - Reset | SPACE - Pause",
    }

    for i, line in ipairs(lines) do
        love.graphics.print(line, 10, 10 + (i - 1) * 18)
    end
end

function love.keypressed(key)
    local step = love.keyboard.isDown("lshift", "rshift") and 10000 or ENTITY_STEP

    if key == "up" then
        addEntities(step)
        print("Total entities: " .. getTotalEntities())

    elseif key == "down" then
        removeEntities(step)
        print("Total entities: " .. getTotalEntities())

    elseif key == "r" then
        resetPools()
        print("Reset to " .. INITIAL_ENTITIES .. " entities")

    elseif key == "space" then
        paused = not paused
        print(paused and "Paused" or "Resumed")

    elseif key == "escape" then
        love.event.quit()
    end
end
