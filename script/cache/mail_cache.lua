local skynet = require "skynet"
local base_cache = require "cache.base_cache"
local class = require "utils.class"

-- 邮件缓存类
local mail_cache = class("mail_cache", base_cache)

-- 构造函数
function mail_cache:ctor(player_id)
    base_cache.ctor(self, "mail_ctn_cache")
    self.player_id = player_id
    -- 邮件详情缓存配置
    local detail_config = {
        max_size = 1000,         -- 最多缓存1000封邮件详情
        ttl = 1800,             -- 缓存30分钟
        cleanup_interval = 300   -- 每5分钟清理一次
    }
    
    -- 初始化缓存实例
    self.detail_cache = base_cache.new("mail_cache", detail_config)
    
    -- 邮件列表缓存
    self.mail_list = {}         -- 完整的邮件列表
    self.list_version = 0       -- 列表版本号
    self.unread_count = 0       -- 未读数量
end

-- 获取单个邮件详情
function mail_cache:get_mail(mail_id)
    return self.detail_cache:get(mail_id, function(key)
        -- 从DB加载邮件详情
        local db = skynet.localname(".db")
        local mail = skynet.call(db, "lua", "get_mail", key)
        if mail then
            -- 检查权限
            if mail.receiver_id == self.player_id or mail.sender_id == self.player_id then
                return mail
            end
        end
        return nil
    end)
end

-- 批量获取邮件详情
function mail_cache:get_mails(mail_ids)
    return self.detail_cache:batch_get(mail_ids, function(keys)
        -- 从DB批量加载邮件详情
        local db = skynet.localname(".db")
        local mails = skynet.call(db, "lua", "get_mails", keys)
        if mails then
            -- 过滤权限
            local filtered_mails = {}
            for mail_id, mail in pairs(mails) do
                if mail.receiver_id == self.player_id or mail.sender_id == self.player_id then
                    filtered_mails[mail_id] = mail
                end
            end
            return filtered_mails
        end
        return nil
    end)
end

-- 获取邮件列表
function mail_cache:get_mail_list(start_index, page_size)
    -- 如果列表为空，从DB加载初始数据
    if #self.mail_list == 0 then
        self:load_initial_list()
    end
    
    -- 计算实际可获取的数据范围
    local end_index = math.min(start_index + page_size - 1, #self.mail_list)
    if start_index > #self.mail_list then
        return {
            mails = {},
            total = #self.mail_list,
            start_index = start_index,
            page_size = page_size,
            version = self.list_version
        }
    end
    
    -- 获取指定范围的邮件ID
    local mail_ids = {}
    for i = start_index, end_index do
        table.insert(mail_ids, self.mail_list[i])
    end
    
    -- 获取邮件详情
    local mails = self:get_mails(mail_ids)
    
    return {
        mails = mails,
        total = #self.mail_list,
        start_index = start_index,
        page_size = page_size,
        version = self.list_version
    }
end

-- 加载初始邮件列表
function mail_cache:load_initial_list()
    local db = skynet.localname(".db")
    local result = skynet.call(db, "lua", "get_player_mail_list", self.player_id, 0, 1000)
    if result and result.mails then
        self.mail_list = {}
        for _, mail in ipairs(result.mails) do
            table.insert(self.mail_list, mail.id)
        end
        self.list_version = self.list_version + 1
    end
end

-- 添加新邮件到列表前端
function mail_cache:add_new_mail(mail_id)
    table.insert(self.mail_list, 1, mail_id)
    self.list_version = self.list_version + 1
end

-- 批量添加新邮件到列表前端
function mail_cache:add_new_mails(mail_ids)
    for i = #mail_ids, 1, -1 do
        table.insert(self.mail_list, 1, mail_ids[i])
    end
    self.list_version = self.list_version + 1
end

-- 从列表中移除邮件
function mail_cache:remove_mail_from_list(mail_id)
    for i, id in ipairs(self.mail_list) do
        if id == mail_id then
            table.remove(self.mail_list, i)
            self.list_version = self.list_version + 1
            break
        end
    end
end

-- 批量从列表中移除邮件
function mail_cache:remove_mails_from_list(mail_ids)
    local removed = false
    for _, mail_id in ipairs(mail_ids) do
        for i, id in ipairs(self.mail_list) do
            if id == mail_id then
                table.remove(self.mail_list, i)
                removed = true
                break
            end
        end
    end
    if removed then
        self.list_version = self.list_version + 1
    end
end

-- 获取未读邮件数量
function mail_cache:get_unread_count()
    return self.unread_count
end

-- 更新邮件状态（已读、删除等）
function mail_cache:update_mail_status(mail_id, status)
    local mail = self:get_mail(mail_id)
    if mail then
        mail.status = status
        self.detail_cache:set(mail_id, mail)
        
        -- 如果状态是已读，更新未读数量
        if status == "READ" and mail.status ~= "READ" then
            self.unread_count = math.max(0, self.unread_count - 1)
        end
    end
end

-- 删除邮件
function mail_cache:delete_mail(mail_id)
    self.detail_cache:remove(mail_id)
    self:remove_mail_from_list(mail_id)
end

-- 批量删除邮件
function mail_cache:delete_mails(mail_ids)
    self.detail_cache:batch_remove(mail_ids)
    self:remove_mails_from_list(mail_ids)
end

-- 清理邮件详情缓存
function mail_cache:clear_detail_cache()
    self.detail_cache:clear()
end

-- 清理所有缓存
function mail_cache:clear()
    self:clear_detail_cache()
    self.mail_list = {}
    self.list_version = 0
    self.unread_count = 0
end

-- 更新未读数量
function mail_cache:update_unread_count(count)
    self.unread_count = count
end

-- 获取缓存统计信息
function mail_cache:get_stats()
    return {
        detail_cache = self.detail_cache:get_stats(),
        list_size = #self.mail_list,
        list_version = self.list_version,
        unread_count = self.unread_count
    }
end

return mail_cache 