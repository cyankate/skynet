local skynet = require "skynet"
local class = require "utils.class"
local log = require "log"
local tableUtils = require "utils.tableUtils"

local landlord_room = class("landlord_room")

-- 房间状态
local ROOM_STATUS = {
    WAITING = 0,  -- 等待中
    PLAYING = 1,  -- 游戏中
    FINISHED = 2, -- 已结束
}

-- 玩家状态
local PLAYER_STATUS = {
    WAITING = 0,  -- 等待中
    READY = 1,    -- 已准备
    PLAYING = 2,  -- 游戏中
    OFFLINE = 3,  -- 离线
}

function landlord_room:ctor(room_id, creator_id)
    self.room_id = room_id
    self.creator_id = creator_id
    self.status = ROOM_STATUS.WAITING
    self.players = {}  -- {player_id = {status = PLAYER_STATUS, cards = {}, ready = false}}
    self.current_player = nil  -- 当前出牌玩家
    self.last_cards = nil      -- 上一次出的牌
    self.last_player = nil     -- 上一次出牌的玩家
    self.landlord = nil        -- 地主玩家ID
    self.landlord_cards = {}   -- 地主牌
    self.create_time = os.time()
    self.update_time = os.time()
end

-- 添加玩家
function landlord_room:add_player(player_id)
    if #self.players >= 3 then
        log.error("room %d is full when player %d try to join", self.room_id, player_id)
        return false, "房间已满"
    end
    
    if self.players[player_id] then
        log.error("player %d already in room %d", player_id, self.room_id)
        return false, "玩家已在房间中"
    end
    
    self.players[player_id] = {
        status = PLAYER_STATUS.WAITING,
        cards = {},
        ready = false
    }
    
    -- 广播玩家加入通知
    self:broadcast("landlord_join_notify", {
        room_id = self.room_id,
        player_id = player_id,
        players = self:get_players_info()
    })
    
    log.info("player %d joined room %d", player_id, self.room_id)
    return true
end

-- 移除玩家
function landlord_room:remove_player(player_id)
    if not self.players[player_id] then
        log.error("player %d not in room %d", player_id, self.room_id)
        return false, "玩家不在房间中"
    end
    
    -- 广播玩家离开通知
    self:broadcast("landlord_leave_notify", {
        room_id = self.room_id,
        player_id = player_id,
        players = self:get_players_info()
    })
    
    self.players[player_id] = nil
    
    -- 如果房间空了,删除房间
    if not next(self.players) then
        log.info("room %d is empty after player %d left", self.room_id, player_id)
        return true, "room_empty"
    end
    
    -- 如果房主离开,转移房主
    if player_id == self.creator_id then
        for pid, _ in pairs(self.players) do
            self.creator_id = pid
            log.info("room %d creator changed from %d to %d", self.room_id, player_id, pid)
            break
        end
    end
    
    log.info("player %d left room %d", player_id, self.room_id)
    return true
end

-- 玩家准备
function landlord_room:player_ready(player_id)
    if not self.players[player_id] then
        log.error("player %d not in room %d", player_id, self.room_id)
        return false, "玩家不在房间中"
    end
    
    self.players[player_id].ready = true
    
    -- 广播玩家准备通知
    self:broadcast("landlord_ready_notify", {
        room_id = self.room_id,
        player_id = player_id,
        players = self:get_players_info()
    })
    
    log.info("player %d ready in room %d", player_id, self.room_id)
    
    -- 检查是否所有玩家都准备好了
    local all_ready = true
    for _, player in pairs(self.players) do
        if not player.ready then
            all_ready = false
            break
        end
    end
    if all_ready and tableUtils.table_size(self.players) == 3 then
        self:start_game()
    end
    
    return true
end

-- 开始游戏
function landlord_room:start_game()
    self.status = ROOM_STATUS.PLAYING
    
    -- 初始化玩家状态
    for _, player in pairs(self.players) do
        player.status = PLAYER_STATUS.PLAYING
        player.cards = self:deal_cards()
    end
    
    -- 发地主牌
    self.landlord_cards = self:deal_landlord_cards()
    
    -- 随机选择地主
    local player_ids = {}
    for pid, _ in pairs(self.players) do
        table.insert(player_ids, pid)
    end
    self.landlord = player_ids[math.random(1, #player_ids)]
    
    -- 地主获得地主牌
    for _, card in ipairs(self.landlord_cards) do
        table.insert(self.players[self.landlord].cards, card)
    end
    
    -- 地主先出牌
    self.current_player = self.landlord
    
    -- 给每个玩家发送游戏开始通知（包含他自己的手牌）
    for player_id, player in pairs(self.players) do
        protocol_handler.send_to_player(player_id, "landlord_game_start_notify", {
        room_id = self.room_id,
        players = self:get_players_info(),
        cards = player.cards,
        landlord_id = self.landlord,
        bottom_cards = self.landlord_cards,
        current_player = self.current_player,
        })
    end
    log.info("Game started in room %d", self.room_id)
end

-- 发牌
function landlord_room:deal_cards()
    -- 生成所有牌
    local all_cards = self:generate_cards()
    -- 洗牌
    self:shuffle_cards(all_cards)
    
    -- 每个玩家17张牌
    local cards = {}
    for i = 1, 17 do
        table.insert(cards, table.remove(all_cards, 1))
    end
    
    -- 保存剩余的牌用于发地主牌
    self.remaining_cards = all_cards
    
    return cards
end

-- 发地主牌
function landlord_room:deal_landlord_cards()
    -- 使用剩余的牌发地主牌
    local cards = {}
    for i = 1, 3 do
        table.insert(cards, table.remove(self.remaining_cards, 1))
    end
    
    -- 清理剩余牌
    self.remaining_cards = nil
    
    return cards
end

-- 洗牌函数
function landlord_room:shuffle_cards(cards)
    local n = #cards
    for i = n, 2, -1 do
        local j = math.random(i)
        cards[i], cards[j] = cards[j], cards[i]
    end
end

-- 生成所有牌
function landlord_room:generate_cards()
    local cards = {}
    local suits = {"♠", "♥", "♣", "♦"}
    local values = {"3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A", "2"}
    
    -- 生成普通牌
    for _, suit in ipairs(suits) do
        for _, value in ipairs(values) do
            table.insert(cards, suit .. value)
        end
    end
    
    -- 添加大小王
    table.insert(cards, "小王")
    table.insert(cards, "大王")
    
    return cards
end

-- 出牌
function landlord_room:play_cards(player_id, cards)
    if not self.players[player_id] then
        log.error("player %d not in room %d", player_id, self.room_id)
        return false, "玩家不在房间中"
    end
    
    if player_id ~= self.current_player then
        log.error("not player %d's turn in room %d, current player is %d", player_id, self.room_id, self.current_player)
        return false, "还没到你的回合"
    end
    
    -- 检查牌是否合法
    if not self:is_valid_cards(cards) then
        log.error("invalid cards %s from player %d in room %d", table.concat(cards, ","), player_id, self.room_id)
        return false, "出牌不合法"
    end
    
    -- 检查是否大于上家
    if self.last_cards and not self:is_bigger_cards(cards, self.last_cards) then
        log.error("cards %s from player %d not bigger than last cards %s in room %d", 
            table.concat(cards, ","), player_id, table.concat(self.last_cards, ","), self.room_id)
        return false, "必须大于上家的牌"
    end
    
    -- 检查玩家是否有这些牌
    for _, card in ipairs(cards) do
        local has_card = false
        for i, player_card in ipairs(self.players[player_id].cards) do
            if player_card == card then
                has_card = true
                break
            end
        end
        if not has_card then
            log.error("player %d doesn't have card %s in room %d", player_id, card, self.room_id)
            return false, "没有这张牌"
        end
    end
    
    -- 移除玩家出的牌
    for _, card in ipairs(cards) do
        for i, player_card in ipairs(self.players[player_id].cards) do
            if player_card == card then
                table.remove(self.players[player_id].cards, i)
                break
            end
        end
    end
    
    -- 更新状态
    self.last_cards = cards
    self.last_player = player_id
    
    -- 计算下一个玩家
    local next_player = self:get_next_player(player_id)
    self.current_player = next_player
    
    -- 广播出牌通知
    self:broadcast("landlord_play_cards_notify", {
        room_id = self.room_id,
        player_id = player_id,
        cards = cards,
        next_player_id = next_player
    })
    
    log.info("player %d played cards %s in room %d, next player is %d", 
        player_id, table.concat(cards, ","), self.room_id, next_player)
    
    -- 检查是否游戏结束
    if #self.players[player_id].cards == 0 then
        self:game_over(player_id)
    end
    
    return true
end

-- 检查牌是否合法
function landlord_room:is_valid_cards(cards)
    -- TODO: 实现牌型判断
    return true
end

-- 检查是否大于上家
function landlord_room:is_bigger_cards(cards1, cards2)
    -- TODO: 实现牌型大小比较
    return true
end

-- 下一个玩家
function landlord_room:next_player()
    local player_ids = {}
    for pid, _ in pairs(self.players) do
        table.insert(player_ids, pid)
    end
    
    -- 找到当前玩家的位置
    local current_index = 1
    for i, pid in ipairs(player_ids) do
        if pid == self.current_player then
            current_index = i
            break
        end
    end
    
    -- 设置下一个玩家
    current_index = current_index % #player_ids + 1
    self.current_player = player_ids[current_index]
end

-- 玩家掉线
function landlord_room:player_offline(player_id)
    if not self.players[player_id] then
        log.error("player %d not in room %d", player_id, self.room_id)
        return false, "玩家不在房间中"
    end
    
    -- 更新玩家状态
    self.players[player_id].status = PLAYER_STATUS.OFFLINE
    
    -- 广播玩家掉线通知
    self:broadcast("landlord_player_offline_notify", {
        room_id = self.room_id,
        player_id = player_id,
        players = self:get_players_info()
    })
    
    log.info("player %d offline in room %d", player_id, self.room_id)
    
    -- 如果是游戏中掉线，检查是否所有人都掉线了
    if self.status == ROOM_STATUS.PLAYING then
        local all_offline = true
        for _, player in pairs(self.players) do
            if player.status ~= PLAYER_STATUS.OFFLINE then
                all_offline = false
                break
            end
        end
        
        -- 如果所有人都掉线了，结束游戏
        if all_offline then
            log.info("all players offline in room %d, game over", self.room_id)
            self:game_over(nil)  -- 没有胜利者
        end
    end
    
    return true
end

-- 玩家重连
function landlord_room:player_reconnect(player_id)
    if not self.players[player_id] then
        log.error("player %d not in room %d", player_id, self.room_id)
        return false, "玩家不在房间中"
    end
    
    -- 更新玩家状态
    self.players[player_id].status = PLAYER_STATUS.PLAYING
    
    -- 广播玩家重连通知
    self:broadcast("landlord_player_reconnect_notify", {
        room_id = self.room_id,
        player_id = player_id,
        players = self:get_players_info()
    })
    
    log.info("player %d reconnected in room %d", player_id, self.room_id)
    
    self:broadcast("landlord_game_state_notify", {
        room_id = self.room_id,
        status = self.status,
        players = self:get_players_info(),
        cards = self.players[player_id].cards,
        landlord_id = self.landlord,
        bottom_cards = self.landlord_cards,
        current_player = self.current_player,
        last_cards = self.last_cards,
        last_player = self.last_player
    })
    
    return true
end

-- 游戏结束
function landlord_room:game_over(winner_id)
    self.status = ROOM_STATUS.FINISHED
    
    -- 计算分数
    local score = 100  -- 基础分
    if winner_id and winner_id == self.landlord then
        score = score * 2  -- 地主赢双倍
    end
    
    -- 广播游戏结束通知
    self:broadcast("landlord_game_over_notify", {
        room_id = self.room_id,
        winner_id = winner_id,
        players = self:get_players_info(),
        score = score
    })
    log.info("Game ended in room %d", self.room_id)
end

-- 获取房间信息
function landlord_room:get_info()
    return {
        room_id = self.room_id,
        creator_id = self.creator_id,
        status = self.status,
        players = self.players,
        current_player = self.current_player,
        last_cards = self.last_cards,
        last_player = self.last_player,
        landlord = self.landlord,
        landlord_cards = self.landlord_cards,
        create_time = self.create_time,
        update_time = self.update_time
    }
end

-- 获取玩家信息
function landlord_room:get_players_info()
    local info = {}
    for player_id, player in pairs(self.players) do
        table.insert(info, {
            player_id = player_id,
            ready = player.ready,
            seat = self:get_player_seat(player_id),
            cards_count = #player.cards
        })
    end
    return info
end

-- 获取玩家座位号
function landlord_room:get_player_seat(player_id)
    -- 将玩家ID按加入顺序排序
    local player_list = {}
    for pid, _ in pairs(self.players) do
        table.insert(player_list, pid)
    end
    table.sort(player_list)
    
    -- 找到玩家的位置
    for i, pid in ipairs(player_list) do
        if pid == player_id then
            return i
        end
    end
    return 0
end

-- 获取下一个玩家
function landlord_room:get_next_player(current_player_id)
    local player_list = {}
    for pid, _ in pairs(self.players) do
        table.insert(player_list, pid)
    end
    table.sort(player_list)
    
    -- 找到当前玩家的位置
    local current_index = 1
    for i, pid in ipairs(player_list) do
        if pid == current_player_id then
            current_index = i
            break
        end
    end
    
    -- 返回下一个玩家
    current_index = current_index % #player_list + 1
    return player_list[current_index]
end

-- 广播消息
function landlord_room:broadcast(name, data)
    local player_list = {}
    for player_id, _ in pairs(self.players) do
        table.insert(player_list, player_id)
    end
    protocol_handler.send_to_players(player_list, name, data)
end

return landlord_room 