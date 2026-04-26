local service_wrapper = require "utils.service_wrapper"
local chat_service = require "chat.chat_service"

CMD = setmetatable({}, { __index = chat_service })

-- 主服务函数
local function main()
    -- 初始化聊天服务
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "chat",
})
