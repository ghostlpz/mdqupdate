#!/bin/bash

# 1. 定义新版本号 (比当前版本大)
NEW_VERSION="13.16.1"

echo "🚀 [Update] 开始执行在线更新 v$NEW_VERSION ..."

# 确保进入应用目录
cd /app

# 2. 更新版本号 (让前端能看到变化)
# 修改 app.js 中的版本号
sed -i "s/global.CURRENT_VERSION = '.*';/global.CURRENT_VERSION = '$NEW_VERSION';/" app.js
# 修改 package.json (如果存在)
if [ -f "package.json" ]; then
    sed -i 's/"version": ".*"/"version": "'$NEW_VERSION'"/' package.json
fi

# 3. 覆盖 organizer.js (精准修改海报命名)
cat > modules/organizer.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const fs = require('fs');
const path = require('path');
const Login115 = require('./login_115');
const ResourceMgr = require('./resource_mgr');

// M3U8 任务由外部服务全权处理，Organizer 不再需要处理 PikPak/M3U8 逻辑
// 本模块现在仅服务于 115 磁力链任务

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

function getFlareUrl() {
    let url = global.CONFIG.flaresolverrUrl || 'http://flaresolverr:8191';
    if (url.endsWith('/')) url = url.slice(0, -1);
    if (!url.endsWith('/v1')) url += '/v1';
    return url;
}

async function fetchMetaViaFlare(url) {
    const flareApi = getFlareUrl();
    try {
        const payload = { cmd: 'request.get', url: url, maxTimeout: 60000 };
        if (global.CONFIG.proxy) payload.proxy = { url: global.CONFIG.proxy };
        const res = await axios.post(flareApi, payload, { headers: { 'Content-Type': 'application/json' } });
        if (res.data.status === 'ok') return cheerio.load(res.data.solution.response);
        throw new Error(`Flaresolverr: ${res.data.message}`);
    } catch (e) { throw new Error(`MetaReq Err: ${e.message}`); }
}

const Organizer = {
    getState: () => ({ queue: TASKS.length, isRunning: IS_RUNNING, logs: LOGS, stats: STATS }),

    addTask: (resource) => {
        if (resource.is_renamed) return;
        // 🚨 拦截 M3U8 任务，不进入队列
        if (resource.magnets && (resource.magnets.startsWith('m3u8|') || resource.magnets.startsWith('pikpak|'))) {
            log(`⏭️ 跳过 M3U8 任务 (外部处理): ${resource.title}`, 'warn');
            return;
        }

        if (TASKS.length === 0 && !IS_RUNNING) STATS = { total: 0, processed: 0, success: 0, fail: 0, current: '' };
        if (!TASKS.find(t => t.id === resource.id)) {
            resource.retryCount = 0;
            resource.driveType = '115';
            resource.realMagnet = resource.magnets;
            
            TASKS.push(resource);
            STATS.total++;
            log(`➕ 加入队列 [115]: ${resource.title.substring(0, 15)}...`, 'info');
            Organizer.run();
        }
    },

    run: async () => {
        if (IS_RUNNING || TASKS.length === 0) return;
        IS_RUNNING = true;
        while (TASKS.length > 0) {
            const item = TASKS[0];
            STATS.current = `${item.title}`;
            try {
                const success = await Organizer.processItem(item);
                TASKS.shift(); 
                if (success) {
                    STATS.processed++; STATS.success++;
                    await ResourceMgr.markAsRenamedByTitle(item.title);
                } else { throw new Error("流程未完成"); }
            } catch (e) {
                TASKS.shift();
                item.retryCount = (item.retryCount || 0) + 1;
                STATS.processed++;
                if (item.retryCount < 5) {
                    log(`⚠️ 重试 (${item.retryCount}/5): ${e.message}`, 'warn');
                    STATS.fail++; TASKS.push(item); STATS.total++;
                } else {
                    log(`❌ 放弃: ${item.title}`, 'error'); STATS.fail++;
                }
            }
            await new Promise(r => setTimeout(r, 2000));
        }
        IS_RUNNING = false; STATS.current = '空闲'; log(`🏁 队列完毕`, 'success');
    },
    
    generateNfo: async (item, standardName) => {
        if (!item.link) return null;
        log(`🕷️ 抓取元数据...`);
        try {
            const $ = await fetchMetaViaFlare(item.link);
            const plot = $('.introduction').text().trim() || '无简介';
            const date = $('.date').first().text().replace('发行日期:', '').trim() || '';
            const studio = $('.studio').text().replace('片商:', '').trim() || '';
            const tags = []; $('.tag').each((i, el) => tags.push($(el).text().trim()));
            
            let xml = `<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>\n<movie>\n`;
            xml += `  <title>${item.title}</title>\n  <originaltitle>${item.code}</originaltitle>\n  <plot>${plot}</plot>\n  <releasedate>${date}</releasedate>\n  <studio>${studio}</studio>\n`;
            if (item.actor) xml += `  <actor>\n    <name>${item.actor}</name>\n    <type>Actor</type>\n  </actor>\n`;
            tags.forEach(tag => xml += `  <tag>${tag}</tag>\n`);
            xml += `  <thumb>poster.jpg</thumb>\n  <fanart>fanart.jpg</fanart>\n</movie>`;
            return Buffer.from(xml, 'utf-8');
        } catch(e) { 
            log(`⚠️ 元数据抓取部分失败: ${e.message}`, 'warn');
            return null; 
        }
    },

    processItem: async (item) => {
        const Driver = Login115;
        const targetCid = global.CONFIG.targetCid;
        
        if (!targetCid) throw new Error("未配置目标目录ID");

        log(`▶️ 开始处理 [115]: ${item.title}`);

        // 1. 定位资源
        let resourceId = null;
        let isDirectory = false;
        let retryCount = 0;
        
        while (retryCount < 5) {
            const query = (item.realMagnet.match(/[a-fA-F0-9]{40}/) || [])[0];
            if (query) {
                const task = await Driver.getTaskByHash(query);
                if (task && task.status_code === 2) {
                    if (task.folder_cid && task.folder_cid !== '0') {
                        resourceId = task.folder_cid;
                        isDirectory = true;
                    } else {
                        resourceId = task.file_id;
                        isDirectory = false;
                    }
                    log(`✅ 任务已就绪 (类型: ${isDirectory ? '文件夹' : '单文件'})`);
                    break;
                }
            }
            retryCount++;
            await new Promise(r => setTimeout(r, 3000));
        }

        if (!resourceId) {
            const cleanTitle = item.title.replace(/[【\[].*?[\]】]/g, '').substring(0, 6).trim();
            const searchRes = await Driver.searchFile(cleanTitle, 0); 
            if (searchRes.data && searchRes.data.length > 0) {
                const hit = searchRes.data[0];
                resourceId = hit.fcid || hit.fid;
                isDirectory = !!hit.fcid;
                log(`✅ 搜索命中: ${hit.n}`);
            }
        }

        if (!resourceId) throw new Error("无法定位资源");

        // 2. 构造名称
        let actor = item.actor;
        let title = item.title;
        if (!actor || actor === '未知演员') {
            const match = title.match(/^(.*?)\s*[（(](.*)[）)]$/);
            if (match) { title = match[1].trim(); actor = match[2].trim(); }
        }
        let standardName = `${actor && actor!=='未知演员' ? actor+' - ' : ''}${title}`.trim();
        standardName = standardName.replace(/[\\/:*?"<>|]/g, "").trim().substring(0, 200);

        let finalFolderCid = null;

        // 3. 结构处理
        if (isDirectory) {
            await Driver.rename(resourceId, standardName);
            finalFolderCid = resourceId;
        } else {
            log(`🛠️ 单文件任务，创建整理目录: ${standardName}`);
            const mkdirRes = await Driver.mkdir(targetCid, standardName);
            if (!mkdirRes || (!mkdirRes.cid && !mkdirRes.file_id)) {
                 throw new Error("创建目录失败");
            }
            finalFolderCid = mkdirRes.cid || mkdirRes.file_id;
            await Driver.move(resourceId, finalFolderCid);
        }

        // 4. 清理与改名
        const fileListRes = await Driver.getFileList(finalFolderCid);
        if (fileListRes && fileListRes.data) {
            let files = fileListRes.data;
            const videoFiles = files.filter(f => !f.fcid && (f.fv || (f.n && f.n.match(/\.(mp4|mkv|avi|wmv|mov|ts)$/i))));
            
            if (videoFiles.length > 0) {
                videoFiles.sort((a, b) => (b.s || 0) - (a.s || 0));
                const mainVideo = videoFiles[0];
                log(`🎥 锁定主视频: ${mainVideo.n} (${(mainVideo.s/1024/1024).toFixed(1)}MB)`);

                const filesToDelete = files.filter(f => f.fid !== mainVideo.fid);
                if (filesToDelete.length > 0) {
                    log(`🧹 正在清理 ${filesToDelete.length} 个杂乱文件...`);
                    await Promise.all(filesToDelete.map(f => Driver.deleteFiles(f.fid).catch(e => {})));
                }

                const ext = path.extname(mainVideo.n) || '.mp4';
                const newVideoName = `${standardName}${ext}`;
                if (mainVideo.n !== newVideoName) {
                    await Driver.rename(mainVideo.fid, newVideoName);
                    log(`🏷️ 视频重命名完毕: ${newVideoName}`);
                }
            }
        }

        // 5. 本地海报强制读取逻辑 (核心修复)
        try {
            // 🔥 读取 image_url 或 image
            const rawPath = item.image_url || item.image; 

            log(`🖼️ 检查海报配置: DB路径=[${rawPath || '空'}]`);

            if (rawPath && !rawPath.startsWith('http')) {
                const cleanPath = rawPath.startsWith('/') ? rawPath.slice(1) : rawPath;
                const localPath = path.join(__dirname, '../public', cleanPath);

                log(`🔍 [海报] 尝试读取本地文件: ${localPath}`);

                if (fs.existsSync(localPath)) {
                    const posterData = fs.readFileSync(localPath);
                    log(`✅ [海报] 读取成功 (${(posterData.length/1024).toFixed(1)}KB), 正在上传3份...`);
                    
                    // 🔥🔥 修正：海报命名更改为 thumb, poster, fanart
                    await Driver.uploadFile(posterData, "poster.jpg", finalFolderCid);
                    await Driver.uploadFile(posterData, "thumb.jpg", finalFolderCid);
                    await Driver.uploadFile(posterData, "fanart.jpg", finalFolderCid);
                    log(`✅ [海报] 上传完毕 (已重命名)`);
                } else {
                    log(`❌ [海报] 文件丢失: 数据库记录为 ${rawPath} 但本地未找到`, 'error');
                }
            } else {
                if (rawPath) log(`ℹ️ [海报] 忽略远程链接: ${rawPath} (仅使用本地文件)`, 'warn');
                else log(`⚠️ [海报] 数据库无图片记录`, 'warn');
            }

            // 生成并上传 NFO
            const nfoBuf = await Organizer.generateNfo(item, standardName);
            if (nfoBuf) {
                await Driver.uploadFile(nfoBuf, `${standardName}.nfo`, finalFolderCid);
                log(`✅ NFO 元数据上传完毕`);
            }
        } catch(e) { log(`⚠️ 资源整理失败: ${e.message}`, 'error'); }

        if (isDirectory) {
            await Driver.move(finalFolderCid, targetCid);
            log(`🚚 文件夹归档完成`);
        }
        return true;
    }
};
module.exports = Organizer;
EOF

echo "✅ 更新脚本执行完毕，系统即将自动重启..."
