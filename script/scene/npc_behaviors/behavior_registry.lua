local skynet = require "skynet"
local log = require "log"

-- 行为注册器
local BehaviorRegistry = {}

-- 已注册的行为
BehaviorRegistry.behaviors = {}

-- 行为配置
BehaviorRegistry.config = {
    auto_discover = true,  -- 自动发现行为
    behavior_path = "scene.npc_behaviors.",  -- 行为路径前缀
    default_behaviors = {  -- 默认行为列表
        "quest_behavior",
        "shop_behavior", 
        "transport_behavior",
        "dialog_behavior",
    }
}

-- 注册行为
function BehaviorRegistry.register_behavior(behavior_name, behavior_class)
    if not behavior_name or not behavior_class then
        log.error("注册行为失败: 参数无效")
        return false
    end
    
    BehaviorRegistry.behaviors[behavior_name] = {
        class = behavior_class,
        name = behavior_name,
        registered_time = os.time()
    }
    
    log.info("注册功能行为: %s", behavior_name)
    return true
end

-- 获取行为
function BehaviorRegistry.get_behavior(behavior_name)
    local behavior_info = BehaviorRegistry.behaviors[behavior_name]
    if behavior_info then
        return behavior_info.class
    end
    return nil
end

-- 获取所有已注册的行为
function BehaviorRegistry.get_all_behaviors()
    local behaviors = {}
    for name, info in pairs(BehaviorRegistry.behaviors) do
        table.insert(behaviors, {
            name = name,
            registered_time = info.registered_time
        })
    end
    return behaviors
end

-- 获取行为名称列表
function BehaviorRegistry.get_behavior_names()
    local names = {}
    for name, _ in pairs(BehaviorRegistry.behaviors) do
        table.insert(names, name)
    end
    return names
end

-- 检查行为是否存在
function BehaviorRegistry.has_behavior(behavior_name)
    return BehaviorRegistry.behaviors[behavior_name] ~= nil
end

-- 移除行为
function BehaviorRegistry.remove_behavior(behavior_name)
    if BehaviorRegistry.behaviors[behavior_name] then
        BehaviorRegistry.behaviors[behavior_name] = nil
        log.info("移除功能行为: %s", behavior_name)
        return true
    end
    return false
end

-- 创建行为实例
function BehaviorRegistry.create_behavior(behavior_name, npc, config)
    local behavior_class = BehaviorRegistry.get_behavior(behavior_name)
    if behavior_class then
        return behavior_class.new(npc, config)
    else
        log.warning("行为不存在: %s", behavior_name)
        return nil
    end
end

-- 自动发现并注册行为
function BehaviorRegistry.auto_discover_behaviors()
    if not BehaviorRegistry.config.auto_discover then
        return
    end
    
    log.info("开始自动发现功能行为...")
    
    for _, behavior_file in ipairs(BehaviorRegistry.config.default_behaviors) do
        local success, behavior_class = pcall(require, BehaviorRegistry.config.behavior_path .. behavior_file)
        if success and behavior_class then
            -- 从文件名提取行为名
            local behavior_name = string.gsub(behavior_file, "_behavior$", "")
            BehaviorRegistry.register_behavior(behavior_name, behavior_class)
        else
            log.warning("加载行为失败: %s", behavior_file)
        end
    end
    
    log.info("自动发现完成，共注册 %d 个行为", #BehaviorRegistry.get_behavior_names())
end

-- 手动加载行为
function BehaviorRegistry.load_behavior(behavior_file)
    local success, behavior_class = pcall(require, BehaviorRegistry.config.behavior_path .. behavior_file)
    if success and behavior_class then
        local behavior_name = string.gsub(behavior_file, "_behavior$", "")
        return BehaviorRegistry.register_behavior(behavior_name, behavior_class)
    else
        log.error("加载行为失败: %s", behavior_file)
        return false
    end
end

-- 获取行为统计信息
function BehaviorRegistry.get_stats()
    local total_behaviors = #BehaviorRegistry.get_behavior_names()
    local behavior_details = {}
    
    for name, info in pairs(BehaviorRegistry.behaviors) do
        table.insert(behavior_details, {
            name = name,
            registered_time = info.registered_time,
            class_name = info.class.__cname or "Unknown"
        })
    end
    
    return {
        total_behaviors = total_behaviors,
        auto_discover = BehaviorRegistry.config.auto_discover,
        behaviors = behavior_details
    }
end

-- 验证行为配置
function BehaviorRegistry.validate_behavior_config(behavior_name, config)
    local behavior_class = BehaviorRegistry.get_behavior(behavior_name)
    if not behavior_class then
        return false, "行为不存在"
    end
    
    -- 创建临时实例进行配置验证
    local temp_npc = { id = 0 }
    local temp_behavior = behavior_class.new(temp_npc, config)
    
    if temp_behavior.validate_config then
        return temp_behavior:validate_config(config)
    end
    
    return true
end

-- 重新加载行为
function BehaviorRegistry.reload_behavior(behavior_name)
    if not BehaviorRegistry.has_behavior(behavior_name) then
        log.warning("行为不存在，无法重新加载: %s", behavior_name)
        return false
    end
    
    -- 移除旧行为
    BehaviorRegistry.remove_behavior(behavior_name)
    
    -- 重新加载
    local behavior_file = behavior_name .. "_behavior"
    return BehaviorRegistry.load_behavior(behavior_file)
end

-- 批量重新加载所有行为
function BehaviorRegistry.reload_all_behaviors()
    log.info("开始重新加载所有行为...")
    
    local behavior_names = BehaviorRegistry.get_behavior_names()
    local success_count = 0
    
    for _, behavior_name in ipairs(behavior_names) do
        if BehaviorRegistry.reload_behavior(behavior_name) then
            success_count = success_count + 1
        end
    end
    
    log.info("重新加载完成: %d/%d 成功", success_count, #behavior_names)
    return success_count
end

return BehaviorRegistry 