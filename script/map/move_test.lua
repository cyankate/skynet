-- 地图移动压测（服务端自驱动，开关与参数见下方常量）
--   1. 地图初始化后刷一批内存测试实体（只进 AOI 做视野负载，不交互、不落库）
--   2. 玩家进图后启动定时器，随机模拟镜头移动，持续 DURATION_SEC 秒
-- 移动模式：约 80% 小步（测同格跳过/跨格差集），约 20% 片内大跳（测大批量差集）
local skynet = require "skynet"
local log = require "log"
local shard = require "map.shard"
local aoi_object = require "map.aoi_object"
local service_ctx = require "runtime.service_ctx"
local observer = require "map.observer"

local ctx = service_ctx.get("map.map_service", {})
local M = {}

-- 开关与参数（改这里，改完重启生效）
local ENABLED = true          -- false 关闭测试
local MONSTER_COUNT = 1000    -- 每片测试怪物数
local ITEM_COUNT = 500        -- 每片测试资源数
local DURATION_SEC = 15       -- 随机镜头持续秒数
local MOVE_INTERVAL = 20      -- 移动间隔（0.01s 单位，20 = 200ms）
local STEP_RANGE = 150        -- 小步移动幅度（地图单位）

function M.enabled()
    return ENABLED
end

-- 刷测试实体：每片刷自己辖区，alive=true 即可被视野收集
function M.seed(map)
    if not M.enabled() then
        return
    end
    math.randomseed(skynet.now() * 31 + (map.shard_id or 0))
    local monster_count = MONSTER_COUNT
    local item_count = ITEM_COUNT
    local seq = 0
    local function add(otype, extra)
        seq = seq + 1
        local x, y = map:rand_spawn()
        local obj = {
            uid = string.format("stress_%d_%d", map.shard_id, seq),
            type = otype,
            x = x,
            y = y,
            alive = true,
            owner_player_id = 0,
        }
        for k, v in pairs(extra) do
            obj[k] = v
        end
        map:attach(obj, otype)
    end
    for _ = 1, monster_count do
        add(aoi_object.TYPE.MONSTER, { kind = "stress" })
    end
    for i = 1, item_count do
        add(aoi_object.TYPE.RESOURCE, { item_id = 10001 + (i % 3), count = 1 })
    end
    log.info("move_test seed done, shard_id=%s monsters=%d items=%d",
        tostring(map.shard_id), monster_count, item_count)
end

-- 片内随机取点（限制在本片，避免跨片迁移后本片的定时器失去玩家状态）
local function next_pos(map, st)
    local x0, y0, x1, y1 = shard.pixel_rect(map.shard_id, map.def)
    if math.random() < 0.2 then
        return math.random(x0, x1), math.random(y0, y1)
    end
    local nx = (st.x or 0) + math.random(-STEP_RANGE, STEP_RANGE)
    local ny = (st.y or 0) + math.random(-STEP_RANGE, STEP_RANGE)
    return math.max(x0, math.min(x1, nx)), math.max(y0, math.min(y1, ny))
end

-- 玩家进图后启动：每 interval 走一步，duration 秒后停；离图/跨片则提前结束
function M.start(player_id)
    if not M.enabled() then
        return
    end
    ctx.move_test = ctx.move_test or {}
    if ctx.move_test[player_id] then
        return
    end
    local duration = DURATION_SEC
    local interval = MOVE_INTERVAL
    local deadline = skynet.now() + duration * 100
    local state = { moves = 0, failed = 0 }
    ctx.move_test[player_id] = state
    log.info("move_test start, player_id=%s duration=%ds interval=%d",
        tostring(player_id), duration, interval)
    local function step()
        if skynet.now() >= deadline then
            ctx.move_test[player_id] = nil
            log.info("move_test done, player_id=%s moves=%d failed=%d",
                tostring(player_id), state.moves, state.failed)
            return
        end
        local st = ctx.player_state[player_id]
        if not st or not st.current_scene_id or st.current_scene_id <= 0 or not ctx.map then
            ctx.move_test[player_id] = nil
            log.info("move_test abort, player_id=%s left map", tostring(player_id))
            return
        end
        local x, y = next_pos(ctx.map, st)
        local ok = observer.move(player_id, x, y)
        if ok then
            state.moves = state.moves + 1
        else
            state.failed = state.failed + 1
        end
        skynet.timeout(interval, step)
    end
    skynet.timeout(interval, step)
end

return M
