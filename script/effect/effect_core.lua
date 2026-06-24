--[[
    养成效果核心：配置展开 + scope 匹配（双端可共享）。
]]

local ATTRIBUTE_ENUM = require "setting.ATTRIBUTE_ENUM"
local EFFECT_DATA = require "setting.EFFECT_DATA"

local M = {}

M.EFFECT_TYPE = {
    ATTR = 1,
    SKILL = 2,
    SPECIAL = 3,
}

M.TARGET_KEY = {
    WEAPON_ID = "WeaponID",
    WEAPON_COLOR = "WeaponColor",
    CAR_HEAD = "CarHead",
}

M.TARGET_NONE = "no"

M.ENTITY = {
    WEAPON = "weapon",
    HEAD = "head",
}

M.SPECIAL = {
    FREE_LOTTERY = "free_lottery",
    FREE_SWEEP = "free_sweep",
    REWARD_BONUS = "reward_bonus",
    CHALLENGE_ADD = "challenge_add",
    WEAPON_HEAL_TICK = "weapon_heal_tick",
    WEAPON_BUFF_ON_SPAWN = "weapon_buff_on_spawn",
    ROGUE_BLESS_UNLOCK = "rogue_bless_unlock",
    WEAPON_UNLOCK = "weapon_unlock",
}

M.OP = {
    ADD = "add",
    PCT = "pct",
}

M.WEAPON_COLOR = {
    RED = "red",
    BLUE = "blue",
    GREEN = "green",
    YELLOW = "yellow",
    PURPLE = "purple",
}

M.scope_handlers = M.scope_handlers or {}

local EFFECT_TYPE = M.EFFECT_TYPE
local TARGET_KEY = M.TARGET_KEY
local ENTITY = M.ENTITY
local OP = M.OP

local OP_ALIAS = {
    add = OP.ADD,
    pct = OP.PCT,
    per = OP.PCT,
}

local function num(v)
    return tonumber(v) or 0
end

local function part_has_tag(part, tag)
    if not part or not tag then
        return false
    end
    local tags = part.tags
    if type(tags) ~= "table" then
        return false
    end
    for _, t in ipairs(tags) do
        if t == tag then
            return true
        end
    end
    return tags[tag] == true
end

local function match_or_list(values, checker)
    if not values or #values == 0 then
        return true
    end
    for _, value in ipairs(values) do
        if checker(value) then
            return true
        end
    end
    return false
end

function M.parse_target(target)
    if target == nil or target == M.TARGET_NONE or target == "" then
        return {}
    end
    if type(target) ~= "table" then
        return {}
    end
    return target
end

function M.register_scope_handler(scope_key, entity_type, handler)
    M.scope_handlers[scope_key] = M.scope_handlers[scope_key] or {}
    M.scope_handlers[scope_key][entity_type] = handler
end

function M.match_scope(scope, unit, entity_type)
    if not unit then
        return false
    end
    if not scope or not next(scope) then
        return true
    end
    for key, values in pairs(scope) do
        local handlers = M.scope_handlers[key]
        if not handlers then
            return false
        end
        local handler = handlers[entity_type]
        if not handler then
            return false
        end
        if not handler(unit, values) then
            return false
        end
    end
    return true
end

local function init_scope_handlers()
    M.register_scope_handler(TARGET_KEY.WEAPON_ID, ENTITY.WEAPON, function(weapon, values)
        return match_or_list(values, function(weapon_id)
            return num(weapon.part_id) == num(weapon_id)
        end)
    end)

    M.register_scope_handler(TARGET_KEY.WEAPON_COLOR, ENTITY.WEAPON, function(weapon, values)
        return match_or_list(values, function(color)
            return part_has_tag(weapon, color)
        end)
    end)

    M.register_scope_handler(TARGET_KEY.CAR_HEAD, ENTITY.HEAD, function(head, values)
        return match_or_list(values, function(car_head_id)
            return num(head.head_id) == num(car_head_id)
        end)
    end)
end

init_scope_handlers()

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

local function normalize_op(op, value)
    local normalized = OP_ALIAS[op] or op
    if normalized == OP.PCT and math.abs(value) >= 1 then
        return normalized, value / 100
    end
    return normalized, value
end

function M.get_effect(effect_id)
    return EFFECT_DATA[num(effect_id)]
end

function M.effect_to_attr_mod(effect, effect_id)
    if not effect or num(effect.Type) ~= EFFECT_TYPE.ATTR then
        return nil
    end
    local args = effect.Args
    if type(args) ~= "table" then
        return nil
    end
    local attr_name = normalize_attr(args[1])
    if not attr_name then
        return nil
    end
    local op, value = normalize_op(args[2] or OP.ADD, num(args[3]))
    return {
        effect_id = effect_id,
        scope = M.parse_target(effect.Target),
        attr = attr_name,
        op = op,
        value = value,
    }
end

function M.expand_effect_ids(effect_ids)
    local attr_mods = {}
    local skills = {}
    local specials = {}
    if type(effect_ids) ~= "table" then
        return attr_mods, skills, specials
    end

    for _, raw_id in ipairs(effect_ids) do
        local effect_id = num(raw_id)
        local cfg = EFFECT_DATA[effect_id]
        if cfg then
            local effect_type = num(cfg.Type)
            if effect_type == EFFECT_TYPE.ATTR then
                local attr_mod = M.effect_to_attr_mod(cfg, effect_id)
                if attr_mod then
                    table.insert(attr_mods, attr_mod)
                end
            elseif effect_type == EFFECT_TYPE.SKILL then
                local args = cfg.Args
                table.insert(skills, {
                    effect_id = effect_id,
                    skill_id = num(args and args[1]),
                    scope = M.parse_target(cfg.Target),
                })
            elseif effect_type == EFFECT_TYPE.SPECIAL then
                local args = cfg.Args
                table.insert(specials, {
                    effect_id = effect_id,
                    special = cfg.Special,
                    value = num(args and args[1]),
                    scope = M.parse_target(cfg.Target),
                })
            end
        end
    end

    return attr_mods, skills, specials
end

return M
