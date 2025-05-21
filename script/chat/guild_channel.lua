local skynet = require "skynet"
local channel_base = require "chat.channel_base"
local class = require "utils.class"

local guild_channel = class("guild_channel", channel_base)

-- 构造函数
function guild_channel:ctor(channel_id, channel_name, channel_type, guild_id)
    channel_base.ctor(self, channel_id, channel_name, channel_type)
    self.guild_id = guild_id
    self.max_members = 100  -- 公会频道最大成员数
end

-- 检查玩家是否可以加入频道
function guild_channel:can_join(player_id, player_name)
    -- 检查频道是否已满
    if self:get_member_count() >= self.max_members then
        return false
    end
    
    -- 检查玩家是否已经在频道中
    if self:is_member(player_id) then
        return false
    end
    
    -- 检查玩家是否是公会成员
    local is_member = skynet.call(".guild", "lua", "is_guild_member", self.guild_id, player_id)
    if not is_member then
        return false
    end
    
    return true
end

-- 检查是否有踢人权限
function guild_channel:can_kick(operator_id, target_id)
    -- 检查操作者是否是公会管理员
    local is_admin = skynet.call(".guild", "lua", "is_guild_admin", self.guild_id, operator_id)
    if not is_admin then
        return false
    end
    
    -- 检查目标是否是公会成员
    local is_member = skynet.call(".guild", "lua", "is_guild_member", self.guild_id, target_id)
    if not is_member then
        return false
    end
    
    return true
end

-- 获取公会ID
function guild_channel:get_guild_id()
    return self.guild_id
end

return guild_channel
