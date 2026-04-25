local protocol_handler = require "protocol_handler"
local TILENT_DATA = require "setting.tilent_data"
local item_mgr = require "system.item_mgr"
local M = {}

function M.activate_tilent(player, tilent_id)
    local ctn = player:get_ctn("common")
    local cfg = TILENT_DATA[tilent_id]
    if not cfg then
        return false, "天赋配置不存在"
    end
    local activated = ctn:get_tilents()
    if activated[tilent_id] then
        return false, "天赋已点亮"
    end
    for _, v in pairs(cfg.pre_tilents) do 
        if not activated[v] then
            return false, "前置天赋未点亮"
        end
    end
    local cost = cfg.cost
    local ok, err = item_mgr.cost_items(player, cost, "activate_tilent")
    if not ok then
        return false, err
    end
    ctn:set_tilent_activated(tilent_id)
    return true, {
        tilent_id = tilent_id,
    }
end
 
function M.sync_to_client(player)
    local ctn = player:get_ctn("common")
    local activated = ctn:get_tilents()
    local data = {
        tilents = {},
    }
    for tilent_id, _ in pairs(activated) do
        table.insert(data.tilents, tilent_id)
    end
    protocol_handler.send_to_player(player.player_id_, "tilent_info_notify", data)
    return true
end

return M
