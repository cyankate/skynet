local skynet = require "skynet"
local log = require "log"
local class = require "utils.class"
local chunk = require "map.chunk"
local shard = require "map.shard"
local map_store = require "map.map_store"
local MapAOI = require "map.map_aoi"
local aoi_object = require "map.aoi_object"

local Map = class("Map")

-- 一张连续大世界共用一个 map_id（同一套坐标 / chunk / 行军）。
-- 多个 map_id 只用于不相接的空间：不同王国、赛季图、副本地图。
function Map.default_defs()
    local def = shard.world_def()
    return {
        [def.map_id] = def,
    }
end

function Map:ctor(def, shard_id)
    self.def = def
    self.map_id = def.map_id
    self.shard_id = tonumber(shard_id) or 0
    self.aoi = nil
    self.public_monsters = {}
    self.public_monsters_ready = false
    self.public_items = {}
    self.public_items_ready = false
    self.store_ephemeral = false
    self.public_region_opened = {}
    self._meta_opened = nil
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

function Map:region_id(x, y)
    local region_count = math.max(1, tonumber(self.def.region_count) or 1)
    local side = math.max(1, math.floor(math.sqrt(region_count)))
    local cell_w = math.max(1, math.floor(self.def.width / side))
    local cell_h = math.max(1, math.floor(self.def.height / side))
    local col = math.max(0, math.min(side - 1, math.floor((x - 1) / cell_w)))
    local row = math.max(0, math.min(side - 1, math.floor((y - 1) / cell_h)))
    local region_id = row * side + col + 1
    if region_id > region_count then
        region_id = region_count
    end
    return region_id
end

function Map:region_side()
    local region_count = math.max(1, tonumber(self.def.region_count) or 1)
    return math.max(1, math.floor(math.sqrt(region_count))), region_count
end

function Map:is_adjacent_region(from_region_id, to_region_id)
    if from_region_id == to_region_id then
        return true
    end
    local side = self:region_side()
    local a = from_region_id - 1
    local b = to_region_id - 1
    if a < 0 or b < 0 then
        return false
    end
    local ar, ac = math.floor(a / side), a % side
    local br, bc = math.floor(b / side), b % side
    return math.abs(ar - br) + math.abs(ac - bc) == 1
end

function Map:ensure_aoi()
    if self.aoi then
        return true
    end
    self.aoi = MapAOI.new(self.def.width, self.def.height, self.def.grid_size or 50)
    return true
end

function Map:on_aoi_changed(x, y, etype)
end

function Map:_emit_aoi(x, y, etype, old_x, old_y)
    if x == nil then
        return
    end
    self:on_aoi_changed(x, y, etype)
    if old_x ~= nil and (old_x ~= x or old_y ~= y) then
        self:on_aoi_changed(old_x, old_y, etype)
    end
end

function Map:enter_obj(obj)
    self:ensure_aoi()
    local ok, err, x, y, otype, old_x, old_y = self.aoi:enter(obj)
    if ok then
        self:sync_ghosts(obj)
        if x ~= nil then
            self:_emit_aoi(x, y, otype, old_x, old_y)
        end
    end
    return ok, err
end

function Map:leave_obj(uid)
    self:clear_ghosts(uid)
    if not self.aoi then
        return true
    end
    local ok, err, x, y, otype = self.aoi:leave(uid)
    if ok and x ~= nil then
        self:_emit_aoi(x, y, otype)
    end
    return ok, err
end

function Map:move_obj(uid, x, y)
    if not self.aoi then
        return false, "aoi not ready"
    end
    local ok, err, nx, ny, otype, old_x, old_y = self.aoi:move(uid, x, y)
    if ok then
        local obj = self.aoi:get(uid)
        if obj then
            self:sync_ghosts(obj)
        end
        self:_emit_aoi(nx, ny, otype, old_x, old_y)
    end
    return ok, err
end

function Map:list_surrounding(uid)
    if not self.aoi then
        return {}
    end
    return self.aoi:list_surrounding(uid)
end

function Map:around(x, y, view_range)
    if not self.aoi then
        return {}
    end
    return self.aoi:around(x, y, view_range)
end

function Map:should_ghost(obj)
    return aoi_object.should_project(obj)
end

function Map:sync_ghosts(obj)
    if not self:should_ghost(obj) then
        return
    end
    local id = aoi_object.uid_of(obj)
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
    local id = tostring(uid)
    local old = self.ghost_replicas[id]
    local obj = self.ghost_payloads[id]
    local x = obj and obj.x or 0
    local y = obj and obj.y or 0
    if old then
        for nid, _ in pairs(old) do
            local addr = shard.addr(self.map_id, nid)
            if addr then
                skynet.send(addr, "lua", "ghost_remove", id, x, y)
            end
        end
    end
    self.ghost_replicas[id] = nil
    self.ghost_payloads[id] = nil
end

function Map:apply_ghost_upsert(payload)
    if not payload then
        return false, "invalid payload"
    end
    self:ensure_aoi()
    aoi_object.ensure(payload, {
        is_ghost = true,
        view_range = shard.HALO_RANGE,
    })
    local ok, err, x, y, otype, old_x, old_y = self.aoi:enter(payload)
    if ok and x ~= nil then
        self:_emit_aoi(x, y, otype, old_x, old_y)
    end
    return ok, err
end

function Map:apply_ghost_remove(uid)
    if not self.aoi then
        return true
    end
    local ok, err, x, y, otype = self.aoi:remove_ghost(uid)
    if ok and x ~= nil then
        self:_emit_aoi(x, y, otype)
    end
    return ok, err
end

function Map:get_obj(uid)
    if not self.aoi then
        return nil
    end
    return self.aoi:get(uid)
end

function Map:resync_border_ghosts()
    for _, obj in pairs(self.ghost_payloads) do
        self:sync_ghosts(obj)
    end
end

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
    for i = 1, 4 do
        local x, y = self:rand_spawn()
        local uid = string.format("pub_%d_%d_%d", self.map_id, self.shard_id, i)
        local monster = {
            uid = uid,
            type = aoi_object.TYPE.MONSTER,
            map_id = self.map_id,
            shard_id = self.shard_id,
            owner_shard_id = self.shard_id,
            x = x,
            y = y,
            view_range = 0,
            is_ghost = false,
            chunk_id = chunk.from_pos(x, y, self.def.chunk_size),
            region_id = self:region_id(x, y),
            alive = true,
            kind = "public",
            visibility_layer = 2,
            owner_player_id = 0,
            version = 1,
        }
        monster._id = map_store.make_id(self.map_id, aoi_object.TYPE.MONSTER, uid)
        monsters[uid] = monster
        docs[#docs + 1] = monster
    end
    return monsters, docs
end

function Map:seed_public_items()
    local items = {}
    local docs = {}
    for i = 1, 6 do
        local x, y = self:rand_spawn()
        local uid = string.format("pub_i_%d_%d_%d", self.map_id, self.shard_id, i)
        local item = {
            uid = uid,
            type = aoi_object.TYPE.RESOURCE,
            map_id = self.map_id,
            shard_id = self.shard_id,
            owner_shard_id = self.shard_id,
            x = x,
            y = y,
            view_range = 0,
            is_ghost = false,
            chunk_id = chunk.from_pos(x, y, self.def.chunk_size),
            region_id = self:region_id(x, y),
            alive = true,
            item_id = 10001 + ((i - 1) % 3),
            count = 1,
            visibility_layer = 2,
            owner_player_id = 0,
            version = 1,
        }
        item._id = map_store.make_id(self.map_id, aoi_object.TYPE.RESOURCE, uid)
        items[uid] = item
        docs[#docs + 1] = item
    end
    return items, docs
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

function Map:load_public_items()
    if self.public_items_ready then
        return self.public_items
    end
    local this = self
    local objs = self:load_typed(aoi_object.TYPE.RESOURCE, function()
        return this:seed_public_items()
    end)
    self.public_items = objs
    self.public_items_ready = true
    return objs
end

function Map:load_opened_regions()
    local list, err = map_store.load(self.map_id, map_store.TYPE_META)
    if err then
        self.store_ephemeral = true
        return
    end
    for _, obj in ipairs(list or {}) do
        if obj.uid == "opened_regions" then
            self._meta_opened = obj
            local opened = {}
            for _, rid in ipairs(obj.opened_ids or {}) do
                opened[tonumber(rid) or rid] = true
            end
            self.public_region_opened = opened
            return
        end
    end
end

function Map:save_opened_regions()
    if not self.store_ephemeral then
        local list = map_store.load(self.map_id, map_store.TYPE_META)
        for _, obj in ipairs(list or {}) do
            if obj.uid == "opened_regions" then
                self._meta_opened = obj
                for _, rid in ipairs(obj.opened_ids or {}) do
                    self.public_region_opened[tonumber(rid) or rid] = true
                end
                break
            end
        end
    end
    local opened_ids = {}
    for rid, on in pairs(self.public_region_opened) do
        if on then
            opened_ids[#opened_ids + 1] = tonumber(rid) or rid
        end
    end
    table.sort(opened_ids, function(a, b)
        return tostring(a) < tostring(b)
    end)
    local ent = self._meta_opened
    if not ent then
        ent = {
            uid = "opened_regions",
            type = map_store.TYPE_META,
            map_id = self.map_id,
            chunk_id = 0,
            x = 0,
            y = 0,
            owner_player_id = 0,
            version = 1,
        }
        ent._id = map_store.make_id(self.map_id, map_store.TYPE_META, ent.uid)
        self._meta_opened = ent
    end
    ent.opened_ids = opened_ids
    self:save(ent)
end

function Map:public_items()
    return self.public_items
end

function Map:get_public_item(uid)
    return self.public_items[uid]
end

function Map:is_items_ephemeral()
    return self.store_ephemeral and true or false
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

function Map:save_item(item)
    return self:save(item)
end

function Map:is_public_region_opened(region_id)
    return self.public_region_opened[region_id] and true or false
end

function Map:open_public_region(region_id, persist)
    if self.public_region_opened[region_id] then
        return false
    end
    self.public_region_opened[region_id] = true
    if persist ~= false then
        self:save_opened_regions()
    end
    return true
end

function Map:bootstrap()
    self:ensure_aoi()
    self:load_opened_regions()
    self:load_public_monsters()
    self:load_public_items()
    self:attach_all(self.public_monsters, aoi_object.TYPE.MONSTER)
    self:attach_all(self.public_items, aoi_object.TYPE.RESOURCE)
    local this = self
    skynet.timeout(100, function()
        this:resync_border_ghosts()
    end)
end

return Map
