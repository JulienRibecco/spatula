--- Spatula Optimization Module
--- @module spatula.opt
---
--- Auto-loads and applies performance optimizations to Spatula modules.
--- Detects FFI availability and loads native extensions when possible.
---
--- Usage: Automatically loaded by main modules. No user action needed.
---
--- Manual usage:
---   local Opt = require("opt")
---   Opt.patchPoint(Point)    -- Add XY/Into/Batch variants
---   Opt.patchForms(Forms)    -- Add SpatialHash, containsBatch, native
---   Opt.patchField(Field)    -- Add native batch sampling
---   Opt.patchTrigger(Trigger) -- Add pooling

local Opt = {
    _VERSION = "1.0.0",
    hasFFI = false,
    hasNative = false,
}

-- Detect FFI availability (LuaJIT)
local ffi_ok, ffi = pcall(require, "ffi")
Opt.hasFFI = ffi_ok
Opt.ffi = ffi_ok and ffi or nil

-- Load declarations and the library together; never expose an undeclared handle.
if ffi_ok then
    local ok, lib = pcall(require, "spatula.compiler.native.field_ffi")
    if ok then
        Opt.hasNative = true
        Opt.native = lib
    end
end

--------------------------------------------------------------------------------
-- PATCH FUNCTIONS
-- Each function adds optimizations to a module.
--------------------------------------------------------------------------------

function Opt.patchPoint(Point)
    local ok, pointOpt = pcall(require, "opt.point")
    if ok then
        for k, v in pairs(pointOpt) do
            if k ~= "_init" then
                Point[k] = v
            end
        end
        if pointOpt._init then
            pointOpt._init(Point, Opt)
        end
    end
    return ok
end

function Opt.patchForms(Forms)
    local ok, formsOpt = pcall(require, "opt.forms")
    if ok then
        for k, v in pairs(formsOpt) do
            if k ~= "_init" then
                Forms[k] = v
            end
        end
        if formsOpt._init then
            formsOpt._init(Forms, Opt)
        end
    end
    return ok
end

function Opt.patchField(Field)
    local ok, fieldOpt = pcall(require, "opt.field")
    if ok and fieldOpt._init then
        fieldOpt._init(Field, Opt)
    end
    return ok
end

function Opt.patchTrigger(Trigger)
    local ok, triggerOpt = pcall(require, "opt.trigger")
    if ok and triggerOpt._init then
        triggerOpt._init(Trigger, Opt)
    end
    return ok
end

function Opt.patchDistribution(Distribution)
    local ok, distOpt = pcall(require, "opt.distribution")
    if ok and distOpt._init then
        distOpt._init(Distribution, Opt)
    end
    return ok
end

--------------------------------------------------------------------------------
-- STATUS
--------------------------------------------------------------------------------

function Opt.status()
    return {
        ffi = Opt.hasFFI,
        native = Opt.hasNative,
        point = pcall(require, "opt.point"),
        forms = pcall(require, "opt.forms"),
        field = pcall(require, "opt.field"),
        trigger = pcall(require, "opt.trigger"),
    }
end

return Opt
