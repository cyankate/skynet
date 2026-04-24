local class = require "utils.class"
local log = require "log"
local cjson = require "cjson.safe"
local protocol_handler = require "protocol_handler"
local InstanceBase = require "instance.instance_base"
local mode_factory = require "instance.modes.mode_factory"
local inst_def = require "define.inst_def"
local InstanceStatus = inst_def.InstanceStatus
local InstanceEndType = inst_def.InstanceEndType
local InstanceEndReason = inst_def.InstanceEndReason

local DEFAULT_TIMEOUT_SECONDS = 600

local InstanceSingle = class("InstanceSingle", InstanceBase)

function InstanceSingle:ctor(inst_id, inst_no, args)
    InstanceBase.ctor(self, inst_id, inst_no, args)
    self.owner_player_id_ = nil
    self.timeout_seconds_ = tonumber(args and args.timeout_seconds) or DEFAULT_TIMEOUT_SECONDS
    self.progress_ = 0
    self.complete_data_ = nil
    self.complete_success_ = nil
    self.fail_reason_ = nil
    self.mode_type_ = tostring(args and args.mode_type or "survival")
    self.mode_ = mode_factory.create(self.mode_type_, args and args.mode_config or {})
end

function InstanceSingle:join(player_id, data_)
    local joined_count = 0
    for _ in pairs(self.pjoins_ or {}) do
        joined_count = joined_count + 1
    end
    if joined_count >= 1 and not self.pjoins_[player_id] then
        return false, "单人副本仅允许一名玩家"
    end
    return InstanceSingle.super.join(self, player_id, data_)
end

function InstanceSingle:on_join(player_id, data_)
    if not self.owner_player_id_ then
        self.owner_player_id_ = player_id
    end
end

function InstanceSingle:on_enter(player_id)
    if not self.owner_player_id_ then
        self.owner_player_id_ = player_id
    end
    local inst_pack_data = self:pack_data_to_client()
    protocol_handler.send_to_player(player_id, "instance_play_data_notify", {
        inst_id = self.inst_id_,
        data = inst_pack_data,
    })
end

function InstanceSingle:on_exit(player_id)
    -- 暂离不清除成员关系，保留可重入状态
end

function InstanceSingle:on_complete(success, data_)
    self.complete_success_ = success and true or false
    self.complete_data_ = data_ or {}
    if not success then
        self.fail_reason_ = self.complete_data_.reason or self.fail_reason_ or "failed"
    end
end

function InstanceSingle:on_quit(player_id)
    if self.mode_ and self.mode_.on_player_quit then
        self.mode_:on_player_quit(self, player_id)
    end
end

function InstanceSingle:on_destroy()
    self:clear_timers()
end

function InstanceSingle:on_start()
    if self.mode_ and self.mode_.on_start then
        self.mode_:on_start(self)
    end
    self:add_timer("single_instance_timeout", self.timeout_seconds_, function(inst)
        if inst:get_status() == InstanceStatus.RUNNING then
            inst:complete(false, {
                reason = "timeout",
                end_type = InstanceEndType.TIMEOUT,
                end_reason = InstanceEndReason.TIMEOUT_SERVER,
            })
            log.info("InstanceSingle: 副本超时结束 %s", tostring(inst.inst_id_))
        end
    end, 1)
end

function InstanceSingle:on_update(dt)
    if self.mode_ and self.mode_.on_update then
        self.mode_:on_update(self, dt)
    end
    -- 提供最小可观测进度，便于前端联调展示
    self.progress_ = math.min(100, self.progress_ + dt * 5)
end

function InstanceSingle:pack_data_to_client()
    local payload = self:build_client_payload_base()
    payload.owner_player_id = self.owner_player_id_ or 0
    payload.progress = math.floor(self.progress_)
    payload.timeout_seconds = self.timeout_seconds_
    payload.complete_success = self.complete_success_
    payload.fail_reason = self.fail_reason_
    payload.complete_data = self.complete_data_
    payload.mode_type = self.mode_type_
    payload.mode_data = self.mode_ and self.mode_:build_runtime_data(self) or {}
    return cjson.encode(payload) or "{}"
end

return InstanceSingle