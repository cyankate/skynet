local bootstrap = require "entry._bootstrap"
bootstrap("service.mongo_service", { name = "mongo", register_hotfix = false })
