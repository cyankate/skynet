-- 交易行：上架 / 购买 / 取消 / 查询（固定价、整堆、邮件交付）
local skynet = require "skynet"
local log = require "log"
local item_mgr = require "system.item_mgr"
local trade_util = require "system.trade.trade_util"
local item_def = require "define.item_def"
local db_call = require "system.db_call"

local M = {}

local LISTED = 1
local PURCHASED = 2
local ORDER_TTL = 24 * 3600
local DEFAULT_CURRENCY = item_def.ITEM_ID.DIAMOND

local function db()
    return skynet.localname(".db")
end

local function order_info(order)
    return {
        order_id = order.order_id,
        seller_id = order.seller_id,
        item_id = order.item_id,
        count = order.item_count,
        price = order.price,
        currency_item_id = order.currency_item_id,
        expire_time = order.expire_time,
    }
end

local function get_order(d, order_id)
    local rows = db_call.call("select", "trade_order", { order_id = order_id }, { limit = 1 })
    return rows and rows[1]
end

-- 上架：扣卖家背包 + 订单 + 托管，同一个事务
function M.list(player, item_id, count, price, currency_item_id)
    item_id = tonumber(item_id)
    count = tonumber(count)
    price = tonumber(price)
    currency_item_id = tonumber(currency_item_id)
    if not currency_item_id or currency_item_id <= 0 then
        currency_item_id = DEFAULT_CURRENCY
    end
    if not item_id or not count or count <= 0 or not price or price <= 0 then
        return false, "参数无效"
    end
    local ok, err = item_mgr.has_enough_items(player, { [item_id] = count })
    if not ok then
        return false, err
    end
    local now = os.time()
    local order_id = trade_util.new_id("o")
    local op_id = "trade:" .. order_id .. ":list"
    local extra = {
        { op = "insert", tbl = "trade_order", data = {
            order_id = order_id,
            seller_id = player.player_id_,
            buyer_id = 0,
            item_id = item_id,
            item_count = count,
            price = price,
            currency_item_id = currency_item_id,
            status = LISTED,
            create_time = now,
            update_time = now,
            expire_time = now + ORDER_TTL,
            version = 1,
        }},
        { op = "insert", tbl = "trade_escrow", data = {
            order_id = order_id,
            seller_id = player.player_id_,
            item_id = item_id,
            item_count = count,
            status = 0,
            create_time = now,
            update_time = now,
        }},
    }
    local commit_ok, res, commit_err = player:cost_items_critical(
        op_id, { [item_id] = count }, extra, { order_id = order_id }, "trade_list")
    if not commit_ok then
        return false, commit_err or res
    end
    return true, { order_id = order_id }
end

-- 购买：扣买家货币 + 条件更新订单 LISTED→PURCHASED，同一个事务
function M.buy(player, order_id)
    order_id = tostring(order_id or "")
    if order_id == "" then
        return false, "参数无效"
    end
    local d = db()
    if not d then
        return false, "db unavailable"
    end
    local order = get_order(d, order_id)
    if not order then
        return false, "订单不存在"
    end
    if order.status ~= LISTED then
        return false, "订单不可购买"
    end
    if order.expire_time and order.expire_time <= os.time() then
        return false, "订单已过期"
    end
    if order.seller_id == player.player_id_ then
        return false, "不能购买自己的订单"
    end
    local now = os.time()
    local op_id = string.format("trade:%s:pay:%s", order_id, tostring(player.player_id_))
    local extra = {
        { op = "update_where", tbl = "trade_order",
          data = { status = PURCHASED, buyer_id = player.player_id_, update_time = now },
          cond = { order_id = order_id, status = LISTED },
          require_affected = 1 },
    }
    local ok, res, err = player:cost_items_critical(
        op_id, { [order.currency_item_id] = order.price }, extra, { order_id = order_id }, "trade_buy")
    if not ok then
        return false, err or res
    end
    return true, { order_id = order_id }
end

-- 取消：订单仍在售时，物品通过邮件退回卖家
function M.cancel(player, order_id)
    order_id = tostring(order_id or "")
    if order_id == "" then
        return false, "参数无效"
    end
    local d = db()
    if not d then
        return false, "db unavailable"
    end
    local order = get_order(d, order_id)
    if not order then
        return false, "订单不存在"
    end
    if order.seller_id ~= player.player_id_ then
        return false, "只能取消自己的订单"
    end
    if order.status ~= LISTED then
        return false, "订单不可取消"
    end
    local now = os.time()
    local op_id = "trade:" .. order_id .. ":cancel"
    local ops = {
        trade_util.mail_op(order.seller_id, "交易行退回", "订单已取消，物品已退回",
            { { item_id = order.item_id, count = order.item_count } }, now),
        { op = "update_where", tbl = "trade_order",
          data = { status = 4, update_time = now },
          cond = { order_id = order_id, status = LISTED },
          require_affected = 1 },
        { op = "update_where", tbl = "trade_escrow",
          data = { status = 1, update_time = now },
          cond = { order_id = order_id, status = 0 },
          require_affected = 0 },
    }
    local ok, res, err = db_call.call("commit_op", op_id, ops, { order_id = order_id })
    if not ok then
        return false, err or res
    end
    local mailS = skynet.localname(".mail")
    if mailS then
        skynet.send(mailS, "lua", "on_new_mail", order.seller_id)
    end
    return true, { order_id = order_id }
end

-- 查询在售订单
function M.query(page, page_size)
    page = math.max(1, tonumber(page) or 1)
    page_size = math.min(50, math.max(1, tonumber(page_size) or 20))
    local d = db()
    if not d then
        return false, "db unavailable"
    end
    local cond = { status = LISTED }
    local orders = db_call.call("select", "trade_order", cond, {
        limit = page_size,
        offset = (page - 1) * page_size,
        order_by = { create_time = "DESC" },
    })
    local total = db_call.call("count", "trade_order", cond)
    local list = {}
    for _, order in ipairs(orders or {}) do
        list[#list + 1] = order_info(order)
    end
    return true, { orders = list, page = page, total = tonumber(total) or #list }
end

return M
