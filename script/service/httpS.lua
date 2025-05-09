package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
local skynet = require "skynet"
local socket = require "skynet.socket"
local httpd = require "http.httpd"
local sockethelper = require "http.sockethelper"
local urllib = require "http.url"
local cjson = require "cjson"
local log = require "log"
local tableUtils = require "tableUtils"
local common = require "common"
local protocol = "https"
-- TLS配置
local TLS_CONFIG = {
    cert = "./cert/server.crt",
    key = "./cert/server.key",
    ca = "./cert/ca.crt",
    verify = true,
    verify_peer = true,
    verify_client = false,
    verify_depth = 3,
    ciphers = "HIGH:!aNULL:!MD5",
    protocols = {"TLSv1.2", "TLSv1.3"},
}

-- 配置常量
local MAX_REQUEST_SIZE = 1024 * 1024  -- 1MB
local RATE_LIMIT = 100  -- 每秒请求数限制
local REQUEST_TIMEOUT = 30  -- 请求超时时间（秒）

-- 请求计数器
local request_counters = {}

-- 清理过期的计数器
local function clean_counters()
    local now = skynet.now()
    for ip, counter in pairs(request_counters) do
        if now - counter.last_reset > 1000 then
            request_counters[ip] = nil
        end
    end
end

-- 检查请求频率
local function check_rate_limit(ip)
    local now = skynet.now()
    if not request_counters[ip] then
        request_counters[ip] = {
            count = 1,
            last_reset = now
        }
    else
        if now - request_counters[ip].last_reset > 1000 then
            request_counters[ip] = {
                count = 1,
                last_reset = now
            }
        else
            request_counters[ip].count = request_counters[ip].count + 1
            if request_counters[ip].count > RATE_LIMIT then
                return false
            end
        end
    end
    return true
end

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
            -- 使用之前生成的证书
            local certfile = TLS_CONFIG.cert
            local keyfile = TLS_CONFIG.key
            
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

local function response(id, write, ...)
    local ok, err = httpd.write_response(write, ...)
    if not ok then
        -- 如果写响应失败，记录错误
        log.error(string.format("fd = %d, %s", id, err))
    end
end

-- 统一的错误响应
local function error_response(fd, write, code)
    response(fd, write, code)
end

-- 统一的成功响应
local function success_response(fd, write, data)
    response(fd, write, 200, "asdadadsdas")
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

-- 处理 HTTP 请求
local function handle_http_request(fd, write, method, path, headers, body)
    -- 获取客户端IP
    local ip = headers["x-forwarded-for"] or headers["x-real-ip"] or "unknown"
    
    -- 检查请求频率
    if not check_rate_limit(ip) then
        error_response(fd, write, 429, "请求过于频繁")
        return
    end
    
    -- 检查请求大小
    if body and #body > MAX_REQUEST_SIZE then
        error_response(fd, write, 413, "请求体过大")
        return
    end
    
    -- 记录请求日志
    log.info(string.format("HTTP请求: %s %s from %s", method, path, ip))
    
    -- 解析请求体（对POST请求）
    local data = {}
    if method == "POST" and body then
        local status, result = pcall(cjson.decode, body)
        if status then
            data = result
        else
            log.error("JSON解析错误: " .. tostring(result))
            error_response(fd, write, 400, "无效的JSON格式")
            return
        end
    end
    
    -- 解析URL参数（对GET请求）
    local params = {}
    if method == "GET" and path:find("?") then
        local base_url, query = path:match("([^?]*)%?(.*)")
        path = base_url
        for pair in query:gmatch("([^&]+)") do
            local k, v = pair:match("([^=]+)=?(.*)")
            params[k] = urllib.unescape(v)
        end
    end
    
    -- 设置请求超时
    local timeout = common.set_timeout(REQUEST_TIMEOUT * 100, function()
        error_response(fd, write, 408, "请求超时")
    end)
    
    -- 基于路径和方法的路由分发
    if path == "/api/users" then

        success_response(fd, {
            ip = "127.0.0.1",
            city = "北京",
            province = "北京",
            country = "中国"
        })
    else
        log.error(string.format("未找到路由: %s", path))
        -- 未找到路由
        error_response(fd, write, 404, "未找到")
    end
    timeout()
end

local function handle_socket(id)
    socket.start(id)
    local interface = gen_interface(protocol, id)
    if interface.init then
        interface.init()
    end
    log.info(string.format("收到请求: %s", id))
    -- limit request body size to 8192 (you can pass nil to unlimit)
    local code, url, method, header, body = httpd.read_request(interface.read, 8192)
    if code then
        if code ~= 200 then
            response(id, interface.write, code)
        else
            handle_http_request(id, interface.write, method, url, header, body)
        end
    else
        if url == sockethelper.socket_error then
            log.error("socket closed")
        else
            log.error(url)
        end
    end
    -- socket.close(id)
    -- if interface.close then
    --     interface.close()
    -- end
end

local function accept(id)
    -- 为每个连接创建一个新的协程
    skynet.fork(
        function()
            local ok, err = pcall(handle_socket, id)
            if not ok then
                log.error(err)
            end 
        end
    )
end

skynet.start(function()
    -- 检查证书文件是否存在
    local function check_cert_files()
        local files = {
            TLS_CONFIG.cert,
            TLS_CONFIG.key,
            TLS_CONFIG.ca
        }
        
        for _, file in ipairs(files) do
            local f = io.open(file, "r")
            if not f then
                log.error("证书文件不存在: " .. file)
                return false
            end
            f:close()
        end
        return true
    end

    -- 检查证书文件
    if not check_cert_files() then
        log.error("缺少必要的TLS证书文件，HTTPS服务启动失败")
        return
    end

    -- 启动HTTPS服务器，监听端口8889
    local id = socket.listen("0.0.0.0", 8889)
    log.info("HTTPS server listening on port 8889")
    
    socket.start(id, accept)
end)
