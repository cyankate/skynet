local bootstrap = require "entry._bootstrap"

bootstrap("service.friend_service", {
    name = "friend",
    custom_stats = function()
        local S = require "service.friend_service"
        return S.custom_stats()
    end,
})
