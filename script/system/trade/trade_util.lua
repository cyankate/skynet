-- 交易行共用工具：ID 生成、邮件附件投递
local skynet = require "skynet"
local mail_util = require "system.mail.mail_util"

local M = {}

M.MAIL_TYPE_SYSTEM_REWARD = mail_util.MAIL_TYPE_SYSTEM_REWARD

function M.new_id(prefix)
    return string.format("%s%x", prefix or "t", skynet.genid())
end

-- 生成一条系统奖励邮件插入 op；items 是 {{item_id=..., count=...}, ...}
function M.mail_op(receiver_id, title, content, items, now)
    return mail_util.mail_op(receiver_id, title, content, items, now)
end

return M
