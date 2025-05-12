local skynet = require "skynet"
local log = require "log"
local class = require "utils.class"
local bit = require "utils.bit"
local IDGenerator = class("IDGenerator")

function IDGenerator:ctor()
    self.config = require "utils.id_generator_config"
    self:init()
end

-- 初始化
function IDGenerator:init()
    -- 初始化递增型ID生成器
    for name, cfg in pairs(self.config) do
        if cfg.type == "increment" then
            self:init_increment_generator(name, cfg)
        end
    end
end

-- 初始化递增型ID生成器
function IDGenerator:init_increment_generator(name, cfg)
    -- 从数据库获取最大ID
    local db = skynet.localname(".db")
    local max_id = skynet.call(db, "lua", "get_max_id", cfg.table, cfg.id_field)
    if not max_id then
        max_id = cfg.init_value
    end
    -- 保存到内存
    cfg.current_id = max_id
end

-- 生成递增ID
function IDGenerator:gen_increment_id(name)
    local cfg = self.config[name]
    if not cfg or cfg.type ~= "increment" then
        error("Invalid ID generator: " .. name)
    end
    
    -- 递增ID
    cfg.current_id = cfg.current_id + 1
    return cfg.current_id
end

-- 生成ID的主接口
function IDGenerator:gen_id(name)
    local cfg = self.config[name]
    if not cfg then
        error("Unknown ID generator: " .. name)
    end
    
    if cfg.type == "increment" then
        return self:gen_increment_id(name)
    else
        error("Unsupported ID generator type: " .. cfg.type)
    end
end

return IDGenerator 