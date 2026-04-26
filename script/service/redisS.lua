local skynet = require "skynet"
local redis_service = require "redis.redis_service"

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        skynet.ret(skynet.pack(redis_service.dispatch(cmd, ...)))
    end)
    skynet.register(".redis")
end) 