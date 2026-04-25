local skynet = require "skynet"
local sprotoloader = require "sprotoloader"
local log = require "log"
local proto_builder = require "utils.proto_builder"
require "skynet.manager"

local CMD = {}

local function load_proto()
    package.loaded["protocol.proto"] = nil
    local proto = require "protocol.proto"

    sprotoloader.save(proto.c2s, 1)
    sprotoloader.save(proto.s2c, 2)

    -- 先清空旧 schema，避免协议删除后遗留脏项
    proto_builder.clear_schemas()
    local ok, count = proto_builder.save_schemas_to_datacenter()
    if ok then
        log.info("protoloader schema synced: %d", count)
    else
        log.warning("protoloader schema sync skipped: datacenter unavailable")
    end
    return true
end

function CMD.reload()
    local ok, err = pcall(load_proto)
    if not ok then
        log.error("protoloader reload failed: %s", tostring(err))
        return false, tostring(err)
    end

    local gate = skynet.localname(".gate")
    if gate then
        local gok, gret, gerr = pcall(skynet.call, gate, "lua", "reload_proto")
        if not gok or not gret then
            local msg = tostring(gerr or gret or "unknown gate reload error")
            log.error("protoloader reload gate proto failed: %s", msg)
            return false, msg
        end
    end

    return true
end

skynet.start(function()
    local ok, err = CMD.reload()
    if not ok then
        error(err or "protoloader init failed")
    end

    skynet.dispatch("lua", function(_, _, cmd, ...)
        local f = CMD[cmd]
        if not f then
            skynet.ret(skynet.pack(false, "unknown command: " .. tostring(cmd)))
            return
        end
        skynet.ret(skynet.pack(f(...)))
    end)
end)