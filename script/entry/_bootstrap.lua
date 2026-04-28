local function bootstrap(service_module, options)
    local service_wrapper = require "utils.service_wrapper"
    local module_name = service_module
    local S = require(module_name)
    local base_cmd = _G.CMD or {}
 
    CMD = setmetatable({}, {
        __index = function(_, k)
            local v = S[k]
            if v ~= nil then
                return v
            end
            return base_cmd[k]
        end
    })

    local function main()
        if S.init then
            local ok, err = S.init()
            if ok == false then
                error(err or (module_name .. " init failed"))
            end
        end
    end

    service_wrapper.create_service(main, options or {})
end

return bootstrap
