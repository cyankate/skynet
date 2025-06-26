local Blackboard = require "scene.ai.blackboard"
local StateMachine = require "scene.ai.state_machine"
local BehaviorTree = require "scene.ai.behavior_tree"
local AINodes = require "scene.ai.ai_nodes"
local CommandSystem = require "scene.ai.command_system"
local log = require "log"

-- AI管理器
local AIManager = class("AIManager")

function AIManager:ctor(entity, config)
    self.entity = entity
    self.config = config or {}
    
    -- 创建黑板
    self.blackboard = Blackboard.new(entity)
    
    -- 创建状态机
    self.state_machine = StateMachine.StateMachine.new("EntityAI")
    self.state_machine:set_context(self.blackboard, entity)
    
    -- 创建命令系统
    self.command_system = CommandSystem.CommandSystem.new(entity)
    
    -- 创建行为树
    self.behavior_tree = self:create_behavior_tree()
    
    -- 初始化
    self:init_state_machine()
    
    log.debug("AIManager: 创建AI管理器 %s", entity.id)
end

-- 初始化状态机
function AIManager:init_state_machine()
    -- 添加所有状态
    self.state_machine:add_state(StateMachine.IdleState.new())
    self.state_machine:add_state(StateMachine.MovingState.new())
    self.state_machine:add_state(StateMachine.AttackingState.new())
    self.state_machine:add_state(StateMachine.ChasingState.new())
    self.state_machine:add_state(StateMachine.PatrolState.new())
    self.state_machine:add_state(StateMachine.FleeState.new())
    self.state_machine:add_state(StateMachine.StunnedState.new())
    self.state_machine:add_state(StateMachine.DeadState.new())
    
    -- 设置初始状态
    self.state_machine:set_initial_state("idle")
    
    -- 启动状态机
    self.state_machine:start()
end

-- 创建行为树
function AIManager:create_behavior_tree()
    local BT = BehaviorTree
    
    -- 创建根选择器
    local root = BT.Selector.new("RootSelector")
    
    -- 1. 死亡检查
    local death_sequence = BT.Sequence.new("DeathSequence")
    death_sequence:add_child(BT.Inverter.new("not_dead", AINodes.IsDeadCondition))
    root:add_child(death_sequence)

    -- 2. 命令检查
    local command_sequence = BT.Sequence.new("CommandSequence")
    command_sequence:add_child(AINodes.IsInCommandCondition)
    root:add_child(command_sequence)
    
    -- 3. 非死亡状态下的AI逻辑（只有非死亡时才执行）
    local alive_selector = BT.Selector.new("AliveSelector")
    
    -- 3.1 眩晕检查
    local stun_sequence = BT.Sequence.new("StunSequence")
    stun_sequence:add_child(AINodes.IsStunnedCondition)
    stun_sequence:add_child(AINodes.RequestStunnedAction)
    alive_selector:add_child(stun_sequence)
    
    -- 3.2 战斗检查
    local combat_selector = BT.Selector.new("CombatSelector")
    
    -- 3.2.1 进入战斗
    local enter_combat_sequence = BT.Sequence.new("EnterCombatSequence")
    enter_combat_sequence:add_child(BT.Inverter.new("not_in_combat", AINodes.IsInCombatCondition))
    enter_combat_sequence:add_child(AINodes.HasEnemyCondition)
    enter_combat_sequence:add_child(AINodes.EnterCombatSequence)
    combat_selector:add_child(enter_combat_sequence)
    
    -- 3.2.2 继续战斗
    local continue_combat_sequence = BT.Sequence.new("ContinueCombatSequence")
    continue_combat_sequence:add_child(AINodes.IsInCombatCondition)
    continue_combat_sequence:add_child(AINodes.HasEnemyCondition)
    combat_selector:add_child(continue_combat_sequence)
    
    alive_selector:add_child(combat_selector)
    
    -- 3.3 巡逻
    local patrol_sequence = BT.Sequence.new("PatrolSequence")
    patrol_sequence:add_child(AINodes.NeedsPatrolCondition)
    patrol_sequence:add_child(AINodes.create_patrol_behavior())
    alive_selector:add_child(patrol_sequence)
    
    -- 3.4 空闲
    local idle_sequence = BT.Sequence.new("IdleSequence")
    idle_sequence:add_child(BT.Inverter.new("not_idle", AINodes.IsIdleCondition))
    idle_sequence:add_child(AINodes.RequestIdleAction)
    alive_selector:add_child(idle_sequence)
    
    root:add_child(alive_selector)
    
    return root
end

-- 更新AI
function AIManager:update(dt)
    -- 1. 优先处理命令（最高优先级）
    if self.command_system:has_commands() then
        self.command_system:process_commands(dt)
        return  -- 有命令时暂停AI决策
    end
    
    -- 2. 执行行为树决策
    self:update_behavior_tree(dt)
    
    -- 3. 执行状态机逻辑
    self:update_state_machine(dt)
end

-- 更新行为树
function AIManager:update_behavior_tree(dt)
    local context = {
        entity = self.entity,
        blackboard = self.blackboard,
        dt = dt,
        log = self.config.enable_logging
    }
    
    self.behavior_tree:run(context)
end

-- 更新状态机
function AIManager:update_state_machine(dt)
    self.state_machine:update(dt)
end

-- 命令系统接口
function AIManager:add_command(command)
    return self.command_system:add_command(command)
end

function AIManager:clear_commands()
    self.command_system:clear_commands()
end

function AIManager:has_commands()
    return self.command_system:has_commands()
end

function AIManager:has_active_command()
    return self.command_system:has_active_command()
end

function AIManager:get_current_command()
    return self.command_system:get_current_command()
end

-- 便捷命令方法
function AIManager:move_to(x, y, speed)
    return self.command_system:move_to(x, y, speed)
end

function AIManager:dance(dance_type, duration)
    return self.command_system:dance(dance_type, duration)
end

function AIManager:attack(target_id, skill_id)
    return self.command_system:attack(target_id, skill_id)
end

function AIManager:use_skill(skill_id, target_x, target_y)
    return self.command_system:use_skill(skill_id, target_x, target_y)
end

function AIManager:emote(emote_type, duration)
    return self.command_system:emote(emote_type, duration)
end

function AIManager:follow(target_id, distance)
    return self.command_system:follow(target_id, distance)
end

function AIManager:stop()
    return self.command_system:stop()
end

-- 便捷方法
function AIManager:get_current_state()
    return self.state_machine:get_current_state_name()
end

function AIManager:get_state_time()
    return self.state_machine:get_state_time()
end

function AIManager:is_in_state(state_name)
    return self.state_machine:is_in_state(state_name)
end

function AIManager:change_state(state_name)
    return self.state_machine:change_state(state_name)
end

function AIManager:get_blackboard()
    return self.blackboard
end

function AIManager:get_state_machine()
    return self.state_machine
end

function AIManager:get_behavior_tree()
    return self.behavior_tree
end

function AIManager:get_command_system()
    return self.command_system
end

function AIManager:set_logging(enabled)
    self.config.enable_logging = enabled
end

-- 调试方法
function AIManager:debug_info()
    return {
        entity_id = self.entity and self.entity.id,
        current_state = self:get_current_state(),
        state_time = self:get_state_time(),
        blackboard_data = self.blackboard:get_all(),
        is_running = self.state_machine.is_running,
        has_commands = self:has_commands(),
        current_command = self:get_current_command() and self:get_current_command().type
    }
end

function AIManager:dump_debug()
    local info = self:debug_info()
    log.debug("=== AI管理器调试信息 ===")
    log.debug("实体ID: %s", tostring(info.entity_id))
    log.debug("当前状态: %s", info.current_state)
    log.debug("状态时间: %.2f", info.state_time)
    log.debug("运行状态: %s", tostring(info.is_running))
    log.debug("有命令: %s", tostring(info.has_commands))
    log.debug("当前命令: %s", tostring(info.current_command))
    self.blackboard:dump()
end

return AIManager 