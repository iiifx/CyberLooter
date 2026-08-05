-- Settings storage and the CET overlay window.

local Config = {}

local CONFIG_FILE = "config.json"

local Log

local DEFAULTS = {
    -- Sweep behaviour
    radius = 5.0,
    holdTime = 0.35,
    skipQuestItems = true,
    respectInteraction = true,
    maxObjectsPerSweep = 24,

    -- Native input hint
    showIndicator = true,
    hintShowKeyName = false,
    hintLabel = "Loot All",
    hintRefreshHack = false,

    -- ImGui fallback indicator
    useImGuiFallback = false,
    indicatorOffsetX = 0.0,
    indicatorOffsetY = 60.0,

    -- Diagnostics
    debugLog = false,
}

Config.values = {}
Config.isOverlayOpen = false
Config.cleanupArmed = false

local _dirty = false

local function resetToDefaults()
    for key, value in pairs(DEFAULTS) do
        Config.values[key] = value
    end
end

function Config.Init(deps)
    Log = deps.Log

    resetToDefaults()
    Config.Load()
    Log.SetEnabled(Config.values.debugLog)

    registerForEvent("onOverlayOpen", function()
        Config.isOverlayOpen = true
    end)

    registerForEvent("onOverlayClose", function()
        Config.isOverlayOpen = false
        if _dirty then
            Config.Save()
            _dirty = false
        end
    end)
end

-- Called on shutdown as well: closing the game with the overlay still open
-- would otherwise discard whatever was just changed.
function Config.SaveIfDirty()
    if _dirty then
        Config.Save()
        _dirty = false
    end
end

function Config.Load()
    local opened, file = pcall(io.open, CONFIG_FILE, "r")
    if not opened or file == nil then
        return
    end

    local contents = file:read("*a")
    file:close()

    local ok, decoded = pcall(json.decode, contents)
    if not ok or type(decoded) ~= "table" then
        Log.Warn("config.json is unreadable, falling back to defaults")
        return
    end

    -- Only accept keys we know about, with the type the default declares.
    for key, defaultValue in pairs(DEFAULTS) do
        local value = decoded[key]
        if value ~= nil and type(value) == type(defaultValue) then
            Config.values[key] = value
        end
    end
end

function Config.Save()
    local opened, file = pcall(io.open, CONFIG_FILE, "w")
    if not opened or file == nil then
        Log.Warn("cannot write config.json")
        return
    end

    local encoded, payload = pcall(json.encode, Config.values)
    if encoded and payload ~= nil then
        file:write(payload)
    else
        Log.Warn("cannot encode settings: " .. tostring(payload))
    end

    file:close()
end

local function checkbox(label, key)
    local value, toggled = ImGui.Checkbox(label, Config.values[key])
    if toggled then
        Config.values[key] = value
        _dirty = true
        return true
    end
    return false
end

local function sliderFloat(label, key, min, max, format)
    local value, used = ImGui.SliderFloat(label, Config.values[key], min, max, format)
    if used then
        Config.values[key] = value
        _dirty = true
    end
end

local function sliderInt(label, key, min, max)
    local value, used = ImGui.SliderInt(label, Config.values[key], min, max)
    if used then
        Config.values[key] = value
        _dirty = true
    end
end

-- Drawn from the shared onDraw handler in init.lua, only while the overlay is open.
function Config.DrawWindow(status)
    ImGui.PushStyleVar(ImGuiStyleVar.WindowMinSize, 380, 60)
    ImGui.Begin("CyberLooter", ImGuiWindowFlags.AlwaysAutoResize)

    ImGui.Text("Bind a key in CET -> Bindings -> CyberLooter.")
    if status.bound then
        ImGui.Text("Current key: " .. tostring(status.bind))
    else
        ImGui.TextColored(1.0, 0.4, 0.4, 1.0, "No key bound yet - the mod does nothing.")
    end

    ImGui.Separator()

    sliderFloat("Radius (m)", "radius", 2.0, 25.0, "%.1f")
    sliderFloat("Hold time (s)", "holdTime", 0.1, 1.5, "%.2f")
    sliderInt("Max objects per sweep", "maxObjectsPerSweep", 4, 100)
    checkbox("Skip quest loot", "skipQuestItems")
    checkbox("Ignore key while a vanilla prompt is up", "respectInteraction")

    ImGui.Separator()
    ImGui.Text("Indicator")

    checkbox("Show indicator", "showIndicator")
    checkbox("Spell out the bound key in the prompt", "hintShowKeyName")
    checkbox("Re-send hint instead of updating", "hintRefreshHack")
    checkbox("ImGui fallback indicator", "useImGuiFallback")

    if Config.values.useImGuiFallback then
        sliderFloat("Offset X", "indicatorOffsetX", -800.0, 800.0, "%.0f")
        sliderFloat("Offset Y", "indicatorOffsetY", -600.0, 600.0, "%.0f")
    end

    ImGui.Separator()
    ImGui.Text("Diagnostics")

    if checkbox("Write cyberlooter.log", "debugLog") then
        Log.SetEnabled(Config.values.debugLog)
    end

    ImGui.Text("Scan strategy: " .. tostring(status.strategy))
    ImGui.Text("Objects in radius: " .. tostring(status.objects))
    ImGui.Text("Stacks in radius: " .. tostring(status.stacks))
    ImGui.Text("Last sweep: " .. tostring(status.lastSweep))
    ImGui.Text("Marker registry entries: " .. tostring(status.registrySize))

    -- Failures that would otherwise be invisible: the mod keeps working, but not
    -- the way the settings above claim it does.
    if status.interactionGuardBroken then
        ImGui.TextColored(1.0, 0.6, 0.2, 1.0, "Vanilla prompt guard is inactive (blackboard unreadable).")
    end

    if status.hintForcedFallback then
        ImGui.TextColored(1.0, 0.6, 0.2, 1.0, "Engine prompt failed, using the ImGui indicator.")
    end

    if status.heavyFilterBroken then
        ImGui.TextColored(1.0, 0.6, 0.2, 1.0, "Heavy weapon filter is inactive (item records unreadable).")
    end

    if ImGui.Button("Clear log") then
        Log.Reset()
    end

    -- Reads nothing but the player's own inventory and changes nothing in it.
    if status.onDumpInventory ~= nil then
        ImGui.SameLine()
        if ImGui.Button("Dump inventory to log") then
            Config.lastDump = string.format("%d entries written to the log",
                status.onDumpInventory())
            -- A fresh look at the inventory invalidates an armed deletion.
            Config.cleanupArmed = false
        end

        if Config.lastDump ~= nil then
            ImGui.Text(Config.lastDump)
        end
    end

    -- This one deletes items, so it asks twice and says exactly what it found.
    if status.onFindStuck ~= nil then
        local stuck, weight = status.onFindStuck()

        if #stuck == 0 then
            ImGui.Text("No stuck items in the inventory.")
            Config.cleanupArmed = false
        else
            ImGui.TextColored(1.0, 0.6, 0.2, 1.0, string.format(
                "%d stuck entries, %.1f weight - invisible in the backpack and not droppable.",
                #stuck, weight))

            -- Named in full: deletion is irreversible, so the list is on screen
            -- before the second click, not only in the log afterwards.
            for index, row in ipairs(stuck) do
                if index > 8 then
                    ImGui.Text(string.format("    ... and %d more", #stuck - 8))
                    break
                end
                ImGui.Text(string.format("    %s x%d", row.name, row.quantity))
            end

            if not Config.cleanupArmed then
                if ImGui.Button("Remove stuck items") then
                    Config.cleanupArmed = true
                end
            else
                if ImGui.Button(string.format("Confirm: delete %d entries", #stuck)) then
                    Config.cleanupArmed = false
                    local removed, freed = status.onRemoveStuck()
                    Config.lastCleanup = string.format("%d entries removed, %.1f weight freed",
                        removed, freed)
                end

                ImGui.SameLine()
                if ImGui.Button("Cancel") then
                    Config.cleanupArmed = false
                end
            end
        end

        if Config.lastCleanup ~= nil then
            ImGui.Text(Config.lastCleanup)
        end
    end

    ImGui.End()
    ImGui.PopStyleVar(1)
end

return Config
