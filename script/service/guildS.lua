local skynet = require "skynet"
local log = require "log"
local guild_manager = require "guild.guild_manager"
require "skynet.manager"
local service_wrapper = require "utils.service_wrapper"
local protocol_handler = require "protocol_handler"

-- 公会数据
local guilds = {}  -- 公会ID -> 公会数据
local player_guild = {}  -- 玩家ID -> 公会ID

-- 初始化
function CMD.init()
    guild_manager.init()
end

-- 创建公会
function CMD.create_guild(player_id, guild_name, guild_info)
    if player_guild[player_id] then
        return false, "已经加入了公会，不能创建新公会"
    end
    
    -- 生成公会ID（简化处理）
    local guild_id = tostring(os.time()) .. "_" .. player_id
    
    -- 创建公会数据
    guilds[guild_id] = {
        id = guild_id,
        name = guild_name,
        info = guild_info or {},
        leader_id = player_id,
        members = { [player_id] = { id = player_id, join_time = os.time(), role = "leader" } },
        create_time = os.time()
    }
    
    -- 关联玩家与公会
    player_guild[player_id] = guild_id
    
    log.info("Player %s created guild %s (%s)", player_id, guild_name, guild_id)
    
    -- 通知创建者
    protocol_handler.send_to_player(player_id, "guild_notification", {
        type = "created",
        guild_id = guild_id,
        guild_name = guild_name,
        message = "恭喜，公会创建成功！"
    })
    
    return true, guild_id
end

-- 解散公会
function CMD.disband_guild(player_id)
    local guild_id = player_guild[player_id]
    if not guild_id then
        return false, "没有加入任何公会"
    end
    
    local guild = guilds[guild_id]
    if not guild then
        player_guild[player_id] = nil
        return false, "公会不存在"
    end
    
    -- 必须是会长才能解散公会
    if guild.leader_id ~= player_id then
        return false, "只有会长才能解散公会"
    end
    
    -- 记录公会成员列表
    local members = {}
    for member_id, _ in pairs(guild.members) do
        table.insert(members, member_id)
        player_guild[member_id] = nil  -- 移除关联
    end
    
    -- 删除公会
    guilds[guild_id] = nil
    
    log.info("Player %s disbanded guild %s (%s)", player_id, guild.name, guild_id)
    
    -- 通知所有成员
    for _, member_id in ipairs(members) do
        protocol_handler.send_to_player(member_id, "guild_notification", {
            type = "disbanded",
            guild_id = guild_id,
            guild_name = guild.name,
            message = string.format("公会 %s 已被会长解散。", guild.name)
        })
    end
    
    return true
end

-- 加入公会
function CMD.join_guild(player_id, guild_id)
    if player_guild[player_id] then
        return false, "已经加入了公会，不能再加入其他公会"
    end
    
    local guild = guilds[guild_id]
    if not guild then
        return false, "公会不存在"
    end
    
    -- 添加玩家到公会
    guild.members[player_id] = {
        id = player_id,
        join_time = os.time(),
        role = "member"
    }
    
    -- 关联玩家与公会
    player_guild[player_id] = guild_id
    
    log.info("Player %s joined guild %s (%s)", player_id, guild.name, guild_id)
    
    -- 获取公会成员列表
    local member_ids = {}
    for member_id, _ in pairs(guild.members) do
        table.insert(member_ids, member_id)
    end
    
    -- 通知加入者
    protocol_handler.send_to_player(player_id, "guild_notification", {
        type = "joined",
        guild_id = guild_id,
        guild_name = guild.name,
        message = "成功加入公会！"
    })
    
    -- 通知其他公会成员
    for member_id, _ in pairs(guild.members) do
        if member_id ~= player_id then
            protocol_handler.send_to_player(member_id, "guild_notification", {
                type = "member_joined",
                guild_id = guild_id,
                player_id = player_id,
                message = string.format("玩家 %s 加入了公会！", player_id)
            })
        end
    end
    
    return true
end

-- 退出公会
function CMD.quit_guild(_player_id)
    local code = guild_manager.quit_guild(_player_id)
    if code ~= guild_manager.ERROR_CODE.SUCCESS then
        return code
    end
    
    -- 通知客户端
    skynet.send(".agent", "lua", "notify_guild_quitted", _player_id)
    
    return code
end

-- 踢出成员
function CMD.kick_member(_guild_id, _operator_id, _target_id)
    local code = guild_manager.kick_member(_guild_id, _operator_id, _target_id)
    if code ~= guild_manager.ERROR_CODE.SUCCESS then
        return code
    end
    
    -- 通知被踢出的玩家
    skynet.send(".agent", "lua", "notify_guild_kicked", _target_id, _guild_id)
    
    return code
end

-- 任命职位
function CMD.appoint_position(_guild_id, _operator_id, _target_id, _new_position)
    local code = guild_manager.appoint_position(_guild_id, _operator_id, _target_id, _new_position)
    if code ~= guild_manager.ERROR_CODE.SUCCESS then
        return code
    end
    
    -- 通知被任命的玩家
    skynet.send(".agent", "lua", "notify_position_changed", _target_id, _guild_id, _new_position)
    
    return code
end

-- 处理加入申请
function CMD.handle_application(_guild_id, _operator_id, _target_id, _accept)
    local code = guild_manager.handle_application(_guild_id, _operator_id, _target_id, _accept)
    if code ~= guild_manager.ERROR_CODE.SUCCESS then
        return code
    end
    
    -- 通知申请人
    skynet.send(".agent", "lua", "notify_application_handled", _target_id, _guild_id, _accept)
    
    return code
end

-- 获取公会信息
function CMD.get_guild_info(player_id)
    local guild_id = player_guild[player_id]
    if not guild_id then
        return nil, "没有加入任何公会"
    end
    
    local guild = guilds[guild_id]
    if not guild then
        player_guild[player_id] = nil
        return nil, "公会不存在"
    end
    
    -- 格式化成员列表
    local members = {}
    for member_id, member_info in pairs(guild.members) do
        table.insert(members, {
            id = member_id,
            join_time = member_info.join_time,
            role = member_info.role
        })
    end
    
    return {
        id = guild.id,
        name = guild.name,
        info = guild.info,
        leader_id = guild.leader_id,
        members = members,
        create_time = guild.create_time
    }
end

-- 获取玩家所在公会信息
function CMD.get_player_guild_info(_player_id)
    return guild_manager.get_player_guild_info(_player_id)
end

-- 获取公会列表
function CMD.get_guild_list(_page, _page_size)
    return guild_manager.get_guild_list(_page, _page_size)
end

-- 发送公会消息
function CMD.send_guild_message(player_id, message)
    local guild_id = player_guild[player_id]
    if not guild_id then
        return false, "没有加入任何公会"
    end
    
    local guild = guilds[guild_id]
    if not guild then
        player_guild[player_id] = nil
        return false, "公会不存在"
    end
    
    log.debug("Guild message from %s to guild %s: %s", player_id, guild.name, message)
    
    -- 向所有公会成员发送消息
    for member_id, _ in pairs(guild.members) do
        protocol_handler.send_to_player(member_id, "guild_message", {
            guild_id = guild_id,
            guild_name = guild.name,
            sender_id = player_id,
            content = message,
            timestamp = os.time()
        })
    end
    
    return true
end

-- 公会系统公告
function CMD.guild_announcement(guild_id, message)
    local guild = guilds[guild_id]
    if not guild then
        return false, "公会不存在"
    end
    
    log.info("Guild announcement to %s: %s", guild.name, message)
    
    -- 获取公会成员列表
    local member_ids = {}
    for member_id, _ in pairs(guild.members) do
        table.insert(member_ids, member_id)
    end
    
    -- 向所有公会成员发送系统公告
    protocol_handler.send_to_players(member_ids, "guild_announcement", {
        guild_id = guild_id,
        guild_name = guild.name,
        content = message,
        timestamp = os.time()
    })
    
    return true
end

-- 处理客户端请求
function CMD.handle_request(_player_id, _cmd, ...)
    local func = CMD[_cmd]
    if not func then
        log.error(string.format("[guildS] Invalid command: %s", _cmd))
        return guild_manager.ERROR_CODE.INVALID_PARAM
    end
    
    return func(_player_id, ...)
end

-- 主服务函数
local function main()
    
    -- 注册服务名
    skynet.register(".guild")
    
    log.info("Guild service started")
end

service_wrapper.create_service(main, {
    name = "guild",
})
