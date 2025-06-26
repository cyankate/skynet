local skynet = require "skynet"
local Entity = require "scene.entity"
local BehaviorRegistry = require "scene.npc_behaviors.behavior_registry"
local class = require "utils.class"
local log = require "log"

-- NPC实体类型
local NPCEntity = class("NPCEntity", Entity)


function NPCEntity:ctor(id, config)
    NPCEntity.super.ctor(self, id, Entity.ENTITY_TYPE.NPC, config)
    
    self.name = config.name or "NPC"
    self.interact_range = config.interact_range or 2.0
    self.behaviors = {}  -- 功能行为列表
    
    -- 初始化功能行为
    self:init_behaviors(config.behaviors or {})
end

-- 初始化功能行为
function NPCEntity:init_behaviors(behavior_configs)
    for behavior_name, config in pairs(behavior_configs) do
        self:add_behavior(behavior_name, config)
    end
end

-- 添加功能行为
function NPCEntity:add_behavior(behavior_name, config)
    local behavior = BehaviorRegistry.create_behavior(behavior_name, self, config)
    if behavior then
        self.behaviors[behavior_name] = behavior
        log.info("NPC %s 添加行为: %s", self.name, behavior_name)
        return true
    else
        log.warning("NPC %s 添加行为失败: %s", self.name, behavior_name)
        return false
    end
end

-- 移除功能行为
function NPCEntity:remove_behavior(behavior_name)
    local behavior = self.behaviors[behavior_name]
    if behavior then
        -- 销毁行为
        if behavior.destroy then
            behavior:destroy()
        end
        self.behaviors[behavior_name] = nil
        log.info("NPC %s 移除行为: %s", self.name, behavior_name)
        return true
    end
    return false
end

-- 获取功能行为
function NPCEntity:get_behavior(behavior_name)
    return self.behaviors[behavior_name]
end

-- 启用功能行为
function NPCEntity:enable_behavior(behavior_name)
    local behavior = self.behaviors[behavior_name]
    if behavior then
        behavior:enable()
        return true
    end
    return false
end

-- 禁用功能行为
function NPCEntity:disable_behavior(behavior_name)
    local behavior = self.behaviors[behavior_name]
    if behavior then
        behavior:disable()
        return true
    end
    return false
end

-- 获取所有可用功能
function NPCEntity:get_available_behaviors(player)
    local available_behaviors = {}
    
    for behavior_name, behavior in pairs(self.behaviors) do
        if behavior:is_enabled() and behavior:can_interact(player) then
            table.insert(available_behaviors, behavior_name)
        end
    end
    
    return available_behaviors
end

-- 当玩家进入视野
function NPCEntity:on_entity_enter(other)
    if other.type == Entity.ENTITY_TYPE.PLAYER then
        -- 发送NPC信息给玩家
        other:send_message("npc_enter", {
            npc_id = self.id,
            name = self.name,
            x = self.x,
            y = self.y,
            available_behaviors = self:get_available_behaviors(other)
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
function NPCEntity:handle_interact(player, behavior_name)
    -- 检查交互距离
    local dx = player.x - self.x
    local dy = player.y - self.y
    local distance = math.sqrt(dx * dx + dy * dy)
    
    if distance > self.interact_range then
        return false, "距离太远"
    end
    
    -- 如果指定了行为名称，直接调用对应行为
    if behavior_name then
        local behavior = self.behaviors[behavior_name]
        if not behavior then
            return false, "该NPC没有此功能"
        end
        
        if not behavior:is_enabled() then
            return false, "该功能暂时不可用"
        end
        
        return behavior:handle_interact(player)
    end
    
    -- 如果没有指定行为名称，显示功能选择界面
    local available_behaviors = self:get_available_behaviors(player)
    if #available_behaviors == 0 then
        return false, "该NPC暂时没有可用功能"
    end
    
    -- 如果只有一个功能，直接调用
    if #available_behaviors == 1 then
        return self:handle_interact(player, available_behaviors[1])
    end
    
    -- 多个功能时，发送功能选择界面
    player:send_message("npc_behavior_select", {
        npc_id = self.id,
        available_behaviors = available_behaviors
    })
    
    return true
end

-- 处理特定行为的操作（使用操作接口系统）
function NPCEntity:handle_operation(player, behavior_name, operation, ...)
    local behavior = self.behaviors[behavior_name]
    if not behavior then
        return false, "该NPC没有此功能"
    end
    
    if not behavior:is_enabled() then
        return false, "该功能暂时不可用"
    end
    
    return behavior:handle_operation(player, operation, ...)
end

-- 动态更新NPC行为配置
function NPCEntity:update_behavior_config(behavior_name, new_config)
    local behavior = self.behaviors[behavior_name]
    if behavior then
        -- 更新配置
        behavior:update_config(new_config)
        return true
    end
    return false
end

-- 批量更新行为配置
function NPCEntity:update_behavior_configs(configs)
    for behavior_name, config in pairs(configs) do
        self:update_behavior_config(behavior_name, config)
    end
end

-- 获取NPC当前行为状态
function NPCEntity:get_behavior_status()
    local status = {}
    for behavior_name, behavior in pairs(self.behaviors) do
        status[behavior_name] = behavior:get_status()
    end
    return status
end

-- 注册新的行为类型
function NPCEntity.register_behavior(behavior_name, behavior_class)
    BehaviorRegistry.register_behavior(behavior_name, behavior_class)
end

-- 获取所有行为类型
function NPCEntity.get_all_behavior_types()
    return BehaviorRegistry.get_behavior_names()
end

return NPCEntity