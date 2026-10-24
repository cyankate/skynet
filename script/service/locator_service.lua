-- 在线目录：player_id → gate + agent。
-- gate 随连接变；agent 跟逻辑进程，闪断宽限期内仍在。
-- 分片直推查 gate；业务下行 / call_agent 查 agent。
local skynet = require "skynet"
local log = require "log"
local rpc = require "cluster.rpc"
local shard = require "map.shard"
local service_ctx = require "runtime.service_ctx"

local M = service_ctx.get("locator.locator", {})
M.players = M.players or {}
local players = M.players

local function invalidate_gate_cache(player_id)
    local map_id = shard.DEFAULT_MAP_ID
    for _, sid in ipairs(shard.all_ids()) do
        local addr = shard.addr(map_id, sid)
        if addr then
            skynet.send(addr, "lua", "forget_player_gate", player_id)
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

function M.init()
    if M._inited then
        return true
    end
    M._inited = true
    log.info("locator service started")
    return true
end

return M
