-- 在线目录：player_id → gate + agent。
-- gate 随连接变；agent 跟逻辑进程，闪断宽限期内仍在。
-- 分片直推查 gate；业务下行 / call_agent 查 agent。
local skynet = require "skynet"
local log = require "log"
local rpc = require "cluster.rpc"
local layout = require "cluster.layout"
local shard = require "map.shard"
local service_ctx = require "runtime.service_ctx"

local M = service_ctx.get("locator.locator", {})
M.players = M.players or {}
M.services = M.services or {}
M.shards = M.shards or {}
local players = M.players
local services = M.services
local shards = M.shards

-- 注册租约：心跳 30 秒（rpc.HEARTBEAT），120 秒没刷新视为下线。
local LEASE_TTL = 12000
local PRUNE_INTERVAL = 3000

local function norm_name(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    if name:sub(1, 1) == "." then
        return name:sub(2)
    end
    return name
end

local function shard_key(map_id, shard_id)
    map_id = tonumber(map_id)
    shard_id = tonumber(shard_id)
    if not map_id or not shard_id then
        return nil, nil, nil
    end
    return tostring(map_id) .. ":" .. tostring(shard_id), map_id, shard_id
end

local function alive(info, now)
    return info ~= nil and (now - (info.ts or 0) < LEASE_TTL)
end

local function invalidate_gate_cache(player_id)
    local seen = {}
    local function notify(name, node)
        local addr = rpc.named(name, node)
        if addr then
            skynet.send(addr, "lua", "forget_player_gate", player_id)
        end
    end
    local now = skynet.now()
    -- 已登记的分片，可能跨多张图
    for key, info in pairs(shards) do
        if alive(info, now) then
            seen[key] = true
            local name = info.name or shard.service_name(info.map_id, info.shard_id)
            local node = info.node ~= "" and info.node or layout.shard_node(info.map_id, info.shard_id)
            notify(name, node)
        end
    end
    -- 兜底：默认图里还没登记的分片也通知一遍
    local map_id = shard.DEFAULT_MAP_ID
    for _, sid in ipairs(shard.all_ids()) do
        local key = shard_key(map_id, sid)
        if key and not seen[key] then
            notify(shard.service_name(map_id, sid), layout.shard_node(map_id, sid))
        end
    end
end

local function ensure(player_id)
    local cur = players[player_id]
    if not cur then
        cur = {}
        players[player_id] = cur
    end
    return cur
end

local function drop_if_empty(player_id)
    local cur = players[player_id]
    if cur and not cur.name and not cur.agent then
        players[player_id] = nil
    end
end

function M.bind(player_id, gate_name, node)
    player_id = tonumber(player_id)
    if not player_id or type(gate_name) ~= "string" or gate_name == "" then
        return false, "invalid locator"
    end
    local old = players[player_id]
    local old_name = old and old.name
    local old_node = old and old.node
    local cur = ensure(player_id)
    cur.name = gate_name
    cur.node = node
    if old_name ~= gate_name or old_node ~= node then
        invalidate_gate_cache(player_id)
    end
    log.info("locator bind player_id=%s gate=%s node=%s", tostring(player_id), gate_name, tostring(node))
    return true
end

-- 仅清 gate。无 gate_name 时也只清连接，避免卸 agent 前误伤；卸人走 remove。
function M.unbind(player_id, gate_name, node)
    player_id = tonumber(player_id)
    if not player_id then
        return false
    end
    local cur = players[player_id]
    if not cur or not cur.name then
        return true
    end
    if gate_name and cur.name ~= gate_name then
        return false
    end
    if node and cur.node and cur.node ~= node then
        return false
    end
    cur.name = nil
    cur.node = nil
    invalidate_gate_cache(player_id)
    drop_if_empty(player_id)
    return true
end

function M.set_agent(player_id, agent)
    player_id = tonumber(player_id)
    if not player_id or not agent then
        return false
    end
    ensure(player_id).agent = agent
    return true
end

function M.get_agent(player_id)
    player_id = tonumber(player_id)
    local cur = player_id and players[player_id]
    return cur and cur.agent or nil
end

function M.get_agents(player_ids)
    if type(player_ids) ~= "table" then
        return {}
    end
    local t = {}
    for _, id in ipairs(player_ids) do
        local pid = tonumber(id)
        local cur = pid and players[pid]
        if cur and cur.agent then
            t[pid] = cur.agent
        end
    end
    return t
end

function M.get_gates(player_ids)
    if type(player_ids) ~= "table" then
        return {}
    end
    local t = {}
    for _, id in ipairs(player_ids) do
        local pid = tonumber(id)
        local cur = pid and players[pid]
        if cur and cur.name then
            t[pid] = { name = cur.name, node = cur.node }
        end
    end
    return t
end

-- 卸号：gate、agent 一起去掉
function M.remove(player_id)
    player_id = tonumber(player_id)
    local cur = player_id and players[player_id]
    if not cur then
        return true
    end
    if cur.name then
        invalidate_gate_cache(player_id)
    end
    players[player_id] = nil
    return true
end

function M.get(player_id)
    player_id = tonumber(player_id)
    local cur = player_id and players[player_id]
    if not cur or not cur.name then
        return nil
    end
    return { name = cur.name, node = cur.node, agent = cur.agent }
end

-- 服务注册表：name → node。同一节点心跳刷新；换节点要等旧租约过期，防脑裂。
function M.register_service(name, node)
    name = norm_name(name)
    if not name then
        return false, "invalid name"
    end
    node = node or ""
    local now = skynet.now()
    local old = services[name]
    if old and old.node ~= node and alive(old, now) then
        return false, "conflict"
    end
    local epoch = old and (old.epoch or 1) or 1
    if old and old.node ~= node then
        epoch = epoch + 1
        log.warning("locator service takeover name=%s %s -> %s epoch=%d", name, tostring(old.node), node, epoch)
    end
    services[name] = { node = node, ts = now, epoch = epoch }
    return true
end

function M.unregister_service(name, node)
    name = norm_name(name)
    local cur = name and services[name]
    if not cur then
        return true
    end
    if node and node ~= "" and cur.node ~= node then
        return false
    end
    services[name] = nil
    return true
end

function M.lookup_service(name)
    name = norm_name(name)
    local cur = name and services[name]
    if not cur then
        return nil
    end
    if not alive(cur, skynet.now()) then
        services[name] = nil
        return nil
    end
    return cur.node
end

function M.list_services()
    local now = skynet.now()
    local t = {}
    for name, info in pairs(services) do
        if alive(info, now) then
            t[name] = info.node
        end
    end
    return t
end

-- 分片注册表：(map_id, shard_id) → node。扩容时新进程启动即登记。
function M.register_shard(map_id, shard_id, node, service_name)
    local key, mid, sid = shard_key(map_id, shard_id)
    if not key then
        return false, "invalid shard"
    end
    node = node or ""
    local now = skynet.now()
    local old = shards[key]
    if old and old.node ~= node and alive(old, now) then
        return false, "conflict"
    end
    local epoch = old and (old.epoch or 1) or 1
    if old and old.node ~= node then
        epoch = epoch + 1
        log.warning("locator shard takeover key=%s %s -> %s epoch=%d", key, tostring(old.node), node, epoch)
    end
    shards[key] = {
        map_id = mid,
        shard_id = sid,
        node = node,
        name = service_name or (old and old.name),
        ts = now,
        epoch = epoch,
    }
    return true
end

function M.unregister_shard(map_id, shard_id, node)
    local key = shard_key(map_id, shard_id)
    local cur = key and shards[key]
    if not cur then
        return true
    end
    if node and node ~= "" and cur.node ~= node then
        return false
    end
    shards[key] = nil
    return true
end

function M.lookup_shard(map_id, shard_id)
    local key = shard_key(map_id, shard_id)
    local cur = key and shards[key]
    if not cur then
        return nil
    end
    if not alive(cur, skynet.now()) then
        shards[key] = nil
        return nil
    end
    return { node = cur.node, name = cur.name, epoch = cur.epoch }
end

function M.list_shards(map_id)
    map_id = tonumber(map_id)
    local now = skynet.now()
    local t = {}
    for _, info in pairs(shards) do
        if alive(info, now) and (not map_id or info.map_id == map_id) then
            t[#t + 1] = {
                map_id = info.map_id,
                shard_id = info.shard_id,
                node = info.node,
                name = info.name,
                epoch = info.epoch,
            }
        end
    end
    return t
end

-- 定时清理过期条目：节点下线后，注册表不会留下永远有效的死记录。
function M.prune()
    local now = skynet.now()
    local removed = 0
    for name, info in pairs(services) do
        if not alive(info, now) then
            services[name] = nil
            removed = removed + 1
            log.warning("locator service lease expired name=%s node=%s", name, tostring(info.node))
        end
    end
    for key, info in pairs(shards) do
        if not alive(info, now) then
            shards[key] = nil
            removed = removed + 1
            log.warning("locator shard lease expired key=%s node=%s", key, tostring(info.node))
        end
    end
    return removed
end

-- 玩家所在分片：分片切换时由 agent 回报，供门直连和其他服务定位，替代全片扫描。
function M.set_scene(player_id, map_id, shard_id, scene_id)
    player_id = tonumber(player_id)
    if not player_id then
        return false
    end
    local cur = ensure(player_id)
    cur.map_id = tonumber(map_id)
    cur.shard_id = tonumber(shard_id)
    cur.scene_id = tonumber(scene_id) or cur.scene_id
    return true
end

function M.clear_scene(player_id)
    player_id = tonumber(player_id)
    local cur = player_id and players[player_id]
    if not cur then
        return true
    end
    cur.map_id = nil
    cur.shard_id = nil
    cur.scene_id = nil
    drop_if_empty(player_id)
    return true
end

function M.get_scene(player_id)
    player_id = tonumber(player_id)
    local cur = player_id and players[player_id]
    if not cur or cur.shard_id == nil then
        return nil
    end
    return { map_id = cur.map_id, shard_id = cur.shard_id, scene_id = cur.scene_id }
end

function M.get_scenes(player_ids)
    if type(player_ids) ~= "table" then
        return {}
    end
    local t = {}
    for _, id in ipairs(player_ids) do
        local pid = tonumber(id)
        local cur = pid and players[pid]
        if cur and cur.shard_id ~= nil then
            t[pid] = { map_id = cur.map_id, shard_id = cur.shard_id, scene_id = cur.scene_id }
        end
    end
    return t
end

function M.kick(player_id, reason, message)
    player_id = tonumber(player_id)
    local cur = player_id and players[player_id]
    if not cur or not cur.name then
        return false
    end
    local name, node = cur.name, cur.node
    local gate = rpc.named(name, node)
    local ok = false
    if gate then
        ok = skynet.call(gate, "lua", "kick_player", player_id, reason, message)
    end
    M.unbind(player_id, name, node)
    return ok
end

function M.count()
    local n = 0
    for _, cur in pairs(players) do
        if cur.name then
            n = n + 1
        end
    end
    return n
end

-- locator 重启后从门恢复玩家目录。已被实时绑定覆盖的条目不回滚。
function M.restore_gate(gate_name, node, list)
    if type(gate_name) ~= "string" or gate_name == "" or type(list) ~= "table" then
        return 0
    end
    local n = 0
    for _, ent in ipairs(list) do
        local pid, agent
        if type(ent) == "table" then
            pid = tonumber(ent.player_id)
            agent = ent.agent
        else
            pid = tonumber(ent)
        end
        if pid then
            local cur = players[pid]
            if not (cur and cur.name) then
                cur = ensure(pid)
                cur.name = gate_name
                cur.node = node
            end
            if agent and not cur.agent then
                cur.agent = agent
            end
            n = n + 1
        end
    end
    return n
end

-- 向所有门要当前在线玩家。返回：就绪门数、门总数、恢复玩家数。
function M.rebuild()
    local total = 0
    local ready = 0
    local restored = 0
    for _, id in ipairs(layout.gate_ids()) do
        total = total + 1
        local name = layout.gate_name(id)
        local node = layout.gate_home_node()
        local addr = rpc.named(name, node)
        if addr then
            local ok, list = pcall(skynet.call, addr, "lua", "list_players")
            if ok and type(list) == "table" then
                ready = ready + 1
                restored = restored + M.restore_gate(name, node, list)
            end
        end
    end
    return ready, total, restored
end

function M.init()
    if M._inited then
        return true
    end
    M._inited = true
    log.info("locator service started")

    local function prune_tick()
        skynet.timeout(PRUNE_INTERVAL, prune_tick)
        local ok, removed = pcall(M.prune)
        if not ok then
            log.error("locator prune failed: %s", tostring(removed))
        end
    end
    skynet.timeout(PRUNE_INTERVAL, prune_tick)

    -- game 先起、门后起也兼容：循环到所有门都能回报为止
    skynet.fork(function()
        for _ = 1, 60 do
            local ok, ready, total, restored = pcall(M.rebuild)
            if ok and ready >= total then
                log.info("locator players rebuilt=%d gates=%d", restored, ready)
                return
            end
            skynet.sleep(200)
        end
        log.warning("locator player rebuild incomplete, some gates unreachable")
    end)
    return true
end

return M
