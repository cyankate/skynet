local bootstrap = require "entry._bootstrap"
bootstrap("service.hotfix_service", {
    name = "hotfix",
    register_hotfix = false,
})
