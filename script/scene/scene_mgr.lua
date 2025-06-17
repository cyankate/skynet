local skynet = require "skynet"
local Scene = require "scene.scene"
local log = require "log"

local scene_mgr = {}

-- 场景列表
local scenes = {}  -- scene_id => scene_obj

-- 场景更新间隔(秒)
local UPDATE_INTERVAL = 0.1

-- 初始化
function scene_mgr.init()
    -- 可以在这里加载场景配置
    log.info("Scene manager initialized")
end

-- 创建场景
function scene_mgr.create_scene(scene_id, config)
    if scenes[scene_id] then
        log.error("Scene %d already exists", scene_id)
        return nil
    end
    
    local scene = Scene.new(scene_id, config)
    scenes[scene_id] = scene
    
    return scene
end

-- 获取场景
function scene_mgr.get_scene(scene_id)
    return scenes[scene_id]
end

-- 销毁场景
function scene_mgr.destroy_scene(scene_id)
    local scene = scenes[scene_id]
    if scene then
        scene:destroy()
        scenes[scene_id] = nil
    end
end

-- 更新所有场景
local function update()
    while true do
        -- 更新每个场景
        for _, scene in pairs(scenes) do
            scene:update()
        end
        
        -- 等待下一次更新
        skynet.sleep(UPDATE_INTERVAL * 100)  -- skynet.sleep的单位是0.01秒
    end
end

-- 启动场景管理器
function scene_mgr.start()
    -- 启动更新协程
    skynet.fork(update)
end

-- 停止场景管理器
function scene_mgr.stop()
    -- 销毁所有场景
    for scene_id, _ in pairs(scenes) do
        scene_mgr.destroy_scene(scene_id)
    end
end

-- 加载场景配置
function scene_mgr.load_scene_config(config_file)
    local config = require(config_file)
    
    for scene_id, scene_config in pairs(config) do
        -- 创建场景
        local scene = scene_mgr.create_scene(scene_id, scene_config)
        if scene then
            -- 加载地形数据
            if scene_config.terrain_data then
                scene:load_terrain(scene_config.terrain_data)
            end
            
            -- 加载NPC数据
            if scene_config.npcs then
                for _, npc_data in ipairs(scene_config.npcs) do
                    local NPCEntity = require "scene.npc_entity"
                    local npc = NPCEntity.new(npc_data.id, npc_data)
                    npc:set_position(npc_data.x, npc_data.y)
                    scene:add_entity(npc)
                end
            end
            
            -- 加载怪物数据
            if scene_config.monsters then
                for _, monster_data in ipairs(scene_config.monsters) do
                    local MonsterEntity = require "scene.monster_entity"
                    local monster = MonsterEntity.new(monster_data.id, monster_data)
                    monster:set_position(monster_data.x, monster_data.y)
                    scene:add_entity(monster)
                end
            end
            
            -- 加载传送点数据
            if scene_config.transport_points then
                for _, point in ipairs(scene_config.transport_points) do
                    scene:add_transport_point(point)
                end
            end
            
            -- 加载安全区数据
            if scene_config.safe_zones then
                for _, zone in ipairs(scene_config.safe_zones) do
                    scene:add_safe_zone(zone)
                end
            end
        end
    end
end

-- 保存场景数据
function scene_mgr.save_scene_data(scene_id, file_path)
    local scene = scenes[scene_id]
    if not scene then
        return false, "场景不存在"
    end
    
    -- 序列化场景数据
    local data = scene:serialize()
    
    -- 保存到文件
    local file = io.open(file_path, "w")
    if not file then
        return false, "无法打开文件"
    end
    
    file:write(skynet.packstring(data))
    file:close()
    
    return true
end

-- 加载场景数据
function scene_mgr.load_scene_data(scene_id, file_path)
    -- 读取文件
    local file = io.open(file_path, "r")
    if not file then
        return false, "无法打开文件"
    end
    
    local content = file:read("*a")
    file:close()
    
    -- 反序列化数据
    local ok, data = pcall(skynet.unpackstring, content)
    if not ok then
        return false, "数据格式错误"
    end
    
    -- 获取或创建场景
    local scene = scenes[scene_id]
    if not scene then
        scene = scene_mgr.create_scene(scene_id, data.config)
        if not scene then
            return false, "创建场景失败"
        end
    end
    
    -- 反序列化场景数据
    scene:deserialize(data)
    
    return true
end

-- 获取所有场景
function scene_mgr.get_all_scenes()
    return scenes
end

-- 传送玩家到指定场景
function scene_mgr.transport_player(player, target_scene_id, x, y)
    -- 获取目标场景
    local target_scene = scenes[target_scene_id]
    if not target_scene then
        return false, "目标场景不存在"
    end
    
    -- 从当前场景移除
    if player.scene then
        player:leave_scene()
    end
    
    -- 设置新位置
    player:set_position(x, y)
    
    -- 进入新场景
    return player:enter_scene(target_scene)
end

return scene_mgr