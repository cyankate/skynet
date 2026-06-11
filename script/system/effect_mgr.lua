--[[
    养成效果：服务端收集与特殊效果执行。
]]

local effect_core = require "effect.effect_core"

local M = setmetatable({}, { __index = effect_core })

M.special_handlers = M.special_handlers or {}
M.effect_id_collectors = M.effect_id_collectors or {}

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

function M.register_effect_id_collector(collector)
    if type(collector) == "function" then
        table.insert(M.effect_id_collectors, collector)
    end
end

local function collect_player_effect_ids(player)
    local ids = {}
    for _, collector in ipairs(M.effect_id_collectors) do
        append_effect_ids(ids, collector(player))
    end
    return ids
end

local function build_player_effects(player)
    local effect_ids = collect_player_effect_ids(player)
    local attr_mods, skills, specials = M.expand_effect_ids(effect_ids)
    return {
        effect_ids = effect_ids,
        attr_mods = attr_mods,
        skills = skills,
        specials = specials,
    }
end

function M.invalidate_player_effects(player)
    if player then
        player.effect_cache_ = nil
    end
end

function M.collect_player_effects(player)
    local effects = build_player_effects(player)
    if player then
        player.effect_cache_ = effects
    end
    return effects
end

function M.get_player_effects(player)
    if not player then
        return nil
    end
    return player.effect_cache_
end

function M.collect_player_attr_mods(player)
    local effects = M.get_player_effects(player)
    if not effects then
        return {}
    end
    return effects.attr_mods
end

function M.collect_special_values(player, special_key)
    local effects = M.get_player_effects(player)
    if not effects then
        return 0
    end
    local total = 0
    for _, item in ipairs(effects.specials) do
        if item.special == special_key then
            total = total + num(item.value)
        end
    end
    return total
end

function M.register_special_handler(special_key, handler)
    M.special_handlers[special_key] = handler
end

function M.apply_special_handlers(player)
    local effects = M.get_player_effects(player)
    if not effects then
        return
    end
    for _, item in ipairs(effects.specials) do
        local handler = M.special_handlers[item.special]
        if handler then
            handler(player, item)
        end
    end
end

M.register_special_handler(effect_core.SPECIAL.FREE_LOTTERY, function(_player, _item)
end)

return M
