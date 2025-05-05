local skynet = require "skynet"
local ctn_mf = require "ctn.ctn_mf"
local class = require "utils.class"
local tableUtils = require "utils.tableUtils"
local log = require "log"

local ctn_bag = class("ctn_bag", ctn_mf)

-- 背包配置
local BAG_CONFIG = {
    MAX_SLOTS = 100,  -- 最大格子数
    MAX_STACK = 999,  -- 最大堆叠数
    BATCH_SIZE = 50,  -- 每批存储的物品数量
}

-- 特殊数据键名
local SPECIAL_KEYS = {
    CONFIG = "bag_config",  -- 背包配置信息
}

function ctn_bag:ctor(_player_id, _tbl, _name)
    ctn_mf.ctor(self, _player_id, _tbl, _name)
    self.datas_ = {}  -- 存储所有数据，包括物品和配置
    self.slots_ = {}  -- 内存中的物品数据
    self.config_ = {  -- 背包配置信息
        max_slots = BAG_CONFIG.MAX_SLOTS,
        max_stack = BAG_CONFIG.MAX_STACK,
        batch_size = BAG_CONFIG.BATCH_SIZE,
        custom_settings = {},  -- 自定义设置
    }
end

-- 保存数据
function ctn_bag:onsave()
    -- 保存配置信息
    self.datas_[SPECIAL_KEYS.CONFIG] = self.config_
    self.field_dirty_[SPECIAL_KEYS.CONFIG] = true

    -- 将物品数据分批存储
    local batch_index = 1
    local current_batch = {}
    
    for slot, item in pairs(self.slots_) do
        current_batch[slot] = item
        
        -- 当达到批次大小时，保存当前批次
        if #current_batch >= BAG_CONFIG.BATCH_SIZE then
            local batch_key = string.format("items_batch_%d", batch_index)
            self.datas_[batch_key] = current_batch
            self.field_dirty_[batch_key] = true
            current_batch = {}
            batch_index = batch_index + 1
        end
    end
    
    -- 保存最后一个不完整的批次
    if next(current_batch) then
        local batch_key = string.format("items_batch_%d", batch_index)
        self.datas_[batch_key] = current_batch
        self.field_dirty_[batch_key] = true
    end
    
    return self.datas_
end

-- 加载数据
function ctn_bag:onload(_datas)
    self.datas_ = _datas or {}
    
    -- 加载配置信息
    if self.datas_[SPECIAL_KEYS.CONFIG] then
        self.config_ = self.datas_[SPECIAL_KEYS.CONFIG]
    end
    
    -- 加载所有物品数据
    self.slots_ = {}
    local batch_index = 1
    while true do
        local batch_key = string.format("items_batch_%d", batch_index)
        local batch = self.datas_[batch_key]
        if not batch then break end
        
        for slot, item in pairs(batch) do
            self.slots_[slot] = item
        end
        batch_index = batch_index + 1
    end
end

-- 获取指定格子的物品
function ctn_bag:get_item(slot)
    return self.slots_[slot]
end

-- 检查格子是否为空
function ctn_bag:is_slot_empty(slot)
    return not self.slots_[slot]
end

-- 检查物品是否可以堆叠
function ctn_bag:can_stack(item_id)
    -- TODO: 从配置中读取物品是否可以堆叠
    return true
end

-- 检查物品是否可以放入指定格子
function ctn_bag:can_put_item(slot, item)
    if slot < 1 or slot > self.config_.max_slots then
        return false, "格子不存在"
    end
    
    local existing_item = self.slots_[slot]
    if existing_item then
        if existing_item.item_id ~= item.item_id then
            return false, "格子已有其他物品"
        end
        if not self:can_stack(item.item_id) then
            return false, "物品不可堆叠"
        end
        if existing_item.count + item.count > self.config_.max_stack then
            return false, "超出最大堆叠数"
        end
    end
    
    return true
end

-- 添加物品
function ctn_bag:add_item(item)
    if not item or not item.item_id or not item.count then
        return false, "物品数据无效"
    end
    
    -- 尝试堆叠到已有物品
    if self:can_stack(item.item_id) then
        for slot, existing_item in pairs(self.slots_) do
            if existing_item.item_id == item.item_id then
                local can_add = math.min(self.config_.max_stack - existing_item.count, item.count)
                if can_add > 0 then
                    existing_item.count = existing_item.count + can_add
                    item.count = item.count - can_add
                    self.field_dirty_[self:get_batch_key(slot)] = true
                    if item.count == 0 then
                        return true
                    end
                end
            end
        end
    end
    
    -- 寻找空格子
    for slot = 1, self.config_.max_slots do
        if self:is_slot_empty(slot) then
            self.slots_[slot] = {
                item_id = item.item_id,
                count = item.count,
                bind = item.bind or false,
                expire_time = item.expire_time or 0,
                extra = item.extra or {},
            }
            self.field_dirty_[self:get_batch_key(slot)] = true
            return true
        end
    end
    
    return false, "背包已满"
end

-- 删除物品
function ctn_bag:remove_item(slot, count)
    if not self.slots_[slot] then
        return false, "格子为空"
    end
    
    local item = self.slots_[slot]
    if item.count < count then
        return false, "物品数量不足"
    end
    
    item.count = item.count - count
    if item.count == 0 then
        self.slots_[slot] = nil
    end
    self.field_dirty_[self:get_batch_key(slot)] = true
    return true
end

-- 移动物品
function ctn_bag:move_item(from_slot, to_slot)
    if not self.slots_[from_slot] then
        return false, "源格子为空"
    end
    
    local from_item = self.slots_[from_slot]
    local to_item = self.slots_[to_slot]
    
    -- 目标格子为空，直接移动
    if not to_item then
        self.slots_[to_slot] = from_item
        self.slots_[from_slot] = nil
        self.field_dirty_[self:get_batch_key(from_slot)] = true
        self.field_dirty_[self:get_batch_key(to_slot)] = true
        return true
    end
    
    -- 目标格子有相同物品且可堆叠
    if from_item.item_id == to_item.item_id and self:can_stack(from_item.item_id) then
        local can_add = math.min(self.config_.max_stack - to_item.count, from_item.count)
        if can_add > 0 then
            to_item.count = to_item.count + can_add
            from_item.count = from_item.count - can_add
            if from_item.count == 0 then
                self.slots_[from_slot] = nil
            end
            self.field_dirty_[self:get_batch_key(from_slot)] = true
            self.field_dirty_[self:get_batch_key(to_slot)] = true
            return true
        end
    end
    
    -- 交换物品
    self.slots_[from_slot] = to_item
    self.slots_[to_slot] = from_item
    self.field_dirty_[self:get_batch_key(from_slot)] = true
    self.field_dirty_[self:get_batch_key(to_slot)] = true
    return true
end

-- 检查背包是否已满
function ctn_bag:is_full()
    local count = 0
    for _ in pairs(self.slots_) do
        count = count + 1
    end
    return count >= self.config_.max_slots
end

-- 获取背包剩余格子数
function ctn_bag:get_free_slots()
    local count = 0
    for _ in pairs(self.slots_) do
        count = count + 1
    end
    return self.config_.max_slots - count
end

-- 获取指定物品的数量
function ctn_bag:get_item_count(item_id)
    local count = 0
    for _, item in pairs(self.slots_) do
        if item.item_id == item_id then
            count = count + item.count
        end
    end
    return count
end

-- 检查是否有足够数量的物品
function ctn_bag:has_enough_items(item_id, count)
    return self:get_item_count(item_id) >= count
end

-- 获取物品所在批次的键名
function ctn_bag:get_batch_key(slot)
    local batch_index = math.ceil(slot / self.config_.batch_size)
    return string.format("items_batch_%d", batch_index)
end

-- 设置背包配置
function ctn_bag:set_config(key, value)
    if key == "max_slots" or key == "max_stack" or key == "batch_size" then
        self.config_[key] = value
        self.field_dirty_[SPECIAL_KEYS.CONFIG] = true
        return true
    end
    return false, "无效的配置项"
end

-- 设置自定义配置
function ctn_bag:set_custom_setting(key, value)
    self.config_.custom_settings[key] = value
    self.field_dirty_[SPECIAL_KEYS.CONFIG] = true
    return true
end

-- 获取自定义配置
function ctn_bag:get_custom_setting(key)
    return self.config_.custom_settings[key]
end

return ctn_bag