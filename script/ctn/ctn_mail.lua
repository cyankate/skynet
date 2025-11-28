local skynet = require "skynet"
local log = require "log"
local CtnKv = require "ctn.ctn_kv"

local CtnMail = class("CtnMail", CtnKv)

function CtnMail:ctor(player_id)
    CtnMail.super.ctor(self, player_id, "mail", "mail")
    self.mail_list = {}
    self.gmail_version = 0
    self.mail_cache = mail_cache.new(player_id)
    self.unread_count = 0
end

function CtnMail:onload(_data)
    CtnMail.super.onload(self, _data.kvdata)
    self.mail_list = _data.mail_list
    self.gmail_version = _data.gmail_version
end 

function CtnMail:onsave()
    local data = {
        kvdata = CtnMail.super.onsave(self),
    }
    data.mail_list = self.mail_list
    data.gmail_version = self.gmail_version
    return data
end

function CtnMail:add_mail(mail_id)

end 

function CtnMail:remove_mail(mail_id)

end

function CtnMail:get_mail_list()

end

function CtnMail:pull_global_mail()
    local mailS = skynet.localname(".mailS")
    local ret = skynet.call(mailS, "lua", "pull_global_mail", self.owner_, self.gmail_version)
    if ret then
        self.mail_list = ret.mail_list
        self.gmail_version = ret.gmail_version
    end
end

return CtnMail