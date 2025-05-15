local skynet = require "skynet"
local encrypt = require "security.encrypt"
local log = require "log"
local tableUtils = require "utils.tableUtils"

local token = {}

-- 令牌配置
local TOKEN_CONFIG = {
    SECRET_KEY = "iamthekeytoeverything", -- 密钥
    EXPIRE_TIME = 86400, -- 默认过期时间(秒)，此处为24小时
    REFRESH_THRESHOLD = 3600, -- 刷新阈值(秒)，小于这个值时自动刷新
}

-- 令牌缓存，用于快速验证和防止重放攻击
local token_cache = {}

-- 生成令牌
function token.generate(user_id, device_id, extra_data)
    if not user_id then
        log.error("Token generation error: user_id is nil")
        return nil
    end
    
    local timestamp = math.floor(skynet.time())
    local expire_time = timestamp + TOKEN_CONFIG.EXPIRE_TIME
    local nonce = encrypt.random(8) -- 8字节随机数
    
    local token_data = {
        uid = user_id,
        did = device_id or "",
        exp = expire_time,
        iat = timestamp,
        nonce = nonce,
    }
    
    -- 添加额外数据
    if extra_data and type(extra_data) == "table" then
        for k, v in pairs(extra_data) do
            if k ~= "uid" and k ~= "exp" and k ~= "iat" and k ~= "nonce" then
                token_data[k] = v
            end
        end
    end
    
    -- 生成签名
    local payload = tableUtils.serialize_table(token_data)
    local signature = encrypt.hmac_sha1(payload, TOKEN_CONFIG.SECRET_KEY)
    
    -- 构建完整令牌
    local full_token = {
        data = token_data,
        sign = signature
    }
    
    -- 序列化并加密
    local token_str = tableUtils.serialize_table(full_token)
    local encrypted_token = encrypt.base64_encode(token_str)
    
    -- 缓存令牌
    token_cache[encrypted_token] = {
        user_id = user_id,
        expire_time = expire_time,
        last_access = timestamp
    }
    
    return encrypted_token
end

-- 验证令牌
function token.verify(token_str)
    if not token_str or token_str == "" then
        return false, "令牌为空"
    end
    
    -- 检查缓存
    local cache_entry = token_cache[token_str]
    if cache_entry then
        local current_time = math.floor(skynet.time())
        
        -- 检查过期
        if cache_entry.expire_time < current_time then
            token_cache[token_str] = nil
            return false, "令牌已过期"
        end
        
        -- 更新最后访问时间
        cache_entry.last_access = current_time
        return true, cache_entry.user_id
    end
    
    -- 解密令牌
    local success, decrypted_token = pcall(function()
        local decoded = encrypt.base64_decode(token_str)
        return tableUtils.deserialize_table(decoded)
    end)
    
    if not success or not decrypted_token then
        return false, "令牌格式错误"
    end
    
    -- 验证结构
    if not decrypted_token.data or not decrypted_token.sign then
        return false, "令牌结构无效"
    end
    
    -- 验证签名
    local payload = tableUtils.serialize_table(decrypted_token.data)
    local expected_sign = encrypt.hmac_sha1(payload, TOKEN_CONFIG.SECRET_KEY)
    
    if expected_sign ~= decrypted_token.sign then
        return false, "令牌签名无效"
    end
    
    -- 验证过期时间
    local current_time = math.floor(skynet.time())
    if decrypted_token.data.exp < current_time then
        return false, "令牌已过期"
    end
    
    -- 缓存验证结果
    token_cache[token_str] = {
        user_id = decrypted_token.data.uid,
        expire_time = decrypted_token.data.exp,
        last_access = current_time
    }
    
    return true, decrypted_token.data.uid, decrypted_token.data
end

-- 刷新令牌
function token.refresh(token_str)
    local is_valid, user_id, token_data = token.verify(token_str)
    
    if not is_valid then
        return nil, "无效令牌无法刷新"
    end
    
    local current_time = math.floor(skynet.time())
    local remaining_time = token_data.exp - current_time
    
    -- 只有当剩余时间小于刷新阈值时才刷新
    if remaining_time > TOKEN_CONFIG.REFRESH_THRESHOLD then
        return token_str
    end
    
    -- 生成新令牌，但保留原始数据
    local new_token = token.generate(user_id, token_data.did, token_data)
    
    -- 使旧令牌无效
    token_cache[token_str] = nil
    
    return new_token
end

-- 使令牌失效
function token.invalidate(token_str)
    if token_cache[token_str] then
        token_cache[token_str] = nil
        return true
    end
    return false
end

-- 清理过期令牌
function token.cleanup()
    local current_time = math.floor(skynet.time())
    local count = 0
    
    for t, info in pairs(token_cache) do
        if info.expire_time < current_time then
            token_cache[t] = nil
            count = count + 1
        end
    end
    
    return count
end

-- 设置配置选项
function token.config(options)
    if options.secret_key then
        TOKEN_CONFIG.SECRET_KEY = options.secret_key
    end
    
    if options.expire_time then
        TOKEN_CONFIG.EXPIRE_TIME = options.expire_time
    end
    
    if options.refresh_threshold then
        TOKEN_CONFIG.REFRESH_THRESHOLD = options.refresh_threshold
    end
end

-- 启动定期清理过期令牌的任务
function token.start_cleanup_task(interval)
    interval = interval or 3600 -- 默认每小时清理一次
    
    skynet.fork(function()
        while true do
            skynet.sleep(interval * 100) -- skynet.sleep单位是0.01秒
            local count = token.cleanup()
        end
    end)
end

return token 