local skynet = require "skynet"
local log = require "log"
local InstanceDef = require "script.define.inst_def"

local instance_mgr = {}

instance_mgr.instances = {}
instance_mgr.instance_counter = 0
instance_mgr.instance_types = {}


function instance_mgr.init()
    log.info("instance_mgr: 初始化副本管理器")

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
        create_time = os.time()
    }
    return inst_id
end

function instance_mgr.destroy_instance(inst_id)
    local data = instance_mgr.instances[inst_id]
    if not data then 
        return false 
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