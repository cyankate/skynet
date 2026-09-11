local map_id = tonumber(...)
local shard_id = select(2, ...)
shard_id = tonumber(shard_id)
if not map_id then
    error("sceneS requires map_id")
end
if shard_id == nil then
    error("sceneS requires shard_id")
end

package.loaded["scene.worker_bind"] = { map_id = map_id, shard_id = shard_id }

local shard = require "map.shard"
local svc_name = shard.scene_local_name(map_id, shard_id)
local bootstrap = require "entry._bootstrap"
bootstrap("service.scene_service", {
    name = svc_name,
    logging_name = svc_name,
})
