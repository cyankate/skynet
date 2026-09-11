local M = {}

-- 固定边长，全图统一。中途改大小会让已落库的 chunk_id 全部错位。
local DEFAULT_SIZE = 64
local AXIS_MASK = 65536

function M.default_size()
    return DEFAULT_SIZE
end

function M.from_pos(x, y, chunk_size)
    chunk_size = chunk_size or DEFAULT_SIZE
    if chunk_size <= 0 then
        chunk_size = DEFAULT_SIZE
    end
    local cx = math.floor((tonumber(x) or 0) / chunk_size)
    local cy = math.floor((tonumber(y) or 0) / chunk_size)
    if cx < 0 then
        cx = 0
    end
    if cy < 0 then
        cy = 0
    end
    return cy * AXIS_MASK + cx, cx, cy
end

function M.encode(cx, cy)
    return (tonumber(cy) or 0) * AXIS_MASK + (tonumber(cx) or 0)
end

function M.decode(chunk_id)
    local id = tonumber(chunk_id) or 0
    local cx = id % AXIS_MASK
    local cy = math.floor(id / AXIS_MASK)
    return cx, cy
end

return M
