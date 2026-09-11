-- 大世界场景对象（统一称 obj）。
-- AoiObj 是空间底座；Observer 带视野；WorldObj 是可投影/可交互对象。
-- ghost 是同型投影态（is_ghost=true），不是单独 type。
local class = require "utils.class"

local M = {}

M.TYPE = {
    OBSERVER = "observer",
    MARCH = "march",
    MONSTER = "monster",
    RESOURCE = "resource",
    BUILDING = "building",
}

function M.uid_of(obj)
    if not obj then
        return nil
    end
    if obj.uid ~= nil and obj.uid ~= "" then
        return tostring(obj.uid)
    end
    return nil
end

-- 补齐 AOI 基类字段（库表加载后、进 AOI 前都走这里）
function M.ensure(obj, opts)
    if type(obj) ~= "table" then
        return obj
    end
    opts = opts or {}
    local uid = tostring(opts.uid or M.uid_of(obj) or "")
    obj.uid = uid
    obj.id = uid -- GridAOI 读 id
    if opts.type ~= nil then
        obj.type = opts.type
    end
    if opts.x ~= nil then
        obj.x = tonumber(opts.x) or 0
    else
        obj.x = tonumber(obj.x) or 0
    end
    if opts.y ~= nil then
        obj.y = tonumber(opts.y) or 0
    else
        obj.y = tonumber(obj.y) or 0
    end
    if opts.view_range ~= nil then
        obj.view_range = tonumber(opts.view_range) or 0
    else
        obj.view_range = tonumber(obj.view_range) or 0
    end
    if opts.is_ghost ~= nil then
        obj.is_ghost = opts.is_ghost and true or false
    elseif obj.is_ghost == nil then
        obj.is_ghost = false
    end
    if opts.map_id ~= nil then
        obj.map_id = opts.map_id
    end
    if opts.owner_shard_id ~= nil then
        obj.owner_shard_id = opts.owner_shard_id
    end
    if opts.shard_id ~= nil then
        obj.shard_id = opts.shard_id
    end
    return obj
end

function M.is_ghost(obj)
    return obj and obj.is_ghost and true or false
end

function M.is_observer(obj)
    return obj and obj.type == M.TYPE.OBSERVER
end

function M.should_project(obj)
    if not obj or M.uid_of(obj) == nil then
        return false
    end
    if M.is_ghost(obj) then
        return false
    end
    if obj.type == M.TYPE.MARCH or obj.type == M.TYPE.OBSERVER then
        return true
    end
    if (obj.owner_player_id or 0) ~= 0 then
        return false
    end
    return obj.type == M.TYPE.MONSTER
        or obj.type == M.TYPE.RESOURCE
        or obj.type == M.TYPE.BUILDING
end

function M.make_ghost_snapshot(obj, map_id, owner_shard_id, view_range)
    if not obj then
        return nil
    end
    local uid = M.uid_of(obj)
    local snap = {
        uid = uid,
        id = uid,
        type = obj.type,
        x = obj.x,
        y = obj.y,
        view_range = view_range or 0,
        is_ghost = true,
        map_id = map_id or obj.map_id,
        owner_shard_id = owner_shard_id or obj.owner_shard_id,
        shard_id = owner_shard_id or obj.shard_id,
        owner_player_id = obj.owner_player_id or 0,
        visibility_layer = obj.visibility_layer or 2,
        region_id = obj.region_id or 0,
        alive = obj.alive,
    }
    if obj.type == M.TYPE.MARCH then
        snap.hp = obj.hp
        snap.max_hp = obj.max_hp
        snap.state = obj.state
        snap.target_uid = obj.target_uid
        snap.battle_id = obj.battle_id
    elseif obj.type == M.TYPE.MONSTER then
        snap.kind = obj.kind
    elseif obj.type == M.TYPE.RESOURCE then
        snap.item_id = obj.item_id
        snap.count = obj.count
    elseif obj.type == M.TYPE.OBSERVER then
        snap.player_id = obj.player_id or uid
        snap.player_name = obj.player_name
    elseif obj.type == M.TYPE.BUILDING then
        snap.building_id = obj.building_id
        snap.level = obj.level
    end
    return snap
end

function M.apply_ghost_update(dst, src)
    if not dst or not src then
        return dst
    end
    dst.x = tonumber(src.x) or dst.x
    dst.y = tonumber(src.y) or dst.y
    dst.view_range = tonumber(src.view_range) or dst.view_range
    dst.type = src.type or dst.type
    dst.is_ghost = true
    dst.map_id = src.map_id or dst.map_id
    dst.owner_shard_id = src.owner_shard_id or dst.owner_shard_id
    dst.shard_id = src.shard_id or src.owner_shard_id or dst.shard_id
    dst.owner_player_id = src.owner_player_id or dst.owner_player_id
    dst.visibility_layer = src.visibility_layer or dst.visibility_layer
    dst.region_id = src.region_id or dst.region_id
    for _, key in ipairs({
        "hp", "max_hp", "state", "target_uid", "battle_id",
        "kind", "item_id", "count", "building_id", "level",
        "player_id", "player_name", "alive",
    }) do
        if src[key] ~= nil then
            dst[key] = src[key]
        end
    end
    return dst
end

---------------------------------------------------------------------------
-- 浅类型：new 创建；库表 ensure
---------------------------------------------------------------------------

local AoiObj = class("AoiObj")

function AoiObj:ctor(opts)
    M.ensure(self, opts or {})
end

local Observer = class("Observer", AoiObj)

function Observer:ctor(opts)
    opts = opts or {}
    opts.type = M.TYPE.OBSERVER
    opts.view_range = opts.view_range or 100
    AoiObj.ctor(self, opts)
    self.player_id = opts.player_id or tonumber(self.uid) or self.uid
    self.player_name = opts.player_name
end

local WorldObj = class("WorldObj", AoiObj)

function WorldObj:ctor(opts)
    opts = opts or {}
    AoiObj.ctor(self, opts)
    self.alive = opts.alive ~= false
    self.region_id = opts.region_id or 0
    self.visibility_layer = opts.visibility_layer or 2
    self.owner_player_id = opts.owner_player_id or 0
end

M.AoiObj = AoiObj
M.Observer = Observer
M.WorldObj = WorldObj

return M
