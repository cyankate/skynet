package.cpath = "luaclib/?.so"
package.path = "lualib/?.lua;script/?.lua"

if _VERSION ~= "Lua 5.4" then
	error "Use lua 5.4"
end

local socket = require "client.socket"
local proto = require "proto"
local sproto = require "sproto"
local json = require "json"
local os = require "os"

-- 日志级别
local LOG_LEVEL = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4
}

local cur_log_level = LOG_LEVEL.INFO

local function log(level, fmt, ...)
    if level >= cur_log_level then
        local levels = {"DEBUG", "INFO", "WARN", "ERROR"}
        local msg = string.format(fmt, ...)
        print(string.format("[%s][%s] %s", os.date("%Y-%m-%d %H:%M:%S"), levels[level], msg))
    end
end

-- 性能统计
local stats = {
    login_attempts = 0,        -- 登录尝试次数
    login_success = 0,         -- 登录成功次数
    login_failed = 0,          -- 登录失败次数
    kicked_count = 0,          -- 被顶号次数
    reconnect_count = 0,       -- 重连次数
    response_times = {},       -- 登录响应时间
    accounts = {},             -- 账号状态跟踪
    start_time = 0,            -- 测试开始时间
    end_time = 0,              -- 测试结束时间
}

-- 测试配置
local config = {
    host = "127.0.0.1",
    port = 8888,
    client_count = 50,            -- 同时连接的客户端数量
    account_count = 30,           -- 模拟的账号数量（小于客户端数量时将触发顶号）
    login_cycle_time = 1000,      -- 每个客户端登录/登出循环时间(毫秒)
    ramp_up_time_ms = 3000,       -- 所有客户端启动的时间跨度(毫秒)
    report_interval_ms = 5000,    -- 定期报告间隔(毫秒)
    test_duration = 60,           -- 测试持续时间（秒），0表示无限制
    account_prefix = "test_user_", -- 账号前缀
    max_login_attempts = 500,     -- 每个客户端最大登录尝试次数
    extra_login_delay_ms = 100,   -- 登录操作额外延迟(毫秒)，模拟真实用户行为
}

-- 客户端类
local Client = {}
Client.__index = Client

function Client.new(id)
    local self = setmetatable({}, Client)
    self.id = id
    self.session = 0
    self.last = ""
    self.fd = nil
    self.connected = false
    self.logined = false
    -- 决定使用哪个账号，让部分客户端使用同一个账号以触发顶号
    local account_id = ((id - 1) % config.account_count) + 1
    self.account_id = config.account_prefix .. account_id
    self.player_id = nil
    self.login_attempts = 0
    self.login_success = 0
    self.login_failed = 0
    self.kicked_count = 0
    self.pending_requests = {}
    self.host = nil
    self.request = nil
    self.last_login_time = 0
    self.last_action_time = 0
    return self
end

function Client:connect()
    -- 如果已经连接，先断开
    if self.connected and self.fd then
        self:disconnect()
    end
    
    self.fd = socket.connect(config.host, config.port)
    if not self.fd then
        log(LOG_LEVEL.ERROR, "Client %d failed to connect", self.id)
        return false
    end
    
    self.host = sproto.new(proto.s2c):host "package"
    self.request = self.host:attach(sproto.new(proto.c2s))
    self.connected = true
    self.logined = false
    
    stats.reconnect_count = stats.reconnect_count + 1
    
    log(LOG_LEVEL.DEBUG, "Client %d connected", self.id)
    return true
end

function Client:disconnect()
    if self.connected and self.fd then
        socket.close(self.fd)
        self.connected = false
        self.logined = false
        log(LOG_LEVEL.DEBUG, "Client %d disconnected", self.id)
    end
end

function Client:send_package(pack)
    if not self.connected then return false end
    local package = string.pack(">s2", pack)
    return socket.send(self.fd, package)
end

function Client:unpack_package(text)
    local size = #text
    if size < 2 then
        return nil, text
    end
    local s = text:byte(1) * 256 + text:byte(2)
    if size < s+2 then
        return nil, text
    end
    return text:sub(3,2+s), text:sub(3+s)
end

function Client:recv_package()
    if not self.connected then return nil end
    
    local result
    result, self.last = self:unpack_package(self.last)
    if result then
        return result
    end
    
    local r = socket.recv(self.fd, 50)  -- 非阻塞接收，超时50ms
    if not r then
        return nil
    end
    if r == "" then
        log(LOG_LEVEL.WARN, "Client %d: Server closed connection", self.id)
        self:disconnect()
        return nil
    end
    
    return self:recv_package(self.last .. r)
end

function Client:send_request(name, args)
    if not self.connected then return false end
    
    self.session = self.session + 1
    local current_session = self.session
    
    local start_time = os.clock()
    self.pending_requests[current_session] = {
        name = name,
        time = start_time
    }
    
    local str = self.request(name, args, current_session)
    local ret = self:send_package(str)
    
    if ret then
        log(LOG_LEVEL.DEBUG, "Client %d: Request %s (session: %d)", self.id, name, current_session)
    else
        log(LOG_LEVEL.ERROR, "Client %d: Failed to send request %s", self.id, name)
    end
    
    return ret
end

function Client:process_package(resp)
    if not resp then return end
    
    local t, name, args, response_session = self.host:dispatch(resp)
    
    if t == "REQUEST" then
        log(LOG_LEVEL.DEBUG, "Client %d: Received request %s", self.id, name)
        
        if name == "kicked_out" then
            log(LOG_LEVEL.INFO, "Client %d: Kicked out from account %s - %s", 
                self.id, self.account_id, args.reason)
            
            self.logined = false
            self.kicked_count = self.kicked_count + 1
            stats.kicked_count = stats.kicked_count + 1
            
            -- 记录账号状态
            if not stats.accounts[self.account_id] then
                stats.accounts[self.account_id] = {
                    kicked_count = 0,
                    login_success = 0,
                    login_failed = 0,
                    current_client = nil
                }
            end
            stats.accounts[self.account_id].kicked_count = 
                (stats.accounts[self.account_id].kicked_count or 0) + 1
            stats.accounts[self.account_id].current_client = nil
            
        elseif name == "login_response" then
            local response_time = nil
            if response_session and self.pending_requests[response_session] then
                local req = self.pending_requests[response_session]
                response_time = os.clock() - req.time
                table.insert(stats.response_times, response_time)
                self.pending_requests[response_session] = nil
            end
            
            if args.success then
                self.logined = true
                self.player_id = args.player_id
                self.login_success = self.login_success + 1
                stats.login_success = stats.login_success + 1
                
                log(LOG_LEVEL.INFO, "Client %d: Login successful to account %s, player_id=%d (%.3fs)", 
                    self.id, self.account_id, self.player_id, response_time or 0)
                
                -- 记录账号状态
                if not stats.accounts[self.account_id] then
                    stats.accounts[self.account_id] = {
                        kicked_count = 0,
                        login_success = 0,
                        login_failed = 0,
                        current_client = nil
                    }
                end
                stats.accounts[self.account_id].login_success = 
                    (stats.accounts[self.account_id].login_success or 0) + 1
                stats.accounts[self.account_id].current_client = self.id
                
            else
                self.login_failed = self.login_failed + 1
                stats.login_failed = stats.login_failed + 1
                
                log(LOG_LEVEL.WARN, "Client %d: Login failed to account %s (%.3fs)", 
                    self.id, self.account_id, response_time or 0)
                
                -- 记录账号状态
                if not stats.accounts[self.account_id] then
                    stats.accounts[self.account_id] = {
                        kicked_count = 0,
                        login_success = 0,
                        login_failed = 0,
                        current_client = nil
                    }
                end
                stats.accounts[self.account_id].login_failed = 
                    (stats.accounts[self.account_id].login_failed or 0) + 1
            end
        end
    else
        -- 处理响应
        if response_session and self.pending_requests[response_session] then
            local req = self.pending_requests[response_session]
            local response_time = os.clock() - req.time
            
            log(LOG_LEVEL.DEBUG, "Client %d: Response for %s (session: %d) received in %.6f seconds", 
                self.id, req.name, response_session, response_time)
            
            self.pending_requests[response_session] = nil
        end
    end
end

-- 执行登录操作
function Client:login()
    if not self.connected then
        if not self:connect() then
            return false
        end
    end
    
    if self.login_attempts >= config.max_login_attempts then
        return false
    end
    
    self:send_request("login", {account_id = self.account_id})
    self.login_attempts = self.login_attempts + 1
    stats.login_attempts = stats.login_attempts + 1
    self.last_login_time = os.time()
    self.last_action_time = os.time()
    
    return true
end

-- 执行登出操作
function Client:logout()
    if not self.connected or not self.logined then
        return false
    end
    
    self:send_request("quit", {})
    self.logined = false
    self.last_action_time = os.time()
    
    return true
end

-- 创建客户端实例
local clients = {}

function create_clients()
    for i = 1, config.client_count do
        clients[i] = Client.new(i)
    end
end

function connect_clients()
    local ramp_delay = config.ramp_up_time_ms / config.client_count
    
    for i, client in ipairs(clients) do
        if client:connect() then
            log(LOG_LEVEL.INFO, "Client %d connected successfully", i)
        else
            log(LOG_LEVEL.ERROR, "Failed to connect client %d", i)
        end
        
        -- 计算客户端启动时间间隔
        if i < config.client_count then
            socket.usleep(ramp_delay * 1000)  -- 转换为微秒
        end
    end
end

function process_clients()
    for _, client in ipairs(clients) do
        if client.connected then
            -- 处理接收到的消息
            local resp = client:recv_package()
            while resp do
                client:process_package(resp)
                resp = client:recv_package()
            end
            
            local now = os.time()
            
            -- 如果客户端未登录且上次操作已经过去一段时间，尝试登录
            if not client.logined and now - client.last_action_time >= (config.login_cycle_time / 1000) then
                if config.extra_login_delay_ms > 0 then
                    socket.usleep(config.extra_login_delay_ms * 1000)  -- 模拟用户登录延迟
                end
                client:login()
            -- 如果客户端已登录且登录时间超过一定时间，尝试登出
            elseif client.logined and now - client.last_login_time >= (config.login_cycle_time * 2 / 1000) then
                client:logout()
            end
        else
            -- 如果客户端断开连接，尝试重连
            local now = os.time()
            if now - client.last_action_time >= 2 then  -- 2秒钟后尝试重连
                client:connect()
            end
        end
    end
end

function print_statistics()
    local now = os.time()
    local duration = now - stats.start_time
    
    -- 计算平均响应时间
    local avg_response_time = 0
    if #stats.response_times > 0 then
        local sum = 0
        for _, time in ipairs(stats.response_times) do
            sum = sum + time
        end
        avg_response_time = sum / #stats.response_times
    end
    
    -- 计算每秒登录次数
    local logins_per_second = stats.login_attempts / duration
    
    log(LOG_LEVEL.INFO, "=== Login Test Report ===")
    log(LOG_LEVEL.INFO, "Duration: %d seconds", duration)
    log(LOG_LEVEL.INFO, "Connected clients: %d/%d", count_connected_clients(), config.client_count)
    log(LOG_LEVEL.INFO, "Total login attempts: %d", stats.login_attempts)
    log(LOG_LEVEL.INFO, "Successful logins: %d", stats.login_success)
    log(LOG_LEVEL.INFO, "Failed logins: %d", stats.login_failed)
    log(LOG_LEVEL.INFO, "Kicked count: %d", stats.kicked_count)
    log(LOG_LEVEL.INFO, "Reconnect count: %d", stats.reconnect_count)
    log(LOG_LEVEL.INFO, "Average login response time: %.6f seconds", avg_response_time)
    log(LOG_LEVEL.INFO, "Logins per second: %.2f", logins_per_second)
    
    -- 顶号统计
    local max_kicked_account = ""
    local max_kicked_count = 0
    local total_accounts_with_kicks = 0
    
    for account_id, account_data in pairs(stats.accounts) do
        if account_data.kicked_count > 0 then
            total_accounts_with_kicks = total_accounts_with_kicks + 1
            if account_data.kicked_count > max_kicked_count then
                max_kicked_count = account_data.kicked_count
                max_kicked_account = account_id
            end
        end
    end
    
    log(LOG_LEVEL.INFO, "Accounts with kick events: %d/%d", 
        total_accounts_with_kicks, config.account_count)
    if max_kicked_count > 0 then
        log(LOG_LEVEL.INFO, "Most kicked account: %s (kicked %d times)", 
            max_kicked_account, max_kicked_count)
    end
    
    log(LOG_LEVEL.INFO, "=======================")
end

function count_connected_clients()
    local count = 0
    for _, client in ipairs(clients) do
        if client.connected then
            count = count + 1
        end
    end
    return count
end

function save_results()
    local result = {
        config = config,
        stats = {
            login_attempts = stats.login_attempts,
            login_success = stats.login_success,
            login_failed = stats.login_failed,
            kicked_count = stats.kicked_count,
            reconnect_count = stats.reconnect_count,
            duration = stats.end_time - stats.start_time,
            avg_response_time = calculate_avg_response_time(),
            logins_per_second = stats.login_attempts / (stats.end_time - stats.start_time),
            accounts = stats.accounts
        }
    }
    
    local file = io.open("login_flood_test_results.json", "w")
    if file then
        file:write(json.encode(result))
        file:close()
        log(LOG_LEVEL.INFO, "Results saved to login_flood_test_results.json")
    else
        log(LOG_LEVEL.ERROR, "Failed to save results")
    end
end

function calculate_avg_response_time()
    if #stats.response_times == 0 then
        return 0
    end
    
    local sum = 0
    for _, time in ipairs(stats.response_times) do
        sum = sum + time
    end
    return sum / #stats.response_times
end

function cleanup()
    for _, client in ipairs(clients) do
        client:disconnect()
    end
    stats.end_time = os.time()
    print_statistics()
    save_results()
end

-- 解析命令行参数
function parse_args()
    local args = arg  -- 使用全局的arg表，它包含了命令行参数
    local i = 1
    while i <= #args do
        local arg_value = args[i]
        if arg_value == "--clients" and i < #args then
            config.client_count = tonumber(args[i+1]) or config.client_count
            i = i + 2
        elseif arg_value == "--accounts" and i < #args then
            config.account_count = tonumber(args[i+1]) or config.account_count
            i = i + 2
        elseif arg_value == "--cycle" and i < #args then
            config.login_cycle_time = tonumber(args[i+1]) or config.login_cycle_time
            i = i + 2
        elseif arg_value == "--duration" and i < #args then
            config.test_duration = tonumber(args[i+1]) or config.test_duration
            i = i + 2
        elseif arg_value == "--host" and i < #args then
            config.host = args[i+1] or config.host
            i = i + 2
        elseif arg_value == "--port" and i < #args then
            config.port = tonumber(args[i+1]) or config.port
            i = i + 2
        elseif arg_value == "--debug" then
            cur_log_level = LOG_LEVEL.DEBUG
            i = i + 1
        else
            i = i + 1
        end
    end
end

-- 主函数
function main()
    parse_args()
    
    -- 确保账号数少于客户端数，以测试顶号场景
    if config.account_count >= config.client_count then
        log(LOG_LEVEL.WARN, "Account count (%d) is not less than client count (%d). Adjusting account count to %d to trigger kicked-out scenarios.", 
            config.account_count, config.client_count, config.client_count - 5)
        config.account_count = config.client_count - 5
        if config.account_count < 1 then
            config.account_count = 1
        end
    end
    
    log(LOG_LEVEL.INFO, "Starting login flood test with %d clients and %d accounts", 
        config.client_count, config.account_count)
    log(LOG_LEVEL.INFO, "Server: %s:%d", config.host, config.port)
    log(LOG_LEVEL.INFO, "Login/logout cycle: %d ms", config.login_cycle_time)
    
    stats.start_time = os.time()
    
    create_clients()
    connect_clients()
    
    local last_report = os.time()
    local start = os.time()
    
    while true do
        process_clients()
        
        -- 检查是否所有客户端都达到最大登录尝试次数
        local all_done = true
        for _, client in ipairs(clients) do
            if client.login_attempts < config.max_login_attempts then
                all_done = false
                break
            end
        end
        
        -- 定期报告
        local now = os.time()
        if now - last_report >= config.report_interval_ms / 1000 then
            print_statistics()
            last_report = now
        end
        
        -- 检查测试持续时间
        if config.test_duration > 0 and now - start >= config.test_duration then
            log(LOG_LEVEL.INFO, "Test duration reached, stopping test")
            break
        end
        
        if all_done then
            log(LOG_LEVEL.INFO, "All clients reached maximum login attempts")
            break
        end
        
        socket.usleep(10000)  -- 10ms
    end
    
    cleanup()
end

-- 运行主函数
xpcall(main, function(err)
    log(LOG_LEVEL.ERROR, "Error in main function: " .. tostring(err) .. "\n" .. debug.traceback())
    cleanup()
end) 