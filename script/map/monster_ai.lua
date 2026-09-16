-- 公共怪物巡逻 AI：以生成点为圆心、patrol_radius 为半径的小范围随机游走
-- 职责拆分：
--   patrol_radius 是配置，随实体持久化（播种时写入 data blob，重载后恢复巡逻行为）
--   home/目标点/停留等巡逻状态是纯运行时（本模块 ctx 表），不落库、不进实体
-- 移动同步复用行军同款路径：move_obj(AOI 网格/投影/可见性) + mark_dirty(x,y) + sync_obj_move_around(100ms 合并推)
local skynet = require "skynet"
local service_ctx = require "runtime.service_ctx"
local aoi_object = require "map.aoi_object"
local view_sync = require "map.view_sync"
local shard = require "map.shard"

local ctx = service_ctx.get("map.shard_service", {})

local M = {}

local STEP = 6          -- 每 tick 移动距离（500ms 一 tick，即 12 单位/秒，慢速游走）
local WAIT_MIN = 100    -- 到达目标点后停留 1s ~ 3s
local WAIT_MAX = 300

ctx.patrol_state = ctx.patrol_state or {} -- uid => { home_x, home_y, tx, ty, wait_until }

-- 战斗中的怪物不巡逻（battle_id 由行军到点开战写入）。
local function in_battle(map, uid)
    local mon = map.public_monsters and map.public_monsters[uid]
    local bid = mon and mon.battle_id
    return bid ~= nil and bid ~= ""
end

-- 在巡逻半径内随机取一个新目标点。
-- 钳制在本片像素矩形内：怪物永不跨片，避免归属/chunk_id/投影一致性问题。
local function pick_target(map, st, radius)
    local x0, y0, x1, y1 = shard.pixel_rect(map.shard_id, map.def)
    local ang = math.random() * math.pi * 2
    local r = math.random() * radius
    st.tx = math.max(x0, math.min(x1, math.floor(st.home_x + math.cos(ang) * r)))
    st.ty = math.max(y0, math.min(y1, math.floor(st.home_y + math.sin(ang) * r)))
end

local function step_toward(map, m, st)
    local dx = st.tx - m.x
    local dy = st.ty - m.y
    local dist = math.sqrt(dx * dx + dy * dy)
    local nx, ny
    if dist <= STEP then
        nx, ny = st.tx, st.ty
    else
        nx = math.floor(m.x + dx / dist * STEP)
        ny = math.floor(m.y + dy / dist * STEP)
    end
    if nx ~= m.x or ny ~= m.y then
        map:move_obj(m.uid, nx, ny)
        aoi_object.mark_dirty(m, "x")
        aoi_object.mark_dirty(m, "y")
        view_sync.sync_obj_move_around(map, m)
    end
    if nx == st.tx and ny == st.ty then
        st.tx, st.ty = nil, nil
        st.wait_until = skynet.now() + math.random(WAIT_MIN, WAIT_MAX)
    end
end

function M.tick(map)
    if not map then
        return
    end
    local now = skynet.now()
    for uid, m in pairs(map.public_monsters) do
        if not m.alive then
            ctx.patrol_state[uid] = nil
        else
            local radius = tonumber(m.patrol_radius) or 0
            if radius > 0 and m.in_aoi and not in_battle(map, uid) then
                local st = ctx.patrol_state[uid]
                if not st then
                    -- 首次 tick 惰性定圆心：当前位置即生成点（重载后 = 落库时的生成点）
                    st = { home_x = m.x, home_y = m.y }
                    ctx.patrol_state[uid] = st
                end
                if not (st.wait_until and now < st.wait_until) then
                    if not st.tx then
                        pick_target(map, st, radius)
                    end
                    step_toward(map, m, st)
                end
            end
        end
    end
end

return M
