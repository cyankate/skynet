-- NPC功能配置示例
-- 这个文件展示了如何配置各种类型的NPC功能

local NPC_CONFIG = {
    -- 新手村村长 - 任务NPC
    [1001] = {
        name = "村长",
        interact_range = 50,
        functions = {
            quest = {
                quests = {
                    {
                        id = 1001,
                        name = "新手任务",
                        description = "击败5只野狼",
                        require_level = 1,
                        require_quests = {},  -- 无前置任务
                        conditions = {
                            {type = "kill_monster", monster_id = 1001, count = 5}
                        },
                        rewards = {
                            {type = "exp", amount = 100},
                            {type = "money", amount = 50},
                            {type = "item", item_id = 1001, count = 1}
                        }
                    },
                    {
                        id = 1002,
                        name = "收集材料",
                        description = "收集10个野狼皮",
                        require_level = 2,
                        require_quests = {1001},  -- 需要完成新手任务
                        conditions = {
                            {type = "collect_item", item_id = 2001, count = 10}
                        },
                        rewards = {
                            {type = "exp", amount = 200},
                            {type = "money", amount = 100},
                            {type = "item", item_id = 1002, count = 1}
                        }
                    }
                }
            },
            dialog = {
                default_dialog = "欢迎来到新手村！有什么可以帮助你的吗？",
                dialogs = {
                    {
                        condition = {level = 1},
                        content = "你是新来的冒险者吗？这里有很多任务等着你。"
                    },
                    {
                        condition = {quest = {id = 1001, status = "in_progress"}},
                        content = "野狼就在村子的东边，小心一点。"
                    },
                    {
                        condition = {quest = {id = 1001, status = "completed"}},
                        content = "你已经完成了新手任务，真是个好苗子！"
                    },
                    {
                        condition = {level = 10},
                        content = "你已经是个有经验的冒险者了，可以去主城寻找更多挑战。"
                    }
                }
            }
        }
    },
    
    -- 杂货商 - 商店NPC
    [1002] = {
        name = "杂货商",
        interact_range = 50,
        functions = {
            shop = {
                shop_items = {
                    {id = 1001, name = "生命药水", price = 100, stock = 999, description = "恢复100点生命值"},
                    {id = 1002, name = "魔法药水", price = 120, stock = 999, description = "恢复100点魔法值"},
                    {id = 1003, name = "回城卷轴", price = 50, stock = 999, description = "立即回到主城"},
                    {id = 1004, name = "小面包", price = 20, stock = 999, description = "恢复50点生命值"},
                    {id = 1005, name = "解毒剂", price = 80, stock = 999, description = "解除中毒状态"}
                },
                buy_rate = 1.0,    -- 购买价格倍率
                sell_rate = 0.3,   -- 出售价格倍率（原价的30%）
                max_stock = 999    -- 最大库存
            },
            dialog = {
                default_dialog = "需要什么商品吗？我这里应有尽有！",
                dialogs = {
                    {
                        condition = {level = 1},
                        content = "新手冒险者？我建议你买一些生命药水，野外很危险的。"
                    },
                    {
                        condition = {level = 5},
                        content = "你已经有些经验了，需要更高级的道具吗？"
                    }
                }
            }
        }
    },
    
    -- 传送师 - 传送NPC
    [1003] = {
        name = "传送师",
        interact_range = 50,
        functions = {
            transport = {
                transport_points = {
                    {
                        id = 1,
                        name = "主城",
                        description = "传送到主城",
                        scene_id = 1002,
                        x = 100,
                        y = 100,
                        price = 10,
                        require_level = 1
                    },
                    {
                        id = 2,
                        name = "副本入口",
                        description = "传送到副本入口",
                        scene_id = 2001,
                        x = 50,
                        y = 50,
                        price = 20,
                        require_level = 5
                    },
                    {
                        id = 3,
                        name = "竞技场",
                        description = "传送到竞技场",
                        scene_id = 3001,
                        x = 200,
                        y = 200,
                        price = 15,
                        require_level = 10
                    }
                }
            },
            dialog = {
                default_dialog = "需要传送到哪里？",
                dialogs = {
                    {
                        condition = {level = 1},
                        content = "新手村到主城的传送是免费的，欢迎使用！"
                    }
                }
            }
        }
    },
    
    -- 神秘商人 - 多功能NPC（任务完成后功能变化）
    [1004] = {
        name = "神秘商人",
        interact_range = 50,
        functions = {
            quest = {
                quests = {
                    {
                        id = 1003,
                        name = "寻找宝藏",
                        description = "找到神秘商人丢失的宝藏",
                        require_level = 5,
                        require_quests = {1002},  -- 需要完成收集材料任务
                        conditions = {
                            {type = "collect_item", item_id = 2001, count = 1}
                        },
                        rewards = {
                            {type = "exp", amount = 500},
                            {type = "money", amount = 1000},
                            {type = "item", item_id = 3001, count = 1}
                        }
                    }
                }
            },
            shop = {
                shop_items = {
                    {id = 2001, name = "神秘宝箱", price = 1000, stock = 1, description = "可能开出稀有物品"},
                    {id = 2002, name = "高级装备", price = 5000, stock = 10, description = "比普通装备更强"}
                },
                buy_rate = 1.0,
                sell_rate = 0.3
            },
            dialog = {
                default_dialog = "我这里有一些特殊的商品...",
                dialogs = {
                    {
                        condition = {quest = {id = 1003, status = "in_progress"}},
                        content = "我的宝藏就在附近，如果你能找到它，我会给你特别的奖励。"
                    },
                    {
                        condition = {quest = {id = 1003, status = "completed"}},
                        content = "你找到了我的宝藏！现在我可以为你提供更多珍贵的商品了。"
                    }
                }
            }
        }
    },
    
    -- 铁匠 - 修理和强化NPC
    [1005] = {
        name = "铁匠",
        interact_range = 50,
        functions = {
            repair = {
                repair_rate = 0.1,  -- 修理费用为装备价值的10%
                can_repair_all = true,  -- 可以修理所有装备
                repair_quality = 1.0    -- 修理后装备耐久度恢复100%
            },
            enhance = {
                enhance_materials = {
                    {id = 3001, name = "强化石", price = 100, description = "提高强化成功率"},
                    {id = 3002, name = "保护石", price = 200, description = "防止强化失败时装备损坏"},
                    {id = 3003, name = "幸运石", price = 500, description = "大幅提高强化成功率"}
                },
                success_rate = 0.8,     -- 基础成功率80%
                max_enhance_level = 10,  -- 最大强化等级
                enhance_cost = 100       -- 每次强化基础费用
            },
            dialog = {
                default_dialog = "需要修理或强化装备吗？",
                dialogs = {
                    {
                        condition = {level = 1},
                        content = "新手装备不需要强化，等你有了好装备再来找我。"
                    },
                    {
                        condition = {level = 10},
                        content = "强化装备需要强化石，你准备好了吗？"
                    }
                }
            }
        }
    },
    
    -- 仓库管理员 - 仓库NPC
    [1006] = {
        name = "仓库管理员",
        interact_range = 50,
        functions = {
            storage = {
                max_slots = 100,        -- 最大仓库格子数
                expand_cost = 1000,     -- 扩展仓库费用
                slots_per_expand = 10   -- 每次扩展增加的格子数
            },
            dialog = {
                default_dialog = "需要存取物品吗？",
                dialogs = {
                    {
                        condition = {level = 1},
                        content = "新手可以免费使用基础仓库，容量有限。"
                    }
                }
            }
        }
    },
    
    -- 制作师 - 制作NPC
    [1007] = {
        name = "制作师",
        interact_range = 50,
        functions = {
            craft = {
                recipes = {
                    {
                        id = 1,
                        name = "生命药水",
                        description = "制作生命药水",
                        materials = {
                            {item_id = 4001, name = "草药", count = 2},
                            {item_id = 4002, name = "清水", count = 1}
                        },
                        result = {item_id = 1001, name = "生命药水", count = 1},
                        success_rate = 0.9,
                        require_level = 1
                    },
                    {
                        id = 2,
                        name = "铁剑",
                        description = "制作铁剑",
                        materials = {
                            {item_id = 4003, name = "铁锭", count = 3},
                            {item_id = 4004, name = "木材", count = 1}
                        },
                        result = {item_id = 5001, name = "铁剑", count = 1},
                        success_rate = 0.8,
                        require_level = 5
                    }
                }
            },
            dialog = {
                default_dialog = "想要制作什么物品吗？",
                dialogs = {
                    {
                        condition = {level = 1},
                        content = "制作需要材料，你可以从怪物身上获得。"
                    }
                }
            }
        }
    },
    
    -- 任务发布员 - 专门的任务NPC
    [1008] = {
        name = "任务发布员",
        interact_range = 50,
        functions = {
            quest = {
                quests = {
                    {
                        id = 2001,
                        name = "日常任务",
                        description = "击败10只怪物",
                        require_level = 1,
                        conditions = {
                            {type = "kill_monster", monster_id = 0, count = 10}  -- 任意怪物
                        },
                        rewards = {
                            {type = "exp", amount = 50},
                            {type = "money", amount = 25}
                        },
                        is_daily = true,  -- 每日任务
                        reset_time = "00:00"  -- 重置时间
                    },
                    {
                        id = 2002,
                        name = "周常任务",
                        description = "完成5个日常任务",
                        require_level = 1,
                        conditions = {
                            {type = "complete_quest", quest_id = 2001, count = 5}
                        },
                        rewards = {
                            {type = "exp", amount = 500},
                            {type = "money", amount = 200},
                            {type = "item", item_id = 6001, count = 1}
                        },
                        is_weekly = true,  -- 每周任务
                        reset_time = "monday 00:00"  -- 重置时间
                    }
                }
            },
            dialog = {
                default_dialog = "这里有各种任务，完成它们可以获得奖励！",
                dialogs = {
                    {
                        condition = {level = 1},
                        content = "新手建议从日常任务开始，每天都有奖励。"
                    }
                }
            }
        }
    }
}

-- 场景NPC分布配置
local SCENE_NPC_CONFIG = {
    [1001] = {  -- 新手村
        {npc_id = 1001, x = 100, y = 100, name = "村长"},
        {npc_id = 1002, x = 150, y = 100, name = "杂货商"},
        {npc_id = 1003, x = 200, y = 100, name = "传送师"},
        {npc_id = 1004, x = 250, y = 100, name = "神秘商人"},
        {npc_id = 1006, x = 300, y = 100, name = "仓库管理员"},
        {npc_id = 1007, x = 350, y = 100, name = "制作师"},
        {npc_id = 1008, x = 400, y = 100, name = "任务发布员"}
    },
    [1002] = {  -- 主城
        {npc_id = 1002, x = 300, y = 300, name = "杂货商"},
        {npc_id = 1003, x = 350, y = 300, name = "传送师"},
        {npc_id = 1005, x = 400, y = 300, name = "铁匠"},
        {npc_id = 1006, x = 450, y = 300, name = "仓库管理员"},
        {npc_id = 1007, x = 500, y = 300, name = "制作师"},
        {npc_id = 1008, x = 550, y = 300, name = "任务发布员"}
    },
    [1003] = {  -- 副本入口
        {npc_id = 1003, x = 100, y = 100, name = "传送师"},
        {npc_id = 1006, x = 150, y = 100, name = "仓库管理员"}
    }
}

-- 功能切换规则配置
local FUNCTION_SWITCH_RULES = {
    -- 任务完成后的功能切换规则
    quest_completion = {
        [1003] = {  -- 任务1003完成后
            disable_functions = {"quest"},  -- 禁用任务功能
            enable_functions = {},          -- 启用功能（空）
            update_configs = {              -- 更新配置
                shop = {
                    shop_items = {
                        {id = 2001, name = "神秘宝箱", price = 1000, stock = 1},
                        {id = 2002, name = "高级装备", price = 5000, stock = 10},
                        {id = 2003, name = "稀有材料", price = 3000, stock = 5},
                        {id = 2004, name = "特殊道具", price = 8000, stock = 2}
                    },
                    buy_rate = 0.9,  -- 任务完成后有折扣
                    sell_rate = 0.4
                }
            }
        }
    },
    
    -- 时间相关的功能切换规则
    time_based = {
        [1003] = {  -- 传送师
            night_mode = {  -- 夜间模式（20:00-06:00）
                start_hour = 20,
                end_hour = 6,
                disable_functions = {"transport"},
                enable_functions = {},
                dialog_override = "夜间传送服务暂停，请明天再来。"
            }
        }
    },
    
    -- 玩家等级相关的功能切换规则
    level_based = {
        [1005] = {  -- 铁匠
            [10] = {  -- 玩家等级达到10级
                enable_functions = {"enhance"},
                dialog_override = "你已经足够强大了，可以尝试强化装备。"
            }
        }
    }
}

return {
    NPC_CONFIG = NPC_CONFIG,
    SCENE_NPC_CONFIG = SCENE_NPC_CONFIG,
    FUNCTION_SWITCH_RULES = FUNCTION_SWITCH_RULES
} 