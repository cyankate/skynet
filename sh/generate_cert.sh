#!/bin/bash

# 创建证书目录
mkdir cert

# 生成CA私钥
openssl genrsa -out cert/ca.key 2048

# 生成CA证书
openssl req -new -x509 -days 3650 -key cert/ca.key -out cert/ca.crt -subj "/C=CN/ST=Beijing/L=Beijing/O=GameServer/CN=GameServer CA"

# 生成服务器私钥
openssl genrsa -out cert/server.key 2048

# 生成服务器证书签名请求
openssl req -new -key cert/server.key -out cert/server.csr -subj "/C=CN/ST=Beijing/L=Beijing/O=GameServer/CN=8.138.80.18"

# 使用CA证书签名服务器证书
openssl x509 -req -days 3650 -in cert/server.csr -CA cert/ca.crt -CAkey cert/ca.key -CAcreateserial -out cert/server.crt

# 删除临时文件
rm cert/server.csr cert/ca.srl

# 设置权限
chmod 600 cert/*.key
chmod 644 cert/*.crt

echo "证书生成完成！" 
