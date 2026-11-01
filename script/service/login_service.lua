local skynet = require "skynet"
local log = require "log"
local protocol_handler = require "protocol_handler"
local service_ctx = require "runtime.service_ctx"
local layout = require "cluster.layout"
local rpc = require "cluster.rpc"

local M = service_ctx.get("login.login", {})
M.account_loading = M.account_loading or {}
M.account_info = M.account_info or {}
M.agent_pool = M.agent_pool or {}
M.agent_to_accounts = M.agent_to_accounts or {}
M.dead_agents = M.dead_agents or {}
M.CLIENT = M.CLIENT or {}
M._protocol_registered = M._protocol_registered or false
M._inited = M._inited or false

local account_loading = M.account_loading
local account_info = M.account_info
local agent_pool = M.agent_pool
local agent_to_accounts = M.agent_to_accounts
local dead_agents = M.dead_agents
local CLIENT = M.CLIENT
local INIT_AGENT_COUNT = 3

local function get_security_service()
    return skynet.localname(".security")
end

local function check_security(ip, account_key, action)
    local security = get_security_service()
    if not security then
        log.warning("Security service not available")
        return true
    end

    local is_safe, message = skynet.call(security, "lua", "check_request_safety", { account = account_key }, ip, account_key, action or "login")
    if not is_safe then
        log.warning("Security check failed for %s: %s", account_key, message)
    end
    return is_safe, message
end

local function verify_token(token_str)
    local security = get_security_service()
    if not security then
        log.warning("Security service not available for token verification")
        return false
    end
    return skynet.call(security, "lua", "verify_token", token_str)
end

-- 接管一个已存在的 agent（登录服重启时从 agent 自己的账号表恢复映射）
local function adopt_agent(handle)
    if not handle or agent_to_accounts[handle] then
        return
    end
    agent_pool[#agent_pool + 1] = handle
    agent_to_accounts[handle] = {}
    local ok, list = pcall(skynet.call, handle, "lua", "list_accounts")
    if ok and type(list) == "table" then
        for _, info in ipairs(list) do
            local key = info.account_key
            if key then
                agent_to_accounts[handle][#agent_to_accounts[handle] + 1] = key
                if not account_info[key] then
                    account_info[key] = { agent = handle, logout = info.logout == true }
                end
            end
        end
    end
end

local function init_agent_pool()
    if #agent_pool > 0 then
        return
    end
    local count = tonumber(skynet.getenv("agent_count")) or INIT_AGENT_COUNT
    local sup = skynet.localname(".supervisor")
    log.info("Initializing agent pool with %d agents", count)
    if sup then
        -- 先接管 supervisor 已知的全部 agent（含按需扩容出来的）
        local ok, list = pcall(skynet.call, sup, "lua", "agents")
        if ok and type(list) == "table" then
            for _, h in ipairs(list) do
                adopt_agent(h)
            end
        end
    end
    for i = 1, count do
        local agent
        if sup then
            local ok, result = pcall(skynet.call, sup, "lua", "ensure_agent", i)
            if ok then
                agent = result
            end
        end
        if not agent then
            agent = skynet.newservice("agentS", i)
        end
        adopt_agent(agent)
    end
    M.next_agent_id = math.max(M.next_agent_id or 0, count + 1)
end

local function get_available_agent()
    local min_load
    local selected_agent = nil
    for _, agent in ipairs(agent_pool) do
        if not dead_agents[agent] then
            local account_count = #(agent_to_accounts[agent] or {})
            if not min_load or account_count < min_load then
                min_load = account_count
                selected_agent = agent
            end
        end
    end
    if selected_agent then
        return selected_agent
    end
    -- 所有 agent 都不可用：按需补一个，supervisor 负责后续监督
    local id = M.next_agent_id or 1
    M.next_agent_id = id + 1
    local sup = skynet.localname(".supervisor")
    if sup then
        local ok, h = pcall(skynet.call, sup, "lua", "ensure_agent", id)
        if ok then
            selected_agent = h
        end
    end
    if not selected_agent then
        selected_agent = skynet.newservice("agentS", id)
    end
    adopt_agent(selected_agent)
    return selected_agent
end

local function assign_account_to_agent(agent, account_key)
    agent_to_accounts[agent] = agent_to_accounts[agent] or {}
    table.insert(agent_to_accounts[agent], account_key)
end

local function login_rpc_ok(fd, session, player_id, player_name, gate)
    protocol_handler.rpc_response(fd, session, {
        success = true,
        player_id = player_id or 0,
        player_name = player_name or "",
    }, gate)
end

local function remove_account_from_agent(agent, account_key)
    if not agent_to_accounts[agent] then
        return
    end
    for i, acc_key in ipairs(agent_to_accounts[agent]) do
        if acc_key == account_key then
            table.remove(agent_to_accounts[agent], i)
            break
        end
    end
end

local function reply_client(fd, gate, name, data)
    protocol_handler.send_to_client(fd, name, data, gate)
end

function CLIENT.login(fd, msg, session, gate, gate_name, gate_node)
    if not gate or type(gate_name) ~= "string" or gate_name == "" then
        log.error("login missing gate, fd=%s", tostring(fd))
        return
    end
    local account_key = msg.account_id
    local ip = msg.ip
    local device_id = msg.device_id
    local gateS = gate
    local gate_args = {
        fd = fd,
        gate = gateS,
    }

    if not account_key or account_key == "" then
        log.warning("Login rejected: empty account_id, fd=%d", fd)
        reply_client(fd, gateS, "error", { code = 1001, message = "账号标识无效" })
        return
    end
    if #account_key > 20 then
        log.warning("Login rejected: account_id too long, fd=%d, len=%d", fd, #account_key)
        reply_client(fd, gateS, "error", { code = 1001, message = "账号标识长度不能超过20" })
        return
    end

    local is_safe, message = check_security(ip, account_key)
    if not is_safe then
        log.warning("Login rejected due to security concerns: %s, account_key: %s", message, account_key)
        protocol_handler.rpc_response(fd, session, { success = false, player_id = 0, player_name = "" }, gateS)
        return
    end
    log.info("login request, fd=%d, account_key=%s gate=%s", fd, account_key, tostring(gate_name))
    local ainfo = account_info[account_key]
    -- agent 已挂：清掉旧信息，按新登录处理（连接会由 agent_down 踢掉）
    if ainfo and ainfo.agent and dead_agents[ainfo.agent] then
        account_info[account_key] = nil
        ainfo = nil
    end
    if ainfo and ainfo.agent then
        if ainfo.logout then
            local ok = M.reconnect(account_key, fd, gate_args)
            if ok then
                login_rpc_ok(fd, session, nil, nil, gateS)
                if gateS then
                    skynet.send(gateS, "lua", "bound_agent", fd, account_key, ainfo.agent)
                end
                return
            end
            -- 重连失败：清掉旧信息，继续按新登录处理
            account_info[account_key] = nil
            ainfo = nil
        else
            local call_ok, ready = pcall(skynet.call, ainfo.agent, "lua", "is_account_ready", account_key)
            if not call_ok then
                M.agent_down(ainfo.agent, account_key)
                account_info[account_key] = nil
                ainfo = nil
            elseif not ready then
                reply_client(fd, gateS, "login_failed", { reason = "账号加载中，请稍后再试" })
                return
            else
                ainfo.last_login_ip = ip
                ainfo.last_login_time = os.date("%Y-%m-%d %H:%M:%S", os.time())
                ainfo.device_id = device_id
                ainfo.logout = false
                local kick_ok, kicked = pcall(skynet.call, ainfo.agent, "lua", "kicked_out", account_key, fd, gate_args)
                if not kick_ok then
                    M.agent_down(ainfo.agent, account_key)
                    account_info[account_key] = nil
                    ainfo = nil
                elseif not kicked then
                    reply_client(fd, gateS, "login_failed", { reason = "顶号失败，请稍后重试" })
                    return
                else
                    login_rpc_ok(fd, session, nil, nil, gateS)
                    if gateS then
                        skynet.send(gateS, "lua", "bound_agent", fd, account_key, ainfo.agent)
                    end
                    return
                end
            end
        end
    end

    if account_loading[account_key] then
        log.error(string.format("Account %s is already loading", account_key))
        reply_client(fd, gateS, "login_failed", { reason = "账号正在加载中，请稍后再试" })
        return
    end

    account_loading[account_key] = true
    local db = skynet.localname(".db")
    local data = skynet.call(db, "lua", "query_account", account_key)
    local account_data
    if not next(data) then
        account_data = {
            account_key = account_key,
            players = {},
            register_ip = ip,
            register_time = os.date("%Y-%m-%d %H:%M:%S", os.time()),
            last_login_ip = ip,
            last_login_time = os.date("%Y-%m-%d %H:%M:%S", os.time()),
            device_id = device_id,
        }
        local ret = skynet.call(db, "lua", "create_account", account_key, account_data)
        if not ret then
            log.error(string.format("Failed to create account %s", account_key))
            account_loading[account_key] = nil
            reply_client(fd, gateS, "login_failed", { reason = "创建账号失败" })
            return
        end
    else
        data = data[1]
        account_data = {
            account_key = data.account_key,
            players = data.players,
            register_ip = data.register_ip or ip,
            register_time = data.register_time or os.date("%Y-%m-%d %H:%M:%S", os.time()),
            last_login_ip = ip,
            last_login_time = os.date("%Y-%m-%d %H:%M:%S", os.time()),
            device_id = device_id,
        }
        skynet.send(db, "lua", "update_account_login", account_key, ip, os.time(), device_id)
    end

    local agent = get_available_agent()
    if not agent then
        log.error("No agent available for account %s", account_key)
        account_loading[account_key] = nil
        reply_client(fd, gateS, "login_failed", { reason = "登录失败" })
        return
    end
    local call_ok, start_ok, start_err = pcall(skynet.call, agent, "lua", "start", account_key, account_data, gate_args)
    if not call_ok then
        -- agent 已死：剔除后换一个重试一次
        M.agent_down(agent, account_key)
        local retry = get_available_agent()
        if retry and retry ~= agent then
            call_ok, start_ok, start_err = pcall(skynet.call, retry, "lua", "start", account_key, account_data, gate_args)
            if call_ok then
                agent = retry
            end
        end
    end
    if not (call_ok and start_ok) then
        log.error("Failed to start agent for account %s: %s", account_key, tostring(start_err))
        account_loading[account_key] = nil
        reply_client(fd, gateS, "login_failed", { reason = "登录失败" })
        return
    end

    assign_account_to_agent(agent, account_key)
    account_info[account_key] = {
        agent = agent,
        logout = false,
        last_login_ip = ip,
        last_login_time = os.date("%Y-%m-%d %H:%M:%S", os.time()),
        device_id = device_id,
    }
    login_rpc_ok(fd, session, nil, nil, gateS)
    if gateS then
        skynet.send(gateS, "lua", "bound_agent", fd, account_key, agent)
    end
end

function CLIENT.token_login(fd, msg, session, gate, gate_name, gate_node)
    local ip = msg.ip
    local device_id = msg.device_id
    local token_str = msg.token

    local is_valid, account_key, token_data = verify_token(token_str)
    if not is_valid then
        log.warning("Invalid token login attempt from IP: %s", ip or "unknown")
        protocol_handler.send_to_client(fd, "login_failed", { reason = "令牌无效或已过期" }, gate)
        return
    end

    local is_safe, message = check_security(ip, account_key, "token_login")
    if not is_safe then
        log.warning("Token login rejected due to security concerns: %s", message)
        protocol_handler.send_to_client(fd, "login_failed", { reason = message }, gate)
        return
    end

    if token_data.did and device_id and token_data.did ~= device_id then
        log.warning("Token login device mismatch: %s vs %s", token_data.did, device_id)
        local security = get_security_service()
        if security then
            skynet.send(security, "lua", "add_to_blacklist", ip, "设备不匹配，可能的令牌盗用", 3600)
        end
        protocol_handler.send_to_client(fd, "login_failed", { reason = "设备不匹配，拒绝登录" }, gate)
        return
    end

    CLIENT.login(fd, { account_id = account_key, ip = ip, device_id = device_id }, session, gate, gate_name, gate_node)
end

function M.account_update(account_key, account_data)
    local db = skynet.localname(".db")
    skynet.send(db, "lua", "update_account", account_key, { account_key = account_key, players = account_data.players })
end

function M.account_loaded(account_key)
    if not account_info[account_key] then
        log.error(string.format("Account %s not found", account_key))
        return false
    end
    account_loading[account_key] = nil
end

function M.account_exit(account_key)
    if not account_info[account_key] then
        log.error(string.format("Account %s not found", account_key))
        return false
    end
    account_info[account_key] = nil
end

function M.disconnect(account_key, fd)
    local ainfo = account_info[account_key]
    if not ainfo then
        -- agent 挂掉时已清过，断开事件可以安全忽略
        return true
    end
    if ainfo.logout then
        return true
    end
    if ainfo.agent and dead_agents[ainfo.agent] then
        ainfo.agent = nil
        ainfo.logout = true
        return true
    end
    if ainfo.agent then
        local call_ok, should = pcall(skynet.call, ainfo.agent, "lua", "should_handle_disconnect", account_key, fd)
        if not call_ok then
            M.agent_down(ainfo.agent, account_key)
            ainfo.agent = nil
            ainfo.logout = true
            return true
        end
        if not should then
            log.info("ignore stale disconnect, account_key=%s, fd=%s", account_key, tostring(fd))
            return true
        end
    end
    ainfo.logout = true
    if ainfo.agent then
        skynet.send(ainfo.agent, "lua", "disconnect", account_key)
    end
    return true
end

function M.logout(account_key)
    if not account_info[account_key] then
        log.error(string.format("Account %s not found", account_key))
        return false
    end
    account_info[account_key].logout = true
    return true
end

function M.reconnect(account_key, fd, gate_args)
    local ainfo = account_info[account_key]
    if not ainfo or not ainfo.agent or not ainfo.logout then
        return false
    end
    if dead_agents[ainfo.agent] then
        return false
    end
    ainfo.reconnecting = true
    local call_ok, ok = pcall(skynet.call, ainfo.agent, "lua", "reconnect", account_key, fd, gate_args)
    if not call_ok or not ok then
        if not call_ok then
            M.agent_down(ainfo.agent, account_key)
            ainfo.agent = nil
        end
        log.error(string.format("Failed to reconnect account %s", account_key))
        ainfo.reconnecting = false
        return false
    end
    ainfo.logout = false
    ainfo.reconnecting = false
    return true
end

function M.agent_exit(account_key)
    local ainfo = account_info[account_key]
    if ainfo and ainfo.agent then
        remove_account_from_agent(ainfo.agent, account_key)
    end
    account_info[account_key] = nil
    return true
end

-- supervisor 通知：agent 进程退出，立即剔除并让受影响玩家重新登录
function M.agent_down(agent_handle, skip_account)
    agent_handle = tonumber(agent_handle)
    if not agent_handle then
        return false
    end
    dead_agents[agent_handle] = true
    local list = agent_to_accounts[agent_handle] or {}
    for i = #agent_pool, 1, -1 do
        if agent_pool[i] == agent_handle then
            table.remove(agent_pool, i)
        end
    end
    agent_to_accounts[agent_handle] = nil
    if #list > 0 then
        local gates = {}
        for _, gid in ipairs(layout.gate_ids()) do
            local addr = rpc.named(layout.gate_name(gid), layout.gate_home_node())
            if addr then
                gates[#gates + 1] = addr
            end
        end
        for _, account_key in ipairs(list) do
            local ainfo = account_info[account_key]
            if ainfo and ainfo.agent == agent_handle then
                ainfo.agent = nil
                ainfo.logout = true
            end
            -- 正在处理这个账号的登录请求时不要踢，否则会误伤随后绑定的新连接
            if account_key ~= skip_account then
                for _, gate in ipairs(gates) do
                    pcall(skynet.send, gate, "lua", "kick_account", account_key,
                        "agent_restarted", "服务器节点重建，请重新登录")
                end
            end
        end
    end
    log.warning("agent down, handle=%s, accounts=%d", tostring(agent_handle), #list)
    return true
end

-- supervisor 通知：agent 已重建，加入池；账号会从新 agent 的 list_accounts 恢复
function M.agent_up(agent_handle, agent_id)
    agent_handle = tonumber(agent_handle)
    if not agent_handle then
        return false
    end
    dead_agents[agent_handle] = nil
    adopt_agent(agent_handle)
    return true
end

function M.get_agent_pool_status()
    local result = { agent_count = #agent_pool, agent_stats = {} }
    for _, agent in ipairs(agent_pool) do
        local accounts = agent_to_accounts[agent] or {}
        table.insert(result.agent_stats, { agent = agent, account_count = #accounts, accounts = accounts })
    end
    return result
end

function M.add_to_blacklist(ip, reason, duration)
    local security = get_security_service()
    if not security then
        log.error("Security service not available for blacklist operation")
        return false
    end
    return skynet.send(security, "lua", "add_to_blacklist", ip, reason, duration)
end

function M.check_ip_blacklist(ip)
    local security = get_security_service()
    if not security then
        log.warning("Security service not available for IP check")
        return false
    end
    local is_safe, message = skynet.call(security, "lua", "check_request_safety", { ip = ip }, ip)
    return not is_safe, message
end

function M.after_hotfix(hotfix_name)
    log.info("Login service after hotfix %s", hotfix_name)
    skynet.fork(function()
        for _, agent in ipairs(agent_pool) do
            skynet.send(agent, "lua", "hotfix", hotfix_name)
        end
    end)
end

function M.dispatch_client(fd, name, args, session, gate, gate_name, gate_node)
    if CLIENT[name] then
        local ok = pcall(CLIENT[name], fd, args, session, gate, gate_name, gate_node)
        if not ok then
            log.error(string.format("Error handling message %s from fd: %s", name, fd))
        end
    else
        log.error(string.format("Unknown message type: %s, from fd: %s", name, fd))
    end
end

function M.register_client_protocol()
    if M._protocol_registered then
        return
    end
    M._protocol_registered = true
    skynet.register_protocol({
        name = "client",
        id = skynet.PTYPE_CLIENT,
        unpack = function(msg, sz)
            return skynet.unpack(msg, sz)
        end,
        dispatch = function(fd, gate, name, args, session, gate_name, gate_node)
            skynet.ignoreret()
            M.dispatch_client(fd, name, args, session, gate, gate_name, gate_node)
        end,
    })
end

function M.init()
    M.register_client_protocol()
    if M._inited then
        return
    end
    M._inited = true
    -- 延迟到 init 返回之后：supervisor 重启本服务时会阻塞在 newservice，
    -- 这里再反向 call supervisor 才不会卡住启动
    skynet.timeout(0, function()
        init_agent_pool()
        log.info("Login service started with %d agents in pool", #agent_pool)
    end)
end

return M
