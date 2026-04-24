local class = require "utils.class"
local ModeBase = require "instance.modes.mode_base"
local inst_def = require "define.inst_def"
local InstanceEndType = inst_def.InstanceEndType
local InstanceEndReason = inst_def.InstanceEndReason

local SurvivalMode = class("SurvivalMode", ModeBase)

function SurvivalMode:ctor(config)
    SurvivalMode.super.ctor(self, "survival", config)
    self.target_seconds_ = tonumber(self.config_.target_seconds) or 180
end

function SurvivalMode:on_update(inst, dt)
    SurvivalMode.super.on_update(self, inst, dt)
    if self.elapsed_ >= self.target_seconds_ then
        inst:complete(true, {
            end_type = InstanceEndType.NORMAL,
            end_reason = InstanceEndReason.NORMAL_WIN,
            mode = self.mode_type_,
        })
    end
end

function SurvivalMode:on_event(inst, event_type, payload)
    if event_type == "core_destroyed" or event_type == "team_wipe" then
        inst:complete(false, {
            end_type = InstanceEndType.NORMAL,
            end_reason = InstanceEndReason.NORMAL_LOSE,
            mode = self.mode_type_,
        })
    elseif event_type == "survival_success" then
        inst:complete(true, {
            end_type = InstanceEndType.NORMAL,
            end_reason = InstanceEndReason.NORMAL_WIN,
            mode = self.mode_type_,
        })
    end
end

function SurvivalMode:build_runtime_data(inst)
    return {
        mode_type = self.mode_type_,
        elapsed = self.elapsed_,
        target_seconds = self.target_seconds_,
        remain_seconds = math.max(0, self.target_seconds_ - self.elapsed_),
    }
end

return SurvivalMode
