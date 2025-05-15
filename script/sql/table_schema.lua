-- 自动生成的表结构配置
local config = {
    ["account"] = {
        table_name = "account",
        fields = {
            ["last_login_ip"] = {
                type = "varchar(16)",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "最后登录IP",
            },
            ["account_key"] = {
                type = "varchar(20)",
                is_required = true,
                is_primary = true,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
            ["last_login_time"] = {
                type = "datetime",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "最后登录时间",
            },
            ["players"] = {
                type = "text",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
            ["account_id"] = {
                type = "int",
                is_required = true,
                is_primary = false,
                is_auto_increment = true,
                default = "nil",
                comment = "",
            },
            ["register_time"] = {
                type = "datetime",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "注册时间",
            },
            ["register_ip"] = {
                type = "varchar(16)",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "注册IP",
            },
            ["device_id"] = {
                type = "varchar(32)",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "设备ID",
            },
        },
        primary_keys = {
            "account_key",
        },
        indexes = {
            ["uk_account_id"] = {
                unique = true,
                columns = {
                    "account_id",
                },
            },
            ["account_key"] = {
                unique = true,
                columns = {
                    "account_key",
                },
            },
        },
        non_primary_fields = {
            ["last_login_ip"] = true,
            ["last_login_time"] = true,
            ["players"] = true,
            ["account_id"] = true,
            ["register_time"] = true,
            ["register_ip"] = true,
            ["device_id"] = true,
        },
    },
    ["player"] = {
        table_name = "player",
        fields = {
            ["player_name"] = {
                type = "varchar(20)",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
            ["info"] = {
                type = "text",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
            ["update_time"] = {
                type = "timestamp",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "CURRENT_TIMESTAMP",
                comment = "",
            },
            ["account_key"] = {
                type = "varchar(20)",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
            ["player_id"] = {
                type = "int",
                is_required = true,
                is_primary = true,
                is_auto_increment = true,
                default = "nil",
                comment = "",
            },
            ["create_time"] = {
                type = "timestamp",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "CURRENT_TIMESTAMP",
                comment = "",
            },
        },
        primary_keys = {
            "player_id",
        },
        indexes = {
            ["fk_account_key"] = {
                unique = false,
                columns = {
                    "account_key",
                },
            },
        },
        non_primary_fields = {
            ["create_time"] = true,
            ["info"] = true,
            ["update_time"] = true,
            ["account_key"] = true,
            ["player_name"] = true,
        },
    },
    ["friend"] = {
        table_name = "friend",
        fields = {
            ["data"] = {
                type = "text",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "好友数据",
            },
            ["player_id"] = {
                type = "int",
                is_required = true,
                is_primary = true,
                is_auto_increment = false,
                default = "nil",
                comment = "玩家ID",
            },
        },
        primary_keys = {
            "player_id",
        },
        indexes = {
        },
        non_primary_fields = {
            ["data"] = true,
        },
    },
    ["bag"] = {
        table_name = "bag",
        fields = {
            ["idx"] = {
                type = "varchar(32)",
                is_required = true,
                is_primary = true,
                is_auto_increment = false,
                default = "nil",
                comment = "子索引",
            },
            ["player_id"] = {
                type = "int",
                is_required = true,
                is_primary = true,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
            ["data"] = {
                type = "text",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
        },
        primary_keys = {
            "player_id",
            "idx",
        },
        indexes = {
        },
        non_primary_fields = {
            ["data"] = true,
        },
    },
    ["ranking"] = {
        table_name = "ranking",
        fields = {
            ["name"] = {
                type = "varchar(32)",
                is_required = true,
                is_primary = true,
                is_auto_increment = false,
                default = "nil",
                comment = "排行榜名称",
            },
            ["data"] = {
                type = "text",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "排行榜数据",
            },
        },
        primary_keys = {
            "name",
        },
        indexes = {
        },
        non_primary_fields = {
            ["data"] = true,
        },
    },
    ["base"] = {
        table_name = "base",
        fields = {
            ["data"] = {
                type = "text",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
            ["player_id"] = {
                type = "int",
                is_required = true,
                is_primary = true,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
        },
        primary_keys = {
            "player_id",
        },
        indexes = {
        },
        non_primary_fields = {
            ["data"] = true,
        },
    },
    ["mail"] = {
        table_name = "mail",
        fields = {
            ["mail_type"] = {
                type = "tinyint",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "邮件类型:1=系统邮件,2=玩家邮件,3=公会邮件,4=系统奖励邮件",
            },
            ["title"] = {
                type = "varchar(50)",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "邮件标题",
            },
            ["content"] = {
                type = "varchar(1000)",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "邮件内容",
            },
            ["id"] = {
                type = "bigint",
                is_required = true,
                is_primary = true,
                is_auto_increment = true,
                default = "nil",
                comment = "邮件ID",
            },
            ["sender_id"] = {
                type = "bigint",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "0",
                comment = "发送者ID,0表示系统邮件",
            },
            ["expire_time"] = {
                type = "int",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "过期时间",
            },
            ["create_time"] = {
                type = "int",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "创建时间",
            },
            ["receiver_id"] = {
                type = "bigint",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "接收者ID",
            },
            ["attachments_claimed"] = {
                type = "tinyint",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "0",
                comment = "附件是否已领取:0=未领取,1=已领取",
            },
            ["status"] = {
                type = "tinyint",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "0",
                comment = "邮件状态:0=未读,1=已读,2=已删除",
            },
            ["attachments"] = {
                type = "text",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "附件JSON格式",
            },
        },
        primary_keys = {
            "id",
        },
        indexes = {
            ["idx_expire_time"] = {
                unique = false,
                columns = {
                    "expire_time",
                },
            },
            ["idx_create_time"] = {
                unique = false,
                columns = {
                    "create_time",
                },
            },
            ["idx_receiver_id"] = {
                unique = false,
                columns = {
                    "receiver_id",
                },
            },
        },
        non_primary_fields = {
            ["mail_type"] = true,
            ["title"] = true,
            ["content"] = true,
            ["sender_id"] = true,
            ["expire_time"] = true,
            ["create_time"] = true,
            ["receiver_id"] = true,
            ["attachments_claimed"] = true,
            ["status"] = true,
            ["attachments"] = true,
        },
    },
}
return config
