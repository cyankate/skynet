local skynet = require "skynet"
local log = require "log"
local chunk = require "map.chunk"
local service_ctx = require "runtime.service_ctx"

-- 地图世界权威冷库（格子上的、不属于某个玩家的数据）。
-- 玩家坐标 / 迷雾 / 私有怪物不进这里。
local M = {}

local COLLECTION = "map_entity"
M.TYPE_RESOURCE = "resource"
M.TYPE_MONSTER = "monster"
M.TYPE_META = "meta"
-- 兼容旧常量名
M.TYPE_ITEM = M.TYPE_RESOURCE

local TOP_KEYS = {
    _id = true,
    map_id = true,
    chunk_id = true,
    type = true,
    x = true,
    y = true,
    owner_player_id = true,
    alliance_id = true,
    version = true,
}

local RUNTIME_KEYS = {
    in_aoi = true,
    id = true,
    view_range = true,
    is_ghost = true,
    owner_shard_id = true,
    _aoi_x = true,
    _aoi_y = true,
}

local ctx = service_ctx.get("map.map_store", {})
ctx.dirty = ctx.dirty or {}
local dirty = ctx.dirty

local function get_mongo()
    return skynet.localname(".mongo")
end

function M.make_id(map_id, etype, uid)
    return string.format("%s:%s:%s", tostring(map_id), tostring(etype), tostring(uid))
end

function M.obj_type(obj)
    return (obj and obj.type) or M.TYPE_RESOURCE
end

function M.entity_type(obj)
    return M.obj_type(obj)
end

function M.to_doc(obj)
    local otype = M.obj_type(obj)
    local uid = obj.uid
    obj.type = otype
    obj._id = obj._id or M.make_id(obj.map_id, otype, uid)
    if otype == M.TYPE_META then
        obj.chunk_id = obj.chunk_id or 0
        obj.x = obj.x or 0
        obj.y = obj.y or 0
    elseif not obj.chunk_id then
        obj.chunk_id = chunk.from_pos(obj.x, obj.y)
    end
    local data = {}
    for k, v in pairs(obj) do
        if not TOP_KEYS[k] and not RUNTIME_KEYS[k] then
            data[k] = v
        end
    end
    data.uid = uid
    if obj.alive ~= nil then
        data.alive = obj.alive and true or false
    end
    return {
        _id = obj._id,
        map_id = obj.map_id,
        chunk_id = obj.chunk_id or 0,
        type = otype,
        x = obj.x or 0,
        y = obj.y or 0,
        owner_id = obj.owner_player_id or 0,
        alliance_id = obj.alliance_id or 0,
        version = obj.version or 1,
        updated_at = os.time(),
        data = data,
    }
end

function M.from_doc(doc)
    local obj = {
        _id = doc._id,
        map_id = doc.map_id,
        chunk_id = doc.chunk_id,
        type = doc.type,
        x = doc.x,
        y = doc.y,
        owner_player_id = doc.owner_id or 0,
        alliance_id = doc.alliance_id or 0,
        version = doc.version or 1,
        view_range = 0,
        is_ghost = false,
        in_aoi = false,
    }
    for k, v in pairs(doc.data or {}) do
        obj[k] = v
    end
    if obj.alive ~= nil then
        obj.alive = obj.alive ~= false
    end
    -- 旧库 item → resource
    if obj.type == "item" then
        obj.type = M.TYPE_RESOURCE
    end
    obj.id = obj.uid
    return obj
end

local function build_query(map_id, etype, chunk_ids)
    local query = {
        map_id = map_id,
        type = etype,
    }
    if type(chunk_ids) == "table" then
        query.chunk_id = { ["$in"] = chunk_ids }
    end
    return query
end

function M.count(map_id, etype, chunk_ids)
    local mongo = get_mongo()
    if not mongo then
        return nil, "mongo unavailable"
    end
    return skynet.call(mongo, "lua", "count", COLLECTION, build_query(map_id, etype, chunk_ids))
end

function M.load(map_id, etype, chunk_ids)
    local mongo = get_mongo()
    if not mongo then
        return nil, "mongo unavailable"
    end
    local docs, err
    if type(chunk_ids) == "table" then
        docs, err = skynet.call(mongo, "lua", "find_by_chunk", COLLECTION, map_id, chunk_ids, {
            type = etype,
        }, { limit = 5000 })
    else
        docs, err = skynet.call(mongo, "lua", "find", COLLECTION, build_query(map_id, etype), {
            limit = 5000,
        })
    end
    if err then
        return nil, err
    end
    local list = {}
    for _, doc in ipairs(docs or {}) do
        list[#list + 1] = M.from_doc(doc)
    end
    return list
end

function M.insert(objs)
    local mongo = get_mongo()
    if not mongo then
        return false, "mongo unavailable"
    end
    local docs = {}
    for _, obj in ipairs(objs) do
        docs[#docs + 1] = M.to_doc(obj)
    end
    if #docs == 0 then
        return true
    end
    return skynet.call(mongo, "lua", "insert_many", COLLECTION, docs)
end

function M.mark_dirty(obj)
    if not obj or not obj.uid then
        return
    end
    local otype = M.obj_type(obj)
    obj.type = otype
    obj.version = (obj.version or 1) + 1
    obj._id = obj._id or M.make_id(obj.map_id, otype, obj.uid)
    dirty[obj._id] = obj
end

function M.save_one(obj)
    M.mark_dirty(obj)
    local mongo = get_mongo()
    if not mongo then
        return false, "mongo unavailable"
    end
    local doc = M.to_doc(obj)
    local id = doc._id
    local ver = obj.version
    doc._id = nil
    local ok, err = skynet.call(mongo, "lua", "upsert", COLLECTION, { _id = id }, doc)
    if ok then
        local cur = dirty[id]
        if cur and cur.version == ver then
            dirty[id] = nil
        end
    else
        log.error("map_store save_one failed: id=%s err=%s", tostring(id), tostring(err))
    end
    return ok, err
end

function M.flush()
    if not next(dirty) then
        return true
    end
    local mongo = get_mongo()
    if not mongo then
        return false, "mongo unavailable"
    end
    local updates = {}
    local snapshot = {}
    for id, obj in pairs(dirty) do
        local doc = M.to_doc(obj)
        doc._id = nil
        updates[#updates + 1] = {
            query = { _id = id },
            update = doc,
            upsert = true,
        }
        snapshot[id] = obj.version
    end
    local ok, err = skynet.call(mongo, "lua", "batch_update", COLLECTION, updates)
    if not ok then
        log.error("map_store flush failed: count=%d err=%s", #updates, tostring(err))
        return false, err
    end
    for id, ver in pairs(snapshot) do
        local cur = dirty[id]
        if cur and cur.version == ver then
            dirty[id] = nil
        end
    end
    return true
end

return M
