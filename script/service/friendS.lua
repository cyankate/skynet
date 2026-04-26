local skynet = require "skynet"
local service_wrapper = require "utils.service_wrapper"
local friend_service = require "friend.friend_service"

CMD = setmetatable({}, { __index = friend_service })

-- 主服务函数
local function main()
    -- 初始化好友服务
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "friend",
    custom_stats = function()
        return friend_service.custom_stats()
    end
})
