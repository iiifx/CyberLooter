-- Test entry point. Run from the repository root: tests/run.sh
--
-- Cyber Engine Tweaks replaces require() with one that takes a path relative to
-- the mod folder, extension and all ("Modules/Scanner.lua"). Standard Lua turns
-- the dots in a module name into slashes, so that form cannot work here without
-- the same substitution. Rather than change the mod to suit the tests, the tests
-- provide the require() the mod is written against.

local cache = {}
local stock = require

local function cetRequire(name)
    if cache[name] ~= nil then
        return cache[name]
    end

    if type(name) ~= "string" or not name:match("%.lua$") then
        return stock(name)
    end

    local chunk = assert(loadfile(name))
    local result = chunk()

    -- A module returning nothing is still a module that has been loaded.
    if result == nil then
        result = true
    end

    cache[name] = result
    return result
end

_G.require = cetRequire

-- Modules keep session state, so specs ask for their own copy.
_G.freshRequire = function(name)
    cache[name] = nil
    return cetRequire(name)
end

local Framework = require("tests/support/framework.lua")
Framework.install(_G)

local SPECS = {
    "tests/spec/log_spec.lua",
    "tests/spec/state_spec.lua",
    "tests/spec/input_spec.lua",
    "tests/spec/scanner_spec.lua",
    "tests/spec/looter_spec.lua",
    "tests/spec/audit_spec.lua",
}

for _, spec in ipairs(SPECS) do
    freshRequire(spec)
end

os.exit(Framework.report() and 0 or 1)
