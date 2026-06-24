local CtnKv = require "ctn.ctn_kv"
local class = require "utils.class"
local log = require "log"
local condition_def = require "define.condition_def"

local LEVEL_KEY = "level"
local CHAPTERS_KEY = "chapters"
local BARRIERS_KEY = "barriers"
local EQUIP_QUALITY_KEY = "equip_quality"
local EQUIP_LEVEL_KEY = "equip_level"

local CtnCondition = class("CtnCondition", CtnKv)

function CtnCondition:ctor(_player_id, _tbl, _name)
    CtnKv.ctor(self, _player_id, _tbl, _name)
    self.subscribers_ = {}
    self.listener_seq_ = 0
end

function CtnCondition:onload(data)
    CtnKv.onload(self, data)
    self:ensure_defaults()
end

function CtnCondition:ensure_defaults()
    if self:get(LEVEL_KEY) == nil then
        self:set(LEVEL_KEY, 1)
    end
    if type(self:get(CHAPTERS_KEY)) ~= "table" then
        self:set(CHAPTERS_KEY, {})
    end
    if type(self:get(BARRIERS_KEY)) ~= "table" then
        self:set(BARRIERS_KEY, {})
    end
    if type(self:get(EQUIP_QUALITY_KEY)) ~= "table" then
        self:set(EQUIP_QUALITY_KEY, {})
    end
    if type(self:get(EQUIP_LEVEL_KEY)) ~= "table" then
        self:set(EQUIP_LEVEL_KEY, {})
    end
end

function CtnCondition:init_player()
    self:set(LEVEL_KEY, 1)
    self:set(CHAPTERS_KEY, {})
    self:set(BARRIERS_KEY, {})
    self:set(EQUIP_QUALITY_KEY, {})
    self:set(EQUIP_LEVEL_KEY, {})
end

function CtnCondition:get_level()
    return tonumber(self:get(LEVEL_KEY)) or 1
end

function CtnCondition:set_level(level, notify)
    level = tonumber(level) or 1
    if level == self:get_level() then
        return
    end
    self:set(LEVEL_KEY, level)
    if notify ~= false then
        self:check_all_conditions(condition_def.LEVEL.REACH)
    end
end

function CtnCondition:is_chapter_passed(chapter_id)
    chapter_id = tonumber(chapter_id)
    if not chapter_id then
        return false
    end
    local chapters = self:get(CHAPTERS_KEY) or {}
    return chapters[chapter_id] == true
end

function CtnCondition:mark_chapter_passed(chapter_id, notify)
    chapter_id = tonumber(chapter_id)
    if not chapter_id or self:is_chapter_passed(chapter_id) then
        return
    end
    local chapters = self:get(CHAPTERS_KEY) or {}
    chapters[chapter_id] = true
    self:set(CHAPTERS_KEY, chapters)
    if notify ~= false then
        self:check_all_conditions(condition_def.CHAPTER.PASS)
    end
end

function CtnCondition:is_barrier_passed(barrier_id)
    barrier_id = tonumber(barrier_id)
    if not barrier_id then
        return false
    end
    local barriers = self:get(BARRIERS_KEY) or {}
    return barriers[barrier_id] == true
end

function CtnCondition:mark_barrier_passed(barrier_id, notify)
    barrier_id = tonumber(barrier_id)
    if not barrier_id or self:is_barrier_passed(barrier_id) then
        return
    end
    local barriers = self:get(BARRIERS_KEY) or {}
    barriers[barrier_id] = true
    self:set(BARRIERS_KEY, barriers)
    if notify ~= false then
        self:check_all_conditions(condition_def.CHAPTER.BARRIER_PASS)
    end
end

function CtnCondition:get_equip_quality_count(quality)
    quality = tonumber(quality)
    if not quality then
        return 0
    end
    local stats = self:get(EQUIP_QUALITY_KEY) or {}
    return tonumber(stats[quality]) or 0
end

function CtnCondition:get_equip_quality_gte_count(min_quality)
    min_quality = tonumber(min_quality) or 0
    local stats = self:get(EQUIP_QUALITY_KEY) or {}
    local total = 0
    for quality, count in pairs(stats) do
        if tonumber(quality) >= min_quality then
            total = total + (tonumber(count) or 0)
        end
    end
    return total
end

function CtnCondition:get_equip_level_count(level)
    level = tonumber(level)
    if not level then
        return 0
    end
    local stats = self:get(EQUIP_LEVEL_KEY) or {}
    return tonumber(stats[level]) or 0
end

function CtnCondition:update_equip_condition(quality, level)
    quality = tonumber(quality)
    level = tonumber(level)
    if not quality or not level then
        log.error("Invalid parameters for update_equip_condition")
        return
    end

    local quality_stats = self:get(EQUIP_QUALITY_KEY) or {}
    quality_stats[quality] = (tonumber(quality_stats[quality]) or 0) + 1
    self:set(EQUIP_QUALITY_KEY, quality_stats)

    local level_stats = self:get(EQUIP_LEVEL_KEY) or {}
    level_stats[level] = (tonumber(level_stats[level]) or 0) + 1
    self:set(EQUIP_LEVEL_KEY, level_stats)

    self:check_all_conditions(condition_def.EQUIP.QUALITY_COUNT)
    self:check_all_conditions(condition_def.EQUIP.QUALITY_GTE_COUNT)
    self:check_all_conditions(condition_def.EQUIP.LEVEL_SUM)
end

function CtnCondition:next_listener_id()
    self.listener_seq_ = (self.listener_seq_ or 0) + 1
    return self.listener_seq_
end

function CtnCondition:generate_condition_id(condition_type, condition_data)
    if type(condition_data) ~= "table" then
        return string.format("%s:%s", condition_type, tostring(condition_data))
    end

    local keys = {}
    for key in pairs(condition_data) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = string.format("%s=%s", key, tostring(condition_data[key]))
    end
    return string.format("%s:%s", condition_type, table.concat(parts, ","))
end

function CtnCondition:subscribe(condition_type, condition_data, callback, always_notify)
    if not condition_type or not condition_data or not callback then
        log.error("Invalid parameters for subscribe")
        return nil
    end

    if not self.subscribers_[condition_type] then
        self.subscribers_[condition_type] = {}
    end

    local condition_id = self:generate_condition_id(condition_type, condition_data)
    local entry = self.subscribers_[condition_type][condition_id]
    if not entry then
        entry = {
            data = condition_data,
            listeners = {},
        }
        self.subscribers_[condition_type][condition_id] = entry
    end

    local listener_id = self:next_listener_id()
    entry.listeners[listener_id] = {
        callback = callback,
        always_notify = always_notify or false,
    }

    self:check_condition(condition_type, condition_id)
    return listener_id
end

function CtnCondition:subscribe_multiple(conditions, callback)
    if not conditions or not callback then
        log.error("Invalid parameters for subscribe_multiple")
        return nil
    end

    local results = {}
    local condition_ids = {}

    for _, condition in ipairs(conditions) do
        if condition.type and condition.data then
            local condition_id = self:generate_condition_id(condition.type, condition.data)
            condition_ids[#condition_ids + 1] = condition_id
            self:subscribe(condition.type, condition.data, function(value)
                results[condition.type] = value
                if self:check_multiple_conditions(conditions, results) then
                    callback(results)
                end
            end, false)
        end
    end

    return condition_ids
end

function CtnCondition:check_multiple_conditions(conditions, results)
    for _, condition in ipairs(conditions) do
        local current_value = results[condition.type]
        if current_value == nil or not self:is_condition_met(condition.type, current_value, condition.data) then
            return false
        end
    end
    return true
end

function CtnCondition:unsubscribe_listener(listener_id)
    listener_id = tonumber(listener_id)
    if not listener_id then
        return false
    end
    for condition_type, entries in pairs(self.subscribers_) do
        for condition_id, entry in pairs(entries) do
            if entry.listeners and entry.listeners[listener_id] then
                entry.listeners[listener_id] = nil
                if not next(entry.listeners) then
                    entries[condition_id] = nil
                end
                return true
            end
        end
    end
    return false
end

function CtnCondition:unsubscribe(condition_type, condition_data, listener_id)
    if listener_id ~= nil then
        return self:unsubscribe_listener(listener_id)
    end
    if not condition_type or not condition_data then
        log.error("Invalid parameters for unsubscribe")
        return false
    end
    if not self.subscribers_[condition_type] then
        return false
    end
    local condition_id = self:generate_condition_id(condition_type, condition_data)
    self.subscribers_[condition_type][condition_id] = nil
    return true
end

function CtnCondition:unsubscribe_multiple(condition_ids)
    if not condition_ids then
        return
    end
    for _, condition_id in ipairs(condition_ids) do
        local condition_type, condition_data = self:parse_condition_id(condition_id)
        if condition_type and condition_data then
            self:unsubscribe(condition_type, condition_data)
        end
    end
end

function CtnCondition:parse_condition_id(condition_id)
    if not condition_id then
        return nil, nil
    end
    local sep = string.find(condition_id, ":", 1, true)
    if not sep then
        return nil, nil
    end

    local condition_type = string.sub(condition_id, 1, sep - 1)
    local payload = string.sub(condition_id, sep + 1)
    if payload == "" then
        return condition_type, {}
    end

    local condition_data = {}
    for pair in string.gmatch(payload, "[^,]+") do
        local key, value = pair:match("^([^=]+)=(.+)$")
        if key then
            local num = tonumber(value)
            condition_data[key] = num or value
        end
    end
    return condition_type, condition_data
end

function CtnCondition:get_condition_value(condition_type, data)
    if not condition_type or not data then
        log.error("Invalid parameters for get_condition_value")
        return nil
    end
    local handler = condition_def.handlers.get_value[condition_type]
    if handler then
        return handler(self, data)
    end
    return nil
end

function CtnCondition:is_condition_met(condition_type, current_value, data)
    if not condition_type or not data then
        return false
    end
    local handler = condition_def.handlers.is_met[condition_type]
    if handler then
        return handler(current_value, data)
    end
    return false
end

function CtnCondition:update_condition(condition_type, value)
    if not condition_type then
        log.error("Invalid parameters for update_condition")
        return
    end
    local handler = condition_def.handlers.update[condition_type]
    if not handler then
        return
    end
    local check_type = handler(self, value)
    if check_type then
        self:check_all_conditions(check_type)
    end
end

function CtnCondition:check_condition(condition_type, condition_id)
    local subscribers = self.subscribers_[condition_type]
    if not subscribers then
        return
    end
    local entry = subscribers[condition_id]
    if not entry or not entry.listeners then
        return
    end

    local current_value = self:get_condition_value(condition_type, entry.data)
    for _, listener in pairs(entry.listeners) do
        if listener.always_notify then
            listener.callback(current_value)
        elseif self:is_condition_met(condition_type, current_value, entry.data) then
            listener.callback(current_value)
        end
    end
end

function CtnCondition:check_all_conditions(condition_type)
    local subscribers = self.subscribers_[condition_type]
    if not subscribers then
        return
    end
    for condition_id in pairs(subscribers) do
        self:check_condition(condition_type, condition_id)
    end
end

function CtnCondition:clear_subscribers()
    self.subscribers_ = {}
end

return CtnCondition
