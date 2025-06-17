local Entity = require "scene.entity"
local class = require "utils.class"
local log = require "log"

local StateEntity = class("StateEntity", Entity)

-- 定义实体状态
StateEntity.STATE = {
    IDLE = "IDLE",           -- 空闲
    MOVING = "MOVING",       -- 移动中
    ATTACKING = "ATTACKING", -- 攻击中
    CASTING = "CASTING",     -- 施法中
    STUNNED = "STUNNED",     -- 眩晕
    DEAD = "DEAD",          -- 死亡
}

-- 定义状态转换规则
local STATE_TRANSITIONS = {
    [StateEntity.STATE.IDLE] = {
        [StateEntity.STATE.MOVING] = true,
        [StateEntity.STATE.ATTACKING] = true,
        [StateEntity.STATE.CASTING] = true,
        [StateEntity.STATE.STUNNED] = true,
        [StateEntity.STATE.DEAD] = true,
    },
    [StateEntity.STATE.MOVING] = {
        [StateEntity.STATE.IDLE] = true,
        [StateEntity.STATE.ATTACKING] = true,
        [StateEntity.STATE.CASTING] = true,
        [StateEntity.STATE.STUNNED] = true,
        [StateEntity.STATE.DEAD] = true,
    },
    [StateEntity.STATE.ATTACKING] = {
        [StateEntity.STATE.IDLE] = true,
        [StateEntity.STATE.MOVING] = true,
        [StateEntity.STATE.STUNNED] = true,
        [StateEntity.STATE.DEAD] = true,
    },
    [StateEntity.STATE.CASTING] = {
        [StateEntity.STATE.IDLE] = true,
        [StateEntity.STATE.STUNNED] = true,
        [StateEntity.STATE.DEAD] = true,
    },
    [StateEntity.STATE.STUNNED] = {
        [StateEntity.STATE.IDLE] = true,
        [StateEntity.STATE.DEAD] = true,
    },
    [StateEntity.STATE.DEAD] = {
        [StateEntity.STATE.IDLE] = true, -- 只有复活可以从死亡状态转换到空闲
    }
}

function StateEntity:ctor(id, type)
    StateEntity.super.ctor(self, id, type)
    
    -- 状态相关属性
    self.current_state = StateEntity.STATE.IDLE
    self.state_time = 0          -- 当前状态持续时间
    self.state_data = {}         -- 状态相关数据
    
    -- 移动相关
    self.moving = false
    self.move_target_x = nil
    self.move_target_y = nil
    self.move_path = nil
    self.move_path_index = 1
    self.last_move_time = 0
    self.move_interval = 0.1
    self.move_speed = 5          -- 默认移动速度
    
    -- 战斗相关
    self.target_id = nil
    self.last_attack_time = 0
    self.attack_cd = 1.0
    
    -- 状态效果
    self.stun_duration = 0
    self.cast_duration = 0
end

-- 状态机更新
function StateEntity:update()
    local now = skynet.now() / 100
    self.state_time = self.state_time + 0.1  -- 假设每次更新间隔0.1秒
    
    -- 根据当前状态执行对应的更新逻辑
    if self.current_state == StateEntity.STATE.MOVING then
        self:update_move()
    elseif self.current_state == StateEntity.STATE.ATTACKING then
        self:update_attack()
    elseif self.current_state == StateEntity.STATE.CASTING then
        self:update_cast()
    elseif self.current_state == StateEntity.STATE.STUNNED then
        self:update_stun()
    end
end

-- 切换状态
function StateEntity:change_state(new_state, state_data)
    -- 检查状态转换是否合法
    if not self:can_change_state(new_state) then
        return false, "不能切换到该状态"
    end
    
    -- 退出当前状态
    self:exit_state(self.current_state)
    
    -- 记录新状态
    local old_state = self.current_state
    self.current_state = new_state
    self.state_time = 0
    self.state_data = state_data or {}
    
    -- 进入新状态
    self:enter_state(new_state)
    
    -- 广播状态变化
    self:broadcast_state_change(old_state, new_state)
    
    return true
end

-- 检查是否可以切换到目标状态
function StateEntity:can_change_state(new_state)
    -- 检查状态转换规则
    return STATE_TRANSITIONS[self.current_state] and 
           STATE_TRANSITIONS[self.current_state][new_state]
end

-- 进入新状态时的处理
function StateEntity:enter_state(state)
    if state == StateEntity.STATE.MOVING then
        self.moving = true
    elseif state == StateEntity.STATE.ATTACKING then
        -- 重置攻击计时
        self.last_attack_time = skynet.now() / 100
    elseif state == StateEntity.STATE.CASTING then
        -- 设置施法持续时间
        self.cast_duration = self.state_data.duration or 1.0
    elseif state == StateEntity.STATE.STUNNED then
        -- 设置眩晕持续时间
        self.stun_duration = self.state_data.duration or 1.0
    end
end

-- 退出当前状态时的处理
function StateEntity:exit_state(state)
    if state == StateEntity.STATE.MOVING then
        self.moving = false
        self.move_target_x = nil
        self.move_target_y = nil
        self.move_path = nil
        self.move_path_index = 1
    elseif state == StateEntity.STATE.ATTACKING then
        self.target_id = nil
    elseif state == StateEntity.STATE.CASTING then
        -- 取消施法效果
        if self.state_data.on_cancel then
            self.state_data.on_cancel()
        end
    end
end

-- 广播状态变化
function StateEntity:broadcast_state_change(old_state, new_state)
    self:broadcast_message("entity_state_change", {
        entity_id = self.id,
        old_state = old_state,
        new_state = new_state,
        state_data = self.state_data
    })
end

-- 统一的路径移动实现
function StateEntity:move_along_path(path)
    if not path or #path == 0 then
        return false
    end
    
    -- 设置移动路径
    self.move_path = path  -- 路径已经在Scene:find_path中被平滑
    self.move_path_index = 1
    
    -- 切换到移动状态
    self:change_state(StateEntity.STATE.MOVING)
    
    -- 调用移动开始钩子
    self:on_move_start()
    
    return true
end

-- 移动开始钩子
function StateEntity:on_move_start()
    -- 基类空实现,由子类重写
end

-- 移动结束钩子
function StateEntity:on_move_end()
    -- 基类空实现,由子类重写
end

-- 移动更新钩子
function StateEntity:on_move_update()
    -- 基类空实现,由子类重写
end

-- 更新移动
function StateEntity:update_move()
    if not self.moving or not self.move_path then
        self:change_state(StateEntity.STATE.IDLE)
        return
    end
    
    local now = skynet.now() / 100
    
    -- 检查移动间隔
    if now - self.last_move_time < self.move_interval then
        return
    end
    
    -- 获取当前路径点
    local current_point = self.move_path[self.move_path_index]
    if not current_point then
        self:change_state(StateEntity.STATE.IDLE)
        return
    end
    
    -- 移动到路径点
    local success = self.scene:move_entity(self.id, current_point.x, current_point.y)
    if not success then
        self:change_state(StateEntity.STATE.IDLE)
        return
    end
    
    -- 更新移动时间
    self.last_move_time = now
    
    -- 调用移动更新钩子
    self:on_move_update()
    
    -- 检查是否到达路径点
    if self.x == current_point.x and self.y == current_point.y then
        self.move_path_index = self.move_path_index + 1
        
        -- 检查是否到达终点
        if self.move_path_index > #self.move_path then
            self:change_state(StateEntity.STATE.IDLE)
            -- 调用移动结束钩子
            self:on_move_end()
        end
    end
end

-- 更新攻击
function StateEntity:update_attack()
    local now = skynet.now() / 100
    
    -- 检查目标是否有效
    local target = self.scene:get_entity(self.target_id)
    if not target then
        self:change_state(StateEntity.STATE.IDLE)
        return
    end
    
    -- 检查攻击CD
    if now - self.last_attack_time >= self.attack_cd then
        -- 执行攻击
        self:perform_attack(target)
        self.last_attack_time = now
    end
end

-- 更新施法
function StateEntity:update_cast()
    -- 检查施法是否完成
    if self.state_time >= self.cast_duration then
        -- 执行施法效果
        if self.state_data.on_complete then
            self.state_data.on_complete()
        end
        self:change_state(StateEntity.STATE.IDLE)
    end
end

-- 更新眩晕
function StateEntity:update_stun()
    -- 检查眩晕是否结束
    if self.state_time >= self.stun_duration then
        self:change_state(StateEntity.STATE.IDLE)
    end
end

-- 处理移动请求
function StateEntity:handle_move(x, y)
    -- 检查当前状态是否可以移动
    if not self:can_change_state(StateEntity.STATE.MOVING) then
        return false, "当前状态不能移动"
    end
    
    -- 获取路径
    if self.scene then
        local path = self.scene:find_path(self.x, self.y, x, y)
        if not path then
            return false, "无法到达目标位置"
        end
        
        -- 设置移动数据
        local move_data = {
            target_x = x,
            target_y = y,
            path = path,
            start_x = self.x,
            start_y = self.y
        }
        
        -- 切换到移动状态
        return self:change_state(StateEntity.STATE.MOVING, move_data)
    else
        self:set_position(x, y)
        return true
    end
end

-- 处理攻击请求
function StateEntity:handle_attack(target_id)
    -- 检查当前状态是否可以攻击
    if not self:can_change_state(StateEntity.STATE.ATTACKING) then
        return false, "当前状态不能攻击"
    end
    
    -- 检查目标是否存在
    local target = self.scene:get_entity(target_id)
    if not target then
        return false, "目标不存在"
    end
    
    -- 切换到攻击状态
    return self:change_state(StateEntity.STATE.ATTACKING, {target_id = target_id})
end

-- 处理施法请求
function StateEntity:handle_cast(skill_id, target_id)
    -- 检查当前状态是否可以施法
    if not self:can_change_state(StateEntity.STATE.CASTING) then
        return false, "当前状态不能施法"
    end
    
    -- 获取技能配置
    local skill_config = self:get_skill_config(skill_id)
    if not skill_config then
        return false, "技能不存在"
    end
    
    -- 切换到施法状态
    return self:change_state(StateEntity.STATE.CASTING, {
        skill_id = skill_id,
        target_id = target_id,
        duration = skill_config.cast_time,
        on_complete = function()
            self:perform_skill(skill_id, target_id)
        end
    })
end

-- 处理眩晕
function StateEntity:handle_stun(duration)
    -- 强制切换到眩晕状态
    return self:change_state(StateEntity.STATE.STUNNED, {duration = duration})
end

-- 处理死亡
function StateEntity:handle_death(killer)
    -- 强制切换到死亡状态
    self:change_state(StateEntity.STATE.DEAD, {killer_id = killer and killer.id})
end

return StateEntity