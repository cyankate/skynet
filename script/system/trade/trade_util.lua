-- 交易行共用工具：ID 生成、邮件附件投递
local skynet = require "skynet"

local M = {}

M.MAIL_TYPE_SYSTEM_REWARD = 4

function M.new_id(prefix)
    return string.format("%s%x", prefix or "t", skynet.genid())
end

-- 生成一条系统奖励邮件插入 op；items 是 {{item_id=..., count=...}, ...}
function M.mail_op(receiver_id, title, content, items, now)
    now = now or os.time()
    return {
        op = "insert",
        tbl = "mail",
        data = {
            mail_id = M.new_id("t"),
            sender_id = 0,
            receiver_id = receiver_id,
            mail_type = M.MAIL_TYPE_SYSTEM_REWARD,
            title = title or "交易行",
            content = content or "",
            items = items,
            items_status = 0,
            status = 0,
            create_time = now,
            expire_time = now + 30 * 86400,
            is_deleted = 0,
        },
    }
end

return M
