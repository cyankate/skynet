local skynet = require "skynet"
local chunk = require "map.chunk"

-- 一张连续大世界、一个 map_id；按 chunk 切成矩形分片，每片一个 map 服。
-- 坐标不局部化：每个 scene 仍用全图宽高。权威实体在所属分片，贴边邻居以 ghost 进 AOI。
local M = {}

M.WORLD_MAP_ID = 1001
M.SHARD_COLS = 2
M.SHARD_ROWS = 2
-- 贴边只读投影半径，需 >= 玩家视野，邻居实体进出才能进本片 AOI
M.HALO_RANGE = 120

function M.world_def()
    return {
        map_id = M.WORLD_MAP_ID,
        name = "苍穹大陆",
        width = 2048,
        height = 2048,
        grid_size = 50,
        chunk_size = chunk.default_size(),
        region_count = 16,
        start = { x = 120, y = 120 },
        shard_cols = M.SHARD_COLS,
        shard_rows = M.SHARD_ROWS,
    }
end

function M.shard_count()
    return M.SHARD_COLS * M.SHARD_ROWS
end

function M.all_ids()
    local t = {}
    for i = 0, M.shard_count() - 1 do
        t[#t + 1] = i
    end
    return t
end

function M.chunk_axis(def)
    local size = def.chunk_size or chunk.default_size()
    local cx_max = math.max(1, math.ceil(def.width / size))
    local cy_max = math.max(1, math.ceil(def.height / size))
    return cx_max, cy_max, size
end

function M.shard_chunk_rect(shard_id, def)
    local cols = def.shard_cols or M.SHARD_COLS
    local rows = def.shard_rows or M.SHARD_ROWS
    local cx_max, cy_max = M.chunk_axis(def)
    local sc = shard_id % cols
    local sr = math.floor(shard_id / cols)
    local x_div = math.max(1, math.floor(cx_max / cols))
    local y_div = math.max(1, math.floor(cy_max / rows))
    local cx0 = sc * x_div
    local cy0 = sr * y_div
    local cx1 = (sc == cols - 1) and (cx_max - 1) or (cx0 + x_div - 1)
    local cy1 = (sr == rows - 1) and (cy_max - 1) or (cy0 + y_div - 1)
    return cx0, cx1, cy0, cy1
end

function M.pixel_rect(shard_id, def)
    local cx0, cx1, cy0, cy1 = M.shard_chunk_rect(shard_id, def)
    local size = def.chunk_size or chunk.default_size()
    local x0 = math.max(1, cx0 * size)
    local y0 = math.max(1, cy0 * size)
    local x1 = math.min(def.width, (cx1 + 1) * size - 1)
    local y1 = math.min(def.height, (cy1 + 1) * size - 1)
    if x1 < x0 then
        x1 = x0
    end
    if y1 < y0 then
        y1 = y0
    end
    return x0, y0, x1, y1
end

function M.shard_id_of_chunk(cx, cy, def)
    local cols = def.shard_cols or M.SHARD_COLS
    local rows = def.shard_rows or M.SHARD_ROWS
    local cx_max, cy_max = M.chunk_axis(def)
    local x_div = math.max(1, math.floor(cx_max / cols))
    local y_div = math.max(1, math.floor(cy_max / rows))
    local sc = math.min(cols - 1, math.floor(cx / x_div))
    local sr = math.min(rows - 1, math.floor(cy / y_div))
    if sc < 0 then
        sc = 0
    end
    if sr < 0 then
        sr = 0
    end
    return sr * cols + sc
end

function M.shard_id_of_pos(x, y, def)
    local _, cx, cy = chunk.from_pos(x, y, def.chunk_size)
    return M.shard_id_of_chunk(cx, cy, def)
end

function M.owns_pos(shard_id, x, y, def)
    return M.shard_id_of_pos(x, y, def) == shard_id
end

function M.owned_chunk_ids(shard_id, def)
    local cx0, cx1, cy0, cy1 = M.shard_chunk_rect(shard_id, def)
    local ids = {}
    for cy = cy0, cy1 do
        for cx = cx0, cx1 do
            ids[#ids + 1] = chunk.encode(cx, cy)
        end
    end
    return ids
end

function M.neighbors(shard_id, def)
    local cols = def.shard_cols or M.SHARD_COLS
    local rows = def.shard_rows or M.SHARD_ROWS
    local sc = shard_id % cols
    local sr = math.floor(shard_id / cols)
    local t = {}
    for dy = -1, 1 do
        for dx = -1, 1 do
            if not (dx == 0 and dy == 0) then
                local nc, nr = sc + dx, sr + dy
                if nc >= 0 and nc < cols and nr >= 0 and nr < rows then
                    t[#t + 1] = nr * cols + nc
                end
            end
        end
    end
    return t
end

function M.dist_to_rect(x, y, shard_id, def)
    local x0, y0, x1, y1 = M.pixel_rect(shard_id, def)
    local dx = 0
    if x < x0 then
        dx = x0 - x
    elseif x > x1 then
        dx = x - x1
    end
    local dy = 0
    if y < y0 then
        dy = y0 - y
    elseif y > y1 then
        dy = y - y1
    end
    return math.sqrt(dx * dx + dy * dy)
end

-- 这个坐标若落在邻居矩形的 halo 内，就把实体投影到那些邻居
function M.halo_neighbors(shard_id, x, y, halo, def)
    halo = tonumber(halo) or M.HALO_RANGE
    local t = {}
    for _, nid in ipairs(M.neighbors(shard_id, def)) do
        if M.dist_to_rect(x, y, nid, def) <= halo then
            t[#t + 1] = nid
        end
    end
    return t
end

function M.service_name(map_id, shard_id)
    return ".map." .. tostring(map_id) .. "." .. tostring(shard_id)
end

function M.local_name(map_id, shard_id)
    return M.service_name(map_id, shard_id):sub(2)
end

function M.scene_name(map_id, shard_id)
    return ".scene.map." .. tostring(map_id) .. "." .. tostring(shard_id)
end

function M.scene_local_name(map_id, shard_id)
    return M.scene_name(map_id, shard_id):sub(2)
end

function M.addr(map_id, shard_id)
    return skynet.localname(M.service_name(map_id, shard_id))
end

function M.scene_addr(map_id, shard_id)
    return skynet.localname(M.scene_name(map_id, shard_id))
end

return M
