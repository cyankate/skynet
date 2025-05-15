
local skynet = require "skynet"
local log = require "log"
require "skynet.manager"
local mail_cache = require "cache.mail_cache"
local service_wrapper = require "utils.service_wrapper"

-- 邮件类型
local MAIL_TYPE = {
    SYSTEM = 1,    -- 系统邮件
    PLAYER = 2,    -- 玩家邮件
    GUILD = 3,     -- 公会邮件
    SYSTEM_REWARD = 4,  -- 系统奖励邮件
}

-- 邮件状态
local MAIL_STATUS = {
    UNREAD = 0,    -- 未读
    READ = 1,      -- 已读
    DELETED = 2,   -- 已删除
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

local mail_mgr = nil

-- 邮件结构
local function create_mail(sender_id, receiver_id, mail_type, title, content, attachments)
    return {
        id = skynet.call(".DB", "lua", "gen_id"),  -- 生成唯一ID
        sender_id = sender_id,
        receiver_id = receiver_id,
        mail_type = mail_type,
        title = title,
        content = content,
        attachments = attachments or {},
        status = MAIL_STATUS.UNREAD,
        create_time = os.time(),
        expire_time = os.time() + (mail_type == MAIL_TYPE.SYSTEM and config.system_mail_expire_days or config.mail_expire_days) * 86400,
    }
end

-- 检查邮件数量限制
local function check_mail_count(receiver_id)
    local count = skynet.call(".DB", "lua", "get_mail_count", receiver_id)
    return count < config.max_mail_count
end

-- 检查附件数量限制
local function check_attachment_count(attachments)
    if not attachments then return true end
    return #attachments <= config.max_attachment_count
end

-- 检查邮件内容长度
local function check_mail_content(title, content)
    return #title <= config.max_title_length and #content <= config.max_content_length
end

-- 发送邮件
function CMD.send_mail(sender_id, receiver_id, mail_type, title, content, attachments)
    -- 参数检查
    if not check_mail_count(receiver_id) then
        return false, "收件人邮箱已满"
    end
    
    if not check_attachment_count(attachments) then
        return false, "附件数量超过限制"
    end
    
    if not check_mail_content(title, content) then
        return false, "邮件内容长度超过限制"
    end
    
    -- 创建邮件
    local mail = create_mail(sender_id, receiver_id, mail_type, title, content, attachments)
    
    -- 保存到数据库
    local ok = skynet.call(".DB", "lua", "save_mail", mail)
    if not ok then
        return false, "保存邮件失败"
    end
    
    -- 通知收件人
    skynet.call(".AGENT", "lua", "notify_mail", receiver_id, mail.id)
    
    return true, mail.id
end

-- 发送系统邮件
function CMD.send_system_mail(receiver_id, title, content, attachments)
    return send_mail(0, receiver_id, MAIL_TYPE.SYSTEM, title, content, attachments)
end

-- 发送系统奖励邮件
function CMD.send_system_reward_mail(receiver_id, title, content, attachments)
    return send_mail(0, receiver_id, MAIL_TYPE.SYSTEM_REWARD, title, content, attachments)
end

-- 发送公会邮件
function CMD.send_guild_mail(sender_id, guild_id, title, content, attachments)
    -- 获取公会所有成员
    local members = skynet.call(".GUILD", "lua", "get_guild_members", guild_id)
    if not members then
        return false, "获取公会成员失败"
    end
    
    -- 给每个成员发送邮件
    local results = {}
    for _, member in ipairs(members) do
        local ok, err = send_mail(sender_id, member.id, MAIL_TYPE.GUILD, title, content, attachments)
        table.insert(results, {
            player_id = member.id,
            success = ok,
            error = err
        })
    end
    
    return true, results
end

-- 获取玩家邮件列表
function CMD.get_mail_list(player_id, page, page_size)
    return skynet.call(".DB", "lua", "get_mail_list", player_id, page, page_size)
end

-- 获取邮件详情
function CMD.get_mail_detail(player_id, mail_id)
    local mail = skynet.call(".DB", "lua", "get_mail", mail_id)
    if not mail then
        return false, "邮件不存在"
    end
    
    if mail.receiver_id ~= player_id then
        return false, "无权查看该邮件"
    end
    
    -- 如果邮件未读，标记为已读
    if mail.status == MAIL_STATUS.UNREAD then
        skynet.call(".DB", "lua", "update_mail_status", mail_id, MAIL_STATUS.READ)
    end
    
    return true, mail
end

-- 领取邮件附件
function CMD.claim_attachment(player_id, mail_id)
    local mail = skynet.call(".DB", "lua", "get_mail", mail_id)
    if not mail then
        return false, "邮件不存在"
    end
    
    if mail.receiver_id ~= player_id then
        return false, "无权领取该邮件附件"
    end
    
    if not mail.attachments or #mail.attachments == 0 then
        return false, "该邮件没有附件"
    end
    
    -- 检查附件是否已领取
    if mail.attachments_claimed then
        return false, "附件已领取"
    end
    
    -- 给玩家发放附件物品
    local ok = skynet.call(".ITEM", "lua", "add_items", player_id, mail.attachments)
    if not ok then
        return false, "发放物品失败"
    end
    
    -- 标记附件已领取
    skynet.call(".DB", "lua", "update_mail_attachments_claimed", mail_id, true)
    
    return true
end

-- 删除邮件
function CMD.delete_mail(player_id, mail_id)
    local mail = skynet.call(".DB", "lua", "get_mail", mail_id)
    if not mail then
        return false, "邮件不存在"
    end
    
    if mail.receiver_id ~= player_id then
        return false, "无权删除该邮件"
    end
    
    -- 检查附件是否已领取
    if mail.attachments and #mail.attachments > 0 and not mail.attachments_claimed then
        return false, "请先领取附件"
    end
    
    -- 标记邮件为已删除
    skynet.call(".DB", "lua", "update_mail_status", mail_id, MAIL_STATUS.DELETED)
    
    return true
end

-- 清理过期邮件
function CMD.clean_expired_mails()
    local now = os.time()
    -- 添加清理逻辑
end

-- 事件处理
function CMD.on_event(event, data)
    if event == "player.login" then
        -- 处理玩家登录事件
    end
end

-- 主服务函数
local function main()
    mail_mgr = mail_cache.new()

    -- 注册事件处理
    local event = skynet.localname(".event")
    skynet.call(event, "lua", "subscribe", "player.login", skynet.self())
    skynet.call(event, "lua", "subscribe", "player.logout", skynet.self())
    
    -- 注册服务名
    skynet.register(".mail")
    
    log.info("Mail service initialized")

    -- 启动定时清理过期邮件
    skynet.fork(function()
        while true do
            CMD.clean_expired_mails()
            skynet.sleep(3600 * 100)  -- 每小时清理一次
        end
    end)
end

service_wrapper.create_service(main, {
    name = "mail",
})
