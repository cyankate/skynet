local skynet = require "skynet"
local service_wrapper = require "utils.service_wrapper"
local scene_mgr = require "scene.scene_mgr"
local log = require "log"

-- 创建场景
function CMD.create_scene(scene_id, config)
    local scene = scene_mgr.create_scene(scene_id, config)
    if not scene then
        return false, "创建场景失败"
    end
    return true
end

-- 销毁场景
function CMD.destroy_scene(scene_id)
    return scene_mgr.destroy_scene(scene_id)
end

-- 实体进入场景
function CMD.enter_scene(scene_id, entity_data)
    local scene = scene_mgr.get_scene(scene_id)
    if not scene then
        return false, "场景不存在"
    end
    
    local Entity = require "scene.entity"
    local entity = Entity.new(entity_data.id, entity_data.type)
    
    -- 设置实体属性
    for k, v in pairs(entity_data.properties or {}) do
        entity:set_property(k, v)
    end
    
    -- 设置实体位置
    entity:set_position(entity_data.x or 0, entity_data.y or 0)
    
    -- 设置视野范围
    if entity_data.view_range then
        entity.view_range = entity_data.view_range
    end
    
    -- 进入场景
    if not entity:enter_scene(scene) then
        return false, "进入场景失败"
    end
    
    return true
end

-- 实体离开场景
function CMD.leave_scene(scene_id, entity_id)
    local scene = scene_mgr.get_scene(scene_id)
    if not scene then
        return false, "场景不存在"
    end
    
    return scene:remove_entity(entity_id)
end

-- 实体移动
function CMD.move_entity(scene_id, entity_id, x, y)
    local scene = scene_mgr.get_scene(scene_id)
    if not scene then
        return false, "场景不存在"
    end
    
    return scene:move_entity(entity_id, x, y)
end

-- 获取实体周围的其他实体
function CMD.get_surrounding_entities(scene_id, entity_id)
    local scene = scene_mgr.get_scene(scene_id)
    if not scene then
        return {}
    end
    
    return scene:get_surrounding_entities(entity_id)
end

-- 广播场景消息
function CMD.broadcast_scene(scene_id, message, exclude_entity_id)
    local scene = scene_mgr.get_scene(scene_id)
    if not scene then
        return false, "场景不存在"
    end
    
    local entities = scene.entities
    local count = 0
    
    for entity_id, entity in pairs(entities) do
        if entity_id ~= exclude_entity_id then
            -- 这里应该调用实体的消息处理方法
            -- entity:handle_message(message)
            count = count + 1
        end
    end
    
    return true, count
end

-- 运行综合AI测试
function CMD.run_ai_test()
    local comprehensive_test = require "test.comprehensive_ai_test"
    return comprehensive_test.run_test()
end

-- 运行特定测试阶段
function CMD.run_test_phase(phase_name)
    local comprehensive_test = require "test.comprehensive_ai_test"
    
    local phase_functions = {
        basic_movement = comprehensive_test.test_phase_1_basic_movement,
        combat = comprehensive_test.test_phase_2_combat,
        state_machine = comprehensive_test.test_phase_3_state_machine,
        monster_ai = comprehensive_test.test_phase_4_monster_ai,
        complex_interaction = comprehensive_test.test_phase_5_complex_interaction,
    }
    
    local phase_func = phase_functions[phase_name]
    if not phase_func then
        return false, "未知的测试阶段: " .. (phase_name or "nil")
    end
    
    -- 确保测试环境已初始化
    if not comprehensive_test.test_state.scene then
        if not comprehensive_test.create_test_scene() then
            return false, "测试环境初始化失败"
        end
        if not comprehensive_test.create_player_entity() then
            return false, "玩家实体创建失败"
        end
        if not comprehensive_test.create_monster_entities() then
            return false, "怪物实体创建失败"
        end
    end
    
    return phase_func()
end

-- 获取测试状态
function CMD.get_test_status()
    local comprehensive_test = require "test.comprehensive_ai_test"
    local state = comprehensive_test.test_state
    
    local result = {
        scene_exists = state.scene ~= nil,
        player_exists = state.player ~= nil,
        monster_count = #state.monsters,
        start_time = state.start_time,
        test_phase = state.test_phase,
        phase_start_time = state.phase_start_time
    }
    
    if state.player then
        result.player_info = {
            id = state.player.id,
            x = state.player.x,
            y = state.player.y,
            hp = state.player.hp,
            current_state = state.player:get_current_state_name(),
            is_moving = state.player:is_moving()
        }
    end
    
    if #state.monsters > 0 then
        result.monster_info = {}
        for _, monster in ipairs(state.monsters) do
            table.insert(result.monster_info, {
                id = monster.id,
                name = monster.name,
                x = monster.x,
                y = monster.y,
                hp = monster.hp,
                current_state = monster:get_current_state_name(),
                is_moving = monster:is_moving()
            })
        end
    end
    
    return result
end

-- 清理测试环境
function CMD.cleanup_test()
    local comprehensive_test = require "test.comprehensive_ai_test"
    comprehensive_test.cleanup_test()
    return true
end

local function main()
    -- 初始化场景管理器
    scene_mgr.init()
    CMD.run_ai_test()
    log.info("Scene service initialized")
end

service_wrapper.create_service(main, {
    name = "scene",
})