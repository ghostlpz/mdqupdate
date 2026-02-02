#!/bin/bash
# VERSION = 13.13.5

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.13.5
# 修复: 1. 刮削逻辑升级 (视频/文件夹 改名为 演员-标题)
#       2. 海报改为"直传"模式，不占用115离线配额
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署完美刮削版 (V13.13.5)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.13.5"/' package.json

# 2. 升级 login_115.js (增加直传功能)
echo "📝 [1/2] 升级 115 API (支持直传)..."
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

    async getTaskByHash(hash) {
        if (!global.CONFIG.cookie115) return null;
        try {
            const cleanHash = hash.toLowerCase().trim();
            for (let page = 1; page <= 5; page++) {
                const url = `https://115.com/web/lixian/?ct=lixian&ac=task_lists&page=${page}`;
                const res = await axios.get(url, { headers: this.getHeaders() });
                if (res.data && res.data.tasks) {
                    for (const task of res.data.tasks) {
                        const tHash = task.info_hash || task.hash;
                        if (tHash === cleanHash) {
                            return {
                                ...task,
                                folder_cid: task.file_id || task.cid || task.id,
                                percent: (task.percent !== undefined) ? task.percent : (task.percentDone !== undefined ? task.percentDone : 0),
                                status_code: (task.state !== undefined) ? task.state : (task.status !== undefined ? task.status : -1),
                                name: task.name
                            };
                        }
                    }
                }
            }
        } catch (e) { console.error("GetTaskErr:", e.message); }
        return null;
    },

    // 🔥 新增：文件直传 (不消耗离线配额)
    async uploadFile(fileBuffer, fileName) {
        try {
            // 1. 获取上传参数
            const infoRes = await axios.get('https://proapi.115.com/app/uploadinfo', { headers: this.getHeaders() });
            if (!infoRes.data || !infoRes.data.state) throw new Error("获取上传信息失败");
            const info = infoRes.data.data;

            // 2. 构造表单 (使用 Node 20 原生 FormData)
            const formData = new FormData();
            formData.append('name', fileName);
            formData.append('key', info.object + fileName);
            formData.append('policy', info.policy);
            formData.append('OSSAccessKeyId', info.accessid);
            formData.append('success_action_status', '200');
            formData.append('callback', info.callback);
            formData.append('signature', info.signature);
            // 构造 Blob
            const blob = new Blob([fileBuffer]);
            formData.append('file', blob, fileName);

            // 3. 上传到阿里云 OSS
            const uploadRes = await fetch(info.host, {
                method: 'POST',
                headers: { 'User-Agent': this.userAgent },
                body: formData
            });
            const text = await uploadRes.text();
            
            // 4. 上传后文件通常在根目录(cid=0)，我们需要找到它并返回 file_id
            if (text.includes('"state":true') || text.includes('"state": true')) {
                // 稍微等待 115 索引
                await new Promise(r => setTimeout(r, 2000));
                // 搜索文件获取 ID (为了准确，搜索文件名)
                const searchRes = await this.searchFile(fileName, 0);
                if (searchRes.data && searchRes.data.length > 0) {
                    // 找到最新创建的同名文件
                    const file = searchRes.data.find(f => f.n === fileName);
                    if (file) return file.fid;
                }
            }
            return null;
        } catch (e) {
            console.error("Upload Failed:", e.message);
            return null;
        }
    }
};
module.exports = Login115;
EOF

# 3. 升级 organizer.js (完美重命名逻辑)
echo "📝 [2/2] 升级整理核心 (命名规范化)..."
cat > modules/organizer.js << 'EOF'
const axios = require('axios'); // 需要 axios 下载图片
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
                TASKS.shift(); STATS.processed++; STATS.fail++;
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

        // 1. 定位文件夹
        let folderCid = null;
        let retryCount = 0;
        while (retryCount < 12) {
            const task = await Login115.getTaskByHash(hash);
            if (task) {
                if (task.status_code === 2) { folderCid = task.folder_cid; log(`✅ [115] 下载完成`); break; } 
                else if (task.status_code < 0) { log(`❌ 任务失败/违规`, 'error'); return false; }
                else { log(`⏳ 下载中... ${task.percent.toFixed(1)}%`); }
            } else { break; } // 查不到可能已完成
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

        // 2. 构造标准名称: "演员 - 标题"
        let standardName = item.title;
        if (item.actor && item.actor !== '未知演员') {
            standardName = `${item.actor} - ${item.title}`;
        }
        // 去除非法字符
        standardName = standardName.replace(/[\\/:*?"<>|]/g, " ").trim();

        try {
            // 3. 处理文件夹内文件 (保留最大视频并重命名)
            const fileList = await Login115.getFileList(folderCid);
            if (fileList.data && fileList.data.length > 0) {
                const files = fileList.data.filter(f => !f.fcid); // 只看文件
                if (files.length > 0) {
                    // 按大小降序，取最大的作为主视频
                    files.sort((a, b) => b.s - a.s);
                    const mainVideo = files[0];
                    
                    // 删除其他杂文件
                    if (files.length > 1) {
                        const deleteIds = files.slice(1).map(f => f.fid).join(',');
                        await Login115.deleteFiles(deleteIds);
                        log(`🧹 清理杂文件: ${files.length - 1} 个`);
                    }

                    // 重命名主视频: 演员 - 标题.mp4
                    const ext = mainVideo.n.lastIndexOf('.') > -1 ? mainVideo.n.substring(mainVideo.n.lastIndexOf('.')) : '';
                    const newVideoName = standardName + ext;
                    if (mainVideo.n !== newVideoName) {
                        await Login115.rename(mainVideo.fid, newVideoName);
                        log(`🎬 视频重命名: ${newVideoName}`);
                    }
                }
            }

            // 4. 上传海报 (直传模式)
            if (item.image_url) {
                log(`🖼️ 正在下载并上传海报...`);
                try {
                    // 下载图片到内存
                    const imgRes = await axios.get(item.image_url, { responseType: 'arraybuffer', timeout: 10000 });
                    if (imgRes.status === 200) {
                        // 使用唯一临时名上传，防止 poster.jpg 冲突
                        const tempName = `poster_${hash.substring(0,6)}.jpg`;
                        const uploadedFid = await Login115.uploadFile(imgRes.data, tempName);
                        
                        if (uploadedFid) {
                            // 移动到目标文件夹
                            await Login115.move(uploadedFid, folderCid);
                            // 改名为 poster.jpg
                            await Login115.rename(uploadedFid, 'poster.jpg');
                            log(`✅ 海报上传成功 (不占离线配额)`);
                        } else {
                            log(`⚠️ 海报上传失败 (接口未返回ID)`, 'warn');
                        }
                    }
                } catch (imgErr) {
                    log(`⚠️ 海报处理失败: ${imgErr.message}`, 'warn');
                }
            }

            // 5. 重命名文件夹 & 移动
            await Login115.rename(folderCid, standardName);
            const moveRes = await Login115.move(folderCid, targetCid);
            
            if (moveRes) {
                log(`🚚 归档成功: [${standardName}]`, 'success');
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

echo "✅ [完成] 完美刮削版 V13.13.5 部署完成！"
