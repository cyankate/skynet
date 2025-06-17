local skynet = require "skynet"
local StateEntity = require "scene.state_entity"
local Entity = require "scene.entity"
local class = require "utils.class"
local log = require "log"
local protocol_handler = require "protocol_handler"

local PlayerEntity = class("PlayerEntity", StateEntity)

function PlayerEntity:ctor(id, player_data)
    PlayerEntity.super.ctor(self, id, Entity.ENTITY_TYPE.PLAYER)
    
    -- 玩家特有属性
    self.name = player_data.name
    self.level = player_data.level or 1
    self.profession = player_data.profession
    self.hp = player_data.hp or 100
    self.max_hp = player_data.max_hp or 100
    self.mp = player_data.mp or 100
    self.max_mp = player_data.max_mp or 100
    self.exp = player_data.exp or 0
    self.speed = player_data.speed or 5
    self.attack = player_data.attack or 10
    self.defense = player_data.defense or 5
    
    -- 设置玩家默认视野
    self.view_range = 200
    
    -- 移动相关
    self.auto_moving = false  -- 是否自动移动（如寻路移动）
end

-- 移动相关钩子方法
function PlayerEntity:on_move_start()
    if self.auto_moving then
        -- 通知客户端开始自动移动
        self:send_message("auto_move_start", {
            path = self.move_path
        })
    end
end

function PlayerEntity:on_move_end()
    if self.auto_moving then
        self.auto_moving = false
        -- 通知客户端停止自动移动
        self:send_message("auto_move_stop", {})
    end
end

function PlayerEntity:on_move_update()
    -- 可以在这里添加移动中的特殊效果
    -- 比如移动时的buff检查等
end

-- 停止自动移动
function PlayerEntity:stop_auto_move()
    if self.auto_moving then
        self.auto_moving = false
        self.move_path = nil
        self.move_path_index = 1
        
        -- 如果当前是移动状态，切换到空闲状态
        if self.current_state == StateEntity.STATE.MOVING then
            self:change_state(StateEntity.STATE.IDLE)
        end
        
        -- 通知客户端停止自动移动
        self:send_message("auto_move_stop", {})
    end
end

-- 处理客户端移动请求
function PlayerEntity:handle_move_request(x, y)
    -- 如果正在自动移动，先停止
    if self.auto_moving then
        self:stop_auto_move()
    end
    
    -- 验证移动是否合法
    if not self:can_move_to(x, y) then
        -- 发送位置校正
        self:send_message("position_correction", {
            x = self.x,
            y = self.y
        })
        return false
    end
    
    -- 更新位置
    self:set_position(x, y)
    
    -- 切换到移动状态
    if self.current_state ~= StateEntity.STATE.MOVING then
        self:change_state(StateEntity.STATE.MOVING)
    end
    
    return true
end

-- 检查是否可以移动到目标位置
function PlayerEntity:can_move_to(x, y)
    -- 检查是否在地图范围内
    if not self.scene:is_position_valid(x, y) then
        return false
    end
    
    -- 检查是否被禁止移动（如眩晕状态）
    if self.current_state == StateEntity.STATE.STUNNED then
        return false
    end
    
    -- 检查移动距离是否合理（防止作弊）
    local dx = x - self.x
    local dy = y - self.y
    local distance = math.sqrt(dx * dx + dy * dy)
    local max_distance = self.speed * 0.1  -- 假设100ms移动一次
    
    if distance > max_distance then
        return false
    end
    
    -- 检查是否有碰撞
    if self.scene:has_collision(self.x, self.y, x, y) then
        return false
    end
    
    return true
end

-- 重写更新方法
function PlayerEntity:update()
    -- 调用父类更新
    PlayerEntity.super.update(self)
    
    -- 如果不是自动移动，且当前是移动状态，检查是否需要停止移动
    if not self.auto_moving and self.current_state == StateEntity.STATE.MOVING then
        -- 这里可以添加一些额外的移动状态检查
        -- 例如：如果一段时间没有收到客户端的移动请求，就停止移动状态
    end
end

-- 执行攻击
function PlayerEntity:perform_attack(target)
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

-- 执行技能
function PlayerEntity:perform_skill(skill_id, target_id)
    -- 获取技能配置
    local skill_config = self:get_skill_config(skill_id)
    if not skill_config then
        return false, "技能不存在"
    end
    
    -- 检查目标
    local target = target_id and self.scene:get_entity(target_id)
    if skill_config.need_target and not target then
        return false, "目标不存在"
    end
    
    -- 检查MP
    if self.mp < skill_config.mp_cost then
        return false, "魔法值不足"
    end
    
    -- 扣除MP
    self.mp = self.mp - skill_config.mp_cost
    
    -- 执行技能效果
    if skill_config.effect then
        skill_config.effect(self, target)
    end
    
    -- 广播技能消息
    self:broadcast_message("entity_skill", {
        caster_id = self.id,
        skill_id = skill_id,
        target_id = target_id,
        mp = self.mp,
        max_mp = self.max_mp
    })
    
    return true
end

-- 获取技能配置
function PlayerEntity:get_skill_config(skill_id)
    -- TODO: 从技能配置表获取
    return {
        id = skill_id,
        name = "测试技能",
        cast_time = 1.0,
        mp_cost = 10,
        need_target = true,
        effect = function(caster, target)
            -- 示例:造成50点伤害
            target:take_damage(50, caster)
        end
    }
end

-- 受到伤害
function PlayerEntity:take_damage(damage, attacker)
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
    
    -- 检查死亡
    if self.hp <= 0 then
        self:handle_death(attacker)
    end
    
    return actual_damage
end

-- 复活处理
function PlayerEntity:respawn()
    -- 恢复生命值和魔法值
    self.hp = self.max_hp
    self.mp = self.max_mp
    
    -- 切换到空闲状态
    self:change_state(StateEntity.STATE.IDLE)
    
    -- 广播复活消息
    self:broadcast_message("entity_respawn", {
        entity_id = self.id,
        hp = self.hp,
        max_hp = self.max_hp,
        mp = self.mp,
        max_mp = self.max_mp
    })
end

-- 当其他实体进入视野
function PlayerEntity:on_entity_enter(other)
    -- 发送实体进入视野消息给客户端
    self:send_message("entity_enter", {
        entity_id = other.id,
        entity_type = other.type,
        x = other.x,
        y = other.y,
        state = other.current_state,
        properties = other.properties,
        -- 如果是玩家,发送玩家信息
        player_data = other.type == Entity.ENTITY_TYPE.PLAYER and {
            name = other.name,
            level = other.level,
            profession = other.profession,
            hp = other.hp,
            max_hp = other.max_hp,
            mp = other.mp,
            max_mp = other.max_mp
        } or nil,
        -- 如果是怪物,发送怪物信息
        monster_data = other.type == Entity.ENTITY_TYPE.MONSTER and {
            name = other.name,
            level = other.level,
            hp = other.hp,
            max_hp = other.max_hp
        } or nil
    })
end

-- 当其他实体离开视野
function PlayerEntity:on_entity_leave(other)
    -- 发送实体离开视野消息给客户端
    self:send_message("entity_leave", {
        entity_id = other.id,
        entity_type = other.type
    })
end

-- 发送消息给客户端
function PlayerEntity:send_message(name, data)
    protocol_handler.send_to_player(self.id, name, data)
end

return PlayerEntity