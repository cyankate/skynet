local service_wrapper = require "utils.service_wrapper"
local pathfinding_service = require "scene.pathfinding_service"

CMD = setmetatable({}, { __index = pathfinding_service })

local function main()
    pathfinding_service.init()
end

service_wrapper.create_service(main, {
    name = "pathfinding",
})
