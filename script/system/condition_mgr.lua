--[[
    条件进度：从各养成/玩法系统写入快照，并通知订阅者。
]]

local condition_def = require "define.condition_def"
local head_mgr = require "system.head_mgr"
local barrier_mgr = require "system.barrier_mgr"
local BARRIER_DATA = require "setting.BARRIER_DATA"
local WEAPON_DATA = require "setting.WEAPON_DATA"

local M = {}

local COLOR_QUALITY = {
    red = 1,
    yellow = 2,
    blue = 3,
    purple = 4,
    orange = 5,
}

local function num(v)
    return tonumber(v) or 0
end

local function get_ctn(player)
    return player and player:get_ctn("condition")
end

local function weapon_quality(weapon_id)
    local cfg = WEAPON_DATA[num(weapon_id)]
    if not cfg or not cfg.Color then
        return 1
    end
    return COLOR_QUALITY[cfg.Color] or 1
end

local function rebuild_equip_stats(player)
    local quality_stats = {}
    local level_stats = {}
    local common = player:get_ctn("common")
    if not common then
        return quality_stats, level_stats
    end

    for weapon_id, entry in pairs(common:get_weapons() or {}) do
        local level = num(type(entry) == "table" and entry.level or entry)
        if level <= 0 then
            level = 1
        end
        local quality = weapon_quality(weapon_id)
        quality_stats[quality] = (quality_stats[quality] or 0) + 1
        level_stats[level] = (level_stats[level] or 0) + 1
    end
    return quality_stats, level_stats
end

function M.get_condition_value(player, condition_type, params)
    local ctn = get_ctn(player)
    if not ctn then
        return nil
    end
    return ctn:get_condition_value(condition_type, params or {})
end

function M.is_condition_met(player, condition_type, params)
    local ctn = get_ctn(player)
    if not ctn then
        return false
    end
    params = params or {}
    local value = ctn:get_condition_value(condition_type, params)
    return ctn:is_condition_met(condition_type, value, params)
end

function M.check(player, condition_type, params)
    return M.is_condition_met(player, condition_type, params)
end

function M.sync_from_player(player)
    local ctn = get_ctn(player)
    if not ctn then
        return false
    end

    ctn:set_level(head_mgr.get_head_level(player), false)

    for barrier_id in pairs(BARRIER_DATA) do
        if barrier_mgr.is_barrier_passed(player, barrier_id) then
            ctn:mark_barrier_passed(barrier_id, false)
        end
    end

    local quality_stats = ctn:get("equip_quality") or {}
    if not next(quality_stats) then
        quality_stats, level_stats = rebuild_equip_stats(player)
        ctn:set("equip_quality", quality_stats)
        ctn:set("equip_level", level_stats)
    end

    return true
end

function M.on_head_level_changed(player, level)
    local ctn = get_ctn(player)
    if not ctn then
        return
    end
    ctn:update_condition(condition_def.LEVEL.REACH, level)
end

function M.on_barrier_passed(player, barrier_id)
    local ctn = get_ctn(player)
    if not ctn then
        return
    end
    ctn:update_condition(condition_def.CHAPTER.BARRIER_PASS, num(barrier_id))
end

function M.on_chapter_passed(player, chapter_id)
    local ctn = get_ctn(player)
    if not ctn then
        return
    end
    ctn:update_condition(condition_def.CHAPTER.PASS, num(chapter_id))
end

function M.on_weapon_obtained(player, weapon_id, level)
    local ctn = get_ctn(player)
    if not ctn then
        return
    end
    local quality = weapon_id and weapon_quality(weapon_id) or 1
    ctn:update_equip_condition(quality, num(level) > 0 and num(level) or 1)
end

return M
