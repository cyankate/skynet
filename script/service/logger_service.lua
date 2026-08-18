local skynet = require "skynet"
local service_ctx = require "runtime.service_ctx"

local M = service_ctx.get("logger.logger", {})
M.file_map = M.file_map or {}
M.service_name_map = M.service_name_map or {}

local log_path = skynet.getenv("logpath")
local log_group = skynet.getenv("loggroup")
local is_daemon = skynet.getenv("daemon") ~= nil

local function check_exists(path)
    if not os.rename(path, path) then
        os.execute("mkdir " .. path)
    end
end

local function normalize_dir(dir, prefix)
    dir = dir or ""
    prefix = prefix or ""
    if prefix == "" then
        prefix = log_group or "debug"
    end
    return dir, prefix
end

local function slot_key(dir, prefix)
    return dir .. "\0" .. prefix
end

local function file_path(dir, prefix, date)
    local stamp = string.format("%04d-%02d-%02d-%02d", date.year, date.month, date.day, date.hour)
    if dir == "" then
        return string.format("%s%s_%s.log", log_path, prefix, stamp)
    end
    return string.format("%s%s/%s_%s.log", log_path, dir, prefix, stamp)
end

local function open_file(dir, prefix, date)
    dir, prefix = normalize_dir(dir, prefix)
    check_exists(log_path)
    if dir ~= "" then
        check_exists(log_path .. dir)
    end

    local key = slot_key(dir, prefix)
    local slot = M.file_map[key]
    if slot and slot.file then
        slot.file:close()
        slot.file = nil
    end

    local f, e = io.open(file_path(dir, prefix, date), "a")
    if not f then
        print("logger error:", tostring(e))
        return nil
    end
    M.file_map[key] = {
        file = f,
        last_hour = date.hour,
    }
    return f
end

local function get_file(dir, prefix, date)
    dir, prefix = normalize_dir(dir, prefix)
    local slot = M.file_map[slot_key(dir, prefix)]
    if slot and slot.file and slot.last_hour == date.hour then
        return slot.file
    end
    return open_file(dir, prefix, date)
end

local function is_default_dir(dir, prefix)
    dir, prefix = normalize_dir(dir, prefix)
    return dir == "" and prefix == (log_group or "debug")
end

local function write_file(f, str)
    if not f then
        return
    end
    f:write(str .. "\n")
    f:flush()
end

local function log_time(date)
    return string.format("%04d-%02d-%02d %02d:%02d:%02d.%02d", date.year, date.month, date.day, date.hour, date.min, date.sec, math.floor(skynet.time() * 100 % 100))
end

function M.logging(source, type_name, color, str, dir, prefix)
    local date = os.date("*t")
    local service_name = M.service_name_map[source]
    if not service_name then
        service_name = string.format(":%08x", source)
    end
    str = string.format("[%s][%s][%s]%s", log_time(date), type_name, service_name, str)
    if color and color ~= "" then
        str = color .. str .. "\27[0m"
    end
    write_file(get_file(dir, prefix, date), str)
    if not is_default_dir(dir, prefix) then
        write_file(get_file("", "", date), str)
    end
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
