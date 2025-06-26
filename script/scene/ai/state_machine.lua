local class = require "utils.class"
local log = require "log"

-- 状态机
local StateMachine = class("StateMachine")

function StateMachine:ctor(name)
    self.name = name
    self.states = {}
    self.current_state = nil
    self.previous_state = nil
    self.is_running = false
    self.blackboard = nil
    self.entity = nil
    self.state_time = 0
end

-- 设置黑板和实体
function StateMachine:set_context(blackboard, entity)
    self.blackboard = blackboard
    self.entity = entity
    return self
end

-- 添加状态
function StateMachine:add_state(state)
    self.states[state.name] = state
    state.machine = self
    return self
end

-- 设置初始状态
function StateMachine:set_initial_state(state_name)
    self.initial_state = state_name
    return self
end

-- 启动状态机
function StateMachine:start()
    if self.is_running then
        return
    end
    
    self.is_running = true
    self.state_time = 0
    
    if self.initial_state and self.states[self.initial_state] then
        self:change_state(self.initial_state)
    end
end

-- 停止状态机
function StateMachine:stop()
    if self.current_state then
        self.current_state:exit()
    end
    self.is_running = false
    self.current_state = nil
    self.previous_state = nil
    self.state_time = 0
end

-- 更新状态机
function StateMachine:update(dt)
    if not self.is_running then
        return
    end
    
    self.state_time = self.state_time + (dt or 0.1)
    
    -- 更新当前状态
    if self.current_state then
        self.current_state:update(dt)
    end
end

-- 切换状态
function StateMachine:change_state(state_name)
    if not self.states[state_name] then
        log.error("StateMachine: 状态 %s 不存在", state_name)
        return false
    end
    
    if self.current_state and self.current_state.name == state_name then
        return false
    end
    
    -- 退出当前状态
    if self.current_state then
        self.current_state:exit()
        self.previous_state = self.current_state.name
    end
    
    -- 进入新状态
    self.current_state = self.states[state_name]
    self.state_time = 0
    self.current_state:enter()
    
    log.debug("StateMachine: 切换到状态 %s", state_name)
    return true
end

-- 获取当前状态名称
function StateMachine:get_current_state_name()
    return self.current_state and self.current_state.name or "none"
end

-- 获取状态持续时间
function StateMachine:get_state_time()
    return self.state_time
end

-- 检查是否在指定状态
function StateMachine:is_in_state(state_name)
    return self.current_state and self.current_state.name == state_name
end

-- 状态基类
local State = class("State")

function State:ctor(name)
    self.name = name
    self.machine = nil
end

function State:enter()
    -- 子类重写
end

function State:update(dt)
    -- 子类重写
end

function State:exit()
    -- 子类重写
end

-- 空闲状态
local IdleState = class("IdleState", State)

function IdleState:ctor()
    State.ctor(self, "idle")
end

function IdleState:enter()
    if self.machine.entity then
        self.machine.entity:play_animation("idle")
        log.debug("IdleState: 进入空闲状态")
    end
end

function IdleState:update(dt)
    -- 空闲状态不需要特殊处理
    -- 等待行为树决策
end

function IdleState:exit()
    log.debug("IdleState: 退出空闲状态")
end

-- 移动状态
local MovingState = class("MovingState", State)

function MovingState:ctor()
    State.ctor(self, "moving")
end

function MovingState:enter()
    if self.machine.entity then
        self.machine.entity:play_animation("walk")
        log.debug("MovingState: 进入移动状态")
    end
end

function MovingState:update(dt)
    local blackboard = self.machine.blackboard
    local entity = self.machine.entity
    
    if not blackboard or not entity then
        return
    end
    
    -- 检查是否有移动目标
    local move_target = blackboard:get("move_target")
    if not move_target then
        -- 没有移动目标，切换到空闲状态
        self.machine:change_state("idle")
        return
    end
    
    -- 执行移动
    if entity:can_move() then
        entity:move_to(move_target.x, move_target.y)
        
        -- 检查是否到达目标
        if entity:is_at_target(move_target) then
            blackboard:clear("move_target")
            self.machine:change_state("idle")
        end
    else
        -- 无法移动，切换到空闲状态
        self.machine:change_state("idle")
    end
end

function MovingState:exit()
    log.debug("MovingState: 退出移动状态")
end

-- 攻击状态
local AttackingState = class("AttackingState", State)

function AttackingState:ctor()
    State.ctor(self, "attacking")
end

function AttackingState:enter()
    if self.machine.entity then
        self.machine.entity:play_animation("attack")
        log.debug("AttackingState: 进入攻击状态")
    end
end

function AttackingState:update(dt)
    local blackboard = self.machine.blackboard
    local entity = self.machine.entity
    
    if not blackboard or not entity then
        return
    end
    
    -- 获取攻击目标
    local attack_target = blackboard:get("attack_target")
    if not attack_target then
        -- 没有攻击目标，切换到空闲状态
        self.machine:change_state("idle")
        return
    end
    
    -- 检查目标是否还在
    if not attack_target.scene or attack_target.hp <= 0 then
        blackboard:clear("attack_target")
        self.machine:change_state("idle")
        return
    end
    
    -- 检查是否在攻击范围内
    if entity:is_in_attack_range(attack_target) then
        -- 执行攻击
        if entity:can_attack() then
            entity:perform_attack(attack_target)
        end
    else
        -- 不在攻击范围内，切换到追击状态
        self.machine:change_state("chasing")
    end
end

function AttackingState:exit()
    log.debug("AttackingState: 退出攻击状态")
end

-- 追击状态
local ChasingState = class("ChasingState", State)

function ChasingState:ctor()
    State.ctor(self, "chasing")
end

function ChasingState:enter()
    if self.machine.entity then
        self.machine.entity:play_animation("walk")
        log.debug("ChasingState: 进入追击状态")
    end
end

function ChasingState:update(dt)
    local blackboard = self.machine.blackboard
    local entity = self.machine.entity
    
    if not blackboard or not entity then
        return
    end
    
    -- 获取攻击目标
    local attack_target = blackboard:get("attack_target")
    if not attack_target then
        -- 没有攻击目标，切换到空闲状态
        self.machine:change_state("idle")
        return
    end
    
    -- 检查目标是否还在
    if not attack_target.scene or attack_target.hp <= 0 then
        blackboard:clear("attack_target")
        self.machine:change_state("idle")
        return
    end
    
    -- 检查是否在攻击范围内
    if entity:is_in_attack_range(attack_target) then
        -- 到达攻击范围，切换到攻击状态
        self.machine:change_state("attacking")
        return
    end
    
    -- 追击目标
    if entity:can_move() then
        entity:move_to(attack_target.x, attack_target.y)
    else
        -- 无法移动，切换到空闲状态
        self.machine:change_state("idle")
    end
end

function ChasingState:exit()
    log.debug("ChasingState: 退出追击状态")
end

-- 巡逻状态
local PatrolState = class("PatrolState", State)

function PatrolState:ctor()
    State.ctor(self, "patrol")
end

function PatrolState:enter()
    if self.machine.entity then
        self.machine.entity:play_animation("walk")
        log.debug("PatrolState: 进入巡逻状态")
    end
end

function PatrolState:update(dt)
    local blackboard = self.machine.blackboard
    local entity = self.machine.entity
    
    if not blackboard or not entity then
        return
    end
    
    -- 检查是否有移动目标
    local move_target = blackboard:get("move_target")
    if not move_target then
        -- 没有移动目标，生成新的巡逻目标
        local patrol_center = blackboard:get("patrol_center")
        if patrol_center then
            local target_x, target_y = entity:generate_patrol_position(patrol_center.x, patrol_center.y, 10.0)
            blackboard:set("move_target", {x = target_x, y = target_y})
        else
            -- 没有巡逻中心，切换到空闲状态
            self.machine:change_state("idle")
            return
        end
    end
    
    -- 执行移动
    if entity:can_move() then
        entity:move_to(move_target.x, move_target.y)
        
        -- 检查是否到达目标
        if entity:is_at_target(move_target) then
            blackboard:clear("move_target")
            -- 到达巡逻点后等待一段时间
            self.machine:change_state("idle")
        end
    else
        -- 无法移动，切换到空闲状态
        self.machine:change_state("idle")
    end
end

function PatrolState:exit()
    log.debug("PatrolState: 退出巡逻状态")
end

-- 逃跑状态
local FleeState = class("FleeState", State)

function FleeState:ctor()
    State.ctor(self, "flee")
end

function FleeState:enter()
    if self.machine.entity then
        self.machine.entity:play_animation("walk")
        log.debug("FleeState: 进入逃跑状态")
    end
end

function FleeState:update(dt)
    local blackboard = self.machine.blackboard
    local entity = self.machine.entity
    
    if not blackboard or not entity then
        return
    end
    
    -- 检查是否有移动目标
    local move_target = blackboard:get("move_target")
    if not move_target then
        -- 没有移动目标，生成逃跑目标
        local target_x, target_y = entity:generate_flee_position(100.0)
        blackboard:set("move_target", {x = target_x, y = target_y})
    end
    
    -- 执行移动
    if entity:can_move() then
        entity:move_to(move_target.x, move_target.y)
        
        -- 检查是否到达目标
        if entity:is_at_target(move_target) then
            blackboard:clear("move_target")
            self.machine:change_state("idle")
        end
    else
        -- 无法移动，切换到空闲状态
        self.machine:change_state("idle")
    end
end

function FleeState:exit()
    log.debug("FleeState: 退出逃跑状态")
end

-- 眩晕状态
local StunnedState = class("StunnedState", State)

function StunnedState:ctor()
    State.ctor(self, "stunned")
end

function StunnedState:enter()
    if self.machine.entity then
        self.machine.entity:play_animation("stunned")
        log.debug("StunnedState: 进入眩晕状态")
    end
end

function StunnedState:update(dt)
    local entity = self.machine.entity
    
    if not entity then
        return
    end
    
    -- 检查是否还在眩晕
    if not entity:is_stunned() then
        self.machine:change_state("idle")
    end
end

function StunnedState:exit()
    log.debug("StunnedState: 退出眩晕状态")
end

-- 死亡状态
local DeadState = class("DeadState", State)

function DeadState:ctor()
    State.ctor(self, "dead")
end

function DeadState:enter()
    if self.machine.entity then
        self.machine.entity:play_animation("dead")
        log.debug("DeadState: 进入死亡状态")
    end
end

function DeadState:update(dt)
    -- 死亡状态不需要特殊处理
end

function DeadState:exit()
    log.debug("DeadState: 退出死亡状态")
end

-- 导出
return {
    StateMachine = StateMachine,
    State = State,
    IdleState = IdleState,
    MovingState = MovingState,
    AttackingState = AttackingState,
    ChasingState = ChasingState,
    PatrolState = PatrolState,
    FleeState = FleeState,
    StunnedState = StunnedState,
    DeadState = DeadState,
} 