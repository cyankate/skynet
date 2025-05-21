local skynet = require "skynet"
local log = require "log"

local attack_protection = {}

-- 频率限制记录
local rate_limit_record = {}

-- IP黑名单
local ip_blacklist = {}

-- 请求类型限制配置
local REQUEST_LIMITS = {
    login = { count = 1000, window = 60 },     -- 60秒内最多5次登录尝试
    register = { count = 300, window = 300 }, -- 5分钟内最多3次注册尝试
    payment = { count = 10, window = 3600 },-- 1小时内最多10次支付请求
    default = { count = 10000, window = 60 }  -- 默认60秒内最多100次请求
}

-- 频率限制检查（ip + uid + action基础上的限制）
function attack_protection.check_rate_limit(ip, uid, action)
    action = action or "default"
    local limit_config = REQUEST_LIMITS[action] or REQUEST_LIMITS.default
    
    -- 构建唯一键
    local key = string.format("%s:%s:%s", ip, uid or "anonymous", action)
    local now = skynet.time()
    
    -- 初始化记录
    if not rate_limit_record[key] then
        rate_limit_record[key] = {
            count = 0,
            first_request_time = now,
            last_request_time = now
        }
    end
    
    local record = rate_limit_record[key]
    
    -- 检查是否超过时间窗口，如果是则重置计数
    if now - record.first_request_time > limit_config.window then
        record.count = 0
        record.first_request_time = now
    end
    
    -- 更新计数和最后请求时间
    record.count = record.count + 1
    record.last_request_time = now
    
    -- 检查是否超过限制
    if record.count > limit_config.count then
        log.warning("Rate limit exceeded for %s, count: %d", key, record.count)
        return false, string.format("请求过于频繁，请%d秒后再试", 
            math.ceil(limit_config.window - (now - record.first_request_time)))
    end
    
    return true
end

-- 设置IP黑名单
function attack_protection.add_to_blacklist(ip, reason, duration)
    if not ip then return end
    
    duration = duration or 3600 -- 默认封禁1小时
    local expire_time = skynet.time() + duration
    
    ip_blacklist[ip] = {
        reason = reason or "可疑行为",
        expire_time = expire_time
    }
    
    log.warning("IP %s added to blacklist: %s, until %s", 
        ip, reason or "可疑行为", os.date("%Y-%m-%d %H:%M:%S", math.floor(expire_time)))
end

-- 检查IP是否在黑名单中
function attack_protection.is_blacklisted(ip)
    if not ip_blacklist[ip] then
        return false
    end
    
    local now = skynet.time()
    if now > ip_blacklist[ip].expire_time then
        ip_blacklist[ip] = nil
        return false
    end
    
    return true, ip_blacklist[ip].reason
end

-- SQL注入检测
function attack_protection.check_sql_injection(input)
    if type(input) ~= "string" then
        return true
    end
    
    -- 常见SQL注入模式
    local patterns = {
        "['\"%;]--%s+",
        "['\"%;]%s*$",
        "xp_cmd",
        "DROP%s+TABLE",
        "DELETE%s+FROM",
        "INSERT%s+INTO",
        "UPDATE%s+.+%s+SET",
        "SELECT%s+.+%s+FROM",
        "UNION%s+SELECT",
        "UNION%s+ALL%s+SELECT",
        "OR%s+%d+%s*=%s*%d+"
    }
    
    for _, pattern in ipairs(patterns) do
        if string.match(string.upper(input), pattern) then
            log.warning("Possible SQL injection detected: %s", input)
            return false, "检测到可能的SQL注入攻击"
        end
    end
    
    return true
end

-- XSS攻击检测
function attack_protection.check_xss(input)
    if type(input) ~= "string" then
        return true
    end
    
    -- 常见XSS攻击模式
    local patterns = {
        "<script[^>]*>",
        "</script>",
        "javascript:",
        "onerror=",
        "onload=",
        "eval%(",
        "document%.cookie",
        "alert%("
    }
    
    for _, pattern in ipairs(patterns) do
        if string.match(string.lower(input), pattern) then
            log.warning("Possible XSS attack detected: %s", input)
            return false, "检测到可能的XSS攻击"
        end
    end
    
    return true
end

-- 检查一组参数是否存在安全风险
function attack_protection.check_request_safety(params)
    if type(params) ~= "table" then
        return true
    end
    
    for k, v in pairs(params) do
        if type(v) == "string" then
            local sql_safe, sql_msg = attack_protection.check_sql_injection(v)
            if not sql_safe then
                return false, sql_msg
            end
            
            local xss_safe, xss_msg = attack_protection.check_xss(v)
            if not xss_safe then
                return false, xss_msg
            end
        elseif type(v) == "table" then
            local safe, msg = attack_protection.check_request_safety(v)
            if not safe then
                return false, msg
            end
        end
    end
    
    return true
end

-- 清理过期的记录
function attack_protection.cleanup()
    local now = skynet.time()
    local count = 0
    
    -- 清理限流记录
    for k, record in pairs(rate_limit_record) do
        local action = string.match(k, "[^:]+$")
        local limit_config = REQUEST_LIMITS[action] or REQUEST_LIMITS.default
        
        if now - record.last_request_time > limit_config.window * 2 then
            rate_limit_record[k] = nil
            count = count + 1
        end
    end
    
    -- 清理IP黑名单
    for ip, info in pairs(ip_blacklist) do
        if now > info.expire_time then
            ip_blacklist[ip] = nil
            count = count + 1
        end
    end
    
    return count
end

-- 设置请求限制
function attack_protection.set_request_limit(action, count, window)
    if not action or not count or not window then
        return false, "参数不完整"
    end
    
    REQUEST_LIMITS[action] = {
        count = count,
        window = window
    }
    
    return true
end

-- 启动定期清理过期记录的任务
function attack_protection.start_cleanup_task(interval)
    interval = interval or 300 -- 默认每5分钟清理一次
    
    skynet.fork(function()
        while true do
            skynet.sleep(interval * 100) -- skynet.sleep单位是0.01秒
            local count = attack_protection.cleanup()
        end
    end)
end

return attack_protection 