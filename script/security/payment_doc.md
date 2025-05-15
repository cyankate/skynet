# 支付模块文档

## 概述

支付模块是游戏服务器的核心功能之一，提供安全、稳定、可扩展的支付服务。本模块集成了多种支付渠道，支持订单创建、支付验证、支付通知处理、订单查询等功能，并内置了风控机制，确保支付安全。

## 目录结构

```
script/
├── security/
│   ├── payment.lua             - 支付安全工具库
│   └── encrypt.lua             - 加密工具库(包含支付签名验签功能)
├── service/
│   └── paymentS.lua            - 支付服务
├── sql/
│   ├── payment.sql             - 支付表结构定义
│   └── all.sql                 - 包含支付表在内的所有表定义
└── define/
    └── product_config.lua      - 商品配置
```

## 数据库结构

支付模块使用两个主要表：

1. **payment** - 支付记录表
   - 记录所有支付交易信息，包括订单状态、金额、支付时间等
   
2. **payment_log** - 支付日志表
   - 记录支付状态变更，便于问题排查和审计

详细表结构见 `script/sql/payment.sql`

## 核心功能

### 1. 订单创建和支付
- 支持创建新订单
- 生成不同渠道的支付参数
- 支持多种支付渠道(支付宝、微信、App Store等)
- 生成支付令牌，提供安全验证

### 2. 支付通知处理
- 验证支付回调通知
- 处理支付状态更新
- 发放商品

### 3. 订单查询
- 查询单个订单详情
- 查询玩家订单列表
- 支持按状态、时间等条件筛选

### 4. 风控系统
- 账号支付限额
- IP限额控制
- 设备ID限额
- 支付频率限制
- 异常交易识别

### 5. 安全机制
- 支付签名验证
- 令牌安全验证
- 防重复支付
- 敏感信息加密

## 支付流程

1. **创建订单**
   - 客户端请求创建订单
   - 服务端验证参数，检查风控规则
   - 生成订单记录，返回支付参数

2. **发起支付**
   - 客户端调用第三方支付SDK
   - 用户完成支付操作

3. **接收支付通知**
   - 第三方支付平台回调服务端通知接口
   - 服务端验证通知合法性
   - 更新订单状态

4. **发放商品**
   - 支付成功后，发放对应商品
   - 更新玩家数据
   - 返回支付结果给客户端

## 支付服务API

### 创建订单
```lua
-- 请求创建订单
local result = skynet.call(".payment", "lua", "create_order", 
    player_id,      -- 玩家ID
    account_id,     -- 账号ID
    product_id,     -- 商品ID
    channel,        -- 支付渠道
    device_id,      -- 设备ID
    ip_address,     -- IP地址
    extra_data      -- 额外数据(可选)
)
```

### 处理支付通知
```lua
-- 处理支付通知
local result = skynet.call(".payment", "lua", "handle_notify",
    channel,        -- 支付渠道
    notify_data     -- 通知数据
)
```

### 查询订单
```lua
-- 查询订单详情
local result = skynet.call(".payment", "lua", "query_order", order_id)

-- 查询玩家订单列表
local result = skynet.call(".payment", "lua", "query_player_orders",
    player_id,      -- 玩家ID
    status,         -- 状态(可选)
    limit,          -- 返回数量限制(可选)
    offset          -- 偏移量(可选)
)
```

### 商品管理
```lua
-- 获取商品列表
local result = skynet.call(".payment", "lua", "get_products")

-- 更新商品配置
local result = skynet.call(".payment", "lua", "update_products", new_products)
```

### 手动发放商品
```lua
-- 手动发放商品(管理员功能)
local result = skynet.call(".payment", "lua", "manual_deliver", 
    order_id,       -- 订单ID
    admin_id        -- 管理员ID(可选)
)
```

## 支付安全工具API

支付安全模块(`security.payment`)提供以下功能：

### 签名与验证
```lua
-- 生成支付签名
local sign = payment.sign(params, channel)

-- 验证支付签名
local is_valid = payment.verify_sign(params, channel, signature)

-- 验证支付通知
local is_valid = payment.verify_notify(channel, notify_data)
```

### 令牌管理
```lua
-- 生成支付令牌
local token = payment.generate_token(order_info)

-- 验证支付令牌
local is_valid, token_data = payment.verify_token(token)
```

### 风控检查
```lua
-- 风控检查
local is_safe, message = payment.risk_check(account_id, player_id, ip, device_id, amount)
```

## 支付渠道配置

支付渠道配置保存在 `payment_security` 模块中，可通过以下方式获取和更新：

```lua
-- 获取渠道配置
local config = payment.get_channel_config(channel)

-- 更新配置
payment.update_config(config)
```

## 错误码定义

| 错误码 | 描述 |
|-------|------|
| 0 | 成功 |
| 1 | 参数不完整 |
| 2 | 商品不存在 |
| 3 | 风控检查不通过 |
| 4 | 订单创建失败 |
| 5 | 更新订单状态失败 |
| -1 | 未知命令 |

## 安全建议

1. **密钥保护**
   - 所有支付密钥应妥善保存，不得硬编码
   - 生产环境应使用加密存储的密钥

2. **通知验证**
   - 必须验证所有支付通知的签名
   - 使用HTTPS确保传输安全

3. **订单追踪**
   - 为每个订单生成唯一订单号
   - 记录完整的支付日志

4. **风控配置**
   - 根据游戏特点设置合理的限额
   - 定期审查异常支付行为

5. **日志审计**
   - 保留完整的支付日志
   - 定期审计重要支付操作

## 常见问题

1. **支付回调没有触发？**
   - 检查回调URL是否配置正确
   - 检查服务器是否能正常接收外部请求
   - 查看第三方支付平台通知日志

2. **订单创建成功但支付失败？**
   - 验证支付参数是否正确
   - 检查签名生成算法
   - 确认商品价格配置

3. **如何处理掉单情况？**
   - 使用订单查询接口主动查询订单状态
   - 建立订单对账机制
   - 提供手动补单功能

4. **支付通知重复接收怎么处理？**
   - 实现幂等性处理，确保同一订单不会重复发货
   - 在数据库层面使用事务保证操作原子性