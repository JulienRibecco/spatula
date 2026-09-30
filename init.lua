--- Spatula - Signal-based behavior composition
--- @module spatula
---
--- ============================================================================
--- THE ONE PRIMITIVE
--- ============================================================================
---
---   Curve = f(t, ctx) → value
---
--- A curve is a function of time. Everything else composes from curves.
---
--- ============================================================================
--- BUILT FROM CURVES
--- ============================================================================
---
---   Motion = f(t, ctx) → (x, y)
---            Two curves combined: xy(curveX, curveY)
---
---   Field  = curve(distance) + source bookkeeping
---            Spatial signal: sample any point, get a value
---
--- ============================================================================
--- GEOMETRY (parallel system, not built from curves)
--- ============================================================================
---
---   Form         = contains(point) → bool, plus bounds/edge/random
---   Distribution = sample(motion, count) filtered by form
---
--- ============================================================================
--- BEHAVIOR
--- ============================================================================
---
---   Trigger = timing × selection → action
---
--- Event streaming is built into Form and Field:
---   Forms.track(form, origin, size, {onEnter, onExit})
---   Field.track(field, ">", threshold, {onEnter, onExit})
---
--- ============================================================================

local Spatula = {
    _VERSION = "5.0.0",

    -- Core: the primitive and its compositions
    Curve        = require("spatula.curve"),
    Signal       = require("spatula.signal"),  -- Curve that reads from ctx
    Motion       = require("spatula.motion"),
    Field        = require("spatula.field"),

    -- Geometry: spatial predicates and distributions
    Point        = require("spatula.point"),
    Forms        = require("spatula.forms"),
    Distribution = require("spatula.distribution"),

    -- Behavior: events and timing
    Trigger      = require("spatula.trigger"),

    -- Audio: extract curves from audio data
    Audio        = require("spatula.audio"),

    -- Tempo: musical time grid and quantization
    Tempo        = require("spatula.tempo"),

    -- Utilities
    Util         = require("spatula.util"),
}

-- Shorthand: S("name") = Signal("name")
Spatula.S = Spatula.Signal

return Spatula
