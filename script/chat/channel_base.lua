local skynet = require "skynet"
local log = require "log"
local class = require "utils.class"

local channel_base = class("channel_base")

-- 构造函数
function channel_base:ctor(channel_id, channel_name, channel_type)
    self.channel_id = channel_id
    self.channel_name = channel_name
    self.channel_type = channel_type
    self.members = {}  -- {player_id = {player_id, player_name, join_time}}
    self.create_time = os.time()
    self.last_message_time = os.time()
end

-- 检查玩家是否可以加入频道
function channel_base:can_join(player_id, player_name)
    -- 基类默认允许加入，子类可以重写此方法
    return true
end

-- 玩家加入频道
function channel_base:join(player_id, player_name)
    if not self:can_join(player_id, player_name) then
        return false, "Cannot join channel"
    end
    
    if self.members[player_id] then
        return true, "Already in channel"
    end
    
    self.members[player_id] = {
        player_id = player_id,
        player_name = player_name,
        join_time = os.time()
    }
    self:onjoin(player_id, player_name)
    return true
end

function channel_base:onjoin(player_id, player_name)
    -- 通知频道内其他成员
    --self:broadcast_system_message(string.format("Player %s has joined the channel", player_name))
end

-- 玩家离开频道
function channel_base:leave(player_id)
    if not self.members[player_id] then
        return false, "Not in channel"
    end
    
    local player_name = self.members[player_id].player_name
    self.members[player_id] = nil
    
    self:onleave(player_id, player_name)
    return true
end

function channel_base:onleave(player_id, player_name)
    -- 通知频道内其他成员
    --self:broadcast_system_message(string.format("Player %s has left the channel", player_name))
end

-- 踢出玩家
function channel_base:kick(player_id, operator_id)
    if not self.members[player_id] then
        return false, "Player not in channel"
    end
    
    -- 检查操作者权限
    if not self:can_kick(operator_id, player_id) then
        return false, "No permission to kick"
    end
    
    local player_name = self.members[player_id].player_name
    self.members[player_id] = nil
    
    -- 通知频道内其他成员
    self:broadcast_system_message(string.format("Player %s has been kicked from the channel", player_name))
    
    return true
end

-- 检查是否有踢人权限
function channel_base:can_kick(operator_id, target_id)
    -- 基类默认不允许踢人，子类可以重写此方法
    return false
end

-- 广播系统消息
function channel_base:broadcast_system_message(content)
    local msg = {
        type = "system",
        channel_id = self.channel_id,
        channel_name = self.channel_name,
        content = content,
        time = os.time()
    }
    
    self:broadcast_message(msg)
end

-- 广播消息
function channel_base:broadcast_message(msg)
    -- 更新最后消息时间
    self.last_message_time = os.time()
    
    -- 发送给所有成员
    for player_id, _ in pairs(self.members) do
        protocol_handler.send_to_player(player_id, "chat_message", msg)
    end
end

-- 获取频道成员列表
function channel_base:get_members()
    local result = {}
    for _, member in pairs(self.members) do
        table.insert(result, {
            player_id = member.player_id,
            player_name = member.player_name,
            join_time = member.join_time
        })
    end
    return result
end

-- 获取频道信息
function channel_base:get_info()
    return {
        channel_id = self.channel_id,
        channel_name = self.channel_name,
        channel_type = self.channel_type,
        member_count = self:get_member_count(),
        create_time = self.create_time,
        last_message_time = self.last_message_time
    }
end

-- 获取成员数量
function channel_base:get_member_count()
    local count = 0
    for _ in pairs(self.members) do
        count = count + 1
    end
    return count
end

-- 检查玩家是否在频道中
function channel_base:is_member(player_id)
    return self.members[player_id] ~= nil
end

-- 获取玩家加入时间
function channel_base:get_member_join_time(player_id)
    if self.members[player_id] then
        return self.members[player_id].join_time
    end
    return nil
end

return channel_base
