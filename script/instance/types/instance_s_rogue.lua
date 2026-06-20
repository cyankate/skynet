--[[
    单人肉鸽副本：继承 InstanceSingle，内聚三选一随机与局内状态机。
]]

local class = require "utils.class"
local InstanceSingle = require "instance.types.instance_single"
local ROGUE_ABILITY_DATA = require "setting.ROGUE_ABILITY_DATA"
local ROGUE_REFRESH_DATA = require "setting.ROGUE_REFRESH_DATA"
local WEAPON_DATA = require "setting.WEAPON_DATA"
local tableUtils = require "utils.tableUtils"
local ROGUE_DEF = require "instance.rogue.rogue_def"

local InstanceRogue = class("InstanceRogue", InstanceSingle)

local function num(v)
    return tonumber(v) or 0
end

local function is_random_token(v)
    local s = tostring(v or ""):lower()
    return s == "random" or s == "-1"
end

local function get_ability(ability_id)
    return ROGUE_ABILITY_DATA[num(ability_id)]
end

local function build_pick_context(state)
    state = state or {}
    local lineup = {}
    for _, wid in ipairs(state.lineup_weapon_ids or {}) do
        lineup[num(wid)] = true
    end
    local unlocked = {}
    for _, wid in ipairs(state.unlocked_weapon_ids or {}) do
        unlocked[num(wid)] = true
    end
    local owned_weapons = {}
    for _, wid in ipairs(state.owned_weapon_ids or {}) do
        owned_weapons[num(wid)] = true
    end
    local owned_colors = {}
    for _, color in ipairs(state.owned_colors or {}) do
        owned_colors[tostring(color)] = true
    end
    return {
        lineup = lineup,
        unlocked = unlocked,
        owned_weapons = owned_weapons,
        owned_colors = owned_colors,
        picked = state.picked or {},
        weapon_levels = state.weapon_levels or {},
        used_option_ids = {},
    }
end

local function check_precondition(ability, ctx)
    local pre = ability.PreCondition
    if pre == nil or pre == "" then
        return true
    end
    local need_id = num(pre)
    if need_id > 0 then
        return num(ctx.picked[need_id]) >= 1
    end
    return true
end

local function has_battle_weapon(ctx, weapon_id)
    weapon_id = num(weapon_id)
    if weapon_id <= 0 then
        return true
    end
    return ctx.owned_weapons[weapon_id] or ctx.lineup[weapon_id]
end

local function is_color_blocked(ctx, weapon_id)
    weapon_id = num(weapon_id)
    if weapon_id <= 0 then
        return false
    end
    local wcfg = WEAPON_DATA[weapon_id]
    if not wcfg or not wcfg.Color then
        return false
    end
    return ctx.owned_colors[tostring(wcfg.Color)] == true
end

local function can_pick_ability(ability, ctx, pick_type)
    if type(ability) ~= "table" then
        return false
    end
    local id = num(ability.Id)
    if id <= 0 or ctx.used_option_ids[id] then
        return false
    end
    local ability_type = tostring(ability.Type or ""):lower()
    local weapon_id = num(ability.WeaponId)
    local limit = num(ability.Limit)
    if limit > 0 and num(ctx.picked[id]) >= limit then
        return false
    end
    if not check_precondition(ability, ctx) then
        return false
    end
    if num(ability.Weight) <= 0 then
        return false
    end

    if ability_type == "weapon" then
        if pick_type ~= "weapon" and pick_type ~= "common" then
            return false
        end
        if weapon_id > 0 and not ctx.unlocked[weapon_id] then
            return false
        end
        if is_color_blocked(ctx, weapon_id) then
            return false
        end
        return true
    end

    if ability_type == "ability" then
        if pick_type ~= "ability" and pick_type ~= "common" then
            return false
        end
        if weapon_id > 0 and not has_battle_weapon(ctx, weapon_id) then
            return false
        end
        return true
    end

    return false
end

local function collect_candidates(pick_type, ctx)
    local list = {}
    for _, ability in pairs(ROGUE_ABILITY_DATA) do
        if can_pick_ability(ability, ctx, pick_type) then
            list[#list + 1] = { num(ability.Id), num(ability.Weight) }
        end
    end
    return list
end

local function collect_common_candidates(ctx)
    local list = {}
    for _, ability in pairs(ROGUE_ABILITY_DATA) do
        local ability_type = tostring(ability.Type or ""):lower()
        local sub_type = ability_type == "weapon" and "weapon" or "ability"
        if can_pick_ability(ability, ctx, sub_type) then
            list[#list + 1] = { num(ability.Id), num(ability.Weight) }
        end
    end
    return list
end

local function weighted_pick(candidates, ctx)
    local id = tableUtils.random_weight_from_list(candidates)
    if id then
        ctx.used_option_ids[num(id)] = true
    end
    return id
end

local function find_refresh_rule(refresh_id, pick_times)
    local group = ROGUE_REFRESH_DATA[num(refresh_id)]
    if type(group) ~= "table" then
        return nil, "肉鸽刷新配置不存在"
    end
    local common_rule
    for _, rule in pairs(group) do
        if type(rule) == "table" then
            if tostring(rule.Type or ""):lower() == "common" then
                common_rule = rule
            end
            if num(rule.Times) == pick_times then
                return rule
            end
        end
    end
    return common_rule
end

local function pick_from_args(args, pick_type, ctx)
    if type(args) ~= "table" or not next(args) then
        return weighted_pick(collect_candidates(pick_type, ctx), ctx)
    end

    for i = 1, #args do
        if is_random_token(args[i]) then
            local id = weighted_pick(collect_candidates(pick_type, ctx), ctx)
            if id then
                return id
            end
        end
    end

    local weapon_ids = {}
    for i = 1, #args do
        local ability = get_ability(args[i])
        if ability and can_pick_ability(ability, ctx, pick_type) then
            local id = num(ability.Id)
            ctx.used_option_ids[id] = true
            return id
        end
        weapon_ids[#weapon_ids + 1] = num(args[i])
    end

    if #weapon_ids > 0 then
        local candidates = {}
        for _, ability in pairs(ROGUE_ABILITY_DATA) do
            local wid = num(ability.WeaponId)
            for _, filter_wid in ipairs(weapon_ids) do
                if wid == num(filter_wid) and can_pick_ability(ability, ctx, pick_type) then
                    candidates[#candidates + 1] = { num(ability.Id), num(ability.Weight) }
                end
            end
        end
        return weighted_pick(candidates, ctx)
    end

    return nil
end

local function fill_with_ability(options, ctx)
    while #options < 3 do
        local id = weighted_pick(collect_candidates("ability", ctx), ctx)
        if not id then
            break
        end
        options[#options + 1] = id
    end
end

local function can_roll_weapon(ctx)
    return #collect_candidates("weapon", ctx) > 0
end

local function roll_three_options(refresh_id, pick_times, state)
    local rule, err = find_refresh_rule(refresh_id, pick_times)
    if not rule then
        return false, err
    end

    local pick_type = tostring(rule.Type or "common"):lower()
    if pick_type == "weapon" and not can_roll_weapon(build_pick_context(state)) then
        pick_type = "common"
    end

    local ctx = build_pick_context(state)
    local options = {}

    if pick_type == "weapon" then
        for _, args in ipairs({ rule.Args1, rule.Args2, rule.Args3 }) do
            local id = pick_from_args(args, "weapon", ctx)
            if id then
                options[#options + 1] = id
            end
        end
        fill_with_ability(options, ctx)
    elseif pick_type == "ability" then
        for _, args in ipairs({ rule.Args1, rule.Args2, rule.Args3 }) do
            local id = pick_from_args(args, "ability", ctx)
            if id then
                options[#options + 1] = id
            end
        end
    else
        while #options < 3 do
            local id = weighted_pick(collect_common_candidates(ctx), ctx)
            if not id then
                break
            end
            options[#options + 1] = id
        end
    end

    if #options == 0 then
        return false, "没有可刷新的能力"
    end
    return true, options
end

local function build_option_view(ability_id)
    local ability = get_ability(ability_id)
    if not ability then
        return nil
    end
    return {
        ability_id = num(ability.Id),
        name = ability.Name or "",
        icon = ability.Icon or "",
        quality = num(ability.Quality),
        type = tostring(ability.Type or ""),
        effect_id = num(ability.EffectId),
        weapon_id = num(ability.WeaponId),
    }
end

function InstanceRogue:on_join(player_id, data_)
    InstanceRogue.super.on_join(self, player_id, data_)
    self:init_rogue_state(data_ or self.args_.join_data or {})
end

function InstanceRogue:on_destroy()
    self.rogue_state_ = nil
    InstanceRogue.super.on_destroy(self)
end

function InstanceRogue:build_extra_data()
    local extra = InstanceRogue.super.build_extra_data(self)
    extra.rogue_sync = self:build_rogue_sync()
    return extra
end

function InstanceRogue:pack_extra_to_client()
    return tableUtils.serialize_table(self:build_extra_data()) or ""
end

function InstanceRogue:init_rogue_state(config)
    config = config or {}
    local energy_needs = config.energy_needs
    if type(energy_needs) ~= "table" or #energy_needs == 0 then
        energy_needs = ROGUE_DEF.DEFAULT_ENERGY_NEEDS
    end
    self.rogue_state_ = {
        refresh_id = num(config.rogue_refresh_id) > 0 and num(config.rogue_refresh_id) or ROGUE_DEF.DEFAULT_REFRESH_ID,
        energy_needs = energy_needs,
        energy_tier = 1,
        pick_times = 0, 
        lineup_weapon_ids = config.lineup_weapon_ids or {},
        unlocked_weapon_ids = config.unlocked_weapon_ids or {},
        weapon_levels = config.weapon_levels or {},
        owned_weapon_ids = {},
        owned_colors = {},
        picked = {},
        pending = nil,
    }
end

function InstanceRogue:get_rogue_max_picks()
    local state = self.rogue_state_
    if not state or type(state.energy_needs) ~= "table" then
        return 0
    end
    return #state.energy_needs
end

function InstanceRogue:can_rogue_open_pick()
    local state = self.rogue_state_
    if not state then
        return false, "肉鸽状态不存在"
    end
    if state.pending then
        return false, "已有待选择的能力"
    end
    local next_pick = num(state.pick_times) + 1
    if next_pick > self:get_rogue_max_picks() then
        return false, "本局三选一次数已满"
    end
    return true
end

local function build_option_list(option_ids)
    local options = {}
    for _, ability_id in ipairs(option_ids or {}) do
        local view = build_option_view(ability_id)
        if view then
            options[#options + 1] = view
        end
    end
    return options
end

function InstanceRogue:roll_rogue_options()
    local state = self.rogue_state_
    local next_pick = num(state.pick_times) + 1
    local ok, result = roll_three_options(state.refresh_id, next_pick, state)
    if not ok then
        return false, result
    end
    return true, {
        pick_index = next_pick,
        option_ids = result,
        options = build_option_list(result),
    }
end

function InstanceRogue:rogue_open_pick()
    local ok, err = self:can_rogue_open_pick()
    if not ok then
        return false, err
    end
    local roll_ok, roll_result = self:roll_rogue_options()
    if not roll_ok then
        return false, roll_result
    end
    local state = self.rogue_state_
    state.pending = {
        pick_index = roll_result.pick_index,
        option_ids = roll_result.option_ids,
        options = roll_result.options,
        selecting = false,
    }
    return true, {
        pick_index = roll_result.pick_index,
        options = roll_result.options,
    }
end

function InstanceRogue:rogue_refresh_pick()
    local state = self.rogue_state_
    if not state or not state.pending then
        return false, "没有待刷新选项"
    end
    if state.pending.selecting then
        return false, "选择处理中"
    end
    local roll_ok, roll_result = self:roll_rogue_options()
    if not roll_ok then
        return false, roll_result
    end
    state.pending = {
        pick_index = roll_result.pick_index,
        option_ids = roll_result.option_ids,
        options = roll_result.options,
        selecting = false,
    }
    return true, {
        pick_index = roll_result.pick_index,
        options = roll_result.options,
    }
end

local function track_weapon_gain(state, ability)
    if tostring(ability.Type or ""):lower() ~= "weapon" then
        return
    end
    local weapon_id = num(ability.WeaponId)
    if weapon_id <= 0 then
        return
    end
    local exists = false
    for _, wid in ipairs(state.owned_weapon_ids) do
        if num(wid) == weapon_id then
            exists = true
            break
        end
    end
    if not exists then
        state.owned_weapon_ids[#state.owned_weapon_ids + 1] = weapon_id
    end
    local wcfg = WEAPON_DATA[weapon_id]
    if wcfg and wcfg.Color then
        local color = tostring(wcfg.Color)
        local color_exists = false
        for _, c in ipairs(state.owned_colors) do
            if tostring(c) == color then
                color_exists = true
                break
            end
        end
        if not color_exists then
            state.owned_colors[#state.owned_colors + 1] = color
        end
    end
end

function InstanceRogue:apply_rogue_pick(ability_id)
    local state = self.rogue_state_
    ability_id = num(ability_id)
    state.picked[ability_id] = num(state.picked[ability_id]) + 1
    local ability = get_ability(ability_id)
    if ability then
        track_weapon_gain(state, ability)
    end
    state.pick_times = num(state.pick_times) + 1
    if state.energy_tier <= #state.energy_needs then
        state.energy_tier = state.energy_tier + 1
    end
end

function InstanceRogue:build_rogue_picked_list()
    local state = self.rogue_state_
    local list = {}
    for ability_id, count in pairs(state and state.picked or {}) do
        list[#list + 1] = {
            ability_id = num(ability_id),
            count = num(count),
        }
    end
    table.sort(list, function(a, b)
        return a.ability_id < b.ability_id
    end)
    return list
end

function InstanceRogue:build_rogue_sync()
    local state = self.rogue_state_
    if not state then
        return nil
    end
    local pending = nil
    if state.pending then
        pending = {
            pick_index = state.pending.pick_index,
            options = state.pending.options,
        }
    end
    return {
        refresh_id = state.refresh_id,
        energy_tier = state.energy_tier,
        pick_times = state.pick_times,
        max_picks = self:get_rogue_max_picks(),
        energy_needs = state.energy_needs,
        owned_weapon_ids = state.owned_weapon_ids,
        picked = self:build_rogue_picked_list(),
        pending = pending,
    }
end

function InstanceRogue:rogue_select_pick(choice_index)
    local state = self.rogue_state_
    choice_index = num(choice_index)
    if not state or not state.pending then
        return false, "没有待选择能力"
    end
    if state.pending.selecting then
        return false, "选择处理中"
    end
    local option_ids = state.pending.option_ids or {}
    local ability_id = num(option_ids[choice_index])
    if ability_id <= 0 then
        return false, "选择下标无效"
    end

    state.pending.selecting = true
    self:apply_rogue_pick(ability_id)
    local ability = get_ability(ability_id)
    state.pending = nil

    return true, {
        ability_id = ability_id,
        effect_id = ability and num(ability.EffectId) or 0,
        pick_times = state.pick_times,
        picked = self:build_rogue_picked_list(),
    }
end

return InstanceRogue
