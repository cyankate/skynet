local skynet = require "skynet"
local log = require "log"
local LandlordRoom = require "match.landlord_room"
local MahjongRoom = require "match.mahjong_room"

local match_mgr = {}

-- 游戏类型定义
match_mgr.GAME_TYPE = {
    LANDLORD = 1,  -- 斗地主
    MAHJONG = 2,   -- 麻将
}

-- 房间管理
match_mgr.rooms = {}  -- {room_id = room_obj}
match_mgr.player_rooms = {}  -- {player_id = room_id}
match_mgr.waiting_players = {}  -- {game_type = {player_id1, player_id2, ...}}
match_mgr.next_room_id = 1  -- 下一个房间ID

-- 初始化
function match_mgr.init()
    -- 清空所有状态
    match_mgr.rooms = {}
    match_mgr.player_rooms = {}
    match_mgr.waiting_players = {
        [match_mgr.GAME_TYPE.LANDLORD] = {},
        [match_mgr.GAME_TYPE.MAHJONG] = {},
    }
    match_mgr.next_room_id = 1
end

-- 创建房间
function match_mgr.create_room(player_id, game_type)
    -- 检查玩家是否已在房间中
    if match_mgr.player_rooms[player_id] then
        log.error("player %d already in room", player_id)
        return false, "玩家已在房间中"
    end
    
    -- 生成房间ID
    local room_id = match_mgr.next_room_id
    match_mgr.next_room_id = match_mgr.next_room_id + 1
    
    -- 创建房间
    local room
    if game_type == match_mgr.GAME_TYPE.LANDLORD then
        room = LandlordRoom.new(room_id, player_id)
    elseif game_type == match_mgr.GAME_TYPE.MAHJONG then
        room = MahjongRoom.new(room_id, player_id)
    else
        log.error("invalid game type %d", game_type)
        return false, "无效的游戏类型"
    end
    
    match_mgr.rooms[room_id] = room
    match_mgr.player_rooms[player_id] = room_id
    
    log.info("create room %d by player %d, game type %d", room_id, player_id, game_type)
    return true, room:get_info()
end

-- 加入房间
function match_mgr.join_room(player_id, room_id)
    -- 检查玩家是否已在房间中
    if match_mgr.player_rooms[player_id] then
        log.error("player %d already in room", player_id)
        return false, "玩家已在房间中"
    end
    
    -- 检查房间是否存在
    local room = match_mgr.rooms[room_id]
    if not room then
        log.error("room %d not exist", room_id)
        return false, "房间不存在"
    end
    
    -- 加入房间
    local ok, err = room:add_player(player_id)
    if not ok then
        log.error("player %d join room %d failed: %s", player_id, room_id, err)
        return false, err
    end
    
    match_mgr.player_rooms[player_id] = room_id
    log.info("player %d join room %d", player_id, room_id)
    
    -- 返回房间信息
    return true, room:get_info()
end

-- 离开房间
function match_mgr.leave_room(player_id)
    local room_id = match_mgr.player_rooms[player_id]
    if not room_id then
        log.error("player %d not in room", player_id)
        return false, "玩家不在房间中"
    end
    
    local room = match_mgr.rooms[room_id]
    if not room then
        log.error("room %d not exist", room_id)
        return false, "房间不存在"
    end
    
    -- 离开房间
    local ok, err = room:remove_player(player_id)
    if not ok then
        log.error("player %d leave room %d failed: %s", player_id, room_id, err)
        return false, err
    end
    
    -- 如果房间空了,删除房间
    if err == "room_empty" then
        match_mgr.rooms[room_id] = nil
        log.info("room %d is empty, removed", room_id)
    end
    
    match_mgr.player_rooms[player_id] = nil
    log.info("player %d leave room %d", player_id, room_id)
    return true
end

-- 准备
function match_mgr.ready(player_id)
    local room_id = match_mgr.player_rooms[player_id]
    if not room_id then
        log.error("player %d not in room", player_id)
        return false, "玩家不在房间中"
    end
    
    local room = match_mgr.rooms[room_id]
    if not room then
        log.error("room %d not exist", room_id)
        return false, "房间不存在"
    end
    
    local ok, err = room:player_ready(player_id)
    if not ok then
        log.error("player %d ready failed in room %d: %s", player_id, room_id, err)
        return false, err
    end
    
    log.info("player %d ready in room %d", player_id, room_id)
    return true
end

-- 获取房间
function match_mgr.get_room(room_id)
    return match_mgr.rooms[room_id]
end

-- 获取房间列表
function match_mgr.get_room_list()
    local list = {}
    for room_id, room in pairs(match_mgr.rooms) do
        table.insert(list, {
            room_id = room_id,
            info = room:get_info()
        })
    end
    return list
end

-- 出牌
function match_mgr.play_cards(player_id, cards)
    local room_id = match_mgr.player_rooms[player_id]
    if not room_id then
        log.warn("player %d not in room", player_id)
        return false, "玩家不在房间中"
    end
    
    local room = match_mgr.rooms[room_id]
    if not room then
        log.warn("room %d not exist", room_id)
        return false, "房间不存在"
    end
    
    local ok, err = room:play_cards(player_id, cards)
    if ok then
        log.info("player %d play cards in room %d", player_id, room_id)
    else
        log.warn("player %d play cards failed in room %d: %s", player_id, room_id, err)
    end
    return ok, err
end

-- 获取房间信息
function match_mgr.get_room_info(room_id)
    local room = match_mgr.rooms[room_id]
    if not room then
        log.warn("room %d not exist", room_id)
        return nil, "房间不存在"
    end
    
    return room:get_info()
end

-- 获取玩家所在房间
function match_mgr.get_player_room(player_id)
    return match_mgr.player_rooms[player_id]
end

-- 快速匹配
function match_mgr.quick_match(player_id, game_type)
    -- 检查玩家是否已在房间中
    if match_mgr.player_rooms[player_id] then
        log.error("player %d already in room", player_id)
        return false, "玩家已在房间中"
    end
    
    -- 检查游戏类型
    if not match_mgr.waiting_players[game_type] then
        log.error("invalid game type %d", game_type)
        return false, "无效的游戏类型"
    end
    
    -- 添加到等待列表
    table.insert(match_mgr.waiting_players[game_type], player_id)
    log.info("player %d join match queue for game type %d", player_id, game_type)
    
    -- 检查是否可以创建房间
    local min_players = game_type == match_mgr.GAME_TYPE.LANDLORD and 3 or 4
    if #match_mgr.waiting_players[game_type] >= min_players then
        local room_id = match_mgr.next_room_id
        match_mgr.next_room_id = match_mgr.next_room_id + 1
        
        -- 创建房间
        local room
        if game_type == match_mgr.GAME_TYPE.LANDLORD then
            room = LandlordRoom.new(room_id, match_mgr.waiting_players[game_type][1])
        else
            room = MahjongRoom.new(room_id, match_mgr.waiting_players[game_type][1])
        end
        match_mgr.rooms[room_id] = room
        
        -- 添加玩家到房间
        for i = 1, min_players do
            local pid = table.remove(match_mgr.waiting_players[game_type], 1)
            room:add_player(pid)
            match_mgr.player_rooms[pid] = room_id
        end
        
        log.info("create room %d for game type %d with %d players", room_id, game_type, min_players)
        return true, room:get_info()
    end
    
    return true, nil  -- 等待匹配时返回nil作为room_info
end

-- 取消匹配
function match_mgr.cancel_match(player_id, game_type)
    if not match_mgr.waiting_players[game_type] then
        log.error("invalid game type %d", game_type)
        return false, "无效的游戏类型"
    end
    
    -- 从等待列表中移除
    for i, pid in ipairs(match_mgr.waiting_players[game_type]) do
        if pid == player_id then
            table.remove(match_mgr.waiting_players[game_type], i)
            log.info("player %d cancel match for game type %d", player_id, game_type)
            return true
        end
    end
    
    log.error("player %d not in match queue for game type %d", player_id, game_type)
    return false, "玩家不在匹配队列中"
end

-- 广播消息到房间
function match_mgr.broadcast_to_room(room_id, msg)
    local room = match_mgr.rooms[room_id]
    if not room then
        log.warn("room %d not exist", room_id)
        return false, "房间不存在"
    end
    
    for player_id, _ in pairs(room.players) do
        skynet.send(player_id, "lua", "landlord_msg", msg)
    end
    
    log.info("broadcast message to room %d", room_id)
    return true
end

return match_mgr 