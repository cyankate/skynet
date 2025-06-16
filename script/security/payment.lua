local skynet = require "skynet"
local log = require "log"
local encrypt = require "security.encrypt"

local payment = {}

-- 支付配置
local payment_config = {
    -- 支付渠道配置
    channels = {
        alipay = {
            app_id = "2021000000000000",
            merchant_id = "2088000000000000", 
            app_private_key = "私钥内容...",
            alipay_public_key = "支付宝公钥...",
            notify_url = "https://api.yourgame.com/payment/notify/alipay",
            return_url = "https://api.yourgame.com/payment/return/alipay"
        },
        wechat = {
            app_id = "wx00000000000000",
            mch_id = "1000000000",
            key = "32位密钥...",
            notify_url = "https://api.yourgame.com/payment/notify/wechat" 
        },
        appstore = {
            bundle_id = "com.yourgame.app",
            shared_secret = "共享密钥..."
        },
        google = {
            package_name = "com.yourgame.app",
            service_account_key = "服务账号密钥..."
        }
    },
    
    -- 风控配置
    risk_control = {
        -- 单个账号支付限额
        account_limit = {
            daily = 2000,   -- 单日限额
            monthly = 50000 -- 单月限额
        },
        -- IP地址支付限额
        ip_limit = {
            daily = 10000,  -- 单日限额
        },
        -- 设备ID支付限额
        device_limit = {
            daily = 5000,   -- 单日限额
            monthly = 100000 -- 单月限额
        },
        -- 频率控制
        frequency = {
            min_interval = 10,  -- 最小支付间隔(秒)
            max_daily = 50      -- 单日最大支付次数
        }
    },
    
    -- 签名配置
    sign = {
        key = "支付签名密钥...",
        expire_time = 300,  -- 签名有效期(秒)
    }
}

-- 获取支付渠道配置
function payment.get_channel_config(channel)
    return payment_config.channels[channel]
end

-- 更新支付配置
function payment.update_config(config)
    for k, v in pairs(config) do
        if type(v) == "table" and type(payment_config[k]) == "table" then
            for k2, v2 in pairs(v) do
                payment_config[k][k2] = v2
            end
        else
            payment_config[k] = v
        end
    end
    return true
end

-- 生成支付签名
function payment.sign(params, channel)
    local channel_config = payment_config.channels[channel]
    if not channel_config then
        return nil, "未知支付渠道"
    end
    
    local sign_key = channel_config.key or payment_config.sign.key
    
    -- 根据渠道选择不同的签名方式
    if channel == "alipay" then
        -- 支付宝使用RSA签名
        return encrypt.rsa_sign(params, channel_config.app_private_key)
    elseif channel == "wechat" then
        -- 微信使用MD5签名
        return encrypt.generate_payment_sign(params, sign_key, "md5")
    else
        -- 默认使用MD5签名
        return encrypt.generate_payment_sign(params, sign_key, "md5")
    end
end

-- 验证支付签名
function payment.verify_sign(params, channel, signature)
    local channel_config = payment_config.channels[channel]
    if not channel_config then
        return false, "未知支付渠道"
    end
    
    local sign_key = channel_config.key or payment_config.sign.key
    
    if channel == "alipay" then
        -- 支付宝使用RSA验签
        return encrypt.rsa_verify(params, signature, channel_config.alipay_public_key)
    elseif channel == "wechat" then
        -- 微信使用MD5验签
        return encrypt.verify_payment_sign(params, sign_key, "md5")
    else
        -- 默认使用MD5验签
        return encrypt.verify_payment_sign(params, sign_key, "md5")
    end
end

-- 生成订单ID
function payment.generate_order_id(player_id, timestamp)
    -- 格式：前缀 + 玩家ID + 时间戳 + 随机数
    timestamp = timestamp or os.time()
    local random = encrypt.random(4)
    local order_id = string.format("PAY%d%d%s", player_id, timestamp, 
        encrypt.base64_encode(random):sub(1, 8))
    return order_id
end

-- 风控检查
function payment.risk_check(account_id, player_id, ip, device_id, amount)
    local risk_config = payment_config.risk_control
    local current_time = os.time()
    local today_start = os.date("%Y-%m-%d 00:00:00", current_time)
    
    -- 检查账号支付限额
    if account_id and risk_config.account_limit then
        -- 这里应该查询数据库，获取该账号今日已支付金额
        -- 假设查询结果为 account_paid_today 和 account_paid_month
        local account_paid_today = 0
        local account_paid_month = 0
        
        -- 检查日限额
        if risk_config.account_limit.daily and 
           account_paid_today + amount > risk_config.account_limit.daily then
            return false, "账号每日支付金额超过限制"
        end
        
        -- 检查月限额
        if risk_config.account_limit.monthly and 
           account_paid_month + amount > risk_config.account_limit.monthly then
            return false, "账号每月支付金额超过限制"
        end
    end
    
    -- 检查IP支付限额
    if ip and risk_config.ip_limit then
        -- 查询该IP今日已支付金额
        local ip_paid_today = 0
        
        -- 检查日限额
        if risk_config.ip_limit.daily and 
           ip_paid_today + amount > risk_config.ip_limit.daily then
            return false, "IP每日支付金额超过限制"
        end
    end
    
    -- 检查设备支付限额
    if device_id and risk_config.device_limit then
        -- 查询该设备今日已支付金额
        local device_paid_today = 0
        local device_paid_month = 0
        
        -- 检查日限额
        if risk_config.device_limit.daily and 
           device_paid_today + amount > risk_config.device_limit.daily then
            return false, "设备每日支付金额超过限制"
        end
        
        -- 检查月限额
        if risk_config.device_limit.monthly and 
           device_paid_month + amount > risk_config.device_limit.monthly then
            return false, "设备每月支付金额超过限制"
        end
    end
    
    -- 检查支付频率
    if player_id and risk_config.frequency then
        -- 查询玩家最近一次支付时间和今日支付次数
        local last_pay_time = 0
        local today_pay_count = 0
        
        -- 检查最小支付间隔
        if risk_config.frequency.min_interval and 
           current_time - last_pay_time < risk_config.frequency.min_interval then
            return false, "支付操作过于频繁，请稍后再试"
        end
        
        -- 检查每日最大支付次数
        if risk_config.frequency.max_daily and 
           today_pay_count >= risk_config.frequency.max_daily then
            return false, "每日支付次数已达上限"
        end
    end
    
    return true
end

-- 验证支付通知
function payment.verify_notify(channel, notify_data)
    local channel_config = payment_config.channels[channel]
    if not channel_config then
        return false, "未知支付渠道"
    end
    
    -- 根据不同渠道验证通知数据
    if channel == "alipay" then
        -- 支付宝通知验证
        local sign = notify_data.sign
        notify_data.sign = nil
        notify_data.sign_type = nil
        
        return encrypt.rsa_verify(encrypt.url_encode(notify_data), sign, channel_config.alipay_public_key)
    elseif channel == "wechat" then
        -- 微信通知验证
        return encrypt.verify_payment_sign(notify_data, channel_config.key, "md5")
    elseif channel == "appstore" then
        -- App Store通知验证
        -- 通常需要解析receipt数据并向苹果服务器验证
        -- 此处简化处理
        return true
    elseif channel == "google" then
        -- Google Play通知验证
        -- 通常需要使用服务账号验证购买数据
        -- 此处简化处理
        return true
    end
    
    return false, "不支持的支付渠道通知验证"
end

-- 生成支付令牌 (用于客户端请求支付)
function payment.generate_token(order_info)
    local expire_time = os.time() + payment_config.sign.expire_time
    
    -- 组合支付信息
    local token_data = {
        order_id = order_info.order_id,
        player_id = order_info.player_id,
        product_id = order_info.product_id,
        amount = order_info.amount,
        expire_time = expire_time
    }
    
    -- 序列化并签名
    local token_str = skynet.packstring(token_data)
    local sign = encrypt.hmac_sha1(token_str, payment_config.sign.key)
    
    -- 返回支付令牌
    return encrypt.base64_encode(token_str .. "." .. sign)
end

-- 验证支付令牌
function payment.verify_token(token)
    if not token then
        return false, "令牌不能为空"
    end
    
    local decoded = encrypt.base64_decode(token)
    if not decoded then
        return false, "令牌格式错误"
    end
    
    local parts = string.split(decoded, ".")
    if #parts ~= 2 then
        return false, "令牌格式错误"
    end
    
    local token_str, sign = parts[1], parts[2]
    
    -- 验证签名
    local expected_sign = encrypt.hmac_sha1(token_str, payment_config.sign.key)
    if sign ~= expected_sign then
        return false, "令牌签名验证失败"
    end
    
    -- 解析数据
    local success, token_data = pcall(function()
        return skynet.unpack(token_str)
    end)
    
    if not success or type(token_data) ~= "table" then
        return false, "令牌数据解析失败"
    end
    
    -- 检查是否过期
    if token_data.expire_time < os.time() then
        return false, "令牌已过期"
    end
    
    return true, token_data
end

-- string.split 函数定义，如果已有此工具函数请删除
if not string.split then
    function string.split(str, sep)
        local ret = {}
        local pattern = string.format("([^%s]+)", sep)
        for match in string.gmatch(str, pattern) do
            table.insert(ret, match)
        end
        return ret
    end
end

-- 热更新钩子
function payment.on_hotfix(old_module)
    log.info("支付安全模块正在执行热更新")
    
    -- 保留原有配置
    if old_module and old_module.channel_configs then
        payment_config.channels = old_module.channel_configs
        log.info("支付渠道配置已从旧模块迁移")
    end
    
    -- 保留风控规则
    if old_module and old_module.risk_rules then
        payment_config.risk_control = old_module.risk_rules
        log.info("风控规则已从旧模块迁移")
    end
    
    return true
end

return payment