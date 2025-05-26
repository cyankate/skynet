local skynet = require "skynet"
local class = require "utils.class"

local room = class("room")

function room:ctor(room_id, owner_id)
    self.room_id = room_id
    self.owner_id = owner_id
    self.players = {}  -- {player_id = {ready = false, ...}}
    self.status = 0    -- 0:等待中 1:游戏中
end

function room:add_player(player_id)
    if self:is_full() then
        return false, "房间已满"
    end
    
    if self.players[player_id] then
        return false, "玩家已在房间中"
    end
    
    self.players[player_id] = {
        ready = false
    }
    
    -- 广播玩家加入消息
    self:broadcast("player_join", {
        room_id = self.room_id,
        player_id = player_id
    })
    
    return true
end

function room:remove_player(player_id)
    if not self.players[player_id] then
        return false, "玩家不在房间中"
    end
    
    if self.status == 1 then
        return false, "游戏中不能离开"
    end
    
    self.players[player_id] = nil
    
    -- 如果房间空了,返回特殊标记
    if self:is_empty() then
        return true, "room_empty"
    end
    
    -- 如果房主离开,转移房主
    if player_id == self.owner_id then
        for pid, _ in pairs(self.players) do
            self.owner_id = pid
            break
        end
    end
    
    -- 广播玩家离开消息
    self:broadcast("player_leave", {
        room_id = self.room_id,
        player_id = player_id,
        new_owner = self.owner_id
    })
    
    return true
end

function room:is_empty()
    return next(self.players) == nil
end

function room:is_full()
    local count = 0
    for _ in pairs(self.players) do
        count = count + 1
    end
    return count >= self:get_max_players()
end

function room:get_max_players()
    -- 子类重写
    return 0
end

function room:get_info()
    return {
        room_id = self.room_id,
        owner_id = self.owner_id,
        status = self.status,
        players = self:get_players_info()
    }
end

function room:get_players_info()
    local info = {}
    for pid, player in pairs(self.players) do
        info[pid] = {
            ready = player.ready
        }
    end
    return info
end

function room:broadcast(msg_type, data)
    for pid, _ in pairs(self.players) do
        skynet.send(pid, "lua", "send_msg", msg_type, data)
    end
end

return room 