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

-- 数据库操作类型
local DB_OPERATION = {
    QUERY = 1,
    CREATE = 2,
    UPDATE = 3,
    DELETE = 4
}

-- 性能统计
local stats = {
    operations = {
        [DB_OPERATION.QUERY] = {count = 0, success = 0, failed = 0, times = {}},
        [DB_OPERATION.CREATE] = {count = 0, success = 0, failed = 0, times = {}},
        [DB_OPERATION.UPDATE] = {count = 0, success = 0, failed = 0, times = {}},
        [DB_OPERATION.DELETE] = {count = 0, success = 0, failed = 0, times = {}}
    },
    total_operations = 0,
    total_success = 0,
    total_failed = 0,
    response_times = {},
    concurrency = {},       -- 每秒并发数统计
    errors = {},            -- 错误统计
    start_time = 0,         -- 测试开始时间
    end_time = 0,           -- 测试结束时间
    clients = {}            -- 客户端状态
}

-- 测试配置
local config = {
    host = "127.0.0.1",
    port = 8888,
    client_count = 50,            -- 同时连接的客户端数量
    operations_per_client = 200,  -- 每个客户端执行的操作数量
    operation_interval_ms = 50,   -- 每个客户端执行操作的间隔(毫秒)
    ramp_up_time_ms = 3000,       -- 所有客户端启动的时间跨度(毫秒)
    report_interval_ms = 5000,    -- 定期报告间隔(毫秒)
    test_duration = 120,          -- 测试持续时间（秒），0表示无限制
    account_prefix = "db_test_",  -- 账号前缀
    operation_ratio = {           -- 各类操作的比例
        [DB_OPERATION.QUERY] = 70,
        [DB_OPERATION.CREATE] = 10,
        [DB_OPERATION.UPDATE] = 15,
        [DB_OPERATION.DELETE] = 5
    },
    concurrency_check_interval = 1, -- 并发检查间隔(秒)
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
    self.account_id = config.account_prefix .. id
    self.player_id = nil
    self.operations_done = 0
    self.operations_success = 0
    self.operations_failed = 0
    self.pending_requests = {}
    self.host = nil
    self.request = nil
    self.last_operation_time = 0
    
    -- 用于创建/更新的测试数据
    self.test_data = {
        items = {},
        stats = {
            kills = math.random(0, 1000),
            deaths = math.random(0, 500),
            assists = math.random(0, 800),
            wins = math.random(0, 100),
            losses = math.random(0, 100)
        },
        profile = {
            level = math.random(1, 50),
            exp = math.random(0, 10000),
            coins = math.random(0, 50000),
            gems = math.random(0, 1000)
        }
    }
    
    -- 生成一些随机物品
    for i = 1, math.random(5, 20) do
        table.insert(self.test_data.items, {
            id = i,
            name = "Item_" .. math.random(1, 100),
            type = math.random(1, 5),
            value = math.random(1, 1000),
            quantity = math.random(1, 99)
        })
    end
    
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
        operations_done = 0,
        operations_success = 0,
        operations_failed = 0
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
        time = start_time,
        op_type = nil  -- 将在发送特定DB操作请求时设置
    }
    
    local str = self.request(name, args, current_session)
    local ret = self:send_package(str)
    
    if ret then
        log(LOG_LEVEL.DEBUG, "Client %d: Request %s (session: %d)", self.id, name, current_session)
    else
        log(LOG_LEVEL.ERROR, "Client %d: Failed to send request %s", self.id, name)
        
        -- 记录错误
        if not stats.errors["send_failed"] then
            stats.errors["send_failed"] = 0
        end
        stats.errors["send_failed"] = stats.errors["send_failed"] + 1
    end
    
    return ret, current_session
end

function Client:process_package(resp)
    if not resp then return end
    
    local t, name, args, response_session = self.host:dispatch(resp)
    
    if t == "REQUEST" then
        log(LOG_LEVEL.DEBUG, "Client %d: Received request %s", self.id, name)
        
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
        if response_session and self.pending_requests[response_session] then
            local req = self.pending_requests[response_session]
            local response_time = os.clock() - req.time
            
            -- 记录响应时间
            table.insert(stats.response_times, response_time)
            
            if req.op_type then
                -- 记录特定操作类型的响应时间
                table.insert(stats.operations[req.op_type].times, response_time)
                
                if args and args.success then
                    stats.operations[req.op_type].success = stats.operations[req.op_type].success + 1
                    stats.total_success = stats.total_success + 1
                    self.operations_success = self.operations_success + 1
                    stats.clients[self.id].operations_success = self.operations_success
                else
                    stats.operations[req.op_type].failed = stats.operations[req.op_type].failed + 1
                    stats.total_failed = stats.total_failed + 1
                    self.operations_failed = self.operations_failed + 1
                    stats.clients[self.id].operations_failed = self.operations_failed
                    
                    -- 记录错误
                    local error_key = "op_" .. req.op_type .. "_failed"
                    if not stats.errors[error_key] then
                        stats.errors[error_key] = 0
                    end
                    stats.errors[error_key] = stats.errors[error_key] + 1
                end
            end
            
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
    
    self:send_request("login", {account_id = self.account_id})
    
    return true
end

-- 选择一个数据库操作类型，基于配置的比例
function select_operation_type()
    local total = 0
    for _, ratio in pairs(config.operation_ratio) do
        total = total + ratio
    end
    
    local rand = math.random(1, total)
    local cumulative = 0
    
    for op_type, ratio in pairs(config.operation_ratio) do
        cumulative = cumulative + ratio
        if rand <= cumulative then
            return op_type
        end
    end
    
    return DB_OPERATION.QUERY  -- 默认为查询操作
end

-- 执行数据库操作
function Client:do_db_operation()
    if not self.connected or not self.logined then
        return false
    end
    
    local op_type = select_operation_type()
    local success = false
    local session = nil
    
    if op_type == DB_OPERATION.QUERY then
        -- 查询操作
        success, session = self:send_request("get", {what = "player_data_" .. self.id})
    elseif op_type == DB_OPERATION.CREATE then
        -- 创建操作
        success, session = self:send_request("set", {
            what = "player_data_" .. self.id .. "_" .. math.random(1, 100),
            value = json.encode(self.test_data)
        })
    elseif op_type == DB_OPERATION.UPDATE then
        -- 更新操作
        -- 修改一些数据来模拟更新
        self.test_data.stats.kills = self.test_data.stats.kills + math.random(1, 10)
        self.test_data.stats.deaths = self.test_data.stats.deaths + math.random(0, 5)
        self.test_data.profile.exp = self.test_data.profile.exp + math.random(10, 100)
        success, session = self:send_request("set", {
            what = "player_data_" .. self.id, 
            value = json.encode(self.test_data)
        })
    elseif op_type == DB_OPERATION.DELETE then
        -- 删除操作
        success, session = self:send_request("set", {
            what = "player_data_" .. self.id .. "_" .. math.random(1, 100),
            value = ""  -- 空值表示删除
        })
    end
    
    if success and session then
        self.operations_done = self.operations_done + 1
        stats.total_operations = stats.total_operations + 1
        stats.operations[op_type].count = stats.operations[op_type].count + 1
        stats.clients[self.id].operations_done = self.operations_done
        
        -- 设置操作类型，以便在接收响应时使用
        self.pending_requests[session].op_type = op_type
        self.last_operation_time = os.time()
        
        -- 记录当前的并发数
        local current_second = math.floor(os.clock())
        if not stats.concurrency[current_second] then
            stats.concurrency[current_second] = 0
        end
        stats.concurrency[current_second] = stats.concurrency[current_second] + 1
    end
    
    return success
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
            -- 登录
            client:login()
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
            
            -- 如果已登录且未达到操作上限，执行数据库操作
            if client.logined and client.operations_done < config.operations_per_client then
                local now = os.time()
                if now - client.last_operation_time >= (config.operation_interval_ms / 1000) then
                    client:do_db_operation()
                end
            end
        else
            -- 如果客户端断开连接，尝试重连
            client:connect()
        end
    end
end

function calculate_percentile(times, percentile)
    if #times == 0 then
        return 0
    end
    
    table.sort(times)
    local index = math.ceil(#times * percentile / 100)
    return times[index]
end

function print_statistics()
    local now = os.time()
    local duration = now - stats.start_time
    
    -- 计算平均响应时间和各百分位数
    local avg_response_time = 0
    if #stats.response_times > 0 then
        local sum = 0
        for _, time in ipairs(stats.response_times) do
            sum = sum + time
        end
        avg_response_time = sum / #stats.response_times
    end
    
    -- 计算每秒操作数
    local ops_per_second = stats.total_operations / duration
    
    -- 计算各百分位数
    local p50 = calculate_percentile(stats.response_times, 50)
    local p90 = calculate_percentile(stats.response_times, 90)
    local p99 = calculate_percentile(stats.response_times, 99)
    
    -- 计算每种操作类型的平均响应时间
    local op_avg_times = {}
    for op_type, data in pairs(stats.operations) do
        if #data.times > 0 then
            local sum = 0
            for _, time in ipairs(data.times) do
                sum = sum + time
            end
            op_avg_times[op_type] = sum / #data.times
        else
            op_avg_times[op_type] = 0
        end
    end
    
    -- 计算最大并发
    local max_concurrency = 0
    for _, count in pairs(stats.concurrency) do
        if count > max_concurrency then
            max_concurrency = count
        end
    end
    
    log(LOG_LEVEL.INFO, "=== DB Stress Test Report ===")
    log(LOG_LEVEL.INFO, "Duration: %d seconds", duration)
    log(LOG_LEVEL.INFO, "Connected clients: %d/%d", count_connected_clients(), config.client_count)
    log(LOG_LEVEL.INFO, "Total operations: %d", stats.total_operations)
    log(LOG_LEVEL.INFO, "Successful operations: %d (%.2f%%)", 
        stats.total_success, (stats.total_success / stats.total_operations) * 100)
    log(LOG_LEVEL.INFO, "Failed operations: %d (%.2f%%)", 
        stats.total_failed, (stats.total_failed / stats.total_operations) * 100)
    log(LOG_LEVEL.INFO, "Average response time: %.6f seconds", avg_response_time)
    log(LOG_LEVEL.INFO, "Response time percentiles: P50=%.6fs, P90=%.6fs, P99=%.6fs", p50, p90, p99)
    log(LOG_LEVEL.INFO, "Operations per second: %.2f", ops_per_second)
    log(LOG_LEVEL.INFO, "Max concurrency: %d", max_concurrency)
    
    log(LOG_LEVEL.INFO, "Operation type statistics:")
    for op_type, data in pairs(stats.operations) do
        local type_name = ""
        if op_type == DB_OPERATION.QUERY then type_name = "QUERY"
        elseif op_type == DB_OPERATION.CREATE then type_name = "CREATE"
        elseif op_type == DB_OPERATION.UPDATE then type_name = "UPDATE"
        elseif op_type == DB_OPERATION.DELETE then type_name = "DELETE"
        end
        
        log(LOG_LEVEL.INFO, "  %s: count=%d, success=%d, failed=%d, avg_time=%.6fs", 
            type_name, data.count, data.success, data.failed, op_avg_times[op_type])
    end
    
    if next(stats.errors) then
        log(LOG_LEVEL.INFO, "Errors:")
        for err, count in pairs(stats.errors) do
            log(LOG_LEVEL.INFO, "  %s: %d", err, count)
        end
    end
    
    log(LOG_LEVEL.INFO, "=============================")
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
            total_operations = stats.total_operations,
            total_success = stats.total_success,
            total_failed = stats.total_failed,
            operations = stats.operations,
            duration = stats.end_time - stats.start_time,
            avg_response_time = calculate_avg_response_time(),
            p50 = calculate_percentile(stats.response_times, 50),
            p90 = calculate_percentile(stats.response_times, 90),
            p99 = calculate_percentile(stats.response_times, 99),
            operations_per_second = stats.total_operations / (stats.end_time - stats.start_time),
            max_concurrency = calculate_max_concurrency(),
            errors = stats.errors
        }
    }
    
    local file = io.open("db_stress_test_results.json", "w")
    if file then
        file:write(json.encode(result))
        file:close()
        log(LOG_LEVEL.INFO, "Results saved to db_stress_test_results.json")
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

function calculate_max_concurrency()
    local max_concurrency = 0
    for _, count in pairs(stats.concurrency) do
        if count > max_concurrency then
            max_concurrency = count
        end
    end
    return max_concurrency
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
        elseif arg_value == "--operations" and i < #args then
            config.operations_per_client = tonumber(args[i+1]) or config.operations_per_client
            i = i + 2
        elseif arg_value == "--interval" and i < #args then
            config.operation_interval_ms = tonumber(args[i+1]) or config.operation_interval_ms
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
        elseif arg_value == "--ratio" and i < #args then
            local ratios = args[i+1]:match("(%d+),(%d+),(%d+),(%d+)")
            if ratios then
                config.operation_ratio[DB_OPERATION.QUERY] = tonumber(ratio[1]) or config.operation_ratio[DB_OPERATION.QUERY]
                config.operation_ratio[DB_OPERATION.CREATE] = tonumber(ratio[2]) or config.operation_ratio[DB_OPERATION.CREATE]
                config.operation_ratio[DB_OPERATION.UPDATE] = tonumber(ratio[3]) or config.operation_ratio[DB_OPERATION.UPDATE]
                config.operation_ratio[DB_OPERATION.DELETE] = tonumber(ratio[4]) or config.operation_ratio[DB_OPERATION.DELETE]
            end
            i = i + 2
        else
            i = i + 1
        end
    end
end

-- 主函数
function main()
    parse_args()
    
    log(LOG_LEVEL.INFO, "Starting DB stress test with %d clients", config.client_count)
    log(LOG_LEVEL.INFO, "Server: %s:%d", config.host, config.port)
    log(LOG_LEVEL.INFO, "Operations per client: %d", config.operations_per_client)
    log(LOG_LEVEL.INFO, "Operation interval: %d ms", config.operation_interval_ms)
    log(LOG_LEVEL.INFO, "Operation ratio (Query,Create,Update,Delete): %d,%d,%d,%d",
        config.operation_ratio[DB_OPERATION.QUERY],
        config.operation_ratio[DB_OPERATION.CREATE],
        config.operation_ratio[DB_OPERATION.UPDATE],
        config.operation_ratio[DB_OPERATION.DELETE])
    
    stats.start_time = os.time()
    
    create_clients()
    connect_clients()
    
    local last_report = os.time()
    local start = os.time()
    
    while true do
        process_clients()
        
        -- 检查是否所有客户端都完成了请求
        local all_done = true
        for _, client in ipairs(clients) do
            if client.connected and client.operations_done < config.operations_per_client then
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
            log(LOG_LEVEL.INFO, "All clients completed their operations")
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