local skynet = require "skynet"
local log = require "log"
local class = require "utils.class"

local Mailbox = class("Mailbox")

function Mailbox:ctor(player_id)
    self.player_id = player_id
    
    -- 缓存数据
    self.mail_count = 0           -- 当前未删除邮件总数
    self.unread_count = 0         -- 未读邮件数量
    self.gen_id = 0              -- 邮件生成ID
    self.last_global_time = 0    -- 最后一封全局邮件的时间
    self.current_page = 1        -- 当前加载的页码
    self.page_size = 10         -- 每页邮件数量
    self.loaded_mails = {}      -- 当前加载的邮件列表
    self.mail_cache = {}        -- 邮件缓存 {mail_id = mail_data}
    self.has_more = false       -- 是否还有更多邮件
    
    -- 初始化数据
    self:init()
end

-- 初始化邮箱数据
function Mailbox:init()
    local dbS = skynet.localname(".db")
    -- 获取邮件总数（未删除）
    local count = skynet.call(dbS, "lua", "select", "mail", {
        receiver_id = self.player_id,
        is_deleted = 0
    }, {
        fields = {"COUNT(*) as count"}
    })
    self.mail_count = count[1].count

    -- 获取未读邮件数量
    local unread = skynet.call(dbS, "lua", "select", "mail", {
        receiver_id = self.player_id,
        status = 0,  -- UNREAD
        is_deleted = 0
    }, {
        fields = {"COUNT(*) as count"}
    })
    self.unread_count = unread[1].count

    -- 获取最大邮件ID（包括已删除的）
    local max_id = skynet.call(dbS, "lua", "select", "mail", {
        receiver_id = self.player_id
    }, {
        fields = {"mail_id"},
        order_by = {id = "DESC"},
        limit = 1
    })
    if max_id and max_id[1] then
        -- 从邮件ID中提取gen_id
        local _, _, gen_id = string.find(max_id[1].mail_id, "p_%d+_(%d+)")
        self.gen_id = tonumber(gen_id) or 0
    end

    -- 获取最后一封全局邮件的时间
    local last_global = skynet.call(dbS, "lua", "select", "mail", {
        receiver_id = self.player_id,
        mail_type = 5  -- GLOBAL
    }, {
        fields = {"create_time"},
        order_by = {create_time = "DESC"},
        limit = 1
    })
    if last_global and last_global[1] then
        self.last_global_time = last_global[1].create_time
    end

end

-- 获取指定邮件
function Mailbox:get_mail(mail_id)
    -- 先从缓存中查找
    local mail = self.mail_cache[mail_id]
    if mail then
        return mail
    end
    
    -- 缓存中没有，从数据库加载
    local dbS = skynet.localname(".db")
    local result = skynet.call(dbS, "lua", "select", "mail", {
        mail_id = mail_id,
        receiver_id = self.player_id,
        is_deleted = 0
    })
    
    if result and result[1] then
        mail = result[1]
        -- 加入缓存
        self.mail_cache[mail_id] = mail
        return mail
    end
    
    return nil
end

-- 加载指定页的邮件列表
function Mailbox:load_page(page)
    local offset = (page - 1) * self.page_size
    local dbS = skynet.localname(".db")
    -- 获取邮件列表
    local mails = skynet.call(dbS, "lua", "select", "mail", {
        receiver_id = self.player_id,
        is_deleted = 0
    }, {
        fields = {"mail_id", "title", "sender_id", "mail_type", "create_time", "status", "items_status"},
        order_by = {id = "DESC"},
        limit = self.page_size,
        offset = offset
    })
    
    self.current_page = page
    self.loaded_mails = mails
    self.has_more = #mails == self.page_size
    
    return mails
end

-- 获取下一页邮件
function Mailbox:next_page()
    if not self.has_more then
        return nil, "没有更多邮件"
    end
    return self:load_page(self.current_page + 1)
end

-- 更新邮件状态
function Mailbox:update_mail_status(mail_id, status)
    -- 获取邮件数据
    local mail = self:get_mail(mail_id)
    if not mail then
        return false, "邮件不存在"
    end
    
    -- 更新缓存中的邮件状态
    if mail.status == 0 and status ~= 0 then  -- 从未读变为已读
        self.unread_count = math.max(0, self.unread_count - 1)
    end
    mail.status = status
    
    -- 更新当前页面显示的邮件状态
    for _, m in ipairs(self.loaded_mails) do
        if m.mail_id == mail_id then
            m.status = status
            break
        end
    end
    
    return true
end

-- 更新邮件附件状态
function Mailbox:update_items_status(mail_id, items_status)
    -- 获取邮件数据
    local mail = self:get_mail(mail_id)
    if not mail then
        return false, "邮件不存在"
    end
    
    -- 更新缓存中的邮件附件状态
    mail.items_status = items_status
    
    -- 更新当前页面显示的邮件附件状态
    for _, m in ipairs(self.loaded_mails) do
        if m.mail_id == mail_id then
            m.items_status = items_status
            break
        end
    end
    
    return true
end

-- 删除邮件
function Mailbox:delete_mail(mail_id)
    -- 获取邮件数据
    local mail = self:get_mail(mail_id)
    if not mail then
        return false, "邮件不存在"
    end
    
    -- 从缓存中移除
    self.mail_cache[mail_id] = nil
    
    -- 更新计数
    if mail.status == 0 then  -- 未读邮件
        self.unread_count = math.max(0, self.unread_count - 1)
    end
    self.mail_count = math.max(0, self.mail_count - 1)
    
    -- 从当前页面移除
    for i, m in ipairs(self.loaded_mails) do
        if m.mail_id == mail_id then
            table.remove(self.loaded_mails, i)
            break
        end
    end
    
    return true
end

-- 添加新邮件
function Mailbox:add_mail(mail)
    -- 更新计数
    self.mail_count = self.mail_count + 1
    if mail.status == 0 then  -- 未读邮件
        self.unread_count = self.unread_count + 1
    end
    
    -- 加入缓存
    self.mail_cache[mail.mail_id] = mail
    
    -- 如果是当前页的邮件，添加到显示列表
    if self.current_page == 1 then
        table.insert(self.loaded_mails, 1, mail)
        -- 移除最后一封邮件保持页面大小
        if #self.loaded_mails > self.page_size then
            table.remove(self.loaded_mails)
        end
    end
end

-- 生成新的邮件ID
function Mailbox:gen_mail_id()
    self.gen_id = self.gen_id + 1
    return string.format("p_%d_%d", self.player_id, self.gen_id)
end

-- 更新最后一封全局邮件时间
function Mailbox:update_last_global_time(time)
    self.last_global_time = time
end

-- 获取最后一封全局邮件时间
function Mailbox:get_last_global_time()
    return self.last_global_time
end

-- 获取未读邮件数量
function Mailbox:get_unread_count()
    return self.unread_count
end

-- 获取邮件总数
function Mailbox:get_mail_count()
    return self.mail_count
end

-- 获取当前加载的邮件列表
function Mailbox:get_loaded_mails()
    return self.loaded_mails
end

-- 清理缓存
function Mailbox:clear_cache()
    self.loaded_mails = {}
    self.current_page = 1
    self.has_more = false
end

return Mailbox 