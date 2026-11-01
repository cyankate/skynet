local skynet = require "skynet"
local log = require "log"
local payment_security = require "security.payment"
local encrypt = require "security.encrypt"
local service_ctx = require "runtime.service_ctx"
local rpc = require "cluster.rpc"
local locator = require "cluster.locator"

local PAYMENT_STATUS = { CREATED = 0, PROCESSING = 1, SUCCESS = 2, FAILED = 3, REFUND = 4 }
local PAYMENT_CHANNEL = {
    ALIPAY = "alipay", WECHAT = "wechat", APPSTORE = "appstore", GOOGLE = "google", PAYPAL = "paypal", CARD = "card", OTHER = "other",
}

local M = service_ctx.get("payment.payment", {})
M.products = M.products or {}
M.db = M.db or nil
M._inited = M._inited or false

local function log_payment(order_id, status, content, operator)
    skynet.call(M.db, "lua", "insert", "payment_log", {
        order_id = order_id, status = status, log_content = content, operator = operator or "system",
    })
end

function M.init()
    if M._inited then return end
    M._inited = true
    M.db = skynet.localname(".db")
    local ok, product_config = pcall(require, "define.product_config")
    if ok then M.products = product_config end
end

local function find_product(product_id)
    for _, p in ipairs(M.products or {}) do
        if p.id == product_id then
            return p
        end
    end
    return nil
end

local function build_reward_items(product)
    local items = {}
    if not product then
        return items
    end
    for _, it in ipairs(product.items or {}) do
        if it.id and it.count then
            items[it.id] = (items[it.id] or 0) + it.count
        end
    end
    local diamond = (product.diamond or 0) + (product.bonus or 0)
    if diamond > 0 then
        items["diamond"] = (items["diamond"] or 0) + diamond
    end
    return items
end

-- 发放订单奖励：op_id = pay:<order_id>，agent 侧幂等；离线时等下次登录补发
function M.grant_order_reward(order)
    if not order then
        return false
    end
    local product = find_product(order.product_id)
    local items = build_reward_items(product)
    if not next(items) then
        return true
    end
    local agent = locator.get_agent(order.player_id)
    if not agent then
        return false, "offline"
    end
    local ok, result, err = rpc.call_timeout(agent, 500, "grant_items_critical", {
        player_id = order.player_id,
        op_id = "pay:" .. tostring(order.order_id),
        items = items,
        reason = "payment_reward",
    })
    if not ok or not result then
        log.error("grant payment reward failed, order=%s err=%s",
            tostring(order.order_id), tostring(err))
        return false, err or "grant failed"
    end
    return true
end

-- 玩家登录后补发已支付但未发放的订单（幂等）
function M.claim_player_rewards(player_id)
    player_id = tonumber(player_id)
    if not player_id then
        return false
    end
    local orders = skynet.call(M.db, "lua", "find", "payment", {
        player_id = player_id,
        status = PAYMENT_STATUS.SUCCESS,
    }, { limit = 100 })
    local granted = 0
    for _, order in ipairs(orders or {}) do
        local exists = skynet.call(M.db, "lua", "op_get", "pay:" .. tostring(order.order_id))
        if not exists then
            local ok = M.grant_order_reward(order)
            if ok then
                granted = granted + 1
            end
        end
    end
    return true, granted
end

function M.create_order(player_id, account_id, product_id, channel, device_id, ip_address, extra_data)
    if not player_id or not account_id or not product_id or not channel then return { code = 1, message = "参数不完整" } end
    local product
    for _, p in ipairs(M.products) do if p.id == product_id then product = p break end end
    if not product then return { code = 2, message = "商品不存在" } end
    local is_safe, risk_message = payment_security.risk_check(account_id, player_id, ip_address, device_id, product.amount)
    if not is_safe then return { code = 3, message = risk_message } end
    local order_id = payment_security.generate_order_id(player_id)
    local current_time = os.date("%Y-%m-%d %H:%M:%S")
    local payment_data = {
        order_id = order_id, player_id = player_id, account_id = account_id, product_id = product_id, product_name = product.name,
        amount = product.amount, currency = product.currency or "CNY", channel = channel, status = PAYMENT_STATUS.CREATED,
        create_time = current_time, ip_address = ip_address, device_id = device_id, extra_data = extra_data and skynet.packstring(extra_data) or nil,
    }
    local result = skynet.call(M.db, "lua", "insert", "payment", payment_data)
    if not result then return { code = 4, message = "订单创建失败" } end
    log_payment(order_id, PAYMENT_STATUS.CREATED, "订单创建成功")
    local pay_params = {}
    local channel_config = payment_security.get_channel_config(channel)
    if channel == PAYMENT_CHANNEL.ALIPAY then
        pay_params = {
            app_id = channel_config.app_id, method = "alipay.trade.app.pay", charset = "utf-8", sign_type = "RSA2",
            timestamp = current_time, version = "1.0", notify_url = channel_config.notify_url,
            biz_content = skynet.packstring({ out_trade_no = order_id, total_amount = tostring(product.amount), subject = product.name, product_code = "QUICK_MSECURITY_PAY" }),
        }
        pay_params.sign = payment_security.sign(skynet.packstring(pay_params), channel)
    elseif channel == PAYMENT_CHANNEL.WECHAT then
        pay_params = {
            appid = channel_config.app_id, mch_id = channel_config.mch_id, nonce_str = encrypt.random(16), body = product.name,
            out_trade_no = order_id, total_fee = math.floor(product.amount * 100), spbill_create_ip = ip_address,
            notify_url = channel_config.notify_url, trade_type = "APP",
        }
        pay_params.sign = payment_security.sign(pay_params, channel)
    elseif channel == PAYMENT_CHANNEL.APPSTORE or channel == PAYMENT_CHANNEL.GOOGLE then
        pay_params = { product_id = product_id, order_id = order_id }
    end
    local ret_token = payment_security.generate_token({ order_id = order_id, player_id = player_id, product_id = product_id, amount = product.amount })
    return { code = 0, order_id = order_id, pay_params = pay_params, token = ret_token }
end

function M.handle_notify(channel, notify_data)
    if not channel or not notify_data then return { code = 1, message = "参数不完整" } end
    if notify_data.token then
        local ok, token_data = payment_security.verify_token(notify_data.token)
        if not ok then return { code = 6, message = "支付令牌无效: " .. (token_data or "") } end
        if notify_data.out_trade_no and token_data.order_id and notify_data.out_trade_no ~= token_data.order_id then
            return { code = 7, message = "支付令牌内容与通知订单号不一致" }
        end
    end
    local is_valid = payment_security.verify_notify(channel, notify_data)
    if not is_valid then return { code = 2, message = "通知验证失败" } end
    local order_id = notify_data.out_trade_no or notify_data.order_id
    if not order_id then return { code = 3, message = "无法识别订单" } end
    local order = skynet.call(M.db, "lua", "find_one", "payment", { order_id = order_id })
    if not order then return { code = 4, message = "订单不存在" } end
    if order.status == PAYMENT_STATUS.SUCCESS then
        -- 回调重试：订单已成功，但奖励可能因离线/崩溃没发出去，这里补发（agent 侧幂等）
        M.grant_order_reward(order)
        return { code = 0, message = "订单已处理" }
    end
    local is_payment_success = false
    if channel == PAYMENT_CHANNEL.ALIPAY then
        is_payment_success = (notify_data.trade_status == "TRADE_SUCCESS" or notify_data.trade_status == "TRADE_FINISHED")
    elseif channel == PAYMENT_CHANNEL.WECHAT then
        is_payment_success = (notify_data.result_code == "SUCCESS" and notify_data.return_code == "SUCCESS")
    else
        is_payment_success = true
    end
    local status = is_payment_success and PAYMENT_STATUS.SUCCESS or PAYMENT_STATUS.FAILED
    local update_data = {
        status = status, pay_time = is_payment_success and os.date("%Y-%m-%d %H:%M:%S") or nil, channel_order_id = notify_data.trade_no or notify_data.transaction_id,
        notify_data = skynet.packstring(notify_data), notify_time = os.date("%Y-%m-%d %H:%M:%S"),
    }
    local result = skynet.call(M.db, "lua", "update", "payment", { order_id = order_id }, update_data)
    if not result then return { code = 5, message = "更新订单状态失败" } end
    log_payment(order_id, status, is_payment_success and "支付成功" or "支付失败")
    if is_payment_success then
        -- 订单已落库；奖励发放失败不影响支付回调，登录时会补发
        M.grant_order_reward(order)
    end
    return { code = 0, message = "处理成功" }
end

function M.query_order(order_id)
    if not order_id then return { code = 1, message = "订单ID不能为空" } end
    local order = skynet.call(M.db, "lua", "find_one", "payment", { order_id = order_id })
    if not order then return { code = 2, message = "订单不存在" } end
    return { code = 0, data = order }
end

function M.query_player_orders(player_id, status, limit, offset)
    if not player_id then return { code = 1, message = "玩家ID不能为空" } end
    limit = limit or 10
    offset = offset or 0
    local query = { player_id = player_id }
    if status then query.status = status end
    local orders = skynet.call(M.db, "lua", "find", "payment", query, { limit = limit, offset = offset, sort = { create_time = -1 } })
    local total = skynet.call(M.db, "lua", "count", "payment", query)
    return { code = 0, data = { list = orders, total = total, limit = limit, offset = offset } }
end

function M.get_products() return { code = 0, data = M.products } end
function M.update_products(new_products)
    if type(new_products) ~= "table" then return { code = 1, message = "商品配置必须是表格" } end
    M.products = new_products
    return { code = 0, message = "商品配置更新成功" }
end

function M.manual_deliver(order_id, admin_id)
    if not order_id then return { code = 1, message = "订单ID不能为空" } end
    local order = skynet.call(M.db, "lua", "find_one", "payment", { order_id = order_id })
    if not order then return { code = 2, message = "订单不存在" } end
    if order.status ~= PAYMENT_STATUS.SUCCESS then
        order.status = PAYMENT_STATUS.SUCCESS
        order.pay_time = os.date("%Y-%m-%d %H:%M:%S")
        skynet.call(M.db, "lua", "update", "payment", { order_id = order_id }, { status = order.status, pay_time = order.pay_time })
        log_payment(order_id, PAYMENT_STATUS.SUCCESS, "管理员手动确认支付", admin_id or "admin")
    end
    return { code = 0, message = "商品发放成功" }
end

return M
