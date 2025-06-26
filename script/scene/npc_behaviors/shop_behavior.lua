local skynet = require "skynet"
local BaseBehavior = require "scene.npc_behaviors.base_behavior"
local class = require "utils.class"
local log = require "log"

-- 商店功能行为
local ShopBehavior = class("ShopBehavior", BaseBehavior)

function ShopBehavior:ctor(npc, config)
    ShopBehavior.super.ctor(self, npc, config)
    self.behavior_name = "shop"
    self.shop_items = config.shop_items or {}
    self.buy_rate = config.buy_rate or 1.0  -- 购买价格倍率
    self.sell_rate = config.sell_rate or 0.3 -- 出售价格倍率
    self:init()
end

function ShopBehavior:init()
    -- 验证商店配置
    for _, item in pairs(self.shop_items) do
        if not self:validate_shop_item(item) then
            log.warning("商店物品配置验证失败: %s", item.name or item.id)
        end
    end
end

function ShopBehavior:validate_shop_item(item)
    if not item.id then
        return false
    end
    if not item.name then
        return false
    end
    if not item.price or item.price < 0 then
        return false
    end
    return true
end

function ShopBehavior:handle_interact(player)
    -- 发送商店物品列表给玩家
    player:send_message("npc_shop_list", {
        npc_id = self.npc.id,
        shop_items = self.shop_items,
        buy_rate = self.buy_rate,
        sell_rate = self.sell_rate
    })
    
    return true
end

function ShopBehavior:handle_buy_item(player, item_id, count)
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
    
    -- 检查库存
    if shop_item.stock and shop_item.stock < count then
        return false, "库存不足"
    end
    
    -- 检查金钱
    local total_price = math.floor(shop_item.price * self.buy_rate * count)
    if player:get_money() < total_price then
        return false, "金钱不足"
    end
    
    -- 检查背包空间
    if not player:check_bag_space(item_id, count) then
        return false, "背包空间不足"
    end
    
    -- 扣除金钱
    player:remove_money(total_price)
    
    -- 减少库存
    if shop_item.stock then
        shop_item.stock = shop_item.stock - count
    end
    
    -- 添加物品
    player:add_item(item_id, count)
    
    log.info("玩家购买物品: %s x%d, 花费: %d", shop_item.name, count, total_price)
    return true
end

function ShopBehavior:handle_sell_item(player, bag_slot, count)
    -- 获取物品信息
    local item = player:get_bag_item(bag_slot)
    if not item then
        return false, "物品不存在"
    end
    
    if item.count < count then
        return false, "物品数量不足"
    end
    
    -- 计算出售价格
    local sell_price = math.floor(item.price * self.sell_rate * count)
    
    -- 移除物品
    player:remove_item(bag_slot, count)
    
    -- 添加金钱
    player:add_money(sell_price)
    
    log.info("玩家出售物品: %s x%d, 获得: %d", item.name, count, sell_price)
    return true
end

-- 添加商店物品
function ShopBehavior:add_shop_item(item)
    if self:validate_shop_item(item) then
        table.insert(self.shop_items, item)
        log.info("商店行为添加物品: %s", item.name)
        return true
    end
    return false
end

-- 移除商店物品
function ShopBehavior:remove_shop_item(item_id)
    for i, item in ipairs(self.shop_items) do
        if item.id == item_id then
            local item_name = item.name
            table.remove(self.shop_items, i)
            log.info("商店行为移除物品: %s", item_name)
            return true
        end
    end
    return false
end

-- 更新物品价格
function ShopBehavior:update_item_price(item_id, new_price)
    for _, item in ipairs(self.shop_items) do
        if item.id == item_id then
            local old_price = item.price
            item.price = new_price
            log.info("商店物品价格更新: %s %d -> %d", item.name, old_price, new_price)
            return true
        end
    end
    return false
end

-- 更新物品库存
function ShopBehavior:update_item_stock(item_id, new_stock)
    for _, item in ipairs(self.shop_items) do
        if item.id == item_id then
            local old_stock = item.stock
            item.stock = new_stock
            log.info("商店物品库存更新: %s %d -> %d", item.name, old_stock or 0, new_stock)
            return true
        end
    end
    return false
end

-- 设置价格倍率
function ShopBehavior:set_buy_rate(rate)
    self.buy_rate = rate
    log.info("商店购买倍率更新: %f", rate)
end

function ShopBehavior:set_sell_rate(rate)
    self.sell_rate = rate
    log.info("商店出售倍率更新: %f", rate)
end

-- 获取商店统计信息
function ShopBehavior:get_shop_stats()
    local total_items = #self.shop_items
    local total_value = 0
    local low_stock_items = 0
    
    for _, item in ipairs(self.shop_items) do
        total_value = total_value + (item.price * (item.stock or 0))
        if item.stock and item.stock < 10 then
            low_stock_items = low_stock_items + 1
        end
    end
    
    return {
        total_items = total_items,
        total_value = total_value,
        low_stock_items = low_stock_items,
        buy_rate = self.buy_rate,
        sell_rate = self.sell_rate
    }
end

return ShopBehavior 