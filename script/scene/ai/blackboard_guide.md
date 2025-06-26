# 黑板系统使用指南

## 概述

黑板系统是行为树中用于数据共享和状态管理的重要组件。它提供了一个安全、高效的数据存储和通信机制，让不同的行为树节点之间可以共享数据，并且支持数据监听、变化通知、历史记录等功能。

## 核心特性

### 1. 数据管理
- **安全存储**: 支持任意类型的数据存储
- **数据锁定**: 防止关键数据被意外修改
- **批量操作**: 支持批量设置和获取数据
- **数据验证**: 支持自定义数据验证规则

### 2. 监听机制
- **变化监听**: 监听数据变化并触发回调
- **一次性观察**: 支持一次性监听器（观察者模式）
- **错误处理**: 监听器执行失败时自动记录错误

### 3. 历史记录
- **自动记录**: 自动记录所有数据变化
- **历史查询**: 支持按时间或键值查询历史记录
- **容量控制**: 可配置最大历史记录数量

### 4. 调试支持
- **统计信息**: 提供详细的统计信息
- **调试输出**: 支持调试信息输出
- **数据导出**: 支持数据导出和导入

## 基本使用

### 创建黑板

```lua
local Blackboard = require "scene.ai.blackboard"
local blackboard = Blackboard.new()
```

### 基本操作

```lua
-- 设置数据
blackboard:set("player_position", {x = 100, y = 200}, "player_movement")
blackboard:set("enemy_count", 5, "spawn_system")

-- 获取数据
local pos = blackboard:get("player_position")
local count = blackboard:get("enemy_count", 0)  -- 提供默认值

-- 检查数据是否存在
if blackboard:has("player_position") then
    -- 数据存在
end

-- 删除数据
blackboard:remove("temp_data", "cleanup")
```

### 数据锁定

```lua
-- 锁定重要数据
blackboard:set("critical_config", "important_value", "init")
blackboard:lock("critical_config")

-- 尝试修改被锁定的数据
local success = blackboard:set("critical_config", "new_value", "test")
if not success then
    print("数据被锁定，无法修改")
end

-- 解锁数据
blackboard:unlock("critical_config")
```

### 监听器

```lua
-- 添加数据变化监听器
blackboard:add_listener("player_health", function(key, old_value, new_value, source, context)
    print(string.format("玩家血量变化: %d -> %d (来源: %s)", old_value, new_value, source))
    
    -- 检查血量是否过低
    if new_value < 20 then
        print("警告：玩家血量过低！")
    end
end, {player_id = 123})

-- 添加一次性观察者
blackboard:watch("boss_spawn", function(key, old_value, new_value, source, context)
    print("Boss已生成！")
    -- 这个监听器只会触发一次，然后自动移除
end)

-- 移除监听器
blackboard:remove_listener("player_health", callback_function)
```

### 批量操作

```lua
-- 批量设置数据
local data_batch = {
    player_x = 100,
    player_y = 200,
    player_health = 80,
    player_level = 5
}
blackboard:set_multiple(data_batch, "player_update")

-- 批量获取数据
local keys = {"player_x", "player_y", "player_health"}
local values = blackboard:get_multiple(keys)
```

### 历史记录

```lua
-- 获取历史记录
local history = blackboard:get_history("player_position", 10)  -- 最近10条记录
for _, record in ipairs(history) do
    print(string.format("时间: %d, 值: %s", record.timestamp, tostring(record.new_value)))
end

-- 清空历史记录
blackboard:clear_history()
```

### 数据验证和转换

```lua
-- 数据验证
local is_valid = blackboard:validate("player_level", function(value)
    return type(value) == "number" and value >= 1 and value <= 100
end)

-- 数据转换
local transformed = blackboard:transform("player_position", function(pos)
    return {x = math.floor(pos.x), y = math.floor(pos.y)}
end)
```

## 在行为树中使用

### 行为树管理器集成

```lua
local BehaviorTreeManager = require "scene.ai.behavior_tree_manager"

-- 创建管理器
local manager = BehaviorTreeManager.new()

-- 获取黑板
local blackboard = manager:get_blackboard()

-- 在行为树节点中使用黑板
local action_node = BT.Action.new("移动动作", function(context)
    local blackboard = context.blackboard
    local target = blackboard:get("move_target")
    
    if target then
        -- 执行移动逻辑
        blackboard:set("last_move_time", os.time(), "move_action")
        return BT.Status.SUCCESS
    end
    
    return BT.Status.FAILURE
end)
```

### 节点间数据共享

```lua
-- 条件节点：检查目标
local check_target = BT.Condition.new("检查目标", function(context)
    local blackboard = context.blackboard
    local target = find_nearest_enemy()
    
    if target then
        blackboard:set("current_target", target, "target_search")
        blackboard:set("target_found_time", os.time(), "target_search")
        return true
    end
    
    return false
end)

-- 动作节点：攻击目标
local attack_target = BT.Action.new("攻击目标", function(context)
    local blackboard = context.blackboard
    local target = blackboard:get("current_target")
    
    if target then
        -- 执行攻击逻辑
        blackboard:set("last_attack_time", os.time(), "attack_action")
        return BT.Status.SUCCESS
    end
    
    return BT.Status.FAILURE
end)
```

## 高级功能

### 自定义数据监听

```lua
-- 监听多个相关数据
blackboard:add_listener("player_position", function(key, old_value, new_value, source)
    -- 当位置变化时，更新相关数据
    local distance = calculate_distance(old_value, new_value)
    blackboard:set("total_distance", 
        blackboard:get("total_distance", 0) + distance, "position_tracking")
end)

-- 监听数据组合
blackboard:add_listener("player_health", function(key, old_value, new_value, source)
    local max_health = blackboard:get("player_max_health", 100)
    local health_percent = (new_value / max_health) * 100
    blackboard:set("health_percent", health_percent, "health_calculation")
end)
```

### 数据统计和调试

```lua
-- 获取统计信息
local stats = blackboard:get_stats()
print(string.format("数据项: %d, 锁定项: %d, 监听器: %d", 
    stats.total_keys, stats.locked_keys, stats.listeners_count))

-- 显示调试信息
blackboard:debug_info()

-- 导出数据
local exported_data = blackboard:export()

-- 导入数据
blackboard:import(exported_data)
```

### 性能优化

```lua
-- 设置合理的最大历史记录数
blackboard.max_history = 50  -- 减少内存使用

-- 及时清理不需要的监听器
blackboard:remove_listener("temp_key", temp_callback)

-- 使用批量操作减少函数调用
blackboard:set_multiple({
    key1 = value1,
    key2 = value2,
    key3 = value3
}, "batch_update")
```

## 最佳实践

### 1. 命名规范
- 使用有意义的键名
- 遵循一致的命名约定
- 添加数据来源标识

```lua
-- 好的命名
blackboard:set("player_health", 80, "combat_system")
blackboard:set("enemy_spawn_timer", 30, "spawn_manager")

-- 避免的命名
blackboard:set("a", 80, "test")
blackboard:set("temp", 30, "temp")
```

### 2. 数据组织
- 按功能模块组织数据
- 使用前缀区分不同类型的数据
- 及时清理临时数据

```lua
-- 按模块组织
blackboard:set("combat.player_health", 80, "combat")
blackboard:set("combat.enemy_count", 5, "combat")
blackboard:set("movement.target_position", {x=100, y=200}, "movement")
```

### 3. 错误处理
- 总是检查操作返回值
- 使用默认值避免nil错误
- 记录重要的数据变化

```lua
-- 安全的操作
local success = blackboard:set("important_data", value, "system")
if not success then
    log.error("无法设置重要数据")
end

local value = blackboard:get("optional_data", default_value)
```

### 4. 性能考虑
- 避免频繁的数据变化
- 合理使用监听器
- 定期清理历史记录

```lua
-- 批量更新而不是频繁更新
local updates = {}
for i = 1, 100 do
    updates["item_" .. i] = i
end
blackboard:set_multiple(updates, "batch_update")
```

## 常见问题

### Q: 黑板数据是全局的吗？
A: 黑板数据是实例级别的，每个黑板实例独立管理自己的数据。

### Q: 如何在不同行为树之间共享数据？
A: 使用同一个黑板实例，或者通过行为树管理器统一管理。

### Q: 监听器会影响性能吗？
A: 监听器会在数据变化时立即执行，建议避免在监听器中执行耗时操作。

### Q: 如何调试黑板数据？
A: 使用`debug_info()`方法查看详细信息，或使用`get_stats()`获取统计信息。

### Q: 黑板数据会持久化吗？
A: 黑板数据默认不持久化，但可以通过`export()`和`import()`方法实现数据保存和恢复。 