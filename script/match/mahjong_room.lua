local skynet = require "skynet"
local log = require "log"
local class = require "utils.class"
local Room = require "match.room"

local MahjongRoom = class("MahjongRoom", Room)

-- 麻将牌定义
local TILE_TYPE = {
    WAN = 1,    -- 万子
    TIAO = 2,   -- 条子
    TONG = 3,   -- 筒子
    FENG = 4,   -- 风牌
    JIAN = 5,   -- 箭牌
}

-- 风牌定义
local FENG_TILE = {
    DONG = 1,   -- 东
    NAN = 2,    -- 南
    XI = 3,     -- 西
    BEI = 4,    -- 北
}

-- 箭牌定义
local JIAN_TILE = {
    ZHONG = 1,  -- 中
    FA = 2,     -- 发
    BAI = 3,    -- 白
}

-- 牌型定义
local MELD_TYPE = {
    CHI = 1,    -- 吃
    PENG = 2,   -- 碰
    GANG = 3,   -- 杠
    HU = 4,     -- 胡
}

function MahjongRoom:ctor(room_id, owner_id)
    MahjongRoom.super.ctor(self, room_id, owner_id)
    self.current_player = nil  -- 当前玩家
    self.last_tile = nil       -- 最后一张牌
    self.last_action = nil     -- 最后动作
    self.last_action_player = nil  -- 最后动作玩家
    self.remaining_tiles = {}  -- 剩余牌堆
end

function MahjongRoom:get_max_players()
    return 4
end

function MahjongRoom:add_player(player_id)
    if not MahjongRoom.super.add_player(self, player_id) then
        return false
    end
    
    self.players[player_id].tiles = {}
    self.players[player_id].discarded = {}
    self.players[player_id].melds = {}
    return true
end

-- 添加玩家
function MahjongRoom:add_player(player_id)
    if #self.players >= 4 then
        return false, "房间已满"
    end
    
    if self.players[player_id] then
        return false, "玩家已在房间中"
    end
    
    self.players[player_id] = {
        ready = false,
        tiles = {},
        discarded = {},
        melds = {},  -- 吃碰杠
    }
    
    -- 广播玩家加入
    self:broadcast("player_join", {
        player_id = player_id,
        player_count = #self.players
    })
    
    return true
end

-- 移除玩家
function MahjongRoom:remove_player(player_id)
    if not self.players[player_id] then
        return false, "玩家不在房间中"
    end
    
    self.players[player_id] = nil
    
    -- 如果房间空了,返回特殊标记
    if #self.players == 0 then
        return true, "room_empty"
    end
    
    -- 如果房主离开,转移房主
    if player_id == self.creator_id then
        for pid, _ in pairs(self.players) do
            self.creator_id = pid
            break
        end
    end
    
    -- 广播玩家离开
    self:broadcast("player_leave", {
        player_id = player_id,
        player_count = #self.players,
        new_creator = self.creator_id
    })
    
    return true
end

-- 玩家准备
function MahjongRoom:player_ready(player_id)
    if not self.players[player_id] then
        return false, "玩家不在房间中"
    end
    
    if self.status ~= 0 then
        return false, "游戏已开始"
    end
    
    self.players[player_id].ready = true
    
    -- 广播准备状态
    self:broadcast("player_ready", {
        player_id = player_id
    })
    
    -- 检查是否所有玩家都准备好了
    local all_ready = true
    for _, player in pairs(self.players) do
        if not player.ready then
            all_ready = false
            break
        end
    end
    
    if all_ready and #self.players == 4 then
        self:start_game()
    end
    
    return true
end

-- 开始游戏
function MahjongRoom:start_game()
    self.status = 1
    
    -- 初始化牌堆
    self.remaining_tiles = self:init_tiles()
    
    -- 发牌
    for player_id, player in pairs(self.players) do
        player.tiles = {}
        for i = 1, 13 do
            table.insert(player.tiles, table.remove(self.remaining_tiles))
        end
    end
    
    -- 设置当前玩家为东家
    self.current_player = self.creator_id
    
    -- 广播游戏开始
    self:broadcast("mahjong_game_start_notify", {
        room_id = self.room_id,
        players = self:get_players_info()
    })
end

-- 初始化牌堆
function MahjongRoom:init_tiles()
    local tiles = {}
    
    -- 添加数牌(万、条、筒)
    for _, type in ipairs({TILE_TYPE.WAN, TILE_TYPE.TIAO, TILE_TYPE.TONG}) do
        for i = 1, 9 do
            for _ = 1, 4 do
                table.insert(tiles, {type = type, value = i})
            end
        end
    end
    
    -- 添加风牌
    for _, value in ipairs({FENG_TILE.DONG, FENG_TILE.NAN, FENG_TILE.XI, FENG_TILE.BEI}) do
        for _ = 1, 4 do
            table.insert(tiles, {type = TILE_TYPE.FENG, value = value})
        end
    end
    
    -- 添加箭牌
    for _, value in ipairs({JIAN_TILE.ZHONG, JIAN_TILE.FA, JIAN_TILE.BAI}) do
        for _ = 1, 4 do
            table.insert(tiles, {type = TILE_TYPE.JIAN, value = value})
        end
    end
    
    -- 洗牌
    for i = #tiles, 2, -1 do
        local j = math.random(i)
        tiles[i], tiles[j] = tiles[j], tiles[i]
    end
    
    return tiles
end

-- 摸牌
function MahjongRoom:draw_tile(player_id)
    if not self.players[player_id] then
        return false, "玩家不在房间中"
    end
    
    if self.status ~= 1 then
        return false, "游戏未开始"
    end
    
    if player_id ~= self.current_player then
        return false, "不是你的回合"
    end
    
    -- 检查牌堆是否为空
    if #self.remaining_tiles == 0 then
        -- 流局
        self:game_over(nil)
        return false, "牌堆已空,流局"
    end
    
    -- 摸牌
    local tile = table.remove(self.remaining_tiles)
    table.insert(self.players[player_id].tiles, tile)
    
    -- 广播摸牌
    self:broadcast("mahjong_draw_tile_notify", {
        room_id = self.room_id,
        player_id = player_id,
        tile_type = tile.type,
        tile_value = tile.value,
        remaining_count = #self.remaining_tiles
    })
    
    return true, tile
end

-- 出牌
function MahjongRoom:play_tile(player_id, tile)
    if not self.players[player_id] then
        return false, "玩家不在房间中"
    end
    
    if self.status ~= 1 then
        return false, "游戏未开始"
    end
    
    if player_id ~= self.current_player then
        return false, "不是你的回合"
    end
    
    -- 检查牌是否在玩家手中
    local tile_index = nil
    for i, t in ipairs(self.players[player_id].tiles) do
        if t.type == tile.type and t.value == tile.value then
            tile_index = i
            break
        end
    end
    
    if not tile_index then
        return false, "没有这张牌"
    end
    
    -- 移除牌
    table.remove(self.players[player_id].tiles, tile_index)
    table.insert(self.players[player_id].discarded, tile)
    
    -- 记录最后一张牌
    self.last_tile = tile
    self.last_action = "play"
    self.last_action_player = player_id
    
    -- 广播出牌
    self:broadcast("mahjong_play_tile_notify", {
        room_id = self.room_id,
        player_id = player_id,
        tile_type = tile.type,
        tile_value = tile.value,
        next_player_id = self.current_player
    })
    
    -- 检查其他玩家是否可以吃碰杠胡
    local can_act = false
    local next_player = nil
    
    -- 按逆时针顺序检查
    local player_ids = {}
    for pid, _ in pairs(self.players) do
        table.insert(player_ids, pid)
    end
    
    local current_index = 1
    for i, pid in ipairs(player_ids) do
        if pid == player_id then
            current_index = i
            break
        end
    end
    
    -- 从下家开始检查
    for i = 1, #player_ids do
        local check_index = (current_index + i - 1) % #player_ids + 1
        local check_player = player_ids[check_index]
        
        if check_player ~= player_id then
            -- 检查是否可以胡
            if self:can_hu(check_player, tile) then
                can_act = true
                break
            end
            
            -- 检查是否可以杠
            if self:can_gang(check_player, tile) then
                can_act = true
                break
            end
            
            -- 检查是否可以碰
            if self:can_peng(check_player, tile) then
                can_act = true
                break
            end
            
            -- 检查是否可以吃(只有下家可以吃)
            if i == 1 and self:can_chi(check_player, tile) then
                can_act = true
                break
            end
        end
    end
    
    if not can_act then
        -- 轮到下一个玩家
        next_player = player_ids[current_index % #player_ids + 1]
        self.current_player = next_player
        
        -- 广播回合变更
        self:broadcast("turn_change", {
            player_id = self.current_player
        })
    end
    
    return true
end

-- 获取房间信息
function MahjongRoom:get_info()
    return {
        room_id = self.room_id,
        creator_id = self.creator_id,
        status = self.status,
        players = self:get_players_info(),
        current_player = self.current_player,
        last_tile = self.last_tile,
        last_action = self.last_action,
        last_action_player = self.last_action_player
    }
end

-- 获取玩家信息
function MahjongRoom:get_players_info()
    local info = {}
    for pid, player in pairs(self.players) do
        info[pid] = {
            ready = player.ready,
            tile_count = #player.tiles,
            discarded = player.discarded,
            melds = player.melds
        }
    end
    return info
end

-- 广播消息
function MahjongRoom:broadcast(msg_type, data)
    for pid, _ in pairs(self.players) do
        skynet.send(pid, "lua", "send_msg", msg_type, data)
    end
end

-- 检查是否可以吃牌
function MahjongRoom:can_chi(player_id, tile)
    if not self.players[player_id] then
        return false, "玩家不在房间中"
    end
    
    if self.status ~= 1 then
        return false, "游戏未开始"
    end
    
    -- 只有下家可以吃牌
    local player_ids = {}
    for pid, _ in pairs(self.players) do
        table.insert(player_ids, pid)
    end
    
    local current_index = 1
    for i, pid in ipairs(player_ids) do
        if pid == self.last_action_player then
            current_index = i
            break
        end
    end
    
    local next_index = current_index % #player_ids + 1
    if player_ids[next_index] ~= player_id then
        return false, "只有下家可以吃牌"
    end
    
    -- 检查是否是数牌
    if tile.type == TILE_TYPE.FENG or tile.type == TILE_TYPE.JIAN then
        return false, "风牌和箭牌不能吃"
    end
    
    -- 检查是否有可以吃的组合
    local player = self.players[player_id]
    local tiles = player.tiles
    
    -- 检查是否有连续的三张牌
    for i = 1, #tiles - 1 do
        for j = i + 1, #tiles do
            if tiles[i].type == tile.type and tiles[j].type == tile.type then
                local values = {tiles[i].value, tiles[j].value, tile.value}
                table.sort(values)
                if values[2] - values[1] == 1 and values[3] - values[2] == 1 then
                    return true, {tiles[i], tiles[j], tile}
                end
            end
        end
    end
    
    return false, "没有可以吃的组合"
end

-- 检查是否可以碰牌
function MahjongRoom:can_peng(player_id, tile)
    if not self.players[player_id] then
        return false, "玩家不在房间中"
    end
    
    if self.status ~= 1 then
        return false, "游戏未开始"
    end
    
    -- 检查是否有两张相同的牌
    local player = self.players[player_id]
    local count = 0
    for _, t in ipairs(player.tiles) do
        if t.type == tile.type and t.value == tile.value then
            count = count + 1
        end
    end
    
    if count >= 2 then
        return true
    end
    
    return false, "没有可以碰的牌"
end

-- 检查是否可以杠牌
function MahjongRoom:can_gang(player_id, tile)
    if not self.players[player_id] then
        return false, "玩家不在房间中"
    end
    
    if self.status ~= 1 then
        return false, "游戏未开始"
    end
    
    -- 检查是否有三张相同的牌
    local player = self.players[player_id]
    local count = 0
    for _, t in ipairs(player.tiles) do
        if t.type == tile.type and t.value == tile.value then
            count = count + 1
        end
    end
    
    if count >= 3 then
        return true
    end
    
    return false, "没有可以杠的牌"
end

-- 检查是否可以胡牌
function MahjongRoom:can_hu(player_id, tile)
    if not self.players[player_id] then
        return false, "玩家不在房间中"
    end
    
    if self.status ~= 1 then
        return false, "游戏未开始"
    end
    
    -- 复制玩家手牌
    local player = self.players[player_id]
    local tiles = {}
    for _, t in ipairs(player.tiles) do
        table.insert(tiles, {type = t.type, value = t.value})
    end
    table.insert(tiles, {type = tile.type, value = tile.value})
    
    -- 检查胡牌
    return self:check_hu(tiles)
end

-- 检查胡牌
function MahjongRoom:check_hu(tiles)
    -- 复制牌组
    local t = {}
    for _, tile in ipairs(tiles) do
        table.insert(t, {type = tile.type, value = tile.value})
    end
    
    -- 按类型和值排序
    table.sort(t, function(a, b)
        if a.type ~= b.type then
            return a.type < b.type
        end
        return a.value < b.value
    end)
    
    -- 检查是否胡牌
    return self:check_hu_recursive(t)
end

-- 递归检查胡牌
function MahjongRoom:check_hu_recursive(tiles)
    if #tiles == 0 then
        return true
    end
    
    -- 尝试作为对子
    if #tiles >= 2 and tiles[1].type == tiles[2].type and tiles[1].value == tiles[2].value then
        local t = {}
        for i = 3, #tiles do
            table.insert(t, tiles[i])
        end
        if self:check_hu_recursive(t) then
            return true
        end
    end
    
    -- 尝试作为刻子
    if #tiles >= 3 and tiles[1].type == tiles[2].type and tiles[1].value == tiles[2].value
        and tiles[2].type == tiles[3].type and tiles[2].value == tiles[3].value then
        local t = {}
        for i = 4, #tiles do
            table.insert(t, tiles[i])
        end
        if self:check_hu_recursive(t) then
            return true
        end
    end
    
    -- 尝试作为顺子
    if #tiles >= 3 and tiles[1].type == tiles[2].type and tiles[1].type == tiles[3].type
        and tiles[1].type ~= TILE_TYPE.FENG and tiles[1].type ~= TILE_TYPE.JIAN then
        local v1, v2, v3 = tiles[1].value, tiles[2].value, tiles[3].value
        if v2 - v1 == 1 and v3 - v2 == 1 then
            local t = {}
            for i = 4, #tiles do
                table.insert(t, tiles[i])
            end
            if self:check_hu_recursive(t) then
                return true
            end
        end
    end
    
    return false
end

-- 吃牌
function MahjongRoom:chi_tile(player_id, tiles)
    local ok, result = self:can_chi(player_id, self.last_tile)
    if not ok then
        return false, result
    end
    
    -- 移除玩家手牌
    local player = self.players[player_id]
    for _, tile in ipairs(result) do
        for i, t in ipairs(player.tiles) do
            if t.type == tile.type and t.value == tile.value then
                table.remove(player.tiles, i)
                break
            end
        end
    end
    
    -- 添加吃牌组合
    table.insert(player.melds, {
        type = MELD_TYPE.CHI,
        tiles = result
    })
    
    -- 设置当前玩家
    self.current_player = player_id
    
    -- 广播吃牌
    self:broadcast("mahjong_chi_tile_notify", {
        room_id = self.room_id,
        player_id = player_id,
        tiles = result,
        next_player_id = self.current_player
    })
    
    return true
end

-- 碰牌
function MahjongRoom:peng_tile(player_id)
    local ok, _ = self:can_peng(player_id, self.last_tile)
    if not ok then
        return false, "不能碰牌"
    end
    
    -- 移除玩家手牌
    local player = self.players[player_id]
    local count = 0
    for i = #player.tiles, 1, -1 do
        if player.tiles[i].type == self.last_tile.type and player.tiles[i].value == self.last_tile.value then
            table.remove(player.tiles, i)
            count = count + 1
            if count == 2 then
                break
            end
        end
    end
    
    -- 添加碰牌组合
    table.insert(player.melds, {
        type = MELD_TYPE.PENG,
        tiles = {self.last_tile, self.last_tile, self.last_tile}
    })
    
    -- 设置当前玩家
    self.current_player = player_id
    
    -- 广播碰牌
    self:broadcast("mahjong_peng_tile_notify", {
        room_id = self.room_id,
        player_id = player_id,
        tile_type = self.last_tile.type,
        tile_value = self.last_tile.value,
        next_player_id = self.current_player
    })
    
    return true
end

-- 杠牌
function MahjongRoom:gang_tile(player_id, tile)
    local ok, _ = self:can_gang(player_id, tile)
    if not ok then
        return false, "不能杠牌"
    end
    
    -- 移除玩家手牌
    local player = self.players[player_id]
    local count = 0
    for i = #player.tiles, 1, -1 do
        if player.tiles[i].type == tile.type and player.tiles[i].value == tile.value then
            table.remove(player.tiles, i)
            count = count + 1
            if count == 3 then
                break
            end
        end
    end
    
    -- 添加杠牌组合
    table.insert(player.melds, {
        type = MELD_TYPE.GANG,
        tiles = {tile, tile, tile, tile}
    })
    
    -- 设置当前玩家
    self.current_player = player_id
    
    -- 广播杠牌
    self:broadcast("mahjong_gang_tile_notify", {
        room_id = self.room_id,
        player_id = player_id,
        tile_type = tile.type,
        tile_value = tile.value,
        next_player_id = self.current_player
    })
    
    return true
end

-- 胡牌
function MahjongRoom:hu_tile(player_id)
    local ok, _ = self:can_hu(player_id, self.last_tile)
    if not ok then
        return false, "不能胡牌"
    end
    
    -- 添加最后一张牌
    table.insert(self.players[player_id].tiles, self.last_tile)
    
    -- 计算分数
    local score = self:calculate_score(player_id)
    
    -- 广播胡牌
    self:broadcast("mahjong_hu_tile_notify", {
        room_id = self.room_id,
        player_id = player_id,
        win_type = self.last_action_player == player_id and 1 or 2,  -- 1:自摸 2:点炮
        score = score
    })
    
    -- 游戏结束
    self:game_over(player_id)
    
    return true
end

-- 计算分数
function MahjongRoom:calculate_score(player_id)
    local score = 0
    local player = self.players[player_id]
    
    -- 基本分
    score = score + 1
    
    -- 自摸加分
    if self.last_action_player == player_id then
        score = score + 1
    end
    
    -- 杠牌加分
    for _, meld in ipairs(player.melds) do
        if meld.type == MELD_TYPE.GANG then
            score = score + 2
        end
    end
    
    return score
end

-- 游戏结束
function MahjongRoom:game_over(winner_id)
    self.status = 0
    
    -- 重置所有玩家状态
    for pid, player in pairs(self.players) do
        player.ready = false
        player.tiles = {}
        player.discarded = {}
        player.melds = {}
    end
    
    -- 广播游戏结束
    self:broadcast("mahjong_game_over_notify", {
        room_id = self.room_id,
        winner_id = winner_id,
        players = self:get_players_info()
    })
end

-- 检查游戏状态
function MahjongRoom:check_game_state()
    -- 检查玩家数量
    if #self.players < 4 then
        return false, "玩家数量不足"
    end
    
    -- 检查是否所有玩家都准备好了
    for _, player in pairs(self.players) do
        if not player.ready then
            return false, "有玩家未准备"
        end
    end
    
    return true
end

-- 检查玩家状态
function MahjongRoom:check_player_state(player_id)
    if not self.players[player_id] then
        return false, "玩家不在房间中"
    end
    
    if self.status ~= 1 then
        return false, "游戏未开始"
    end
    
    if player_id ~= self.current_player then
        return false, "不是你的回合"
    end
    
    return true
end

-- 检查牌堆状态
function MahjongRoom:check_tiles_state()
    if #self.remaining_tiles == 0 then
        return false, "牌堆已空"
    end
    
    return true
end

-- 检查玩家手牌
function MahjongRoom:check_player_tiles(player_id)
    local player = self.players[player_id]
    if not player then
        return false, "玩家不在房间中"
    end
    
    if #player.tiles == 0 then
        return false, "玩家没有手牌"
    end
    
    return true
end

-- 检查玩家是否可以操作
function MahjongRoom:check_player_action(player_id, action_type)
    if not self.players[player_id] then
        return false, "玩家不在房间中"
    end
    
    if self.status ~= 1 then
        return false, "游戏未开始"
    end
    
    -- 检查是否是当前玩家
    if action_type == "play" and player_id ~= self.current_player then
        return false, "不是你的回合"
    end
    
    -- 检查是否有最后一张牌
    if action_type ~= "play" and not self.last_tile then
        return false, "没有可以操作的牌"
    end
    
    -- 检查是否是最后动作的玩家
    if action_type ~= "play" and player_id == self.last_action_player then
        return false, "不能操作自己打出的牌"
    end
    
    return true
end

-- 检查玩家是否可以吃碰杠胡
function MahjongRoom:check_player_meld(player_id, meld_type)
    if not self.players[player_id] then
        return false, "玩家不在房间中"
    end
    
    if self.status ~= 1 then
        return false, "游戏未开始"
    end
    
    if not self.last_tile then
        return false, "没有可以操作的牌"
    end
    
    if player_id == self.last_action_player then
        return false, "不能操作自己打出的牌"
    end
    
    -- 检查是否是下家
    if meld_type == MELD_TYPE.CHI then
        local player_ids = {}
        for pid, _ in pairs(self.players) do
            table.insert(player_ids, pid)
        end
        
        local current_index = 1
        for i, pid in ipairs(player_ids) do
            if pid == self.last_action_player then
                current_index = i
                break
            end
        end
        
        local next_index = current_index % #player_ids + 1
        if player_ids[next_index] ~= player_id then
            return false, "只有下家可以吃牌"
        end
    end
    
    return true
end

-- 获取玩家手牌数量
function MahjongRoom:get_player_tile_count(player_id)
    local player = self.players[player_id]
    if not player then
        return 0
    end
    
    return #player.tiles
end

-- 获取玩家弃牌数量
function MahjongRoom:get_player_discarded_count(player_id)
    local player = self.players[player_id]
    if not player then
        return 0
    end
    
    return #player.discarded
end

-- 获取玩家吃碰杠数量
function MahjongRoom:get_player_meld_count(player_id)
    local player = self.players[player_id]
    if not player then
        return 0
    end
    
    return #player.melds
end

-- 获取剩余牌堆数量
function MahjongRoom:get_remaining_tile_count()
    return #self.remaining_tiles
end

-- 获取玩家信息
function MahjongRoom:get_player_info(player_id)
    local player = self.players[player_id]
    if not player then
        return nil
    end
    
    return {
        ready = player.ready,
        tile_count = #player.tiles,
        discarded_count = #player.discarded,
        meld_count = #player.melds
    }
end

-- 获取房间信息
function MahjongRoom:get_room_info()
    return {
        room_id = self.room_id,
        creator_id = self.creator_id,
        status = self.status,
        current_player = self.current_player,
        remaining_tiles = #self.remaining_tiles,
        players = self:get_players_info()
    }
end

-- 获取玩家列表
function MahjongRoom:get_player_list()
    local players = {}
    for pid, _ in pairs(self.players) do
        table.insert(players, pid)
    end
    return players
end

-- 获取玩家数量
function MahjongRoom:get_player_count()
    return #self.players
end

-- 检查是否是房主
function MahjongRoom:is_creator(player_id)
    return player_id == self.creator_id
end

-- 检查是否是当前玩家
function MahjongRoom:is_current_player(player_id)
    return player_id == self.current_player
end

-- 检查是否是最后动作的玩家
function MahjongRoom:is_last_action_player(player_id)
    return player_id == self.last_action_player
end

-- 检查是否是下家
function MahjongRoom:is_next_player(player_id)
    local player_ids = {}
    for pid, _ in pairs(self.players) do
        table.insert(player_ids, pid)
    end
    
    local current_index = 1
    for i, pid in ipairs(player_ids) do
        if pid == self.last_action_player then
            current_index = i
            break
        end
    end
    
    local next_index = current_index % #player_ids + 1
    return player_ids[next_index] == player_id
end

-- 检查是否是上家
function MahjongRoom:is_prev_player(player_id)
    local player_ids = {}
    for pid, _ in pairs(self.players) do
        table.insert(player_ids, pid)
    end
    
    local current_index = 1
    for i, pid in ipairs(player_ids) do
        if pid == self.current_player then
            current_index = i
            break
        end
    end
    
    local prev_index = (current_index - 2) % #player_ids + 1
    return player_ids[prev_index] == player_id
end

return MahjongRoom 