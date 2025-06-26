local skynet = require "skynet"
local BaseBehavior = require "scene.npc_behaviors.base_behavior"
local class = require "utils.class"
local log = require "log"

-- 对话功能行为
local DialogBehavior = class("DialogBehavior", BaseBehavior)

function DialogBehavior:ctor(npc, config)
    DialogBehavior.super.ctor(self, npc, config)
    self.behavior_name = "dialog"
    self.dialogs = config.dialogs or {}
    self.default_dialog = config.default_dialog or "你好，有什么可以帮助你的吗？"
    self:init()
end

function DialogBehavior:init()
    -- 验证对话配置
    for _, dialog in pairs(self.dialogs) do
        if not self:validate_dialog(dialog) then
            log.warning("对话配置验证失败: %s", dialog.name or dialog.id)
        end
    end
end

function DialogBehavior:validate_dialog(dialog)
    if not dialog.id then
        return false
    end
    if not dialog.content then
        return false
    end
    return true
end

function DialogBehavior:handle_interact(player)
    -- 根据玩家状态选择合适的对话
    local dialog = self:select_dialog(player)
    
    -- 发送对话内容给玩家
    player:send_message("npc_dialog", {
        npc_id = self.npc.id,
        dialog = dialog,
        options = dialog.options or {}
    })
    
    return true
end

function DialogBehavior:select_dialog(player)
    -- 按优先级选择对话
    local selected_dialog = nil
    local highest_priority = -1
    
    for _, dialog in pairs(self.dialogs) do
        if self:can_show_dialog(player, dialog) then
            local priority = dialog.priority or 0
            if priority > highest_priority then
                highest_priority = priority
                selected_dialog = dialog
            end
        end
    end
    
    -- 如果没有找到合适的对话，使用默认对话
    if not selected_dialog then
        selected_dialog = {
            id = "default",
            content = self.default_dialog,
            options = {}
        }
    end
    
    return selected_dialog
end

function DialogBehavior:can_show_dialog(player, dialog)
    -- 检查等级要求
    if dialog.require_level and player.level < dialog.require_level then
        return false
    end
    
    -- 检查职业要求
    if dialog.require_profession and player.profession ~= dialog.require_profession then
        return false
    end
    
    -- 检查任务要求
    if dialog.require_quests then
        for _, quest_id in ipairs(dialog.require_quests) do
            if player:get_quest_status(quest_id) ~= "completed" then
                return false
            end
        end
    end
    
    -- 检查条件函数
    if dialog.condition_func then
        if not dialog.condition_func(player) then
            return false
        end
    end
    
    return true
end

function DialogBehavior:handle_dialog_option(player, dialog_id, option_id)
    local dialog = self.dialogs[dialog_id]
    if not dialog then
        return false, "对话不存在"
    end
    
    local option = nil
    for _, opt in ipairs(dialog.options or {}) do
        if opt.id == option_id then
            option = opt
            break
        end
    end
    
    if not option then
        return false, "选项不存在"
    end
    
    -- 执行选项动作
    if option.action then
        return self:execute_dialog_action(player, option.action)
    end
    
    return true
end

function DialogBehavior:execute_dialog_action(player, action)
    local action_type = action.type
    
    if action_type == "quest" then
        -- 触发任务相关动作
        return self:handle_quest_action(player, action)
    elseif action_type == "shop" then
        -- 触发商店相关动作
        return self:handle_shop_action(player, action)
    elseif action_type == "transport" then
        -- 触发传送相关动作
        return self:handle_transport_action(player, action)
    elseif action_type == "custom" then
        -- 触发自定义动作
        return self:handle_custom_action(player, action)
    else
        log.warning("未知的对话动作类型: %s", action_type)
        return false, "未知动作类型"
    end
end

function DialogBehavior:handle_quest_action(player, action)
    -- 处理任务相关动作
    if action.quest_id then
        local quest_behavior = self.npc:get_behavior("quest")
        if quest_behavior then
            return quest_behavior:handle_interact(player)
        end
    end
    return false, "任务功能不可用"
end

function DialogBehavior:handle_shop_action(player, action)
    -- 处理商店相关动作
    local shop_behavior = self.npc:get_behavior("shop")
    if shop_behavior then
        return shop_behavior:handle_interact(player)
    end
    return false, "商店功能不可用"
end

function DialogBehavior:handle_transport_action(player, action)
    -- 处理传送相关动作
    local transport_behavior = self.npc:get_behavior("transport")
    if transport_behavior then
        return transport_behavior:handle_interact(player)
    end
    return false, "传送功能不可用"
end

function DialogBehavior:handle_custom_action(player, action)
    -- 处理自定义动作
    if action.func then
        return action.func(player, action.params)
    end
    return true
end

-- 添加对话
function DialogBehavior:add_dialog(dialog)
    if self:validate_dialog(dialog) then
        self.dialogs[dialog.id] = dialog
        log.info("对话行为添加对话: %s", dialog.name or dialog.id)
        return true
    end
    return false
end

-- 移除对话
function DialogBehavior:remove_dialog(dialog_id)
    if self.dialogs[dialog_id] then
        local dialog_name = self.dialogs[dialog_id].name or dialog_id
        self.dialogs[dialog_id] = nil
        log.info("对话行为移除对话: %s", dialog_name)
        return true
    end
    return false
end

-- 更新对话内容
function DialogBehavior:update_dialog_content(dialog_id, new_content)
    if self.dialogs[dialog_id] then
        local old_content = self.dialogs[dialog_id].content
        self.dialogs[dialog_id].content = new_content
        log.info("对话内容更新: %s", dialog_id)
        return true
    end
    return false
end

-- 设置默认对话
function DialogBehavior:set_default_dialog(content)
    self.default_dialog = content
    log.info("默认对话更新: %s", content)
end

-- 获取对话统计信息
function DialogBehavior:get_dialog_stats()
    local total_dialogs = 0
    local conditional_dialogs = 0
    
    for _, dialog in pairs(self.dialogs) do
        total_dialogs = total_dialogs + 1
        if dialog.require_level or dialog.require_profession or dialog.require_quests or dialog.condition_func then
            conditional_dialogs = conditional_dialogs + 1
        end
    end
    
    return {
        total_dialogs = total_dialogs,
        conditional_dialogs = conditional_dialogs,
        default_dialog = self.default_dialog
    }
end

-- 获取所有可用对话
function DialogBehavior:get_available_dialogs(player)
    local available_dialogs = {}
    
    for _, dialog in pairs(self.dialogs) do
        if self:can_show_dialog(player, dialog) then
            table.insert(available_dialogs, dialog)
        end
    end
    
    return available_dialogs
end

return DialogBehavior 