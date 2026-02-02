#!/bin/bash
# VERSION = 13.14.2

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.14.2
# 优化: 1. 失败自动重试机制 (错误移至队尾，最大重试5次)
#       2. 严格错误处理 (海报/NFO失败均触发重试)
#       3. 自动跳过已完成任务
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署智能重试版 (V13.14.2)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.14.2"/' package.json

# 2. 升级 organizer.js (重构队列逻辑)
echo "📝 [1/1] 重构刮削核心 (增加重试与跳过逻辑)..."
cat > modules/organizer.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
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

        const res = await axios.post(flareApi, payload, { 
            headers: { 'Content-Type': 'application/json' } 
        });

        if (res.data.status === 'ok') {
            return cheerio.load(res.data.solution.response);
        } else {
            throw new Error(`Flaresolverr: ${res.data.message}`);
        }
    } catch (e) { throw new Error(`MetaReq Err: ${e.message}`); }
}

const Organizer = {
    getState: () => ({ queue: TASKS.length, isRunning: IS_RUNNING, logs: LOGS, stats: STATS }),

    addTask: (resource) => {
        // 🔥 优化1: 自动跳过已整理的任务
        if (resource.is_renamed) {
            // log(`⏭️ 已整理过，自动跳过: ${resource.title}`, 'warn');
            return;
        }

        if (TASKS.length === 0 && !IS_RUNNING) STATS = { total: 0, processed: 0, success: 0, fail: 0, current: '' };
        
        if (!TASKS.find(t => t.id === resource.id)) {
            // 初始化重试计数
            resource.retryCount = 0;
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
            const item = TASKS[0]; // 获取队头，暂不移除
            STATS.current = `${item.title} (第${(item.retryCount||0) + 1}次)`;
            
            try {
                // 执行处理
                const success = await Organizer.processItem(item);
                
                // 移出队头
                TASKS.shift(); 

                if (success) {
                    STATS.processed++;
                    STATS.success++;
                    // 标记数据库为已整理
                    await ResourceMgr.markAsRenamedByTitle(item.title);
                } else {
                    // 🔥 优化2: 失败重试逻辑
                    throw new Error("处理流程未返回成功");
                }
            } catch (e) {
                TASKS.shift(); // 先移出队头
                
                item.retryCount = (item.retryCount || 0) + 1;
                STATS.processed++;

                if (item.retryCount < 5) {
                    log(`⚠️ 失败重试 (${item.retryCount}/5): ${item.title.substring(0, 10)}... - ${e.message}`, 'warn');
                    STATS.fail++; // 暂时记一次失败，但任务没丢
                    TASKS.push(item); // 🔥 重新加到队尾
                    STATS.total++; // 保持进度条逻辑通顺(可选)
                } else {
                    log(`❌ 超过最大重试次数，放弃: ${item.title}`, 'error');
                    STATS.fail++;
                }
            }
            // 稍作休息
            await new Promise(r => setTimeout(r, 2000));
        }
        IS_RUNNING = false;
        STATS.current = '空闲';
        log(`🏁 队列处理完毕`, 'success');
    },

    generateNfo: async (item, standardName) => {
        if (!item.link) throw new Error("无原始链接，无法生成NFO");
        log(`🕷️ 正在抓取元数据...`);
        
        // 这里不捕获错误，直接抛出给 processItem 处理，触发重试
        const $ = await fetchMetaViaFlare(item.link);
        
        const plot = $('.introduction').text().trim() || '无简介';
        const date = $('.date').first().text().replace('发行日期:', '').trim() || '';
        const studio = $('.studio').text().replace('片商:', '').trim() || '';
        const tags = [];
        $('.tag').each((i, el) => tags.push($(el).text().trim()));
        
        let xml = `<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>\n<movie>\n`;
        xml += `  <title>${item.title}</title>\n`;
        xml += `  <originaltitle>${item.code || item.title}</originaltitle>\n`;
        xml += `  <plot>${plot}</plot>\n`;
        xml += `  <releasedate>${date}</releasedate>\n`;
        xml += `  <studio>${studio}</studio>\n`;
        if (item.actor && item.actor !== '未知演员') {
            xml += `  <actor>\n    <name>${item.actor}</name>\n    <type>Actor</type>\n  </actor>\n`;
        }
        tags.forEach(tag => xml += `  <tag>${tag}</tag>\n`);
        xml += `  <thumb>poster.jpg</thumb>\n  <fanart>fanart.jpg</fanart>\n</movie>`;
        
        return Buffer.from(xml, 'utf-8');
    },

    processItem: async (item) => {
        const targetCid = global.CONFIG.targetCid;
        if (!targetCid) throw new Error("未配置目标目录CID");

        const magnetMatch = item.magnets.match(/[a-fA-F0-9]{40}/);
        if (!magnetMatch) throw new Error("无效Hash");
        const hash = magnetMatch[0];

        log(`▶️ 处理: ${item.title.substring(0, 15)}...`);

        // 1. 定位文件夹
        let folderCid = null;
        let retryCount = 0;
        // 查找任务 (如果是重试，文件可能已经改名了，所以这里可能查不到，需要靠后面的searchFile)
        while (retryCount < 5) {
            const task = await Login115.getTaskByHash(hash);
            if (task) {
                if (task.status_code === 2) { 
                    folderCid = task.folder_cid; 
                    log(`✅ [115] 任务已完成`); 
                    break; 
                } 
                else if (task.status_code < 0) throw new Error(`115任务失败/违规: ${task.status_code}`);
            }
            retryCount++;
            await new Promise(r => setTimeout(r, 3000));
        }

        // 2. 如果任务列表没找到，尝试搜索 (可能上次改名了一半失败了，或者已经改好名了)
        if (!folderCid) {
            const cleanTitle = item.title.replace(/[【\[].*?[\]】]/g, '').replace(/[()（）]/g, ' ').substring(0, 6).trim();
            const searchRes = await Login115.searchFile(cleanTitle, 0);
            if (searchRes.data && searchRes.data.length > 0) {
                const folder = searchRes.data.find(f => f.fcid); // 找文件夹
                if (folder) { folderCid = folder.cid; log(`✅ 搜索命中: ${folder.n}`); }
            }
        }

        if (!folderCid) throw new Error("无法定位文件夹(未下载或被删)");

        // 3. 构造标准名称
        let actor = item.actor;
        let title = item.title;
        if (!actor || actor === '未知演员') {
            const match = title.match(/^(.*?)\s*[（(](.*)[）)]$/);
            if (match) { title = match[1].trim(); actor = match[2].trim(); }
        }
        let standardName = title;
        if (actor && actor !== '未知演员') standardName = `${actor} - ${title}`;
        standardName = standardName.replace(/[\\/:*?"<>|]/g, "").replace(/\s+/g, ' ').trim();
        if(standardName.length > 200) standardName = standardName.substring(0, 200);

        // 4. 处理视频文件
        const fileList = await Login115.getFileList(folderCid);
        if (!fileList.data || fileList.data.length === 0) throw new Error("文件夹为空");

        const files = fileList.data.filter(f => !f.fcid);
        if (files.length > 0) {
            files.sort((a, b) => b.s - a.s);
            const mainVideo = files[0];
            
            // 清理杂文件
            if (files.length > 1) {
                const deleteIds = files.slice(1).map(f => f.fid).join(',');
                await Login115.deleteFiles(deleteIds);
            }

            const ext = mainVideo.n.lastIndexOf('.') > -1 ? mainVideo.n.substring(mainVideo.n.lastIndexOf('.')) : '';
            const newVideoName = standardName + ext;
            if (mainVideo.n !== newVideoName) {
                const renRes = await Login115.rename(mainVideo.fid, newVideoName);
                if (!renRes.success) throw new Error(`视频改名失败: ${renRes.msg}`);
                log(`🎬 视频已规范化`);
            }
        }

        // 5. 海报三件套 (严格模式：失败则抛出异常 -> 重试)
        if (item.image_url) {
            try {
                const imgRes = await axios.get(item.image_url, { responseType: 'arraybuffer', timeout: 15000 });
                const imgBuffer = imgRes.data;
                const targets = ['poster.jpg', 'thumb.jpg', 'fanart.jpg'];
                
                log(`🖼️ 上传海报...`);
                for (const targetName of targets) {
                    // 检查是否已存在 (避免重复上传)
                    const existCheck = fileList.data.find(f => f.n === targetName);
                    if (existCheck) continue;

                    const tempName = `${hash.substring(0,5)}_${targetName}`;
                    const fid = await Login115.uploadFile(imgBuffer, tempName);
                    if (!fid) throw new Error(`${targetName} 直传失败`);
                    
                    await Login115.move(fid, folderCid);
                    await Login115.rename(fid, targetName);
                }
            } catch (imgErr) {
                throw new Error(`海报处理失败: ${imgErr.message}`);
            }
        }

        // 6. NFO (严格模式：失败则抛出异常 -> 重试)
        const existNfo = fileList.data.find(f => f.n.endsWith('.nfo'));
        if (!existNfo) {
            try {
                const nfoBuffer = await Organizer.generateNfo(item, standardName);
                const nfoName = `${standardName}.nfo`;
                const tempNfoName = `nfo_${hash.substring(0,5)}.nfo`;
                const nfoFid = await Login115.uploadFile(nfoBuffer, tempNfoName);
                if (!nfoFid) throw new Error("NFO上传失败");
                
                await Login115.move(nfoFid, folderCid);
                await Login115.rename(nfoFid, nfoName);
                log(`📝 NFO已生成`);
            } catch (nfoErr) {
                throw new Error(`NFO生成失败: ${nfoErr.message}`);
            }
        }

        // 7. 文件夹改名 & 移动
        const folderRenRes = await Login115.rename(folderCid, standardName);
        if (!folderRenRes.success) throw new Error(`文件夹改名失败: ${folderRenRes.msg}`);

        const moveRes = await Login115.move(folderCid, targetCid);
        if (!moveRes) throw new Error("移动到目标目录失败");

        log(`🚚 归档成功!`, 'success');
        return true;
    }
};
module.exports = Organizer;
EOF

# 3. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.14.2 智能重试版部署完成！"
