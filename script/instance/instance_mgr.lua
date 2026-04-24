local skynet = require "skynet"
local log = require "log"
local InstanceDef = require "define.inst_def"

local instance_mgr = {}

instance_mgr.instances = {}
instance_mgr.instance_counter = 0
instance_mgr.instance_types = {}
instance_mgr.player_instance_map = {} -- player_id -> inst_id

local function resolve_ready_mode(args)
    if args.ready_mode == "all" or args.ready_mode == "leader" or args.ready_mode == "auto" then
        return args.ready_mode
    end
    if args.auto_start == false then
        -- 兼容旧参数：关闭自动开始时默认走全员准备
        return "all"
    end
    return "auto"
end


function instance_mgr.init()
    log.info("instance_mgr: 初始化副本管理器")
    local InstanceSingle = require "instance.types.instance_single"
    local InstanceMulti = require "instance.types.instance_multi"
    instance_mgr.register_instance_type("single", InstanceSingle)
    instance_mgr.register_instance_type("multi", InstanceMulti)
end

function instance_mgr.register_instance_type(type_name, instance_class)
    instance_mgr.instance_types[type_name] = instance_class
    log.info("instance_mgr: 注册副本类型 %s", type_name)
end

function instance_mgr.generate_instance_id()
    instance_mgr.instance_counter = instance_mgr.instance_counter + 1
    return string.format("inst_%d_%d", os.time(), instance_mgr.instance_counter)
end

function instance_mgr.create_instance(type_name, args)
    args = args or {}
    local instance_class = instance_mgr.instance_types[type_name]
    if not instance_class then
        log.error("instance_mgr: 未知的副本类型 %s", type_name)
        return nil
    end
    local inst_id = instance_mgr.generate_instance_id()
    local inst = instance_class.new(inst_id, args.inst_no, args)
    if not inst then
        log.error("instance_mgr: 创建副本失败 %s", type_name)
        return nil
    end
    inst:init()
    instance_mgr.instances[inst_id] = {
        inst = inst,
        type = type_name,
        create_time = os.time(),
        type_name = args.type_name or type_name,
        ready_mode = resolve_ready_mode(args),
        result_source = args.result_source or "server",
        creator_id = args.creator_id,
        ready_players = {},
    }
    return inst_id
end

function instance_mgr.on_player_join(inst_id, player_id, data_)
    -- 预留给后续埋点/事件系统
    log.info("instance_mgr: 玩家%s加入副本%s", tostring(player_id), tostring(inst_id))
end

function instance_mgr.on_player_leave(inst_id, player_id)
    -- 预留给后续埋点/事件系统
    log.info("instance_mgr: 玩家%s离开副本%s", tostring(player_id), tostring(inst_id))
end

function instance_mgr.destroy_instance(inst_id)
    local data = instance_mgr.instances[inst_id]
    if not data then
        -- 幂等：重复销毁视为成功
        return true
    end
    if data.inst then
        for player_id in pairs(data.inst.pjoins_ or {}) do
            instance_mgr.player_instance_map[player_id] = nil
        end
        for player_id in pairs(data.inst.penters_ or {}) do
            instance_mgr.player_instance_map[player_id] = nil
        end
    end
    if data.inst then 
        data.inst:destroy() 
    end
    instance_mgr.instances[inst_id] = nil
    return true
end

function instance_mgr.get_instance(inst_id)
    local data = instance_mgr.instances[inst_id]
    return data and data.inst or nil
end

function instance_mgr.get_instance_data(inst_id)
    return instance_mgr.instances[inst_id]
end

function instance_mgr.get_player_instance(player_id)
    local inst_id = instance_mgr.player_instance_map[player_id]
    if not inst_id then
        return false, "玩家不在副本中"
    end
    return true, inst_id
end

function instance_mgr.join_instance(inst_id, player_id, data_)
    local data = instance_mgr.instances[inst_id]
    if not data or not data.inst then
        return false, "副本不存在"
    end
    local mapped_inst_id = instance_mgr.player_instance_map[player_id]
    if mapped_inst_id and mapped_inst_id ~= inst_id then
        log.warning("instance_mgr: 玩家%s已在副本%s中，拒绝加入副本%s", tostring(player_id), tostring(mapped_inst_id), tostring(inst_id))
        return false, "玩家已在其他副本中"
    end
    local join_ok, join_err = data.inst:join(player_id, data_)
    if not join_ok then
        return false, join_err or "加入副本失败"
    end
    instance_mgr.player_instance_map[player_id] = inst_id
    if not data.creator_id then
        data.creator_id = player_id
    end
    return true
end

function instance_mgr.exit_instance(inst_id, player_id)
    local data = instance_mgr.instances[inst_id]
    if not data or not data.inst then
        return false, "副本不存在"
    end
    return data.inst:exit(player_id)
end

function instance_mgr.quit_instance(inst_id, player_id)
    local data = instance_mgr.instances[inst_id]
    if not data or not data.inst then
        return false, "副本不存在"
    end
    local quit_ok, quit_err = data.inst:quit(player_id)
    if not quit_ok then
        return false, quit_err or "退出副本失败"
    end
    instance_mgr.player_instance_map[player_id] = nil
    data.ready_players[player_id] = nil
    return true
end

function instance_mgr.enter_instance(inst_id, player_id)
    local data = instance_mgr.instances[inst_id]
    if not data or not data.inst then
        return false, "副本不存在"
    end
    return data.inst:enter(player_id)
end

function instance_mgr.is_auto_start(inst_id)
    local data = instance_mgr.instances[inst_id]
    if not data then
        return false
    end
    return data.ready_mode == "auto"
end

function instance_mgr.get_ready_mode(inst_id)
    local data = instance_mgr.instances[inst_id]
    if not data then
        return nil
    end
    return data.ready_mode
end

function instance_mgr.ready_instance(inst_id, player_id)
    local data = instance_mgr.instances[inst_id]
    if not data or not data.inst then
        return false, "副本不存在", false
    end

    local inst = data.inst
    if not inst:has_player(player_id) then
        return false, "玩家未加入副本", false
    end
    if data.ready_mode == "auto" then
        return true, "该副本为自动开始", false
    end
    if inst:is_running() then
        return true, "副本已开始", false
    end

    data.ready_players[player_id] = true

    if data.ready_mode == "leader" then
        if data.creator_id ~= player_id then
            return true, "已准备，等待队长开始", false
        end
        return true, "队长已准备，副本开始", true
    end

    for join_player_id in pairs(inst.pjoins_ or {}) do
        if not data.ready_players[join_player_id] then
            return true, "已准备，等待其他玩家", false
        end
    end
    return true, "全员准备完成，副本开始", true
end

function instance_mgr.update(dt)
    for _, data in pairs(instance_mgr.instances) do
        local inst = data.inst
        if inst and inst.update then
            inst:update(dt)
        end
    end
end

function instance_mgr.shutdown()
    for inst_id, _ in pairs(instance_mgr.instances) do
        instance_mgr.destroy_instance(inst_id)
    end
end

return instance_mgr