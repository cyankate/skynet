local skynet = require "skynet"
local class = require "utils.class"
local log = require "log"

-- 功能行为基类
local BaseBehavior = class("BaseBehavior")

function BaseBehavior:ctor(npc, config)
    self.npc = npc
    self.config = config or {}
    self.enabled = true
    self.behavior_name = "base"  -- 子类需要重写
end

function BaseBehavior:is_enabled()
    return self.enabled
end

function BaseBehavior:enable()
    self.enabled = true
    log.info("功能行为 %s 已启用", self.behavior_name)
end

function BaseBehavior:disable()
    self.enabled = false
    log.info("功能行为 %s 已禁用", self.behavior_name)
end

function BaseBehavior:can_interact(player)
    return true
end

function BaseBehavior:handle_interact(player)
    return false, "功能未实现"
end

function BaseBehavior:handle_operation(player, operation, ...)
    return false, "功能未实现"
end

-- 获取行为名称
function BaseBehavior:get_behavior_name()
    return self.behavior_name
end

-- 行为初始化（子类可重写）
function BaseBehavior:init()
    -- 子类可重写此方法进行初始化
end

-- 行为销毁（子类可重写）
function BaseBehavior:destroy()
    -- 子类可重写此方法进行清理
end

-- 获取行为配置
function BaseBehavior:get_config()
    return self.config
end

-- 更新行为配置
function BaseBehavior:update_config(new_config)
    for key, value in pairs(new_config) do
        self.config[key] = value
    end
    log.info("功能行为 %s 配置已更新", self.behavior_name)
end

-- 验证配置（子类可重写）
function BaseBehavior:validate_config(config)
    return true
end

-- 获取行为状态信息
function BaseBehavior:get_status()
    return {
        name = self.behavior_name,
        enabled = self.enabled,
        config = self.config
    }
end

return BaseBehavior 