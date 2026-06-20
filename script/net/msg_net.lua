local handlers = {}

local modules = {
    "net.player_net",
    "net.chat_net",
    "net.friend_net",
    "net.instance_net",
    "net.guild_net",
    "net.mail_net",
    "net.combat_net",
    "net.map_net",
}

for _, module_name in ipairs(modules) do
    local module_handlers = require(module_name)
    for name, fn in pairs(module_handlers) do
        handlers[name] = fn
    end
end

return handlers
