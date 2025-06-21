#ifdef __cplusplus
extern "C" {
#endif
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#ifdef __cplusplus
}
#endif
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>

// 包含常量定义头文件
#include "recastnavigation/recast_constants.h"

// RecastNavigation头文件
#include "recastnavigation/Recast.h"
#include "recastnavigation/DetourNavMesh.h"
#include "recastnavigation/DetourNavMeshBuilder.h"
#include "recastnavigation/DetourNavMeshQuery.h"
#include "recastnavigation/DetourTileCache.h"
#include "recastnavigation/DetourTileCacheBuilder.h"

// TileCache分配器实现
struct TileCacheAllocator : public dtTileCacheAlloc
{
    virtual void reset() {}
    virtual void* alloc(const size_t size) { return malloc(size); }
    virtual void free(void* ptr) { ::free(ptr); }
};

// TileCache压缩器实现
struct TileCacheCompressor : public dtTileCacheCompressor
{
    virtual int maxCompressedSize(const int bufferSize) { return bufferSize; }
    virtual dtStatus compress(const unsigned char* buffer, const int bufferSize,
                             unsigned char* compressed, const int maxCompressedSize, int* compressedSize)
    {
        if (bufferSize > maxCompressedSize) return DT_FAILURE;
        memcpy(compressed, buffer, bufferSize);
        *compressedSize = bufferSize;
        return DT_SUCCESS;
    }
    virtual dtStatus decompress(const unsigned char* compressed, const int compressedSize,
                               unsigned char* buffer, const int maxBufferSize, int* bufferSize)
    {
        if (compressedSize > maxBufferSize) return DT_FAILURE;
        memcpy(buffer, compressed, compressedSize);
        *bufferSize = compressedSize;
        return DT_SUCCESS;
    }
};

// TileCache网格处理器实现
struct TileCacheMeshProcess : public dtTileCacheMeshProcess
{
    virtual void process(struct dtNavMeshCreateParams* params,
                        unsigned char* polyAreas, unsigned short* polyFlags)
    {
        // 设置所有多边形的区域和标志
        for (int i = 0; i < params->polyCount; ++i)
        {
            polyAreas[i] = DT_TILECACHE_WALKABLE_AREA;
            polyFlags[i] = DEFAULT_POLY_FLAGS;
        }
    }
};

// 所有Lua API函数需要extern "C"声明
#ifdef __cplusplus
extern "C" {
#endif

// 动态障碍物结构
typedef struct {
    int id;
    float x, y, z;
    float radius;
    float height;
    dtObstacleRef ref;
} DynamicObstacle;

// 扩展导航网格数据结构以支持动态障碍物
typedef struct {
    dtNavMesh* navMesh;
    dtNavMeshQuery* navQuery;
    dtTileCache* tileCache;
    int navMeshId;
    DynamicObstacle* obstacles;
    int obstacleCount;
    int maxObstacles;
} NavMeshData;

// 全局导航网格存储
static NavMeshData* g_navMeshes = NULL;
static int g_navMeshCount = 0;
static int g_maxNavMeshes = DEFAULT_MAX_NAV_MESHES;

// 初始化导航网格存储
static void init_navmesh_storage() {
    if (!g_navMeshes) {
        g_navMeshes = (NavMeshData*)malloc(sizeof(NavMeshData) * g_maxNavMeshes);
        memset(g_navMeshes, 0, sizeof(NavMeshData) * g_maxNavMeshes);
        
        // 初始化每个导航网格的障碍物存储
        for (int i = 0; i < g_maxNavMeshes; i++) {
            g_navMeshes[i].maxObstacles = DEFAULT_MAX_OBSTACLES_PER_MESH;
            g_navMeshes[i].obstacles = (DynamicObstacle*)malloc(sizeof(DynamicObstacle) * g_navMeshes[i].maxObstacles);
            memset(g_navMeshes[i].obstacles, 0, sizeof(DynamicObstacle) * g_navMeshes[i].maxObstacles);
            
            // 创建TileCache
            g_navMeshes[i].tileCache = dtAllocTileCache();
        }
    }
}

// 获取导航网格数据
static NavMeshData* get_navmesh(int navMeshId) {
    if (navMeshId < 0 || navMeshId >= g_navMeshCount) {
        return NULL;
    }
    return &g_navMeshes[navMeshId];
}

// 创建新的导航网格ID
static int create_navmesh_id() {
    if (g_navMeshCount >= g_maxNavMeshes) {
        return -1;
    }
    return g_navMeshCount++;
}

// 统一的资源清理函数
static void cleanup_navmesh_resources(NavMeshData* navData, rcHeightfield* hf, 
                                     rcCompactHeightfield* chf, rcContourSet* cset,
                                     rcPolyMesh* pmesh, rcPolyMeshDetail* dmesh) {
    if (dmesh) rcFreePolyMeshDetail(dmesh);
    if (pmesh) rcFreePolyMesh(pmesh);
    if (cset) rcFreeContourSet(cset);
    if (chf) rcFreeCompactHeightfield(chf);
    if (hf) rcFreeHeightField(hf);
    
    if (navData) {
        if (navData->tileCache) {
            dtFreeTileCache(navData->tileCache);
            navData->tileCache = NULL;
        }
        if (navData->navQuery) {
            dtFreeNavMeshQuery(navData->navQuery);
            navData->navQuery = NULL;
        }
        if (navData->navMesh) {
            dtFreeNavMesh(navData->navMesh);
            navData->navMesh = NULL;
        }
    }
}

// 初始化RecastNavigation
static int l_recast_init(lua_State* L) {
    init_navmesh_storage();
    lua_pushboolean(L, 1);
    return 1;
}

// 创建导航网格
static int l_create_navmesh(lua_State* L) {
    // 确保导航网格存储已初始化
    init_navmesh_storage();
    
    // 获取地形数据
    luaL_checktype(L, 1, LUA_TTABLE);
    
    // 获取配置参数
    lua_getfield(L, 1, "cell_size");
    float cellSize = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : DEFAULT_CELL_SIZE;
    lua_pop(L, 1);
    
    lua_getfield(L, 1, "cell_height");
    float cellHeight = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : DEFAULT_CELL_HEIGHT;
    lua_pop(L, 1);
    
    lua_getfield(L, 1, "walkable_slope_angle");
    float walkableSlopeAngle = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : DEFAULT_WALKABLE_SLOPE_ANGLE;
    lua_pop(L, 1);
    
    // 获取地形数据
    lua_getfield(L, 1, "width");
    int width = luaL_checkinteger(L, -1);
    lua_pop(L, 1);
    
    lua_getfield(L, 1, "height");
    int height = luaL_checkinteger(L, -1);
    lua_pop(L, 1);
    
    lua_getfield(L, 1, "terrain_data");
    luaL_checktype(L, -1, LUA_TTABLE);
    
    // 创建导航网格ID
    int navMeshId = create_navmesh_id();
    if (navMeshId == -1) {
        lua_pushnil(L);
        return 1;
    }
    
    NavMeshData* navData = &g_navMeshes[navMeshId];
    
    // 创建导航网格
    navData->navMesh = dtAllocNavMesh();
    if (!navData->navMesh) {
        lua_pushnil(L);
        return 1;
    }
    
    // 创建导航查询
    navData->navQuery = dtAllocNavMeshQuery();
    if (!navData->navQuery) {
        cleanup_navmesh_resources(navData, NULL, NULL, NULL, NULL, NULL);
        lua_pushnil(L);
        return 1;
    }
    
    navData->navMeshId = navMeshId;
    
    // 初始化TileCache
    static TileCacheAllocator allocator;
    static TileCacheCompressor compressor;
    static TileCacheMeshProcess meshProcess;
    
    dtTileCacheParams tcParams;
    memset(&tcParams, 0, sizeof(tcParams));
    tcParams.ch = cellHeight;
    tcParams.cs = cellSize;
    tcParams.walkableHeight = DEFAULT_WALKABLE_HEIGHT;
    tcParams.walkableRadius = DEFAULT_WALKABLE_RADIUS;
    tcParams.walkableClimb = DEFAULT_WALKABLE_CLIMB;
    tcParams.maxSimplificationError = DEFAULT_MAX_SIMPLIFICATION_ERROR;
    tcParams.maxTiles = DEFAULT_MAX_TILES;
    tcParams.maxObstacles = DEFAULT_MAX_OBSTACLES;
    
    if (dtStatusFailed(navData->tileCache->init(&tcParams, &allocator, &compressor, &meshProcess))) {
        printf("TileCache初始化失败\n");
        cleanup_navmesh_resources(navData, NULL, NULL, NULL, NULL, NULL);
        lua_pushnil(L);
        return 1;
    }
    
    // 构建导航网格
    printf("开始构建导航网格，width=%d, height=%d, cellSize=%.2f, cellHeight=%.2f\n", 
           width, height, cellSize, cellHeight);
    
    // 创建rcContext用于错误处理和日志
    rcContext ctx(true);  // 启用日志和计时器
    
    // 1. 创建高度场
    rcHeightfield* hf = rcAllocHeightfield();
    if (!hf) {
        printf("rcAllocHeightfield失败\n");
        cleanup_navmesh_resources(navData, NULL, NULL, NULL, NULL, NULL);
        lua_pushnil(L);
        return 1;
    }
    
    // 计算边界框
    float bmin[3] = {0, 0, 0};
    float bmax[3] = {width * cellSize, DEFAULT_MAX_HEIGHT, height * cellSize};
    
    // 初始化高度场
    if (!rcCreateHeightfield(&ctx, *hf, width, height, bmin, bmax, cellSize, cellHeight)) {
        printf("rcCreateHeightfield失败\n");
        cleanup_navmesh_resources(navData, hf, NULL, NULL, NULL, NULL);
        lua_pushnil(L);
        return 1;
    }
    
    // 2. 从地形数据构建高度场
    // 读取地形数据并标记可行走区域
    for (int z = 0; z < height; z++) {
        for (int x = 0; x < width; x++) {
            lua_rawgeti(L, -1, z + 1);  // Lua索引从1开始
            luaL_checktype(L, -1, LUA_TTABLE);
            lua_rawgeti(L, -1, x + 1);
            int terrainType = luaL_checkinteger(L, -1);
            lua_pop(L, 2);  // 弹出内层table和terrainType
            
            // 根据地形类型设置高度和可行走性
            float h = 0.0f;
            bool walkable = true;
            
            switch (terrainType) {
                case TERRAIN_TYPE_PLAIN: // PLAIN（平地）
                    h = DEFAULT_TERRAIN_HEIGHT_PLAIN;
                    walkable = true;
                    break;
                case TERRAIN_TYPE_WATER: // WATER（水域）
                    h = DEFAULT_TERRAIN_HEIGHT_WATER;
                    walkable = false;
                    break;
                case TERRAIN_TYPE_MOUNTAIN: // MOUNTAIN（山地）
                    h = DEFAULT_TERRAIN_HEIGHT_MOUNTAIN;
                    walkable = false;
                    break;
                case TERRAIN_TYPE_OBSTACLE: // OBSTACLE（障碍物）
                    h = DEFAULT_TERRAIN_HEIGHT_OBSTACLE;
                    walkable = false;
                    break;
                case TERRAIN_TYPE_SAFE_ZONE: // SAFE_ZONE（安全区）
                    h = DEFAULT_TERRAIN_HEIGHT_SAFE_ZONE;
                    walkable = true;
                    break;
                case TERRAIN_TYPE_TRANSPORT: // TRANSPORT（传送点）
                    h = DEFAULT_TERRAIN_HEIGHT_TRANSPORT;
                    walkable = true;
                    break;
                default:
                    h = DEFAULT_TERRAIN_HEIGHT_PLAIN;
                    walkable = true;
                    break;
            }
            
            // 标记高度场中的可行走区域
            if (walkable) {
                // 使用rcAddSpan添加span到高度场
                unsigned short spanMin = (unsigned short)(h / cellHeight);
                unsigned short spanMax = (unsigned short)((h + DEFAULT_CHARACTER_HEIGHT) / cellHeight);
                
                if (!rcAddSpan(&ctx, *hf, x, z, spanMin, spanMax, RC_WALKABLE_AREA, 1)) {
                    printf("添加span失败: (%d, %d)\n", x, z);
                    cleanup_navmesh_resources(navData, hf, NULL, NULL, NULL, NULL);
                    lua_pushnil(L);
                    return 1;
                }
            }
        }
    }
    lua_pop(L, 1); // 弹出terrain_data表
    
    // 3. 过滤高度场
    rcFilterLowHangingWalkableObstacles(&ctx, DEFAULT_WALKABLE_CLIMB_FILTER, *hf);
    rcFilterLedgeSpans(&ctx, DEFAULT_WALKABLE_HEIGHT_FILTER, DEFAULT_WALKABLE_CLIMB_FILTER, *hf);
    rcFilterWalkableLowHeightSpans(&ctx, DEFAULT_WALKABLE_HEIGHT_FILTER, *hf);
    
    // 4. 构建紧凑高度场
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    if (!chf) {
        cleanup_navmesh_resources(navData, hf, NULL, NULL, NULL, NULL);
        lua_pushnil(L);
        return 1;
    }
    
    if (!rcBuildCompactHeightfield(&ctx, DEFAULT_WALKABLE_HEIGHT_FILTER, DEFAULT_WALKABLE_CLIMB_FILTER, *hf, *chf)) {
        cleanup_navmesh_resources(navData, hf, chf, NULL, NULL, NULL);
        lua_pushnil(L);
        return 1;
    }
    
    // 5. 构建距离场
    if (!rcErodeWalkableArea(&ctx, DEFAULT_WALKABLE_RADIUS_ERODE, *chf)) {
        cleanup_navmesh_resources(navData, hf, chf, NULL, NULL, NULL);
        lua_pushnil(L);
        return 1;
    }
    
    // 6. 构建区域
    if (!rcBuildDistanceField(&ctx, *chf)) {
        cleanup_navmesh_resources(navData, hf, chf, NULL, NULL, NULL);
        lua_pushnil(L);
        return 1;
    }
    
    if (!rcBuildRegions(&ctx, *chf, DEFAULT_REGION_MIN_SIZE, DEFAULT_REGION_MERGE_SIZE, DEFAULT_REGION_MIN_AREA)) {
        cleanup_navmesh_resources(navData, hf, chf, NULL, NULL, NULL);
        lua_pushnil(L);
        return 1;
    }
    
    // 7. 构建轮廓
    rcContourSet* cset = rcAllocContourSet();
    if (!cset) {
        cleanup_navmesh_resources(navData, hf, chf, NULL, NULL, NULL);
        lua_pushnil(L);
        return 1;
    }
    
    if (!rcBuildContours(&ctx, *chf, DEFAULT_CONTOUR_MAX_ERROR, DEFAULT_CONTOUR_MAX_EDGE_LEN, *cset)) {
        cleanup_navmesh_resources(navData, hf, chf, cset, NULL, NULL);
        lua_pushnil(L);
        return 1;
    }
    
    // 8. 构建多边形网格
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    if (!pmesh) {
        cleanup_navmesh_resources(navData, hf, chf, cset, NULL, NULL);
        lua_pushnil(L);
        return 1;
    }
    
    if (!rcBuildPolyMesh(&ctx, *cset, DEFAULT_POLY_MAX_VERTS, *pmesh)) {
        cleanup_navmesh_resources(navData, hf, chf, cset, pmesh, NULL);
        lua_pushnil(L);
        return 1;
    }
    
    // 打印多边形网格信息
    printf("多边形网格构建成功: nverts=%d, npolys=%d, nvp=%d\n", 
           pmesh->nverts, pmesh->npolys, pmesh->nvp);
    
    // 检查多边形网格是否为空
    if (pmesh->npolys == 0) {
        printf("错误: 多边形网格为空，没有生成任何多边形\n");
        cleanup_navmesh_resources(navData, hf, chf, cset, pmesh, NULL);
        lua_pushnil(L);
        return 1;
    }
    
    // 手动设置所有多边形的标志位
    for (int i = 0; i < pmesh->npolys; i++) {
        pmesh->flags[i] = DEFAULT_POLY_FLAGS;
    }
    
    // 9. 构建详细网格
    rcPolyMeshDetail* dmesh = rcAllocPolyMeshDetail();
    if (!dmesh) {
        cleanup_navmesh_resources(navData, hf, chf, cset, pmesh, NULL);
        lua_pushnil(L);
        return 1;
    }
    
    if (!rcBuildPolyMeshDetail(&ctx, *pmesh, *chf, DEFAULT_DETAIL_SAMPLE_DIST, DEFAULT_DETAIL_SAMPLE_MAX_ERROR, *dmesh)) {
        cleanup_navmesh_resources(navData, hf, chf, cset, pmesh, dmesh);
        lua_pushnil(L);
        return 1;
    }
    
    // 10. 创建导航网格数据
    dtNavMeshCreateParams params;
    memset(&params, 0, sizeof(params));
    
    params.verts = pmesh->verts;
    params.vertCount = pmesh->nverts;
    params.polys = pmesh->polys;
    params.polyAreas = pmesh->areas;
    params.polyFlags = pmesh->flags;
    params.polyCount = pmesh->npolys;
    params.nvp = pmesh->nvp;
    params.detailMeshes = dmesh->meshes;
    params.detailVerts = dmesh->verts;
    params.detailVertsCount = dmesh->nverts;
    params.detailTris = dmesh->tris;
    params.detailTriCount = dmesh->ntris;
    params.offMeshConVerts = NULL;
    params.offMeshConRad = NULL;
    params.offMeshConDir = NULL;
    params.offMeshConAreas = NULL;
    params.offMeshConFlags = NULL;
    params.offMeshConUserID = NULL;
    params.offMeshConCount = 0;
    params.walkableHeight = DEFAULT_WALKABLE_HEIGHT;
    params.walkableRadius = DEFAULT_WALKABLE_RADIUS;
    params.walkableClimb = DEFAULT_WALKABLE_CLIMB;
    params.tileX = 0;
    params.tileY = 0;
    params.tileLayer = 0;
    params.bmin[0] = bmin[0];
    params.bmin[1] = bmin[1];
    params.bmin[2] = bmin[2];
    params.bmax[0] = bmax[0];
    params.bmax[1] = bmax[1];
    params.bmax[2] = bmax[2];
    params.cs = cellSize;
    params.ch = cellHeight;
    params.buildBvTree = true;
    
    // 11. 创建导航网格数据
    unsigned char* navDataBuffer = NULL;
    int navDataSize = 0;
    
    if (!dtCreateNavMeshData(&params, &navDataBuffer, &navDataSize)) {
        cleanup_navmesh_resources(navData, hf, chf, cset, pmesh, dmesh);
        lua_pushnil(L);
        return 1;
    }
    
    // 12. 初始化导航网格
    if (dtStatusFailed(navData->navMesh->init(navDataBuffer, navDataSize, DT_TILE_FREE_DATA))) {
        dtFree(navDataBuffer);
        cleanup_navmesh_resources(navData, hf, chf, cset, pmesh, dmesh);
        lua_pushnil(L);
        return 1;
    }
    
    // 13. 初始化导航查询
    if (dtStatusFailed(navData->navQuery->init(navData->navMesh, DEFAULT_NAV_QUERY_MAX_NODES))) {
        cleanup_navmesh_resources(navData, hf, chf, cset, pmesh, dmesh);
        lua_pushnil(L);
        return 1;
    }
    
    // 清理临时数据
    cleanup_navmesh_resources(NULL, hf, chf, cset, pmesh, dmesh);
    
    printf("导航网格创建成功，ID: %d\n", navMeshId);
    
    // 返回导航网格ID
    lua_pushinteger(L, navMeshId);
    return 1;
}

// 从文件创建导航网格
static int l_create_navmesh_from_file(lua_State* L) {
    // 确保导航网格存储已初始化
    init_navmesh_storage();
    
    // 获取文件路径
    const char* filepath = luaL_checkstring(L, 1);
    
    // 打开文件
    FILE* file = fopen(filepath, "rb");
    if (!file) {
        printf("无法打开导航网格文件: %s\n", filepath);
        lua_pushnil(L);
        return 1;
    }
    
    // 创建导航网格ID
    int navMeshId = create_navmesh_id();
    if (navMeshId == -1) {
        fclose(file);
        lua_pushnil(L);
        return 1;
    }
    
    NavMeshData* navData = &g_navMeshes[navMeshId];
    
    // 创建导航网格
    navData->navMesh = dtAllocNavMesh();
    if (!navData->navMesh) {
        fclose(file);
        lua_pushnil(L);
        return 1;
    }
    
    // 创建导航查询
    navData->navQuery = dtAllocNavMeshQuery();
    if (!navData->navQuery) {
        cleanup_navmesh_resources(navData, NULL, NULL, NULL, NULL, NULL);
        fclose(file);
        lua_pushnil(L);
        return 1;
    }
    
    navData->navMeshId = navMeshId;
    
    // 读取文件头
    struct {
        uint32_t version;           // 版本号
        uint32_t tileCount;         // tile数量
        dtNavMeshParams params;     // 导航网格参数
    } fileHeader;
    
    if (fread(&fileHeader, sizeof(fileHeader), 1, file) != 1) {
        printf("读取文件头失败\n");
        cleanup_navmesh_resources(navData, NULL, NULL, NULL, NULL, NULL);
        fclose(file);
        lua_pushnil(L);
        return 1;
    }
    
    // 检查版本号 (假设当前版本为1)
    if (fileHeader.version != 1) {
        printf("不支持的导航网格文件版本: %d\n", fileHeader.version);
        cleanup_navmesh_resources(navData, NULL, NULL, NULL, NULL, NULL);
        fclose(file);
        lua_pushnil(L);
        return 1;
    }
    
    printf("读取导航网格文件: 版本=%d, tile数量=%d\n", 
           fileHeader.version, fileHeader.tileCount);
    
    // 初始化导航网格
    if (dtStatusFailed(navData->navMesh->init(&fileHeader.params))) {
        printf("初始化导航网格失败\n");
        cleanup_navmesh_resources(navData, NULL, NULL, NULL, NULL, NULL);
        fclose(file);
        lua_pushnil(L);
        return 1;
    }
    
    // 初始化导航查询
    if (dtStatusFailed(navData->navQuery->init(navData->navMesh, DEFAULT_NAV_QUERY_MAX_NODES))) {
        printf("初始化导航查询失败\n");
        cleanup_navmesh_resources(navData, NULL, NULL, NULL, NULL, NULL);
        fclose(file);
        lua_pushnil(L);
        return 1;
    }
    
    // 读取并添加tile
    int successCount = 0;
    for (uint32_t i = 0; i < fileHeader.tileCount; i++) {
        // 读取tile头信息
        struct {
            uint32_t tileRef;       // tile引用
            uint32_t dataSize;      // tile数据大小
            uint32_t tileX, tileY, tileLayer; // tile坐标
        } tileHeader;
        
        if (fread(&tileHeader, sizeof(tileHeader), 1, file) != 1) {
            printf("读取tile %d 头信息失败\n", i);
            break;
        }
        
        // 分配tile数据内存
        unsigned char* tileData = (unsigned char*)malloc(tileHeader.dataSize);
        if (!tileData) {
            printf("分配tile %d 数据内存失败\n", i);
            break;
        }
        
        // 读取tile数据
        if (fread(tileData, 1, tileHeader.dataSize, file) != tileHeader.dataSize) {
            printf("读取tile %d 数据失败\n", i);
            free(tileData);
            break;
        }
        
        // 添加tile到导航网格
        dtTileRef tileRef;
        if (dtStatusSucceed(navData->navMesh->addTile(tileData, tileHeader.dataSize, 
                                                     DT_TILE_FREE_DATA, tileHeader.tileRef, &tileRef))) {
            successCount++;
            printf("成功添加tile %d: ref=%u, size=%u, pos=(%u,%u,%u)\n", 
                   i, tileRef, tileHeader.dataSize, tileHeader.tileX, tileHeader.tileY, tileHeader.tileLayer);
        } else {
            printf("添加tile %d 失败\n", i);
            free(tileData);
        }
    }
    
    fclose(file);
    
    if (successCount == 0) {
        printf("没有成功添加任何tile\n");
        cleanup_navmesh_resources(navData, NULL, NULL, NULL, NULL, NULL);
        lua_pushnil(L);
        return 1;
    }
    
    printf("导航网格创建成功: ID=%d, 成功添加 %d/%d 个tile\n", 
           navMeshId, successCount, fileHeader.tileCount);
    
    // 返回导航网格ID
    lua_pushinteger(L, navMeshId);
    return 1;
}

// 保存导航网格到文件
static int l_save_navmesh_to_file(lua_State* L) {
    // 获取导航网格ID和文件路径
    int navMeshId = luaL_checkinteger(L, 1);
    const char* filepath = luaL_checkstring(L, 2);
    
    NavMeshData* navData = get_navmesh(navMeshId);
    if (!navData || !navData->navMesh) {
        printf("导航网格不存在: ID=%d\n", navMeshId);
        lua_pushboolean(L, 0);
        return 1;
    }
    
    // 打开文件
    FILE* file = fopen(filepath, "wb");
    if (!file) {
        printf("无法创建导航网格文件: %s\n", filepath);
        lua_pushboolean(L, 0);
        return 1;
    }
    
    // 获取导航网格参数
    const dtNavMeshParams* params = navData->navMesh->getParams();
    if (!params) {
        printf("获取导航网格参数失败\n");
        fclose(file);
        lua_pushboolean(L, 0);
        return 1;
    }
    
    // 写入文件头
    struct {
        uint32_t version;           // 版本号
        uint32_t tileCount;         // tile数量
        dtNavMeshParams params;     // 导航网格参数
    } fileHeader;
    
    fileHeader.version = 1;
    fileHeader.tileCount = navData->navMesh->getMaxTiles();
    fileHeader.params = *params;
    
    if (fwrite(&fileHeader, sizeof(fileHeader), 1, file) != 1) {
        printf("写入文件头失败\n");
        fclose(file);
        lua_pushboolean(L, 0);
        return 1;
    }
    
    // 遍历并保存所有tile
    int savedCount = 0;
    for (int i = 0; i < navData->navMesh->getMaxTiles(); i++) {
        // 使用公共API获取tile引用
        dtTileRef tileRef = navData->navMesh->getTileRefAt(i, 0, 0);
        if (!tileRef) continue;
        
        // 获取tile数据
        const dtMeshTile* tile = navData->navMesh->getTileByRef(tileRef);
        if (!tile || !tile->header) continue;
        
        // 计算tile数据大小
        int dataSize = tile->dataSize;
        
        // 写入tile头信息
        struct {
            uint32_t tileRef;       // tile引用
            uint32_t dataSize;      // tile数据大小
            uint32_t tileX, tileY, tileLayer; // tile坐标
        } tileHeader;
        
        tileHeader.tileRef = tileRef;
        tileHeader.dataSize = dataSize;
        tileHeader.tileX = tile->header->x;
        tileHeader.tileY = tile->header->y;
        tileHeader.tileLayer = tile->header->layer;
        
        if (fwrite(&tileHeader, sizeof(tileHeader), 1, file) != 1) {
            printf("写入tile %d 头信息失败\n", i);
            break;
        }
        
        // 写入tile数据
        if (fwrite(tile->data, 1, dataSize, file) != dataSize) {
            printf("写入tile %d 数据失败\n", i);
            break;
        }
        
        savedCount++;
    }
    
    fclose(file);
    
    printf("导航网格保存成功: ID=%d, 保存了 %d 个tile 到 %s\n", 
           navMeshId, savedCount, filepath);
    
    lua_pushboolean(L, 1);
    return 1;
}

// 坐标系转换函数
// RecastNavigation使用右手坐标系：X右Y上Z前
// 很多游戏引擎使用左手坐标系或其他坐标系

// 从Unity坐标系转换到Recast坐标系
static void convertFromUnityToRecast(const float* unityPos, float* recastPos) {
    // Unity: X右Y上Z前 -> Recast: X右Y上Z前
    // Unity和Recast使用相同的坐标系，直接复制
    recastPos[0] = unityPos[0];  // X
    recastPos[1] = unityPos[1];  // Y  
    recastPos[2] = unityPos[2];  // Z
}

// 从Recast坐标系转换到Unity坐标系
static void convertFromRecastToUnity(const float* recastPos, float* unityPos) {
    // Recast: X右Y上Z前 -> Unity: X右Y上Z前
    // 直接复制
    unityPos[0] = recastPos[0];  // X
    unityPos[1] = recastPos[1];  // Y
    unityPos[2] = recastPos[2];  // Z
}

// 从Unreal坐标系转换到Recast坐标系
static void convertFromUnrealToRecast(const float* unrealPos, float* recastPos) {
    // Unreal: X右Y前Z上 -> Recast: X右Y上Z前
    recastPos[0] = unrealPos[0];  // X: 右 -> 右
    recastPos[1] = unrealPos[2];  // Y: Z上 -> Y上
    recastPos[2] = unrealPos[1];  // Z: Y前 -> Z前
}

// 从Recast坐标系转换到Unreal坐标系
static void convertFromRecastToUnreal(const float* recastPos, float* unrealPos) {
    // Recast: X右Y上Z前 -> Unreal: X右Y前Z上
    unrealPos[0] = recastPos[0];  // X: 右 -> 右
    unrealPos[1] = recastPos[2];  // Y: Z前 -> Y前
    unrealPos[2] = recastPos[1];  // Z: Y上 -> Z上
}

// 从左手坐标系转换到右手坐标系
static void convertFromLeftToRightHand(const float* leftPos, float* rightPos) {
    // 左手坐标系 -> 右手坐标系：Z轴取反
    rightPos[0] = leftPos[0];  // X
    rightPos[1] = leftPos[1];  // Y
    rightPos[2] = -leftPos[2]; // Z取反
}

// 从右手坐标系转换到左手坐标系
static void convertFromRightToLeftHand(const float* rightPos, float* leftPos) {
    // 右手坐标系 -> 左手坐标系：Z轴取反
    leftPos[0] = rightPos[0];  // X
    leftPos[1] = rightPos[1];  // Y
    leftPos[2] = -rightPos[2]; // Z取反
}

// 寻路
static int l_find_path(lua_State* L) {
    int navMeshId = luaL_checkinteger(L, 1);
    float startX = luaL_checknumber(L, 2);
    float startY = luaL_checknumber(L, 3);
    float startZ = luaL_checknumber(L, 4);
    float endX = luaL_checknumber(L, 5);
    float endY = luaL_checknumber(L, 6);
    float endZ = luaL_checknumber(L, 7);
    
    // 获取坐标系类型（可选参数）
    int coordSystem = 0; // 0=Unity/Recast, 1=Unreal, 2=左手坐标系
    if (lua_gettop(L) >= 8) {
        coordSystem = luaL_optinteger(L, 8, 0);
    }
    
    NavMeshData* navData = get_navmesh(navMeshId);
    if (!navData || !navData->navMesh || !navData->navQuery) {
        lua_pushnil(L);
        return 1;
    }
    
    // 创建查询过滤器
    dtQueryFilter filter;
    filter.setIncludeFlags(0xffff);  // 允许所有标志位（包括0）
    filter.setExcludeFlags(0);
    
    // 坐标系转换
    float startPos[3], endPos[3];
    float inputStart[3] = {startX, startY, startZ};
    float inputEnd[3] = {endX, endY, endZ};
    
    switch (coordSystem) {
        case 0: // Unity/Recast (相同坐标系)
            convertFromUnityToRecast(inputStart, startPos);
            convertFromUnityToRecast(inputEnd, endPos);
            break;
        case 1: // Unreal
            convertFromUnrealToRecast(inputStart, startPos);
            convertFromUnrealToRecast(inputEnd, endPos);
            break;
        case 2: // 左手坐标系
            convertFromLeftToRightHand(inputStart, startPos);
            convertFromLeftToRightHand(inputEnd, endPos);
            break;
        default:
            // 默认使用Unity/Recast坐标系
            convertFromUnityToRecast(inputStart, startPos);
            convertFromUnityToRecast(inputEnd, endPos);
            break;
    }
    
    // 寻找最近的多边形
    float extents[3] = {2, 4, 2};
    
    dtPolyRef startRef, endRef;
    float startNearest[3], endNearest[3];
    
    if (dtStatusFailed(navData->navQuery->findNearestPoly(startPos, extents, &filter, &startRef, startNearest))) {
        lua_pushnil(L);
        return 1;
    }
    
    if (dtStatusFailed(navData->navQuery->findNearestPoly(endPos, extents, &filter, &endRef, endNearest))) {
        lua_pushnil(L);
        return 1;
    }
    
    // 寻路
    dtPolyRef path[DEFAULT_PATH_MAX_SIZE];
    int pathCount;
    if (dtStatusFailed(navData->navQuery->findPath(startRef, endRef, startNearest, endNearest, &filter, path, &pathCount, DEFAULT_PATH_MAX_SIZE))) {
        lua_pushnil(L);
        return 1;
    }
    if (pathCount == 0) {
        lua_pushnil(L);
        return 1;
    }
    
    // 构建直线路径
    float straightPath[DEFAULT_PATH_MAX_SIZE*3];
    unsigned char straightPathFlags[DEFAULT_PATH_MAX_SIZE];
    dtPolyRef straightPathPolys[DEFAULT_PATH_MAX_SIZE];
    int straightPathCount;
    
    if (dtStatusFailed(navData->navQuery->findStraightPath(startNearest, endNearest, path, pathCount, straightPath, straightPathFlags, straightPathPolys, &straightPathCount, DEFAULT_PATH_MAX_SIZE))) {
        lua_pushnil(L);
        return 1;
    }
    
    // 返回路径点（需要转换回原始坐标系）
    lua_createtable(L, straightPathCount, 0);
    for (int i = 0; i < straightPathCount; i++) {
        float recastPoint[3] = {straightPath[i*3], straightPath[i*3+1], straightPath[i*3+2]};
        float originalPoint[3];
        
        // 转换回原始坐标系
        switch (coordSystem) {
            case 0: // Unity/Recast
                convertFromRecastToUnity(recastPoint, originalPoint);
                break;
            case 1: // Unreal
                convertFromRecastToUnreal(recastPoint, originalPoint);
                break;
            case 2: // 左手坐标系
                convertFromRightToLeftHand(recastPoint, originalPoint);
                break;
            default:
                convertFromRecastToUnity(recastPoint, originalPoint);
                break;
        }
        
        lua_createtable(L, 3, 0);
        lua_pushnumber(L, originalPoint[0]);
        lua_rawseti(L, -2, 1);
        lua_pushnumber(L, originalPoint[1]);
        lua_rawseti(L, -2, 2);
        lua_pushnumber(L, originalPoint[2]);
        lua_rawseti(L, -2, 3);
        lua_rawseti(L, -2, i+1);
    }
    
    return 1;
}

// 添加动态障碍物
static int l_add_obstacle(lua_State* L) {
    int navMeshId = luaL_checkinteger(L, 1);
    float x = luaL_checknumber(L, 2);
    float y = luaL_checknumber(L, 3);
    float z = luaL_checknumber(L, 4);
    float radius = luaL_checknumber(L, 5);
    float height = luaL_checknumber(L, 6);
    
    NavMeshData* navData = get_navmesh(navMeshId);
    if (!navData || !navData->navMesh || !navData->tileCache) {
        lua_pushnil(L);
        return 1;
    }
    
    // 检查障碍物数量限制
    if (navData->obstacleCount >= navData->maxObstacles) {
        lua_pushnil(L);
        return 1;
    }
    
    // 创建动态障碍物
    dtObstacleRef obstacleRef;
    float pos[3] = {x, y, z};
    
    // 添加圆柱形障碍物到TileCache
    if (dtStatusFailed(navData->tileCache->addObstacle(pos, radius, height, &obstacleRef))) {
        lua_pushnil(L);
        return 1;
    }
    
    // 更新TileCache
    bool upToDate = false;
    navData->tileCache->update(0, navData->navMesh, &upToDate);
    
    // 存储障碍物信息
    DynamicObstacle* obstacle = &navData->obstacles[navData->obstacleCount];
    obstacle->id = navData->obstacleCount + 1;  // 简单的ID分配
    obstacle->x = x;
    obstacle->y = y;
    obstacle->z = z;
    obstacle->radius = radius;
    obstacle->height = height;
    obstacle->ref = obstacleRef;
    
    navData->obstacleCount++;
    
    lua_pushinteger(L, obstacle->id);
    return 1;
}

// 移除动态障碍物
static int l_remove_obstacle(lua_State* L) {
    int navMeshId = luaL_checkinteger(L, 1);
    int obstacleId = luaL_checkinteger(L, 2);
    
    NavMeshData* navData = get_navmesh(navMeshId);
    if (!navData || !navData->navMesh || !navData->tileCache) {
        lua_pushboolean(L, 0);
        return 1;
    }
    
    // 查找障碍物
    DynamicObstacle* obstacle = NULL;
    int obstacleIndex = -1;
    for (int i = 0; i < navData->obstacleCount; i++) {
        if (navData->obstacles[i].id == obstacleId) {
            obstacle = &navData->obstacles[i];
            obstacleIndex = i;
            break;
        }
    }
    
    if (!obstacle) {
        lua_pushboolean(L, 0);
        return 1;
    }
    
    // 从TileCache移除障碍物
    if (dtStatusFailed(navData->tileCache->removeObstacle(obstacle->ref))) {
        lua_pushboolean(L, 0);
        return 1;
    }
    
    // 更新TileCache
    bool upToDate = false;
    navData->tileCache->update(0, navData->navMesh, &upToDate);
    
    // 从数组中移除（移动后面的元素）
    for (int i = obstacleIndex; i < navData->obstacleCount - 1; i++) {
        navData->obstacles[i] = navData->obstacles[i + 1];
    }
    
    navData->obstacleCount--;
    
    lua_pushboolean(L, 1);
    return 1;
}

// 销毁导航网格
static int l_destroy_navmesh(lua_State* L) {
    int navMeshId = luaL_checkinteger(L, 1);
    
    NavMeshData* navData = get_navmesh(navMeshId);
    if (!navData) {
        lua_pushboolean(L, 0);
        return 1;
    }
    
    // 移除所有动态障碍物
    for (int i = 0; i < navData->obstacleCount; i++) {
        navData->tileCache->removeObstacle(navData->obstacles[i].ref);
    }
    navData->obstacleCount = 0;
    
    if (navData->navQuery) {
        dtFreeNavMeshQuery(navData->navQuery);
        navData->navQuery = NULL;
    }
    
    if (navData->tileCache) {
        dtFreeTileCache(navData->tileCache);
        navData->tileCache = NULL;
    }
    
    if (navData->navMesh) {
        dtFreeNavMesh(navData->navMesh);
        navData->navMesh = NULL;
    }
    
    // 释放障碍物数组
    if (navData->obstacles) {
        free(navData->obstacles);
        navData->obstacles = NULL;
    }
    
    lua_pushboolean(L, 1);
    return 1;
}

// 清理资源
static int l_cleanup(lua_State* L) {
    for (int i = 0; i < g_navMeshCount; i++) {
        NavMeshData* navData = &g_navMeshes[i];
        
        // 移除所有动态障碍物
        for (int j = 0; j < navData->obstacleCount; j++) {
            if (navData->tileCache) {
                navData->tileCache->removeObstacle(navData->obstacles[j].ref);
            }
        }
        navData->obstacleCount = 0;
        
        if (navData->navQuery) {
            dtFreeNavMeshQuery(navData->navQuery);
            navData->navQuery = NULL;
        }
        
        if (navData->tileCache) {
            dtFreeTileCache(navData->tileCache);
            navData->tileCache = NULL;
        }
        
        if (navData->navMesh) {
            dtFreeNavMesh(navData->navMesh);
            navData->navMesh = NULL;
        }
        
        // 释放障碍物数组
        if (navData->obstacles) {
            free(navData->obstacles);
            navData->obstacles = NULL;
        }
    }
    
    if (g_navMeshes) {
        free(g_navMeshes);
        g_navMeshes = NULL;
    }
    
    g_navMeshCount = 0;
    
    lua_pushboolean(L, 1);
    return 1;
}

// 模块注册
static const luaL_Reg recast_functions[] = {
    {"init", l_recast_init},
    {"create_navmesh", l_create_navmesh},
    {"create_navmesh_from_file", l_create_navmesh_from_file},
    {"find_path", l_find_path},
    {"add_obstacle", l_add_obstacle},
    {"remove_obstacle", l_remove_obstacle},
    {"destroy_navmesh", l_destroy_navmesh},
    {"cleanup", l_cleanup},
    {"save_navmesh_to_file", l_save_navmesh_to_file},
    {NULL, NULL}
};

int luaopen_recast(lua_State* L) {
    luaL_newlib(L, recast_functions);
    return 1;
}

#ifdef __cplusplus
}
#endif 