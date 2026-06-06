--[[
    武器管理：虚拟武器道具（Type=0, SubType=1200）获得时不进背包，
    由 item_mgr 特殊处理器直接解锁对应武器（Args 内配置 weapon_id）。
]]

local log = require "log"
local protocol_handler = require "protocol_handler"
local ITEM_DATA = require "setting.ITEM_DATA"

local M = {
}

local function num(v)
    return math.floor(tonumber(v) or 0)
end

function M.activate_weapon(player, weapon_id)
    weapon_id = num(weapon_id)
    if weapon_id <= 0 then
        return false, "invalid weapon_id"
    end
    local ctn = player:get_ctn("common")
    if not ctn then
        return false, "common container not found"
    end
    if ctn:get_weapons()[weapon_id] then
        return true
    end
    ctn:set_weapon_unlocked(weapon_id)
    log.info("player %s unlock weapon %d", tostring(player.player_id_), weapon_id)
    return true
end

function M.get_unlocked_weapon_ids(player)
    local ctn = player:get_ctn("common")
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

function M.sync_to_client(player)
    if not player or not player.player_id_ then
        return false
    end
    protocol_handler.send_to_player(player.player_id_, "weapon_list_notify", {
        weapons = M.get_unlocked_weapon_ids(player),
    })
    return true
end

function M.has_weapon(player, weapon_id)
    local ctn = player:get_ctn("common")
    if not ctn then
        return false
    end
    return ctn:get_weapons()[num(weapon_id)] ~= nil
end

return M
