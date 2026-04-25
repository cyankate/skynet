local protocol_handler = require "protocol_handler"
local log = require "log"
local skynet = require "skynet"

local ITEM_DATA = require "setting.item_data"

local item_mgr = {}

local virtual_add_handlers = {}

local function to_int(v, default_v)
    local n = tonumber(v)
    if not n then
        return default_v or 0
    end
    return math.floor(n)
end

local function get_cfg(item_id)
    return ITEM_DATA[to_int(item_id, 0)]
end

local function is_virtual_item(cfg)
    return cfg and to_int(cfg.type, -1) == 0
end

local function get_virtual_subtype(cfg)
    return cfg and (cfg.subType or cfg.sub_type) or nil
end

local function get_count(player, item_id)
    local cfg = get_cfg(item_id)
    if not cfg then
        return 0
    end
    if is_virtual_item(cfg) then
        local bag = player:get_ctn("bag")
        if not bag then
            return 0
        end
        return to_int(bag:get_virtual_item_count(item_id), 0)
    end
    local bag = player:get_ctn("bag")
    if not bag then
        return 0
    end
    return to_int(bag:get_item_count(item_id), 0)
end

local function build_change(player, item_id, delta)
    return {
        item_id = item_id,
        delta = delta,
        count = get_count(player, item_id),
    }
end

local function analyze_add_items(items)
    local ctx = {
        all = {},
        real = {},
        virtual = {},
        special_virtual = {},
    }
    if type(items) ~= "table" then
        return ctx
    end

    for item_id_raw, count_raw in pairs(items) do
        local item_id = to_int(item_id_raw, 0)
        local count = to_int(count_raw, 0)
        if item_id > 0 and count > 0 then
            local cfg = get_cfg(item_id)
            if not cfg then
                return nil, string.format("物品配置不存在:%s", tostring(item_id))
            end
            local entry = {
                item_id = item_id,
                count = count,
                cfg = cfg,
                is_virtual = is_virtual_item(cfg),
                sub_type = get_virtual_subtype(cfg),
            }
            table.insert(ctx.all, entry)
            if entry.is_virtual then
                local add_handler = entry.sub_type and virtual_add_handlers[entry.sub_type] or nil
                if add_handler then
                    table.insert(ctx.special_virtual, entry)
                else
                    table.insert(ctx.virtual, entry)
                end
            else
                table.insert(ctx.real, entry)
            end
        end
    end
    return ctx
end

local function run_add_item_rules(ctx, player, ext)
    -- 规则处理预留点：
    -- 可在这里做“整卡转碎片、重复转材料、溢出转换”等二次加工
    -- 当前版本保持透传，不修改 ctx
    return ctx
end

local function precheck_add_items(ctx, player, ext)
    local bag = player:get_ctn("bag")
    if not bag then
        return false, "背包不存在"
    end

    -- 规则二次加工后重新校验实体道具可加入性，避免执行期失败
    if #ctx.real > 0 then
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

    for _, entry in ipairs(ctx.special_virtual) do
        local add_handler = virtual_add_handlers[entry.sub_type]
        local h_ok, need_add_to_virtual = add_handler(player, entry.item_id, entry.count, ext)
        if not h_ok then
            return false, need_add_to_virtual or "虚拟道具添加失败"
        end
        if need_add_to_virtual then
            local old = to_int(bag:get_virtual_item_count(entry.item_id), 0)
            bag:set_virtual_item_count(entry.item_id, old + entry.count)
            table.insert(changes, build_change(player, entry.item_id, entry.count))
        end
    end

    for _, entry in ipairs(ctx.virtual) do
        local old = to_int(bag:get_virtual_item_count(entry.item_id), 0)
        bag:set_virtual_item_count(entry.item_id, old + entry.count)
        table.insert(changes, build_change(player, entry.item_id, entry.count))
    end

    for _, entry in ipairs(ctx.real) do
        local add_ok, add_err = bag:add_item(entry.item_id, entry.count)
        if not add_ok then
            return false, add_err or "背包添加失败"
        end
        table.insert(changes, build_change(player, entry.item_id, entry.count))
    end

    protocol_handler.send_to_player(player.player_id_, "item_update_notify", {
        reason = reason or "add",
        changes = changes,
    })
    return true, changes
end

function item_mgr.can_add_items(player, items, ext)
    local ctx, err = analyze_add_items(items)
    if not ctx then
        return false, err
    end
    if #ctx.real > 0 then
        local bag = player:get_ctn("bag")
        if not bag then
            return false, "背包不存在"
        end
        return bag:can_add_items(ctx.real)
    end
    return true
end

function item_mgr.has_enough_items(player, items, ext)
    if type(items) ~= "table" then
        return true
    end
    for item_id_raw, count_raw in pairs(items) do
        local item_id = to_int(item_id_raw, 0)
        local count = to_int(count_raw, 0)
        if item_id <= 0 or count <= 0 then
            goto continue
        end
        local cfg = get_cfg(item_id)
        if not cfg then
            return false, string.format("物品配置不存在:%s", tostring(item_id))
        end
        if is_virtual_item(cfg) then
            local bag = player:get_ctn("bag")
            if not bag then
                return false, "背包不存在"
            end
            local own = to_int(bag:get_virtual_item_count(item_id), 0)
            if own < count then
                return false, "虚拟道具不足"
            end
        else
            local bag = player:get_ctn("bag")
            if not bag or not bag:has_enough_items(item_id, count) then
                return false, "背包道具不足"
            end
        end
        ::continue::
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
    for item_id_raw, count_raw in pairs(items) do
        local item_id = to_int(item_id_raw, 0)
        local count = to_int(count_raw, 0)
        if item_id <= 0 or count <= 0 then
            goto continue
        end
        local cfg = get_cfg(item_id)
        if not cfg then
            return false, string.format("物品配置不存在:%s", tostring(item_id))
        end
        if is_virtual_item(cfg) then
            local bag = player:get_ctn("bag")
            if not bag then
                return false, "背包不存在"
            end
            local old = to_int(bag:get_virtual_item_count(item_id), 0)
            bag:set_virtual_item_count(item_id, old - count)
        else
            local bag = player:get_ctn("bag")
            local cost_ok, cost_err = bag:cost_item(item_id, count)
            if not cost_ok then
                return false, cost_err
            end
        end
        table.insert(changes, build_change(player, item_id, -count))
        ::continue::
    end

    protocol_handler.send_to_player(player.player_id_, "item_update_notify", {
        reason = reason or "cost",
        changes = changes,
    })
    return true, changes
end

function item_mgr.get_item_count(player, item_id)
    local cfg = get_cfg(item_id)
    if not cfg then
        return 0
    end
    return get_count(player, item_id)
end

virtual_add_handlers = {
    guild_point = function(player, item_id, count, ext)
        local guildS = skynet.localname(".guild")
        if not guildS then
            return false, "guild服务不可用"
        end
        local ok, msg = skynet.call(guildS, "lua", "add_player_guild_point", player.player_id_, tonumber(count) or 0)
        if not ok then
            return false, msg or "公会积分添加失败"
        end
        return true, false
    end,
}

return item_mgr
