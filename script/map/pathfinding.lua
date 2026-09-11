-- 大世界静态寻路：一张 map 一份格子图，路点用世界坐标。
-- 动态障碍只给城墙 / 关隘这类低频变化，行军不要写进来。
local class = require "utils.class"
local Simple2DNavMesh = require "scene.pathfinding.simple_2d_navmesh"

local WorldPath = class("WorldPath")

WorldPath.CELL_SIZE = 8
WorldPath.SNAP_CELLS = 24

function WorldPath:ctor(def)
    self.def = def
    self.map_id = def.map_id
    self.nav = Simple2DNavMesh.new(def.width, def.height, WorldPath.CELL_SIZE)
end

function WorldPath:clamp(x, y)
    local w = self.def.width or 2048
    local h = self.def.height or 2048
    x = tonumber(x) or 1
    y = tonumber(y) or 1
    if x < 1 then
        x = 1
    elseif x > w then
        x = w
    end
    if y < 1 then
        y = 1
    elseif y > h then
        y = h
    end
    return x, y
end

function WorldPath:is_walkable(x, y)
    x, y = self:clamp(x, y)
    return self.nav:is_walkable(x, y)
end

function WorldPath:snap_walkable(x, y)
    x, y = self:clamp(x, y)
    if self.nav:is_walkable(x, y) then
        return x, y
    end
    local gx, gy = self.nav:world_to_grid(x, y)
    local best, best_d2
    for r = 1, WorldPath.SNAP_CELLS do
        for dy = -r, r do
            for dx = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local nx, ny = gx + dx, gy + dy
                    local node = self.nav.grid[ny] and self.nav.grid[ny][nx]
                    if node and node.walkable then
                        local wx, wy = self.nav:grid_to_world(nx, ny)
                        local d2 = (wx - x) * (wx - x) + (wy - y) * (wy - y)
                        if not best_d2 or d2 < best_d2 then
                            best_d2 = d2
                            best = { x = wx, y = wy }
                        end
                    end
                end
            end
        end
        if best then
            return best.x, best.y
        end
    end
    return nil
end

function WorldPath:find_path(sx, sy, ex, ey, keep_end)
    sx, sy = self:clamp(sx, sy)
    ex, ey = self:clamp(ex, ey)
    local nsx, nsy = self:snap_walkable(sx, sy)
    local nex, ney = self:snap_walkable(ex, ey)
    if not nsx or not nex then
        return nil, "起点或终点不可通行"
    end
    local path, err = self.nav:find_path(nsx, nsy, nex, ney)
    if not path then
        return nil, err or "找不到路径"
    end
    path[1] = { x = sx, y = sy }
    path[#path] = { x = nex, y = ney }
    if nsx ~= sx or nsy ~= sy then
        table.insert(path, 2, { x = nsx, y = nsy })
    end
    -- 追击要咬到真实坐标；行军点山/水则停在最近可走点
    if keep_end and (ex ~= nex or ey ~= ney) then
        path[#path + 1] = { x = ex, y = ey }
    end
    return path
end

function WorldPath:add_obstacle(x, y, radius)
    x, y = self:clamp(x, y)
    return self.nav:add_obstacle(x, y, tonumber(radius) or 0)
end

function WorldPath:remove_obstacle(obstacle_id)
    return self.nav:remove_obstacle(obstacle_id)
end

function WorldPath:set_terrain(x, y, terrain_type)
    x, y = self:clamp(x, y)
    self.nav:set_terrain(x, y, terrain_type)
    self.nav:clear_path_cache()
end

function WorldPath:get_stats()
    return self.nav:get_stats()
end

return WorldPath
