local skynet = require "skynet"
local log = require "log"

local M = {}

local cache = {}
local dirty = {}

local FLUSH_INTERVAL = 500 -- 5s

local function ensure_node(name)
    if not cache[name] then
        cache[name] = {}
    end
    return cache[name]
end

local function flush_one(name)
    if not dirty[name] then
        return
    end

    local db = skynet.localname(".db")
    if not db then
        log.error("global_mgr flush failed, db not found")
        return
    end

    local row = {
        name = name,
        data = cache[name] or {},
        update_time = os.time(),
    }

    local exists = skynet.call(db, "lua", "select", "global_data", { name = name }, { limit = 1 })
    local ok
    if exists and exists[1] then
        ok = skynet.call(db, "lua", "update", "global_data", row)
    else
        ok = skynet.call(db, "lua", "insert", "global_data", row)
    end

    if not ok then
        log.error("global_mgr flush failed, name=%s", tostring(name))
        return
    end

    dirty[name] = nil
end

local function flush_loop()
    skynet.timeout(FLUSH_INTERVAL, flush_loop)
    for name, _ in pairs(dirty) do
        flush_one(name)
    end
end

function M.init()
    local db = skynet.localname(".db")
    if not db then
        return false, "db service not found"
    end

    local rows = skynet.call(db, "lua", "select", "global_data", {}, nil) or {}
    for _, row in ipairs(rows) do
        cache[row.name] = row.data or {}
    end

    skynet.timeout(FLUSH_INTERVAL, flush_loop)
    return true
end

function M.get(name)
    return ensure_node(name)
end

function M.get_field(name, key, default)
    local node = ensure_node(name)
    local value = node[key]
    if value == nil then
        return default
    end
    return value
end

function M.set(name, data)
    cache[name] = data or {}
    dirty[name] = true
    return true
end

function M.flush(name)
    if name then
        flush_one(name)
        return true
    end
    for n, _ in pairs(dirty) do
        flush_one(n)
    end
    return true
end

-- world_boss 示例接口
function M.get_world_boss_state()
    local node = ensure_node("world_boss")
    if node.status == nil then
        node.status = "idle"
        node.hp = 0
        node.round = 0
        dirty["world_boss"] = true
    end
    return node
end

function M.set_world_boss_state(state)
    cache["world_boss"] = state or {}
    dirty["world_boss"] = true
    return true
end

return M
