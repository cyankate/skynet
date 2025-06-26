local log = require "log"
local BehaviorTree = require "scene.ai.behavior_tree"
local StateMachine = require "scene.ai.state_machine"

-- 获取行为树节点类
local BTAction = BehaviorTree.Action
local BTCondition = BehaviorTree.Condition
local BTStatus = BehaviorTree.Status

-- ==================== 状态条件节点 ====================

-- 检查是否死亡
local IsDeadCondition = BTCondition.new("is_dead", function(context)
    local entity = context.entity
    return entity.hp <= 0 or context.blackboard:get("current_state") == StateMachine.STATE.DEAD
end)

-- 检查是否眩晕
local IsStunnedCondition = BTCondition.new("is_stunned", function(context)
    return context.blackboard:get("current_state") == StateMachine.STATE.STUNNED
end)

-- 检查是否应该被眩晕
local ShouldBeStunnedCondition = BTCondition.new("should_be_stunned", function(context)
    return context.blackboard:get("stun_duration", 0) > 0
end)

-- 检查血量是否低
local IsLowHPCondition = BTCondition.new("is_low_hp", function(context)
    local entity = context.entity
    local threshold = context.threshold or 0.3
    return entity.hp < entity.max_hp * threshold
end)

-- 检查是否在特定状态
local IsInStateCondition = BTCondition.new("is_in_state", function(context)
    local current_state = context.blackboard:get("current_state")
    local target_state = context.state
    return current_state == target_state
end)

-- 检查状态持续时间
local StateDurationCondition = BTCondition.new("state_duration", function(context)
    local entity = context.entity
    local min_duration = context.min_duration or 0
    local max_duration = context.max_duration or math.huge
    
    local state_time = entity:get_state_time()
    return state_time >= min_duration and state_time <= max_duration
end)

-- ==================== 状态切换动作节点 ====================

-- 切换到待机状态
local SwitchToIdleAction = BTAction.new("switch_to_idle", function(context)
    context.entity:change_state(StateMachine.STATE.IDLE)
    return BTStatus.SUCCESS
end)

-- 切换到移动状态
local SwitchToMoveAction = BTAction.new("switch_to_move", function(context)
    context.entity:change_state(StateMachine.STATE.MOVING)
    return BTStatus.SUCCESS
end)

-- 切换到攻击状态
local SwitchToAttackAction = BTAction.new("switch_to_attack", function(context)
    context.entity:change_state(StateMachine.STATE.ATTACKING)
    log.debug("StateNode: 切换到攻击状态")
    return BTStatus.SUCCESS
end)

-- 切换到眩晕状态
local SwitchToStunnedAction = BTAction.new("switch_to_stunned", function(context)
    context.entity:change_state(StateMachine.STATE.STUNNED)
    log.debug("StateNode: 切换到眩晕状态")
    return BTStatus.SUCCESS
end)

-- 切换到死亡状态
local SwitchToDeadAction = BTAction.new("switch_to_dead", function(context)
    local entity = context.entity
    local current_state = context.blackboard:get("current_state")
    
    -- 如果已经在死亡状态，不需要重复切换
    if current_state == StateMachine.STATE.DEAD then
        return BTStatus.SUCCESS
    end
    
    entity:change_state(StateMachine.STATE.DEAD)
    log.debug("StateNode: 切换到死亡状态")
    return BTStatus.SUCCESS
end)

-- ==================== 状态处理动作节点 ====================

-- 处理眩晕
local HandleStunnedAction = BTAction.new("handle_stunned", function(context)
    local entity = context.entity
    local duration = context.blackboard:get("stun_duration", 0)
    local current_state = context.blackboard:get("current_state")
    
    if duration > 0 then
        -- 如果已经在眩晕状态，不需要重复切换
        if current_state == StateMachine.STATE.STUNNED then
            log.debug("StateNode: 已经在眩晕状态，跳过切换")
            return BTStatus.SUCCESS
        end
        
        entity:change_state(StateMachine.STATE.STUNNED)
        context.blackboard:set("stun_duration", 0)  -- 清除眩晕时间
        log.debug("StateNode: 处理眩晕，持续时间 %.1f 秒", duration)
        return BTStatus.SUCCESS
    else
        return BTStatus.FAILURE
    end
end)

-- 处理死亡
local HandleDeadAction = BTAction.new("handle_dead", function(context)
    local entity = context.entity
    local current_state = context.blackboard:get("current_state")
    
    if entity.hp <= 0 then
        -- 如果已经在死亡状态，不需要重复切换
        if current_state == StateMachine.STATE.DEAD then
            return BTStatus.SUCCESS
        end
        
        entity:change_state(StateMachine.STATE.DEAD)
        log.debug("StateNode: 处理死亡")
        return BTStatus.SUCCESS
    else
        return BTStatus.FAILURE
    end
end)

-- 设置眩晕时间
local SetStunDurationAction = BTAction.new("set_stun_duration", function(context)
    local duration = context.duration or 0
    context.blackboard:set("stun_duration", duration)
    log.debug("StateNode: 设置眩晕时间 %.1f 秒", duration)
    return BTStatus.SUCCESS
end)

-- 减少眩晕时间
local ReduceStunDurationAction = BTAction.new("reduce_stun_duration", function(context)
    local current_duration = context.blackboard:get("stun_duration", 0)
    local reduce_amount = context.reduce_amount or context.dt or 0.1
    
    local new_duration = math.max(0, current_duration - reduce_amount)
    context.blackboard:set("stun_duration", new_duration)
    
    log.debug("StateNode: 减少眩晕时间 %.1f -> %.1f", current_duration, new_duration)
    return BTStatus.SUCCESS
end)

-- 等待状态
local WaitAction = BTAction.new("wait", function(context)
    local wait_time = context.wait_time or 1.0
    local start_time = context.blackboard:get_private("wait_start_time")
    
    if not start_time then
        -- 第一次执行，记录开始时间
        context.blackboard:set_private("wait_start_time", os.time())
        return BTStatus.RUNNING
    end
    
    local elapsed_time = os.time() - start_time
    if elapsed_time >= wait_time then
        -- 等待完成，清除开始时间
        context.blackboard:set_private("wait_start_time", nil)
        log.debug("StateNode: 等待完成，耗时 %.1f 秒", elapsed_time)
        return BTStatus.SUCCESS
    else
        return BTStatus.RUNNING
    end
end)

-- 重置状态
local ResetStateAction = BTAction.new("reset_state", function(context)
    local entity = context.entity
    entity:change_state(StateMachine.STATE.IDLE)
    
    -- 清除相关数据
    context.blackboard:remove("target_id")
    context.blackboard:remove("move_target_x")
    context.blackboard:remove("move_target_y")
    context.blackboard:set("is_moving", false)
    context.blackboard:set("stun_duration", 0)
    
    log.debug("StateNode: 重置状态到待机")
    return BTStatus.SUCCESS
end)

-- 检查状态转换条件
local CheckStateTransitionAction = BTAction.new("check_state_transition", function(context)
    local entity = context.entity
    local current_state = context.blackboard:get("current_state")
    local target_state = context.target_state
    
    if not target_state then
        return BTStatus.FAILURE
    end
    
    -- 检查是否可以转换到目标状态
    local can_transition = true
    
    -- 死亡状态检查
    if target_state == StateMachine.STATE.DEAD then
        can_transition = entity.hp <= 0
    end
    
    -- 眩晕状态检查
    if target_state == StateMachine.STATE.STUNNED then
        can_transition = context.blackboard:get("stun_duration", 0) > 0
    end
    
    -- 移动状态检查
    if target_state == StateMachine.STATE.MOVING then
        can_transition = context.blackboard:get("move_target_x") ~= nil and 
                        context.blackboard:get("move_target_y") ~= nil
    end
    
    -- 攻击状态检查
    if target_state == StateMachine.STATE.ATTACKING then
        can_transition = context.blackboard:get("target_id") ~= nil
    end
    
    if can_transition then
        context.blackboard:set("can_transition_to", target_state)
        log.debug("StateNode: 可以转换到状态 %s", target_state)
        return BTStatus.SUCCESS
    else
        log.debug("StateNode: 无法转换到状态 %s", target_state)
        return BTStatus.FAILURE
    end
end)

return {
    -- 条件节点
    IsDeadCondition = IsDeadCondition,
    IsStunnedCondition = IsStunnedCondition,
    ShouldBeStunnedCondition = ShouldBeStunnedCondition,
    IsLowHPCondition = IsLowHPCondition,
    IsInStateCondition = IsInStateCondition,
    StateDurationCondition = StateDurationCondition,
    
    -- 状态切换动作节点
    SwitchToIdleAction = SwitchToIdleAction,
    SwitchToMoveAction = SwitchToMoveAction,
    SwitchToAttackAction = SwitchToAttackAction,
    SwitchToStunnedAction = SwitchToStunnedAction,
    SwitchToDeadAction = SwitchToDeadAction,
    
    -- 状态处理动作节点
    HandleStunnedAction = HandleStunnedAction,
    HandleDeadAction = HandleDeadAction,
    SetStunDurationAction = SetStunDurationAction,
    ReduceStunDurationAction = ReduceStunDurationAction,
    WaitAction = WaitAction,
    ResetStateAction = ResetStateAction,
    CheckStateTransitionAction = CheckStateTransitionAction
} 