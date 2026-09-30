--------------------------------------------------------------------------------
-- SPATULA TRIGGER POOL MODULE
-- Multi-instance trigger management with independent contexts
--------------------------------------------------------------------------------

local TriggerPool = {}

--- Create a trigger pool for multiple instances sharing the same pattern
--- @param Compiler table The Compiler module
--- @param timingIR table Timing IR node (interval, times, burst)
--- @param selectionIR table Selection IR node (selectAll, selectRandom, etc)
--- @param opts table Options:
---   count: number - Number of trigger instances (default 1)
--- @return table Pool object with multi-instance API
function TriggerPool.create(Compiler, timingIR, selectionIR, opts)
    opts = opts or {}
    local count = opts.count or 1

    -- Compile the trigger once
    local triggerFn = Compiler.compileTrigger(timingIR, selectionIR)

    local pool = {
        count = count,
        trigger = triggerFn,
        contexts = {},  -- per-instance contexts
    }

    -- Initialize contexts for each instance
    for i = 1, count do
        pool.contexts[i] = {}
    end

    --- Update a single trigger instance
    --- @param idx number Trigger instance index (1-based)
    --- @param points table Points array
    --- @param t number Current time
    --- @param action function Action callback(x, y, ctx, pointIdx, totalPoints)
    function pool:update(idx, points, t, action)
        self.trigger(points, t, self.contexts[idx], action)
    end

    --- Update all trigger instances with shared points
    --- @param points table Points array (shared by all instances)
    --- @param t number Current time
    --- @param action function Action callback(x, y, ctx, instanceIdx, pointIdx, totalPoints)
    function pool:updateAll(points, t, action)
        local trigger = self.trigger
        local contexts = self.contexts
        for i = 1, self.count do
            trigger(points, t, contexts[i], function(x, y, ctx, pointIdx, total)
                action(x, y, ctx, i, pointIdx, total)
            end)
        end
    end

    --- Update all trigger instances with per-instance points
    --- @param pointsArray table Array of points arrays (one per instance)
    --- @param t number Current time
    --- @param action function Action callback(x, y, ctx, instanceIdx, pointIdx, totalPoints)
    function pool:updateEach(pointsArray, t, action)
        local trigger = self.trigger
        local contexts = self.contexts
        for i = 1, self.count do
            trigger(pointsArray[i], t, contexts[i], function(x, y, ctx, pointIdx, total)
                action(x, y, ctx, i, pointIdx, total)
            end)
        end
    end

    --- Reset a trigger instance's timing state
    --- @param idx number Instance index to reset
    function pool:reset(idx)
        self.contexts[idx] = {}
    end

    --- Reset all trigger instances
    function pool:resetAll()
        for i = 1, self.count do
            self.contexts[i] = {}
        end
    end

    --- Get context for a trigger instance
    --- @param idx number Instance index
    --- @return table Context table
    function pool:getContext(idx)
        return self.contexts[idx]
    end

    --- Resize the pool (add or remove instances)
    --- @param newCount number New instance count
    function pool:resize(newCount)
        if newCount > self.count then
            -- Add new contexts
            for i = self.count + 1, newCount do
                self.contexts[i] = {}
            end
        elseif newCount < self.count then
            -- Remove excess contexts
            for i = newCount + 1, self.count do
                self.contexts[i] = nil
            end
        end
        self.count = newCount
    end

    return pool
end

return TriggerPool
