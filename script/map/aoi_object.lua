-- 大世界场景对象（统一称 obj）。
-- AoiObj 是空间底座；Observer 带视野；WorldObj 是可投影/可交互对象。
-- ghost 是同型投影态（is_ghost=true），不是单独 type。
-- 字段契约以 SCHEMA 为准；玩法热状态（行军路径等）留在各自模块。
local class = require "utils.class"

local M = {}

M.TYPE = {
    OBSERVER = "observer",
    MARCH = "march",
    MONSTER = "monster",
    RESOURCE = "resource",
    BUILDING = "building",
}

-- 空间底座（所有 type）
M.BASE_FIELDS = {
    "uid", "type", "x", "y", "view_range", "is_ghost",
    "map_id", "shard_id", "owner_shard_id",
}

-- 世界对象公共
M.WORLD_FIELDS = {
    "alive", "owner_player_id",
}

-- 分型扩展：只列 AOI / 可见 / ghost 边界需要的字段
M.TYPE_FIELDS = {
    [M.TYPE.OBSERVER] = { "player_id", "player_name" },
    [M.TYPE.MARCH] = { "hp", "max_hp", "state", "target_uid", "battle_id" },
    [M.TYPE.MONSTER] = { "kind" },
    [M.TYPE.RESOURCE] = { "item_id", "count" },
    [M.TYPE.BUILDING] = { "building_id", "level" },
}

-- 客户端可见字段（协议打包）；observer 暂不同步给他人
M.VISIBLE_FIELDS = {
    [M.TYPE.MARCH] = {
        "uid", "owner_player_id", "x", "y",
        "hp", "max_hp", "state", "target_uid", "battle_id", "shard_id",
    },
    [M.TYPE.MONSTER] = {
        "uid", "x", "y", "kind", "owner_player_id",
    },
    [M.TYPE.RESOURCE] = {
        "uid", "x", "y", "item_id", "count", "owner_player_id",
    },
    [M.TYPE.BUILDING] = {
        "uid", "x", "y", "building_id", "level", "owner_player_id",
    },
}

-- 全量可见包分桶名（内部）；下发协议里资源列表字段仍叫 items
M.VISIBLE_BUCKET = {
    [M.TYPE.MARCH] = "marches",
    [M.TYPE.MONSTER] = "monsters",
    [M.TYPE.RESOURCE] = "resources",
    [M.TYPE.BUILDING] = "buildings",
}

local BASE_DEFAULTS = {
    x = 0,
    y = 0,
    view_range = 0,
    is_ghost = false,
}

local WORLD_DEFAULTS = {
    owner_player_id = 0,
}

local VISIBLE_DEFAULTS = {
    owner_player_id = 0,
    kind = "",
    item_id = 0,
    count = 1,
    building_id = 0,
    level = 0,
    hp = 0,
    max_hp = 100,
    state = "",
    target_uid = "",
    battle_id = "",
    shard_id = 0,
}

-- ghost 快照里 nil 会变成这些值，便于邻居覆盖清空（否则 apply 会跳过 nil）
local GHOST_CLEAR_DEFAULTS = {
    target_uid = "",
    battle_id = "",
    state = "",
}

local function append_keys(dst, keys)
    for i = 1, #keys do
        dst[#dst + 1] = keys[i]
    end
end

function M.schema_keys(otype)
    local keys = {}
    append_keys(keys, M.BASE_FIELDS)
    append_keys(keys, M.WORLD_FIELDS)
    local extra = otype and M.TYPE_FIELDS[otype]
    if extra then
        append_keys(keys, extra)
    end
    return keys
end

-- 补齐 AOI 基类 + 世界公共字段（库表加载后、进 AOI 前）
function M.ensure(obj, opts)
    if type(obj) ~= "table" then
        return obj
    end
    if opts then
        for k, v in pairs(opts) do
            if v ~= nil then
                obj[k] = v
            end
        end
    end

    obj.x = tonumber(obj.x) or BASE_DEFAULTS.x
    obj.y = tonumber(obj.y) or BASE_DEFAULTS.y
    obj.view_range = tonumber(obj.view_range) or BASE_DEFAULTS.view_range

    if obj.is_ghost == nil then
        obj.is_ghost = false
    else
        obj.is_ghost = obj.is_ghost and true or false
    end

    for _, key in ipairs(M.WORLD_FIELDS) do
        if key == "alive" then
            if obj.alive ~= nil then
                obj.alive = obj.alive and true or false
            end
        elseif obj[key] == nil and WORLD_DEFAULTS[key] ~= nil then
            obj[key] = WORLD_DEFAULTS[key]
        end
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
    if not obj or obj.uid == nil or obj.uid == "" then
        return false
    end
    if M.is_ghost(obj) then
        return false
    end
    -- 玩家观察者只在本片，不跨区投影
    if M.is_observer(obj) then
        return false
    end
    if obj.type == M.TYPE.MARCH then
        return true
    end
    -- 建筑（玩家主城）全图可见，带 owner 也要贴边投影
    if obj.type == M.TYPE.BUILDING then
        return true
    end
    if (obj.owner_player_id or 0) ~= 0 then
        return false
    end
    return obj.type == M.TYPE.MONSTER
        or obj.type == M.TYPE.RESOURCE
end

function M.visible_bucket(otype)
    return M.VISIBLE_BUCKET[otype]
end

-- 客户端可见序列化。ctx.shard_id 可覆盖行军/投影所属 shard。
-- ctx.full = true 全量；否则只推脏字段（_dirty_fields）
function M.pack_visible(obj, ctx)
    if not obj or M.is_observer(obj) then
        return nil
    end
    local fields = M.VISIBLE_FIELDS[obj.type]
    if not fields then
        return nil
    end
    ctx = ctx or {}
    local out = {}
    local dirty = obj._dirty_fields
    local use_dirty = not ctx.full and dirty and next(dirty)
    for _, key in ipairs(fields) do
        local v
        if key == "uid" then
            v = obj.uid
        elseif key == "shard_id" then
            v = ctx.shard_id or obj.owner_shard_id or obj.shard_id
        else
            v = obj[key]
        end
        if v == nil then
            v = VISIBLE_DEFAULTS[key]
        end
        if use_dirty then
            -- 增量：只打包脏字段 + uid
            if key == "uid" or dirty[key] then
                out[key] = v
            end
        else
            out[key] = v
        end
    end
    -- 增量模式非脏字段为 nil，sproto 编码时自动跳过（线上即稀疏包），客户端按非 nil 覆盖
    return out
end

-- 标记字段变化（增量同步用）
function M.mark_dirty(obj, field)
    if not obj then
        return
    end
    obj._dirty_fields = obj._dirty_fields or {}
    obj._dirty_fields[field] = true
end

-- 清脏字段标记（推完增量后调）
function M.clear_dirty(obj)
    if obj then
        obj._dirty_fields = nil
    end
end

function M.make_ghost_snapshot(obj, map_id, owner_shard_id, view_range)
    if not obj then
        return nil
    end
    local uid = obj.uid
    local otype = obj.type
    local snap = {
        uid = uid,
        is_ghost = true,
        map_id = map_id or obj.map_id,
        owner_shard_id = owner_shard_id or obj.owner_shard_id,
        shard_id = owner_shard_id or obj.shard_id,
        view_range = view_range or obj.view_range or 0,
    }

    for _, key in ipairs(M.schema_keys(otype)) do
        if snap[key] ~= nil then
            goto continue
        end
        local v = obj[key]
        if v == nil then
            v = GHOST_CLEAR_DEFAULTS[key]
            if v == nil then
                v = WORLD_DEFAULTS[key]
            end
            if v == nil then
                v = BASE_DEFAULTS[key]
            end
        end
        if key == "player_id" and v == nil then
            v = uid
        end
        if v ~= nil then
            snap[key] = v
        end
        ::continue::
    end

    snap.type = otype
    snap.is_ghost = true
    return snap
end

function M.apply_ghost_update(dst, src)
    if not dst or not src then
        return dst
    end
    local otype = src.type or dst.type
    for _, key in ipairs(M.schema_keys(otype)) do
        local v = src[key]
        if v == nil then
            goto continue
        end
        if key == "x" or key == "y" or key == "view_range" then
            dst[key] = tonumber(v) or dst[key]
        else
            dst[key] = v
        end
        ::continue::
    end
    dst.uid = src.uid or dst.uid
    dst.is_ghost = true
    if src.owner_shard_id ~= nil then
        dst.owner_shard_id = src.owner_shard_id
        if src.shard_id == nil then
            dst.shard_id = src.owner_shard_id
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
    self.player_id = self.player_id or self.uid
end

local WorldObj = class("WorldObj", AoiObj)

function WorldObj:ctor(opts)
    opts = opts or {}
    if opts.alive == nil then
        opts.alive = true
    end
    AoiObj.ctor(self, opts)
end

M.AoiObj = AoiObj
M.Observer = Observer
M.WorldObj = WorldObj

return M
