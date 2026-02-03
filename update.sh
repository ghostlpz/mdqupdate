#!/bin/bash
# VERSION = 13.15.0

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.15.0
# 优化: 1. 界面体验 (配置整合/说明文案/移除扫码)
#       2. 新增 "推送+刮削" 联动按钮
#       3. 修复停止按钮无日志反馈的问题
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署体验优化版 (V13.15.0)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.15.0"/' package.json

# 2. 优化 Scraper (增加停止日志)
echo "📝 [1/3] 优化采集器交互..."
# 我们微调 scraper_xchina.js 的 stop 方法
sed -i "s/stop: () => { STATE.stopSignal = true; }/stop: () => { STATE.stopSignal = true; log('🛑 用户已点击停止，正在结束当前任务...', 'warn'); }/" modules/scraper_xchina.js

# 3. 重构 API (支持 推送+刮削 联动)
echo "📝 [2/3] 升级后端接口 (支持混合推送)..."
cat > routes/api.js << 'EOF'
const express = require('express');
const axios = require('axios');
const router = express.Router();
const fs = require('fs');
const { exec } = require('child_process');
const { HttpsProxyAgent } = require('https-proxy-agent');
const { Parser } = require('json2csv');
const Scraper = require('../modules/scraper');
const ScraperXChina = require('../modules/scraper_xchina');
const Renamer = require('../modules/renamer');
const Organizer = require('../modules/organizer');
const Login115 = require('../modules/login_115');
const LoginPikPak = require('../modules/login_pikpak');
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
    if(LoginPikPak.setConfig) LoginPikPak.setConfig(global.CONFIG);
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
router.get('/categories', (req, res) => {
    res.json({ categories: ScraperXChina.getCategories() });
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

router.get('/pikpak/check', async (req, res) => {
    try {
        LoginPikPak.setConfig(global.CONFIG);
        const result = await LoginPikPak.testConnection();
        res.json(result);
    } catch (e) { res.json({ success: false, msg: e.message }); }
});

router.post('/start', (req, res) => {
    const autoDl = req.body.autoDownload === true;
    const type = req.body.type; 
    const source = req.body.source || 'madou';
    const categories = req.body.categories || []; 

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

// 🔥 重构: 智能推送接口 (支持 115/PikPak 混合 + 自动刮削)
router.post('/push', async (req, res) => {
    const ids = req.body.ids || [];
    const autoOrganize = req.body.organize === true;

    if (ids.length === 0) return res.json({ success: false, msg: "未选择任务" });
    
    let successCount = 0;
    try {
        const items = await ResourceMgr.getByIds(ids);
        
        for (const item of items) {
            let pushed = false;
            let magnet = item.magnets || '';
            
            // 识别驱动
            if (magnet.startsWith('pikpak|')) {
                const realLink = magnet.replace('pikpak|', '');
                // PikPak 推送
                const task = await LoginPikPak.addTask(realLink);
                pushed = !!task;
            } else {
                // 115 推送
                if (!global.CONFIG.cookie115) { continue; }
                pushed = await Login115.addTask(magnet);
            }

            if (pushed) {
                successCount++;
                await ResourceMgr.markAsPushed(item.id);
                // 联动刮削
                if (autoOrganize) {
                    Organizer.addTask(item);
                }
            }
            await new Promise(r => setTimeout(r, 200));
        }
        res.json({ 
            success: true, 
            count: successCount, 
            msg: autoOrganize ? "已推送并加入刮削队列" : "推送完成" 
        });
    } catch (e) { res.json({ success: false, msg: e.message }); }
});

router.post('/organize', async (req, res) => {
    const ids = req.body.ids || [];
    if (ids.length === 0) return res.json({ success: false, msg: "未选择任务" });

    try {
        const items = await ResourceMgr.getByIds(ids);
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

# 4. 重写前端 (UI 优化 + 配置搬家)
echo "📝 [3/3] 升级前端界面 (UI 优化)..."
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
        .btn-grad { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); box-shadow: 0 4px 6px rgba(0,0,0,0.2); }
        .input-group { margin-bottom: 15px; } label { display: block; margin-bottom: 5px; font-size: 13px; color: var(--text-sub); }
        .desc { font-size: 12px; color: #64748b; margin-top: 4px; }
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
                <div style="color:var(--text-sub);padding:20px 0;">目前此页面仅用于查看日志，配置项已移至“系统设置”</div>
            </div>
        </div>
        
        <div id="database" class="page hidden" style="height:100%; display:flex; flex-direction:column;">
            <h2>资源数据库</h2>
            <div class="card" style="padding:0; flex:1; display:flex; flex-direction:column; min-height:0;">
                <div style="padding:15px; border-bottom:1px solid var(--border); display:flex; justify-content:space-between; align-items:center">
                    <div style="display:flex;gap:10px;">
                        <button class="btn btn-info" onclick="pushSelected(false)">📤 仅推送</button>
                        <button class="btn btn-warn" onclick="organizeSelected()">🛠️ 仅刮削</button>
                        <button class="btn btn-grad" onclick="pushSelected(true)">🚀 推送+刮削</button>
                        <button class="btn btn-dang" onclick="deleteSelected()">🗑️ 删除</button>
                    </div>
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
                <div class="input-group">
                    <label>HTTP 代理</label>
                    <input id="cfg-proxy">
                    <div class="desc">NAS 连接外部网络（如 PikPak/墙外刮削）所需代理，格式: http://ip:port</div>
                </div>
                <div class="input-group">
                    <label>Flaresolverr 地址</label>
                    <input id="cfg-flare">
                    <div class="desc">用于绕过 Cloudflare 验证的服务地址，默认 http://flaresolverr:8191</div>
                </div>
                <div class="input-group">
                    <label>115 Cookie</label>
                    <textarea id="cfg-cookie" rows="3"></textarea>
                    <div class="desc">115 网盘网页版 Cookie (UID/CID/SEID)，用于离线下载和管理</div>
                </div>
                <hr style="border:0;border-top:1px solid var(--border);margin:20px 0">
                <div class="input-group">
                    <label>PikPak 账号 (用户名|密码)</label>
                    <div style="display:flex;gap:10px">
                        <input id="cfg-pikpak" placeholder="username|password" style="flex:1">
                        <button class="btn btn-info" onclick="checkPikPak()">🧪 测试连接</button>
                    </div>
                    <div class="desc">PikPak 账号密码 (username|password)，用于 M3U8 视频离线</div>
                </div>
                <div class="input-group">
                    <label>目标目录 CID</label>
                    <input id="cfg-target-cid" placeholder="例如: 28419384919384">
                    <div class="desc">刮削整理后的资源存放目录 ID (115/PikPak 通用，不填则默认根目录)</div>
                </div>
                
                <button class="btn btn-pri" onclick="saveCfg()">保存配置</button>
                <hr style="border:0;border-top:1px solid var(--border);margin:20px 0">
                <div style="display:flex;justify-content:space-between;align-items:center"><div>当前版本: <span id="cur-ver" style="color:var(--primary);font-weight:bold">Loading</span></div><button class="btn btn-succ" onclick="runOnlineUpdate()">检查更新</button></div>
            </div>
        </div>
    </div>
    
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
        
        async function checkPikPak() {
            const btn = event.target;
            const oldTxt = btn.innerText;
            btn.innerText = "⏳ 测试中...";
            btn.disabled = true;
            await saveCfg();
            try {
                const res = await request('pikpak/check');
                if(res.success) alert(res.msg);
                else alert("❌ " + res.msg);
            } catch(e) { alert("请求失败"); }
            btn.innerText = oldTxt;
            btn.disabled = false;
        }
        
        // Init
        toggleCat(document.getElementById('scr-source').value);
    </script>
</body>
</html>
EOF

# 5. 更新前端逻辑 (适配新 API)
echo "📝 [4/4] 升级前端逻辑..."
cat > public/js/app.js << 'EOF'
let dbPage = 1;

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
    // 刷新配置
    if(id === 'settings') {
        setTimeout(async () => {
            const r = await request('status');
            if(r.config) {
                if(document.getElementById('cfg-proxy')) document.getElementById('cfg-proxy').value = r.config.proxy || '';
                if(document.getElementById('cfg-cookie')) document.getElementById('cfg-cookie').value = r.config.cookie115 || '';
                if(document.getElementById('cfg-flare')) document.getElementById('cfg-flare').value = r.config.flaresolverrUrl || '';
                if(document.getElementById('cfg-target-cid')) document.getElementById('cfg-target-cid').value = r.config.targetCid || '';
                if(document.getElementById('cfg-pikpak')) document.getElementById('cfg-pikpak').value = r.config.pikpak || '';
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
    const proxy = document.getElementById('cfg-proxy').value;
    const cookie115 = document.getElementById('cfg-cookie').value;
    const flaresolverrUrl = document.getElementById('cfg-flare').value;
    const targetCid = document.getElementById('cfg-target-cid').value;
    const pikpak = document.getElementById('cfg-pikpak').value;
    
    const body = { proxy, cookie115, flaresolverrUrl, targetCid, pikpak };
    await request('config', { method: 'POST', body: JSON.stringify(body) });
    alert('✅ 配置已保存');
}

function toggleAll(source) { const checkboxes = document.querySelectorAll('.row-chk'); checkboxes.forEach(cb => cb.checked = source.checked); }

// 🔥 新增: 支持 organize 参数 (是否联动刮削)
async function pushSelected(organize = false) {
    const checkboxes = document.querySelectorAll('.row-chk:checked');
    if (checkboxes.length === 0) { alert("请先勾选!"); return; }
    // 提取 IDs
    const ids = Array.from(checkboxes).map(cb => cb.value.includes('|') ? cb.value.split('|')[0] : cb.value);
    
    const btn = event.target; const oldText = btn.innerText; btn.innerText = "处理中..."; btn.disabled = true;
    try { 
        // 调用新的智能接口
        const res = await request('push', { method: 'POST', body: JSON.stringify({ ids, organize }) }); 
        if (res.success) { alert(`✅ ${res.msg}`); loadDb(dbPage); } else { alert(`❌ 失败: ${res.msg}`); }
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
                let magnetLabel = '🔗';
                if(cleanMagnet.includes('.m3u8')) magnetLabel = '📺';
                if (cleanMagnet.includes('&')) cleanMagnet = cleanMagnet.split('&')[0];
                const magnetDisplay = cleanMagnet ? `<div class="magnet-link" onclick="navigator.clipboard.writeText('${cleanMagnet}');alert('链接已复制')">${magnetLabel} ${cleanMagnet.substring(0, 20)}...</div>` : '';
                tbody.innerHTML += `<tr><td><input type="checkbox" class="row-chk" value="${chkValue}"></td><td>${imgHtml}</td><td><div style="font-weight:500;margin-bottom:4px;max-width:300px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${r.title}</div><div style="font-size:12px;color:var(--text-sub);font-family:monospace">${r.code || '无番号'}</div>${magnetDisplay}</td><td>${metaTags}</td><td>${statusTags}</td></tr>`;
            });
        } else { totalCountEl.innerText = "加载失败"; }
    } catch(e) { totalCountEl.innerText = "网络错误"; }
}

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
EOF

# 6. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.15.0 体验优化版部署完成！"
