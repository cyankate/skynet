--[[
    登录服务
    负责账号的登录、登出、重连、令牌验证等功能    
]]

local account_loading = {}
local account_info = {}
require "skynet.manager"
local service_wrapper = require "utils.service_wrapper"

-- agent池管理
local agent_pool = {}           -- 存储所有agent服务实例
local agent_to_accounts = {}    -- 每个agent负责的账号 {agent_handle = {account_key1, account_key2, ...}}
local INIT_AGENT_COUNT = 3      -- 初始创建的agent数量
local CLIENT = {}

-- 获取安全服务实例
local function get_security_service()
    return skynet.localname(".security")
end

-- 检查安全限制
local function check_security(ip, account_key, action)
    local security = get_security_service()
    if not security then
        log.warning("Security service not available")
        return true -- 安全服务不可用时默认允许
    end
    
    local is_safe, message = skynet.call(security, "lua", "check_request_safety", 
        {account = account_key}, ip, account_key, action or "login")
    
    if not is_safe then
        log.warning("Security check failed for %s: %s", account_key, message)
    end
    
    return is_safe, message
end

-- 生成令牌
local function generate_token(account_key, device_id)
    local security = get_security_service()
    if not security then
        log.warning("Security service not available for token generation")
        return nil
    end
    
    return skynet.call(security, "lua", "generate_token", account_key, device_id)
end

-- 验证令牌
local function verify_token(token_str)
    local security = get_security_service()
    if not security then
        log.warning("Security service not available for token verification")
        return false
    end
    
    return skynet.call(security, "lua", "verify_token", token_str)
end

-- 初始化agent池
local function init_agent_pool()
    log.info("Initializing agent pool with %d agents", INIT_AGENT_COUNT)
    for i = 1, INIT_AGENT_COUNT do
        local agent = skynet.newservice("agentS", i)
        table.insert(agent_pool, agent)
        agent_to_accounts[agent] = {}
    end
end

-- 获取负载最小的agent
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

-- 将账号分配给指定agent
local function assign_account_to_agent(agent, account_key)
    if not agent_to_accounts[agent] then
        agent_to_accounts[agent] = {}
    end
    table.insert(agent_to_accounts[agent], account_key)
end

-- 从agent中移除账号
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
    -- 安全检查
    local is_safe, message = check_security(ip, account_key)
    if not is_safe then
        log.warning("Login rejected due to security concerns: %s, account_key: %s", message, account_key)
        protocol_handler.rpc_response(fd, session, {success = false, player_id = 0, player_name = ""})
        return
    end

    protocol_handler.rpc_response(fd, session, {success = true, player_id = 0, player_name = "test"})

    local gateS = skynet.localname(".gate")
    -- 尝试查找账号信息
    local ainfo = account_info[account_key]
    
    if ainfo and ainfo.agent then
        if ainfo.logout then
            -- 账号已有agent服务，尝试重连
            log.debug(string.format("Account %s has existing agent, attempting reconnect", account_key))
    
            -- 尝试与已有agent重新连接，传递账号key
            local ok = CMD.reconnect(account_key, fd)
            if ok then
                skynet.send(gateS, "lua", "bound_agent", fd, account_key, ainfo.agent)
                
                log.info(string.format("Account %s reconnected to agent %s", account_key, ainfo.agent))
                return
            end
        end
        
        ainfo.last_login_ip = ip
        ainfo.last_login_time = os.date("%Y-%m-%d %H:%M:%S", os.time())
        ainfo.device_id = device_id
        
        -- 向agent服务发送顶号通知
        skynet.send(ainfo.agent, "lua", "kicked_out", account_key, fd)

        log.debug(string.format("Account %s kicked out from fd %s", account_key, fd))
        
        skynet.send(gateS, "lua", "bound_agent", fd, account_key, ainfo.agent)
        return
    end
    
    if account_loading[account_key] then
        log.error(string.format("Account %s is already loading", account_key))
        protocol_handler.send_to_client(fd, "login_failed", {reason = "账号正在加载中，请稍后再试"})
        return
    end
    
    account_loading[account_key] = true
    
    -- 请求 db 服务查询账号数据
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
            protocol_handler.send_to_client(fd, "login_failed", {reason = "创建账号失败"})
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
        
        -- 更新最后登录信息
        skynet.send(db, "lua", "update_account_login", account_key, ip, os.time(), device_id)
    end
    
    -- 从agent池获取可用的agent
    local agent = get_available_agent()
    local ok = skynet.send(agent, "lua", "start", account_key, account_data, {fd = fd})
    if not ok then
        log.error(string.format("Failed to start agent for account %s", account_key))
        account_loading[account_key] = nil
        protocol_handler.send_to_client(fd, "login_failed", {reason = "登录失败"})
        return
    end
    
    -- 记录账号与agent的关系
    assign_account_to_agent(agent, account_key)
    
    account_info[account_key] = {
        agent = agent, 
        last_login_ip = ip,
        last_login_time = os.date("%Y-%m-%d %H:%M:%S", os.time()),
        device_id = device_id
    }
    
    log.info(string.format("Account %s logged in, assigned to agent: %s", account_key, agent))
    
    skynet.send(gateS, "lua", "bound_agent", fd, account_key, agent)
end 

-- 令牌验证登录
function CMD.token_login(fd, msg)
    local account_key = msg.account_id
    local ip = msg.ip
    local device_id = msg.device_id
    local token_str = msg.token
    
    -- 验证令牌
    local is_valid, account_key, token_data = verify_token(token_str)
    if not is_valid then
        log.warning("Invalid token login attempt from IP: %s", ip or "unknown")
        protocol_handler.send_to_client(fd, "login_failed", {reason = "令牌无效或已过期"})
        return
    end
    
    -- 安全检查
    local is_safe, message = check_security(ip, account_key, "token_login")
    if not is_safe then
        log.warning("Token login rejected due to security concerns: %s", message)
        protocol_handler.send_to_client(fd, "login_failed", {reason = message})
        return
    end
    
    -- 检查设备匹配
    if token_data.did and device_id and token_data.did ~= device_id then
        log.warning("Token login device mismatch: %s vs %s", token_data.did, device_id)
        
        -- 可能的设备盗用，将此IP加入黑名单
        local security = get_security_service()
        if security then
            skynet.send(security, "lua", "add_to_blacklist", ip, "设备不匹配，可能的令牌盗用", 3600)
        end
        
        protocol_handler.send_to_client(fd, "login_failed", {reason = "设备不匹配，拒绝登录"})
        return
    end
    
    CLIENT.login(fd, {
        account_id = account_key,
        ip = ip,
        device_id = device_id
    })
end

function CMD.account_update(account_key, account_data)
    local db = skynet.localname(".db")
    skynet.send(db, "lua", "update_account", account_key, {
        account_key = account_key,
        players = account_data.players,
    })
end

function CMD.account_loaded(account_key)
    if not account_info[account_key] then
        log.error(string.format("Account %s not found", account_key))
        return false
    end
    account_loading[account_key] = nil
end

function CMD.account_exit(account_key)
    if not account_info[account_key] then
        log.error(string.format("Account %s not found", account_key))
        return false
    end
    account_info[account_key] = nil
end

function CMD.disconnect(account_key)
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

-- 处理账号登出
function CMD.logout(account_key)
    log.info(string.format("Account %s logged out", account_key))
    
    -- 注意：我们不立即移除account_map中的映射，
    -- 这样玩家在3分钟内重连时仍能找到原来的agent
    -- 实际清理会在agent服务彻底退出时进行
    if not account_info[account_key] then
        log.error(string.format("Account %s not found", account_key))
        return false
    end
    account_info[account_key].logout = true 
    return true
end

function CMD.reconnect(account_key, fd)
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

-- 当agent服务彻底退出时调用此函数
function CMD.agent_exit(account_key)
    log.info(string.format("Agent for account %s exited completely", account_key))
    
    -- 获取账号对应的agent
    local ainfo = account_info[account_key]
    if ainfo and ainfo.agent then
        -- 从agent的账号列表中移除此账号
        remove_account_from_agent(ainfo.agent, account_key)
    end
    
    -- 清理账号映射
    account_info[account_key] = nil
    
    return true
end

-- 获取agent池状态
function CMD.get_agent_pool_status()
    local result = {
        agent_count = #agent_pool,
        agent_stats = {}
    }
    
    for i, agent in ipairs(agent_pool) do
        local accounts = agent_to_accounts[agent] or {}
        table.insert(result.agent_stats, {
            agent = agent,
            account_count = #accounts,
            accounts = accounts
        })
    end
    
    return result
end

-- 添加IP到黑名单
function CMD.add_to_blacklist(ip, reason, duration)
    local security = get_security_service()
    if not security then
        log.error("Security service not available for blacklist operation")
        return false
    end
    
    return skynet.send(security, "lua", "add_to_blacklist", ip, reason, duration)
end

-- 检查IP是否在黑名单中
function CMD.check_ip_blacklist(ip)
    local security = get_security_service()
    if not security then
        log.warning("Security service not available for IP check")
        return false
    end
    
    -- 通过安全服务检查IP状态
    local params = {ip = ip}
    local is_safe, message = skynet.call(security, "lua", "check_request_safety", params, ip)
    
    -- is_safe为false表示IP在黑名单中
    return not is_safe, message
end

function CMD.after_hotfix(hotfix_name)
    log.info("Login service after hotfix %s", hotfix_name)
    
    -- 向所有agent发送热更新通知
    log.info("Sending hotfix notification to %d agents", #agent_pool)
    skynet.fork(function()
        for _, agent in ipairs(agent_pool) do
            skynet.send(agent, "lua", "hotfix", hotfix_name)
        end
    end)
end

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
	unpack = function (msg, sz)
		return skynet.unpack(msg, sz)
	end,
	dispatch = function (fd, _, name, args, session)
        skynet.ignoreret()
		if CLIENT[name] then
            local ok, result = pcall(CLIENT[name], fd, args, session)
			if not ok then
				log.error(string.format("Error handling message %s from fd: %s", name, fd))
			end
		else
			log.error(string.format("Unknown message type: %s, from fd: %s", name, fd))
		end
	end
}

-- 主服务函数
local function main()
    -- 初始化agent池
    init_agent_pool()
    
    log.info("Login service started with %d agents in pool", #agent_pool)
end

service_wrapper.create_service(main, {
    name = "login",
})