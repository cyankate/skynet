local skynet = require "skynet"
local Entity = require "scene.entity"
local class = require "utils.class"
local log = require "log"
local StateMachine = require "scene.ai.state_machine"
local Blackboard = require "scene.ai.blackboard"

local StateEntity = class("StateEntity", Entity)

function StateEntity:ctor(id, type)
    StateEntity.super.ctor(self, id, type)
    
    -- 状态机相关
    self.state_machine = nil     -- 状态机实例
    
    -- 行为树相关
    self.behavior_tree = nil     -- 行为树实例
    self.blackboard = Blackboard.new():set_entity(self)  -- 黑板系统
    
    -- 移动相关
    self.moving = false
    self.move_target_x = nil
    self.move_target_y = nil
    self.move_path = nil
    self.move_path_index = 1
    self.move_speed = 5          -- 默认移动速度
    
    -- 战斗相关
    self.target_id = nil
    self.last_attack_time = 0
    self.attack_cd = 1.0
    
    -- 状态效果
    self.stun_duration = 0
    self.cast_duration = 0
end

-- 更新实体
function StateEntity:update(dt)
    -- 更新状态机
    if self.state_machine then
        self.state_machine:update(dt)
    end
    -- 更新行为树（如果有）
    self:update_behavior_tree(dt)
end

-- 设置状态机
function StateEntity:set_state_machine(state_machine)
    self.state_machine = state_machine
    if state_machine then
        state_machine:set_entity(self)
    end
    return self
end

-- 获取属性值（支持getter方法）
function StateEntity:get_attr_value(attr_name, config)
    if config.getter and type(self[config.getter]) == "function" then
        return self[config.getter](self)
    else
        return self[attr_name]
    end
end

-- 设置属性值（支持setter方法）
function StateEntity:set_attr_value(attr_name, value, config)
    if config.setter and type(self[config.setter]) == "function" then
        return self[config.setter](self, value)
    else
        self[attr_name] = value
        return true
    end
end

-- 设置移动目标（实体接口）
function StateEntity:set_move_target(x, y)
    if self.ai_manager then
        self.ai_manager:set_move_target(x, y)
    end
    
    log.debug("StateEntity: 设置移动目标 %s: (%f, %f)", self.id, x, y)
    return self
end

-- 停止移动（实体接口）
function StateEntity:stop_moving()
    if self.ai_manager then
        self.ai_manager:request_state("idle")
    end
    
    log.debug("StateEntity: 停止移动 %s", self.id)
    return self
end

-- 设置目标（实体接口）
function StateEntity:set_target(target_id)
    if self.ai_manager then
        local blackboard = self.ai_manager:get_blackboard()
        if blackboard then
            blackboard:set_decision("attack_target", target_id, "entity_set_target")
        end
    end
    
    log.debug("StateEntity: 设置目标 %s: %s", self.id, tostring(target_id))
    return self
end

-- 获取目标
function StateEntity:get_target()
    if self.ai_manager then
        local blackboard = self.ai_manager:get_blackboard()
        if blackboard then
            return blackboard:get_decision("attack_target")
        end
    end
    return nil
end

-- 设置眩晕时间（实体接口）
function StateEntity:set_stun_duration(duration)
    if self.ai_manager then
        local blackboard = self.ai_manager:get_blackboard()
        if blackboard then
            blackboard:set_state("stun_duration", duration, "entity_set_stun")
        end
    end
    
    log.debug("StateEntity: 设置眩晕时间 %s: %f", self.id, duration)
    return self
end

-- 设置施法时间（实体接口）
function StateEntity:set_cast_duration(duration)
    if self.ai_manager then
        local blackboard = self.ai_manager:get_blackboard()
        if blackboard then
            blackboard:set_state("cast_duration", duration, "entity_set_cast")
        end
    end
    
    log.debug("StateEntity: 设置施法时间 %s: %f", self.id, duration)
    return self
end

-- 停止状态机
function StateEntity:stop_state_machine()
    if self.state_machine then
        self.state_machine:stop()
    end
end

-- 中断状态机
function StateEntity:interrupt_state_machine()
    if self.state_machine then
        self.state_machine:interrupt()
    end
end

-- 行为树相关方法
function StateEntity:set_behavior_tree(behavior_tree)
    self.behavior_tree = behavior_tree
    return self
end

-- AI管理器相关方法
function StateEntity:set_ai_manager(ai_manager)
    self.ai_manager = ai_manager
    return self
end

function StateEntity:get_ai_manager()
    return self.ai_manager
end

function StateEntity:create_ai_manager(config)
    local AIManager = require "scene.ai.ai_manager"
    self.ai_manager = AIManager.new(self, config)
    return self.ai_manager
end

function StateEntity:update_behavior_tree(dt)
    if self.ai_manager then
        self.ai_manager:update(dt)
    end
end

function StateEntity:get_behavior_tree()
    if self.ai_manager then
        return self.ai_manager:get_behavior_tree()
    end
    return nil
end

-- 获取当前状态名称
function StateEntity:get_current_state_name()
    if self.ai_manager then
        return self.ai_manager:get_current_state()
    end
    return "none"
end

-- 获取状态持续时间
function StateEntity:get_state_time()
    if self.ai_manager then
        return self.ai_manager:get_state_time()
    end
    return 0
end

-- 便捷方法
function StateEntity:request_state(state_name)
    if self.ai_manager then
        self.ai_manager:request_state(state_name)
    end
end

-- 设置移动速度
function StateEntity:set_move_speed(speed)
    self.move_speed = speed
end

-- 获取移动速度
function StateEntity:get_move_speed()
    return self.move_speed
end

-- 检查是否正在移动
function StateEntity:is_moving()
    return self.moving
end

-- 获取移动目标位置
function StateEntity:get_move_target()
    if self.move_path and #self.move_path > 0 then
        return self.move_path[#self.move_path]
    end
    return nil
end

-- 获取当前移动进度（0-1）
function StateEntity:get_move_progress()
    if not self.move_path or #self.move_path == 0 then
        return 0
    end
    
    local total_distance = 0
    local traveled_distance = 0
    
    -- 计算总距离
    for i = 1, #self.move_path - 1 do
        local p1 = self.move_path[i]
        local p2 = self.move_path[i + 1]
        local dx = p2.x - p1.x
        local dy = p2.y - p1.y
        total_distance = total_distance + math.sqrt(dx * dx + dy * dy)
    end
    
    -- 计算已移动距离
    for i = 1, self.move_path_index - 1 do
        if i < #self.move_path then
            local p1 = self.move_path[i]
            local p2 = self.move_path[i + 1]
            local dx = p2.x - p1.x
            local dy = p2.y - p1.y
            traveled_distance = traveled_distance + math.sqrt(dx * dx + dy * dy)
        end
    end
    
    -- 加上当前位置到下一个路径点的距离
    if self.move_path_index <= #self.move_path then
        local current_point = self.move_path[self.move_path_index]
        local dx = current_point.x - self.x
        local dy = current_point.y - self.y
        traveled_distance = traveled_distance + math.sqrt(dx * dx + dy * dy)
    end
    
    return total_distance > 0 and (traveled_distance / total_distance) or 0
end

-- 停止移动
function StateEntity:stop_move()
    self.moving = false
    self.move_target_x = nil
    self.move_target_y = nil
    self.move_path = nil
    self.move_path_index = 1
end

-- 暂停移动
function StateEntity:pause_move()
    self.moving = false
end

-- 恢复移动
function StateEntity:resume_move()
    if self.move_path and #self.move_path > 0 then
        self.moving = true
    end
end

-- 更新移动
function StateEntity:update_move(dt)
    if not self.moving or not self.move_path then
        self:stop_move()
        return "failed"
    end
    
    -- 获取当前路径点
    local current_point = self.move_path[self.move_path_index]
    if not current_point then
        self:stop_move()
        return "failed"
    end
    
    -- 计算到当前路径点的距离
    local dx = current_point.x - self.x
    local dy = current_point.y - self.y
    local distance = math.sqrt(dx * dx + dy * dy)

    -- 计算这一帧应该移动的距离
    local frame_distance = self.move_speed * dt
    if distance <= frame_distance then
        -- 可以直接到达路径点
        local success = self.scene:move_entity(self.id, current_point.x, current_point.y)
        if not success then
            log.error("StateEntity:update_move() move_entity failed")
            self:stop_move()
            return "failed"
        end
        
        -- 移动到下一个路径点
        self.move_path_index = self.move_path_index + 1
        
        -- 检查是否到达终点
        if self.move_path_index > #self.move_path then
            self:stop_move()
            -- 调用移动结束钩子
            self:on_move_end()
            return "success"
        end
    else
        -- 需要插值移动到路径点
        local ratio = frame_distance / distance
        local next_x = self.x + dx * ratio
        local next_y = self.y + dy * ratio
        
        -- 检查下一个位置是否可行走
        if not self.scene:is_position_walkable(next_x, next_y) then
            -- 如果下一个位置不可行走，尝试重新寻路
            local target_point = self.move_path[#self.move_path]
            local new_path = self.scene:find_path(self.x, self.y, target_point.x, target_point.y)
            if new_path then
                self.move_path = new_path
                self.move_path_index = 1
                return "running"
            else
                self:stop_move()
                return "failed"
            end
        end
        --log.debug("StateEntity: 移动到计算出的下一个位置 (%.1f, %.1f)", next_x, next_y)
        -- 移动到计算出的下一个位置
        local success = self.scene:move_entity(self.id, next_x, next_y)
        if not success then
            self:stop_move()
            return "failed"
        end
    end
    
    -- 调用移动更新钩子
    self:on_move_update()
    return "running"
end

-- 处理移动请求
function StateEntity:handle_move(x, y)
    -- 获取路径
    if self.scene then
        --log.debug("StateEntity: 开始寻路 (%.1f, %.1f) -> (%.1f, %.1f)", self.x, self.y, x, y)
        local path = self.scene:find_path(self.x, self.y, x, y)
        if not path then
            log.warning("StateEntity: 寻路失败，直接设置位置")
            self:set_position(x, y)
            return true
        end
        
        -- 设置移动路径数据
        self.move_path = path
        self.move_path_index = 1
        self.move_target_x = x
        self.move_target_y = y
        self.moving = true
        
        -- 调用移动开始钩子
        self:on_move_start()
        return true
    else
        log.warning("StateEntity: 实体不在场景中，直接设置位置")
        self:set_position(x, y)
        return true
    end
end

-- 处理攻击请求
function StateEntity:handle_attack(target_id)
    -- 检查目标是否存在
    local target = self.scene:get_entity(target_id)
    if not target then
        return false, "目标不存在"
    end
    
    self.target_id = target_id
    return true
end

-- 处理施法请求
function StateEntity:handle_cast(skill_id, target_id)
    -- 获取技能配置
    local skill_config = self:get_skill_config(skill_id)
    if not skill_config then
        return false, "技能不存在"
    end
    
    -- 设置施法数据
    self.cast_duration = skill_config.cast_time
    self.target_id = target_id
    
    return true
end

-- 处理眩晕
function StateEntity:handle_stun(duration)
    self.stun_duration = duration
    return true
end

-- 处理死亡
function StateEntity:handle_death(killer)
    -- 停止所有活动
    self:stop_move()
    self.target_id = nil
    self.stun_duration = 0
    self.cast_duration = 0
end

-- 播放动画（基类空实现）
function StateEntity:play_animation(anim_name)

end

-- 复活
function StateEntity:respawn()
    -- 恢复生命值和魔法值
    self.hp = self.max_hp
    if self.mana then
        self.mana = self.max_mana
    end
    
    -- 清除死亡标志
    self.is_dead = false
    
    -- 切换到待机状态
    self:change_state("idle")
    
    log.info("StateEntity: 实体 %d 复活", self.id)
end

-- 受到伤害
function StateEntity:take_damage(damage, attacker)
    -- 计算实际伤害
    local actual_damage = math.max(1, damage - (self.defense or 0))
    self.hp = math.max(0, self.hp - actual_damage)
    
    -- 记录攻击者
    self.last_attacker = attacker
    
    log.info("StateEntity: 实体 %d 受到 %d 点伤害，剩余血量 %d", self.id, actual_damage, self.hp)
    
    -- 检查死亡
    if self.hp <= 0 then
        self:handle_death(attacker)
    end
    
    return actual_damage
end

-- 掉落物品（基类空实现）
function StateEntity:drop_loot()
    -- 基类空实现，由子类重写
    log.debug("StateEntity: 实体 %d 掉落物品", self.id)
end

-- 移动开始钩子
function StateEntity:on_move_start()
    -- 基类空实现,由子类重写
end

-- 移动结束钩子
function StateEntity:on_move_end()
    -- 基类空实现,由子类重写
end

-- 移动更新钩子
function StateEntity:on_move_update()
    -- 基类空实现,由子类重写
end

-- 便捷方法：获取黑板
function StateEntity:get_blackboard()
    if self.ai_manager then
        return self.ai_manager:get_blackboard()
    end
    return nil
end

function StateEntity:request_move(x, y)
    if not self:can_move() then
        log.warning("StateEntity: 实体无法移动")
        return false
    end
    
    if self.ai_manager then
        self.ai_manager:set_move_target(x, y)
        log.debug("StateEntity: 请求移动到 (%.1f, %.1f)", x, y)
        return true
    end
    
    return false
end

function StateEntity:request_move_to_entity(target_id, distance)
    local target = self.scene:get_entity(target_id)
    if not target then
        return false, "目标实体不存在"
    end
    
    distance = distance or 2.0
    
    local dx = self.x - target.x
    local dy = self.y - target.y
    local current_distance = math.sqrt(dx * dx + dy * dy)
    
    if current_distance <= distance then
        return true, "已在目标距离内"
    end
    
    local angle = math.atan(dy, dx)
    local target_x = target.x + math.cos(angle) * distance
    local target_y = target.y + math.sin(angle) * distance
    
    return self:request_move(target_x, target_y)
end

function StateEntity:request_random_move(max_distance)
    max_distance = max_distance or 10.0
    
    local angle = math.random() * math.pi * 2
    local distance = math.random() * max_distance
    
    local target_x = self.x + math.cos(angle) * distance
    local target_y = self.y + math.sin(angle) * distance
    
    return self:request_move(target_x, target_y)
end

function StateEntity:request_patrol_move(center_x, center_y, radius)
    center_x = center_x or self.x
    center_y = center_y or self.y
    radius = radius or 10.0
    
    local angle = math.random() * math.pi * 2
    local distance = math.random() * radius
    
    local target_x = center_x + math.cos(angle) * distance
    local target_y = center_y + math.sin(angle) * distance
    
    return self:request_move(target_x, target_y)
end

function StateEntity:cancel_move()
    if self.ai_manager then
        self.ai_manager:request_state("idle")
    end
    
    self:stop_move()
    log.debug("StateEntity: 取消移动")
    return true
end

-- 检查是否可以移动
function StateEntity:can_move()
    if self.hp <= 0 then
        return false
    end
    
    local current_state = self:get_current_state_name()
    if current_state == "dead" or current_state == "stunned" then
        return false
    end
    
    return true
end

-- 切换状态
function StateEntity:change_state(state_name)
    if self.ai_manager then
        self.ai_manager:request_state(state_name)
        return true
    end
    
    log.warning("StateEntity: 尝试切换状态但AI管理器未设置")
    return false
end

-- 检查是否可以攻击
function StateEntity:can_attack()
    -- 检查血量
    if self.hp <= 0 then
        return false
    end
    
    -- 检查是否有目标
    if not self.target_id then
        return false
    end
    
    -- 检查攻击冷却
    local current_time = skynet.now() / 100
    if self.last_attack_time and (current_time - self.last_attack_time) < self.attack_cd then
        return false
    end
    
    -- 检查状态
    local current_state = self:get_current_state_name()
    if current_state == "stunned" or current_state == "dead" then
        return false
    end
    
    return true
end

-- 场景销毁回调（基类空实现）
function StateEntity:on_scene_destroy()
    -- 基类空实现，由子类重写
    log.debug("StateEntity: 实体 %d 场景销毁", self.id)
end

return StateEntity