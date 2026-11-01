-- 邮件投递 op：交易行、支付奖励等关键奖励都通过这里生成 mail 行
local skynet = require "skynet"

local M = {}

M.MAIL_TYPE_SYSTEM_REWARD = 4

function M.new_id(prefix)
    return string.format("%s%x", prefix or "t", skynet.genid())
end

-- items 是 {{item_id=..., count=...}, ...}
-- mail_id 传入时用于幂等（同一个 mail_id 重复 upsert 不会产生多封）
function M.mail_op(receiver_id, title, content, items, now, mail_id)
    now = now or os.time()
    return {
        op = "upsert",
        tbl = "mail",
        data = {
            mail_id = mail_id or M.new_id("t"),
            sender_id = 0,
            receiver_id = receiver_id,
            mail_type = M.MAIL_TYPE_SYSTEM_REWARD,
            title = title or "系统奖励",
            content = content or "",
            items = items,
            items_status = 0,
            status = 0,
            create_time = now,
            expire_time = 0, -- 0 = 永不过期（奖励类邮件）
            is_deleted = 0,
        },
    }
end

return M
