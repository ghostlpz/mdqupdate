#!/bin/bash
# VERSION = 13.12.0

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.12.0
# 核心升级: 全自动遍历模式 (自动识别所有分类并轮询采集)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署全自动遍历版 (V13.12.0)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.12.0"/' package.json

# 2. 重写 scraper_xchina.js (实现分类队列逻辑)
echo "📝 [1/1] 升级采集核心 (自动遍历所有分类)..."
cat > modules/scraper_xchina.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const ResourceMgr = require('./resource_mgr');

// ⚡️ 并发数 (页内视频处理)
const CONCURRENCY_LIMIT = 3;
// ⚡️ 失败重试次数
const MAX_RETRIES = 3;

let STATE = { isRunning: false, stopSignal: false, logs: [], totalScraped: 0, currentCategory: '' };

function log(msg, type = 'info') {
    STATE.logs.push({ time: new Date().toLocaleTimeString(), msg, type });
    if (STATE.logs.length > 200) STATE.logs.shift();
    console.log(`[Scraper-xChina] ${msg}`);
}

function cleanMagnet(magnet) {
    if (!magnet) return '';
    const match = magnet.match(/magnet:\?xt=urn:btih:([a-zA-Z0-9]+)/i);
    if (match) return `magnet:?xt=urn:btih:${match[1]}`;
    return magnet.split('&')[0];
}

function getFlareUrl() {
    let url = global.CONFIG.flaresolverrUrl || 'http://flaresolverr:8191';
    if (url.endsWith('/')) url = url.slice(0, -1);
    if (!url.endsWith('/v1')) url += '/v1';
    return url;
}

async function requestViaFlare(url) {
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
    } catch (e) { throw new Error(`Request Err: ${e.message}`); }
}

async function pushTo115(magnet) {
    if (!global.CONFIG.cookie115) return false;
    try {
        const postData = `url=${encodeURIComponent(magnet)}`;
        const res = await axios.post('https://115.com/web/lixian/?ct=lixian&ac=add_task_url', postData, {
            headers: {
                'Cookie': global.CONFIG.cookie115,
                'User-Agent': global.CONFIG.userAgent,
                'Content-Type': 'application/x-www-form-urlencoded'
            }
        });
        return res.data && res.data.state;
    } catch (e) { return false; }
}

// 获取所有分类链接
async function getAllCategories(baseUrl) {
    log(`🔍 正在扫描首页获取全部分类...`, 'info');
    try {
        const $ = await requestViaFlare(`${baseUrl}/videos.html`);
        const categories = [];
        // 提取侧边栏或内容区的分类链接
        // 规则: href 包含 /videos/series-
        $('a[href*="/videos/series-"]').each((i, el) => {
            const href = $(el).attr('href');
            // 提取分类名 (移除数字统计)
            let name = $(el).text().replace(/\(\d+\)/, '').trim(); 
            // 提取 series code
            const match = href.match(/(series-[a-zA-Z0-9]+)/);
            
            if (match && name) {
                // 去重
                if (!categories.find(c => c.code === match[1])) {
                    categories.push({ name: name, code: match[1] });
                }
            }
        });
        
        log(`📚 成功识别 ${categories.length} 个分类 (麻豆/天美/蜜桃等)`, 'success');
        return categories;
    } catch (e) {
        log(`❌ 获取分类失败: ${e.message}`, 'error');
        return [];
    }
}

async function processVideoTaskWithRetry(task, baseUrl, autoDownload) {
    let attempt = 0;
    while (attempt < MAX_RETRIES) {
        if (STATE.stopSignal) return;
        attempt++;
        try {
            return await processVideoTask(task, baseUrl, autoDownload);
        } catch (e) {
            if (attempt === MAX_RETRIES) {
                log(`❌ [彻底失败] ${task.title.substring(0, 10)}...`, 'error');
            } else {
                await new Promise(r => setTimeout(r, 2000 * attempt)); 
            }
        }
    }
    return false;
}

async function processVideoTask(task, baseUrl, autoDownload) {
    const { link } = task; 
    const $ = await requestViaFlare(link);
    
    let title = $('h1').text().trim() || task.title;
    let image = $('.vjs-poster img').attr('src') || $('video').attr('poster');
    if (image && !image.startsWith('http')) image = baseUrl + image;
    
    const actor = $('.model-container .model-item').text().trim() || '未知演员';
    
    let category = '';
    $('.text').each((i, el) => {
        if ($(el).find('.joiner').length > 0) category = $(el).find('a').last().text().trim();
    });
    if (!category) category = '未分类';

    let code = '';
    const codeMatch = link.match(/id-([a-zA-Z0-9]+)/);
    if (codeMatch) code = codeMatch[1];

    const downloadLinkEl = $('a[href*="/download/id-"]');
    if (downloadLinkEl.length === 0) throw new Error("无下载入口");

    let downloadPageUrl = downloadLinkEl.attr('href');
    if (downloadPageUrl && !downloadPageUrl.startsWith('http')) {
        downloadPageUrl = baseUrl + downloadPageUrl;
    }

    const $down = await requestViaFlare(downloadPageUrl);
    const rawMagnet = $down('a.btn.magnet').attr('href');
    if (!rawMagnet) throw new Error("无磁力链");
    const magnet = cleanMagnet(rawMagnet);

    if (magnet && magnet.startsWith('magnet:')) {
        const saveRes = await ResourceMgr.save({
            title, link, magnets: magnet, code, image, actor, category
        });

        if (saveRes.success) {
            if (saveRes.newInsert) {
                STATE.totalScraped++;
                let extraMsg = "";
                if (autoDownload) {
                    const pushed = await pushTo115(magnet);
                    extraMsg = pushed ? " | 📥 已推115" : " | ⚠️ 推送失败";
                    if(pushed) await ResourceMgr.markAsPushedByLink(link);
                }
                log(`✅ [入库] ${code} | ${title.substring(0, 10)}...${extraMsg}`, 'success');
                return true;
            } else {
                log(`⏭️ [已存在] ${title.substring(0, 10)}...`, 'info');
                return true;
            }
        }
    }
    return false;
}

// 核心：单分类采集循环
async function scrapeCategory(cat, baseUrl, limitPages, autoDownload) {
    let page = 1;
    let emptyCount = 0;
    
    log(`📂 开始采集分类: [${cat.name}] (${cat.code})`, 'info');

    while (page <= limitPages && !STATE.stopSignal) {
        // 构造精准翻页链接
        const listUrl = page === 1 
            ? `${baseUrl}/videos/${cat.code}.html` 
            : `${baseUrl}/videos/${cat.code}/${page}.html`;
            
        // log(`📡 ${cat.name} - 第 ${page} 页...`);

        try {
            const $ = await requestViaFlare(listUrl);
            const items = $('.item.video');
            
            if (items.length === 0) { 
                log(`⚠️ [${cat.name}] 第 ${page} 页无内容，本分类结束`, 'warn'); 
                break; 
            }

            // 本页任务
            const tasks = [];
            items.each((i, el) => {
                const title = $(el).find('.text .title a').text().trim();
                let subLink = $(el).find('.text .title a').attr('href');
                if (title && subLink) {
                    if (!subLink.startsWith('http')) subLink = baseUrl + subLink;
                    tasks.push({ title, link: subLink });
                }
            });

            // 并发执行
            let newInPage = 0;
            for (let i = 0; i < tasks.length; i += CONCURRENCY_LIMIT) {
                if (STATE.stopSignal) break;
                const chunk = tasks.slice(i, i + CONCURRENCY_LIMIT);
                const results = await Promise.all(chunk.map(task => 
                    processVideoTaskWithRetry(task, baseUrl, autoDownload)
                ));
                newInPage += results.filter(r => r === true).length;
                await new Promise(r => setTimeout(r, 500)); 
            }

            if (newInPage === 0) emptyCount++;
            else emptyCount = 0;

            // 连续2页没新内容，或者这是全量采集的第1页就没内容，可能该分类采完了
            // 但为了保险，我们只在连续多页无新内容时才跳过分类
            // 这里为了效率，如果增量模式下本页全是旧的，直接跳出该分类
            if (newInPage === 0 && limitPages < 100) {
                log(`⏭️ [${cat.name}] 本页全为旧数据，跳过该分类剩余页码`, 'warn');
                break;
            }

            page++;
            await new Promise(r => setTimeout(r, 1500)); // 翻页休息

        } catch (pageErr) {
            log(`❌ [${cat.name}] 翻页失败: ${pageErr.message}`, 'error');
            if (pageErr.message.includes('404')) break;
            await new Promise(r => setTimeout(r, 3000));
        }
    }
}

const ScraperXChina = {
    getState: () => STATE,
    stop: () => { STATE.stopSignal = true; },
    clearLogs: () => { STATE.logs = []; },
    
    start: async (limitPages = 5, autoDownload = false) => {
        if (STATE.isRunning) return;
        STATE.isRunning = true;
        STATE.stopSignal = false;
        STATE.totalScraped = 0;
        
        const baseUrl = "https://xchina.co";
        
        try {
            // 1. 检查 Flaresolverr
            const flareUrl = getFlareUrl().replace('/v1','');
            const checkUrl = flareUrl.replace(/\/v1\/?$/, '') || 'http://flaresolverr:8191';
            try { await axios.get(checkUrl, { timeout: 5000 }); } 
            catch (e) { throw new Error(`无法连接 Flaresolverr: ${checkUrl}`); }

            // 2. 获取全部分类
            const categories = await getAllCategories(baseUrl);
            if (categories.length === 0) {
                log("❌ 未找到任何分类，请检查网络或网站结构", 'error');
                STATE.isRunning = false;
                return;
            }

            // 3. 遍历分类采集
            for (let i = 0; i < categories.length; i++) {
                if (STATE.stopSignal) break;
                
                const cat = categories[i];
                STATE.currentCategory = cat.name;
                
                // 执行单个分类采集
                await scrapeCategory(cat, baseUrl, limitPages, autoDownload);
                
                log(`✅ [${cat.name}] 采集完成，准备进入下一个分类...`, 'success');
                // 分类间休息 5 秒
                await new Promise(r => setTimeout(r, 5000));
            }

        } catch (err) { log(`🔥 全局异常: ${err.message}`, 'error'); }
        
        STATE.isRunning = false;
        STATE.currentCategory = '';
        log(`🏁 全站遍历任务结束，新增资源 ${STATE.totalScraped} 条`, 'warn');
    }
};
module.exports = ScraperXChina;
EOF

# 3. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] 全自动遍历版 V13.12.0 部署完成。"
