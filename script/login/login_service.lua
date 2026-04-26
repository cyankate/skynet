local skynet = require "skynet"
local log = require "log"
local protocol_handler = require "protocol_handler"
local service_ctx = require "runtime.service_ctx"

local M = service_ctx.get("login.login", {})
M.account_loading = M.account_loading or {}
M.account_info = M.account_info or {}
M.agent_pool = M.agent_pool or {}
M.agent_to_accounts = M.agent_to_accounts or {}
M.CLIENT = M.CLIENT or {}
M._protocol_registered = M._protocol_registered or false
M._inited = M._inited or false

local account_loading = M.account_loading
local account_info = M.account_info
local agent_pool = M.agent_pool
local agent_to_accounts = M.agent_to_accounts
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

local function init_agent_pool()
    if #agent_pool > 0 then
        return
    end
    log.info("Initializing agent pool with %d agents", INIT_AGENT_COUNT)
    for i = 1, INIT_AGENT_COUNT do
        local agent = skynet.newservice("agentS", i)
        table.insert(agent_pool, agent)
        agent_to_accounts[agent] = agent_to_accounts[agent] or {}
    end
end

local function get_available_agent()
    local min_load
    local selected_agent = nil
    for _, agent in ipairs(agent_pool) do
        local account_count = #(agent_to_accounts[agent] or {})
        if not min_load or account_count < min_load then
            min_load = account_count
            selected_agent = agent
        end
    end
    return selected_agent
end

local function assign_account_to_agent(agent, account_key)
    agent_to_accounts[agent] = agent_to_accounts[agent] or {}
    table.insert(agent_to_accounts[agent], account_key)
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

function CLIENT.login(fd, msg, session)
    local account_key = msg.account_id
    local ip = msg.ip
    local device_id = msg.device_id

    local is_safe, message = check_security(ip, account_key)
    if not is_safe then
        log.warning("Login rejected due to security concerns: %s, account_key: %s", message, account_key)
        protocol_handler.rpc_response(fd, session, { success = false, player_id = 0, player_name = "" })
        return
    end

    protocol_handler.rpc_response(fd, session, { success = true, player_id = 0, player_name = "test" })

    local gateS = skynet.localname(".gate")
    local ainfo = account_info[account_key]
    if ainfo and ainfo.agent then
        if ainfo.logout then
            local ok = M.reconnect(account_key, fd)
            if ok then
                skynet.send(gateS, "lua", "bound_agent", fd, account_key, ainfo.agent)
                return
            end
        end

        ainfo.last_login_ip = ip
        ainfo.last_login_time = os.date("%Y-%m-%d %H:%M:%S", os.time())
        ainfo.device_id = device_id
        skynet.send(ainfo.agent, "lua", "kicked_out", account_key, fd)
        skynet.send(gateS, "lua", "bound_agent", fd, account_key, ainfo.agent)
        return
    end

    if account_loading[account_key] then
        log.error(string.format("Account %s is already loading", account_key))
        protocol_handler.send_to_client(fd, "login_failed", { reason = "账号正在加载中，请稍后再试" })
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
            protocol_handler.send_to_client(fd, "login_failed", { reason = "创建账号失败" })
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
    local ok = skynet.send(agent, "lua", "start", account_key, account_data, { fd = fd })
    if not ok then
        log.error(string.format("Failed to start agent for account %s", account_key))
        account_loading[account_key] = nil
        protocol_handler.send_to_client(fd, "login_failed", { reason = "登录失败" })
        return
    end

    assign_account_to_agent(agent, account_key)
    account_info[account_key] = {
        agent = agent,
        last_login_ip = ip,
        last_login_time = os.date("%Y-%m-%d %H:%M:%S", os.time()),
        device_id = device_id,
    }
    skynet.send(gateS, "lua", "bound_agent", fd, account_key, agent)
end

function M.token_login(fd, msg)
    local ip = msg.ip
    local device_id = msg.device_id
    local token_str = msg.token

    local is_valid, account_key, token_data = verify_token(token_str)
    if not is_valid then
        log.warning("Invalid token login attempt from IP: %s", ip or "unknown")
        protocol_handler.send_to_client(fd, "login_failed", { reason = "令牌无效或已过期" })
        return
    end

    local is_safe, message = check_security(ip, account_key, "token_login")
    if not is_safe then
        log.warning("Token login rejected due to security concerns: %s", message)
        protocol_handler.send_to_client(fd, "login_failed", { reason = message })
        return
    end

    if token_data.did and device_id and token_data.did ~= device_id then
        log.warning("Token login device mismatch: %s vs %s", token_data.did, device_id)
        local security = get_security_service()
        if security then
            skynet.send(security, "lua", "add_to_blacklist", ip, "设备不匹配，可能的令牌盗用", 3600)
        end
        protocol_handler.send_to_client(fd, "login_failed", { reason = "设备不匹配，拒绝登录" })
        return
    end

    CLIENT.login(fd, { account_id = account_key, ip = ip, device_id = device_id })
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

function M.disconnect(account_key)
    if not account_info[account_key] then
        log.error(string.format("Account %s not found", account_key))
        return false
    end
    if account_info[account_key].logout then
        return true
    end
    account_info[account_key].logout = true
    skynet.send(account_info[account_key].agent, "lua", "disconnect", account_key)
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

function M.reconnect(account_key, fd)
    local ainfo = account_info[account_key]
    if not ainfo or not ainfo.agent or not ainfo.logout then
        return false
    end
    ainfo.reconnecting = true
    local ok = skynet.call(ainfo.agent, "lua", "reconnect", account_key, fd)
    if not ok then
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

function M.dispatch_client(fd, name, args, session)
    if CLIENT[name] then
        local ok = pcall(CLIENT[name], fd, args, session)
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
        dispatch = function(fd, _, name, args, session)
            skynet.ignoreret()
            M.dispatch_client(fd, name, args, session)
        end,
    })
end

function M.init()
    M.register_client_protocol()
    if M._inited then
        return
    end
    M._inited = true
    init_agent_pool()
    log.info("Login service started with %d agents in pool", #agent_pool)
end

return M
