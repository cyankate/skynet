--[[
    武器养成：解锁、升级、属性结算。
]]

local attr_calc = require "effect.attr_calc"
local effect_mgr = require "system.effect_mgr"
local protocol_handler = require "protocol_handler"
local condition_mgr = require "system.condition_mgr"
local item_mgr = require "system.item_mgr"
local WEAPON_DATA = require "setting.WEAPON_DATA"
local WEAPON_UPGRADE_DATA = require "setting.WEAPON_UPGRADE_DATA"
local log = require "log"

local M = {}

local DEFAULT_WEAPON_LEVEL = 1

local function num(v)
    return tonumber(v) or 0
end

local function get_ctn(player)
    return player and player:get_ctn("common")
end

local function get_weapon_cfg(weapon_id)
    return WEAPON_DATA[num(weapon_id)]
end

--- UpgradeCost[方案组][槽] = {itemId, count} → {[itemId]=count}
local function flatten_upgrade_cost(upgrade_cost)
    local cost = {}
    if type(upgrade_cost) ~= "table" then
        return cost
    end
    local group = upgrade_cost[1] or upgrade_cost
    if type(group) ~= "table" then
        return cost
    end
    for _, slot in pairs(group) do
        if type(slot) == "table" then
            local item_id = num(slot[1])
            local count = num(slot[2])
            if item_id > 0 and count > 0 then
                cost[item_id] = num(cost[item_id]) + count
            end
        end
    end
    return cost
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

function M.build_sync_list(player)
    local list = {}
    for _, weapon_id in ipairs(M.get_unlocked_weapon_ids(player)) do
        list[#list + 1] = {
            weapon_id = weapon_id,
            level = M.get_weapon_level(player, weapon_id),
        }
    end
    return list
end

function M.sync_to_client(player)
    if not player or not player.player_id_ then
        return false
    end
    protocol_handler.send_to_player(player.player_id_, "weapon_list_notify", {
        weapons = M.build_sync_list(player),
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

--- 汇总已解锁武器在当前等级及以下解锁的 EffectIds
function M.collect_weapon_effect_ids(player)
    local ids = {}
    if not player then
        return ids
    end
    for _, weapon_id in ipairs(M.get_unlocked_weapon_ids(player)) do
        local cur_level = M.get_weapon_level(player, weapon_id)
        local cfg = get_weapon_cfg(weapon_id)
        local tree = cfg and WEAPON_UPGRADE_DATA[cfg.UpgradeArgs]
        if tree then
            for level = 1, cur_level do
                local row = tree[level]
                local effect_ids = row and row.EffectIds
                if type(effect_ids) == "table" then
                    for _, effect_id in pairs(effect_ids) do
                        effect_id = num(effect_id)
                        if effect_id > 0 then
                            ids[#ids + 1] = effect_id
                        end
                    end
                end
            end
        end
    end
    return ids
end

--- 升级到下一级：消耗 UpgradeCost（取 next_level 行），成功后写 level
function M.upgrade_weapon(player, weapon_id)
    weapon_id = num(weapon_id)
    if weapon_id <= 0 then
        return false, "武器ID无效"
    end
    local cfg = get_weapon_cfg(weapon_id)
    if not cfg then
        return false, "武器配置不存在"
    end
    if not M.has_weapon(player, weapon_id) then
        return false, "武器未解锁"
    end

    local cur_level = M.get_weapon_level(player, weapon_id)
    local next_level = cur_level + 1
    local tree = WEAPON_UPGRADE_DATA[cfg.UpgradeArgs]
    local next_row = tree and tree[next_level]
    if not next_row then
        return false, "已达最大等级"
    end

    local cost = flatten_upgrade_cost(next_row.UpgradeCost)
    if next(cost) then
        local ok, err = item_mgr.cost_items(player, cost, "weapon_upgrade")
        if not ok then
            return false, err or "材料不足"
        end
    end

    local ctn = get_ctn(player)
    if not ctn or not ctn:set_weapon_level(weapon_id, next_level) then
        return false, "保存武器等级失败"
    end

    condition_mgr.on_weapon_obtained(player, weapon_id, next_level)
    effect_mgr.collect_player_effects(player)

    log.info("player %s upgrade weapon %d to level %d", tostring(player.player_id_), weapon_id, next_level)
    return true, {
        weapon_id = weapon_id,
        level = next_level,
    }
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
