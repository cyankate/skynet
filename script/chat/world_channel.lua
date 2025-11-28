local skynet = require "skynet"
local ChannelBase = require "chat.channel_base"

local WorldChannel = class("WorldChannel", ChannelBase)

-- 构造函数
function WorldChannel:ctor(channel_id, channel_name, channel_type)
    ChannelBase.ctor(self, channel_id, channel_name, channel_type)
    self.max_members = 1000  -- 世界频道最大成员数
end

-- 检查玩家是否可以加入频道
function WorldChannel:can_join(player_id, player_name)
    -- 检查频道是否已满
    if self:get_member_count() >= self.max_members then
        return false
    end
    
    -- 检查玩家是否已经在频道中
    if self:is_member(player_id) then
        return false
    end
    
    return true
end

-- 检查是否有踢人权限
function WorldChannel:can_kick(operator_id, target_id)
    -- 世界频道不允许踢人
    return false
end

function WorldChannel:broadcast_message(msg)
    ChannelBase.broadcast_message(self, msg)
end

return WorldChannel
