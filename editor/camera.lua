--- editor.camera - Coordinate conversion and viewport management
--- @module spatula.editor.camera

local Camera = {}
Camera.__index = Camera

--- Create a new camera
--- @return table Camera instance
function Camera.new()
    return setmetatable({
        x = 0,      -- Pan offset X (screen space)
        y = 0,      -- Pan offset Y (screen space)
        zoom = 1,   -- Scale factor (0.25 to 2.0)
    }, Camera)
end

--- Convert screen coordinates to world coordinates
--- @param sx number Screen X
--- @param sy number Screen Y
--- @return number, number World X, World Y
function Camera:screenToWorld(sx, sy)
    return (sx - self.x) / self.zoom,
           (sy - self.y) / self.zoom
end

--- Convert world coordinates to screen coordinates
--- @param wx number World X
--- @param wy number World Y
--- @return number, number Screen X, Screen Y
function Camera:worldToScreen(wx, wy)
    return wx * self.zoom + self.x,
           wy * self.zoom + self.y
end

--- Reset camera to default view
function Camera:reset()
    self.x = 0
    self.y = 0
    self.zoom = 1
end

--- Set scissor in world coordinates (converts to screen space for proper clipping with zoom)
--- @param wx number World X
--- @param wy number World Y
--- @param ww number World width
--- @param wh number World height
function Camera:setWorldScissor(wx, wy, ww, wh)
    local sx, sy = self:worldToScreen(wx, wy)
    local sw = ww * self.zoom
    local sh = wh * self.zoom
    love.graphics.setScissor(sx, sy, sw, sh)
end

--- Check if a world-space rectangle is visible on screen
--- @param wx number World X
--- @param wy number World Y
--- @param ww number World width
--- @param wh number World height
--- @param screenW number Screen width
--- @param screenH number Screen height
--- @return boolean True if any part of rectangle is visible
function Camera:isVisible(wx, wy, ww, wh, screenW, screenH)
    local sx, sy = self:worldToScreen(wx, wy)
    local sw, sh = ww * self.zoom, wh * self.zoom
    return sx + sw >= 0 and sx <= screenW and sy + sh >= 0 and sy <= screenH
end

return Camera
