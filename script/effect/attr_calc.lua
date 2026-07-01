--[[
    实体属性结算（双端可共享）：武器/车头建模 + effect_ids 上下文 + 属性公式。

    用法：
        local calc = require "effect.attr_calc"
        local ctx = calc.build_context(effect_ids)
        local att = calc.get_weapon_attr(weapon_id, level, "ATT", ctx)
]]
        
local effect_core
local ATTRIBUTE_ENUM
local ATTRIBUTE_LEVEL_DATA
local WEAPON_DATA
local HEAD_UPGRADE_DATA

if SKYNET_LUA_ROOT then
    effect_core = require "Skynet/script/attr/effect_core"
    ATTRIBUTE_ENUM = require "Setting/ATTRIBUTE_ENUM"
    ATTRIBUTE_LEVEL_DATA = require "Setting/ATTRIBUTE_LEVEL_DATA"
    WEAPON_DATA = require "Setting/WEAPON_DATA"
    HEAD_UPGRADE_DATA = require "Setting/HEAD_UPGRADE_DATA"
else
    effect_core = require "effect.effect_core"
    ATTRIBUTE_ENUM = require "setting.ATTRIBUTE_ENUM"
    ATTRIBUTE_LEVEL_DATA = require "setting.ATTRIBUTE_LEVEL_DATA"
    WEAPON_DATA = require "setting.WEAPON_DATA"
    HEAD_UPGRADE_DATA = require "setting.HEAD_UPGRADE_DATA"
end

local M = {}

local OP = effect_core.OP
local ENTITY = effect_core.ENTITY
local DEFAULT_WEAPON_LEVEL = 1

local function num(v)
    return tonumber(v) or 0
end

local function normalize_attr(attr)
    if type(attr) ~= "string" then
        return nil
    end
    if ATTRIBUTE_ENUM[attr] then
        return attr
    end
    local upper = string.upper(attr)
    if ATTRIBUTE_ENUM[upper] then
        return upper
    end
    return nil
end

local function get_attr_level_cfg(attr_id, level)
    attr_id = num(attr_id)
    level = num(level)
    if attr_id <= 0 or level <= 0 then
        return nil
    end
    local group = ATTRIBUTE_LEVEL_DATA[attr_id]
    if not group then
        return nil
    end
    return group[level]
end

local function attr_cfg_to_base(attr_cfg)
    if not attr_cfg then
        return {}
    end
    local base = {}
    for field, value in pairs(attr_cfg) do
        local attr_name = normalize_attr(field)
        if attr_name then
            base[attr_name] = num(value)
        end
    end
    return base
end

local function sum_attr_mods_for_attr(entity, attr_mods, attr_name, entity_type)
    local flat, pct = 0, 0
    for _, attr_mod in ipairs(attr_mods or {}) do
        if attr_mod.attr == attr_name
            and effect_core.match_scope(attr_mod.scope, entity, entity_type) then
            local value = num(attr_mod.value)
            if attr_mod.op == OP.PCT then
                pct = pct + value
            else
                flat = flat + value
            end
        end
    end
    return flat, pct
end

local function calc_entity_attrs(entity, attr_mods, entity_type)
    entity = entity or {}
    attr_mods = attr_mods or {}
    local attrs = {}
    local seen = {}
    if entity.base then
        for attr_name in pairs(entity.base) do
            seen[attr_name] = true
        end
    end
    for _, attr_mod in ipairs(attr_mods) do
        if attr_mod.attr then
            seen[attr_mod.attr] = true
        end
    end
    for attr_name in pairs(seen) do
        local base = num(entity.base and entity.base[attr_name])
        local flat, pct = sum_attr_mods_for_attr(entity, attr_mods, attr_name, entity_type)
        attrs[attr_name] = (base + flat) * (1 + pct)
    end
    return attrs
end

-- weapon ----------------------------------------------------------------

local function get_weapon_cfg(weapon_id)
    return WEAPON_DATA[num(weapon_id)]
end

local function get_weapon_base(weapon_cfg, level)
    if not weapon_cfg then
        return {}
    end
    return attr_cfg_to_base(get_attr_level_cfg(weapon_cfg.AttrId, level))
end

function M.build_weapon(weapon_id, level, extra)
    weapon_id = num(weapon_id)
    level = num(level)
    if level <= 0 then
        level = DEFAULT_WEAPON_LEVEL
    end
    extra = extra or {}

    local weapon_cfg = get_weapon_cfg(weapon_id)
    local base = get_weapon_base(weapon_cfg, level)

    for k, v in pairs(extra.base or {}) do
        base[k] = num(v)
    end

    local tags = {}
    local color = weapon_cfg and weapon_cfg.Color
    if color and color ~= "" then
        table.insert(tags, color)
    end
    for _, t in ipairs(extra.tags or {}) do
        table.insert(tags, t)
    end

    return {
        weapon_id = weapon_id,
        part_id = weapon_id,
        level = level,
        base = base,
        tags = tags,
    }
end

function M.calc_weapon_attrs(weapon, attr_mods)
    return calc_entity_attrs(weapon, attr_mods, ENTITY.WEAPON)
end

function M.calc_weapons_attrs(weapons, attr_mods)
    weapons = weapons or {}
    attr_mods = attr_mods or {}
    local result = {
        weapons = {},
        total = {},
    }
    for i, weapon in ipairs(weapons) do
        local attrs = M.calc_weapon_attrs(weapon, attr_mods)
        result.weapons[i] = {
            weapon_id = weapon.weapon_id,
            level = weapon.level,
            attrs = attrs,
        }
        for attr_name, value in pairs(attrs) do
            result.total[attr_name] = num(result.total[attr_name]) + value
        end
    end
    return result
end

-- head ------------------------------------------------------------------

local function get_head_upgrade_cfg(level)
    return HEAD_UPGRADE_DATA[num(level)]
end

local function get_head_attr_cfg(head_level)
    local upgrade_cfg = get_head_upgrade_cfg(head_level)
    if not upgrade_cfg then
        return nil
    end
    return get_attr_level_cfg(upgrade_cfg.AttrId, head_level)
end

function M.build_head(head_id, level, extra)
    head_id = num(head_id)
    level = num(level)
    extra = extra or {}
    local base = attr_cfg_to_base(get_head_attr_cfg(level))
    for k, v in pairs(extra.base or {}) do
        base[k] = num(v)
    end
    return {
        head_id = head_id,
        level = level,
        base = base,
    }
end

function M.calc_head_attrs(head, attr_mods)
    return calc_entity_attrs(head, attr_mods, ENTITY.HEAD)
end

-- facade ----------------------------------------------------------------

function M.build_context(effect_ids)
    local attr_mods, skills, specials = effect_core.expand_effect_ids(effect_ids)
    return {
        effect_ids = effect_ids or {},
        attr_mods = attr_mods,
        skills = skills,
        specials = specials,
    }
end

function M.get_weapon_attrs(weapon_id, level, ctx)
    ctx = ctx or {}
    return M.calc_weapon_attrs(M.build_weapon(weapon_id, level), ctx.attr_mods)
end

function M.get_weapon_attr(weapon_id, level, attr_name, ctx)
    local attrs = M.get_weapon_attrs(weapon_id, level, ctx)
    return num(attrs[attr_name])
end

function M.get_weapons_attrs(weapon_list, ctx)
    ctx = ctx or {}
    local weapons = {}
    for _, item in ipairs(weapon_list or {}) do
        table.insert(weapons, M.build_weapon(item.weapon_id, item.level))
    end
    return M.calc_weapons_attrs(weapons, ctx.attr_mods)
end

function M.get_head_attrs(head_id, level, ctx)
    ctx = ctx or {}
    return M.calc_head_attrs(M.build_head(head_id, level), ctx.attr_mods)
end

function M.get_head_attr(head_id, level, attr_name, ctx)
    local attrs = M.get_head_attrs(head_id, level, ctx)
    return num(attrs[attr_name])
end

return M
