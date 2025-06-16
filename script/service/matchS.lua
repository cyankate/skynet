local skynet = require "skynet"
local log = require "log"
local service_wrapper = require "utils.service_wrapper"
local match_mgr = require "match.match_mgr"

-- 初始化
function CMD.init()
    log.info("match service init")
    match_mgr.init()
end

-- 创建房间
function CMD.create_room(player_id, game_type)
    return match_mgr.create_room(player_id, game_type)
end

-- 加入房间
function CMD.join_room(player_id, room_id)
    return match_mgr.join_room(player_id, room_id)
end

-- 离开房间
function CMD.leave_room(player_id)
    return match_mgr.leave_room(player_id)
end

-- 准备
function CMD.ready(player_id)
    return match_mgr.ready(player_id)
end

-- 获取房间信息
function CMD.get_room_info(room_id)
    local room = match_mgr.get_room(room_id)
    if not room then
        return nil, "房间不存在"
    end
    return room:get_info()
end

-- 获取房间列表
function CMD.get_room_list()
    return match_mgr.get_room_list()
end

-- 游戏操作
function CMD.play_tile(room_id, player_id, tile)
    local room = match_mgr.get_room(room_id)
    if not room then
        return false, "房间不存在"
    end
    return room:play_tile(player_id, tile)
end

function CMD.chi_tile(room_id, player_id, tiles)
    local room = match_mgr.get_room(room_id)
    if not room then
        return false, "房间不存在"
    end
    return room:chi_tile(player_id, tiles)
end

function CMD.peng_tile(room_id, player_id)
    local room = match_mgr.get_room(room_id)
    if not room then
        return false, "房间不存在"
    end
    return room:peng_tile(player_id)
end

function CMD.gang_tile(room_id, player_id, tile)
    local room = match_mgr.get_room(room_id)
    if not room then
        return false, "房间不存在"
    end
    return room:gang_tile(player_id, tile)
end

function CMD.hu_tile(room_id, player_id)
    local room = match_mgr.get_room(room_id)
    if not room then
        return false, "房间不存在"
    end
    return room:hu_tile(player_id)
end

-- 快速匹配
function CMD.quick_match(player_id, game_type)
    return match_mgr.quick_match(player_id, game_type)
end

-- 取消匹配
function CMD.cancel_match(player_id, game_type)
    return match_mgr.cancel_match(player_id, game_type)
end

-- 出牌
function CMD.play_cards(player_id, cards)
    local room_id = match_mgr.get_player_room(player_id)
    if not room_id then
        return false, "玩家不在房间中"
    end
    
    local room = match_mgr.get_room(room_id)
    if not room then
        return false, "房间不存在"
    end
    
    return room:play_cards(player_id, cards)
end

local function main()
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "match",
})
