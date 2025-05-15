-- 自动生成的表结构配置
local config = {
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
    ["account"] = {
        table_name = "account",
        fields = {
            ["device_id"] = {
                type = "varchar(32)",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "设备ID",
            },
            ["account_id"] = {
                type = "int",
                is_required = true,
                is_primary = false,
                is_auto_increment = true,
                default = "nil",
                comment = "",
            },
            ["register_ip"] = {
                type = "varchar(16)",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "注册IP",
            },
            ["players"] = {
                type = "text",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
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
            ["last_login_time"] = {
                type = "datetime",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "最后登录时间",
            },
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
            ["account_id"] = true,
            ["register_ip"] = true,
            ["players"] = true,
            ["register_time"] = true,
            ["device_id"] = true,
            ["last_login_time"] = true,
            ["last_login_ip"] = true,
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
    ["ranking"] = {
        table_name = "ranking",
        fields = {
            ["data"] = {
                type = "text",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "排行榜数据",
            },
            ["name"] = {
                type = "varchar(32)",
                is_required = true,
                is_primary = true,
                is_auto_increment = false,
                default = "nil",
                comment = "排行榜名称",
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
            ["create_time"] = {
                type = "timestamp",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "CURRENT_TIMESTAMP",
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
            ["account_key"] = {
                type = "varchar(20)",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
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
            ["player_name"] = true,
            ["info"] = true,
            ["update_time"] = true,
            ["create_time"] = true,
            ["account_key"] = true,
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
            "idx",
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
            ["status"] = {
                type = "tinyint",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "0",
                comment = "邮件状态:0=未读,1=已读,2=已删除",
            },
            ["title"] = {
                type = "varchar(50)",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "邮件标题",
            },
            ["mail_type"] = {
                type = "tinyint",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "邮件类型:1=系统邮件,2=玩家邮件,3=公会邮件,4=系统奖励邮件",
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
            ["attachments"] = {
                type = "text",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "附件JSON格式",
            },
            ["attachments_claimed"] = {
                type = "tinyint",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "0",
                comment = "附件是否已领取:0=未领取,1=已领取",
            },
        },
        primary_keys = {
            "id",
        },
        indexes = {
            ["idx_receiver_id"] = {
                unique = false,
                columns = {
                    "receiver_id",
                },
            },
            ["idx_create_time"] = {
                unique = false,
                columns = {
                    "create_time",
                },
            },
            ["idx_expire_time"] = {
                unique = false,
                columns = {
                    "expire_time",
                },
            },
        },
        non_primary_fields = {
            ["sender_id"] = true,
            ["expire_time"] = true,
            ["status"] = true,
            ["title"] = true,
            ["mail_type"] = true,
            ["create_time"] = true,
            ["content"] = true,
            ["receiver_id"] = true,
            ["attachments"] = true,
            ["attachments_claimed"] = true,
        },
    },
}
return config
