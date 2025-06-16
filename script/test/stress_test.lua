package.cpath = "luaclib/?.so"
package.path = "lualib/?.lua;script/?.lua;script/test/?.lua"

if _VERSION ~= "Lua 5.4" then
    error "Use lua 5.4"
end

local socket = require "client.socket"
local Client = require "stress_client"
local ChatTest = require "chat_test"
local PlayerTest = require "player_test"
local FriendTest = require "friend_test"  -- 添加好友测试模块
local MailTest = require "mail_test"  -- 添加邮件测试模块
local Stats = require "stats"
local new_socket = require "socket.core"

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
        local args = {...}
        for i, v in ipairs(args) do
            if v == nil then
                args[i] = "nil"
            end
        end
        local msg = string.format(fmt, table.unpack(args))
        print(string.format("[%s][%s] %s", os.date("%Y-%m-%d %H:%M:%S"), levels[level], msg))
    end
end

-- 基础配置
local config = {
    host = "127.0.0.1",
    port = 8888,
    report_interval_ms = 10,   -- 定期报告间隔(秒)
    test_duration = 0,          -- 测试持续时间（秒），0表示无限制
    account_prefix = "test_user_", -- 账号前缀
    total_clients = 500,         -- 总客户端数量
    dynamic_schedule = false,    -- 是否启用动态调度
    schedule_interval = 10,     -- 调度间隔（秒）
    connect_interval_ms = 30,   -- 建立连接的间隔(毫秒)
    test_configs = {           -- 不同测试类型的配置
        chat = {
            target_rps = 100    -- 目标每秒请求数
        },
        player = {
            target_rps = 50    -- 目标每秒请求数
        },
        friend = {             -- 添加好友测试配置
            target_rps = 50     -- 目标每秒请求数
        },
        mail = {              -- 添加邮件测试配置
            target_rps = 50     -- 目标每秒请求数
        }
    }
}

-- 创建测试实例的工具函数
local function create_test_instance(client, test_type, client_count)
    if test_type == "chat" then
        return ChatTest.new(client, config.test_configs.chat, client_count)
    elseif test_type == "player" then
        return PlayerTest.new(client, config.test_configs.player, client_count)
    elseif test_type == "friend" then
        return FriendTest.new(client, config.test_configs.friend, client_count)
    elseif test_type == "mail" then
        return MailTest.new(client, config.test_configs.mail, client_count)
    end
    return nil
end

-- 调度器类定义
local Scheduler = {}
Scheduler.__index = Scheduler

function Scheduler.new(config)
    local self = setmetatable({}, Scheduler)
    self.config = config
    self.clients = {}  -- 所有客户端
    self.tests = {}    -- 所有测试实例
    self.test_types = {"chat", "player", "friend", "mail"}  -- 添加mail测试类型
    
    -- 计算总RPS和每个测试类型的权重
    local total_rps = 0
    self.weights = {}
    for _, test_type in ipairs(self.test_types) do
        total_rps = total_rps + config.test_configs[test_type].target_rps
    end
    for _, test_type in ipairs(self.test_types) do
        self.weights[test_type] = config.test_configs[test_type].target_rps / total_rps
    end
    
    -- 初始化测试类型分配表
    self.type_assignments = {}  -- client_id -> test_type
    self.type_counts = {}      -- test_type -> count
    for _, test_type in ipairs(self.test_types) do
        self.type_counts[test_type] = 0
    end
    
    return self
end

function Scheduler:create_clients()
    -- 创建所有客户端但不立即连接
    for i = 1, self.config.total_clients do
        local client = Client.new(i, self.config)
        self.clients[i] = client
        log(LOG_LEVEL.DEBUG, "Client %d created", i)
    end
end

function Scheduler:init_connections()
    local connected = 0
    local logged_in = 0
    
    for i = 1, self.config.total_clients do
        local client = self.clients[i]
        if client:connect() then
            connected = connected + 1
            if client:try_login() then
                logged_in = logged_in + 1
            end
            
            if i % 100 == 0 then
                log(LOG_LEVEL.INFO, "Progress: Connected %d, Logged in %d", connected, logged_in)
            end
            
            socket.usleep(self.config.connect_interval_ms * 1000)
        end
    end
    
    log(LOG_LEVEL.INFO, "Connection completed: Connected %d/%d, Logged in %d/%d", 
        connected, self.config.total_clients, logged_in, self.config.total_clients)
    
    return connected, logged_in
end

function Scheduler:assign_fixed()
    -- 根据权重固定分配客户端
    local assigned = 0
    for _, test_type in ipairs(self.test_types) do
        local count = math.floor(self.config.total_clients * self.weights[test_type])
        if test_type == self.test_types[#self.test_types] then
            -- 最后一个类型分配剩余的所有客户端（处理舍入误差）
            count = self.config.total_clients - assigned
        end
        
        -- 分配客户端到该测试类型
        for i = assigned + 1, assigned + count do
            if self.clients[i] then
                self.type_assignments[i] = test_type
                self.type_counts[test_type] = self.type_counts[test_type] + 1
                self.tests[i] = create_test_instance(self.clients[i], test_type, count)
            end
        end
        assigned = assigned + count
    end
    
    -- 打印分配结果
    for test_type, count in pairs(self.type_counts) do
        log(LOG_LEVEL.INFO, "Assigned %d clients to %s test (%.1f%%)", 
            count, test_type, (count / self.config.total_clients) * 100)
    end
end

function Scheduler:reassign_random()
    -- 随机重新分配一部分客户端（每次调用时）
    local reassign_count = math.floor(self.config.total_clients * 0.1)  -- 每次重新分配10%的客户端
    for _ = 1, reassign_count do
        local client_id = math.random(1, self.config.total_clients)
        if self.clients[client_id] then
            -- 从原测试类型中移除
            local old_type = self.type_assignments[client_id]
            if old_type then
                self.type_counts[old_type] = self.type_counts[old_type] - 1
            end
            
            -- 随机选择新的测试类型（基于权重）
            local rand = math.random()
            local cumulative = 0
            local new_type
            for test_type, weight in pairs(self.weights) do
                cumulative = cumulative + weight
                if rand <= cumulative then
                    new_type = test_type
                    break
                end
            end
            
            -- 分配到新的测试类型
            self.type_assignments[client_id] = new_type
            self.type_counts[new_type] = self.type_counts[new_type] + 1
            self.tests[client_id] = create_test_instance(self.clients[client_id], new_type, 
                self.type_counts[new_type])
        end
    end
end

-- 解析命令行参数
local function parse_args()
    local args = arg
    local i = 1
    while i <= #args do
        local arg_value = args[i]
        if arg_value == "--chat-clients" and i < #args then
            config.chat_clients = tonumber(args[i+1]) or config.chat_clients
            i = i + 2
        elseif arg_value == "--player-clients" and i < #args then
            config.player_clients = tonumber(args[i+1]) or config.player_clients
            i = i + 2
        elseif arg_value == "--chat-rps" and i < #args then
            config.test_configs.chat.target_rps = tonumber(args[i+1]) or config.test_configs.chat.target_rps
            i = i + 2
        elseif arg_value == "--player-rps" and i < #args then
            config.test_configs.player.target_rps = tonumber(args[i+1]) or config.test_configs.player.target_rps
            i = i + 2
        elseif arg_value == "--friend-rps" and i < #args then
            config.test_configs.friend.target_rps = tonumber(args[i+1]) or config.test_configs.friend.target_rps
            i = i + 2
        elseif arg_value == "--mail-rps" and i < #args then
            config.test_configs.mail.target_rps = tonumber(args[i+1]) or config.test_configs.mail.target_rps
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

-- 修改主函数
local function main()
    parse_args()
    
    log(LOG_LEVEL.INFO, "Starting stress test with configuration:")
    log(LOG_LEVEL.INFO, "Server: %s:%d", config.host, config.port)
    log(LOG_LEVEL.INFO, "Total clients: %d", config.total_clients)
    log(LOG_LEVEL.INFO, "Connect interval: %dms", config.connect_interval_ms)
    
    local stats = Stats.new()
    stats:register_test_type("chat", config.test_configs.chat)
    stats:register_test_type("player", config.test_configs.player)
    stats:register_test_type("friend", config.test_configs.friend)
    stats:register_test_type("mail", config.test_configs.mail)
    
    -- 创建调度器并初始化连接
    local scheduler = Scheduler.new(config)
    scheduler:create_clients()
    local connected, logged_in = scheduler:init_connections()
    
    if connected == 0 then
        log(LOG_LEVEL.ERROR, "No clients connected, stopping test")
        return
    end
    
    scheduler:assign_fixed()
    local now = new_socket.gettime()
    local last_schedule = now
    local last_report = now
    local start = now
    
    -- 主循环
    while true do
        for client_id, client in pairs(scheduler.clients) do
            if client.connected then
                -- 处理响应
                local resp = client:recv_package()
                while resp do
                    client:process_package(resp)
                    resp = client:recv_package()
                end
                
                -- 运行测试
                local test = scheduler.tests[client_id]
                if test then
                    local success = test:run()
                    if success then
                        local test_type = scheduler.type_assignments[client_id]
                        local action = test:get_last_action()
                        if action then 
                            stats:record_request(test_type, action)
                        end 
                    end
                end
            end
        end
        
        -- 动态调度
        if config.dynamic_schedule then
            local now = new_socket.gettime()
            if now - last_schedule >= config.schedule_interval then
                scheduler:reassign_random()
                last_schedule = now
            end
        end
        
        -- 定期报告
        local now = new_socket.gettime()
        if now - last_report >= config.report_interval_ms then
            stats:print_report()
            last_report = now
        end
        
        -- 检查测试持续时间
        if config.test_duration > 0 and now - start >= config.test_duration then
            log(LOG_LEVEL.INFO, "Test duration reached, stopping test")
            break
        end
        
        socket.usleep(10000)  -- 1ms的休眠间隔
    end
    
    -- 清理
    for _, client in pairs(scheduler.clients) do
        client:disconnect()
    end
    
    stats.end_time = new_socket.gettime()
    stats:print_report()
    stats:save_results(config)
end

-- 运行主函数
xpcall(main, function(err)
    log(LOG_LEVEL.ERROR, "Error in main function: " .. tostring(err) .. "\n" .. debug.traceback())
end) 