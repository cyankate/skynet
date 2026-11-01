-- 增量更新 SQL（按时间顺序追加）
-- 约定：
-- 1) all.sql 只用于全量初始化（新库/重建库）
-- 2) update.sql 只用于已上线库的增量变更（ALTER/CREATE INDEX/补表等）
-- 3) 每次变更新增一段，不要改历史段落，保证可追溯
-- 4) 版本段格式使用 [#N]，N 从 1 递增
-- 5) [#N] 到下一个 [#N+1] 之间的 SQL 都视为版本 N 的迁移内容

[#1]
-- 全局数据表
CREATE TABLE IF NOT EXISTS `global_data` (
    `name` varchar(64) NOT NULL COMMENT '全局模块名',
    `data` text COMMENT '全局数据',
    `update_time` int NOT NULL COMMENT '更新时间',
    PRIMARY KEY (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='全局数据表';

[#2]
-- 玩家日/周周期数据表
CREATE TABLE IF NOT EXISTS `player_day` (
    `player_id` int NOT NULL COMMENT '玩家ID',
    `data` text COMMENT '日周期数据',
    PRIMARY KEY (`player_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='玩家日周期数据表';

CREATE TABLE IF NOT EXISTS `player_week` (
    `player_id` int NOT NULL COMMENT '玩家ID',
    `data` text COMMENT '周周期数据',
    PRIMARY KEY (`player_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='玩家周周期数据表';

[#3]
-- 条件进度 / 任务数据
CREATE TABLE IF NOT EXISTS `condition` (
    `player_id` int NOT NULL COMMENT '玩家ID',
    `data` text COMMENT '条件进度数据',
    PRIMARY KEY (`player_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='玩家条件进度表';

CREATE TABLE IF NOT EXISTS `task` (
    `player_id` int NOT NULL COMMENT '玩家ID',
    `data` text COMMENT '任务数据',
    PRIMARY KEY (`player_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='玩家任务数据表';

[#4]
-- condition 为 MySQL 保留字，改用 player_condition
CREATE TABLE IF NOT EXISTS `player_condition` (
    `player_id` int NOT NULL COMMENT '玩家ID',
    `data` text COMMENT '条件进度数据',
    PRIMARY KEY (`player_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='玩家条件进度表';

DROP TABLE IF EXISTS `condition`;


[#5]
-- 操作日志表（幂等 / 关键提交）
CREATE TABLE IF NOT EXISTS `op_log` (
    `op_id` varchar(128) NOT NULL COMMENT '操作ID',
    `status` tinyint NOT NULL DEFAULT '1' COMMENT '状态:1=完成',
    `result` text COMMENT '操作结果',
    `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
    PRIMARY KEY (`op_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='操作日志表';

[#6]
-- 交易行订单与托管表
CREATE TABLE IF NOT EXISTS `trade_order` (
    `order_id` varchar(64) NOT NULL COMMENT '订单ID',
    `seller_id` int NOT NULL COMMENT '卖家',
    `buyer_id` int NOT NULL DEFAULT '0' COMMENT '买家',
    `item_id` int NOT NULL COMMENT '物品ID',
    `item_count` int NOT NULL COMMENT '数量',
    `price` int NOT NULL COMMENT '价格',
    `currency_item_id` int NOT NULL DEFAULT '801' COMMENT '货币物品ID',
    `status` tinyint NOT NULL DEFAULT '1' COMMENT '1=在售,2=已购买,3=已结算,4=已取消,5=补偿中',
    `create_time` int NOT NULL COMMENT '创建时间',
    `update_time` int NOT NULL COMMENT '更新时间',
    `expire_time` int NOT NULL COMMENT '过期时间',
    `version` int NOT NULL DEFAULT '1' COMMENT '版本',
    PRIMARY KEY (`order_id`),
    KEY `idx_seller` (`seller_id`),
    KEY `idx_status` (`status`),
    KEY `idx_expire` (`expire_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='交易行订单表';

CREATE TABLE IF NOT EXISTS `trade_escrow` (
    `order_id` varchar(64) NOT NULL COMMENT '订单ID',
    `seller_id` int NOT NULL COMMENT '卖家',
    `item_id` int NOT NULL COMMENT '物品ID',
    `item_count` int NOT NULL COMMENT '数量',
    `status` tinyint NOT NULL DEFAULT '0' COMMENT '0=托管中,1=已退回,2=已结算',
    `create_time` int NOT NULL COMMENT '创建时间',
    `update_time` int NOT NULL COMMENT '更新时间',
    PRIMARY KEY (`order_id`),
    KEY `idx_seller` (`seller_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='交易行托管表';

[#7]
-- 可靠投递 outbox（status=2 即死信）
CREATE TABLE IF NOT EXISTS `op_outbox` (
    `outbox_id` varchar(128) NOT NULL COMMENT '投递ID',
    `target_type` varchar(16) NOT NULL DEFAULT 'agent' COMMENT '目标类型:agent/service',
    `target_id` varchar(64) NOT NULL COMMENT '目标ID:玩家ID或服务名',
    `method` varchar(64) NOT NULL COMMENT '目标方法',
    `payload` text COMMENT '参数',
    `status` tinyint NOT NULL DEFAULT '0' COMMENT '0=待投递,1=完成,2=死信',
    `retries` int NOT NULL DEFAULT '0' COMMENT '重试次数',
    `next_retry_at` int NOT NULL DEFAULT '0' COMMENT '下次重试时间',
    `last_error` varchar(255) DEFAULT '' COMMENT '最后错误',
    `create_time` int NOT NULL COMMENT '创建时间',
    `update_time` int NOT NULL COMMENT '更新时间',
    PRIMARY KEY (`outbox_id`),
    KEY `idx_status_retry` (`status`, `next_retry_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='可靠投递 outbox';
