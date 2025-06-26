local class = require "utils.class"
local log = require "log"
local StateMachine = require "scene.ai.state_machine"

-- 空闲状态
local IdleState = class("IdleState", StateMachine.IdleState)

function IdleState:ctor()
    StateMachine.IdleState.ctor(self, StateMachine.STATE.IDLE)
end

function IdleState:update(context, dt)
    local monster = context.entity
    
    -- 检查是否需要切换到其他状态
    if monster:is_in_combat() then
        self.machine:change_state(StateMachine.STATE.CHASE)
        return "running"
    end
    
    if monster:should_patrol() then
        self.machine:change_state(StateMachine.STATE.PATROL)
        return "running"
    end
    
    return "running"
end

-- 巡逻状态
local PatrolState = class("PatrolState", StateMachine.State)

function PatrolState:ctor()
    StateMachine.State.ctor(self, StateMachine.STATE.PATROL)
end

function PatrolState:enter(context)
    local monster = context.entity
    monster:play_animation("walk")
    
end

function PatrolState:update(context, dt)
    local monster = context.entity
    
    -- 检查是否被中断
    if context.is_interrupted then
        return "failure"
    end
    
    -- 更新移动
    monster:update_move(dt)
    
    return "running"
end

function PatrolState:exit(context)
    local monster = context.entity
    log.info("Monster %d 退出巡逻状态", monster.id)
end

function PatrolState:interrupt(context)
    local monster = context.entity
    monster:stop_move()
end

-- 追击状态
local ChaseState = class("ChaseState", StateMachine.State)

function ChaseState:ctor()
    StateMachine.State.ctor(self, StateMachine.STATE.CHASE)
end

function ChaseState:enter(context)
    local monster = context.entity
    monster:play_animation("run")
    log.info("Monster %d 开始追击", monster.id)
end

function ChaseState:update(context, dt)
    local monster = context.entity
    local target = monster:get_combat_target()
    
    -- 检查是否被中断
    if context.is_interrupted then
        return "failure"
    end
    
    -- 检查目标是否还在
    if not target or target.hp <= 0 then
        monster:stop_move()
        monster:exit_combat()
        self.machine:change_state(StateMachine.STATE.IDLE)
        return "running"
    end
    
    -- 检查是否需要逃跑
    if monster.hp < monster.max_hp * 0.2 then
        monster:stop_move()
        self.machine:change_state(StateMachine.STATE.FLEE)
        return "running"
    end
    
    -- 检查是否在攻击范围内
    if monster:is_in_attack_range(target) then
        monster:stop_move()
        self.machine:change_state(StateMachine.STATE.ATTACKING)
        return "running"
    end
    
    -- 继续追击
    if not monster:is_moving() then
        monster:handle_move(target.x, target.y)
    end
    
    -- 更新移动
    monster:update_move(dt)
    
    return "running"
end

function ChaseState:exit(context)
    local monster = context.entity
    log.info("Monster %d 退出追击状态", monster.id)
end

function ChaseState:interrupt(context)
    local monster = context.entity
    monster:stop_move()
end

-- 攻击状态
local AttackState = class("AttackState", StateMachine.State)

function AttackState:ctor()
    StateMachine.State.ctor(self, StateMachine.STATE.ATTACKING)
end

function AttackState:enter(context)
    local monster = context.entity
    monster:play_animation("attack")
    log.info("Monster %d 开始攻击", monster.id)
end

function AttackState:update(context, dt)
    local monster = context.entity
    local target = monster:get_combat_target()
    
    -- 检查是否被中断
    if context.is_interrupted then
        return "failure"
    end
    
    -- 检查目标是否还在
    if not target or target.hp <= 0 then
        monster:exit_combat()
        self.machine:change_state(StateMachine.STATE.IDLE)
        return "running"
    end
    
    -- 检查是否需要逃跑
    if monster.hp < monster.max_hp * 0.2 then
        self.machine:change_state(StateMachine.STATE.FLEE)
        return "running"
    end
    
    -- 执行普通攻击
    if monster:can_attack(target) then
        monster:perform_attack(target)
        -- 攻击完成后，检查目标是否还在攻击范围内
        if not monster:is_in_attack_range(target) then
            self.machine:change_state(StateMachine.STATE.CHASE)
        else
            self.machine:change_state(StateMachine.STATE.IDLE)  -- 短暂休息
        end
        return "running"
    end
    
    return "running"
end

function AttackState:exit(context)
    local monster = context.entity
    log.info("Monster %d 退出攻击状态", monster.id)
end

-- 逃跑状态
local FleeState = class("FleeState", StateMachine.State)

function FleeState:ctor()
    StateMachine.State.ctor(self, StateMachine.STATE.FLEE)
end

function FleeState:enter(context)
    local monster = context.entity
    monster:play_animation("flee")
    
    -- 计算逃跑方向
    local threat = monster:get_nearest_threat()
    if threat then
        local dx = monster.x - threat.x
        local dy = monster.y - threat.y
        local distance = math.sqrt(dx * dx + dy * dy)
        
        if distance < 0.1 then
            dx, dy = 1, 0  -- 默认向右逃跑
        else
            dx, dy = dx / distance, dy / distance
        end
        
        -- 计算逃跑目标点
        local flee_distance = monster.flee_distance or 20
        context.flee_target = {
            x = monster.x + dx * flee_distance,
            y = monster.y + dy * flee_distance
        }
        
        monster:handle_move(context.flee_target.x, context.flee_target.y)
    end
    
    log.info("Monster %d 开始逃跑", monster.id)
end

function FleeState:update(context, dt)
    local monster = context.entity
    local flee_target = context.flee_target
    
    -- 检查是否被中断
    if context.is_interrupted then
        return "failure"
    end
    
    -- 检查是否到达逃跑目标
    if monster:is_reached_target(flee_target) then
        monster:exit_combat()
        self.machine:change_state(StateMachine.STATE.IDLE)
        return "running"
    end
    
    -- 更新移动
    monster:update_move(dt)
    
    return "running"
end

function FleeState:exit(context)
    local monster = context.entity
    log.info("Monster %d 退出逃跑状态", monster.id)
end

function FleeState:interrupt(context)
    local monster = context.entity
    monster:stop_move()
end

-- 怪物眩晕状态
local MonsterStunnedState = class("MonsterStunnedState", StateMachine.StunnedState)

function MonsterStunnedState:ctor(duration)
    StateMachine.StunnedState.ctor(self, StateMachine.STATE.STUNNED, duration)
end

function MonsterStunnedState:enter(context)
    local monster = context.entity
    StateMachine.StunnedState.enter(self, context)
    
    -- 怪物特有的眩晕逻辑
    log.info("Monster %d 被眩晕，持续 %.1f 秒", monster.id, self.duration)
end

function MonsterStunnedState:update(context, dt)
    local monster = context.entity
    
    -- 检查怪物是否死亡
    if monster.hp <= 0 then
        self.machine:change_state(StateMachine.STATE.DEAD)
        return "running"
    end
    
    -- 调用父类的更新逻辑
    return StateMachine.StunnedState.update(self, context, dt)
end

function MonsterStunnedState:exit(context)
    local monster = context.entity
    StateMachine.StunnedState.exit(self, context)
    
    -- 眩晕结束后切换到待机状态
    self.machine:change_state(StateMachine.STATE.IDLE)
    log.info("Monster %d 眩晕结束，恢复正常", monster.id)
end

-- 怪物死亡状态
local MonsterDeadState = class("MonsterDeadState", StateMachine.DeadState)

function MonsterDeadState:ctor()
    StateMachine.DeadState.ctor(self, StateMachine.STATE.DEAD)
end

function MonsterDeadState:enter(context)
    local monster = context.entity
    StateMachine.DeadState.enter(self, context)
    
    -- 怪物特有的死亡逻辑
    log.info("Monster %d 死亡", monster.id)
    
    -- 掉落物品
    monster:drop_loot()
    
    -- 给予经验值
    local killer = monster.last_attacker
    if killer then
        killer:add_exp(monster.exp_reward)
    end
end

function MonsterDeadState:update(context, dt)
    local monster = context.entity
    
    -- 怪物死亡后可以设置重生时间
    -- 这里可以添加重生逻辑，或者保持死亡状态直到被清理
    if self.machine:get_state_time() >= 10.0 then  -- 10秒后重生
        monster:respawn()
        self.machine:change_state(StateMachine.STATE.IDLE)
        return "running"
    end
    
    return "running"
end

function MonsterDeadState:exit(context)
    local monster = context.entity
    StateMachine.DeadState.exit(self, context)
    
    log.info("Monster %d 重生", monster.id)
end

-- 怪物AI状态机（单一状态机管理所有状态）
local MonsterStateMachine = class("MonsterStateMachine", StateMachine.StateMachine)

function MonsterStateMachine:ctor()
    StateMachine.StateMachine.ctor(self, "怪物AI状态机")
    
    -- 添加所有AI状态
    self:add_state(IdleState.new())
        :add_state(PatrolState.new())
        :add_state(ChaseState.new())
        :add_state(AttackState.new())
        :add_state(FleeState.new())
        :add_state(StateMachine.MoveState.new())
        :add_state(MonsterStunnedState.new(2.0))  -- 默认眩晕2秒
        :add_state(MonsterDeadState.new())
        :set_initial_state(StateMachine.STATE.IDLE)
    
    -- 配置状态打断机制
    self:set_state_interruptible(StateMachine.STATE.IDLE, true)      -- 待机状态可被打断
    self:set_state_interruptible(StateMachine.STATE.PATROL, true)    -- 巡逻状态可被打断
    self:set_state_interruptible(StateMachine.STATE.CHASE, true)     -- 追击状态可被打断
    self:set_state_interruptible(StateMachine.STATE.ATTACKING, true) -- 攻击状态可被打断
    self:set_state_interruptible(StateMachine.STATE.FLEE, false)     -- 逃跑状态不可被打断
    self:set_state_interruptible(StateMachine.STATE.STUNNED, false)  -- 眩晕状态不可被打断
    self:set_state_interruptible(StateMachine.STATE.DEAD, false)     -- 死亡状态不可被打断
    
    -- 设置状态优先级
    self:set_priority_state(StateMachine.STATE.DEAD, 10)      -- 死亡最高优先级
    self:set_priority_state(StateMachine.STATE.STUNNED, 8)    -- 眩晕高优先级
    self:set_priority_state(StateMachine.STATE.FLEE, 3)       -- 逃跑高优先级
    self:set_priority_state(StateMachine.STATE.ATTACKING, 1)  -- 攻击中等优先级
    self:set_priority_state(StateMachine.STATE.CHASE, 1)      -- 追击中等优先级
    self:set_priority_state(StateMachine.STATE.PATROL, 0)     -- 巡逻低优先级
    self:set_priority_state(StateMachine.STATE.IDLE, 0)       -- 待机最低优先级
end

-- 创建怪物状态机实例
local function create_monster_state_machine()
    return MonsterStateMachine.new()
end

return {
    MonsterStateMachine = MonsterStateMachine,
    create_monster_state_machine = create_monster_state_machine,
    -- 导出各个状态类，方便单独使用
    IdleState = IdleState,
    PatrolState = PatrolState,
    ChaseState = ChaseState,
    AttackState = AttackState,
    FleeState = FleeState,
    MonsterStunnedState = MonsterStunnedState,
    MonsterDeadState = MonsterDeadState
} 