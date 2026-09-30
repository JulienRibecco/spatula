--- Spatula Distribution Optimizations
--- @module spatula.opt.distribution
---
--- Performance utilities for Distribution:
--- - Reusable point helper
--- - Batch containment integration

local M = {}

-- Reusable point table to avoid allocations in contains() calls
local _pt = {0, 0}
function M.pt(x, y)
    _pt[1], _pt[2] = x, y
    return _pt
end

--------------------------------------------------------------------------------
-- INIT
--------------------------------------------------------------------------------

function M._init(Distribution, Opt)
    -- Expose pt helper for external use
    Distribution.pt = M.pt
end

return M
