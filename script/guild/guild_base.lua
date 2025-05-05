local skynet = require "skynet"
local class = require "utils.class"
local log = require "log"
local tableUtils = require "utils.tableUtils"

local guild_base = class("guild_base")

-- 公会职位定义
local GUILD_POSITION = {
    LEADER = 1,      -- 会长
    VICE_LEADER = 2, -- 副会长
    ELDER = 3,       -- 长老
    MEMBER = 4,      -- 普通成员
}

-- 公会权限定义
local GUILD_PERMISSION = {
    DISBAND = 1,           -- 解散公会
    KICK = 2,              -- 踢人
    APPOINT = 3,           -- 任命职位
    MODIFY_NOTICE = 4,     -- 修改公告
    MODIFY_JOIN_SETTING = 5, -- 修改加入设置
    ACCEPT_JOIN = 6,       -- 接受加入申请
    REJECT_JOIN = 7,       -- 拒绝加入申请
    MANAGE_TREASURY = 8,   -- 管理公会仓库
    MANAGE_BUILDING = 9,   -- 管理公会建筑
    MANAGE_TECH = 10,      -- 管理公会科技
}

-- 职位对应的权限
local POSITION_PERMISSIONS = {
    [GUILD_POSITION.LEADER] = {
        GUILD_PERMISSION.DISBAND,
        GUILD_PERMISSION.KICK,
        GUILD_PERMISSION.APPOINT,
        GUILD_PERMISSION.MODIFY_NOTICE,
        GUILD_PERMISSION.MODIFY_JOIN_SETTING,
        GUILD_PERMISSION.ACCEPT_JOIN,
        GUILD_PERMISSION.REJECT_JOIN,
        GUILD_PERMISSION.MANAGE_TREASURY,
        GUILD_PERMISSION.MANAGE_BUILDING,
        GUILD_PERMISSION.MANAGE_TECH,
    },
    [GUILD_POSITION.VICE_LEADER] = {
        GUILD_PERMISSION.KICK,
        GUILD_PERMISSION.APPOINT,
        GUILD_PERMISSION.MODIFY_NOTICE,
        GUILD_PERMISSION.ACCEPT_JOIN,
        GUILD_PERMISSION.REJECT_JOIN,
        GUILD_PERMISSION.MANAGE_TREASURY,
        GUILD_PERMISSION.MANAGE_BUILDING,
        GUILD_PERMISSION.MANAGE_TECH,
    },
    [GUILD_POSITION.ELDER] = {
        GUILD_PERMISSION.MODIFY_NOTICE,
        GUILD_PERMISSION.ACCEPT_JOIN,
        GUILD_PERMISSION.REJECT_JOIN,
        GUILD_PERMISSION.MANAGE_TREASURY,
    },
    [GUILD_POSITION.MEMBER] = {
        -- 普通成员没有特殊权限
    },
}

function guild_base:ctor(_id, _name, _leader_id)
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
    self.buildings_ = {              -- 公会建筑
        hall = 1,                    -- 公会大厅
        warehouse = 1,               -- 仓库
        tech_center = 1,             -- 科技中心
    }
    self.techs_ = {                  -- 公会科技
        attack = 0,                  -- 攻击科技
        defense = 0,                 -- 防御科技
        hp = 0,                      -- 生命科技
    }
    self.treasury_ = {               -- 公会仓库
        items = {},                  -- 物品列表
        capacity = 100,              -- 容量
    }
    self.dirty_ = false              -- 数据是否被修改
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
function guild_base:add_member(_player_id, _player_name, _position)
    if self.members_[_player_id] then
        return false
    end
    
    self.members_[_player_id] = {
        id = _player_id,
        name = _player_name,
        position = _position or GUILD_POSITION.MEMBER,
        join_time = os.time(),
        last_online_time = os.time(),
        contribution = 0,
        daily_contribution = 0,
    }
    
    self.dirty_ = true
    return true
end

-- 移除成员
function guild_base:remove_member(_player_id)
    if not self.members_[_player_id] then
        return false
    end
    
    self.members_[_player_id] = nil
    self.dirty_ = true
    return true
end

-- 修改成员职位
function guild_base:change_position(_player_id, _new_position)
    local member = self.members_[_player_id]
    if not member then
        return false
    end
    
    member.position = _new_position
    self.dirty_ = true
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
    self.dirty_ = true
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
    self.dirty_ = true
    return true
end

-- 添加经验
function guild_base:add_exp(_amount)
    self.exp_ = self.exp_ + _amount
    self.dirty_ = true
    return true
end

-- 添加资金
function guild_base:add_funds(_amount)
    self.funds_ = self.funds_ + _amount
    self.dirty_ = true
    return true
end

-- 修改公告
function guild_base:modify_notice(_notice)
    self.notice_ = _notice
    self.dirty_ = true
    return true
end

-- 修改加入设置
function guild_base:modify_join_setting(_setting)
    self.join_setting_ = _setting
    self.dirty_ = true
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
    
    self.dirty_ = true
    return true
end

-- 移除申请
function guild_base:remove_application(_player_id)
    if not self.applications_[_player_id] then
        return false
    end
    
    self.applications_[_player_id] = nil
    self.dirty_ = true
    return true
end

-- 升级建筑
function guild_base:upgrade_building(_building_type)
    if not self.buildings_[_building_type] then
        return false
    end
    
    self.buildings_[_building_type] = self.buildings_[_building_type] + 1
    self.dirty_ = true
    return true
end

-- 升级科技
function guild_base:upgrade_tech(_tech_type)
    if not self.techs_[_tech_type] then
        return false
    end
    
    self.techs_[_tech_type] = self.techs_[_tech_type] + 1
    self.dirty_ = true
    return true
end

-- 添加物品到仓库
function guild_base:add_item_to_treasury(_item_id, _count)
    if #self.treasury_.items >= self.treasury_.capacity then
        return false
    end
    
    table.insert(self.treasury_.items, {
        id = _item_id,
        count = _count,
        add_time = os.time() ,
    })
    
    self.dirty_ = true
    return true
end

-- 从仓库移除物品
function guild_base:remove_item_from_treasury(_index)
    if not self.treasury_.items[_index] then
        return false
    end
    
    table.remove(self.treasury_.items, _index)
    self.dirty_ = true
    return true
end

-- 获取公会数据
function guild_base:get_data()
    return {
        id = self.id_,
        name = self.name_,
        level = self.level_,
        exp = self.exp_,
        funds = self.funds_,
        notice = self.notice_,
        create_time = self.create_time_,
        members = self.members_,
        applications = self.applications_,
        join_setting = self.join_setting_,
        buildings = self.buildings_,
        techs = self.techs_,
        treasury = self.treasury_,
    }
end

function guild_base:onsave()
    return self:get_data()
end 

-- 加载公会数据
function guild_base:onload(_data)
    self.id_ = _data.id
    self.name_ = _data.name
    self.level_ = _data.level
    self.exp_ = _data.exp
    self.funds_ = _data.funds
    self.notice_ = _data.notice
    self.create_time_ = _data.create_time
    self.members_ = _data.members
    self.applications_ = _data.applications
    self.join_setting_ = _data.join_setting
    self.buildings_ = _data.buildings
    self.techs_ = _data.techs
    self.treasury_ = _data.treasury
end

return guild_base 