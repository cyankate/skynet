local skynet = require "skynet"
local log = require "log"
local tableUtils = require "utils.tableUtils"

local M = {}

local player_map = {}

function M.add_player_obj(_player_id, _player_obj)
    if player_map[_player_id] then
        log.error(string.format("player_id %s already exists", _player_id))
        return false
    end
    player_map[_player_id] = _player_obj
    return true
end 

function M.get_player_obj(_player_id)
    return player_map[_player_id]
end

function M.del_player_obj(_player_id)
    if not player_map[_player_id] then
        log.error(string.format("player_id %s not found", _player_id))
        return false
    end
    player_map[_player_id] = nil
    return true
end

return M