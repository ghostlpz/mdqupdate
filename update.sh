#!/bin/bash
# VERSION = 13.13.4

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.13.4
# 修复: 刮削器死循环问题 (参考 renamer.js 修复 115 字段兼容性)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署字段兼容修复版 (V13.13.4)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.13.4"/' package.json

# 2. 升级 login_115.js (增加字段清洗逻辑)
echo "📝 [1/2] 升级 115 API (统一字段格式)..."
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
            const url = `https://webapi.115.com/files?aid=1&cid=${cid}&o=user_ptime&asc=0&show_dir=1&limit=100`;
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

    // 🔥 核心升级：增加字段兼容性处理
    async getTaskByHash(hash) {
        if (!global.CONFIG.cookie115) return null;
        try {
            const cleanHash = hash.toLowerCase().trim();
            // 扫描前 5 页 (增加扫描范围，防止任务被挤下去)
            for (let page = 1; page <= 5; page++) {
                const url = `https://115.com/web/lixian/?ct=lixian&ac=task_lists&page=${page}`;
                const res = await axios.get(url, { headers: this.getHeaders() });
                
                if (res.data && res.data.tasks) {
                    const tasks = res.data.tasks;
                    for (const task of tasks) {
                        // 1. 匹配 Hash (兼容 info_hash 和 hash)
                        const tHash = task.info_hash || task.hash;
                        if (tHash === cleanHash) {
                            // 2. 统一字段 (参考 renamer.js 逻辑)
                            const normalizedTask = {
                                ...task,
                                // 统一文件ID
                                folder_cid: task.file_id || task.cid || task.id,
                                // 统一进度
                                percent: (task.percent !== undefined) ? task.percent : (task.percentDone !== undefined ? task.percentDone : 0),
                                // 统一状态
                                status_code: (task.state !== undefined) ? task.state : (task.status !== undefined ? task.status : -1),
                                name: task.name
                            };
                            return normalizedTask;
                        }
                    }
                }
            }
        } catch (e) { console.error("GetTaskErr:", e.message); }
        return null;
    }
};
module.exports = Login115;
EOF

# 3. 升级 organizer.js (使用统一后的字段)
echo "📝 [2/2] 升级整理核心 (逻辑修正)..."
cat > modules/organizer.js << 'EOF'
const Login115 = require('./login_115');
const ResourceMgr = require('./resource_mgr');

let TASKS = []; 
let IS_RUNNING = false;
let LOGS = [];
let STATS = { total: 0, processed: 0, success: 0, fail: 0, current: '' };

function log(msg, type = 'info') {
    const time = new Date().toLocaleTimeString();
    console.log(`[Organizer ${time}] ${msg}`);
    LOGS.push({ time, msg, type });
    if (LOGS.length > 200) LOGS.shift();
}

const Organizer = {
    getState: () => ({ queue: TASKS.length, isRunning: IS_RUNNING, logs: LOGS, stats: STATS }),

    addTask: (resource) => {
        if (TASKS.length === 0 && !IS_RUNNING) STATS = { total: 0, processed: 0, success: 0, fail: 0, current: '' };
        if (!TASKS.find(t => t.id === resource.id)) {
            TASKS.push(resource);
            STATS.total++;
            log(`➕ 加入队列: ${resource.title.substring(0, 15)}...`, 'info');
            Organizer.run();
        }
    },

    run: async () => {
        if (IS_RUNNING || TASKS.length === 0) return;
        IS_RUNNING = true;

        while (TASKS.length > 0) {
            const item = TASKS[0];
            STATS.current = item.title;
            try {
                const success = await Organizer.processItem(item);
                TASKS.shift(); 
                STATS.processed++;
                if (success) STATS.success++; else STATS.fail++;
            } catch (e) {
                log(`❌ 异常: ${item.title} - ${e.message}`, 'error');
                TASKS.shift();
                STATS.processed++;
                STATS.fail++;
            }
            await new Promise(r => setTimeout(r, 2000));
        }
        IS_RUNNING = false;
        STATS.current = '空闲';
        log(`🏁 队列处理完毕`, 'success');
    },

    processItem: async (item) => {
        const targetCid = global.CONFIG.targetCid;
        if (!targetCid) { log("❌ 未配置目标目录CID", 'error'); return false; }

        const magnetMatch = item.magnets.match(/[a-fA-F0-9]{40}/);
        if (!magnetMatch) { log(`❌ 无效Hash`, 'error'); return false; }
        const hash = magnetMatch[0];

        log(`▶️ 处理: ${item.title.substring(0, 15)}...`);

        let folderCid = null;
        let retryCount = 0;
        const maxRetries = 10; 

        while (retryCount < maxRetries) {
            // 获取清洗后的任务对象
            const task = await Login115.getTaskByHash(hash);
            
            if (task) {
                // 使用统一后的 status_code
                if (task.status_code === 2) {
                    folderCid = task.folder_cid;
                    log(`✅ [115] 下载完成 (CID: ${folderCid})`);
                    break;
                } else if (task.status_code < 0) {
                    log(`❌ [115] 任务失败/违规 (Code: ${task.status_code})`, 'error');
                    return false;
                } else {
                    log(`⏳ [115] 下载中... ${task.percent.toFixed(2)}%`);
                }
            } else {
                log(`⚠️ [115] 未找到任务，尝试搜索模式...`);
                break;
            }
            retryCount++;
            await new Promise(r => setTimeout(r, 5000)); 
        }

        if (!folderCid) {
            const cleanTitle = item.title.replace(/[【\[].*?[\]】]/g, '').replace(/[()（）]/g, ' ').substring(0, 6).trim();
            const searchRes = await Login115.searchFile(cleanTitle, 0);
            if (searchRes.data && searchRes.data.length > 0) {
                const folder = searchRes.data.find(f => f.fcid);
                if (folder) { folderCid = folder.cid; log(`✅ 搜索命中: ${folder.n}`); }
            }
        }

        if (!folderCid) { log(`❌ 无法定位文件夹`, 'error'); return false; }

        try {
            const fileList = await Login115.getFileList(folderCid);
            if (fileList.data && fileList.data.length > 0) {
                const files = fileList.data.filter(f => !f.fcid);
                if (files.length > 1) {
                    files.sort((a, b) => b.s - a.s);
                    const deleteIds = files.slice(1).map(f => f.fid).join(',');
                    if (deleteIds) {
                        await Login115.deleteFiles(deleteIds);
                        log(`🧹 清理杂文件: ${files.length - 1}个`);
                    }
                }
            }

            if (item.image_url) await Login115.addTask(item.image_url, folderCid);

            let newFolderName = item.title;
            if (item.actor && item.actor !== '未知演员') newFolderName = `${item.actor} - ${item.title}`;
            newFolderName = newFolderName.replace(/[\\/:*?"<>|]/g, " ").trim();
            
            // 重命名文件夹
            await Login115.rename(folderCid, newFolderName);
            
            // 移动
            const moveRes = await Login115.move(folderCid, targetCid);
            if (moveRes) {
                log(`🚚 归档成功!`, 'success');
                await ResourceMgr.markAsRenamedByTitle(item.title);
                return true;
            } else {
                log(`❌ 移动失败`, 'error');
                return false;
            }
        } catch (err) {
            log(`⚠️ 整理异常: ${err.message}`, 'warn');
            return false;
        }
    }
};
module.exports = Organizer;
EOF

# 4. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.13.4 部署完成！"
