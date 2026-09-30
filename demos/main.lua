--[[
    Spatula Demos

    A scene-based demo launcher showcasing Spatula capabilities.
    Run with: love demos   (from the spatula directory)

    Controls:
    - 1/2/3: Switch demo
    - ESC: Quit
    - Each demo has its own controls shown at the bottom
]]

-- require("spatula.curve") needs a path entry where spatula/ is a subdirectory.
-- demos/ is inside spatula/, so the parent of spatula/ (i.e. game/) is what we need.
local srcDir = love.filesystem.getSource()  -- .../spatula/demos
local spatulaRoot = srcDir .. "/.."          -- .../spatula
local gameRoot = srcDir .. "/../.."          -- .../game
package.path = gameRoot .. "/?.lua;"
    .. gameRoot .. "/?/init.lua;"
    .. srcDir .. "/?.lua;"
    .. package.path

local scenes = {
    { name = "Motion Showcase",   mod = require("demo_motions") },
    { name = "Field-Driven AI",   mod = require("demo_fields") },
    { name = "Signal Reactivity", mod = require("demo_signals") },
}

local currentScene = 1

local function switchScene(idx)
    currentScene = idx
    scenes[idx].mod.load()
end

function love.load()
    love.graphics.setBackgroundColor(0.08, 0.08, 0.12)
    love.graphics.setFont(love.graphics.newFont(14))
    switchScene(1)
end

function love.update(dt)
    scenes[currentScene].mod.update(dt)
end

function love.draw()
    scenes[currentScene].mod.draw()

    -- Scene selector bar at top-right
    love.graphics.setColor(0.15, 0.15, 0.18, 0.85)
    love.graphics.rectangle("fill", love.graphics.getWidth() - 420, 0, 420, 26)
    for i, s in ipairs(scenes) do
        if i == currentScene then
            love.graphics.setColor(0.3, 0.7, 1.0, 1)
        else
            love.graphics.setColor(0.6, 0.6, 0.65, 1)
        end
        local x = love.graphics.getWidth() - 415 + (i - 1) * 140
        love.graphics.print(string.format("[%d] %s", i, s.name), x, 5)
    end
end

function love.keypressed(key)
    if key == "escape" then
        love.event.quit()
    elseif key == "1" or key == "2" or key == "3" then
        local idx = tonumber(key)
        if idx >= 1 and idx <= #scenes then
            switchScene(idx)
        end
    else
        scenes[currentScene].mod.keypressed(key)
    end
end

function love.mousepressed(x, y, button)
    scenes[currentScene].mod.mousepressed(x, y, button)
end

function love.mousereleased(x, y, button)
    local mod = scenes[currentScene].mod
    if mod.mousereleased then mod.mousereleased(x, y, button) end
end

function love.mousemoved(x, y, dx, dy)
    local mod = scenes[currentScene].mod
    if mod.mousemoved then mod.mousemoved(x, y) end
end
