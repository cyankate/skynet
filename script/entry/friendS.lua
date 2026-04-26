local service_wrapper = require "utils.service_wrapper"
local S = require "service.friend_service"

CMD = setmetatable({}, { __index = S })

local function main()
    if S.init then
        S.init()
    end
end

service_wrapper.create_service(main, {
    name = "friend",
    custom_stats = function()
        return S.custom_stats()
    end,
})
