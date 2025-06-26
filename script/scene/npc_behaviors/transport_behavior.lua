local skynet = require "skynet"
local BaseBehavior = require "scene.npc_behaviors.base_behavior"
local class = require "utils.class"
local log = require "log"

-- 传送功能行为
local TransportBehavior = class("TransportBehavior", BaseBehavior)

function TransportBehavior:ctor(npc, config)
    TransportBehavior.super.ctor(self, npc, config)
    self.behavior_name = "transport"
    self.destinations = config.destinations or {}
    self.transport_cost = config.transport_cost or 0
    self:init()
end

function TransportBehavior:init()
    -- 验证传送配置
    for _, dest in pairs(self.destinations) do
        if not self:validate_destination(dest) then
            log.warning("传送目标配置验证失败: %s", dest.name or dest.id)
        end
    end
end

function TransportBehavior:validate_destination(dest)
    if not dest.id then
        return false
    end
    if not dest.name then
        return false
    end
    if not dest.scene_id then
        return false
    end
    if not dest.x or not dest.y then
        return false
    end
    return true
end

function TransportBehavior:handle_interact(player)
    -- 发送传送目标列表给玩家
    player:send_message("npc_transport_list", {
        npc_id = self.npc.id,
        destinations = self.destinations,
        transport_cost = self.transport_cost
    })
    
    return true
end

function TransportBehavior:handle_transport(player, dest_id)
    -- 查找传送目标
    local destination = nil
    for _, dest in ipairs(self.destinations) do
        if dest.id == dest_id then
            destination = dest
            break
        end
    end
    
    if not destination then
        return false, "传送目标不存在"
    end
    
    -- 检查等级要求
    if destination.require_level and player.level < destination.require_level then
        return false, "等级不足"
    end
    
    -- 检查职业要求
    if destination.require_profession and player.profession ~= destination.require_profession then
        return false, "职业不符"
    end
    
    -- 检查任务要求
    if destination.require_quests then
        for _, quest_id in ipairs(destination.require_quests) do
            if player:get_quest_status(quest_id) ~= "completed" then
                return false, "任务未完成"
            end
        end
    end
    
    -- 检查金钱
    local cost = destination.cost or self.transport_cost
    if cost > 0 and player:get_money() < cost then
        return false, "金钱不足"
    end
    
    -- 扣除金钱
    if cost > 0 then
        player:remove_money(cost)
    end
    
    -- 执行传送
    player:teleport(destination.scene_id, destination.x, destination.y)
    
    log.info("玩家传送: %s -> %s, 花费: %d", player.name, destination.name, cost)
    return true
end

-- 检查玩家是否可以传送到指定目标
function TransportBehavior:can_transport_to(player, dest_id)
    local destination = nil
    for _, dest in ipairs(self.destinations) do
        if dest.id == dest_id then
            destination = dest
            break
        end
    end
    
    if not destination then
        return false, "传送目标不存在"
    end
    
    -- 检查等级要求
    if destination.require_level and player.level < destination.require_level then
        return false, "等级不足"
    end
    
    -- 检查职业要求
    if destination.require_profession and player.profession ~= destination.require_profession then
        return false, "职业不符"
    end
    
    -- 检查任务要求
    if destination.require_quests then
        for _, quest_id in ipairs(destination.require_quests) do
            if player:get_quest_status(quest_id) ~= "completed" then
                return false, "任务未完成"
            end
        end
    end
    
    -- 检查金钱
    local cost = destination.cost or self.transport_cost
    if cost > 0 and player:get_money() < cost then
        return false, "金钱不足"
    end
    
    return true
end

return TransportBehavior 