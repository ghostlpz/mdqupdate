#!/bin/bash
# VERSION = 13.16.1

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.16.1
# 修复: 补全 Scraper 缺失的代码逻辑 (修复 SyntaxError)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署完整修复版 (V13.16.1)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.16.1"/' package.json

# 2. 写入完整的 scraper_xchina.js (无省略)
echo "📝 [1/1] 覆盖采集器核心代码..."
cat > modules/scraper_xchina.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const ResourceMgr = require('./resource_mgr');
const M3U8Client = require('./m3u8_client');
const { spawn } = require('child_process');

// --- Python Bridge 管理 (用于 curl_cffi 下载图片) ---
let pythonProcess = null;
const BRIDGE_URL = 'http://127.0.0.1:5005';

function ensureBridge() {
    if (pythonProcess && !pythonProcess.killed) return;
    console.log('🐍 [Bridge] 启动 curl_cffi 服务...');
    // 使用 -u 参数禁用缓冲
    pythonProcess = spawn('python3', ['-u', '/app/python_service/bridge.py'], { stdio: 'inherit' });
    pythonProcess.on('error', (err) => console.error('🐍 [Bridge] 启动失败:', err));
}
// 启动时检查一次
ensureBridge();

// 使用 curl_cffi 下载穿盾图片 (辅助功能)
async function downloadImageViaCurl(url, referer) {
    if (!url) return null;
    try {
        const res = await axios.post(`${BRIDGE_URL}/download_image`, {
            url: url,
            referer: referer,
            proxy: global.CONFIG.proxy
        }, { responseType: 'arraybuffer', timeout: 30000 });
        return res.data;
    } catch (e) {
        // console.error(`🖼️ [Curl] 图片下载失败: ${e.message}`);
        return null;
    }
}

// ------------------------------------------------

// ⚡️ 任务配置
const CONCURRENCY_LIMIT = 3;
const MAX_RETRIES = 3;

// 📜 分类库 (完整列表)
const FULL_CATS = [
    { name: "麻豆传媒", code: "series-5f904550b8fcc" }, { name: "独立创作者", code: "series-61bf6e439fed6" }, { name: "糖心Vlog", code: "series-61014080dbfde" }, { name: "蜜桃传媒", code: "series-5fe8403919165" }, { name: "星空传媒", code: "series-6054e93356ded" }, { name: "天美传媒", code: "series-60153c49058ce" }, { name: "果冻传媒", code: "series-5fe840718d665" }, { name: "香蕉视频", code: "series-65e5f74e4605c" }, { name: "精东影业", code: "series-60126bcfb97fa" }, { name: "杏吧原版", code: "series-6072997559b46" }, { name: "爱豆传媒", code: "series-63d134c7a0a15" }, { name: "IBiZa Media", code: "series-64e9cce89da21" }, { name: "性视界", code: "series-63490362dac45" }, { name: "ED Mosaic", code: "series-63732f5c3d36b" }, { name: "大象传媒", code: "series-65bcaa9688514" }, { name: "扣扣传媒", code: "series-6230974ada989" }, { name: "萝莉社", code: "series-6360ca9706ecb" }, { name: "SA国际传媒", code: "series-633ef3ef07d33" }, { name: "其他中文AV", code: "series-63986aec205d8" }, { name: "抖阴", code: "series-6248705dab604" }, { name: "葫芦影业", code: "series-6193d27975579" }, { name: "乌托邦", code: "series-637750ae0ee71" }, { name: "爱神传媒", code: "series-6405b6842705b" }, { name: "乐播传媒", code: "series-60589daa8ff97" }, { name: "91茄子", code: "series-639c8d983b7d5" }, { name: "草莓视频", code: "series-671ddc0b358ca" }, { name: "JVID", code: "series-6964cfbda328b" }, { name: "YOYO", code: "series-64eda52c1c3fb" }, { name: "51吃瓜", code: "series-671dd88d06dd3" }, { name: "哔哩传媒", code: "series-64458e7da05e6" }, { name: "映秀传媒", code: "series-6560dc053c99f" }, { name: "西瓜影视", code: "series-648e1071386ef" }, { name: "思春社", code: "series-64be8551bd0f1" }, { name: "有码AV", code: "series-6395aba3deb74" }, { name: "无码AV", code: "series-6395ab7fee104" }, { name: "AV解说", code: "series-6608638e5fcf7" }, { name: "PANS视频", code: "series-63963186ae145" }, { name: "其他模特私拍", code: "series-63963534a9e49" }, { name: "热舞", code: "series-64edbeccedb2e" }, { name: "相约中国", code: "series-63ed0f22e9177" }, { name: "果哥作品", code: "series-6396315ed2e49" }, { name: "SweatGirl", code: "series-68456564f2710" }, { name: "风吟鸟唱作品", code: "series-6396319e6b823" }, { name: "色艺无间", code: "series-6754a97d2b343" }, { name: "黄甫", code: "series-668c3b2de7f1c" }, { name: "日月俱乐部", code: "series-63ab1dd83a1c6" }, { name: "探花现场", code: "series-63965bf7b7f51" }, { name: "主播现场", code: "series-63965bd5335fc" }, { name: "华语电影", code: "series-6396492fdb1a0" }, { name: "日韩电影", code: "series-6396494584b57" }, { name: "欧美电影", code: "series-63964959ddb1b" }, { name: "其他亚洲影片", code: "series-63963ea949a82" }, { name: "门事件", code: "series-63963de3f2a0f" }, { name: "其他欧美影片", code: "series-6396404e6bdb5" }, { name: "无关情色", code: "series-66643478ceedd" }
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

// --------------------------------------------------------

async function processVideoTask(task, baseUrl, autoDownload) {
    const { link } = task; 
    
    // 1. 获取 HTML (使用 Flaresolverr 绕过 Cloudflare)
    const flareApi = getFlareUrl();
    let htmlContent = "";
    try {
        const payload = { cmd: 'request.get', url: link, maxTimeout: 60000 };
        if (global.CONFIG.proxy) payload.proxy = { url: global.CONFIG.proxy };
        const res = await axios.post(flareApi, payload, { headers: { 'Content-Type': 'application/json' } });
        if (res.data.status === 'ok') htmlContent = res.data.solution.response;
        else throw new Error(res.data.message);
    } catch(e) { throw new Error(`Req Err: ${e.message}`); }

    const $ = cheerio.load(htmlContent);
    let title = $('h1').text().trim() || task.title;
    
    // 🔥 图片抓取 (正则 + curl_cffi 下载)
    let image = '';
    const regexPoster = /(?:poster|pic|thumb)\s*[:=]\s*['"]([^'"]+)['"]/i;
    const regexCss = /background-image\s*:\s*url\(['"]?([^'"\)]+)['"]?\)/i;
    
    if (htmlContent.match(regexPoster)) image = htmlContent.match(regexPoster)[1].replace(/\\\//g, '/');
    else if (htmlContent.match(regexCss)) image = htmlContent.match(regexCss)[1].replace(/\\\//g, '/');
    else image = $('.vjs-poster img').attr('src') || $('video').attr('poster');
    
    if (image && !image.startsWith('http')) image = baseUrl + image;

    const actor = $('.model-container .model-item').text().trim() || '未知演员';
    let category = '未分类';
    $('.text').each((i, el) => { if ($(el).find('.joiner').length > 0) category = $(el).find('a').last().text().trim(); });

    let code = '';
    const codeMatch = link.match(/id-([a-zA-Z0-9]+)/);
    if (codeMatch) code = codeMatch[1];

    let magnet = '';
    let isM3u8 = false;

    // A. 尝试获取磁力 (优先级 1)
    try {
        const downloadLinkEl = $('a[href*="/download/id-"]');
        if (downloadLinkEl.length > 0) {
            let downloadPageUrl = downloadLinkEl.attr('href');
            if (downloadPageUrl && !downloadPageUrl.startsWith('http')) downloadPageUrl = baseUrl + downloadPageUrl;
            
            const dlPayload = { cmd: 'request.get', url: downloadPageUrl, maxTimeout: 30000 };
            if (global.CONFIG.proxy) dlPayload.proxy = { url: global.CONFIG.proxy };
            const dlRes = await axios.post(flareApi, dlPayload);
            if (dlRes.data.status === 'ok') {
                const $d = cheerio.load(dlRes.data.solution.response);
                const rawMagnet = $d('a.btn.magnet').attr('href');
                if (rawMagnet) magnet = cleanMagnet(rawMagnet);
            }
        }
    } catch (e) {}

    // B. 如果无磁力，判定为 M3U8 资源
    if (!magnet) {
        // xChina 的视频页如果没有磁力，基本上都是 m3u8 播放
        // 直接提交网页 URL 给 M3U8 Pro API 即可
        isM3u8 = true;
        log(`🔎 [${code}] 发现流媒体资源 (无磁力)`, 'info');
    }

    // 💾 入库逻辑
    if (magnet || isM3u8) {
        // M3U8资源存入 "m3u8|网页链接"
        const storageValue = isM3u8 ? `m3u8|${link}` : magnet;
        
        const saveRes = await ResourceMgr.save({
            title, link, magnets: storageValue, code, image, actor, category
        });

        if (saveRes.success) {
            if (saveRes.newInsert && image) {
                // 可选: 调用 curl_cffi 下载图片用于缓存
                // await downloadImageViaCurl(image, baseUrl);
            }

            if (saveRes.newInsert) {
                STATE.totalScraped++;
                let extraMsg = "";
                
                // 🔥 投递逻辑
                if (isM3u8) {
                    // M3U8 -> 投递给 5003 端口
                    const pushRes = await M3U8Client.addTask(link);
                    extraMsg = pushRes.success ? " | 🚀 已推至下载队列" : (" | ⚠️ 推送失败: " + pushRes.msg);
                    if(pushRes.success) await ResourceMgr.markAsPushedByLink(link);
                } else {
                    // 磁力 -> 仅存库
                    extraMsg = " | 💾 磁力已存库";
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

// 完整的翻页采集逻辑
async function scrapeCategory(cat, baseUrl, limitPages, autoDownload) {
    let page = 1;
    log(`📂 正在采集: [${cat.name}]`, 'info');

    while (page <= limitPages && !STATE.stopSignal) {
        const listUrl = page === 1 
            ? `${baseUrl}/videos/${cat.code}.html` 
            : `${baseUrl}/videos/${cat.code}/${page}.html`;
            
        try {
            // 获取列表页
            const flareApi = getFlareUrl();
            const payload = { cmd: 'request.get', url: listUrl, maxTimeout: 60000 };
            if (global.CONFIG.proxy) payload.proxy = { url: global.CONFIG.proxy };
            
            let res;
            try {
                res = await axios.post(flareApi, payload, { headers: { 'Content-Type': 'application/json' } });
            } catch(e) { throw new Error(`Req Err: ${e.message}`); }

            if (res.data.status !== 'ok') {
                 log(`⚠️ 访问列表页失败: ${res.data.message}`, 'error');
                 break;
            }

            const $ = cheerio.load(res.data.solution.response);
            const items = $('.item.video');
            if (items.length === 0) { log(`⚠️ 第 ${page} 页无内容`, 'warn'); break; }

            const tasks = [];
            items.each((i, el) => {
                const title = $(el).find('.text .title a').text().trim();
                let subLink = $(el).find('.text .title a').attr('href');
                if (title && subLink) {
                    if (!subLink.startsWith('http')) subLink = baseUrl + subLink;
                    tasks.push({ title, link: subLink });
                }
            });

            log(`📡 [${cat.name}] 第 ${page}/${limitPages} 页: ${tasks.length} 个视频`);

            // 并发处理视频页
            for (let i = 0; i < tasks.length; i += CONCURRENCY_LIMIT) {
                if (STATE.stopSignal) break;
                const chunk = tasks.slice(i, i + CONCURRENCY_LIMIT);
                await Promise.all(chunk.map(async (task) => {
                    for(let k=0; k<MAX_RETRIES; k++){
                        try { return await processVideoTask(task, baseUrl, autoDownload); }
                        catch(e){ if(k===MAX_RETRIES-1) log(`❌ ${task.title.substring(0,10)} 失败: ${e.message}`, 'error'); }
                        await new Promise(r=>setTimeout(r, 1500));
                    }
                }));
                await new Promise(r => setTimeout(r, 500)); 
            }
            page++;
            await new Promise(r => setTimeout(r, 1500));

        } catch (pageErr) {
            log(`❌ 翻页失败: ${pageErr.message}`, 'error');
            break;
        }
    }
}

const ScraperXChina = {
    getState: () => STATE,
    stop: () => { STATE.stopSignal = true; log('🛑 停止中...', 'warn'); },
    clearLogs: () => { STATE.logs = []; },
    start: async (mode = 'inc', autoDownload = false, selectedCodes = []) => {
        if (STATE.isRunning) return;
        STATE.isRunning = true;
        STATE.stopSignal = false;
        STATE.totalScraped = 0;
        
        const limitPages = mode === 'full' ? 5000 : 50;
        const baseUrl = "https://xchina.co";
        ensureBridge();

        try {
            let targetCategories = FULL_CATS;
            if (selectedCodes && selectedCodes.length > 0) {
                targetCategories = FULL_CATS.filter(c => selectedCodes.includes(c.code));
            }
            for (let i = 0; i < targetCategories.length; i++) {
                if (STATE.stopSignal) break;
                await scrapeCategory(targetCategories[i], baseUrl, limitPages, autoDownload);
                if (i < targetCategories.length - 1) await new Promise(r => setTimeout(r, 5000));
            }
        } catch (err) { log(`🔥 全局异常: ${err.message}`, 'error'); }
        STATE.isRunning = false;
        log(`🏁 任务结束`, 'warn');
    },
    getCategories: () => FULL_CATS
};
module.exports = ScraperXChina;
EOF

# 3. 重启应用
echo "🔄 重启应用..."
pkill -f "node app.js" || echo "应用可能未运行。"
pkill -f "python3 -u /app/python_service/bridge.py" || true

echo "✅ [完成] V13.16.1 完整修复版部署完成！"
