local skynet = require "skynet"
local crypt = require "skynet.crypt"
local log = require "log"

local encrypt = {}

-- DES加密
function encrypt.des_encrypt(text, key)
    if not text or not key then
        log.error("Encryption error: text or key is nil")
        return nil
    end
    
    local padding_len = 8 - (#text % 8)
    if padding_len > 0 and padding_len < 8 then
        text = text .. string.rep(string.char(padding_len), padding_len)
    end
    
    return crypt.desencode(key, text)
end

-- DES解密
function encrypt.des_decrypt(text, key)
    if not text or not key then
        log.error("Decryption error: text or key is nil")
        return nil
    end
    
    local result = crypt.desdecode(key, text)
    if not result then
        return nil
    end
    
    local len = #result
    if len > 0 then
        local padding = string.byte(result, len)
        if padding and padding <= 8 then
            result = string.sub(result, 1, len - padding)
        end
    end
    
    return result
end

-- AES加密 (通过调用skynet.core的aes函数实现)
function encrypt.aes_encrypt(text, key, iv)
    if not text or not key then
        log.error("AES Encryption error: text or key is nil")
        return nil
    end
    
    -- 实际应用中可能需要引入OpenSSL或其他加密库
    -- 这里使用简化实现
    return crypt.base64encode(encrypt.des_encrypt(text, key)) -- 替代方案
end

-- AES解密
function encrypt.aes_decrypt(text, key, iv)
    if not text or not key then
        log.error("AES Decryption error: text or key is nil")
        return nil
    end
    
    return encrypt.des_decrypt(crypt.base64decode(text), key) -- 替代方案
end

-- RSA生成密钥对
function encrypt.generate_rsa_keypair()
    -- 需要调用RSA库或使用OpenSSL
    -- 以下是模拟返回
    return {
        public_key = "simulated_public_key",
        private_key = "simulated_private_key"
    }
end

-- RSA公钥加密
function encrypt.rsa_encrypt(text, public_key)
    -- 实际应用中应调用OpenSSL或其他RSA库实现
    -- 这里返回base64编码的模拟结果
    if not text or not public_key then
        log.error("RSA Encryption error: text or public_key is nil")
        return nil
    end
    return crypt.base64encode(text .. "_rsa_encrypted")
end

-- RSA私钥解密
function encrypt.rsa_decrypt(encrypted_text, private_key)
    -- 实际应用中应调用OpenSSL或其他RSA库实现
    if not encrypted_text or not private_key then
        log.error("RSA Decryption error: encrypted_text or private_key is nil")
        return nil
    end
    
    local decoded = crypt.base64decode(encrypted_text)
    -- 模拟解密过程
    local original = string.gsub(decoded, "_rsa_encrypted$", "")
    return original
end

-- RSA签名
function encrypt.rsa_sign(text, private_key)
    -- 实际应用中应调用OpenSSL或其他RSA库实现
    if not text or not private_key then
        log.error("RSA Signing error: text or private_key is nil")
        return nil
    end
    -- 模拟签名过程
    local signature = crypt.sha1(text .. private_key)
    return crypt.base64encode(signature)
end

-- RSA验签
function encrypt.rsa_verify(text, signature, public_key)
    -- 实际应用中应调用OpenSSL或其他RSA库实现
    if not text or not signature or not public_key then
        log.error("RSA Verification error: missing parameters")
        return false
    end
    
    -- 模拟验签过程
    local decoded_sig = crypt.base64decode(signature)
    local expected_sig = crypt.sha1(text .. string.gsub(public_key, "public", "private"))
    return decoded_sig == expected_sig
end

-- SHA1哈希
function encrypt.sha1(text)
    return crypt.sha1(text)
end

-- HMAC-SHA1
function encrypt.hmac_sha1(text, key)
    return crypt.hmac_sha1(key, text)
end

-- MD5哈希
function encrypt.md5(text)
    return crypt.md5(text)
end

-- Base64编码
function encrypt.base64_encode(text)
    return crypt.base64encode(text)
end

-- Base64解码
function encrypt.base64_decode(text)
    return crypt.base64decode(text)
end

-- URL编码
function encrypt.url_encode(text)
    if not text then return "" end
    
    text = string.gsub(text, "([^%w%.%- ])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    -- 空格替换为+
    return string.gsub(text, " ", "+")
end

-- URL解码
function encrypt.url_decode(text)
    if not text then return "" end
    
    text = string.gsub(text, "+", " ")
    text = string.gsub(text, "%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
    return text
end

-- 生成随机数
function encrypt.random(len)
    return crypt.randomkey(len)
end

-- 生成唯一令牌
function encrypt.generate_token(uid, timestamp, salt)
    local str = string.format("%s:%d:%s", uid, timestamp, salt)
    return encrypt.md5(str)
end

-- 生成支付签名 (常用于支付接口)
function encrypt.generate_payment_sign(params, secret_key, sign_type)
    -- 第一步：按字母顺序排序参数
    local keys = {}
    for k, _ in pairs(params) do
        if k ~= "sign" and k ~= "sign_type" then  -- 排除sign和sign_type参数
            table.insert(keys, k)
        end
    end
    table.sort(keys)
    
    -- 第二步：拼接key=value字符串
    local str = ""
    for _, k in ipairs(keys) do
        local v = params[k]
        if v ~= nil and v ~= "" and type(v) ~= "table" then
            str = str .. k .. "=" .. tostring(v) .. "&"
        end
    end
    
    -- 第三步：拼接密钥
    str = str .. "key=" .. secret_key
    
    -- 第四步：根据签名类型进行签名
    sign_type = sign_type or "md5"
    if sign_type == "md5" then
        return string.upper(encrypt.md5(str))
    elseif sign_type == "sha1" then
        return string.upper(encrypt.sha1(str))
    elseif sign_type == "hmac_sha1" then
        return string.upper(encrypt.hmac_sha1(str, secret_key))
    else
        log.error("Unsupported sign type: %s", sign_type)
        return nil
    end
end

-- 验证支付签名
function encrypt.verify_payment_sign(params, secret_key, sign_type)
    if not params.sign then
        return false, "签名不存在"
    end
    
    local sign = params.sign
    local calculated_sign = encrypt.generate_payment_sign(params, secret_key, sign_type or "md5")
    
    return sign == calculated_sign, calculated_sign
end

-- Diffie-Hellman密钥交换
function encrypt.dhexchange(...)
    return crypt.dhexchange(...)
end

-- DH密钥交换客户端步骤
function encrypt.dhsecret(...)
    return crypt.dhsecret(...)
end

-- 热更新钩子，old_module是更新前的模块
function encrypt.on_hotfix(old_module)
    log.info("加密模块正在执行热更新")
    -- 如果需要保留旧模块的状态，可以在这里进行
    return true
end

return encrypt 