local skynet = require "skynet"
local log = require "log"
local class = require "utils.class"

local ChannelBase = class("ChannelBase")

-- 构造函数
function ChannelBase:ctor(channel_id, channel_name, channel_type)
    self.channel_id = channel_id
    self.channel_name = channel_name
    self.channel_type = channel_type
    self.members = {}  -- {player_id = {player_id, player_name, join_time}}
    self.player_ids = {}
    self.create_time = os.time()
    self.last_message_time = os.time()
end

-- 检查玩家是否可以加入频道
function ChannelBase:can_join(player_id, player_name)
    -- 基类默认允许加入，子类可以重写此方法
    return true
end

-- 玩家加入频道
function ChannelBase:join(player_id, player_name)
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

    table.insert(self.player_ids, player_id)

    self:onjoin(player_id, player_name)
    return true
end

function ChannelBase:onjoin(player_id, player_name)
    -- 通知频道内其他成员
    --self:broadcast_system_message(string.format("Player %s has joined the channel", player_name))
end

-- 玩家离开频道
function ChannelBase:leave(player_id)
    if not self.members[player_id] then
        return false, "Not in channel"
    end
    
    local player_name = self.members[player_id].player_name
    self.members[player_id] = nil
    
    for i, v in ipairs(self.player_ids) do
        if v == player_id then
            table.remove(self.player_ids, i)
            break
        end
    end

    self:onleave(player_id, player_name)
    return true
end

function ChannelBase:onleave(player_id, player_name)
    -- 通知频道内其他成员
    --self:broadcast_system_message(string.format("Player %s has left the channel", player_name))
end

-- 踢出玩家
function ChannelBase:kick(player_id, operator_id)
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
function ChannelBase:can_kick(operator_id, target_id)
    -- 基类默认不允许踢人，子类可以重写此方法
    return false
end

-- 广播系统消息
function ChannelBase:broadcast_system_message(content)
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
function ChannelBase:broadcast_message(msg)
    -- 更新最后消息时间
    self.last_message_time = os.time()
    -- 更新缓存
    channel_mgr.cache:update_message(self.channel_id, msg)
    protocol_handler.send_to_players(self.player_ids, "chat_message", msg)
end

-- 获取频道成员列表
function ChannelBase:get_members()
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
function ChannelBase:get_info()
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
function ChannelBase:get_member_count()
    local count = 0
    for _ in pairs(self.members) do
        count = count + 1
    end
    return count
end

-- 检查玩家是否在频道中
function ChannelBase:is_member(player_id)
    return self.members[player_id] ~= nil
end

-- 获取玩家加入时间
function ChannelBase:get_member_join_time(player_id)
    if self.members[player_id] then
        return self.members[player_id].join_time
    end
    return nil
end

return ChannelBase
