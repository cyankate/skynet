local skynet = require "skynet"
local InstanceBase = require "instance.instance_base"

local InstanceSingle = class("InstanceSingle", InstanceBase)

function InstanceSingle:ctor(inst_id, inst_no, args)
    InstanceBase.ctor(self, inst_id, inst_no, args)
end

function InstanceSingle:on_join(player_id, data_)

end

function InstanceSingle:on_leave(player_id)

end

function InstanceSingle:on_enter(player_id)

end

function InstanceSingle:on_exit(player_id)

end

function InstanceSingle:on_complete(success, data_)

end

function InstanceSingle:on_destroy()

end

return InstanceSingle