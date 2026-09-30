--- Demo 1: Motion Composer — Visual node editor
--- Uses spatula.editor to compose curves into motions interactively.

local Curve = require("spatula.curve")
local Motion = require("spatula.motion")
local Editor = require("spatula.editor")

local M = {}

local editor
local screenW, screenH
local time = 0
local trail = {}
local MAX_TRAIL = 500

local currentMotion
local scatterEntities = {}
local xyNodeId

local function rebuildMotion()
    local motion, scatterPoints = editor:buildMotion()
    currentMotion = motion

    scatterEntities = {}
    if #scatterPoints > 0 then
        local n = #scatterPoints
        for i, pt in ipairs(scatterPoints) do
            scatterEntities[i] = {
                x = pt.x, y = pt.y,
                ox = pt.x, oy = pt.y,
                phase = (i / n) * math.pi * 2,
                curveState = {},
            }
        end
    end

    trail = {}
    time = 0
end

function M.load()
    screenW, screenH = love.graphics.getDimensions()

    editor = Editor.new()
    editor:load(screenW, screenH)
    editor:onGraphChanged(function()
        rebuildMotion()
    end)

    -- Create the motion output node
    local xyNode = editor:createNode({
        type = "xy_output",
        label = "Motion.xy",
        color = {0.5, 0.35, 0.2},
        inputs = {"x", "y"},
        outputs = {"x", "y"},
        buildCurve = function() return Curve.const(0) end,
    }, screenW / 2 - 70, screenH / 2 + 30)
    xyNodeId = xyNode.id

    currentMotion = Motion.xy(Curve.const(0), Curve.const(0))
end

function M.update(dt)
    time = time + dt
    editor:update(dt)

    -- Record trail
    local ctx = { curveState = {} }
    local ok, x, y = pcall(currentMotion, time, ctx)
    if ok then
        trail[#trail + 1] = { x = x, y = y }
        if #trail > MAX_TRAIL then table.remove(trail, 1) end
    end

    -- Share trail with editor for chain preview of xy_output
    editor.trail = trail

    -- Animate scatter entities
    if #scatterEntities > 0 then
        for _, e in ipairs(scatterEntities) do
            local ectx = { curveState = e.curveState }
            local eok, mx, my = pcall(currentMotion, time + e.phase, ectx)
            if eok then
                e.x = e.ox + mx
                e.y = e.oy + my
            end
        end
    end
end

--------------------------------------------------------------------------------
-- DRAW
--------------------------------------------------------------------------------

local function drawPreviewPane(cx, cy, r, label)
    love.graphics.setColor(0.06, 0.06, 0.1, 0.6)
    love.graphics.circle("fill", cx, cy, r)
    love.graphics.setColor(0.2, 0.2, 0.25, 0.4)
    love.graphics.circle("line", cx, cy, r)
    love.graphics.setColor(0.25, 0.25, 0.3, 0.4)
    love.graphics.line(cx - 12, cy, cx + 12, cy)
    love.graphics.line(cx, cy - 12, cx, cy + 12)
    love.graphics.setColor(0.4, 0.4, 0.5, 0.6)
    love.graphics.print(label, cx - 25, cy + r + 4)
end

local function drawVisualization()
    local xyNode = editor.nodes[xyNodeId]
    if not xyNode then return end

    local hasScatter = #scatterEntities > 0
    local vizR = hasScatter and 90 or 120

    local trailCx = xyNode.x + Editor.NODE_W / 2
    local trailCy = xyNode.y - vizR - 20
    if hasScatter then
        trailCx = trailCx - vizR - 10
    end

    drawPreviewPane(trailCx, trailCy, vizR, "motion")

    for i = 1, #trail do
        local alpha = i / #trail
        local pt = trail[i]
        local dx = math.max(-vizR+5, math.min(vizR-5, pt.x))
        local dy = math.max(-vizR+5, math.min(vizR-5, pt.y))
        love.graphics.setColor(0.5, 0.75, 1.0, alpha * 0.6)
        love.graphics.circle("fill", trailCx + dx, trailCy + dy, 1.2 + alpha * 1.2)
    end
    if #trail > 0 then
        local pt = trail[#trail]
        local dx = math.max(-vizR+5, math.min(vizR-5, pt.x))
        local dy = math.max(-vizR+5, math.min(vizR-5, pt.y))
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.circle("fill", trailCx + dx, trailCy + dy, 4)
    end

    if hasScatter then
        local scatCx = xyNode.x + Editor.NODE_W / 2 + vizR + 10
        local scatCy = trailCy

        drawPreviewPane(scatCx, scatCy, vizR, string.format("scatter (%d)", #scatterEntities))

        for _, e in ipairs(scatterEntities) do
            love.graphics.setColor(0.4, 0.75, 1.0, 0.8)
            love.graphics.circle("fill", scatCx + e.x, scatCy + e.y, 2)
        end
    end
end

function M.draw()
    editor:draw()
    drawVisualization()
end

function M.mousepressed(x, y, button)
    editor:mousepressed(x, y, button)
end

function M.mousereleased(x, y, button)
    editor:mousereleased(x, y, button)
end

function M.mousemoved(x, y)
    editor:mousemoved(x, y)
end

function M.keypressed(key)
    editor:keypressed(key)
end

return M
