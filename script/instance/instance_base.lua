local skynet = require "skynet"
local log = require "log"
local class = require "utils.class"
local inst_def = require "script.define.inst_def"

-- 副本基类
local InstanceBase = class("InstanceBase")

function InstanceBase:ctor(inst_id, inst_no, args)
    self.inst_id_ = inst_id
    self.inst_no_ = inst_no
    self.args_ = args_ or {}
    self.status_ = InstanceStatus.CREATING
    self.create_time_ = os.time()
    self.start_time_ = nil
    self.end_time_ = nil
    self.duration_ = 0
    self.penters_ = {}
    self.pjoins_ = {}
    -- 副本数据
    self.data_ = {}
    -- 事件回调
    self.event_handlers_ = {}
    -- 定时器
    self.timers_ = {}
    
    log.info("InstanceBase: 创建副本 %s", inst_id)
end

-- 初始化副本
function InstanceBase:init()
    log.info("InstanceBase: 初始化副本 %s", self.inst_id_)
    self:on_init()
    self.status_ = InstanceStatus.WAITING
end

function InstanceBase:join(player_id, data_)
    log.info("InstanceBase: 玩家 %s 加入副本 %s", player_id, self.inst_id_)
    if self.pjoins_[player_id] then
        log.warn("InstanceBase: 玩家 %s 已加入副本 %s", player_id, self.inst_id_)
        return
    end
    
    -- 检查副本状态，只有等待中的副本才允许加入
    if self.status_ ~= InstanceStatus.WAITING then
        log.warn("InstanceBase: 副本 %s 状态不允许加入，当前状态: %d", self.inst_id_, self.status_)
        return
    end
    
    self.pjoins_[player_id] = data_
    self:on_join(player_id, data_)
    intance_mgr.on_player_join(self.inst_id_, player_id, data_)
end

function InstanceBase:on_join(player_id, data_)
    -- 子类重写
end

function InstanceBase:leave(player_id)
    log.info("InstanceBase: 玩家 %s 离开副本 %s", player_id, self.inst_id_)
    if not self.pjoins_[player_id] then
        log.warn("InstanceBase: 玩家 %s 未加入副本 %s", player_id, self.inst_id_)
        return
    end
    self:exit(player_id)
    self.pjoins_[player_id] = nil
    self:on_leave(player_id)
    intance_mgr.on_player_leave(self.inst_id_, player_id)
end

function InstanceBase:on_leave(player_id)
    -- 子类重写
end

function InstanceBase:enter(player_id)
    if self.penters_[player_id] then
        log.warn("InstanceBase: 玩家 %s 已进入副本 %s", player_id, self.inst_id_)
        return
    end
    self.penters_[player_id] = true
    self:on_enter(player_id)
end 

function InstanceBase:on_enter(player_id)
    -- 子类重写
end

function InstanceBase:exit(player_id)
    log.info("InstanceBase: 玩家 %s 退出副本 %s", player_id, self.inst_id_)
    if not self.penters_[player_id] then
        log.warn("InstanceBase: 玩家 %s 未进入副本 %s", player_id, self.inst_id_)
        return
    end
    self.penters_[player_id] = nil
    self:on_exit(player_id)
end

function InstanceBase:on_exit(player_id)
    -- 子类重写
end

function InstanceBase:close()
    self:kick_all()
    self:destroy()
end 

function InstanceBase:kick_all()
    for player_id, _ in pairs(self.penters_) do
        if not self.pjoins_[player_id] then
            self:exit(player_id)
        end
    end
    for player_id, _ in pairs(self.pjoins_) do
        self:leave(player_id)
    end
    self.penters_ = {}
    self.pjoins_ = {}
end     

-- 启动副本
function InstanceBase:start()
    if self.status_ ~= InstanceStatus.WAITING then
        log.warn("InstanceBase: 副本 %s 状态错误，无法启动", self.inst_id_)
        return false
    end
    
    log.info("InstanceBase: 启动副本 %s", self.inst_id_)
    self.status_ = InstanceStatus.RUNNING
    self.start_time_ = os.time()
    
    self:on_start()
    return true
end

-- 暂停副本
function InstanceBase:pause()
    if self.status_ ~= InstanceStatus.RUNNING then
        return false
    end
    
    log.info("InstanceBase: 暂停副本 %s", self.inst_id_)
    self.status_ = InstanceStatus.PAUSED
    self:on_pause()
    return true
end

-- 恢复副本
function InstanceBase:resume()
    if self.status_ ~= InstanceStatus.PAUSED then
        return false
    end
    
    log.info("InstanceBase: 恢复副本 %s", self.inst_id_)
    self.status_ = InstanceStatus.RUNNING
    self:on_resume()
    return true
end

-- 副本结束
function InstanceBase:complete(success, data_)
    if self.status_ ~= InstanceStatus.RUNNING and self.status_ ~= InstanceStatus.PAUSED then
        return false
    end
    
    self.status_ = InstanceStatus.COMPLETED
    self.end_time_ = os.time()
    self.duration_ = self.end_time_ - (self.start_time_ or self.create_time_)
    
    self:on_complete(success, data_)
    return true
end

-- 销毁副本
function InstanceBase:destroy()
    log.info("InstanceBase: 销毁副本 %s", self.inst_id_)
    self.status_ = InstanceStatus.DESTROYING
    
    -- 清理定时器
    self:clear_timers()
    
    -- 清理事件处理器
    self.event_handlers_ = {}
    
    self:on_destroy()
end

-- 检查玩家是否在副本中
function InstanceBase:has_player(player_id)
    return self.pjoins_[player_id] ~= nil
end

-- 设置数据
function InstanceBase:set_data(key, value)
    self.data_[key] = value
end

-- 获取数据
function InstanceBase:get_data(key, default_value)
    return self.data_[key] or default_value
end

-- 注册事件处理器
function InstanceBase:register_event(event_type, handler)
    if not self.event_handlers_[event_type] then
        self.event_handlers_[event_type] = {}
    end
    table.insert(self.event_handlers_[event_type], handler)
end

-- 触发事件
function InstanceBase:trigger_event(event_type, ...)
    local handlers = self.event_handlers_[event_type]
    if handlers then
        for _, handler in ipairs(handlers) do
            local ok, err = pcall(handler, ...)
            if not ok then
                log.error("InstanceBase: 事件处理器执行失败 %s", err)
            end
        end
    end
end

-- 添加定时器
function InstanceBase:add_timer(name, interval, callback, repeat_count)
    if self.timers_[name] then
        self:remove_timer(name)
    end
    
    self.timers_[name] = {
        interval = interval,
        callback = callback,
        repeat_count = repeat_count or -1, -- -1表示无限重复
        elapsed = 0,
        current_repeat = 0
    }
end

-- 移除定时器
function InstanceBase:remove_timer(name)
    self.timers_[name] = nil
end

-- 清理所有定时器
function InstanceBase:clear_timers()
    self.timers_ = {}
end

-- 更新定时器
function InstanceBase:update_timers(dt)
    for name, timer in pairs(self.timers_) do
        timer.elapsed = timer.elapsed + dt
        
        if timer.elapsed >= timer.interval then
            timer.elapsed = 0
            timer.current_repeat = timer.current_repeat + 1
            
            local ok, err = pcall(timer.callback, self, timer.current_repeat)
            if not ok then
                log.error("InstanceBase: 定时器 %s 执行失败 %s", name, err)
            end
            
            -- 检查是否需要移除定时器
            if timer.repeat_count > 0 and timer.current_repeat >= timer.repeat_count then
                self:remove_timer(name)
            end
        end
    end
end

-- 更新副本
function InstanceBase:update(dt)
    if self.status_ == InstanceStatus.RUNNING then
        self:update_timers(dt)
        self:on_update(dt)
    end
end

-- 获取副本状态
function InstanceBase:get_status()
    return self.status_
end

-- 检查副本是否运行中
function InstanceBase:is_running()
    return self.status_ == InstanceStatus.RUNNING
end

-- 检查副本是否已完成
function InstanceBase:is_completed()
    return self.status_ == InstanceStatus.COMPLETED
end

-- 检查副本是否已销毁
function InstanceBase:is_destroyed()
    return self.status_ == InstanceStatus.DESTROYING
end

-- 虚函数 - 子类需要重写的方法

-- 初始化回调
function InstanceBase:on_init()
    -- 子类重写
end

-- 启动回调
function InstanceBase:on_start()
    -- 子类重写
end

-- 暂停回调
function InstanceBase:on_pause()
    -- 子类重写
end

-- 恢复回调
function InstanceBase:on_resume()
    -- 子类重写
end

-- 结束回调
function InstanceBase:on_complete(success, data_)
    -- 子类重写
end

-- 销毁回调
function InstanceBase:on_destroy()
    -- 子类重写
end

-- 更新回调
function InstanceBase:on_update(dt)
    -- 子类重写
end

return InstanceBase
