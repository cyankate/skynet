--[[
    武器养成：解锁 + 属性结算。
]]

local attr_calc = require "effect.attr_calc"
local effect_mgr = require "system.effect_mgr"
local protocol_handler = require "protocol_handler"
local condition_mgr = require "system.condition_mgr"
local WEAPON_DATA = require "setting.WEAPON_DATA"
local log = require "log"

local M = {}

local DEFAULT_WEAPON_LEVEL = 1

local function num(v)
    return tonumber(v) or 0
end

local function get_ctn(player)
    return player and player:get_ctn("common")
end

function M.get_weapon_level(player, weapon_id)
    local ctn = get_ctn(player)
    if not ctn then
        return DEFAULT_WEAPON_LEVEL
    end
    local weapons = ctn:get_weapons()
    local entry = weapons and weapons[num(weapon_id)]
    if type(entry) == "table" then
        local level = num(entry.level)
        if level > 0 then
            return level
        end
    end
    return DEFAULT_WEAPON_LEVEL
end

function M.calc_player_weapon_attrs(player, weapon_ids)
    weapon_ids = weapon_ids or M.get_unlocked_weapon_ids(player)
    local weapons = {}
    for _, weapon_id in ipairs(weapon_ids) do
        table.insert(weapons, attr_calc.build_weapon(weapon_id, M.get_weapon_level(player, weapon_id)))
    end
    local effects = effect_mgr.get_effects(player)
    local attr_mods = effects and effects:get_attr_mods() or {}
    return attr_calc.calc_weapons_attrs(weapons, attr_mods), attr_mods
end

function M.activate_weapon(player, weapon_id)
    weapon_id = num(weapon_id)
    if weapon_id <= 0 then
        return false, "invalid weapon_id"
    end
    local ctn = get_ctn(player)
    if not ctn then
        return false, "common container not found"
    end
    if ctn:get_weapons()[weapon_id] then
        return true
    end
    ctn:set_weapon_unlocked(weapon_id)
    condition_mgr.on_weapon_obtained(player, weapon_id, M.get_weapon_level(player, weapon_id))
    log.info("player %s unlock weapon %d", tostring(player.player_id_), weapon_id)
    return true
end

function M.get_unlocked_weapon_ids(player)
    local ctn = get_ctn(player)
    if not ctn then
        return {}
    end
    local list = {}
    for weapon_id in pairs(ctn:get_weapons()) do
        list[#list + 1] = weapon_id
    end
    table.sort(list)
    return list
end

function M.sync_to_client(player)
    if not player or not player.player_id_ then
        return false
    end
    protocol_handler.send_to_player(player.player_id_, "weapon_list_notify", {
        weapons = M.get_unlocked_weapon_ids(player),
    })
    return true
end

function M.has_weapon(player, weapon_id)
    local ctn = get_ctn(player)
    if not ctn then
        return false
    end
    return ctn:get_weapons()[num(weapon_id)] ~= nil
end

--- 按车头等级解锁武器：UnlockLevel <= level 且尚未拥有则激活
function M.try_unlock_by_level(player, level)
    if not player then
        return false, 0
    end
    level = num(level)
    if level < 0 then
        return false, 0
    end

    local unlocked_count = 0
    for weapon_id, cfg in pairs(WEAPON_DATA) do
        weapon_id = num(weapon_id)
        if weapon_id > 0 and type(cfg) == "table" then
            local need_level = num(cfg.UnlockLevel)
            if need_level <= level and not M.has_weapon(player, weapon_id) then
                local ok = M.activate_weapon(player, weapon_id)
                if ok then
                    unlocked_count = unlocked_count + 1
                end
            end
        end
    end
    return unlocked_count > 0, unlocked_count
end

return M
