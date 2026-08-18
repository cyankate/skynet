local skynet = require "skynet"

local log = {}

log.DIR = {
    DEFAULT = { dir = "", prefix = "" },
    INSTANCE = { dir = "instance", prefix = "instance" },
}

local LOG_LEVEL = {
    DEBUG   = 1,
    INFO    = 2, 
    WARN    = 3, 
    ERROR   = 4, 
    FATAL   = 5,
    SYSTEM  = 6
}

local OUT_PUT_LEVEL = LOG_LEVEL.DEBUG

local LOG_LEVEL_DESC = {
    [1] = "DEBUG",
    [2] = "INFO",
    [3] = "WARN",
    [4] = "ERROR",
    [5] = "FATAL",
    [6] = "SYSTEM",
}

-- ANSI 颜色码，不同级别使用常见颜色
local LOG_LEVEL_COLOR = {
    [LOG_LEVEL.DEBUG] = "\27[92m",
    [LOG_LEVEL.INFO]  = "",
    [LOG_LEVEL.WARN]  = "\27[93m", -- 黄色
    [LOG_LEVEL.ERROR] = "\27[91m", -- 红色
    [LOG_LEVEL.FATAL] = "\27[95m", -- 品红/紫色
    [LOG_LEVEL.SYSTEM] = "\27[94m", -- 蓝色
}

local function is_dir_cfg(v)
    return type(v) == "table" and type(v.dir) == "string" and type(v.prefix) == "string"
end

local function format(fmt, ...)
    local ok, str = pcall(string.format, fmt, ...)
    if ok then
        return str
    else
        return "error format : " .. fmt
    end
end

local function send_log(level, ...)
    if level < OUT_PUT_LEVEL then
        return
    end

    local argc = select("#", ...)
    local offset = 0
    local dir_cfg = log.DIR.DEFAULT
    if argc >= 1 and is_dir_cfg(select(1, ...)) then
        dir_cfg = select(1, ...)
        offset = 1
    end

    local str
    if argc - offset <= 1 then
        str = tostring(select(offset + 1, ...))
    else
        str = format(select(offset + 1, ...), select(offset + 2, ...))
    end

    local info = debug.getinfo(3)
    if info then
        local filename = string.match(info.short_src, "[^/.]+.lua$")
        str = string.format("[%s:%d] %s", filename, info.currentline, str)
    end

    local color = LOG_LEVEL_COLOR[level] or ""
    skynet.send(".logger", "lua", "logging", LOG_LEVEL_DESC[level], color, str, dir_cfg.dir, dir_cfg.prefix)
end

function log.debug(fmt, ...)
    send_log(LOG_LEVEL.DEBUG, fmt, ...)
end

function log.info(fmt, ...)
    send_log(LOG_LEVEL.INFO, fmt, ...)
end

function log.warning(fmt, ...)
    send_log(LOG_LEVEL.WARN, fmt, ...)
end

function log.error(fmt, ...)
    send_log(LOG_LEVEL.ERROR, fmt, ...)
end

function log.fatal(fmt, ...)
    send_log(LOG_LEVEL.FATAL, fmt, ...)
end

function log.system(fmt, ...)
    send_log(LOG_LEVEL.SYSTEM, fmt, ...)
end

return log
