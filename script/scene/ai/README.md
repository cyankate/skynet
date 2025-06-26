# 状态机系统架构说明

## 概述

本状态机系统为游戏中的各种实体（怪物、玩家、NPC）提供了统一的状态管理框架。系统支持状态常量定义、状态打断机制、优先级管理等功能。

## 核心特性

### 1. 状态常量定义

为了避免在代码中直接使用字符串，系统定义了统一的状态常量：

```lua
local STATE = {
    -- 基础状态
    IDLE = "idle",           -- 待机状态
    MOVING = "moving",       -- 移动状态
    ATTACKING = "attacking", -- 攻击状态
    
    -- 怪物特有状态
    PATROL = "patrol",       -- 巡逻状态
    CHASE = "chase",         -- 追击状态
    FLEE = "flee",          -- 逃跑状态
    
    -- 玩家特有状态
    TRADING = "trading",     -- 交易状态
    
    -- NPC特有状态
    DIALOG = "dialog",       -- 对话状态
    QUEST = "quest",         -- 任务状态
    SHOP = "shop",          -- 商店状态
}
```

### 2. 状态打断机制

系统支持灵活的状态打断机制：

#### 可打断性配置
```lua
-- 设置状态是否可被打断
state_machine:set_state_interruptible(STATE.IDLE, true)      -- 待机状态可被打断
state_machine:set_state_interruptible(STATE.FLEE, false)     -- 逃跑状态不可被打断
```

#### 优先级管理
```lua
-- 设置状态优先级（高优先级可以打断低优先级）
state_machine:set_priority_state(STATE.FLEE, 3)      -- 逃跑最高优先级
state_machine:set_priority_state(STATE.ATTACKING, 1) -- 攻击中等优先级
state_machine:set_priority_state(STATE.IDLE, 0)      -- 待机最低优先级
```

#### 强制切换
```lua
-- 强制切换状态（忽略打断限制）
state_machine:force_change_state(STATE.IDLE)
```

### 3. 多实体类型支持

系统为不同类型的实体提供了专门的状态机：

#### 怪物状态机
- **待机状态**: 检查是否需要巡逻或进入战斗
- **巡逻状态**: 在指定范围内随机移动
- **追击状态**: 追击敌人
- **攻击状态**: 执行攻击
- **逃跑状态**: 血量低时逃跑

#### 玩家状态机
- **待机状态**: 基础待机，可执行各种操作
- **移动状态**: 玩家移动
- **攻击状态**: 玩家攻击

#### NPC状态机
- **待机状态**: 检查玩家靠近，播放欢迎动画
- **对话状态**: 与玩家对话
- **任务状态**: 处理任务相关交互
- **商店状态**: 商店交易
- **巡逻状态**: NPC巡逻

## 架构设计

### 核心类层次

```
StateMachine (状态机基类)
├── State (状态基类)
├── IdleState (待机状态)
├── MoveState (移动状态)
├── CompositeState (复合状态)
├── ConditionalState (条件状态)
├── DelayState (延迟状态)
└── ActionState (动作状态)

MonsterStateMachine (怪物状态机)
├── IdleState (怪物待机)
├── PatrolState (巡逻)
├── ChaseState (追击)
├── AttackState (攻击)
└── FleeState (逃跑)

PlayerStateMachine (玩家状态机)
├── PlayerIdleState (玩家待机)
├── PlayerMoveState (移动)
└── PlayerAttackState (攻击)

NPCStateMachine (NPC状态机)
├── NPCIdleState (NPC待机)
├── NPCDialogState (对话)
├── NPCQuestState (任务)
├── NPCShopState (商店)
└── NPCPatrolState (巡逻)
```

### 状态生命周期

每个状态都有完整的生命周期管理：

```lua
function State:enter(context)
    -- 进入状态时的初始化
end

function State:update(context, dt)
    -- 状态更新逻辑
    return "running" | "success" | "failure"
end

function State:exit(context)
    -- 退出状态时的清理
end

function State:interrupt(context)
    -- 状态被中断时的处理
end
```

## 使用示例

### 创建怪物状态机

```lua
local MonsterStateMachine = require "scene.ai.monster_state_machine"

-- 创建状态机
local state_machine = MonsterStateMachine.create_monster_state_machine()

-- 启动状态机
state_machine:start({ entity = monster })

-- 更新状态机
state_machine:update(dt)

-- 切换状态
state_machine:change_state(StateMachine.STATE.CHASE)

-- 停止状态机
state_machine:stop()
```

### 自定义状态

```lua
local CustomState = class("CustomState", StateMachine.State)

function CustomState:ctor()
    StateMachine.State.ctor(self, "custom")
end

function CustomState:enter(context)
    local entity = context.entity
    entity:play_animation("custom_start")
end

function CustomState:update(context, dt)
    -- 自定义逻辑
    if some_condition then
        self.machine:change_state(StateMachine.STATE.IDLE)
        return "running"
    end
    return "running"
end

function CustomState:exit(context)
    local entity = context.entity
    entity:play_animation("custom_end")
end
```

### 配置状态打断

```lua
local state_machine = StateMachine.StateMachine.new("自定义状态机")

-- 添加状态
state_machine:add_state(CustomState.new())

-- 配置打断机制
state_machine:set_state_interruptible("custom", false)  -- 不可被打断
state_machine:set_priority_state("custom", 2)           -- 高优先级

-- 设置初始状态
state_machine:set_initial_state("custom")
```

## 状态打断规则

### 打断条件

1. **优先级规则**: 高优先级状态可以打断低优先级状态
2. **可打断性**: 当前状态必须允许被打断
3. **强制切换**: 使用 `force_change_state` 可以忽略所有限制

### 优先级示例

```lua
-- 怪物状态优先级（从高到低）
FLEE (3)      -- 逃跑：最高优先级，可以打断任何状态
ATTACKING (1) -- 攻击：中等优先级
CHASE (1)     -- 追击：中等优先级
PATROL (0)    -- 巡逻：低优先级
IDLE (0)      -- 待机：最低优先级
```

### 打断配置示例

```lua
-- 可被打断的状态
IDLE: true     -- 待机状态可被打断
PATROL: true   -- 巡逻状态可被打断
CHASE: true    -- 追击状态可被打断
ATTACKING: true -- 攻击状态可被打断

-- 不可被打断的状态
FLEE: false    -- 逃跑状态不可被打断
```

## 最佳实践

### 1. 状态设计原则

- **单一职责**: 每个状态只负责一个特定的行为
- **状态独立性**: 状态之间尽量减少依赖
- **清晰的转换条件**: 明确定义状态转换的条件

### 2. 性能优化

- **避免频繁切换**: 合理设置状态切换条件
- **缓存计算结果**: 在状态中缓存计算结果
- **批量更新**: 对于大量实体，考虑批量更新

### 3. 调试支持

- **状态日志**: 记录状态切换和重要事件
- **状态可视化**: 提供状态机的可视化工具
- **错误处理**: 完善的错误处理和恢复机制

## 扩展指南

### 添加新状态类型

1. 继承 `StateMachine.State` 基类
2. 实现必要的生命周期方法
3. 在状态机中注册新状态
4. 配置打断和优先级规则

### 添加新实体类型

1. 创建专门的状态机类
2. 定义该实体特有的状态
3. 配置状态转换逻辑
4. 实现实体相关的接口方法

### 自定义状态机行为

1. 继承 `StateMachine.StateMachine` 基类
2. 重写相关方法
3. 添加自定义功能
4. 保持与基类的兼容性

## 总结

本状态机系统提供了：

- **统一的状态管理**: 所有实体使用相同的状态机框架
- **灵活的状态打断**: 支持优先级和可打断性配置
- **类型安全**: 使用状态常量避免字符串错误
- **易于扩展**: 模块化设计便于添加新功能
- **性能优化**: 高效的状态切换和更新机制

通过合理使用状态机系统，可以大大简化游戏AI的开发和维护工作。 