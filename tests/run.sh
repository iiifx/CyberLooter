#!/bin/sh
# Syntax-check every file the game will load, then run the specs.
#
# The syntax pass matters as much as the specs do: the mod is written on Linux
# and run on Windows, so a file that does not parse is only discovered after a
# copy, a game launch and a lost evening. LuaJIT is used because that is what
# Cyber Engine Tweaks embeds; any Lua 5.1-compatible interpreter will do.
#
#   tests/run.sh              # uses luajit from PATH
#   LUA=/path/to/luajit tests/run.sh

set -e

cd "$(dirname "$0")/.."

LUA="${LUA:-luajit}"

if ! command -v "$LUA" >/dev/null 2>&1; then
    echo "No Lua interpreter found (looked for '$LUA')."
    echo "Install LuaJIT - the interpreter Cyber Engine Tweaks itself embeds:"
    echo "    sudo apt install luajit"
    echo "or point the runner at one you already have:"
    echo "    LUA=/path/to/luajit tests/run.sh"
    exit 127
fi

echo "Interpreter: $("$LUA" -v 2>&1 | head -n 1)"

echo "Checking syntax..."
for file in init.lua Modules/*.lua tests/run.lua tests/support/*.lua tests/spec/*.lua; do
    "$LUA" -e "assert(loadfile('$file'))"
done
echo "All files parse."

echo "Running specs..."
exec "$LUA" tests/run.lua
