-- Conservative proofs for automatic looping LUTs. Boundedness alone is not a
-- period, and a periodic signal must also fit the chosen LUT window exactly.
local Period = {}

local oscillators = { sin = true, cos = true, triangle = true, saw = true,
    square = true, pulse = true }
local compositions = { const = true, add = true, mul = true, sub = true,
    scaleConst = true, scaleCurve = true, offsetConst = true, offsetCurve = true,
    neg = true, abs = true, powConst = true, powCurve = true, clamp = true,
    exp = true, xy = true, motionAdd = true, motionScaleConst = true,
    motionScaleCurve = true, motionRotateConst = true, motionRotateCurve = true,
    motionMixConst = true, motionMixCurve = true, timeOffsetConst = true,
    timeOffsetCurve = true }

local function dynamic(node)
    if type(node) == "function" then return true end
    if type(node) ~= "table" then return false end
    if node.op == "fromCtx" or node.op == "follow" or node.op == "spring" then return true end
    for _, child in pairs(node) do
        if dynamic(child) then return true end
    end
    return false
end

local function wholeCycles(cycles)
    if cycles ~= cycles or cycles == math.huge then return false end
    local nearest = math.floor(cycles + 0.5)
    return nearest >= 1 and math.abs(cycles - nearest) <= 1e-9
end

local function periodic(node, window)
    if type(node) ~= "table" then return type(node) ~= "function" end
    local op = node.op
    if oscillators[op] then
        if type(node.freq) ~= "number" then return false end
        if node.freq == 0 then return true end
        return not window or wholeCycles(math.abs(node.freq) * window)
    elseif op == "linear" then
        return node.speed == 0
    elseif op == "loop" then
        local duration = node.duration
        return type(duration) == "number" and duration > 0 and duration < math.huge
            and (not window or wholeCycles(window / duration))
    elseif op == "remap" then
        -- A repeating input time makes any pure outer curve repeat.
        return periodic(node.timeCurve, window)
    elseif op == "timeScaleConst" then
        return node.factor == 0 or periodic(node.curve, window and math.abs(node.factor) * window)
    elseif op == "timeScaleCurve" then
        if node.factor and node.factor.op == "const" then
            return node.factor.value == 0 or periodic(node.curve, window and math.abs(node.factor.value) * window)
        end
        -- t * factor(t) need not repeat even when factor(t) does.
        return false
    elseif op and not compositions[op] then
        -- Ramps, easing, delays, finite segments, noise, and unknown operations
        -- stay on the direct compiler path unless explicitly wrapped in loop().
        return false
    end
    for _, child in pairs(node) do
        if type(child) == "table" and not periodic(child, window) then return false end
    end
    return true
end

function Period.isPeriodic(node)
    return not dynamic(node) and periodic(node)
end

function Period.repeatsAfter(node, duration)
    return type(duration) == "number" and duration > 0 and duration < math.huge
        and not dynamic(node) and periodic(node, duration)
end

return Period
