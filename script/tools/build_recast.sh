#!/bin/bash

# RecastNavigation编译脚本

set -e

RECAST_VERSION="1.6.0"
RECAST_DIR="3rd/recastnavigation"
BUILD_DIR="build/recast"

echo "开始编译RecastNavigation..."

# 创建目录
mkdir -p $RECAST_DIR
mkdir -p $BUILD_DIR

# 下载RecastNavigation源码
if [ ! -d "$RECAST_DIR/.git" ]; then
    echo "下载RecastNavigation源码..."
    git clone https://github.com/recastnavigation/recastnavigation.git $RECAST_DIR
    cd $RECAST_DIR
    git checkout v$RECAST_VERSION
    cd ../..
else
    echo "RecastNavigation源码已存在，跳过下载"
fi

# 进入构建目录
cd $BUILD_DIR

# 配置CMake
echo "配置CMake..."
cmake ../../$RECAST_DIR \
    -DCMAKE_BUILD_TYPE=Release \
    -DRECASTNAVIGATION_DEMO=OFF \
    -DRECASTNAVIGATION_TESTS=OFF \
    -DRECASTNAVIGATION_EXAMPLES=OFF \
    -DRECASTNAVIGATION_TOOLS=OFF \
    -DCMAKE_INSTALL_PREFIX=../../$RECAST_DIR/install \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON

# 编译
echo "编译RecastNavigation..."
make -j$(nproc)

# 安装
echo "安装RecastNavigation..."
make install

echo "RecastNavigation编译完成！"

# 复制头文件到lualib-src
echo "复制头文件..."
mkdir -p ../../lualib-src/recast
cp -r ../../$RECAST_DIR/install/include/* ../../lualib-src/recast/

# 复制库文件
echo "复制库文件..."
mkdir -p ../../lualib-src/lib
cp ../../$RECAST_DIR/install/lib/*.a ../../lualib-src/lib/

cd ../../
rm -f luaclib/recast.so
make luaclib/recast.so

echo "RecastNavigation集成完成！" 
