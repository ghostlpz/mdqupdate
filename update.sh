#!/bin/sh
# VERSION=13.4.0

echo "🚀 [容器内] 开始执行 OTA 在线升级 (Target: V13.4.0 Filter Update)..."

# 1. 进入工作目录
cd /app

echo "📂 正在更新核心代码..."

# 2. 更新 Package.json
cat > package.json << 'EOF'
{
  "name": "madou-omni-system",
  "version": "13.4.0",
  "main": "app.js",
  "dependencies": {
    "axios": "^1.6.0",
    "cheerio": "^1.0.0-rc.12",
    "cookie-parser": "^1.4.6",
    "cors": "^2.8.5",
    "express": "^4.18.2",
    "https-proxy-agent": "^7.0.2",
    "mysql2": "^3.6.5",
    "node-schedule": "^2.1.1",
    "json2csv": "^6.0.0-alpha.2"
  }
}
EOF

# 3. 更新 ResourceMgr (核心：支持 SQL 动态筛选)
cat > modules/resource_mgr.js << 'EOF'
const { pool } = require('./db');

function hexToBase32(hex) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
    let binary = '';
    for (let i = 0; i < hex.length; i++) {
        binary += parseInt(hex[i], 16).toString(2).padStart(4, '0');
    }
    let base32 = '';
    for (let i = 0; i < binary.length; i += 5) {
        const chunk = binary.substr(i, 5);
        const index = parseInt(chunk.padEnd(5, '0'), 2);
        base32 += alphabet[index];
    }
    return base32;
}

const ResourceMgr = {
    async save(title, link, magnets) {
        try {
            await pool.execute(
                'INSERT IGNORE INTO resources (title, link, magnets) VALUES (?, ?, ?)',
                [title, link, magnets]
            );
            return true;
        } catch (err) { return false; }
    },
    
    async queryByHash(hash) {
        if (!hash) return null;
        try {
            const inputHash = hash.trim().toLowerCase();
            const conditions = [
                `magnet:?xt=urn:btih:${inputHash}`,
                `magnet:?xt=urn:btih:${inputHash.toUpperCase()}`
            ];
            try {
                const b32 = hexToBase32(inputHash);
                conditions.push(`magnet:?xt=urn:btih:${b32}`);
                conditions.push(`magnet:?xt=urn:btih:${b32.toUpperCase()}`);
            } catch (e) {}
            const [rows] = await pool.query(
                'SELECT title, is_renamed FROM resources WHERE magnets IN (?) LIMIT 1',
                [conditions]
            );
            return rows.length > 0 ? rows[0] : null;
        } catch (err) { return null; }
    },

    async markAsPushed(id) { try { await pool.query('UPDATE resources SET is_pushed = 1 WHERE id = ?', [id]); } catch (e) {} },
    async markAsPushedByLink(link) { try { await pool.query('UPDATE resources SET is_pushed = 1 WHERE link = ?', [link]); } catch (e) {} },
    async markAsRenamedByTitle(title) { try { await pool.query('UPDATE resources SET is_renamed = 1 WHERE title = ?', [title]); } catch (e) {} },

    // 🔥 修改：增加 filters 参数
    async getList(page, limit, filters = {}) {
        try {
            const offset = (page - 1) * limit;
            
            // 构建动态 SQL
            let whereClause = "";
            const conditions = [];
            
            if (filters.pushed === '1') conditions.push("is_pushed = 1");
            if (filters.pushed === '0') conditions.push("is_pushed = 0");
            
            if (filters.renamed === '1') conditions.push("is_renamed = 1");
            if (filters.renamed === '0') conditions.push("is_renamed = 0");
            
            if (conditions.length > 0) {
                whereClause = " WHERE " + conditions.join(" AND ");
            }

            const countSql = `SELECT COUNT(*) as total FROM resources${whereClause}`;
            const [countRows] = await pool.query(countSql);
            const total = countRows[0].total;

            const dataSql = `SELECT * FROM resources${whereClause} ORDER BY created_at DESC LIMIT ${limit} OFFSET ${offset}`;
            const [rows] = await pool.query(dataSql);
            
            return { total, data: rows };
        } catch (err) {
            console.error(err);
            return { total: 0, data: [], error: err.message };
        }
    },

    async getAllForExport() {
        try {
            const [rows] = await pool.query(`SELECT id, title, magnets, created_at, is_pushed, is_renamed FROM resources ORDER BY created_at DESC`);
            return rows;
        } catch (err) { return []; }
    }
};

module.exports = ResourceMgr;
EOF

# 4. 更新 API (接收筛选参数)
cat > routes/api.js << 'EOF'
const express = require('express');
const axios = require('axios');
const router = express.Router();
const fs = require('fs');
const { exec } = require('child_process');
const { HttpsProxyAgent } = require('https-proxy-agent');
const { Parser } = require('json2csv');
const Scraper = require('../modules/scraper');
const Renamer = require('../modules/renamer');
const Login115 = require('../modules/login_115');
const ResourceMgr = require('../modules/resource_mgr');
const AUTH_PASSWORD = process.env.AUTH_PASSWORD || "admin888";

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
    res.json({ config: global.CONFIG, state: Scraper.getState(), renamerState: Renamer.getState(), version: global.CURRENT_VERSION });
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
    Scraper.start(req.body.type === 'full' ? 50000 : 100, "手动", autoDl);
    res.json({ success: true });
});
router.post('/stop', (req, res) => {
    Scraper.stop();
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
            const postData = `url=${encodeURIComponent(magnet)}`;
            const result = await axios.post('https://115.com/web/lixian/?ct=lixian&ac=add_task_url', postData, {
                headers: {
                    'Cookie': global.CONFIG.cookie115,
                    'User-Agent': global.CONFIG.userAgent,
                    'Content-Type': 'application/x-www-form-urlencoded'
                }
            });
            if (result.data && result.data.state) {
                successCount++;
                await ResourceMgr.markAsPushed(id);
            }
            await new Promise(r => setTimeout(r, 500));
        }
        res.json({ success: true, count: successCount });
    } catch (e) { res.json({ success: false, msg: e.message }); }
});

// 🔥 修改：传递筛选参数
router.get('/data', async (req, res) => {
    const filters = {
        pushed: req.query.pushed || '',
        renamed: req.query.renamed || ''
    };
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
        const parser = new Parser({ fields: ['id', 'title', 'magnets', 'created_at'] });
        const csv = parser.parse(data);
        res.header('Content-Type', 'text/csv');
        res.attachment(`madou_${Date.now()}.csv`);
        return res.send(csv);
    } catch (err) { res.status(500).send("Err: " + err.message); }
});

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

# 5. 更新 UI (增加筛选栏)
cat > public/index.html << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN" data-bs-theme="dark">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Madou Omni V13.4</title>
    <style>
        :root{--bg:#1e1e2f;--card:#27293d;--txt:#e1e1e6;--acc:#e14eca}
        body{background:var(--bg);color:var(--txt);font-family:sans-serif;margin:0;display:flex}
        
        .sidebar{width:240px;background:#000;height:100vh;display:flex;flex-direction:column;border-right:1px solid #333;flex-shrink:0}
        .sidebar h2{padding:20px;text-align:center;color:var(--acc);margin:0;border-bottom:1px solid #333}
        .nav-item{padding:15px 20px;cursor:pointer;color:#aaa;text-decoration:none;display:block;transition:0.3s}
        .nav-item:hover,.nav-item.active{color:var(--acc);background:#ffffff0d;font-weight:bold;border-left:4px solid var(--acc)}
        
        .main{flex:1;padding:20px;overflow-y:auto;height:100vh;width:100%}
        .card{background:var(--card);border-radius:8px;padding:20px;margin-bottom:20px}
        
        .log-box{height:350px;background:#111;color:#0f0;font-family:monospace;font-size:12px;overflow-y:scroll;padding:10px;border-radius:4px;white-space: pre-wrap;word-break: break-all;}
        .log-box .err{color:#f55} .log-box .warn{color:#fb5} .log-box .suc{color:#5f7}
        
        .btn{padding:10px 20px;border:none;border-radius:4px;cursor:pointer;color:#fff;font-weight:bold;margin-right:10px}
        .btn-pri{background:var(--acc)} .btn-dang{background:#d33} .btn-succ{background:#28a745} .btn-warn{background:#ffc107;color:#000}
        .btn-info{background:#17a2b8;color:#fff}
        
        input,textarea,select{background:#111;border:1px solid #444;color:#fff;padding:8px;border-radius:4px;width:100%;box-sizing:border-box;margin-bottom:10px}
        
        /* 筛选栏样式 */
        .filter-bar { display: flex; gap: 10px; margin-bottom: 10px; align-items: center; background: #333; padding: 10px; border-radius: 4px; }
        .filter-bar label { white-space: nowrap; font-size: 13px; color: #aaa; }
        .filter-bar select { margin-bottom: 0; width: auto; flex: 1; min-width: 100px; }

        table{width:100%;border-collapse:collapse;table-layout:fixed;} 
        th,td{text-align:left;padding:10px;border-bottom:1px solid #444;overflow:hidden;text-overflow:ellipsis;vertical-align:middle;}
        
        .tag { padding: 2px 6px; border-radius: 4px; font-size: 10px; font-weight: bold; margin-right: 5px; }
        .tag-push { background: #28a745; color: #fff; }
        .tag-ren { background: #17a2b8; color: #fff; }
        
        #lock{position:fixed;top:0;left:0;width:100%;height:100%;background:#000;z-index:999;display:flex;justify-content:center;align-items:center}
        #lock .box{background:var(--card);padding:40px;border-radius:10px;width:300px;text-align:center;border:1px solid #444}
        .hidden{display:none!important}
        .check-group { display: flex; align-items: center; margin-bottom: 15px; }
        .check-group input { width: 20px; height: 20px; margin: 0 10px 0 0; }
        .tbl-chk { width: 18px; height: 18px; cursor: pointer; }

        @media (max-width: 768px) {
            body { flex-direction: column; }
            .sidebar { width: 100%; height: auto; flex-direction: row; flex-wrap: wrap; border-right: none; border-bottom: 2px solid #333; padding-bottom: 5px; justify-content: space-around; }
            .sidebar h2 { width: 100%; border-bottom: none; padding: 10px; font-size: 18px; }
            .nav-item { border-left: none !important; border-bottom: 3px solid transparent; padding: 10px 5px; font-size: 13px; flex: 1; text-align: center; white-space: nowrap; }
            .nav-item.active { border-bottom: 3px solid var(--acc); background: none; color: var(--acc); }
            .main { padding: 10px; height: auto; overflow: visible; }
            .card { padding: 15px; }
            .btn { display: block; width: 100%; margin-bottom: 10px; margin-right: 0; padding: 12px 0; }
            .card:has(table) { overflow-x: auto; -webkit-overflow-scrolling: touch; }
            table { min-width: 600px; }
            #g-status { width: 100%; padding: 10px; font-size: 12px; background: #111; }
            .filter-bar { flex-direction: column; align-items: stretch; }
        }
    </style>
</head>
<body>
    <div id="lock">
        <div class="box">
            <h2 style="color:#e14eca">🔒 系统锁定</h2>
            <input type="password" id="pass" placeholder="请输入密码" style="text-align:center;font-size:18px;margin:20px 0">
            <button class="btn btn-pri" style="width:100%" onclick="login()">解锁</button>
            <div id="msg" style="color:#f55;margin-top:10px"></div>
        </div>
    </div>

    <div class="sidebar">
        <h2>🤖 Madou</h2>
        <a class="nav-item active" onclick="show('scraper')">采集</a>
        <a class="nav-item" onclick="show('renamer')">整理</a>
        <a class="nav-item" onclick="show('database')">库</a>
        <a class="nav-item" onclick="show('settings')">设置</a>
        <div style="margin-top:auto;padding:20px;text-align:center;color:#666" id="g-status">待机</div>
    </div>

    <div class="main">
        <div id="scraper" class="page">
            <h1>资源采集</h1>
            <div class="card">
                <div class="check-group">
                    <input type="checkbox" id="auto-dl">
                    <label for="auto-dl">📥 采集成功后自动推送到 115 离线下载</label>
                </div>
                <button class="btn btn-succ" onclick="api('start',{type:'inc', autoDownload: getDlState()})">▶ 增量采集</button>
                <button class="btn btn-warn" onclick="api('start',{type:'full', autoDownload: getDlState()})">♻️ 全量采集</button>
                <button class="btn btn-dang" onclick="api('stop')">⏹ 停止</button>
                <span style="float:right;font-size:20px">本次采集: <b id="stat-scr" style="color:#e14eca">0</b></span>
            </div>
            <div class="card">
                <h3>实时日志</h3>
                <div id="log-scr" class="log-box"></div>
            </div>
        </div>

        <div id="renamer" class="page hidden">
            <h1>115 整理</h1>
            <div class="card">
                <label>扫描页数 (0=全部)</label>
                <input type="number" id="r-pages" value="0">
                <div class="check-group" style="margin-top:10px">
                    <input type="checkbox" id="r-force">
                    <label for="r-force">⚠️ 强制重新整理 (勾选后会处理“已整理”的项目，速度较慢)</label>
                </div>
                <button class="btn btn-pri" onclick="startRenamer()">▶ 开始整理</button>
                <button class="btn btn-dang" onclick="api('stop')">⏹ 停止</button>
                <div style="margin-top:10px">
                    成功: <b style="color:#5f7" id="stat-suc">0</b> | 
                    失败: <b style="color:#f55" id="stat-fail">0</b> | 
                    跳过: <b style="color:#aaa" id="stat-skip">0</b>
                </div>
            </div>
            <div class="card">
                <h3>操作日志</h3>
                <div id="log-ren" class="log-box"></div>
            </div>
        </div>

        <div id="database" class="page hidden">
            <h1>已入库资源</h1>
            <div class="card">
                <div class="filter-bar">
                    <label>📥 推送状态:</label>
                    <select id="filter-push" onchange="loadDb(1)">
                        <option value="">全部</option>
                        <option value="1">已推送 (115)</option>
                        <option value="0">未推送</option>
                    </select>
                    
                    <label>✏️ 整理状态:</label>
                    <select id="filter-ren" onchange="loadDb(1)">
                        <option value="">全部</option>
                        <option value="1">已整理 (改名)</option>
                        <option value="0">未整理</option>
                    </select>
                </div>

                <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:10px">
                    <div>
                        <button class="btn btn-pri" style="width:auto" onclick="loadDb(dbPage-1)">◀</button>
                        <span id="page-info" style="margin:0 10px">第 1 页</span>
                        <button class="btn btn-pri" style="width:auto" onclick="loadDb(dbPage+1)">▶</button>
                    </div>
                    <h3 style="margin:0; color:#e14eca; font-size:16px" id="total-count">📚 0</h3>
                </div>
                <div style="float:right; margin-bottom:10px; width:100%">
                    <button class="btn btn-info" onclick="pushSelected()">📤 推送选中</button>
                    <button class="btn btn-warn" onclick="window.open(url('/export?type=all'))">导出全部</button>
                </div>
            </div>
            <div class="card">
                <table id="db-tbl">
                    <thead>
                        <tr>
                            <th style="width:30px"><input type="checkbox" class="tbl-chk" onclick="toggleAll(this)"></th>
                            <th style="width:40px">ID</th>
                            <th style="width:40%">标题</th>
                            <th style="width:35%">磁力链</th>
                            <th style="width:120px">入库时间</th>
                        </tr>
                    </thead>
                    <tbody></tbody>
                </table>
            </div>
        </div>

        <div id="settings" class="page hidden">
            <h1>设置</h1>
            <div class="card" style="text-align:center">
                <button class="btn btn-pri" onclick="showQr()">📱 115 扫码登录</button>
                <p style="color:#888;margin-top:10px">扫码后 Cookie 自动填充</p>
            </div>
            
            <div class="card" style="border-left: 4px solid #e14eca">
                <div style="display:flex; justify-content:space-between; align-items:center">
                    <h3>🔄 系统升级</h3>
                    <span id="cur-ver" style="color:#e14eca; font-weight:bold">V13.4.0</span>
                </div>
                <p style="color:#aaa; font-size:12px; margin-bottom:10px">
                    升级源: GitHub (ghostlpz/mdqupdate) <br>
                    系统会自动检测新版本。如果存在更新，将自动下载并重启。
                </p>
                <button class="btn btn-warn" onclick="runOnlineUpdate()">☁️ 检查并升级</button>
            </div>

            <div class="card">
                <label>HTTP 代理</label>
                <input id="cfg-proxy" placeholder="http://...">
                <label>Cookie</label>
                <textarea id="cfg-cookie" rows="5"></textarea>
                <button class="btn btn-pri" onclick="saveCfg()">保存配置</button>
            </div>
        </div>
    </div>

    <div id="modal" style="display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:#000000cc;z-index:900;justify-content:center;align-items:center">
        <div style="background:#fff;padding:20px;border-radius:8px;text-align:center">
            <h3 style="color:#000">115 扫码</h3>
            <div id="qr-img"></div>
            <div id="qr-txt" style="color:#000;margin-top:10px">...</div>
            <button class="btn btn-dang" onclick="document.getElementById('modal').style.display='none'" style="margin-top:10px">关闭</button>
        </div>
    </div>

    <script src="js/app.js"></script>
    <script>
        // 🔥 修改 loadDb 函数，支持筛选
        async function loadDb(p) {
            if(p < 1) return;
            dbPage = p;
            document.getElementById('page-info').innerText = "第 " + p + " 页";
            
            // 获取筛选值
            const pushVal = document.getElementById('filter-push').value;
            const renVal = document.getElementById('filter-ren').value;
            
            // 拼接到 URL
            const res = await request(`data?page=${p}&pushed=${pushVal}&renamed=${renVal}`);
            
            const tbody = document.querySelector('#db-tbl tbody');
            tbody.innerHTML = '';
            const headerCheck = document.querySelector('thead .tbl-chk');
            if(headerCheck) headerCheck.checked = false;
            
            if(res.data) {
                document.getElementById('total-count').innerText = "📚 总资源: " + (res.total || 0);
                res.data.forEach(r => {
                    const time = new Date(r.created_at).toLocaleString();
                    let tags = "";
                    if (r.is_pushed) tags += `<span class="tag tag-push">已推</span>`;
                    if (r.is_renamed) tags += `<span class="tag tag-ren">已整</span>`;
                    const chkValue = `${r.id}|${r.magnets}`;
                    tbody.innerHTML += `<tr><td><input type="checkbox" class="tbl-chk row-chk" value="${chkValue}"></td><td>${r.id}</td><td>${tags} ${r.title}</td><td style="word-break:break-all;font-size:12px;color:#aaa">${r.magnets || ''}</td><td style="font-size:12px;color:#888">${time}</td></tr>`;
                });
            }
        }
    </script>
</body>
</html>
EOF

echo "📦 正在安装依赖..."
npm install --registry=https://registry.npmmirror.com

echo "🔄 正在重启应用..."
# 对于 Docker 容器，让主进程退出即可触发 Restart
# Node.js 将在几秒后重启
kill 1

echo "✅ 升级完成！请稍后刷新浏览器查看 V13.4.0"
