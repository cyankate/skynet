local skynet = require "skynet"
require "skynet.manager"
local service_wrapper = require "utils.service_wrapper"
local global_service = require "global.global_service"

local function main()
    local ok, err = global_service.init()
    if not ok then
        error(err or "global_mgr init failed")
    end
end

service_wrapper.create_service(main, {
    name = "global",
})
