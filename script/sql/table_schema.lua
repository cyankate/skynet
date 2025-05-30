-- 自动生成的表结构配置
local config = {
    ["private_channel"] = {
        table_name = "private_channel",
        fields = {
            ["last_message_time"] = {
                type = "int",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
            ["channel_id"] = {
                type = "bigint",
                is_required = true,
                is_primary = true,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
            ["player2_id"] = {
                type = "bigint",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
            ["create_time"] = {
                type = "int",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
            ["player1_id"] = {
                type = "bigint",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
        },
        primary_keys = {
            "channel_id",
        },
        indexes = {
            ["idx_players"] = {
                unique = true,
                columns = {
                    "player1_id",
                    "player2_id",
                },
            },
            ["idx_last_msg"] = {
                unique = false,
                columns = {
                    "last_message_time",
                },
            },
        },
        non_primary_fields = {
            ["last_message_time"] = true,
            ["player1_id"] = true,
            ["create_time"] = true,
            ["player2_id"] = true,
        },
    },
    ["player_odb"] = {
        table_name = "player_odb",
        fields = {
            ["player_id"] = {
                type = "int unsigned",
                is_required = true,
                is_primary = true,
                is_auto_increment = false,
                default = "nil",
                comment = "玩家ID",
            },
            ["data"] = {
                type = "text",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "离线玩家数据",
            },
            ["update_time"] = {
                type = "timestamp",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "CURRENT_TIMESTAMP",
                comment = "更新时间",
            },
        },
        primary_keys = {
            "player_id",
        },
        indexes = {
        },
        non_primary_fields = {
            ["data"] = true,
            ["update_time"] = true,
        },
    },
    ["player"] = {
        table_name = "player",
        fields = {
            ["account_key"] = {
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
            ["player_name"] = {
                type = "varchar(20)",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
            ["player_id"] = {
                type = "int unsigned",
                is_required = true,
                is_primary = true,
                is_auto_increment = false,
                default = "nil",
                comment = "玩家ID",
            },
            ["create_time"] = {
                type = "timestamp",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "CURRENT_TIMESTAMP",
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
            ["account_key"] = true,
            ["player_name"] = true,
            ["info"] = true,
            ["create_time"] = true,
            ["update_time"] = true,
        },
    },
    ["bag"] = {
        table_name = "bag",
        fields = {
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
            ["idx"] = {
                type = "varchar(32)",
                is_required = true,
                is_primary = true,
                is_auto_increment = false,
                default = "nil",
                comment = "子索引",
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
    ["player_private"] = {
        table_name = "player_private",
        fields = {
            ["data"] = {
                type = "text",
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
            ["last_login_ip"] = {
                type = "varchar(16)",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "最后登录IP",
            },
            ["register_time"] = {
                type = "datetime",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "注册时间",
            },
            ["device_id"] = {
                type = "varchar(32)",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "设备ID",
            },
            ["register_ip"] = {
                type = "varchar(16)",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "注册IP",
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
            ["device_id"] = true,
            ["register_time"] = true,
            ["register_ip"] = true,
            ["last_login_time"] = true,
            ["players"] = true,
            ["account_id"] = true,
        },
    },
    ["channel"] = {
        table_name = "channel",
        fields = {
            ["update_time"] = {
                type = "int",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
            ["channel_id"] = {
                type = "int",
                is_required = true,
                is_primary = true,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
            ["messages"] = {
                type = "text",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "",
            },
        },
        primary_keys = {
            "channel_id",
        },
        indexes = {
        },
        non_primary_fields = {
            ["update_time"] = true,
            ["messages"] = true,
        },
    },
    ["mail"] = {
        table_name = "mail",
        fields = {
            ["expire_time"] = {
                type = "int",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "过期时间",
            },
            ["attachments"] = {
                type = "text",
                is_required = false,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "附件JSON格式",
            },
            ["mail_type"] = {
                type = "tinyint",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "邮件类型:1=系统邮件,2=玩家邮件,3=公会邮件,4=系统奖励邮件",
            },
            ["receiver_id"] = {
                type = "bigint",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "接收者ID",
            },
            ["id"] = {
                type = "bigint",
                is_required = true,
                is_primary = true,
                is_auto_increment = true,
                default = "nil",
                comment = "邮件ID",
            },
            ["status"] = {
                type = "tinyint",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "0",
                comment = "邮件状态:0=未读,1=已读,2=已删除",
            },
            ["sender_id"] = {
                type = "bigint",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "0",
                comment = "发送者ID,0表示系统邮件",
            },
            ["attachments_claimed"] = {
                type = "tinyint",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "0",
                comment = "附件是否已领取:0=未领取,1=已领取",
            },
            ["create_time"] = {
                type = "int",
                is_required = true,
                is_primary = false,
                is_auto_increment = false,
                default = "nil",
                comment = "创建时间",
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
            ["expire_time"] = true,
            ["attachments"] = true,
            ["mail_type"] = true,
            ["receiver_id"] = true,
            ["status"] = true,
            ["sender_id"] = true,
            ["attachments_claimed"] = true,
            ["create_time"] = true,
            ["title"] = true,
            ["content"] = true,
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
}
return config
