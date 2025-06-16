local skynet = require "skynet"
local class = require "utils.class"
local log = require "log"
local ctn_kv = require "ctn.ctn_kv"

local ctn_mail = class("ctn_mail", ctn_kv)

function ctn_mail:ctor(player_id)
    ctn_mail.super.ctor(self, player_id, "mail", "mail")
    self.mail_list = {}
    self.gmail_version = 0
    self.mail_cache = mail_cache.new(player_id)
    self.unread_count = 0
end

function ctn_mail:onload(_data)
    ctn_mail.super.onload(self, _data.kvdata)
    self.mail_list = _data.mail_list
    self.gmail_version = _data.gmail_version
end 

function ctn_mail:onsave()
    local data = {
        kvdata = ctn_mail.super.onsave(self),
    }
    data.mail_list = self.mail_list
    data.gmail_version = self.gmail_version
    return data
end

function ctn_mail:add_mail(mail_id)

end 

function ctn_mail:remove_mail(mail_id)

end

function ctn_mail:get_mail_list()

end

function ctn_mail:pull_global_mail()
    local mailS = skynet.localname(".mailS")
    local ret = skynet.call(mailS, "lua", "pull_global_mail", self.owner_, self.gmail_version)
    if ret then
        self.mail_list = ret.mail_list
        self.gmail_version = ret.gmail_version
    end
end

return ctn_mail