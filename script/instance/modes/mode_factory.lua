local SurvivalMode = require "instance.modes.survival_mode"
local WavesMode = require "instance.modes.waves_mode"
local BossRushMode = require "instance.modes.boss_rush_mode"
local ObjectiveMode = require "instance.modes.objective_mode"

local mode_factory = {}

local MODE_CLASS_MAP = {
    survival = SurvivalMode,
    waves = WavesMode,
    boss_rush = BossRushMode,
    objective = ObjectiveMode,
}

function mode_factory.create(mode_type, mode_config)
    local t = tostring(mode_type or ""):lower()
    local mode_class = MODE_CLASS_MAP[t]
    if not mode_class then
        return nil
    end
    return mode_class.new(mode_config or {})
end

return mode_factory
