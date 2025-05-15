# 安全模块 (Security Module)

安全模块提供了一系列工具和服务，用于保护游戏服务端的安全性。它包含加密、令牌管理、攻击防护和数据验证等功能。

## 模块结构

```
script/security/
├── encrypt.lua          - 加密工具库
├── token.lua            - 令牌管理工具
├── attack_protection.lua - 防攻击工具
├── validator.lua        - 数据验证工具
└── README.md            - 文档说明
```

服务：
```
script/service/securityS.lua - 安全服务
```

## 功能概述

1. **加密功能**
   - DES/AES加密解密
   - RSA非对称加密
   - 哈希函数 (SHA1, MD5)
   - HMAC签名验证
   - Base64编解码
   - 随机数生成

2. **令牌管理**
   - 生成安全令牌
   - 验证令牌有效性
   - 令牌自动刷新
   - 令牌失效处理

3. **攻击防护**
   - 请求频率限制(Rate Limiting)
   - IP黑名单
   - SQL注入防护
   - XSS攻击防护

4. **数据验证**
   - 类型验证
   - 格式验证
   - 表单验证
   - 自定义规则验证

## API 参考

### 安全服务 (securityS.lua)

通过skynet.call调用，服务名为 `.security`

#### 令牌管理
- `generate_token(uid, device_id, extra_data)` - 生成令牌
- `verify_token(token_str)` - 验证令牌
- `refresh_token(token_str)` - 刷新令牌
- `invalidate_token(token_str)` - 使令牌失效

#### 数据加密
- `encrypt_data(data, key)` - 加密数据
- `decrypt_data(data, key)` - 解密数据
- `generate_signature(data, key)` - 生成数据签名
- `verify_signature(data, signature, key)` - 验证数据签名

#### 安全防护
- `check_request_safety(params, ip, uid, action)` - 检查请求安全性
- `add_to_blacklist(ip, reason, duration)` - 将IP添加到黑名单

#### 数据验证
- `validate_data(value, rule_name, ...)` - 验证单个数据
- `validate_form(form, schema)` - 验证表单数据

#### 配置管理
- `get_status()` - 获取安全模块状态
- `update_config(config)` - 更新安全配置

### 加密工具 (encrypt.lua)

直接require "security.encrypt"使用

- `des_encrypt(text, key)` - DES加密
- `des_decrypt(text, key)` - DES解密
- `aes_encrypt(text, key, iv)` - AES加密
- `aes_decrypt(text, key, iv)` - AES解密
- `sha1(text)` - SHA1哈希
- `md5(text)` - MD5哈希
- `hmac_sha1(text, key)` - HMAC-SHA1签名
- `base64_encode(text)` - Base64编码
- `base64_decode(text)` - Base64解码
- `random(len)` - 生成指定长度的随机字符串
- `generate_token(uid, timestamp, salt)` - 生成唯一令牌
- `dhexchange(...)` - DH密钥交换
- `dhsecret(...)` - DH密钥计算

### 令牌管理 (token.lua)

直接require "security.token"使用

- `generate(user_id, device_id, extra_data)` - 生成令牌
- `verify(token_str)` - 验证令牌
- `refresh(token_str)` - 刷新令牌
- `invalidate(token_str)` - 使令牌失效
- `cleanup()` - 清理过期令牌
- `config(options)` - 设置配置选项
- `start_cleanup_task(interval)` - 启动定期清理任务

### 攻击防护 (attack_protection.lua)

直接require "security.attack_protection"使用

- `check_rate_limit(ip, uid, action)` - 检查请求频率限制
- `add_to_blacklist(ip, reason, duration)` - 添加IP到黑名单
- `is_blacklisted(ip)` - 检查IP是否在黑名单中
- `check_sql_injection(input)` - 检查SQL注入
- `check_xss(input)` - 检查XSS攻击
- `check_request_safety(params)` - 检查请求参数安全性
- `cleanup()` - 清理过期记录
- `set_request_limit(action, count, window)` - 设置请求限制
- `start_cleanup_task(interval)` - 启动定期清理任务

### 数据验证 (validator.lua)

直接require "security.validator"使用

- **基本类型验证**: `is_string()`, `is_number()`, `is_boolean()`...
- **规则验证**: `is_integer()`, `is_positive()`, `is_in_range()`...
- **长度验证**: `is_empty()`, `has_length()`, `min_length()`, `max_length()`...
- **模式验证**: `is_email()`, `is_url()`, `is_alphanumeric()`...
- **日期时间验证**: `is_date()`, `is_time()`, `is_datetime()`...
- **自定义验证**: `register_rule()`, `validate()`, `validate_all()`, `validate_form()`...

## 使用示例

### 初始化安全服务

在`main.lua`或服务启动脚本中添加：

```lua
-- 启动安全服务
local security = skynet.newservice("securityS")
```

### 生成和验证令牌

```lua
local token_str = skynet.call(".security", "lua", "generate_token", player_id, device_id)
local is_valid, uid, data = skynet.call(".security", "lua", "verify_token", token_str)

if is_valid then
    -- 令牌有效，处理请求
else
    -- 令牌无效，拒绝请求
end
```

### 加密和解密数据

```lua
local encrypted = skynet.call(".security", "lua", "encrypt_data", sensitive_data)
local decrypted = skynet.call(".security", "lua", "decrypt_data", encrypted)
```

### 检查请求安全性

```lua
local is_safe, message = skynet.call(".security", "lua", "check_request_safety", 
    request_params, client_ip, player_id, "login")
    
if not is_safe then
    -- 请求不安全，拒绝处理
    return {code = 403, message = message}
end
```

### 验证表单数据

```lua
local schema = {
    username = {
        required = true,
        rules = {
            {"is_alphanumeric"},
            {"min_length", 3},
            {"max_length", 20}
        },
        message = "用户名必须是3-20个字母或数字"
    },
    email = {
        required = true,
        rules = {{"is_email"}},
        message = "请输入有效的电子邮件地址"
    }
}

local is_valid, errors = skynet.call(".security", "lua", "validate_form", form_data, schema)

if not is_valid then
    -- 表单验证失败，返回错误信息
    return {code = 400, errors = errors}
end
```

## 最佳实践

1. **修改默认密钥**
   - 在生产环境中务必修改默认的令牌密钥。

2. **定期轮换密钥**
   - 建议定期更换加密密钥和令牌密钥，提高安全性。

3. **合理设置频率限制**
   - 根据不同接口的特性设置合适的频率限制，避免影响正常用户体验。

4. **记录安全事件**
   - 对安全相关事件（如尝试SQL注入）进行记录和监控。

5. **安全配置因环境而异**
   - 开发环境可以放宽限制，生产环境应该更严格。

## 注意事项

- 安全模块提供基本的安全防护，对于复杂的攻击场景可能需要更专业的安全解决方案。
- 令牌缓存和IP黑名单会占用内存，长时间运行后应监控内存使用情况。
- 过于严格的安全限制可能影响正常用户体验，需要在安全性和可用性之间找到平衡。 