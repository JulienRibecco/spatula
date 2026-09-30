--------------------------------------------------------------------------------
-- SPATULA DISTRIBUTION POOL MODULE
-- Pre-allocated arrays for point generation with array reuse
--------------------------------------------------------------------------------

local DistributionPool = {}

--- Create a distribution pool for efficient point generation
--- @param Compiler table The Compiler module
--- @param distIR table Distribution IR node
--- @param opts table Options:
---   maxPoints: number - Max points to generate (default 1000)
--- @return table Pool object with generation API
function DistributionPool.create(Compiler, distIR, opts)
    opts = opts or {}
    local maxPoints = opts.maxPoints or 1000

    -- Compile the distribution once
    local generateFn = Compiler.compileDistribution(distIR)

    local pool = {
        maxPoints = maxPoints,
        x = {},
        y = {},
        count = 0,
        _generateFn = generateFn,
    }

    -- Pre-allocate arrays
    for i = 1, maxPoints do
        pool.x[i] = 0
        pool.y[i] = 0
    end

    --- Generate points at the given origin and size
    --- @param ox number Origin X
    --- @param oy number Origin Y
    --- @param size number Size/radius
    --- @return number Count of points generated
    function pool:generate(ox, oy, size)
        self.count = self._generateFn(ox, oy, size, self.x, self.y)
        return self.count
    end

    --- Get point count from last generation
    --- @return number
    function pool:getCount()
        return self.count
    end

    --- Iterator over generated points
    --- @return function Iterator yielding (x, y) pairs
    function pool:points()
        local i = 0
        local n = self.count
        local xs, ys = self.x, self.y
        return function()
            i = i + 1
            if i <= n then
                return xs[i], ys[i]
            end
        end
    end

    --- Iterator with index over generated points
    --- @return function Iterator yielding (index, x, y) tuples
    function pool:ipairs()
        local i = 0
        local n = self.count
        local xs, ys = self.x, self.y
        return function()
            i = i + 1
            if i <= n then
                return i, xs[i], ys[i]
            end
        end
    end

    --- Get point at index
    --- @param idx number Point index (1-based)
    --- @return number, number x, y coordinates
    function pool:get(idx)
        return self.x[idx], self.y[idx]
    end

    --- Apply a function to each point
    --- @param fn function Callback(x, y, index)
    function pool:forEach(fn)
        local xs, ys = self.x, self.y
        for i = 1, self.count do
            fn(xs[i], ys[i], i)
        end
    end

    --- Resize the pool's max capacity
    --- @param newMaxPoints number New maximum point count
    function pool:resize(newMaxPoints)
        if newMaxPoints > self.maxPoints then
            -- Expand arrays
            for i = self.maxPoints + 1, newMaxPoints do
                self.x[i] = 0
                self.y[i] = 0
            end
        elseif newMaxPoints < self.maxPoints then
            -- Shrink arrays
            for i = newMaxPoints + 1, self.maxPoints do
                self.x[i] = nil
                self.y[i] = nil
            end
        end
        self.maxPoints = newMaxPoints
    end

    --- Clear the pool (reset count, keeps arrays allocated)
    function pool:clear()
        self.count = 0
    end

    return pool
end

return DistributionPool
