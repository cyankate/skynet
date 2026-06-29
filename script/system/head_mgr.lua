--[[
    车头养成：等级经验 + 属性/效果结算。
]]

local attr_calc = require "effect.attr_calc"
local effect_mgr = require "system.effect_mgr"
local condition_mgr = require "system.condition_mgr"
local weapon_mgr = require "system.weapon_mgr"
local HEAD_UPGRADE_DATA = require "setting.HEAD_UPGRADE_DATA"
local protocol_handler = require "protocol_handler"
local log = require "log"

local M = {}

local DEFAULT_HEAD_ID = 1
local DEFAULT_HEAD_LEVEL = 1

local function num(v)
    return tonumber(v) or 0
end

local function get_ctn(player)
    return player and player:get_ctn("common")
end

local function get_max_level()
    local max_level = 0
    for level in pairs(HEAD_UPGRADE_DATA) do
        max_level = math.max(max_level, num(level))
    end
    return max_level
end

local function get_upgrade_cfg(level)
    return HEAD_UPGRADE_DATA[num(level)]
end

function M.init_player(player)
    local ctn = get_ctn(player)
    if not ctn then
        return false
    end
    if num(ctn:get("head_id")) <= 0 then
        ctn:set("head_id", DEFAULT_HEAD_ID)
    end
    if num(ctn:get("head_level")) <= 0 then
        ctn:set("head_level", DEFAULT_HEAD_LEVEL)
    end
    if ctn:get("head_exp") == nil then
        ctn:set("head_exp", 0)
    end
    return true
end

function M.get_head_id(player)
    local ctn = get_ctn(player)
    if not ctn then
        return 0
    end
    return num(ctn:get("head_id"))
end

function M.get_head_level(player)
    local ctn = get_ctn(player)
    if not ctn then
        return 0
    end
    return num(ctn:get("head_level"))
end

function M.get_head_exp(player)
    local ctn = get_ctn(player)
    if not ctn then
        return 0
    end
    return num(ctn:get("head_exp"))
end

function M.get_upgrade_need_exp(level)
    local cfg = get_upgrade_cfg(level)
    if not cfg then
        return 0
    end
    return num(cfg.NeedExp)
end

function M.collect_head_effect_ids(player)
    local ids = {}
    local head_id = M.get_head_id(player)
    local head_level = M.get_head_level(player)
    if head_id <= 0 or head_level <= 0 then
        return ids
    end
    for lv = 1, head_level do
        local cfg = get_upgrade_cfg(lv)
        local effects = cfg and cfg.Effects
        if effects then
            for _, effect_id in ipairs(effects) do
                table.insert(ids, effect_id)
            end
        end
    end
    return ids
end

function M.sync_to_client(player)
    if not player or not player.player_id_ then
        return false
    end
    protocol_handler.send_to_player(player.player_id_, "head_upgrade_notify", {
        level = M.get_head_level(player),
        exp = M.get_head_exp(player),
    })
    return true
end

function M.add_head_exp(player, delta)
    delta = num(delta)
    if delta <= 0 then
        return true, {
            added = 0,
            level = M.get_head_level(player),
            exp = M.get_head_exp(player),
            level_ups = 0,
        }
    end
    local ctn = get_ctn(player)
    if not ctn then
        return false, "common container not found"
    end

    local level = M.get_head_level(player)
    local exp = M.get_head_exp(player) + delta
    local level_ups = 0
    local max_level = get_max_level()

    while level < max_level do
        local need_exp = M.get_upgrade_need_exp(level)
        if need_exp <= 0 or exp < need_exp then
            break
        end
        exp = exp - need_exp
        level = level + 1
        level_ups = level_ups + 1
    end

    ctn:set("head_level", level)
    ctn:set("head_exp", exp)
    M.sync_to_client(player)
    if level_ups > 0 then
        effect_mgr.collect_player_effects(player)
        condition_mgr.on_head_level_changed(player, level)
        local unlocked, count = weapon_mgr.try_unlock_by_level(player, level)
        if unlocked then
            weapon_mgr.sync_to_client(player)
            log.info("player %s unlock %d weapons by level %d", tostring(player.player_id_), count, level)
        end
        effect_mgr.sync_to_client(player)
    end

    return true, {
        added = delta,
        level = level,
        exp = exp,
        level_ups = level_ups,
        need_exp = M.get_upgrade_need_exp(level),
    }
end

return M
