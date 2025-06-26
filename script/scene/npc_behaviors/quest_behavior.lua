local skynet = require "skynet"
local BaseBehavior = require "scene.npc_behaviors.base_behavior"
local class = require "utils.class"
local log = require "log"

-- 任务功能行为
local QuestBehavior = class("QuestBehavior", BaseBehavior)

function QuestBehavior:ctor(npc, config)
    QuestBehavior.super.ctor(self, npc, config)
    self.behavior_name = "quest"
    self.quests = config.quests or {}
    self:init()
end

function QuestBehavior:init()
    -- 验证任务配置
    for _, quest in pairs(self.quests) do
        if not self:validate_quest_config(quest) then
            log.warning("任务配置验证失败: %s", quest.name or quest.id)
        end
    end
end

function QuestBehavior:validate_quest_config(quest)
    if not quest.id then
        return false
    end
    if not quest.name then
        return false
    end
    return true
end

function QuestBehavior:can_interact(player)
    -- 检查是否有可接或可完成的任务
    for _, quest in pairs(self.quests) do
        local quest_status = player:get_quest_status(quest.id)
        
        if not quest_status then
            -- 检查是否可接任务
            if self:can_accept_quest(player, quest) then
                return true
            end
        elseif quest_status == "in_progress" then
            -- 检查是否可完成任务
            if self:can_complete_quest(player, quest) then
                return true
            end
        end
    end
    return false
end

function QuestBehavior:handle_interact(player)
    local available_quests = {}
    local in_progress_quests = {}
    local completed_quests = {}
    
    -- 检查每个任务的状态
    for _, quest in pairs(self.quests) do
        local quest_status = player:get_quest_status(quest.id)
        
        if not quest_status then
            -- 检查是否可接任务
            if self:can_accept_quest(player, quest) then
                table.insert(available_quests, quest)
            end
        elseif quest_status == "in_progress" then
            -- 检查是否可完成任务
            if self:can_complete_quest(player, quest) then
                table.insert(completed_quests, quest)
            else
                table.insert(in_progress_quests, quest)
            end
        end
    end
    
    -- 发送任务列表给玩家
    player:send_message("npc_quest_list", {
        npc_id = self.npc.id,
        available_quests = available_quests,
        in_progress_quests = in_progress_quests,
        completed_quests = completed_quests
    })
    
    return true
end

function QuestBehavior:can_accept_quest(player, quest)
    -- 检查等级要求
    if quest.require_level and player.level < quest.require_level then
        return false
    end
    
    -- 检查职业要求
    if quest.require_profession and player.profession ~= quest.require_profession then
        return false
    end
    
    -- 检查前置任务
    if quest.require_quests then
        for _, require_quest_id in ipairs(quest.require_quests) do
            if player:get_quest_status(require_quest_id) ~= "completed" then
                return false
            end
        end
    end
    
    return true
end

function QuestBehavior:can_complete_quest(player, quest)
    -- 检查任务条件
    for _, condition in ipairs(quest.conditions or {}) do
        if not player:check_quest_condition(condition) then
            return false
        end
    end
    
    return true
end

-- 添加任务
function QuestBehavior:add_quest(quest)
    if self:validate_quest_config(quest) then
        self.quests[quest.id] = quest
        log.info("任务行为添加任务: %s", quest.name)
        return true
    end
    return false
end

-- 移除任务
function QuestBehavior:remove_quest(quest_id)
    if self.quests[quest_id] then
        local quest_name = self.quests[quest_id].name
        self.quests[quest_id] = nil
        log.info("任务行为移除任务: %s", quest_name)
        return true
    end
    return false
end

-- 获取所有任务
function QuestBehavior:get_all_quests()
    return self.quests
end

-- 获取任务信息
function QuestBehavior:get_quest(quest_id)
    return self.quests[quest_id]
end

return QuestBehavior 