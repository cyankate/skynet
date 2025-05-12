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
  UNIQUE KEY `uk_name` (`name`),
  KEY `idx_leader_id` (`leader_id`),
  KEY `idx_create_time` (`create_time`)
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