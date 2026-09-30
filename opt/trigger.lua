--- Spatula Trigger Optimizations
--- @module spatula.opt.trigger
---
--- Performance utilities for Trigger:
--- - Context pooling for reduced GC
--- - Index array pooling for Fisher-Yates
--- - Preallocated batch results

local M = {}

-- Context pooling
local contextPool = {}

function M.getContext()
    local ctx = table.remove(contextPool)
    return ctx or {}
end

function M.releaseContext(ctx)
    contextPool[#contextPool + 1] = ctx
end

-- Index array pooling for random selection
local indexPool = {}

function M.getIndexArray()
    return table.remove(indexPool) or {}
end

function M.releaseIndexArray(arr)
    indexPool[#indexPool + 1] = arr
end

--------------------------------------------------------------------------------
-- INIT
--------------------------------------------------------------------------------

function M._init(Trigger, Opt)
    -- Expose pooling utilities
    Trigger.getContext = M.getContext
    Trigger.releaseContext = M.releaseContext
    Trigger._indexPool = indexPool
end

return M
