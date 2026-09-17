-- 大地图占格：建筑（主城）写入全局寻路障碍。行军不占格。
local skynet = require "skynet"
local log = require "log"
local aoi_object = require "map.aoi_object"
local MapPath = require "map.pathfinding"

local M = {}
local NAME = ".pathfinding"

local function addr()
    return skynet.localname(NAME)
end

function M.blocks(obj)
    return obj and obj.type == aoi_object.TYPE.BUILDING and not obj.is_ghost
end

function M.radius_of(obj)
    return MapPath.CITY_BLOCK_RADIUS
end

function M.set(obj)
    if not M.blocks(obj) then
        return
    end
    local a = addr()
    if not a then
        log.warning("pathfinding unavailable, skip blocker uid=%s", tostring(obj.uid))
        return
    end
    local ok, err = skynet.call(a, "lua", "set_blocker", obj.map_id, obj.uid, obj.x, obj.y, M.radius_of(obj))
    if not ok then
        log.error("set_blocker failed uid=%s err=%s", tostring(obj.uid), tostring(err))
    end
end

function M.clear(obj)
    if not M.blocks(obj) then
        return
    end
    local a = addr()
    if not a then
        return
    end
    skynet.call(a, "lua", "clear_blocker", obj.map_id, obj.uid)
end

function M.pick_city(map)
    if not map then
        return nil, "map not found"
    end
    local a = addr()
    if not a then
        log.warning("pathfinding unavailable, city spawn fallback random")
        return map:rand_spawn()
    end
    local ok, result = skynet.call(a, "lua", "pick_city_spawn", map.map_id, map.shard_id)
    if ok and type(result) == "table" then
        return tonumber(result.x), tonumber(result.y)
    end
    return nil, result or "没有空地建城"
end

return M
