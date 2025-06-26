local log = require "log"
local BehaviorTree = require "scene.ai.behavior_tree"
local StateMachine = require "scene.ai.state_machine"

-- 获取行为树节点类
local BTAction = BehaviorTree.Action
local BTCondition = BehaviorTree.Condition
local BTStatus = BehaviorTree.Status

-- ==================== 战斗条件节点 ====================

-- 检查是否有目标
local HasTargetCondition = BTCondition.new("has_target", function(context)
    return context.blackboard:get("target_id") ~= nil
end)

-- 检查是否有敌人
local HasEnemyCondition = BTCondition.new("has_enemy", function(context)
    -- 优先检查战斗目标
    local target_id = context.blackboard:get("combat_target")
    if not target_id then
        -- 如果没有战斗目标，检查普通目标
        target_id = context.blackboard:get("target_id")
    end
    
    if not target_id then
        return false
    end
    
    local target = context.entity.scene:get_entity(target_id)
    return target and target.hp > 0
end)

-- 检查是否可以攻击
local CanAttackCondition = BTCondition.new("can_attack", function(context)
    return context.entity:can_attack()
end)

-- 检查目标是否在攻击范围内
local IsInAttackRangeCondition = BTCondition.new("is_in_attack_range", function(context)
    -- 优先使用战斗目标
    local target_id = context.blackboard:get("combat_target")
    if not target_id then
        target_id = context.blackboard:get("target_id")
    end
    
    if not target_id then
        return false
    end
    
    local target = context.entity.scene:get_entity(target_id)
    if not target then
        return false
    end
    
    local dx = target.x - context.entity.x
    local dy = target.y - context.entity.y
    local distance = math.sqrt(dx * dx + dy * dy)
    local attack_range = context.blackboard:get("attack_range", 2.0)
    
    --log.debug("IsInAttackRangeCondition: 检查目标是否在攻击范围内 entity_id: %d, target_id: %d, distance: %.1f, attack_range: %.1f, entity_pos: {x: %.1f, y: %.1f}, target_pos: {x: %.1f, y: %.1f}", context.entity.id, target_id, distance, attack_range, context.entity.x, context.entity.y, target.x, target.y)

    return distance <= attack_range
end)

-- 检查目标是否死亡
local IsTargetDeadCondition = BTCondition.new("is_target_dead", function(context)
    local target_id = context.blackboard:get("target_id")
    if not target_id then
        return true  -- 没有目标也算"死亡"
    end
    
    local target = context.entity.scene:get_entity(target_id)
    return not target or target.hp <= 0
end)

-- 检查是否在战斗中
local IsInCombatCondition = BTCondition.new("is_in_combat", function(context)
    return context.blackboard:get("in_combat", false)
end)

-- 检查是否有战斗目标
local HasCombatTargetCondition = BTCondition.new("has_combat_target", function(context)
    return context.blackboard:get("combat_target") ~= nil
end)

-- 检查是否有最后攻击者
local HasLastAttackerCondition = BTCondition.new("has_last_attacker", function(context)
    return context.blackboard:get("last_attacker") ~= nil
end)

-- ==================== 战斗动作节点 ====================

-- 设置目标
local SetTargetAction = BTAction.new("set_target", function(context)
    local target_id = context.target_id or context.blackboard:get("target_id")
    
    if target_id then
        context.blackboard:set("target_id", target_id)
        log.debug("CombatNode: 设置目标 %d", target_id)
        return BTStatus.SUCCESS
    else
        return BTStatus.FAILURE
    end
end)

-- 清除目标
local ClearTargetAction = BTAction.new("clear_target", function(context)
    context.blackboard:remove("target_id")
    log.debug("CombatNode: 清除目标")
    return BTStatus.SUCCESS
end)

-- 执行攻击
local PerformAttackAction = BTAction.new("perform_attack", function(context)
    local entity = context.entity
    -- 优先使用战斗目标
    local target_id = context.blackboard:get("combat_target")
    if not target_id then
        target_id = context.blackboard:get("target_id")
    end
    
    if not target_id then
        return BTStatus.FAILURE
    end
    
    local target = entity.scene:get_entity(target_id)
    if not target or not entity:can_attack() then
        return BTStatus.FAILURE
    end
    
    entity:perform_attack(target)
    return BTStatus.SUCCESS
end)

-- 检查并清除死亡目标
local CheckTargetDeadAction = BTAction.new("check_target_dead", function(context)
    local target_id = context.blackboard:get("target_id")
    if not target_id then
        return BTStatus.SUCCESS
    end
    
    local target = context.entity.scene:get_entity(target_id)
    if not target or target.hp <= 0 then
        context.blackboard:remove("target_id")
        log.debug("CombatNode: 目标已死亡，清除目标")
        return BTStatus.SUCCESS
    else
        return BTStatus.FAILURE
    end
end)

-- 移动到攻击范围
local MoveToAttackRangeAction = BTAction.new("move_to_attack_range", function(context)
    local entity = context.entity
    -- 优先使用战斗目标
    local target_id = context.blackboard:get("combat_target")
    if not target_id then
        target_id = context.blackboard:get("target_id")
    end
    
    if not target_id then
        return BTStatus.FAILURE
    end
    
    local target = entity.scene:get_entity(target_id)
    if not target then
        return BTStatus.FAILURE
    end
    
    -- 计算攻击范围内的位置
    local dx = target.x - entity.x
    local dy = target.y - entity.y
    local distance = math.sqrt(dx * dx + dy * dy)
    -- 攻击范围为2.0，移动到攻击范围的距离为攻击范围的0.7倍
    local attack_range = context.blackboard:get("attack_range", 2.0)
    
    if distance <= attack_range then
        return BTStatus.SUCCESS  -- 已在攻击范围内
    end
    
    -- 计算移动目标位置（在攻击范围边缘）
    local angle = math.atan(dy, dx)
    local target_x = target.x - math.cos(angle) * attack_range * 0.7
    local target_y = target.y - math.sin(angle) * attack_range * 0.7
    
    -- 设置移动目标（不直接设置到黑板，而是通过context传递）
    context.target_x = target_x
    context.target_y = target_y

    if entity.id == 1001 then
        log.debug("CombatNode: 设置移动到攻击范围的目标 entity_id: %d, target_id: %d, (%.1f, %.1f)", entity.id, target_id, target_x, target_y)
    end
    
    return BTStatus.SUCCESS
end)

-- 检测敌人
local DetectEnemyAction = BTAction.new("detect_enemy", function(context)
    local entity = context.entity
    local detect_range = context.blackboard:get("detect_range", 8.0)
    
    -- 获取视野范围内的所有实体
    local surrounding = entity:get_surrounding_entities()
    local nearest_enemy = nil
    local min_distance = detect_range
    
    for _, target in pairs(surrounding) do
        -- 检查是否是敌人（玩家）
        if target.type == 1 and target.hp > 0 then  -- 玩家类型为1
            local dx = target.x - entity.x
            local dy = target.y - entity.y
            local distance = math.sqrt(dx * dx + dy * dy)
            
            if distance <= detect_range and distance < min_distance then
                min_distance = distance
                nearest_enemy = target
            end
        end
    end
    
    if nearest_enemy then
        context.blackboard:set("target_id", nearest_enemy.id)
        log.debug("CombatNode: 检测到敌人 %d，距离 %.1f", nearest_enemy.id, min_distance)
        return BTStatus.SUCCESS
    else
        return BTStatus.FAILURE
    end
end)

-- 进入战斗状态
local EnterCombatAction = BTAction.new("enter_combat", function(context)
    local entity = context.entity
    local attacker = context.attacker or context.blackboard:get("last_attacker")
    
    if not attacker then
        return BTStatus.FAILURE
    end
    
    -- 设置战斗状态到黑板
    context.blackboard:set("in_combat", true)
    context.blackboard:set("combat_target", attacker.id)
    context.blackboard:set("last_attacker", attacker.id)
    
    -- 同步到实体
    entity.in_combat = true
    entity.combat_target = attacker
    entity.last_attacker = attacker
    
    log.debug("CombatNode: 实体 %d 进入战斗状态，目标: %d", entity.id, attacker.id)
    return BTStatus.SUCCESS
end)

-- 退出战斗状态
local ExitCombatAction = BTAction.new("exit_combat", function(context)
    local entity = context.entity
    
    -- 清除黑板中的战斗状态
    context.blackboard:set("in_combat", false)
    context.blackboard:remove("combat_target")
    context.blackboard:remove("last_attacker")
    
    -- 同步到实体
    entity.in_combat = false
    entity.combat_target = nil
    entity.last_attacker = nil
    
    log.debug("CombatNode: 实体 %d 退出战斗状态", entity.id)
    return BTStatus.SUCCESS
end)

-- 更新战斗目标
local UpdateCombatTargetAction = BTAction.new("update_combat_target", function(context)
    local entity = context.entity
    local current_target = context.blackboard:get("combat_target")
    
    if not current_target then
        return BTStatus.FAILURE
    end
    
    -- 检查目标是否还活着
    local target = entity.scene:get_entity(current_target)
    if not target or target.hp <= 0 then
        -- 目标死亡，退出战斗
        context.blackboard:set("in_combat", false)
        context.blackboard:remove("combat_target")
        context.blackboard:remove("last_attacker")
        
        -- 立即同步到实体（通过同步管理器）
        if entity.blackboard_sync then
            entity.blackboard_sync:sync_to_entity("in_combat")
            entity.blackboard_sync:sync_to_entity("combat_target")
            entity.blackboard_sync:sync_to_entity("last_attacker")
        end
        
        log.debug("CombatNode: 目标死亡，实体 %d 退出战斗状态", entity.id)
        return BTStatus.SUCCESS
    end
    
    -- 检查目标是否在视野范围内
    local dx = target.x - entity.x
    local dy = target.y - entity.y
    local distance = math.sqrt(dx * dx + dy * dy)
    local view_range = context.blackboard:get("view_range", 150)
    
    if distance > view_range then
        -- 目标超出视野，退出战斗
        context.blackboard:set("in_combat", false)
        context.blackboard:remove("combat_target")
        context.blackboard:remove("last_attacker")
        
        -- 立即同步到实体（通过同步管理器）
        if entity.blackboard_sync then
            entity.blackboard_sync:sync_to_entity("in_combat")
            entity.blackboard_sync:sync_to_entity("combat_target")
            entity.blackboard_sync:sync_to_entity("last_attacker")
        end
        
        log.debug("CombatNode: 目标超出视野，实体 %d 退出战斗状态", entity.id)
        return BTStatus.SUCCESS
    end
    
    return BTStatus.SUCCESS
end)

-- 处理受到攻击
local HandleAttackedAction = BTAction.new("handle_attacked", function(context)
    local entity = context.entity
    local attacker_id = context.blackboard:get("last_attacker")
    
    if not attacker_id then
        return BTStatus.FAILURE
    end
    
    local attacker = entity.scene:get_entity(attacker_id)
    if not attacker then
        return BTStatus.FAILURE
    end
    
    -- 如果不在战斗中，进入战斗状态
    if not context.blackboard:get("in_combat", false) then
        context.blackboard:set("in_combat", true)
        context.blackboard:set("combat_target", attacker_id)
        
        -- 立即同步到实体（通过同步管理器）
        if entity.blackboard_sync then
            entity.blackboard_sync:sync_to_entity("in_combat")
            entity.blackboard_sync:sync_to_entity("combat_target")
        end
        
        log.debug("CombatNode: 实体 %d 受到攻击，进入战斗状态", entity.id)
    end
    
    return BTStatus.SUCCESS
end)

-- ==================== 战斗复合节点 ====================

-- 移动到攻击范围的复合节点
local MoveToAttackRangeSequence = BehaviorTree.Sequence.new("move_to_attack_range_sequence")
MoveToAttackRangeSequence:add_child(MoveToAttackRangeAction)
-- 注意：这里需要引入移动节点的SetMoveTargetAction和MoveToTargetSequence
-- 但由于模块依赖问题，我们将在使用的地方组合这些节点

-- 战斗状态管理序列
local CombatStateSequence = BehaviorTree.Sequence.new("combat_state_sequence")
CombatStateSequence:add_child(IsInCombatCondition)
CombatStateSequence:add_child(UpdateCombatTargetAction)

-- 进入战斗序列
local EnterCombatSequence = BehaviorTree.Sequence.new("enter_combat_sequence")
EnterCombatSequence:add_child(BehaviorTree.Inverter.new("not_in_combat", IsInCombatCondition))
EnterCombatSequence:add_child(EnterCombatAction)

return {
    -- 条件节点
    HasTargetCondition = HasTargetCondition,
    HasEnemyCondition = HasEnemyCondition,
    CanAttackCondition = CanAttackCondition,
    IsInAttackRangeCondition = IsInAttackRangeCondition,
    IsTargetDeadCondition = IsTargetDeadCondition,
    IsInCombatCondition = IsInCombatCondition,
    HasCombatTargetCondition = HasCombatTargetCondition,
    HasLastAttackerCondition = HasLastAttackerCondition,
    
    -- 动作节点
    SetTargetAction = SetTargetAction,
    ClearTargetAction = ClearTargetAction,
    PerformAttackAction = PerformAttackAction,
    CheckTargetDeadAction = CheckTargetDeadAction,
    MoveToAttackRangeAction = MoveToAttackRangeAction,
    DetectEnemyAction = DetectEnemyAction,
    EnterCombatAction = EnterCombatAction,
    ExitCombatAction = ExitCombatAction,
    UpdateCombatTargetAction = UpdateCombatTargetAction,
    HandleAttackedAction = HandleAttackedAction,
    
    -- 复合节点
    MoveToAttackRangeSequence = MoveToAttackRangeSequence,
    CombatStateSequence = CombatStateSequence,
    EnterCombatSequence = EnterCombatSequence
} 