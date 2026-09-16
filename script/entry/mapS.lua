local map_id = ...
map_id = tonumber(map_id)
if not map_id then
    error("mapS requires map_id")
end

package.loaded["map.worker_bind"] = { map_id = map_id }

local shard = require "map.shard"
local svc_name = shard.global_local_name(map_id)
local bootstrap = require "entry._bootstrap"
bootstrap("service.map_service", {
    name = svc_name,
    logging_name = svc_name,
})
