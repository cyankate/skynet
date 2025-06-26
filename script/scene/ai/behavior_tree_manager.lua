local class = require "utils.class"
local Blackboard = require "scene.ai.blackboard"
local log = require "log"

-- 行为树管理器
local BehaviorTreeManager = class("BehaviorTreeManager")

function BehaviorTreeManager:ctor()
    self.blackboard = Blackboard.new()
    self.trees = {}
    self.active_trees = {}
    self.tree_stats = {}
end

-- 注册行为树
function BehaviorTreeManager:register_tree(name, tree)
    if self.trees[name] then
        log.warning("BehaviorTreeManager: 行为树 %s 已存在，将被覆盖", name)
    end
    
    -- 为行为树设置黑板
    tree:set_blackboard(self.blackboard)
    
    self.trees[name] = tree
    self.tree_stats[name] = {
        runs = 0,
        successes = 0,
        failures = 0,
        last_run_time = 0
    }
    
    log.info("BehaviorTreeManager: 注册行为树 %s", name)
end

-- 获取行为树
function BehaviorTreeManager:get_tree(name)
    return self.trees[name]
end

-- 激活行为树
function BehaviorTreeManager:activate_tree(name, context)
    if not self.trees[name] then
        log.error("BehaviorTreeManager: 行为树 %s 不存在", name)
        return false
    end
    
    self.active_trees[name] = {
        tree = self.trees[name],
        context = context or {},
        start_time = os.time()
    }
    
    log.info("BehaviorTreeManager: 激活行为树 %s", name)
    return true
end

-- 停用行为树
function BehaviorTreeManager:deactivate_tree(name)
    if self.active_trees[name] then
        self.active_trees[name] = nil
        log.info("BehaviorTreeManager: 停用行为树 %s", name)
        return true
    end
    return false
end

-- 运行所有激活的行为树
function BehaviorTreeManager:update()
    local current_time = os.time()
    
    for name, active_tree in pairs(self.active_trees) do
        local tree = active_tree.tree
        local context = active_tree.context
        
        -- 更新统计信息
        self.tree_stats[name].runs = self.tree_stats[name].runs + 1
        self.tree_stats[name].last_run_time = current_time
        
        -- 运行行为树
        local start_time = skynet.now()
        local status = tree:run(context)
        local end_time = skynet.now()
        
        -- 记录结果
        if status == 1 then  -- SUCCESS
            self.tree_stats[name].successes = self.tree_stats[name].successes + 1
        elseif status == 2 then  -- FAILURE
            self.tree_stats[name].failures = self.tree_stats[name].failures + 1
        end
        
        -- 记录执行时间
        local execution_time = (end_time - start_time) / 100
        if execution_time > 0.1 then  -- 超过100ms的执行时间
            log.warning("BehaviorTreeManager: 行为树 %s 执行时间过长: %.3f秒", name, execution_time)
        end
    end
end

-- 获取黑板
function BehaviorTreeManager:get_blackboard()
    return self.blackboard
end

-- 设置黑板数据
function BehaviorTreeManager:set_data(key, value, source)
    return self.blackboard:set(key, value, source)
end

-- 获取黑板数据
function BehaviorTreeManager:get_data(key, default_value)
    return self.blackboard:get(key, default_value)
end

-- 添加数据监听器
function BehaviorTreeManager:add_listener(key, callback, context)
    return self.blackboard:add_listener(key, callback, context)
end

-- 移除数据监听器
function BehaviorTreeManager:remove_listener(key, callback)
    return self.blackboard:remove_listener(key, callback)
end

-- 获取行为树统计信息
function BehaviorTreeManager:get_tree_stats(name)
    if name then
        return self.tree_stats[name]
    else
        return self.tree_stats
    end
end

-- 获取激活的行为树列表
function BehaviorTreeManager:get_active_trees()
    local result = {}
    for name, active_tree in pairs(self.active_trees) do
        table.insert(result, {
            name = name,
            start_time = active_tree.start_time,
            duration = os.time() - active_tree.start_time
        })
    end
    return result
end

-- 清空所有行为树
function BehaviorTreeManager:clear()
    self.trees = {}
    self.active_trees = {}
    self.tree_stats = {}
    self.blackboard:clear()
    log.info("BehaviorTreeManager: 已清空所有行为树")
end

-- 导出状态
function BehaviorTreeManager:export()
    return {
        trees = self.trees,
        active_trees = self.active_trees,
        tree_stats = self.tree_stats,
        blackboard = self.blackboard:export()
    }
end

-- 导入状态
function BehaviorTreeManager:import(data)
    if data.trees then
        self.trees = data.trees
    end
    if data.active_trees then
        self.active_trees = data.active_trees
    end
    if data.tree_stats then
        self.tree_stats = data.tree_stats
    end
    if data.blackboard then
        self.blackboard:import(data.blackboard)
    end
    log.info("BehaviorTreeManager: 状态导入完成")
end

-- 调试信息
function BehaviorTreeManager:debug_info()
    log.info("BehaviorTreeManager 调试信息:")
    log.info("  注册的行为树: %d", table.getn(self.trees))
    log.info("  激活的行为树: %d", table.getn(self.active_trees))
    
    if next(self.active_trees) then
        log.info("  激活的行为树列表:")
        for name, active_tree in pairs(self.active_trees) do
            local duration = os.time() - active_tree.start_time
            log.info("    %s (运行时间: %d秒)", name, duration)
        end
    end
    
    -- 显示黑板信息
    self.blackboard:debug_info()
end

return BehaviorTreeManager 