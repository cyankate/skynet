local skynet = require "skynet"
local class = require "utils.class"
local log = require "log"
local tableUtils = require "utils.tableUtils"
local guild_def = require "define.guild_def"

local GUILD_POSITION = guild_def.GUILD_POSITION
local POSITION_PERMISSIONS = guild_def.POSITION_PERMISSIONS
local MEMBER_DATA_KEYS = guild_def.MEMBER_DATA_KEYS

local guild_base = class("guild_base")

function guild_base:ctor(_id, _name)
    self.id_ = _id                   -- 公会ID
    self.name_ = _name               -- 公会名称
    self.level_ = 1                  -- 公会等级
    self.exp_ = 0                    -- 公会经验
    self.funds_ = 0                  -- 公会资金
    self.notice_ = ""                -- 公会公告
    self.create_time_ = os.time()    -- 创建时间
    self.members_ = {}               -- 成员列表
    self.applications_ = {}          -- 申请列表
    self.join_setting_ = {           -- 加入设置
        need_approval = true,        -- 是否需要审批
        min_level = 1,               -- 最低等级要求
        min_power = 0,               -- 最低战力要求
    }
    self.leader_id_ = 0               -- 会长ID
    self.leader_name_ = ""            -- 会长名称

    self.dirty_ = false              -- 数据是否被修改
    self.inserted_ = false           -- 是否是新插入的数据
    self.is_deleted_ = 0             -- 是否已删除
end

-- 检查权限
function guild_base:check_permission(_player_id, _permission)
    local member = self.members_[_player_id]
    if not member then
        return false
    end
    
    local permissions = POSITION_PERMISSIONS[member.position]
    if not permissions then
        return false
    end
    
    for _, p in ipairs(permissions) do
        if p == _permission then
            return true
        end
    end
    
    return false
end

-- 添加成员
function guild_base:add_member(_player_id, _player_name, _position, _data)
    if self.members_[_player_id] then
        return false
    end
    
    local member = {
        id = _player_id,
        name = _player_name,
        position = _position or GUILD_POSITION.MEMBER,
    }
    self.members_[_player_id] = member
    if _data then
        member.last_online_time = _data[MEMBER_DATA_KEYS.LAST_ONLINE_TIME]
    else
        member.last_online_time = os.time()
        self:dirty()
    end 
    if _position == GUILD_POSITION.LEADER then
        self.leader_id_ = _player_id
        self.leader_name_ = _player_name
    end
    return true
end

-- 移除成员
function guild_base:remove_member(_player_id)
    if not self.members_[_player_id] then
        return false
    end
    
    self.members_[_player_id] = nil
    self:dirty()
    return true
end

-- 修改成员职位
function guild_base:change_position(_player_id, _new_position)
    local member = self.members_[_player_id]
    if not member then
        return false
    end
    
    member.position = _new_position
    self:dirty()
    return true
end

-- 更新成员在线状态
function guild_base:update_member_online(_player_id, _online)
    local member = self.members_[_player_id]
    if not member then
        return false
    end
    
    member.last_online_time = os.time()
    member.online = _online
    self:dirty()
    return true
end

-- 添加贡献
function guild_base:add_contribution(_player_id, _amount)
    local member = self.members_[_player_id]
    if not member then
        return false
    end
    
    member.contribution = member.contribution + _amount
    member.daily_contribution = member.daily_contribution + _amount
    self:dirty()
    return true
end

-- 添加经验
function guild_base:add_exp(_amount)
    self.exp_ = self.exp_ + _amount
    self:dirty()
    return true
end

-- 添加资金
function guild_base:add_funds(_amount)
    self.funds_ = self.funds_ + _amount
    self:dirty()
    return true
end

-- 修改公告
function guild_base:modify_notice(_notice)
    self.notice_ = _notice
    self:dirty()
    return true
end

-- 修改加入设置
function guild_base:modify_join_setting(_setting)
    self.join_setting_ = _setting
    self:dirty()
    return true
end

-- 添加申请
function guild_base:add_application(_player_id, _player_name)
    if self.applications_[_player_id] then
        return false
    end
    
    self.applications_[_player_id] = {
        id = _player_id,
        name = _player_name,
        apply_time = os.time(),
    }
    
    self:dirty()
    return true
end

-- 移除申请
function guild_base:remove_application(_player_id)
    if not self.applications_[_player_id] then
        return false
    end
    
    self.applications_[_player_id] = nil
    self:dirty()
    return true
end 

function guild_base:dirty()
    self.dirty_ = true 
end

function guild_base:is_dirty()
    return self.dirty_
end

function guild_base:clear_dirty()
    self.dirty_ = false
end

-- 获取公会数据
function guild_base:get_data()
    local data = {
        id = self.id_,
        name = self.name_,
    }
    data.members = {}
    for _, member in pairs(self.members_) do
        local mdata = {}
        mdata[MEMBER_DATA_KEYS.ID] = member.id
        mdata[MEMBER_DATA_KEYS.NAME] = member.name
        mdata[MEMBER_DATA_KEYS.POSITION] = member.position
        mdata[MEMBER_DATA_KEYS.LAST_ONLINE_TIME] = member.last_online_time
        table.insert(data.members, mdata)
    end
    data.applications = {}
    for _, application in ipairs(self.applications_) do
        table.insert(data.applications, {
            id = application.id,
            name = application.name,
        })
    end
    local dmap = {}
    dmap.level = self.level_
    dmap.exp = self.exp_
    dmap.funds = self.funds_
    dmap.notice = self.notice_
    data.data = dmap
    data.create_time = self.create_time_
    data.is_deleted = self.is_deleted_
    return data
end

function guild_base:onsave()
    return self:get_data()
end 

-- 加载公会数据
function guild_base:onload(_data)
    self.id_ = _data.id
    self.name_ = _data.name
    for _, member in ipairs(_data.members) do
        local id = member[MEMBER_DATA_KEYS.ID]
        local name = member[MEMBER_DATA_KEYS.NAME]
        local position = member[MEMBER_DATA_KEYS.POSITION]
        self:add_member(id, name, position, member)
    end
    for _, application in ipairs(_data.applications) do
        self:add_application(application.id, application.name)
    end
    local dmap = _data.data
    self.level_ = dmap.level
    self.exp_ = dmap.exp
    self.funds_ = dmap.funds
    self.notice_ = dmap.notice

    self.create_time_ = _data.create_time
    self.is_deleted_ = _data.is_deleted
    self.inserted_ = true
end

return guild_base 