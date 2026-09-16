local skynet = require "skynet"
local log = require "log"
local class = require "utils.class"
local chunk = require "map.chunk"
local shard = require "map.shard"
local map_store = require "map.map_store"
local MapAOI = require "map.map_aoi"
local aoi_object = require "map.aoi_object"
local view_sync = require "map.view_sync"

local Map = class("Map")

-- 一张连续大世界共用一个 map_id（同一套坐标 / chunk / 行军）。
-- 多个 map_id 只用于不相接的空间：不同王国、赛季图、副本地图。
function Map.default_defs()
    local def = shard.default_def()
    return {
        [def.map_id] = def,
    }
end

function Map:ctor(def, shard_id)
    self.def = def
    self.map_id = def.map_id
    self.shard_id = tonumber(shard_id) or 0
    self.aoi = MapAOI.new(def.width, def.height, def.grid_size or 50)
    self.public_monsters = {}
    self.public_monsters_ready = false
    self.public_resources = {}
    self.public_resources_ready = false
    self.store_ephemeral = false
    self.ghost_replicas = {}  -- uid => { [neighbor_shard] = true }
    self.ghost_payloads = {}  -- uid => 真身 obj 引用（仅贴边投影时有）
end

function Map:owns_pos(x, y)
    return shard.owns_pos(self.shard_id, x, y, self.def)
end

function Map:owned_chunk_ids()
    return shard.owned_chunk_ids(self.shard_id, self.def)
end

function Map:neighbor_ids()
    return shard.neighbors(self.shard_id, self.def)
end

function Map:rand_spawn()
    local x0, y0, x1, y1 = shard.pixel_rect(self.shard_id, self.def)
    return math.random(x0, x1), math.random(y0, y1)
end

-- 公共对象播种配置（每片）
local PUBLIC_MONSTER_COUNT = 48
local PUBLIC_RESOURCE_COUNT = 32
local PATROL_RATIO = 0.3        -- 巡逻怪比例
local PATROL_RADIUS_MIN = 60    -- 巡逻半径区间（以生成点为圆心小范围游走）
local PATROL_RADIUS_MAX = 120

-- 抖动网格均匀取点：按矩形纵横比切成网格，洗牌后每格内随机落一点。
-- 相比纯随机，保证全片覆盖均匀、不扎堆；相比纯网格，格内抖动避免棋盘感。
local function jittered_points(x0, y0, x1, y1, count)
    local w = math.max(1, x1 - x0)
    local h = math.max(1, y1 - y0)
    local cols = math.max(1, math.ceil(math.sqrt(count * w / h)))
    local rows = math.max(1, math.ceil(count / cols))
    local cw = w / cols
    local ch = h / rows
    local cells = {}
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            cells[#cells + 1] = { r = r, c = c }
        end
    end
    for i = #cells, 2, -1 do
        local j = math.random(i)
        cells[i], cells[j] = cells[j], cells[i]
    end
    local pts = {}
    for i = 1, math.min(count, #cells) do
        local cell = cells[i]
        local x = math.floor(x0 + (cell.c + math.random()) * cw)
        local y = math.floor(y0 + (cell.r + math.random()) * ch)
        pts[#pts + 1] = { x = math.max(1, x), y = math.max(1, y) }
    end
    return pts
end

-- 非观察者实体进/离视野：同步周围观察者对该 uid 的可见性
-- 观察者自身不推（客户端自己知道自己在哪）
local function sync_visible(map, x, y, uid, otype)
    if x == nil or not uid then
        return
    end
    if otype == aoi_object.TYPE.OBSERVER then
        return
    end
    view_sync.sync_obj_visible_around(map, { x = x, y = y }, uid)
end

-- 移动时新旧位置都要扫：旧位置补 leave，新位置补 enter，合并去重
local function sync_visible_move(map, x, y, old_x, old_y, uid, otype)
    if otype == aoi_object.TYPE.OBSERVER then
        return
    end
    if x == nil or not uid then
        return
    end
    -- 可见性按 AOI 格子窗口判定（in_observer_range 比较格子号）：
    -- 同一格子内的移动不可能改变任何观察者的 should/has，扫描必然零产出，直接短路。
    -- 行军 30u/s 每 tick 走 3u，~94% 的 tick 落在此分支（热点压测 march_tick 主要开销）
    if old_x ~= nil then
        local gs = (map.aoi and map.aoi.grid_size) or 50
        if math.floor(x / gs) == math.floor(old_x / gs)
            and math.floor(y / gs) == math.floor(old_y / gs) then
            return
        end
    end
    view_sync.sync_obj_visible_around(map, {
        { x = x, y = y },
        old_x ~= nil and (old_x ~= x or old_y ~= y) and { x = old_x, y = old_y } or nil,
    }, uid)
end

function Map:enter_obj(obj)
    local ok, err, x, y, otype, old_x, old_y = self.aoi:enter(obj)
    if ok then
        self:sync_ghosts(obj)
        if x ~= nil then
            sync_visible_move(self, x, y, old_x, old_y, obj and obj.uid, otype)
        end
    end
    return ok, err
end

function Map:leave_obj(uid)
    self:clear_ghosts(uid)
    local ok, err, x, y, otype = self.aoi:leave(uid)
    if ok and x ~= nil then
        sync_visible(self, x, y, uid, otype)
    end
    return ok, err
end

function Map:move_obj(uid, x, y)
    local ok, err, nx, ny, otype, old_x, old_y = self.aoi:move(uid, x, y)
    if ok then
        local obj = self.aoi:get(uid)
        if obj then
            self:sync_ghosts(obj)
        end
        sync_visible_move(self, nx, ny, old_x, old_y, uid, otype)
    end
    return ok, err
end

function Map:list_surrounding(uid)
    return self.aoi:list_surrounding(uid)
end

function Map:around(x, y, view_range)
    return self.aoi:around(x, y, view_range)
end

function Map:observers_around(x, y, view_range)
    return self.aoi:observers_around(x, y, view_range)
end

function Map:should_ghost(obj)
    return aoi_object.should_project(obj)
end

-- ghost 投影：实体贴边时向邻居 shard 同步一份镜像，跨片视野/交互用
-- 真身 enter 时若已有 ghost，ghost 让位（enter 里处理）
function Map:sync_ghosts(obj)
    if not self:should_ghost(obj) then
        return
    end
    local id = obj.uid
    local want = {}
    for _, nid in ipairs(shard.halo_neighbors(self.shard_id, obj.x, obj.y, shard.HALO_RANGE, self.def)) do
        want[nid] = true
    end
    local old = self.ghost_replicas[id] or {}
    for nid, _ in pairs(old) do
        if not want[nid] then
            local addr = shard.addr(self.map_id, nid)
            if addr then
                skynet.send(addr, "lua", "ghost_remove", id, obj.x, obj.y)
            end
        end
    end
    if not next(want) then
        self.ghost_replicas[id] = nil
        self.ghost_payloads[id] = nil
        return
    end

    self.ghost_payloads[id] = obj
    local ghost = aoi_object.make_ghost_snapshot(obj, self.map_id, self.shard_id, shard.HALO_RANGE)
    for nid, _ in pairs(want) do
        local addr = shard.addr(self.map_id, nid)
        if addr then
            skynet.send(addr, "lua", "ghost_upsert", ghost)
        end
    end
    self.ghost_replicas[id] = want
end

function Map:clear_ghosts(uid)
    local old = self.ghost_replicas[uid]
    local obj = self.ghost_payloads[uid]
    local x = obj and obj.x or 0
    local y = obj and obj.y or 0
    if old then
        for nid, _ in pairs(old) do
            local addr = shard.addr(self.map_id, nid)
            if addr then
                skynet.send(addr, "lua", "ghost_remove", uid, x, y)
            end
        end
    end
    self.ghost_replicas[uid] = nil
    self.ghost_payloads[uid] = nil
end

function Map:apply_ghost_upsert(payload)
    if not payload then
        return false, "invalid payload"
    end
    aoi_object.ensure(payload, {
        is_ghost = true,
        view_range = shard.HALO_RANGE,
    })
    local ok, err, x, y, otype, old_x, old_y = self.aoi:enter(payload)
    if ok and x ~= nil then
        sync_visible_move(self, x, y, old_x, old_y, payload.uid, otype)
    end
    return ok, err
end

function Map:apply_ghost_remove(uid)
    local ok, err, x, y, otype = self.aoi:remove_ghost(uid)
    if ok and x ~= nil then
        sync_visible(self, x, y, uid, otype)
    end
    return ok, err
end

function Map:get_obj(uid)
    return self.aoi:get(uid)
end

function Map:resync_border_ghosts()
    for _, obj in pairs(self.ghost_payloads) do
        self:sync_ghosts(obj)
    end
end

-- 邻居晚启动时，请对方把贴边投影再推一遍（ghost 恢复）
function Map:request_neighbor_ghost_resync()
    for _, nid in ipairs(self:neighbor_ids()) do
        local addr = shard.addr(self.map_id, nid)
        if addr then
            skynet.send(addr, "lua", "resync_border_ghosts")
        end
    end
end

-- 进 AOI 并标记；alive=false 的实体不进（如已死亡怪物）
function Map:attach(obj, otype)
    if not obj or not obj.uid or obj.in_aoi then
        return
    end
    if obj.alive == false then
        return
    end
    aoi_object.ensure(obj, {
        type = otype or obj.type,
        view_range = 0,
        is_ghost = false,
        map_id = self.map_id,
        owner_shard_id = self.shard_id,
        shard_id = self.shard_id,
    })
    local ok, err = self:enter_obj(obj)
    if ok then
        obj.in_aoi = true
    else
        log.error("%s enter aoi failed, uid=%s err=%s", tostring(otype), tostring(obj.uid), tostring(err))
    end
end

function Map:detach(obj)
    if not obj or not obj.uid then
        return
    end
    if obj.in_aoi then
        pcall(function()
            self:leave_obj(obj.uid)
        end)
        obj.in_aoi = false
    end
end

function Map:attach_all(objs, otype)
    for _, obj in pairs(objs or {}) do
        self:attach(obj, otype)
    end
end

function Map:detach_all(objs)
    for _, obj in pairs(objs or {}) do
        self:detach(obj)
    end
end

function Map:get_public_monster(uid)
    return self.public_monsters[uid]
end

function Map:seed_public_monsters()
    local monsters = {}
    local docs = {}
    local x0, y0, x1, y1 = shard.pixel_rect(self.shard_id, self.def)
    local pts = jittered_points(x0, y0, x1, y1, PUBLIC_MONSTER_COUNT)
    for i, pt in ipairs(pts) do
        local uid = string.format("pub_%d_%d_%d", self.map_id, self.shard_id, i)
        -- 部分怪物带巡逻半径（配置随实体持久化，巡逻状态是运行时）
        local patrol_radius = 0
        if math.random() < PATROL_RATIO then
            patrol_radius = math.random(PATROL_RADIUS_MIN, PATROL_RADIUS_MAX)
        end
        local monster = {
            uid = uid,
            type = aoi_object.TYPE.MONSTER,
            map_id = self.map_id,
            shard_id = self.shard_id,
            owner_shard_id = self.shard_id,
            x = pt.x,
            y = pt.y,
            view_range = 0,
            is_ghost = false,
            chunk_id = chunk.from_pos(pt.x, pt.y, self.def.chunk_size),
            alive = true,
            kind = "public",
            hp = 100,
            max_hp = 100,
            owner_player_id = 0,
            patrol_radius = patrol_radius,
            version = 1,
        }
        monster._id = map_store.make_id(self.map_id, aoi_object.TYPE.MONSTER, uid)
        monsters[uid] = monster
        docs[#docs + 1] = monster
    end
    return monsters, docs
end

function Map:seed_public_resources()
    local resources = {}
    local docs = {}
    local x0, y0, x1, y1 = shard.pixel_rect(self.shard_id, self.def)
    local pts = jittered_points(x0, y0, x1, y1, PUBLIC_RESOURCE_COUNT)
    for i, pt in ipairs(pts) do
        local uid = string.format("pub_i_%d_%d_%d", self.map_id, self.shard_id, i)
        local obj = {
            uid = uid,
            type = aoi_object.TYPE.RESOURCE,
            map_id = self.map_id,
            shard_id = self.shard_id,
            owner_shard_id = self.shard_id,
            x = pt.x,
            y = pt.y,
            view_range = 0,
            is_ghost = false,
            chunk_id = chunk.from_pos(pt.x, pt.y, self.def.chunk_size),
            alive = true,
            item_id = 10001 + ((i - 1) % 3),
            count = 120,
            gatherable = true,
            occupier_uid = "",
            owner_player_id = 0,
            version = 1,
        }
        obj._id = map_store.make_id(self.map_id, aoi_object.TYPE.RESOURCE, uid)
        resources[uid] = obj
        docs[#docs + 1] = obj
    end
    return resources, docs
end

local function index_by_uid(list)
    local t = {}
    local alive = 0
    for _, obj in ipairs(list or {}) do
        if obj.uid and obj.uid ~= "" then
            t[obj.uid] = obj
            if obj.alive then
                alive = alive + 1
            end
        end
    end
    return t, alive
end

function Map:load_typed(etype, seed_fn)
    local chunk_ids = self:owned_chunk_ids()
    local n, err = map_store.count(self.map_id, etype, chunk_ids)
    if err then
        self.store_ephemeral = true
        local objs = seed_fn()
        return objs, 0, err
    end
    if (tonumber(n) or 0) <= 0 then
        local objs, docs = seed_fn()
        local ok, insert_err = map_store.insert(docs)
        if not ok then
            self.store_ephemeral = true
            for _, obj in pairs(objs) do
                map_store.mark_dirty(obj)
            end
            log.error("map_store seed insert failed, map_id=%s shard_id=%s type=%s err=%s",
                tostring(self.map_id), tostring(self.shard_id), tostring(etype), tostring(insert_err))
        else
            log.info("map_store seeded, map_id=%s shard_id=%s type=%s count=%d",
                tostring(self.map_id), tostring(self.shard_id), tostring(etype), #(docs or {}))
        end
        return objs, n
    end
    local list, load_err = map_store.load(self.map_id, etype, chunk_ids)
    if load_err then
        log.error("map_store load failed, map_id=%s shard_id=%s type=%s err=%s",
            tostring(self.map_id), tostring(self.shard_id), tostring(etype), tostring(load_err))
        return {}, n, load_err
    end
    local objs, alive = index_by_uid(list)
    log.info("map_store loaded, map_id=%s shard_id=%s type=%s total=%d alive=%d",
        tostring(self.map_id), tostring(self.shard_id), tostring(etype), n, alive)
    return objs, n
end

function Map:load_public_monsters()
    if self.public_monsters_ready then
        return self.public_monsters
    end
    local this = self
    local objs = self:load_typed(aoi_object.TYPE.MONSTER, function()
        return this:seed_public_monsters()
    end)
    self.public_monsters = objs
    self.public_monsters_ready = true
    return objs
end

function Map:load_public_resources()
    if self.public_resources_ready then
        return self.public_resources
    end
    local this = self
    local objs = self:load_typed(aoi_object.TYPE.RESOURCE, function()
        return this:seed_public_resources()
    end)
    self.public_resources = objs
    self.public_resources_ready = true
    for _, obj in pairs(self.public_resources) do
        obj.occupier_uid = ""
        if obj.gatherable == nil then
            obj.gatherable = true
        end
    end
    return objs
end

function Map:get_public_resource(uid)
    return self.public_resources[uid]
end

-- 玩家主城：uid 约定 city_<player_id>，AOI 实体即权威，不落 player_state
function Map:get_city(player_id)
    return self.aoi:get("city_" .. tostring(player_id))
end

-- 本片辖区内的争夺建筑清单（公共 BUILDING；玩家主城 owner~=0 不算，ghost 不算）
function Map:list_contention_buildings()
    local list = {}
    for _, obj in pairs(self.aoi.objs) do
        if obj.type == aoi_object.TYPE.BUILDING
            and not obj.is_ghost
            and (obj.owner_player_id or 0) == 0 then
            list[#list + 1] = {
                uid = obj.uid,
                building_id = obj.building_id or 0,
                x = obj.x,
                y = obj.y,
                shard_id = self.shard_id,
                alliance_id = obj.alliance_id or 0,
            }
        end
    end
    return list
end

-- 建筑（含玩家主城）：不自动刷，只从库加载；建城在 enter_map 流程里
function Map:load_buildings()
    if self.buildings_ready then
        return
    end
    self.buildings_ready = true
    local objs = self:load_typed(aoi_object.TYPE.BUILDING, function()
        return {}, {}
    end)
    self:attach_all(objs, aoi_object.TYPE.BUILDING)
end

function Map:save(obj)
    if not obj then
        return false, "invalid obj"
    end
    if self.store_ephemeral then
        map_store.mark_dirty(obj)
        return true
    end
    return map_store.save_one(obj)
end

function Map:bootstrap()
    self:load_public_monsters()
    self:load_public_resources()
    self:load_buildings()
    self:attach_all(self.public_monsters, aoi_object.TYPE.MONSTER)
    self:attach_all(self.public_resources, aoi_object.TYPE.RESOURCE)
    local this = self
    skynet.timeout(100, function()
        this:resync_border_ghosts()
        this:request_neighbor_ghost_resync()
    end)
end

return Map
