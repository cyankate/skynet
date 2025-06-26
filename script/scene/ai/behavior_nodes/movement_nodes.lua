local log = require "log"
local BehaviorTree = require "scene.ai.behavior_tree"
local StateMachine = require "scene.ai.state_machine"

-- 获取行为树节点类
local BTAction = BehaviorTree.Action
local BTCondition = BehaviorTree.Condition
local BTStatus = BehaviorTree.Status

-- ==================== 移动条件节点 ====================

-- 检查是否有移动请求
local HasMoveRequestCondition = BTCondition.new("has_move_request", function(context)
    return context.blackboard:get("move_requested", false)
end)

-- 检查是否正在移动
local IsMovingCondition = BTCondition.new("is_moving", function(context)
    return context.blackboard:get("is_moving", false)
end)

-- 检查是否有移动目标
local HasMoveTargetCondition = BTCondition.new("has_move_target", function(context)
    return context.blackboard:get("move_target_x") ~= nil and 
           context.blackboard:get("move_target_y") ~= nil
end)

-- 检查是否到达目标位置
local IsAtTargetCondition = BTCondition.new("is_at_target", function(context)
    local entity = context.entity
    local target_x = context.blackboard:get("move_target_x")
    local target_y = context.blackboard:get("move_target_y")
    
    if not target_x or not target_y then
        return true  -- 没有目标就算到达
    end
    
    local dx = entity.x - target_x
    local dy = entity.y - target_y
    local distance = math.sqrt(dx * dx + dy * dy)
    
    return distance <= 0.5  -- 到达阈值
end)

-- 检查是否可以移动
local CanMoveCondition = BTCondition.new("can_move", function(context)
    local entity = context.entity
    return entity:can_move()
end)

-- ==================== 移动动作节点 ====================

-- 设置移动目标（通用方法）
local SetMoveTargetAction = BTAction.new("set_move_target", function(context)
    local target_x = context.target_x or context.blackboard:get("move_target_x")
    local target_y = context.target_y or context.blackboard:get("move_target_y")
    
    if target_x and target_y then
        context.blackboard:set("move_target_x", target_x)
        context.blackboard:set("move_target_y", target_y)
        context.blackboard:set("move_requested", true)  -- 设置移动请求标志
        --log.debug("MovementNode: 设置移动目标 entity_id: %d, target_pos: {x: %.1f, y: %.1f}", context.entity.id, target_x, target_y)
        return BTStatus.SUCCESS
    else
        return BTStatus.FAILURE
    end
end)

-- 清除移动目标
local ClearMoveTargetAction = BTAction.new("clear_move_target", function(context)
    local entity = context.entity
    
    -- 清除黑板数据
    context.blackboard:remove("move_target_x")
    context.blackboard:remove("move_target_y")
    context.blackboard:set("is_moving", false)
    context.blackboard:set("move_requested", false)  -- 清除移动请求标志
    
    -- 同步到实体
    entity:stop_move()
    
    return BTStatus.SUCCESS
end)

-- 开始移动
local StartMoveAction = BTAction.new("start_move", function(context)
    local entity = context.entity
    local target_x = context.blackboard:get("move_target_x")
    local target_y = context.blackboard:get("move_target_y")
    local move_requested = context.blackboard:get("move_requested", false)
    
    -- 检查是否有移动请求
    if not move_requested then
        return BTStatus.FAILURE
    end
    
    if not target_x or not target_y then
        return BTStatus.FAILURE
    end
    
    -- 调用实体的移动方法
    local success, error_msg = entity:handle_move(target_x, target_y)
    
    if success then
        context.blackboard:set("is_moving", true)
        context.blackboard:set("move_requested", false)  -- 清除移动请求标志
        if context.entity.id == 1001 then
            log.debug("MovementNode: 开始移动到 entity_id: %d, target_pos: {x: %.1f, y: %.1f}", context.entity.id, target_x, target_y)
        end
        return BTStatus.SUCCESS
    else
        log.warn("MovementNode: 移动失败: %s", error_msg)
        context.blackboard:set("move_requested", false)  -- 清除移动请求标志
        return BTStatus.FAILURE
    end
end)

-- 停止移动
local StopMoveAction = BTAction.new("stop_move", function(context)
    local entity = context.entity
    entity:stop_move()
    context.blackboard:set("is_moving", false)
    context.blackboard:set("move_requested", false)  -- 清除移动请求标志
    log.debug("MovementNode: 停止移动")
    return BTStatus.SUCCESS
end)

-- ==================== 移动目标设置节点 ====================

-- 设置随机移动目标
local SetRandomMoveTargetAction = BTAction.new("set_random_move_target", function(context)
    local entity = context.entity
    local max_distance = context.max_distance or 10.0
    
    -- 生成随机角度和距离
    local angle = math.random() * math.pi * 2
    local distance = math.random() * max_distance
    
    -- 计算目标位置
    local target_x = entity.x + math.cos(angle) * distance
    local target_y = entity.y + math.sin(angle) * distance
    
    -- 设置移动目标
    context.target_x = target_x
    context.target_y = target_y
    
    log.debug("MovementNode: 设置随机移动目标 (%.1f, %.1f)", target_x, target_y)
    return BTStatus.SUCCESS
end)

-- 设置移动到实体附近的目标
local SetMoveToEntityTargetAction = BTAction.new("set_move_to_entity_target", function(context)
    local entity = context.entity
    local target_id = context.target_id or context.blackboard:get("target_id")
    local distance = context.distance or 2.0
    
    if not target_id then
        return BTStatus.FAILURE
    end
    
    local target = entity.scene:get_entity(target_id)
    if not target then
        return BTStatus.FAILURE
    end
    
    -- 计算当前距离
    local dx = entity.x - target.x
    local dy = entity.y - target.y
    local current_distance = math.sqrt(dx * dx + dy * dy)
    
    if current_distance <= distance then
        return BTStatus.SUCCESS  -- 已在目标距离内
    end
    
    -- 计算移动目标位置（在目标实体的distance距离处）
    local angle = math.atan(dy, dx)
    local target_x = target.x + math.cos(angle) * distance
    local target_y = target.y + math.sin(angle) * distance
    
    -- 设置移动目标
    context.target_x = target_x
    context.target_y = target_y
    
    log.debug("MovementNode: 设置移动到实体 %d 附近的目标 (%.1f, %.1f)", target_id, target_x, target_y)
    return BTStatus.SUCCESS
end)

-- 设置巡逻移动目标
local SetPatrolMoveTargetAction = BTAction.new("set_patrol_move_target", function(context)
    local entity = context.entity
    local center_x = context.center_x or entity.x
    local center_y = context.center_y or entity.y
    local radius = context.radius or 10.0
    
    -- 生成巡逻目标位置
    local angle = math.random() * math.pi * 2
    local distance = math.random() * radius
    
    local target_x = center_x + math.cos(angle) * distance
    local target_y = center_y + math.sin(angle) * distance
    
    -- 设置移动目标
    context.target_x = target_x
    context.target_y = target_y
    
    log.debug("MovementNode: 设置巡逻移动目标  - 中心点 (%.1f, %.1f) - 半径 %.1f - 目标 (%.1f, %.1f)", center_x, center_y, radius, target_x, target_y)
    return BTStatus.SUCCESS
end)

-- ==================== 复合移动节点 ====================

-- 移动到目标位置的复合节点（核心移动逻辑）
local MoveToTargetSequence = BehaviorTree.Sequence.new("move_to_target")
MoveToTargetSequence:add_child(HasMoveTargetCondition)
MoveToTargetSequence:add_child(CanMoveCondition)
MoveToTargetSequence:add_child(StartMoveAction)

-- 移动到随机位置的复合节点
local MoveToRandomSequence = BehaviorTree.Sequence.new("move_to_random")
MoveToRandomSequence:add_child(SetRandomMoveTargetAction)
MoveToRandomSequence:add_child(SetMoveTargetAction)
MoveToRandomSequence:add_child(MoveToTargetSequence)

-- 移动到实体附近的复合节点
local MoveToEntitySequence = BehaviorTree.Sequence.new("move_to_entity")
MoveToEntitySequence:add_child(SetMoveToEntityTargetAction)
MoveToEntitySequence:add_child(SetMoveTargetAction)
MoveToEntitySequence:add_child(MoveToTargetSequence)

-- 巡逻移动的复合节点
local PatrolMoveSequence = BehaviorTree.Sequence.new("patrol_move")
PatrolMoveSequence:add_child(SetPatrolMoveTargetAction)
PatrolMoveSequence:add_child(SetMoveTargetAction)
PatrolMoveSequence:add_child(MoveToTargetSequence)

-- ==================== 移动管理节点 ====================

-- 处理移动请求的复合节点
local HandleMoveRequestSequence = BehaviorTree.Sequence.new("handle_move_request")
HandleMoveRequestSequence:add_child(HasMoveRequestCondition)
HandleMoveRequestSequence:add_child(CanMoveCondition)
HandleMoveRequestSequence:add_child(StartMoveAction)
HandleMoveRequestSequence:add_child(StateNodes.SwitchToMoveAction)

-- 处理移动完成的复合节点
local HandleMoveCompleteSequence = BehaviorTree.Sequence.new("handle_move_complete")
HandleMoveCompleteSequence:add_child(IsMovingCondition)
HandleMoveCompleteSequence:add_child(IsAtTargetCondition)
HandleMoveCompleteSequence:add_child(ClearMoveTargetAction)
HandleMoveCompleteSequence:add_child(StateNodes.SwitchToIdleAction)

-- 处理移动中断的复合节点
local HandleMoveInterruptSequence = BehaviorTree.Sequence.new("handle_move_interrupt")
HandleMoveInterruptSequence:add_child(IsMovingCondition)
HandleMoveInterruptSequence:add_child(BehaviorTree.Inverter.new("not_at_target", IsAtTargetCondition))
HandleMoveInterruptSequence:add_child(StopMoveAction)
HandleMoveInterruptSequence:add_child(StateNodes.SwitchToIdleAction)

-- 移动管理选择器（优先级：处理中断 > 处理完成 > 处理请求）
local MoveManagerSelector = BehaviorTree.Selector.new("move_manager")
MoveManagerSelector:add_child(HandleMoveInterruptSequence)
MoveManagerSelector:add_child(HandleMoveCompleteSequence)
MoveManagerSelector:add_child(HandleMoveRequestSequence)

return {
    -- 条件节点
    HasMoveRequestCondition = HasMoveRequestCondition,
    IsMovingCondition = IsMovingCondition,
    HasMoveTargetCondition = HasMoveTargetCondition,
    IsAtTargetCondition = IsAtTargetCondition,
    CanMoveCondition = CanMoveCondition,
    
    -- 基础动作节点
    SetMoveTargetAction = SetMoveTargetAction,
    ClearMoveTargetAction = ClearMoveTargetAction,
    StartMoveAction = StartMoveAction,
    StopMoveAction = StopMoveAction,
    
    -- 目标设置节点
    SetRandomMoveTargetAction = SetRandomMoveTargetAction,
    SetMoveToEntityTargetAction = SetMoveToEntityTargetAction,
    SetPatrolMoveTargetAction = SetPatrolMoveTargetAction,
    
    -- 复合移动节点
    MoveToTargetSequence = MoveToTargetSequence,
    MoveToRandomSequence = MoveToRandomSequence,
    MoveToEntitySequence = MoveToEntitySequence,
    PatrolMoveSequence = PatrolMoveSequence,
    
    -- 移动管理节点
    HandleMoveRequestSequence = HandleMoveRequestSequence,
    HandleMoveCompleteSequence = HandleMoveCompleteSequence,
    HandleMoveInterruptSequence = HandleMoveInterruptSequence,
    MoveManagerSelector = MoveManagerSelector
} 