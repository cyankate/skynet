local skynet = require "skynet"
require "skynet.manager"
local log = require "log"
local shard = require "map.shard"

-- 只负责拉起各 chunk 分片 mapS，不常驻转发。协议直连 .map.{map_id}.{shard_id}
skynet.start(function()
    local def = shard.world_def()
    for _, sid in ipairs(shard.all_ids()) do
        skynet.newservice("mapS", def.map_id, sid)
        local name = shard.service_name(def.map_id, sid)
        local n = 0
        while not skynet.localname(name) and n < 50 do
            skynet.sleep(10)
            n = n + 1
        end
        if not skynet.localname(name) then
            log.error("map shard not ready, map_id=%s shard_id=%s", tostring(def.map_id), tostring(sid))
        end
    end
    log.info("map shards launched, map_id=%s count=%d", tostring(def.map_id), shard.shard_count())
    skynet.exit()
end)
