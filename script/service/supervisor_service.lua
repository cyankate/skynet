-- 进程内服务监督：接管 skynet 的退出通知，按 spec 重启本节点服务。
-- 只管理同一个 OS 进程里的服务；跨节点分片由各自节点的 supervisor 负责。
local skynet = require "skynet"
local log = require "log"
local service_ctx = require "runtime.service_ctx"

local M = service_ctx.get("supervisor.supervisor", {})
M.watched = M.watched or {}
M.stats = M.stats or {}
M.pending_agents = M.pending_agents or {}
local watched = M.watched
local stats = M.stats
local pending_agents = M.pending_agents

local RESTART_WINDOW = 6000 -- 60 秒内连续重启才计数
local MAX_DELAY = 3000      -- 退避上限 30 秒
local DEFAULT_MAX = 10

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
    watched[handle] = spec
    stats[handle] = st or { restarts = 0, since = skynet.now() }
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
    local st = stats[handle] or { restarts = 0, since = skynet.now() }
    stats[handle] = nil

    notify(spec.on_down, handle)

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
    watched[handle] = spec
    stats[handle] = stats[handle] or { restarts = 0, since = skynet.now() }
    return true
end

function M.unwatch(handle)
    watched[handle] = nil
    stats[handle] = nil
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
    log.info("supervisor started")
    return true
end

return M
