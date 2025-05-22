#!/bin/bash

# 创建证书目录
mkdir cert

# 生成CA私钥
openssl genrsa -out cert/ca.key 2048

# 生成CA证书
openssl req -new -x509 -days 3650 -key cert/ca.key -out cert/ca.crt -subj "/C=CN/ST=Beijing/L=Beijing/O=Bruno/CN=Bruno GameServer CA"

# 生成服务器私钥
openssl genrsa -out cert/server.key 2048

# 创建SAN配置文件
cat > cert/san.cnf << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = CN
ST = Beijing
L = Beijing
O = Bruno
CN = 8.138.80.18

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
IP.1 = 8.138.80.18
DNS.1 = 8.138.80.18
EOF

# 生成服务器证书签名请求（包含SAN扩展）
openssl req -new -key cert/server.key -out cert/server.csr -config cert/san.cnf

# 使用CA证书签名服务器证书（包含SAN扩展）
openssl x509 -req -days 3650 -in cert/server.csr -CA cert/ca.crt -CAkey cert/ca.key -CAcreateserial -out cert/server.crt -extensions v3_req -extfile cert/san.cnf

# 删除临时文件
rm cert/server.csr cert/ca.srl cert/san.cnf

# 设置权限
chmod 600 cert/*.key
chmod 644 cert/*.crt

echo "证书生成完成！" 
