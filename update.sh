#!/bin/bash
# VERSION = 13.7.3

echo "🚀 开始升级 Madou-Omni 到 v13.7.3 (UA/Cookie 双重伪装)..."

# 1. 更新前端界面 (index.html) - 增加 User-Agent 输入框
echo "📝 更新 /app/public/index.html..."
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
                        <option value="xchina">XChina (小黄书) - 需配置Cookie & UA</option>
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
                    <div><div style="font-size:13px;color:var(--text-sub)">当前版本</div><div id="cur-ver" style="font-size:24px;font-weight:bold;color:var(--text-main)">V13.6.0</div></div>
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
                    <h4 style="margin-top:0;margin-bottom:10px;color:var(--warning)">🛡️ 反爬虫穿透配置 (必填)</h4>
                    <div class="input-group">
                        <label>采集 Cookie (从浏览器 F12 网络请求中复制)</label>
                        <textarea id="cfg-scraper-cookie" rows="3" placeholder="cf_clearance=...; other=..."></textarea>
                    </div>
                    <div class="input-group">
                        <label>User-Agent (浏览器标识，必须与 Cookie 来源一致)</label>
                        <textarea id="cfg-ua" rows="2" placeholder="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)..."></textarea>
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

# 2. 更新前端逻辑 (app.js) - 读取和保存 UA
echo "📝 更新 /app/public/js/app.js..."
cat > /app/public/js/app.js << 'EOF'
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
                document.getElementById('cfg-scraper-cookie').value = r.config.scraperCookie || '';
                // 读取 UA
                document.getElementById('cfg-ua').value = r.config.userAgent || '';
            }
            if(r.version) {
                document.getElementById('cur-ver').innerText = "V" + r.version;
            }
        }, 100);
    }
}

function getDlState() { return document.getElementById('auto-dl').checked; }
async function api(act, body={}) { await request(act, { method: 'POST', body: JSON.stringify(body) }); }

async function startScrape(type) {
    const source = document.getElementById('src-site').value;
    const autoDl = getDlState();
    await api('start', { type, source, autoDownload: autoDl });
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
    await request('config', { 
        method: 'POST', 
        body: JSON.stringify({ 
            proxy: document.getElementById('cfg-proxy').value, 
            cookie115: document.getElementById('cfg-cookie').value,
            scraperCookie: document.getElementById('cfg-scraper-cookie').value,
            userAgent: document.getElementById('cfg-ua').value 
        }) 
    });
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

# 3. 更新爬虫模块 (scraper.js) - 优先使用配置的 UA
echo "📝 更新 /app/modules/scraper.js..."
cat > /app/modules/scraper.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const { HttpsProxyAgent } = require('https-proxy-agent');
const ResourceMgr = require('./resource_mgr');

let STATE = { isRunning: false, stopSignal: false, logs: [], totalScraped: 0 };

function log(msg, type='info') {
    STATE.logs.push({ time: new Date().toLocaleTimeString(), msg, type });
    if (STATE.logs.length > 200) STATE.logs.shift();
    console.log(`[Scraper] ${msg}`);
}

function getRequest(referer) {
    // 默认 User-Agent (作为后备)
    const defaultUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    
    // 优先使用用户配置的 UA，其次使用 Config 对象中的，最后使用默认
    const userAgent = (global.CONFIG.userAgent && global.CONFIG.userAgent.trim() !== '') 
        ? global.CONFIG.userAgent.trim() 
        : defaultUA;

    const options = {
        headers: { 
            'User-Agent': userAgent,
            'Referer': referer 
        },
        timeout: 20000
    };
    
    // 如果配置了采集 Cookie，则添加到请求头中
    if (global.CONFIG.scraperCookie && global.CONFIG.scraperCookie.trim() !== '') {
        options.headers['Cookie'] = global.CONFIG.scraperCookie.trim();
    }

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

async function scrapeMadouQu(request, limitPages, autoDownload) {
    let page = 1;
    let url = "https://madouqu.com/";
    log(`==== 正在启动 MadouQu 采集 (Max: ${limitPages}页) ====`, 'info');
    while (page <= limitPages && !STATE.stopSignal) {
        log(`[Madou] 正在抓取第 ${page} 页: ${url}`, 'info');
        try {
            const res = await request.get(url);
            const $ = cheerio.load(res.data);
            const posts = $('article h2.entry-title a, h2.entry-title a');
            if (posts.length === 0) { log(`[Madou] ⚠️ 第 ${page} 页未找到文章`, 'warn'); break; }
            log(`[Madou] 本页发现 ${posts.length} 个资源...`);
            for (let i = 0; i < posts.length; i++) {
                if (STATE.stopSignal) break;
                const el = posts[i];
                const link = $(el).attr('href');
                const title = $(el).text().trim();
                try {
                    const detail = await request.get(link);
                    const match = detail.data.match(/magnet:\?xt=urn:btih:[a-zA-Z0-9]{32,40}/gi);
                    if (match) {
                        const magnets = Array.from(new Set(match)).join(' | ');
                        const saved = await ResourceMgr.save(title, link, magnets);
                        if(saved) {
                            STATE.totalScraped++;
                            let extraMsg = "";
                            if (autoDownload && match[0]) {
                                const pushRes = await pushTo115(match[0]);
                                if (pushRes) { extraMsg = " | 📥 已推115"; await ResourceMgr.markAsPushedByLink(link); }
                                else { extraMsg = " | ⚠️ 推送失败"; }
                            }
                            log(`✅ [入库${extraMsg}] ${title.substring(0, 15)}...`, 'success');
                        }
                    } else { log(`❌ [无磁力] ${title.substring(0, 15)}...`, 'warn'); }
                } catch (e) { log(`❌ [Madou失败] ${title.substring(0, 10)}... : ${e.message}`, 'error'); }
                await new Promise(r => setTimeout(r, Math.floor(Math.random() * 1000) + 1000));
            }
            const next = $('a.next').attr('href');
            if (next) { url = next; page++; await new Promise(r => setTimeout(r, 2000)); } 
            else { log("[Madou] 🚫 没有下一页了", 'success'); break; }
        } catch (pageErr) { log(`❌ [Madou] 获取第 ${page} 页失败: ${pageErr.message}`, 'error'); await new Promise(r => setTimeout(r, 5000)); }
    }
}

async function scrapeXChina(request, limitPages, autoDownload) {
    let page = 1;
    let url = "https://xchina.co/videos.html";
    const domain = "https://xchina.co";
    log(`==== 正在启动 XChina 采集 (Max: ${limitPages}页) ====`, 'info');
    while (page <= limitPages && !STATE.stopSignal) {
        log(`[XChina] 正在抓取第 ${page} 页: ${url}`, 'info');
        try {
            const res = await request.get(url);
            const $ = cheerio.load(res.data);
            const posts = $('.list.video-index .item.video');
            if (posts.length === 0) { log(`[XChina] ⚠️ 第 ${page} 页未找到视频`, 'warn'); break; }
            log(`[XChina] 本页发现 ${posts.length} 个资源...`);
            for (let i = 0; i < posts.length; i++) {
                if (STATE.stopSignal) break;
                const el = posts[i];
                const titleTag = $(el).find('.text .title a');
                let title = titleTag.text().trim();
                let detailLink = titleTag.attr('href');
                if (!title || !detailLink) continue;
                if (detailLink.startsWith('/')) detailLink = domain + detailLink;
                try {
                    const detailRes = await request.get(detailLink);
                    const $d = cheerio.load(detailRes.data);
                    let downloadPageLink = $d('a[href*="/download/id-"]').attr('href');
                    if (downloadPageLink) {
                        if (downloadPageLink.startsWith('/')) downloadPageLink = domain + downloadPageLink;
                        const downloadRes = await request.get(downloadPageLink);
                        const $dl = cheerio.load(downloadRes.data);
                        const magnet = $dl('a.btn.magnet[href^="magnet:"]').attr('href');
                        if (magnet) {
                            const saved = await ResourceMgr.save(title, detailLink, magnet);
                            if(saved) {
                                STATE.totalScraped++;
                                let extraMsg = "";
                                if (autoDownload) {
                                    const pushRes = await pushTo115(magnet);
                                    if (pushRes) { extraMsg = " | 📥 已推115"; await ResourceMgr.markAsPushedByLink(detailLink); }
                                    else { extraMsg = " | ⚠️ 推送失败"; }
                                }
                                log(`✅ [入库${extraMsg}] ${title.substring(0, 15)}...`, 'success');
                            }
                        } else { log(`❌ [XChina无磁力] ${title.substring(0, 15)}...`, 'warn'); }
                    } else { log(`❌ [XChina无下载页] ${title.substring(0, 15)}...`, 'warn'); }
                } catch (e) { log(`❌ [XChina失败] ${title.substring(0, 10)}... : ${e.message}`, 'error'); }
                await new Promise(r => setTimeout(r, Math.floor(Math.random() * 1500) + 1000));
            }
            const nextHref = $('.pagination a:contains("下一页"), .pagination a:contains("Next"), a.next').attr('href');
            if (nextHref) {
                url = nextHref.startsWith('/') ? domain + nextHref : nextHref;
                page++;
                await new Promise(r => setTimeout(r, 2000));
            } else { log("[XChina] 🚫 当前页未发现下一页链接，停止采集", 'success'); break; }
        } catch (pageErr) { log(`❌ [XChina] 获取第 ${page} 页失败: ${pageErr.message}`, 'error'); await new Promise(r => setTimeout(r, 5000)); break; }
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

        if (source === 'madou') {
            const req = getRequest('https://madouqu.com/');
            await scrapeMadouQu(req, limitPages, autoDownload);
        } else if (source === 'xchina') {
            const req = getRequest('https://xchina.co/');
            await scrapeXChina(req, limitPages, autoDownload);
        } else {
            log(`❌ 未知的采集源: ${source}`, 'error');
        }

        STATE.isRunning = false;
        log(`🏁 任务结束，本次共入库 ${STATE.totalScraped} 条`, 'warn');
    }
};
module.exports = Scraper;
EOF

# 4. 更新版本号 (package.json)
echo "📝 更新 /app/package.json..."
sed -i 's/"version": ".*"/"version": "13.7.3"/' /app/package.json

echo "✅ 升级完成，系统将自动重启..."
