local class = require "utils.class"
local InstanceBase = require "instance.instance_base"

local function table_size(t)
    local n = 0
    for _ in pairs(t or {}) do
        n = n + 1
    end
    return n
end

local InstanceMulti = class("InstanceMulti", InstanceBase)

function InstanceMulti:ctor(inst_id, inst_no, args)
    InstanceBase.ctor(self, inst_id, inst_no, args)
    self.max_players_ = (args and args.team_size) or 3
    self.min_players_ = (args and args.min_players) or 2
end

function InstanceMulti:join(player_id, data_)
    local joined_count = table_size(self.pjoins_)
    if joined_count >= self.max_players_ then
        return false, "多人副本已满"
    end
    return InstanceMulti.super.join(self, player_id, data_)
end

function InstanceMulti:start()
    local joined_count = table_size(self.pjoins_)
    if joined_count < self.min_players_ then
        return false, "人数不足，无法开始多人副本"
    end
    return InstanceMulti.super.start(self)
end

return InstanceMulti
