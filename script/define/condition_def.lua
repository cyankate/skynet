local condition_def = {
    LEVEL = {
        REACH = "level.reach",
        BETWEEN = "level.between",
    },
    CHAPTER = {
        PASS = "chapter.pass",
        BARRIER_PASS = "barrier.pass",
        STAGE_PASS = "barrier.pass",
    },
    EQUIP = {
        QUALITY_COUNT = "equip.quality_count",
        QUALITY_GTE_COUNT = "equip.quality_gte_count",
        LEVEL_SUM = "equip.level_sum",
    },
}

local function num(v)
    return tonumber(v) or 0
end

condition_def.handlers = {
    get_value = {
        [condition_def.LEVEL.REACH] = function(ctn, data)
            return ctn:get_level()
        end,
        [condition_def.CHAPTER.PASS] = function(ctn, data)
            return ctn:is_chapter_passed(data.chapter_id)
        end,
        [condition_def.CHAPTER.BARRIER_PASS] = function(ctn, data)
            local barrier_id = data.barrier_id or data.stage_id
            return ctn:is_barrier_passed(barrier_id)
        end,
        [condition_def.EQUIP.QUALITY_COUNT] = function(ctn, data)
            return ctn:get_equip_quality_count(data.quality)
        end,
        [condition_def.EQUIP.QUALITY_GTE_COUNT] = function(ctn, data)
            return ctn:get_equip_quality_gte_count(data.min_quality)
        end,
        [condition_def.EQUIP.LEVEL_SUM] = function(ctn, data)
            return ctn:get_equip_level_count(data.level)
        end,
    },
    is_met = {
        [condition_def.LEVEL.REACH] = function(current_value, data)
            return num(current_value) >= num(data.target_level)
        end,
        [condition_def.CHAPTER.PASS] = function(current_value, data)
            return current_value == true
        end,
        [condition_def.CHAPTER.BARRIER_PASS] = function(current_value, data)
            return current_value == true
        end,
        [condition_def.EQUIP.QUALITY_COUNT] = function(current_value, data)
            return num(current_value) >= num(data.target_count)
        end,
        [condition_def.EQUIP.QUALITY_GTE_COUNT] = function(current_value, data)
            return num(current_value) >= num(data.target_count)
        end,
        [condition_def.EQUIP.LEVEL_SUM] = function(current_value, data)
            return num(current_value) >= num(data.target_sum)
        end,
    },
    update = {
        [condition_def.LEVEL.REACH] = function(ctn, value)
            ctn:set_level(value)
            return condition_def.LEVEL.REACH
        end,
        [condition_def.CHAPTER.PASS] = function(ctn, value)
            ctn:mark_chapter_passed(value)
            return condition_def.CHAPTER.PASS
        end,
        [condition_def.CHAPTER.BARRIER_PASS] = function(ctn, value)
            ctn:mark_barrier_passed(value)
            return condition_def.CHAPTER.BARRIER_PASS
        end,
    },
}

return condition_def
