local log = require "log"
local BehaviorTree = require "scene.ai.behavior_tree"
local StateMachine = require "scene.ai.state_machine"

-- 获取行为树节点类
local BTAction = BehaviorTree.Action
local BTCondition = BehaviorTree.Condition
local BTStatus = BehaviorTree.Status

-- ==================== 战斗条件节点 ====================

-- 检查是否有敌人（直接调用实体方法）
local HasEnemyCondition = BTCondition.new("has_enemy", function(context)
    local entity = context.entity
    return entity and entity:has_enemy_in_range()
end)

-- 检查是否有最近的敌人（直接调用实体方法）
local HasNearestEnemyCondition = BTCondition.new("has_nearest_enemy", function(context)
    local entity = context.entity
    return entity and entity:has_nearest_enemy()
end)

-- 检查是否在攻击范围内（直接调用实体方法）
local IsInAttackRangeCondition = BTCondition.new("is_in_attack_range", function(context)
    local entity = context.entity
    local target = context.target or context.blackboard:get("attack_target")
    return entity and target and entity:is_in_attack_range(target)
end)

-- 检查是否可以攻击（直接调用实体方法）
local CanAttackCondition = BTCondition.new("can_attack", function(context)
    local entity = context.entity
    return entity and entity:can_attack()
end)

-- 检查是否有威胁（直接调用实体方法）
local HasThreatCondition = BTCondition.new("has_threat", function(context)
    local entity = context.entity
    return entity and entity:has_threat_in_range()
end)

-- 检查是否在战斗中（直接调用实体方法）
local IsInCombatCondition = BTCondition.new("is_in_combat", function(context)
    local entity = context.entity
    return entity and (entity:is_attacking() or entity:is_chasing())
end)

-- 检查是否在攻击状态（直接调用实体方法）
local IsAttackingCondition = BTCondition.new("is_attacking", function(context)
    local entity = context.entity
    return entity and entity:is_attacking()
end)

-- 检查是否在追击状态（直接调用实体方法）
local IsChasingCondition = BTCondition.new("is_chasing", function(context)
    local entity = context.entity
    return entity and entity:is_chasing()
end)

local IsInCommandCondition = BTCondition.new("is_in_command", function(context)
    local entity = context.entity
    return entity and entity:is_in_command()
end)

-- ==================== 移动条件节点 ====================

-- 检查是否正在移动（直接调用实体方法）
local IsMovingCondition = BTCondition.new("is_moving", function(context)
    local entity = context.entity
    return entity and entity:is_moving()
end)

-- 检查是否有移动目标（从黑板读取）
local HasMoveTargetCondition = BTCondition.new("has_move_target", function(context)
    local blackboard = context.blackboard
    return blackboard:get("move_target") ~= nil
end)

-- 检查是否到达目标位置（直接调用实体方法）
local IsAtTargetCondition = BTCondition.new("is_at_target", function(context)
    local entity = context.entity
    local target = context.target or context.blackboard:get("move_target")
    return entity and target and entity:is_at_target(target)
end)

-- 检查是否可以移动（直接调用实体方法）
local CanMoveCondition = BTCondition.new("can_move", function(context)
    local entity = context.entity
    return entity and entity:can_move()
end)

-- 检查是否需要巡逻（直接调用实体方法）
local NeedsPatrolCondition = BTCondition.new("needs_patrol", function(context)
    local entity = context.entity
    return entity and entity:needs_patrol()
end)

-- 检查是否在巡逻状态（直接调用实体方法）
local IsPatrollingCondition = BTCondition.new("is_patrolling", function(context)
    local entity = context.entity
    return entity and entity:is_patrolling()
end)

-- 检查是否在逃跑状态（直接调用实体方法）
local IsFleeingCondition = BTCondition.new("is_fleeing", function(context)
    local entity = context.entity
    return entity and entity:is_fleeing()
end)

-- ==================== 状态条件节点 ====================

-- 检查是否死亡（直接调用实体方法）
local IsDeadCondition = BTCondition.new("is_dead", function(context)
    local entity = context.entity
    return entity and entity:is_dead()
end)

-- 检查是否眩晕（直接调用实体方法）
local IsStunnedCondition = BTCondition.new("is_stunned", function(context)
    local entity = context.entity
    return entity and entity:is_stunned()
end)

-- 检查血量是否低（直接调用实体方法）
local IsLowHPCondition = BTCondition.new("is_low_hp", function(context)
    local entity = context.entity
    local threshold = context.threshold or 0.3
    return entity and entity:is_low_hp(threshold)
end)

-- 检查是否在特定状态（直接调用实体方法）
local IsInStateCondition = BTCondition.new("is_in_state", function(context)
    local entity = context.entity
    local target_state = context.state
    return entity and entity:is_in_state(target_state)
end)

-- 检查是否在空闲状态（直接调用实体方法）
local IsIdleCondition = BTCondition.new("is_idle", function(context)
    local entity = context.entity
    return entity and entity:is_idle()
end)

-- ==================== 战斗动作节点 ====================

-- 设置攻击目标（存储到黑板）
local SetAttackTargetAction = BTAction.new("set_attack_target", function(context)
    local entity = context.entity
    local blackboard = context.blackboard
    
    local target = entity:find_nearest_enemy()
    if target then
        blackboard:set("attack_target", target)
        log.debug("CombatNode: 设置攻击目标 %d", target.id)
        return BTStatus.SUCCESS
    else
        return BTStatus.FAILURE
    end
end)

-- 清除攻击目标
local ClearAttackTargetAction = BTAction.new("clear_attack_target", function(context)
    local blackboard = context.blackboard
    blackboard:clear("attack_target")
    log.debug("CombatNode: 清除攻击目标")
    return BTStatus.SUCCESS
end)

-- 进入战斗状态（状态机优先）
local EnterCombatAction = BTAction.new("enter_combat", function(context)
    local entity = context.entity
    local blackboard = context.blackboard
    
    local target = blackboard:get("attack_target")
    if target then
        entity.state_machine:change_state("attacking")
        log.debug("CombatNode: 进入战斗状态")
        return BTStatus.SUCCESS
    else
        return BTStatus.FAILURE
    end
end)

-- 进入追击状态（状态机优先）
local EnterChaseAction = BTAction.new("enter_chase", function(context)
    local entity = context.entity
    local blackboard = context.blackboard
    
    local target = blackboard:get("attack_target")
    if target then
        entity.state_machine:change_state("chasing")
        log.debug("CombatNode: 进入追击状态")
        return BTStatus.SUCCESS
    else
        return BTStatus.FAILURE
    end
end)

-- 退出战斗状态
local ExitCombatAction = BTAction.new("exit_combat", function(context)
    local entity = context.entity
    local blackboard = context.blackboard
    
    blackboard:clear("attack_target")
    entity.state_machine:change_state("idle")
    log.debug("CombatNode: 退出战斗状态")
    return BTStatus.SUCCESS
end)

-- 简单攻击（直接调用）
local AttackAction = BTAction.new("attack", function(context)
    local entity = context.entity
    local target = context.target or context.blackboard:get("attack_target")
    
    if target and entity:can_attack() and entity:is_in_attack_range(target) then
        entity:perform_attack(target)
        log.debug("CombatNode: 执行攻击，目标: %d", target.id)
        return BTStatus.SUCCESS
    else
        return BTStatus.FAILURE
    end
end)

-- ==================== 移动动作节点 ====================

-- 设置移动目标（存储到黑板）
local SetMoveTargetAction = BTAction.new("set_move_target", function(context)
    local target_x = context.target_x
    local target_y = context.target_y
    local blackboard = context.blackboard
    
    if target_x and target_y then
        blackboard:set("move_target", {x = target_x, y = target_y})
        log.debug("MovementNode: 设置移动目标 (%.1f, %.1f)", target_x, target_y)
        return BTStatus.SUCCESS
    else
        return BTStatus.FAILURE
    end
end)

-- 清除移动目标
local ClearMoveTargetAction = BTAction.new("clear_move_target", function(context)
    local blackboard = context.blackboard
    blackboard:clear("move_target")
    log.debug("MovementNode: 清除移动目标")
    return BTStatus.SUCCESS
end)

-- 进入移动状态（状态机优先）
local EnterMoveAction = BTAction.new("enter_move", function(context)
    local entity = context.entity
    local blackboard = context.blackboard
    
    local move_target = blackboard:get("move_target")
    if move_target then
        entity.state_machine:change_state("moving")
        log.debug("MovementNode: 进入移动状态")
        return BTStatus.SUCCESS
    else
        return BTStatus.FAILURE
    end
end)

-- 停止移动
local StopMoveAction = BTAction.new("stop_move", function(context)
    local entity = context.entity
    local blackboard = context.blackboard
    
    entity:stop_move()
    blackboard:clear("move_target")
    entity.state_machine:change_state("idle")
    log.debug("MovementNode: 停止移动")
    return BTStatus.SUCCESS
end)

-- 简单移动（直接调用）
local MoveAction = BTAction.new("move", function(context)
    local entity = context.entity
    local target_x = context.target_x
    local target_y = context.target_y
    
    if target_x and target_y and entity:can_move() then
        entity:move_to(target_x, target_y)
        log.debug("MovementNode: 执行移动到 (%.1f, %.1f)", target_x, target_y)
        return BTStatus.RUNNING
    else
        return BTStatus.FAILURE
    end
end)

-- ==================== 移动目标设置节点 ====================

-- 设置随机移动目标
local SetRandomMoveTargetAction = BTAction.new("set_random_move_target", function(context)
    local entity = context.entity
    local max_distance = context.max_distance or 10.0
    local blackboard = context.blackboard
    
    if entity then
        local target_x, target_y = entity:generate_random_position(max_distance)
        blackboard:set("move_target", {x = target_x, y = target_y})
        log.debug("MovementNode: 设置随机移动目标 (%.1f, %.1f)", target_x, target_y)
        return BTStatus.SUCCESS
    else
        return BTStatus.FAILURE
    end
end)

-- 设置巡逻移动目标
local SetPatrolMoveTargetAction = BTAction.new("set_patrol_move_target", function(context)
    local entity = context.entity
    local center_x = context.center_x or entity.x
    local center_y = context.center_y or entity.y
    local radius = context.radius or 10.0
    local blackboard = context.blackboard
    
    if entity then
        local target_x, target_y = entity:generate_patrol_position(center_x, center_y, radius)
        blackboard:set("move_target", {x = target_x, y = target_y})
        log.debug("MovementNode: 设置巡逻移动目标 (%.1f, %.1f)", target_x, target_y)
        return BTStatus.SUCCESS
    else
        return BTStatus.FAILURE
    end
end)

-- 设置逃跑移动目标
local SetFleeMoveTargetAction = BTAction.new("set_flee_move_target", function(context)
    local entity = context.entity
    local flee_distance = context.flee_distance or 100.0
    local blackboard = context.blackboard
    
    if entity then
        local target_x, target_y = entity:generate_flee_position(flee_distance)
        blackboard:set("move_target", {x = target_x, y = target_y})
        log.debug("MovementNode: 设置逃跑移动目标 (%.1f, %.1f)", target_x, target_y)
        return BTStatus.SUCCESS
    else
        return BTStatus.FAILURE
    end
end)

-- ==================== 状态切换动作节点 ====================

-- 请求空闲状态
local RequestIdleAction = BTAction.new("request_idle", function(context)
    local entity = context.entity
    entity.state_machine:change_state("idle")
    log.debug("StateNode: 请求空闲状态")
    return BTStatus.SUCCESS
end)

-- 请求巡逻状态
local RequestPatrolAction = BTAction.new("request_patrol", function(context)
    local entity = context.entity
    entity.state_machine:change_state("patrol")
    log.debug("StateNode: 请求巡逻状态")
    return BTStatus.SUCCESS
end)

-- 请求逃跑状态
local RequestFleeAction = BTAction.new("request_flee", function(context)
    local entity = context.entity
    entity.state_machine:change_state("flee")
    log.debug("StateNode: 请求逃跑状态")
    return BTStatus.SUCCESS
end)

-- 请求眩晕状态
local RequestStunnedAction = BTAction.new("request_stunned", function(context)
    local entity = context.entity
    entity.state_machine:change_state("stunned")
    log.debug("StateNode: 请求眩晕状态")
    return BTStatus.SUCCESS
end)

-- 请求死亡状态
local RequestDeadAction = BTAction.new("request_dead", function(context)
    local entity = context.entity
    entity.state_machine:change_state("dead")
    log.debug("StateNode: 请求死亡状态")
    return BTStatus.SUCCESS
end)

-- ==================== 状态处理动作节点 ====================

-- 等待状态（简单等待）
local WaitAction = BTAction.new("wait", function(context)
    local wait_time = context.wait_time or 1.0
    local blackboard = context.blackboard
    local start_time = blackboard:get("wait_start_time")
    
    if not start_time then
        blackboard:set("wait_start_time", os.time())
        return BTStatus.RUNNING
    end
    
    local elapsed_time = os.time() - start_time
    if elapsed_time >= wait_time then
        blackboard:clear("wait_start_time")
        log.debug("StateNode: 等待完成，耗时 %.1f 秒", elapsed_time)
        return BTStatus.SUCCESS
    else
        return BTStatus.RUNNING
    end
end)

-- 重置状态
local ResetStateAction = BTAction.new("reset_state", function(context)
    local entity = context.entity
    local blackboard = context.blackboard
    
    -- 清除黑板数据
    blackboard:clear("attack_target")
    blackboard:clear("move_target")
    blackboard:clear("patrol_center")
    blackboard:clear("flee_direction")
    
    -- 切换到空闲状态
    entity.state_machine:change_state("idle")
    
    log.debug("StateNode: 重置状态到待机")
    return BTStatus.SUCCESS
end)

-- ==================== 移动行为组合节点 ====================

-- 创建巡逻行为
local function create_patrol_behavior()
    local BT = BehaviorTree
    
    local patrol_sequence = BT.Sequence.new("PatrolSequence")
    
    -- 1. 检查是否需要巡逻
    patrol_sequence:add_child(NeedsPatrolCondition)
    
    -- 2. 设置巡逻移动目标
    patrol_sequence:add_child(SetPatrolMoveTargetAction)
    
    -- 3. 请求巡逻状态
    patrol_sequence:add_child(RequestPatrolAction)
    
    return patrol_sequence
end

-- 创建随机移动行为
local function create_random_move_behavior()
    local BT = BehaviorTree
    
    local random_move_sequence = BT.Sequence.new("RandomMoveSequence")
    
    -- 1. 设置随机移动目标
    random_move_sequence:add_child(SetRandomMoveTargetAction)
    
    -- 2. 进入移动状态
    random_move_sequence:add_child(EnterMoveAction)
    
    return random_move_sequence
end

-- ==================== 战斗复合节点 ====================

-- 进入战斗序列
local EnterCombatSequence = BehaviorTree.Sequence.new("enter_combat_sequence")
EnterCombatSequence:add_child(BehaviorTree.Inverter.new("not_in_combat", IsInCombatCondition))
EnterCombatSequence:add_child(SetAttackTargetAction)
EnterCombatSequence:add_child(EnterCombatAction)

-- 追击序列
local ChaseSequence = BehaviorTree.Sequence.new("chase_sequence")
ChaseSequence:add_child(SetAttackTargetAction)
ChaseSequence:add_child(EnterChaseAction)

-- 导出所有节点
return {
    -- 战斗条件节点
    HasEnemyCondition = HasEnemyCondition,
    HasNearestEnemyCondition = HasNearestEnemyCondition,
    IsInAttackRangeCondition = IsInAttackRangeCondition,
    CanAttackCondition = CanAttackCondition,
    HasThreatCondition = HasThreatCondition,
    IsInCombatCondition = IsInCombatCondition,
    IsAttackingCondition = IsAttackingCondition,
    IsChasingCondition = IsChasingCondition,
    IsInCommandCondition = IsInCommandCondition,
    
    -- 移动条件节点
    IsMovingCondition = IsMovingCondition,
    HasMoveTargetCondition = HasMoveTargetCondition,
    IsAtTargetCondition = IsAtTargetCondition,
    CanMoveCondition = CanMoveCondition,
    NeedsPatrolCondition = NeedsPatrolCondition,
    IsPatrollingCondition = IsPatrollingCondition,
    IsFleeingCondition = IsFleeingCondition,
    
    -- 状态条件节点
    IsDeadCondition = IsDeadCondition,
    IsStunnedCondition = IsStunnedCondition,
    IsLowHPCondition = IsLowHPCondition,
    IsInStateCondition = IsInStateCondition,
    IsIdleCondition = IsIdleCondition,
    IsDeadAndNotInDeadStateCondition = IsDeadAndNotInDeadStateCondition,
    IsStunnedAndNotInStunnedStateCondition = IsStunnedAndNotInStunnedStateCondition,
    IsIdleAndNotInIdleStateCondition = IsIdleAndNotInIdleStateCondition,
    
    -- 战斗动作节点
    SetAttackTargetAction = SetAttackTargetAction,
    ClearAttackTargetAction = ClearAttackTargetAction,
    EnterCombatAction = EnterCombatAction,
    EnterChaseAction = EnterChaseAction,
    ExitCombatAction = ExitCombatAction,
    AttackAction = AttackAction,
    
    -- 移动动作节点
    SetMoveTargetAction = SetMoveTargetAction,
    ClearMoveTargetAction = ClearMoveTargetAction,
    EnterMoveAction = EnterMoveAction,
    StopMoveAction = StopMoveAction,
    MoveAction = MoveAction,
    
    -- 移动目标设置节点
    SetRandomMoveTargetAction = SetRandomMoveTargetAction,
    SetPatrolMoveTargetAction = SetPatrolMoveTargetAction,
    SetFleeMoveTargetAction = SetFleeMoveTargetAction,
    
    -- 状态切换动作节点
    RequestIdleAction = RequestIdleAction,
    RequestPatrolAction = RequestPatrolAction,
    RequestFleeAction = RequestFleeAction,
    RequestStunnedAction = RequestStunnedAction,
    RequestDeadAction = RequestDeadAction,
    
    -- 状态处理动作节点
    WaitAction = WaitAction,
    ResetStateAction = ResetStateAction,
    
    -- 行为组合
    create_patrol_behavior = create_patrol_behavior,
    create_random_move_behavior = create_random_move_behavior,
    
    -- 复合节点
    EnterCombatSequence = EnterCombatSequence,
    ChaseSequence = ChaseSequence,
} 