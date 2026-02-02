#!/bin/bash
# VERSION = 13.9.0

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.9.0
# 核心升级: 支持配置外部 Flaresolverr 地址，减轻本机负载
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署外挂 Flaresolverr 版 (V13.9.0)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.9.0"/' package.json

# 2. 升级 scraper_xchina.js (支持动态 Flaresolverr 地址)
echo "📝 [1/3] 升级采集核心 (支持外部服务)..."
cat > modules/scraper_xchina.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const ResourceMgr = require('./resource_mgr');

// ⚡️ 并发数
const CONCURRENCY_LIMIT = 3;
// ⚡️ 最大重试次数
const MAX_RETRIES = 3;

let STATE = { isRunning: false, stopSignal: false, logs: [], totalScraped: 0 };

function log(msg, type = 'info') {
    STATE.logs.push({ time: new Date().toLocaleTimeString(), msg, type });
    if (STATE.logs.length > 200) STATE.logs.shift();
    console.log(`[Scraper-xChina] ${msg}`);
}

function cleanMagnet(magnet) {
    if (!magnet) return '';
    const match = magnet.match(/(magnet:\?xt=urn:btih:[a-zA-Z0-9]{32,40})/i);
    if (match) return match[0];
    return magnet.split('&')[0];
}

// 🔧 获取配置的 Flaresolverr 地址
function getFlareUrl() {
    let url = global.CONFIG.flaresolverrUrl || 'http://flaresolverr:8191';
    // 去除末尾斜杠
    if (url.endsWith('/')) url = url.slice(0, -1);
    // 自动补全 /v1 接口路径
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
    let image = $('.vjs-poster img').attr('src');
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
    } else {
        throw new Error("无效磁力链");
    }
    return false;
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
        
        const flareUrl = getFlareUrl().replace('/v1',''); // 仅用于日志显示
        log(`🚀 xChina 外挂版 (V13.9.0) | Flare: ${flareUrl}`, 'success');

        try {
            // 检查外部 Flaresolverr 连通性
            // 移除 /v1 检查根路径，因为 /v1 只接受 POST
            const checkUrl = flareUrl.replace(/\/v1\/?$/, '') || 'http://flaresolverr:8191';
            
            try { await axios.get(checkUrl, { timeout: 5000 }); } 
            catch (e) { throw new Error(`无法连接外部 Flaresolverr: ${checkUrl} (${e.message})`); }

            let page = 1;
            const baseUrl = "https://xchina.co";
            
            while (page <= limitPages && !STATE.stopSignal) {
                const listUrl = page === 1 ? `${baseUrl}/videos.html` : `${baseUrl}/videos/${page}.html`;
                log(`📡 扫描第 ${page} 页列表...`, 'info');

                try {
                    const $ = await requestViaFlare(listUrl);
                    const items = $('.item.video');
                    
                    if (items.length === 0) { log(`⚠️ 第 ${page} 页未发现视频`, 'warn'); break; }
                    log(`🔍 本页发现 ${items.length} 个视频...`);

                    let newItemsInPage = 0;
                    const tasks = [];
                    
                    items.each((i, el) => {
                        const title = $(el).find('.text .title a').text().trim();
                        let subLink = $(el).find('.text .title a').attr('href');
                        if (title && subLink) {
                            if (!subLink.startsWith('http')) subLink = baseUrl + subLink;
                            tasks.push({ title, link: subLink });
                        }
                    });

                    for (let i = 0; i < tasks.length; i += CONCURRENCY_LIMIT) {
                        if (STATE.stopSignal) break;
                        const chunk = tasks.slice(i, i + CONCURRENCY_LIMIT);
                        const results = await Promise.all(chunk.map(task => 
                            processVideoTaskWithRetry(task, baseUrl, autoDownload)
                        ));
                        newItemsInPage += results.filter(r => r === true).length;
                        await new Promise(r => setTimeout(r, 500)); 
                    }

                    if (newItemsInPage === 0 && page > 1) { log(`⚠️ 本页全为旧数据，提前结束`, 'warn'); break; }
                    page++;
                    await new Promise(r => setTimeout(r, 2000));

                } catch (pageErr) {
                    log(`❌ 页面获取失败: ${pageErr.message}`, 'error');
                    await new Promise(r => setTimeout(r, 5000));
                }
            }
        } catch (err) { log(`🔥 全局异常: ${err.message}`, 'error'); }
        
        STATE.isRunning = false;
        log(`🏁 任务结束，新增 ${STATE.totalScraped} 条`, 'warn');
    }
};
module.exports = ScraperXChina;
EOF

# 3. 更新 public/index.html (增加设置项)
echo "📝 [2/3] 更新前端设置界面..."
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
        .main { flex: 1; padding: 30px; overflow-y: auto; }
        .card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; padding: 24px; margin-bottom: 24px; }
        .btn { padding: 8px 16px; border-radius: 6px; border: none; cursor: pointer; color: white; font-size: 14px; }
        .btn-pri { background: var(--primary); }
        .btn-succ { background: #10b981; } .btn-dang { background: #ef4444; } .btn-info { background: #3b82f6; }
        .input-group { margin-bottom: 15px; } label { display: block; margin-bottom: 5px; font-size: 13px; color: var(--text-sub); }
        input, select, textarea { width: 100%; background: rgba(0,0,0,0.2); border: 1px solid var(--border); padding: 8px; color: white; border-radius: 6px; }
        .log-box { background: #0b1120; height: 300px; overflow-y: auto; padding: 15px; font-family: monospace; font-size: 12px; border-radius: 8px; }
        .log-entry.suc { color: #4ade80; } .log-entry.err { color: #f87171; } .log-entry.warn { color: #fbbf24; }
        .table-container { overflow-x: auto; }
        table { width: 100%; border-collapse: collapse; font-size: 13px; }
        th, td { text-align: left; padding: 12px; border-bottom: 1px solid var(--border); vertical-align: middle; }
        th { color: var(--text-sub); background: rgba(0,0,0,0.2); }
        .cover-img { width: 100px; height: 60px; object-fit: cover; border-radius: 4px; background: #000; }
        .tag { padding: 2px 6px; border-radius: 4px; font-size: 10px; margin-right: 4px; display: inline-block; background: rgba(255,255,255,0.1); }
        .tag-actor { color: #f472b6; background: rgba(244, 114, 182, 0.1); }
        .tag-cat { color: #fbbf24; background: rgba(251, 191, 36, 0.1); }
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
        <a class="nav-item" onclick="show('renamer')">📂 整理助手</a>
        <a class="nav-item" onclick="show('database')">💾 资源库</a>
        <a class="nav-item" onclick="show('settings')">⚙️ 系统设置</a>
    </div>

    <div class="main">
        <div id="scraper" class="page">
            <div class="card">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:20px">
                    <h2>资源采集</h2>
                    <div>今日采集: <span id="stat-scr" style="color:var(--primary);font-weight:bold;font-size:18px">0</span></div>
                </div>
                <div class="input-group">
                    <label>数据源</label>
                    <select id="scr-source">
                        <option value="madou">🍄 麻豆区 (MadouQu)</option>
                        <option value="xchina">📘 小黄书 (xChina - 推荐)</option>
                    </select>
                </div>
                <div class="input-group" style="display:flex;align-items:center;gap:10px;">
                    <input type="checkbox" id="auto-dl" style="width:auto"> <label style="margin:0;cursor:pointer" for="auto-dl">自动推送到 115</label>
                </div>
                <div style="margin-top:20px; display:flex; gap:10px;">
                    <button class="btn btn-succ" onclick="startScrape('inc')">▶ 增量采集</button>
                    <button class="btn btn-info" onclick="startScrape('full')">♻️ 全量采集</button>
                    <button class="btn btn-dang" onclick="api('stop')">⏹ 停止</button>
                </div>
            </div>
            <div class="card" style="padding:0;">
                <div style="padding:15px;border-bottom:1px solid var(--border);font-weight:600">📡 运行日志</div>
                <div id="log-scr" class="log-box"></div>
            </div>
        </div>

        <div id="database" class="page hidden">
            <h2>资源数据库</h2>
            <div class="card" style="padding:0;">
                <div style="padding:15px; border-bottom:1px solid var(--border); display:flex; justify-content:space-between;">
                    <div>
                        <button class="btn btn-info" onclick="pushSelected()">📤 推送选中</button>
                        <button class="btn btn-succ" onclick="window.open(url('/export?type=all'))">📥 导出CSV</button>
                    </div>
                    <div id="total-count">Loading...</div>
                </div>
                <div class="table-container">
                    <table id="db-tbl">
                        <thead>
                            <tr>
                                <th style="width:40px"><input type="checkbox" onclick="toggleAll(this)"></th>
                                <th style="width:120px">封面</th>
                                <th>标题 / 番号</th>
                                <th>元数据</th>
                                <th>状态</th>
                            </tr>
                        </thead>
                        <tbody></tbody>
                    </table>
                </div>
                <div style="padding:15px;text-align:center;">
                    <button class="btn btn-pri" onclick="loadDb(dbPage-1)">上一页</button>
                    <span id="page-info" style="margin:0 15px;color:var(--text-sub)">1</span>
                    <button class="btn btn-pri" onclick="loadDb(dbPage+1)">下一页</button>
                </div>
            </div>
        </div>

        <div id="settings" class="page hidden">
            <div class="card">
                <h2>系统设置</h2>
                <div class="input-group">
                    <label>HTTP 代理 (例如 http://192.168.1.5:7890)</label>
                    <input id="cfg-proxy">
                </div>
                <div class="input-group">
                    <label>Flaresolverr 地址 (留空则使用内置, 外部如 http://192.168.1.6:8191)</label>
                    <input id="cfg-flare" placeholder="http://flaresolverr:8191">
                </div>
                
                <div class="input-group"><label>115 Cookie</label><textarea id="cfg-cookie" rows="3"></textarea></div>
                <button class="btn btn-pri" onclick="saveCfg()">保存配置</button>
                <hr style="border:0;border-top:1px solid var(--border);margin:20px 0">
                <div style="display:flex;justify-content:space-between;align-items:center">
                    <div>当前版本: <span id="cur-ver" style="color:var(--primary);font-weight:bold">Loading</span></div>
                    <button class="btn btn-succ" onclick="runOnlineUpdate()">检查更新</button>
                </div>
                <button class="btn btn-info" style="margin-top:10px" onclick="showQr()">扫码登录 115</button>
            </div>
        </div>
        
        <div id="renamer" class="page hidden">
            <div class="card"><h2>115 整理助手</h2>
            <div class="input-group"><label>扫描页数</label><input type="number" id="r-pages" value="0"></div>
            <div class="input-group"><input type="checkbox" id="r-force" style="width:auto"><label style="display:inline">强制重整</label></div>
            <button class="btn btn-pri" onclick="startRenamer()">开始整理</button>
            <div id="log-ren" class="log-box" style="margin-top:20px;height:200px"></div></div>
        </div>
    </div>

    <div id="modal" class="hidden" style="position:fixed;inset:0;background:rgba(0,0,0,0.8);z-index:2000;display:flex;justify-content:center;align-items:center;">
        <div class="card" style="width:300px;text-align:center;background:#1e293b;">
            <div id="qr-img" style="background:#fff;padding:10px;border-radius:8px;"></div>
            <div id="qr-txt" style="margin:20px 0;">请使用115 App扫码</div>
            <button class="btn btn-dang" onclick="document.getElementById('modal').classList.add('hidden')">关闭</button>
        </div>
    </div>

    <script src="js/app.js"></script>
    <script>
        async function loadDb(p) {
            if(p < 1) return;
            dbPage = p;
            document.getElementById('page-info').innerText = p;
            const res = await request(`data?page=${p}`);
            const tbody = document.querySelector('#db-tbl tbody');
            tbody.innerHTML = '';
            if(res.data) {
                document.getElementById('total-count').innerText = "总计: " + (res.total || 0);
                res.data.forEach(r => {
                    const chkValue = `${r.id}|${r.magnets}`;
                    const imgHtml = r.image_url ? 
                        `<img src="${r.image_url}" class="cover-img" loading="lazy" onclick="window.open('${r.link}')" style="cursor:pointer">` : 
                        `<div class="cover-img" style="display:flex;align-items:center;justify-content:center;color:#555;font-size:10px">无封面</div>`;
                    let statusTags = "";
                    if (r.is_pushed) statusTags += `<span class="tag" style="color:#34d399;background:rgba(16,185,129,0.1)">已推</span>`;
                    if (r.is_renamed) statusTags += `<span class="tag" style="color:#60a5fa;background:rgba(59,130,246,0.1)">已整</span>`;
                    let metaTags = "";
                    if (r.actor) metaTags += `<span class="tag tag-actor">👤 ${r.actor}</span>`;
                    if (r.category) metaTags += `<span class="tag tag-cat">🏷️ ${r.category}</span>`;
                    tbody.innerHTML += `<tr><td><input type="checkbox" class="row-chk" value="${chkValue}"></td><td>${imgHtml}</td><td><div style="font-weight:500;margin-bottom:4px;max-width:300px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${r.title}</div><div style="font-size:12px;color:var(--text-sub);font-family:monospace">${r.code || '无番号'}</div></td><td>${metaTags}</td><td>${statusTags}</td></tr>`;
                });
            }
        }
    </script>
</body>
</html>
EOF

# 4. 更新 public/js/app.js (绑定保存逻辑)
echo "📝 [3/3] 更新 JS 配置逻辑..."
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
    if (data.success) { localStorage.setItem('token', p); document.getElementById('lock').classList.add('hidden'); } else { document.getElementById('msg').innerText = "密码错误"; }
}

window.onload = async () => {
    const res = await request('check-auth');
    if (res.authenticated) document.getElementById('lock').classList.add('hidden');
    document.getElementById('pass').addEventListener('keypress', e => { if(e.key === 'Enter') login(); });
};

function show(id) {
    document.querySelectorAll('.page').forEach(e => e.classList.add('hidden'));
    document.getElementById(id).classList.remove('hidden');
    document.querySelectorAll('.nav-item').forEach(e => e.classList.remove('active'));
    if(event && event.target) {
       const target = event.target.closest('.nav-item');
       if(target) target.classList.add('active');
    }
    if(id === 'database') loadDb(1);
    
    if(id === 'settings') {
        setTimeout(async () => {
            const r = await request('status');
            if(r.config) {
                document.getElementById('cfg-proxy').value = r.config.proxy || '';
                document.getElementById('cfg-cookie').value = r.config.cookie115 || '';
                // 加载 Flaresolverr 地址
                document.getElementById('cfg-flare').value = r.config.flaresolverrUrl || '';
            }
            if(r.version) {
                document.getElementById('cur-ver').innerText = "V" + r.version;
            }
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
    api('start', { type: type, source: src, autoDownload: dl });
}

async function startRenamer() { const p = document.getElementById('r-pages').value; const f = document.getElementById('r-force').checked; api('renamer/start', { pages: p, force: f }); }

async function runOnlineUpdate() {
    const btn = event.target;
    const oldTxt = btn.innerText;
    btn.innerText = "⏳ 检查中...";
    btn.disabled = true;
    try {
        const res = await request('system/online-update', { method: 'POST' });
        if(res.success) {
            alert("🚀 " + res.msg);
            setTimeout(() => location.reload(), 15000);
        } else {
            alert("❌ " + res.msg);
        }
    } catch(e) { alert("请求失败"); }
    btn.innerText = oldTxt;
    btn.disabled = false;
}

async function saveCfg() {
    const proxy = document.getElementById('cfg-proxy').value;
    const cookie115 = document.getElementById('cfg-cookie').value;
    const flaresolverrUrl = document.getElementById('cfg-flare').value;
    
    await request('config', { method: 'POST', body: JSON.stringify({ proxy, cookie115, flaresolverrUrl }) });
    alert('保存成功');
}

function toggleAll(source) { const checkboxes = document.querySelectorAll('.row-chk'); checkboxes.forEach(cb => cb.checked = source.checked); }
async function pushSelected() {
    const checkboxes = document.querySelectorAll('.row-chk:checked');
    if (checkboxes.length === 0) { alert("请先勾选需要推送的资源！"); return; }
    const magnets = Array.from(checkboxes).map(cb => cb.value);
    const btn = event.target; const oldText = btn.innerText; btn.innerText = "推送中..."; btn.disabled = true;
    try { const res = await request('push', { method: 'POST', body: JSON.stringify({ magnets }) }); if (res.success) { alert(`✅ 成功推送 ${res.count} 个任务`); loadDb(dbPage); } else { alert(`❌ 失败: ${res.msg}`); } } catch(e) { alert("网络请求失败"); }
    btn.innerText = oldText; btn.disabled = false;
}

let lastLogTimeScr = ""; let lastLogTimeRen = "";
setInterval(async () => {
    if(!document.getElementById('lock').classList.contains('hidden')) return;
    const res = await request('status');
    if(!res.config) return;
    const renderLog = (elId, logs, lastTimeVar) => {
        const el = document.getElementById(elId);
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
    lastLogTimeRen = renderLog('log-ren', res.renamerState.logs, lastLogTimeRen);
    document.getElementById('stat-scr').innerText = res.state.totalScraped;
}, 2000);

async function showQr() {
    const m = document.getElementById('modal'); m.style.display = 'flex';
    const res = await request('115/qr'); if(!res.success) return;
    const { uid, time, sign, qr_url } = res.data;
    document.getElementById('qr-img').innerHTML = `<img src="${qr_url}" width="200">`;
    if(qrTimer) clearInterval(qrTimer);
    qrTimer = setInterval(async () => {
        const chk = await request(`115/check?uid=${uid}&time=${time}&sign=${sign}`);
        const txt = document.getElementById('qr-txt');
        if(chk.success) { txt.innerText = "✅ 成功! 刷新..."; txt.style.color = "#0f0"; clearInterval(qrTimer); setTimeout(() => { m.style.display='none'; location.reload(); }, 1000); }
        else if (chk.status === 1) { txt.innerText = "📱 已扫码"; txt.style.color = "#fb5"; }
    }, 1500);
}
EOF

# 5. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] 外挂版部署完成！请进入设置页面填写 Flaresolverr 地址。"
