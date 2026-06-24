--[[
    养成效果：EffectContext 为唯一效果容器。
]]

local effect_core = require "effect.effect_core"
local class = require "utils.class"
local head_mgr = require "system.head_mgr"
local talent_mgr = require "system.talent_mgr"

local M = setmetatable({}, { __index = effect_core })

M.special_handlers = M.special_handlers or {}

local function num(v)
    return tonumber(v) or 0
end

local function append_effect_ids(ids, part)
    if type(part) ~= "table" then
        return
    end
    for _, effect_id in pairs(part) do
        ids[#ids + 1] = effect_id
    end
end

local function copy_effect_ids(effect_ids)
    local list = {}
    if type(effect_ids) ~= "table" then
        return list
    end
    for _, raw_id in ipairs(effect_ids) do
        local effect_id = num(raw_id)
        if effect_id > 0 then
            list[#list + 1] = effect_id
        end
    end
    return list
end

local function collect_effect_unlock_weapons_from_specials(specials)
    local map = {}
    for _, item in ipairs(specials or {}) do
        if item.special == effect_core.SPECIAL.WEAPON_UNLOCK then
            local weapon_id = num(item.value)
            if weapon_id > 0 then
                map[weapon_id] = true
            end
        end
    end
    return map
end

local function map_to_sorted_ids(map)
    local ids = {}
    for weapon_id in pairs(map or {}) do
        ids[#ids + 1] = weapon_id
    end
    table.sort(ids)
    return ids
end

local function build_effects_cache(effect_ids)
    local attr_mods, skills, specials = M.expand_effect_ids(effect_ids)
    return {
        effect_ids = copy_effect_ids(effect_ids),
        attr_mods = attr_mods,
        skills = skills,
        specials = specials,
    }
end

local EffectContext = class("EffectContext")

function EffectContext:ctor(effect_ids)
    self.effect_ids_ = copy_effect_ids(effect_ids)
    self.cache_ = nil
end

function EffectContext:invalidate()
    self.cache_ = nil
end

function EffectContext:rebuild()
    self.cache_ = build_effects_cache(self.effect_ids_)
    return self.cache_
end

function EffectContext:get_cache()
    if not self.cache_ then
        self:rebuild()
    end
    return self.cache_
end

function EffectContext:get_effect_ids()
    return copy_effect_ids(self.effect_ids_)
end

function EffectContext:add_effect_id(effect_id)
    effect_id = num(effect_id)
    if effect_id <= 0 then
        return false
    end
    self.effect_ids_[#self.effect_ids_ + 1] = effect_id
    self:invalidate()
    return true
end

function EffectContext:get_attr_mods()
    return self:get_cache().attr_mods or {}
end

function EffectContext:get_skills()
    return self:get_cache().skills or {}
end

function EffectContext:get_specials()
    return self:get_cache().specials or {}
end

function EffectContext:collect_special_values(special_key)
    local total = 0
    for _, item in ipairs(self:get_specials()) do
        if item.special == special_key then
            total = total + num(item.value)
        end
    end
    return total
end

function EffectContext:get_effect_unlock_weapon_ids()
    return map_to_sorted_ids(collect_effect_unlock_weapons_from_specials(self:get_specials()))
end

function EffectContext:has_effect_unlock_weapon(weapon_id)
    weapon_id = num(weapon_id)
    if weapon_id <= 0 then
        return false
    end
    return collect_effect_unlock_weapons_from_specials(self:get_specials())[weapon_id] == true
end

function EffectContext:build_sync()
    return {
        effect_ids = self:get_effect_ids(),
        effect_unlock_weapon_ids = self:get_effect_unlock_weapon_ids(),
    }
end

M.EffectContext = EffectContext

function M.new_effects(effect_ids)
    return EffectContext.new(effect_ids)
end

function M.from_pack(player_pack)
    if type(player_pack) ~= "table" then
        return M.new_effects({})
    end
    return M.new_effects(player_pack.effect_ids)
end

--- 汇总玩家养成侧 effect_id（新增来源在此追加）
function M.collect_player_effect_ids(player)
    if not player then
        return {}
    end
    local ids = {}
    append_effect_ids(ids, head_mgr.collect_head_effect_ids(player))
    append_effect_ids(ids, talent_mgr.collect_talent_effect_ids(player))
    return ids
end

function M.invalidate_player_effects(player)
    if player then
        player.effects_ = nil
    end
end

function M.collect_player_effects(player)
    if not player then
        return nil
    end
    player.effects_ = EffectContext.new(M.collect_player_effect_ids(player))
    return player.effects_
end

function M.get_effects(player)
    if not player then
        return nil
    end
    if not player.effects_ then
        M.collect_player_effects(player)
    end
    return player.effects_
end

function M.register_special_handler(special_key, handler)
    M.special_handlers[special_key] = handler
end

function M.apply_special_handlers(player)
    local effects = M.get_effects(player)
    if not effects then
        return
    end
    for _, item in ipairs(effects:get_specials()) do
        local handler = M.special_handlers[item.special]
        if handler then
            handler(player, item)
        end
    end
end

M.register_special_handler(effect_core.SPECIAL.FREE_LOTTERY, function(_player, _item)
end)

function M.calc_runtime_attrs(player_pack, effects)
    if type(player_pack) ~= "table" or not effects then
        return nil
    end
    local attr_calc = require "effect.attr_calc"
    local attr_mods = effects:get_attr_mods()

    local weapons = {}
    for weapon_id, level in pairs(player_pack.weapon_levels or {}) do
        weapons[#weapons + 1] = attr_calc.build_weapon(weapon_id, level)
    end
    local weapon_result = attr_calc.calc_weapons_attrs(weapons, attr_mods)

    local head_id = num(player_pack.head_id)
    if head_id <= 0 and type(player_pack.head) == "table" then
        head_id = num(player_pack.head.head_id)
    end
    local head_level = num(player_pack.head_level)
    if head_level <= 0 and type(player_pack.head) == "table" then
        head_level = num(player_pack.head.level)
    end
    local head = attr_calc.build_head(head_id, head_level)
    local head_attrs = attr_calc.calc_head_attrs(head, attr_mods)

    return {
        weapons = weapon_result,
        head = {
            head_id = head.head_id,
            level = head.level,
            attrs = head_attrs,
        },
    }
end

return M
