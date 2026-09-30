--------------------------------------------------------------------------------
-- SPATULA FORM POOL MODULE
-- Batch containment testing with pre-allocated arrays
--------------------------------------------------------------------------------

local FormPool = {}

--- Create a form pool for batch containment testing
--- @param Compiler table The Compiler module
--- @param formIR table Form IR node
--- @param opts table Options:
---   count: number - Max entities to check (default 100)
--- @return table Pool object with batch API
function FormPool.create(Compiler, formIR, opts)
    opts = opts or {}
    local count = opts.count or 100

    -- Compile the form once
    local containsFn = Compiler.compileForm(formIR)

    local pool = {
        count = count,
        _containsFn = containsFn,
        results = {},  -- indices of entities inside
        _resultCount = 0,
    }

    --- Single containment check
    --- @param x number X coordinate
    --- @param y number Y coordinate
    --- @return boolean True if inside
    function pool:contains(x, y)
        return self._containsFn(x, y)
    end

    -- Pre-allocate results array
    for i = 1, count do
        pool.results[i] = 0
    end

    --- Batch containment check
    --- Returns count of entities inside, fills pool.results with their indices
    --- @param xs table X coordinates array
    --- @param ys table Y coordinates array
    --- @param n number Number of entities to check
    --- @return number Count of entities inside
    function pool:containsBatch(xs, ys, n)
        local contains = self._containsFn
        local results = self.results
        local resultCount = 0

        for i = 1, n do
            if contains(xs[i], ys[i]) then
                resultCount = resultCount + 1
                results[resultCount] = i
            end
        end

        self._resultCount = resultCount
        return resultCount
    end

    --- Batch containment check returning boolean array
    --- @param xs table X coordinates array
    --- @param ys table Y coordinates array
    --- @param n number Number of entities to check
    --- @param outResults table Pre-allocated boolean array (optional)
    --- @return table Boolean array (true = inside)
    function pool:containsBatchBool(xs, ys, n, outResults)
        local contains = self._containsFn
        local results = outResults or {}

        for i = 1, n do
            results[i] = contains(xs[i], ys[i])
        end

        return results
    end

    --- Get count of entities inside from last containsBatch call
    --- @return number
    function pool:getResultCount()
        return self._resultCount
    end

    --- Iterator over entities inside from last containsBatch call
    --- @return function Iterator yielding entity indices
    function pool:insideIter()
        local i = 0
        local n = self._resultCount
        local results = self.results
        return function()
            i = i + 1
            if i <= n then
                return results[i]
            end
        end
    end

    return pool
end

return FormPool
