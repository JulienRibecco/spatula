--------------------------------------------------------------------------------
-- SPATULA INCREMENTAL ROTATOR MODULE
-- Rotation-matrix based incremental stepping for fixed-timestep games
-- No trig calls per frame - just rotation matrix multiplication!
--------------------------------------------------------------------------------

local Rotator = {}

local sin, cos = math.sin, math.cos
local PI2 = math.pi * 2

--------------------------------------------------------------------------------
-- ANALYSIS
--------------------------------------------------------------------------------

--- Analyze IR to determine what kind of rotator we can generate
--- @param ir table IR node
--- @param hasStatefulNodes function Function to check for stateful nodes
--- @return table Analysis result
function Rotator.analyze(ir, hasStatefulNodes)
    local result = {
        canStep = false,
        type = nil,
        params = {},
        reason = nil
    }
    
    if not ir or type(ir) ~= "table" then
        result.reason = "Invalid IR"
        return result
    end
    
    -- Check for stateful nodes - can't step those
    if hasStatefulNodes and hasStatefulNodes(ir) then
        result.reason = "Contains stateful nodes (follow/spring)"
        return result
    end
    
    -- Check for ctx-dependent nodes
    local function hasCtx(node)
        if not node or type(node) ~= "table" then return false end
        if node.op == "fromCtx" then return true end
        for k, v in pairs(node) do
            if type(v) == "table" and hasCtx(v) then return true end
        end
        return false
    end
    
    if hasCtx(ir) then
        result.reason = "Contains ctx-dependent values"
        return result
    end
    
    -- Analyze motion type
    if ir.type == "motion" then
        -- Simple circle: xy(cos, sin) with same freq
        if ir.op == "xy" and ir.x.op == "cos" and ir.y.op == "sin" then
            if ir.x.freq == ir.y.freq and (ir.x.phase or 0) == (ir.y.phase or 0) then
                result.canStep = true
                result.type = "circle"
                result.params = {
                    freq = ir.x.freq,
                    radiusX = ir.x.amp,
                    radiusY = ir.y.amp,
                    phase = ir.x.phase
                }
                return result
            end
        end
        
        -- Ellipse: same structure
        if ir.op == "xy" and ir.x.op == "cos" and ir.y.op == "sin" then
            result.canStep = true
            result.type = "ellipse"
            result.params = {
                freqX = ir.x.freq,
                freqY = ir.y.freq,
                radiusX = ir.x.amp,
                radiusY = ir.y.amp,
                phaseX = ir.x.phase,
                phaseY = ir.y.phase
            }
            return result
        end
        
        -- Drift: xy(linear, linear)
        if ir.op == "xy" and ir.x.op == "linear" and ir.y.op == "linear" then
            result.canStep = true
            result.type = "drift"
            result.params = {
                vx = ir.x.speed,
                vy = ir.y.speed
            }
            return result
        end
        
        -- Hover: xy(const, sin) - common for UI
        if ir.op == "xy" and ir.x.op == "const" and ir.y.op == "sin" then
            result.canStep = true
            result.type = "hover"
            result.params = {
                freq = ir.y.freq,
                amplitude = ir.y.amp,
                phase = ir.y.phase,
                constant = ir.x.value
            }
            return result
        end
        
        -- Sway: xy(sin, const) - horizontal sway
        if ir.op == "xy" and ir.x.op == "sin" and ir.y.op == "const" then
            result.canStep = true
            result.type = "sway"
            result.params = {
                freq = ir.x.freq,
                amplitude = ir.x.amp,
                phase = ir.x.phase,
                constant = ir.y.value
            }
            return result
        end
    end
    
    -- Curve: single sin/cos can step
    if ir.op == "sin" then
        result.canStep = true
        result.type = "sinCurve"
        result.params = {
            freq = ir.freq,
            amplitude = ir.amp,
            phase = ir.phase
        }
        return result
    end
    
    if ir.op == "cos" then
        result.canStep = true
        result.type = "cosCurve"
        result.params = {
            freq = ir.freq,
            amplitude = ir.amp,
            phase = ir.phase
        }
        return result
    end
    
    if ir.op == "linear" then
        result.canStep = true
        result.type = "linear"
        result.params = {
            speed = ir.speed
        }
        return result
    end
    
    result.reason = "Unsupported pattern for rotator"
    return result
end

--------------------------------------------------------------------------------
-- STEPPER GENERATORS
--------------------------------------------------------------------------------

--- Create a circle rotator (rotation matrix)
--- @param params table { freq, radiusX, radiusY }
--- @param dt number Timestep
--- @return table Rotator object
function Rotator.createCircle(params, dt)
    local freq = params.freq or 1
    local rx = params.radiusX or params.radius or 1
    local ry = params.radiusY or params.radius or 1
    
    -- Pre-compute rotation delta
    local angle = freq * dt * PI2
    local cosD = cos(angle)
    local sinD = sin(angle)
    
    return {
        type = "circle",
        params = params,
        
        -- Initialize at a time offset in seconds; oscillator phase is radians.
        init = function(phase)
            phase = phase or 0
            local a = phase * freq * PI2 + (params.phase or 0)
            local ux, uy = cos(a), sin(a)
            return {
                ux = ux,
                uy = uy,
                x = ux * rx,
                y = uy * ry
            }
        end,
        
        -- Step state forward by dt
        step = function(state)
            local ux, uy = state.ux, state.uy
            state.ux = ux * cosD - uy * sinD
            state.uy = ux * sinD + uy * cosD
            state.x = state.ux * rx
            state.y = state.uy * ry
            return state
        end,
        
        -- Batch step multiple states
        stepBatch = function(states, n)
            for i = 1, n do
                local state = states[i]
                local ux, uy = state.ux, state.uy
                state.ux = ux * cosD - uy * sinD
                state.uy = ux * sinD + uy * cosD
                state.x = state.ux * rx
                state.y = state.uy * ry
            end
        end
    }
end

--- Create an ellipse rotator (independent X/Y frequencies)
--- @param params table { freqX, freqY, radiusX, radiusY }
--- @param dt number Timestep
--- @return table Rotator object
function Rotator.createEllipse(params, dt)
    local freqX = params.freqX or 1
    local freqY = params.freqY or 1
    local rx = params.radiusX or 1
    local ry = params.radiusY or 1
    
    local angleX = freqX * dt * PI2
    local angleY = freqY * dt * PI2
    local cosDx, sinDx = cos(angleX), sin(angleX)
    local cosDy, sinDy = cos(angleY), sin(angleY)
    
    return {
        type = "ellipse",
        params = params,
        
        init = function(phase)
            phase = phase or 0
            local ax = phase * freqX * PI2 + (params.phaseX or 0)
            local ay = phase * freqY * PI2 + (params.phaseY or 0)
            return {
                ux = cos(ax), uy_x = sin(ax),
                vx = cos(ay), vy = sin(ay),
                x = cos(ax) * rx,
                y = sin(ay) * ry
            }
        end,
        
        step = function(state)
            local ux, uy_x = state.ux, state.uy_x
            state.ux = ux * cosDx - uy_x * sinDx
            state.uy_x = ux * sinDx + uy_x * cosDx
            
            local vx, vy = state.vx, state.vy
            state.vx = vx * cosDy - vy * sinDy
            state.vy = vx * sinDy + vy * cosDy
            
            state.x = state.ux * rx
            state.y = state.vy * ry
            return state
        end,
        
        stepBatch = function(states, n)
            for i = 1, n do
                local state = states[i]
                local ux, uy_x = state.ux, state.uy_x
                state.ux = ux * cosDx - uy_x * sinDx
                state.uy_x = ux * sinDx + uy_x * cosDx
                
                local vx, vy = state.vx, state.vy
                state.vx = vx * cosDy - vy * sinDy
                state.vy = vx * sinDy + vy * cosDy
                
                state.x = state.ux * rx
                state.y = state.vy * ry
            end
        end
    }
end

--- Create a drift rotator (linear motion)
--- @param params table { vx, vy }
--- @param dt number Timestep
--- @return table Rotator object
function Rotator.createDrift(params, dt)
    local dx = (params.vx or 0) * dt
    local dy = (params.vy or 0) * dt
    
    return {
        type = "drift",
        params = params,
        
        init = function(phase)
            return { x = (phase or 0) * (params.vx or 0), y = (phase or 0) * (params.vy or 0) }
        end,
        
        step = function(state)
            state.x = state.x + dx
            state.y = state.y + dy
            return state
        end,
        
        stepBatch = function(states, n)
            for i = 1, n do
                states[i].x = states[i].x + dx
                states[i].y = states[i].y + dy
            end
        end
    }
end

--- Create a hover rotator (vertical oscillation)
--- @param params table { freq, amplitude }
--- @param dt number Timestep
--- @return table Rotator object
function Rotator.createHover(params, dt)
    local freq = params.freq or 1
    local amp = params.amplitude or 1
    
    local angle = freq * dt * PI2
    local cosD, sinD = cos(angle), sin(angle)
    
    return {
        type = "hover",
        params = params,
        
        init = function(phase)
            local a = (phase or 0) * freq * PI2 + (params.phase or 0)
            local uy = sin(a)
            return {
                ux = cos(a),
                uy = uy,
                x = params.constant or 0,
                y = uy * amp
            }
        end,
        
        step = function(state)
            local ux, uy = state.ux, state.uy
            state.ux = ux * cosD - uy * sinD
            state.uy = ux * sinD + uy * cosD
            state.y = state.uy * amp
            return state
        end,
        
        stepBatch = function(states, n)
            for i = 1, n do
                local state = states[i]
                local ux, uy = state.ux, state.uy
                state.ux = ux * cosD - uy * sinD
                state.uy = ux * sinD + uy * cosD
                state.y = state.uy * amp
            end
        end
    }
end

--- Create a sway rotator (horizontal oscillation)
--- @param params table { freq, amplitude }
--- @param dt number Timestep
--- @return table Rotator object
function Rotator.createSway(params, dt)
    local freq = params.freq or 1
    local amp = params.amplitude or 1
    
    local angle = freq * dt * PI2
    local cosD, sinD = cos(angle), sin(angle)
    
    return {
        type = "sway",
        params = params,
        
        init = function(phase)
            local a = (phase or 0) * freq * PI2 + (params.phase or 0)
            local ux = sin(a)
            return {
                ux = ux,
                uy = -cos(a),
                x = ux * amp,
                y = params.constant or 0
            }
        end,
        
        step = function(state)
            local ux, uy = state.ux, state.uy
            state.ux = ux * cosD - uy * sinD
            state.uy = ux * sinD + uy * cosD
            state.x = state.ux * amp
            return state
        end,
        
        stepBatch = function(states, n)
            for i = 1, n do
                local state = states[i]
                local ux, uy = state.ux, state.uy
                state.ux = ux * cosD - uy * sinD
                state.uy = ux * sinD + uy * cosD
                state.x = state.ux * amp
            end
        end
    }
end

--- Create a sin curve rotator
--- @param params table { freq, amplitude }
--- @param dt number Timestep
--- @return table Rotator object
function Rotator.createSinCurve(params, dt)
    local freq = params.freq or 1
    local amp = params.amplitude or 1
    
    local angle = freq * dt * PI2
    local cosD, sinD = cos(angle), sin(angle)
    
    return {
        type = "sinCurve",
        params = params,
        
        init = function(phase)
            local a = (phase or 0) * freq * PI2 + (params.phase or 0)
            return {
                ux = cos(a),
                uy = sin(a),
                value = sin(a) * amp
            }
        end,
        
        step = function(state)
            local ux, uy = state.ux, state.uy
            state.ux = ux * cosD - uy * sinD
            state.uy = ux * sinD + uy * cosD
            state.value = state.uy * amp
            return state
        end,
        
        stepBatch = function(states, n)
            for i = 1, n do
                local state = states[i]
                local ux, uy = state.ux, state.uy
                state.ux = ux * cosD - uy * sinD
                state.uy = ux * sinD + uy * cosD
                state.value = state.uy * amp
            end
        end
    }
end

--- Create a cos curve rotator
--- @param params table { freq, amplitude }
--- @param dt number Timestep
--- @return table Rotator object
function Rotator.createCosCurve(params, dt)
    local freq = params.freq or 1
    local amp = params.amplitude or 1
    
    local angle = freq * dt * PI2
    local cosD, sinD = cos(angle), sin(angle)
    
    return {
        type = "cosCurve",
        params = params,
        
        init = function(phase)
            local a = (phase or 0) * freq * PI2 + (params.phase or 0)
            return {
                ux = cos(a),
                uy = sin(a),
                value = cos(a) * amp
            }
        end,
        
        step = function(state)
            local ux, uy = state.ux, state.uy
            state.ux = ux * cosD - uy * sinD
            state.uy = ux * sinD + uy * cosD
            state.value = state.ux * amp
            return state
        end,
        
        stepBatch = function(states, n)
            for i = 1, n do
                local state = states[i]
                local ux, uy = state.ux, state.uy
                state.ux = ux * cosD - uy * sinD
                state.uy = ux * sinD + uy * cosD
                state.value = state.ux * amp
            end
        end
    }
end

--- Create a linear curve rotator
--- @param params table { speed }
--- @param dt number Timestep
--- @return table Rotator object
function Rotator.createLinear(params, dt)
    local dv = (params.speed or 1) * dt
    
    return {
        type = "linear",
        params = params,
        
        init = function(phase)
            return { value = phase * params.speed }
        end,
        
        step = function(state)
            state.value = state.value + dv
            return state
        end,
        
        stepBatch = function(states, n)
            for i = 1, n do
                states[i].value = states[i].value + dv
            end
        end
    }
end

--------------------------------------------------------------------------------
-- MAIN COMPILE FUNCTION
--------------------------------------------------------------------------------

--- Compile IR to a rotator (if possible)
--- @param ir table IR node
--- @param opts table Options: dt (required)
--- @param hasStatefulNodes function Optional function to check for stateful nodes
--- @return table|nil Rotator object or nil if not steppable
function Rotator.compile(ir, opts, hasStatefulNodes)
    opts = opts or {}
    local dt = opts.dt or (1 / 60)
    
    local analysis = Rotator.analyze(ir, hasStatefulNodes)
    
    if not analysis.canStep then
        return nil
    end
    
    local creators = {
        circle = Rotator.createCircle,
        ellipse = Rotator.createEllipse,
        drift = Rotator.createDrift,
        hover = Rotator.createHover,
        sway = Rotator.createSway,
        sinCurve = Rotator.createSinCurve,
        cosCurve = Rotator.createCosCurve,
        linear = Rotator.createLinear,
    }
    
    local creator = creators[analysis.type]
    if creator then
        local rotator = creator(analysis.params, dt)
        
        -- Add getPositions helper if not already present
        if not rotator.getPositions then
            rotator.getPositions = function(states, n)
                local xs, ys = {}, {}
                for i = 1, n do
                    xs[i] = states[i].x or 0
                    ys[i] = states[i].y or 0
                end
                return xs, ys
            end
        end
        
        return rotator
    end
    
    return nil
end

--- Create array of rotator states
--- @param rotator table Rotator object
--- @param n number Number of states
--- @param phases table|nil Optional phase array
--- @return table Array of states
function Rotator.createStates(rotator, n, phases)
    local states = {}
    for i = 1, n do
        states[i] = rotator.init(phases and phases[i] or 0)
    end
    return states
end

return Rotator
