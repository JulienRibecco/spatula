-- Test-only module discovery; independent of checkout name and working directory.
local source = debug.getinfo(1, "S").source:sub(2)
local root = (source:match("^(.*[/\\])") or "./") .. "../"
package.path = root .. "?.lua;" .. root .. "?/init.lua;"
    .. root .. "compiler/?.lua;" .. root .. "compiler/?/init.lua;" .. package.path

local searchers = package.searchers or package.loaders
if not package.loaded["spatula.test_bootstrap"] then
    table.insert(searchers, 2, function(name)
        local relative
        if name == "spatula" then relative = "init"
        elseif name:sub(1, 8) == "spatula." then relative = name:sub(9):gsub("%.", "/")
        else return nil end
        for _, suffix in ipairs({".lua", "/init.lua"}) do
            local path = root .. relative .. suffix
            local file = io.open(path, "r")
            if file then
                file:close()
                return assert(loadfile(path))
            end
        end
        return "\n\tno test module '" .. name .. "' under " .. root
    end)
    package.loaded["spatula.test_bootstrap"] = true
end
return root
