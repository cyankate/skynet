CREATE TABLE `mail` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '邮件ID',
  `sender_id` bigint NOT NULL DEFAULT '0' COMMENT '发送者ID,0表示系统邮件',
  `receiver_id` bigint NOT NULL COMMENT '接收者ID',
  `mail_type` tinyint NOT NULL COMMENT '邮件类型:1=系统邮件,2=玩家邮件,3=公会邮件,4=系统奖励邮件',
  `title` varchar(50) NOT NULL COMMENT '邮件标题',
  `content` varchar(1000) NOT NULL COMMENT '邮件内容',
  `attachments` text COMMENT '附件JSON格式',
  `attachments_claimed` tinyint NOT NULL DEFAULT '0' COMMENT '附件是否已领取:0=未领取,1=已领取',
  `status` tinyint NOT NULL DEFAULT '0' COMMENT '邮件状态:0=未读,1=已读,2=已删除',
  `create_time` int NOT NULL COMMENT '创建时间',
  `expire_time` int NOT NULL COMMENT '过期时间',
  PRIMARY KEY (`id`),
  KEY `idx_receiver_id` (`receiver_id`),
  KEY `idx_create_time` (`create_time`),
  KEY `idx_expire_time` (`expire_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='邮件表';

-- 账号表
CREATE TABLE IF NOT EXISTS `account` (
  `account_key` varchar(20) NOT NULL COMMENT '账号标识',
  `account_id` int NOT NULL AUTO_INCREMENT COMMENT '账号ID',
  `players` text COMMENT '玩家列表数据',
  `last_login_ip` varchar(16) DEFAULT NULL COMMENT '最后登录IP',
  `last_login_time` datetime DEFAULT NULL COMMENT '最后登录时间',
  `device_id` varchar(32) DEFAULT NULL COMMENT '设备ID',
  `register_ip` varchar(16) DEFAULT NULL COMMENT '注册IP',
  `register_time` datetime DEFAULT NULL COMMENT '注册时间',
  PRIMARY KEY (`account_key`),
  UNIQUE KEY `account_key` (`account_key`),
  UNIQUE KEY `uk_account_id` (`account_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='账号表';

CREATE TABLE `guild` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '公会ID',
  `name` varchar(32) NOT NULL COMMENT '公会名称',
  `leader_id` bigint NOT NULL COMMENT '会长ID',
  `level` int NOT NULL DEFAULT '1' COMMENT '公会等级',
  `exp` int NOT NULL DEFAULT '0' COMMENT '公会经验',
  `funds` int NOT NULL DEFAULT '0' COMMENT '公会资金',
  `notice` varchar(200) NOT NULL DEFAULT '' COMMENT '公会公告',
  `create_time` int NOT NULL COMMENT '创建时间',
  `members` text NOT NULL COMMENT '成员列表JSON格式',
  `applications` text NOT NULL COMMENT '申请列表JSON格式',
  `join_setting` text NOT NULL COMMENT '加入设置JSON格式',
  `buildings` text NOT NULL COMMENT '公会建筑JSON格式',
  `techs` text NOT NULL COMMENT '公会科技JSON格式',
  `treasury` text NOT NULL COMMENT '公会仓库JSON格式',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_name` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='公会表';

-- 好友表
CREATE TABLE IF NOT EXISTS `friend` (
    `player_id` int(11) NOT NULL COMMENT '玩家ID',
    `data` text NOT NULL COMMENT '好友数据',
    PRIMARY KEY (`player_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='好友表';

-- 排行榜表
CREATE TABLE IF NOT EXISTS `ranking` (
    `name` varchar(32) NOT NULL COMMENT '排行榜名称',
    `data` text COMMENT '排行榜数据',
    PRIMARY KEY (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='排行榜表';

-- 支付表
CREATE TABLE IF NOT EXISTS `payment` (
    `id` bigint NOT NULL AUTO_INCREMENT COMMENT '支付记录ID',
    `order_id` varchar(64) NOT NULL COMMENT '订单ID',
    `player_id` int NOT NULL COMMENT '玩家ID',
    `account_id` int NOT NULL COMMENT '账号ID',
    `product_id` varchar(32) NOT NULL COMMENT '商品ID',
    `amount` decimal(10,2) NOT NULL DEFAULT '0.00' COMMENT '支付金额',
    `currency` varchar(8) NOT NULL DEFAULT 'CNY' COMMENT '货币类型',
    `channel` varchar(16) NOT NULL COMMENT '支付渠道',
    `channel_order_id` varchar(64) DEFAULT NULL COMMENT '渠道订单ID',
    `status` tinyint NOT NULL DEFAULT '0' COMMENT '支付状态:0=创建,1=处理中,2=成功,3=失败,4=退款',
    `create_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    `pay_time` datetime DEFAULT NULL COMMENT '支付时间',
    `ip_address` varchar(16) DEFAULT NULL COMMENT '支付IP',
    `device_id` varchar(32) DEFAULT NULL COMMENT '设备ID',
    `extra_data` text DEFAULT NULL COMMENT '额外数据',
    PRIMARY KEY (`id`),
    UNIQUE KEY `idx_order_id` (`order_id`),
    KEY `idx_player_id` (`player_id`),
    KEY `idx_account_id` (`account_id`),
    KEY `idx_create_time` (`create_time`),
    KEY `idx_channel_order` (`channel`, `channel_order_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='支付表';

-- 支付日志表（可选）
-- 用于记录支付过程中的状态变更，便于问题排查
CREATE TABLE IF NOT EXISTS `payment_log` (
    `id` bigint NOT NULL AUTO_INCREMENT COMMENT '日志ID',
    `order_id` varchar(64) NOT NULL COMMENT '订单ID',
    `status` tinyint NOT NULL COMMENT '状态变更',
    `log_time` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '日志时间',
    `log_content` text NOT NULL COMMENT '日志内容',
    `operator` varchar(32) DEFAULT NULL COMMENT '操作人/系统',
    PRIMARY KEY (`id`),
    KEY `idx_order_id` (`order_id`),
    KEY `idx_log_time` (`log_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='支付日志表'; 

CREATE TABLE channel (
    channel_id INT PRIMARY KEY,
    channel_type TINYINT NOT NULL COMMENT '1:私聊 2:世界 3:公会 4:系统',
    channel_key VARCHAR(32) NOT NULL COMMENT '私聊:player1_id_player2_id, 世界:global, 公会:guild_id',
    data TEXT NOT NULL,
    update_time INT NOT NULL DEFAULT 0 ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_channel_key (channel_key)
);

CREATE TABLE channel (
    channel_id INT PRIMARY KEY,
    data TEXT NOT NULL,
    update_time INT NOT NULL DEFAULT 0 ON UPDATE CURRENT_TIMESTAMP,
);