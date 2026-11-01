local user_mgr = require "user_mgr"
local protocol_handler = require "protocol_handler"
local trade_mgr = require "system.trade.trade_mgr"

local function reply(player_id, name, result, message, extra)
    local data = { result = result, message = message or "" }
    for k, v in pairs(extra or {}) do
        data[k] = v
    end
    protocol_handler.send_to_player(player_id, name, data)
end

local function on_trade_list(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        return false, "Player not found"
    end
    local ok, result = trade_mgr.list(player, msg.item_id, msg.count, msg.price, msg.currency_item_id)
    if ok then
        reply(player_id, "trade_list_response", 0, "ok", { order_id = result.order_id })
    else
        reply(player_id, "trade_list_response", 1, tostring(result))
    end
    return ok
end

local function on_trade_buy(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        return false, "Player not found"
    end
    local ok, result = trade_mgr.buy(player, msg.order_id)
    if ok then
        reply(player_id, "trade_buy_response", 0, "ok", { order_id = result.order_id })
    else
        reply(player_id, "trade_buy_response", 1, tostring(result))
    end
    return ok
end

local function on_trade_cancel(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        return false, "Player not found"
    end
    local ok, result = trade_mgr.cancel(player, msg.order_id)
    if ok then
        reply(player_id, "trade_cancel_response", 0, "ok", { order_id = result.order_id })
    else
        reply(player_id, "trade_cancel_response", 1, tostring(result))
    end
    return ok
end

local function on_trade_query(player_id, msg)
    local ok, result = trade_mgr.query(msg.page, msg.page_size)
    if ok then
        reply(player_id, "trade_query_response", 0, "ok", {
            page = result.page,
            total = result.total,
            orders = result.orders,
        })
    else
        reply(player_id, "trade_query_response", 1, tostring(result), { page = 0, total = 0, orders = {} })
    end
    return ok
end

return {
    trade_list = on_trade_list,
    trade_buy = on_trade_buy,
    trade_cancel = on_trade_cancel,
    trade_query = on_trade_query,
}
