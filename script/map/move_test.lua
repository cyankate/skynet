-- 地图移动压测（服务端自驱动，开关与参数见下方常量）
--   1. 地图初始化后刷一批内存测试实体（只进 AOI 做视野负载，不交互、不落库）
--   2. 玩家进图后启动定时器，随机模拟镜头移动，持续 DURATION_SEC 秒
-- 移动模式：约 80% 小步（测同格跳过/跨格差集），约 20% 全图大跳（可能跨片）
-- 跨片接力：deadline 存 player_state 随 transfer 快照带到新片，新片接着驱动，总时长不重置
local skynet = require "skynet"
local log = require "log"
local aoi_object = require "map.aoi_object"
local service_ctx = require "runtime.service_ctx"
local observer = require "map.observer"

local ctx = service_ctx.get("map.shard_service", {})
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

-- 全图随机取点：小步以镜头当前位置为基准钳在地图边界内，大跳全图随机（可能落到别的片，触发跨片迁移）
local function next_pos(map, player_id)
    if math.random() < 0.2 then
        return math.random(1, map.def.width), math.random(1, map.def.height)
    end
    local obj = map:get_obj(player_id)
    local cx = (obj and obj.x) or 0
    local cy = (obj and obj.y) or 0
    local nx = cx + math.random(-STEP_RANGE, STEP_RANGE)
    local ny = cy + math.random(-STEP_RANGE, STEP_RANGE)
    return math.max(1, math.min(map.def.width, nx)), math.max(1, math.min(map.def.height, ny))
end

-- 玩家进图/跨片接收后启动：每 MOVE_INTERVAL 走一步，到 deadline 停；离图则提前结束
function M.start(player_id)
    if not M.enabled() then
        return
    end
    ctx.move_test = ctx.move_test or {}
    if ctx.move_test[player_id] then
        return
    end
    local st = ctx.player_state and ctx.player_state[player_id]
    if not st then
        return
    end
    if st.hotspot_virtual then
        -- 热点压测的虚拟观察者由 hotspot_test 自己驱动，move_test 不得劫持
        -- （否则会随机乱走，与 churn 账本互相打架）
        return
    end
    -- 跨片接力：快照带过来的 deadline 未到期则继续用；已过期/没有则开新窗口
    local now = skynet.now()
    local deadline = st.move_test_deadline
    if not deadline or deadline <= now then
        deadline = now + DURATION_SEC * 100
        st.move_test_deadline = deadline
    end
    local state = { moves = 0, failed = 0 }
    ctx.move_test[player_id] = state
    log.info("move_test start, player_id=%s remain=%.1fs interval=%d",
        tostring(player_id), (deadline - now) / 100, MOVE_INTERVAL)
    local function step()
        if skynet.now() >= deadline then
            ctx.move_test[player_id] = nil
            st.move_test_deadline = nil
            log.info("move_test done, player_id=%s moves=%d failed=%d",
                tostring(player_id), state.moves, state.failed)
            return
        end
        if not st.current_scene_id or st.current_scene_id <= 0 or not ctx.map then
            -- 离图或跨片迁走（本片状态已清），本片驱动结束；跨片由新片接力
            ctx.move_test[player_id] = nil
            log.info("move_test abort, player_id=%s left or transferred", tostring(player_id))
            return
        end
        local x, y = next_pos(ctx.map, player_id)
        local ok = observer.move(player_id, x, y)
        if ok then
            state.moves = state.moves + 1
        else
            state.failed = state.failed + 1
        end
        skynet.timeout(MOVE_INTERVAL, step)
    end
    skynet.timeout(MOVE_INTERVAL, step)
end

return M
