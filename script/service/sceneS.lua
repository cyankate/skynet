local service_wrapper = require "utils.service_wrapper"
local scene_service = require "scene.scene_service"

CMD = setmetatable({}, { __index = scene_service })

local function main()
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "scene",
})