local skynet = require "skynet"
local log = require "log"
require "skynet.manager"
local payment_security = require "security.payment"
local encrypt = require "security.encrypt"
local service_wrapper = require "utils.service_wrapper"

-- 支付记录状态
local PAYMENT_STATUS = {
    CREATED = 0,     -- 创建
    PROCESSING = 1,  -- 处理中
    SUCCESS = 2,     -- 成功
    FAILED = 3,      -- 失败
    REFUND = 4       -- 退款
}

-- 支付渠道
local PAYMENT_CHANNEL = {
    ALIPAY = "alipay",       -- 支付宝
    WECHAT = "wechat",       -- 微信支付
    APPSTORE = "appstore",   -- 苹果App Store
    GOOGLE = "google",       -- Google Play
    PAYPAL = "paypal",       -- PayPal
    CARD = "card",           -- 信用卡
    OTHER = "other"          -- 其他
}

-- 商品配置
local products = {}

-- 数据库连接
local db

-- 初始化函数
local function init()
    -- 连接数据库
    db = skynet.localname(".db")
    
    -- 加载商品配置
    local ok, product_config = pcall(require, "define.product_config")
    if ok then
        products = product_config
        log.info("商品配置加载成功，共%d个商品", #products)
    else
        log.error("商品配置加载失败: %s", product_config)
    end
end

-- 记录支付日志
local function log_payment(order_id, status, content, operator)
    skynet.call(db, "lua", "insert", "payment_log", {
        order_id = order_id,
        status = status,
        log_content = content,
        operator = operator or "system"
    })
end

-- 创建订单
function CMD.create_order(player_id, account_id, product_id, channel, device_id, ip_address, extra_data)
    -- 参数检查
    if not player_id or not account_id or not product_id or not channel then
        return {code = 1, message = "参数不完整"}
    end
    
    -- 查找商品信息
    local product = nil
    for _, p in ipairs(products) do
        if p.id == product_id then
            product = p
            break
        end
    end
    
    if not product then
        return {code = 2, message = "商品不存在"}
    end
    
    -- 风控检查
    local is_safe, risk_message = payment_security.risk_check(
        account_id, player_id, ip_address, device_id, product.amount)
    
    if not is_safe then
        log.warning("订单风控检查不通过: player_id=%d, account_id=%d, product_id=%s, reason=%s", 
            player_id, account_id, product_id, risk_message)
        return {code = 3, message = risk_message}
    end
    
    -- 生成订单号
    local order_id = payment_security.generate_order_id(player_id)
    
    -- 创建支付记录
    local current_time = os.date("%Y-%m-%d %H:%M:%S")
    local payment_data = {
        order_id = order_id,
        player_id = player_id,
        account_id = account_id,
        product_id = product_id,
        product_name = product.name,
        amount = product.amount,
        currency = product.currency or "CNY",
        channel = channel,
        status = PAYMENT_STATUS.CREATED,
        create_time = current_time,
        ip_address = ip_address,
        device_id = device_id,
        extra_data = extra_data and skynet.packstring(extra_data) or nil
    }
    
    -- 插入数据库
    local result = skynet.call(db, "lua", "insert", "payment", payment_data)
    if not result then
        return {code = 4, message = "订单创建失败"}
    end
    
    -- 记录日志
    log_payment(order_id, PAYMENT_STATUS.CREATED, "订单创建成功")
    
    -- 根据不同渠道准备支付参数
    local pay_params = {}
    local channel_config = payment_security.get_channel_config(channel)
    
    if channel == PAYMENT_CHANNEL.ALIPAY then
        -- 支付宝参数
        pay_params = {
            app_id = channel_config.app_id,
            method = "alipay.trade.app.pay",
            charset = "utf-8",
            sign_type = "RSA2",
            timestamp = current_time,
            version = "1.0",
            notify_url = channel_config.notify_url,
            biz_content = skynet.packstring({
                out_trade_no = order_id,
                total_amount = tostring(product.amount),
                subject = product.name,
                product_code = "QUICK_MSECURITY_PAY"
            })
        }
        
        -- 生成签名
        local sign = payment_security.sign(skynet.packstring(pay_params), channel)
        pay_params.sign = sign
        
    elseif channel == PAYMENT_CHANNEL.WECHAT then
        -- 微信支付参数
        pay_params = {
            appid = channel_config.app_id,
            mch_id = channel_config.mch_id,
            nonce_str = encrypt.random(16),
            body = product.name,
            out_trade_no = order_id,
            total_fee = math.floor(product.amount * 100), -- 转换为分
            spbill_create_ip = ip_address,
            notify_url = channel_config.notify_url,
            trade_type = "APP"
        }
        
        -- 生成签名
        local sign = payment_security.sign(pay_params, channel)
        pay_params.sign = sign
        
    elseif channel == PAYMENT_CHANNEL.APPSTORE then
        -- App Store IAP参数
        pay_params = {
            product_id = product_id,
            order_id = order_id
        }
        
    elseif channel == PAYMENT_CHANNEL.GOOGLE then
        -- Google Play参数
        pay_params = {
            product_id = product_id,
            order_id = order_id
        }
    end
    
    -- 生成支付令牌
    local token = payment_security.generate_token({
        order_id = order_id,
        player_id = player_id,
        product_id = product_id,
        amount = product.amount
    })
    
    return {
        code = 0,
        order_id = order_id,
        pay_params = pay_params,
        token = token
    }
end

-- 处理支付通知
function CMD.handle_notify(channel, notify_data)
    -- 参数检查
    if not channel or not notify_data then
        return {code = 1, message = "参数不完整"}
    end
    
    -- 验证通知签名
    local is_valid, verify_message = payment_security.verify_notify(channel, notify_data)
    if not is_valid then
        log.error("支付通知验证失败: channel=%s, reason=%s", channel, verify_message)
        return {code = 2, message = "通知验证失败"}
    end
    
    -- 提取订单号(不同渠道字段不同)
    local order_id = nil
    if channel == PAYMENT_CHANNEL.ALIPAY then
        order_id = notify_data.out_trade_no
    elseif channel == PAYMENT_CHANNEL.WECHAT then
        order_id = notify_data.out_trade_no
    elseif channel == PAYMENT_CHANNEL.APPSTORE then
        -- 解析receipt获取订单号
        order_id = notify_data.order_id
    elseif channel == PAYMENT_CHANNEL.GOOGLE then
        -- 解析purchase数据获取订单号
        order_id = notify_data.order_id
    end
    
    if not order_id then
        log.error("无法从通知中获取订单号: channel=%s", channel)
        return {code = 3, message = "无法识别订单"}
    end
    
    -- 查询订单信息
    local order = skynet.call(db, "lua", "find_one", "payment", {order_id = order_id})
    if not order then
        log.error("订单不存在: order_id=%s", order_id)
        return {code = 4, message = "订单不存在"}
    end
    
    -- 检查订单状态
    if order.status == PAYMENT_STATUS.SUCCESS then
        log.info("订单已处理成功，忽略重复通知: order_id=%s", order_id)
        return {code = 0, message = "订单已处理"}
    end
    
    -- 检查支付状态
    local is_payment_success = false
    if channel == PAYMENT_CHANNEL.ALIPAY then
        is_payment_success = (notify_data.trade_status == "TRADE_SUCCESS" or notify_data.trade_status == "TRADE_FINISHED")
    elseif channel == PAYMENT_CHANNEL.WECHAT then
        is_payment_success = (notify_data.result_code == "SUCCESS" and notify_data.return_code == "SUCCESS")
    elseif channel == PAYMENT_CHANNEL.APPSTORE then
        is_payment_success = true -- 需要进一步验证receipt
    elseif channel == PAYMENT_CHANNEL.GOOGLE then
        is_payment_success = true -- 需要进一步验证购买状态
    end
    
    -- 更新订单状态
    local status = is_payment_success and PAYMENT_STATUS.SUCCESS or PAYMENT_STATUS.FAILED
    local update_data = {
        status = status,
        pay_time = is_payment_success and os.date("%Y-%m-%d %H:%M:%S") or nil,
        channel_order_id = notify_data.trade_no or notify_data.transaction_id,
        notify_data = skynet.packstring(notify_data),
        notify_time = os.date("%Y-%m-%d %H:%M:%S")
    }
    
    local result = skynet.call(db, "lua", "update", "payment", 
        {order_id = order_id}, update_data)
    
    if not result then
        log.error("更新订单状态失败: order_id=%s", order_id)
        return {code = 5, message = "更新订单状态失败"}
    end
    
    -- 记录日志
    log_payment(order_id, status, is_payment_success and "支付成功" or "支付失败")
    
    -- 如果支付成功，发放商品
    if is_payment_success then
        -- 获取玩家代理
        local agent = skynet.call(".login", "lua", "get_agent_by_player_id", order.player_id)
        if agent then
            -- 通知玩家代理发放商品
            skynet.send(agent, "lua", "deliver_product", {
                order_id = order_id,
                product_id = order.product_id,
                amount = order.amount
            })
        else
            log.warning("玩家不在线，无法立即发放商品: player_id=%d, order_id=%s", 
                order.player_id, order_id)
            -- 可以将订单标记为待发放，等玩家上线时处理
        end
    end
    
    return {code = 0, message = "处理成功"}
end

-- 查询订单
function CMD.query_order(order_id)
    if not order_id then
        return {code = 1, message = "订单ID不能为空"}
    end
    
    local order = skynet.call(db, "lua", "find_one", "payment", {order_id = order_id})
    if not order then
        return {code = 2, message = "订单不存在"}
    end
    
    -- 如果额外数据是JSON，解析它
    if order.extra_data then
        local ok, data = pcall(skynet.unpack, order.extra_data)
        if ok then
            order.extra_data = data
        end
    end
    
    -- 如果通知数据是JSON，解析它
    if order.notify_data then
        local ok, data = pcall(skynet.unpack, order.notify_data)
        if ok then
            order.notify_data = data
        end
    end
    
    return {code = 0, data = order}
end

-- 查询玩家订单列表
function CMD.query_player_orders(player_id, status, limit, offset)
    if not player_id then
        return {code = 1, message = "玩家ID不能为空"}
    end
    
    limit = limit or 10
    offset = offset or 0
    
    local query = {player_id = player_id}
    if status then
        query.status = status
    end
    
    local orders = skynet.call(db, "lua", "find", "payment", query, 
        {limit = limit, offset = offset, sort = {create_time = -1}})
    
    local total = skynet.call(db, "lua", "count", "payment", query)
    
    return {
        code = 0,
        data = {
            list = orders,
            total = total,
            limit = limit,
            offset = offset
        }
    }
end

-- 获取商品列表
function CMD.get_products()
    return {code = 0, data = products}
end

-- 更新商品配置
function CMD.update_products(new_products)
    if type(new_products) ~= "table" then
        return {code = 1, message = "商品配置必须是表格"}
    end
    
    products = new_products
    return {code = 0, message = "商品配置更新成功"}
end

-- 手动发放商品
function CMD.manual_deliver(order_id, admin_id)
    if not order_id then
        return {code = 1, message = "订单ID不能为空"}
    end
    
    local order = skynet.call(db, "lua", "find_one", "payment", {order_id = order_id})
    if not order then
        return {code = 2, message = "订单不存在"}
    end
    
    -- 检查订单状态
    if order.status ~= PAYMENT_STATUS.SUCCESS then
        order.status = PAYMENT_STATUS.SUCCESS
        order.pay_time = os.date("%Y-%m-%d %H:%M:%S")
        
        -- 更新订单状态
        skynet.call(db, "lua", "update", "payment", 
            {order_id = order_id}, 
            {status = order.status, pay_time = order.pay_time})
        
        -- 记录日志
        log_payment(order_id, PAYMENT_STATUS.SUCCESS, "管理员手动确认支付", admin_id or "admin")
    end
    
    -- 获取玩家代理
    local agent = skynet.call(".login", "lua", "get_agent_by_player_id", order.player_id)
    if agent then
        -- 通知玩家代理发放商品
        skynet.send(agent, "lua", "deliver_product", {
            order_id = order_id,
            product_id = order.product_id,
            amount = order.amount
        })
        
        return {code = 0, message = "商品发放成功"}
    else
        log.warning("玩家不在线，无法立即发放商品: player_id=%d, order_id=%s", 
            order.player_id, order_id)
        
        -- 可以将订单标记为待发放，等玩家上线时处理
        return {code = 3, message = "玩家不在线，已标记为待发放"}
    end
end

local function main()
    log.info("Payment service started")
    
    -- 初始化
    init()
    
    -- 注册服务
    skynet.register(".payment")
end

service_wrapper.create_service(main, {
    name = "payment",
})