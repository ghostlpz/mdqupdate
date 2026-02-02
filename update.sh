#!/bin/bash
# VERSION = 13.12.1

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.12.1
# 修复: 刮削找不到文件夹的问题 (改为通过 Hash 查任务 + 等待下载完成)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署精准定位版 (V13.12.1)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.12.1"/' package.json

# 2. 升级 login_115.js (增加按 Hash 查任务功能)
echo "📝 [1/2] 升级 115 API (支持 Hash 反查)..."
cat > modules/login_115.js << 'EOF'
const axios = require('axios');
const fs = require('fs');

const Login115 = {
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36',
    
    getHeaders() {
        return {
            'Cookie': global.CONFIG.cookie115,
            'User-Agent': this.userAgent,
            'Content-Type': 'application/x-www-form-urlencoded'
        };
    },

    async getQrCode() {
        const res = await axios.get('https://qrcodeapi.115.com/api/1.0/web/1.0/token');
        return res.data.data;
    },

    async checkStatus(uid, time, sign) {
        const url = `https://qrcodeapi.115.com/api/1.0/web/1.0/status?uid=${uid}&time=${time}&sign=${sign}&_=${Date.now()}`;
        const res = await axios.get(url);
        return res.data.data;
    },

    async getFileList(cid = 0) {
        if (!global.CONFIG.cookie115) return { data: [] };
        try {
            const url = `https://webapi.115.com/files?aid=1&cid=${cid}&o=user_ptime&asc=0&offset=0&show_dir=1&limit=100`;
            const res = await axios.get(url, { headers: this.getHeaders() });
            return res.data;
        } catch (e) { return { data: [] }; }
    },

    async searchFile(keyword, cid = 0) {
        try {
            const url = `https://webapi.115.com/files/search?offset=0&limit=100&search_value=${encodeURIComponent(keyword)}&cid=${cid}`;
            const res = await axios.get(url, { headers: this.getHeaders() });
            return res.data;
        } catch (e) { return { data: [] }; }
    },

    async rename(fileId, newName) {
        try {
            const postData = `fid=${fileId}&file_name=${encodeURIComponent(newName)}`;
            const res = await axios.post('https://webapi.115.com/files/rename', postData, { headers: this.getHeaders() });
            return res.data.state;
        } catch (e) { return false; }
    },

    async move(fileIds, targetCid) {
        try {
            const postData = `pid=${targetCid}&fid=${fileIds}`;
            const res = await axios.post('https://webapi.115.com/files/move', postData, { headers: this.getHeaders() });
            return res.data.state;
        } catch (e) { return false; }
    },

    async deleteFiles(fileIds) {
        try {
            const postData = `fid=${fileIds}`;
            const res = await axios.post('https://webapi.115.com/rb/delete', postData, { headers: this.getHeaders() });
            return res.data.state;
        } catch (e) { return false; }
    },

    async addTask(url, wp_path_id = null) {
        if (!global.CONFIG.cookie115) return false;
        try {
            let postData = `url=${encodeURIComponent(url)}`;
            if (wp_path_id) postData += `&wp_path_id=${wp_path_id}`;
            const res = await axios.post('https://115.com/web/lixian/?ct=lixian&ac=add_task_url', postData, {
                headers: this.getHeaders()
            });
            return res.data && res.data.state;
        } catch (e) { return false; }
    },

    // 🔥 新增：通过 Hash 查找任务状态
    async getTaskByHash(hash) {
        if (!global.CONFIG.cookie115) return null;
        try {
            const cleanHash = hash.toLowerCase().trim();
            // 扫描前 3 页任务列表 (通常刚推的任务都在第1页)
            for (let page = 1; page <= 3; page++) {
                const url = `https://115.com/web/lixian/?ct=lixian&ac=task_lists&page=${page}`;
                const res = await axios.get(url, { headers: this.getHeaders() });
                if (res.data && res.data.tasks) {
                    const task = res.data.tasks.find(t => (t.info_hash === cleanHash) || (t.hash === cleanHash));
                    if (task) return task;
                }
            }
        } catch (e) { console.error("GetTaskErr:", e.message); }
        return null;
    }
};
module.exports = Login115;
EOF

# 3. 升级 organizer.js (增加等待逻辑)
echo "📝 [2/2] 升级整理核心 (等待下载+精准匹配)..."
cat > modules/organizer.js << 'EOF'
const Login115 = require('./login_115');
const ResourceMgr = require('./resource_mgr');

let TASKS = []; 
let IS_RUNNING = false;

function log(msg, type = 'info') {
    console.log(`[Organizer] ${msg}`);
}

const Organizer = {
    getState: () => ({ queue: TASKS.length, isRunning: IS_RUNNING }),

    addTask: (resource) => {
        // 去重
        if (!TASKS.find(t => t.id === resource.id)) {
            TASKS.push(resource);
            log(`➕ 加入整理队列: ${resource.title}`, 'info');
            Organizer.run();
        }
    },

    run: async () => {
        if (IS_RUNNING || TASKS.length === 0) return;
        IS_RUNNING = true;

        while (TASKS.length > 0) {
            const item = TASKS[0]; // 这是一个 peek，成功后再 shift
            try {
                const success = await Organizer.processItem(item);
                if (success) {
                    TASKS.shift(); // 处理成功，移除
                } else {
                    // 如果是还没下载完，就暂时跳过它，放到队尾，或者等待
                    // 为了简单，我们把它放到队尾，先处理别的
                    TASKS.shift();
                    // 如果是因为下载中，可以考虑放回队尾: TASKS.push(item); 
                    // 但为了防止死循环堵塞，这里暂时只尝试一次流程，
                    // 只有在明确是“下载中”状态时，processItem 内部会等待。
                }
            } catch (e) {
                log(`❌ 异常: ${item.title} - ${e.message}`, 'error');
                TASKS.shift(); // 异常任务移除
            }
            await new Promise(r => setTimeout(r, 2000));
        }
        IS_RUNNING = false;
        log(`🏁 整理队列处理完毕`, 'success');
    },

    processItem: async (item) => {
        const targetCid = global.CONFIG.targetCid;
        if (!targetCid) { log("未配置目标目录CID", 'error'); return true; }

        // 提取 Hash
        const magnetMatch = item.magnets.match(/[a-fA-F0-9]{40}/);
        if (!magnetMatch) { log(`❌ 无法提取Hash: ${item.title}`, 'error'); return true; }
        const hash = magnetMatch[0];

        log(`🔍 正在定位任务: ${item.title.substring(0, 10)}...`);

        // 1. 核心逻辑：循环检查 115 任务状态 (最多等 5 分钟)
        let folderCid = null;
        let retryCount = 0;
        const maxRetries = 30; // 30 * 10s = 300s = 5分钟

        while (retryCount < maxRetries) {
            const task = await Login115.getTaskByHash(hash);
            
            if (task) {
                if (task.state === 2) {
                    // 下载成功 (state=2)
                    folderCid = task.file_id || task.cid;
                    if (folderCid) {
                        log(`✅ 任务已完成，文件夹CID: ${folderCid}`);
                        break; 
                    }
                } else {
                    // 下载中 (state=1) 或其他
                    const percent = task.percent || 0;
                    log(`⏳ 下载中... ${percent}% (等待 10s)`);
                }
            } else {
                // 任务列表没找到，可能是很久以前的任务，或者是被删除了
                log(`⚠️ 任务列表中未找到，尝试直接搜索文件名...`);
                break; // 跳出循环，去尝试备用方案
            }

            retryCount++;
            await new Promise(r => setTimeout(r, 10000)); // 等待 10 秒
        }

        // 2. 备用方案：如果任务列表没找到，尝试搜名字
        if (!folderCid) {
            // 净化标题用于搜索 (去除特殊符号)
            const cleanTitle = item.title.replace(/[【】\[\]()（）]/g, ' ').substring(0, 8).trim();
            const searchRes = await Login115.searchFile(cleanTitle, 0);
            if (searchRes.data && searchRes.data.length > 0) {
                const folder = searchRes.data.find(f => f.fcid);
                if (folder) {
                    folderCid = folder.cid;
                    log(`🔍 通过搜索找到文件夹: ${folder.n}`);
                }
            }
        }

        if (!folderCid) {
            log(`❌ 最终未找到对应文件夹，跳过`, 'warn');
            return true; // 视为处理结束，以免卡死队列
        }

        // 3. 开始整理操作
        try {
            // 清理文件
            const fileList = await Login115.getFileList(folderCid);
            if (fileList.data && fileList.data.length > 0) {
                const files = fileList.data.filter(f => !f.fcid);
                if (files.length > 0) {
                    // 保留最大的文件
                    files.sort((a, b) => b.s - a.s);
                    const keepFile = files[0];
                    const deleteIds = files.slice(1).map(f => f.fid).join(',');
                    if (deleteIds) {
                        await Login115.deleteFiles(deleteIds);
                        log(`🧹 清理了 ${files.length - 1} 个杂文件`);
                    }
                    // 可选：把视频文件重命名和标题一致
                    // await Login115.rename(keepFile.fid, item.title + ".mp4");
                }
            }

            // 下载海报
            if (item.image_url) {
                await Login115.addTask(item.image_url, folderCid);
                log(`🖼️ 已添加海报下载任务`);
            }

            // 重命名文件夹
            let newFolderName = item.title;
            if (item.actor && item.actor !== '未知演员') {
                newFolderName = `${item.actor} - ${item.title}`;
            }
            newFolderName = newFolderName.replace(/[\\/:*?"<>|]/g, " ");
            
            await Login115.rename(folderCid, newFolderName);
            log(`✏️ 文件夹重命名: ${newFolderName}`);

            // 移动
            const moveRes = await Login115.move(folderCid, targetCid);
            if (moveRes) {
                log(`🚚 归档成功!`, 'success');
                await ResourceMgr.markAsRenamedByTitle(item.title);
            } else {
                log(`❌ 移动失败`);
            }

        } catch (err) {
            log(`⚠️ 整理过程部分失败: ${err.message}`);
        }

        return true;
    }
};

module.exports = Organizer;
EOF

# 4. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.12.1 部署完成。"
