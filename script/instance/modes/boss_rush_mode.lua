local class = require "utils.class"
local ModeBase = require "instance.modes.mode_base"
local inst_def = require "define.inst_def"
local InstanceEndType = inst_def.InstanceEndType
local InstanceEndReason = inst_def.InstanceEndReason

local BossRushMode = class("BossRushMode", ModeBase)

function BossRushMode:ctor(config)
    BossRushMode.super.ctor(self, "boss_rush", config)
    self.total_bosses_ = tonumber(self.config_.total_bosses) or 3
    self.boss_seconds_ = tonumber(self.config_.boss_seconds) or 45
    self.auto_advance_ = self.config_.auto_advance ~= false
    self.current_boss_ = 1
    self.boss_elapsed_ = 0
end

function BossRushMode:on_start(inst)
    BossRushMode.super.on_start(self, inst)
    self.current_boss_ = 1
    self.boss_elapsed_ = 0
end

function BossRushMode:on_update(inst, dt)
    BossRushMode.super.on_update(self, inst, dt)
    if not self.auto_advance_ then
        return
    end
    self.boss_elapsed_ = self.boss_elapsed_ + (dt or 0)
    if self.boss_elapsed_ < self.boss_seconds_ then
        return
    end

    self.boss_elapsed_ = 0
    self.current_boss_ = self.current_boss_ + 1
    if self.current_boss_ > self.total_bosses_ then
        inst:complete(true, {
            end_type = InstanceEndType.NORMAL,
            end_reason = InstanceEndReason.NORMAL_WIN,
            mode = self.mode_type_,
        })
    end
end

function BossRushMode:on_event(inst, event_type, payload)
    if event_type == "boss_killed" then
        local add = tonumber(payload and payload.event_value) or 1
        if add < 1 then
            add = 1
        end
        self.current_boss_ = self.current_boss_ + add
        self.boss_elapsed_ = 0
        if self.current_boss_ > self.total_bosses_ then
            inst:complete(true, {
                end_type = InstanceEndType.NORMAL,
                end_reason = InstanceEndReason.NORMAL_WIN,
                mode = self.mode_type_,
            })
        end
    elseif event_type == "team_wipe" then
        inst:complete(false, {
            end_type = InstanceEndType.NORMAL,
            end_reason = InstanceEndReason.NORMAL_LOSE,
            mode = self.mode_type_,
        })
    end
end

function BossRushMode:build_runtime_data(inst)
    return {
        mode_type = self.mode_type_,
        total_bosses = self.total_bosses_,
        current_boss = math.min(self.current_boss_, self.total_bosses_),
        boss_seconds = self.boss_seconds_,
        boss_elapsed = self.boss_elapsed_,
    }
end

return BossRushMode
