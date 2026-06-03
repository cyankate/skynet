--[[
    时间工具：
    - get_day_key / get_week_key：自然日、自然周（0 点切）
    - get_reset_day_key / get_reset_week_key：游戏日/游戏周（按 RESET_HOUR 切）
    - RESET_HOUR：日/周重置时刻（小时 0-23），改此处即可
    - 全局定时器：整分、整点、游戏日重置（start_global_timers）
]]

local skynet = require "skynet"
local log = require "log"

local timeutils = {}

timeutils.RESET_HOUR = 6
local EPOCH = os.time({ year = 2020, month = 1, day = 1, hour = 0, min = 0, sec = 0 })
local SEC_PER_DAY = 86400
local SEC_PER_WEEK = 7 * SEC_PER_DAY
local RESET_OFFSET = timeutils.RESET_HOUR * 3600

local minute_callbacks = {}
local hour_callbacks = {}
local day_reset_callbacks = {}
local timers_started = false

local function fire_callbacks(list, name, ...)
    for _, cb in ipairs(list) do
        local ok, err = pcall(cb, ...)
        if not ok then
            log.error("timeutils %s callback error: %s", name, tostring(err))
        end
    end
end

local function to_cs(sec)
    if sec <= 0 then
        return 1
    end
    return math.ceil(sec * 100)
end

--- 距下一次本地 RESET_HOUR 的秒数
function timeutils.get_seconds_to_next_reset(ts)
    ts = ts or os.time()
    local d = os.date("*t", ts)
    local today_reset = os.time({
        year = d.year,
        month = d.month,
        day = d.day,
        hour = timeutils.RESET_HOUR,
        min = 0,
        sec = 0,
    })
    if ts < today_reset then
        return today_reset - ts
    end
    local tomorrow_reset = os.time({
        year = d.year,
        month = d.month,
        day = d.day + 1,
        hour = timeutils.RESET_HOUR,
        min = 0,
        sec = 0,
    })
    return tomorrow_reset - ts
end

function timeutils.get_epoch()
    return EPOCH
end

--- 自然日 key（0 点跨天）
function timeutils.get_day_key(ts)
    ts = ts or os.time()
    return math.floor((ts - EPOCH) / SEC_PER_DAY)
end

--- 游戏日 key（按 RESET_HOUR 跨天）
function timeutils.get_reset_day_key(ts)
    ts = ts or os.time()
    return math.floor((ts - EPOCH - RESET_OFFSET) / SEC_PER_DAY)
end

function timeutils.get_week_key(ts)
    ts = ts or os.time()
    return math.floor((ts - EPOCH) / SEC_PER_WEEK)
end

--- 游戏周 key（与 get_reset_day_key 同一锚点，每 7 个游戏日为一周）
function timeutils.get_reset_week_key(ts)
    ts = ts or os.time()
    return math.floor((ts - EPOCH - RESET_OFFSET) / SEC_PER_WEEK)
end

function timeutils.on_minute(callback)
    table.insert(minute_callbacks, callback)
end

function timeutils.on_hour(callback)
    table.insert(hour_callbacks, callback)
end

--- 游戏日重置（每日 RESET_HOUR 触发）；callback(reset_day_key, ts)
function timeutils.on_day_reset(callback)
    table.insert(day_reset_callbacks, callback)
end

local function start_minute_timer()
    local function loop()
        local now = os.time()
        fire_callbacks(minute_callbacks, "minute", now)
        skynet.timeout(60 * 100, loop)
    end
    local d = os.date("*t")
    skynet.timeout(to_cs(60 - d.sec), loop)
end

local function start_hour_timer()
    local function loop()
        local now = os.time()
        fire_callbacks(hour_callbacks, "hour", now)
        skynet.timeout(3600 * 100, loop)
    end
    local d = os.date("*t")
    skynet.timeout(to_cs(3600 - d.min * 60 - d.sec), loop)
end

local function start_day_reset_timer()
    local function loop()
        local now = os.time()
        local reset_day_key = timeutils.get_reset_day_key(now)
        fire_callbacks(day_reset_callbacks, "day_reset", reset_day_key, now)
        skynet.timeout(to_cs(timeutils.get_seconds_to_next_reset(now)), loop)
    end
    skynet.timeout(to_cs(timeutils.get_seconds_to_next_reset()), loop)
end

--- 启动全局分钟 / 小时 / 游戏日重置定时器，重复调用无效
function timeutils.start_global_timers()
    if timers_started then
        return false
    end
    timers_started = true
    start_minute_timer()
    start_hour_timer()
    start_day_reset_timer()
    log.info("timeutils global timers started (day reset at %02d:00)", timeutils.RESET_HOUR)
    return true
end

return timeutils
