-- 可靠投递 worker：扫 op_outbox 的 pending 记录，按目标投递；超限进死信（status=2）
local skynet = require "skynet"
local log = require "log"
local service_ctx = require "runtime.service_ctx"
local db_call = require "system.db_call"
local locator = require "cluster.locator"
local rpc = require "cluster.rpc"
local tableUtils = require "utils.tableUtils"

local M = service_ctx.get("outbox.outbox_service", {})

local TICK = 500
local BATCH = 20
local MAX_RETRIES = 10
local OFFLINE_STATUS = 3 -- 玩家离线：休眠，登录时 flush

local function resolve(row)
    if row.target_type == "agent" then
        return locator.get_agent(tonumber(row.target_id))
    elseif row.target_type == "service" then
        return rpc.named_addr(row.target_id)
    end
    return nil
end

local function delay_for(retries)
    return math.min(300, 5 * 2 ^ math.max(0, retries - 1))
end

-- 玩家离线：休眠，不参与扫描；登录时 flush_player 唤醒
local function set_dormant(row, now)
    db_call.call("update_where", "op_outbox", { outbox_id = row.outbox_id }, {
        status = OFFLINE_STATUS,
        next_retry_at = 0,
        last_error = "target offline",
        update_time = now,
    })
end

local function mark_done(row, now)
    db_call.call("update_where", "op_outbox", { outbox_id = row.outbox_id }, {
        status = 1,
        last_error = "",
        update_time = now,
    })
end

local function mark_retry(row, now, err)
    local retries = (row.retries or 0) + 1
    local status = retries >= MAX_RETRIES and 2 or 0
    if status == 2 then
        log.error("outbox dead letter, id=%s err=%s", tostring(row.outbox_id), tostring(err))
    end
    db_call.call("update_where", "op_outbox", { outbox_id = row.outbox_id }, {
        status = status,
        retries = retries,
        next_retry_at = now + delay_for(retries),
        last_error = tostring(err or ""):sub(1, 255),
        update_time = now,
    })
end

local function deliver(row, now)
    local addr = resolve(row)
    if not addr then
        if row.target_type == "agent" then
            set_dormant(row, now)
        else
            mark_retry(row, now, "target offline")
        end
        return
    end
    local payload = row.payload
    if type(payload) == "string" and payload ~= "" then
        payload = tableUtils.deserialize_table(payload)
    end
    local completed, result, err = rpc.call_timeout(addr, 500, row.method, payload)
    if completed and result then
        mark_done(row, now)
    else
        mark_retry(row, now, err or "deliver failed")
    end
end

local function tick()
    local now = os.time()
    local rows = db_call.call("select", "op_outbox", { status = 0 }, {
        limit = BATCH,
        order_by = { next_retry_at = "ASC" },
    })
    for _, row in ipairs(rows or {}) do
        if (row.next_retry_at or 0) <= now then
            deliver(row, now)
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
                log.error("outbox tick failed: %s", tostring(err))
            end
        end)
    end
    skynet.timeout(TICK, loop)
    log.info("outbox service started")
    return true
end

function M.tick()
    return tick()
end

function M.replay(outbox_id)
    local now = os.time()
    return db_call.call("update_where", "op_outbox", { outbox_id = outbox_id }, {
        status = 0,
        retries = 0,
        next_retry_at = now,
        last_error = "",
        update_time = now,
    })
end

-- 玩家登录后唤醒其休眠的投递记录
function M.flush_player(player_id)
    local now = os.time()
    return db_call.call("update_where", "op_outbox", {
        target_type = "agent",
        target_id = tostring(player_id),
        status = OFFLINE_STATUS,
    }, {
        status = 0,
        next_retry_at = now,
        update_time = now,
    })
end

function M.list_dead(limit)
    return db_call.call("select", "op_outbox", { status = 2 }, {
        limit = tonumber(limit) or 50,
    }) or {}
end

return M
