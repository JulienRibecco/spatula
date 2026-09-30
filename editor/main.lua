--[[
    Spatula Editor - Visual Node Graph Editor

    Run with: love editor   (from the spatula directory)

    Controls:
    - Drag from palette to create nodes
    - Drag between ports to wire
    - Right-click node to delete
    - Right-click input port to disconnect
    - Mouse wheel: Zoom in/out
    - Middle-drag: Pan canvas
    - Shift+click: Add/remove from selection
    - Drag on empty: Box select
    - Ctrl+A: Select all
    - Escape: Clear selection / cancel wire
    - Delete/Backspace: Delete selected nodes
    - Home: Reset camera

    Live Co-Pilot (Claude Code integration):
    - E: Export state (graph.json + preview.png)
    - R: Manual refresh (check for edits)
    - M: Toggle mode (auto/confirm)
    - Y/N: Accept/reject pending edits (in confirm mode)
    - Z: Undo last edit batch

    Development:
    - F5: Hot reload (reload all spatula modules, preserves graph)
]]

-- Setup package path to find spatula modules
local srcDir = love.filesystem.getSource()  -- .../spatula/editor
local spatulaRoot = srcDir .. "/.."          -- .../spatula
local gameRoot = srcDir .. "/../.."          -- .../game
package.path = gameRoot .. "/?.lua;"
    .. gameRoot .. "/?/init.lua;"
    .. spatulaRoot .. "/?.lua;"
    .. spatulaRoot .. "/?/init.lua;"
    .. package.path

local Editor = require("spatula.editor")
local editor = Editor.new()

-- Hot-reload function: reloads editor code while preserving graph state
local function hotReload()
    -- Save current state
    local savedNodes = editor.nodes
    local savedCables = editor.cables
    local savedNextId = editor.nextNodeId
    local savedCamera = {x = editor.cameraX, y = editor.cameraY, zoom = editor.zoom}

    -- Clear cached modules
    for name, _ in pairs(package.loaded) do
        if name:match("^spatula") then
            package.loaded[name] = nil
        end
    end

    -- Reload editor module
    local ok, newEditor = pcall(require, "spatula.editor")
    if ok then
        Editor = newEditor
        editor = Editor.new()
        editor:load(love.graphics.getWidth(), love.graphics.getHeight())

        -- Restore state
        editor.cameraX = savedCamera.x
        editor.cameraY = savedCamera.y
        editor.zoom = savedCamera.zoom

        -- Rebuild nodes with new definitions
        local newNodes = {}
        for id, node in pairs(savedNodes) do
            local def = nil
            for _, d in ipairs(editor.nodeDefs) do
                if d.type == node.type then def = d; break end
            end
            if def then
                local rebuilt = editor:createNode(def, node.x, node.y)
                rebuilt.id = node.id
                -- Restore knob values
                for k, v in pairs(node.knobValues or {}) do
                    if rebuilt.knobValues[k] ~= nil then
                        rebuilt.knobValues[k] = v
                    end
                end
                newNodes[rebuilt.id] = rebuilt
            end
        end
        editor.nodes = newNodes
        editor.nextNodeId = savedNextId

        -- Restore cables
        for _, cable in ipairs(savedCables) do
            local fromNode = editor.nodes[cable.fromNode]
            local toNode = editor.nodes[cable.toNode]
            if fromNode and toNode then
                editor:addCable(cable.fromNode, cable.fromPort, cable.toNode, cable.toPort)
            end
        end

        print("Hot reload successful!")
        if editor.Live then
            editor.Live.setStatus("Hot reload: code updated")
        end
    else
        print("Hot reload failed: " .. tostring(newEditor))
        if editor.Live then
            editor.Live.setStatus("Hot reload FAILED: " .. tostring(newEditor):sub(1, 50))
        end
    end
end

function love.load()
    love.graphics.setBackgroundColor(0.08, 0.08, 0.12)
    editor:load(love.graphics.getWidth(), love.graphics.getHeight())
end

function love.update(dt)
    editor:update(dt)
end

function love.draw()
    editor:draw()
end

function love.mousepressed(x, y, button)
    editor:mousepressed(x, y, button)
end

function love.mousereleased(x, y, button)
    editor:mousereleased(x, y, button)
end

function love.mousemoved(x, y)
    editor:mousemoved(x, y)
end

function love.keypressed(key)
    -- F5: Hot reload code
    if key == "f5" then
        hotReload()
        return
    end
    editor:keypressed(key)
end

function love.resize(w, h)
    editor.screenW = w
    editor.screenH = h
end

function love.wheelmoved(dx, dy)
    editor:wheelmoved(dx, dy)
end
