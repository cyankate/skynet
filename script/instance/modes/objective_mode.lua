local class = require "utils.class"
local ModeBase = require "instance.modes.mode_base"
local inst_def = require "define.inst_def"
local InstanceEndType = inst_def.InstanceEndType
local InstanceEndReason = inst_def.InstanceEndReason

local ObjectiveMode = class("ObjectiveMode", ModeBase)

function ObjectiveMode:ctor(config)
    ObjectiveMode.super.ctor(self, "objective", config)
    self.target_score_ = tonumber(self.config_.target_score) or 100
    self.gain_per_second_ = tonumber(self.config_.gain_per_second) or 5
    self.score_ = 0
end

function ObjectiveMode:on_start(inst)
    ObjectiveMode.super.on_start(self, inst)
    self.score_ = 0
end

function ObjectiveMode:on_update(inst, dt)
    ObjectiveMode.super.on_update(self, inst, dt)
    self.score_ = math.min(self.target_score_, self.score_ + self.gain_per_second_ * (dt or 0))
    if self.score_ >= self.target_score_ then
        inst:complete(true, {
            end_type = InstanceEndType.NORMAL,
            end_reason = InstanceEndReason.NORMAL_WIN,
            mode = self.mode_type_,
        })
    end
end

function ObjectiveMode:on_event(inst, event_type, payload)
    if event_type == "add_score" then
        local add = tonumber(payload and payload.event_value) or 0
        if add <= 0 then
            return
        end
        self.score_ = math.min(self.target_score_, self.score_ + add)
        if self.score_ >= self.target_score_ then
            inst:complete(true, {
                end_type = InstanceEndType.NORMAL,
                end_reason = InstanceEndReason.NORMAL_WIN,
                mode = self.mode_type_,
            })
        end
    elseif event_type == "objective_failed" then
        inst:complete(false, {
            end_type = InstanceEndType.NORMAL,
            end_reason = InstanceEndReason.NORMAL_LOSE,
            mode = self.mode_type_,
        })
    end
end

function ObjectiveMode:build_runtime_data(inst)
    return {
        mode_type = self.mode_type_,
        target_score = self.target_score_,
        score = math.floor(self.score_),
        gain_per_second = self.gain_per_second_,
    }
end

return ObjectiveMode
