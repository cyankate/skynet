local skynet = require "skynet"
local StateEntity = require "scene.state_entity"
local PlayerEntity = require "scene.player_entity"
local MonsterEntity = require "scene.monster_entity"
local BehaviorTree = require "scene.ai.behavior_tree"
local StateMachine = require "scene.ai.state_machine"
local PlayerStateMachine = require "scene.ai.player_state_machine"
local MonsterStateMachine = require "scene.ai.monster_state_machine"
local CombatNodes = require "scene.ai.behavior_nodes.combat_nodes"
local MovementNodes = require "scene.ai.behavior_nodes.movement_nodes"
local StateNodes = require "scene.ai.behavior_nodes.state_nodes"
local scene_mgr = require "scene.scene_mgr"
local log = require "log"

-- 测试配置
local TEST_CONFIG = {
    scene_id = 1001,
    scene_width = 1000,
    scene_height = 1000,
    grid_size = 50,
    test_duration = 30,  -- 测试持续30秒
    update_interval = 0.5
}

-- 全局测试状态
local test_state = {
    scene = nil,
    player = nil,
    monsters = {},
    start_time = 0,
    test_phase = 0,
    phase_start_time = 0
}

-- 创建测试场景
local function create_test_scene()
    log.info("=== 创建测试场景 ===")
    
    local scene_config = {
        width = TEST_CONFIG.scene_width,
        height = TEST_CONFIG.scene_height,
        grid_size = TEST_CONFIG.grid_size,
        terrain_data = {
            -- 创建一些障碍物
            -- {x = 200, y = 200, type = 4, width = 100, height = 100},  -- 障碍物
            -- {x = 600, y = 400, type = 4, width = 80, height = 80},   -- 障碍物
            -- {x = 400, y = 600, type = 4, width = 120, height = 60},  -- 障碍物
        }
    }
    
    test_state.scene = scene_mgr.create_scene(TEST_CONFIG.scene_id, scene_config)
    if not test_state.scene then
        log.error("创建测试场景失败")
        return false
    end
    
    log.info("测试场景创建成功: ID=%d, 大小=%dx%d", 
             TEST_CONFIG.scene_id, TEST_CONFIG.scene_width, TEST_CONFIG.scene_height)
    return true
end

-- 创建玩家实体
local function create_player_entity()
    log.info("=== 创建玩家实体 ===")
    
    local player = PlayerEntity.create_player_entity(1001, 50, 50)
    player.name = "测试玩家"
    player.hp = 100
    player.max_hp = 100
    player.attack = 20
    player.defense = 10
    player.move_speed = 25
    
    -- 创建玩家行为树
    local root = BehaviorTree.Selector.new("player_root")
    
    -- 优先级1：处理死亡
    local dead_sequence = BehaviorTree.Sequence.new("dead_sequence")
    dead_sequence:add_child(StateNodes.IsDeadCondition)
    dead_sequence:add_child(StateNodes.SwitchToDeadAction)
    
    -- 优先级2：处理眩晕
    local stunned_sequence = BehaviorTree.Sequence.new("stunned_sequence")
    stunned_sequence:add_child(StateNodes.ShouldBeStunnedCondition)
    stunned_sequence:add_child(StateNodes.SwitchToStunnedAction)
    
    -- 优先级3：处理攻击
    local attack_sequence = BehaviorTree.Sequence.new("attack_sequence")
    attack_sequence:add_child(CombatNodes.HasEnemyCondition)
    attack_sequence:add_child(CombatNodes.IsInAttackRangeCondition)
    attack_sequence:add_child(CombatNodes.CanAttackCondition)
    attack_sequence:add_child(CombatNodes.PerformAttackAction)
    attack_sequence:add_child(StateNodes.SwitchToAttackAction)
    
    -- 优先级4：移动到敌人
    local move_to_attack_sequence = BehaviorTree.Sequence.new("move_to_attack_sequence")
    move_to_attack_sequence:add_child(CombatNodes.HasEnemyCondition)
    move_to_attack_sequence:add_child(BehaviorTree.Inverter.new("not_in_attack_range", CombatNodes.IsInAttackRangeCondition))
    move_to_attack_sequence:add_child(BehaviorTree.Inverter.new("has_move_target", MovementNodes.HasMoveTargetCondition))
    move_to_attack_sequence:add_child(BehaviorTree.Inverter.new("is_moving", MovementNodes.IsMovingCondition))
    move_to_attack_sequence:add_child(CombatNodes.MoveToAttackRangeAction)
    move_to_attack_sequence:add_child(MovementNodes.SetMoveTargetAction)
    move_to_attack_sequence:add_child(MovementNodes.MoveToTargetSequence)
    move_to_attack_sequence:add_child(StateNodes.SwitchToMoveAction)
    
    -- 优先级5：处理移动请求
    local move_request_sequence = BehaviorTree.Sequence.new("move_request_sequence")
    move_request_sequence:add_child(MovementNodes.HasMoveRequestCondition)
    move_request_sequence:add_child(MovementNodes.CanMoveCondition)
    move_request_sequence:add_child(MovementNodes.StartMoveAction)
    move_request_sequence:add_child(StateNodes.SwitchToMoveAction)
    
    -- 优先级6：处理移动完成
    local move_complete_sequence = BehaviorTree.Sequence.new("move_complete_sequence")
    move_complete_sequence:add_child(MovementNodes.IsMovingCondition)
    move_complete_sequence:add_child(MovementNodes.IsAtTargetCondition)
    move_complete_sequence:add_child(MovementNodes.ClearMoveTargetAction)
    move_complete_sequence:add_child(StateNodes.SwitchToIdleAction)
    
    -- 优先级7：寻找敌人
    local find_enemy_sequence = BehaviorTree.Sequence.new("find_enemy_sequence")
    find_enemy_sequence:add_child(BehaviorTree.Inverter.new("has_no_target", CombatNodes.HasTargetCondition))
    find_enemy_sequence:add_child(CombatNodes.SetTargetAction)
    
    -- 优先级8：待机
    local idle_sequence = BehaviorTree.Sequence.new("idle_sequence")
    idle_sequence:add_child(BehaviorTree.Inverter.new("not_moving", MovementNodes.IsMovingCondition))
    idle_sequence:add_child(StateNodes.SwitchToIdleAction)
    
    root:add_child(dead_sequence)
    root:add_child(stunned_sequence)
    root:add_child(attack_sequence)
    root:add_child(move_to_attack_sequence)
    root:add_child(move_request_sequence)
    root:add_child(move_complete_sequence)
    root:add_child(find_enemy_sequence)
    root:add_child(idle_sequence)
    
    player:set_behavior_tree(root)
    
    -- 添加到场景
    if test_state.scene:add_entity(player) then
        test_state.player = player
        log.info("玩家实体创建成功: ID=%d, 位置=(%.1f, %.1f)", player.id, player.x, player.y)
        return true
    else
        log.error("玩家实体添加到场景失败")
        return false
    end
end

-- 创建怪物实体
local function create_monster_entities()
    log.info("=== 创建怪物实体 ===")
    
    local monster_configs = {
        {id = 2001, x = 200, y = 200, name = "狼", hp = 50, attack = 15, patrol_radius = 1},
        -- {id = 2002, x = 500, y = 500, name = "熊", hp = 80, attack = 25, patrol_radius = 80},
        -- {id = 2003, x = 700, y = 200, name = "蛇", hp = 30, attack = 20, patrol_radius = 120},
    }
    
    for _, config in ipairs(monster_configs) do
        local monster = MonsterEntity.new(config.id, config)
        monster.name = config.name
        monster.hp = config.hp
        monster.max_hp = config.hp
        monster.attack = config.attack
        monster.defense = 5
        monster.move_speed = 5
        monster.patrol_radius = config.patrol_radius
        monster.attack_range = 2.0
        monster.detect_range = 8.0
        
        -- 设置怪物状态机
        local monster_state_machine = MonsterStateMachine.create_monster_state_machine()
        monster:set_state_machine(monster_state_machine)
        
        -- 创建怪物行为树
        local root = BehaviorTree.Selector.new("monster_root")
        
        -- 优先级1：处理死亡
        local dead_sequence = BehaviorTree.Sequence.new("dead_sequence")
        dead_sequence:add_child(StateNodes.IsDeadCondition)
        dead_sequence:add_child(StateNodes.SwitchToDeadAction)
        
        -- 优先级2：处理眩晕
        local stunned_sequence = BehaviorTree.Sequence.new("stunned_sequence")
        stunned_sequence:add_child(StateNodes.ShouldBeStunnedCondition)
        stunned_sequence:add_child(StateNodes.SwitchToStunnedAction)
        
        -- 优先级3：处理受到攻击（进入战斗状态）
        local handle_attacked_sequence = BehaviorTree.Sequence.new("handle_attacked_sequence")
        handle_attacked_sequence:add_child(CombatNodes.HasLastAttackerCondition)
        handle_attacked_sequence:add_child(BehaviorTree.Inverter.new("already_in_combat", CombatNodes.IsInCombatCondition))
        handle_attacked_sequence:add_child(CombatNodes.HandleAttackedAction)
        
        -- 优先级4：战斗状态管理
        local combat_state_sequence = BehaviorTree.Sequence.new("combat_state_sequence")
        combat_state_sequence:add_child(CombatNodes.IsInCombatCondition)
        combat_state_sequence:add_child(CombatNodes.UpdateCombatTargetAction)
        
        -- 优先级5：处理攻击
        local attack_sequence = BehaviorTree.Sequence.new("attack_sequence")
        attack_sequence:add_child(CombatNodes.HasEnemyCondition)
        attack_sequence:add_child(CombatNodes.IsInAttackRangeCondition)
        attack_sequence:add_child(CombatNodes.CanAttackCondition)
        attack_sequence:add_child(CombatNodes.PerformAttackAction)
        attack_sequence:add_child(StateNodes.SwitchToAttackAction)
        
        -- 优先级6：追击敌人
        local chase_sequence = BehaviorTree.Sequence.new("chase_sequence")
        chase_sequence:add_child(CombatNodes.HasEnemyCondition)
        chase_sequence:add_child(BehaviorTree.Inverter.new("not_in_attack_range", CombatNodes.IsInAttackRangeCondition))
        chase_sequence:add_child(BehaviorTree.Inverter.new("has_move_target", MovementNodes.HasMoveTargetCondition))
        chase_sequence:add_child(BehaviorTree.Inverter.new("is_moving", MovementNodes.IsMovingCondition))
        chase_sequence:add_child(CombatNodes.MoveToAttackRangeAction)
        chase_sequence:add_child(MovementNodes.SetMoveTargetAction)
        chase_sequence:add_child(MovementNodes.MoveToTargetSequence)
        chase_sequence:add_child(StateNodes.SwitchToMoveAction)
        
        -- 优先级7：处理移动请求
        local move_request_sequence = BehaviorTree.Sequence.new("move_request_sequence")
        move_request_sequence:add_child(MovementNodes.HasMoveRequestCondition)
        move_request_sequence:add_child(MovementNodes.CanMoveCondition)
        move_request_sequence:add_child(MovementNodes.StartMoveAction)
        move_request_sequence:add_child(StateNodes.SwitchToMoveAction)
        
        -- 优先级8：处理移动完成
        local move_complete_sequence = BehaviorTree.Sequence.new("move_complete_sequence")
        move_complete_sequence:add_child(MovementNodes.IsMovingCondition)
        move_complete_sequence:add_child(MovementNodes.IsAtTargetCondition)
        move_complete_sequence:add_child(MovementNodes.ClearMoveTargetAction)
        move_complete_sequence:add_child(StateNodes.SwitchToIdleAction)
        
        -- 优先级9：巡逻
        local patrol_sequence = BehaviorTree.Sequence.new("patrol_sequence")
        patrol_sequence:add_child(BehaviorTree.Inverter.new("has_move_request", MovementNodes.HasMoveRequestCondition))
        patrol_sequence:add_child(BehaviorTree.Inverter.new("has_move_target", MovementNodes.HasMoveTargetCondition))
        patrol_sequence:add_child(BehaviorTree.Inverter.new("is_moving", MovementNodes.IsMovingCondition))
        patrol_sequence:add_child(MovementNodes.PatrolMoveSequence)
        patrol_sequence:add_child(StateNodes.SwitchToMoveAction)
        
        -- 优先级10：待机
        local idle_sequence = BehaviorTree.Sequence.new("idle_sequence")
        idle_sequence:add_child(BehaviorTree.Inverter.new("not_moving", MovementNodes.IsMovingCondition))
        idle_sequence:add_child(StateNodes.SwitchToIdleAction)
        
        root:add_child(dead_sequence)
        root:add_child(stunned_sequence)
        root:add_child(handle_attacked_sequence)
        root:add_child(combat_state_sequence)
        root:add_child(attack_sequence)
        root:add_child(chase_sequence)
        root:add_child(move_request_sequence)
        root:add_child(move_complete_sequence)
        root:add_child(patrol_sequence)
        root:add_child(idle_sequence)
        
        monster:set_behavior_tree(root)
        
        -- 添加到场景
        if test_state.scene:add_entity(monster) then
            table.insert(test_state.monsters, monster)
            log.info("怪物实体创建成功: %s(ID=%d), 位置=(%.1f, %.1f)", 
                     monster.name, monster.id, monster.x, monster.y)
        else
            log.error("怪物实体 %s 添加到场景失败", monster.name)
        end
    end
    
    log.info("共创建 %d 个怪物实体", #test_state.monsters)
    return #test_state.monsters > 0
end

-- 测试阶段1：基础移动测试
local function test_phase_1_basic_movement()
    log.info("=== 测试阶段1：基础移动测试 ===")
    
    -- 让玩家移动到指定位置
    local target_x, target_y = 200, 200
    test_state.player:request_move(target_x, target_y)
    
    log.info("玩家开始移动到 (%.1f, %.1f)", target_x, target_y)
    
    skynet.sleep(TEST_CONFIG.update_interval * 100)
    -- 等待移动完成
    local wait_time = 0
    while test_state.player:is_moving() and wait_time < 30 do
        skynet.sleep(TEST_CONFIG.update_interval * 100)
        wait_time = wait_time + TEST_CONFIG.update_interval
        
        local current_x, current_y = test_state.player.x, test_state.player.y
        local distance = math.sqrt((current_x - target_x)^2 + (current_y - target_y)^2)
        log.info("玩家位置: (%.1f, %.1f), 距离目标: %.1f", current_x, current_y, distance)
    end
    
    if not test_state.player:is_moving() then
        log.info("玩家移动完成")
        return true
    else
        log.warning("玩家移动超时")
        return false
    end
end

-- 测试阶段2：战斗测试
local function test_phase_2_combat()
    log.info("=== 测试阶段2：战斗测试 ===")
    
    -- 让玩家攻击最近的怪物
    local nearest_monster = nil
    local min_distance = math.huge
    
    for _, monster in ipairs(test_state.monsters) do
        if monster.hp > 0 then
            local distance = math.sqrt((monster.x - test_state.player.x)^2 + (monster.y - test_state.player.y)^2)
            if distance < min_distance then
                min_distance = distance
                nearest_monster = monster
            end
        end
    end
    
    if not nearest_monster then
        log.warning("没有可攻击的怪物")
        return false
    end
    
    log.info("玩家开始攻击怪物: %s(ID=%d)", nearest_monster.name, nearest_monster.id)
    
    -- 设置攻击目标
    test_state.player:set_blackboard_data("target_id", nearest_monster.id)
    
    -- 等待战斗完成
    local wait_time = 0
    local initial_hp = nearest_monster.hp
    
    while nearest_monster.hp > 0 and wait_time < 30 do
        skynet.sleep(TEST_CONFIG.update_interval * 100)
        wait_time = wait_time + TEST_CONFIG.update_interval
        
        log.info("战斗状态: 玩家HP=%d, 怪物HP=%d, 距离=%.1f", 
                 test_state.player.hp, nearest_monster.hp, 
                 math.sqrt((nearest_monster.x - test_state.player.x)^2 + (nearest_monster.y - test_state.player.y)^2))
    end
    
    if nearest_monster.hp <= 0 then
        log.info("战斗完成，怪物 %s 被击败", nearest_monster.name)
        return true
    else
        log.warning("战斗超时")
        return false
    end
end

-- 测试阶段3：状态机测试
local function test_phase_3_state_machine()
    log.info("=== 测试阶段3：状态机测试 ===")
    
    -- 测试眩晕状态
    log.info("测试眩晕状态")
    test_state.player:set_blackboard_data("stun_duration", 3.0)
    
    local wait_time = 0
    while test_state.player:get_blackboard_data("stun_duration", 0) > 0 and wait_time < 5 do
        skynet.sleep(TEST_CONFIG.update_interval * 100)
        wait_time = wait_time + TEST_CONFIG.update_interval
        
        local current_state = test_state.player:get_current_state_name()
        local stun_duration = test_state.player:get_blackboard_data("stun_duration", 0)
        log.info("眩晕状态: %s, 剩余时间: %.1f", current_state, stun_duration)
    end
    
    -- 测试死亡状态
    log.info("测试死亡状态")
    test_state.player.hp = 0
    
    skynet.sleep(TEST_CONFIG.update_interval * 100)
    local current_state = test_state.player:get_current_state_name()
    log.info("死亡状态: %s", current_state)
    
    -- 恢复玩家
    test_state.player.hp = 100
    test_state.player:set_blackboard_data("stun_duration", 0)
    
    return true
end

-- 测试阶段4：怪物AI测试
local function test_phase_4_monster_ai()
    log.info("=== 测试阶段4：怪物AI测试 ===")
    
    -- 观察怪物行为
    local observation_time = 10
    local start_time = skynet.now() / 100
    
    while (skynet.now() / 100) - start_time < observation_time do
        skynet.sleep(TEST_CONFIG.update_interval * 100)
        
        for _, monster in ipairs(test_state.monsters) do
            if monster.hp > 0 then
                local current_state = monster:get_current_state_name()
                local target_id = monster:get_blackboard_data("target_id")
                local is_moving = monster:is_moving()
                
                log.info("怪物 %s: 状态=%s, 目标=%s, 移动=%s, 位置=(%.1f, %.1f)", 
                         monster.name, current_state, target_id or "无", 
                         is_moving and "是" or "否", monster.x, monster.y)
            end
        end
    end
    
    return true
end

-- 测试阶段5：复杂交互测试
local function test_phase_5_complex_interaction()
    log.info("=== 测试阶段5：复杂交互测试 ===")
    
    -- 让玩家在怪物群中移动，触发复杂的AI交互
    local waypoints = {
        {x = 400, y = 400},
        {x = 600, y = 300},
        {x = 800, y = 500},
        {x = 300, y = 700},
        {x = 100, y = 500},
    }
    
    for i, waypoint in ipairs(waypoints) do
        log.info("移动到路径点 %d: (%.1f, %.1f)", i, waypoint.x, waypoint.y)
        test_state.player:request_move(waypoint.x, waypoint.y)
        
        -- 等待到达或超时
        local wait_time = 0
        while test_state.player:is_moving() and wait_time < 8 do
            skynet.sleep(TEST_CONFIG.update_interval * 100)
            wait_time = wait_time + TEST_CONFIG.update_interval
            
            -- 检查是否有怪物在攻击玩家
            for _, monster in ipairs(test_state.monsters) do
                if monster.hp > 0 and monster:get_blackboard_data("target_id") == test_state.player.id then
                    log.info("怪物 %s 正在追击玩家", monster.name)
                end
            end
        end
        
        if not test_state.player:is_moving() then
            log.info("到达路径点 %d", i)
        else
            log.warning("到达路径点 %d 超时", i)
        end
        
        -- 短暂停留
        skynet.sleep(1 * 100)
    end
    
    return true
end

-- 打印测试统计信息
local function print_test_statistics()
    log.info("=== 测试统计信息 ===")
    
    -- 玩家统计
    log.info("玩家统计:")
    log.info("  最终位置: (%.1f, %.1f)", test_state.player.x, test_state.player.y)
    log.info("  最终血量: %d/%d", test_state.player.hp, test_state.player.max_hp)
    log.info("  当前状态: %s", test_state.player:get_current_state_name())
    
    -- 怪物统计
    log.info("怪物统计:")
    local alive_count = 0
    local dead_count = 0
    
    for _, monster in ipairs(test_state.monsters) do
        if monster.hp > 0 then
            alive_count = alive_count + 1
            log.info("  %s: 存活, 位置=(%.1f, %.1f), 状态=%s", 
                     monster.name, monster.x, monster.y, monster:get_current_state_name())
        else
            dead_count = dead_count + 1
            log.info("  %s: 死亡", monster.name)
        end
    end
    
    log.info("  存活: %d, 死亡: %d", alive_count, dead_count)
    
    -- 场景统计
    local scene_entities = test_state.scene:get_all_entities()
    log.info("场景统计:")
    log.info("  总实体数: %d", #scene_entities)
    
    -- 黑板统计
    log.info("黑板统计:")
    local player_blackboard = test_state.player.blackboard
    local stats = player_blackboard:get_stats()
    log.info("  数据项数: %d", stats.total_keys)
    log.info("  监听器数: %d", stats.total_listeners)
    log.info("  历史记录: %d", stats.total_history)
end

-- 清理测试环境
local function cleanup_test()
    log.info("=== 清理测试环境 ===")
    
    -- 销毁场景
    if test_state.scene then
        scene_mgr.destroy_scene(TEST_CONFIG.scene_id)
        test_state.scene = nil
    end
    
    -- 清理全局状态
    test_state.player = nil
    test_state.monsters = {}
    
    log.info("测试环境清理完成")
end

-- 主测试函数
local function run_comprehensive_test()
    log.info("=== 开始综合AI测试 ===")
    log.info("测试配置: 场景ID=%d, 持续时间=%d秒", TEST_CONFIG.scene_id, TEST_CONFIG.test_duration)
    
    test_state.start_time = skynet.now() / 100
    
    -- 初始化测试环境
    if not create_test_scene() then
        log.error("测试环境初始化失败")
        return false
    end
    
    if not create_player_entity() then
        log.error("玩家实体创建失败")
        return false
    end
    
    if not create_monster_entities() then
        log.error("怪物实体创建失败")
        return false
    end
    
    log.info("测试环境初始化完成")
    
    -- 执行测试阶段
    local test_phases = {
        {name = "基础移动测试", func = test_phase_1_basic_movement},
        {name = "战斗测试", func = test_phase_2_combat},
        -- {name = "状态机测试", func = test_phase_3_state_machine},
        -- {name = "怪物AI测试", func = test_phase_4_monster_ai},
        -- {name = "复杂交互测试", func = test_phase_5_complex_interaction},
    }
    
    for i, phase in ipairs(test_phases) do
        log.info("开始执行测试阶段 %d: %s", i, phase.name)
        test_state.phase_start_time = skynet.now() / 100
        
        local success = phase.func()
        
        local phase_duration = (skynet.now() / 100) - test_state.phase_start_time
        log.info("测试阶段 %d 完成: %s, 耗时: %.1f秒", i, success and "成功" or "失败", phase_duration)
        
        if not success then
            log.warning("测试阶段 %d 失败，继续执行后续测试", i)
        end
        
        -- 阶段间短暂休息
        skynet.sleep(1 * 100)
    end
    
    -- 打印统计信息
    print_test_statistics()
    
    -- 清理环境
    cleanup_test()
    
    local total_duration = (skynet.now() / 100) - test_state.start_time
    log.info("=== 综合AI测试完成，总耗时: %.1f秒 ===", total_duration)
    
    return true
end

-- 导出测试函数
return {
    run_test = run_comprehensive_test,
    test_config = TEST_CONFIG,
    test_state = test_state,
    -- 导出测试阶段函数
    test_phase_1_basic_movement = test_phase_1_basic_movement,
    test_phase_2_combat = test_phase_2_combat,
    test_phase_3_state_machine = test_phase_3_state_machine,
    test_phase_4_monster_ai = test_phase_4_monster_ai,
    test_phase_5_complex_interaction = test_phase_5_complex_interaction,
    -- 导出创建函数
    create_test_scene = create_test_scene,
    create_player_entity = create_player_entity,
    create_monster_entities = create_monster_entities,
    -- 导出工具函数
    print_test_statistics = print_test_statistics,
    cleanup_test = cleanup_test
} 