--[[
    单人肉鸽副本：继承 InstanceSingle，内聚三选一随机与局内状态机。
]]

local class = require "utils.class"
local InstanceSingle = require "instance.types.instance_single"
local ROGUE_ABILITY_DATA = require "setting.ROGUE_ABILITY_DATA"
local ROGUE_REFRESH_DATA = require "setting.ROGUE_REFRESH_DATA"
local WEAPON_DATA = require "setting.WEAPON_DATA"
local INSTANCE_DATA = require "setting.INSTANCE_DATA"
local tableUtils = require "utils.tableUtils"
local ROGUE_DEF = require "instance.rogue.rogue_def"
local effect_mgr = require "system.effect_mgr"

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

local function build_pick_context(inst)
    local player_pack = inst.player_pack_ or {}
    local effects = inst.effects_
    local weapon_levels = player_pack.weapon_levels or {}
    local lineup = {}
    local unlocked = {}
    for weapon_id, _ in pairs(weapon_levels) do
        weapon_id = num(weapon_id)
        if weapon_id > 0 then
            lineup[weapon_id] = true
            unlocked[weapon_id] = true
        end
    end
    for _, wid in ipairs(effects and effects:get_effect_unlock_weapon_ids() or {}) do
        unlocked[num(wid)] = true
    end
    local owned_weapons = {}
    for _, wid in ipairs(inst.owned_weapon_ids_ or {}) do
        owned_weapons[num(wid)] = true
    end
    local owned_colors = {}
    for _, color in ipairs(inst.owned_colors_ or {}) do
        owned_colors[tostring(color)] = true
    end
    return {
        lineup = lineup,
        unlocked = unlocked,
        owned_weapons = owned_weapons,
        owned_colors = owned_colors,
        picked = inst.picked_ or {},
        weapon_levels = weapon_levels,
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
    refresh_id = num(refresh_id)
    if refresh_id <= 0 then
        return nil, "肉鸽刷新id未配置"
    end
    local group = ROGUE_REFRESH_DATA[refresh_id]
    if type(group) ~= "table" then
        return nil, string.format("肉鸽刷新配置不存在: refresh_id=%d", refresh_id)
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

local function roll_three_options(inst, pick_times)
    local refresh_id = num(inst.refresh_id_)
    local rule, err = find_refresh_rule(refresh_id, pick_times)
    if not rule then
        return false, err
    end

    local pick_type = tostring(rule.Type or "common"):lower()
    if pick_type == "weapon" and not can_roll_weapon(build_pick_context(inst)) then
        pick_type = "common"
    end

    local ctx = build_pick_context(inst)
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

local function normalize_energy_needs(raw)
    if type(raw) ~= "table" or #raw == 0 then
        return nil
    end
    local list = {}
    for i = 1, #raw do
        list[i] = num(raw[i])
    end
    return list
end

local function get_instance_rogue_cfg(inst_no)
    inst_no = num(inst_no)
    local cfg = INSTANCE_DATA[inst_no]
    if not cfg then
        return nil, "副本配置不存在"
    end
    local refresh_id = num(cfg.RogueRefreshId)
    if refresh_id <= 0 then
        return nil, "肉鸽刷新id未配置"
    end
    if not ROGUE_REFRESH_DATA[refresh_id] then
        return nil, string.format("肉鸽刷新配置不存在: refresh_id=%d", refresh_id)
    end
    return cfg, refresh_id
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

function InstanceRogue:on_join(player_id, data_)
    InstanceRogue.super.on_join(self, player_id, data_)
    self:init_rogue(data_ or self.args_.join_data or {})
end

function InstanceRogue:on_destroy()
    self.player_pack_ = nil
    self.effects_ = nil
    self.refresh_id_ = nil
    self.energy_needs_ = nil
    self.energy_tier_ = nil
    self.pick_times_ = nil
    self.picked_ = nil
    self.owned_weapon_ids_ = nil
    self.owned_colors_ = nil
    self.pending_pick_ = nil
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

function InstanceRogue:init_rogue(player_pack)
    player_pack = type(player_pack) == "table" and player_pack or {}
    self.player_pack_ = player_pack
    self.effects_ = effect_mgr.from_pack(player_pack)

    local inst_no = num(self.inst_no_)
    local cfg, refresh_id = get_instance_rogue_cfg(inst_no)
    if not cfg then
        refresh_id = 0
    end
    local energy_needs = cfg and normalize_energy_needs(cfg.SelectNeedEnergy)
    if not energy_needs then
        energy_needs = ROGUE_DEF.DEFAULT_ENERGY_NEEDS
    end

    self.refresh_id_ = refresh_id
    self.energy_needs_ = energy_needs
    self.energy_tier_ = 1
    self.pick_times_ = 0
    self.owned_weapon_ids_ = {}
    self.owned_colors_ = {}
    self.picked_ = {}
    self.pending_pick_ = nil
end

function InstanceRogue:get_effects()
    return self.effects_
end

function InstanceRogue:get_rogue_max_picks()
    if type(self.energy_needs_) ~= "table" then
        return 0
    end
    return #self.energy_needs_
end

function InstanceRogue:can_rogue_open_pick()
    if num(self.refresh_id_) <= 0 then
        return false, "肉鸽刷新id未配置"
    end
    if self.pending_pick_ then
        return false, "已有待选择的能力"
    end
    local next_pick = num(self.pick_times_) + 1
    if next_pick > self:get_rogue_max_picks() then
        return false, "本局三选一次数已满"
    end
    return true
end

function InstanceRogue:roll_rogue_options()
    local next_pick = num(self.pick_times_) + 1
    local ok, result = roll_three_options(self, next_pick)
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
    self.pending_pick_ = {
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
    if not self.pending_pick_ then
        return false, "没有待刷新选项"
    end
    if self.pending_pick_.selecting then
        return false, "选择处理中"
    end
    local roll_ok, roll_result = self:roll_rogue_options()
    if not roll_ok then
        return false, roll_result
    end
    self.pending_pick_ = {
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

function InstanceRogue:track_weapon_gain(ability)
    if tostring(ability.Type or ""):lower() ~= "weapon" then
        return
    end
    local weapon_id = num(ability.WeaponId)
    if weapon_id <= 0 then
        return
    end
    self.owned_weapon_ids_ = self.owned_weapon_ids_ or {}
    local exists = false
    for _, wid in ipairs(self.owned_weapon_ids_) do
        if num(wid) == weapon_id then
            exists = true
            break
        end
    end
    if not exists then
        self.owned_weapon_ids_[#self.owned_weapon_ids_ + 1] = weapon_id
    end
    local wcfg = WEAPON_DATA[weapon_id]
    if wcfg and wcfg.Color then
        self.owned_colors_ = self.owned_colors_ or {}
        local color = tostring(wcfg.Color)
        local color_exists = false
        for _, c in ipairs(self.owned_colors_) do
            if tostring(c) == color then
                color_exists = true
                break
            end
        end
        if not color_exists then
            self.owned_colors_[#self.owned_colors_ + 1] = color
        end
    end
end

function InstanceRogue:apply_rogue_pick(ability_id)
    ability_id = num(ability_id)
    self.picked_[ability_id] = num(self.picked_[ability_id]) + 1
    local ability = get_ability(ability_id)
    if ability then
        self:track_weapon_gain(ability)
        local effect_id = num(ability.EffectId)
        if effect_id > 0 and self.effects_ then
            self.effects_:add_effect_id(effect_id)
        end
    end
    self.pick_times_ = num(self.pick_times_) + 1
    if num(self.energy_tier_) <= #self.energy_needs_ then
        self.energy_tier_ = num(self.energy_tier_) + 1
    end
end

function InstanceRogue:build_rogue_picked_list()
    local list = {}
    for ability_id, count in pairs(self.picked_ or {}) do
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
    if type(self.picked_) ~= "table" then
        return nil
    end
    local pending = nil
    if self.pending_pick_ then
        pending = {
            pick_index = self.pending_pick_.pick_index,
            options = self.pending_pick_.options,
        }
    end
    return {
        refresh_id = num(self.refresh_id_),
        energy_tier = num(self.energy_tier_),
        pick_times = num(self.pick_times_),
        max_picks = self:get_rogue_max_picks(),
        owned_weapon_ids = self.owned_weapon_ids_,
        effects = self.effects_ and self.effects_:build_sync() or nil,
        picked = self:build_rogue_picked_list(),
        pending = pending,
    }
end

function InstanceRogue:rogue_select_pick(choice_index)
    choice_index = num(choice_index)
    if not self.pending_pick_ then
        return false, "没有待选择能力"
    end
    if self.pending_pick_.selecting then
        return false, "选择处理中"
    end
    local option_ids = self.pending_pick_.option_ids or {}
    local ability_id = num(option_ids[choice_index])
    if ability_id <= 0 then
        return false, "选择下标无效"
    end

    self.pending_pick_.selecting = true
    self:apply_rogue_pick(ability_id)
    local ability = get_ability(ability_id)
    self.pending_pick_ = nil

    return true, {
        ability_id = ability_id,
        effect_id = ability and num(ability.EffectId) or 0,
        pick_times = num(self.pick_times_),
        picked = self:build_rogue_picked_list(),
    }
end

return InstanceRogue
