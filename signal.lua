--- Spatula Signal Module
--- @module spatula.signal
---
--- A Signal is a Curve that ignores time and reads from context.
--- This enables reactive parameters without changing the composition model.
---
--- Lookup Priority:
---   1. Explicit ctx argument (one-off overrides)
---   2. Active context (the subject entity - setActive)
---   3. Global registry (singletons - setGlobal)
---   4. Default value
---
--- Usage:
---   local S = require("spatula.signal")
---
---   -- Define with signals
---   local shield = Forms.circle(S("x"), S("y"), S("radius"))
---
---   -- Set globals once per frame (player, time, wind)
---   S.setGlobal("playerSpeed", player.speed)
---   S.setGlobal("time", gameTime)
---
---   -- Set active per entity (the subject)
---   for _, boss in ipairs(bosses) do
---       S.setActive(boss)  -- reads boss.x, boss.y, boss.radius
---       if shield:contains(bullet.x, bullet.y) then
---           -- explicit override for interaction
---           local dmg = damageCurve(0, { damage = bullet.damage })
---       end
---   end
---

local Signal = {}

-- Active context: the current subject entity (Lua table or FFI struct)
local ActiveContext = nil

-- Global registry: frame-wide singletons (player, time, wind)
local Globals = {}

--- Set the active context (the subject entity)
--- Each call overwrites the previous active context
--- @param ctx table|cdata The entity to use (Lua table or FFI struct)
function Signal.setActive(ctx)
    ActiveContext = ctx
end

--- Get the current active context
--- @return table|cdata|nil
function Signal.getActive()
    return ActiveContext
end

--- Set a global value (singletons: player, time, wind)
--- @param name string The key
--- @param value any The value
function Signal.setGlobal(name, value)
    Globals[name] = value
end

--- Get a global value
--- @param name string The key
--- @return any
function Signal.getGlobal(name)
    return Globals[name]
end

--- Clear all globals (optional, for testing)
function Signal.clearGlobals()
    Globals = {}
end

--- Create a new Signal that reads from context
--- Priority: explicit ctx > active context > globals > default
--- If the looked-up value is a function (curve), it is evaluated with (t, ctx)
--- This enables LFO-style modulation: S.setGlobal("wobble", Curve.sin(2, 10))
--- @param name string The key to read from ctx
--- @param default number Optional default value if key is missing (default: 0)
--- @return function A curve function(t, ctx) -> value
function Signal.new(name, default)
    default = default or 0
    return function(t, ctx)
        local value
        -- Priority 1: Explicit argument
        if ctx and ctx[name] ~= nil then
            value = ctx[name]
        -- Priority 2: Active context (the subject)
        elseif ActiveContext and ActiveContext[name] ~= nil then
            value = ActiveContext[name]
        -- Priority 3: Global registry (singletons)
        elseif Globals[name] ~= nil then
            value = Globals[name]
        -- Priority 4: Default
        else
            return default
        end
        -- Auto-evaluate curves (LFO behavior)
        if type(value) == "function" then
            return value(t, ctx)
        end
        return value
    end
end

-- Allow Signal("name") as shorthand for Signal.new("name")
setmetatable(Signal, { __call = function(_, ...) return Signal.new(...) end })

return Signal
