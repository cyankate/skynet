local skynet = require "skynet"
local log = require "log"
local friend_cache = require "cache.friend_cache"
local protocol_handler = require "protocol_handler"

-- 好友管理器
friend_mgr = {
    cache = nil,
}

-- 发送消息给玩家
local function send_to_player(player_id, name, data)
    local gate = skynet.localname(".gate")
    if not gate then
        log.error("Gate service not found")
        return false
    end
    skynet.send(gate, "lua", "send_to_player", player_id, name, data)
end

-- 添加好友
function friend_mgr.add_friend(player_id, target_id, message)
    -- 检查是否已经是好友
    local operator = friend_mgr.cache:get(player_id)
    if not operator then
        return false, "Operator data not found"
    end
    
    if operator:is_friend(target_id) then
        return false, "Already friend"
    end
    
    -- 检查是否在黑名单中
    if operator:is_in_blacklist(target_id) then
        return false, "Target in black list"
    end
    
    -- 添加好友申请
    local target = friend_mgr.cache:get(target_id)
    if not target then
        return false, "Target not found"
    end
    
    -- 检查目标是否在黑名单中
    if target:is_in_blacklist(player_id) then
        return false, "You are in target's black list"
    end
    
    local ok, err = target:add_apply(player_id, message)
    if not ok then
        return false, err
    end
    
    friend_mgr.cache:mark_dirty(target_id)
    send_to_player(player_id, "add_friend_response", { result = 0, message = "Success" })
    
    -- 通知目标玩家有新好友申请
    send_to_player(target_id, "friend_apply_notify", { player_id = player_id, message = message })
    return true
end

-- 删除好友
function friend_mgr.delete_friend(player_id, target_id)
    local operator = friend_mgr.cache:get(player_id)
    if not operator then
        return false, "Operator data not found"
    end
    
    local ok, err = operator:remove_friend(target_id)
    if not ok then
        return false, err
    end
    
    friend_mgr.cache:mark_dirty(player_id)
    send_to_player(player_id, "delete_friend_response", { result = 0, message = "Success" })
    
    -- 通知对方好友关系解除
    send_to_player(target_id, "friend_delete_notify", { player_id = player_id })
    return true
end

-- 同意好友申请
function friend_mgr.agree_apply(player_id, target_id)
    local operator = friend_mgr.cache:get(player_id)
    if not operator then
        return false, "Operator data not found"
    end
    
    -- 检查是否有申请
    if not operator:has_apply(target_id) then
        return false, "No apply"
    end
    
    -- 添加好友关系
    local target = friend_mgr.cache:get(target_id)
    if not target then
        return false, "Target not found"
    end
    
    -- 双向添加好友
    local ok1, err1 = operator:add_friend(target_id, {})
    local ok2, err2 = target:add_friend(player_id, {})
    
    if not (ok1 and ok2) then
        -- 回滚操作
        operator:remove_friend(target_id)
        target:remove_friend(player_id)
        return false, "Add friend failed"
    end
    
    -- 删除申请
    operator:remove_apply(target_id)
    
    friend_mgr.cache:mark_dirty(player_id)
    friend_mgr.cache:mark_dirty(target_id)
    
    -- 发送成功响应
    send_to_player(player_id, "agree_apply_response", { result = 0, message = "Success" })
    
    -- 通知对方好友申请已同意
    send_to_player(target_id, "friend_agree_notify", { player_id = player_id })
    return true
end

-- 拒绝好友申请
function friend_mgr.reject_apply(player_id, target_id)
    local operator = friend_mgr.cache:get(player_id)
    if not operator then
        return false, "Operator data not found"
    end
    
    local ok, err = operator:remove_apply(target_id)
    if not ok then
        return false, err
    end
    
    friend_mgr.cache:mark_dirty(player_id)
    send_to_player(player_id, "reject_apply_response", { result = 0, message = "Success" })
    return true
end

-- 获取好友列表
function friend_mgr.get_friend_list(player_id)
    local operator = friend_mgr.cache:get(player_id)
    if not operator then
        return false, "Operator data not found"
    end
    
    local list = operator:get_friend_list()
    send_to_player(player_id, "get_friend_list_response", { result = 0, friend_list = list })
    return true
end

-- 获取申请列表
function friend_mgr.get_apply_list(player_id)
    local operator = friend_mgr.cache:get(player_id)
    if not operator then
        return false, "Operator data not found"
    end
    
    local list = operator:get_apply_list()
    send_to_player(player_id, "get_apply_list_response", { result = 0, apply_list = list })
    return true
end

-- 添加到黑名单
function friend_mgr.add_blacklist(player_id, target_id)
    local operator = friend_mgr.cache:get(player_id)
    if not operator then
        return false, "Operator data not found"
    end
    
    local ok, err = operator:add_to_blacklist(target_id)
    if not ok then
        return false, err
    end
    
    friend_mgr.cache:mark_dirty(player_id)
    send_to_player(player_id, "add_blacklist_response", { result = 0, message = "Success" })
    return true
end

-- 从黑名单移除
function friend_mgr.remove_blacklist(player_id, target_id)
    local operator = friend_mgr.cache:get(player_id)
    if not operator then
        return false, "Operator data not found"
    end
    
    local ok, err = operator:remove_from_blacklist(target_id)
    if not ok then
        return false, err
    end
    
    friend_mgr.cache:mark_dirty(player_id)
    send_to_player(player_id, "remove_blacklist_response", { result = 0, message = "Success" })
    return true
end

-- 获取黑名单列表
function friend_mgr.get_black_list(player_id)
    local operator = friend_mgr.cache:get(player_id)
    if not operator then
        return false, "Operator data not found"
    end
    
    local list = operator:get_black_list()
    send_to_player(player_id, "get_black_list_response", { result = 0, black_list = list })
    return true
end

-- 玩家登录处理
function friend_mgr.on_player_login(player_id)
    -- 加载玩家好友数据
    friend_mgr.cache:get(player_id)
end

-- 玩家登出处理
function friend_mgr.on_player_logout(player_id)
    -- 保存玩家好友数据
    local data = friend_mgr.cache:get(player_id)
    if data then
        friend_mgr.cache:save(player_id, data)
    end
end

-- 初始化管理器
function friend_mgr.init()
    friend_mgr.cache = friend_cache.new()
    
    -- 定时保存数据
    local function tick()
        skynet.timeout(180 * 100, tick)
        friend_mgr.cache:tick()
    end
    skynet.timeout(180 * 100, tick)
    
    return true
end

return friend_mgr 