local skynet = require "skynet"
local channel_base = require "chat.channel_base"
local class = require "utils.class"

local private_channel = class("private_channel", channel_base)

-- 构造函数
function private_channel:ctor(channel_id, channel_name, channel_type, player1_id, player2_id)
    channel_base.ctor(self, channel_id, channel_name, channel_type)
    self.player1_id = player1_id
    self.player2_id = player2_id
    self.max_members = 2  -- 私聊频道固定为2人
    self.inserted = false
    self.dirty_ = false
end

-- 检查玩家是否可以加入频道
function private_channel:can_join(player_id, player_name)
    -- 检查是否是频道允许的玩家
    if player_id ~= self.player1_id and player_id ~= self.player2_id then
        return false
    end
    
    -- 检查玩家是否已经在频道中
    if self:is_member(player_id) then
        return false
    end
    
    return true
end

-- 检查是否有踢人权限
function private_channel:can_kick(operator_id, target_id)
    -- 私聊频道不允许踢人
    return false
end

-- 获取对方玩家ID
function private_channel:get_other_player_id(player_id)
    if player_id == self.player1_id then
        return self.player2_id
    elseif player_id == self.player2_id then
        return self.player1_id
    end
    return nil
end

function private_channel:onjoin(player_id, player_name)

end
-- 广播消息（重写基类方法，私聊只发给对方）
function private_channel:broadcast_message(msg)
    -- 更新最后消息时间
    self.last_message_time = os.time()
    
    
    channel_mgr.cache:update_message(self.channel_id, msg)

    protocol_handler.send_to_player(self.player1_id, "chat_message", msg)
    protocol_handler.send_to_player(self.player2_id, "chat_message", msg)
end

-- 获取频道信息（重写基类方法，增加删除状态）
function private_channel:onsave()
    local info = {
        channel_id = self.channel_id,
        player1_id = math.min(self.player1_id, self.player2_id),
        player2_id = math.max(self.player1_id, self.player2_id),
        create_time = os.time(),
        last_message_time = os.time(),
    }
    return info
end

return private_channel
