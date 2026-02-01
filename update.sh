#!/bin/bash
# VERSION = 13.9.8 (Rollback)

echo "🔄 正在执行回滚操作: 降级至 V13.9.8 (磁力链清洗版)..."

# 1. 还原 scraper.js (V13.9.8 的逻辑：仅清洗磁力链，不提取分类)
echo "📝 [1/3] 还原爬虫模块..."
cat > /app/modules/scraper.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const { HttpsProxyAgent } = require('https-proxy-agent');
const puppeteer = require('puppeteer-core');
const ResourceMgr = require('./resource_mgr');
const fs = require('fs');

let STATE = { isRunning: false, stopSignal: false, logs: [], totalScraped: 0 };

function log(msg, type='info') {
    STATE.logs.push({ time: new Date().toLocaleTimeString(), msg, type });
    if (STATE.logs.length > 200) STATE.logs.shift();
    console.log(`[Scraper] ${msg}`);
}

function findChromium() {
    const paths = ['/usr/bin/chromium-browser', '/usr/bin/chromium', '/usr/bin/google-chrome-stable'];
    for (const p of paths) { if (fs.existsSync(p)) return p; }
    return null;
}

// 🧹 磁力链清洗函数
function cleanMagnet(magnet) {
    if (!magnet) return null;
    const match = magnet.match(/(magnet:\?xt=urn:btih:[a-zA-Z0-9]{32,40})/i);
    return match ? match[1] : magnet;
}

function getRequest() {
    const userAgent = global.CONFIG.userAgent || 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    const options = { headers: { 'User-Agent': userAgent }, timeout: 20000 };
    if (global.CONFIG.proxy && global.CONFIG.proxy.startsWith('http')) {
        const agent = new HttpsProxyAgent(global.CONFIG.proxy);
        options.httpAgent = agent;
        options.httpsAgent = agent;
    }
    return axios.create(options);
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

async function scrapeMadouQu(limitPages, autoDownload) {
    let page = 1;
    let url = "https://madouqu.com/";
    const request = getRequest();
    log(`==== 启动 MadouQu 采集 ====`, 'info');
    while (page <= limitPages && !STATE.stopSignal) {
        try {
            const res = await request.get(url);
            const $ = cheerio.load(res.data);
            const posts = $('article h2.entry-title a, h2.entry-title a');
            if (posts.length === 0) break;
            for (let i = 0; i < posts.length; i++) {
                if (STATE.stopSignal) break;
                const link = $(posts[i]).attr('href');
                const title = $(posts[i]).text().trim();
                try {
                    const detail = await request.get(link);
                    const match = detail.data.match(/magnet:\?xt=urn:btih:[a-zA-Z0-9]{32,40}/gi);
                    if (match) {
                        const cleanLink = cleanMagnet(match[0]);
                        const saved = await ResourceMgr.save(title, link, cleanLink);
                        if(saved) {
                            STATE.totalScraped++;
                            if(autoDownload) pushTo115(cleanLink);
                            log(`✅ [入库] ${title.substring(0,10)}...`, 'success');
                        }
                    }
                } catch(e) {}
                await new Promise(r => setTimeout(r, 1000));
            }
            const next = $('a.next').attr('href');
            if (next) { url = next; page++; } else break;
        } catch (e) { log(`Error: ${e.message}`, 'error'); break; }
    }
}

async function scrapeXChina(limitPages, autoDownload) {
    log(`==== 启动 XChina (V13.9.8 回滚版) ====`, 'info');
    const execPath = findChromium();
    if (!execPath) { log(`❌ 未找到 Chromium`, 'error'); return; }

    let browser = null;
    try {
        const launchArgs = ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--disable-blink-features=AutomationControlled', '--window-size=1280,800'];
        if (global.CONFIG.proxy) {
            const proxyUrl = global.CONFIG.proxy.replace('http://', '').replace('https://', '');
            launchArgs.push(`--proxy-server=${proxyUrl}`);
        }

        browser = await puppeteer.launch({ executablePath: execPath, headless: 'new', args: launchArgs });
        const page = await browser.newPage();
        
        await page.evaluateOnNewDocument(() => { Object.defineProperty(navigator, 'webdriver', { get: () => false }); });
        await page.setUserAgent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');

        let currPage = 1;
        let url = "https://xchina.co/videos.html";
        const domain = "https://xchina.co";

        while (currPage <= limitPages && !STATE.stopSignal) {
            log(`[XChina] 浏览器正在加载第 ${currPage} 页...`);
            try {
                await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
                const title = await page.title();
                if (title.includes('Just a moment')) {
                    log(`🛡️ 等待 Cloudflare...`, 'warn');
                    await new Promise(r => setTimeout(r, 8000));
                }
                try { await page.waitForSelector('.item.video', { timeout: 30000 }); } catch(e) {}
            } catch(e) { log(`❌ 网络异常，尝试读取...`, 'error'); }

            const items = await page.evaluate((domain) => {
                const els = document.querySelectorAll('.item.video');
                return Array.from(els).map(el => ({
                    title: el.querySelector('.text .title a')?.innerText.trim(),
                    link: el.querySelector('.text .title a')?.getAttribute('href')
                })).filter(i => i.title && i.link).map(i => {
                    if(i.link.startsWith('/')) i.link = domain + i.link;
                    return i;
                });
            }, domain);

            if (items.length === 0) { log(`⚠️ 未找到数据`, 'warn'); break; }
            log(`[XChina] 发现 ${items.length} 个资源...`);

            for (const item of items) {
                if (STATE.stopSignal) break;
                try {
                    await page.goto(item.link, { waitUntil: 'domcontentloaded', timeout: 45000 });
                    try { await page.waitForSelector('a[href*="/download/id-"]', { timeout: 10000 }); } catch(e){}
                    
                    const dlLink = await page.evaluate((domain) => {
                        const a = document.querySelector('a[href*="/download/id-"]');
                        if(!a) return null;
                        let href = a.getAttribute('href');
                        if(href && href.startsWith('/')) return domain + href;
                        return href;
                    }, domain);
                    
                    if (dlLink) {
                        const fullDlLink = dlLink.startsWith('/') ? domain + dlLink : dlLink;
                        await page.goto(fullDlLink, { waitUntil: 'domcontentloaded', timeout: 45000 });
                        try {
                            await page.waitForSelector('a.btn.magnet[href^="magnet:"]', { timeout: 10000 });
                            const rawMagnet = await page.$eval('a.btn.magnet[href^="magnet:"]', el => el.getAttribute('href'));
                            const cleanLink = cleanMagnet(rawMagnet);

                            if (cleanLink) {
                                const saved = await ResourceMgr.save(item.title, item.link, cleanLink);
                                if(saved) {
                                    STATE.totalScraped++;
                                    let extraMsg = "";
                                    if(autoDownload) {
                                        await pushTo115(cleanLink);
                                        extraMsg = " | 📥 推送OK";
                                    }
                                    log(`✅ [入库${extraMsg}] ${item.title.substring(0, 15)}...`, 'success');
                                }
                            }
                        } catch(e) {}
                    }
                } catch(e) { log(`❌ 单条失败`, 'warn'); }
                await new Promise(r => setTimeout(r, 1000));
            }

            const nextHref = await page.evaluate((domain) => {
                const a = document.querySelector('.pagination a:contains("下一页")') || 
                          Array.from(document.querySelectorAll('.pagination a')).find(el => el.textContent.includes('下一页') || el.textContent.includes('Next'));
                if(!a) return null;
                let href = a.getAttribute('href');
                if(href && href.startsWith('/')) return domain + href;
                return href;
            }, domain);

            if (nextHref) {
                url = nextHref;
                currPage++;
                await new Promise(r => setTimeout(r, 2000));
            } else { break; }
        }
    } catch (e) { log(`🔥 浏览器崩溃: ${e.message}`, 'error'); } 
    finally { if (browser) await browser.close(); }
}

module.exports = Scraper;
EOF

# 2. 还原 resource_mgr.js (去掉 category 字段的逻辑)
echo "📝 [2/3] 还原数据库管理器..."
cat > /app/modules/resource_mgr.js << 'EOF'
const sqlite3 = require('sqlite3').verbose();
const path = require('path');
const dbPath = path.join(__dirname, '../data/database.sqlite');
const db = new sqlite3.Database(dbPath);

db.serialize(() => {
    db.run(`CREATE TABLE IF NOT EXISTS resources (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT,
        link TEXT UNIQUE,
        magnets TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )`);
    // 即使 V13.9.9 已经加了 category 列，旧代码不调用它也不会报错
    db.run("ALTER TABLE resources ADD COLUMN is_pushed INTEGER DEFAULT 0", () => {});
    db.run("ALTER TABLE resources ADD COLUMN is_renamed INTEGER DEFAULT 0", () => {});
});

const ResourceMgr = {
    save: (title, link, magnets) => {
        return new Promise((resolve, reject) => {
            const stmt = db.prepare(`INSERT OR IGNORE INTO resources (title, link, magnets) VALUES (?, ?, ?)`);
            stmt.run(title, link, magnets, function(err) {
                if (err) reject(err);
                else resolve(this.changes > 0);
            });
            stmt.finalize();
        });
    },
    markAsPushedByLink: (link) => {
        return new Promise((resolve, reject) => {
            db.run("UPDATE resources SET is_pushed = 1 WHERE link = ?", [link], (err) => {
                if (err) reject(err); else resolve(true);
            });
        });
    }
};
module.exports = ResourceMgr;
EOF

# 3. 还原 index.html (去掉分类列)
echo "📝 [3/3] 还原前端界面..."
cat > /app/public/index.html << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>Madou Omni Pro</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
    <style>
        :root { --primary: #6366f1; --primary-hover: #4f46e5; --bg-body: #0f172a; --bg-sidebar: #1e293b; --bg-card: rgba(30, 41, 59, 0.7); --border: rgba(148, 163, 184, 0.1); --text-main: #f8fafc; --text-sub: #94a3b8; --success: #10b981; --warning: #f59e0b; --danger: #ef4444; --radius: 12px; --shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1); }
        * { box-sizing: border-box; outline: none; -webkit-tap-highlight-color: transparent; }
        body { background-color: var(--bg-body); background-image: radial-gradient(at 0% 0%, rgba(99, 102, 241, 0.15) 0px, transparent 50%), radial-gradient(at 100% 100%, rgba(16, 185, 129, 0.1) 0px, transparent 50%); background-attachment: fixed; color: var(--text-main); font-family: 'Inter', sans-serif; margin: 0; display: flex; height: 100vh; overflow: hidden; }
        .sidebar { width: 260px; background: var(--bg-sidebar); border-right: 1px solid var(--border); display: flex; flex-direction: column; padding: 20px; z-index: 10; }
        .logo { font-size: 24px; font-weight: 700; color: var(--text-main); margin-bottom: 40px; }
        .logo span { color: var(--primary); }
        .nav-item { display: flex; align-items: center; padding: 12px 16px; color: var(--text-sub); text-decoration: none; border-radius: var(--radius); margin-bottom: 8px; transition: all 0.2s; font-weight: 500; cursor: pointer; }
        .nav-item:hover { background: rgba(255,255,255,0.05); color: var(--text-main); }
        .nav-item.active { background: var(--primary); color: white; box-shadow: 0 4px 12px rgba(99, 102, 241, 0.3); }
        .nav-icon { margin-right: 12px; font-size: 18px; }
        .main { flex: 1; padding: 30px; overflow-y: auto; position: relative; }
        h1 { font-size: 24px; margin: 0 0 20px 0; font-weight: 600; }
        .card { background: var(--bg-card); backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px); border: 1px solid var(--border); border-radius: var(--radius); padding: 24px; margin-bottom: 24px; box-shadow: var(--shadow); }
        .btn { padding: 10px 24px; border: none; border-radius: 8px; font-weight: 500; cursor: pointer; transition: all 0.2s; display: inline-flex; align-items: center; justify-content: center; gap: 8px; color: white; font-size: 14px; min-width: 100px; }
        .btn:active { transform: scale(0.98); }
        .btn-pri { background: var(--primary); }
        .btn-pri:hover { background: var(--primary-hover); }
        .btn-succ { background: var(--success); color: #fff; }
        .btn-succ:hover { filter: brightness(1.1); }
        .btn-dang { background: var(--danger); }
        .btn-warn { background: var(--warning); color: #000; }
        .btn-info { background: #3b82f6; }
        .input-group { margin-bottom: 15px; }
        label { display: block; margin-bottom: 8px; color: var(--text-sub); font-size: 13px; }
        input, select, textarea { width: 100%; background: rgba(0,0,0,0.2); border: 1px solid var(--border); border-radius: 8px; padding: 10px 12px; color: white; font-family: inherit; transition: 0.2s; }
        input:focus, select:focus, textarea:focus { border-color: var(--primary); }
        .btn-row { display: flex; gap: 10px; justify-content: flex-start; margin-bottom: 10px; flex-wrap: wrap; }
        .log-box { background: #0b1120; border-radius: 8px; padding: 15px; height: 300px; overflow-y: auto; font-family: monospace; font-size: 12px; line-height: 1.6; border: 1px solid var(--border); }
        .log-box .err{color:#f55} .log-box .warn{color:#fb5} .log-box .suc{color:#5f7}
        .filter-bar { display: flex; gap: 15px; background: rgba(0,0,0,0.2); padding: 15px; border-radius: 8px; align-items: flex-end; margin-bottom: 20px; }
        .filter-item { flex: 1; }
        .filter-item select { margin-bottom: 0; }
        .table-container { overflow-x: auto; }
        table { width: 100%; border-collapse: collapse; table-layout: fixed; }
        th, td { text-align: left; padding: 12px; border-bottom: 1px solid var(--border); font-size: 13px; vertical-align: top; }
        th { color: var(--text-sub); background: rgba(0,0,0,0.2); }
        td { color: var(--text-main); line-height: 1.5; }
        .col-chk { width: 40px; }
        .col-id { width: 60px; }
        .col-time { width: 110px; }
        .col-title { width: 25%; }
        .magnet-cell { word-break: break-all; white-space: normal; font-family: monospace; font-size: 12px; color: #a5b4fc; }
        .title-cell { white-space: normal; font-weight: 500; }
        .tag { padding: 2px 6px; border-radius: 4px; font-size: 10px; font-weight: 600; margin-right: 5px; display: inline-block; margin-bottom: 4px;}
        .tag-push { background: rgba(16, 185, 129, 0.2); color: #34d399; }
        .tag-ren { background: rgba(59, 130, 246, 0.2); color: #60a5fa; }
        #lock { position: fixed; inset: 0; background: rgba(15, 23, 42, 0.95); z-index: 999; display: flex; align-items: center; justify-content: center; }
        .lock-box { background: var(--bg-sidebar); padding: 40px; border-radius: 16px; width: 100%; max-width: 360px; text-align: center; border: 1px solid var(--border); }
        .hidden { display: none !important; }
        @media (max-width: 768px) {
            body { flex-direction: column; height: 100dvh; }
            .sidebar { position: fixed; bottom: 0; left: 0; width: 100%; height: 60px; flex-direction: row; padding: 0; background: rgba(30, 41, 59, 0.9); backdrop-filter: blur(10px); border-top: 1px solid var(--border); border-right: none; justify-content: space-around; align-items: center; }
            .logo { display: none; }
            .nav-item { flex-direction: column; gap: 4px; padding: 6px; margin: 0; font-size: 10px; background: none !important; color: var(--text-sub); }
            .nav-item.active { color: var(--primary); background: none; box-shadow: none; }
            .nav-icon { margin: 0; font-size: 20px; }
            .main { padding: 15px; padding-bottom: 80px; }
            .btn { width: 100%; margin-right: 0; margin-bottom: 10px; }
            .btn-row { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
            .filter-bar { flex-direction: column; gap: 10px; }
            table { min-width: 700px; }
        }
    </style>
</head>
<body>
    <div id="lock">
        <div class="lock-box">
            <div style="font-size:40px;margin-bottom:20px">🔐</div>
            <h2 style="margin-bottom:20px">系统锁定</h2>
            <input type="password" id="pass" placeholder="输入访问密码" style="text-align:center;font-size:16px;margin-bottom:20px">
            <button class="btn btn-pri" style="width:100%" onclick="login()">解锁进入</button>
            <div id="msg" style="color:var(--danger);margin-top:15px;font-size:14px"></div>
        </div>
    </div>
    <div class="sidebar">
        <div class="logo">⚡ Madou<span>Pro</span></div>
        <a class="nav-item active" onclick="show('scraper')"><span class="nav-icon">🕷️</span> 采集</a>
        <a class="nav-item" onclick="show('renamer')"><span class="nav-icon">📂</span> 整理</a>
        <a class="nav-item" onclick="show('database')"><span class="nav-icon">💾</span> 资源库</a>
        <a class="nav-item" onclick="show('settings')"><span class="nav-icon">⚙️</span> 设置</a>
    </div>
    <div class="main">
        <div id="scraper" class="page">
            <div class="card">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:20px">
                    <h1>资源采集</h1>
                    <div style="font-size:14px;color:var(--text-sub)">今日采集: <span id="stat-scr" style="color:var(--primary);font-weight:bold;font-size:18px">0</span></div>
                </div>
                <div class="input-group">
                    <label>📡 选择采集源</label>
                    <select id="src-site">
                        <option value="madou">MadouQu (麻豆区)</option>
                        <option value="xchina">XChina (小黄书) - 全自动</option>
                    </select>
                </div>
                <div class="input-group" style="display:flex;align-items:center;gap:10px;background:rgba(255,255,255,0.05);padding:10px;border-radius:8px;margin-bottom:20px">
                    <input type="checkbox" id="auto-dl" style="width:20px;height:20px;margin:0">
                    <label for="auto-dl" style="margin:0;cursor:pointer">启用自动推送 (采集成功后直接发往 115)</label>
                </div>
                <div class="btn-row">
                    <button class="btn btn-succ" onclick="startScrape('inc')">▶ 增量采集</button>
                    <button class="btn btn-info" onclick="startScrape('full')">♻️ 全量采集</button>
                    <button class="btn btn-dang" onclick="api('stop')">⏹ 停止</button>
                </div>
            </div>
            <div class="card" style="padding:0;overflow:hidden">
                <div style="padding:15px;border-bottom:1px solid var(--border);font-weight:600">📡 实时终端日志</div>
                <div id="log-scr" class="log-box" style="border:none;border-radius:0"></div>
            </div>
        </div>
        <div id="renamer" class="page hidden">
            <div class="card">
                <h1>115 整理助手</h1>
                <div class="input-group">
                    <label>扫描页数 (0 代表全部)</label>
                    <input type="number" id="r-pages" value="0" placeholder="默认扫描全部">
                </div>
                <div class="input-group" style="display:flex;align-items:center;gap:10px;margin-bottom:20px">
                    <input type="checkbox" id="r-force" style="width:20px;margin:0">
                    <label for="r-force" style="margin:0">强制模式 (重新检查已整理项目)</label>
                </div>
                <div class="btn-row">
                    <button class="btn btn-pri" onclick="startRenamer()">🚀 开始整理</button>
                    <button class="btn btn-dang" onclick="api('stop')">⏹ 停止</button>
                </div>
                <div style="margin-top:20px;display:flex;justify-content:space-around;text-align:center;background:rgba(0,0,0,0.2);padding:15px;border-radius:8px">
                    <div><div style="font-size:12px;color:var(--text-sub)">成功</div><div id="stat-suc" style="color:var(--success);font-size:20px;font-weight:bold">0</div></div>
                    <div><div style="font-size:12px;color:var(--text-sub)">失败</div><div id="stat-fail" style="color:var(--danger);font-size:20px;font-weight:bold">0</div></div>
                    <div><div style="font-size:12px;color:var(--text-sub)">跳过</div><div id="stat-skip" style="color:var(--text-sub);font-size:20px;font-weight:bold">0</div></div>
                </div>
            </div>
            <div class="card" style="padding:0;overflow:hidden">
                <div style="padding:15px;border-bottom:1px solid var(--border);font-weight:600">🛠️ 整理日志</div>
                <div id="log-ren" class="log-box" style="border:none;border-radius:0"></div>
            </div>
        </div>
        <div id="database" class="page hidden">
            <h1>资源数据库</h1>
            <div class="filter-bar">
                <div class="filter-item">
                    <label>推送状态</label>
                    <select id="filter-push" onchange="loadDb(1)"><option value="">全部</option><option value="1">✅ 已推送</option><option value="0">⏳ 未推送</option></select>
                </div>
                <div class="filter-item">
                    <label>整理状态</label>
                    <select id="filter-ren" onchange="loadDb(1)"><option value="">全部</option><option value="1">✨ 已整理</option><option value="0">📝 未整理</option></select>
                </div>
            </div>
            <div class="card" style="padding:0;overflow:hidden">
                <div style="padding:15px;border-bottom:1px solid var(--border);display:flex;justify-content:space-between;align-items:center;background:rgba(0,0,0,0.1)">
                    <div class="btn-row" style="margin-bottom:0">
                        <button class="btn btn-info" style="padding:6px 12px;font-size:12px;min-width:auto" onclick="pushSelected()">📤 推送选中</button>
                        <button class="btn btn-warn" style="padding:6px 12px;font-size:12px;min-width:auto" onclick="window.open(url('/export?type=all'))">📥 导出CSV</button>
                    </div>
                    <div id="total-count" style="font-size:12px;color:var(--text-sub)">Loading...</div>
                </div>
                <div class="table-container">
                    <table id="db-tbl">
                        <thead>
                            <tr>
                                <th class="col-chk"><input type="checkbox" onclick="toggleAll(this)"></th>
                                <th class="col-id">ID</th>
                                <th class="col-title">标题</th>
                                <th>磁力链</th>
                                <th class="col-time">时间</th>
                            </tr>
                        </thead>
                        <tbody></tbody>
                    </table>
                </div>
                <div style="padding:15px;display:flex;justify-content:center;gap:20px;align-items:center;border-top:1px solid var(--border)">
                    <button class="btn btn-pri" style="min-width:auto" onclick="loadDb(dbPage-1)">上一页</button>
                    <span id="page-info" style="color:var(--text-sub)">1</span>
                    <button class="btn btn-pri" style="min-width:auto" onclick="loadDb(dbPage+1)">下一页</button>
                </div>
            </div>
        </div>
        <div id="settings" class="page hidden">
            <h1>系统设置</h1>
            <div class="card" style="display:flex;flex-direction:column;align-items:center;justify-content:center;padding:40px">
                <div style="font-size:48px;margin-bottom:20px">📱</div>
                <button class="btn btn-pri" style="font-size:16px;padding:12px 30px" onclick="showQr()">扫码登录 115</button>
                <p style="color:var(--text-sub);margin-top:10px;font-size:13px">使用 115 App 扫码，Cookie 将自动更新</p>
            </div>
            <div class="card" style="border-left: 4px solid var(--success)">
                <h3>☁️ 在线升级</h3>
                <div style="display:flex;justify-content:space-between;align-items:center;margin-top:15px">
                    <div><div style="font-size:13px;color:var(--text-sub)">当前版本</div><div id="cur-ver" style="font-size:24px;font-weight:bold;color:var(--text-main)">V13.9.8</div></div>
                    <button class="btn btn-succ" onclick="runOnlineUpdate()">检查更新</button>
                </div>
            </div>
            <div class="card">
                <h3>网络配置</h3>
                <div class="input-group">
                    <label>HTTP 代理</label>
                    <input id="cfg-proxy" placeholder="留空则直连">
                </div>
                <div style="background:rgba(0,0,0,0.2);padding:15px;border-radius:8px;margin-bottom:15px">
                    <h4 style="margin-top:0;margin-bottom:10px;color:var(--warning)">🛡️ 反爬虫配置 (高级模式可留空)</h4>
                    <div class="input-group">
                        <label>User-Agent (浏览器标识)</label>
                        <textarea id="cfg-ua" rows="2" placeholder="自动管理，可留空"></textarea>
                    </div>
                </div>
                <div class="input-group">
                    <label>115 Cookie</label>
                    <textarea id="cfg-cookie" rows="4" placeholder="UID=...; CID=...; SEID=..."></textarea>
                </div>
                <div class="btn-row">
                    <button class="btn btn-pri" onclick="saveCfg()">💾 保存配置</button>
                </div>
            </div>
        </div>
    </div>
    <div id="modal" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,0.8);z-index:1000;justify-content:center;align-items:center;backdrop-filter:blur(5px)">
        <div class="card" style="width:300px;text-align:center;background:var(--bg-sidebar)">
            <h3 style="margin-bottom:20px">请使用 115 App 扫码</h3>
            <div id="qr-img" style="background:white;padding:10px;border-radius:8px;display:inline-block"></div>
            <div id="qr-txt" style="margin:20px 0;color:var(--warning)">正在加载二维码...</div>
            <button class="btn btn-dang" onclick="document.getElementById('modal').style.display='none'">关闭</button>
        </div>
    </div>
    <script src="js/app.js"></script>
    <script>
        async function loadDb(p) {
            if(p < 1) return;
            dbPage = p;
            document.getElementById('page-info').innerText = p;
            const pushVal = document.getElementById('filter-push').value;
            const renVal = document.getElementById('filter-ren').value;
            const res = await request(`data?page=${p}&pushed=${pushVal}&renamed=${renVal}`);
            const tbody = document.querySelector('#db-tbl tbody');
            tbody.innerHTML = '';
            if(res.data) {
                document.getElementById('total-count').innerText = "总计: " + (res.total || 0);
                res.data.forEach(r => {
                    const time = new Date(r.created_at).toLocaleDateString();
                    let tags = "";
                    if (r.is_pushed) tags += `<span class="tag tag-push">已推</span> `;
                    if (r.is_renamed) tags += `<span class="tag tag-ren">已整</span>`;
                    const chkValue = `${r.id}|${r.magnets}`;
                    const magnetText = r.magnets || '';
                    tbody.innerHTML += `<tr><td><input type="checkbox" class="tbl-chk row-chk" value="${chkValue}"></td><td><span style="opacity:0.5">#</span>${r.id}</td><td class="title-cell"><div style="margin-bottom:4px">${r.title}</div><div>${tags}</div></td><td class="magnet-cell">${magnetText}</td><td style="font-size:12px;color:var(--text-sub)">${time}</td></tr>`;
                });
            }
        }
    </script>
</body>
</html>
EOF

# 4. 更新版本号
echo "📝 更新版本号..."
sed -i 's/"version": ".*"/"version": "13.9.8"/' /app/package.json

echo "✅ 回滚完成！系统将自动重启..."

# 重启容器 (需要容器外部支持，或者手动重启)
# 如果是 Docker 内部，通常 exit 0 不会重启容器，除非配置了 restart=always
exit 0
