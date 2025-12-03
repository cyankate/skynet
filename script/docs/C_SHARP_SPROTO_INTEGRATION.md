# C# 前端项目接入 sproto 完整方案

## 架构概述

```
C# 前端 (Unity/其他)  <--sproto-->  Skynet 服务器 (Lua 业务层)
```

## 一、准备工作

### 1. 获取 C# 版本的 sproto 库

**推荐方案：使用已有的 C# sproto 实现**

- **sproto-csharp**: https://github.com/cloudwu/sproto/tree/master/csharp
- 或者使用其他社区维护的 C# sproto 实现

### 2. 生成协议二进制文件

从你的 Lua 协议定义生成 C# 可用的协议二进制文件。

#### 方法1：使用 Lua 脚本生成

创建一个脚本 `script/tools/generate_proto_bin.lua`：

```lua
local sprotoparser = require "sprotoparser"
local proto = require "proto"
local io = require "io"

-- 生成 c2s 协议二进制
local c2s_bin = sprotoparser.parse(proto.c2s)
local c2s_file = io.open("proto/c2s.sproto", "wb")
c2s_file:write(c2s_bin)
c2s_file:close()

-- 生成 s2c 协议二进制
local s2c_bin = sprotoparser.parse(proto.s2c)
local s2c_file = io.open("proto/s2c.sproto", "wb")
s2c_file:write(s2c_bin)
s2c_file:close()

print("Protocol binary files generated successfully!")
print("  - proto/c2s.sproto")
print("  - proto/s2c.sproto")
```

运行：
```bash
lua script/tools/generate_proto_bin.lua
```

#### 方法2：直接从 proto.lua 提取协议文本

也可以直接提取协议文本，让 C# 端自己解析：

```lua
-- script/tools/extract_proto_text.lua
local proto = require "proto"
local io = require "io"

-- 提取 c2s 协议文本（需要手动从 proto.lua 复制）
-- 或者写一个解析器提取 sprotoparser.parse 的参数部分
```

### 3. 将协议文件放到 C# 项目

将生成的 `c2s.sproto` 和 `s2c.sproto` 文件放到 C# 项目的 `Assets/Resources/Proto/` 或类似目录。

---

## 二、C# 端核心代码实现

### 1. 网络管理器 (NetworkManager.cs)

```csharp
using System;
using System.Collections.Generic;
using System.Net.Sockets;
using System.Threading;
using UnityEngine;

public class NetworkManager : MonoBehaviour
{
    private static NetworkManager _instance;
    public static NetworkManager Instance => _instance;

    private TcpClient _tcpClient;
    private NetworkStream _stream;
    private Thread _receiveThread;
    private bool _isConnected = false;
    
    // sproto 相关
    private Sproto.SprotoRpc _rpc;
    private Sproto.Sproto _c2sProto;  // 客户端到服务器协议
    private Sproto.Sproto _s2cProto;  // 服务器到客户端协议
    
    // session 管理
    private uint _sessionCounter = 0;
    private Dictionary<uint, Action<object>> _pendingCallbacks = new Dictionary<uint, Action<object>>();
    
    // 消息处理器
    private Dictionary<string, Action<object>> _messageHandlers = new Dictionary<string, Action<object>>();
    
    private void Awake()
    {
        if (_instance == null)
        {
            _instance = this;
            DontDestroyOnLoad(gameObject);
            InitializeSproto();
        }
        else
        {
            Destroy(gameObject);
        }
    }
    
    // 初始化 sproto
    private void InitializeSproto()
    {
        // 加载协议文件
        TextAsset c2sAsset = Resources.Load<TextAsset>("Proto/c2s");
        TextAsset s2cAsset = Resources.Load<TextAsset>("Proto/s2c");
        
        if (c2sAsset == null || s2cAsset == null)
        {
            Debug.LogError("Protocol files not found!");
            return;
        }
        
        // 创建 sproto 对象
        _c2sProto = new Sproto.Sproto(c2sAsset.bytes);
        _s2cProto = new Sproto.Sproto(s2cAsset.bytes);
        
        // 创建 RPC host（用于接收服务器消息）
        _rpc = _s2cProto.NewRpc();
        
        Debug.Log("Sproto initialized successfully");
    }
    
    // 连接到服务器
    public void Connect(string host, int port)
    {
        try
        {
            _tcpClient = new TcpClient();
            _tcpClient.Connect(host, port);
            _stream = _tcpClient.GetStream();
            _isConnected = true;
            
            // 启动接收线程
            _receiveThread = new Thread(ReceiveLoop);
            _receiveThread.IsBackground = true;
            _receiveThread.Start();
            
            Debug.Log($"Connected to server {host}:{port}");
        }
        catch (Exception e)
        {
            Debug.LogError($"Connection failed: {e.Message}");
        }
    }
    
    // 发送请求（带回调）
    public uint SendRequest(string protocolName, object args, Action<object> callback = null)
    {
        if (!_isConnected || _c2sProto == null)
        {
            Debug.LogError("Not connected or sproto not initialized");
            return 0;
        }
        
        _sessionCounter++;
        uint session = _sessionCounter;
        
        // 保存回调
        if (callback != null)
        {
            _pendingCallbacks[session] = callback;
        }
        
        // 打包请求
        byte[] requestData = _c2sProto.RequestEncode(protocolName, args, session);
        
        // 发送（需要先发送长度，格式：>s2，即大端序的 2 字节长度）
        byte[] lengthBytes = BitConverter.GetBytes((ushort)requestData.Length);
        if (BitConverter.IsLittleEndian)
        {
            Array.Reverse(lengthBytes);
        }
        
        _stream.Write(lengthBytes, 0, 2);
        _stream.Write(requestData, 0, requestData.Length);
        
        Debug.Log($"Sent request: {protocolName}, session: {session}");
        
        return session;
    }
    
    // 接收循环
    private void ReceiveLoop()
    {
        byte[] lengthBuffer = new byte[2];
        List<byte> buffer = new List<byte>();
        
        while (_isConnected && _tcpClient.Connected)
        {
            try
            {
                // 读取长度（2字节）
                int bytesRead = _stream.Read(lengthBuffer, 0, 2);
                if (bytesRead != 2)
                {
                    break;
                }
                
                // 转换长度（大端序）
                if (BitConverter.IsLittleEndian)
                {
                    Array.Reverse(lengthBuffer);
                }
                ushort packetLength = BitConverter.ToUInt16(lengthBuffer, 0);
                
                // 读取数据包
                byte[] packetData = new byte[packetLength];
                int totalRead = 0;
                while (totalRead < packetLength)
                {
                    int read = _stream.Read(packetData, totalRead, packetLength - totalRead);
                    if (read == 0)
                    {
                        break;
                    }
                    totalRead += read;
                }
                
                if (totalRead == packetLength)
                {
                    // 在主线程处理消息
                    UnityMainThreadDispatcher.Instance.Enqueue(() => {
                        ProcessMessage(packetData);
                    });
                }
            }
            catch (Exception e)
            {
                Debug.LogError($"Receive error: {e.Message}");
                break;
            }
        }
        
        _isConnected = false;
        Debug.Log("Disconnected from server");
    }
    
    // 处理接收到的消息
    private void ProcessMessage(byte[] data)
    {
        if (_rpc == null || _s2cProto == null)
        {
            return;
        }
        
        // 使用 RPC host 解析消息
        var result = _rpc.Dispatch(data);
        
        if (result.Type == "REQUEST")
        {
            // 服务器主动推送的消息（如 chat_message, kicked_out 等）
            string messageName = result.ProtocolName;
            object messageData = result.Message;
            
            Debug.Log($"Received server message: {messageName}");
            
            // 调用注册的处理器
            if (_messageHandlers.ContainsKey(messageName))
            {
                _messageHandlers[messageName](messageData);
            }
            else
            {
                Debug.LogWarning($"No handler for message: {messageName}");
            }
        }
        else if (result.Type == "RESPONSE")
        {
            // 响应消息（对应之前发送的请求）
            uint session = result.Session;
            object responseData = result.Message;
            
            Debug.Log($"Received response for session: {session}");
            
            // 查找并调用回调
            if (_pendingCallbacks.ContainsKey(session))
            {
                var callback = _pendingCallbacks[session];
                _pendingCallbacks.Remove(session);
                callback?.Invoke(responseData);
            }
            else
            {
                Debug.LogWarning($"No callback for session: {session}");
            }
        }
    }
    
    // 注册消息处理器（用于服务器推送的消息）
    public void RegisterMessageHandler(string messageName, Action<object> handler)
    {
        _messageHandlers[messageName] = handler;
    }
    
    // 断开连接
    public void Disconnect()
    {
        _isConnected = false;
        _tcpClient?.Close();
        _receiveThread?.Join(1000);
    }
    
    private void OnDestroy()
    {
        Disconnect();
    }
}
```

### 2. Unity 主线程调度器 (UnityMainThreadDispatcher.cs)

用于在接收线程中安全地调用 Unity API：

```csharp
using System;
using System.Collections;
using System.Collections.Generic;
using UnityEngine;

public class UnityMainThreadDispatcher : MonoBehaviour
{
    private static UnityMainThreadDispatcher _instance;
    public static UnityMainThreadDispatcher Instance
    {
        get
        {
            if (_instance == null)
            {
                GameObject go = new GameObject("UnityMainThreadDispatcher");
                _instance = go.AddComponent<UnityMainThreadDispatcher>();
                DontDestroyOnLoad(go);
            }
            return _instance;
        }
    }
    
    private Queue<Action> _actionQueue = new Queue<Action>();
    private object _lockObject = new object();
    
    private void Update()
    {
        lock (_lockObject)
        {
            while (_actionQueue.Count > 0)
            {
                _actionQueue.Dequeue()?.Invoke();
            }
        }
    }
    
    public void Enqueue(Action action)
    {
        lock (_lockObject)
        {
            _actionQueue.Enqueue(action);
        }
    }
}
```

### 3. 协议数据类定义（可选，但推荐）

为每个协议消息创建对应的 C# 类，方便使用：

```csharp
// LoginRequest.cs
[System.Serializable]
public class LoginRequest
{
    public string account_id;
}

// LoginResponse.cs
[System.Serializable]
public class LoginResponse
{
    public bool success;
    public int player_id;
    public string player_name;
}

// ChatMessage.cs
[System.Serializable]
public class ChatMessage
{
    public string type;
    public int channel_id;
    public string channel_name;
    public int sender_id;
    public string sender_name;
    public string content;
    public long timestamp;
}
```

### 4. 使用示例

```csharp
public class GameClient : MonoBehaviour
{
    void Start()
    {
        // 初始化网络管理器
        NetworkManager.Instance.Connect("127.0.0.1", 8888);
        
        // 注册消息处理器
        NetworkManager.Instance.RegisterMessageHandler("chat_message", OnChatMessage);
        NetworkManager.Instance.RegisterMessageHandler("kicked_out", OnKickedOut);
        
        // 发送登录请求（带回调）
        LoginRequest loginReq = new LoginRequest { account_id = "test123" };
        NetworkManager.Instance.SendRequest("login", loginReq, (response) => {
            LoginResponse loginResp = JsonUtility.FromJson<LoginResponse>(JsonUtility.ToJson(response));
            if (loginResp.success)
            {
                Debug.Log($"Login success! Player ID: {loginResp.player_id}");
            }
            else
            {
                Debug.LogError("Login failed");
            }
        });
    }
    
    void OnChatMessage(object data)
    {
        ChatMessage msg = JsonUtility.FromJson<ChatMessage>(JsonUtility.ToJson(data));
        Debug.Log($"[{msg.channel_name}] {msg.sender_name}: {msg.content}");
    }
    
    void OnKickedOut(object data)
    {
        Debug.LogError("You have been kicked out!");
        // 处理被踢下线
    }
}
```

---

## 三、关键点说明

### 1. 协议文件格式

- **二进制格式**：使用 `sprotoparser.parse()` 生成的二进制文件（`.sproto`）
- **文本格式**：也可以直接使用协议文本，但需要 C# 端有解析器

### 2. 数据包格式

Skynet 的 gate 服务使用 `string.pack(">s2", pack)` 格式：
- 前 2 字节：大端序的长度（`>s2`）
- 后面：sproto 打包的数据

### 3. Session 管理

- 客户端维护一个递增的 `session` 计数器
- 每个请求分配一个唯一的 `session`
- 响应通过 `session` 匹配对应的回调

### 4. 消息类型

- **REQUEST**：服务器主动推送的消息（如聊天消息、系统通知）
- **RESPONSE**：对应客户端请求的响应

---

## 四、注意事项

### 1. 线程安全

- 网络接收在后台线程
- Unity API 调用必须在主线程
- 使用 `UnityMainThreadDispatcher` 进行线程切换

### 2. 错误处理

- 网络断开重连机制
- 请求超时处理
- 协议解析错误处理

### 3. 性能优化

- 协议二进制文件预加载
- 消息处理队列化
- 避免频繁的 GC 分配

### 4. 调试

- 添加日志输出
- 协议数据可视化
- 网络状态监控

---

## 五、完整工作流程

1. **生成协议文件**：运行 Lua 脚本生成 `c2s.sproto` 和 `s2c.sproto`
2. **集成 sproto 库**：将 C# sproto 库添加到项目
3. **实现网络层**：创建 `NetworkManager` 和 `UnityMainThreadDispatcher`
4. **定义数据类**：为常用协议消息创建 C# 类（可选）
5. **注册处理器**：注册服务器推送消息的处理器
6. **发送请求**：使用 `SendRequest` 发送请求并处理响应

---

## 六、参考资源

- sproto C# 实现：https://github.com/cloudwu/sproto/tree/master/csharp
- sproto 官方文档：https://github.com/cloudwu/sproto
- Skynet 文档：https://github.com/cloudwu/skynet

---

## 七、快速开始检查清单

- [ ] 安装/集成 C# sproto 库
- [ ] 生成协议二进制文件（`c2s.sproto`, `s2c.sproto`）
- [ ] 将协议文件放到 Resources 目录
- [ ] 实现 `NetworkManager.cs`
- [ ] 实现 `UnityMainThreadDispatcher.cs`
- [ ] 测试连接和基本消息收发
- [ ] 实现具体的业务消息处理

