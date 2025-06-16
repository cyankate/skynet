local skynet = require "skynet"
local log = require "log"
require "skynet.manager"
local service_wrapper = require "utils.service_wrapper"
local friend_mgr = require "friend.friend_mgr"

-- 初始化服务
function CMD.init()
    -- 初始化好友管理器
    friend_mgr.init()
    
    -- 注册事件处理
    local event = skynet.localname(".event")
    skynet.send(event, "lua", "subscribe", "player.login", skynet.self())
    skynet.send(event, "lua", "subscribe", "player.logout", skynet.self())
    
    return true
end

-- 事件处理函数
function CMD.on_event(event_name, event_data)
    if event_name == "player.login" then
        friend_mgr.on_player_login(event_data.player_id)
    elseif event_name == "player.logout" then
        friend_mgr.on_player_logout(event_data.player_id)
    end
end

-- 添加好友
function CMD.add_friend(player_id, target_id, apply_info)
    return friend_mgr.add_friend(player_id, target_id, apply_info)
end

-- 删除好友
function CMD.delete_friend(player_id, target_id)
    return friend_mgr.delete_friend(player_id, target_id)
end

-- 同意好友申请
function CMD.agree_apply(player_id, target_id)
    return friend_mgr.agree_apply(player_id, target_id)
end

-- 拒绝好友申请
function CMD.reject_apply(player_id, target_id)
    return friend_mgr.reject_apply(player_id, target_id)
end

-- 获取好友列表
function CMD.get_friend_list(player_id)
    return friend_mgr.get_friend_list(player_id)
end

-- 获取申请列表
function CMD.get_apply_list(player_id)
    return friend_mgr.get_apply_list(player_id)
end

-- 添加到黑名单
function CMD.add_blacklist(player_id, target_id)
    return friend_mgr.add_blacklist(player_id, target_id)
end

-- 从黑名单移除
function CMD.remove_blacklist(player_id, target_id)
    return friend_mgr.remove_blacklist(player_id, target_id)
end

-- 获取黑名单列表
function CMD.get_black_list(player_id)
    return friend_mgr.get_black_list(player_id)
end

-- 主服务函数
local function main()
    -- 初始化好友服务
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "friend",
    custom_stats = function()
        friend_mgr.cache:get_stats()
    end
})
