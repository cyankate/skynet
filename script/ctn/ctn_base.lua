local skynet = require "skynet"
local class = require "utils.class"
local log = require "log"

local ctn_base = class("ctn_base")

-- 容器状态
local CONTAINER_STATE = {
    UNLOADED = 0,  -- 未加载
    LOADING = 1,   -- 加载中
    LOADED = 2,    -- 已加载
    ERROR = 3,     -- 错误状态
}

function ctn_base:ctor(_owner, _name)
    self.owner_ = _owner -- 容器所属的玩家id
    self.name_ = _name or "noname" -- 容器名称
    self.data_ = {}     -- 容器内的数据
    self.state_ = CONTAINER_STATE.UNLOADED -- 容器状态
    self.loaded_ = false -- 是否已加载
    self.error_ = nil   -- 错误信息
    self.last_save_time_ = 0 -- 上次保存时间
    self.auto_save_interval_ = 300 -- 自动保存间隔（秒）
    self.dirty_ = false -- 数据是否被修改

end

-- 获取容器名称
function ctn_base:get_name()
    return self.name_
end

-- 获取容器所有者
function ctn_base:get_owner()
    return self.owner_
end

-- 获取容器状态
function ctn_base:get_state()
    return self.state_
end

-- 设置容器状态
function ctn_base:set_state(state)
    self.state_ = state
end

-- 检查是否已加载
function ctn_base:is_loaded()
    return self.loaded_
end

-- 检查是否有错误
function ctn_base:has_error()
    return self.error_ ~= nil
end

-- 获取错误信息
function ctn_base:get_error()
    return self.error_
end

-- 设置错误信息
function ctn_base:set_error(err)
    self.error_ = err
    self.state_ = CONTAINER_STATE.ERROR
end

-- 清除错误
function ctn_base:clear_error()
    self.error_ = nil
    self.state_ = CONTAINER_STATE.UNLOADED
end

-- 设置自动保存间隔
function ctn_base:set_auto_save_interval(interval)
    self.auto_save_interval_ = interval
end

-- 检查是否需要自动保存
function ctn_base:need_auto_save()
    if not self.dirty_ then
        return false
    end
    local now = skynet.time()
    return now - self.last_save_time_ >= self.auto_save_interval_
end

-- 标记数据被修改
function ctn_base:set_dirty()
    self.dirty_ = true
end

-- 清除修改标记
function ctn_base:clear_dirty()
    self.dirty_ = false
end

-- 检查数据是否被修改
function ctn_base:is_dirty()
    return self.dirty_
end

-- 保存数据
function ctn_base:onsave()
    -- 子类需要实现具体的保存逻辑
    return self.data_
end

-- 加载数据
function ctn_base:onload(data)
    -- 子类需要实现具体的加载逻辑
    self.data_ = data or {}
end

-- 加载数据
function ctn_base:load(_loaded_cb)
    if self.loaded_ then 
        log.error(string.format("[ctn_base] Data already loaded for ctn: %s", self.owner_))
        return
    end 
    
    self.state_ = CONTAINER_STATE.LOADING
    skynet.fork(function()
        local ok, err = pcall(function()
            self:doload()
            self.loaded_ = true
            self.state_ = CONTAINER_STATE.LOADED
            self.last_save_time_ = skynet.time()
            if _loaded_cb then 
                _loaded_cb(self)
            end
        end)
        
        if not ok then
            self:set_error(err)
            log.error(string.format("[ctn_base] Failed to load data for ctn: %s, error: %s", 
                self.owner_, err))
        end
    end)
end

-- 从数据库加载数据
function ctn_base:doload()
    -- 子类需要实现具体的数据库加载逻辑
end 

-- 保存数据到数据库
function ctn_base:save()
    if not self.loaded_ then
        log.error(string.format("[ctn_base] Invalid save, Data not loaded for ctn: %s", self.owner_))
        return 
    end
    
    skynet.fork(function()
        local ok, err = pcall(function()
            self:dosave()
        end)
        
        if not ok then
            self:set_error(err)
            log.error(string.format("[ctn_base] Failed to save data for ctn: %s, name: %s, error: %s", 
                self.owner_, self.name_, err))
            return 
        end

        self:clear_dirty()
        self.last_save_time_ = skynet.time()
    end)
end

-- 保存数据到数据库
function ctn_base:dosave()
    -- 子类需要实现具体的数据库保存逻辑
end

-- 添加数据
function ctn_base:add_item(key, value)
    self.data_[key] = value
    self:set_dirty()
end

-- 获取数据
function ctn_base:get_item(key)
    return self.data_[key]
end

-- 删除数据
function ctn_base:remove_item(key)
    self.data_[key] = nil
    self:set_dirty()
end

-- 检查数据是否存在
function ctn_base:has_item(key)
    return self.data_[key] ~= nil
end

-- 获取所有数据
function ctn_base:get_all_items()
    return self.data_
end

-- 清空数据
function ctn_base:clear()
    self.data_ = {}
    self:set_dirty()
end

-- 获取数据数量
function ctn_base:get_item_count()
    local count = 0
    for _ in pairs(self.data_) do
        count = count + 1
    end
    return count
end

-- 检查数据是否为空
function ctn_base:is_empty()
    return next(self.data_) == nil
end

return ctn_base