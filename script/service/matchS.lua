local skynet = require "skynet"
local log = require "log"
local match_def = require "define.match_def"

local match = {}

-- 匹配队列 {match_type = {player_id = player_data}}
local match_queues = {}
-- 匹配房间 {room_id = room_data}
local match_rooms = {}
-- 玩家匹配信息 {player_id = match_data}
local player_matches = {}
-- 匹配统计 {match_type = {total = 0, success = 0, timeout = 0, cancel = 0}}
local match_stats = {}

-- 错误码定义
local ERROR = {
    ALREADY_MATCHING = 1001,    -- 已经在匹配中
    NOT_MATCHING = 1002,        -- 未在匹配中
    NOT_IN_ROOM = 1003,         -- 未在匹配房间中
    ROOM_NOT_EXIST = 1004,      -- 房间不存在
    INVALID_MATCH_TYPE = 1005,  -- 无效的匹配类型
    INVALID_PLAYER_DATA = 1006, -- 无效的玩家数据
    MATCH_TIMEOUT = 1007,       -- 匹配超时
    MATCH_CANCELED = 1008,      -- 匹配已取消
}

-- 初始化匹配统计
local function init_stats()
    for _, match_type in pairs(match_def.TYPE) do
        match_stats[match_type] = {
            total = 0,
            success = 0,
            timeout = 0,
            cancel = 0,
            avg_time = 0,
            total_time = 0,
        }
    end
end

-- 更新匹配统计
local function update_stats(match_type, stat_type)
    if not match_stats[match_type] then 
        log.error("Invalid match type:", match_type)
        return 
    end
    
    match_stats[match_type][stat_type] = match_stats[match_type][stat_type] + 1
    if stat_type == "success" then
        match_stats[match_type].total = match_stats[match_type].total + 1
    end
end

-- 检查匹配超时
local function check_match_timeout()
    local now = os.time()
    for player_id, match_data in pairs(player_matches) do
        if match_data.state == match_def.STATE.WAITING then
            local wait_time = now - match_data.start_time
            if wait_time >= match_config.timeout then
                -- 超时处理
                log.warning("Match timeout for player:", player_id, "wait time:", wait_time)
                match.cancel_match(player_id)
                match_data.state = match_def.STATE.CANCELED
                
                -- 更新统计
                update_stats(match_data.type, "timeout")
            end
        end
    end
end

-- 匹配房间数据
local function create_room(match_type, players)
    local room_id = skynet.unique()
    local room = {
        id = room_id,
        type = match_type,
        players = players,
        state = match_def.STATE.MATCHED,
        create_time = os.time(),
        ready_players = {},
    }
    match_rooms[room_id] = room
    log.info("Create match room:", room_id, "type:", match_type, "players:", #players)
    return room
end

-- 检查玩家是否匹配
local function check_match(player1, player2, match_type)
    local rule = match_config.rules[match_type]
    if not rule then 
        log.error("Invalid match type:", match_type)
        return false 
    end
    
    -- 检查积分差
    local score_diff = math.abs(player1.score - player2.score)
    if score_diff > rule.score_range then
        log.debug("Score difference too large:", score_diff, ">", rule.score_range)
        return false
    end
    
    -- 检查等级差
    local level_diff = math.abs(player1.level - player2.level)
    if level_diff > rule.level_range then
        log.debug("Level difference too large:", level_diff, ">", rule.level_range)
        return false
    end
    
    -- 检查在线状态
    if not player1.online or not player2.online then
        log.debug("Player offline:", player1.online, player2.online)
        return false
    end
    
    return true
end

-- 尝试匹配玩家
local function try_match(match_type)
    local queue = match_queues[match_type]
    if not queue then 
        log.debug("No players in queue for type:", match_type)
        return 
    end
    
    local rule = match_config.rules[match_type]
    if not rule then 
        log.error("Invalid match type:", match_type)
        return 
    end
    
    -- 获取所有等待匹配的玩家
    local waiting_players = {}
    for player_id, player_data in pairs(queue) do
        table.insert(waiting_players, {
            id = player_id,
            data = player_data,
        })
    end
    
    log.debug("Try match for type:", match_type, "players:", #waiting_players)
    
    -- 按积分排序
    table.sort(waiting_players, function(a, b)
        return a.data.score > b.data.score
    end)
    
    -- 尝试匹配
    local matched_players = {}
    for i = 1, #waiting_players do
        local player1 = waiting_players[i]
        if not player1.matched then
            for j = i + 1, #waiting_players do
                local player2 = waiting_players[j]
                if not player2.matched and check_match(player1.data, player2.data, match_type) then
                    table.insert(matched_players, player1)
                    table.insert(matched_players, player2)
                    player1.matched = true
                    player2.matched = true
                    
                    -- 如果达到最大人数,创建房间
                    if #matched_players >= rule.max_players then
                        local room = create_room(match_type, matched_players)
                        -- 通知玩家匹配成功
                        for _, player in ipairs(matched_players) do
                            player_matches[player.id].room_id = room.id
                            player_matches[player.id].state = match_def.STATE.MATCHED
                            local ok, err = pcall(function()
                                skynet.call(player.data.agent, "lua", "match_success", room)
                            end)
                            if not ok then
                                log.error("Failed to notify player:", player.id, "error:", err)
                            end
                            
                            -- 从匹配队列中移除
                            match_queues[match_type][player.id] = nil
                        end
                        
                        -- 更新统计
                        update_stats(match_type, "success")
                        return
                    end
                end
            end
        end
    end
end

-- 开始匹配
function match.start_match(player_id, match_type, player_data)
    if not match_def.TYPE[match_type] then
        log.error("Invalid match type:", match_type)
        return false, ERROR.INVALID_MATCH_TYPE, "无效的匹配类型"
    end
    
    if not player_data or not player_data.agent then
        log.error("Invalid player data:", player_id)
        return false, ERROR.INVALID_PLAYER_DATA, "无效的玩家数据"
    end
    
    if not match_queues[match_type] then
        match_queues[match_type] = {}
    end
    
    -- 检查是否已经在匹配中
    if player_matches[player_id] then
        log.warning("Player already in match:", player_id)
        return false, ERROR.ALREADY_MATCHING, "已经在匹配中"
    end
    
    -- 添加到匹配队列
    match_queues[match_type][player_id] = player_data
    
    -- 记录匹配信息
    player_matches[player_id] = {
        type = match_type,
        state = match_def.STATE.WAITING,
        start_time = os.time(),
    }
    
    log.info("Player start match:", player_id, "type:", match_type)
    
    -- 触发匹配开始事件
    local eventS = skynet.uniqueservice("event")
    skynet.call(eventS, "lua", "trigger", match_def.EVENT.MATCH_START, player_id, match_type)
    
    -- 尝试匹配
    try_match(match_type)
    
    return true
end

-- 取消匹配
function match.cancel_match(player_id)
    local match_data = player_matches[player_id]
    if not match_data then
        log.warning("Player not in match:", player_id)
        return false, ERROR.NOT_MATCHING, "未在匹配中"
    end
    
    -- 从匹配队列中移除
    if match_queues[match_data.type] then
        match_queues[match_data.type][player_id] = nil
    end
    
    -- 如果已经在房间中,从房间中移除
    if match_data.room_id then
        local room = match_rooms[match_data.room_id]
        if room then
            for i, player in ipairs(room.players) do
                if player.id == player_id then
                    table.remove(room.players, i)
                    break
                end
            end
            
            -- 如果房间空了,删除房间
            if #room.players == 0 then
                match_rooms[match_data.room_id] = nil
                log.info("Delete empty room:", match_data.room_id)
            end
        end
    end
    
    -- 更新匹配状态
    match_data.state = match_def.STATE.CANCELED
    
    log.info("Player cancel match:", player_id)
    
    -- 触发取消匹配事件
    local eventS = skynet.uniqueservice("event")
    skynet.call(eventS, "lua", "trigger", match_def.EVENT.MATCH_CANCEL, player_id)
    
    -- 更新统计
    update_stats(match_data.type, "cancel")
    
    return true
end

-- 玩家准备
function match.player_ready(player_id)
    local match_data = player_matches[player_id]
    if not match_data or not match_data.room_id then
        log.warning("Player not in room:", player_id)
        return false, ERROR.NOT_IN_ROOM, "未在匹配房间中"
    end
    
    local room = match_rooms[match_data.room_id]
    if not room then
        log.error("Room not exist:", match_data.room_id)
        return false, ERROR.ROOM_NOT_EXIST, "房间不存在"
    end
    
    -- 标记玩家准备
    room.ready_players[player_id] = true
    
    log.info("Player ready:", player_id, "room:", room.id)
    
    -- 检查是否所有玩家都准备好了
    local all_ready = true
    for _, player in ipairs(room.players) do
        if not room.ready_players[player.id] then
            all_ready = false
            break
        end
    end
    
    if all_ready then
        -- 所有玩家准备就绪,可以开始游戏
        room.state = match_def.STATE.READY
        for _, player in ipairs(room.players) do
            local ok, err = pcall(function()
                skynet.call(player.data.agent, "lua", "game_start", room)
            end)
            if not ok then
                log.error("Failed to start game for player:", player.id, "error:", err)
            end
        end
        log.info("All players ready, start game in room:", room.id)
    end
    
    return true
end

-- 获取匹配信息
function match.get_match_info(player_id)
    return player_matches[player_id]
end

-- 获取房间信息
function match.get_room_info(room_id)
    return match_rooms[room_id]
end

-- 获取匹配统计
function match.get_match_stats()
    return match_stats
end

-- 启动服务
skynet.start(function()
    -- 初始化统计
    init_stats()
    
    -- 启动匹配定时器
    skynet.fork(function()
        while true do
            for match_type, _ in pairs(match_queues) do
                try_match(match_type)
            end
            skynet.sleep(300)
        end
    end)
    
    -- 启动超时检查定时器
    skynet.fork(function()
        while true do
            check_match_timeout()
            skynet.sleep(10 * 100)  -- 每10秒检查一次
        end
    end)
    
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = match[cmd]
        if f then
            local ok, err, errmsg = pcall(f, ...)
            if not ok then
                log.error("Match service error:", err)
                skynet.ret(skynet.pack(false, 1000, "服务内部错误"))
            else
                skynet.ret(skynet.pack(err, errmsg))
            end
        else
            log.error("Unknown command:", cmd)
            skynet.ret(skynet.pack(false, 1000, "未知命令"))
        end
    end)
end)

return match
