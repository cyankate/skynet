local skynet = require "skynet"
local socket = require "skynet.socket"
local httpd = require "http.httpd"
local sockethelper = require "http.sockethelper"
local urllib = require "http.url"
local cjson = require "cjson"
local log = require "log"
local tableUtils = require "utils.tableUtils"
local common = require "utils.common"
local attack_protection = require "security.attack_protection"
local table_schema = require "sql.table_schema"
--local jwt = require "resty.jwt"  -- 添加 JWT 库
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
        enabled = false,
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
    auth = {
        enabled = true,
        token_header = "X-Auth-Token",
        token_required = true,
        allowed_origins = {"*"},  -- 允许所有来源，可以设置为具体域名
        token = {
            secret = "your-secret-key",  -- 用于签名验证的密钥
            algorithm = "HS256",         -- 签名算法
            expire_time = 24 * 3600,     -- token 过期时间（秒）
            refresh_time = 7 * 24 * 3600 -- 刷新 token 的有效期（秒）
        },
        third_party = {
            wechat = {
                appid = "your_appid",
                secret = "your_secret",
                code2session_url = "https://api.weixin.qq.com/sns/jscode2session"
            }
        },
    },
    api = {
        version = "1.0.0",
        default_format = "json",
        error_codes = {
            SUCCESS = 0,
            INVALID_PARAMS = 1001,
            UNAUTHORIZED = 1002,
            FORBIDDEN = 1003,
            NOT_FOUND = 1004,
            INTERNAL_ERROR = 1005,
            RATE_LIMIT = 1006
        }
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
                log.error(string.format("Certificate file not found: %s", certfile))
            end
            f:close()
            
            f = io.open(keyfile, "r")
            if not f then
                log.error(string.format("Key file not found: %s", keyfile))
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

-- 统一的响应格式
local function create_response(code, data, message)
    -- return {
    --     code = code or 200,
    --     message = message or "success",
    --     data = data,
    --     timestamp = os.time()
    -- }
    -- data = data or {}
    -- if message then
    --     data.message = message
    -- end
    -- data.code = code or 200
    return data 
end

local function sanitize_for_json(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return "<circular>"
    end
    seen[value] = true

    local max_index = 0
    local int_count = 0
    local has_non_int_key = false
    for k, _ in pairs(value) do
        if type(k) == "number" and k > 0 and math.floor(k) == k then
            int_count = int_count + 1
            if k > max_index then
                max_index = k
            end
        else
            has_non_int_key = true
        end
    end

    local out = {}
    if not has_non_int_key and max_index > 0 then
        local has_hole = (int_count ~= max_index)
        if has_hole then
            -- 稀疏数组转对象，避免 cjson 抛错
            for k, v in pairs(value) do
                out[tostring(k)] = sanitize_for_json(v, seen)
            end
        else
            for i = 1, max_index do
                out[i] = sanitize_for_json(value[i], seen)
            end
        end
    else
        for k, v in pairs(value) do
            out[k] = sanitize_for_json(v, seen)
        end
    end

    seen[value] = nil
    return out
end

local function encode_json_payload(payload)
    local ok, encoded = pcall(cjson.encode, payload)
    if ok then
        return true, encoded
    end
    local sanitized = sanitize_for_json(payload)
    local ok2, encoded2 = pcall(cjson.encode, sanitized)
    if ok2 then
        return true, encoded2
    end
    return false, encoded2
end

-- 统一的成功响应
local function success_response(fd, interface, data, headers)
    -- 创建新的响应headers，而不是直接使用原始headers
    local response_headers = {}
    
    -- 添加安全headers
    response_headers = add_security_headers(response_headers)
    response_headers = add_cors_headers(response_headers)
    
    -- 添加内容类型
    response_headers["Content-Type"] = "application/json; charset=utf-8"
    
    -- 添加缓存控制（可选，根据业务需求调整）
    response_headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    response_headers["Pragma"] = "no-cache"
    response_headers["Expires"] = "0"
    
    -- 添加响应时间戳
    response_headers["X-Response-Time"] = tostring(os.time())
    
    -- 如果有原始headers，可以选择性地保留一些安全的headers
    if headers then
        -- 保留一些安全的headers（根据业务需求调整）
        local safe_headers = {
            "x-request-id",      -- 请求ID，用于追踪
            "x-user-id",         -- 用户ID（如果业务需要）
            "x-trace-id",        -- 追踪ID
            "x-version",         -- 版本信息
        }
        
        for _, header_name in ipairs(safe_headers) do
            local header_value = headers[header_name]
            if header_value then
                response_headers[header_name] = header_value
            end
        end
    end
    
    local ok, payload = encode_json_payload(create_response(200, data))
    if not ok then
        log.error("success_response encode failed: %s", tostring(payload))
        error_response(fd, interface, 500, "Response serialization failed")
        return
    end
    response(fd, interface, 200, payload, response_headers)
end

-- 统一的错误响应
local function error_response(fd, interface, code, message)
    local headers = add_security_headers()
    headers = add_cors_headers(headers)
    headers["Content-Type"] = "application/json; charset=utf-8"
    headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    headers["X-Response-Time"] = tostring(os.time())
    
    response(fd, interface, code, cjson.encode(create_response(code, nil, message)), headers)
end

-- Token 验证相关函数
local function sign_token(payload)
    local ok, token = pcall(function()
        return jwt:sign(config.auth.token.secret, {
            header = {
                typ = "JWT",
                alg = config.auth.token.algorithm
            },
            payload = payload
        })
    end)
    
    if not ok then
        return false, "Failed to sign token"
    end
    return true, token
end

local function verify_token(token)
    if not token then
        return false, "Missing token"
    end
    
    local ok, jwt_obj = pcall(function()
        return jwt:verify(config.auth.token.secret, token)
    end)
    
    if not ok then
        return false, "Invalid token format"
    end
    
    if not jwt_obj["verified"] then
        return false, "Invalid token signature"
    end
    
    local payload = jwt_obj["payload"]
    
    -- 检查过期时间
    if payload.exp and payload.exp < os.time() then
        return false, "Token expired"
    end
    
    return true, payload
end

-- 生成 token
local function generate_token(user_id, data)
    local now = os.time()
    local payload = {
        sub = user_id,           -- 用户ID
        iat = now,              -- 签发时间
        exp = now + config.auth.token.expire_time,  -- 过期时间
        data = data or {}       -- 额外数据
    }
    
    return sign_token(payload)
end

-- 刷新 token
local function refresh_token(token)
    local ok, decoded = verify_token(token)
    if not ok then
        return false, decoded
    end
    
    -- 检查是否在刷新期内
    if decoded.exp and decoded.exp + config.auth.token.refresh_time < os.time() then
        return false, "Token cannot be refreshed"
    end
    
    -- 生成新 token
    return generate_token(decoded.sub, decoded.data)
end

-- 修改验证请求头函数
local function validate_headers(headers)
    if config.auth.enabled and config.auth.token_required then
        local token = headers[config.auth.token_header:lower()]
        if not token then
            return false, "Missing authentication token"
        end
        
        -- 验证 token
        local ok, result = verify_token(token)
        if not ok then
            return false, result
        end
        
        -- 将用户信息添加到请求上下文中
        headers["x-user-id"] = result.sub
        headers["x-user-data"] = cjson.encode(result.data)
    end
    return true
end

-- 验证请求参数
local function validate_params(params, required)
    if not params then
        return false, "Missing parameters"
    end
    for _, field in ipairs(required) do
        if not params[field] then
            return false, string.format("Missing required parameter: %s", field)
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

-- 路径标准化函数
local function normalize_path(path)
    if path:match("/$") and path ~= "/" then
        return path:gsub("/$", "")
    end
    return path
end

-- 路径参数匹配函数
local function match_path_pattern(pattern, path)
    -- 将路径模式转换为正则表达式
    local regex_pattern = pattern:gsub("([^/]+)", function(segment)
        if segment:match("^{[^}]+}$") then
            -- 命名参数，如 {server_id}
            return "([^/]+)"
        else
            -- 普通路径段
            return segment:gsub("[%-%.%+%[%]%*%?%^%$%(%)%%]", "%%%1")
        end
    end)
    
    local matches = {}
    local matched = {path:match("^" .. regex_pattern .. "$")}
    
    if #matched > 0 and matched[1] then
        -- 提取参数名
        local param_names = {}
        pattern:gsub("([^/]+)", function(segment)
            if segment:match("^{[^}]+}$") then
                local param_name = segment:sub(2, -2)
                table.insert(param_names, param_name)
            end
        end)
        
        -- 将匹配的值与参数名对应
        for i, value in ipairs(matched) do
            if param_names[i] then
                matches[param_names[i]] = value
            end
        end
        
        return true, matches
    end
    
    return false
end

-- 注册路由
local function register_route(method, path, handler)
    -- 注册标准化路径
    routes[method][normalize_path(path)] = handler
end

-- 注册带参数的路由
local function register_param_route(method, path_pattern, handler)
    if not routes[method] then
        routes[method] = {}
    end
    
    -- 存储路径模式和处理器
    routes[method][path_pattern] = {
        pattern = path_pattern,
        handler = handler
    }
end

-- 查找路由处理器
local function find_route_handler(method, path)
    -- 首先尝试精确匹配
    local handler = routes[method] and routes[method][path]
    if handler then
        return handler, {}
    end
    
    -- 然后尝试参数匹配
    if routes[method] then
        for pattern, route_info in pairs(routes[method]) do
            if type(route_info) == "table" and route_info.pattern then
                local matched, params = match_path_pattern(route_info.pattern, path)
                if matched then
                    return route_info.handler, params
                end
            end
        end
    end
    
    return nil, {}
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

-- 第三方认证相关函数
local function wechat_code2session(code)
    local url = string.format("%s?appid=%s&secret=%s&js_code=%s&grant_type=authorization_code",
        config.auth.third_party.wechat.code2session_url,
        config.auth.third_party.wechat.appid,
        config.auth.third_party.wechat.secret,
        code
    )
    
    -- 发送HTTP请求获取session
    local http = require "http"
    local ok, result = pcall(function()
        return http.get(url)
    end)
    
    if not ok then
        return false, "Failed to get session"
    end
    
    local session = cjson.decode(result)
    if session.errcode and session.errcode ~= 0 then
        return false, session.errmsg
    end
    
    return true, {
        openid = session.openid,
        session_key = session.session_key
    }
end

-- 修改登录接口
local function register_auth_routes()
    -- 微信小程序登录
    register_route("POST", "/api/auth/wechat/login", function(fd, method, url, headers, body, interface)
        local data = cjson.decode(body)
        -- 验证登录参数
        local valid, err = validate_params(data, {"code"})
        if not valid then
            error_response(fd, interface, 400, err)
            return
        end
        
        -- 获取微信session
        local ok, session = wechat_code2session(data.code)
        if not ok then
            error_response(fd, interface, 401, session)
            return
        end
        
        -- 生成token
        local ok, token = generate_token(session.openid, {
            openid = session.openid,
            type = "wechat"
        })
        
        if not ok then
            error_response(fd, interface, 500, token)
            return
        end
        
        return {
            token = token,
            expires_in = config.auth.token.expire_time,
            openid = session.openid
        }
    end)

    register_route("GET", "/api/people/ip_info", function(fd, method, url, headers, body, interface)
        log.info("ip_info", {body = body})
        return {
            province = "广东省",
            city = "广州市",
            is_strict = false,
        }
    end)
end

-- Web：filters -> dbS select 的 cond（与 Web DB_FILTER_OPS 对齐；字段需在 table_schema 中）
local function web_filters_to_cond(tbl_name, filters)
    local struct = table_schema[tbl_name]
    if not struct then
        return nil, "unknown table: " .. tostring(tbl_name)
    end
    local cond = {}
    for _, f in ipairs(filters or {}) do
        local field = f.field
        if type(field) ~= "string" or field == "" then
            return nil, "each filter needs a non-empty field"
        end
        if not struct.fields[field] then
            return nil, "unknown field: " .. field
        end
        local op = tostring(f.operator or "="):match("^%s*(.-)%s*$") or "="
        local opu = op:upper()
        local val = f.value

        if opu == "=" or op == "==" then
            cond[field] = val
        elseif opu == "!=" or opu == "<>" then
            cond[field] = { ["!="] = val }
        elseif opu == ">" or opu == "<" or opu == ">=" or opu == "<=" then
            cond[field] = { [op] = val }
        elseif opu == "LIKE" then
            if val == nil then
                return nil, "LIKE requires value"
            end
            cond[field] = { __like = tostring(val) }
        elseif opu == "IN" then
            if type(val) ~= "table" then
                return nil, "IN requires value to be a non-empty array"
            end
            if #val == 0 then
                return nil, "IN requires a non-empty array"
            end
            cond[field] = val
        elseif opu == "IS NULL" then
            cond[field] = { __is_null = true }
        elseif opu == "IS NOT NULL" then
            cond[field] = { __is_not_null = true }
        else
            return nil, "unsupported operator: " .. op
        end
    end
    return cond
end

-- 策划配置目录（相对 skynet 工作目录，与 dbS 写 table_schema 路径一致）
local SETTING_DIR = "script/setting"

local function safe_setting_basename(name)
    if type(name) ~= "string" or name == "" or #name > 160 then
        return false
    end
    if name:find("%.%.") or name:find("/", 1, true) or name:find("\\", 1, true) then
        return false
    end
    return name:match("^[%w_%+%-%.]+$") ~= nil
end

local function list_setting_dir()
    local p = io.popen('ls -1 "' .. SETTING_DIR .. '" 2>/dev/null')
    if not p then
        return nil
    end
    local files = {}
    for line in p:lines() do
        line = line:match("^%s*(.-)%s*$") or ""
        if line ~= "" and line:sub(1, 1) ~= "." and safe_setting_basename(line) then
            table.insert(files, line)
        end
    end
    p:close()
    table.sort(files)
    return files
end

local function read_setting_file(name)
    if not safe_setting_basename(name) then
        return nil, "invalid name"
    end
    local path = SETTING_DIR .. "/" .. name
    local f, err = io.open(path, "rb")
    if not f then
        return nil, err or "open failed"
    end
    local content = f:read("*a")
    f:close()
    return content
end

local function write_setting_file(name, content)
    if not safe_setting_basename(name) then
        return false, "invalid name"
    end
    if type(content) ~= "string" then
        return false, "content must be string"
    end
    local path = SETTING_DIR .. "/" .. name
    local f, err = io.open(path, "wb")
    if not f then
        return false, err or "open failed"
    end
    local ok, werr = f:write(content)
    f:close()
    if not ok then
        return false, werr or "write failed"
    end
    return true
end

local function trigger_setting_hotreload()
    local hotfix = skynet.localname(".hotfix")
    if not hotfix then
        return false, "hotfix service unavailable"
    end
    local ok, result = skynet.call(hotfix, "lua", "batch_update", {"all"}, "setting_reload")
    if not ok then
        return false, result
    end
    return true, result
end

-- 注册默认路由
local function register_default_routes()
    register_auth_routes()  -- 添加认证路由
    
    -- 状态查询
    register_route("GET", "/api/status/", function(fd, method, url, headers, body, interface)
        return {
            status = "ok",
            timestamp = os.time(),
            uptime = os.time() - start_time,
            version = config.api.version
        }
    end)

    -- Web 后台：数据库（action: tables | columns | query）
    register_route("POST", "/api/web/db/query", function(fd, method, url, headers, body, interface)
        local ok, data = pcall(cjson.decode, body or "")
        if not ok or type(data) ~= "table" then
            error_response(fd, interface, 400, "Invalid JSON body")
            return
        end
        local db = skynet.localname(".db")
        if not db then
            error_response(fd, interface, 503, "Database service unavailable")
            return
        end

        if not data.action or data.action == "" then
            error_response(fd, interface, 400, "Missing field: action")
            return
        end

        local act = data.action
        if act == "tables" then
            local names = skynet.call(db, "lua", "web_list_tables")
            if not names then
                error_response(fd, interface, 500, "Failed to list tables")
                return
            end
            return { tables = names }
        elseif act == "columns" then
            local tbl = data.table
            if type(tbl) ~= "string" or tbl == "" then
                error_response(fd, interface, 400, "Missing or invalid field: table")
                return
            end
            local cols = skynet.call(db, "lua", "web_list_columns", tbl)
            if not cols then
                error_response(fd, interface, 400, "Failed to load columns (check table name)")
                return
            end
            return { columns = cols }
        elseif act == "query" then
            local tbl = data.table
            if type(tbl) ~= "string" or tbl == "" then
                error_response(fd, interface, 400, "Missing or invalid field: table")
                return
            end
            local sql = data.sql
            if type(sql) == "string" and sql:gsub("%s+", "") ~= "" then
                local rows, err = skynet.call(db, "lua", "web_select_sql", sql)
                if rows == nil then
                    error_response(fd, interface, 400, err or "SQL query failed")
                    return
                end
                return { rows = rows }
            end
            local cond, ferr = web_filters_to_cond(tbl, data.filters)
            if not cond then
                error_response(fd, interface, 400, ferr or "invalid filters")
                return
            end
            local limit = tonumber(data.limit) or 100
            if limit > 5000 then
                limit = 5000
            end
            if limit < 1 then
                limit = 1
            end
            local offset = tonumber(data.offset) or 0
            if offset < 0 then
                offset = 0
            end
            local options = { limit = limit, offset = offset }
            local cok, rows = pcall(function()
                return skynet.call(db, "lua", "select", tbl, cond, options)
            end)
            if not cok then
                log.error("web db query select failed: %s", tostring(rows))
                error_response(fd, interface, 500, tostring(rows))
                return
            end
            return { rows = rows }
        else
            error_response(fd, interface, 400, "Unknown action: " .. tostring(act))
            return
        end
    end)

    -- Web：热更配置 — 读取 script/setting 下数据文件（仅 POST + JSON）
    register_route("POST", "/api/web/hotreload", function(fd, method, url, headers, body, interface)
        local ok, data = pcall(cjson.decode, body or "")
        if not ok or type(data) ~= "table" then
            error_response(fd, interface, 400, "Invalid JSON body")
            return
        end
        if not data.action or data.action == "" then
            error_response(fd, interface, 400, "Missing field: action")
            return
        end
        local act = data.action
        if act == "list" then
            local files = list_setting_dir()
            if not files then
                error_response(fd, interface, 500, "Failed to list setting directory")
                return
            end
            return { files = files, dir = SETTING_DIR }
        elseif act == "get" then
            local name = data.name
            if type(name) ~= "string" or name == "" then
                error_response(fd, interface, 400, "Missing or invalid field: name")
                return
            end
            local content, err = read_setting_file(name)
            if content == nil then
                error_response(fd, interface, 404, tostring(err or "file not found"))
                return
            end
            return { name = name, content = content }
        elseif act == "upload" then
            local name = data.name
            if type(name) ~= "string" or name == "" then
                error_response(fd, interface, 400, "Missing or invalid field: name")
                return
            end
            if type(data.content) ~= "string" then
                error_response(fd, interface, 400, "Missing or invalid field: content")
                return
            end
            local wok, werr = write_setting_file(name, data.content)
            if not wok then
                error_response(fd, interface, 400, tostring(werr or "write failed"))
                return
            end
            local hok, hres = trigger_setting_hotreload()
            if not hok then
                error_response(fd, interface, 500, "hotreload failed: " .. tostring(hres))
                return
            end
            return {
                updated = true,
                name = name,
                size = #data.content,
                hotreload = hres,
            }
        else
            error_response(fd, interface, 400, "Unknown action: " .. tostring(act))
            return
        end
    end)

    -- Web 后台：下发命令（占位，后续实现业务）
    register_route("POST", "/api/web/command", function(fd, method, url, headers, body, interface)
        error_response(fd, interface, 501, "Web command API not implemented yet")
    end)

    
end

-- 检查数据访问权限
local function check_data_access(user_id, data)
    -- 如果数据没有所有者信息，则不允许访问
    if not data.owner_id then
        return false, "No access permission"
    end
    
    -- 检查是否是数据所有者
    if data.owner_id ~= user_id then
        return false, "Access denied"
    end
    
    return true
end

-- 处理HTTP请求
local function handle_request(fd, method, url, headers, body, interface)
    -- 记录请求
    log_request(method, url, headers, body)
    
    -- 执行中间件
    -- local ok, result = execute_middlewares(fd, method, url, headers, body, interface)
    -- if not ok then
    --     error_response(fd, interface, 500, result)
    --     return
    -- end
    -- if result then
    --     return
    -- end
    
    -- 解析URL和查询参数
    local path, query = urllib.parse(url)
    local query_params = {}
    if query then
        query_params = urllib.parse_query(query)
    end
    
    -- 标准化路径
    local normalized_path = normalize_path(path)
    
    -- 获取用户身份（从请求头中获取，不暴露在URL中）
    local user_id = headers["x-user-id"] or "anonymous"
    
    -- 查找并执行路由处理函数
    local handler, params = find_route_handler(method, normalized_path)
    if handler then
        local ok, result = pcall(handler, fd, method, url, headers, body, interface, params, query_params)
        if not ok then
            error_response(fd, interface, 500, result)
            return
        end
        
        if result then
            -- 返回成功响应
            success_response(fd, interface, result, headers)
        end
    else
        error_response(fd, interface, 404, "Not Found")
    end
end

-- 添加数据访问控制中间件
local function register_data_access_middleware()
    register_middleware(function(fd, method, url, headers, body, interface)
        -- 获取用户身份
        local user_id = headers["x-user-id"] or "anonymous"
        
        -- 解析URL
        local path = urllib.parse(url)
        
        -- 检查是否是敏感路径
        if path:match("^/api/data/") then
            -- 验证用户权限
            if user_id == "anonymous" then
                error_response(fd, interface, 401, "Authentication required")
                return true
            end
            
            -- 可以添加更多的权限检查逻辑
            -- 例如：检查用户角色、检查资源所有权等
        end
    end)
end

-- 在注册默认中间件时添加数据访问控制
local function register_default_middlewares()
    register_data_access_middleware()  -- 添加数据访问控制中间件
    -- 请求验证中间件
    register_middleware(function(fd, method, url, headers, body, interface)
        local valid, err = validate_request(method, url, headers)
        if not valid then
            error_response(fd, interface, 400, err)
            return true
        end
        
        -- -- 验证请求头
        -- valid, err = validate_headers(headers)
        -- if not valid then
        --     error_response(fd, interface, 401, err)
        --     return true
        -- end
    end)
    
    -- 速率限制中间件 
    register_middleware(function(fd, method, url, headers, body, interface)
        local client_ip = headers["X-Real-IP"] or headers["X-Forwarded-For"] or "unknown"
        if not attack_protection.check_rate_limit(client_ip) then
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
 
    local fd = socket.listen("0.0.0.0", 8889)
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
            log_error("Failed to read request", {fd = id})
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
end

-- 启动服务
skynet.start(function()
    start_http_server()
end)
