#!/bin/bash
# VERSION = 13.14.1

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.14.1
# 修复: 补全 UI 界面代码，解决分类选择器不显示的问题
# 功能: 1. xChina 精准分类采集 (54个厂牌)
#       2. 全能刮削 (NFO/海报三件套/规范命名)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署 V13.14.1 (完整UI修复版)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.14.1"/' package.json

# 2. 写入后端: scraper_xchina.js (内置分类库)
echo "📝 [1/3] 部署采集核心..."
cat > modules/scraper_xchina.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const ResourceMgr = require('./resource_mgr');

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
                'User-Agent': global.CONFIG.userAgent,
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
    
    log(`📂 正在采集: [${cat.name}]`, 'info');

    while (page <= limitPages && !STATE.stopSignal) {
        // 修正翻页逻辑: /videos/CODE/PAGE.html
        // 注意：第1页通常是 /videos/CODE.html
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

            let newInPage = 0;
            for (let i = 0; i < tasks.length; i += CONCURRENCY_LIMIT) {
                if (STATE.stopSignal) break;
                const chunk = tasks.slice(i, i + CONCURRENCY_LIMIT);
                
                // 简单的重试包装
                const results = await Promise.all(chunk.map(async (task) => {
                    for(let k=0; k<MAX_RETRIES; k++){
                        try { return await processVideoTask(task, baseUrl, autoDownload); }
                        catch(e){ if(k===MAX_RETRIES-1) log(`❌ ${task.title.substring(0,10)} 失败: ${e.message}`, 'error'); }
                        await new Promise(r=>setTimeout(r, 1500));
                    }
                    return false;
                }));
                
                newInPage += results.filter(r => r === true).length;
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
    
    // start 接收选中的分类列表
    start: async (mode = 'inc', autoDownload = false, selectedCodes = []) => {
        if (STATE.isRunning) return;
        STATE.isRunning = true;
        STATE.stopSignal = false;
        STATE.totalScraped = 0;
        
        // 修正页数限制: 增量50页, 全量5000页
        const limitPages = mode === 'full' ? 5000 : 50;
        const baseUrl = "https://xchina.co";
        
        try {
            const flareUrl = getFlareUrl().replace('/v1','');
            try { await axios.get(flareUrl.replace(/\/v1\/?$/, '') || 'http://flaresolverr:8191', { timeout: 5000 }); } 
            catch (e) { throw new Error(`无法连接 Flaresolverr`); }

            // 决定采集目标：如果传了 selectedCodes，就只采这些；否则采全部
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
                    log(`☕ 休息 5 秒，准备下一个分类...`, 'info');
                    await new Promise(r => setTimeout(r, 5000));
                }
            }

        } catch (err) { log(`🔥 全局异常: ${err.message}`, 'error'); }
        
        STATE.isRunning = false;
        log(`🏁 任务结束，新增资源 ${STATE.totalScraped} 条`, 'warn');
    },
    
    // 暴露分类列表给 API
    getCategories: () => CATEGORY_MAP
};
module.exports = ScraperXChina;
EOF

# 3. 写入 API: api.js (支持分类接口)
echo "📝 [2/3] 部署 API..."
cat > routes/api.js << 'EOF'
const express = require('express');
const axios = require('axios');
const router = express.Router();
const fs = require('fs');
const { exec } = require('child_process');
const { HttpsProxyAgent } = require('https-proxy-agent');
const { Parser } = require('json2csv');
const Scraper = require('../modules/scraper');
const ScraperXChina = require('../modules/scraper_xchina'); // 确保引用
const Renamer = require('../modules/renamer');
const Organizer = require('../modules/organizer');
const Login115 = require('../modules/login_115');
const ResourceMgr = require('../modules/resource_mgr');
const AUTH_PASSWORD = process.env.AUTH_PASSWORD || "admin888";

function compareVersions(v1, v2) {
    if (!v1 || !v2) return 0;
    const p1 = v1.split('.').map(Number);
    const p2 = v2.split('.').map(Number);
    for (let i = 0; i < Math.max(p1.length, p2.length); i++) {
        const n1 = p1[i] || 0;
        const n2 = p2[i] || 0;
        if (n1 > n2) return 1;
        if (n1 < n2) return -1;
    }
    return 0;
}

router.get('/check-auth', (req, res) => {
    const auth = req.headers['authorization'];
    res.json({ authenticated: auth === AUTH_PASSWORD });
});
router.post('/login', (req, res) => {
    if (req.body.password === AUTH_PASSWORD) res.json({ success: true });
    else res.json({ success: false, msg: "密码错误" });
});
router.post('/config', (req, res) => {
    global.CONFIG = { ...global.CONFIG, ...req.body };
    global.saveConfig();
    res.json({ success: true });
});
router.get('/status', (req, res) => {
    let logs = Scraper.getState().logs;
    let scraped = Scraper.getState().totalScraped;
    if (ScraperXChina.getState().isRunning) {
        logs = ScraperXChina.getState().logs;
        scraped = ScraperXChina.getState().totalScraped;
    }
    const orgState = Organizer.getState();
    res.json({ 
        config: global.CONFIG, 
        state: { isRunning: Scraper.getState().isRunning || ScraperXChina.getState().isRunning, logs, totalScraped: scraped }, 
        renamerState: Renamer.getState(),
        organizerLogs: orgState.logs, 
        organizerStats: orgState.stats,
        version: global.CURRENT_VERSION 
    });
});
// 🔥 获取分类列表
router.get('/categories', (req, res) => {
    res.json({ categories: ScraperXChina.getCategories() });
});

router.get('/115/qr', async (req, res) => {
    try {
        const data = await Login115.getQrCode();
        res.json({ success: true, data });
    } catch (e) { res.json({ success: false, msg: e.message }); }
});
router.get('/115/check', async (req, res) => {
    const { uid, time, sign } = req.query;
    const result = await Login115.checkStatus(uid, time, sign);
    if (result.success && result.cookie) {
        global.CONFIG.cookie115 = result.cookie;
        global.saveConfig();
        res.json({ success: true, msg: "登录成功", cookie: result.cookie });
    } else { res.json(result); }
});
router.post('/start', (req, res) => {
    const autoDl = req.body.autoDownload === true;
    const type = req.body.type; // 'inc' or 'full'
    const source = req.body.source || 'madou';
    const categories = req.body.categories || []; // 🔥 接收分类数组

    if (Scraper.getState().isRunning || ScraperXChina.getState().isRunning) {
        return res.json({ success: false, msg: "已有任务正在运行" });
    }

    if (source === 'xchina') {
        ScraperXChina.clearLogs();
        ScraperXChina.start(type, autoDl, categories);
    } else {
        const pages = type === 'full' ? 50000 : 100;
        Scraper.clearLogs();
        Scraper.start(pages, "手动", autoDl);
    }
    res.json({ success: true });
});
router.post('/stop', (req, res) => {
    Scraper.stop();
    ScraperXChina.stop();
    Renamer.stop();
    res.json({ success: true });
});
router.post('/renamer/start', (req, res) => {
    Renamer.start(parseInt(req.body.pages) || 0, req.body.force === true);
    res.json({ success: true });
});
router.post('/push', async (req, res) => {
    const magnets = req.body.magnets || [];
    if (!global.CONFIG.cookie115) return res.json({ success: false, msg: "未登录115" });
    if (magnets.length === 0) return res.json({ success: false, msg: "未选择任务" });
    let successCount = 0;
    try {
        for (const val of magnets) {
            const parts = val.split('|');
            const id = parts[0];
            const magnet = parts.length > 1 ? parts[1].trim() : parts[0].trim();
            const pushed = await Login115.addTask(magnet);
            if (pushed) {
                successCount++;
                await ResourceMgr.markAsPushed(id);
            }
            await new Promise(r => setTimeout(r, 500));
        }
        res.json({ success: true, count: successCount, msg: "推送成功" });
    } catch (e) { res.json({ success: false, msg: e.message }); }
});
router.post('/organize', async (req, res) => {
    const ids = req.body.ids || [];
    if (!global.CONFIG.cookie115) return res.json({ success: false, msg: "未登录115" });
    if (ids.length === 0) return res.json({ success: false, msg: "未选择任务" });

    try {
        const items = await ResourceMgr.getByIds(ids);
        if (items.length === 0) return res.json({ success: false, msg: "未找到记录" });

        let count = 0;
        items.forEach(item => {
            Organizer.addTask(item);
            count++;
        });
        res.json({ success: true, count: count, msg: "已加入后台刮削队列" });
    } catch (e) { res.json({ success: false, msg: e.message }); }
});
router.post('/delete', async (req, res) => {
    const ids = req.body.ids || [];
    if (ids.length === 0) return res.json({ success: false, msg: "未选择删除项" });
    const result = await ResourceMgr.deleteByIds(ids);
    if (result.success) res.json({ success: true, count: result.count });
    else res.json({ success: false, msg: "删除失败: " + result.error });
});
router.get('/data', async (req, res) => {
    const filters = { pushed: req.query.pushed || '', renamed: req.query.renamed || '' };
    const result = await ResourceMgr.getList(parseInt(req.query.page) || 1, 100, filters);
    res.json(result);
});
router.get('/export', async (req, res) => {
    try {
        const type = req.query.type || 'page';
        let data = [];
        if (type === 'all') data = await ResourceMgr.getAllForExport();
        else {
            const result = await ResourceMgr.getList(parseInt(req.query.page) || 1, 100);
            data = result.data;
        }
        const parser = new Parser({ fields: ['id', 'code', 'title', 'magnets', 'created_at'] });
        const csv = parser.parse(data);
        res.header('Content-Type', 'text/csv');
        res.attachment(`madou_${Date.now()}.csv`);
        return res.send(csv);
    } catch (err) { res.status(500).send("Err: " + err.message); }
});
router.post('/system/online-update', async (req, res) => {
    const updateUrl = global.UPDATE_URL;
    const options = { timeout: 30000 };
    if (global.CONFIG.proxy && global.CONFIG.proxy.startsWith('http')) {
        const agent = new HttpsProxyAgent(global.CONFIG.proxy);
        options.httpAgent = agent;
        options.httpsAgent = agent;
    }
    const tempScriptPath = '/data/update_temp.sh';
    const finalScriptPath = '/data/update.sh';
    try {
        console.log(`⬇️ 正在检查更新: ${updateUrl}`);
        const response = await axios({ method: 'get', url: updateUrl, ...options, responseType: 'stream' });
        const writer = fs.createWriteStream(tempScriptPath);
        response.data.pipe(writer);
        writer.on('finish', () => {
            fs.readFile(tempScriptPath, 'utf8', (err, data) => {
                if (err) return res.json({ success: false, msg: "无法读取下载的脚本" });
                const match = data.match(/#\s*VERSION\s*=\s*([0-9\.]+)/);
                const remoteVersion = match ? match[1] : null;
                const localVersion = global.CURRENT_VERSION;
                if (!remoteVersion) return res.json({ success: false, msg: "远程脚本未包含版本号信息" });
                console.log(`🔍 版本对比: 本地[${localVersion}] vs 云端[${remoteVersion}]`);
                if (compareVersions(remoteVersion, localVersion) > 0) {
                    fs.renameSync(tempScriptPath, finalScriptPath);
                    res.json({ success: true, msg: `发现新版本 V${remoteVersion}，正在升级...` });
                    setTimeout(() => {
                        exec(`chmod +x ${finalScriptPath} && sh ${finalScriptPath}`, (error, stdout, stderr) => {
                            if (error) console.error(`❌ 升级失败: ${error.message}`);
                            else {
                                console.log(`✅ 升级日志:\n${stdout}`);
                                fs.renameSync(finalScriptPath, finalScriptPath + '.bak');
                                console.log("🔄 重启容器...");
                                process.exit(0);
                            }
                        });
                    }, 1000);
                } else {
                    fs.unlinkSync(tempScriptPath);
                    res.json({ success: false, msg: `当前已是最新版本 (V${localVersion})` });
                }
            });
        });
        writer.on('error', (err) => { res.json({ success: false, msg: "文件写入失败" }); });
    } catch (e) { res.json({ success: false, msg: "连接失败: " + e.message }); }
});
module.exports = router;
EOF

# 4. 写入完整前端代码: index.html
echo "📝 [3/3] 部署完整 UI..."
cat > public/index.html << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Madou Omni Pro</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
    <style>
        :root { --primary: #6366f1; --bg-body: #0f172a; --bg-card: rgba(30, 41, 59, 0.7); --text-main: #f8fafc; --text-sub: #94a3b8; --border: rgba(148, 163, 184, 0.1); }
        * { box-sizing: border-box; }
        body { background: var(--bg-body); color: var(--text-main); font-family: 'Inter', sans-serif; margin: 0; display: flex; height: 100vh; overflow: hidden; }
        .sidebar { width: 260px; background: #1e293b; padding: 20px; display: flex; flex-direction: column; border-right: 1px solid var(--border); }
        .logo { font-size: 24px; font-weight: 700; margin-bottom: 40px; } .logo span { color: var(--primary); }
        .nav-item { padding: 12px; color: var(--text-sub); border-radius: 8px; margin-bottom: 8px; cursor: pointer; display: block; text-decoration: none; }
        .nav-item:hover { background: rgba(255,255,255,0.05); color: #fff; }
        .nav-item.active { background: var(--primary); color: white; }
        .main { flex: 1; padding: 30px; overflow-y: auto; display: flex; flex-direction: column; }
        .card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; padding: 24px; margin-bottom: 24px; }
        .btn { padding: 8px 16px; border-radius: 6px; border: none; cursor: pointer; color: white; font-size: 14px; }
        .btn-pri { background: var(--primary); }
        .btn-succ { background: #10b981; } .btn-dang { background: #ef4444; } .btn-info { background: #3b82f6; } .btn-warn { background: #f59e0b; color: #000; }
        .input-group { margin-bottom: 15px; } label { display: block; margin-bottom: 5px; font-size: 13px; color: var(--text-sub); }
        input, select, textarea { width: 100%; background: rgba(0,0,0,0.2); border: 1px solid var(--border); padding: 8px; color: white; border-radius: 6px; }
        .log-box { background: #0b1120; height: 300px; overflow-y: auto; padding: 15px; font-family: monospace; font-size: 12px; border-radius: 8px; }
        .log-entry.suc { color: #4ade80; } .log-entry.err { color: #f87171; } .log-entry.warn { color: #fbbf24; }
        .table-container { overflow-x: auto; flex: 1; min-height: 300px;}
        table { width: 100%; border-collapse: collapse; font-size: 13px; }
        th, td { text-align: left; padding: 12px; border-bottom: 1px solid var(--border); vertical-align: middle; }
        th { color: var(--text-sub); background: rgba(0,0,0,0.2); }
        .cover-img { width: 100px; height: 60px; object-fit: cover; border-radius: 4px; background: #000; }
        .tag { padding: 2px 6px; border-radius: 4px; font-size: 10px; margin-right: 4px; display: inline-block; background: rgba(255,255,255,0.1); }
        .tag-actor { color: #f472b6; background: rgba(244, 114, 182, 0.1); }
        .tag-cat { color: #fbbf24; background: rgba(251, 191, 36, 0.1); }
        .magnet-link { display: inline-block; max-width: 300px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #a5b4fc; background: rgba(99,102,241,0.1); padding: 2px 6px; border-radius: 4px; font-family: monospace; font-size: 11px; cursor: pointer; margin-top: 4px; }
        .magnet-link:hover { background: rgba(99,102,241,0.3); color: white; }
        .progress-bar-container { height: 4px; background: rgba(255,255,255,0.1); width: 100%; margin-top: 5px; border-radius: 2px; overflow: hidden; }
        .progress-bar-fill { height: 100%; background: var(--primary); width: 0%; transition: width 0.3s; }
        .status-text { font-size: 11px; color: #94a3b8; display: flex; justify-content: space-between; margin-bottom: 2px; }
        
        .cat-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(120px, 1fr)); gap: 8px; max-height: 200px; overflow-y: auto; padding: 10px; background: rgba(0,0,0,0.2); border-radius: 6px; border: 1px solid var(--border); }
        .cat-item { display: flex; align-items: center; font-size: 12px; cursor: pointer; color: var(--text-sub); }
        .cat-item input { margin-right: 6px; width: auto; }
        .cat-item:hover { color: #fff; }

        .hidden { display: none !important; }
        #lock { position: fixed; inset: 0; background: rgba(15,23,42,0.95); z-index: 999; display: flex; align-items: center; justify-content: center; }
    </style>
</head>
<body>
    <div id="lock">
        <div style="text-align:center; width: 300px;">
            <h2 style="margin-bottom:20px">🔐 系统锁定</h2>
            <input type="password" id="pass" placeholder="输入密码" style="text-align:center;margin-bottom:20px">
            <button class="btn btn-pri" style="width:100%" onclick="login()">解锁</button>
        </div>
    </div>

    <div class="sidebar">
        <div class="logo">⚡ Madou<span>Omni</span></div>
        <a class="nav-item active" onclick="show('scraper')">🕷️ 采集任务</a>
        <a class="nav-item" onclick="show('organizer')">📂 刮削服务</a>
        <a class="nav-item" onclick="show('database')">💾 资源库</a>
        <a class="nav-item" onclick="show('settings')">⚙️ 系统设置</a>
    </div>

    <div class="main">
        <div id="scraper" class="page">
            <div class="card">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:20px"><h2>资源采集</h2><div>今日采集: <span id="stat-scr" style="color:var(--primary);font-weight:bold;font-size:18px">0</span></div></div>
                <div class="input-group"><label>数据源</label><select id="scr-source" onchange="toggleCat(this.value)"><option value="madou">🍄 麻豆区 (MadouQu)</option><option value="xchina">📘 小黄书 (xChina)</option></select></div>
                
                <div class="input-group" id="cat-group" style="display:none">
                    <label>分类选择 (不选则采集全部 54 个分类)</label>
                    <div id="cat-container" class="cat-grid">加载中...</div>
                </div>

                <div class="input-group" style="display:flex;align-items:center;gap:10px;"><input type="checkbox" id="auto-dl" style="width:auto"> <label style="margin:0;cursor:pointer" for="auto-dl">采集并推送到 115</label></div>
                <div style="margin-top:20px; display:flex; gap:10px;"><button class="btn btn-succ" onclick="startScrape('inc')">▶ 增量采集 (50页)</button><button class="btn btn-info" onclick="startScrape('full')">♻️ 全量采集 (5000页)</button><button class="btn btn-dang" onclick="api('stop')">⏹ 停止</button></div>
            </div>
            <div class="card" style="padding:0;"><div style="padding:15px;border-bottom:1px solid var(--border);font-weight:600">📡 运行日志</div><div id="log-scr" class="log-box"></div></div>
        </div>
        <div id="organizer" class="page hidden">
            <div class="card"><h2>115 智能刮削</h2>
                <div class="input-group"><label>目标目录 CID</label><input id="cfg-target-cid" placeholder="例如: 28419384919384"></div>
                <button class="btn btn-pri" onclick="saveCfg()">保存配置</button>
            </div>
        </div>
        <div id="database" class="page hidden" style="height:100%; display:flex; flex-direction:column;">
            <h2>资源数据库</h2>
            <div class="card" style="padding:0; flex:1; display:flex; flex-direction:column; min-height:0;">
                <div style="padding:15px; border-bottom:1px solid var(--border); display:flex; justify-content:space-between; align-items:center">
                    <div><button class="btn btn-info" onclick="pushSelected()">📤 仅推送</button><button class="btn btn-warn" onclick="organizeSelected()">🛠️ 仅刮削</button><button class="btn btn-dang" onclick="deleteSelected()">🗑️ 删除</button></div>
                    <div id="total-count">Loading...</div>
                </div>
                <div class="table-container" style="overflow-y:auto;"><table id="db-tbl"><thead><tr><th style="width:40px"><input type="checkbox" onclick="toggleAll(this)"></th><th style="width:120px">封面</th><th>标题 / 番号 / 磁力</th><th>元数据</th><th>状态</th></tr></thead><tbody></tbody></table></div>
                <div style="padding:15px;text-align:center;border-top:1px solid var(--border)"><button class="btn btn-pri" onclick="loadDb(dbPage-1)">上一页</button><span id="page-info" style="margin:0 15px;color:var(--text-sub)">1</span><button class="btn btn-pri" onclick="loadDb(dbPage+1)">下一页</button></div>
                <div style="height:170px; background:#000; border-top:1px solid var(--border); overflow:hidden; display:flex; flex-direction:column;">
                    <div style="padding:8px 15px; background:#111; border-bottom:1px solid #222;">
                        <div class="status-text"><span id="org-status-txt">⏳ 空闲</span><span id="org-status-count">0 / 0</span></div>
                        <div class="progress-bar-container"><div id="org-progress-fill" class="progress-bar-fill"></div></div>
                    </div>
                    <div id="log-org" class="log-box" style="flex:1; border:none; border-radius:0; height:auto; padding-top:5px;"></div>
                </div>
            </div>
        </div>
        <div id="settings" class="page hidden"><div class="card"><h2>系统设置</h2><div class="input-group"><label>HTTP 代理</label><input id="cfg-proxy"></div><div class="input-group"><label>Flaresolverr 地址</label><input id="cfg-flare"></div><div class="input-group"><label>115 Cookie</label><textarea id="cfg-cookie" rows="3"></textarea></div><button class="btn btn-pri" onclick="saveCfg()">保存配置</button><hr style="border:0;border-top:1px solid var(--border);margin:20px 0"><div style="display:flex;justify-content:space-between;align-items:center"><div>当前版本: <span id="cur-ver" style="color:var(--primary);font-weight:bold">Loading</span></div><button class="btn btn-succ" onclick="runOnlineUpdate()">检查更新</button></div><button class="btn btn-info" style="margin-top:10px" onclick="showQr()">扫码登录 115</button></div></div>
    </div>
    <div id="modal" class="hidden" style="position:fixed;inset:0;background:rgba(0,0,0,0.8);z-index:2000;display:flex;justify-content:center;align-items:center;"><div class="card" style="width:300px;text-align:center;background:#1e293b;"><div id="qr-img" style="background:#fff;padding:10px;border-radius:8px;"></div><div id="qr-txt" style="margin:20px 0;">请使用115 App扫码</div><button class="btn btn-dang" onclick="document.getElementById('modal').classList.add('hidden')">关闭</button></div></div>
    <script src="js/app.js"></script>
    <script>
        // 动态加载分类
        let loadedCats = false;
        async function loadCats() {
            if(loadedCats) return;
            try {
                const res = await request('categories');
                if(res.categories) {
                    const html = res.categories.map(c => 
                        `<label class="cat-item"><input type="checkbox" name="cats" value="${c.code}"> ${c.name}</label>`
                    ).join('');
                    document.getElementById('cat-container').innerHTML = html;
                    loadedCats = true;
                }
            } catch(e) {}
        }

        function toggleCat(val) {
            if(val === 'xchina') {
                document.getElementById('cat-group').style.display = 'block';
                loadCats();
            } else {
                document.getElementById('cat-group').style.display = 'none';
            }
        }

        function startScrape(type) {
            const src = document.getElementById('scr-source').value;
            const dl = getDlState();
            let categories = [];
            
            if (src === 'xchina') {
                const checkedBoxes = document.querySelectorAll('input[name="cats"]:checked');
                checkedBoxes.forEach(cb => categories.push(cb.value));
            }
            
            api('start', { type: type, source: src, autoDownload: dl, categories: categories });
        }
        
        // Init
        toggleCat(document.getElementById('scr-source').value);
    </script>
</body>
</html>
EOF

# 5. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.14.1 部署完成，请强制刷新浏览器体验新分类功能！"
