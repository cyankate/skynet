local skynet = require "skynet"
local log = require "log"
local service_ctx = require "runtime.service_ctx"
local mail_mgr = require "system.mail.mail_mgr"
local event_def = require "define.event_def"

local M = service_ctx.get("system.mail.mail_service", {})

function M.get_mail_list(player_id, page, page_size)
    return mail_mgr.get_mail_list(player_id, page, page_size)
end

function M.get_mail_detail(player_id, mail_id)
    return mail_mgr.get_mail_detail(player_id, mail_id)
end

function M.claim_items(player_id, mail_id)
    return mail_mgr.claim_items(player_id, mail_id)
end

function M.delete_mail(player_id, mail_id)
    return mail_mgr.delete_mail(player_id, mail_id)
end

function M.send_player_mail(sender_id, receiver_id, title, content, items)
    return mail_mgr.send_player_mail(sender_id, receiver_id, title, content, items)
end

function M.send_system_mail(receiver_id, title, content, items)
    return mail_mgr.send_system_mail(receiver_id, title, content, items)
end

function M.send_global_mail(title, content, items, expire_days)
    return mail_mgr.send_global_mail(title, content, items, expire_days)
end

function M.on_event(event, data)
    if event == event_def.PLAYER.LOGIN then
        mail_mgr.get_mailbox(data.player_id)
        local count = mail_mgr.check_global_mails(data.player_id)
        if count > 0 then
            log.info("Player %d received %d global mails on login", data.player_id, count)
        end
    elseif event == event_def.PLAYER.LOGOUT then
        mail_mgr.remove_mailbox(data.player_id)
    end
end

function M.init()
    if M._inited then
        return
    end
    M._inited = true

    local event = skynet.localname(".event")
    if event then
        skynet.call(event, "lua", "subscribe", event_def.PLAYER.LOGIN, skynet.self())
        skynet.call(event, "lua", "subscribe", event_def.PLAYER.LOGOUT, skynet.self())
    end
end

return M
