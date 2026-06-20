local skynet = require "skynet"

local function on_get_mail_list(player_id, msg)
    local mailS = skynet.localname(".mail")
    if not mailS then
        return false, "Mail service not available"
    end
    return skynet.call(mailS, "lua", "get_mail_list", player_id, msg.page, msg.page_size)
end

local function on_get_mail_detail(player_id, msg)
    local mailS = skynet.localname(".mail")
    if not mailS then
        return false, "Mail service not available"
    end
    return skynet.call(mailS, "lua", "get_mail_detail", player_id, msg.mail_id)
end

local function on_claim_items(player_id, msg)
    local mailS = skynet.localname(".mail")
    if not mailS then
        return false, "Mail service not available"
    end
    return skynet.call(mailS, "lua", "claim_items", player_id, msg.mail_id)
end

local function on_delete_mail(player_id, msg)
    local mailS = skynet.localname(".mail")
    if not mailS then
        return false, "Mail service not available"
    end
    return skynet.call(mailS, "lua", "delete_mail", player_id, msg.mail_id)
end

local function on_send_player_mail(player_id, msg)
    local mailS = skynet.localname(".mail")
    if not mailS then
        return false, "Mail service not available"
    end
    return skynet.call(mailS, "lua", "send_player_mail", player_id, msg.receiver_id, msg.title, msg.content, msg.items)
end

local function on_mark_mail_read(player_id, msg)
    local mailS = skynet.localname(".mail")
    if not mailS then
        return false, "Mail service not available"
    end
    return skynet.call(mailS, "lua", "mark_mail_read", player_id, msg.mail_id)
end

return {
    get_mail_list = on_get_mail_list,
    get_mail_detail = on_get_mail_detail,
    claim_items = on_claim_items,
    delete_mail = on_delete_mail,
    send_player_mail = on_send_player_mail,
    mark_mail_read = on_mark_mail_read,
}
