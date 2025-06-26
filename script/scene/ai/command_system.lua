local class = require "utils.class"
local log = require "log"

-- 命令类型定义
local CommandType = {
    MOVE = "move",           -- 移动命令
    DANCE = "dance",         -- 跳舞命令
    ATTACK = "attack",       -- 攻击命令
    SKILL = "skill",         -- 技能命令
    EMOTE = "emote",         -- 表情命令
    FOLLOW = "follow",       -- 跟随命令
    STOP = "stop",           -- 停止命令
}

-- 命令基类
local Command = class("Command")

function Command:ctor(type, data)
    self.type = type
    self.data = data or {}
    self.priority = 0
    self.create_time = os.time()
    self.timeout = 30  -- 默认30秒超时
end

function Command:is_expired()
    return (os.time() - self.create_time) > self.timeout
end

function Command:get_priority()
    return self.priority
end

-- 移动命令
local MoveCommand = class("MoveCommand", Command)

function MoveCommand:ctor(x, y, speed)
    Command.ctor(self, CommandType.MOVE, {x = x, y = y, speed = speed})
    self.priority = 10
end

-- 跳舞命令
local DanceCommand = class("DanceCommand", Command)

function DanceCommand:ctor(dance_type, duration)
    Command.ctor(self, CommandType.DANCE, {dance_type = dance_type, duration = duration})
    self.priority = 5
    self.timeout = duration or 10
end

-- 攻击命令
local AttackCommand = class("AttackCommand", Command)

function AttackCommand:ctor(target_id, skill_id)
    Command.ctor(self, CommandType.ATTACK, {target_id = target_id, skill_id = skill_id})
    self.priority = 15
end

-- 技能命令
local SkillCommand = class("SkillCommand", Command)

function SkillCommand:ctor(skill_id, target_x, target_y)
    Command.ctor(self, CommandType.SKILL, {skill_id = skill_id, target_x = target_x, target_y = target_y})
    self.priority = 12
end

-- 表情命令
local EmoteCommand = class("EmoteCommand", Command)

function EmoteCommand:ctor(emote_type, duration)
    Command.ctor(self, CommandType.EMOTE, {emote_type = emote_type, duration = duration})
    self.priority = 3
    self.timeout = duration or 5
end

-- 跟随命令
local FollowCommand = class("FollowCommand", Command)

function FollowCommand:ctor(target_id, distance)
    Command.ctor(self, CommandType.FOLLOW, {target_id = target_id, distance = distance})
    self.priority = 8
end

-- 停止命令
local StopCommand = class("StopCommand", Command)

function StopCommand:ctor()
    Command.ctor(self, CommandType.STOP, {})
    self.priority = 20  -- 最高优先级
end

-- 命令系统
local CommandSystem = class("CommandSystem")

function CommandSystem:ctor(entity)
    self.entity = entity
    self.commands = {}
    self.current_command = nil
    self.is_executing = false
    self.execution_start_time = 0
end

-- 添加命令
function CommandSystem:add_command(command)
    if not command or not command.type then
        log.error("CommandSystem: 无效命令")
        return false
    end
    
    -- 如果是停止命令，清除所有其他命令
    if command.type == CommandType.STOP then
        self.commands = {}
        self.current_command = command
        self.is_executing = true
        self.execution_start_time = os.time()
        log.debug("CommandSystem: 添加停止命令，清除所有其他命令")
        return true
    end
    
    -- 按优先级插入命令队列
    local inserted = false
    for i, existing_command in ipairs(self.commands) do
        if command:get_priority() > existing_command:get_priority() then
            table.insert(self.commands, i, command)
            inserted = true
            break
        end
    end
    
    if not inserted then
        table.insert(self.commands, command)
    end
    
    log.debug("CommandSystem: 添加命令 %s，优先级 %d，队列长度 %d", 
              command.type, command:get_priority(), #self.commands)
    return true
end

-- 清除所有命令
function CommandSystem:clear_commands()
    self.commands = {}
    self.current_command = nil
    self.is_executing = false
    log.debug("CommandSystem: 清除所有命令")
end

-- 检查是否有命令
function CommandSystem:has_commands()
    return #self.commands > 0 or self.current_command ~= nil
end

-- 检查是否有活动命令
function CommandSystem:has_active_command()
    return self.current_command ~= nil
end

-- 获取当前命令
function CommandSystem:get_current_command()
    return self.current_command
end

-- 处理命令
function CommandSystem:process_commands(dt)
    -- 检查当前命令是否完成或超时
    if self.current_command then
        if self:is_command_completed() or self.current_command:is_expired() then
            log.debug("CommandSystem: 命令 %s 完成或超时", self.current_command.type)
            self.current_command = nil
            self.is_executing = false
        else
            -- 继续执行当前命令
            self:execute_current_command(dt)
            return
        end
    end
    
    -- 获取下一个命令
    if #self.commands > 0 then
        self.current_command = table.remove(self.commands, 1)
        self.is_executing = true
        self.execution_start_time = os.time()
        log.debug("CommandSystem: 开始执行命令 %s", self.current_command.type)
        self:execute_current_command(dt)
    end
end

-- 检查命令是否完成
function CommandSystem:is_command_completed()
    if not self.current_command then
        return true
    end
    
    local command = self.current_command
    
    -- 根据命令类型检查完成状态
    if command.type == CommandType.MOVE then
        local target_x = command.data.x
        local target_y = command.data.y
        return self.entity:is_at_target({x = target_x, y = target_y})
        
    elseif command.type == CommandType.DANCE then
        local duration = command.data.duration or 10
        return (os.time() - self.execution_start_time) >= duration
        
    elseif command.type == CommandType.ATTACK then
        -- 攻击命令执行一次就完成
        return true
        
    elseif command.type == CommandType.SKILL then
        -- 技能命令执行一次就完成
        return true
        
    elseif command.type == CommandType.EMOTE then
        local duration = command.data.duration or 5
        return (os.time() - self.execution_start_time) >= duration
        
    elseif command.type == CommandType.FOLLOW then
        -- 跟随命令需要手动停止
        return false
        
    elseif command.type == CommandType.STOP then
        -- 停止命令立即完成
        return true
    end
    
    return true
end

-- 执行当前命令
function CommandSystem:execute_current_command(dt)
    if not self.current_command then
        return
    end
    
    local command = self.current_command
    
    if command.type == CommandType.MOVE then
        self:execute_move_command(command)
        
    elseif command.type == CommandType.DANCE then
        self:execute_dance_command(command)
        
    elseif command.type == CommandType.ATTACK then
        self:execute_attack_command(command)
        
    elseif command.type == CommandType.SKILL then
        self:execute_skill_command(command)
        
    elseif command.type == CommandType.EMOTE then
        self:execute_emote_command(command)
        
    elseif command.type == CommandType.FOLLOW then
        self:execute_follow_command(command)
        
    elseif command.type == CommandType.STOP then
        self:execute_stop_command(command)
    end
end

-- 执行移动命令
function CommandSystem:execute_move_command(command)
    local target_x = command.data.x
    local target_y = command.data.y
    local speed = command.data.speed
    
    if self.entity:can_move() then
        self.entity:move_to(target_x, target_y)
        log.debug("CommandSystem: 执行移动命令到 (%.1f, %.1f)", target_x, target_y)
    end
end

-- 执行跳舞命令
function CommandSystem:execute_dance_command(command)
    local dance_type = command.data.dance_type or "default"
    
    if self.entity.play_animation then
        self.entity:play_animation("dance_" .. dance_type)
        log.debug("CommandSystem: 执行跳舞命令 %s", dance_type)
    end
end

-- 执行攻击命令
function CommandSystem:execute_attack_command(command)
    local target_id = command.data.target_id
    local skill_id = command.data.skill_id
    
    -- 查找目标
    local target = self.entity:find_target_by_id(target_id)
    if target and self.entity:can_attack() then
        self.entity:perform_attack(target, skill_id)
        log.debug("CommandSystem: 执行攻击命令，目标 %d，技能 %s", target_id, skill_id or "默认")
    end
end

-- 执行技能命令
function CommandSystem:execute_skill_command(command)
    local skill_id = command.data.skill_id
    local target_x = command.data.target_x
    local target_y = command.data.target_y
    
    if self.entity.use_skill then
        self.entity:use_skill(skill_id, target_x, target_y)
        log.debug("CommandSystem: 执行技能命令 %s 在 (%.1f, %.1f)", skill_id, target_x, target_y)
    end
end

-- 执行表情命令
function CommandSystem:execute_emote_command(command)
    local emote_type = command.data.emote_type or "wave"
    
    if self.entity.play_emote then
        self.entity:play_emote(emote_type)
        log.debug("CommandSystem: 执行表情命令 %s", emote_type)
    end
end

-- 执行跟随命令
function CommandSystem:execute_follow_command(command)
    local target_id = command.data.target_id
    local distance = command.data.distance or 5
    
    local target = self.entity:find_target_by_id(target_id)
    if target and self.entity:can_move() then
        -- 计算跟随位置
        local dx = target.x - self.entity.x
        local dy = target.y - self.entity.y
        local current_distance = math.sqrt(dx*dx + dy*dy)
        
        if current_distance > distance then
            local follow_x = target.x - (dx / current_distance) * distance
            local follow_y = target.y - (dy / current_distance) * distance
            self.entity:move_to(follow_x, follow_y)
            log.debug("CommandSystem: 执行跟随命令，跟随目标 %d", target_id)
        end
    end
end

-- 执行停止命令
function CommandSystem:execute_stop_command(command)
    if self.entity.stop_all_actions then
        self.entity:stop_all_actions()
        log.debug("CommandSystem: 执行停止命令")
    end
end

-- 便捷方法
function CommandSystem:move_to(x, y, speed)
    local command = MoveCommand.new(x, y, speed)
    return self:add_command(command)
end

function CommandSystem:dance(dance_type, duration)
    local command = DanceCommand.new(dance_type, duration)
    return self:add_command(command)
end

function CommandSystem:attack(target_id, skill_id)
    local command = AttackCommand.new(target_id, skill_id)
    return self:add_command(command)
end

function CommandSystem:use_skill(skill_id, target_x, target_y)
    local command = SkillCommand.new(skill_id, target_x, target_y)
    return self:add_command(command)
end

function CommandSystem:emote(emote_type, duration)
    local command = EmoteCommand.new(emote_type, duration)
    return self:add_command(command)
end

function CommandSystem:follow(target_id, distance)
    local command = FollowCommand.new(target_id, distance)
    return self:add_command(command)
end

function CommandSystem:stop()
    local command = StopCommand.new()
    return self:add_command(command)
end

-- 导出
return {
    CommandSystem = CommandSystem,
    CommandType = CommandType,
    MoveCommand = MoveCommand,
    DanceCommand = DanceCommand,
    AttackCommand = AttackCommand,
    SkillCommand = SkillCommand,
    EmoteCommand = EmoteCommand,
    FollowCommand = FollowCommand,
    StopCommand = StopCommand,
} 