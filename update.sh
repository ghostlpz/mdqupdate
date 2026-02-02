#!/bin/bash
# VERSION = 13.13.9

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.13.9
# 功能: 1. NFO 元数据生成 (集成 Flaresolverr 抓取)
#       2. 海报/Fanart/Thumb 三件套上传 (严格直传)
#       3. 命名严格标准化
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署全能刮削版 (V13.13.9)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.13.9"/' package.json

# 2. 升级 organizer.js (集成爬虫与NFO生成)
echo "📝 [1/1] 升级整理核心 (NFO生成 + 海报三件套)..."
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

// 获取 Flaresolverr 地址
function getFlareUrl() {
    let url = global.CONFIG.flaresolverrUrl || 'http://flaresolverr:8191';
    if (url.endsWith('/')) url = url.slice(0, -1);
    if (!url.endsWith('/v1')) url += '/v1';
    return url;
}

// 独立的爬虫请求函数
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

    // 生成 NFO 内容
    async generateNfo(item, standardName) {
        if (!item.link) return null;
        log(`🕷️ 正在抓取元数据: ${item.link}`);
        
        try {
            const $ = await fetchMetaViaFlare(item.link);
            
            // 抓取逻辑 (适配 xChina)
            const plot = $('.introduction').text().trim() || '无简介';
            const date = $('.date').first().text().replace('发行日期:', '').trim() || '';
            const studio = $('.studio').text().replace('片商:', '').trim() || '';
            const tags = [];
            $('.tag').each((i, el) => tags.push($(el).text().trim()));
            
            // 构造 XML
            let xml = `<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>\n<movie>\n`;
            xml += `  <title>${item.title}</title>\n`;
            xml += `  <originaltitle>${item.code || item.title}</originaltitle>\n`;
            xml += `  <sorttitle>${item.title}</sorttitle>\n`;
            xml += `  <plot>${plot}</plot>\n`;
            xml += `  <outline>${plot.substring(0, 100)}...</outline>\n`;
            xml += `  <premiered>${date}</premiered>\n`;
            xml += `  <releasedate>${date}</releasedate>\n`;
            xml += `  <studio>${studio}</studio>\n`;
            
            if (item.actor && item.actor !== '未知演员') {
                xml += `  <actor>\n    <name>${item.actor}</name>\n    <type>Actor</type>\n  </actor>\n`;
            }
            
            tags.forEach(tag => {
                xml += `  <genre>${tag}</genre>\n`;
                xml += `  <tag>${tag}</tag>\n`;
            });
            
            xml += `  <thumb>poster.jpg</thumb>\n`;
            xml += `  <fanart>fanart.jpg</fanart>\n`;
            xml += `</movie>`;
            
            return Buffer.from(xml, 'utf-8');
        } catch (e) {
            log(`⚠️ 元数据抓取失败: ${e.message}`, 'warn');
            // 即使抓取失败，也可以生成一个基础 NFO
            let xml = `<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>\n<movie>\n  <title>${item.title}</title>\n  <plot>元数据抓取失败，请手动补充</plot>\n</movie>`;
            return Buffer.from(xml, 'utf-8');
        }
    },

    processItem: async (item) => {
        const targetCid = global.CONFIG.targetCid;
        if (!targetCid) { log("❌ 未配置目标目录CID", 'error'); return false; }

        const magnetMatch = item.magnets.match(/[a-fA-F0-9]{40}/);
        if (!magnetMatch) { log(`❌ 无效Hash`, 'error'); return false; }
        const hash = magnetMatch[0];

        log(`▶️ 处理: ${item.title.substring(0, 15)}...`);

        // 1. 定位
        let folderCid = null;
        let retryCount = 0;
        while (retryCount < 8) {
            const task = await Login115.getTaskByHash(hash);
            if (task) {
                if (task.status_code === 2) { folderCid = task.folder_cid; log(`✅ [115] 下载完成`); break; } 
                else if (task.status_code < 0) { log(`❌ 任务失败/违规`, 'error'); return false; }
                else { log(`⏳ 下载中... ${task.percent.toFixed(1)}%`); }
            } else { break; }
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

        // 2. 构造标准名称
        let actor = item.actor;
        let title = item.title;
        // 尝试从标题提取演员: "Title (Actor)"
        if (!actor || actor === '未知演员') {
            const match = title.match(/^(.*?)\s*[（(](.*)[）)]$/);
            if (match) { title = match[1].trim(); actor = match[2].trim(); }
        }
        let standardName = title;
        if (actor && actor !== '未知演员') standardName = `${actor} - ${title}`;
        standardName = standardName.replace(/[\\/:*?"<>|]/g, "").replace(/\s+/g, ' ').trim();
        if(standardName.length > 200) standardName = standardName.substring(0, 200);

        try {
            // 3. 处理文件 (重命名视频)
            const fileList = await Login115.getFileList(folderCid);
            if (fileList.data && fileList.data.length > 0) {
                const files = fileList.data.filter(f => !f.fcid);
                if (files.length > 0) {
                    files.sort((a, b) => b.s - a.s);
                    const mainVideo = files[0];
                    if (files.length > 1) {
                        const deleteIds = files.slice(1).map(f => f.fid).join(',');
                        await Login115.deleteFiles(deleteIds);
                        log(`🧹 清理杂文件: ${files.length - 1}个`);
                    }
                    const ext = mainVideo.n.lastIndexOf('.') > -1 ? mainVideo.n.substring(mainVideo.n.lastIndexOf('.')) : '';
                    const newVideoName = standardName + ext;
                    if (mainVideo.n !== newVideoName) {
                        const renRes = await Login115.rename(mainVideo.fid, newVideoName);
                        if (renRes.success) log(`🎬 视频改名成功: ${newVideoName}`);
                        else log(`⚠️ 视频改名失败: ${renRes.msg}`, 'warn');
                    }
                }
            }

            // 4. 海报三件套 (Poster, Thumb, Fanart) - 严格直传
            if (item.image_url) {
                try {
                    const imgRes = await axios.get(item.image_url, { responseType: 'arraybuffer', timeout: 10000 });
                    if (imgRes.status === 200) {
                        const imgBuffer = imgRes.data;
                        const targets = ['poster.jpg', 'thumb.jpg', 'fanart.jpg'];
                        
                        log(`🖼️ 正在上传海报三件套...`);
                        
                        for (const targetName of targets) {
                            // 失败重试 1 次
                            let success = false;
                            for(let i=0; i<2; i++) {
                                const tempName = `${hash.substring(0,5)}_${targetName}`; // 临时名避免冲突
                                try {
                                    const fid = await Login115.uploadFile(imgBuffer, tempName);
                                    if (fid) {
                                        await Login115.move(fid, folderCid);
                                        await Login115.rename(fid, targetName);
                                        success = true;
                                        break;
                                    }
                                } catch(e) { /* retry */ }
                            }
                            if(!success) log(`⚠️ 上传 ${targetName} 失败`, 'warn');
                        }
                        log(`✅ 海报处理完成`);
                    }
                } catch (imgErr) {
                    log(`❌ 海报下载失败: ${imgErr.message}`, 'error');
                    // 绝不使用离线下载
                }
            }

            // 5. 生成并上传 NFO
            try {
                const nfoBuffer = await Organizer.generateNfo(item, standardName);
                if (nfoBuffer) {
                    const nfoName = `${standardName}.nfo`;
                    // 上传 NFO
                    const tempNfoName = `nfo_${hash.substring(0,5)}.nfo`;
                    const nfoFid = await Login115.uploadFile(nfoBuffer, tempNfoName);
                    if (nfoFid) {
                        await Login115.move(nfoFid, folderCid);
                        await Login115.rename(nfoFid, nfoName);
                        log(`📝 NFO 元数据已生成并上传`);
                    } else {
                        log(`⚠️ NFO 上传失败`, 'warn');
                    }
                }
            } catch (nfoErr) {
                log(`⚠️ NFO 处理异常: ${nfoErr.message}`, 'warn');
            }

            // 6. 文件夹重命名 & 移动
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

# 3. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.13.9 全能刮削版部署完成！"
