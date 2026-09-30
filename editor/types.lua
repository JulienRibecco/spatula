--- editor.types - Type inference and color utilities
--- @module spatula.editor.types

local Types = {}

--- Infer wire type from port name for type-safe connections
--- @param portName string The port name to check
--- @return string The wire type ("curve", "form", "pts", "point", "tempo", etc.)
function Types.portWireType(portName)
    if portName == "form" then return "form" end
    if portName == "pts" then return "pts" end
    if portName == "point" then return "point" end
    if portName == "entity" then return "point" end  -- entity inputs accept point outputs
    if portName == "tempo" then return "tempo" end
    if portName == "timing" then return "timing" end
    if portName == "select" then return "select" end
    if portName == "trig" then return "trig" end
    if portName == "field" then return "field" end
    if portName == "fieldIn" then return "field" end  -- field input for chaining
    if portName == "entityA" or portName == "entityB" or portName == "from" or portName == "to" then
        return "point"  -- These all accept point outputs
    end
    if portName == "audio" then return "curve" end  -- Audio outputs are curves
    if portName == "text" then return "text" end  -- Text manager for classifier nodes
    -- Multi-output audio band names
    if portName == "low" or portName == "mid" or portName == "high" then return "curve" end
    -- Color/vec4 types
    if portName == "color" then return "color" end
    if portName == "colorIn" then return "color" end
    if portName == "colorA" or portName == "colorB" then return "color" end
    -- Clock type for domain-independent timing
    if portName == "clock" then return "clock" end
    -- Note: r,g,b,a as inputs are scalar curves; as outputs they're also curves
    return "curve"
end

--- Convert HSL to RGB
--- @param h number Hue (0-1)
--- @param s number Saturation (0-1)
--- @param l number Lightness (0-1)
--- @return number, number, number RGB values (0-1 each)
function Types.hslToRgb(h, s, l)
    if s == 0 then return l, l, l end
    local function hue2rgb(p, q, t)
        if t < 0 then t = t + 1 end
        if t > 1 then t = t - 1 end
        if t < 1/6 then return p + (q - p) * 6 * t end
        if t < 1/2 then return q end
        if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
        return p
    end
    local q = l < 0.5 and l * (1 + s) or l + s - l * s
    local p = 2 * l - q
    return hue2rgb(p, q, h + 1/3), hue2rgb(p, q, h), hue2rgb(p, q, h - 1/3)
end

return Types
