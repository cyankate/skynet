package.path = package.path .. ";./script/?.lua;./script/?/init.lua"
local skynet = require "skynet"

local class = require "utils.class"

local ctn_base = class("ctn_base")

function ctn_base:ctor(owner, _name)
    self.owner_ = owner -- 容器所属的玩家对象
    self.name_ = _name or "noname" -- 容器名称
    self.data_ = {}     -- 容器内的数据
end

function ctn_base:onsave()
    -- 这里可以添加保存数据的逻辑
    -- 例如将 self.data_ 保存到数据库
    return self.data_
end

function ctn_base:onload(data)
    -- 这里可以添加加载数据的逻辑
    -- 例如将从数据库加载的数据赋值给 self.data_
    self.data_ = data or {}
end

function ctn_base:load(_loaded_cb)
    if self.loaded_ then 
        log.error(string.format("[ctn_base] Data already loaded for ctn: %s", self.owner_))
        return
    end 
    skynet.fork(function()
        self:doload()
        self.loaded_ = true
        if _loaded_cb then 
            _loaded_cb(self)
        end 
    end)
end

function ctn_base:doload()
    -- 实现从db加载数据的逻辑
end 

function ctn_base:save()
    -- 这里可以添加保存数据的逻辑
    -- 例如将 self.data_ 保存到数据库
    -- save_data_to_db(self.owner, self.data_)
end

-- 添加数据
function ctn_base:add_item(key, value)
    self.data_[key] = value
end

-- 获取数据
function ctn_base:get_item(key)
    return self.data_[key]
end

return ctn_base