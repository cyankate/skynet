local M = {}

local REGISTRY_KEY = "__service_ctx_registry"

local function get_registry()
    local registry = _G[REGISTRY_KEY]
    if not registry then
        registry = {}
        _G[REGISTRY_KEY] = registry
    end
    return registry
end

function M.get(ctx_key, defaults)
    assert(type(ctx_key) == "string" and ctx_key ~= "", "ctx_key is required")

    local registry = get_registry()
    local ctx = registry[ctx_key]
    if not ctx then
        ctx = {}
        registry[ctx_key] = ctx
    end

    if type(defaults) == "table" then
        for k, v in pairs(defaults) do
            if ctx[k] == nil then
                ctx[k] = v
            end
        end
    end

    return ctx
end

function M.get_or_create(ctx_key)
    return M.get(ctx_key)
end

function M.clear(ctx_key)
    assert(type(ctx_key) == "string" and ctx_key ~= "", "ctx_key is required")
    local registry = get_registry()
    registry[ctx_key] = nil
end

function M.clear_all()
    _G[REGISTRY_KEY] = {}
end

return M
