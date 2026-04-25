local protocol_handler = require "protocol_handler"
local TILENT_DATA = require "setting.tilent_data"

local M = {}

function M.activate_tilent(player, tilent_id)
    local ctn = player:get_ctn("tilent")
    if not ctn then
        return false, "天赋容器不存在"
    end
    local cfg = TILENT_DATA[tilent_id]
    if not cfg then
        return false, "天赋配置不存在"
    end
    local activated = ctn:get_activated()
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
    activated[tilent_id] = 1
    ctn:set_activated(activated)
    return true, {
        tilent_id = tilent_id,
    }
end

function M.sync_to_client(player)
    local ctn = player:get_ctn("tilent")
    if not ctn then
        return false, "天赋容器不存在"
    end
    local activated = ctn:get_activated()
    protocol_handler.send_to_player(player.player_id_, "tilent_info_notify", {
        activated = activated,
    })
    return true
end

return M
