-- Fallback indicator, used only if the engine's own hint system does not work.
--
-- Safe to draw while the overlay is closed: LuaVM::Draw() is called every frame
-- from the render loop regardless of overlay state (D3D12_Functions.cpp:358).

local Hud = {}

local Config
local Hint

local WINDOW_FLAGS = ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoResize
    + ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoScrollbar + ImGuiWindowFlags.NoInputs
    + ImGuiWindowFlags.NoBackground + ImGuiWindowFlags.NoFocusOnAppearing
    + ImGuiWindowFlags.NoNav + ImGuiWindowFlags.AlwaysAutoResize

function Hud.Init(deps)
    Config = deps.Config
    Hint = deps.Hint
end

-- CET exposes GetDisplayResolution(); ImGui.GetDisplaySize() is not part of its
-- bindings, so it is only tried as a second guess.
local function displaySize()
    if GetDisplayResolution ~= nil then
        local ok, width, height = pcall(GetDisplayResolution)
        if ok and width ~= nil and height ~= nil then
            return width, height
        end
    end

    local ok, width, height = pcall(function()
        return ImGui.GetDisplaySize()
    end)

    if ok and width ~= nil and height ~= nil then
        return width, height
    end

    return 1920, 1080
end

-- count: stacks in radius, progress: 0..1 hold progress, bind: assigned key.
function Hud.Draw(count, progress, bind)
    if not Config.values.showIndicator then
        return
    end

    -- Drawn either because the user asked for it, or because the engine hint
    -- failed this session and something has to stand in for it.
    if not Config.values.useImGuiFallback and not Hint.forcedFallback then
        return
    end

    if count <= 0 then
        return
    end

    local width, height = displaySize()
    local x = width * 0.5 + Config.values.indicatorOffsetX
    local y = height * 0.5 + Config.values.indicatorOffsetY

    ImGui.SetNextWindowPos(x, y, ImGuiCond.Always, 0.5, 0.5)
    ImGui.Begin("##CyberLooterIndicator", true, WINDOW_FLAGS)

    -- Filling from dim to bright is the hold progress.
    local fill = 0.35 + 0.65 * math.max(0.0, math.min(1.0, progress))
    ImGui.TextColored(fill, fill, fill * 0.4 + 0.2, 1.0, "[" .. tostring(bind or "?") .. "]")
    ImGui.SameLine()
    ImGui.Text(tostring(count))

    ImGui.End()
end

return Hud
