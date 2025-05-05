local skynet = require "skynet"
local log = require "log"
local tableUtils = require "utils.tableUtils"
local guild_base = require "guild.guild_base"

-- 错误码定义
local ERROR_CODE = {
    SUCCESS = 0,
    GUILD_NOT_FOUND = 1,
    GUILD_ALREADY_EXISTS = 2,
    PLAYER_ALREADY_IN_GUILD = 3,
    PLAYER_NOT_IN_GUILD = 4,
    PERMISSION_DENIED = 5,
    GUILD_FULL = 6,
    INVALID_PARAM = 7,
    DB_ERROR = 8,
}

local guild_manager = {
    guilds_ = {},                -- 公会列表
    player_guilds_ = {},         -- 玩家所在公会映射
    guild_names_ = {},           -- 公会名称映射
    dirty_guilds_ = {},          -- 需要保存的公会列表
    save_timer_ = nil,           -- 保存定时器
    max_guild_count_ = 1000,     -- 最大公会数量
    max_member_count_ = 100,     -- 最大成员数量
    save_interval_ = 300,        -- 保存间隔(秒)
    ERROR_CODE = ERROR_CODE,     -- 错误码
}

-- 初始化
function guild_manager.init()
    -- 加载所有公会数据
    local guilds = skynet.call(".db", "lua", "load_all_guilds")
    for _, guild_data in ipairs(guilds) do
        local guild = guild_base:new(guild_data.id, guild_data.name, guild_data.leader_id)
        guild:onload(guild_data)
        guild_manager.add_guild(guild)
    end
    
    -- 启动保存定时器
    guild_manager.save_timer_ = skynet.timeout(guild_manager.save_interval_ * 100, function()
        guild_manager.save_dirty_guilds()
    end)
end

-- 创建公会
function guild_manager.create_guild(_leader_id, _leader_name, _guild_name)
    -- 检查公会名称是否已存在
    if guild_manager.guild_names_[_guild_name] then
        return ERROR_CODE.GUILD_ALREADY_EXISTS
    end
    
    -- 检查玩家是否已在其他公会
    if guild_manager.player_guilds_[_leader_id] then
        return ERROR_CODE.PLAYER_ALREADY_IN_GUILD
    end
    
    -- 检查公会数量是否达到上限
    if tableUtils.table_count(guild_manager.guilds_) >= guild_manager.max_guild_count_ then
        return ERROR_CODE.GUILD_FULL
    end
    
    -- 创建公会
    local guild_id = guild_manager.generate_guild_id()
    local guild = guild_base:new(guild_id, _guild_name, _leader_id)
    
    -- 添加会长
    guild:add_member(_leader_id, _leader_name, guild.GUILD_POSITION.LEADER)
    
    -- 添加到管理器
    guild_manager.add_guild(guild)
    
    -- 标记为需要保存
    guild_manager.dirty_guilds_[guild_id] = true
    
    return ERROR_CODE.SUCCESS, guild_id
end

-- 解散公会
function guild_manager.disband_guild(_guild_id, _player_id)
    local guild = guild_manager.guilds_[_guild_id]
    if not guild then
        return ERROR_CODE.GUILD_NOT_FOUND
    end
    
    -- 检查权限
    if not guild:check_permission(_player_id, guild.GUILD_PERMISSION.DISBAND) then
        return ERROR_CODE.PERMISSION_DENIED
    end
    
    -- 移除所有成员
    for member_id, _ in pairs(guild.members_) do
        guild_manager.player_guilds_[member_id] = nil
    end
    
    -- 从管理器中移除
    guild_manager.guilds_[_guild_id] = nil
    guild_manager.guild_names_[guild.name_] = nil
    guild_manager.dirty_guilds_[_guild_id] = nil
    
    -- 从数据库中删除
    skynet.call(".db", "lua", "delete_guild", _guild_id)
    
    return ERROR_CODE.SUCCESS
end

-- 加入公会
function guild_manager.join_guild(_guild_id, _player_id, _player_name)
    local guild = guild_manager.guilds_[_guild_id]
    if not guild then
        return ERROR_CODE.GUILD_NOT_FOUND
    end
    
    -- 检查玩家是否已在其他公会
    if guild_manager.player_guilds_[_player_id] then
        return ERROR_CODE.PLAYER_ALREADY_IN_GUILD
    end
    
    -- 检查公会是否已满
    if tableUtils.table_count(guild.members_) >= guild_manager.max_member_count_ then
        return ERROR_CODE.GUILD_FULL
    end
    
    -- 检查加入条件
    if guild.join_setting_.need_approval then
        guild:add_application(_player_id, _player_name)
        guild_manager.dirty_guilds_[_guild_id] = true
        return ERROR_CODE.SUCCESS
    end
    
    -- 直接加入
    guild:add_member(_player_id, _player_name)
    guild_manager.player_guilds_[_player_id] = _guild_id
    guild_manager.dirty_guilds_[_guild_id] = true
    
    return ERROR_CODE.SUCCESS
end

-- 退出公会
function guild_manager.quit_guild(_player_id)
    local guild_id = guild_manager.player_guilds_[_player_id]
    if not guild_id then
        return ERROR_CODE.PLAYER_NOT_IN_GUILD
    end
    
    local guild = guild_manager.guilds_[guild_id]
    if not guild then
        return ERROR_CODE.GUILD_NOT_FOUND
    end
    
    -- 检查是否是会长
    local member = guild.members_[_player_id]
    if member.position == guild.GUILD_POSITION.LEADER then
        return ERROR_CODE.PERMISSION_DENIED
    end
    
    -- 移除成员
    guild:remove_member(_player_id)
    guild_manager.player_guilds_[_player_id] = nil
    guild_manager.dirty_guilds_[guild_id] = true
    
    return ERROR_CODE.SUCCESS
end

-- 踢出成员
function guild_manager.kick_member(_guild_id, _operator_id, _target_id)
    local guild = guild_manager.guilds_[_guild_id]
    if not guild then
        return ERROR_CODE.GUILD_NOT_FOUND
    end
    
    -- 检查权限
    if not guild:check_permission(_operator_id, guild.GUILD_PERMISSION.KICK) then
        return ERROR_CODE.PERMISSION_DENIED
    end
    
    -- 检查目标是否是会长
    local target_member = guild.members_[_target_id]
    if target_member.position == guild.GUILD_POSITION.LEADER then
        return ERROR_CODE.PERMISSION_DENIED
    end
    
    -- 移除成员
    guild:remove_member(_target_id)
    guild_manager.player_guilds_[_target_id] = nil
    guild_manager.dirty_guilds_[_guild_id] = true
    
    return ERROR_CODE.SUCCESS
end

-- 任命职位
function guild_manager.appoint_position(_guild_id, _operator_id, _target_id, _new_position)
    local guild = guild_manager.guilds_[_guild_id]
    if not guild then
        return ERROR_CODE.GUILD_NOT_FOUND
    end
    
    -- 检查权限
    if not guild:check_permission(_operator_id, guild.GUILD_PERMISSION.APPOINT) then
        return ERROR_CODE.PERMISSION_DENIED
    end
    
    -- 修改职位
    guild:change_position(_target_id, _new_position)
    guild_manager.dirty_guilds_[_guild_id] = true
    
    return ERROR_CODE.SUCCESS
end

-- 处理加入申请
function guild_manager.handle_application(_guild_id, _operator_id, _target_id, _accept)
    local guild = guild_manager.guilds_[_guild_id]
    if not guild then
        return ERROR_CODE.GUILD_NOT_FOUND
    end
    
    -- 检查权限
    if not guild:check_permission(_operator_id, guild.GUILD_PERMISSION.ACCEPT_JOIN) and
       not guild:check_permission(_operator_id, guild.GUILD_PERMISSION.REJECT_JOIN) then
        return ERROR_CODE.PERMISSION_DENIED
    end
    
    -- 检查申请是否存在
    if not guild.applications_[_target_id] then
        return ERROR_CODE.INVALID_PARAM
    end
    
    -- 移除申请
    guild:remove_application(_target_id)
    
    -- 如果接受申请，则添加成员
    if _accept then
        -- 检查公会是否已满
        if tableUtils.table_count(guild.members_) >= guild_manager.max_member_count_ then
            return ERROR_CODE.GUILD_FULL
        end
        
        -- 检查玩家是否已在其他公会
        if guild_manager.player_guilds_[_target_id] then
            return ERROR_CODE.PLAYER_ALREADY_IN_GUILD
        end
        
        -- 添加成员
        guild:add_member(_target_id, guild.applications_[_target_id].name)
        guild_manager.player_guilds_[_target_id] = _guild_id
    end
    
    guild_manager.dirty_guilds_[_guild_id] = true
    return ERROR_CODE.SUCCESS
end

-- 添加公会到管理器
function guild_manager.add_guild(_guild)
    guild_manager.guilds_[_guild.id_] = _guild
    guild_manager.guild_names_[_guild.name_] = _guild.id_
    
    -- 更新玩家所在公会映射
    for member_id, _ in pairs(_guild.members_) do
        guild_manager.player_guilds_[member_id] = _guild.id_
    end
end

-- 生成公会ID
function guild_manager.generate_guild_id()
    local id = 1
    while guild_manager.guilds_[id] do
        id = id + 1
    end
    return id
end

-- 保存需要保存的公会
function guild_manager.save_dirty_guilds()
    for guild_id, _ in pairs(guild_manager.dirty_guilds_) do
        local guild = guild_manager.guilds_[guild_id]
        if guild then
            skynet.call(".db", "lua", "save_guild", guild:onsave())
        end
    end
    
    guild_manager.dirty_guilds_ = {}
    
    -- 重新启动保存定时器
    guild_manager.save_timer_ = skynet.timeout(guild_manager.save_interval_ * 100, function()
        guild_manager.save_dirty_guilds()
    end)
end

-- 获取公会信息
function guild_manager.get_guild_info(_guild_id)
    local guild = guild_manager.guilds_[_guild_id]
    if not guild then
        return nil
    end
    
    return guild:get_data()
end

-- 获取玩家所在公会信息
function guild_manager.get_player_guild_info(_player_id)
    local guild_id = guild_manager.player_guilds_[_player_id]
    if not guild_id then
        return nil
    end
    
    return guild_manager.get_guild_info(guild_id)
end

-- 获取公会列表
function guild_manager.get_guild_list(_page, _page_size)
    local guilds = {}
    local start = (_page - 1) * _page_size + 1
    local count = 0
    
    for guild_id, guild in pairs(guild_manager.guilds_) do
        count = count + 1
        if count >= start and count < start + _page_size then
            table.insert(guilds, guild:get_data())
        end
    end
    
    return guilds, math.ceil(count / _page_size)
end

return guild_manager 