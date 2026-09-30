dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "bootstrap.lua")
-- Exercise the distributed core independently of optional native patches.
package.preload.opt = function() return {} end
local T = require("spatula.tests.support")
local S = require("spatula")
local function near(a, b)
    assert(math.abs(a - b) < 1e-8, tostring(a) .. " != " .. tostring(b))
end

T.test("distribution motions receive context without sharing implicit state", function()
    local form = S.Forms.circle(0, 0, 1)
    local motion = function(t, ctx)
        ctx.calls = (ctx.calls or 0) + 1
        return ctx.x or 0.25, 0
    end
    local sample = S.Distribution.sample(motion, 1)
    local ctx = {x = 0.5}
    sample(form, function(x) near(x, 0.5 * 0.999999) end, ctx)
    assert(ctx.calls == 1)
    for _ = 1, 2 do
        S.Distribution.sample(function(t, c)
            assert(c.calls == nil)
            c.calls = true
            return 0, 0
        end, 1)(form, function() end)
    end
end)

T.test("field combinators preserve both context signatures and gradients", function()
    local a, b = S.Field.new(), S.Field.new({base = 2})
    a:add({0, 0}, {radius = 10, value = S.S("strength", 1)})
    local cases = {
        {S.Field.combine(a, b), 7}, {S.Field.sub(a, b), 3},
        {S.Field.mul(a, b), 10}, {S.Field.max(a, b), 5}, {S.Field.min(a, b), 2},
        {S.Field.invert(a), -4}, {S.Field.scale(a, 2), 10}, {S.Field.clamp(a, 0, 4), 4},
        {S.Field.resolution(a, {spatial = 2}), 5},
    }
    local ctx = {strength = 5}
    for _, case in ipairs(cases) do
        local field, expected = case[1], case[2]
        near(field:sample(0, 0, ctx), expected)
        near(field:sample({0, 0}, ctx), expected)
        local gx, gy = field:gradient({0, 0}, ctx)
        near(gx, (field:sample(2, 0, ctx) - expected) / 2)
        near(gy, (field:sample(0, 2, ctx) - expected) / 2)
    end
end)

T.test("spatial index builds lazily and rebuilds after source changes", function()
    local field = S.Field.new()
    local source = field:add({0, 0}, {radius = 10})
    field:enableSpatialIndex()
    near(field:sample(0, 0), 1)
    assert(field._quadtree, "index should have been built")
    field:move(source, {30, 0})
    near(field:sample(0, 0), 0)
    near(field:sample(30, 0), 1)
    field:remove(source)
    near(field:sample(30, 0), 0)
    field:add({S.S("x", 0), 0}, {radius = S.S("radius", 10)})
    for _, x in ipairs({0, 30, -20}) do
        near(field:sample(x, 0, {x = x}), 1)
        near(field:sample(x + 20, 0, {x = x}), 0)
    end
end)

T.test("spatial and ordinary trackers agree across the hysteresis boundary", function()
    local entity = {id = "one", x = 0, y = 0}
    local form = S.Forms.circle(0, 0, 10)
    local exits = {0, 0}
    local ordinary = S.Forms.track(form, {exitMargin = 5, onExit = function() exits[1] = exits[1] + 1 end})
    local spatial = S.Forms.track(form, {exitMargin = 5, onExit = function() exits[2] = exits[2] + 1 end,
        queryFn = function(x1, y1, x2, y2)
            if entity.x >= x1 and entity.x <= x2 and entity.y >= y1 and entity.y <= y2 then return {entity} end
            return {}
        end})
    for _, x in ipairs({0, 12, 14, 16, 0}) do
        entity.x = x
        S.Forms.updateTracker(ordinary, {entity}, 0.1)
        S.Forms.updateTracker(spatial, 0.1)
        assert((ordinary.inside.one ~= nil) == (spatial.inside.one ~= nil))
        assert(exits[1] == exits[2])
    end
    assert(exits[1] == 1)
end)

local function sound(count, value)
    return {getSampleRate = function() return 44100 end,
        getSampleCount = function() return count end, getChannelCount = function() return 1 end,
        getSample = function(_, i) assert(i >= 0 and i < count); return value end}
end

T.test("audio includes complete windows and keeps silence finite", function()
    for _, count in ipairs({1023, 1024, 1536, 2048}) do
        local expected = math.max(0, math.floor((count - 1024) / 512) + 1)
        local frames = S.Audio.analyze(sound(count, 0.5), {windowSize = 1024, hopSize = 512})
        assert(#frames == expected)
    end
    local bands = S.Audio.bands(sound(4096, 0))
    for _, frames in pairs(bands) do
        for _, frame in ipairs(frames) do near(frame[2], 0) end
    end
end)

T.finish()
