local skynet = require "skynet"
local Entity = require "scene.entity"
local class = require "utils.class"
local log = require "log"

local NPCEntity = class("NPCEntity", Entity)

-- NPC类型
local NPC_TYPE = {
    QUEST = 1,     -- 任务NPC
    SHOP = 2,      -- 商店NPC
    STORAGE = 3,   -- 仓库NPC
    TRANSPORT = 4, -- 传送NPC
}

function NPCEntity:ctor(id, npc_data)
    NPCEntity.super.ctor(self, id, Entity.ENTITY_TYPE.NPC)
    
    -- NPC属性
    self.name = npc_data.name
    self.npc_type = npc_data.npc_type
    self.interact_range = npc_data.interact_range or 50
    self.dialog = npc_data.dialog or {}
    self.quests = npc_data.quests or {}
    self.shop_items = npc_data.shop_items or {}
    self.transport_points = npc_data.transport_points or {}
    
    -- 设置NPC视野范围
    self.view_range = 100
end

-- 当玩家进入视野
function NPCEntity:on_entity_enter(other)
    if other.type == Entity.ENTITY_TYPE.PLAYER then
        -- 发送NPC信息给玩家
        other:send_message("npc_enter", {
            npc_id = self.id,
            name = self.name,
            npc_type = self.npc_type,
            x = self.x,
            y = self.y
        })
    end
end

-- 当玩家离开视野
function NPCEntity:on_entity_leave(other)
    if other.type == Entity.ENTITY_TYPE.PLAYER then
        other:send_message("npc_leave", {
            npc_id = self.id
        })
    end
end

-- 处理玩家交互
function NPCEntity:handle_interact(player)
    -- 检查交互距离
    local dx = player.x - self.x
    local dy = player.y - self.y
    local distance = math.sqrt(dx * dx + dy * dy)
    
    if distance > self.interact_range then
        return false, "距离太远"
    end
    
    -- 根据NPC类型处理交互
    if self.npc_type == NPC_TYPE.QUEST then
        return self:handle_quest_interact(player)
    elseif self.npc_type == NPC_TYPE.SHOP then
        return self:handle_shop_interact(player)
    elseif self.npc_type == NPC_TYPE.STORAGE then
        return self:handle_storage_interact(player)
    elseif self.npc_type == NPC_TYPE.TRANSPORT then
        return self:handle_transport_interact(player)
    end
    
    return false, "无法与该NPC交互"
end

-- 处理任务交互
function NPCEntity:handle_quest_interact(player)
    local available_quests = {}
    local in_progress_quests = {}
    local completed_quests = {}
    
    -- 检查每个任务的状态
    for _, quest in pairs(self.quests) do
        local quest_status = player:get_quest_status(quest.id)
        
        if not quest_status then
            -- 检查是否可接任务
            if self:can_accept_quest(player, quest) then
                table.insert(available_quests, quest)
            end
        elseif quest_status == "in_progress" then
            -- 检查是否可完成任务
            if self:can_complete_quest(player, quest) then
                table.insert(completed_quests, quest)
            else
                table.insert(in_progress_quests, quest)
            end
        end
    end
    
    -- 发送任务列表给玩家
    player:send_message("npc_quest_list", {
        npc_id = self.id,
        available_quests = available_quests,
        in_progress_quests = in_progress_quests,
        completed_quests = completed_quests
    })
    
    return true
end

-- 检查是否可接任务
function NPCEntity:can_accept_quest(player, quest)
    -- 检查等级要求
    if quest.require_level and player.level < quest.require_level then
        return false
    end
    
    -- 检查职业要求
    if quest.require_profession and player.profession ~= quest.require_profession then
        return false
    end
    
    -- 检查前置任务
    if quest.require_quests then
        for _, require_quest_id in ipairs(quest.require_quests) do
            if player:get_quest_status(require_quest_id) ~= "completed" then
                return false
            end
        end
    end
    
    return true
end

-- 检查是否可完成任务
function NPCEntity:can_complete_quest(player, quest)
    -- 检查任务条件
    for _, condition in ipairs(quest.conditions) do
        if not player:check_quest_condition(condition) then
            return false
        end
    end
    
    return true
end

-- 处理商店交互
function NPCEntity:handle_shop_interact(player)
    -- 发送商店物品列表给玩家
    player:send_message("npc_shop_list", {
        npc_id = self.id,
        shop_items = self.shop_items
    })
    
    return true
end

-- 处理仓库交互
function NPCEntity:handle_storage_interact(player)
    -- 发送仓库物品列表给玩家
    local storage = player:get_storage()
    player:send_message("npc_storage_list", {
        npc_id = self.id,
        storage_items = storage
    })
    
    return true
end

-- 处理传送交互
function NPCEntity:handle_transport_interact(player)
    -- 发送传送点列表给玩家
    player:send_message("npc_transport_list", {
        npc_id = self.id,
        transport_points = self.transport_points
    })
    
    return true
end

-- 处理购买物品
function NPCEntity:handle_buy_item(player, item_id, count)
    if self.npc_type ~= NPC_TYPE.SHOP then
        return false, "该NPC不是商人"
    end
    
    -- 查找商品
    local shop_item = nil
    for _, item in ipairs(self.shop_items) do
        if item.id == item_id then
            shop_item = item
            break
        end
    end
    
    if not shop_item then
        return false, "商品不存在"
    end
    
    -- 检查金钱
    local total_price = shop_item.price * count
    if player:get_money() < total_price then
        return false, "金钱不足"
    end
    
    -- 检查背包空间
    if not player:check_bag_space(item_id, count) then
        return false, "背包空间不足"
    end
    
    -- 扣除金钱
    player:remove_money(total_price)
    
    -- 添加物品
    player:add_item(item_id, count)
    
    return true
end

-- 处理出售物品
function NPCEntity:handle_sell_item(player, bag_slot, count)
    if self.npc_type ~= NPC_TYPE.SHOP then
        return false, "该NPC不是商人"
    end
    
    -- 获取物品信息
    local item = player:get_bag_item(bag_slot)
    if not item then
        return false, "物品不存在"
    end
    
    if item.count < count then
        return false, "物品数量不足"
    end
    
    -- 计算出售价格
    local sell_price = math.floor(item.price * 0.3) * count  -- 假设出售价为原价的30%
    
    -- 移除物品
    player:remove_item(bag_slot, count)
    
    -- 添加金钱
    player:add_money(sell_price)
    
    return true
end

-- 处理传送
function NPCEntity:handle_transport(player, point_id)
    if self.npc_type ~= NPC_TYPE.TRANSPORT then
        return false, "该NPC不是传送员"
    end
    
    -- 查找传送点
    local transport_point = nil
    for _, point in ipairs(self.transport_points) do
        if point.id == point_id then
            transport_point = point
            break
        end
    end
    
    if not transport_point then
        return false, "传送点不存在"
    end
    
    -- 检查金钱
    if player:get_money() < transport_point.price then
        return false, "金钱不足"
    end
    
    -- 扣除金钱
    player:remove_money(transport_point.price)
    
    -- 传送玩家
    player:transport(transport_point.scene_id, transport_point.x, transport_point.y)
    
    return true
end

NPCEntity.NPC_TYPE = NPC_TYPE
return NPCEntity