local skynet = require "skynet"
local log = require "log"
local service_ctx = require "runtime.service_ctx"
local encrypt = require "security.encrypt"
local token = require "security.token"
local attack_protection = require "security.attack_protection"
local validator = require "security.validator"

local M = service_ctx.get("security.security", {})
M.security_config = M.security_config or {
    token_secret = "default_secret_key_change_me_in_production",
    token_expire = 86400,
    rate_limit_enabled = true,
    xss_protection = true,
    sql_injection_protection = true,
    ip_blacklist_enabled = true,
    cleanup_interval = 300,
}
M._inited = M._inited or false
local security_config = M.security_config

local function init_config()
    token.config({
        secret_key = security_config.token_secret,
        expire_time = security_config.token_expire,
        refresh_threshold = security_config.token_expire / 6,
    })
    token.start_cleanup_task(security_config.cleanup_interval)
    attack_protection.start_cleanup_task(security_config.cleanup_interval)
end

function M.generate_token(uid, device_id, extra_data) return token.generate(uid, device_id, extra_data) end
function M.verify_token(token_str) return token.verify(token_str) end
function M.refresh_token(token_str) return token.refresh(token_str) end
function M.invalidate_token(token_str) return token.invalidate(token_str) end

function M.encrypt_data(data, key)
    if type(data) == "table" then data = skynet.packstring(data) end
    return encrypt.des_encrypt(data, key or security_config.token_secret)
end

function M.decrypt_data(data, key)
    local decrypted = encrypt.des_decrypt(data, key or security_config.token_secret)
    if not decrypted then return nil, "解密失败" end
    local success, result = pcall(function() return skynet.unpack(decrypted) end)
    if success and type(result) == "table" then return result end
    return decrypted
end

function M.generate_signature(data, key)
    if type(data) == "table" then data = skynet.packstring(data) end
    return encrypt.hmac_sha1(data, key or security_config.token_secret)
end

function M.verify_signature(data, signature, key)
    if type(data) == "table" then data = skynet.packstring(data) end
    local expected = encrypt.hmac_sha1(data, key or security_config.token_secret)
    return expected == signature
end

function M.check_request_safety(params, ip, uid, action)
    if security_config.ip_blacklist_enabled and ip then
        local is_blacklisted, reason = attack_protection.is_blacklisted(ip)
        if is_blacklisted then return false, reason end
    end
    if security_config.rate_limit_enabled and ip then
        local result, message = attack_protection.check_rate_limit(ip, uid, action)
        if not result then return result, message end
    end
    if security_config.sql_injection_protection and params then
        local result, message = attack_protection.check_request_safety(params)
        if not result then return result, message end
    end
    return true
end

function M.add_to_blacklist(ip, reason, duration)
    if not security_config.ip_blacklist_enabled then return false, "IP黑名单功能未启用" end
    attack_protection.add_to_blacklist(ip, reason, duration)
    return true
end

function M.validate_data(value, rule_name, ...) return validator.validate(value, rule_name, ...) end
function M.validate_form(form, schema) return validator.validate_form(form, schema) end

function M.get_status()
    return {
        config = security_config,
        token_cache_size = #token.get_status and token.get_status() or "N/A",
        blacklist_size = #attack_protection.get_status and attack_protection.get_status().blacklist or "N/A",
    }
end

function M.update_config(config)
    for k, v in pairs(config) do
        if security_config[k] ~= nil then security_config[k] = v end
    end
    init_config()
    return true
end

function M.init()
    if M._inited then return end
    M._inited = true
    init_config()
    log.info("Security module initialized")
end

return M
