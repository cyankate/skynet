# 行为树装饰节点使用指南

## 概述

装饰节点是行为树中用于修改子节点行为的特殊节点。它们可以改变子节点的执行结果、添加条件检查、控制执行频率等，大大增强了行为树的表达能力。

## 装饰节点列表

### 1. Inverter (反转节点)
**功能**: 反转子节点的执行结果
- SUCCESS → FAILURE
- FAILURE → SUCCESS
- RUNNING → RUNNING

**使用场景**: 
- 当需要"非"逻辑时
- 将失败条件转换为成功条件

**示例**:
```lua
local tree = BT.Inverter.new("非战斗状态", 
    BT.Condition.new("检查战斗状态", function(context)
        return monster:is_in_combat()
    end))
```

### 2. Succeeder (成功节点)
**功能**: 无论子节点返回什么，总是返回成功
- SUCCESS → SUCCESS
- FAILURE → SUCCESS
- RUNNING → RUNNING

**使用场景**:
- 忽略子节点的失败结果
- 确保某个分支总是"成功"

**示例**:
```lua
local tree = BT.Succeeder.new("忽略失败", 
    BT.Action.new("尝试困难动作", function(context)
        -- 即使失败也会返回成功
        return BT.Status.FAILURE
    end))
```

### 3. Failer (失败节点)
**功能**: 无论子节点返回什么，总是返回失败
- SUCCESS → FAILURE
- FAILURE → FAILURE
- RUNNING → RUNNING

**使用场景**:
- 强制某个分支失败
- 调试时禁用某个行为

**示例**:
```lua
local tree = BT.Failer.new("禁用行为", 
    BT.Action.new("被禁用的动作", function(context)
        return BT.Status.SUCCESS
    end))
```

### 4. UntilFail (直到失败节点)
**功能**: 不断重复执行子节点，直到子节点失败
- SUCCESS → 继续执行
- FAILURE → 返回成功
- RUNNING → 继续执行

**使用场景**:
- 重复执行某个动作直到失败
- 持续巡逻直到遇到障碍

**示例**:
```lua
local tree = BT.UntilFail.new("持续巡逻", 
    BT.Action.new("巡逻动作", function(context)
        -- 会一直执行直到返回FAILURE
        return BT.Status.SUCCESS
    end))
```

### 5. UntilSuccess (直到成功节点)
**功能**: 不断重复执行子节点，直到子节点成功
- SUCCESS → 返回成功
- FAILURE → 继续执行
- RUNNING → 继续执行

**使用场景**:
- 重试机制
- 持续尝试直到成功

**示例**:
```lua
local tree = BT.UntilSuccess.new("重试连接", 
    BT.Action.new("连接服务器", function(context)
        -- 会一直尝试直到连接成功
        return BT.Status.FAILURE
    end))
```

### 6. Cooldown (冷却节点)
**功能**: 在子节点成功执行后，在一段时间内阻止其再次执行
- 冷却期间: 直接返回FAILURE
- 非冷却期间: 正常执行子节点

**使用场景**:
- 技能冷却
- 攻击间隔控制
- 防止过于频繁的动作

**示例**:
```lua
local tree = BT.Cooldown.new("技能冷却", 
    BT.Action.new("使用技能", function(context)
        return BT.Status.SUCCESS
    end), 5.0)  -- 5秒冷却
```

### 7. ConditionDecorator (条件装饰节点)
**功能**: 只有当条件满足时才执行子节点
- 条件满足: 执行子节点
- 条件不满足: 直接返回FAILURE

**使用场景**:
- 前置条件检查
- 资源检查
- 状态验证

**示例**:
```lua
local tree = BT.ConditionDecorator.new("有足够魔法值", 
    BT.Action.new("施法", function(context)
        return BT.Status.SUCCESS
    end), function(context)
        return monster.mp >= 50
    end)
```

### 8. TimeLimit (时间限制节点)
**功能**: 在指定时间内执行子节点，超时则失败
- 超时: 返回FAILURE
- 未超时: 正常执行子节点

**使用场景**:
- 超时控制
- 防止无限等待
- 紧急情况处理

**示例**:
```lua
local tree = BT.TimeLimit.new("超时控制", 
    BT.Action.new("等待响应", function(context)
        return BT.Status.RUNNING
    end), 10.0)  -- 10秒超时
```

### 9. Random (随机执行节点)
**功能**: 按概率执行子节点
- 概率命中: 执行子节点
- 概率未命中: 直接返回FAILURE

**使用场景**:
- 随机行为
- 概率触发
- 增加AI的不可预测性

**示例**:
```lua
local tree = BT.Random.new("随机行为", 
    BT.Action.new("随机动作", function(context)
        return BT.Status.SUCCESS
    end), 0.3)  -- 30%概率执行
```

### 10. Repeat (重复节点)
**功能**: 重复执行子节点指定次数
- 达到次数: 返回SUCCESS
- 未达到次数: 继续执行

**使用场景**:
- 固定次数重复
- 批量操作
- 训练动作

**示例**:
```lua
local tree = BT.Repeat.new("重复3次", 
    BT.Action.new("训练动作", function(context)
        return BT.Status.SUCCESS
    end), 3)  -- 重复3次
```

## 组合使用示例

### 复杂的AI行为
```lua
local complex_ai = BT.Selector.new("复杂AI")
    :add_child(BT.Sequence.new("战斗序列")
        :add_child(BT.Condition.new("发现敌人", function(context)
            return monster:find_enemy()
        end))
        :add_child(BT.Cooldown.new("攻击冷却", 
            BT.Action.new("攻击", function(context)
                return monster:attack()
            end), 2.0))
        :add_child(BT.Random.new("随机技能", 
            BT.Action.new("使用技能", function(context)
                return monster:use_skill()
            end), 0.4)))
    :add_child(BT.Sequence.new("巡逻序列")
        :add_child(BT.Inverter.new("非战斗状态", 
            BT.Condition.new("检查战斗", function(context)
                return monster:is_in_combat()
            end)))
        :add_child(BT.UntilFail.new("持续巡逻", 
            BT.Action.new("巡逻", function(context)
                return monster:patrol()
            end))))
```

## 最佳实践

1. **合理使用装饰节点**: 不要过度嵌套，保持行为树的可读性
2. **性能考虑**: 某些装饰节点（如Cooldown、TimeLimit）会保存状态，注意内存使用
3. **调试友好**: 为装饰节点提供有意义的名称，便于调试
4. **组合使用**: 合理组合多个装饰节点，实现复杂的AI行为
5. **测试验证**: 对复杂的装饰节点组合进行充分测试

## 注意事项

- 装饰节点会影响行为树的执行效率，特别是在复杂嵌套时
- 某些装饰节点（如Cooldown、TimeLimit）依赖于时间，需要确保时间获取的准确性
- 装饰节点的状态管理需要小心处理，避免内存泄漏
- 在热更新时，装饰节点的状态可能需要重置 