-- 进程内服务监督：接管 skynet 的退出通知，按 spec 重启本节点服务。
-- 只管理同一个 OS 进程里的服务；跨节点分片由各自节点的 supervisor 负责。
local skynet = require "skynet"
local log = require "log"
local rpc = require "cluster.rpc"
local service_ctx = require "runtime.service_ctx"
require "skynet.manager"

local M = service_ctx.get("supervisor.supervisor", {})
M.watched = M.watched or {}
M.stats = M.stats or {}
M.pending_agents = M.pending_agents or {}
M.misses = M.misses or {}
local watched = M.watched
local stats = M.stats
local pending_agents = M.pending_agents
local misses = M.misses

local RESTART_WINDOW = 6000 -- 60 秒内连续重启才计数
local MAX_DELAY = 3000      -- 退避上限 30 秒
local DEFAULT_MAX = 10

-- 看门狗：30 秒 ping 一次，0.5 秒超时；连续 3 次无响应视为卡死
local WATCHDOG_INTERVAL = 3000
local PING_TIMEOUT = 50
local MAX_MISSES = 3
local MAX_KILLS = 3

local function find_agent(agent_id)
    for h, spec in pairs(watched) do
        if spec.kind == "agent" and spec.agent_id == agent_id then
            return h, spec
        end
    end
    return nil
end

local function notify(target, handle)
    if type(target) ~= "table" or type(target.name) ~= "string" then
        return
    end
    local addr = skynet.localname(target.name)
    if not addr then
        return
    end
    local args = { handle }
    for _, v in ipairs(target.args or {}) do
        args[#args + 1] = v
    end
    pcall(skynet.send, addr, "lua", target.method, table.unpack(args))
end

local spawn

local function schedule_restart(spec, st)
    local delay = math.min(100 * 2 ^ (st.restarts - 1), MAX_DELAY)
    local agent_id = spec.kind == "agent" and spec.agent_id or nil
    if agent_id then
        pending_agents[agent_id] = true
    end
    skynet.timeout(delay, function()
        if agent_id then
            -- ensure_agent 可能已经提前重建了，丢掉这次计划
            if not pending_agents[agent_id] then
                return
            end
            pending_agents[agent_id] = nil
        end
        if not spawn(spec, st) then
            st.restarts = st.restarts + 1
            if st.restarts <= spec.max_restarts then
                schedule_restart(spec, st)
            else
                log.error("supervisor: giving up %s after %d restarts", spec.entry, st.restarts)
            end
        end
    end)
end

function spawn(spec, st)
    local ok, handle = pcall(skynet.newservice, spec.entry, table.unpack(spec.args or {}))
    if not ok or not handle then
        log.error("supervisor: restart %s failed: %s", spec.entry, tostring(handle))
        return nil
    end
    spec.down_notified = false
    spec.hang_logged = false
    spec.kill_attempts = 0
    spec.kill_gave_up = false
    watched[handle] = spec
    stats[handle] = st or { restarts = 0, since = skynet.now() }
    misses[handle] = nil
    if spec.start_call then
        local sc = spec.start_call
        local ok2, err = pcall(skynet.call, handle, "lua", sc.method, table.unpack(sc.args or {}))
        if not ok2 then
            log.error("supervisor: start_call %s failed: %s", tostring(sc.method), tostring(err))
        end
    end
    log.warning("supervisor: restarted %s as %s", spec.entry, skynet.address(handle))
    notify(spec.on_up, handle)
    return handle
end

local function on_exit(handle)
    local spec = watched[handle]
    if not spec then
        return
    end
    watched[handle] = nil
    misses[handle] = nil
    local st = stats[handle] or { restarts = 0, since = skynet.now() }
    stats[handle] = nil

    if not spec.down_notified then
        notify(spec.on_down, handle)
    end

    if spec.restart == false then
        log.error("supervisor: %s exited (auto-restart disabled)", spec.entry)
        return
    end
    local now = skynet.now()
    if now - (st.since or now) > RESTART_WINDOW then
        st.restarts = 0
        st.since = now
    end
    st.restarts = st.restarts + 1
    if st.restarts > (spec.max_restarts or DEFAULT_MAX) then
        log.error("supervisor: giving up %s after %d restarts", spec.entry, st.restarts)
        return
    end
    schedule_restart(spec, st)
end

function M.watch(handle, spec)
    if type(handle) ~= "number" or type(spec) ~= "table" or type(spec.entry) ~= "string" then
        return false
    end
    spec.args = spec.args or {}
    spec.max_restarts = spec.max_restarts or DEFAULT_MAX
    spec.down_notified = false
    spec.hang_logged = false
    spec.kill_attempts = 0
    spec.kill_gave_up = false
    watched[handle] = spec
    stats[handle] = stats[handle] or { restarts = 0, since = skynet.now() }
    misses[handle] = nil
    return true
end

function M.unwatch(handle)
    watched[handle] = nil
    stats[handle] = nil
    misses[handle] = nil
    return true
end

function M.list()
    local t = {}
    for h, spec in pairs(watched) do
        t[#t + 1] = {
            handle = h,
            entry = spec.entry,
            kind = spec.kind,
            agent_id = spec.agent_id,
        }
    end
    return t
end

function M.agents()
    local t = {}
    for h, spec in pairs(watched) do
        if spec.kind == "agent" then
            t[#t + 1] = h
        end
    end
    return t
end

local function agent_spec(agent_id)
    return {
        entry = "agentS",
        args = { agent_id },
        kind = "agent",
        agent_id = agent_id,
        on_down = { name = ".login", method = "agent_down" },
        on_up = { name = ".login", method = "agent_up", args = { agent_id } },
    }
end

-- 登录服初始化/重启时调用：保证指定 id 的 agent 存在，返回 handle。
-- 如果这个 id 正在等待重启，这里直接提前重建，取消原来的计划。
function M.ensure_agent(agent_id)
    agent_id = tonumber(agent_id)
    if not agent_id then
        return nil
    end
    local h = find_agent(agent_id)
    if h then
        return h
    end
    pending_agents[agent_id] = nil
    return spawn(agent_spec(agent_id))
end

-- 连续 PING 无响应：先通知 on_down（agent 走登录服剔除/踢人），
-- 再尝试 kill；真正的重启仍由退出通知 on_exit 统一处理，避免重复拉起。
local function on_hung(handle, spec)
    if not spec.down_notified then
        spec.down_notified = true
        notify(spec.on_down, handle)
        log.error("supervisor: %s %s unresponsive, notifying",
            spec.entry, skynet.address(handle))
    end
    if spec.kill_on_hang == false or spec.restart == false then
        if not spec.hang_logged then
            spec.hang_logged = true
            log.error("supervisor: %s hung, auto-kill disabled (manual intervention)", spec.entry)
        end
        return
    end
    spec.kill_attempts = (spec.kill_attempts or 0) + 1
    if spec.kill_attempts > MAX_KILLS then
        if not spec.kill_gave_up then
            spec.kill_gave_up = true
            log.error("supervisor: %s still hung after %d kills, giving up",
                spec.entry, MAX_KILLS)
        end
        return
    end
    log.error("supervisor: killing hung %s (%s), attempt %d",
        spec.entry, skynet.address(handle), spec.kill_attempts)
    pcall(skynet.kill, handle)
end

-- 手动触发一轮检查（定时器也会调它）
function M.watchdog()
    local handles = {}
    for h, spec in pairs(watched) do
        if spec.watchdog ~= false then
            handles[#handles + 1] = h
        end
    end
    for _, h in ipairs(handles) do
        local spec = watched[h]
        if spec then
            local ok = rpc.call_timeout(h, PING_TIMEOUT, "ping")
            if ok then
                misses[h] = 0
                -- 还没走到 kill 的误报允许恢复
                if (spec.kill_attempts or 0) == 0 then
                    spec.down_notified = false
                    spec.hang_logged = false
                end
            else
                local n = (misses[h] or 0) + 1
                misses[h] = n
                if n >= MAX_MISSES then
                    on_hung(h, spec)
                end
            end
        end
    end
end

function M.init()
    if M._inited then
        return true
    end
    M._inited = true
    skynet.register_protocol({
        name = "client",
        id = skynet.PTYPE_CLIENT,
        unpack = function() end,
        dispatch = function(_, source)
            on_exit(source)
        end,
    })
    -- 与 skynet.monitor 相同的底层命令：把自己设为进程级退出通知接收者
    local core = require "skynet.core"
    core.command("MONITOR", string.format(":%08x", skynet.self()))

    local function watchdog_tick()
        skynet.timeout(WATCHDOG_INTERVAL, watchdog_tick)
        skynet.fork(function()
            local ok, err = pcall(M.watchdog)
            if not ok then
                log.error("supervisor watchdog failed: %s", tostring(err))
            end
        end)
    end
    skynet.timeout(WATCHDOG_INTERVAL, watchdog_tick)

    log.info("supervisor started")
    return true
end

return M
