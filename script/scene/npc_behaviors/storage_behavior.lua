local skynet = require "skynet"
local BaseBehavior = require "scene.npc_behaviors.base_behavior"
local class = require "utils.class"
local log = require "log"

-- 仓库功能行为
local StorageBehavior = class("StorageBehavior", BaseBehavior)

function StorageBehavior:ctor(npc, config)
    StorageBehavior.super.ctor(self, npc, config)
    self.behavior_name = "storage"
    self.storage_fee = config.storage_fee or 0  -- 存储费用
    self.max_slots = config.max_slots or 50     -- 最大槽位数
    self.storage_items = {}                     -- 存储的物品
    self:init()
end

function StorageBehavior:init()
    -- 初始化存储空间
    for i = 1, self.max_slots do
        self.storage_items[i] = nil
    end
end

function StorageBehavior:handle_interact(player)
    -- 发送仓库物品列表给玩家
    player:send_message("npc_storage_list", {
        npc_id = self.npc.id,
        storage_items = self.storage_items,
        max_slots = self.max_slots,
        storage_fee = self.storage_fee
    })
    
    return true
end

function StorageBehavior:handle_store_item(player, bag_slot, storage_slot)
    -- 获取背包物品
    local bag_item = player:get_bag_item(bag_slot)
    if not bag_item then
        return false, "背包物品不存在"
    end
    
    -- 检查存储槽位
    if storage_slot < 1 or storage_slot > self.max_slots then
        return false, "存储槽位无效"
    end
    
    if self.storage_items[storage_slot] then
        return false, "存储槽位已被占用"
    end
    
    -- 检查存储费用
    if self.storage_fee > 0 and player:get_money() < self.storage_fee then
        return false, "存储费用不足"
    end
    
    -- 扣除存储费用
    if self.storage_fee > 0 then
        player:remove_money(self.storage_fee)
    end
    
    -- 存储物品
    self.storage_items[storage_slot] = {
        id = bag_item.id,
        name = bag_item.name,
        count = bag_item.count,
        quality = bag_item.quality,
        attributes = bag_item.attributes,
        store_time = os.time()
    }
    
    -- 从背包移除物品
    player:remove_item(bag_slot, bag_item.count)
    
    log.info("玩家存储物品: %s x%d 到槽位 %d", bag_item.name, bag_item.count, storage_slot)
    return true
end

function StorageBehavior:handle_retrieve_item(player, storage_slot, bag_slot)
    -- 获取存储物品
    local storage_item = self.storage_items[storage_slot]
    if not storage_item then
        return false, "存储物品不存在"
    end
    
    -- 检查背包槽位
    if bag_slot < 1 or bag_slot > player:get_bag_size() then
        return false, "背包槽位无效"
    end
    
    local bag_item = player:get_bag_item(bag_slot)
    if bag_item and bag_item.id ~= storage_item.id then
        return false, "背包槽位已被其他物品占用"
    end
    
    -- 检查背包空间
    if not player:check_bag_space(storage_item.id, storage_item.count) then
        return false, "背包空间不足"
    end
    
    -- 取出物品
    if bag_item and bag_item.id == storage_item.id then
        -- 合并到现有物品
        player:add_item_count(bag_slot, storage_item.count)
    else
        -- 添加到新槽位
        player:add_item_to_slot(bag_slot, storage_item.id, storage_item.count, storage_item.attributes)
    end
    
    -- 从存储中移除
    self.storage_items[storage_slot] = nil
    
    log.info("玩家取出物品: %s x%d 从槽位 %d", storage_item.name, storage_item.count, storage_slot)
    return true
end

function StorageBehavior:handle_destroy_item(player, storage_slot)
    -- 获取存储物品
    local storage_item = self.storage_items[storage_slot]
    if not storage_item then
        return false, "存储物品不存在"
    end
    
    -- 销毁物品
    self.storage_items[storage_slot] = nil
    
    log.info("玩家销毁存储物品: %s x%d 从槽位 %d", storage_item.name, storage_item.count, storage_slot)
    return true
end

-- 设置存储费用
function StorageBehavior:set_storage_fee(fee)
    self.storage_fee = fee
    log.info("存储费用更新: %d", fee)
end

-- 扩展存储空间
function StorageBehavior:expand_storage(additional_slots)
    local old_max_slots = self.max_slots
    self.max_slots = self.max_slots + additional_slots
    
    -- 初始化新槽位
    for i = old_max_slots + 1, self.max_slots do
        self.storage_items[i] = nil
    end
    
    log.info("存储空间扩展: %d -> %d", old_max_slots, self.max_slots)
    return true
end

-- 获取存储统计信息
function StorageBehavior:get_storage_stats()
    local used_slots = 0
    local total_items = 0
    local total_value = 0
    
    for slot, item in pairs(self.storage_items) do
        if item then
            used_slots = used_slots + 1
            total_items = total_items + item.count
            total_value = total_value + (item.price or 0) * item.count
        end
    end
    
    return {
        max_slots = self.max_slots,
        used_slots = used_slots,
        free_slots = self.max_slots - used_slots,
        total_items = total_items,
        total_value = total_value,
        storage_fee = self.storage_fee
    }
end

-- 查找物品
function StorageBehavior:find_item(item_id)
    local found_items = {}
    
    for slot, item in pairs(self.storage_items) do
        if item and item.id == item_id then
            table.insert(found_items, {
                slot = slot,
                item = item
            })
        end
    end
    
    return found_items
end

-- 获取物品数量
function StorageBehavior:get_item_count(item_id)
    local count = 0
    
    for _, item in pairs(self.storage_items) do
        if item and item.id == item_id then
            count = count + item.count
        end
    end
    
    return count
end

-- 检查是否有足够物品
function StorageBehavior:has_enough_items(item_id, required_count)
    return self:get_item_count(item_id) >= required_count
end

-- 批量取出物品
function StorageBehavior:retrieve_items_by_id(player, item_id, count)
    local remaining_count = count
    local retrieved_slots = {}
    
    for slot, item in pairs(self.storage_items) do
        if item and item.id == item_id and remaining_count > 0 then
            local retrieve_count = math.min(remaining_count, item.count)
            
            if self:handle_retrieve_item(player, slot, nil) then
                table.insert(retrieved_slots, slot)
                remaining_count = remaining_count - retrieve_count
            end
        end
    end
    
    return remaining_count == 0, retrieved_slots
end

-- 清空存储
function StorageBehavior:clear_storage()
    local cleared_count = 0
    
    for slot, item in pairs(self.storage_items) do
        if item then
            self.storage_items[slot] = nil
            cleared_count = cleared_count + 1
        end
    end
    
    log.info("存储空间已清空，共清理 %d 个槽位", cleared_count)
    return cleared_count
end

-- 获取存储物品列表
function StorageBehavior:get_storage_items()
    local items = {}
    
    for slot, item in pairs(self.storage_items) do
        if item then
            table.insert(items, {
                slot = slot,
                item = item
            })
        end
    end
    
    return items
end

return StorageBehavior 