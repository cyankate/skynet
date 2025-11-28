local skynet = require "skynet"
local log = require "log"
local tableUtils = require "utils.tableUtils"
local Guild = require "guild.guild_base"
local guild_def = require "define.guild_def"

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

local guild_mgr = {
    guilds_ = {},                -- 公会列表
    player_guilds_ = {},         -- 玩家所在公会映射
    guild_names_ = {},           -- 公会名称映射
    save_timer_ = nil,           -- 保存定时器
    max_guild_count_ = 1000,     -- 最大公会数量
    max_member_count_ = 100,     -- 最大成员数量
    save_interval_ = 300,        -- 保存间隔(秒)
    ERROR_CODE = ERROR_CODE,     -- 错误码
    gen_id_ = 1,                 -- 生成ID
}

-- 初始化
function guild_mgr.init()
    -- 加载所有公会数据
    local dbS = skynet.localname(".db")
    local guilds = skynet.call(dbS, "lua", "select", "guild", {is_deleted = 0})
    for _, guild_data in ipairs(guilds) do
        local guild = Guild.new(guild_data.id, guild_data.name, guild_data.leader_id)
        guild:onload(guild_data)
        guild_mgr.add_guild(guild)
    end

    local max_id = skynet.call(dbS, "lua", "select", "guild", {}, {
        fields = {"MAX(id) as max_id"},
    })
    if max_id and max_id[1] then
        guild_mgr.gen_id_ = max_id[1].max_id
    end
    
    -- 启动保存定时器
    guild_mgr.save_timer_ = skynet.timeout(guild_mgr.save_interval_ * 100, function()
        guild_mgr.save_dirty_guilds()
    end)
    log.info("guild_mgr init, guild_count: %d, gen_id: %d", tableUtils.table_size(guild_mgr.guilds_), guild_mgr.gen_id_)
end

-- 创建公会
function guild_mgr.create_guild(_leader_id, _leader_name, _guild_name)
    -- 检查公会名称是否已存在
    if guild_mgr.guild_names_[_guild_name] then
        return ERROR_CODE.GUILD_ALREADY_EXISTS
    end
    
    -- 检查玩家是否已在其他公会
    if guild_mgr.player_guilds_[_leader_id] then
        return ERROR_CODE.PLAYER_ALREADY_IN_GUILD
    end
    
    -- 检查公会数量是否达到上限
    if tableUtils.table_size(guild_mgr.guilds_) >= guild_mgr.max_guild_count_ then
        return ERROR_CODE.GUILD_FULL
    end
    
    -- 创建公会
    local guild_id = guild_mgr.generate_guild_id()
    local guild = Guild.new(guild_id, _guild_name, _leader_id)
    
    -- 添加会长
    guild:add_member(_leader_id, _leader_name, guild_def.GUILD_POSITION.LEADER)
    
    -- 添加到管理器
    guild_mgr.add_guild(guild)
    
    guild_mgr.save_guild(guild)
    
    return ERROR_CODE.SUCCESS, guild_id
end

-- 解散公会
function guild_mgr.disband_guild(_guild_id, _player_id)
    local guild = guild_mgr.guilds_[_guild_id]
    if not guild then
        return ERROR_CODE.GUILD_NOT_FOUND
    end
    
    -- 检查权限
    if not guild:check_permission(_player_id, guild_def.GUILD_PERMISSION.DISBAND) then
        return ERROR_CODE.PERMISSION_DENIED
    end
    
    -- 移除所有成员
    for member_id, _ in pairs(guild.members_) do
        guild_mgr.player_guilds_[member_id] = nil
    end
    
    -- 从管理器中移除
    guild_mgr.guilds_[_guild_id] = nil
    guild_mgr.guild_names_[guild.name_] = nil
    guild:dirty()
    
    -- 从数据库中删除
    guild_mgr.delete_guild(_guild_id)
    
    return ERROR_CODE.SUCCESS
end

-- 加入公会
function guild_mgr.join_guild(_guild_id, _player_id, _player_name)
    local guild = guild_mgr.guilds_[_guild_id]
    if not guild then
        return ERROR_CODE.GUILD_NOT_FOUND
    end
    
    -- 检查玩家是否已在其他公会
    if guild_mgr.player_guilds_[_player_id] then
        return ERROR_CODE.PLAYER_ALREADY_IN_GUILD
    end
    
    -- 检查公会是否已满
    if tableUtils.table_size(guild.members_) >= guild_mgr.max_member_count_ then
        return ERROR_CODE.GUILD_FULL
    end
    
    -- 检查加入条件
    if guild.join_setting_.need_approval then
        guild:add_application(_player_id, _player_name)
        guild:dirty()
        return ERROR_CODE.SUCCESS
    end
    
    -- 直接加入
    guild:add_member(_player_id, _player_name)
    guild_mgr.player_guilds_[_player_id] = _guild_id
    guild:dirty()
    
    return ERROR_CODE.SUCCESS
end

-- 退出公会
function guild_mgr.quit_guild(_player_id)
    local guild_id = guild_mgr.player_guilds_[_player_id]
    if not guild_id then
        return ERROR_CODE.PLAYER_NOT_IN_GUILD
    end
    
    local guild = guild_mgr.guilds_[guild_id]
    if not guild then
        return ERROR_CODE.GUILD_NOT_FOUND
    end
    
    -- 检查是否是会长
    local member = guild.members_[_player_id]
    if member.position == guild_def.GUILD_POSITION.LEADER then
        return ERROR_CODE.PERMISSION_DENIED
    end
    
    -- 移除成员
    guild:remove_member(_player_id)
    guild_mgr.player_guilds_[_player_id] = nil
    guild:dirty()
    
    return ERROR_CODE.SUCCESS
end

-- 踢出成员
function guild_mgr.kick_member(_guild_id, _operator_id, _target_id)
    local guild = guild_mgr.guilds_[_guild_id]
    if not guild then
        return ERROR_CODE.GUILD_NOT_FOUND
    end
    
    -- 检查权限
    if not guild:check_permission(_operator_id, guild_def.GUILD_PERMISSION.KICK) then
        return ERROR_CODE.PERMISSION_DENIED
    end
    
    -- 检查目标是否是会长
    local target_member = guild.members_[_target_id]
    if target_member.position == guild_def.GUILD_POSITION.LEADER then
        return ERROR_CODE.PERMISSION_DENIED
    end
    
    -- 移除成员
    guild:remove_member(_target_id)
    guild_mgr.player_guilds_[_target_id] = nil
    guild:dirty()
    
    return ERROR_CODE.SUCCESS
end

-- 任命职位
function guild_mgr.appoint_position(_guild_id, _operator_id, _target_id, _new_position)
    local guild = guild_mgr.guilds_[_guild_id]
    if not guild then
        return ERROR_CODE.GUILD_NOT_FOUND
    end
    
    -- 检查权限
    if not guild:check_permission(_operator_id, guild_def.GUILD_PERMISSION.APPOINT) then
        return ERROR_CODE.PERMISSION_DENIED
    end
    
    -- 修改职位
    guild:change_position(_target_id, _new_position)
    guild:dirty()
    
    return ERROR_CODE.SUCCESS
end

-- 处理加入申请
function guild_mgr.handle_application(_guild_id, _operator_id, _target_id, _accept)
    local guild = guild_mgr.guilds_[_guild_id]
    if not guild then
        return ERROR_CODE.GUILD_NOT_FOUND
    end
    
    -- 检查权限
    if not guild:check_permission(_operator_id, guild_def.GUILD_PERMISSION.ACCEPT_JOIN) and
       not guild:check_permission(_operator_id, guild_def.GUILD_PERMISSION.REJECT_JOIN) then
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
        if tableUtils.table_size(guild.members_) >= guild_mgr.max_member_count_ then
            return ERROR_CODE.GUILD_FULL
        end
        
        -- 检查玩家是否已在其他公会
        if guild_mgr.player_guilds_[_target_id] then
            return ERROR_CODE.PLAYER_ALREADY_IN_GUILD
        end
        
        -- 添加成员
        guild:add_member(_target_id, guild.applications_[_target_id].name)
        guild_mgr.player_guilds_[_target_id] = _guild_id
    end
    
    guild:dirty()
    return ERROR_CODE.SUCCESS
end

-- 添加公会到管理器
function guild_mgr.add_guild(_guild)
    guild_mgr.guilds_[_guild.id_] = _guild
    guild_mgr.guild_names_[_guild.name_] = _guild.id_
    
    -- 更新玩家所在公会映射
    for member_id, _ in pairs(_guild.members_) do
        guild_mgr.player_guilds_[member_id] = _guild.id_
    end
end

-- 生成公会ID
function guild_mgr.generate_guild_id()
    local id = guild_mgr.gen_id_
    guild_mgr.gen_id_ = guild_mgr.gen_id_ + 1
    return id
end

-- 保存需要保存的公会
function guild_mgr.save_dirty_guilds()
    for _, guild in pairs(guild_mgr.guilds_) do
        if guild:is_dirty() then
            guild_mgr.save_guild(guild)
        end
    end
    
    -- 重新启动保存定时器
    guild_mgr.save_timer_ = skynet.timeout(guild_mgr.save_interval_ * 100, function()
        guild_mgr.save_dirty_guilds()
    end)
end

function guild_mgr.save_guild(_guild)
    local dbS = skynet.localname(".db")
    local data = _guild:onsave()
    if not _guild.inserted_ then
        skynet.call(dbS, "lua", "insert", "guild", data)
    else
        skynet.call(dbS, "lua", "update", "guild", data)
    end
    _guild:clear_dirty()
end

function guild_mgr.delete_guild(_guild_id)
    local guild = guild_mgr.guilds_[_guild_id]
    if not guild then
        return
    end
    guild_mgr.guilds_[_guild_id] = nil
    guild_mgr.guild_names_[guild.name_] = nil
    local dbS = skynet.localname(".db")
    guild.is_deleted_ = 1
    local data = guild:onsave()
    skynet.call(dbS, "lua", "update", "guild", data)
end
-- 获取公会信息
function guild_mgr.get_guild_info(_guild_id)
    local guild = guild_mgr.guilds_[_guild_id]
    if not guild then
        return nil
    end
    return guild:get_data()
end

-- 获取玩家所在公会信息
function guild_mgr.get_player_guild_info(_player_id)
    local guild_id = guild_mgr.player_guilds_[_player_id]
    if not guild_id then
        return nil
    end
    
    return guild_mgr.get_guild_info(guild_id)
end

-- 获取公会列表
function guild_mgr.get_guild_list(_page, _page_size)
    local guilds = {}
    local start = (_page - 1) * _page_size + 1
    local count = 0
    
    for guild_id, guild in pairs(guild_mgr.guilds_) do
        count = count + 1
        if count >= start and count < start + _page_size then
            table.insert(guilds, guild:get_data())
        end
    end
    
    return guilds, math.ceil(count / _page_size)
end

return guild_mgr 