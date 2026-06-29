--[[
    GM 指令：由 agent 在线玩家上下文执行，供 Web / 平台下发。
]]

local log = require "log"
local item_mgr = require "system.item_mgr"
local weapon_mgr = require "system.weapon_mgr"
local effect_mgr = require "system.effect_mgr"

local M = {}

local function num(v)
    return tonumber(v) or 0
end

local function ensure_loaded(player)
    if not player or not player.loaded_ then
        return false, "玩家未加载完成"
    end
    return true
end

local function normalize_items(raw)
    if type(raw) ~= "table" or not next(raw) then
        return nil, "items 无效"
    end
    local items = {}
    for item_id_raw, count_raw in pairs(raw) do
        local item_id = num(item_id_raw)
        local count = num(count_raw)
        if item_id > 0 and count > 0 then
            items[item_id] = count
        end
    end
    if not next(items) then
        return nil, "items 无效"
    end
    return items
end

local function cmd_add_items(player, args)
    local items, err = normalize_items(args.items)
    if not items then
        return false, err
    end
    local reason = tostring(args.reason or "gm_add_items")
    local ok, result = item_mgr.add_items(player, items, reason)
    if not ok then
        return false, result or "添加物品失败"
    end
    return true, {
        action = "add_items",
        player_id = player.player_id_,
        items = items,
        changes = result,
    }
end

local function cmd_activate_weapon(player, args)
    local weapon_id = num(args.weapon_id)
    if weapon_id <= 0 then
        return false, "weapon_id 无效"
    end
    local ok, err = weapon_mgr.activate_weapon(player, weapon_id)
    if not ok then
        return false, err or "激活武器失败"
    end
    weapon_mgr.sync_to_client(player)
    effect_mgr.sync_to_client(player)
    return true, {
        action = "activate_weapon",
        player_id = player.player_id_,
        weapon_id = weapon_id,
        unlocked = weapon_mgr.get_unlocked_weapon_ids(player),
    }
end

local COMMAND_HANDLERS = {
    add_items = cmd_add_items,
    activate_weapon = cmd_activate_weapon,
}

local COMMAND_META = {
    add_items = {
        label = "添加物品",
        desc = "给在线玩家发放背包道具",
        template = {
            action = "add_items",
            player_id = "",
            items = {
                ["802"] = "",
            },
        },
    },
    activate_weapon = {
        label = "激活武器",
        desc = "解锁玩家武器并同步客户端",
        template = {
            action = "activate_weapon",
            player_id = "",
            weapon_id = "",
        },
    },
}

function M.execute(player, action, args)
    action = tostring(action or "")
    if action == "" then
        return false, "action 无效"
    end
    local ok, err = ensure_loaded(player)
    if not ok then
        return false, err
    end
    local handler = COMMAND_HANDLERS[action]
    if not handler then
        return false, "未知 GM 指令: " .. action
    end
    args = type(args) == "table" and args or {}
    log.info("gm_mgr: player=%s action=%s", tostring(player.player_id_), action)
    return handler(player, args)
end

function M.list_templates()
    local list = {}
    for action, meta in pairs(COMMAND_META) do
        if COMMAND_HANDLERS[action] then
            list[#list + 1] = {
                action = action,
                label = meta.label or action,
                desc = meta.desc or "",
                template = meta.template,
            }
        end
    end
    table.sort(list, function(a, b)
        return tostring(a.action) < tostring(b.action)
    end)
    return list
end

return M
