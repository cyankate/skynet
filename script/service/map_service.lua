-- 全图全局服务：每张图一个，单点。
-- 职责收窄为「注册表 + 派生状态计算」：
--   1. 争夺建筑归属注册表：分片战斗回写后上报（report_ownership）
--   2. 联盟 buff 聚合：归属变更时重算，回推各分片缓存（分片本地读，零跨服调用）
--   3. 全图统计 / 赛季进度（占位）
-- 权威数据永远在分片，本服状态全是派生品：崩溃后 rebuild 从分片重建。
-- 反模式红线：热路径（移动 / 视野 / 战斗结算）永远不路由进本服。
local skynet = require "skynet"
local log = require "log"
local shard = require "map.shard"
local service_ctx = require "runtime.service_ctx"

local ctx = service_ctx.get("map.map_global", {})
local CMD = {}

-- 争夺建筑归属注册表：uid => { alliance_id, owner_player_id, building_id, shard_id, occupy_tick }
ctx.building_owner = ctx.building_owner or {}
-- 联盟 buff 聚合结果：alliance_id => { buff_key => value }，变更时回推分片缓存
ctx.alliance_buffs = ctx.alliance_buffs or {}
-- 全图统计占位（击杀数、占点数等）
ctx.stats = ctx.stats or {}

-- 归属变更 → 重算联盟 buff → 回推所有分片
local function recompute_and_push()
    -- TODO: 争夺建筑玩法上线后，按 building_id 配置表聚合各联盟 buff
    -- 当前无配置，聚合结果为空表；上报 → 重算 → 回推管线先跑通
    local next_buffs = {}
    for _, info in pairs(ctx.building_owner) do
        local alliance_id = info.alliance_id or 0
        if alliance_id ~= 0 then
            next_buffs[alliance_id] = next_buffs[alliance_id] or {}
        end
    end
    ctx.alliance_buffs = next_buffs
    for _, sid in ipairs(shard.all_ids()) do
        local addr = shard.addr(ctx.map_id, sid)
        if addr then
            skynet.send(addr, "lua", "alliance_buff_sync", ctx.alliance_buffs)
        end
    end
end

-- 分片上报：争夺建筑归属变更（战斗回写后调用）
function CMD.report_ownership(uid, info)
    uid = tostring(uid or "")
    if uid == "" or type(info) ~= "table" then
        return false, "invalid report"
    end
    ctx.building_owner[uid] = {
        alliance_id = tonumber(info.alliance_id) or 0,
        owner_player_id = tonumber(info.owner_player_id) or 0,
        building_id = tonumber(info.building_id) or 0,
        shard_id = tonumber(info.shard_id) or 0,
        occupy_tick = tonumber(info.occupy_tick) or skynet.now(),
    }
    recompute_and_push()
    return true
end

function CMD.remove_ownership(uid)
    ctx.building_owner[tostring(uid)] = nil
    recompute_and_push()
    return true
end

function CMD.query_building_owner(uid)
    return true, ctx.building_owner[tostring(uid)]
end

function CMD.query_alliance_buffs(alliance_id)
    return true, ctx.alliance_buffs[tonumber(alliance_id) or 0] or {}
end

-- 崩溃/重启重建：向所有分片拉取争夺建筑清单，重建注册表
function CMD.rebuild()
    ctx.building_owner = {}
    local count = 0
    for _, sid in ipairs(shard.all_ids()) do
        local addr = shard.addr(ctx.map_id, sid)
        if addr then
            local ok, list = skynet.call(addr, "lua", "list_contention_buildings")
            if ok and type(list) == "table" then
                for _, info in ipairs(list) do
                    ctx.building_owner[tostring(info.uid)] = info
                    count = count + 1
                end
            else
                log.warning("map global rebuild: shard %s unavailable", tostring(sid))
            end
        end
    end
    recompute_and_push()
    log.info("map global rebuilt, map_id=%s contention_buildings=%d", tostring(ctx.map_id), count)
    return true
end

-- 拉起本图所有分片（幂等：已注册则跳过，崩溃重启安全）
local function launch_shards(map_id)
    for _, sid in ipairs(shard.all_ids()) do
        local name = shard.service_name(map_id, sid)
        if not skynet.localname(name) then
            skynet.newservice("shardS", map_id, sid)
        end
        local n = 0
        while not skynet.localname(name) and n < 50 do
            skynet.sleep(10)
            n = n + 1
        end
        if not skynet.localname(name) then
            log.error("map shard not ready, map_id=%s shard_id=%s", tostring(map_id), tostring(sid))
        end
    end
end

function CMD.init()
    if ctx._inited then
        return true
    end
    ctx._inited = true
    local bind = package.loaded["map.worker_bind"]
    local map_id = bind and tonumber(bind.map_id)
    if not map_id then
        return false, "map global missing map_id"
    end
    ctx.map_id = map_id
    -- 全局服拥有本地图生命周期：分片由它拉起
    launch_shards(map_id)
    -- 延迟重建：等分片 bootstrap 完成（注册名不等于 map 数据就绪，双保险）
    skynet.timeout(200, function()
        local ok, err = pcall(CMD.rebuild)
        if not ok then
            log.error("map global rebuild failed: %s", tostring(err))
        end
    end)
    log.info("Map global service initialized, map_id=%s", tostring(map_id))
    return true
end

return CMD
