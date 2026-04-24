local M = {}

function M.update()
    local reloaded = {}
    for mod_name, _ in pairs(package.loaded) do
        if type(mod_name) == "string" and mod_name:match("^setting%.") then
            package.loaded[mod_name] = nil
            table.insert(reloaded, mod_name)
        end
    end
    table.sort(reloaded)
    return {
        reloaded = reloaded,
        count = #reloaded,
    }
end

return M
