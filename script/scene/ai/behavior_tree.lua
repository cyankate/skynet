local class = require "utils.class"

-- 行为树节点状态
local BTStatus = {
    SUCCESS = 1,    -- 执行成功
    FAILURE = 2,    -- 执行失败
    RUNNING = 3     -- 正在执行
}

local STATUS_NAME = {
    [BTStatus.SUCCESS] = "success",
    [BTStatus.FAILURE] = "failure",
    [BTStatus.RUNNING] = "running"
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

function BTSequence:ctor(name)
    BTComposite.ctor(self, name)
    self.running_child_index = nil
end

function BTSequence:run(context)
    local start_index = self.running_child_index or 1
    for i = start_index, #self.children do
        local child = self.children[i]
        local status = child:run(context)
        if context.log and context.entity.id == 2001 then
            log.info("BTSequence: 当前节点: %s, 子节点: %s, 返回状态: %s", self.name, child.name, STATUS_NAME[status])
        end
        if status == BTStatus.FAILURE then
            self.running_child_index = nil -- 遇到失败，重置状态
            self.status = BTStatus.FAILURE
            return BTStatus.FAILURE
        elseif status == BTStatus.RUNNING then
            self.running_child_index = i -- 记住正在运行的子节点
            self.status = BTStatus.RUNNING
            return BTStatus.RUNNING
        end
        -- 如果是 SUCCESS，则继续下一个
    end
    
    self.running_child_index = nil -- 所有子节点都成功了，重置状态
    self.status = BTStatus.SUCCESS
    return BTStatus.SUCCESS
end

-- 选择节点：依次执行子节点，直到一个成功或全部失败
local BTSelector = class("BTSelector", BTComposite)

function BTSelector:ctor(name)
    BTComposite.ctor(self, name)
    self.running_child_index = nil
end

function BTSelector:run(context)
    -- 总是从第一个子节点开始检查，确保高优先级节点有机会执行
    for i = 1, #self.children do
        local child = self.children[i]
        local status = child:run(context)
        if context.log and context.entity.id == 2001 then
            log.info("BTSelector: 当前节点: %s, 子节点: %s, 返回状态: %s", self.name, child.name, STATUS_NAME[status])
        end
        if status == BTStatus.SUCCESS then
            -- 如果当前节点不是之前运行的节点，说明发生了中断
            if self.running_child_index and self.running_child_index ~= i then
                -- 通知之前运行的节点被中断
                local previous_child = self.children[self.running_child_index]
                if previous_child.on_interrupt then
                    previous_child:on_interrupt(context)
                end
            end
            
            self.running_child_index = nil -- 遇到成功，重置状态
            self.status = BTStatus.SUCCESS
            return BTStatus.SUCCESS
        elseif status == BTStatus.RUNNING then
            -- 如果当前节点不是之前运行的节点，说明发生了中断
            if self.running_child_index and self.running_child_index ~= i then
                -- 通知之前运行的节点被中断
                local previous_child = self.children[self.running_child_index]
                if previous_child.on_interrupt then
                    previous_child:on_interrupt(context)
                end
            end
            
            self.running_child_index = i -- 记住正在运行的子节点
            self.status = BTStatus.RUNNING
            return BTStatus.RUNNING
        end
        -- 如果是 FAILURE，则继续下一个
    end
    
    self.running_child_index = nil -- 所有子节点都失败了，重置状态
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
        if context.log and context.entity.id == 2001 then
            log.info("BTParallel: 当前节点: %s, 子节点: %s, 返回状态: %s", self.name, child.name, STATUS_NAME[status])
        end
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
    if context.log and context.entity.id == 2001 then
        log.info("BTRepeat: 当前节点: %s, 子节点: %s, 返回状态: %s", self.name, self.child.name, STATUS_NAME[status])
    end
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

-- 反转节点：反转子节点的执行结果
local BTInverter = class("BTInverter", BTDecorator)

function BTInverter:ctor(name, child)
    BTDecorator.ctor(self, name, child)
end

function BTInverter:run(context)
    local status = self.child:run(context)
    if context.log and context.entity.id == 2001 then
        log.info("BTInverter: 当前节点: %s, 子节点: %s, 返回状态: %s", self.name, self.child.name, STATUS_NAME[status])
    end
    if status == BTStatus.SUCCESS then
        self.status = BTStatus.FAILURE
        return BTStatus.FAILURE
    elseif status == BTStatus.FAILURE then
        self.status = BTStatus.SUCCESS
        return BTStatus.SUCCESS
    else
        self.status = BTStatus.RUNNING
        return BTStatus.RUNNING
    end
end

-- 成功节点：无论子节点返回什么，总是返回成功
local BTSucceeder = class("BTSucceeder", BTDecorator)

function BTSucceeder:ctor(name, child)
    BTDecorator.ctor(self, name, child)
end

function BTSucceeder:run(context)
    local status = self.child:run(context)
    if context.log and context.entity.id == 2001 then
        log.info("BTSucceeder: 当前节点: %s, 子节点: %s, 返回状态: %s", self.name, self.child.name, STATUS_NAME[status])
    end
    if status == BTStatus.RUNNING then
        self.status = BTStatus.RUNNING
        return BTStatus.RUNNING
    else
        self.status = BTStatus.SUCCESS
        return BTStatus.SUCCESS
    end
end

-- 失败节点：无论子节点返回什么，总是返回失败
local BTFailer = class("BTFailer", BTDecorator)

function BTFailer:ctor(name, child)
    BTDecorator.ctor(self, name, child)
end

function BTFailer:run(context)
    local status = self.child:run(context)
    if context.log and context.entity.id == 2001 then
        log.info("BTFailer: 当前节点: %s, 子节点: %s, 返回状态: %s", self.name, self.child.name, STATUS_NAME[status])
    end
    if status == BTStatus.RUNNING then
        self.status = BTStatus.RUNNING
        return BTStatus.RUNNING
    else
        self.status = BTStatus.FAILURE
        return BTStatus.FAILURE
    end
end

-- 直到失败节点：不断重复执行子节点，直到子节点失败
local BTUntilFail = class("BTUntilFail", BTDecorator)

function BTUntilFail:ctor(name, child)
    BTDecorator.ctor(self, name, child)
end

function BTUntilFail:run(context)
    local status = self.child:run(context)
    if context.log and context.entity.id == 2001 then
        log.info("BTUntilFail: 当前节点: %s, 子节点: %s, 返回状态: %s", self.name, self.child.name, STATUS_NAME[status])
    end
    if status == BTStatus.FAILURE then
        self.status = BTStatus.SUCCESS
        return BTStatus.SUCCESS
    else
        self.status = BTStatus.RUNNING
        return BTStatus.RUNNING
    end
end

-- 直到成功节点：不断重复执行子节点，直到子节点成功
local BTUntilSuccess = class("BTUntilSuccess", BTDecorator)

function BTUntilSuccess:ctor(name, child)
    BTDecorator.ctor(self, name, child)
end

function BTUntilSuccess:run(context)
    local status = self.child:run(context)
    if context.log and context.entity.id == 2001 then
        log.info("BTUntilSuccess: 当前节点: %s, 子节点: %s, 返回状态: %s", self.name, self.child.name, STATUS_NAME[status])
    end
    if status == BTStatus.SUCCESS then
        self.status = BTStatus.SUCCESS
        return BTStatus.SUCCESS
    else
        self.status = BTStatus.RUNNING
        return BTStatus.RUNNING
    end
end

-- 冷却节点：在子节点成功执行后，在一段时间内阻止其再次执行
local BTCooldown = class("BTCooldown", BTDecorator)

function BTCooldown:ctor(name, child, cooldown_time)
    BTDecorator.ctor(self, name, child)
    self.cooldown_time = cooldown_time or 1.0
    self.last_success_time = 0
end

function BTCooldown:run(context)
    local current_time = skynet.now() / 100  -- 转换为秒
    
    -- 检查是否在冷却中
    if current_time - self.last_success_time < self.cooldown_time then
        self.status = BTStatus.FAILURE
        return BTStatus.FAILURE
    end
    
    local status = self.child:run(context)
    if context.log and context.entity.id == 2001 then
        log.info("BTCooldown: 当前节点: %s, 子节点: %s, 返回状态: %s", self.name, self.child.name, STATUS_NAME[status])
    end
    if status == BTStatus.SUCCESS then
        self.last_success_time = current_time
    end
    
    self.status = status
    return status
end

-- 条件装饰节点：只有当条件满足时才执行子节点
local BTConditionDecorator = class("BTConditionDecorator", BTDecorator)

function BTConditionDecorator:ctor(name, child, condition_func)
    BTDecorator.ctor(self, name, child)
    self.condition_func = condition_func
end

function BTConditionDecorator:run(context)
    if not self.condition_func(context) then
        self.status = BTStatus.FAILURE
        return BTStatus.FAILURE
    end
    
    local status = self.child:run(context)
    if context.log and context.entity.id == 2001 then
        log.info("BTConditionDecorator: 当前节点: %s, 子节点: %s, 返回状态: %s", self.name, self.child.name, STATUS_NAME[status])
    end
    self.status = status
    return status
end

-- 时间限制节点：在指定时间内执行子节点，超时则失败
local BTTimeLimit = class("BTTimeLimit", BTDecorator)

function BTTimeLimit:ctor(name, child, time_limit)
    BTDecorator.ctor(self, name, child)
    self.time_limit = time_limit or 5.0
    self.start_time = nil
end

function BTTimeLimit:run(context)
    local current_time = skynet.now() / 100
    
    if not self.start_time then
        self.start_time = current_time
    end
    
    -- 检查是否超时
    if current_time - self.start_time > self.time_limit then
        self.status = BTStatus.FAILURE
        return BTStatus.FAILURE
    end
    
    local status = self.child:run(context)
    if context.log and context.entity.id == 2001 then
        log.info("BTTimeLimit: 当前节点: %s, 子节点: %s, 返回状态: %s", self.name, self.child.name, STATUS_NAME[status])
    end
    -- 如果子节点完成，重置开始时间
    if status ~= BTStatus.RUNNING then
        self.start_time = nil
    end
    
    self.status = status
    return status
end

-- 随机执行节点：按概率执行子节点
local BTRandom = class("BTRandom", BTDecorator)

function BTRandom:ctor(name, child, probability)
    BTDecorator.ctor(self, name, child)
    self.probability = probability or 0.5  -- 默认50%概率
end

function BTRandom:run(context)
    if math.random() > self.probability then
        self.status = BTStatus.FAILURE
        return BTStatus.FAILURE
    end
    
    local status = self.child:run(context)
    if context.log and context.entity.id == 2001 then
        log.info("BTRandom: 当前节点: %s, 子节点: %s, 返回状态: %s", self.name, self.child.name, STATUS_NAME[status])
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
    self.is_interrupted = false
end

function BTAction:run(context)
    -- 如果被中断，重置中断标志
    if self.is_interrupted then
        self.is_interrupted = false
    end
    
    self.status = self.action_func(context)
    -- if context.log and context.entity.id == 2001 then
    --     log.info("BTAction: 当前节点: %s, 返回状态: %s", self.name, STATUS_NAME[self.status])
    -- end
    return self.status
end

-- 中断处理
function BTAction:on_interrupt(context)
    self.is_interrupted = true
    -- 设置context中的中断标志，让动作函数能够感知到中断
    if context then
        context.is_interrupted = true
    end
    -- 可以在这里添加中断时的清理逻辑
    -- 比如停止移动、取消技能等
end

-- 状态机动作节点：用于处理复杂的过程行为
local BTStateMachineAction = class("BTStateMachineAction", BTNode)

function BTStateMachineAction:ctor(name, state_machine)
    BTNode.ctor(self, name)
    self.state_machine = state_machine
    self.is_interrupted = false
end

function BTStateMachineAction:run(context)
    -- 检查是否被中断
    if self.is_interrupted then
        self.state_machine:stop()
        self.is_interrupted = false
        return BTStatus.FAILURE
    end
    
    -- 更新状态机
    local status = self.state_machine:update(context)
    
    if status == "success" then
        self.status = BTStatus.SUCCESS
        return BTStatus.SUCCESS
    elseif status == "failure" then
        self.status = BTStatus.FAILURE
        return BTStatus.FAILURE
    else
        self.status = BTStatus.RUNNING
        return BTStatus.RUNNING
    end
end

function BTStateMachineAction:on_interrupt(context)
    self.is_interrupted = true
    if context then
        context.is_interrupted = true
    end
    -- 通知状态机被中断
    if self.state_machine then
        self.state_machine:interrupt()
    end
end

-- 异步动作节点：用于处理需要等待外部事件的动作
local BTAsyncAction = class("BTAsyncAction", BTNode)

function BTAsyncAction:ctor(name, start_func, check_func, cleanup_func)
    BTNode.ctor(self, name)
    self.start_func = start_func      -- 开始执行的函数
    self.check_func = check_func      -- 检查完成状态的函数
    self.cleanup_func = cleanup_func  -- 清理函数
    self.is_started = false
    self.is_interrupted = false
end

function BTAsyncAction:run(context)
    -- 检查是否被中断
    if self.is_interrupted then
        if self.cleanup_func then
            self.cleanup_func(context)
        end
        self.is_interrupted = false
        self.is_started = false
        return BTStatus.FAILURE
    end
    
    -- 如果还没开始，先启动
    if not self.is_started then
        if self.start_func then
            self.start_func(context)
        end
        self.is_started = true
        return BTStatus.RUNNING
    end
    
    -- 检查是否完成
    if self.check_func then
        local status = self.check_func(context)
        if status == "success" then
            self.is_started = false
            self.status = BTStatus.SUCCESS
            return BTStatus.SUCCESS
        elseif status == "failure" then
            self.is_started = false
            self.status = BTStatus.FAILURE
            return BTStatus.FAILURE
        end
    end
    
    self.status = BTStatus.RUNNING
    return BTStatus.RUNNING
end

function BTAsyncAction:on_interrupt(context)
    self.is_interrupted = true
    if context then
        context.is_interrupted = true
    end
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
    Inverter = BTInverter,      -- 反转节点
    Succeeder = BTSucceeder,    -- 成功节点
    Failer = BTFailer,          -- 失败节点
    UntilFail = BTUntilFail,    -- 直到失败节点
    UntilSuccess = BTUntilSuccess, -- 直到成功节点
    Cooldown = BTCooldown,      -- 冷却节点
    ConditionDecorator = BTConditionDecorator, -- 条件装饰节点
    TimeLimit = BTTimeLimit,    -- 时间限制节点
    Random = BTRandom,          -- 随机执行节点
    Condition = BTCondition,    -- 条件节点
    Action = BTAction,          -- 动作节点
    StateMachineAction = BTStateMachineAction, -- 状态机动作节点
    AsyncAction = BTAsyncAction  -- 异步动作节点
} 