local skynet = require "skynet"
local Entity = require "scene.entity"
local StateEntity = require "scene.state_entity"
local class = require "utils.class"
local log = require "log"
local MonsterStateMachine = require "scene.ai.monster_state_machine"

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
    
    -- 创建状态机
    local state_machine = MonsterStateMachine.create_monster_state_machine()
    self:set_state_machine(state_machine)
    
    -- 初始化怪物特有的黑板同步配置
    self:init_monster_blackboard_sync()
    
    log.debug("MonsterEntity: 创建怪物 %s (类型: %s)", self.id, self.monster_type)
end

-- 初始化怪物特有黑板同步配置
function MonsterEntity:init_monster_blackboard_sync()
    -- 使用静态配置
    for key, config in pairs(SyncConfig.MONSTER_ENTITY_SYNC_CONFIG) do
        self.blackboard:add_sync_config(key, config)
    end
    
    -- 设置初始值
    self.blackboard:set("in_combat", false, "entity_init")
    self.blackboard:set("combat_target", nil, "entity_init")
    self.blackboard:set("last_attacker", nil, "entity_init")
    self.blackboard:set("patrol_center_x", 0, "entity_init")
    self.blackboard:set("patrol_center_y", 0, "entity_init")
    self.blackboard:set("attack_cooldown", 0, "entity_init")
    self.blackboard:set("max_hp", self.max_hp, "entity_init")
    self.blackboard:set("attack_power", self.attack_power, "entity_init")
    self.blackboard:set("defense", self.defense, "entity_init")
    self.blackboard:set("attack_range", self.attack_range, "entity_init")
    self.blackboard:set("move_speed", self.move_speed, "entity_init")
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
    
    -- 记录攻击者到黑板，让行为树处理战斗状态
    self.blackboard:set("last_attacker", attacker.id)
    self.last_attacker = attacker
    
    -- 检查死亡
    if self.hp <= 0 then
        self:on_death(attacker)
    end
    
    return actual_damage
end

-- 战斗状态管理（保持向后兼容）
function MonsterEntity:enter_combat(target)
    local current_target = self.blackboard:get("combat_target")
    if current_target == target then
        return false
    end
    
    self.blackboard:set("in_combat", true, "monster_enter_combat")
    self.blackboard:set("combat_target", target and target.id or nil, "monster_enter_combat")
    
    log.debug("MonsterEntity: 进入战斗 %s -> %s", self.id, target and target.id or "nil")
    
    return true
end

function MonsterEntity:exit_combat()
    local in_combat = self.blackboard:get("in_combat", false)
    if not in_combat then
        return false
    end
    
    self.blackboard:set("in_combat", false, "monster_exit_combat")
    self.blackboard:set("combat_target", nil, "monster_exit_combat")
    
    log.debug("MonsterEntity: 退出战斗 %s", self.id)
    
    return true
end

function MonsterEntity:is_in_combat()
    return self.blackboard:get("in_combat", false)
end

-- 设置战斗目标（实体接口）
function MonsterEntity:set_combat_target(target)
    self.blackboard:set("combat_target", target, "entity_set_combat_target")
    
    if target then
        log.debug("MonsterEntity: 设置战斗目标 %s: %s", self.id, target.id)
    else
        log.debug("MonsterEntity: 清除战斗目标 %s", self.id)
    end
    
    return self
end

-- 获取战斗目标
function MonsterEntity:get_combat_target()
    return self.blackboard:get("combat_target")
end

-- 设置最后攻击者（实体接口）
function MonsterEntity:set_last_attacker(attacker)
    self.blackboard:set("last_attacker", attacker, "entity_set_last_attacker")
    
    if attacker then
        log.debug("MonsterEntity: 设置最后攻击者 %s: %s", self.id, attacker.id)
    end
    
    return self
end

-- 获取最后攻击者
function MonsterEntity:get_last_attacker()
    return self.blackboard:get("last_attacker")
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
    local attack_cooldown = self.blackboard:get("attack_cooldown", 0)
    local is_dead = self.blackboard:get("is_dead", false)
    return attack_cooldown <= 0 and not is_dead
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

function MonsterEntity:get_nearest_threat()
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

-- 设置最后攻击者（实体接口）
function MonsterEntity:set_last_attacker(attacker)
    self.blackboard:set("last_attacker", attacker and attacker.id or nil, "monster_set_attacker")
    
    log.debug("MonsterEntity: 设置最后攻击者 %s: %s", self.id, attacker and attacker.id or "nil")
    
    return self
end

-- 获取最后攻击者
function MonsterEntity:get_last_attacker()
    return self.blackboard:get_entity_attr("last_attacker")
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
    self.blackboard:set("patrol_center_x", x, "monster_set_patrol")
    self.blackboard:set("patrol_center_y", y, "monster_set_patrol")
    
    log.debug("MonsterEntity: 设置巡逻中心点 %s: (%f, %f)", self.id, x, y)
    
    return self
end

-- 获取巡逻中心点
function MonsterEntity:get_patrol_center()
    local x = self.blackboard:get("patrol_center_x", self.x)
    local y = self.blackboard:get("patrol_center_y", self.y)
    return x, y
end

-- 生成随机巡逻目标（实体接口）
function MonsterEntity:generate_patrol_target()
    local patrol_center_x = self.blackboard:get("patrol_center_x", self.x)
    local patrol_center_y = self.blackboard:get("patrol_center_y", self.y)
    
    local angle = math.random() * 2 * math.pi
    local distance = math.random() * self.patrol_radius
    
    local target_x = patrol_center_x + math.cos(angle) * distance
    local target_y = patrol_center_y + math.sin(angle) * distance
    
    self:set_move_target(target_x, target_y)
    
    log.debug("MonsterEntity: 生成巡逻目标 %s: (%f, %f)", self.id, target_x, target_y)
    
    return target_x, target_y
end

-- 检查是否在巡逻范围内
function MonsterEntity:is_in_patrol_range()
    local patrol_center_x = self.blackboard:get("patrol_center_x", self.x)
    local patrol_center_y = self.blackboard:get("patrol_center_y", self.y)
    
    local dx = self.x - patrol_center_x
    local dy = self.y - patrol_center_y
    local distance = math.sqrt(dx * dx + dy * dy)
    
    return distance <= self.patrol_radius
end

-- 获取调试信息
function MonsterEntity:get_debug_info()
    local info = MonsterEntity.super.get_debug_info(self)
    
    -- 添加怪物特有信息
    info.monster_type = self.monster_type
    info.combat = {
        in_combat = self.blackboard:get("in_combat", false),
        combat_target = self.blackboard:get("combat_target"),
        last_attacker = self.blackboard:get("last_attacker"),
        attack_cooldown = self.blackboard:get("attack_cooldown", 0),
        attack_range = self.attack_range,
        attack_damage = self.attack_damage
    }
    info.movement = {
        move_speed = self.move_speed,
        patrol_radius = self.patrol_radius,
        patrol_center = {
            x = self.blackboard:get("patrol_center_x", self.x),
            y = self.blackboard:get("patrol_center_y", self.y)
        }
    }
    info.detection = {
        detect_range = self.detect_range,
        aggro_range = self.aggro_range
    }
    
    return info
end

return MonsterEntity