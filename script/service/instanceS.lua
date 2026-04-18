local skynet = require "skynet"
local log = require "log"
local service_wrapper = require "utils.service_wrapper"
local instance_mgr = require "instance.instance_mgr"
local inst_def = require "define.inst_def"
local InstanceStatus = inst_def.InstanceStatus
local tableUtils = require "utils.tableUtils"
local protocol_handler = require "protocol_handler"
local user_mgr = require "user_mgr"

local UPDATE_INTERVAL_TICK = 10 -- 0.1s
local running = true
local scene_counter = 0
local instance_scene_map = {} -- inst_id -> { scene_id, spawn_x, spawn_y }

local function get_instance_or_error(inst_id)
    local inst = instance_mgr.get_instance(inst_id)
    if not inst then
        return nil, false, "副本不存在"
    end
    return inst, true
end

local function generate_scene_id()
    scene_counter = scene_counter + 1
    return 9000000 + scene_counter
end

local function update_loop()
    while running do
        instance_mgr.update(0.1)
        skynet.sleep(UPDATE_INTERVAL_TICK)
    end
end

function CMD.init()
    instance_mgr.init()
    skynet.fork(update_loop)
    log.info("instance service init")
    return true
end

function CMD.create_instance(type_name, args)
    args = args or {}
    local inst_id = instance_mgr.create_instance(type_name, args)
    if not inst_id then
        return false, "创建副本失败"
    end

    local scene_id = args.scene_id or generate_scene_id()
    local scene_config = args.scene_config or {
        width = 1000,
        height = 1000,
        grid_size = 50,
    }
    local scene = skynet.localname(".scene")
    if not scene then
        instance_mgr.destroy_instance(inst_id)
        return false, "场景服务不可用"
    end

    local ok, err = skynet.call(scene, "lua", "create_scene", scene_id, scene_config)
    if not ok then
        instance_mgr.destroy_instance(inst_id)
        return false, err or "创建副本场景失败"
    end

    instance_scene_map[inst_id] = {
        scene_id = scene_id,
        spawn_x = args.spawn_x or 100,
        spawn_y = args.spawn_y or 100,
    }
    return true, inst_id
end

function CMD.destroy_instance(inst_id)
    local scene_data = instance_scene_map[inst_id]
    if scene_data then
        local scene = skynet.localname(".scene")
        if scene then
            skynet.call(scene, "lua", "destroy_scene", scene_data.scene_id)
        end
        instance_scene_map[inst_id] = nil
    end
    local ok = instance_mgr.destroy_instance(inst_id)
    if not ok then
        return false, "副本不存在"
    end
    return true
end

function CMD.join_instance(inst_id, player_id, data_)
    return instance_mgr.join_instance(inst_id, player_id, data_)
end

function CMD.create_and_enter_batch(type_name, args, players, join_data_map)
    args = args or {}
    players = players or {}
    join_data_map = join_data_map or {}

    if #players == 0 then
        return false, "匹配玩家为空", { stage = "precheck" }
    end

    for _, player_id in ipairs(players) do
        local in_inst, current_inst_id = instance_mgr.get_player_instance(player_id)
        if in_inst then
            return false, "玩家已在副本中", {
                stage = "precheck",
                player_id = player_id,
                current_inst_id = current_inst_id,
            }
        end
    end

    local create_ok, inst_id_or_err = CMD.create_instance(type_name, args)
    if not create_ok then
        return false, inst_id_or_err or "创建副本失败", { stage = "create" }
    end

    local inst_id = inst_id_or_err
    for _, player_id in ipairs(players) do
        local join_ok, join_err = instance_mgr.join_instance(inst_id, player_id, join_data_map[player_id] or {})
        if not join_ok then
            CMD.destroy_instance(inst_id)
            return false, join_err or "加入副本失败", {
                stage = "join",
                inst_id = inst_id,
                player_id = player_id,
            }
        end
    end

    for _, player_id in ipairs(players) do
        local enter_ok, enter_err = CMD.enter_instance(inst_id, player_id)
        if not enter_ok then
            CMD.destroy_instance(inst_id)
            return false, enter_err or "进入副本失败", {
                stage = "enter",
                inst_id = inst_id,
                player_id = player_id,
            }
        end
    end

    return true, {
        inst_id = inst_id,
        scene_id = instance_scene_map[inst_id] and instance_scene_map[inst_id].scene_id or 0,
        players = players,
    }
end

function CMD.play_start_direct(player_id, type_name, options)
    local opt = options or {}
    local create_ok, result_or_err, err_info = CMD.create_and_enter_batch(
        opt.instance_type_name or type_name or "single",
        {
            inst_no = opt.inst_no,
            ready_mode = opt.ready_mode or "auto",
            creator_id = player_id,
            type_name = type_name,
            result_source = opt.result_source or "server",
        },
        { player_id },
        {}
    )
    if not create_ok then
        return false, result_or_err, err_info
    end

    local inst_id = result_or_err.inst_id
    local inst_data = instance_mgr.get_instance_data(inst_id)
    local inst = inst_data and inst_data.inst or nil
    local inst_pack_data = inst:pack_data_to_client()

    protocol_handler.send_to_player(player_id, "instance_play_data_notify", {
        inst_id = inst_id,
        data = inst_pack_data,
    })
    return true, inst_id
end

function CMD.leave_instance(inst_id, player_id)
    local scene_data = instance_scene_map[inst_id]
    if scene_data then
        local scene = skynet.localname(".scene")
        if scene then
            skynet.call(scene, "lua", "leave_scene", scene_data.scene_id, player_id)
        end
    end
    local exit_ok, exit_err = instance_mgr.exit_instance(inst_id, player_id)
    if not exit_ok then
        return false, exit_err or "离开副本失败"
    end
    return true
end

function CMD.enter_instance(inst_id, player_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end

    if not inst:has_player(player_id) then
        return false, "玩家未加入副本"
    end

    local scene_data = instance_scene_map[inst_id]
    local scene_entered = false
    if scene_data then
        local scene = skynet.localname(".scene")
        if scene then
            local enter_ok, enter_err = skynet.call(scene, "lua", "enter_scene", scene_data.scene_id, {
                id = player_id,
                type = "player",
                x = scene_data.spawn_x,
                y = scene_data.spawn_y,
                properties = {
                    instance_id = inst_id,
                },
            })
            if not enter_ok then
                return false, enter_err or "进入副本场景失败"
            end
            scene_entered = true
        end
    end

    local enter_ok, enter_err = inst:enter(player_id)
    if not enter_ok then
        if scene_entered then
            local scene = skynet.localname(".scene")
            if scene and scene_data then
                skynet.call(scene, "lua", "leave_scene", scene_data.scene_id, player_id)
            end
        end
        return false, enter_err or "进入副本失败"
    end

    if instance_mgr.is_auto_start(inst_id) and inst:get_status() ~= InstanceStatus.RUNNING then
        local started = inst:start()
        if started then
            log.info("instance auto started, inst_id=%s", tostring(inst_id))
        end
    end
    return true
end

function CMD.exit_instance(inst_id, player_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end

    local scene_data = instance_scene_map[inst_id]
    if scene_data then
        local scene = skynet.localname(".scene")
        if scene then
            skynet.call(scene, "lua", "leave_scene", scene_data.scene_id, player_id)
        end
    end
    local exit_ok, exit_err = inst:exit(player_id)
    if not exit_ok then
        return false, exit_err or "退出副本场景失败"
    end
    return true
end

function CMD.start_instance(inst_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    local started = inst:start()
    if not started then
        return false, "副本状态不允许启动"
    end
    return true
end

function CMD.ready_instance(inst_id, player_id)
    local ok, msg, should_start = instance_mgr.ready_instance(inst_id, player_id)
    if not ok then
        return false, msg or "准备失败"
    end
    if not should_start then
        return true, msg
    end

    local inst, inst_ok, inst_err = get_instance_or_error(inst_id)
    if not inst_ok then
        return false, inst_err
    end
    local started = inst:start()
    if not started then
        return false, "副本状态不允许准备开始"
    end
    return true, msg
end

function CMD.quit_instance(inst_id, player_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end

    local scene_data = instance_scene_map[inst_id]
    if scene_data and inst.penters_[player_id] then
        local scene = skynet.localname(".scene")
        if scene then
            skynet.call(scene, "lua", "leave_scene", scene_data.scene_id, player_id)
        end
    end
    local leave_ok, leave_err = instance_mgr.leave_instance(inst_id, player_id)
    if not leave_ok then
        return false, leave_err or "退出副本失败"
    end

    if tableUtils.table_size(inst.pjoins_) == 0 then
        CMD.destroy_instance(inst_id)
    end
    return true
end

function CMD.pause_instance(inst_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    local paused = inst:pause()
    if not paused then
        return false, "副本状态不允许暂停"
    end
    return true
end

function CMD.resume_instance(inst_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    local resumed = inst:resume()
    if not resumed then
        return false, "副本状态不允许恢复"
    end
    return true
end

function CMD.complete_instance(inst_id, success, data_)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    local completed = inst:complete(success, data_)
    if not completed then
        return false, "副本状态不允许结束"
    end
    return true
end

function CMD.get_instance_status(inst_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    return true, inst:get_status()
end

function CMD.get_instance_info(inst_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end

    return true, {
        inst_id = inst.inst_id_,
        inst_no = inst.inst_no_,
        status = inst.status_,
        create_time = inst.create_time_,
        start_time = inst.start_time_,
        end_time = inst.end_time_,
        duration = inst.duration_,
        scene_id = instance_scene_map[inst_id] and instance_scene_map[inst_id].scene_id or 0,
        join_count = tableUtils.table_size(inst.pjoins_),
        enter_count = tableUtils.table_size(inst.penters_),
    }
end

function CMD.list_instances()
    local list = {}
    for inst_id, data in pairs(instance_mgr.instances) do
        list[inst_id] = {
            type = data.type,
            create_time = data.create_time,
            status = data.inst and data.inst:get_status() or 0,
            scene_id = instance_scene_map[inst_id] and instance_scene_map[inst_id].scene_id or 0,
        }
    end
    return true, list
end

function CMD.get_player_instance(player_id)
    return instance_mgr.get_player_instance(player_id)
end

function CMD.shutdown()
    running = false

    local scene = skynet.localname(".scene")
    if scene then
        for _, data in pairs(instance_scene_map) do
            skynet.call(scene, "lua", "destroy_scene", data.scene_id)
        end
    end

    instance_scene_map = {}
    instance_mgr.shutdown()
    return true
end

local function main()
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "instance",
})
