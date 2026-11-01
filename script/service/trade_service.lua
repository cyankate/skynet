-- 交易行结算 worker：已购买订单发货/收款/结算，过期在售订单退回
local skynet = require "skynet"
local log = require "log"
local service_ctx = require "runtime.service_ctx"
local trade_util = require "system.trade.trade_util"
local db_call = require "system.db_call"

local M = service_ctx.get("trade.trade_service", {})

local LISTED = 1
local PURCHASED = 2
local SETTLED = 3
local CANCELLED = 4
local TICK = 500
local BATCH = 20

local function db()
    return skynet.localname(".db")
end

local function op_exists(op_id)
    local exists = db_call.call("op_get", op_id)
    return exists == true
end

local function commit(op_id, ops, result)
    local ok, res = db_call.call("commit_op", op_id, ops, result)
    return ok, res
end

local function notify_mail(player_id)
    local mailS = skynet.localname(".mail")
    if mailS then
        skynet.send(mailS, "lua", "on_new_mail", player_id)
    end
end

local function deliver(order)
    local op_id = "trade:" .. order.order_id .. ":deliver"
    if op_exists(op_id) then
        return true
    end
    local ok = commit(op_id, {
        trade_util.mail_op(order.buyer_id, "交易行发货", "您购买的物品已到账",
            { { item_id = order.item_id, count = order.item_count } }),
    }, { order_id = order.order_id })
    if ok then
        notify_mail(order.buyer_id)
    end
    return ok
end

local function credit(order)
    local op_id = "trade:" .. order.order_id .. ":credit"
    if op_exists(op_id) then
        return true
    end
    local ok = commit(op_id, {
        trade_util.mail_op(order.seller_id, "交易行收入", "您的商品已售出，收入已到账",
            { { item_id = order.currency_item_id, count = order.price } }),
    }, { order_id = order.order_id })
    if ok then
        notify_mail(order.seller_id)
    end
    return ok
end

local function settle(order, now)
    local op_id = "trade:" .. order.order_id .. ":settle"
    if op_exists(op_id) then
        return true
    end
    return commit(op_id, {
        { op = "update_where", tbl = "trade_order",
          data = { status = SETTLED, update_time = now },
          cond = { order_id = order.order_id, status = PURCHASED },
          require_affected = 1 },
        { op = "update_where", tbl = "trade_escrow",
          data = { status = 2, update_time = now },
          cond = { order_id = order.order_id, status = 0 },
          require_affected = 0 },
    }, { order_id = order.order_id })
end

local function expire(order, now)
    local op_id = "trade:" .. order.order_id .. ":expire"
    if op_exists(op_id) then
        return true
    end
    local ok = commit(op_id, {
        trade_util.mail_op(order.seller_id, "交易行退回", "订单已过期，物品已退回",
            { { item_id = order.item_id, count = order.item_count } }, now),
        { op = "update_where", tbl = "trade_order",
          data = { status = CANCELLED, update_time = now },
          cond = { order_id = order.order_id, status = LISTED },
          require_affected = 1 },
        { op = "update_where", tbl = "trade_escrow",
          data = { status = 1, update_time = now },
          cond = { order_id = order.order_id, status = 0 },
          require_affected = 0 },
    }, { order_id = order.order_id })
    if ok then
        notify_mail(order.seller_id)
    end
    return ok
end

local function tick()
    local d = db()
    if not d then
        return
    end
    local now = os.time()
    local purchased = db_call.call("select", "trade_order",
        { status = PURCHASED }, { limit = BATCH, order_by = { update_time = "ASC" } })
    for _, order in ipairs(purchased or {}) do
        local ok = deliver(order)
        if ok then
            ok = credit(order)
        end
        if ok then
            ok = settle(order, now)
        end
        if not ok then
            log.error("trade settle failed, order=%s", tostring(order.order_id))
        end
    end

    local listed = db_call.call("select", "trade_order",
        { status = LISTED }, { limit = 50 })
    for _, order in ipairs(listed or {}) do
        if (order.expire_time or 0) <= now then
            local ok = expire(order, now)
            if not ok then
                log.error("trade expire failed, order=%s", tostring(order.order_id))
            end
        end
    end
end

function M.init()
    if M._inited then
        return true
    end
    M._inited = true
    local function loop()
        skynet.timeout(TICK, loop)
        if M.running then
            return
        end
        M.running = true
        skynet.fork(function()
            local ok, err = pcall(tick)
            M.running = false
            if not ok then
                log.error("trade tick failed: %s", tostring(err))
            end
        end)
    end
    skynet.timeout(TICK, loop)
    log.info("trade service started")
    return true
end

function M.tick()
    return tick()
end

return M
