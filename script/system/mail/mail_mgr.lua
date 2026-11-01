local skynet = require "skynet"
local log = require "log"
local mailbox = require "system.mail.mailbox"
local service_ctx = require "runtime.service_ctx"
local locator = require "cluster.locator"
local rpc = require "cluster.rpc"
local db_call = require "system.db_call"

-- 邮件类型
local MAIL_TYPE = {
    SYSTEM = 1,    -- 系统邮件
    PLAYER = 2,    -- 玩家邮件
    GUILD = 3,     -- 公会邮件
    SYSTEM_REWARD = 4,  -- 系统奖励邮件
    GLOBAL = 5,    -- 全局邮件
}

-- 邮件状态
local MAIL_STATUS = {
    UNREAD = 0,    -- 未读
    READ = 1,      -- 已读
    DELETED = 2,   -- 已删除
}

-- 附件状态
local ITEMS_STATUS = {
    UNCLAIMED = 0,  -- 未领取
    CLAIMED = 1,    -- 已领取
}

-- 邮件配置
local config = {
    max_mail_count = 100,        -- 每个玩家最大邮件数量
    max_attachment_count = 5,    -- 每封邮件最大附件数量
    mail_expire_days = 30,       -- 邮件过期天数
    system_mail_expire_days = 7, -- 系统邮件过期天数
    max_title_length = 50,       -- 邮件标题最大长度
    max_content_length = 1000,   -- 邮件内容最大长度
}

local mail_mgr = {}

-- 玩家邮箱缓存
local ctx = service_ctx.get("system.mail.mail_mgr", {})
ctx.player_mailboxes = ctx.player_mailboxes or {}
local player_mailboxes = ctx.player_mailboxes

-- 获取玩家邮箱对象
function mail_mgr.get_mailbox(player_id)
    local box = player_mailboxes[player_id]
    if not box then
        box = mailbox.new(player_id)
        player_mailboxes[player_id] = box
    end
    return box
end

-- 移除玩家邮箱对象
function mail_mgr.remove_mailbox(player_id)
    player_mailboxes[player_id] = nil
end

-- 新邮件写入 DB 后调用：清掉缓存，让在线玩家下次拉取时重新加载
function mail_mgr.on_new_mail(player_id)
    mail_mgr.remove_mailbox(player_id)
    return true
end

-- 连接断开（闪断宽限期内邮箱仍保留）
function mail_mgr.on_player_logout(player_id)
end

-- 玩家正式离线，从内存卸载邮箱
function mail_mgr.on_player_offline(player_id)
    mail_mgr.remove_mailbox(player_id)
end

-- 获取邮件列表（分页）
function mail_mgr.get_mail_list(player_id, page)
    local box = mail_mgr.get_mailbox(player_id)
    local mails = box:load_page(page)
    
    return {
        mails = mails,
        unread_count = box:get_unread_count(),
        has_more = box.has_more
    }
end

-- 获取邮件详情
function mail_mgr.get_mail_detail(player_id, mail_id)
    local dbS = skynet.localname(".db")
    -- 获取完整邮件信息
    local mail = db_call.call("select", "mail", {
        mail_id = mail_id,
        receiver_id = player_id,
        is_deleted = 0
    })
    
    if not mail or not mail[1] then
        return false, "邮件不存在"
    end
    
    mail = mail[1]
    
    -- 如果是未读，标记为已读
    if mail.status == MAIL_STATUS.UNREAD then
        db_call.call("update_where", "mail", {
            mail_id = mail_id,
            receiver_id = player_id,
        }, {
            status = MAIL_STATUS.READ
        })
        
        -- 更新邮箱缓存
        local box = mail_mgr.get_mailbox(player_id)
        box:update_mail_status(mail_id, MAIL_STATUS.READ)
    end
    
    -- dbS.select 已反序列化 text；字符串按旧格式解析
    local items = mail.items
    if type(items) == "string" and items ~= "" then
        items = tableUtils.deserialize_table(items)
    elseif type(items) ~= "table" then
        items = nil
    end
    mail.items = items

    return true, mail
end

-- 领取附件：校验 / 发奖 / 标记已领取由玩家 agent 在一个事务里完成
function mail_mgr.claim_items(player_id, mail_id)
    local agent = locator.get_agent(player_id)
    if not agent then
        log.error("领取附件失败，玩家不在线: " .. tostring(player_id))
        return false, "player offline"
    end
    local ok, result, err = rpc.call_timeout(agent, 500, "claim_mail_items", {
        player_id = player_id,
        mail_id = mail_id,
    })
    if not ok or not result then
        log.error("领取附件失败: " .. tostring(err or result))
        return false, err or result
    end
    local box = mail_mgr.get_mailbox(player_id)
    box:update_attachments_claimed(mail_id, ITEMS_STATUS.CLAIMED)
    return true
end

-- 删除邮件
function mail_mgr.delete_mail(player_id, mail_id)
    local dbS = skynet.localname(".db")
    -- 检查是否有未领取的附件
    local mail = db_call.call("select", "mail", {
        mail_id = mail_id,
        receiver_id = player_id,
        is_deleted = 0
    })
    
    if not mail or not mail[1] then
        return false, "邮件不存在"
    end
    
    if mail[1].items_status == ITEMS_STATUS.UNCLAIMED and mail[1].items and mail[1].items ~= "" then
        return false, "请先领取附件"
    end
    -- 标记删除
    local ok = db_call.call("update_where", "mail", {
        mail_id = mail_id,
        receiver_id = player_id,
    }, {
        is_deleted = 1
    })
    
    if ok then
        -- 更新邮箱缓存
        local box = mail_mgr.get_mailbox(player_id)
        box:delete_mail(mail_id)
    end
    
    return ok
end

-- 发送个人邮件
function mail_mgr.send_player_mail(sender_id, receiver_id, title, content, items)
    -- 参数检查
    if not receiver_id or receiver_id <= 0 then
        return false, "无效的接收者ID"
    end
    
    if not title or title == "" or #title > config.max_title_length then
        return false, "无效的邮件标题"
    end
    
    if content and #content > config.max_content_length then
        return false, "邮件内容超过长度限制"
    end
    
    if items and #items > config.max_attachment_count then
        return false, "附件数量超过限制"
    end
    
    -- 获取玩家邮箱
    local box = mail_mgr.get_mailbox(receiver_id)
    
    -- 检查邮件数量限制
    if box:get_mail_count() >= config.max_mail_count then
        return false, "收件人邮箱已满"
    end
    local dbS = skynet.localname(".db")
    -- 创建邮件数据
    local mail = {
        mail_id = box:gen_mail_id(sender_id),
        mail_type = MAIL_TYPE.PLAYER,
        sender_id = sender_id,
        receiver_id = receiver_id,
        title = title,
        content = content or "",
        items = items and tableUtils.serialize_table(items) or "",
        create_time = os.time(),
        expire_time = os.time() + config.mail_expire_days * 86400,
        status = MAIL_STATUS.UNREAD,
        items_status = items and #items > 0 and ITEMS_STATUS.UNCLAIMED or 0,
        is_deleted = 0
    }
    
    -- 插入数据库
    local ok = db_call.call("insert", "mail", mail)
    if not ok then
        return false, "发送邮件失败"
    end
    
    -- 更新邮箱缓存
    box:add_mail(mail)
    
    protocol_handler.send_to_player(receiver_id, "new_mail_notify", {
        mail_id = mail.mail_id,
        title = mail.title,
        has_items = items and #items > 0
    })
    
    return true, mail.mail_id
end

-- 发送系统邮件
function mail_mgr.send_system_mail(receiver_id, title, content, items)
    return mail_mgr.send_player_mail(0, receiver_id, title, content, items)
end

-- 发送全服邮件
function mail_mgr.send_global_mail(title, content, items, expire_days)
    -- 参数检查
    if not title or title == "" or #title > config.max_title_length then
        return false, "无效的邮件标题"
    end
    
    if content and #content > config.max_content_length then
        return false, "邮件内容超过长度限制"
    end
    
    if items and #items > config.max_attachment_count then
        return false, "附件数量超过限制"
    end
    local dbS = skynet.localname(".db")
    expire_days = expire_days or config.system_mail_expire_days
    
    -- 创建全局邮件模板
    local global_mail = {
        mail_id = string.format("g_%d_%d", os.time(), db_call.call("gen_id", "mail")),
        title = title,
        content = content or "",
        items = items and tableUtils.serialize_table(items) or "",
        create_time = os.time(),
        expire_time = os.time() + expire_days * 86400,
        --status = 1
    }
    
    -- 保存全局邮件模板
    local ok = db_call.call("insert", "global_mail", global_mail)
    if not ok then
        return false, "创建全局邮件失败"
    end

    local loginS = skynet.localname(".login")
    local online_players = skynet.call(loginS, "lua", "get_all_online_player_id")
    
    -- 批量插入在线玩家的邮件
    local batch_mails = {}
    for player_id, _ in pairs(online_players) do
        table.insert(batch_mails, {
            mail_id = string.format("%s_%d", global_mail.mail_id, player_id),
            mail_type = MAIL_TYPE.GLOBAL,
            sender = 0,
            receiver_id = player_id,
            title = title,
            content = content or "",
            items = items and tableUtils.serialize_table(items) or "",
            create_time = global_mail.create_time,
            expire_time = global_mail.expire_time,
            status = MAIL_STATUS.UNREAD,
            items_status = items and #items > 0 and ITEMS_STATUS.UNCLAIMED or 0,
            is_deleted = 0
        })
        
        -- 每1000个玩家批量插入一次
        if #batch_mails >= 100 then
            db_call.call("batch_insert", "mail", batch_mails)
            batch_mails = {}
        end
    end
    
    -- 插入剩余的邮件
    if #batch_mails > 0 then
        db_call.call("batch_insert", "mail", batch_mails)
    end
    
    -- 广播新邮件通知
    protocol_handler.send_to_players(online_players, "new_mail_notify", {
        mail_id = global_mail.mail_id,
        title = title,
        has_items = items and #items > 0
    })
    
    return true, global_mail.mail_id
end

-- 检查玩家未接收的全局邮件
function mail_mgr.check_global_mails(player_id)
    local box = mail_mgr.get_mailbox(player_id)
    local last_time = box:get_last_global_time()
    local dbS = skynet.localname(".db")
    -- 获取新的全局邮件
    local new_globals = db_call.call("select", "global_mail", {
        create_time = {[">"] = last_time},
        --status = 1,
        expire_time = {[">"] = os.time()}
    })
    
    -- 批量插入新邮件
    if #new_globals > 0 then
        local values = {}
        for _, global in ipairs(new_globals) do
            local mail = {
                mail_id = string.format("g_%d_%d", global.mail_id, player_id),
                mail_type = MAIL_TYPE.GLOBAL,
                sender = 0,
                receiver_id = player_id,
                title = global.title,
                content = global.content,
                items = global.items,
                create_time = global.create_time,
                expire_time = global.expire_time,
                status = MAIL_STATUS.UNREAD,
                items_status = global.items and global.items ~= "" and ITEMS_STATUS.UNCLAIMED or 0,
                is_deleted = 0
            }
            table.insert(values, mail)
            
            -- 更新邮箱缓存
            box:add_mail(mail)
        end
        
        db_call.call("batch_insert", "mail", values)
        box:update_last_global_time(new_globals[#new_globals].create_time)
        return #values
    end
    
    return 0
end

-- 清理过期邮件（expire_time = 0 表示永不过期）
function mail_mgr.clean_expired_mails()
    local now = os.time()
    local mails = db_call.call("select", "mail", {
        expire_time = {["<"] = now, ["!="] = 0},
    }, { limit = 500 })
    for _, mail in ipairs(mails or {}) do
        if (mail.expire_time or 0) > 0 then
            db_call.call("delete", "mail", { mail_id = mail.mail_id })
        end
    end

    local globals = db_call.call("select", "global_mail", {
        expire_time = {["<"] = now, ["!="] = 0},
    }, { limit = 500 })
    for _, mail in ipairs(globals or {}) do
        if (mail.expire_time or 0) > 0 then
            db_call.call("delete", "global_mail", { mail_id = mail.mail_id })
        end
    end
end

return mail_mgr 