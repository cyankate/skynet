local class = require "utils.class"

-- 行为树节点状态
local BTStatus = {
    SUCCESS = 1,    -- 执行成功
    FAILURE = 2,    -- 执行失败
    RUNNING = 3     -- 正在执行
}

-- 基础节点类
local BTNode = class("BTNode")

function BTNode:ctor(name)
    self.name = name
    self.status = BTStatus.SUCCESS
end

function BTNode:run(context)
    return BTStatus.SUCCESS
end

-- 复合节点基类
local BTComposite = class("BTComposite", BTNode)

function BTComposite:ctor(name)
    BTNode.ctor(self, name)
    self.children = {}
end

function BTComposite:add_child(child)
    table.insert(self.children, child)
    return self
end

-- 顺序节点：依次执行子节点，直到一个失败或全部成功
local BTSequence = class("BTSequence", BTComposite)

function BTSequence:run(context)
    for _, child in ipairs(self.children) do
        local status = child:run(context)
        if status ~= BTStatus.SUCCESS then
            self.status = status
            return status
        end
    end
    self.status = BTStatus.SUCCESS
    return BTStatus.SUCCESS
end

-- 选择节点：依次执行子节点，直到一个成功或全部失败
local BTSelector = class("BTSelector", BTComposite)

function BTSelector:run(context)
    for _, child in ipairs(self.children) do
        local status = child:run(context)
        if status ~= BTStatus.FAILURE then
            self.status = status
            return status
        end
    end
    self.status = BTStatus.FAILURE
    return BTStatus.FAILURE
end

-- 并行节点：同时执行所有子节点
local BTParallel = class("BTParallel", BTComposite)

function BTParallel:ctor(name, success_policy, failure_policy)
    BTComposite.ctor(self, name)
    -- success_policy: 需要多少个子节点成功才算成功
    -- failure_policy: 需要多少个子节点失败才算失败
    self.success_policy = success_policy or #self.children
    self.failure_policy = failure_policy or 1
end

function BTParallel:run(context)
    local success_count = 0
    local failure_count = 0
    
    for _, child in ipairs(self.children) do
        local status = child:run(context)
        if status == BTStatus.SUCCESS then
            success_count = success_count + 1
        elseif status == BTStatus.FAILURE then
            failure_count = failure_count + 1
        end
    end
    
    if failure_count >= self.failure_policy then
        self.status = BTStatus.FAILURE
        return BTStatus.FAILURE
    end
    
    if success_count >= self.success_policy then
        self.status = BTStatus.SUCCESS
        return BTStatus.SUCCESS
    end
    
    self.status = BTStatus.RUNNING
    return BTStatus.RUNNING
end

-- 装饰节点：修改子节点的行为
local BTDecorator = class("BTDecorator", BTNode)

function BTDecorator:ctor(name, child)
    BTNode.ctor(self, name)
    self.child = child
end

-- 重复节点：重复执行子节点指定次数
local BTRepeat = class("BTRepeat", BTDecorator)

function BTRepeat:ctor(name, child, count)
    BTDecorator.ctor(self, name, child)
    self.count = count
    self.current = 0
end

function BTRepeat:run(context)
    if self.current >= self.count then
        self.current = 0
        self.status = BTStatus.SUCCESS
        return BTStatus.SUCCESS
    end
    
    local status = self.child:run(context)
    if status == BTStatus.SUCCESS then
        self.current = self.current + 1
        if self.current >= self.count then
            self.status = BTStatus.SUCCESS
            return BTStatus.SUCCESS
        end
        self.status = BTStatus.RUNNING
        return BTStatus.RUNNING
    end
    
    self.status = status
    return status
end

-- 条件节点：检查条件是否满足
local BTCondition = class("BTCondition", BTNode)

function BTCondition:ctor(name, condition_func)
    BTNode.ctor(self, name)
    self.condition_func = condition_func
end

function BTCondition:run(context)
    if self.condition_func(context) then
        self.status = BTStatus.SUCCESS
        return BTStatus.SUCCESS
    end
    self.status = BTStatus.FAILURE
    return BTStatus.FAILURE
end

-- 动作节点：执行具体动作
local BTAction = class("BTAction", BTNode)

function BTAction:ctor(name, action_func)
    BTNode.ctor(self, name)
    self.action_func = action_func
end

function BTAction:run(context)
    self.status = self.action_func(context)
    return self.status
end

return {
    Status = BTStatus,
    Node = BTNode,
    Composite = BTComposite,    -- 复合节点
    Sequence = BTSequence,      -- 顺序节点
    Selector = BTSelector,      -- 选择节点
    Parallel = BTParallel,      -- 并行节点
    Decorator = BTDecorator,    -- 装饰节点
    Repeat = BTRepeat,          -- 重复节点
    Condition = BTCondition,    -- 条件节点
    Action = BTAction           -- 动作节点
} 