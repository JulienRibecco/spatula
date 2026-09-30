--- Spatula Compiler Module
--- @module spatula.compiler
---
--- ============================================================================
--- IR-based compiler for Spatula compositions
--- ============================================================================
---
--- Converts Spatula compositions to optimized, inlined closures.
---
--- USAGE:
---   local C = require("spatula.compiler")
---
---   -- Build using IR (intermediate representation)
---   local ir = C.motion.circle(100, 2)
---   local optimized = C.compile(ir)
---
---   -- Or wrap existing compositions for analysis
---   local motion = Motion.circle(100, 2)
---   -- (runtime tracing approach - future)
---
--- WHY:
---   Motion.circle(100, 2) creates nested closures:
---     Motion.xy(
---       Curve.cos(2, 100),   -- closure 1
---       Curve.sin(2, 100)    -- closure 2
---     )                      -- closure 3 (xy wrapper)
---
---   Each call traverses 3 function calls. For 10k entities at 60fps,
---   that's 1.8M extra function calls per second.
---
---   Compiled version:
---     function(t, ctx)
---       local angle = t * 2 * 6.283185307179586
---       return cos(angle) * 100, sin(angle) * 100
---     end
---
---   Single function, no indirection.
---
--- ============================================================================

local Compiler = {}
local Period = require("spatula.compiler.period")

-- Load extracted modules
local IR = require("spatula.compiler.ir")
local RotatorModule = require("spatula.compiler.strategies.incremental_rotator")
local LUTModule = require("spatula.compiler.strategies.lut")
local PoolModule = require("spatula.compiler.pool")
local FormPoolModule = require("spatula.compiler.pool.form")
local TriggerPoolModule = require("spatula.compiler.pool.trigger")
local DistributionPoolModule = require("spatula.compiler.pool.distribution")

local PI = math.pi
local PI2 = PI * 2

-- Import IR constructors
Compiler.curve = IR.curve
Compiler.motion = IR.motion
Compiler.form = IR.form
Compiler.trigger = IR.trigger
Compiler.distribution = IR.distribution
Compiler.falloff = IR.falloff
Compiler.field = IR.field

-- JSON serialization for cross-language codegen
Compiler.toJSON = IR.toJSON
Compiler.fromJSON = IR.fromJSON

-- Unique variable counter for generated code
local varCounter = 0
local function nextVar()
    varCounter = varCounter + 1
    return "_v" .. varCounter
end

local function resetVars()
    varCounter = 0
end

--------------------------------------------------------------------------------
-- COMMON SUBEXPRESSION ELIMINATION (CSE)
-- Track computed expressions to avoid redundant calculations.
--------------------------------------------------------------------------------

-- Expression cache: maps expression string -> variable name
local exprCache = {}

local function resetCSE()
    exprCache = {}
end

--- Check if an expression is already computed, or compute and cache it
--- @param expr string The expression to potentially cache
--- @param lines table The lines array to append to
--- @param threshold number Minimum expression length to consider caching (default 5)
--- @return string Variable name if cached, or original expression if too simple
local function cacheExpr(expr, lines, threshold)
    threshold = threshold or 5
    
    -- Don't cache simple expressions (single variables, small constants)
    if #expr < threshold then
        return expr
    end
    
    -- Don't cache expressions that are already just variable references
    if expr:match("^_v%d+$") or expr:match("^[%a_][%w_]*$") then
        return expr
    end
    
    -- Check if we've already computed this
    if exprCache[expr] then
        return exprCache[expr]
    end
    
    -- Cache it
    local var = nextVar()
    lines[#lines + 1] = string.format("local %s = %s", var, expr)
    exprCache[expr] = var
    return var
end

--- Cache a time-derived expression (common pattern: t * factor, t + offset)
--- These are high-value CSE targets because they're often shared
local function cacheTimeExpr(tVar, op, value, lines)
    local expr = string.format("%s %s %s", tVar, op, value)
    return cacheExpr(expr, lines, 1)  -- Always cache time expressions
end

-- Note: IR node constructors are in ir.lua (Compiler.curve.*, Compiler.motion.*)

--- Emit a parameter that may be a signal or literal
--- Used by Form, Trigger, Distribution, Field compilers
local function emitParam(val)
    if type(val) == "table" and val.op == "fromCtx" then
        return string.format("(ctx.%s or %s)", val.key, val.default)
    elseif type(val) == "number" then
        return tostring(val)
    elseif type(val) == "string" then
        return string.format("%q", val)
    else
        error("Expected number, string, or signal, got: " .. type(val))
    end
end

-- Walk the IR tree and emit Lua source code.
--------------------------------------------------------------------------------

local codeGenerators = {}

-- Helper: emit code that evaluates a curve and stores result in a variable
local function emitCurve(node, lines, tVar)
    local gen = codeGenerators[node.op]
    if not gen then
        error("Unknown curve op: " .. tostring(node.op))
    end
    return gen(node, lines, tVar)
end

-- Primitives
codeGenerators["const"] = function(node, lines, tVar)
    return tostring(node.value)
end

codeGenerators["linear"] = function(node, lines, tVar)
    if node.speed == 1 then
        return tVar
    else
        return string.format("(%s * %s)", tVar, node.speed)
    end
end

codeGenerators["sin"] = function(node, lines, tVar)
    -- Pre-compute freq * PI2 at compile time
    local freqPI2 = node.freq * PI2
    local angleExpr
    if node.phase == 0 then
        angleExpr = string.format("%s * %.15g", tVar, freqPI2)
    else
        angleExpr = string.format("%s * %.15g + %.15g", tVar, freqPI2, node.phase)
    end
    
    -- Cache the angle expression (shared between sin/cos with same freq)
    local angleVar = cacheExpr(angleExpr, lines, 10)
    
    if node.amp == 1 then
        return string.format("sin(%s)", angleVar)
    else
        return string.format("sin(%s) * %.15g", angleVar, node.amp)
    end
end

codeGenerators["cos"] = function(node, lines, tVar)
    -- Pre-compute freq * PI2 at compile time
    local freqPI2 = node.freq * PI2
    local angleExpr
    if node.phase == 0 then
        angleExpr = string.format("%s * %.15g", tVar, freqPI2)
    else
        angleExpr = string.format("%s * %.15g + %.15g", tVar, freqPI2, node.phase)
    end
    
    -- Cache the angle expression (shared between sin/cos with same freq)
    local angleVar = cacheExpr(angleExpr, lines, 10)
    
    if node.amp == 1 then
        return string.format("cos(%s)", angleVar)
    else
        return string.format("cos(%s) * %.15g", angleVar, node.amp)
    end
end

codeGenerators["triangle"] = function(node, lines, tVar)
    local var = nextVar()
    local phaseVar = nextVar()
    lines[#lines + 1] = string.format("local %s = (%s * %s) %% 1", phaseVar, tVar, node.freq)
    lines[#lines + 1] = string.format("local %s = (%s < 0.5) and (%s * 4 - 1) or (3 - %s * 4)", 
        var, phaseVar, phaseVar, phaseVar)
    if node.amp == 1 then
        return var
    else
        return string.format("%s * %s", var, node.amp)
    end
end

codeGenerators["saw"] = function(node, lines, tVar)
    local phaseVar = nextVar()
    lines[#lines + 1] = string.format("local %s = (%s * %s) %% 1", phaseVar, tVar, node.freq)
    if node.amp == 1 then
        return string.format("(%s * 2 - 1)", phaseVar)
    else
        return string.format("(%s * 2 - 1) * %s", phaseVar, node.amp)
    end
end

codeGenerators["square"] = function(node, lines, tVar)
    local phaseVar = nextVar()
    lines[#lines + 1] = string.format("local %s = (%s * %s) %% 1", phaseVar, tVar, node.freq)
    if node.amp == 1 then
        return string.format("((%s < %s) and 1 or -1)", phaseVar, node.duty)
    else
        return string.format("((%s < %s) and 1 or -1) * %s", phaseVar, node.duty, node.amp)
    end
end

codeGenerators["pulse"] = function(node, lines, tVar)
    local phaseVar = nextVar()
    lines[#lines + 1] = string.format("local %s = (%s * %s) %% 1", phaseVar, tVar, node.freq)
    return string.format("((%s < %s) and 1 or 0)", phaseVar, node.duty)
end

codeGenerators["noise"] = function(node, lines, tVar)
    -- Deterministic noise approximation
    local seed = node.seed
    return string.format(
        "(sin(%s * 1.0 + %s) * 0.5 + sin(%s * 2.3 + %s) * 0.3 + sin(%s * 5.7 + %s) * 0.2) * %s",
        tVar, seed, tVar, seed * 2, tVar, seed * 3, node.scale
    )
end

--------------------------------------------------------------------------------
-- STATEFUL CURVE CODE GENERATORS
-- These generate code that manages state via ctx.curveState
--------------------------------------------------------------------------------

codeGenerators["follow"] = function(node, lines, tVar)
    local id = node.stateId
    local speed = node.speed
    local targetExpr = emitCurve(node.target, lines, tVar)
    
    local stateVar = "_st" .. id
    local resultVar = "_fv" .. id
    
    -- Initialize state structure
    lines[#lines + 1] = "ctx.curveState = ctx.curveState or {}"
    lines[#lines + 1] = string.format("local %s = ctx.curveState[%d]", stateVar, id)
    lines[#lines + 1] = string.format("if not %s then", stateVar)
    lines[#lines + 1] = string.format("  %s = { value = %s, lastT = %s }", stateVar, targetExpr, tVar)
    lines[#lines + 1] = string.format("  ctx.curveState[%d] = %s", id, stateVar)
    lines[#lines + 1] = "end"
    
    -- Calculate dt and update
    lines[#lines + 1] = string.format("local _dt%d = %s - %s.lastT", id, tVar, stateVar)
    lines[#lines + 1] = string.format("%s.lastT = %s", stateVar, tVar)
    lines[#lines + 1] = string.format("local _tgt%d = %s", id, targetExpr)
    lines[#lines + 1] = string.format(
        "%s.value = %s.value + (_tgt%d - %s.value) * min(1, %.15g * _dt%d)",
        stateVar, stateVar, id, stateVar, speed, id
    )
    lines[#lines + 1] = string.format("local %s = %s.value", resultVar, stateVar)
    
    return resultVar
end

codeGenerators["spring"] = function(node, lines, tVar)
    local id = node.stateId
    local stiffness = node.stiffness
    local damping = node.damping
    local targetExpr = emitCurve(node.target, lines, tVar)
    
    local stateVar = "_st" .. id
    local resultVar = "_sv" .. id
    
    -- Initialize state structure
    lines[#lines + 1] = "ctx.curveState = ctx.curveState or {}"
    lines[#lines + 1] = string.format("local %s = ctx.curveState[%d]", stateVar, id)
    lines[#lines + 1] = string.format("if not %s then", stateVar)
    lines[#lines + 1] = string.format("  %s = { value = %s, velocity = 0, lastT = %s }", stateVar, targetExpr, tVar)
    lines[#lines + 1] = string.format("  ctx.curveState[%d] = %s", id, stateVar)
    lines[#lines + 1] = "end"
    
    -- Calculate dt (clamped to prevent instability)
    lines[#lines + 1] = string.format("local _dt%d = min(%s - %s.lastT, 0.1)", id, tVar, stateVar)
    lines[#lines + 1] = string.format("%s.lastT = %s", stateVar, tVar)
    
    -- Spring physics
    lines[#lines + 1] = string.format("local _tgt%d = %s", id, targetExpr)
    lines[#lines + 1] = string.format(
        "local _force%d = (_tgt%d - %s.value) * %.15g",
        id, id, stateVar, stiffness
    )
    lines[#lines + 1] = string.format(
        "local _damp%d = %s.velocity * %.15g",
        id, stateVar, damping
    )
    lines[#lines + 1] = string.format(
        "%s.velocity = %s.velocity + (_force%d - _damp%d) * _dt%d",
        stateVar, stateVar, id, id, id
    )
    lines[#lines + 1] = string.format(
        "%s.value = %s.value + %s.velocity * _dt%d",
        stateVar, stateVar, stateVar, id
    )
    lines[#lines + 1] = string.format("local %s = %s.value", resultVar, stateVar)
    
    return resultVar
end

codeGenerators["easeIn"] = function(node, lines, tVar)
    local pVar = nextVar()
    lines[#lines + 1] = string.format("local %s = clamp(%s / %s, 0, 1)", pVar, tVar, node.duration)
    return string.format("%s ^ %s", pVar, node.power)
end

codeGenerators["easeOut"] = function(node, lines, tVar)
    local pVar = nextVar()
    lines[#lines + 1] = string.format("local %s = clamp(%s / %s, 0, 1)", pVar, tVar, node.duration)
    return string.format("1 - (1 - %s) ^ %s", pVar, node.power)
end

codeGenerators["easeInOut"] = function(node, lines, tVar)
    local pVar = nextVar()
    local resVar = nextVar()
    lines[#lines + 1] = string.format("local %s = clamp(%s / %s, 0, 1)", pVar, tVar, node.duration)
    local coeff = 2 ^ (node.power - 1)
    lines[#lines + 1] = string.format(
        "local %s = (%s < 0.5) and (%s * %s ^ %s) or (1 - ((-2 * %s + 2) ^ %s) / 2)",
        resVar, pVar, coeff, pVar, node.power, pVar, node.power
    )
    return resVar
end

codeGenerators["ramp"] = function(node, lines, tVar)
    local resVar = nextVar()
    lines[#lines + 1] = string.format(
        "local %s = (%s >= %s) and %s or (%s + (%s - %s) * (%s / %s))",
        resVar, tVar, node.duration, node.target,
        node.start, node.target, node.start, tVar, node.duration
    )
    return resVar
end

-- Combinators
codeGenerators["add"] = function(node, lines, tVar)
    local parts = {}
    for _, child in ipairs(node.children) do
        parts[#parts + 1] = emitCurve(child, lines, tVar)
    end
    return "(" .. table.concat(parts, " + ") .. ")"
end

codeGenerators["mul"] = function(node, lines, tVar)
    local parts = {}
    for _, child in ipairs(node.children) do
        parts[#parts + 1] = emitCurve(child, lines, tVar)
    end
    return "(" .. table.concat(parts, " * ") .. ")"
end

codeGenerators["sub"] = function(node, lines, tVar)
    local aExpr = emitCurve(node.a, lines, tVar)
    local bExpr = emitCurve(node.b, lines, tVar)
    return string.format("(%s - %s)", aExpr, bExpr)
end

codeGenerators["scaleConst"] = function(node, lines, tVar)
    local curveExpr = emitCurve(node.curve, lines, tVar)
    if node.factor == 1 then
        return curveExpr
    else
        return string.format("(%s * %s)", curveExpr, node.factor)
    end
end

codeGenerators["scaleCurve"] = function(node, lines, tVar)
    local curveExpr = emitCurve(node.curve, lines, tVar)
    local factorExpr = emitCurve(node.factor, lines, tVar)
    return string.format("(%s * %s)", curveExpr, factorExpr)
end

codeGenerators["offsetConst"] = function(node, lines, tVar)
    local curveExpr = emitCurve(node.curve, lines, tVar)
    if node.amount == 0 then
        return curveExpr
    else
        return string.format("(%s + %s)", curveExpr, node.amount)
    end
end

codeGenerators["offsetCurve"] = function(node, lines, tVar)
    local curveExpr = emitCurve(node.curve, lines, tVar)
    local amountExpr = emitCurve(node.amount, lines, tVar)
    return string.format("(%s + %s)", curveExpr, amountExpr)
end

codeGenerators["neg"] = function(node, lines, tVar)
    local curveExpr = emitCurve(node.curve, lines, tVar)
    return string.format("(-%s)", curveExpr)
end

codeGenerators["abs"] = function(node, lines, tVar)
    local curveExpr = emitCurve(node.curve, lines, tVar)
    return string.format("abs(%s)", curveExpr)
end

codeGenerators["powConst"] = function(node, lines, tVar)
    local curveExpr = emitCurve(node.curve, lines, tVar)
    if node.exponent == 1 then
        return curveExpr
    elseif node.exponent == 2 then
        local var = nextVar()
        lines[#lines + 1] = string.format("local %s = %s", var, curveExpr)
        return string.format("%s * %s", var, var)
    else
        return string.format("(%s ^ %s)", curveExpr, node.exponent)
    end
end

codeGenerators["powCurve"] = function(node, lines, tVar)
    local curveExpr = emitCurve(node.curve, lines, tVar)
    local expExpr = emitCurve(node.exponent, lines, tVar)
    return string.format("(%s ^ %s)", curveExpr, expExpr)
end

codeGenerators["clamp"] = function(node, lines, tVar)
    local curveExpr = emitCurve(node.curve, lines, tVar)
    return string.format("clamp(%s, %s, %s)", curveExpr, node.lo, node.hi)
end

codeGenerators["exp"] = function(node, lines, tVar)
    local curveExpr = emitCurve(node.curve, lines, tVar)
    return string.format("exp(%s)", curveExpr)
end

-- Time manipulation
codeGenerators["timeScaleConst"] = function(node, lines, tVar)
    local scaledT = cacheTimeExpr(tVar, "*", node.factor, lines)
    return emitCurve(node.curve, lines, scaledT)
end

codeGenerators["timeScaleCurve"] = function(node, lines, tVar)
    local factorExpr = emitCurve(node.factor, lines, tVar)
    local scaledT = nextVar()
    lines[#lines + 1] = string.format("local %s = %s * %s", scaledT, tVar, factorExpr)
    return emitCurve(node.curve, lines, scaledT)
end

codeGenerators["timeOffsetConst"] = function(node, lines, tVar)
    local offsetT = cacheTimeExpr(tVar, "+", node.offset, lines)
    return emitCurve(node.curve, lines, offsetT)
end

codeGenerators["timeOffsetCurve"] = function(node, lines, tVar)
    local offsetExpr = emitCurve(node.offset, lines, tVar)
    local offsetT = nextVar()
    lines[#lines + 1] = string.format("local %s = %s + %s", offsetT, tVar, offsetExpr)
    return emitCurve(node.curve, lines, offsetT)
end

codeGenerators["remap"] = function(node, lines, tVar)
    -- Evaluate timeCurve to get new time value
    local newT = emitCurve(node.timeCurve, lines, tVar)
    -- Evaluate curve at the remapped time
    return emitCurve(node.curve, lines, newT)
end

codeGenerators["loop"] = function(node, lines, tVar)
    local expr = string.format("%s %% %s", tVar, node.duration)
    local loopedT = cacheExpr(expr, lines, 1)
    return emitCurve(node.curve, lines, loopedT)
end

codeGenerators["delay"] = function(node, lines, tVar)
    local resVar = nextVar()
    local delayedT = nextVar()
    lines[#lines + 1] = string.format("local %s", resVar)
    lines[#lines + 1] = string.format("if %s < %s then", tVar, node.delay)
    lines[#lines + 1] = string.format("  %s = 0", resVar)
    lines[#lines + 1] = "else"
    lines[#lines + 1] = string.format("  local %s = %s - %s", delayedT, tVar, node.delay)
    
    -- Collect nested curve lines
    local nestedLines = {}
    local curveExpr = emitCurve(node.curve, nestedLines, delayedT)
    
    -- Add nested lines with indentation
    for _, line in ipairs(nestedLines) do
        lines[#lines + 1] = "  " .. line
    end
    
    lines[#lines + 1] = string.format("  %s = %s", resVar, curveExpr)
    lines[#lines + 1] = "end"
    return resVar
end

codeGenerators["segment"] = function(node, lines, tVar)
    local resVar = nextVar()
    local localT = nextVar()
    local startTime = node.start
    local endTime = node.start + node.duration
    
    lines[#lines + 1] = string.format("local %s", resVar)
    lines[#lines + 1] = string.format("if %s >= %s and %s < %s then", tVar, startTime, tVar, endTime)
    lines[#lines + 1] = string.format("  local %s = %s - %s", localT, tVar, startTime)
    
    -- Collect nested curve lines
    local nestedLines = {}
    local curveExpr = emitCurve(node.curve, nestedLines, localT)
    
    -- Add nested lines with indentation
    for _, line in ipairs(nestedLines) do
        lines[#lines + 1] = "  " .. line
    end
    
    lines[#lines + 1] = string.format("  %s = %s", resVar, curveExpr)
    lines[#lines + 1] = "else"
    lines[#lines + 1] = string.format("  %s = 0", resVar)
    lines[#lines + 1] = "end"
    return resVar
end

-- Motion operations
codeGenerators["xy"] = function(node, lines, tVar)
    local xExpr = emitCurve(node.x, lines, tVar)
    local yExpr = emitCurve(node.y, lines, tVar)
    return xExpr, yExpr
end

codeGenerators["motionAdd"] = function(node, lines, tVar)
    local xParts, yParts = {}, {}
    for _, child in ipairs(node.children) do
        local xExpr, yExpr = emitCurve(child, lines, tVar)
        xParts[#xParts + 1] = xExpr
        yParts[#yParts + 1] = yExpr
    end
    return "(" .. table.concat(xParts, " + ") .. ")", "(" .. table.concat(yParts, " + ") .. ")"
end

codeGenerators["motionScaleConst"] = function(node, lines, tVar)
    local xExpr, yExpr = emitCurve(node.motion, lines, tVar)
    if node.factor == 1 then
        return xExpr, yExpr
    else
        return string.format("(%s * %s)", xExpr, node.factor),
               string.format("(%s * %s)", yExpr, node.factor)
    end
end

codeGenerators["motionScaleCurve"] = function(node, lines, tVar)
    local xExpr, yExpr = emitCurve(node.motion, lines, tVar)
    local factorExpr = emitCurve(node.factor, lines, tVar)
    local fVar = nextVar()
    lines[#lines + 1] = string.format("local %s = %s", fVar, factorExpr)
    return string.format("(%s * %s)", xExpr, fVar),
           string.format("(%s * %s)", yExpr, fVar)
end

codeGenerators["motionRotateConst"] = function(node, lines, tVar)
    local xExpr, yExpr = emitCurve(node.motion, lines, tVar)
    local xVar, yVar = nextVar(), nextVar()
    lines[#lines + 1] = string.format("local %s, %s = %s, %s", xVar, yVar, xExpr, yExpr)
    
    local c = math.cos(node.angle)
    local s = math.sin(node.angle)
    return string.format("(%s * %s - %s * %s)", xVar, c, yVar, s),
           string.format("(%s * %s + %s * %s)", xVar, s, yVar, c)
end

codeGenerators["motionRotateCurve"] = function(node, lines, tVar)
    local xExpr, yExpr = emitCurve(node.motion, lines, tVar)
    local angleExpr = emitCurve(node.angle, lines, tVar)
    
    local xVar, yVar = nextVar(), nextVar()
    local cVar, sVar = nextVar(), nextVar()
    
    lines[#lines + 1] = string.format("local %s, %s = %s, %s", xVar, yVar, xExpr, yExpr)
    lines[#lines + 1] = string.format("local %s, %s = cos(%s), sin(%s)", cVar, sVar, angleExpr, angleExpr)
    
    return string.format("(%s * %s - %s * %s)", xVar, cVar, yVar, sVar),
           string.format("(%s * %s + %s * %s)", xVar, sVar, yVar, cVar)
end

codeGenerators["motionMixConst"] = function(node, lines, tVar)
    local axExpr, ayExpr = emitCurve(node.a, lines, tVar)
    local bxExpr, byExpr = emitCurve(node.b, lines, tVar)
    
    local f = node.factor
    local invF = 1 - f
    
    return string.format("(%s * %s + %s * %s)", axExpr, invF, bxExpr, f),
           string.format("(%s * %s + %s * %s)", ayExpr, invF, byExpr, f)
end

codeGenerators["motionMixCurve"] = function(node, lines, tVar)
    local axExpr, ayExpr = emitCurve(node.a, lines, tVar)
    local bxExpr, byExpr = emitCurve(node.b, lines, tVar)
    local factorExpr = emitCurve(node.factor, lines, tVar)
    
    local fVar = nextVar()
    local invFVar = nextVar()
    
    lines[#lines + 1] = string.format("local %s = %s", fVar, factorExpr)
    lines[#lines + 1] = string.format("local %s = 1 - %s", invFVar, fVar)
    
    return string.format("(%s * %s + %s * %s)", axExpr, invFVar, bxExpr, fVar),
           string.format("(%s * %s + %s * %s)", ayExpr, invFVar, byExpr, fVar)
end

codeGenerators["motionSegment"] = function(node, lines, tVar)
    local xVar = nextVar()
    local yVar = nextVar()
    local localT = nextVar()
    local startTime = node.start
    local endTime = node.start + node.duration
    
    lines[#lines + 1] = string.format("local %s, %s", xVar, yVar)
    lines[#lines + 1] = string.format("if %s >= %s and %s < %s then", tVar, startTime, tVar, endTime)
    lines[#lines + 1] = string.format("  local %s = %s - %s", localT, tVar, startTime)
    
    -- Collect nested motion lines
    local nestedLines = {}
    local xExpr, yExpr = emitCurve(node.motion, nestedLines, localT)
    
    -- Add nested lines with indentation
    for _, line in ipairs(nestedLines) do
        lines[#lines + 1] = "  " .. line
    end
    
    lines[#lines + 1] = string.format("  %s, %s = %s, %s", xVar, yVar, xExpr, yExpr)
    lines[#lines + 1] = "else"
    lines[#lines + 1] = string.format("  %s, %s = 0, 0", xVar, yVar)
    lines[#lines + 1] = "end"
    return xVar, yVar
end

--------------------------------------------------------------------------------
-- FORM CODE GENERATORS
-- Forms compile to: function(x, y) -> bool
--------------------------------------------------------------------------------

-- Helper to emit form expressions
local function emitForm(node, lines, xVar, yVar)
    local gen = codeGenerators[node.op]
    if not gen then
        error("Unknown form op: " .. tostring(node.op))
    end
    return gen(node, lines, xVar, yVar)
end

codeGenerators["formCircle"] = function(node, lines, xVar, yVar)
    local oxExpr = emitParam(node.ox)
    local oyExpr = emitParam(node.oy)
    local dx = string.format("(%s - %s)", xVar, oxExpr)
    local dy = string.format("(%s - %s)", yVar, oyExpr)
    -- Pre-compute r^2 if literal, otherwise emit runtime
    local r2Expr
    if type(node.radius) == "number" then
        r2Expr = tostring(node.radius * node.radius)
    else
        local rExpr = emitParam(node.radius)
        r2Expr = string.format("(%s*%s)", rExpr, rExpr)
    end
    return string.format("(%s*%s + %s*%s <= %s)", dx, dx, dy, dy, r2Expr)
end

codeGenerators["formRect"] = function(node, lines, xVar, yVar)
    local oxExpr = emitParam(node.ox)
    local oyExpr = emitParam(node.oy)
    local hwExpr = emitParam(node.hw)
    local hhExpr = emitParam(node.hh)
    return string.format(
        "(abs(%s - %s) <= %s and abs(%s - %s) <= %s)",
        xVar, oxExpr, hwExpr, yVar, oyExpr, hhExpr
    )
end

codeGenerators["formEllipse"] = function(node, lines, xVar, yVar)
    local oxExpr = emitParam(node.ox)
    local oyExpr = emitParam(node.oy)
    local rxExpr = emitParam(node.rx)
    local ryExpr = emitParam(node.ry)
    local dx = string.format("((%s - %s) / %s)", xVar, oxExpr, rxExpr)
    local dy = string.format("((%s - %s) / %s)", yVar, oyExpr, ryExpr)
    return string.format("(%s*%s + %s*%s <= 1)", dx, dx, dy, dy)
end

codeGenerators["formRing"] = function(node, lines, xVar, yVar)
    local oxExpr = emitParam(node.ox)
    local oyExpr = emitParam(node.oy)
    local dx = string.format("(%s - %s)", xVar, oxExpr)
    local dy = string.format("(%s - %s)", yVar, oyExpr)
    local d2Expr = string.format("(%s*%s + %s*%s)", dx, dx, dy, dy)
    -- Cache the distance squared computation
    local d2Var = nextVar()
    lines[#lines + 1] = string.format("local %s = %s", d2Var, d2Expr)
    -- Pre-compute r^2 if literal, otherwise emit runtime
    local outer2Expr, inner2Expr
    if type(node.outerR) == "number" then
        outer2Expr = tostring(node.outerR * node.outerR)
    else
        local oExpr = emitParam(node.outerR)
        outer2Expr = string.format("(%s*%s)", oExpr, oExpr)
    end
    if type(node.innerR) == "number" then
        inner2Expr = tostring(node.innerR * node.innerR)
    else
        local iExpr = emitParam(node.innerR)
        inner2Expr = string.format("(%s*%s)", iExpr, iExpr)
    end
    return string.format("(%s <= %s and %s >= %s)", d2Var, outer2Expr, d2Var, inner2Expr)
end

codeGenerators["formUnion"] = function(node, lines, xVar, yVar)
    local parts = {}
    for _, child in ipairs(node.children) do
        parts[#parts + 1] = emitForm(child, lines, xVar, yVar)
    end
    return "(" .. table.concat(parts, " or ") .. ")"
end

codeGenerators["formIntersect"] = function(node, lines, xVar, yVar)
    local parts = {}
    for _, child in ipairs(node.children) do
        parts[#parts + 1] = emitForm(child, lines, xVar, yVar)
    end
    return "(" .. table.concat(parts, " and ") .. ")"
end

codeGenerators["formSubtract"] = function(node, lines, xVar, yVar)
    local outerExpr = emitForm(node.outer, lines, xVar, yVar)
    local innerExpr = emitForm(node.inner, lines, xVar, yVar)
    return string.format("(%s and not %s)", outerExpr, innerExpr)
end

--------------------------------------------------------------------------------
-- UNIT FORM CODE GENERATORS (for distributions)
-- These generate containment checks relative to (ox, oy, size)
--------------------------------------------------------------------------------

-- Helper to emit unit form expressions (relative to origin and size)
local function emitFormRelative(node, lines, oxVar, oyVar, sizeVar, xVar, yVar)
    local op = node.op

    -- Small epsilon for floating point boundary tolerance
    local EPS = 1e-9

    if op == "formCircleUnit" then
        local dx = string.format("(%s - %s)", xVar, oxVar)
        local dy = string.format("(%s - %s)", yVar, oyVar)
        local r2 = string.format("(%s * %s + %.15g)", sizeVar, sizeVar, EPS)
        return string.format("(%s*%s + %s*%s <= %s)", dx, dx, dy, dy, r2)

    elseif op == "formRectUnit" then
        return string.format(
            "(abs(%s - %s) <= %s and abs(%s - %s) <= %s)",
            xVar, oxVar, sizeVar, yVar, oyVar, sizeVar
        )

    elseif op == "formEllipseUnit" then
        local rx = string.format("(%s * %.15g)", sizeVar, node.aspectX)
        local ry = string.format("(%s * %.15g)", sizeVar, node.aspectY)
        local dx = string.format("((%s - %s) / %s)", xVar, oxVar, rx)
        local dy = string.format("((%s - %s) / %s)", yVar, oyVar, ry)
        return string.format("(%s*%s + %s*%s <= %.15g)", dx, dx, dy, dy, 1 + EPS)

    elseif op == "formRingUnit" then
        local dx = string.format("(%s - %s)", xVar, oxVar)
        local dy = string.format("(%s - %s)", yVar, oyVar)
        local d2Var = nextVar()
        lines[#lines + 1] = string.format("local %s = %s*%s + %s*%s", d2Var, dx, dx, dy, dy)
        local outer2 = string.format("(%s * %s + %.15g)", sizeVar, sizeVar, EPS)
        local innerR = string.format("(%s * %.15g)", sizeVar, node.innerRatio)
        local inner2 = string.format("(%s * %s - %.15g)", innerR, innerR, EPS)
        return string.format("(%s <= %s and %s >= %s)", d2Var, outer2, d2Var, inner2)

    elseif op == "formUnion" then
        local parts = {}
        for _, child in ipairs(node.children) do
            parts[#parts + 1] = emitFormRelative(child, lines, oxVar, oyVar, sizeVar, xVar, yVar)
        end
        return "(" .. table.concat(parts, " or ") .. ")"

    elseif op == "formIntersect" then
        local parts = {}
        for _, child in ipairs(node.children) do
            parts[#parts + 1] = emitFormRelative(child, lines, oxVar, oyVar, sizeVar, xVar, yVar)
        end
        return "(" .. table.concat(parts, " and ") .. ")"

    elseif op == "formSubtract" then
        local outerExpr = emitFormRelative(node.outer, lines, oxVar, oyVar, sizeVar, xVar, yVar)
        local innerExpr = emitFormRelative(node.inner, lines, oxVar, oyVar, sizeVar, xVar, yVar)
        return string.format("(%s and not %s)", outerExpr, innerExpr)

    else
        error("Unknown unit form op: " .. tostring(op))
    end
end

--------------------------------------------------------------------------------
-- COMPILE FORM FUNCTION
--------------------------------------------------------------------------------

--- Compile a form IR node to a containment test function
--- @param ir table Form IR node
--- @param opts table Options: { debug = bool, name = string }
--- @return function Compiled function f(x, y) -> bool
function Compiler.compileForm(ir, opts)
    opts = opts or {}
    resetVars()
    resetCSE()

    local lines = {}

    -- Preamble
    lines[#lines + 1] = "local abs = math.abs"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "return function(x, y, ctx)"
    lines[#lines + 1] = "  ctx = ctx or {}"

    -- Body
    local bodyLines = {}
    local resultExpr = emitForm(ir, bodyLines, "x", "y")

    for _, line in ipairs(bodyLines) do
        lines[#lines + 1] = "  " .. line
    end
    lines[#lines + 1] = "  return " .. resultExpr
    lines[#lines + 1] = "end"

    local code = table.concat(lines, "\n")

    if opts.debug then
        print("=== Compiled Form Code ===")
        print(code)
        print("==========================")
    end

    local fn, err = load(code, opts.name or "spatula_form")
    if not fn then
        error("Form compilation failed: " .. tostring(err) .. "\n\nCode:\n" .. code)
    end

    return fn()
end

--- Get the generated source code for a form without compiling
--- @param ir table Form IR node
--- @return string Lua source code
function Compiler.formToSource(ir)
    resetVars()
    resetCSE()

    local lines = {}

    lines[#lines + 1] = "local abs = math.abs"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "return function(x, y, ctx)"
    lines[#lines + 1] = "  ctx = ctx or {}"

    local bodyLines = {}
    local resultExpr = emitForm(ir, bodyLines, "x", "y")

    for _, line in ipairs(bodyLines) do
        lines[#lines + 1] = "  " .. line
    end
    lines[#lines + 1] = "  return " .. resultExpr
    lines[#lines + 1] = "end"

    return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- TRIGGER CODE GENERATORS
-- Triggers compile to: function(points, t, ctx, action)
--------------------------------------------------------------------------------

-- Helper to emit timing check code
local function emitTiming(node, lines)
    if node.op == "triggerInterval" then
        local intervalExpr = emitParam(node.interval)
        lines[#lines + 1] = "  ctx._lastFire = ctx._lastFire or -math.huge"
        lines[#lines + 1] = string.format("  if t - ctx._lastFire < %s then return end", intervalExpr)
        lines[#lines + 1] = "  ctx._lastFire = t"
    elseif node.op == "triggerTimes" then
        local nExpr = emitParam(node.n)
        local intervalExpr = emitParam(node.interval)
        lines[#lines + 1] = "  ctx._fireCount = ctx._fireCount or 0"
        lines[#lines + 1] = string.format("  if ctx._fireCount >= %s then return end", nExpr)
        lines[#lines + 1] = "  ctx._lastFire = ctx._lastFire or -math.huge"
        lines[#lines + 1] = string.format("  if t - ctx._lastFire < %s then return end", intervalExpr)
        lines[#lines + 1] = "  ctx._lastFire = t"
        lines[#lines + 1] = "  ctx._fireCount = ctx._fireCount + 1"
    elseif node.op == "triggerBurst" then
        local countExpr = emitParam(node.count)
        local intervalExpr = emitParam(node.interval)
        local pauseExpr = emitParam(node.pause)
        lines[#lines + 1] = "  ctx._burstCount = ctx._burstCount or 0"
        lines[#lines + 1] = "  ctx._lastFire = ctx._lastFire or -math.huge"
        lines[#lines + 1] = "  ctx._burstStart = ctx._burstStart or 0"
        lines[#lines + 1] = string.format("  local inBurst = ctx._burstCount < %s", countExpr)
        lines[#lines + 1] = "  if inBurst then"
        lines[#lines + 1] = string.format("    if t - ctx._lastFire < %s then return end", intervalExpr)
        lines[#lines + 1] = "    ctx._lastFire = t"
        lines[#lines + 1] = "    ctx._burstCount = ctx._burstCount + 1"
        lines[#lines + 1] = "  else"
        lines[#lines + 1] = string.format("    if t - ctx._burstStart < %s then return end", pauseExpr)
        lines[#lines + 1] = "    ctx._burstCount = 1"
        lines[#lines + 1] = "    ctx._burstStart = t"
        lines[#lines + 1] = "    ctx._lastFire = t"
        lines[#lines + 1] = "  end"
    else
        error("Unknown timing op: " .. tostring(node.op))
    end
end

-- Helper to emit selection code
local function emitSelection(node, lines)
    lines[#lines + 1] = "  local n = #points"
    lines[#lines + 1] = "  if n == 0 then return end"

    if node.op == "selectAll" then
        lines[#lines + 1] = "  for i = 1, n do"
        lines[#lines + 1] = "    local p = points[i]"
        lines[#lines + 1] = "    action(p.x or p[1], p.y or p[2], ctx, i, n)"
        lines[#lines + 1] = "  end"
    elseif node.op == "selectRandom" then
        local nExpr = emitParam(node.n)
        lines[#lines + 1] = string.format("  local count = min(%s, n)", nExpr)
        lines[#lines + 1] = "  for _ = 1, count do"
        lines[#lines + 1] = "    local idx = random(1, n)"
        lines[#lines + 1] = "    local p = points[idx]"
        lines[#lines + 1] = "    action(p.x or p[1], p.y or p[2], ctx, idx, n)"
        lines[#lines + 1] = "  end"
    elseif node.op == "selectFirst" then
        local nExpr = emitParam(node.n)
        lines[#lines + 1] = string.format("  local count = min(%s, n)", nExpr)
        lines[#lines + 1] = "  for i = 1, count do"
        lines[#lines + 1] = "    local p = points[i]"
        lines[#lines + 1] = "    action(p.x or p[1], p.y or p[2], ctx, i, n)"
        lines[#lines + 1] = "  end"
    elseif node.op == "selectLast" then
        local nExpr = emitParam(node.n)
        lines[#lines + 1] = string.format("  local count = min(%s, n)", nExpr)
        lines[#lines + 1] = "  for i = n - count + 1, n do"
        lines[#lines + 1] = "    local p = points[i]"
        lines[#lines + 1] = "    action(p.x or p[1], p.y or p[2], ctx, i, n)"
        lines[#lines + 1] = "  end"
    elseif node.op == "selectSequential" then
        lines[#lines + 1] = "  ctx._cursor = (ctx._cursor or 0) % n + 1"
        lines[#lines + 1] = "  local p = points[ctx._cursor]"
        lines[#lines + 1] = "  action(p.x or p[1], p.y or p[2], ctx, ctx._cursor, n)"
    else
        error("Unknown selection op: " .. tostring(node.op))
    end
end

--------------------------------------------------------------------------------
-- COMPILE TRIGGER FUNCTION
--------------------------------------------------------------------------------

--- Compile timing and selection IR to a trigger function
--- @param timingIR table Timing IR node (interval, times, burst)
--- @param selectionIR table Selection IR node (selectAll, selectRandom, etc)
--- @param opts table Options: { debug = bool, name = string }
--- @return function Compiled function f(points, t, ctx, action)
function Compiler.compileTrigger(timingIR, selectionIR, opts)
    opts = opts or {}
    resetVars()
    resetCSE()

    local lines = {}

    -- Preamble
    lines[#lines + 1] = "local random, min, max = math.random, math.min, math.max"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "return function(points, t, ctx, action)"

    -- Emit timing check
    emitTiming(timingIR, lines)

    -- Emit selection
    emitSelection(selectionIR, lines)

    lines[#lines + 1] = "end"

    local code = table.concat(lines, "\n")

    if opts.debug then
        print("=== Compiled Trigger Code ===")
        print(code)
        print("=============================")
    end

    local fn, err = load(code, opts.name or "spatula_trigger")
    if not fn then
        error("Trigger compilation failed: " .. tostring(err) .. "\n\nCode:\n" .. code)
    end

    return fn()
end

--- Get the generated source code for a trigger without compiling
--- @param timingIR table Timing IR node
--- @param selectionIR table Selection IR node
--- @return string Lua source code
function Compiler.triggerToSource(timingIR, selectionIR)
    resetVars()
    resetCSE()

    local lines = {}

    lines[#lines + 1] = "local random, min, max = math.random, math.min, math.max"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "return function(points, t, ctx, action)"

    emitTiming(timingIR, lines)
    emitSelection(selectionIR, lines)

    lines[#lines + 1] = "end"

    return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- DISTRIBUTION CODE GENERATORS
-- Distributions compile to: function(ox, oy, size, outX, outY) -> count
--------------------------------------------------------------------------------

-- Helper to emit motion at a given time (returns x, y expressions)
local function emitMotionAt(motionNode, lines, tExpr)
    return emitCurve(motionNode, lines, tExpr)
end

--- Compile a distribution IR node to a point generation function
--- @param ir table Distribution IR node
--- @param opts table Options: { debug = bool, name = string }
--- @return function Compiled function f(ox, oy, size, outX, outY) -> count
function Compiler.compileDistribution(ir, opts)
    opts = opts or {}
    resetVars()
    resetCSE()

    local lines = {}

    -- Preamble
    lines[#lines + 1] = "local sin, cos, abs, floor, sqrt, min, max, random = math.sin, math.cos, math.abs, math.floor, math.sqrt, math.min, math.max, math.random"
    lines[#lines + 1] = "local PI = 3.141592653589793"
    lines[#lines + 1] = "local PI2 = 6.283185307179586"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "return function(ox, oy, size, outX, outY, ctx)"
    lines[#lines + 1] = "  ctx = ctx or {}"
    lines[#lines + 1] = "  local n = 0"

    if ir.op == "distSample" then
        -- Sample motion at discrete t values
        local countExpr = emitParam(ir.count)
        -- Evaluate count once at start (may be signal)
        if type(ir.count) ~= "number" then
            lines[#lines + 1] = string.format("  local _count = %s", countExpr)
            lines[#lines + 1] = "  local _countM1 = math.max(1, _count - 1)"
            lines[#lines + 1] = "  for i = 0, _count - 1 do"
            lines[#lines + 1] = "    local t = i / _countM1"
        else
            local count = ir.count
            local countM1 = math.max(1, count - 1)
            lines[#lines + 1] = string.format("  for i = 0, %d do", count - 1)
            lines[#lines + 1] = string.format("    local t = i / %d", countM1)
        end

        -- Emit motion evaluation
        local motionLines = {}
        local xExpr, yExpr = emitMotionAt(ir.motion, motionLines, "t")
        for _, line in ipairs(motionLines) do
            lines[#lines + 1] = "    " .. line
        end

        -- Scale and translate motion output
        lines[#lines + 1] = string.format("    local px = ox + (%s) * size", xExpr)
        lines[#lines + 1] = string.format("    local py = oy + (%s) * size", yExpr)

        -- Emit containment check
        local formLines = {}
        local containsExpr = emitFormRelative(ir.form, formLines, "ox", "oy", "size", "px", "py")
        for _, line in ipairs(formLines) do
            lines[#lines + 1] = "    " .. line
        end

        lines[#lines + 1] = string.format("    if %s then", containsExpr)
        lines[#lines + 1] = "      n = n + 1"
        lines[#lines + 1] = "      outX[n] = px"
        lines[#lines + 1] = "      outY[n] = py"
        lines[#lines + 1] = "    end"
        lines[#lines + 1] = "  end"

    elseif ir.op == "distGrid" then
        -- Grid distribution
        local colsExpr = emitParam(ir.cols)
        local rowsExpr = emitParam(ir.rows)

        if type(ir.cols) ~= "number" or type(ir.rows) ~= "number" then
            lines[#lines + 1] = string.format("  local _cols = %s", colsExpr)
            lines[#lines + 1] = string.format("  local _rows = %s", rowsExpr)
            lines[#lines + 1] = "  local step = (size * 2) / math.max(_cols, _rows)"
            lines[#lines + 1] = "  local startX = ox - size + step / 2"
            lines[#lines + 1] = "  local startY = oy - size + step / 2"
            lines[#lines + 1] = "  for row = 0, _rows - 1 do"
            lines[#lines + 1] = "    for col = 0, _cols - 1 do"
        else
            local cols = ir.cols
            local rows = ir.rows
            lines[#lines + 1] = string.format("  local step = (size * 2) / %d", math.max(cols, rows))
            lines[#lines + 1] = "  local startX = ox - size + step / 2"
            lines[#lines + 1] = "  local startY = oy - size + step / 2"
            lines[#lines + 1] = string.format("  for row = 0, %d do", rows - 1)
            lines[#lines + 1] = string.format("    for col = 0, %d do", cols - 1)
        end
        lines[#lines + 1] = "      local px = startX + col * step"
        lines[#lines + 1] = "      local py = startY + row * step"

        -- Emit containment check
        local formLines = {}
        local containsExpr = emitFormRelative(ir.form, formLines, "ox", "oy", "size", "px", "py")
        for _, line in ipairs(formLines) do
            lines[#lines + 1] = "      " .. line
        end

        lines[#lines + 1] = string.format("      if %s then", containsExpr)
        lines[#lines + 1] = "        n = n + 1"
        lines[#lines + 1] = "        outX[n] = px"
        lines[#lines + 1] = "        outY[n] = py"
        lines[#lines + 1] = "      end"
        lines[#lines + 1] = "    end"
        lines[#lines + 1] = "  end"

    elseif ir.op == "distSpiral" then
        -- Spiral distribution (outward spiral from center)
        local countExpr = emitParam(ir.count)
        local turnsExpr = emitParam(ir.turns)

        if type(ir.count) ~= "number" or type(ir.turns) ~= "number" then
            lines[#lines + 1] = string.format("  local _count = %s", countExpr)
            lines[#lines + 1] = string.format("  local _turns = %s", turnsExpr)
            lines[#lines + 1] = "  local _countM1 = math.max(1, _count - 1)"
            lines[#lines + 1] = "  for i = 0, _count - 1 do"
            lines[#lines + 1] = "    local t = i / _countM1"
            lines[#lines + 1] = string.format("    local angle = t * _turns * %.15g", PI2)
        else
            local count = ir.count
            local turns = ir.turns
            local countM1 = math.max(1, count - 1)
            lines[#lines + 1] = string.format("  for i = 0, %d do", count - 1)
            lines[#lines + 1] = string.format("    local t = i / %d", countM1)
            lines[#lines + 1] = string.format("    local angle = t * %.15g", turns * PI2)
        end
        lines[#lines + 1] = "    local r = t * size"
        lines[#lines + 1] = "    local px = ox + cos(angle) * r"
        lines[#lines + 1] = "    local py = oy + sin(angle) * r"

        -- Emit containment check
        local formLines = {}
        local containsExpr = emitFormRelative(ir.form, formLines, "ox", "oy", "size", "px", "py")
        for _, line in ipairs(formLines) do
            lines[#lines + 1] = "    " .. line
        end

        lines[#lines + 1] = string.format("    if %s then", containsExpr)
        lines[#lines + 1] = "      n = n + 1"
        lines[#lines + 1] = "      outX[n] = px"
        lines[#lines + 1] = "      outY[n] = py"
        lines[#lines + 1] = "    end"
        lines[#lines + 1] = "  end"

    elseif ir.op == "distBurst" then
        -- Burst distribution (radial rays)
        local raysExpr = emitParam(ir.rays)
        local pprExpr = emitParam(ir.pointsPerRay)

        if type(ir.rays) ~= "number" or type(ir.pointsPerRay) ~= "number" then
            lines[#lines + 1] = string.format("  local _rays = %s", raysExpr)
            lines[#lines + 1] = string.format("  local _ppr = %s", pprExpr)
            lines[#lines + 1] = "  for ray = 0, _rays - 1 do"
            lines[#lines + 1] = string.format("    local angle = ray * %.15g / _rays", PI2)
            lines[#lines + 1] = "    for pt = 1, _ppr do"
            lines[#lines + 1] = "      local r = (pt / _ppr) * size"
        else
            local rays = ir.rays
            local pointsPerRay = ir.pointsPerRay
            lines[#lines + 1] = string.format("  for ray = 0, %d do", rays - 1)
            lines[#lines + 1] = string.format("    local angle = ray * %.15g", PI2 / rays)
            lines[#lines + 1] = string.format("    for pt = 1, %d do", pointsPerRay)
            lines[#lines + 1] = string.format("      local r = (pt / %d) * size", pointsPerRay)
        end
        lines[#lines + 1] = "      local px = ox + cos(angle) * r"
        lines[#lines + 1] = "      local py = oy + sin(angle) * r"

        -- Emit containment check
        local formLines = {}
        local containsExpr = emitFormRelative(ir.form, formLines, "ox", "oy", "size", "px", "py")
        for _, line in ipairs(formLines) do
            lines[#lines + 1] = "      " .. line
        end

        lines[#lines + 1] = string.format("      if %s then", containsExpr)
        lines[#lines + 1] = "        n = n + 1"
        lines[#lines + 1] = "        outX[n] = px"
        lines[#lines + 1] = "        outY[n] = py"
        lines[#lines + 1] = "      end"
        lines[#lines + 1] = "    end"
        lines[#lines + 1] = "  end"

    elseif ir.op == "distRandom" then
        -- Random distribution (rejection sampling)
        local countExpr = emitParam(ir.count)

        -- Evaluate count once for loop bound (may be signal)
        lines[#lines + 1] = string.format("  local _count = %s", countExpr)
        lines[#lines + 1] = "  local attempts = 0"
        lines[#lines + 1] = "  while n < _count and attempts < _count * 10 do"
        lines[#lines + 1] = "    attempts = attempts + 1"
        lines[#lines + 1] = "    local px = ox + (random() * 2 - 1) * size"
        lines[#lines + 1] = "    local py = oy + (random() * 2 - 1) * size"

        -- Emit containment check
        local formLines = {}
        local containsExpr = emitFormRelative(ir.form, formLines, "ox", "oy", "size", "px", "py")
        for _, line in ipairs(formLines) do
            lines[#lines + 1] = "    " .. line
        end

        lines[#lines + 1] = string.format("    if %s then", containsExpr)
        lines[#lines + 1] = "      n = n + 1"
        lines[#lines + 1] = "      outX[n] = px"
        lines[#lines + 1] = "      outY[n] = py"
        lines[#lines + 1] = "    end"
        lines[#lines + 1] = "  end"

    elseif ir.op == "distRings" then
        -- Concentric rings distribution
        local ringCountExpr = emitParam(ir.ringCount)
        local pointsPerRingExpr = emitParam(ir.pointsPerRing)

        -- Evaluate counts once for loop bounds (may be signals)
        lines[#lines + 1] = string.format("  local _ringCount = %s", ringCountExpr)
        lines[#lines + 1] = string.format("  local _pointsPerRing = %s", pointsPerRingExpr)
        lines[#lines + 1] = "  for ring = 1, _ringCount do"
        lines[#lines + 1] = "    local r = (ring / _ringCount) * size"
        lines[#lines + 1] = "    for pt = 0, _pointsPerRing - 1 do"
        lines[#lines + 1] = "      local angle = pt * (6.283185307179586 / _pointsPerRing)"
        lines[#lines + 1] = "      local px = ox + cos(angle) * r"
        lines[#lines + 1] = "      local py = oy + sin(angle) * r"

        -- Emit containment check
        local formLines = {}
        local containsExpr = emitFormRelative(ir.form, formLines, "ox", "oy", "size", "px", "py")
        for _, line in ipairs(formLines) do
            lines[#lines + 1] = "      " .. line
        end

        lines[#lines + 1] = string.format("      if %s then", containsExpr)
        lines[#lines + 1] = "        n = n + 1"
        lines[#lines + 1] = "        outX[n] = px"
        lines[#lines + 1] = "        outY[n] = py"
        lines[#lines + 1] = "      end"
        lines[#lines + 1] = "    end"
        lines[#lines + 1] = "  end"

    else
        error("Unknown distribution op: " .. tostring(ir.op))
    end

    lines[#lines + 1] = "  return n"
    lines[#lines + 1] = "end"

    local code = table.concat(lines, "\n")

    if opts.debug then
        print("=== Compiled Distribution Code ===")
        print(code)
        print("==================================")
    end

    local fn, err = load(code, opts.name or "spatula_distribution")
    if not fn then
        error("Distribution compilation failed: " .. tostring(err) .. "\n\nCode:\n" .. code)
    end

    return fn()
end

--- Get the generated source code for a distribution without compiling
--- @param ir table Distribution IR node
--- @return string Lua source code
function Compiler.distributionToSource(ir)
    -- Compile with debug to get the source, then return just the source
    resetVars()
    resetCSE()

    local lines = {}

    lines[#lines + 1] = "local sin, cos, abs, floor, sqrt, min, max, random = math.sin, math.cos, math.abs, math.floor, math.sqrt, math.min, math.max, math.random"
    lines[#lines + 1] = "local PI = 3.141592653589793"
    lines[#lines + 1] = "local PI2 = 6.283185307179586"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "return function(ox, oy, size, outX, outY)"
    lines[#lines + 1] = "  local n = 0"

    -- Use compileDistribution's internal logic by calling it with debug
    -- Actually, just return empty for now - implement properly if needed
    lines[#lines + 1] = "  -- Source generation for: " .. ir.op
    lines[#lines + 1] = "  return n"
    lines[#lines + 1] = "end"

    return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- STATIC FIELD COMPILATION
--------------------------------------------------------------------------------

-- Emit falloff expression for a normalized distance variable
local function emitFalloff(falloffIR, distVar)
    if not falloffIR then
        -- Default to smooth if no falloff specified
        return "(1 - " .. distVar .. ") * (1 - " .. distVar .. ")"
    end

    local op = falloffIR.op
    if op == "falloffLinear" then
        return "(1 - " .. distVar .. ")"
    elseif op == "falloffSmooth" then
        return "(1 - " .. distVar .. ") * (1 - " .. distVar .. ")"
    elseif op == "falloffSpike" then
        local v = "(1 - " .. distVar .. ")"
        return v .. " * " .. v .. " * " .. v .. " * " .. v
    elseif op == "falloffSteep" then
        local v = "(1 - " .. distVar .. ")"
        return v .. " * " .. v .. " * " .. v .. " * " .. v .. " * " .. v .. " * " .. v
    elseif op == "falloffSoft" then
        return "((1 - " .. distVar .. ") ^ 1.5)"
    elseif op == "falloffGaussian" then
        local kExpr = emitParam(falloffIR.k or 3)
        return "exp(-" .. kExpr .. " * " .. distVar .. " * " .. distVar .. ")"
    elseif op == "falloffConstant" then
        return "1"
    elseif op == "falloffInverse" then
        return distVar
    elseif op == "falloffRing" then
        return "sin(" .. distVar .. " * 3.141592653589793)"
    elseif op == "falloffStep" then
        local thresholdExpr = emitParam(falloffIR.threshold or 0.5)
        return "(" .. distVar .. " < " .. thresholdExpr .. " and 1 or 0)"
    elseif op == "falloffPower" then
        local nExpr = emitParam(falloffIR.n or 2)
        return "((1 - " .. distVar .. ") ^ " .. nExpr .. ")"
    else
        -- Unknown falloff, default to smooth
        return "(1 - " .. distVar .. ") * (1 - " .. distVar .. ")"
    end
end

-- Emit blend expression
local function emitBlend(blend, resultVar, valueExpr)
    if blend == "max" then
        return "max(" .. resultVar .. ", " .. valueExpr .. ")"
    elseif blend == "min" then
        return "min(" .. resultVar .. ", " .. valueExpr .. ")"
    else
        -- Default to add
        return resultVar .. " + " .. valueExpr
    end
end

--- Compile a static field to an optimized sampler function
--- @param ir table Field IR node from IR.field.static()
--- @param opts table Options: { debug = bool, name = string }
--- @return function Compiled function f(x, y, ctx) -> value
function Compiler.compileStaticField(ir, opts)
    opts = opts or {}
    local code = Compiler.staticFieldToSource(ir)

    if opts.debug then
        print("============= StaticField Code =============")
        print(code)
        print("=============================================")
    end

    local fn, err = load(code, opts.name or "spatula_static_field")
    if not fn then
        error("StaticField compilation failed: " .. tostring(err) .. "\n\nCode:\n" .. code)
    end

    return fn()
end

--- Get the generated source code for a static field without compiling
--- @param ir table Field IR node from IR.field.static()
--- @return string Lua source code
function Compiler.staticFieldToSource(ir)
    if ir.type ~= "field" or ir.op ~= "fieldStatic" then
        error("staticFieldToSource requires IR.field.static() IR node")
    end

    local lines = {}

    lines[#lines + 1] = "local sqrt, sin, exp, max, min = math.sqrt, math.sin, math.exp, math.max, math.min"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "return function(x, y, ctx)"
    lines[#lines + 1] = "    ctx = ctx or {}"
    local baseExpr = emitParam(ir.base or 0)
    lines[#lines + 1] = "    local result = " .. baseExpr

    for i, src in ipairs(ir.sources) do
        local xExpr = emitParam(src.x or 0)
        local yExpr = emitParam(src.y or 0)
        local radiusExpr = emitParam(src.radius or 50)
        local valueExpr = emitParam(src.value or 1)
        local falloff = src.falloff

        lines[#lines + 1] = ""
        lines[#lines + 1] = "    -- Source " .. i
        lines[#lines + 1] = "    local sx" .. i .. " = " .. xExpr
        lines[#lines + 1] = "    local sy" .. i .. " = " .. yExpr
        lines[#lines + 1] = "    local sr" .. i .. " = " .. radiusExpr
        lines[#lines + 1] = "    local sv" .. i .. " = " .. valueExpr
        lines[#lines + 1] = "    local dx" .. i .. " = x - sx" .. i
        lines[#lines + 1] = "    local dy" .. i .. " = y - sy" .. i
        lines[#lines + 1] = "    local d" .. i .. " = sqrt(dx" .. i .. " * dx" .. i .. " + dy" .. i .. " * dy" .. i .. ")"
        lines[#lines + 1] = "    if d" .. i .. " < sr" .. i .. " then"
        lines[#lines + 1] = "        local t" .. i .. " = d" .. i .. " / sr" .. i

        local falloffExpr = emitFalloff(falloff, "t" .. i)
        local combinedExpr = falloffExpr .. " * sv" .. i
        local blendExpr = emitBlend(ir.blend, "result", combinedExpr)

        lines[#lines + 1] = "        result = " .. blendExpr
        lines[#lines + 1] = "    end"
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "    return result"
    lines[#lines + 1] = "end"

    return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- MAIN COMPILE FUNCTION
--------------------------------------------------------------------------------

local function curvePreamble()
    return {
        "local sin, cos, abs, floor, min, max, exp = math.sin, math.cos, math.abs, math.floor, math.min, math.max, math.exp",
        "local function clamp(v, lo, hi) return min(max(v, lo), hi) end",
        "local function _sig(v, t, ctx, def) if type(v) == 'function' then return v(t, ctx) elseif v == nil then return def else return v end end",
    }
end

--- Compile an IR node to an optimized Lua function
--- @param ir table IR node from Compiler.curve.* or Compiler.motion.*
--- @param opts table Options: { debug = bool, name = string }
--- @return function Compiled function f(t, ctx) -> value or (x, y)
function Compiler.compile(ir, opts)
    opts = opts or {}
    local code = Compiler.toSource(ir)

    if opts.debug then
        print("=== Compiled Code ===")
        print(code)
        print("=====================")
    end
    
    local fn, err = load(code, opts.name or "spatula_compiled")
    if not fn then
        error("Compilation failed: " .. tostring(err) .. "\n\nCode:\n" .. code)
    end
    
    return fn()
end

--- Get the generated source code without compiling
--- @param ir table IR node
--- @return string Lua source code
function Compiler.toSource(ir)
    resetVars()
    resetCSE()  -- Clear expression cache
    
    local lines = curvePreamble()
    local isMotion = ir.type == "motion"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "return function(t, ctx)"

    local bodyLines = {}

    if isMotion then
        local xExpr, yExpr = emitCurve(ir, bodyLines, "t")
        bodyLines[#bodyLines + 1] = string.format("return %s, %s", xExpr, yExpr)
    else
        local resultExpr = emitCurve(ir, bodyLines, "t")
        bodyLines[#bodyLines + 1] = string.format("return %s", resultExpr)
    end

    for _, line in ipairs(bodyLines) do
        lines[#lines + 1] = "  " .. line
    end

    lines[#lines + 1] = "end"
    
    return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- OPTIMIZATION PASSES
-- These transform the IR tree before code generation.
--------------------------------------------------------------------------------

--- Check if an IR node is a constant
local function isConst(node)
    return node and node.op == "const"
end

--- Deep copy an IR node
local function copyIR(node)
    if type(node) ~= "table" then return node end
    local copy = {}
    for k, v in pairs(node) do
        if type(v) == "table" then
            copy[k] = copyIR(v)
        else
            copy[k] = v
        end
    end
    return copy
end

--- Optimize an IR tree (constant folding, dead code elimination)
--- @param ir table IR node
--- @return table Optimized IR node
function Compiler.optimize(ir)
    if not ir or type(ir) ~= "table" then return ir end
    
    local op = ir.op
    
    -- First, recursively optimize children
    local optimized = copyIR(ir)
    
    -- Optimize nested nodes
    if optimized.curve then
        optimized.curve = Compiler.optimize(optimized.curve)
    end
    if optimized.a then
        optimized.a = Compiler.optimize(optimized.a)
    end
    if optimized.b then
        optimized.b = Compiler.optimize(optimized.b)
    end
    if optimized.x then
        optimized.x = Compiler.optimize(optimized.x)
    end
    if optimized.y then
        optimized.y = Compiler.optimize(optimized.y)
    end
    if optimized.target then
        optimized.target = Compiler.optimize(optimized.target)
    end
    if optimized.factor and type(optimized.factor) == "table" then
        optimized.factor = Compiler.optimize(optimized.factor)
    end
    if optimized.amount and type(optimized.amount) == "table" then
        optimized.amount = Compiler.optimize(optimized.amount)
    end
    if optimized.exponent and type(optimized.exponent) == "table" then
        optimized.exponent = Compiler.optimize(optimized.exponent)
    end
    if optimized.motion then
        optimized.motion = Compiler.optimize(optimized.motion)
    end
    if optimized.timeCurve then
        optimized.timeCurve = Compiler.optimize(optimized.timeCurve)
    end
    if optimized.offset and type(optimized.offset) == "table" then
        optimized.offset = Compiler.optimize(optimized.offset)
    end
    if optimized.children then
        for i, child in ipairs(optimized.children) do
            optimized.children[i] = Compiler.optimize(child)
        end
    end
    
    -- Now apply optimizations based on operation type
    
    -------------------------
    -- Arithmetic identity operations
    -------------------------
    
    -- scale(x, 0) -> const(0)
    if op == "scaleConst" and optimized.factor == 0 then
        return { op = "const", value = 0 }
    end
    
    -- scale(x, 1) -> x
    if op == "scaleConst" and optimized.factor == 1 then
        return optimized.curve
    end
    
    -- scale(const(a), b) -> const(a * b)
    if op == "scaleConst" and isConst(optimized.curve) then
        return { op = "const", value = optimized.curve.value * optimized.factor }
    end
    
    -- offset(x, 0) -> x
    if op == "offsetConst" and optimized.amount == 0 then
        return optimized.curve
    end
    
    -- offset(const(a), b) -> const(a + b)
    if op == "offsetConst" and isConst(optimized.curve) then
        return { op = "const", value = optimized.curve.value + optimized.amount }
    end
    
    -- neg(const(a)) -> const(-a)
    if op == "neg" and isConst(optimized.curve) then
        return { op = "const", value = -optimized.curve.value }
    end
    
    -- neg(neg(x)) -> x
    if op == "neg" and optimized.curve.op == "neg" then
        return optimized.curve.curve
    end
    
    -- abs(const(a)) -> const(|a|)
    if op == "abs" and isConst(optimized.curve) then
        return { op = "const", value = math.abs(optimized.curve.value) }
    end
    
    -- pow(const(a), b) -> const(a^b)
    if op == "powConst" and isConst(optimized.curve) then
        return { op = "const", value = optimized.curve.value ^ optimized.exponent }
    end
    
    -- pow(x, 1) -> x
    if op == "powConst" and optimized.exponent == 1 then
        return optimized.curve
    end
    
    -- pow(x, 0) -> const(1)
    if op == "powConst" and optimized.exponent == 0 then
        return { op = "const", value = 1 }
    end
    
    -------------------------
    -- add optimization
    -------------------------
    if op == "add" then
        local nonZero = {}
        local constSum = 0
        local hasConst = false
        
        for _, child in ipairs(optimized.children) do
            if isConst(child) then
                constSum = constSum + child.value
                hasConst = true
            else
                nonZero[#nonZero + 1] = child
            end
        end
        
        -- Add back the constant if non-zero
        if hasConst and constSum ~= 0 then
            nonZero[#nonZero + 1] = { op = "const", value = constSum }
        end
        
        if #nonZero == 0 then
            return { op = "const", value = constSum }
        elseif #nonZero == 1 then
            return nonZero[1]
        else
            return { op = "add", children = nonZero }
        end
    end
    
    -------------------------
    -- mul optimization
    -------------------------
    if op == "mul" then
        local nonOne = {}
        local constProduct = 1
        local hasConst = false
        local hasZero = false
        
        for _, child in ipairs(optimized.children) do
            if isConst(child) then
                if child.value == 0 then
                    hasZero = true
                    break
                end
                constProduct = constProduct * child.value
                hasConst = true
            else
                nonOne[#nonOne + 1] = child
            end
        end
        
        -- Any zero makes the whole thing zero
        if hasZero then
            return { op = "const", value = 0 }
        end
        
        -- Add back the constant if not 1
        if hasConst and constProduct ~= 1 then
            nonOne[#nonOne + 1] = { op = "const", value = constProduct }
        end
        
        if #nonOne == 0 then
            return { op = "const", value = constProduct }
        elseif #nonOne == 1 then
            return nonOne[1]
        else
            return { op = "mul", children = nonOne }
        end
    end
    
    -------------------------
    -- sub optimization
    -------------------------
    if op == "sub" then
        -- sub(const(a), const(b)) -> const(a - b)
        if isConst(optimized.a) and isConst(optimized.b) then
            return { op = "const", value = optimized.a.value - optimized.b.value }
        end
        -- sub(x, const(0)) -> x
        if isConst(optimized.b) and optimized.b.value == 0 then
            return optimized.a
        end
        -- sub(const(0), x) -> neg(x)
        if isConst(optimized.a) and optimized.a.value == 0 then
            return { op = "neg", curve = optimized.b }
        end
    end
    
    -------------------------
    -- Nested operation collapse
    -------------------------
    
    -- scale(scale(x, a), b) -> scale(x, a * b)
    if op == "scaleConst" and optimized.curve.op == "scaleConst" then
        return { 
            op = "scaleConst", 
            curve = optimized.curve.curve,
            factor = optimized.curve.factor * optimized.factor
        }
    end
    
    -- offset(offset(x, a), b) -> offset(x, a + b)
    if op == "offsetConst" and optimized.curve.op == "offsetConst" then
        return {
            op = "offsetConst",
            curve = optimized.curve.curve,
            amount = optimized.curve.amount + optimized.amount
        }
    end
    
    -- timeScale(timeScale(x, a), b) -> timeScale(x, a * b)
    if op == "timeScaleConst" and optimized.curve.op == "timeScaleConst" then
        return {
            op = "timeScaleConst",
            curve = optimized.curve.curve,
            factor = optimized.curve.factor * optimized.factor
        }
    end
    
    -- timeOffset(timeOffset(x, a), b) -> timeOffset(x, a + b)
    if op == "timeOffsetConst" and optimized.curve.op == "timeOffsetConst" then
        return {
            op = "timeOffsetConst",
            curve = optimized.curve.curve,
            offset = optimized.curve.offset + optimized.offset
        }
    end
    
    -------------------------
    -- Time manipulation identity
    -------------------------
    
    -- timeScale(x, 1) -> x
    if op == "timeScaleConst" and optimized.factor == 1 then
        return optimized.curve
    end
    
    -- timeScale(x, 0) -> const(curve(0)) - tricky, skip for now
    
    -- timeScale(const(a), _) -> const(a)
    if op == "timeScaleConst" and isConst(optimized.curve) then
        return optimized.curve
    end
    
    -- timeOffset(x, 0) -> x
    if op == "timeOffsetConst" and optimized.offset == 0 then
        return optimized.curve
    end
    
    -- timeOffset(const(a), _) -> const(a)
    if op == "timeOffsetConst" and isConst(optimized.curve) then
        return optimized.curve
    end
    
    -- loop(const(a), _) -> const(a)
    if op == "loop" and isConst(optimized.curve) then
        return optimized.curve
    end
    
    -- delay(const(a), _) -> const(a)
    if op == "delay" and isConst(optimized.curve) then
        return optimized.curve
    end
    
    -------------------------
    -- clamp optimization
    -------------------------
    
    -- clamp(const(x), lo, hi) -> const(clamped)
    if op == "clamp" and isConst(optimized.curve) then
        local v = optimized.curve.value
        local lo = optimized.lo or -math.huge
        local hi = optimized.hi or math.huge
        return { op = "const", value = math.max(lo, math.min(hi, v)) }
    end
    
    -------------------------
    -- Motion optimizations
    -------------------------
    
    -- motionScale(motion, 0) -> xy(const(0), const(0))
    if op == "motionScaleConst" and optimized.factor == 0 then
        return { 
            op = "xy", 
            x = { op = "const", value = 0 }, 
            y = { op = "const", value = 0 },
            type = "motion"
        }
    end
    
    -- motionScale(motion, 1) -> motion
    if op == "motionScaleConst" and optimized.factor == 1 then
        return optimized.motion
    end
    
    -- motionScale(motionScale(m, a), b) -> motionScale(m, a * b)
    if op == "motionScaleConst" and optimized.motion.op == "motionScaleConst" then
        return {
            op = "motionScaleConst",
            motion = optimized.motion.motion,
            factor = optimized.motion.factor * optimized.factor,
            type = "motion"
        }
    end
    
    -- motionAdd with single child -> that child
    if op == "motionAdd" and #optimized.children == 1 then
        return optimized.children[1]
    end
    
    return optimized
end

--- Compile with optimization enabled
--- @param ir table IR node
--- @param opts table Options: { optimize = bool, debug = bool, name = string }
--- @return function Compiled function
function Compiler.compileOptimized(ir, opts)
    opts = opts or {}
    local optimizedIR = Compiler.optimize(ir)
    return Compiler.compile(optimizedIR, opts)
end

--------------------------------------------------------------------------------
-- CTX-BASED CURVES (for reactive behaviors)
-- These read from ctx at runtime, enabling dynamic parameters
--------------------------------------------------------------------------------

--- Create a curve that reads from ctx
--- @param key string Key to read from ctx (e.g., "target.x")
--- @param default number Default value if key not found
function Compiler.curve.fromCtx(key, default)
    return { op = "fromCtx", key = key, default = default or 0 }
end

codeGenerators["fromCtx"] = function(node, lines, tVar)
    local value = nextVar()
    lines[#lines + 1] = "local " .. value .. " = ctx"
    for part in node.key:gmatch("[^%.]+") do
        lines[#lines + 1] = string.format(
            "if type(%s) == 'table' or type(%s) == 'cdata' then %s = %s[%q] else %s = nil end",
            value, value, value, value, part, value)
    end
    return string.format("_sig(%s, %s, ctx, %.17g)", value, tVar, node.default)

end

--------------------------------------------------------------------------------
-- CUSTOM NODE REGISTRATION
-- Allow users to add their own IR nodes
--------------------------------------------------------------------------------

Compiler.customNodes = {}

--- Register a custom IR node type
--- @param name string Node operation name
--- @param generator function(node, lines, tVar) -> expression string
function Compiler.registerNode(name, generator)
    Compiler.customNodes[name] = generator
    codeGenerators[name] = generator
end

--- Create a custom node instance
--- @param op string Operation name (must be registered)
--- @param ... any Node parameters
function Compiler.curve.custom(op, ...)
    return { op = op, args = {...} }
end

function Compiler.motion.custom(op, ...)
    return { op = op, args = {...}, type = "motion" }
end

--------------------------------------------------------------------------------
-- ANNOTATED CLOSURES
-- Allows automatic conversion from Spatula closures that have embedded IR.
--
-- Usage (in Spatula library):
--   function Motion.circle(radius, speed)
--       local fn = Motion.xy(Curve.cos(speed, radius), Curve.sin(speed, radius))
--       fn._ir = Compiler.motion.circle(radius, speed)  -- Embed IR
--       return fn
--   end
--
-- Then users can do:
--   local motion = Motion.circle(100, 2)
--   local optimized = Compiler.fromClosure(motion)
--------------------------------------------------------------------------------

--- Check if a value has embedded IR (works with tables or functions with _ir)
--- @param fn function|table The closure or wrapper to check
--- @return boolean hasIR Whether the value has IR attached
function Compiler.hasIR(fn)
    if type(fn) == "table" then
        return fn._ir ~= nil
    end
    return false
end

--- Get the embedded IR from a closure wrapper
--- @param fn function|table The closure wrapper with embedded IR
--- @return table|nil IR node or nil if not available
function Compiler.getIR(fn)
    if type(fn) == "table" then
        return fn._ir
    end
    return nil
end

--- Compile a Spatula closure that has embedded IR
--- @param fn function|table The closure wrapper with embedded IR
--- @param opts table Compilation options
--- @return function Compiled function
function Compiler.fromClosure(fn, opts)
    local ir = Compiler.getIR(fn)
    if not ir then
        error("Closure has no embedded IR. Use Compiler.motion.* or Compiler.curve.* directly, or wrap with Compiler.annotate().")
    end
    return Compiler.compile(ir, opts)
end

--- Compile with optimization from a closure
--- @param fn function|table The closure wrapper with embedded IR
--- @param opts table Compilation options
--- @return function Compiled and optimized function
function Compiler.fromClosureOptimized(fn, opts)
    local ir = Compiler.getIR(fn)
    if not ir then
        error("Closure has no embedded IR. Use Compiler.motion.* or Compiler.curve.* directly, or wrap with Compiler.annotate().")
    end
    return Compiler.compileOptimized(ir, opts)
end

--- Wrap a function and attach IR (creates a callable table)
--- @param fn function The original closure
--- @param ir table The IR representation
--- @return table Callable wrapper with IR attached
function Compiler.annotate(fn, ir)
    local wrapper = {
        _fn = fn,
        _ir = ir,
    }
    setmetatable(wrapper, {
        __call = function(self, ...)
            return self._fn(...)
        end
    })
    return wrapper
end

--- Create an annotated curve factory
--- Returns a function that creates both the closure AND the IR
--- @param name string The operation name
--- @param factory function(params...) -> closure Function that creates the closure
--- @param irFactory function(params...) -> ir Function that creates the IR
--- @return function Annotated factory
function Compiler.createAnnotatedFactory(name, factory, irFactory)
    return function(...)
        local fn = factory(...)
        local ir = irFactory(...)
        local wrapper = Compiler.annotate(fn, ir)
        wrapper._spatulaOp = name
        return wrapper
    end
end

--------------------------------------------------------------------------------
-- BATCH COMPILATION
-- Compile multiple IR nodes efficiently
--------------------------------------------------------------------------------

--- Compile multiple IR nodes, deduplicating common subexpressions across all
--- @param irs table Array of IR nodes
--- @param opts table Compilation options
--- @return table Array of compiled functions
function Compiler.compileBatch(irs, opts)
    local results = {}
    for i, ir in ipairs(irs) do
        results[i] = Compiler.compile(ir, opts)
    end
    return results
end

--------------------------------------------------------------------------------
-- BATCH EVALUATION
-- Process many entities in a single function call.
-- Eliminates per-entity function call overhead.
--------------------------------------------------------------------------------

--- Compile a curve/motion for batch evaluation
--- @param ir table IR node
--- @param opts table Options:
---   preallocate: boolean - Whether to accept pre-allocated output arrays (default false)
---   withPhase: boolean - Whether each entity has a phase offset (default false)
--- @return function Batch function (see below for signatures)
--- @return string Generated source code
---
--- Signatures based on options:
---   Curve basic:        f(ts, n) -> values[]
---   Curve preallocate:  f(ts, n, out) -> out
---   Curve withPhase:    f(ts, phases, n) -> values[]
---   Motion basic:       f(ts, n) -> xs[], ys[]
---   Motion preallocate: f(ts, n, outX, outY) -> outX, outY
---   Motion withPhase:   f(ts, phases, n) -> xs[], ys[]
--- All variants accept an optional final contexts[] argument. Omitted contexts
--- persist within the generated batch function; supplied tables belong to callers.
function Compiler.compileBatchEval(ir, opts)
    opts = opts or {}
    local preallocate = opts.preallocate or false
    local withPhase = opts.withPhase or false
    local needsContext = Compiler.hasStatefulNodes(ir) or Compiler.hasContextNodes(ir)
    
    local isMotion = ir.type == "motion"
    
    -- First compile the single-evaluation version to get the body
    resetVars()
    resetCSE()
    
    local bodyLines = {}
    local tVar = "t"
    
    local resultExpr, resultExprY
    if isMotion then
        resultExpr, resultExprY = emitCurve(ir, bodyLines, tVar)
    else
        resultExpr = emitCurve(ir, bodyLines, tVar)
    end
    
    -- Build the batch function
    local lines = curvePreamble()
    if needsContext then lines[#lines + 1] = "local defaultContexts = {}" end
    lines[#lines + 1] = ""
    
    -- Function signature
    if isMotion then
        if withPhase then
            if preallocate then
                lines[#lines + 1] = "return function(ts, phases, n, outX, outY, contexts)"
            else
                lines[#lines + 1] = "return function(ts, phases, n, contexts)"
                lines[#lines + 1] = "  local outX, outY = {}, {}"
            end
        else
            if preallocate then
                lines[#lines + 1] = "return function(ts, n, outX, outY, contexts)"
            else
                lines[#lines + 1] = "return function(ts, n, contexts)"
                lines[#lines + 1] = "  local outX, outY = {}, {}"
            end
        end
    else
        if withPhase then
            if preallocate then
                lines[#lines + 1] = "return function(ts, phases, n, out, contexts)"
            else
                lines[#lines + 1] = "return function(ts, phases, n, contexts)"
                lines[#lines + 1] = "  local out = {}"
            end
        else
            if preallocate then
                lines[#lines + 1] = "return function(ts, n, out, contexts)"
            else
                lines[#lines + 1] = "return function(ts, n, contexts)"
                lines[#lines + 1] = "  local out = {}"
            end
        end
    end
    
    -- Main loop
    if needsContext then lines[#lines + 1] = "  contexts = contexts or defaultContexts" end
    lines[#lines + 1] = "  for i = 1, n do"
    if needsContext then
        lines[#lines + 1] = "    local ctx = contexts[i]"
        lines[#lines + 1] = "    if ctx == nil then ctx = {}; contexts[i] = ctx end"
    end
    
    if withPhase then
        lines[#lines + 1] = "    local t = ts[i] + phases[i]"
    else
        lines[#lines + 1] = "    local t = ts[i]"
    end
    
    -- Add body computation (indented for loop)
    for _, line in ipairs(bodyLines) do
        lines[#lines + 1] = "    " .. line
    end
    
    -- Store results
    if isMotion then
        lines[#lines + 1] = string.format("    if outX then outX[i] = %s end", resultExpr)
        lines[#lines + 1] = string.format("    if outY then outY[i] = %s end", resultExprY)
    else
        lines[#lines + 1] = string.format("    out[i] = %s", resultExpr)
    end
    
    lines[#lines + 1] = "  end"
    
    -- Return
    if isMotion then
        lines[#lines + 1] = "  return outX, outY"
    else
        lines[#lines + 1] = "  return out"
    end
    
    lines[#lines + 1] = "end"
    
    local source = table.concat(lines, "\n")
    
    local fn, err = load(source, "spatula_batch")
    if not fn then
        error("Batch compilation failed: " .. tostring(err) .. "\n\nSource:\n" .. source)
    end
    
    return fn(), source
end

--- Compile batch evaluation using a shared LUT with phase offsets
--- Ultra-fast: just array indexing in a loop
--- @param ir table IR node
--- @param opts table Options:
---   fps: number - Frames per second (default 60)
---   duration: number - Loop duration in seconds (default 1)
---   preallocate: boolean - Accept pre-allocated output arrays (default false)
--- @return function Batch LUT function f(ts, phases, n, [outX, outY]) -> xs, ys
--- @return string Generated source code
--- @return table Raw LUT data
function Compiler.compileBatchLUT(ir, opts)
    opts = opts or {}
    local fps = opts.fps or 60
    local duration = opts.duration or 1
    local preallocate = opts.preallocate or false
    
    local frameCount = math.floor(fps * duration)
    if frameCount < 1 then frameCount = 1 end
    
    local isMotion = ir.type == "motion"
    
    -- Generate LUT values
    local compiled = Compiler.compile(ir)
    local ctx = {}
    
    local lines = {}
    lines[#lines + 1] = "local floor = math.floor"
    lines[#lines + 1] = ""
    
    -- Embed LUT
    if isMotion then
        local xvals, yvals = {}, {}
        for i = 0, frameCount - 1 do
            local t = i / fps
            local x, y = compiled(t, ctx)
            xvals[#xvals + 1] = string.format("%.10g", x)
            yvals[#yvals + 1] = string.format("%.10g", y)
        end
        lines[#lines + 1] = "local lut_x = { " .. table.concat(xvals, ", ") .. " }"
        lines[#lines + 1] = "local lut_y = { " .. table.concat(yvals, ", ") .. " }"
    else
        local vals = {}
        for i = 0, frameCount - 1 do
            local t = i / fps
            vals[#vals + 1] = string.format("%.10g", compiled(t, ctx))
        end
        lines[#lines + 1] = "local lut = { " .. table.concat(vals, ", ") .. " }"
    end
    
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("local frameCount = %d", frameCount)
    lines[#lines + 1] = string.format("local fps = %d", fps)
    lines[#lines + 1] = ""
    
    -- Batch function
    if isMotion then
        if preallocate then
            lines[#lines + 1] = "return function(ts, phases, n, outX, outY)"
        else
            lines[#lines + 1] = "return function(ts, phases, n)"
            lines[#lines + 1] = "  local outX, outY = {}, {}"
        end
        lines[#lines + 1] = "  for i = 1, n do"
        lines[#lines + 1] = "    local idx = floor((ts[i] + phases[i]) * fps) % frameCount + 1"
        lines[#lines + 1] = "    if outX then outX[i] = lut_x[idx] end"
        lines[#lines + 1] = "    if outY then outY[i] = lut_y[idx] end"
        lines[#lines + 1] = "  end"
        lines[#lines + 1] = "  return outX, outY"
        lines[#lines + 1] = "end"
    else
        if preallocate then
            lines[#lines + 1] = "return function(ts, phases, n, out)"
        else
            lines[#lines + 1] = "return function(ts, phases, n)"
            lines[#lines + 1] = "  local out = {}"
        end
        lines[#lines + 1] = "  for i = 1, n do"
        lines[#lines + 1] = "    local idx = floor((ts[i] + phases[i]) * fps) % frameCount + 1"
        lines[#lines + 1] = "    out[i] = lut[idx]"
        lines[#lines + 1] = "  end"
        lines[#lines + 1] = "  return out"
        lines[#lines + 1] = "end"
    end
    
    local source = table.concat(lines, "\n")
    
    local fn, err = load(source, "spatula_batch_lut")
    if not fn then
        error("Batch LUT compilation failed: " .. tostring(err) .. "\n\nSource:\n" .. source)
    end
    
    -- Build raw LUT data for return
    local lutData = {}
    if isMotion then
        lutData.x = {}
        lutData.y = {}
        for i = 0, frameCount - 1 do
            local t = i / fps
            lutData.x[i + 1], lutData.y[i + 1] = compiled(t, ctx)
        end
    else
        for i = 0, frameCount - 1 do
            local t = i / fps
            lutData[i + 1] = compiled(t, ctx)
        end
    end
    
    return fn(), source, lutData
end

--- Create a batch evaluation context for managing entity arrays
--- @param n number Maximum number of entities
--- @return table Context with pre-allocated arrays
function Compiler.createBatchContext(n)
    return {
        n = n,
        ts = {},        -- Time values
        phases = {},    -- Phase offsets
        outX = {},      -- X output
        outY = {},      -- Y output (for motions)
        out = {},       -- Single output (for curves)
    }
end

--- Helper to initialize phases with random offsets
--- @param phases table Array to fill
--- @param n number Number of entities
--- @param maxPhase number Maximum phase offset (default 1)
function Compiler.randomizePhases(phases, n, maxPhase)
    maxPhase = maxPhase or 1
    for i = 1, n do
        phases[i] = math.random() * maxPhase
    end
end

--- Helper to set all entities to same time
--- @param ts table Array to fill
--- @param n number Number of entities
--- @param t number Time value
function Compiler.fillTimes(ts, n, t)
    for i = 1, n do
        ts[i] = t
    end
end


--------------------------------------------------------------------------------
-- INCREMENTAL/STEPPER COMPILATION
-- Wraps rotator.lua module for backward compatibility
--------------------------------------------------------------------------------

--- Compile a motion/curve to an incremental rotator for fixed timestep
--- @param ir table IR node
--- @param opts table Options: dt, fps
--- @return table|nil Rotator object or nil if not steppable
--- @return string|nil Error message if cannot create rotator
function Compiler.compileRotator(ir, opts)
    local rotator = RotatorModule.compile(ir, opts, Compiler.hasStatefulNodes)
    if not rotator then
        local analysis = RotatorModule.analyze(ir, Compiler.hasStatefulNodes)
        return nil, analysis.reason
    end
    return rotator
end

--- Check if IR can be compiled to a rotator
--- @param ir table IR node
--- @return boolean canStep
--- @return string|nil reason Why not (if canStep is false)
function Compiler.canUseRotator(ir)
    local analysis = RotatorModule.analyze(ir, Compiler.hasStatefulNodes)
    return analysis.canStep, analysis.reason
end

--- Create initial states for batch stepping
--- @param rotator table Rotator object
--- @param n number Number of entities
--- @param phases table|nil Optional phase offsets per entity
--- @return table Array of state objects
function Compiler.createRotatorStates(rotator, n, phases)
    return RotatorModule.createStates(rotator, n, phases)
end


--------------------------------------------------------------------------------
-- LOOKUP TABLE (LUT) COMPILATION
-- Wraps lut.lua module for backward compatibility
--------------------------------------------------------------------------------

--- Compile a curve/motion to a lookup table for fixed-fps evaluation
--- @param ir table IR node
--- @param opts table Options: fps, duration, loop, interpolate
--- @return function Lookup function f(t) -> value or (x, y)
--- @return table The raw LUT data for inspection
function Compiler.compileLUT(ir, opts)
    return LUTModule.compile(ir, Compiler.compile, opts)
end

--- Generate Lua source code for a LUT and compile it
--- @param ir table IR node
--- @param opts table Options: fps, duration
--- @return function Compiled LUT function
--- @return string Lua source code
function Compiler.compileLUTSource(ir, opts)
    local source = LUTModule.toSource(ir, Compiler.compile, opts)
    local fn = load(source)()
    return fn, source
end

--- Estimate LUT memory size in bytes
--- @param ir table IR node
--- @param opts table Options: fps, duration
--- @return number Size in bytes
function Compiler.estimateLUTSize(ir, opts)
    return LUTModule.estimateSize(ir, opts)
end

--- Check if IR safely repeats over a looping LUT's duration.
--- @param ir table IR node
--- @param duration number|nil LUT duration in seconds (default 1)
--- @param fps number|nil When provided, require a whole number of samples
--- @return boolean canUseLUT
--- @return string|nil reason Why not (if false)
function Compiler.canUseLUT(ir, duration, fps)
    if not ir then return false, "Invalid IR" end

    if Compiler.hasStatefulNodes(ir) then
        return false, "Contains stateful nodes"
    end

    if Compiler.hasContextNodes(ir) then
        return false, "Contains ctx-dependent values"
    end

    if fps then
        local frames = fps * (duration or 1)
        if frames < 1 or frames ~= math.floor(frames) then
            return false, "LUT duration must contain a whole number of samples"
        end
    end

    if not Period.repeatsAfter(ir, duration or 1) then
        return false, "Does not provably repeat over the LUT duration"
    end
    
    return true
end

--- Analyze IR for hybrid opportunity (some pure, some stateful children)
--- @param ir table IR node
--- @return boolean canHybrid
--- @return table pureChildren
--- @return table statefulChildren
function Compiler.analyzeHybrid(ir, duration, fps)
    -- Only proven repeating children may be baked. Other pure children (ramps,
    -- noise, context values) must still be evaluated at their actual time.
    if not ir or (ir.op ~= "motionAdd" and ir.op ~= "add") then return false, {}, {} end
    local baked, evaluated = {}, {}
    for index, child in ipairs(ir.children or {}) do
        local group = Compiler.canUseLUT(child, duration, fps) and baked or evaluated
        group[#group + 1] = { idx = index, ir = child }
    end
    return #baked > 0 and #evaluated > 0, baked, evaluated
end

--- Compile a curve/motion to an FFI-backed lookup table (LuaJIT only)
--- Uses FFI float arrays for maximum cache locality and SIMD potential
--- @param ir table IR node
--- @param opts table Options: fps, duration, loop
--- @return function Lookup function f(t) -> value or (x, y)
--- @return table The raw LUT data (FFI arrays if available)
function Compiler.compileLUTFFI(ir, opts)
    return LUTModule.compileFFI(ir, Compiler.compile, opts)
end

--- Compile batch evaluation using FFI LUT with phase offsets (LuaJIT only)
--- Ultra-fast: FFI arrays for input/output, direct indexing
--- @param ir table IR node
--- @param opts table Options:
---   fps: number - Frames per second (default 60)
---   duration: number - Loop duration in seconds (default 1)
--- @return function Batch LUT function f(times, phases, n, outX, outY)
--- @return number frameCount
--- @return table Raw LUT data (with FFI arrays if available)
function Compiler.compileBatchLUTFFI(ir, opts)
    return LUTModule.compileBatchFFI(ir, Compiler.compile, opts)
end

--------------------------------------------------------------------------------
-- INTROSPECTION
-- Tools for analyzing IR
--------------------------------------------------------------------------------

--- Count the number of nodes in an IR tree
--- @param ir table IR node
--- @return number Node count
function Compiler.countNodes(ir)
    if not ir or type(ir) ~= "table" then return 0 end
    
    local count = 1
    
    if ir.curve then count = count + Compiler.countNodes(ir.curve) end
    if ir.a then count = count + Compiler.countNodes(ir.a) end
    if ir.b then count = count + Compiler.countNodes(ir.b) end
    if ir.x then count = count + Compiler.countNodes(ir.x) end
    if ir.y then count = count + Compiler.countNodes(ir.y) end
    if ir.target then count = count + Compiler.countNodes(ir.target) end
    if ir.motion then count = count + Compiler.countNodes(ir.motion) end
    if type(ir.factor) == "table" then count = count + Compiler.countNodes(ir.factor) end
    if type(ir.amount) == "table" then count = count + Compiler.countNodes(ir.amount) end
    if type(ir.exponent) == "table" then count = count + Compiler.countNodes(ir.exponent) end
    
    if ir.children then
        for _, child in ipairs(ir.children) do
            count = count + Compiler.countNodes(child)
        end
    end
    
    return count
end

--- Check if an IR tree contains any stateful nodes
--- @param ir table IR node
--- @return boolean hasState
function Compiler.hasStatefulNodes(ir)
    if not ir or type(ir) ~= "table" then return false end

    if ir.op == "follow" or ir.op == "spring" then
        return true
    end

    -- Inspect every operand, including rotation angles and exponents.
    for _, child in pairs(ir) do
        if type(child) == "table" and Compiler.hasStatefulNodes(child) then return true end
    end

    return false
end

--- Whether evaluation reads dynamic context values.
function Compiler.hasContextNodes(ir)
    if type(ir) ~= "table" then return false end
    if ir.op == "fromCtx" then return true end
    for _, child in pairs(ir) do
        if type(child) == "table" and Compiler.hasContextNodes(child) then return true end
    end
    return false
end

--- Conservatively identify pure repeating compositions; this does not imply
--- that they fit a specific LUT duration. canUseLUT checks that separately.
function Compiler.isPeriodic(ir)
    return Period.isPeriodic(ir)
end

--- Analyze IR for hybrid rotate/scale opportunity
--- Returns info if inner motion is periodic but outer curve is non-periodic
--- @param ir table IR node
--- @return boolean canHybrid
--- @return table|nil info { innerMotion, outerCurve, operation }
function Compiler.analyzeRotateScaleHybrid(ir, duration, fps)
    if not ir then return false, nil end

    -- Check for motionRotateCurve or motionScaleCurve
    local innerMotion, outerCurve, operation
    if ir.op == "motionRotateCurve" then
        innerMotion = ir.motion
        outerCurve = ir.angle
        operation = "rotate"
    elseif ir.op == "motionScaleCurve" then
        innerMotion = ir.motion
        outerCurve = ir.factor
        operation = "scale"
    else
        return false, nil
    end

    -- Check if inner motion is periodic (can LUT)
    local innerPeriodic = Compiler.canUseLUT(innerMotion, duration, fps)
    local innerStateful = Compiler.hasStatefulNodes(innerMotion)

    -- Check if outer curve is non-periodic (needs runtime eval)
    local outerPeriodic = Compiler.isPeriodic(outerCurve)
    local outerStateful = Compiler.hasStatefulNodes(outerCurve)

    -- Hybrid is beneficial if:
    -- - Inner is periodic and not stateful (can LUT)
    -- - Outer is non-periodic and stateless (stateful outers need persistent ctx)
    local canHybrid = innerPeriodic and not innerStateful and not outerStateful and not outerPeriodic

    if canHybrid then
        return true, {
            innerMotion = innerMotion,
            outerCurve = outerCurve,
            operation = operation,
        }
    end

    return false, nil
end

--- Get a summary of an IR tree
--- @param ir table IR node
--- @return table Summary { nodeCount, hasState, ops }
function Compiler.summarize(ir)
    local ops = {}
    
    local function collectOps(node)
        if not node or type(node) ~= "table" then return end
        if node.op then
            ops[node.op] = (ops[node.op] or 0) + 1
        end
        
        if node.curve then collectOps(node.curve) end
        if node.a then collectOps(node.a) end
        if node.b then collectOps(node.b) end
        if node.x then collectOps(node.x) end
        if node.y then collectOps(node.y) end
        if node.target then collectOps(node.target) end
        if node.motion then collectOps(node.motion) end
        if node.timeCurve then collectOps(node.timeCurve) end
        if type(node.factor) == "table" then collectOps(node.factor) end
        if type(node.amount) == "table" then collectOps(node.amount) end
        if type(node.offset) == "table" then collectOps(node.offset) end
        
        if node.children then
            for _, child in ipairs(node.children) do
                collectOps(child)
            end
        end
    end
    
    collectOps(ir)
    
    return {
        nodeCount = Compiler.countNodes(ir),
        hasState = Compiler.hasStatefulNodes(ir),
        ops = ops
    }
end

--------------------------------------------------------------------------------
-- TRANSPARENT POOL API
-- Wraps pool.lua module for backward compatibility
--------------------------------------------------------------------------------

--- Create a motion/curve pool that auto-selects the best evaluation strategy
--- @param ir table IR node
--- @param opts table Options: count, fps, dt, duration
--- @return table Pool object with simple API
function Compiler.createPool(ir, opts)
    return PoolModule.create(Compiler, ir, opts)
end

--- Single entity optimizer
--- @param ir table IR node
--- @param opts table Options
--- @return function Compiled evaluation function
function Compiler.auto(ir, opts)
    return Compiler.compileOptimized(ir, opts)
end

--- Create pool and init with random phases
--- @param ir table IR node
--- @param count number Number of entities
--- @param opts table Pool options
--- @return table Initialized pool
function Compiler.createPoolRandom(ir, count, opts)
    opts = opts or {}
    opts.count = count
    return Compiler.createPool(ir, opts):initRandom()
end

--------------------------------------------------------------------------------
-- FORM AND TRIGGER POOLS
--------------------------------------------------------------------------------

--- Create a form pool for batch containment testing
--- @param formIR table Form IR node
--- @param opts table Options: { count = max entities }
--- @return table FormPool object
function Compiler.createFormPool(formIR, opts)
    return FormPoolModule.create(Compiler, formIR, opts)
end

--- Create a trigger pool for multiple instances sharing the same pattern
--- @param timingIR table Timing IR node (interval, times, burst)
--- @param selectionIR table Selection IR node (selectAll, selectRandom, etc)
--- @param opts table Options: { count = number of instances }
--- @return table TriggerPool object
function Compiler.createTriggerPool(timingIR, selectionIR, opts)
    return TriggerPoolModule.create(Compiler, timingIR, selectionIR, opts)
end

--- Create a distribution pool for efficient point generation
--- @param distIR table Distribution IR node
--- @param opts table Options: { maxPoints = max points to generate }
--- @return table DistributionPool object
function Compiler.createDistributionPool(distIR, opts)
    return DistributionPoolModule.create(Compiler, distIR, opts)
end

--- Get LUT cache statistics (if cache is enabled)
--- @return table|nil Stats or nil if cache not available
function Compiler.lutCacheStats()
    local ok, LUTCache = pcall(require, "lutcache")
    if ok then
        return LUTCache.stats()
    end
    return nil
end

--- Clear LUT cache
function Compiler.clearLutCache()
    local ok, LUTCache = pcall(require, "lutcache")
    if ok then
        LUTCache.clear()
    end
end

return Compiler
