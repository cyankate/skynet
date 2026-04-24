local class = require "utils.class"

local ModeBase = class("ModeBase")

function ModeBase:ctor(mode_type, config)
    self.mode_type_ = mode_type
    self.config_ = config or {}
    self.elapsed_ = 0
end

function ModeBase:on_start(inst)
    self.elapsed_ = 0
end

function ModeBase:on_update(inst, dt)
    self.elapsed_ = self.elapsed_ + (dt or 0)
end

function ModeBase:on_player_quit(inst, player_id)
    -- 子类按需实现
end

function ModeBase:build_runtime_data(inst)
    return {
        mode_type = self.mode_type_,
        elapsed = self.elapsed_,
    }
end

return ModeBase
