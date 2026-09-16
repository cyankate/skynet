-- shard_service 共享 helper（纯函数，不挂状态，不进 CMD）
local service_ctx = require "runtime.service_ctx"

local ctx = service_ctx.get("map.shard_service", {})
local M = {}

function M.with_shard(map, payload)
    payload = payload or {}
    payload.map_id = payload.map_id or (map and map.map_id or 0)
    payload.shard_id = map and map.shard_id or 0
    return payload
end

function M.get_map(map_id)
    local map = ctx.map
    if not map then
        return nil
    end
    if map_id and tonumber(map_id) ~= 0 and tonumber(map_id) ~= map.map_id then
        return nil
    end
    return map
end

function M.get_or_init_player_state(player_id)
    local st = ctx.player_state[player_id]
    if st then
        return st
    end
    -- 纯视野状态：玩法锚点是主城实体（AOI 里的 building），不在这里存坐标
    st = {
        current_map_id = 0,
        current_scene_id = 0,
    }
    ctx.player_state[player_id] = st
    return st
end

function M.current_map(st)
    if not st or not st.current_map_id or st.current_map_id <= 0 then
        return nil
    end
    return M.get_map(st.current_map_id)
end

function M.get_players_in_map(map_id)
    local players = {}
    for player_id, st in pairs(ctx.player_state) do
        if st.current_map_id == map_id and st.current_scene_id > 0 then
            players[#players + 1] = player_id
        end
    end
    return players
end

return M
