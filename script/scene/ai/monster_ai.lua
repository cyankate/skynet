local BT = require "scene.ai.behavior_tree"
local log = require "log"

local MonsterAI = {}

-- 创建巡逻行为树
function MonsterAI.create_patrol_tree(monster)
    local bt = BT.Selector.new("巡逻选择器")
    
    -- 1. 检查是否需要返回出生点
    local check_return_spawn = BT.Sequence.new("返回出生点序列")
        :add_child(BT.Condition.new("检查是否远离出生点", function(context)
            local dx = monster.x - monster.spawn_x
            local dy = monster.y - monster.spawn_y
            local distance = math.sqrt(dx * dx + dy * dy)
            return distance > monster.patrol_radius
        end))
        :add_child(BT.Action.new("移动到出生点", function(context)
            local path = monster.scene:find_path(monster.x, monster.y, monster.spawn_x, monster.spawn_y)
            if not path then
                return BT.Status.FAILURE
            end
            monster:move_along_path(path)
            return BT.Status.SUCCESS
        end))
    
    -- 2. 检查是否发现目标
    local check_target = BT.Sequence.new("发现目标序列")
        :add_child(BT.Condition.new("搜索目标", function(context)
            local target = monster:find_nearest_target()
            if target then
                context.target = target
                return true
            end
            return false
        end))
        :add_child(BT.Action.new("追击目标", function(context)
            local target = context.target
            local path = monster.scene:find_path(monster.x, monster.y, target.x, target.y)
            if not path then
                return BT.Status.FAILURE
            end
            monster:move_along_path(path)
            return BT.Status.SUCCESS
        end))
    
    -- 3. 随机巡逻
    local random_patrol = BT.Sequence.new("随机巡逻序列")
        :add_child(BT.Condition.new("检查是否需要新的巡逻点", function(context)
            if not context.patrol_target or monster:is_reached_target(context.patrol_target) then
                -- 生成新的巡逻点
                local angle = math.random() * math.pi * 2
                local distance = math.random() * monster.patrol_radius
                context.patrol_target = {
                    x = monster.spawn_x + math.cos(angle) * distance,
                    y = monster.spawn_y + math.sin(angle) * distance
                }
                return true
            end
            return false
        end))
        :add_child(BT.Action.new("移动到巡逻点", function(context)
            local target = context.patrol_target
            local path = monster.scene:find_path(monster.x, monster.y, target.x, target.y)
            if not path then
                return BT.Status.FAILURE
            end
            monster:move_along_path(path)
            return BT.Status.SUCCESS
        end))
    
    -- 添加到选择器
    bt:add_child(check_return_spawn)
    bt:add_child(check_target)
    bt:add_child(random_patrol)
    
    return bt
end

-- 创建战斗行为树
function MonsterAI.create_combat_tree(monster)
    local bt = BT.Selector.new("战斗选择器")
    
    -- 1. 检查是否需要逃跑
    local check_flee = BT.Sequence.new("逃跑序列")
        :add_child(BT.Condition.new("检查生命值", function(context)
            return monster.hp < monster.max_hp * 0.2  -- 生命值低于20%时逃跑
        end))
        :add_child(BT.Action.new("逃离目标", function(context)
            local target = monster:get_combat_target()
            if not target then
                return BT.Status.SUCCESS
            end
            
            -- 计算逃跑方向
            local dx = monster.x - target.x
            local dy = monster.y - target.y
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance < 0.1 then
                dx, dy = 1, 0
            else
                dx, dy = dx / distance, dy / distance
            end
            
            -- 找到逃跑目标点
            local flee_x = monster.x + dx * monster.patrol_radius
            local flee_y = monster.y + dy * monster.patrol_radius
            
            local path = monster.scene:find_path(monster.x, monster.y, flee_x, flee_y)
            if not path then
                return BT.Status.FAILURE
            end
            
            monster:move_along_path(path)
            return BT.Status.SUCCESS
        end))
    
    -- 2. 检查是否可以使用技能
    local check_skill = BT.Sequence.new("技能序列")
        :add_child(BT.Condition.new("检查技能冷却", function(context)
            return monster:can_use_skill()
        end))
        :add_child(BT.Action.new("使用技能", function(context)
            local target = monster:get_combat_target()
            if not target then
                return BT.Status.FAILURE
            end
            
            return monster:use_skill(target)
        end))
    
    -- 3. 普通攻击
    local normal_attack = BT.Sequence.new("普通攻击序列")
        :add_child(BT.Condition.new("检查攻击范围", function(context)
            local target = monster:get_combat_target()
            if not target then
                return false
            end
            
            local dx = target.x - monster.x
            local dy = target.y - monster.y
            local distance = math.sqrt(dx * dx + dy * dy)
            
            return distance <= monster.attack_range
        end))
        :add_child(BT.Action.new("执行攻击", function(context)
            local target = monster:get_combat_target()
            if not target then
                return BT.Status.FAILURE
            end
            
            return monster:attack(target)
        end))
    
    -- 4. 追击目标
    local chase_target = BT.Sequence.new("追击序列")
        :add_child(BT.Condition.new("检查目标", function(context)
            local target = monster:get_combat_target()
            return target ~= nil
        end))
        :add_child(BT.Action.new("移动到目标", function(context)
            local target = monster:get_combat_target()
            if not target then
                return BT.Status.FAILURE
            end
            
            local path = monster.scene:find_path(monster.x, monster.y, target.x, target.y)
            if not path then
                return BT.Status.FAILURE
            end
            
            monster:move_along_path(path)
            return BT.Status.SUCCESS
        end))
    
    -- 添加到选择器
    bt:add_child(check_flee)
    bt:add_child(check_skill)
    bt:add_child(normal_attack)
    bt:add_child(chase_target)
    
    return bt
end

-- 创建完整的怪物行为树
function MonsterAI.create_monster_tree(monster)
    local bt = BT.Selector.new("怪物主选择器")
    
    -- 1. 战斗行为
    local combat_sequence = BT.Sequence.new("战斗序列")
        :add_child(BT.Condition.new("检查战斗状态", function(context)
            return monster:is_in_combat()
        end))
        :add_child(MonsterAI.create_combat_tree(monster))
    
    -- 2. 巡逻行为
    local patrol_sequence = BT.Sequence.new("巡逻序列")
        :add_child(BT.Condition.new("检查非战斗状态", function(context)
            return not monster:is_in_combat()
        end))
        :add_child(MonsterAI.create_patrol_tree(monster))
    
    -- 添加到主选择器
    bt:add_child(combat_sequence)
    bt:add_child(patrol_sequence)
    
    return bt
end

return MonsterAI 