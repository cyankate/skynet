local skynet = require "skynet"
local class = require "utils.class"
local log = require "log"

local Entity = class("Entity")

-- 实体类型
local ENTITY_TYPE = {
    PLAYER = 1,    -- 玩家
    MONSTER = 2,   -- 怪物
    NPC = 3,       -- NPC
    ITEM = 4,      -- 物品
}

function Entity:ctor(id, type)
    self.id = id
    self.type = type
    self.x = 0
    self.y = 0
    self.scene = nil
    self.view_range = 100  -- 默认视野范围
    self.properties = {}   -- 实体属性
end

-- 设置位置
function Entity:set_position(x, y)
    if not self.scene then
        self.x = x
        self.y = y
        return true
    end
    return self.scene:move_entity(self.id, x, y)
end

-- 获取位置
function Entity:get_position()
    return self.x, self.y
end

-- 设置属性
function Entity:set_property(key, value)
    self.properties[key] = value
end

-- 获取属性
function Entity:get_property(key)
    return self.properties[key]
end

-- 进入场景
function Entity:enter_scene(scene)
    if self.scene then
        self:leave_scene()
    end
    return scene:add_entity(self)
end

-- 离开场景
function Entity:leave_scene()
    if self.scene then
        return self.scene:remove_entity(self.id)
    end
    return false
end

-- 获取周围实体
function Entity:get_surrounding_entities()
    if not self.scene then
        return {}
    end
    return self.scene:get_surrounding_entities(self.id, self.view_range)
end

-- 当其他实体进入视野
function Entity:on_entity_enter(other)
    -- 子类重写此方法
end

-- 当其他实体离开视野
function Entity:on_entity_leave(other)
    -- 子类重写此方法
end

-- 更新实体
function Entity:update()
    -- 子类重写此方法
end

-- 销毁实体
function Entity:destroy()
    self:leave_scene()
end

-- 广播消息给周围实体
function Entity:broadcast_message(name, data)
    -- 获取周围实体
    local surrounding = self:get_surrounding_entities()
    
    -- 给所有周围的玩家发送消息
    for _, entity in pairs(surrounding) do
        if entity.type == ENTITY_TYPE.PLAYER then
            entity:send_message(name, data)
        end
    end
end

function Entity:send_message(name, data)
    self:broadcast_message(name, data)
end

Entity.ENTITY_TYPE = ENTITY_TYPE
return Entity