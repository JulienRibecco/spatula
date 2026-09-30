dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "bootstrap.lua")
local T = require("spatula.tests.support")
local JSON = require("spatula.json")
local IR = require("spatula.compiler.ir")
local Live = require("spatula.editor.live")

T.test("JSON round-trips escaped keys, controls, Unicode, and full precision", function()
    local key = 'say"hello\\world'
    local text = '\0\1\b\f\n\r\t"\\/ café 🍳'
    local object = {[key] = text, value = 1.2345678901234567}
    for _, codec in ipairs({{JSON.encode, JSON.decode}, {IR.toJSON, IR.fromJSON}, {Live.toJSON, Live.fromJSON}}) do
        local result = codec[2](codec[1](object))
        assert(result[key] == text)
        assert(result.value == object.value)
    end
    assert(JSON.decode('"\\u00e9\\ud83c\\udf73"') == 'é🍳')
    if math.type then
        local integer = 9007199254740993
        assert(JSON.decode(JSON.encode(integer)) == integer)
    end
end)

T.test("JSON preserves null array slots and empty container types", function()
    local value = JSON.decode('[null,false,{},[]]')
    assert(#value == 4 and value[1] == JSON.null and value[2] == false)
    assert(JSON.encode(value) == '[null,false,{},[]]')
    assert(JSON.decode('null') == JSON.null)
    assert(JSON.encode(0/0) == 'null')
end)

T.test("JSON rejects malformed input instead of accepting partial data or hanging", function()
    for _, source in ipairs({'', '[bad]', '[1,]', '{"x":1,}', '{"x" 1}', '[1 2]', 'true false',
        '01', '+1', '1.', '1e', '--1', '1e999', '"\\q"', '"\\uZZZZ"', '"\\ud800"', '"\\udc00"', '"line\nbreak"'}) do
        assert(not pcall(JSON.decode, source), 'accepted ' .. source)
    end
    local cycle = {}; cycle.self = cycle
    assert(not pcall(JSON.encode, cycle))
end)

T.finish()
