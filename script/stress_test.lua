package.cpath = "luaclib/?.so"
package.path = "lualib/?.lua;script/?.lua"

if _VERSION ~= "Lua 5.4" then
	error "Use lua 5.4"
end

local socket = require "client.socket"
local proto = require "proto"
local sproto = require "sproto"
local json = require "cjson"
local os = require "os"

-- 辅助函数：检查表中是否包含某个值
local function table_contains(tbl, element)
    for _, value in pairs(tbl) do
        if value == element then
            return true
        end
    end
    return false
end

-- 日志级别
local LOG_LEVEL = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4
}

local cur_log_level = LOG_LEVEL.DEBUG

local function log(level, fmt, ...)
    if level >= cur_log_level then
        local levels = {"DEBUG", "INFO", "WARN", "ERROR"}
        local args = {...}
        -- 检查参数中是否有nil
        for i, v in ipairs(args) do
            if v == nil then
                args[i] = "nil"
            end
        end
        local msg = string.format(fmt, table.unpack(args))
        print(string.format("[%s][%s] %s", os.date("%Y-%m-%d %H:%M:%S"), levels[level], msg))
    end
end

-- 连接配置
local config = {
    host = "127.0.0.1",
    port = 8888,
    report_interval_ms = 5000,   -- 定期报告间隔(毫秒)
    test_duration = 0,          -- 测试持续时间（秒），0表示无限制
    account_prefix = "test_user_", -- 账号前缀
    total_clients = 800,        -- 总客户端数
    protocol_configs = {        -- 不同协议的配置
        chat = {
            target_rps = 100,    -- 目标每秒请求数
            token_bucket = {
                tokens = 200,     -- 初始令牌数，等于target_rps，避免启动时的突发
                last_update = 0,  -- 上次更新时间
                capacity = 400    -- 桶容量，允许2秒的突发请求
            },
            protocols = {
                "send_private_message",
                "get_channel_history",
                "get_private_history"
            }
        },
        player = {
            target_rps = 50,     -- 目标每秒请求数
            token_bucket = {
                tokens = 200,      -- 初始令牌数，等于target_rps
                last_update = 0,  -- 上次更新时间
                capacity = 400    -- 桶容量，允许2秒的突发请求
            },
            protocols = {
                "change_name",
                "add_item",
                "add_score"
            }
        }
    }
}

-- 性能统计
local stats = {
    total_requests = 0,
    successful_requests = 0,
    failed_requests = 0,
    response_times = {},  -- 每个请求的响应时间
    request_types = {},   -- 不同类型请求的计数
    errors = {},          -- 错误统计
    start_time = 0,       -- 测试开始时间
    end_time = 0,         -- 测试结束时间
    clients = {},         -- 客户端状态
    protocol_stats = {    -- 各协议类型的统计
        chat = {
            requests_sent = 0,
            requests_received = 0,
            response_times = {},
            errors = {},
            current_rps = 0,     -- 当前每秒请求数
            last_rps_time = 0,   -- 上次计算RPS的时间
            last_rps_count = 0   -- 上次计算RPS时的请求数
        },
        player = {
            requests_sent = 0,
            requests_received = 0,
            response_times = {},
            errors = {},
            current_rps = 0,     -- 当前每秒请求数
            last_rps_time = 0,   -- 上次计算RPS的时间
            last_rps_count = 0   -- 上次计算RPS时的请求数
        }
    }
}

-- 创建客户端实例
local clients = {}

-- 客户端类
local Client = {}
Client.__index = Client

local g_session = 0

function Client.new(id, protocol_type)
    local self = setmetatable({}, Client)
    self.id = id
    self.session = 0
    self.last = ""
    self.fd = nil
    self.connected = false
    self.logined = false
    self.last_login_time = 0
    self.last_request_time = nil
    self.protocol_type = protocol_type  -- 协议类型：chat 或 player
    self.account_id = config.account_prefix .. id
    self.player_id = nil
    self.requests_sent = 0
    self.requests_received = 0
    self.pending_requests = {}
    self.host = nil
    self.request = nil
    return self
end

function Client:connect()
    self.fd = socket.connect(config.host, config.port)
    if not self.fd then
        log(LOG_LEVEL.ERROR, "Client %d failed to connect", self.id)
        return false
    end
    
    self.host = sproto.new(proto.s2c):host "package"
    self.request = self.host:attach(sproto.new(proto.c2s))
    self.connected = true
    stats.clients[self.id] = {
        connected = true,
        login_time = 0,
        requests_sent = 0,
        requests_received = 0
    }
    
    log(LOG_LEVEL.DEBUG, "Client %d connected", self.id)
    return true
end

function Client:disconnect()
    if self.connected and self.fd then
        socket.close(self.fd)
        self.connected = false
        if stats.clients[self.id] then
            stats.clients[self.id].connected = false
        end
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
    local r = socket.recv(self.fd, 100)  -- 非阻塞接收，超时100ms
    if not r then
        return nil
    end
    if r == "" then
        log(LOG_LEVEL.WARN, "Client %d: Server closed connection", self.id)
        self:disconnect()
        return nil
    end
    self.last = self.last .. r
    return self:recv_package()
end

function Client:send_request(name, args)
    if not self.connected then return false end
    
    g_session = g_session + 1
    local current_session = g_session
    
    local start_time = os.clock()
    self.pending_requests[current_session] = {
        name = name,
        time = start_time,
        protocol_type = self.protocol_type
    }
    
    local str = self.request(name, args, current_session)
    local ret = self:send_package(str)
    
    self.requests_sent = self.requests_sent + 1
    stats.total_requests = stats.total_requests + 1
    stats.protocol_stats[self.protocol_type].requests_sent = stats.protocol_stats[self.protocol_type].requests_sent + 1
    stats.clients[self.id].requests_sent = self.requests_sent
    
    -- 记录请求类型统计
    if not stats.request_types[name] then
        stats.request_types[name] = 0
    end
    stats.request_types[name] = stats.request_types[name] + 1
        
    return ret
end

function Client:process_package(resp)
    if not resp then return end
    
    local t, name, args, response_session = self.host:dispatch(resp)
    
    if t == "REQUEST" then
        -- 处理服务器推送的请求
        if name == "kicked_out" then
            log(LOG_LEVEL.INFO, "Client %d: Kicked out - %s", self.id, args.reason)
            self.logined = false
        elseif name == "login_response" then
            if args.success then
                self.logined = true
                self.player_id = args.player_id
                log(LOG_LEVEL.INFO, "Client %d: Login successful, player_id=%d", self.id, self.player_id)
            else
                log(LOG_LEVEL.WARN, "Client %d: Login failed", self.id)
            end
        end
    else
        -- 处理响应
        if name and self.pending_requests[name] then
            local req = self.pending_requests[name]
            local response_time = os.clock() - req.time
            
            table.insert(stats.response_times, response_time)
            table.insert(stats.protocol_stats[req.protocol_type].response_times, response_time)
            
            self.requests_received = self.requests_received + 1
            stats.successful_requests = stats.successful_requests + 1
            stats.protocol_stats[req.protocol_type].requests_received = stats.protocol_stats[req.protocol_type].requests_received + 1
            stats.clients[self.id].requests_received = self.requests_received
            
            log(LOG_LEVEL.DEBUG, "Client %d: Response for %s (session: %d) received in %.6f seconds", 
                self.id, req.name, name, response_time)
            
            self.pending_requests[name] = nil
        end
    end
end

function Client:send_random_request()
    if not self.connected or not self.logined then
        return
    end
    
    local protocol_config = config.protocol_configs[self.protocol_type]
    local protocol = protocol_config.protocols[math.random(1, #protocol_config.protocols)]
    local args = {}
    
    if protocol == "send_channel_message" then
        args.channel_id = 1
        args.content = "Test message from client " .. self.id
    elseif protocol == "send_private_message" then
        local list = {}
        for _, client in ipairs(clients) do   
            if client.player_id ~= self.player_id then
                table.insert(list, client.player_id)
            end
        end
        if not next(list) then
            return
        end
        args.to_player_id = list[math.random(1, #list)]
        args.content = "Private message from client " .. self.id
    elseif protocol == "get_channel_history" then
        args.channel_id = 1
        args.count = 10
    elseif protocol == "get_private_history" then
        local list = {}
        for _, client in ipairs(clients) do   
            if client.player_id ~= self.player_id then
                table.insert(list, client.player_id)
            end
        end
        if not next(list) then
            return
        end 
        args.player_id = list[math.random(1, #list)]
        args.count = 10
    elseif protocol == "change_name" then
        args.name = "Player_" .. math.random(1000, 9999)
    elseif protocol == "add_item" then
        args.item_id = math.random(1, 100)
        args.count = math.random(1, 10)
    elseif protocol == "add_score" then
        args.score = math.random(1, 1000)
    end
    self:send_request(protocol, args)
end

function Client:run_action()
    if not self.connected then
        return false
    end
    
    -- 如果未登录，执行登录操作
    if not self.logined then
        if os.time() - self.last_login_time > 30 then
            self:send_request("login", {account_id = self.account_id})
            self.last_login_time = os.time()
        end
        return true
    end

    local now = os.clock()
    local protocol_type = self.protocol_type
    local protocol_config = config.protocol_configs[protocol_type]
    local bucket = protocol_config.token_bucket
    
    -- 更新令牌桶
    local time_passed = now - bucket.last_update
    local new_tokens = time_passed * protocol_config.target_rps
    bucket.tokens = math.min(bucket.capacity, bucket.tokens + new_tokens)
    bucket.last_update = now
    
    -- 如果有令牌，发送请求
    if bucket.tokens >= 1 then
        self:send_random_request()
        bucket.tokens = bucket.tokens - 1
    end
    
    return true
end

function create_clients()
    for i = 1, config.total_clients do
        -- 随机分配协议类型，chat和player的比例约为5:1
        local protocol_type = math.random() < 0.8 and "chat" or "player"
        clients[i] = Client.new(i, protocol_type)
    end
end

function connect_clients()
    -- 计算每个客户端启动的时间间隔（毫秒）
    local total_clients = #clients
    local ramp_up_time = 2000  -- 固定2秒的启动时间
    local ramp_delay = ramp_up_time / total_clients
    
    for i, client in ipairs(clients) do
        if client:connect() then
            log(LOG_LEVEL.INFO, "Client %d connected successfully", i)
        else
            log(LOG_LEVEL.ERROR, "Failed to connect client %d", i)
        end
        
        -- 计算客户端启动时间间隔
        if i < total_clients then
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
            
            -- 发送请求
            client:run_action()  -- 移除随机概率，每次都尝试发送请求
        end
    end
end

function print_statistics()
    local now = os.clock()
    local duration = now - stats.start_time
    
    log(LOG_LEVEL.INFO, "=== Performance Report ===")
    log(LOG_LEVEL.INFO, "Duration: %.3f seconds", duration)
    log(LOG_LEVEL.INFO, "Connected clients: %d/%d", count_connected_clients(), #clients)
    log(LOG_LEVEL.INFO, "Total requests: %d", stats.total_requests or 0)
    log(LOG_LEVEL.INFO, "Successful responses: %d", stats.successful_requests or 0)
    log(LOG_LEVEL.INFO, "Failed requests: %d", stats.failed_requests or 0)
    
    -- 打印各协议类型的统计信息
    for protocol_type, protocol_config in pairs(config.protocol_configs) do
        local protocol_stats = stats.protocol_stats[protocol_type]
        if not protocol_stats then
            log(LOG_LEVEL.INFO, "\n=== %s Protocol Stats ===", protocol_type:upper())
            log(LOG_LEVEL.INFO, "No statistics available")
            goto continue
        end
        
        local avg_response_time = 0
        if protocol_stats.response_times and #protocol_stats.response_times > 0 then
            local sum = 0
            for _, time in ipairs(protocol_stats.response_times) do
                sum = sum + time
            end
            avg_response_time = sum / #protocol_stats.response_times
        end
        
        -- 计算实际RPS
        local actual_rps = 0
        if duration > 0 then
            actual_rps = (protocol_stats.requests_sent or 0) / duration
        end
        
        log(LOG_LEVEL.INFO, "\n=== %s Protocol Stats ===", protocol_type:upper())
        log(LOG_LEVEL.INFO, "Target RPS: %d", protocol_config.target_rps)
        log(LOG_LEVEL.INFO, "Actual RPS: %.2f", actual_rps)
        log(LOG_LEVEL.INFO, "Requests sent: %d", protocol_stats.requests_sent or 0)
        log(LOG_LEVEL.INFO, "Responses received: %d", protocol_stats.requests_received or 0)
        log(LOG_LEVEL.INFO, "Average response time: %.6f seconds", avg_response_time)
        
        -- 打印该协议类型的请求统计
        log(LOG_LEVEL.INFO, "Request types:")
        for name, count in pairs(stats.request_types or {}) do
            if table_contains(protocol_config.protocols, name) then
                log(LOG_LEVEL.INFO, "  %s: %d", name, count)
            end
        end
        
        ::continue::
    end
    
    if stats.errors and next(stats.errors) then
        log(LOG_LEVEL.INFO, "\nErrors:")
        for err, count in pairs(stats.errors) do
            log(LOG_LEVEL.INFO, "  %s: %d", err, count)
        end
    end
    
    local logined_count = 0
    for _, client in ipairs(clients) do
        if client.logined then  
            logined_count = logined_count + 1
        end
    end 
    log(LOG_LEVEL.INFO, "\nLogined clients: %d/%d", logined_count, #clients)
    
    log(LOG_LEVEL.INFO, "=========================")
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
            total_requests = stats.total_requests,
            successful_requests = stats.successful_requests,
            failed_requests = stats.failed_requests,
            duration = stats.end_time - stats.start_time,
            protocol_stats = stats.protocol_stats,
            request_types = stats.request_types,
            errors = stats.errors
        }
    }
    
    local file = io.open("stress_test_results.json", "w")
    if file then
        file:write(json.encode(result))
        file:close()
        log(LOG_LEVEL.INFO, "Results saved to stress_test_results.json")
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
    stats.end_time = os.clock() + 1
    print_statistics()
    save_results()
end

-- 解析命令行参数
function parse_args()
    local args = arg
    local i = 1
    while i <= #args do
        local arg_value = args[i]
        if arg_value == "--total-clients" and i < #args then
            config.total_clients = tonumber(args[i+1]) or config.total_clients
            i = i + 2
        elseif arg_value == "--chat-rps" and i < #args then
            config.protocol_configs.chat.target_rps = tonumber(args[i+1]) or config.protocol_configs.chat.target_rps
            i = i + 2
        elseif arg_value == "--player-rps" and i < #args then
            config.protocol_configs.player.target_rps = tonumber(args[i+1]) or config.protocol_configs.player.target_rps
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
    
    log(LOG_LEVEL.INFO, "Starting stress test with configuration:")
    log(LOG_LEVEL.INFO, "Server: %s:%d", config.host, config.port)
    log(LOG_LEVEL.INFO, "Total clients: %d", config.total_clients)
    log(LOG_LEVEL.INFO, "Chat system: target RPS %d", 
        config.protocol_configs.chat.target_rps)
    log(LOG_LEVEL.INFO, "Player operations: target RPS %d", 
        config.protocol_configs.player.target_rps)
    
    stats.start_time = os.clock()
    
    create_clients()
    connect_clients()
    
    local last_report = os.clock()
    local start = os.clock()
    
    while true do
        process_clients()
        
        -- 定期报告
        local now = os.clock()
        if now - last_report >= config.report_interval_ms / 1000 then
            print_statistics()
            last_report = now
        end
        
        -- 检查测试持续时间
        if config.test_duration > 0 and now - start >= config.test_duration then
            log(LOG_LEVEL.INFO, "Test duration reached, stopping test")
            break
        end
        
        socket.usleep(1000)  -- 1ms的休眠间隔
    end
    
    stats.end_time = os.clock()
    socket.usleep(2000000)  -- 2秒
    cleanup()
end

-- 运行主函数
xpcall(main, function(err)
    log(LOG_LEVEL.ERROR, "Error in main function: " .. tostring(err) .. "\n" .. debug.traceback())
    cleanup()
end) 