-- A test framework small enough to read in one sitting.
--
-- There is no package manager in play here and no reason to introduce one: the
-- specs need suites, assertions and an exit code, and nothing else.

local Framework = {}

local _suite = "?"
local _passed = 0
local _failures = {}

function Framework.describe(name, fn)
    local previous = _suite
    _suite = name
    fn()
    _suite = previous
end

function Framework.it(name, fn)
    local ok, err = pcall(fn)

    if ok then
        _passed = _passed + 1
        return
    end

    _failures[#_failures + 1] = { suite = _suite, name = name, err = tostring(err) }
end

-- Assertions -----------------------------------------------------------------

local function fail(message)
    -- level 3: report the line in the spec, not the line in here.
    error(message, 3)
end

local function describeValue(value)
    if type(value) == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end

function Framework.eq(actual, expected, context)
    if actual ~= expected then
        fail(string.format("%sexpected %s, got %s",
            context and (context .. ": ") or "",
            describeValue(expected), describeValue(actual)))
    end
end

function Framework.isTrue(value, context)
    if value ~= true then
        fail(string.format("%sexpected true, got %s",
            context and (context .. ": ") or "", describeValue(value)))
    end
end

function Framework.isFalse(value, context)
    if value ~= false then
        fail(string.format("%sexpected false, got %s",
            context and (context .. ": ") or "", describeValue(value)))
    end
end

function Framework.isNil(value, context)
    if value ~= nil then
        fail(string.format("%sexpected nil, got %s",
            context and (context .. ": ") or "", describeValue(value)))
    end
end

function Framework.notNil(value, context)
    if value == nil then
        fail(string.format("%sexpected a value, got nil", context and (context .. ": ") or ""))
    end
end

-- Substring rather than pattern: log messages contain punctuation that would
-- otherwise have to be escaped at every call site.
function Framework.contains(haystack, needle, context)
    if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
        fail(string.format("%sexpected %s to contain %s",
            context and (context .. ": ") or "",
            describeValue(haystack), describeValue(needle)))
    end
end

-- Reporting ------------------------------------------------------------------

function Framework.report()
    print("")

    for _, failure in ipairs(_failures) do
        print(string.format("FAIL  %s", failure.suite))
        print(string.format("      %s", failure.name))
        print(string.format("      %s", failure.err))
        print("")
    end

    print(string.format("%d passed, %d failed", _passed, #_failures))

    return #_failures == 0
end

-- Exported as globals so the specs read as prose.
function Framework.install(target)
    target.describe = Framework.describe
    target.it = Framework.it
    target.eq = Framework.eq
    target.isTrue = Framework.isTrue
    target.isFalse = Framework.isFalse
    target.isNil = Framework.isNil
    target.notNil = Framework.notNil
    target.contains = Framework.contains
end

return Framework
