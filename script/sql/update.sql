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

