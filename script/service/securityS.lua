
local skynet = require "skynet"
local log = require "log"
require "skynet.manager"
local service_wrapper = require "utils.service_wrapper"

-- 安全模块
local encrypt = require "security.encrypt"
local token = require "security.token"
local attack_protection = require "security.attack_protection"
local validator = require "security.validator"

local security_config = {
    token_secret = "default_secret_key_change_me_in_production",
    token_expire = 86400, -- 24小时
    rate_limit_enabled = true,
    xss_protection = true,
    sql_injection_protection = true,
    ip_blacklist_enabled = true,
    cleanup_interval = 300, -- 5分钟
}

-- 初始化配置
local function init_config()
    -- 初始化令牌配置
    token.config({
        secret_key = security_config.token_secret,
        expire_time = security_config.token_expire,
        refresh_threshold = security_config.token_expire / 6,
    })
    
    -- 启动清理任务
    token.start_cleanup_task(security_config.cleanup_interval)
    attack_protection.start_cleanup_task(security_config.cleanup_interval)
    
    log.info("Security module initialized with config: %s", table.concat({
        "token_expire=" .. security_config.token_expire,
        "rate_limit=" .. (security_config.rate_limit_enabled and "enabled" or "disabled"),
        "xss_protection=" .. (security_config.xss_protection and "enabled" or "disabled"),
        "sql_protection=" .. (security_config.sql_injection_protection and "enabled" or "disabled"),
        "ip_blacklist=" .. (security_config.ip_blacklist_enabled and "enabled" or "disabled"),
    }, ", "))
end

-- 生成令牌
function CMD.generate_token(uid, device_id, extra_data)
    return token.generate(uid, device_id, extra_data)
end

-- 验证令牌
function CMD.verify_token(token_str)
    return token.verify(token_str)
end

-- 刷新令牌
function CMD.refresh_token(token_str)
    return token.refresh(token_str)
end

-- 注销令牌
function CMD.invalidate_token(token_str)
    return token.invalidate(token_str)
end

-- 加密敏感数据
function CMD.encrypt_data(data, key)
    if type(data) == "table" then
        data = skynet.packstring(data)
    end
    return encrypt.des_encrypt(data, key or security_config.token_secret)
end

-- 解密数据
function CMD.decrypt_data(data, key)
    local decrypted = encrypt.des_decrypt(data, key or security_config.token_secret)
    if not decrypted then
        return nil, "解密失败"
    end
    
    -- 尝试解包为table
    local success, result = pcall(function()
        return skynet.unpack(decrypted)
    end)
    
    if success and type(result) == "table" then
        return result
    end
    
    return decrypted
end

-- 生成HMAC签名
function CMD.generate_signature(data, key)
    if type(data) == "table" then
        data = skynet.packstring(data)
    end
    return encrypt.hmac_sha1(data, key or security_config.token_secret)
end

-- 验证签名
function CMD.verify_signature(data, signature, key)
    if type(data) == "table" then
        data = skynet.packstring(data)
    end
    local expected = encrypt.hmac_sha1(data, key or security_config.token_secret)
    return expected == signature
end

-- 检查请求安全性
function CMD.check_request_safety(params, ip, uid, action)
    local result = true
    local message = nil
    
    -- 检查IP黑名单
    if security_config.ip_blacklist_enabled and ip then
        local is_blacklisted, reason = attack_protection.is_blacklisted(ip)
        if is_blacklisted then
            return false, reason
        end
    end
    
    -- 检查请求频率
    if security_config.rate_limit_enabled and ip then
        result, message = attack_protection.check_rate_limit(ip, uid, action)
        if not result then
            return result, message
        end
    end
    
    -- 检查SQL注入
    if security_config.sql_injection_protection and params then
        result, message = attack_protection.check_request_safety(params)
        if not result then
            return result, message
        end
    end
    
    return true
end

-- 添加IP到黑名单
function CMD.add_to_blacklist(ip, reason, duration)
    if not security_config.ip_blacklist_enabled then
        return false, "IP黑名单功能未启用"
    end
    
    attack_protection.add_to_blacklist(ip, reason, duration)
    return true
end

-- 验证数据
function CMD.validate_data(value, rule_name, ...)
    return validator.validate(value, rule_name, ...)
end

-- 验证表单数据
function CMD.validate_form(form, schema)
    return validator.validate_form(form, schema)
end

-- 获取安全模块状态
function CMD.get_status()
    return {
        config = security_config,
        token_cache_size = #token.get_status and token.get_status() or "N/A",
        blacklist_size = #attack_protection.get_status and attack_protection.get_status().blacklist or "N/A",
    }
end

-- 更新安全配置
function CMD.update_config(config)
    for k, v in pairs(config) do
        if security_config[k] ~= nil then
            security_config[k] = v
        end
    end
    
    -- 重新应用配置
    init_config()
    
    return true
end

local function main()
    -- 初始化配置
    init_config()
end 

service_wrapper.create_service(main, {
    name = "security",
})
