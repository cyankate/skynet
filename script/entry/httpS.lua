local bootstrap = require "entry._bootstrap"
bootstrap("service.http_service", { name = "http", register_hotfix = false, logging_name = "http" })
