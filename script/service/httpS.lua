
local skynet = require "skynet"
local socket = require "skynet.socket"
local httpd = require "http.httpd"
local sockethelper = require "http.sockethelper"
local urllib = require "http.url"
local cjson = require "cjson"
local log = require "log"
local tableUtils = require "utils.tableUtils"
local common = require "utils.common"
require "skynet.manager"

-- 配置管理
local config = {
    server = {
        host = "0.0.0.0",
        port = 8889,
        max_connections = 1000,
        timeout = 30,
        keep_alive = true,
        request_timeout = 30,
        max_request_size = 1024 * 1024  -- 1MB
    },
    tls = {
        enabled = true,
        cert = "../../cert/server.crt",
        key = "../../cert/server.key",
        ca = "../../cert/ca.crt",
        verify = true,
        verify_peer = true,
        verify_client = false,
        verify_depth = 3,
        ciphers = "HIGH:!aNULL:!MD5",
        protocols = {"TLSv1.2", "TLSv1.3"}
    },
    rate_limit = {
        enabled = true,
        requests_per_second = 100,
        burst = 200
    },
    health_check = {
        enabled = true,
        interval = 30,  -- 30秒检查一次
        timeout = 5,    -- 5秒超时
        path = "/health"
    },
    metrics = {
        enabled = true,
        retention_period = 3600,  -- 1小时
        cleanup_interval = 300,   -- 5分钟清理一次
        path = "/metrics"
    },
    cache = {
        enabled = true,
        ttl = 3600,     -- 1小时
        max_size = 1000 -- 最大缓存条目数
    }
}

-- 连接池管理
local connection_pool = {
    max_size = 100,
    timeout = 300,  -- 5分钟
    connections = {}
}

-- 缓存支持
local cache = {
    data = {},
    max_size = 1000,
    ttl = 3600  -- 1小时
}

-- 监控指标
local metrics = {
    requests = {
        total = 0,
        by_status = {},
        by_path = {},
        by_method = {},
        history = {}  -- 添加历史记录
    },
    performance = {
        response_time = {},
        errors = 0
    }
}

-- 安全相关的HTTP头
local function add_security_headers(headers)
    headers = headers or {}
    headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    headers["X-Content-Type-Options"] = "nosniff"
    headers["X-Frame-Options"] = "DENY"
    headers["X-XSS-Protection"] = "1; mode=block"
    headers["Content-Security-Policy"] = "default-src 'self'"
    return headers
end

-- CORS支持
local function add_cors_headers(headers)
    headers = headers or {}
    headers["Access-Control-Allow-Origin"] = "*"
    headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
    headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    return headers
end

-- 结构化日志
local function log_request(method, path, headers, body, status_code)
    local log_data = {
        timestamp = os.time(),
        method = method,
        path = path,
        ip = headers["x-forwarded-for"] or headers["x-real-ip"] or "unknown",
        status_code = status_code,
        user_agent = headers["user-agent"],
        content_length = body and #body or 0
    }
    log.info(cjson.encode(log_data))
end

-- 错误日志
local function log_error(err, context)
    local error_data = {
        timestamp = os.time(),
        error = err,
        context = context,
        stack = debug.traceback()
    }
    log.error(cjson.encode(error_data))
end

-- 更新指标
local function update_metrics(method, path, status_code, response_time)
    metrics.requests.total = metrics.requests.total + 1
    metrics.requests.by_status[status_code] = (metrics.requests.by_status[status_code] or 0) + 1
    metrics.requests.by_path[path] = (metrics.requests.by_path[path] or 0) + 1
    metrics.requests.by_method[method] = (metrics.requests.by_method[method] or 0) + 1
    
    -- 添加历史记录
    table.insert(metrics.requests.history, {
        timestamp = os.time(),
        method = method,
        path = path,
        status_code = status_code,
        response_time = response_time
    })
    
    -- 限制历史记录数量
    if #metrics.requests.history > 1000 then
        table.remove(metrics.requests.history, 1)
    end
end

-- 请求验证
local function validate_request(method, path, headers)
    if not method or not path then
        return false, "Invalid request"
    end
    
    -- 检查Content-Type
    if method == "POST" and headers["content-type"] ~= "application/json" then
        return false, "Content-Type must be application/json"
    end
    
    return true
end

-- 健康检查
local start_time = os.time()
local function check_health()
    return {
        status = "ok",
        uptime = os.time() - start_time,
        connections = #connection_pool.connections,
        memory = collectgarbage("count"),
        requests = metrics.requests.total
    }
end

-- 优雅关闭
local function graceful_shutdown()
    -- 停止接受新连接
    socket.close(listen_fd)
    
    -- 等待现有请求完成
    local timeout = 30
    local start_time = os.time()
    while #connection_pool.connections > 0 and os.time() - start_time < timeout do
        skynet.sleep(100)
    end
    
    -- 关闭所有连接
    for _, conn in ipairs(connection_pool.connections) do
        socket.close(conn.fd)
    end
    
    -- 保存状态
    log.info("Server shutdown gracefully")
end

-- TLS配置
local TLS_CONFIG = config.tls

local SSLCTX_SERVER = nil
local function gen_interface(protocol, fd)
    if protocol == "http" then
        return {
            init = nil,
            close = nil,
            read = sockethelper.readfunc(fd),
            write = sockethelper.writefunc(fd),
        }
    elseif protocol == "https" then
        local tls = require "http.tlshelper"
        if not SSLCTX_SERVER then
            SSLCTX_SERVER = tls.newctx()
            -- 使用配置中的证书
            local certfile = skynet.getenv("certfile") or "./cert/server.crt"
            local keyfile = skynet.getenv("keyfile") or "./cert/server.key"
            
            -- 检查证书文件是否存在
            local f = io.open(certfile, "r")
            if not f then
                error(string.format("Certificate file not found: %s", certfile))
            end
            f:close()
            
            f = io.open(keyfile, "r")
            if not f then
                error(string.format("Key file not found: %s", keyfile))
            end
            f:close()
            
            -- 设置证书
            SSLCTX_SERVER:set_cert(certfile, keyfile)
        end
        
        local tls_ctx = tls.newtls("server", SSLCTX_SERVER)
        return {
            init = tls.init_responsefunc(fd, tls_ctx),
            close = tls.closefunc(tls_ctx),
            read = tls.readfunc(fd, tls_ctx),
            write = tls.writefunc(fd, tls_ctx),
        }
    else
        error(string.format("Invalid protocol: %s", protocol))
    end
end

local function response(id, interface, ...)
    local start_time = os.time()
    local ok, err = httpd.write_response(interface.write, ...)
    local response_time = os.time() - start_time
    
    if not ok then
        -- 如果写响应失败，记录错误
        log_error(err, {fd = id})
        metrics.performance.errors = metrics.performance.errors + 1
    end
    
    -- 更新指标
    local status_code = select(1, ...)
    update_metrics("", "", status_code, response_time)
    
    return ok, err
end

-- 统一的错误响应
local function error_response(fd, interface, code, message)
    local headers = add_security_headers()
    headers = add_cors_headers(headers)
    response(fd, interface, code, cjson.encode({
        error = true,
        message = message or "Internal Server Error",
        code = code
    }), headers)
end

-- 统一的成功响应
local function success_response(fd, interface, data, headers)
    headers = headers or {}
    headers = add_security_headers(headers)
    headers = add_cors_headers(headers)
    response(fd, interface, 200, cjson.encode({
        error = false,
        data = data
    }), headers)
end

-- 验证请求参数
local function validate_params(params, required)
    for _, field in ipairs(required) do
        if not params[field] then
            return false, "缺少必要参数: " .. field
        end
    end
    return true
end

-- 路由表
local routes = {
    GET = {},
    POST = {},
    PUT = {},
    DELETE = {},
    OPTIONS = {}
}

-- 注册路由
local function register_route(method, path, handler)
    routes[method][path] = handler
end

-- 注册中间件
local middlewares = {}
local function register_middleware(middleware)
    table.insert(middlewares, middleware)
end

-- 执行中间件
local function execute_middlewares(fd, method, url, headers, body, interface)
    for _, middleware in ipairs(middlewares) do
        local ok, result = pcall(middleware, fd, method, url, headers, body, interface)
        if not ok then
            return false, result
        end
        if result then
            return true, result
        end
    end
    return true
end

-- 注册默认路由
local function register_default_routes()
    -- 健康检查
    register_route("GET", "/health", function(fd, method, url, headers, body, interface)
        return check_health()
    end)
    
    -- 指标查询
    register_route("GET", "/metrics", function(fd, method, url, headers, body, interface)
        return metrics
    end)
    
    -- 状态查询
    register_route("GET", "/api/status", function(fd, method, url, headers, body, interface)
        return {
            status = "ok",
            timestamp = os.time(),
            uptime = os.time() - start_time
        }
    end)
    
    -- 服务信息
    register_route("GET", "/api/info", function(fd, method, url, headers, body, interface)
        return {
            version = "1.0.0",
            name = "HTTPS Service",
            description = "A secure HTTPS service built with Skynet"
        }
    end)
    
    -- Echo服务
    register_route("POST", "/api/echo", function(fd, method, url, headers, body, interface)
        local data = cjson.decode(body)
        return {
            echo = data,
            timestamp = os.time()
        }
    end)
end

-- 注册默认中间件
local function register_default_middlewares()
    -- 请求验证中间件
    register_middleware(function(fd, method, url, headers, body, interface)
        local valid, err = validate_request(method, url, headers)
        if not valid then
            error_response(fd, interface, 400, err)
            return true
        end
    end)
    
    -- 速率限制中间件
    register_middleware(function(fd, method, url, headers, body, interface)
        local client_ip = headers["X-Real-IP"] or headers["X-Forwarded-For"] or "unknown"
        if not check_rate_limit(client_ip) then
            error_response(fd, interface, 429, "Too Many Requests")
            return true
        end
    end)
    
    -- CORS中间件
    register_middleware(function(fd, method, url, headers, body, interface)
        if method == "OPTIONS" then
            local headers = add_security_headers()
            headers = add_cors_headers(headers)
            response(fd, interface, 204, "", headers)
            return true
        end
    end)
end

-- 处理HTTP请求
local function handle_request(fd, method, url, headers, body, interface)
    -- 记录请求
    log_request(method, url, headers, body)
    
    -- 执行中间件
    local ok, result = execute_middlewares(fd, method, url, headers, body, interface)
    if not ok then
        error_response(fd, interface, 500, result)
        return
    end
    if result then
        return
    end
    
    -- 解析URL
    local path, query = urllib.parse(url)
    
    -- 检查缓存
    local cache_key = string.format("%s:%s:%s", method, path, query)
    if config.cache.enabled and cache[cache_key] then
        local cached_data = cache[cache_key]
        if os.time() - cached_data.timestamp < config.cache.ttl then
            success_response(fd, interface, cached_data.data)
            return
        end
    end
    
    -- 查找并执行路由处理函数
    local handler = routes[method] and routes[method][path]
    if handler then
        local ok, result = pcall(handler, fd, method, url, headers, body, interface)
        if not ok then
            error_response(fd, interface, 500, result)
            return
        end
        
        if result then
            -- 缓存结果
            if config.cache.enabled then
                cache[cache_key] = {
                    data = result,
                    timestamp = os.time()
                }
            end
            
            -- 返回成功响应
            success_response(fd, interface, result)
        end
    else
        error_response(fd, interface, 404, "Not Found")
    end
end

-- 启动HTTP服务
local function start_http_server()
    -- 注册默认路由和中间件
    register_default_routes()
    register_default_middlewares()
    
    local server = {
        host = config.server.host,
        port = config.server.port,
        maxclient = config.server.max_connections,
    }
    
    local protocol = "http"
    if config.tls.enabled then
        protocol = "https"
    end
    local fd = socket.listen(server.host, server.port)
    socket.start(fd, function(id, addr)
        socket.start(id)
        
        -- 初始化接口
        local interface = gen_interface(protocol, id)
        if interface.init then
            interface.init()
        end
        
        -- 处理请求
        local code, url, method, header, body = httpd.read_request(interface.read, config.server.max_request_size)
        if not code then
            log_error(result, {fd = id})
            error_response(id, interface, 500, "Internal Server Error")
            return
        end
        if code ~= 200 then
            error_response(id, interface, code, "Internal Server Error")
        else 
            -- 处理请求
            handle_request(id, method, url, header, body, interface)
        end 
    end)
    
    -- 启动健康检查
    if config.health_check.enabled then
        skynet.fork(function()
            while true do
                check_health()
                skynet.sleep(config.health_check.interval * 100)
            end
        end)
    end
    
    -- 启动指标收集
    if config.metrics.enabled then
        skynet.fork(function()
            while true do
                -- 定期清理过期的指标数据
                local now = os.time()
                local i = 1
                while i <= #metrics.requests.history do
                    if now - metrics.requests.history[i].timestamp > config.metrics.retention_period then
                        table.remove(metrics.requests.history, i)
                    else
                        i = i + 1
                    end
                end
                skynet.sleep(config.metrics.cleanup_interval * 100)
            end
        end)
    end
    
    -- 注册关闭处理
    skynet.register_protocol {
        name = "text",
        id = skynet.PTYPE_TEXT,
        unpack = skynet.tostring,
        dispatch = function(_, address, text)
            if text == "shutdown" then
                graceful_shutdown()
            end
        end
    }

    skynet.register(".http")
end

-- 启动服务
skynet.start(function()
    start_http_server()
end)
