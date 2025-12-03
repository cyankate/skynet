# C# 前端项目中 Lua 业务层发送协议消息指南

## 架构概述

```
C# 层（网络、sproto 打包/解包）
    ↑↓
Lua 层（业务逻辑）
    ↑↓
Skynet 服务器
```

在 C# 前端项目中：
- **C# 层**：负责网络连接、sproto 协议打包/解包、消息收发
- **Lua 层**：负责业务逻辑，通过调用 C# 接口发送消息
- **数据传递**：使用 LuaTable 直接传递，性能更好

---

## 一、接口设计概述

C# 层需要暴露以下接口给 Lua：

- `SendRequest(protocolName, args, callback)` - 发送请求（带回调）
- `SendRequestNoCallback(protocolName, args)` - 发送请求（不带回调）
- `RegisterMessageHandler(messageName, handler)` - 注册消息处理器
- `Connect(host, port)` - 连接服务器
- `Disconnect()` - 断开连接

所有接口使用 `LuaTable` 作为参数和返回值，C# 层负责与 `Dictionary<string, object>` 的转换。

---

## 二、完整实现代码

### 1. C# 层实现

```csharp
// NetworkManager.cs
using System;
using System.Collections.Generic;
using System.Collections;
using UnityEngine;
using XLua;

public class NetworkManager : MonoBehaviour
{
    // ... 之前的 NetworkManager 实现代码 ...
    
    // 暴露给 Lua 的静态接口
    [LuaCallCSharp]
    public static class LuaAPI
    {
        // 发送请求（LuaTable 方式）
        public static uint SendRequest(string protocolName, LuaTable args, LuaFunction callback)
        {
            try
            {
                // 将 LuaTable 转换为 Dictionary
                Dictionary<string, object> argsDict = ConvertLuaTableToDict(args);
                
                // 发送请求
                return Instance.SendRequest(protocolName, argsDict, (response) => {
                    // 在主线程调用 Lua 回调
                    UnityMainThreadDispatcher.Instance.Enqueue(() => {
                        if (callback != null)
                        {
                            // 将响应转换为 LuaTable
                            LuaTable responseTable = ConvertDictToLuaTable(response);
                            callback.Call(responseTable);
                            callback.Dispose();  // 释放 LuaFunction
                        }
                    });
                });
            }
            catch (Exception e)
            {
                Debug.LogError($"SendRequest error: {e.Message}");
                return 0;
            }
        }
        
        // 发送请求（不带回调）
        public static uint SendRequestNoCallback(string protocolName, LuaTable args)
        {
            return SendRequest(protocolName, args, null);
        }
        
        // 注册消息处理器
        public static void RegisterMessageHandler(string messageName, LuaFunction handler)
        {
            Instance.RegisterMessageHandler(messageName, (data) => {
                // 在主线程调用 Lua 处理器
                UnityMainThreadDispatcher.Instance.Enqueue(() => {
                    LuaTable dataTable = ConvertDictToLuaTable(data);
                    handler.Call(dataTable);
                });
            });
        }
        
        // 连接服务器
        public static void Connect(string host, int port)
        {
            Instance.Connect(host, port);
        }
        
        // 断开连接
        public static void Disconnect()
        {
            Instance.Disconnect();
        }
        
        // LuaTable 转 Dictionary（支持嵌套和数组）
        private static Dictionary<string, object> ConvertLuaTableToDict(LuaTable table)
        {
            Dictionary<string, object> dict = new Dictionary<string, object>();
            
            if (table == null)
            {
                return dict;
            }
            
            // 遍历 LuaTable 的键值对
            table.Get<string, object>((key, value) => {
                if (value is LuaTable nestedTable)
                {
                    // 检查是否是数组（所有键都是数字）
                    bool isArray = true;
                    int maxIndex = 0;
                    nestedTable.Get<int, object>((index, item) => {
                        if (index > maxIndex) maxIndex = index;
                    });
                    
                    if (isArray && maxIndex > 0)
                    {
                        // 作为数组处理
                        List<object> list = new List<object>();
                        for (int i = 1; i <= maxIndex; i++)
                        {
                            object item = nestedTable.Get<int, object>(i);
                            if (item is LuaTable itemTable)
                            {
                                list.Add(ConvertLuaTableToDict(itemTable));
                            }
                            else
                            {
                                list.Add(item);
                            }
                        }
                        dict[key] = list;
                    }
                    else
                    {
                        // 作为字典处理
                        dict[key] = ConvertLuaTableToDict(nestedTable);
                    }
                }
                else
                {
                    dict[key] = value;
                }
            });
            
            return dict;
        }
        
        // Dictionary 转 LuaTable（支持嵌套和数组）
        private static LuaTable ConvertDictToLuaTable(Dictionary<string, object> dict)
        {
            if (dict == null)
            {
                return null;
            }
            
            // 获取 LuaEnv
            LuaEnv luaEnv = XLuaManager.Instance.GetLuaEnv();
            LuaTable table = luaEnv.NewTable();
            
            foreach (var kvp in dict)
            {
                object value = kvp.Value;
                
                if (value is Dictionary<string, object> nestedDict)
                {
                    table.Set(kvp.Key, ConvertDictToLuaTable(nestedDict));
                }
                else if (value is List<object> list)
                {
                    // 数组转 LuaTable
                    LuaTable arrayTable = luaEnv.NewTable();
                    for (int i = 0; i < list.Count; i++)
                    {
                        object item = list[i];
                        if (item is Dictionary<string, object> itemDict)
                        {
                            arrayTable.Set(i + 1, ConvertDictToLuaTable(itemDict));  // Lua 数组从1开始
                        }
                        else
                        {
                            arrayTable.Set(i + 1, item);
                        }
                    }
                    table.Set(kvp.Key, arrayTable);
                }
                else
                {
                    table.Set(kvp.Key, value);
                }
            }
            
            return table;
        }
    }
}
```

### 2. Lua 层封装

```lua
-- network.lua
local network = {}

-- C# 接口引用
local NetworkLuaAPI = CS.NetworkManager.LuaAPI

-- 发送请求（带回调）
-- args: LuaTable，直接传递
-- callback: function(response_table) - response_table 是 LuaTable
function network.send_request(protocol_name, args, callback)
    return NetworkLuaAPI.SendRequest(protocol_name, args, function(response)
        if callback then
            callback(response)  -- response 已经是 LuaTable，直接使用
        end
    end)
end

-- 发送请求（不带回调）
function network.send_request_no_callback(protocol_name, args)
    return NetworkLuaAPI.SendRequestNoCallback(protocol_name, args)
end

-- 注册消息处理器
-- handler: function(data_table) - data_table 是 LuaTable
function network.register_handler(message_name, handler)
    NetworkLuaAPI.RegisterMessageHandler(message_name, function(data)
        handler(data)  -- data 已经是 LuaTable，直接使用
    end)
end

-- 连接服务器
function network.connect(host, port)
    NetworkLuaAPI.Connect(host, port)
end

-- 断开连接
function network.disconnect()
    NetworkLuaAPI.Disconnect()
end

return network
```

### 3. 业务层使用示例

```lua
-- game_logic.lua
local network = require "network"

local game_logic = {}

-- 登录
function game_logic.login(account_id, callback)
    network.send_request("login", {
        account_id = account_id
    }, function(response)
        if response.success then
            print("登录成功！玩家ID:", response.player_id)
            -- 保存玩家数据
            PlayerData.player_id = response.player_id
            PlayerData.player_name = response.player_name
        else
            print("登录失败:", response.reason)
        end
        
        if callback then
            callback(response)
        end
    end)
end

-- 发送聊天消息
function game_logic.send_chat(channel_id, content)
    network.send_request_no_callback("send_channel_message", {
        channel_id = channel_id,
        content = content
    })
end

-- 获取好友列表
function game_logic.get_friend_list(callback)
    network.send_request("get_friend_list", {}, function(response)
        if response and response.friends then
            for i = 1, #response.friends do
                local friend = response.friends[i]
                print(string.format("好友 %d: %s (ID: %s)", 
                    i, friend.name, friend.player_id))
            end
            if callback then
                callback(response.friends)
            end
        end
    end)
end

return game_logic
```

---

## 三、完整工作流程

```
1. Lua 业务层调用
   game_logic.login("test123")

2. Lua network 模块封装
   network.send_request("login", {account_id="test123"}, callback)

3. C# NetworkManager 接收
   NetworkManager.LuaAPI.SendRequest(protocolName, argsTable, callback)
   → ConvertLuaTableToDict(argsTable) 转换为 Dictionary

4. C# 层打包并发送
   sproto 打包 → 网络发送

5. 服务器处理并回复

6. C# 层接收并解析
   网络接收 → sproto 解析 → Dictionary

7. C# 调用 Lua 回调
   ConvertDictToLuaTable(response) → callback.Call(responseTable)

8. Lua 业务层处理
   callback(response_table) → 直接使用 LuaTable → 更新游戏状态
```

---

## 四、LuaTable 使用示例

### 1. 简单数据

```lua
-- 发送登录请求
network.send_request("login", {
    account_id = "test123"
}, function(response)
    -- response 是 LuaTable，直接访问字段
    if response.success then
        print("登录成功！玩家ID:", response.player_id)
        print("玩家名:", response.player_name)
    end
end)
```

### 2. 嵌套结构

```lua
-- 发送复杂数据
network.send_request("update_player_info", {
    player_id = 12345,
    info = {
        name = "玩家A",
        level = 10,
        exp = 1000
    }
}, function(response)
    -- 直接访问嵌套字段
    print("更新结果:", response.success)
end)
```

### 3. 数组数据

```lua
-- 获取好友列表
network.send_request("get_friend_list", {}, function(response)
    -- response.friends 是 LuaTable 数组
    if response.friends then
        for i = 1, #response.friends do
            local friend = response.friends[i]  -- 直接访问数组元素
            print(string.format("好友 %d: %s (ID: %s)", 
                i, friend.name, friend.player_id))
        end
    end
end)
```

### 4. 服务器推送消息

```lua
-- 注册聊天消息处理器
network.register_handler("chat_message", function(data)
    -- data 是 LuaTable，直接访问
    print(string.format("[%s] %s: %s", 
        data.channel_name, 
        data.sender_name, 
        data.content))
end)
```

---

## 五、关键要点和注意事项

### 1. 数据转换

**使用 LuaTable 方式**：
- 性能更好，无需 JSON 序列化/反序列化
- 直接传递，减少内存拷贝
- 支持嵌套结构和数组

**类型转换实现**：
- **Lua → C#**：`ConvertLuaTableToDict` 处理嵌套和数组
- **C# → Lua**：`ConvertDictToLuaTable` 处理嵌套和数组

### 2. 数组处理

Lua 数组从 1 开始，C# 数组从 0 开始，转换时需要注意：
```csharp
// C# → Lua
arrayTable.Set(i + 1, item);  // Lua 数组索引从1开始

// Lua → C#
for (int i = 1; i <= maxIndex; i++)  // 从1开始遍历
```

### 3. 线程安全

- C# 的网络接收在后台线程
- Lua 回调必须在主线程执行
- 使用 `UnityMainThreadDispatcher` 确保线程安全

### 4. 内存管理

- 及时释放 `LuaFunction`（xlua）
- LuaTable 由 Lua 的 GC 管理，不需要手动释放
- 避免在回调中持有 C# 对象引用

### 5. 错误处理

```lua
-- 在 Lua 层添加错误处理
function network.send_request_safe(protocol_name, args, callback)
    local ok, err = pcall(function()
        network.send_request(protocol_name, args, callback)
    end)
    
    if not ok then
        print("Send request error:", err)
    end
end
```

---

## 六、总结

C# 前端项目中 Lua 业务层发送消息的核心：

1. **C# 层暴露接口**：通过 xlua/tolua 暴露网络接口给 Lua，使用 LuaTable 作为参数
2. **类型转换**：实现 `ConvertLuaTableToDict` 和 `ConvertDictToLuaTable` 处理数据转换
3. **Lua 层封装**：创建 `network.lua` 模块封装 C# 接口，直接传递 LuaTable
4. **业务层调用**：业务逻辑直接调用 `network.send_request()`，传递 LuaTable
5. **线程安全**：确保 Lua 回调在主线程执行

**优势**：
- ✅ 性能更好，无需 JSON 序列化
- ✅ 直接传递，减少内存拷贝
- ✅ 支持嵌套结构和数组
- ✅ Lua 层使用更自然（直接操作 LuaTable）

这样，Lua 业务层可以专注于业务逻辑，直接使用 LuaTable 操作数据，而不需要关心底层的网络和协议细节。

