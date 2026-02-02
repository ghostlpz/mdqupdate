#!/bin/bash
# VERSION = 13.14.6

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.14.6
# 修复: xChina M3U8 页面图片抓取失败问题 (增加正则提取兜底)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署图片抓取修复版 (V13.14.6)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.14.6"/' package.json

# 2. 升级 scraper_xchina.js (修复图片逻辑)
echo "📝 [1/1] 升级采集核心 (增强图片正则提取)..."
cat > modules/scraper_xchina.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const ResourceMgr = require('./resource_mgr');
const LoginPikPak = require('./login_pikpak');

// ⚡️ 任务配置
const CONCURRENCY_LIMIT = 3;
const MAX_RETRIES = 3;

// 📜 内置分类库
const CATEGORY_MAP = [
    { name: "麻豆传媒", code: "series-5f904550b8fcc" },
    { name: "独立创作者", code: "series-61bf6e439fed6" },
    { name: "糖心Vlog", code: "series-61014080dbfde" },
    { name: "蜜桃传媒", code: "series-5fe8403919165" },
    { name: "星空传媒", code: "series-6054e93356ded" },
    { name: "天美传媒", code: "series-60153c49058ce" },
    { name: "果冻传媒", code: "series-5fe840718d665" },
    { name: "香蕉视频", code: "series-65e5f74e4605c" },
    { name: "精东影业", code: "series-60126bcfb97fa" },
    { name: "杏吧原版", code: "series-6072997559b46" },
    { name: "爱豆传媒", code: "series-63d134c7a0a15" },
    { name: "IBiZa Media", code: "series-64e9cce89da21" },
    { name: "性视界", code: "series-63490362dac45" },
    { name: "ED Mosaic", code: "series-63732f5c3d36b" },
    { name: "大象传媒", code: "series-65bcaa9688514" },
    { name: "扣扣传媒", code: "series-6230974ada989" },
    { name: "萝莉社", code: "series-6360ca9706ecb" },
    { name: "SA国际传媒", code: "series-633ef3ef07d33" },
    { name: "其他中文AV", code: "series-63986aec205d8" },
    { name: "抖阴", code: "series-6248705dab604" },
    { name: "葫芦影业", code: "series-6193d27975579" },
    { name: "乌托邦", code: "series-637750ae0ee71" },
    { name: "爱神传媒", code: "series-6405b6842705b" },
    { name: "乐播传媒", code: "series-60589daa8ff97" },
    { name: "91茄子", code: "series-639c8d983b7d5" },
    { name: "草莓视频", code: "series-671ddc0b358ca" },
    { name: "JVID", code: "series-6964cfbda328b" },
    { name: "YOYO", code: "series-64eda52c1c3fb" },
    { name: "51吃瓜", code: "series-671dd88d06dd3" },
    { name: "哔哩传媒", code: "series-64458e7da05e6" },
    { name: "映秀传媒", code: "series-6560dc053c99f" },
    { name: "西瓜影视", code: "series-648e1071386ef" },
    { name: "思春社", code: "series-64be8551bd0f1" },
    { name: "有码AV", code: "series-6395aba3deb74" },
    { name: "无码AV", code: "series-6395ab7fee104" },
    { name: "AV解说", code: "series-6608638e5fcf7" },
    { name: "PANS视频", code: "series-63963186ae145" },
    { name: "其他模特私拍", code: "series-63963534a9e49" },
    { name: "热舞", code: "series-64edbeccedb2e" },
    { name: "相约中国", code: "series-63ed0f22e9177" },
    { name: "果哥作品", code: "series-6396315ed2e49" },
    { name: "SweatGirl", code: "series-68456564f2710" },
    { name: "风吟鸟唱作品", code: "series-6396319e6b823" },
    { name: "色艺无间", code: "series-6754a97d2b343" },
    { name: "黄甫", code: "series-668c3b2de7f1c" },
    { name: "日月俱乐部", code: "series-63ab1dd83a1c6" },
    { name: "探花现场", code: "series-63965bf7b7f51" },
    { name: "主播现场", code: "series-63965bd5335fc" },
    { name: "华语电影", code: "series-6396492fdb1a0" },
    { name: "日韩电影", code: "series-6396494584b57" },
    { name: "欧美电影", code: "series-63964959ddb1b" },
    { name: "其他亚洲影片", code: "series-63963ea949a82" },
    { name: "门事件", code: "series-63963de3f2a0f" },
    { name: "其他欧美影片", code: "series-6396404e6bdb5" },
    { name: "无关情色", code: "series-66643478ceedd" }
];

let STATE = { isRunning: false, stopSignal: false, logs: [], totalScraped: 0 };

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
                'User-Agent': global.CONFIG.userAgent || 'Mozilla/5.0',
                'Content-Type': 'application/x-www-form-urlencoded'
            }
        });
        return res.data && res.data.state;
    } catch (e) { return false; }
}

async function processVideoTask(task, baseUrl, autoDownload) {
    const { link } = task; 
    const $ = await requestViaFlare(link);
    
    let title = $('h1').text().trim() || task.title;
    
    // 🔥 图片抓取优化开始
    let image = '';
    // 1. 尝试从 DOM 获取
    image = $('.vjs-poster img').attr('src') || $('video').attr('poster');
    
    // 2. 如果 DOM 没拿到，尝试从源码正则匹配 (针对 M3U8 页面)
    if (!image) {
        const htmlContent = $.html();
        // 匹配 poster: 'http...' 或 poster: "http..."
        const posterMatch = htmlContent.match(/poster:\s*['"]([^'"]+)['"]/);
        if (posterMatch && posterMatch[1]) {
            image = posterMatch[1];
        }
    }
    
    // 3. 补全相对路径
    if (image && !image.startsWith('http')) image = baseUrl + image;
    // 🔥 图片抓取优化结束

    const actor = $('.model-container .model-item').text().trim() || '未知演员';
    
    let category = '';
    $('.text').each((i, el) => { if ($(el).find('.joiner').length > 0) category = $(el).find('a').last().text().trim(); });
    if (!category) category = '未分类';

    let code = '';
    const codeMatch = link.match(/id-([a-zA-Z0-9]+)/);
    if (codeMatch) code = codeMatch[1];

    let magnet = '';
    let driveType = '115';

    // 1. 优先找磁力 (115)
    try {
        const downloadLinkEl = $('a[href*="/download/id-"]');
        if (downloadLinkEl.length > 0) {
            let downloadPageUrl = downloadLinkEl.attr('href');
            if (downloadPageUrl && !downloadPageUrl.startsWith('http')) downloadPageUrl = baseUrl + downloadPageUrl;
            const $down = await requestViaFlare(downloadPageUrl);
            const rawMagnet = $down('a.btn.magnet').attr('href');
            if (rawMagnet) magnet = cleanMagnet(rawMagnet);
        }
    } catch (e) {}

    // 2. 备用找 M3U8 (PikPak)
    if (!magnet) {
        const htmlContent = $.html();
        const regex = /src:\s*['"](https?:\/\/[^'"]+\.m3u8[^'"]*)['"]/;
        const match = htmlContent.match(regex);
        if (match && match[1]) {
            magnet = match[1];
            driveType = 'pikpak';
            log(`🔎 [${code}] 启用 M3U8 (PikPak)`, 'info');
        }
    }

    if (magnet) {
        const storageValue = driveType === 'pikpak' ? `pikpak|${magnet}` : magnet;
        const saveRes = await ResourceMgr.save({
            title, link, magnets: storageValue, code, image, actor, category
        });

        if (saveRes.success && saveRes.newInsert) {
            STATE.totalScraped++;
            let extraMsg = "";
            
            // 差异化策略: M3U8 强制推 PikPak，磁力只存库
            if (driveType === 'pikpak') {
                const pushed = await LoginPikPak.addTask(magnet);
                extraMsg = pushed ? " | 🚀 已强制推PikPak" : " | ⚠️ PikPak推送失败(请检查代理)";
                if(pushed) await ResourceMgr.markAsPushedByLink(link);
            } else {
                extraMsg = " | 💾 仅存库";
            }

            log(`✅ [入库] ${code} | ${title.substring(0, 10)}...${extraMsg}`, 'success');
            return true;
        } else if (!saveRes.newInsert) {
            log(`⏭️ [已存在] ${title.substring(0, 10)}...`, 'info');
            return true;
        }
    }
    return false;
}

async function scrapeCategory(cat, baseUrl, limitPages, autoDownload) {
    let page = 1;
    log(`📂 正在采集: [${cat.name}]`, 'info');

    while (page <= limitPages && !STATE.stopSignal) {
        const listUrl = page === 1 
            ? `${baseUrl}/videos/${cat.code}.html` 
            : `${baseUrl}/videos/${cat.code}/${page}.html`;
            
        try {
            const $ = await requestViaFlare(listUrl);
            const items = $('.item.video');
            
            if (items.length === 0) { 
                log(`⚠️ [${cat.name}] 第 ${page} 页无内容，本分类结束`, 'warn'); 
                break; 
            }

            const tasks = [];
            items.each((i, el) => {
                const title = $(el).find('.text .title a').text().trim();
                let subLink = $(el).find('.text .title a').attr('href');
                if (title && subLink) {
                    if (!subLink.startsWith('http')) subLink = baseUrl + subLink;
                    tasks.push({ title, link: subLink });
                }
            });

            log(`📡 [${cat.name}] 第 ${page}/${limitPages} 页: 发现 ${tasks.length} 个视频`);

            for (let i = 0; i < tasks.length; i += CONCURRENCY_LIMIT) {
                if (STATE.stopSignal) break;
                const chunk = tasks.slice(i, i + CONCURRENCY_LIMIT);
                
                const results = await Promise.all(chunk.map(async (task) => {
                    for(let k=0; k<MAX_RETRIES; k++){
                        try { return await processVideoTask(task, baseUrl, autoDownload); }
                        catch(e){ if(k===MAX_RETRIES-1) log(`❌ ${task.title.substring(0,10)} 失败: ${e.message}`, 'error'); }
                        await new Promise(r=>setTimeout(r, 1500));
                    }
                    return false;
                }));
                
                await new Promise(r => setTimeout(r, 500)); 
            }

            page++;
            await new Promise(r => setTimeout(r, 1500));

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
    start: async (mode = 'inc', autoDownload = false, selectedCodes = []) => {
        if (STATE.isRunning) return;
        STATE.isRunning = true;
        STATE.stopSignal = false;
        STATE.totalScraped = 0;
        
        const limitPages = mode === 'full' ? 5000 : 50;
        const baseUrl = "https://xchina.co";
        
        try {
            const flareUrl = getFlareUrl().replace('/v1','');
            try { await axios.get(flareUrl.replace(/\/v1\/?$/, '') || 'http://flaresolverr:8191', { timeout: 5000 }); } 
            catch (e) { throw new Error(`无法连接 Flaresolverr`); }

            let targetCategories = CATEGORY_MAP;
            if (selectedCodes && selectedCodes.length > 0) {
                targetCategories = CATEGORY_MAP.filter(c => selectedCodes.includes(c.code));
                log(`🎯 已锁定 ${targetCategories.length} 个目标分类`, 'success');
            } else {
                log(`🌍 未选择分类，将全站遍历 (54个分类)`, 'success');
            }

            for (let i = 0; i < targetCategories.length; i++) {
                if (STATE.stopSignal) break;
                const cat = targetCategories[i];
                await scrapeCategory(cat, baseUrl, limitPages, autoDownload);
                if (i < targetCategories.length - 1) {
                    log(`☕ 休息 5 秒...`, 'info');
                    await new Promise(r => setTimeout(r, 5000));
                }
            }
        } catch (err) { log(`🔥 全局异常: ${err.message}`, 'error'); }
        STATE.isRunning = false;
        log(`🏁 任务结束，新增资源 ${STATE.totalScraped} 条`, 'warn');
    },
    getCategories: () => CATEGORY_MAP
};
module.exports = ScraperXChina;
EOF

# 3. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.14.6 部署完成，已修复图片抓取问题！"
