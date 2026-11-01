local skynet = require "skynet"
local redis_service = require "service.redis_service"

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "ping" then
            skynet.ret(skynet.pack(true))
            return
        end
        skynet.ret(skynet.pack(redis_service.dispatch(cmd, ...)))
    end)
    skynet.register(".redis")
end)
