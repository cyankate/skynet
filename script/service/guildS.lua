package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
local skynet = require "skynet"
local log = require "log"
local guild_manager = require "guild.guild_manager"

local CMD = {}

-- 初始化
function CMD.init()
    guild_manager.init()
end

-- 创建公会
function CMD.create_guild(_player_id, _player_name, _guild_name)
    local code, guild_id = guild_manager.create_guild(_player_id, _player_name, _guild_name)
    if code ~= guild_manager.ERROR_CODE.SUCCESS then
        return code
    end
    
    -- 通知客户端
    skynet.send(".agent", "lua", "notify_guild_created", _player_id, guild_id)
    
    return code, guild_id
end

-- 解散公会
function CMD.disband_guild(_guild_id, _player_id)
    local code = guild_manager.disband_guild(_guild_id, _player_id)
    if code ~= guild_manager.ERROR_CODE.SUCCESS then
        return code
    end
    
    -- 通知所有成员
    local guild = guild_manager.guilds_[_guild_id]
    if guild then
        for member_id, _ in pairs(guild.members_) do
            skynet.send(".agent", "lua", "notify_guild_disbanded", member_id, _guild_id)
        end
    end
    
    return code
end

-- 加入公会
function CMD.join_guild(_guild_id, _player_id, _player_name)
    local code = guild_manager.join_guild(_guild_id, _player_id, _player_name)
    if code ~= guild_manager.ERROR_CODE.SUCCESS then
        return code
    end
    
    -- 通知客户端
    skynet.send(".agent", "lua", "notify_guild_joined", _player_id, _guild_id)
    
    return code
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
function CMD.get_guild_info(_guild_id)
    return guild_manager.get_guild_info(_guild_id)
end

-- 获取玩家所在公会信息
function CMD.get_player_guild_info(_player_id)
    return guild_manager.get_player_guild_info(_player_id)
end

-- 获取公会列表
function CMD.get_guild_list(_page, _page_size)
    return guild_manager.get_guild_list(_page, _page_size)
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

-- 服务启动入口
skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            if session == 0 then
                f(...)
            else
                skynet.ret(skynet.pack(f(...)))
            end
        else
            log.error(string.format("[guildS] Unknown command: %s", cmd))
            if session ~= 0 then
                skynet.ret(skynet.pack(guild_manager.ERROR_CODE.INVALID_PARAM))
            end
        end
    end)
end)
