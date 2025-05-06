-- 条件定义
local condition_def = {
    -- 等级相关
    LEVEL = {
        REACH = "level.reach",           -- 达到指定等级
        BETWEEN = "level.between",       -- 等级区间
    },
    
    -- 关卡相关
    CHAPTER = {
        PASS = "chapter.pass",           -- 通关指定章节
        STAGE_PASS = "stage.pass",       -- 通关指定关卡
    },
    
    -- 装备相关
    EQUIP = {
        QUALITY_COUNT = "equip.quality_count",  -- 指定品质装备数量
        LEVEL_SUM = "equip.level_sum",          -- 装备等级总和
    },
}

-- 条件处理器映射表
condition_def.handlers = {
    -- 获取条件值处理器
    get_value = {
        [condition_def.LEVEL.REACH] = function(self, data)
            return self.conditions.level
        end,
        [condition_def.CHAPTER.PASS] = function(self, data)
            return self.conditions.chapters[data.chapter_id] or false
        end,
        [condition_def.STAGE_PASS] = function(self, data)
            return self.conditions.stages[data.stage_id] or false
        end,
        [condition_def.EQUIP.QUALITY_COUNT] = function(self, data)
            return self.conditions.equip_quality[data.quality] or 0
        end,
        [condition_def.EQUIP.LEVEL_SUM] = function(self, data)
            return self.conditions.equip_level[data.level] or 0
        end,
    },
    
    -- 判断条件是否满足处理器
    is_met = {
        [condition_def.LEVEL.REACH] = function(current_value, data)
            return current_value >= data.target_level
        end,
        [condition_def.CHAPTER.PASS] = function(current_value, data)
            return current_value == true
        end,
        [condition_def.STAGE_PASS] = function(current_value, data)
            return current_value == true
        end,
        [condition_def.EQUIP.QUALITY_COUNT] = function(current_value, data)
            return current_value >= data.target_count
        end,
        [condition_def.EQUIP.LEVEL_SUM] = function(current_value, data)
            return current_value >= data.target_sum
        end,
    },
    
    -- 更新条件值处理器
    update = {
        [condition_def.LEVEL.REACH] = function(self, value)
            self.conditions.level = value
            return condition_def.LEVEL.REACH
        end,
        [condition_def.CHAPTER.PASS] = function(self, value)
            self.conditions.chapters[value] = true
            return condition_def.CHAPTER.PASS
        end,
        [condition_def.STAGE_PASS] = function(self, value)
            self.conditions.stages[value] = true
            return condition_def.STAGE_PASS
        end,
    },
}

return condition_def