--[[
    武器管理：虚拟武器道具（Type=0, SubType=1200）获得时不进背包，
    由 item_mgr 特殊处理器直接解锁对应武器（Args 内配置 weapon_id）。
]]

local log = require "log"
local ITEM_DATA = require "setting.ITEM_DATA"

local M = {
    VIRTUAL_SUB_TYPE = 1200,
}

local function num(v)
    return math.floor(tonumber(v) or 0)
end

local function get_item_cfg(item_id)
    return ITEM_DATA[num(item_id)]
end

local function parse_weapon_id_from_item(cfg)
    local args = cfg.Args or cfg.args
    if type(args) ~= "table" then
        return nil
    end
    for _, v in pairs(args) do
        if type(v) == "table" then
            local wid = v[1] or v.weapon_id or v.WeaponId
            if wid then
                return num(wid)
            end
        end
    end
    return nil
end

function M.is_weapon_item(item_id)
    local cfg = get_item_cfg(item_id)
    if not cfg then
        return false
    end
    local sub = cfg.subType or cfg.sub_type or cfg.SubType
    return num(sub) == M.VIRTUAL_SUB_TYPE
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

function M.has_weapon(player, weapon_id)
    local ctn = player:get_ctn("common")
    if not ctn then
        return false
    end
    return ctn:get_weapons()[num(weapon_id)] ~= nil
end

--- item_mgr 虚拟道具处理器：成功且不写入背包 virtual_items
function M.on_virtual_weapon_item(player, item_id, count, ext)
    local cfg = get_item_cfg(item_id)
    if not cfg then
        return false, "item cfg not found"
    end
    local weapon_id = parse_weapon_id_from_item(cfg)
    if weapon_id <= 0 then
        return false, "weapon id missing in item args"
    end
    local n = num(count)
    if n <= 0 then
        return false, "invalid count"
    end
    for _ = 1, n do
        local ok, err = M.activate_weapon(player, weapon_id)
        if not ok then
            return false, err
        end
    end
    return true, false
end

local item_mgr = require "system.item_mgr"
item_mgr.virtual_add_handlers[M.VIRTUAL_SUB_TYPE] = M.on_virtual_weapon_item

return M
