#!/bin/bash
# 目标版本: 13.9.8 (从 13.6.0 直升)

echo "========================================================"
echo "🚀 开始执行 Madou-Omni 全量升级 (V13.6.0 -> V13.9.8)"
echo "📅 日期: $(date)"
echo "🛡️ 安全承诺: 仅更新代码与环境，不触碰数据库文件 (data.db)"
echo "========================================================"

# --------------------------------------------------------
# 步骤 1: 安装系统级依赖 (Chromium 浏览器内核)
# --------------------------------------------------------
echo "⏳ [1/5] 正在配置 Alpine Linux 系统环境..."

# 切换为阿里云源，确保国内下载速度
echo "   -> 切换软件源为阿里云..."
sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories

# 更新索引并安装浏览器
echo "   -> 正在下载并安装 Chromium 及依赖 (可能需要 2-5 分钟)..."
apk update
apk add --no-cache \
    chromium \
    nss \
    freetype \
    harfbuzz \
    ca-certificates \
    ttf-freefont \
    libstdc++ \
    udev \
    ttf-opensans \
    mesa-gl

# 验证安装结果
if [ -f "/usr/bin/chromium-browser" ] || [ -f "/usr/bin/chromium" ]; then
    echo "   ✅ Chromium 内核安装成功！"
else
    echo "   ❌ 严重错误: Chromium 安装失败，请检查网络连接！"
    # 这里不退出，尝试继续，但爬虫可能无法运行
fi

# --------------------------------------------------------
# 步骤 2: 更新 Node.js 依赖配置
# --------------------------------------------------------
echo "📦 [2/5] 更新 package.json (添加 puppeteer-core)..."
cat > /app/package.json << 'EOF'
{
  "name": "madou-omni-system",
  "version": "13.9.8",
  "description": "Madou Omni Pro System",
  "main": "app.js",
  "scripts": {
    "start": "node app.js"
  },
  "dependencies": {
    "axios": "^1.6.0",
    "cheerio": "^1.0.0-rc.12",
    "cookie-parser": "^1.4.6",
    "cors": "^2.8.5",
    "express": "^4.18.2",
    "https-proxy-agent": "^7.0.2",
    "mysql2": "^3.6.5",
    "node-schedule": "^2.1.1",
    "json2csv": "^6.0.0-alpha.2",
    "puppeteer-core": "^21.5.0"
  }
}
EOF

# --------------------------------------------------------
# 步骤 3: 更新前端 UI (增加高级设置项)
# --------------------------------------------------------
echo "🖥️ [3/5] 更新前端界面 (index.html)..."
cat > /app/public/index.html << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Madou Omni Pro</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
    <style>
        :root { --primary: #6366f1; --bg-body: #0f172a; --bg-card: rgba(30, 41, 59, 0.7); --text-main: #f8fafc; --text-sub: #94a3b8; }
        * { box-sizing: border-box; }
        body { background-color: var(--bg-body); color: var(--text-main); font-family: 'Inter', sans-serif; margin: 0; display: flex; height: 100vh; overflow: hidden; }
        .sidebar { width: 260px; background: #1e293b; padding: 20px; display: flex; flex-direction: column; border-right: 1px solid rgba(255,255,255,0.1); }
        .nav-item { padding: 12px; color: var(--text-sub); cursor: pointer; border-radius: 8px; margin-bottom: 5px; }
        .nav-item.active { background: var(--primary); color: white; }
        .main { flex: 1; padding: 30px; overflow-y: auto; }
        .card { background: var(--bg-card); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 24px; margin-bottom: 24px; }
        .btn { padding: 10px 24px; border: none; border-radius: 8px; cursor: pointer; color: white; font-weight: 500; }
        .btn-pri { background: var(--primary); }
        .btn-succ { background: #10b981; }
        .btn-dang { background: #ef4444; }
        .input-group { margin-bottom: 15px; }
        label { display: block; margin-bottom: 8px; color: var(--text-sub); font-size: 13px; }
        input, select, textarea { width: 100%; background: rgba(0,0,0,0.3); border: 1px solid rgba(255,255,255,0.1); border-radius: 8px; padding: 10px; color: white; }
        .log-box { background: #000; padding: 15px; height: 300px; overflow-y: auto; font-family: monospace; font-size: 12px; border-radius: 8px; color: #ccc; }
        .hidden { display: none !important; }
        table { width: 100%; border-collapse: collapse; }
        td, th { text-align: left; padding: 12px; border-bottom: 1px solid rgba(255,255,255,0.1); }
    </style>
</head>
<body>
    <div class="sidebar">
        <h2 style="margin-bottom: 30px">⚡ MadouPro</h2>
        <div class="nav-item active" onclick="show('scraper')">🕷️ 采集任务</div>
        <div class="nav-item" onclick="show('renamer')">📂 115 整理</div>
        <div class="nav-item" onclick="show('database')">💾 资源数据库</div>
        <div class="nav-item" onclick="show('settings')">⚙️ 系统设置</div>
    </div>
    <div class="main">
        <div id="scraper" class="page">
            <div class="card">
                <h1>新建采集任务</h1>
                <div class="input-group">
                    <label>数据源</label>
                    <select id="src-site">
                        <option value="madou">MadouQu (普通源)</option>
                        <option value="xchina">XChina (浏览器增强源)</option>
                    </select>
                </div>
                <div class="input-group">
                    <input type="checkbox" id="auto-dl" style="width:auto"> 
                    <label style="display:inline"> 采集成功后自动推送到 115</label>
                </div>
                <button class="btn btn-succ" onclick="startScrape('inc')">▶ 开始增量采集</button>
                <button class="btn btn-dang" onclick="api('stop')">⏹ 停止任务</button>
            </div>
            <div class="card">
                <h3>运行日志</h3>
                <div id="log-scr" class="log-box"></div>
            </div>
        </div>

        <div id="renamer" class="page hidden">
            <div class="card">
                <h1>115 文件整理</h1>
                <div class="input-group"><label>扫描页数</label><input type="number" id="r-pages" value="1"></div>
                <button class="btn btn-pri" onclick="startRenamer()">🚀 开始整理</button>
            </div>
            <div class="card"><div id="log-ren" class="log-box"></div></div>
        </div>

        <div id="database" class="page hidden">
            <div class="card">
                <div style="display:flex;justify-content:space-between;align-items:center">
                    <h1>本地资源库</h1>
                    <button class="btn btn-pri" onclick="loadDb(1)">🔄 刷新</button>
                </div>
                <div style="overflow-x:auto">
                    <table id="db-tbl"><thead><tr><th>ID</th><th>标题</th><th>磁力链 (已清洗)</th></tr></thead><tbody></tbody></table>
                </div>
            </div>
        </div>

        <div id="settings" class="page hidden">
            <div class="card">
                <h1>系统配置</h1>
                <div class="input-group">
                    <label>HTTP 代理 (例如 http://192.168.1.5:7890)</label>
                    <input id="cfg-proxy" placeholder="留空则直连">
                </div>
                <div class="input-group">
                    <label>115 Cookie</label>
                    <textarea id="cfg-cookie" rows="3"></textarea>
                </div>
                <div style="border-top:1px solid rgba(255,255,255,0.1); margin: 20px 0; padding-top: 20px;">
                    <h3 style="margin-top:0">🛡️ 反爬虫高级配置</h3>
                    <div class="input-group">
                        <label>User-Agent (浏览器标识)</label>
                        <textarea id="cfg-ua" rows="2" placeholder="Mozilla/5.0..."></textarea>
                    </div>
                    <div class="input-group">
                        <label>采集 Cookie (备用，通常自动获取)</label>
                        <textarea id="cfg-scraper-cookie" rows="3"></textarea>
                    </div>
                </div>
                <button class="btn btn-pri" onclick="saveCfg()">💾 保存配置</button>
            </div>
        </div>
    </div>
    <script src="js/app.js"></script>
</body>
</html>
EOF

# --------------------------------------------------------
# 步骤 4: 更新前端逻辑 (app.js)
# --------------------------------------------------------
echo "📝 [4/5] 更新前端交互逻辑 (app.js)..."
cat > /app/public/js/app.js << 'EOF'
// V13.9.8 App Logic
async function request(endpoint, options = {}) {
    try {
        const res = await fetch('/api/' + endpoint, {
            ...options,
            headers: { 'Content-Type': 'application/json', ...options.headers }
        });
        return await res.json();
    } catch (e) { console.error(e); return { success: false, msg: e.message }; }
}

async function api(act, body = {}) {
    await request(act, { method: 'POST', body: JSON.stringify(body) });
}

function show(id) {
    document.querySelectorAll('.page').forEach(e => e.classList.add('hidden'));
    document.getElementById(id).classList.remove('hidden');
    document.querySelectorAll('.nav-item').forEach(e => e.classList.remove('active'));
    
    // Highlight sidebar
    const items = document.querySelectorAll('.nav-item');
    if(id === 'scraper') items[0].classList.add('active');
    if(id === 'renamer') items[1].classList.add('active');
    if(id === 'database') { items[2].classList.add('active'); loadDb(1); }
    if(id === 'settings') { items[3].classList.add('active'); loadCfg(); }
}

async function startScrape(type) {
    const source = document.getElementById('src-site').value;
    const autoDl = document.getElementById('auto-dl').checked;
    await api('start', { type, source, autoDownload: autoDl });
}

async function startRenamer() {
    api('renamer/start', { pages: document.getElementById('r-pages').value });
}

// 加载配置
async function loadCfg() {
    const res = await request('status');
    if (res.config) {
        document.getElementById('cfg-proxy').value = res.config.proxy || '';
        document.getElementById('cfg-cookie').value = res.config.cookie115 || '';
        document.getElementById('cfg-scraper-cookie').value = res.config.scraperCookie || '';
        document.getElementById('cfg-ua').value = res.config.userAgent || '';
    }
}

// 保存配置
async function saveCfg() {
    await request('config', {
        method: 'POST',
        body: JSON.stringify({
            proxy: document.getElementById('cfg-proxy').value,
            cookie115: document.getElementById('cfg-cookie').value,
            scraperCookie: document.getElementById('cfg-scraper-cookie').value,
            userAgent: document.getElementById('cfg-ua').value
        })
    });
    alert('✅ 配置已保存');
}

// 加载数据库
async function loadDb(p) {
    const res = await request(`data?page=${p}`);
    const tbody = document.querySelector('#db-tbl tbody');
    tbody.innerHTML = '';
    if (res.data) {
        res.data.forEach(r => {
            // 简单截取显示磁力链，防止太长
            const shortMag = r.magnets ? r.magnets.substring(0, 40) + '...' : '';
            tbody.innerHTML += `<tr><td>${r.id}</td><td>${r.title}</td><td style="font-family:monospace;font-size:12px;color:#a5b4fc">${shortMag}</td></tr>`;
        });
    }
}

// 日志轮询
setInterval(async () => {
    const res = await request('status');
    if (res.state) {
        const el = document.getElementById('log-scr');
        res.state.logs.forEach(l => {
            el.innerHTML += `<div style="margin-bottom:2px"><span style="color:#666">[${l.time}]</span> ${l.msg}</div>`;
        });
        if(res.state.logs.length > 0) el.scrollTop = el.scrollHeight;
    }
    if (res.renamerState) {
        const el = document.getElementById('log-ren');
        res.renamerState.logs.forEach(l => {
            el.innerHTML += `<div style="margin-bottom:2px"><span style="color:#666">[${l.time}]</span> ${l.msg}</div>`;
        });
        if(res.renamerState.logs.length > 0) el.scrollTop = el.scrollHeight;
    }
}, 2000);
EOF

# --------------------------------------------------------
# 步骤 5: 更新采集核心 (scraper.js)
# --------------------------------------------------------
echo "🕷️ [5/5] 更新采集核心模块 (scraper.js)..."
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

// 自动探测 Chromium 路径
function findChromium() {
    const paths = ['/usr/bin/chromium-browser', '/usr/bin/chromium', '/usr/bin/google-chrome-stable'];
    for (const p of paths) { if (fs.existsSync(p)) return p; }
    return null;
}

// 🧽 磁力链清洗函数 (V13.9.8 新增)
function cleanMagnet(magnet) {
    if (!magnet) return null;
    const match = magnet.match(/(magnet:\?xt=urn:btih:[a-zA-Z0-9]{32,40})/i);
    return match ? match[1] : magnet;
}

// 通用 HTTP 请求构建器
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

// 115 推送函数
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

// MadouQu 采集 (Axios 模式)
async function scrapeMadouQu(limitPages, autoDownload) {
    let page = 1;
    let url = "https://madouqu.com/";
    const request = getRequest();
    log(`==== 启动 MadouQu 采集 (V13.9.8) ====`, 'info');
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
                        const cleanLink = cleanMagnet(match[0]); // 清洗
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

// XChina 采集 (Puppeteer 浏览器模式 - 强行读取版)
async function scrapeXChina(limitPages, autoDownload) {
    log(`==== 启动 XChina (浏览器增强版 V13.9.8) ====`, 'info');
    const execPath = findChromium();
    if (!execPath) { log(`❌ 错误: 未找到 Chromium 浏览器，请检查安装`, 'error'); return; }

    let browser = null;
    try {
        const launchArgs = [
            '--no-sandbox', 
            '--disable-setuid-sandbox', 
            '--disable-dev-shm-usage',
            '--disable-gpu',
            '--disable-blink-features=AutomationControlled',
            '--window-size=1280,800'
        ];
        if (global.CONFIG.proxy) {
            const proxyUrl = global.CONFIG.proxy.replace('http://', '').replace('https://', '');
            launchArgs.push(`--proxy-server=${proxyUrl}`);
        }

        browser = await puppeteer.launch({ executablePath: execPath, headless: 'new', args: launchArgs });
        const page = await browser.newPage();
        
        // 伪装隐身
        await page.evaluateOnNewDocument(() => { Object.defineProperty(navigator, 'webdriver', { get: () => false }); });
        await page.setUserAgent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');

        let currPage = 1;
        let url = "https://xchina.co/videos.html";
        const domain = "https://xchina.co";

        while (currPage <= limitPages && !STATE.stopSignal) {
            log(`[XChina] 浏览器正在渲染第 ${currPage} 页...`);
            
            try {
                await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
                
                const title = await page.title();
                if (title.includes('Just a moment') || title.includes('Attention')) {
                    log(`🛡️ 遇到 Cloudflare，模拟人类操作...`, 'warn');
                    await page.mouse.move(100, 100);
                    await new Promise(r => setTimeout(r, 8000));
                }
                
                // 尝试等待内容，超时也不报错
                try { await page.waitForSelector('.item.video', { timeout: 20000 }); } catch(e) {}

            } catch(e) { log(`⚠️ 网络加载异常，尝试强行读取...`, 'warn'); }

            const items = await page.evaluate((domain) => {
                const els = document.querySelectorAll('.item.video');
                const results = [];
                els.forEach(el => {
                    const t = el.querySelector('.text .title a');
                    if(t) {
                        let href = t.getAttribute('href');
                        if(href && href.startsWith('/')) href = domain + href;
                        results.push({ title: t.innerText.trim(), link: href });
                    }
                });
                return results;
            }, domain);

            if (items.length === 0) { log(`⚠️ 本页未提取到数据 (可能已被拦截)`, 'warn'); break; }
            log(`[XChina] 成功提取 ${items.length} 条数据，开始解析...`);

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
                            const cleanLink = cleanMagnet(rawMagnet); // 执行清洗

                            if (cleanLink) {
                                const saved = await ResourceMgr.save(item.title, item.link, cleanLink);
                                if(saved) {
                                    STATE.totalScraped++;
                                    let extraMsg = "";
                                    if(autoDownload) {
                                        const pushed = await pushTo115(cleanLink);
                                        if(pushed) extraMsg = " | 📥 推送成功";
                                    }
                                    log(`✅ [入库${extraMsg}] ${item.title.substring(0, 15)}...`, 'success');
                                }
                            }
                        } catch(e) {}
                    }
                } catch(e) {}
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

            if (nextHref) { url = nextHref; currPage++; await new Promise(r => setTimeout(r, 2000)); } else { break; }
        }

    } catch (e) {
        log(`🔥 浏览器异常: ${e.message}`, 'error');
    } finally {
        if (browser) await browser.close();
    }
}

const Scraper = {
    getState: () => STATE,
    stop: () => { STATE.stopSignal = true; },
    clearLogs: () => { STATE.logs = []; },
    start: async (limitPages = 5, source = "madou", autoDownload = false) => {
        if (STATE.isRunning) return;
        STATE.isRunning = true;
        STATE.stopSignal = false;
        STATE.totalScraped = 0;
        log(`🚀 任务启动 | 源: ${source} | 自动下载: ${autoDownload ? '✅开启' : '❌关闭'}`, 'success');
        if (source === 'madou') await scrapeMadouQu(limitPages, autoDownload);
        else if (source === 'xchina') await scrapeXChina(limitPages, autoDownload);
        STATE.isRunning = false;
        log(`🏁 任务结束，本次共入库 ${STATE.totalScraped} 条`, 'warn');
    }
};
module.exports = Scraper;
EOF

echo "========================================================"
echo "✅ 全量升级脚本执行完毕 (V13.9.8)"
echo "⚠️ 请务必执行以下命令重启容器以生效："
echo "   exit"
echo "   docker restart madou_omni_system"
echo "========================================================"
