local class = require "utils.class"
local log = require "log"
local StateMachine = require "scene.ai.state_machine"

-- 玩家待机状态
local PlayerIdleState = class("PlayerIdleState", StateMachine.IdleState)

function PlayerIdleState:ctor()
    StateMachine.IdleState.ctor(self, StateMachine.STATE.IDLE)
end

function PlayerIdleState:update(context, dt)
    local player = context.entity
    
    -- 玩家待机时可以执行各种操作
    -- 这里可以添加玩家的待机逻辑，比如自动恢复、检查任务等
    
    return "running"
end

-- 玩家移动状态
local PlayerMoveState = class("PlayerMoveState", StateMachine.MoveState)

function PlayerMoveState:ctor()
    StateMachine.MoveState.ctor(self, StateMachine.STATE.MOVING)
end

function PlayerMoveState:enter(context)
    local player = context.entity
    player:play_animation("walk")
    log.info("Player %d 开始移动", player.id)
end

function PlayerMoveState:exit(context)
    local player = context.entity
    log.info("Player %d 停止移动", player.id)
end

-- 玩家攻击状态
local PlayerAttackState = class("PlayerAttackState", StateMachine.State)

function PlayerAttackState:ctor()
    StateMachine.State.ctor(self, StateMachine.STATE.ATTACKING)
end

function PlayerAttackState:enter(context)
    local player = context.entity
    player:play_animation("attack")
    log.info("Player %d 开始攻击", player.id)
end

function PlayerAttackState:update(context, dt)
    local player = context.entity
    local target = player.target_id and player.scene:get_entity(player.target_id)
    
    if not target or target.hp <= 0 then
        self.machine:change_state(StateMachine.STATE.IDLE)
        return "running"
    end
    
    -- 执行攻击逻辑
    if player:can_attack() then
        player:perform_attack(target)
        self.machine:change_state(StateMachine.STATE.IDLE)
        return "running"
    end
    
    return "running"
end

function PlayerAttackState:exit(context)
    local player = context.entity
    log.info("Player %d 退出攻击状态", player.id)
end

-- 玩家眩晕状态
local PlayerStunnedState = class("PlayerStunnedState", StateMachine.StunnedState)

function PlayerStunnedState:ctor(duration)
    StateMachine.StunnedState.ctor(self, StateMachine.STATE.STUNNED, duration)
end

function PlayerStunnedState:enter(context)
    local player = context.entity
    StateMachine.StunnedState.enter(self, context)
    
    -- 玩家特有的眩晕逻辑
    log.info("Player %d 被眩晕，持续 %.1f 秒", player.id, self.duration)
end

function PlayerStunnedState:update(context, dt)
    local player = context.entity
    
    -- 检查玩家是否死亡
    if player.hp <= 0 then
        self.machine:change_state(StateMachine.STATE.DEAD)
        return "running"
    end
    
    -- 调用父类的更新逻辑
    return StateMachine.StunnedState.update(self, context, dt)
end

function PlayerStunnedState:exit(context)
    local player = context.entity
    StateMachine.StunnedState.exit(self, context)
    
    -- 眩晕结束后切换到待机状态
    self.machine:change_state(StateMachine.STATE.IDLE)
    log.info("Player %d 眩晕结束，恢复正常", player.id)
end

-- 玩家死亡状态
local PlayerDeadState = class("PlayerDeadState", StateMachine.DeadState)

function PlayerDeadState:ctor()
    StateMachine.DeadState.ctor(self, StateMachine.STATE.DEAD)
end

function PlayerDeadState:enter(context)
    local player = context.entity
    StateMachine.DeadState.enter(self, context)
    
    -- 玩家特有的死亡逻辑
    log.info("Player %d 死亡", player.id)
    
    -- 可以在这里添加死亡惩罚、掉落物品等逻辑
end

function PlayerDeadState:update(context, dt)
    local player = context.entity
    
    -- 检查是否应该复活（这里可以添加自动复活逻辑）
    -- 例如：5秒后自动复活
    if self.machine:get_state_time() >= 5.0 then
        player:respawn()
        self.machine:change_state(StateMachine.STATE.IDLE)
        return "running"
    end
    
    return "running"
end

function PlayerDeadState:exit(context)
    local player = context.entity
    StateMachine.DeadState.exit(self, context)
    
    log.info("Player %d 复活", player.id)
end

-- 玩家状态机
local PlayerStateMachine = class("PlayerStateMachine", StateMachine.StateMachine)

function PlayerStateMachine:ctor()
    StateMachine.StateMachine.ctor(self, "玩家状态机")
    
    -- 添加所有玩家状态
    self:add_state(PlayerIdleState.new())
        :add_state(PlayerMoveState.new())
        :add_state(PlayerAttackState.new())
        :add_state(PlayerStunnedState.new(2.0))  -- 默认眩晕2秒
        :add_state(PlayerDeadState.new())
        :set_initial_state(StateMachine.STATE.IDLE)
    
    -- 配置状态打断机制
    self:set_state_interruptible(StateMachine.STATE.IDLE, true)      -- 待机状态可被打断
    self:set_state_interruptible(StateMachine.STATE.MOVING, true)    -- 移动状态可被打断
    self:set_state_interruptible(StateMachine.STATE.ATTACKING, true) -- 攻击状态可被打断
    self:set_state_interruptible(StateMachine.STATE.STUNNED, false)  -- 眩晕状态不可被打断
    self:set_state_interruptible(StateMachine.STATE.DEAD, false)     -- 死亡状态不可被打断
    
    -- 设置状态优先级
    self:set_priority_state(StateMachine.STATE.DEAD, 10)      -- 死亡最高优先级
    self:set_priority_state(StateMachine.STATE.STUNNED, 8)    -- 眩晕高优先级
    self:set_priority_state(StateMachine.STATE.ATTACKING, 2)  -- 攻击中优先级
    self:set_priority_state(StateMachine.STATE.MOVING, 0)     -- 移动低优先级
    self:set_priority_state(StateMachine.STATE.IDLE, 0)       -- 待机最低优先级
end

-- 创建玩家状态机实例
local function create_player_state_machine()
    return PlayerStateMachine.new()
end

return {
    PlayerStateMachine = PlayerStateMachine,
    create_player_state_machine = create_player_state_machine,
    -- 导出各个状态类，方便单独使用
    PlayerIdleState = PlayerIdleState,
    PlayerMoveState = PlayerMoveState,
    PlayerAttackState = PlayerAttackState,
    PlayerStunnedState = PlayerStunnedState,
    PlayerDeadState = PlayerDeadState
} 