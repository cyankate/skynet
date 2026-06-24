--[[
    天赋养成
]]

local protocol_handler = require "protocol_handler"
local TALENT_DATA = require "setting.TALENT_DATA"
local item_mgr = require "system.item_mgr"
local effect_mgr = require "system.effect_mgr"
local head_mgr = require "system.head_mgr"

local M = {}

local TALENT_STATE = {
    ACTIVATED = 1,
    UNLOCKABLE = 2,
    LOCKED = 3,
}

local function num(v)
    return tonumber(v) or 0
end

local function get_ctn(player)
    return player and player:get_ctn("common")
end

local function get_cfg(talent_id)
    return TALENT_DATA[num(talent_id)]
end

local function pre_talents_satisfied(activated, pre_talents)
    if type(pre_talents) ~= "table" or not next(pre_talents) then
        return true
    end
    for _, pre_id in pairs(pre_talents) do
        if not activated[num(pre_id)] then
            return false
        end
    end
    return true
end

function M.get_talent_state(player, talent_id)
    talent_id = num(talent_id)
    local cfg = get_cfg(talent_id)
    if not cfg then
        return nil, "天赋配置不存在"
    end
    local ctn = get_ctn(player)
    if not ctn then
        return nil, "common container not found"
    end
    local activated = ctn:get_talents()
    if activated[talent_id] then
        return TALENT_STATE.ACTIVATED
    end
    if not pre_talents_satisfied(activated, cfg.PreTalents) then
        return TALENT_STATE.LOCKED
    end
    local head_level = head_mgr.get_head_level(player)
    if head_level < num(cfg.LimitLevel) then
        return TALENT_STATE.LOCKED
    end
    return TALENT_STATE.UNLOCKABLE
end

function M.activate_talent(player, talent_id)
    talent_id = num(talent_id)
    local cfg = get_cfg(talent_id)
    if not cfg then
        return false, "天赋配置不存在"
    end

    local ctn = get_ctn(player)
    if not ctn then
        return false, "common container not found"
    end

    local activated = ctn:get_talents()
    if activated[talent_id] then
        return false, "天赋已点亮"
    end

    if not pre_talents_satisfied(activated, cfg.PreTalents) then
        return false, "前置天赋未点亮"
    end

    local head_level = head_mgr.get_head_level(player)
    local limit_level = num(cfg.LimitLevel)
    if limit_level > 0 and head_level < limit_level then
        return false, string.format("车头等级不足，需要%d级", limit_level)
    end

    local cost = cfg.Cost
    if type(cost) == "table" and next(cost) then
        local ok, err = item_mgr.cost_items(player, cost, "activate_talent")
        if not ok then
            return false, err or "材料不足"
        end
    end

    ctn:set_talent_activated(talent_id)
    effect_mgr.collect_player_effects(player)
    return true, {
        talent_id = talent_id,
    }
end

function M.collect_talent_effect_ids(player)
    local ids = {}
    local ctn = get_ctn(player)
    if not ctn then
        return ids
    end
    local activated = ctn:get_talents()
    for talent_id in pairs(activated) do
        local cfg = get_cfg(talent_id)
        local effect_ids = cfg and cfg.EffectIds
        if type(effect_ids) == "table" then
            for _, effect_id in pairs(effect_ids) do
                ids[#ids + 1] = effect_id
            end
        end
    end
    return ids
end

function M.sync_to_client(player)
    if not player or not player.player_id_ then
        return false
    end
    local ctn = get_ctn(player)
    if not ctn then
        return false
    end
    local activated = ctn:get_talents()
    local talents = {}
    for talent_id in pairs(activated) do
        talents[#talents + 1] = talent_id
    end
    table.sort(talents)
    protocol_handler.send_to_player(player.player_id_, "talent_info_notify", {
        talents = talents,
    })
    return true
end

return M
