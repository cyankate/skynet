local skynet = require "skynet"
local service_ctx = require "runtime.service_ctx"

local M = service_ctx.get("logger.logger", {})
M.last_hour = M.last_hour or -1
M.log_file = M.log_file or nil
M.service_name_map = M.service_name_map or {}

local log_path = skynet.getenv("logpath")
local log_group = skynet.getenv("loggroup")
local is_daemon = skynet.getenv("daemon") ~= nil

local function check_exists(path)
    if not os.rename(path, path) then
        os.execute("mkdir " .. path)
    end
end

local function file_path(date)
    return string.format("%s%s_%04d-%02d-%02d-%02d.log", log_path, log_group, date.year, date.month, date.day, date.hour)
end

local function open_file(date)
    check_exists(log_path)
    if M.log_file then
        M.log_file:close()
        M.log_file = nil
    end
    local f, e = io.open(file_path(date), "a")
    if not f then
        print("logger error:", tostring(e))
        return
    end
    M.log_file = f
    M.last_hour = date.hour
end

local function log_time(date)
    return string.format("%04d-%02d-%02d %02d:%02d:%02d.%02d", date.year, date.month, date.day, date.hour, date.min, date.sec, math.floor(skynet.time() * 100 % 100))
end

function M.logging(source, type_name, color, str)
    local date = os.date("*t")
    local service_name = M.service_name_map[source]
    if not service_name then
        service_name = string.format(":%08x", source)
    end
    str = string.format("[%s][%s][%s]%s", log_time(date), type_name, service_name, str)
    if color ~= "" then
        str = color .. str .. "\27[0m"
    end
    if not M.log_file or date.hour ~= M.last_hour then
        open_file(date)
    end
    if not M.log_file then
        return
    end
    M.log_file:write(str .. "\n")
    M.log_file:flush()
    if not is_daemon then
        print(str)
    end
end

function M.register_name(source, name)
    M.service_name_map[source] = name
end

function M.init()
    if M._inited then
        return
    end
    M._inited = true
end

return M
