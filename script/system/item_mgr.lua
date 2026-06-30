local protocol_handler = require "protocol_handler"
local log = require "log"
local skynet = require "skynet"
local service_ctx = require "runtime.service_ctx"

local ITEM_DEF = require "define.item_def"
local ITEM_DATA = require "setting.ITEM_DATA"
local head_mgr = require "system.head_mgr"

local item_mgr = service_ctx.get("system.item_mgr", {})
item_mgr.virtual_add_handlers = item_mgr.virtual_add_handlers or {}
local virtual_add_handlers = item_mgr.virtual_add_handlers

local function num(v)
    return math.floor(tonumber(v) or 0)
end

local function get_cfg(item_id)
    return ITEM_DATA[num(item_id)]
end

local function is_virtual_item(item_id)
    local cfg = get_cfg(item_id)
    return cfg ~= nil and num(cfg.Type) == 0
end

local function get_virtual_subtype(item_id)
    local cfg = get_cfg(item_id)
    if not cfg then
        return nil
    end
    return cfg.SubType
end

local function is_weapon_item(item_id)
    local cfg = get_cfg(item_id)
    return cfg ~= nil and num(cfg.SubType) == ITEM_DEF.ITEM_SUB_TYPE.WEAPON
end 

local function get_count(player, item_id)
    if not get_cfg(item_id) then
        return 0
    end
    local bag = player:get_ctn("bag")
    if not bag then
        return 0
    end
    if is_virtual_item(item_id) then
        return num(bag:get_virtual_item_count(item_id))
    end
    return num(bag:get_item_count(item_id))
end

local function build_change(player, item_id, delta)
    return {
        item_id = item_id,
        delta = delta,
        count = get_count(player, item_id),
    }
end

local function merge_count(tbl, item_id, count)
    tbl[item_id] = (tbl[item_id] or 0) + count
end

local function analyze_add_items(items)
    local ctx = {
        all = {},
        real = {},
        virtual = {},
        special = {},
    }
    if type(items) ~= "table" then
        return ctx
    end

    for item_id_raw, count_raw in pairs(items) do
        local item_id = num(item_id_raw)
        local count = num(count_raw)
        if item_id > 0 and count > 0 then
            if not get_cfg(item_id) then
                return nil, string.format("物品配置不存在:%s", tostring(item_id))
            end
            merge_count(ctx.all, item_id, count)
            if is_virtual_item(item_id) then
                local sub_type = get_virtual_subtype(item_id)
                if sub_type and virtual_add_handlers[sub_type] then
                    merge_count(ctx.special, item_id, count)
                else
                    merge_count(ctx.virtual, item_id, count)
                end
            else
                merge_count(ctx.real, item_id, count)
            end
        end
    end
    return ctx
end

local function run_add_item_rules(ctx, player, ext)
    -- 规则处理预留点：整卡转碎片、重复转材料、溢出转换等
    local real_items = ctx.real
    local remove_items = {}
    local new_items = {}
    for item_id, count in pairs(real_items) do
        local cfg = get_cfg(item_id)
        if cfg.SubType == ITEM_DEF.ITEM_SUB_TYPE.GIFT and cfg.UseType == ITEM_DEF.ITEM_USE_TYPE.AUTO_OPEN then
            for i = 1, count do
                local items = reward_mgr.get_reward(cfg.Args[1])
                if items then 
                    remove_items[item_id] = (remove_items[item_id] or 0) + 1
                    for new_item_id, new_count in pairs(items) do
                        merge_count(new_items, new_item_id, new_count)
                    end
                end 
            end
        end 
    end

    -- 转换后合并进ctx
    for item_id, count in pairs(remove_items) do 
        ctx.real[item_id] = (ctx.real[item_id] or 0) - count
    end 
    for item_id, count in pairs(new_items) do 
        local cfg = get_cfg(item_id)
        if is_virtual_item(item_id) then
            local sub_type = get_virtual_subtype(item_id)
            if sub_type and virtual_add_handlers[sub_type] then
                merge_count(ctx.special, item_id, count)
            else
                merge_count(ctx.virtual, item_id, count)
            end
        else
            merge_count(ctx.real, item_id, count)
        end
    end 
    return ctx
end

local function precheck_add_items(ctx, player, ext)
    local bag = player:get_ctn("bag")
    if not bag then
        return false, "背包不存在"
    end
    if next(ctx.real) then
        local ok, err = bag:can_add_items(ctx.real)
        if not ok then
            return false, err or "背包空间不足"
        end
    end
    return true
end

local function apply_add_items(ctx, player, reason, ext)
    local bag = player:get_ctn("bag")
    if not bag then
        return false, "背包不存在"
    end

    local changes = {}
    local items = {}
    for item_id, count in pairs(ctx.special) do
        local sub_type = get_virtual_subtype(item_id)
        local add_handler = sub_type and virtual_add_handlers[sub_type]
        if not add_handler then
            return false, "虚拟道具处理器不存在"
        end
        local h_ok, need_add_to_virtual = add_handler(player, item_id, count, ext)
        if not h_ok then
            return false, need_add_to_virtual or "虚拟道具添加失败"
        end
        if need_add_to_virtual then
            bag:set_virtual_item_count(item_id, num(bag:get_virtual_item_count(item_id)) + count)
            items[item_id] = (items[item_id] or 0) + count 
        end
    end

    for item_id, count in pairs(ctx.virtual) do
        bag:set_virtual_item_count(item_id, num(bag:get_virtual_item_count(item_id)) + count)
        items[item_id] = (items[item_id] or 0) + count 
    end

    for item_id, count in pairs(ctx.real) do
        local add_ok, add_err = bag:add_item(item_id, count)
        if not add_ok then
            return false, add_err or "背包添加失败"
        end
        items[item_id] = (items[item_id] or 0) + count 
    end
    local changes = {}
    for k, v in pairs(items) do 
        table.insert(changes, build_change(player, k, v))
    end 
    protocol_handler.send_to_player(player.player_id_, "item_update_notify", {
        reason = reason or "add",
        changes = changes,
    })
    local tips = ext.tips 
    if ext.reward_id then 
        local cfg = REWARD_DATA[ext.reward_id]
        if cfg.ShowType == 1 then 
            tips = ITEM_DEF.TIPS.POPUP
        elseif cfg.ShowType == 0 then 
            tips = ITEM_DEF.TIPS.TICKER
        end 
    end 
    if tips then 
        local item_list = {}
        for k, v in pairs(items) do
            table.insert(item_list, {item_id = k, count = v})
        end 
        protocol_handler.send_to_player(player.player_id_, "show_item_tips", {
            tips = tips,
            items = item_list,
        })
    end 
    return true, changes
end

function item_mgr.can_add_items(player, items, ext)
    local ctx, err = analyze_add_items(items)
    if not ctx then
        return false, err
    end
    if not next(ctx.real) then
        return true
    end
    local bag = player:get_ctn("bag")
    if not bag then
        return false, "背包不存在"
    end
    return bag:can_add_items(ctx.real)
end

function item_mgr.has_enough_items(player, items, ext)
    if type(items) ~= "table" then
        return true
    end
    for item_id_raw, count_raw in pairs(items) do
        local item_id = num(item_id_raw)
        local count = num(count_raw)
        if item_id > 0 and count > 0 then
            if not get_cfg(item_id) then
                return false, string.format("物品配置不存在:%s", tostring(item_id))
            end
            local bag = player:get_ctn("bag")
            if not bag then
                return false, "背包不存在"
            end
            if is_virtual_item(item_id) then
                if num(bag:get_virtual_item_count(item_id)) < count then
                    return false, "虚拟道具不足"
                end
            elseif not bag:has_enough_items(item_id, count) then
                return false, "背包道具不足"
            end
        end
    end
    return true
end

function item_mgr.add_items(player, items, reason, ext)
    local ctx, analyze_err = analyze_add_items(items)
    if not ctx then
        return false, analyze_err
    end
    ctx = run_add_item_rules(ctx, player, ext)
    local pre_ok, pre_err = precheck_add_items(ctx, player, ext)
    if not pre_ok then
        return false, pre_err
    end
    return apply_add_items(ctx, player, reason, ext)
end

function item_mgr.cost_items(player, items, reason, ext)
    local ok, err = item_mgr.has_enough_items(player, items, ext)
    if not ok then
        return false, err
    end

    if type(items) ~= "table" then
        items = {}
    end
    local changes = {}
    local bag = player:get_ctn("bag")
    if not bag then
        return false, "背包不存在"
    end

    for item_id_raw, count_raw in pairs(items) do
        local item_id = num(item_id_raw)
        local count = num(count_raw)
        if item_id > 0 and count > 0 then
            if not get_cfg(item_id) then
                return false, string.format("物品配置不存在:%s", tostring(item_id))
            end
            if is_virtual_item(item_id) then
                bag:set_virtual_item_count(item_id, num(bag:get_virtual_item_count(item_id)) - count)
            else
                local cost_ok, cost_err = bag:cost_item(item_id, count)
                if not cost_ok then
                    return false, cost_err
                end
            end
            table.insert(changes, build_change(player, item_id, -count))
        end
    end

    protocol_handler.send_to_player(player.player_id_, "item_update_notify", {
        reason = reason or "cost",
        changes = changes,
    })
    return true, changes
end

function item_mgr.get_item_count(player, item_id)
    if not get_cfg(item_id) then
        return 0
    end
    return get_count(player, item_id)
end

function item_mgr.build_item_list(player)
    local bag = player:get_ctn("bag")
    if not bag then
        return {}
    end

    local tally = {}
    for _, item in pairs(bag.slots_ or {}) do
        local item_id = num(item.item_id)
        local count = num(item.count)
        if item_id > 0 and count > 0 then
            tally[item_id] = (tally[item_id] or 0) + count
        end
    end
    for item_id_raw, count_raw in pairs(bag.virtual_items_ or {}) do
        local item_id = num(item_id_raw)
        local count = num(count_raw)
        if item_id > 0 and count > 0 then
            tally[item_id] = (tally[item_id] or 0) + count
        end
    end

    local items = {}
    for item_id, count in pairs(tally) do
        table.insert(items, { item_id = item_id, count = count })
    end
    return items
end

function item_mgr.sync_bag_list_to_client(player)
    if not player or not player.player_id_ then
        return false
    end
    protocol_handler.send_to_player(player.player_id_, "bag_item_list_notify", {
        items = item_mgr.build_item_list(player),
    })
    return true
end

virtual_add_handlers[ITEM_DEF.ITEM_SUB_TYPE.GUILD_POINT] = function(player, item_id, count, ext)
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "guild服务不可用"
    end
    local ok, msg = skynet.call(guildS, "lua", "add_player_guild_point", player.player_id_, num(count))
    if not ok then
        return false, msg or "公会积分添加失败"
    end
    return true, false
end

virtual_add_handlers[ITEM_DEF.ITEM_SUB_TYPE.HEAD_EXP] = function(player, item_id, count, ext)
    local ok, result = head_mgr.add_head_exp(player, num(count))
    if not ok then
        return false, result or "车头经验添加失败"
    end
    return true, false
end

virtual_add_handlers[ITEM_DEF.ITEM_SUB_TYPE.WEAPON] = function(player, item_id, count, ext)
    local weapon_id = num(ext.weapon_id)
    if weapon_id <= 0 then
        return false, "武器id不存在"
    end
    local weapon_cfg = WEAPON_DATA[weapon_id]
    if not weapon_cfg then
        return false, "武器配置不存在"
    end
    local cfg = get_cfg(item_id)
    weapon_mgr.activate_weapon(player, cfg.Args[1])
    return true, false
end

return item_mgr
