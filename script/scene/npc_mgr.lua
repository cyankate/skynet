local skynet = require "skynet"
local NPCEntity = require "scene.npc_entity"
local class = require "utils.class"
local log = require "log"

local NPCMgr = class("NPCMgr")

function NPCMgr:ctor(scene)
    self.scene = scene
    self.npcs = {}  -- 存储所有NPC实例
    self.npc_configs = {}  -- 存储NPC配置模板
    self:load_npc_configs()
end

-- 加载NPC配置
function NPCMgr:load_npc_configs()
    -- 这里可以从配置文件或数据库加载NPC配置
    self.npc_configs = {
        -- 新手村任务NPC
        [1001] = {
            name = "村长",
            interact_range = 50,
            behaviors = {
                quest = {
                    quests = {
                        {
                            id = 1001,
                            name = "新手任务",
                            require_level = 1,
                            conditions = {
                                {type = "kill_monster", monster_id = 1001, count = 5}
                            }
                        }
                    }
                },
                dialog = {
                    default_dialog = "欢迎来到新手村！",
                    dialogs = {
                        {
                            condition = {level = 1},
                            content = "你是新来的冒险者吗？"
                        },
                        {
                            condition = {quest = {id = 1001, status = "completed"}},
                            content = "你已经完成了新手任务，真是个好苗子！"
                        }
                    }
                }
            }
        },
        
        -- 商店NPC
        [1002] = {
            name = "杂货商",
            interact_range = 50,
            behaviors = {
                shop = {
                    shop_items = {
                        {id = 1001, name = "生命药水", price = 100, stock = 999},
                        {id = 1002, name = "魔法药水", price = 120, stock = 999},
                        {id = 1003, name = "回城卷轴", price = 50, stock = 999}
                    },
                    buy_rate = 1.0,
                    sell_rate = 0.3
                },
                dialog = {
                    default_dialog = "需要什么商品吗？"
                }
            }
        },
        
        -- 传送NPC
        [1003] = {
            name = "传送师",
            interact_range = 50,
            behaviors = {
                transport = {
                    destinations = {
                        {id = 1, name = "主城", scene_id = 1001, x = 100, y = 100, cost = 10},
                        {id = 2, name = "副本入口", scene_id = 2001, x = 50, y = 50, cost = 20}
                    }
                },
                dialog = {
                    default_dialog = "需要传送到哪里？"
                }
            }
        },
        
        -- 多功能NPC（任务完成后变成商店）
        [1004] = {
            name = "神秘商人",
            interact_range = 50,
            behaviors = {
                quest = {
                    quests = {
                        {
                            id = 1002,
                            name = "寻找宝藏",
                            require_level = 5,
                            conditions = {
                                {type = "collect_item", item_id = 2001, count = 1}
                            }
                        }
                    }
                },
                shop = {
                    shop_items = {
                        {id = 2001, name = "神秘宝箱", price = 1000, stock = 1},
                        {id = 2002, name = "高级装备", price = 5000, stock = 10}
                    },
                    buy_rate = 1.0,
                    sell_rate = 0.3
                },
                dialog = {
                    default_dialog = "我这里有一些特殊的商品...",
                    dialogs = {
                        {
                            condition = {quest = {id = 1002, status = "completed"}},
                            content = "你找到了宝藏！现在我可以为你提供更多商品了。"
                        }
                    }
                }
            }
        },
        
        -- 铁匠NPC
        [1005] = {
            name = "铁匠",
            interact_range = 50,
            behaviors = {
                repair = {
                    repair_fee_rate = 0.1
                },
                enhance = {
                    max_enhance_level = 10,
                    enhance_fee_rate = 0.5,
                    success_rate_base = 0.8
                },
                dialog = {
                    default_dialog = "需要修理或强化装备吗？"
                }
            }
        }
    }
end

-- 创建NPC
function NPCMgr:create_npc(npc_id, x, y)
    local config = self.npc_configs[npc_id]
    if not config then
        log.error("NPC配置不存在: %d", npc_id)
        return nil
    end
    
    -- 创建NPC实体
    local npc = NPCEntity.new(npc_id, config)
    npc:set_position(x, y)
    self.scene:add_entity(npc)
    self.npcs[npc_id] = npc
    log.info("创建NPC: %s (ID: %d) 位置: (%d, %d)", config.name, npc_id, x, y)
    
    return npc
end

-- 获取NPC
function NPCMgr:get_npc(npc_id)
    return self.npcs[npc_id]
end

-- 移除NPC
function NPCMgr:remove_npc(npc_id)
    local npc = self.npcs[npc_id]
    if npc then
        npc:destroy()
        self.npcs[npc_id] = nil
        log.info("移除NPC: %d", npc_id)
    end
end

-- 动态添加NPC行为
function NPCMgr:add_npc_behavior(npc_id, behavior_name, config)
    local npc = self.npcs[npc_id]
    if not npc then
        return false, "NPC不存在"
    end
    
    local success = npc:add_behavior(behavior_name, config)
    if success then
        log.info("为NPC %d 添加行为: %s", npc_id, behavior_name)
    end
    
    return success
end

-- 动态移除NPC行为
function NPCMgr:remove_npc_behavior(npc_id, behavior_name)
    local npc = self.npcs[npc_id]
    if not npc then
        return false, "NPC不存在"
    end
    
    npc:remove_behavior(behavior_name)
    log.info("移除NPC %d 的行为: %s", npc_id, behavior_name)
    
    return true
end

-- 启用NPC行为
function NPCMgr:enable_npc_behavior(npc_id, behavior_name)
    local npc = self.npcs[npc_id]
    if not npc then
        return false, "NPC不存在"
    end
    
    local success = npc:enable_behavior(behavior_name)
    if success then
        log.info("启用NPC %d 的行为: %s", npc_id, behavior_name)
    end
    
    return success
end

-- 禁用NPC行为
function NPCMgr:disable_npc_behavior(npc_id, behavior_name)
    local npc = self.npcs[npc_id]
    if not npc then
        return false, "NPC不存在"
    end
    
    local success = npc:disable_behavior(behavior_name)
    if success then
        log.info("禁用NPC %d 的行为: %s", npc_id, behavior_name)
    end
    
    return success
end

-- 更新NPC行为配置
function NPCMgr:update_npc_behavior_config(npc_id, behavior_name, new_config)
    local npc = self.npcs[npc_id]
    if not npc then
        return false, "NPC不存在"
    end
    
    local success = npc:update_behavior_config(behavior_name, new_config)
    if success then
        log.info("更新NPC %d 的行为配置: %s", npc_id, behavior_name)
    end
    
    return success
end

-- 批量更新NPC行为配置
function NPCMgr:update_npc_behavior_configs(npc_id, configs)
    local npc = self.npcs[npc_id]
    if not npc then
        return false, "NPC不存在"
    end
    
    npc:update_behavior_configs(configs)
    log.info("批量更新NPC %d 的行为配置", npc_id)
    
    return true
end

-- 获取NPC行为状态
function NPCMgr:get_npc_behavior_status(npc_id)
    local npc = self.npcs[npc_id]
    if not npc then
        return nil
    end
    
    return npc:get_behavior_status()
end

-- 获取所有NPC
function NPCMgr:get_all_npcs()
    return self.npcs
end

-- 清理所有NPC
function NPCMgr:clear_all_npcs()
    for npc_id, npc in pairs(self.npcs) do
        npc:destroy()
    end
    self.npcs = {}
    log.info("清理所有NPC")
end

return NPCMgr 