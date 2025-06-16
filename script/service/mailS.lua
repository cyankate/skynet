local skynet = require "skynet"
local log = require "log"
require "skynet.manager"
local service_wrapper = require "utils.service_wrapper"
local mail_mgr = require "mail.mail_mgr"

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

-- 获取邮件列表
function CMD.get_mail_list(player_id, page, page_size)
    return mail_mgr.get_mail_list(player_id, page, page_size)
end

-- 获取邮件详情
function CMD.get_mail_detail(player_id, mail_id)
    return mail_mgr.get_mail_detail(player_id, mail_id)
end

-- 领取附件
function CMD.claim_items(player_id, mail_id)
    return mail_mgr.claim_items(player_id, mail_id)
end

-- 删除邮件
function CMD.delete_mail(player_id, mail_id)
    return mail_mgr.delete_mail(player_id, mail_id)
end

-- 发送个人邮件
function CMD.send_player_mail(sender_id, receiver_id, title, content, items)
    return mail_mgr.send_player_mail(sender_id, receiver_id, title, content, items)
end

-- 发送系统邮件
function CMD.send_system_mail(receiver_id, title, content, items)
    return mail_mgr.send_system_mail(receiver_id, title, content, items)
end

-- 发送全服邮件
function CMD.send_global_mail(title, content, items, expire_days)
    return mail_mgr.send_global_mail(title, content, items, expire_days)
end

-- 事件处理
function CMD.on_event(event, data)
    if event == "player.login" then
        -- 获取玩家邮箱（这会自动初始化邮箱数据）
        mail_mgr.get_mailbox(data.player_id)
        
        -- 检查玩家未接收的全局邮件
        local count = mail_mgr.check_global_mails(data.player_id)
        if count > 0 then
            log.info("Player %d received %d global mails on login", data.player_id, count)
        end
    elseif event == "player.logout" then
        -- 移除玩家邮箱缓存
        mail_mgr.remove_mailbox(data.player_id)
    end
end

-- 主服务函数
local function main()
    -- 注册事件处理
    local event = skynet.localname(".event")
    skynet.call(event, "lua", "subscribe", "player.login", skynet.self())

end

service_wrapper.create_service(main, {
    name = "mail",
})
