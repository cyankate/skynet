local skynet = require "skynet"
local StateEntity = require "scene.state_entity"
local class = require "utils.class"
local log = require "log"
local MonsterAI = require "scene.ai.monster_ai"

local MonsterEntity = class("MonsterEntity", StateEntity)

-- 定义怪物AI状态
MonsterEntity.AI_STATE = {
    PATROL = "PATROL",       -- 巡逻
    CHASE = "CHASE",        -- 追击
    RETURN = "RETURN",      -- 返回出生点
    COMBAT = "COMBAT"       -- 战斗状态
}

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
    
    -- AI相关属性
    self.ai_state = MonsterEntity.AI_STATE.PATROL
    self.spawn_x = monster_data.x      -- 出生点X
    self.spawn_y = monster_data.y      -- 出生点Y
    self.patrol_radius = monster_data.patrol_radius or 50  -- 巡逻半径
    self.chase_radius = monster_data.chase_radius or 100   -- 追击半径
    self.attack_radius = monster_data.attack_radius or 20  -- 攻击半径
    self.target_id = nil              -- 当前目标
    self.last_patrol_time = 0         -- 上次巡逻时间
    self.patrol_interval = 3.0        -- 巡逻间隔
    
    -- 设置怪物视野
    self.view_range = monster_data.view_range or 150
    
    -- 技能相关
    self.skills = monster_data.skills or {}
    self.skill_cooldowns = {}
    
    -- 创建AI行为树
    self.behavior_tree = MonsterAI.create_monster_tree(self)
    self.ai_context = {}
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
    
    -- 进入战斗状态
    if not self:is_in_combat() then
        self:enter_combat(attacker)
    end
    
    -- 检查死亡
    if self.hp <= 0 then
        self:handle_death(attacker)
    end
    
    return actual_damage
end

-- 战斗状态管理
function MonsterEntity:enter_combat(target)
    self.in_combat = true
    self.combat_target = target
    self.ai_state = MonsterEntity.AI_STATE.COMBAT
end

function MonsterEntity:exit_combat()
    self.in_combat = false
    self.combat_target = nil
    self.ai_state = MonsterEntity.AI_STATE.PATROL
end

function MonsterEntity:is_in_combat()
    return self.in_combat
end

function MonsterEntity:get_combat_target()
    return self.combat_target
end

-- 技能相关
function MonsterEntity:can_use_skill()
    for skill_id, cooldown in pairs(self.skill_cooldowns) do
        if cooldown <= 0 then
            return true
        end
    end
    return false
end

function MonsterEntity:use_skill(target)
    for skill_id, cooldown in pairs(self.skill_cooldowns) do
        if cooldown <= 0 then
            local skill = self.skills[skill_id]
            if skill then
                -- 检查技能范围
                local dx = target.x - self.x
                local dy = target.y - self.y
                local distance = math.sqrt(dx * dx + dy * dy)
                
                if distance <= skill.range then
                    -- 使用技能
                    self:cast_skill(skill, target)
                    self.skill_cooldowns[skill_id] = skill.cooldown
                    return true
                end
            end
        end
    end
    return false
end

function MonsterEntity:cast_skill(skill, target)
    -- 由子类实现具体技能效果
end

function MonsterEntity:update_cooldowns(dt)
    for skill_id, cooldown in pairs(self.skill_cooldowns) do
        if cooldown > 0 then
            self.skill_cooldowns[skill_id] = cooldown - dt
        end
    end
end

-- 移动相关钩子方法
function MonsterEntity:on_move_start()
    -- 根据AI状态处理移动开始
    if self.ai_state == MonsterEntity.AI_STATE.CHASE then
        -- 追击状态下的特殊处理
        local target = self.scene:get_entity(self.target_id)
        if target then
            -- 可以播放追击动画或者音效
            self:broadcast_message("monster_chase_start", {
                monster_id = self.id,
                target_id = self.target_id
            })
        end
    elseif self.ai_state == MonsterEntity.AI_STATE.RETURN then
        -- 返回出生点时的特殊处理
        self:broadcast_message("monster_return", {
            monster_id = self.id
        })
    end
end

function MonsterEntity:on_move_end()
    -- 根据AI状态处理移动结束
    if self.ai_state == MonsterEntity.AI_STATE.CHASE then
        -- 追击结束时检查是否在攻击范围内
        local target = self.scene:get_entity(self.target_id)
        if target then
            local dx = target.x - self.x
            local dy = target.y - self.y
            local distance = math.sqrt(dx * dx + dy * dy)
            
            if distance <= self.attack_radius then
                -- 进入攻击状态
                self:change_state(StateEntity.STATE.ATTACKING)
            end
        end
    elseif self.ai_state == MonsterEntity.AI_STATE.RETURN then
        -- 返回出生点完成后切换到巡逻状态
        self.ai_state = MonsterEntity.AI_STATE.PATROL
    end
end

function MonsterEntity:on_move_update()
    -- 移动过程中的特殊处理
    if self.ai_state == MonsterEntity.AI_STATE.CHASE then
        -- 追击过程中检查目标是否还在追击范围内
        local target = self.scene:get_entity(self.target_id)
        if target then
            local dx = target.x - self.x
            local dy = target.y - self.y
            local distance = math.sqrt(dx * dx + dy * dy)
            
            if distance > self.chase_radius then
                -- 目标超出追击范围,返回出生点
                self.ai_state = MonsterEntity.AI_STATE.RETURN
                local path = self.scene:find_path(self.x, self.y, self.spawn_x, self.spawn_y)
                if path then
                    self:move_along_path(path)
                end
            end
        end
    end
end

function MonsterEntity:is_reached_target(target)
    if not target then return true end
    
    local dx = target.x - self.x
    local dy = target.y - self.y
    local distance = math.sqrt(dx * dx + dy * dy)
    
    return distance < 0.1
end

-- 更新AI
function MonsterEntity:update()
    -- 调用父类更新
    MonsterEntity.super.update(self)
    
    -- 死亡状态不执行AI
    if self.current_state == StateEntity.STATE.DEAD then
        return
    end
    
    -- 更新技能冷却
    self:update_cooldowns(1/60)  -- 假设60帧
    
    -- 执行行为树
    if self.behavior_tree then
        self.behavior_tree:run(self.ai_context)
    end
end

-- 查找最近的目标
function MonsterEntity:find_nearest_target()
    local nearest_target = nil
    local min_distance = self.view_range
    
    -- 获取视野范围内的所有玩家
    local surrounding = self:get_surrounding_entities()
    for _, entity in pairs(surrounding) do
        if entity.type == Entity.ENTITY_TYPE.PLAYER and
           entity.current_state ~= StateEntity.STATE.DEAD then
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

-- 死亡处理
function MonsterEntity:on_death(killer)
    -- 如果击杀者是玩家,给予经验值奖励
    if killer and killer.type == Entity.ENTITY_TYPE.PLAYER then
        killer.exp = killer.exp + self.exp_reward
        killer:send_message("gain_exp", {
            exp = self.exp_reward,
            total_exp = killer.exp
        })
    end
    
    -- 退出战斗状态
    self:exit_combat()
    
    -- 5秒后重生
    skynet.timeout(500, function()
        self:respawn()
    end)
end

-- 重生处理
function MonsterEntity:respawn()
    -- 恢复生命值
    self.hp = self.max_hp
    
    -- 重置位置到出生点
    self:set_position(self.spawn_x, self.spawn_y)
    
    -- 重置状态
    self:change_state(StateEntity.STATE.IDLE)
    self.ai_state = MonsterEntity.AI_STATE.PATROL
    self.target_id = nil
    self.last_patrol_time = skynet.now() / 100
    
    -- 重置技能冷却
    self.skill_cooldowns = {}
    
    -- 广播重生消息
    self:broadcast_message("entity_respawn", {
        entity_id = self.id,
        x = self.x,
        y = self.y,
        hp = self.hp,
        max_hp = self.max_hp
    })
end

-- 广播消息给周围实体
function MonsterEntity:broadcast_message(name, data)
    -- 获取周围实体
    local surrounding = self:get_surrounding_entities()
    
    -- 给所有周围的玩家发送消息
    for _, entity in pairs(surrounding) do
        if entity.type == Entity.ENTITY_TYPE.PLAYER then
            entity:send_message(name, data)
        end
    end
end

return MonsterEntity