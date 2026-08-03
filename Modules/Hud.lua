-- Fallback indicator, used only if the engine's own hint system does not work.
--
-- Safe to draw while the overlay is closed: LuaVM::Draw() is called every frame
-- from the render loop regardless of overlay state (D3D12_Functions.cpp:358).

local Hud = {}

local Config

local WINDOW_FLAGS = ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoResize
    + ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoScrollbar + ImGuiWindowFlags.NoInputs
    + ImGuiWindowFlags.NoBackground + ImGuiWindowFlags.NoFocusOnAppearing
    + ImGuiWindowFlags.NoNav + ImGuiWindowFlags.AlwaysAutoResize

function Hud.Init(deps)
    Config = deps.Config
end

-- count: stacks in radius, progress: 0..1 hold progress, bind: assigned key.
function Hud.Draw(count, progress, bind)
    if not Config.values.showIndicator or not Config.values.useImGuiFallback then
        return
    end

    if count <= 0 then
        return
    end

    local width, height = ImGui.GetDisplaySize()
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
