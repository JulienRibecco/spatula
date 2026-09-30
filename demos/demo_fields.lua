--- Demo 2: Field-Driven AI
--- Entities follow field gradients. Click to place attractors/repulsors.

local Field = require("spatula.field")

local M = {}

local field
local entities = {}
local NUM_ENTITIES = 80
local screenW, screenH
local time = 0

-- Entity: a dot that steers via field gradient
local function spawnEntity(x, y)
    return {
        x = x, y = y,
        vx = 0, vy = 0,
        speed = 60 + math.random() * 40,
        trail = {},
    }
end

function M.load()
    screenW, screenH = love.graphics.getDimensions()

    field = Field.new({ falloff = "smooth", blend = "add", base = 0 })

    -- Seed a few attractors
    field:add(screenW * 0.3, screenH * 0.5, { radius = 250, value = 1 })
    field:add(screenW * 0.7, screenH * 0.5, { radius = 250, value = 1 })
    field:add(screenW * 0.5, screenH * 0.3, { radius = 200, value = -0.8 })

    -- Spawn entities scattered
    entities = {}
    for i = 1, NUM_ENTITIES do
        local ex = 100 + math.random() * (screenW - 200)
        local ey = 100 + math.random() * (screenH - 200)
        entities[i] = spawnEntity(ex, ey)
    end
end

function M.update(dt)
    time = time + dt
    local damping = 0.92

    for _, e in ipairs(entities) do
        -- Sample gradient at entity position
        local gx, gy = field:gradient(e.x, e.y)
        local mag = math.sqrt(gx * gx + gy * gy)

        if mag > 0.001 then
            -- Normalize and steer toward ascending gradient
            e.vx = e.vx + (gx / mag) * e.speed * dt * 3
            e.vy = e.vy + (gy / mag) * e.speed * dt * 3
        end

        -- Damping
        e.vx = e.vx * damping
        e.vy = e.vy * damping

        -- Integrate
        e.x = e.x + e.vx * dt
        e.y = e.y + e.vy * dt

        -- Soft boundary wrap
        if e.x < 0 then e.x = screenW end
        if e.x > screenW then e.x = 0 end
        if e.y < 0 then e.y = screenH end
        if e.y > screenH then e.y = 0 end

        -- Trail
        e.trail[#e.trail + 1] = { x = e.x, y = e.y }
        if #e.trail > 30 then table.remove(e.trail, 1) end
    end
end

function M.draw()
    -- Draw field heatmap (low-res grid)
    local step = 16
    for gx = 0, screenW, step do
        for gy = 0, screenH, step do
            local v = field:sample(gx, gy)
            if v > 0 then
                love.graphics.setColor(0.1, 0.3 + v * 0.4, 0.5 + v * 0.3, 0.3 + v * 0.3)
            else
                love.graphics.setColor(0.5 - v * 0.3, 0.1, 0.15, 0.3 + math.abs(v) * 0.3)
            end
            love.graphics.rectangle("fill", gx, gy, step, step)
        end
    end

    -- Draw sources
    for _, source in pairs(field.sources) do
        if source.active then
            if source.value > 0 then
                love.graphics.setColor(0.2, 0.8, 0.5, 0.6)
            else
                love.graphics.setColor(0.9, 0.2, 0.3, 0.6)
            end
            love.graphics.circle("line", source.x, source.y, source.radius)
            love.graphics.circle("fill", source.x, source.y, 5)
        end
    end

    -- Draw entities
    for _, e in ipairs(entities) do
        -- Trail
        for i, pt in ipairs(e.trail) do
            local alpha = i / #e.trail
            love.graphics.setColor(1, 0.8, 0.3, alpha * 0.4)
            love.graphics.circle("fill", pt.x, pt.y, 1.5)
        end
        -- Dot
        love.graphics.setColor(1, 0.9, 0.4, 1)
        love.graphics.circle("fill", e.x, e.y, 3)
    end

    -- UI
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print("Field-Driven AI", 20, 20)
    love.graphics.print("Entities steer via field gradient", 20, 42)
    love.graphics.print(string.format("Sources: %d  |  Entities: %d", field:count(), #entities), 20, 64)

    love.graphics.setColor(0.6, 0.6, 0.6, 1)
    love.graphics.print("LEFT-CLICK: add attractor  |  RIGHT-CLICK: add repulsor  |  C: clear sources", 20, screenH - 30)
end

function M.keypressed(key)
    if key == "c" then
        field:clear()
    end
end

function M.mousepressed(x, y, button)
    if button == 1 then
        field:add(x, y, { radius = 200 + math.random() * 100, value = 1 })
    elseif button == 2 then
        field:add(x, y, { radius = 200 + math.random() * 100, value = -0.8 })
    end
end

return M
