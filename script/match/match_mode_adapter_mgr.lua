local adapter_mgr = {}

adapter_mgr.adapters = {}

local function load_builtin_adapters()
    local builtins = {
        instance_default = "match.adapters.instance_default_adapter",
        world_boss = "match.adapters.world_boss_adapter",
        daily_instance = "match.adapters.daily_instance_adapter",
    }
    for adapter_name, module_name in pairs(builtins) do
        local ok, adapter_impl = pcall(require, module_name)
        if ok and type(adapter_impl) == "table" then
            adapter_mgr.adapters[adapter_name] = adapter_impl
        end
    end
end

function adapter_mgr.register_adapter(adapter_name, adapter_impl)
    if not adapter_name or adapter_name == "" then
        return false, "adapter_name 不能为空"
    end
    if type(adapter_impl) ~= "table" or type(adapter_impl.on_all_confirmed) ~= "function" then
        return false, "adapter 实现必须包含 on_all_confirmed"
    end
    adapter_mgr.adapters[adapter_name] = adapter_impl
    return true
end

function adapter_mgr.get_adapter(adapter_name)
    return adapter_mgr.adapters[adapter_name or "instance_default"] or adapter_mgr.adapters.instance_default
end

function adapter_mgr.prepare_team(players, options)
    local adapter_name = options and options.adapter_name or "instance_default"
    local adapter = adapter_mgr.get_adapter(adapter_name)
    local profiles = {}
    for _, player_id in ipairs(players or {}) do
        local profile = adapter.build_player_profile(player_id, options or {})
        table.insert(profiles, profile or { player_id = player_id })
    end
    local ok, err = adapter.validate_candidate(profiles, options or {})
    if ok == false then
        return false, err or "队伍校验失败"
    end
    return true, profiles
end

function adapter_mgr.on_all_confirmed(players, options)
    local adapter_name = options and options.adapter_name or "instance_default"
    local adapter = adapter_mgr.get_adapter(adapter_name)
    return adapter.on_all_confirmed(players, options or {})
end

load_builtin_adapters()

return adapter_mgr
