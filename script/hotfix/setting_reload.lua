local M = {}

function M.update()
    local invalidated = {}
    local reloaded = {}
    local failed = {}

    for mod_name, _ in pairs(package.loaded) do
        if type(mod_name) == "string" and mod_name:match("^setting%.") then
            package.loaded[mod_name] = nil
            table.insert(invalidated, mod_name)
        end
    end

    -- 立即重载，避免仅清缓存导致“看起来没生效”
    for _, mod_name in ipairs(invalidated) do
        local ok, result = pcall(require, mod_name)
        if ok then
            table.insert(reloaded, mod_name)
        else
            failed[#failed + 1] = {
                module = mod_name,
                error = tostring(result),
            }
        end
    end

    table.sort(invalidated)
    table.sort(reloaded)

    return {
        invalidated = invalidated,
        reloaded = reloaded,
        failed = failed,
        invalidated_count = #invalidated,
        reloaded_count = #reloaded,
        failed_count = #failed,
    }
end

return M
