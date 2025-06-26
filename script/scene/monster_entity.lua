local skynet = require "skynet"
local Entity = require "scene.entity"
local StateEntity = require "scene.state_entity"
local class = require "utils.class"
local log = require "log"
local AIConfig = require "scene.ai.ai_config"

local MonsterEntity = class("MonsterEntity", StateEntity)

function MonsterEntity:ctor(id, monster_data)
    MonsterEntity.super.ctor(self, id, Entity.ENTITY_TYPE.MONSTER)
    
    -- 怪物基础属性
    self.name = monster_data.name
    self.level = monster_data.level or 1
    self.hp = monster_data.hp or 100
    self.max_hp = monster_data.max_hp or 100
    self.attack = monster_data.attack or 10
    self.defense = monster_data.defense or 5
    self.speed = monster_data.speed or 3
    self.exp_reward = monster_data.exp_reward or 10
    
    self.patrol_radius = monster_data.patrol_radius or 50  -- 巡逻半径
    self.chase_radius = monster_data.chase_radius or 100   -- 追击半径
    self.attack_radius = monster_data.attack_radius or 20  -- 攻击半径
    self.view_range = monster_data.view_range or 150       -- 视野范围
    self.flee_distance = monster_data.flee_distance or 20  -- 逃跑距离
    
    -- 设置初始位置
    self:set_position(monster_data.x, monster_data.y)
    
    -- 技能相关
    self.skills = monster_data.skills or {}
    self.skill_cooldowns = {}
    
    -- 战斗相关
    self.in_combat = false
    self.combat_target = nil
    
    -- 初始化AI上下文
    self.ai_context = {}
    
    -- 创建AI管理器
    self:create_ai_manager(monster_data.ai_config)
    
    log.debug("MonsterEntity: 创建怪物 %s", self.id)
end

-- 创建AI管理器
function MonsterEntity:create_ai_manager(ai_config)
    -- 获取怪物AI配置
    local config = AIConfig:get_config("monster", ai_config)
    
    -- 验证配置
    local is_valid, errors = AIConfig:validate_config(config)
    if not is_valid then
        log.error("MonsterEntity: AI配置验证失败: %s", table.concat(errors, ", "))
        config = AIConfig:get_config("monster") -- 使用默认配置
    end
    
    -- 创建AI管理器
    local AIManager = require "scene.ai.ai_manager"
    self.ai_manager = AIManager.new(self, config)
    
    -- 配置AI管理器
    if config.enable_logging then
        self.ai_manager:set_logging(true)
    end
    
    -- 设置黑板配置
    if config.blackboard then
        local blackboard = self.ai_manager:get_blackboard()
        if config.blackboard.max_history then
            blackboard:set_max_history(config.blackboard.max_history)
        end
    end
    
    log.debug("MonsterEntity: 创建AI管理器 %s", self.id)
end

-- 初始化怪物特有黑板同步配置
function MonsterEntity:init_monster_blackboard_sync()
    -- 设置初始值
    self.blackboard:set_entity_data("in_combat", false, "entity_init")
    self.blackboard:set_entity_data("combat_target", nil, "entity_init")
    self.blackboard:set_entity_data("last_attacker", nil, "entity_init")
    self.blackboard:set_entity_data("patrol_center_x", 0, "entity_init")
    self.blackboard:set_entity_data("patrol_center_y", 0, "entity_init")
    self.blackboard:set_entity_data("attack_cooldown", 0, "entity_init")
    self.blackboard:set_entity_data("max_hp", self.max_hp, "entity_init")
    self.blackboard:set_entity_data("attack", self.attack, "entity_init")
    self.blackboard:set_entity_data("defense", self.defense, "entity_init")
    self.blackboard:set_entity_data("attack_range", self.attack_radius, "entity_init")
    self.blackboard:set_entity_data("move_speed", self.speed, "entity_init")
end

-- 执行攻击
function MonsterEntity:perform_attack(target)
    -- 计算实际伤害
    local actual_damage = math.max(1, self.attack - target.defense)
    target:take_damage(actual_damage, self)
    
    -- 广播攻击消息
    self:broadcast_message("entity_attack", {
        attacker_id = self.id,
        target_id = target.id,
        damage = actual_damage
    })
    
    return actual_damage
end

-- 受到伤害
function MonsterEntity:take_damage(damage, attacker)
    -- 计算实际伤害
    local actual_damage = math.max(1, damage - self.defense)
    self.hp = math.max(0, self.hp - actual_damage)
    
    -- 广播伤害信息
    self:broadcast_message("entity_damage", {
        target_id = self.id,
        attacker_id = attacker.id,
        damage = actual_damage,
        hp = self.hp,
        max_hp = self.max_hp
    })
    
    -- 记录攻击者
    self.last_attacker = attacker
    
    -- 检查死亡
    if self.hp <= 0 then
        self:on_death(attacker)
    end
    
    return actual_damage
end

-- 战斗状态管理
function MonsterEntity:enter_combat(target)
    self.in_combat = true
    self.combat_target = target
    
    log.debug("MonsterEntity: 进入战斗 %s -> %s", self.id, target and target.id or "nil")
    return true
end

function MonsterEntity:exit_combat()
    self.in_combat = false
    self.combat_target = nil
    
    log.debug("MonsterEntity: 退出战斗 %s", self.id)
    return true
end

function MonsterEntity:is_in_combat()
    return self.in_combat
end

-- 设置战斗目标（实体接口）
function MonsterEntity:set_combat_target(target)
    self.combat_target = target
    
    if target then
        log.debug("MonsterEntity: 设置战斗目标 %s: %s", self.id, target.id)
    else
        log.debug("MonsterEntity: 清除战斗目标 %s", self.id)
    end
    
    return self
end

-- 获取战斗目标
function MonsterEntity:get_combat_target()
    return self.combat_target
end

-- 设置最后攻击者（实体接口）
function MonsterEntity:set_last_attacker(attacker)
    self.last_attacker = attacker
    
    if attacker then
        log.debug("MonsterEntity: 设置最后攻击者 %s: %s", self.id, attacker.id)
    end
    
    return self
end

-- 获取最后攻击者
function MonsterEntity:get_last_attacker()
    return self.last_attacker
end

function MonsterEntity:cast_skill(skill, target)
    -- 计算技能伤害
    local damage = skill.base_damage or self.attack
    target:take_damage(damage, self)
    
    -- 广播技能使用消息
    self:broadcast_message("monster_skill", {
        monster_id = self.id,
        target_id = target.id,
        skill_id = skill.id,
        damage = damage
    })
    
    log.info("Monster %d 使用技能 %s 攻击目标 %d，造成 %d 伤害", 
             self.id, skill.name, target.id, damage)
end

function MonsterEntity:update_cooldowns(dt)
    for skill_id, cooldown in pairs(self.skill_cooldowns) do
        if cooldown > 0 then
            self.skill_cooldowns[skill_id] = cooldown - dt
        end
    end
end

-- 攻击相关
function MonsterEntity:can_attack()
    if self.ai_manager then
        local blackboard = self.ai_manager:get_blackboard()
        if blackboard then
            local attack_cooldown = blackboard:get_state("attack_cooldown", 0)
            local is_dead = blackboard:get_state("is_dead", false)
            return attack_cooldown <= 0 and not is_dead
        end
    end
    return false
end

function MonsterEntity:is_in_attack_range(target)
    if not target then return false end
    
    local dx = target.x - self.x
    local dy = target.y - self.y
    local distance = math.sqrt(dx * dx + dy * dy)
    
    return distance <= self.attack_radius
end

function MonsterEntity:is_in_skill_range(target)
    if not target then return false end
    
    local skill = self:get_available_skill()
    if not skill then return false end
    
    local dx = target.x - self.x
    local dy = target.y - self.y
    local distance = math.sqrt(dx * dx + dy * dy)
    
    return distance <= skill.range
end

-- 移动相关
function MonsterEntity:is_reached_target(target)
    if not target then return true end
    
    local dx = target.x - self.x
    local dy = target.y - self.y
    local distance = math.sqrt(dx * dx + dy * dy)
    
    return distance < 0.1
end

function MonsterEntity:is_moving()
    return self.moving
end

function MonsterEntity:get_move_target()
    return MonsterEntity.super.get_move_target(self)
end

function MonsterEntity:stop_move()
    MonsterEntity.super.stop_move(self)
end

-- 动画相关
function MonsterEntity:play_animation(anim_name)
    -- 广播动画播放消息
    self:broadcast_message("monster_animation", {
        monster_id = self.id,
        animation = anim_name
    })
end

-- 目标查找相关
function MonsterEntity:find_nearest_target()
    local nearest_target = nil
    local min_distance = self.view_range
    
    -- 获取视野范围内的所有玩家
    local surrounding = self:get_surrounding_entities()
    for _, entity in pairs(surrounding) do
        if entity.type == Entity.ENTITY_TYPE.PLAYER and
           entity.hp > 0 then
            local dx = entity.x - self.x
            local dy = entity.y - self.y
            local distance = math.sqrt(dx * dx + dy * dy)
            
            if distance < min_distance then
                min_distance = distance
                nearest_target = entity
            end
        end
    end
    
    return nearest_target
end

function MonsterEntity:find_nearest_threat()
    -- 返回最近的威胁（通常是攻击者）
    return self.combat_target
end

-- 巡逻相关
function MonsterEntity:should_patrol()
    -- 检查是否应该巡逻
    local current_time = skynet.now() / 100
    if not self.last_patrol_time then
        self.last_patrol_time = 0
    end
    
    -- 如果不在战斗中且距离上次巡逻超过间隔时间
    return not self:is_in_combat() and (current_time - self.last_patrol_time) > 3.0
end

-- 更新AI
function MonsterEntity:update(dt)
    -- 调用父类更新
    MonsterEntity.super.update(self, dt)
    
    -- 更新技能冷却
    self:update_cooldowns(1/60)  -- 假设60帧
end

-- 死亡处理
function MonsterEntity:on_death(killer)
    -- 退出战斗状态
    self:exit_combat()
end

-- 受到攻击（实体接口）
function MonsterEntity:on_attacked(attacker, damage)
    -- 设置最后攻击者
    self:set_last_attacker(attacker)
    
    -- 进入战斗状态
    self:enter_combat()
    
    -- 给所有周围的玩家发送消息
    for _, entity in pairs(surrounding) do
        if entity.type == Entity.ENTITY_TYPE.PLAYER then
            entity:send_message(name, data)
        end
    end
end

-- 检查是否在视野范围内
function MonsterEntity:is_in_detect_range(target)
    if not target then
        return false
    end
    
    local dx = target.x - self.x
    local dy = target.y - self.y
    local distance = math.sqrt(dx * dx + dy * dy)
    
    return distance <= self.detect_range
end

-- 检查是否在仇恨范围内
function MonsterEntity:is_in_aggro_range(target)
    if not target then
        return false
    end
    
    local dx = target.x - self.x
    local dy = target.y - self.y
    local distance = math.sqrt(dx * dx + dy * dy)
    
    return distance <= self.aggro_range
end

-- 设置巡逻中心点（实体接口）
function MonsterEntity:set_patrol_center(x, y)
    if self.ai_manager then
        local blackboard = self.ai_manager:get_blackboard()
        if blackboard then
            blackboard:set_entity_data("patrol_center_x", x, "monster_set_patrol")
            blackboard:set_entity_data("patrol_center_y", y, "monster_set_patrol")
        end
    end
    
    log.debug("MonsterEntity: 设置巡逻中心点 %s: (%f, %f)", self.id, x, y)
    return self
end

-- AI管理器相关方法
function MonsterEntity:set_ai_manager(ai_manager)
    self.ai_manager = ai_manager
    return self
end

function MonsterEntity:get_ai_manager()
    return self.ai_manager
end

function MonsterEntity:create_ai_manager(config)
    local AIManager = require "scene.ai.ai_manager"
    self.ai_manager = AIManager.new(self, config)
    return self.ai_manager
end

function MonsterEntity:update_behavior_tree(dt)
    if self.ai_manager then
        self.ai_manager:update(dt)
    end
end

function MonsterEntity:get_behavior_tree()
    if self.ai_manager then
        return self.ai_manager:get_behavior_tree()
    end
    return nil
end

-- 获取当前状态名称
function MonsterEntity:get_current_state_name()
    if self.ai_manager then
        return self.ai_manager:get_current_state()
    end
    return "none"
end

-- 获取状态持续时间
function MonsterEntity:get_state_time()
    if self.ai_manager then
        return self.ai_manager:get_state_time()
    end
    return 0
end

-- 便捷方法
function MonsterEntity:request_state(state_name)
    if self.ai_manager then
        self.ai_manager:request_state(state_name)
    end
end

function MonsterEntity:set_move_target(x, y)
    if self.ai_manager then
        self.ai_manager:set_move_target(x, y)
    end
    
    log.debug("MonsterEntity: 设置移动目标 %s: (%f, %f)", self.id, x, y)
    return self
end

function MonsterEntity:get_blackboard()
    if self.ai_manager then
        return self.ai_manager:get_blackboard()
    end
    return nil
end

return MonsterEntity