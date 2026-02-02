#!/bin/bash
# VERSION = 13.14.3

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.14.3
# 功能: 1. xChina 集成 m3u8 视频流提取逻辑 (无磁力时自动回退)
#       2. 增加 PikPak 配置界面 (为下一版对接做准备)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署 M3U8 提取增强版 (V13.14.3)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.14.3"/' package.json

# 2. 升级 Scraper (加入您的提取代码)
echo "📝 [1/3] 升级采集核心 (集成油猴提取逻辑)..."
cat > modules/scraper_xchina.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const ResourceMgr = require('./resource_mgr');

// ⚡️ 任务配置
const CONCURRENCY_LIMIT = 3;
const MAX_RETRIES = 3;

// 📜 内置分类库 (保持不变)
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

    let magnet = '';

    // 1. 尝试常规磁力提取 (Priority 1)
    try {
        const downloadLinkEl = $('a[href*="/download/id-"]');
        if (downloadLinkEl.length > 0) {
            let downloadPageUrl = downloadLinkEl.attr('href');
            if (downloadPageUrl && !downloadPageUrl.startsWith('http')) {
                downloadPageUrl = baseUrl + downloadPageUrl;
            }
            const $down = await requestViaFlare(downloadPageUrl);
            const rawMagnet = $down('a.btn.magnet').attr('href');
            if (rawMagnet) magnet = cleanMagnet(rawMagnet);
        }
    } catch (e) {}

    // 2. 备用: 尝试提取 m3u8 (Priority 2)
    // 逻辑来源: 您的油猴脚本
    if (!magnet) {
        const htmlContent = $.html(); // 获取完整 HTML
        const regex = /src:\s*['"](https?:\/\/[^'"]+\.m3u8[^'"]*)['"]/;
        const match = htmlContent.match(regex);
        if (match && match[1]) {
            magnet = match[1];
            log(`🔎 [${code}] 启用 M3U8 备用源`, 'info');
        }
    }

    if (magnet) {
        const saveRes = await ResourceMgr.save({
            title, link, magnets: magnet, code, image, actor, category
        });

        if (saveRes.success) {
            if (saveRes.newInsert) {
                STATE.totalScraped++;
                let extraMsg = "";
                
                // 如果是磁力链，推115
                if (autoDownload && magnet.startsWith('magnet')) {
                    const pushed = await pushTo115(magnet);
                    extraMsg = pushed ? " | 📥 已推115" : " | ⚠️ 推送失败";
                    if(pushed) await ResourceMgr.markAsPushedByLink(link);
                } 
                // 🔥 如果是 m3u8，暂时不推 115 (等待 PikPak 模块)
                else if (magnet.includes('.m3u8')) {
                    extraMsg = " | ⏳ 待推PikPak"; 
                }

                log(`✅ [入库] ${code} | ${title.substring(0, 10)}...${extraMsg}`, 'success');
                return true;
            } else {
                log(`⏭️ [已存在] ${title.substring(0, 10)}...`, 'info');
                return true;
            }
        }
    } else {
        // log(`❌ 无有效链接 (Magnet/M3U8): ${code}`, 'warn');
    }
    return false;
}

// 核心：单分类采集循环
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

# 3. 升级 index.html (添加 PikPak 配置槽位)
echo "📝 [2/3] 升级 UI (添加 PikPak 配置)..."
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
        <div id="settings" class="page hidden">
            <div class="card">
                <h2>系统设置</h2>
                <div class="input-group"><label>HTTP 代理</label><input id="cfg-proxy"></div>
                <div class="input-group"><label>Flaresolverr 地址</label><input id="cfg-flare"></div>
                <div class="input-group"><label>115 Cookie</label><textarea id="cfg-cookie" rows="3"></textarea></div>
                <hr style="border:0;border-top:1px solid var(--border);margin:20px 0">
                <div class="input-group"><label>PikPak 账号/Cookie (预留)</label><textarea id="cfg-pikpak" rows="2" placeholder="下一版本启用，请填入 PikPak 鉴权信息"></textarea></div>
                
                <button class="btn btn-pri" onclick="saveCfg()">保存配置</button>
                <hr style="border:0;border-top:1px solid var(--border);margin:20px 0">
                <div style="display:flex;justify-content:space-between;align-items:center"><div>当前版本: <span id="cur-ver" style="color:var(--primary);font-weight:bold">Loading</span></div><button class="btn btn-succ" onclick="runOnlineUpdate()">检查更新</button></div>
                <button class="btn btn-info" style="margin-top:10px" onclick="showQr()">扫码登录 115</button>
            </div>
        </div>
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

# 4. 更新前端 JS 以保存 PikPak 设置
echo "📝 [3/3] 升级前端逻辑..."
cat > public/js/app.js << 'EOF'
let dbPage = 1;
let qrTimer = null;

async function request(endpoint, options = {}) {
    const token = localStorage.getItem('token');
    const headers = { 'Content-Type': 'application/json' };
    if (token) headers['Authorization'] = token;
    try {
        const res = await fetch('/api/' + endpoint, { ...options, headers: { ...headers, ...options.headers } });
        if (res.status === 401) {
            localStorage.removeItem('token');
            document.getElementById('lock').classList.remove('hidden');
            throw new Error("未登录");
        }
        return await res.json();
    } catch (e) { console.error(e); return { success: false, msg: e.message }; }
}

async function login() {
    const p = document.getElementById('pass').value;
    const res = await fetch('/api/login', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({password: p}) });
    const data = await res.json();
    if (data.success) { localStorage.setItem('token', p); document.getElementById('lock').classList.add('hidden'); } else { alert("密码错误"); }
}

window.onload = async () => {
    const res = await request('check-auth');
    if (res.authenticated) document.getElementById('lock').classList.add('hidden');
    document.getElementById('pass').addEventListener('keypress', e => { if(e.key === 'Enter') login(); });
    
    // 初始化配置回显
    const r = await request('status');
    if(r.config) {
        if(document.getElementById('cfg-proxy')) document.getElementById('cfg-proxy').value = r.config.proxy || '';
        if(document.getElementById('cfg-cookie')) document.getElementById('cfg-cookie').value = r.config.cookie115 || '';
        if(document.getElementById('cfg-flare')) document.getElementById('cfg-flare').value = r.config.flaresolverrUrl || '';
        if(document.getElementById('cfg-target-cid')) document.getElementById('cfg-target-cid').value = r.config.targetCid || '';
        // 🔥 新增 PikPak 回显
        if(document.getElementById('cfg-pikpak')) document.getElementById('cfg-pikpak').value = r.config.pikpak || '';
    }
    if(r.version && document.getElementById('cur-ver')) document.getElementById('cur-ver').innerText = "V" + r.version;
};

function show(id) {
    document.querySelectorAll('.page').forEach(e => e.classList.add('hidden'));
    document.getElementById(id).classList.remove('hidden');
    document.querySelectorAll('.nav-item').forEach(e => e.classList.remove('active'));
    if(event && event.target) event.target.closest('.nav-item').classList.add('active');
    if(id === 'database') loadDb(1);
    if(id === 'settings' || id === 'organizer') {
        // 重新获取状态刷新配置显示
        setTimeout(async () => {
            const r = await request('status');
            if(r.config) {
                if(document.getElementById('cfg-proxy')) document.getElementById('cfg-proxy').value = r.config.proxy || '';
                if(document.getElementById('cfg-cookie')) document.getElementById('cfg-cookie').value = r.config.cookie115 || '';
                if(document.getElementById('cfg-flare')) document.getElementById('cfg-flare').value = r.config.flaresolverrUrl || '';
                if(document.getElementById('cfg-target-cid')) document.getElementById('cfg-target-cid').value = r.config.targetCid || '';
                if(document.getElementById('cfg-pikpak')) document.getElementById('cfg-pikpak').value = r.config.pikpak || '';
            }
            if(r.version && document.getElementById('cur-ver')) document.getElementById('cur-ver').innerText = "V" + r.version;
        }, 100);
    }
}

function getDlState() { return document.getElementById('auto-dl').checked; }

async function api(act, body={}) { 
    const res = await request(act, { method: 'POST', body: JSON.stringify(body) }); 
    if(!res.success && res.msg) alert("❌ " + res.msg);
    if(res.success && act === 'start') alert("✅ 任务已启动");
}

function startScrape(type) {
    const src = document.getElementById('scr-source').value;
    const dl = getDlState();
    // 使用全局 toggleCat 函数中定义的逻辑，这里简化
    // (逻辑已经在 index.html 中被内联 JS 覆盖，这里 app.js 主要是辅助)
    // 为了兼容，这里保留空壳，实际调用的是 index.html 里的 startScrape
}

async function startRenamer() { const p = document.getElementById('r-pages').value; const f = document.getElementById('r-force').checked; api('renamer/start', { pages: p, force: f }); }

async function runOnlineUpdate() {
    const btn = event.target; const oldTxt = btn.innerText; btn.innerText = "⏳ 检查中..."; btn.disabled = true;
    try {
        const res = await request('system/online-update', { method: 'POST' });
        if(res.success) { alert("🚀 " + res.msg); setTimeout(() => location.reload(), 15000); } 
        else { alert("❌ " + res.msg); }
    } catch(e) { alert("请求失败"); }
    btn.innerText = oldTxt; btn.disabled = false;
}

async function saveCfg() {
    const proxy = document.getElementById('cfg-proxy') ? document.getElementById('cfg-proxy').value : undefined;
    const cookie115 = document.getElementById('cfg-cookie') ? document.getElementById('cfg-cookie').value : undefined;
    const flaresolverrUrl = document.getElementById('cfg-flare') ? document.getElementById('cfg-flare').value : undefined;
    const targetCid = document.getElementById('cfg-target-cid') ? document.getElementById('cfg-target-cid').value : undefined;
    const pikpak = document.getElementById('cfg-pikpak') ? document.getElementById('cfg-pikpak').value : undefined;
    
    const body = {};
    if(proxy !== undefined) body.proxy = proxy;
    if(cookie115 !== undefined) body.cookie115 = cookie115;
    if(flaresolverrUrl !== undefined) body.flaresolverrUrl = flaresolverrUrl;
    if(targetCid !== undefined) body.targetCid = targetCid;
    if(pikpak !== undefined) body.pikpak = pikpak;

    await request('config', { method: 'POST', body: JSON.stringify(body) });
    alert('✅ 配置已保存');
}

function toggleAll(source) { const checkboxes = document.querySelectorAll('.row-chk'); checkboxes.forEach(cb => cb.checked = source.checked); }

async function pushSelected(organize = false) {
    const checkboxes = document.querySelectorAll('.row-chk:checked');
    if (checkboxes.length === 0) { alert("请先勾选!"); return; }
    const magnets = Array.from(checkboxes).map(cb => cb.value);
    const btn = event.target; const oldText = btn.innerText; btn.innerText = "处理中..."; btn.disabled = true;
    try { 
        const res = await request('push', { method: 'POST', body: JSON.stringify({ magnets, organize }) }); 
        if (res.success) { alert(`✅ ${res.msg} (成功: ${res.count})`); loadDb(dbPage); } else { alert(`❌ 失败: ${res.msg}`); }
    } catch(e) { alert("网络请求失败"); }
    btn.innerText = oldText; btn.disabled = false;
}

async function organizeSelected() {
    const checkboxes = document.querySelectorAll('.row-chk:checked');
    if (checkboxes.length === 0) { alert("请先勾选!"); return; }
    const ids = Array.from(checkboxes).map(cb => cb.value.includes('|') ? cb.value.split('|')[0] : cb.value);
    const btn = event.target; btn.innerText = "请求中..."; btn.disabled = true;
    try { 
        const res = await request('organize', { method: 'POST', body: JSON.stringify({ ids }) }); 
        if (res.success) { alert(`✅ 已加入队列: ${res.count}`); } else { alert(`❌ ${res.msg}`); }
    } catch(e) { alert("网络错误"); }
    btn.innerText = "🛠️ 仅刮削"; btn.disabled = false;
}

async function deleteSelected() {
    const checkboxes = document.querySelectorAll('.row-chk:checked');
    if (checkboxes.length === 0) { alert("请先勾选!"); return; }
    if(!confirm(`确定要删除 ${checkboxes.length} 条记录吗？`)) return;
    const ids = Array.from(checkboxes).map(cb => cb.value.includes('|') ? cb.value.split('|')[0] : cb.value);
    try { await request('delete', { method: 'POST', body: JSON.stringify({ ids }) }); loadDb(dbPage); } catch(e) {}
}

async function loadDb(p) {
    if(p < 1) return;
    dbPage = p;
    document.getElementById('page-info').innerText = p;
    const totalCountEl = document.getElementById('total-count');
    totalCountEl.innerText = "Loading...";
    try {
        const res = await request(`data?page=${p}`);
        const tbody = document.querySelector('#db-tbl tbody');
        tbody.innerHTML = '';
        if(res.data) {
            totalCountEl.innerText = "总计: " + (res.total || 0);
            res.data.forEach(r => {
                const chkValue = `${r.id}|${r.magnets || ''}`;
                const imgHtml = r.image_url ? `<img src="${r.image_url}" class="cover-img" loading="lazy" onclick="window.open('${r.link}')" style="cursor:pointer">` : `<div class="cover-img" style="display:flex;align-items:center;justify-content:center;color:#555;font-size:10px">无封面</div>`;
                let statusTags = "";
                if (r.is_pushed) statusTags += `<span class="tag" style="color:#34d399;background:rgba(16,185,129,0.1)">已推</span>`;
                if (r.is_renamed) statusTags += `<span class="tag" style="color:#60a5fa;background:rgba(59,130,246,0.1)">已整</span>`;
                let metaTags = "";
                if (r.actor) metaTags += `<span class="tag tag-actor">👤 ${r.actor}</span>`;
                if (r.category) metaTags += `<span class="tag tag-cat">🏷️ ${r.category}</span>`;
                let cleanMagnet = r.magnets || '';
                // 优化显示：如果是m3u8，显示m3u8标签
                let magnetLabel = '🔗';
                if(cleanMagnet.includes('.m3u8')) magnetLabel = '📺';
                
                if (cleanMagnet.includes('&')) cleanMagnet = cleanMagnet.split('&')[0];
                const magnetDisplay = cleanMagnet ? `<div class="magnet-link" onclick="navigator.clipboard.writeText('${cleanMagnet}');alert('链接已复制')">${magnetLabel} ${cleanMagnet.substring(0, 20)}...</div>` : '';
                tbody.innerHTML += `<tr><td><input type="checkbox" class="row-chk" value="${chkValue}"></td><td>${imgHtml}</td><td><div style="font-weight:500;margin-bottom:4px;max-width:300px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${r.title}</div><div style="font-size:12px;color:var(--text-sub);font-family:monospace">${r.code || '无番号'}</div>${magnetDisplay}</td><td>${metaTags}</td><td>${statusTags}</td></tr>`;
            });
        } else { totalCountEl.innerText = "加载失败"; }
    } catch(e) { totalCountEl.innerText = "网络错误"; }
}

// 保持日志定时器 (略)
let lastLogTimeScr = "";
let lastLogTimeOrg = "";
setInterval(async () => {
    if(!document.getElementById('lock').classList.contains('hidden')) return;
    const res = await request('status');
    if(!res.config) return;
    
    const renderLog = (elId, logs, lastTimeVar) => {
        const el = document.getElementById(elId);
        if(!el) return lastTimeVar;
        if(logs && logs.length > 0) {
            const latestLog = logs[logs.length-1];
            const latestSignature = latestLog.time + latestLog.msg;
            if (latestSignature !== lastTimeVar) {
                el.innerHTML = logs.map(l => `<div class="log-entry ${l.type==='error'?'err':l.type==='success'?'suc':l.type==='warn'?'warn':''}"><span class="time">[${l.time}]</span> ${l.msg}</div>`).join('');
                el.scrollTop = el.scrollHeight;
                return latestSignature;
            }
        }
        return lastTimeVar;
    };
    lastLogTimeScr = renderLog('log-scr', res.state.logs, lastLogTimeScr);
    lastLogTimeOrg = renderLog('log-org', res.organizerLogs, lastLogTimeOrg);
    if(res.organizerStats && document.getElementById('org-progress-fill')) {
        const s = res.organizerStats;
        const percent = s.total > 0 ? (s.processed / s.total) * 100 : 0;
        document.getElementById('org-progress-fill').style.width = percent + '%';
        let statusText = s.current || '空闲';
        if(s.total > 0) {
            if(s.processed < s.total) statusText = '🎬 处理中: ' + statusText;
            else statusText = '✅ 完成';
        }
        document.getElementById('org-status-txt').innerText = statusText;
        document.getElementById('org-status-count').innerText = `${s.processed} / ${s.total}`;
    }
    if(document.getElementById('stat-scr')) document.getElementById('stat-scr').innerText = res.state.totalScraped || 0;
}, 2000);

async function showQr() {
    const m = document.getElementById('modal'); m.classList.remove('hidden');
    const res = await request('115/qr'); if(!res.success) return;
    const { uid, time, sign, qr_url } = res.data;
    document.getElementById('qr-img').innerHTML = `<img src="${qr_url}" width="200">`;
    if(qrTimer) clearInterval(qrTimer);
    qrTimer = setInterval(async () => {
        const chk = await request(`115/check?uid=${uid}&time=${time}&sign=${sign}`);
        const txt = document.getElementById('qr-txt');
        if(chk.success) { txt.innerText = "✅ 成功! 刷新..."; txt.style.color = "#0f0"; clearInterval(qrTimer); setTimeout(() => { m.classList.add('hidden'); location.reload(); }, 1000); }
        else if (chk.status === 1) { txt.innerText = "📱 已扫码"; txt.style.color = "#fb5"; }
    }, 1500);
}
EOF

# 5. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.14.3 部署完成！"
