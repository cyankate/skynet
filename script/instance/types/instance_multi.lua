local class = require "utils.class"
local tableUtils = require "utils.tableUtils"
local log = require "log"
local InstanceBase = require "instance.instance_base"
local protocol_handler = require "protocol_handler"
local mode_factory = require "instance.modes.mode_factory"
local inst_def = require "define.inst_def"
local InstanceStatus = inst_def.InstanceStatus
local InstanceEndType = inst_def.InstanceEndType
local InstanceEndReason = inst_def.InstanceEndReason

local DEFAULT_TIMEOUT_SECONDS = 900

local function table_size(t)
    local n = 0
    for _ in pairs(t or {}) do
        n = n + 1
    end
    return n
end

local InstanceMulti = class("InstanceMulti", InstanceBase)

function InstanceMulti:ctor(inst_id, inst_no, args)
    InstanceBase.ctor(self, inst_id, inst_no, args)
    self.max_players_ = (args and args.team_size) or 3
    self.min_players_ = (args and args.min_players) or 2
    self.timeout_seconds_ = tonumber(args and args.timeout_seconds) or DEFAULT_TIMEOUT_SECONDS
    self.complete_data_ = nil
    self.complete_success_ = nil
    self.fail_reason_ = nil
    self.mode_type_ = tostring(args and args.mode_type or "waves")
    self.mode_ = mode_factory.create(self.mode_type_, args and args.mode_config or {})
end

function InstanceMulti:join(player_id, data_)
    local joined_count = table_size(self.pjoins_)
    if joined_count >= self.max_players_ then
        return false, "多人副本已满"
    end
    return InstanceMulti.super.join(self, player_id, data_)
end

function InstanceMulti:start()
    local joined_count = table_size(self.pjoins_)
    if joined_count < self.min_players_ then
        return false, "人数不足，无法开始多人副本"
    end
    return InstanceMulti.super.start(self)
end

function InstanceMulti:on_start()
    if self.mode_ and self.mode_.on_start then
        self.mode_:on_start(self)
    end
    self:add_timer("multi_instance_timeout", self.timeout_seconds_, function(inst)
        if inst:get_status() == InstanceStatus.RUNNING then
            inst:complete(false, {
                reason = "timeout",
                end_type = InstanceEndType.TIMEOUT,
                end_reason = InstanceEndReason.TIMEOUT_SERVER,
            })
            log.info("InstanceMulti: 副本超时结束 %s", tostring(inst.inst_id_))
        end
    end, 1)
end

function InstanceMulti:on_quit(player_id)
    if self.mode_ and self.mode_.on_player_quit then
        self.mode_:on_player_quit(self, player_id)
    end
end

function InstanceMulti:on_enter(player_id)
    protocol_handler.send_to_player(player_id, "instance_play_data_notify", self:build_play_data_notify())
end

function InstanceMulti:on_update(dt)
    if self.mode_ and self.mode_.on_update then
        self.mode_:on_update(self, dt)
    end
end

function InstanceMulti:on_complete(success, data_)
    self.complete_success_ = success and true or false
    self.complete_data_ = {}
    if type(data_) == "table" then
        for k, v in pairs(data_) do
            self.complete_data_[k] = v
        end
    end
    if not success then
        self.fail_reason_ = self.complete_data_.reason or self.fail_reason_ or "failed"
    end
end

function InstanceMulti:build_extra_data()
    local members = {}
    for player_id in pairs(self.pjoins_ or {}) do
        table.insert(members, player_id)
    end
    return {
        max_players = self.max_players_,
        min_players = self.min_players_,
        members = members,
        timeout_seconds = self.timeout_seconds_,
        mode_type = self.mode_type_,
        mode_data = self.mode_ and self.mode_:build_runtime_data(self) or {},
        complete_data = self.complete_data_,
    }
end

function InstanceMulti:pack_extra_to_client()
    return tableUtils.serialize_table(self:build_extra_data()) or ""
end

return InstanceMulti
