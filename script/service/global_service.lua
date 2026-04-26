local service_ctx = require "runtime.service_ctx"
local global_mgr = require "system.global.global_mgr"

local M = service_ctx.get("global.global_service", {})

function M.init()
    if M._inited then
        return true
    end
    local ok, err = global_mgr.init()
    if not ok then
        return false, err or "global_mgr init failed"
    end
    M._inited = true
    return true
end

return M
