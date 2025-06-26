local skynet = require "skynet"
local StateEntity = require "scene.state_entity"
local Entity = require "scene.entity"
local class = require "utils.class"
local log = require "log"
local protocol_handler = require "protocol_handler"

local PlayerEntity = class("PlayerEntity", StateEntity)

function PlayerEntity:ctor(id, x, y)
    StateEntity.ctor(self, id, "player")
    
    -- 设置初始位置
    self:set_position(x, y)
    
    -- 玩家特有属性
    self.name = "玩家" .. id
    self.level = 1
    self.exp = 0
    self.max_exp = 100
    self.mana = 100
    self.max_mana = 100
    self.stamina = 100
    self.max_stamina = 100
    
    -- 战斗相关
    self.attack_power = 20
    self.defense = 10
    self.critical_rate = 0.1
    self.critical_damage = 1.5
    self.attack_speed = 1.0
    self.attack_range = 2.0
    
    -- 创建AI管理器
    self:create_ai_manager()
    
    log.info("PlayerEntity: 创建玩家 %d 在位置 (%.1f, %.1f)", id, x, y)
end

-- 创建AI管理器
function PlayerEntity:create_ai_manager()
    local AIManager = require "scene.ai.ai_manager"
    self.ai_manager = AIManager.new(self, {
        sync_interval = 0.1,
        enable_logging = true
    })
    
    log.debug("PlayerEntity: 创建AI管理器 %s", self.id)
end

function PlayerEntity:can_attack()
    -- 检查攻击冷却、目标是否存在等
    if not self.target_id then
        return false
    end
    
    local target = self.scene:get_entity(self.target_id)
    if not target then
        return false
    end
    
    -- 检查距离
    local dx = target.x - self.x
    local dy = target.y - self.y
    local distance = math.sqrt(dx * dx + dy * dy)
    
    return distance <= self.attack_range
end

function PlayerEntity:perform_attack(target)
    if not target then
        return false
    end
    
    -- 计算伤害
    local damage = self.attack_power
    local is_critical = math.random() < self.critical_rate
    
    if is_critical then
        damage = damage * self.critical_damage
    end
    
    -- 应用防御
    damage = math.max(1, damage - target.defense)
    
    -- 造成伤害
    target:take_damage(damage, self)
    
    log.info("PlayerEntity: 玩家 %d 攻击目标 %d，造成 %d 伤害%s", 
             self.id, target.id, damage, is_critical and "（暴击）" or "")
    
    return true
end

-- 重写父类的update方法，添加玩家特有的更新逻辑
function PlayerEntity:update()
    -- 更新基础实体（包括AI管理器）
    StateEntity.update(self)
end

-- 检查是否可以移动
function PlayerEntity:can_move()
    if self.hp <= 0 then
        return false, "玩家已死亡"
    end
    
    local current_state = self:get_current_state_name()
    if current_state == "stunned" then
        return false, "玩家被眩晕"
    end
    
    if current_state == "dead" then
        return false, "玩家已死亡"
    end
    
    return true
end

-- 创建玩家实体的工厂方法
local function create_player_entity(id, x, y)
    return PlayerEntity.new(id, x, y)
end

return {
    PlayerEntity = PlayerEntity,
    create_player_entity = create_player_entity
}