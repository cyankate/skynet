# 导航网格文件格式说明

## 文件结构

导航网格文件采用二进制格式，包含文件头和tile数据集合。

### 文件头结构 (File Header)

```c
struct FileHeader {
    uint32_t version;           // 版本号，当前为1
    uint32_t tileCount;         // tile数量
    dtNavMeshParams params;     // 导航网格参数
};
```

### Tile头结构 (Tile Header)

```c
struct TileHeader {
    uint32_t tileRef;           // tile引用ID
    uint32_t dataSize;          // tile数据大小（字节）
    uint32_t tileX;             // tile X坐标
    uint32_t tileY;             // tile Y坐标  
    uint32_t tileLayer;         // tile层级
};
```

## 文件布局

```
[FileHeader][TileHeader1][TileData1][TileHeader2][TileData2]...[TileHeaderN][TileDataN]
```

## 详细说明

### 1. 文件头 (FileHeader)

- **version**: 文件格式版本号，用于向后兼容
- **tileCount**: 文件中包含的tile总数
- **params**: dtNavMeshParams结构，包含导航网格的全局参数

### 2. Tile数据

每个tile包含：
- **TileHeader**: tile的元数据信息
- **TileData**: 实际的tile二进制数据

### 3. dtNavMeshParams结构

```c
struct dtNavMeshParams {
    float orig[3];              // 原点坐标
    float tileWidth;            // tile宽度
    float tileHeight;           // tile高度
    int maxTiles;               // 最大tile数量
    int maxPolys;               // 每个tile最大多边形数
};
```

## 使用示例

### Lua API调用

```lua
local recast = require "recast"

-- 从文件创建导航网格
local navMeshId = recast.create_navmesh_from_file("map_navmesh.bin")

-- 保存导航网格到文件
recast.save_navmesh_to_file(navMeshId, "map_navmesh.bin")
```

### C API函数

```c
// 从文件创建导航网格
int l_create_navmesh_from_file(lua_State* L);

// 保存导航网格到文件  
int l_save_navmesh_to_file(lua_State* L);
```

## 文件大小估算

对于1000x1000的地图：
- 文件头: ~100字节
- 每个tile头: ~20字节
- 每个tile数据: ~47KB
- 总文件大小: ~96MB (2048个tile)

## 注意事项

1. **版本兼容性**: 当前版本为1，后续版本变更时需要处理兼容性
2. **内存管理**: 读取时使用DT_TILE_FREE_DATA标志自动释放tile数据内存
3. **错误处理**: 函数会返回nil或false表示失败
4. **文件完整性**: 建议添加校验和或CRC来验证文件完整性

## 扩展建议

1. **压缩**: 可以对tile数据进行压缩以减少文件大小
2. **流式加载**: 支持部分tile的流式加载
3. **增量更新**: 支持单个tile的增量更新
4. **元数据**: 可以添加更多元数据如创建时间、版本信息等 