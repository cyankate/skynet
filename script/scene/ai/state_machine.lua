local class = require "utils.class"
local log = require "log"

-- 通用状态常量
local STATE = {
    -- 基础状态
    IDLE = "idle",           -- 待机状态
    MOVING = "moving",       -- 移动状态
    ATTACKING = "attacking", -- 攻击状态
    STUNNED = "stunned",     -- 眩晕状态
    DEAD = "dead",          -- 死亡状态
    
    -- 怪物特有状态
    PATROL = "patrol",       -- 巡逻状态
    CHASE = "chase",         -- 追击状态
    FLEE = "flee",          -- 逃跑状态
}

-- 状态机基类
local StateMachine = class("StateMachine")

function StateMachine:ctor(name)
    self.name = name
    self.states = {}
    self.current_state = nil
    self.previous_state = nil
    self.is_running = false
    self.is_interrupted = false
    self.context = {}
    self.state_time = 0
    
    -- 状态打断配置
    self.interruptible_states = {}  -- 可被打断的状态
    self.priority_states = {}       -- 高优先级状态（可以打断其他状态）
end

-- 设置状态是否可被打断
function StateMachine:set_state_interruptible(state_name, interruptible)
    self.interruptible_states[state_name] = interruptible
    return self
end

-- 设置高优先级状态
function StateMachine:set_priority_state(state_name, priority)
    self.priority_states[state_name] = priority or 1
    return self
end

-- 检查状态是否可以被打断
function StateMachine:can_state_be_interrupted(state_name)
    return self.interruptible_states[state_name] ~= false
end

-- 检查是否可以切换到目标状态
function StateMachine:can_change_to_state(target_state_name)
    -- 当前状态可被打断
    if not self:can_state_be_interrupted(self.current_state.name) then
        return false
    end
    local current_priority = self.priority_states[self.current_state.name] or 0
    local target_priority = self.priority_states[target_state_name] or 0
    
    -- 高优先级状态可以打断低优先级状态
    if target_priority < current_priority then
        return false 
    end
    
    return true
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
function StateMachine:start(context)
    if self.is_running then
        return
    end
    
    self.context = context or {}
    self.is_running = true
    self.is_interrupted = false
    self.state_time = 0
    
    if self.initial_state and self.states[self.initial_state] then
        self:change_state(self.initial_state)
    end
end

-- 停止状态机
function StateMachine:stop()
    if self.current_state then
        self.current_state:exit(self.context)
    end
    self.is_running = false
    self.current_state = nil
    self.previous_state = nil
    self.state_time = 0
end

-- 中断状态机
function StateMachine:interrupt()
    self.is_interrupted = true
    if self.current_state then
        self.current_state:interrupt(self.context)
    end
end

-- 更新状态机
function StateMachine:update(dt)
    if not self.is_running or self.is_interrupted then
        return "failure"
    end
    
    self.state_time = self.state_time + (dt or 0.1)
    
    if self.current_state then
        local result = self.current_state:update(self.context, dt)
        if result == "success" then
            -- 状态成功完成，但不停止状态机，让它继续运行
            --log.debug("StateMachine: 状态 %s 完成", self.current_state.name)
            return "running"
        elseif result == "failure" then
            -- 状态失败，也不停止状态机
            log.debug("StateMachine: 状态 %s 失败", self.current_state.name)
            return "running"
        end
    end
    
    return "running"
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
    -- 检查是否可以切换状态
    if self.current_state and not self:can_change_to_state(state_name) then
        return false
    end
    
    -- 退出当前状态
    if self.current_state then
        self.current_state:exit(self.context)
        self.previous_state = self.current_state.name
    end
    
    -- 进入新状态
    self.current_state = self.states[state_name]
    self.state_time = 0
    self.current_state:enter(self.context)
    return true
end

-- 强制切换状态（忽略打断限制）
function StateMachine:force_change_state(state_name)
    if not self.states[state_name] then
        log.error("StateMachine: 状态 %s 不存在", state_name)
        return false
    end
    
    -- 退出当前状态
    if self.current_state then
        self.current_state:exit(self.context)
        self.previous_state = self.current_state.name
    end
    
    -- 进入新状态
    self.current_state = self.states[state_name]
    self.state_time = 0
    self.current_state:enter(self.context)
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

-- 状态基类
local State = class("State")

function State:ctor(name)
    self.name = name
    self.machine = nil
end

function State:enter(context)
    -- 子类重写
end

function State:update(context, dt)
    -- 子类重写
    return "running"
end

function State:exit(context)
    -- 子类重写
end

function State:interrupt(context)
    -- 子类重写
end

-- 移动状态
local MoveState = class("MoveState", State)

function MoveState:ctor(name)
    State.ctor(self, name or STATE.MOVING)
end

function MoveState:enter(context)

end

function MoveState:update(context, dt)
    local entity = context.entity
    if not entity then
        return "failure"
    end
    
    -- 检查是否被中断
    if context.is_interrupted then
        entity:stop_move()
        return "failure"
    end
    
    -- 更新移动
    entity:update_move(dt)
    
    -- 检查是否到达目标
    if not entity:is_moving() then
        log.debug("MoveState: 移动完成")
        return "success"
    end
    
    return "running"
end

function MoveState:exit(context)
    local entity = context.entity
    if entity then
        entity:stop_move()
    end
end

function MoveState:interrupt(context)
    local entity = context.entity
    if entity then
        entity:stop_move()
    end
end

-- 待机状态（通用）
local IdleState = class("IdleState", State)

function IdleState:ctor(name)
    State.ctor(self, name or STATE.IDLE)
end

function IdleState:enter(context)
    local entity = context.entity
    if entity then
        entity:play_animation("idle")
    end
end

function IdleState:update(context, dt)
    -- 待机状态通常由子类重写，添加具体的待机逻辑
    return "running"
end

function IdleState:exit(context)
end

-- 复合状态（可以包含子状态机）
local CompositeState = class("CompositeState", State)

function CompositeState:ctor(name)
    State.ctor(self, name)
    self.sub_machine = nil
end

function CompositeState:set_sub_machine(machine)
    self.sub_machine = machine
    return self
end

function CompositeState:enter(context)
    if self.sub_machine then
        self.sub_machine:start(context)
    end
end

function CompositeState:update(context, dt)
    if self.sub_machine then
        return self.sub_machine:update(dt)
    end
    return "running"
end

function CompositeState:exit(context)
    if self.sub_machine then
        self.sub_machine:stop()
    end
end

function CompositeState:interrupt(context)
    if self.sub_machine then
        self.sub_machine:interrupt()
    end
end

-- 条件状态（根据条件决定下一个状态）
local ConditionalState = class("ConditionalState", State)

function ConditionalState:ctor(name)
    State.ctor(self, name)
    self.conditions = {}
end

function ConditionalState:add_condition(condition_func, target_state)
    table.insert(self.conditions, {
        func = condition_func,
        target = target_state
    })
    return self
end

function ConditionalState:update(context, dt)
    -- 检查所有条件
    for _, condition in ipairs(self.conditions) do
        if condition.func(context) then
            self.machine:change_state(condition.target)
            return "running"
        end
    end
    
    return "running"
end

-- 延迟状态（延迟一段时间后切换到指定状态）
local DelayState = class("DelayState", State)

function DelayState:ctor(name, delay_time, target_state)
    State.ctor(self, name)
    self.delay_time = delay_time or 1.0
    self.target_state = target_state
end

function DelayState:update(context, dt)
    if self.machine:get_state_time() >= self.delay_time then
        if self.target_state then
            self.machine:change_state(self.target_state)
        end
        return "success"
    end
    return "running"
end

-- 眩晕状态
local StunnedState = class("StunnedState", State)

function StunnedState:ctor(name, duration)
    State.ctor(self, name or STATE.STUNNED)
    self.duration = duration or 2.0  -- 默认眩晕2秒
end

function StunnedState:enter(context)
    local entity = context.entity
    if entity then
        -- 停止所有活动
        entity:stop_move()
        entity.target_id = nil
        
        -- 播放眩晕动画
        entity:play_animation("stunned")
        
        log.debug("StunnedState: 实体 %d 进入眩晕状态，持续 %.1f 秒", entity.id, self.duration)
    end
end

function StunnedState:update(context, dt)
    local entity = context.entity
    if not entity then
        return "failure"
    end
    
    -- 检查眩晕时间是否结束
    if self.machine:get_state_time() >= self.duration then
        log.debug("StunnedState: 实体 %d 眩晕状态结束", entity.id)
        return "success"
    end
    
    return "running"
end

function StunnedState:exit(context)
    local entity = context.entity
    if entity then
        -- 恢复动画
        entity:play_animation("idle")
        log.debug("StunnedState: 实体 %d 退出眩晕状态", entity.id)
    end
end

function StunnedState:interrupt(context)
    local entity = context.entity
    if entity then
        log.debug("StunnedState: 实体 %d 眩晕状态被中断", entity.id)
    end
end

-- 死亡状态
local DeadState = class("DeadState", State)

function DeadState:ctor(name)
    State.ctor(self, name or STATE.DEAD)
end

function DeadState:enter(context)
    local entity = context.entity
    if entity then
        -- 停止所有活动
        entity:stop_move()
        entity.target_id = nil
        
        -- 播放死亡动画
        entity:play_animation("dead")
        
        -- 设置死亡标志
        entity.is_dead = true
        
        log.debug("DeadState: 实体 %d 进入死亡状态", entity.id)
    end
end

function DeadState:update(context, dt)
    local entity = context.entity
    if not entity then
        return "failure"
    end
    
    -- 死亡状态通常需要外部干预才能恢复（如复活）
    -- 这里可以添加自动复活的逻辑，或者保持死亡状态
    return "running"
end

function DeadState:exit(context)
    local entity = context.entity
    if entity then
        -- 清除死亡标志
        entity.is_dead = false
        
        -- 恢复动画
        entity:play_animation("idle")
        
        log.debug("DeadState: 实体 %d 退出死亡状态", entity.id)
    end
end

function DeadState:interrupt(context)
    local entity = context.entity
    if entity then
        log.debug("DeadState: 实体 %d 死亡状态被中断", entity.id)
    end
end

-- 动作状态（执行一次性动作）
local ActionState = class("ActionState", State)

function ActionState:ctor(name, action_func)
    State.ctor(self, name)
    self.action_func = action_func
end

function ActionState:enter(context)
    if self.action_func then
        self.action_func(context)
    end
end

function ActionState:update(context, dt)
    return "success"
end

return {
    STATE = STATE,
    StateMachine = StateMachine,
    State = State,
    MoveState = MoveState,
    IdleState = IdleState,
    StunnedState = StunnedState,
    DeadState = DeadState,
    CompositeState = CompositeState,
    ConditionalState = ConditionalState,
    DelayState = DelayState,
    ActionState = ActionState
} 