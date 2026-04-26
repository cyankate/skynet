local M = {}

local function replace_inplace(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then
        return src
    end

    for k, _ in pairs(dst) do
        if src[k] == nil then
            dst[k] = nil
        end
    end

    for k, v in pairs(src) do
        if type(dst[k]) == "table" and type(v) == "table" then
            replace_inplace(dst[k], v)
        else
            dst[k] = v
        end
    end

    setmetatable(dst, getmetatable(src))
    return dst
end

function M.update()
    local invalidated = {}
    local reloaded = {}
    local failed = {}
    local old_modules = {}

    local ok_codecache, codecache = pcall(require, "skynet.codecache")
    if ok_codecache and codecache and codecache.clear then
        pcall(codecache.clear)
    end

    for mod_name, mod_ref in pairs(package.loaded) do
        if type(mod_name) == "string" and mod_name:match("^setting%.") then
            old_modules[mod_name] = mod_ref
            package.loaded[mod_name] = nil
            table.insert(invalidated, mod_name)
        end
    end

    for _, mod_name in ipairs(invalidated) do
        local ok, result = pcall(require, mod_name)
        if ok then
            local old_ref = old_modules[mod_name]
            if type(old_ref) == "table" and type(result) == "table" then
                replace_inplace(old_ref, result)
                package.loaded[mod_name] = old_ref
            else
                package.loaded[mod_name] = result
            end
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
