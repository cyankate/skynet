local class = require "utils.class"
local ModeBase = require "instance.modes.mode_base"
local inst_def = require "define.inst_def"
local InstanceEndType = inst_def.InstanceEndType
local InstanceEndReason = inst_def.InstanceEndReason

local WavesMode = class("WavesMode", ModeBase)

function WavesMode:ctor(config)
    WavesMode.super.ctor(self, "waves", config)
    self.total_waves_ = tonumber(self.config_.total_waves) or 5
    self.wave_seconds_ = tonumber(self.config_.wave_seconds) or 30
    self.auto_advance_ = self.config_.auto_advance ~= false
    self.current_wave_ = 1
    self.wave_elapsed_ = 0
end

function WavesMode:on_start(inst)
    WavesMode.super.on_start(self, inst)
    self.current_wave_ = 1
    self.wave_elapsed_ = 0
end

function WavesMode:on_update(inst, dt)
    WavesMode.super.on_update(self, inst, dt)
    if not self.auto_advance_ then
        return
    end
    self.wave_elapsed_ = self.wave_elapsed_ + (dt or 0)
    if self.wave_elapsed_ < self.wave_seconds_ then
        return
    end

    self.wave_elapsed_ = 0
    self.current_wave_ = self.current_wave_ + 1
    if self.current_wave_ > self.total_waves_ then
        inst:complete(true, {
            end_type = InstanceEndType.NORMAL,
            end_reason = InstanceEndReason.NORMAL_WIN,
            mode = self.mode_type_,
        })
    end
end

function WavesMode:on_event(inst, event_type, payload)
    if event_type ~= "wave_clear" then
        return
    end
    local add = tonumber(payload and payload.event_value) or 1
    if add < 1 then
        add = 1
    end
    self.current_wave_ = self.current_wave_ + add
    self.wave_elapsed_ = 0
    if self.current_wave_ > self.total_waves_ then
        inst:complete(true, {
            end_type = InstanceEndType.NORMAL,
            end_reason = InstanceEndReason.NORMAL_WIN,
            mode = self.mode_type_,
        })
    end
end

function WavesMode:build_runtime_data(inst)
    return {
        mode_type = self.mode_type_,
        total_waves = self.total_waves_,
        current_wave = math.min(self.current_wave_, self.total_waves_),
        wave_seconds = self.wave_seconds_,
        wave_elapsed = self.wave_elapsed_,
    }
end

return WavesMode
