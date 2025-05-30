#!/bin/bash

# 创建临时MySQL配置文件
CONFIG_FILE="mysql_clear_tables.cnf"
cat > $CONFIG_FILE << EOF
[client]
host=localhost
user=root
password=1234
database=skynet
EOF

# 确保配置文件权限安全
chmod 600 $CONFIG_FILE

# 从table_schema.lua中提取表名
TABLES=$(grep "table_name = " table_schema.lua | cut -d'"' -f2)

# 遍历所有表并清空数据
for TABLE in $TABLES
do
    echo "正在清空表 $TABLE ..."
    mysql --defaults-file=$CONFIG_FILE -e "TRUNCATE TABLE $TABLE;"
    if [ $? -eq 0 ]; then
        echo "✓ 表 $TABLE 已清空"
    else
        echo "✗ 清空表 $TABLE 时出错"
    fi
done

# 清理临时配置文件
rm -f $CONFIG_FILE

echo "所有表清理完成!" 

echo "正在清除redis缓存..."
redis-cli FLUSHALL
echo "redis缓存清理完成"
