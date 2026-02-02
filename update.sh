#!/bin/bash
# VERSION = 13.13.0

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.13.0
# 优化: 资源库增加实时日志窗口，Organizer 增加详细日志反馈
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署可视化反馈版 (V13.13.0)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.13.0"/' package.json

# 2. 升级 organizer.js (增加日志存储功能)
echo "📝 [1/3] 升级整理核心 (日志持久化)..."
cat > modules/organizer.js << 'EOF'
const Login115 = require('./login_115');
const ResourceMgr = require('./resource_mgr');

let TASKS = []; 
let IS_RUNNING = false;
// 🔥 新增：日志存储数组
let LOGS = [];

function log(msg, type = 'info') {
    const time = new Date().toLocaleTimeString();
    // 控制台打印
    console.log(`[Organizer] ${msg}`);
    // 存入内存供前端读取
    LOGS.push({ time, msg, type });
    // 保留最近 200 条防止内存溢出
    if (LOGS.length > 200) LOGS.shift();
}

const Organizer = {
    // 暴露日志给 API
    getState: () => ({ queue: TASKS.length, isRunning: IS_RUNNING, logs: LOGS }),

    addTask: (resource) => {
        if (!TASKS.find(t => t.id === resource.id)) {
            TASKS.push(resource);
            log(`➕ 加入整理队列: ${resource.title}`, 'info');
            Organizer.run();
        }
    },

    run: async () => {
        if (IS_RUNNING || TASKS.length === 0) return;
        IS_RUNNING = true;

        while (TASKS.length > 0) {
            const item = TASKS[0]; 
            try {
                const success = await Organizer.processItem(item);
                if (success) {
                    TASKS.shift(); 
                } else {
                    TASKS.shift(); // 失败也移除，避免阻塞
                }
            } catch (e) {
                log(`❌ 异常: ${item.title} - ${e.message}`, 'error');
                TASKS.shift(); 
            }
            await new Promise(r => setTimeout(r, 2000));
        }
        IS_RUNNING = false;
        log(`🏁 整理队列处理完毕`, 'success');
    },

    processItem: async (item) => {
        const targetCid = global.CONFIG.targetCid;
        if (!targetCid) { log("未配置目标目录CID，请去设置页配置", 'error'); return true; }

        // 提取 Hash
        const magnetMatch = item.magnets.match(/[a-fA-F0-9]{40}/);
        if (!magnetMatch) { log(`❌ 无法提取Hash: ${item.title}`, 'error'); return true; }
        const hash = magnetMatch[0];

        log(`🔍 [${TASKS.length}待处理] 正在定位任务: ${item.title.substring(0, 15)}...`);

        // 1. 检查 115 任务状态
        let folderCid = null;
        let retryCount = 0;
        const maxRetries = 10; // 手动触发时，我们减少等待时间 (10次 * 5秒 = 50秒)

        while (retryCount < maxRetries) {
            const task = await Login115.getTaskByHash(hash);
            
            if (task) {
                if (task.state === 2) {
                    folderCid = task.file_id || task.cid;
                    if (folderCid) {
                        log(`✅ 任务已完成，锁定文件夹CID: ${folderCid}`);
                        break; 
                    }
                } else {
                    const percent = task.percent || 0;
                    log(`⏳ 下载中... ${percent}% (等待 5s)`);
                }
            } else {
                // 手动刮削时，经常出现任务早已完成但在任务列表被清除的情况
                // 所以如果查不到 Hash，立即尝试搜索文件夹名
                log(`⚠️ 任务列表未找到Hash，切换为文件名搜索模式...`);
                break; 
            }

            retryCount++;
            await new Promise(r => setTimeout(r, 5000)); 
        }

        // 2. 备用方案：搜名字
        if (!folderCid) {
            // 净化标题: 去除括号内容，取前8个字，去除特殊字符
            const cleanTitle = item.title.replace(/[【\[].*?[\]】]/g, '').replace(/[()（）]/g, ' ').substring(0, 8).trim();
            log(`🔍 尝试搜索文件夹名: "${cleanTitle}"`);
            const searchRes = await Login115.searchFile(cleanTitle, 0);
            if (searchRes.data && searchRes.data.length > 0) {
                // 优先找文件夹
                const folder = searchRes.data.find(f => f.fcid);
                if (folder) {
                    folderCid = folder.cid;
                    log(`✅ 通过搜索定位到: ${folder.n}`);
                }
            }
        }

        if (!folderCid) {
            log(`❌ 未能在115找到对应文件夹，请确认已下载成功`, 'error');
            return true; 
        }

        // 3. 执行整理
        try {
            // 清理
            const fileList = await Login115.getFileList(folderCid);
            if (fileList.data && fileList.data.length > 0) {
                const files = fileList.data.filter(f => !f.fcid);
                if (files.length > 0) {
                    files.sort((a, b) => b.s - a.s);
                    const keepFile = files[0];
                    // 只有当有多个文件时才清理
                    if (files.length > 1) {
                        const deleteIds = files.slice(1).map(f => f.fid).join(',');
                        if (deleteIds) {
                            await Login115.deleteFiles(deleteIds);
                            log(`🧹 清理了 ${files.length - 1} 个杂文件 (保留: ${keepFile.n})`);
                        }
                    }
                }
            }

            // 海报
            if (item.image_url) {
                await Login115.addTask(item.image_url, folderCid);
                log(`🖼️ 已添加海报下载任务`);
            }

            // 重命名
            let newFolderName = item.title;
            if (item.actor && item.actor !== '未知演员') {
                newFolderName = `${item.actor} - ${item.title}`;
            }
            newFolderName = newFolderName.replace(/[\\/:*?"<>|]/g, " ").trim();
            
            await Login115.rename(folderCid, newFolderName);
            log(`✏️ 重命名为: ${newFolderName}`);

            // 移动
            const moveRes = await Login115.move(folderCid, targetCid);
            if (moveRes) {
                log(`🚚 成功归档到目标目录!`, 'success');
                await ResourceMgr.markAsRenamedByTitle(item.title);
            } else {
                log(`❌ 移动失败 (可能目标目录不存在?)`, 'error');
            }

        } catch (err) {
            log(`⚠️ 整理异常: ${err.message}`, 'warn');
        }

        return true;
    }
};

module.exports = Organizer;
EOF

# 3. 升级 api.js (传递 Organizer 日志)
echo "📝 [2/3] 升级 API 接口..."
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
    let logs = Scraper.getState().logs;
    let scraped = Scraper.getState().totalScraped;
    if (ScraperXChina.getState().isRunning) {
        logs = ScraperXChina.getState().logs;
        scraped = ScraperXChina.getState().totalScraped;
    }
    // 🔥 关键修改：将 Organizer 的日志和队列状态传给前端
    const organizerState = Organizer.getState();
    
    res.json({ 
        config: global.CONFIG, 
        state: { isRunning: Scraper.getState().isRunning || ScraperXChina.getState().isRunning, logs, totalScraped: scraped }, 
        renamerState: Renamer.getState(),
        organizerLogs: organizerState.logs, // 传递日志
        organizerQueue: organizerState.queue, // 传递队列数
        version: global.CURRENT_VERSION 
    });
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
    const type = req.body.type;
    const source = req.body.source || 'madou';
    const targetUrl = req.body.targetUrl || '';

    if (Scraper.getState().isRunning || ScraperXChina.getState().isRunning) {
        return res.json({ success: false, msg: "已有任务正在运行" });
    }

    if (source === 'xchina') {
        const pages = type === 'full' ? 50 : 5;
        ScraperXChina.clearLogs();
        ScraperXChina.start(pages, autoDl, targetUrl);
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

# 4. 更新前端 index.html (添加日志窗口)
echo "📝 [3/3] 升级前端界面 (添加日志展示)..."
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
                <div class="input-group">
                    <label>采集目标链接 (可选，留空则默认采 麻豆传媒)</label>
                    <input id="scr-target-url" placeholder="粘贴分类链接，例如: https://xchina.co/videos/series-5fe8403919165.html">
                </div>
                <div class="input-group" style="display:flex;align-items:center;gap:10px;">
                    <input type="checkbox" id="auto-dl" style="width:auto"> <label style="margin:0;cursor:pointer" for="auto-dl">采集并推送到 115</label>
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

        <div id="organizer" class="page hidden">
            <div class="card">
                <h2>115 智能刮削</h2>
                <div style="background:rgba(59,130,246,0.1); border:1px solid rgba(59,130,246,0.2); padding:15px; border-radius:8px; margin-bottom:20px; font-size:13px; line-height:1.6">
                    <strong style="color:#60a5fa">功能说明：</strong><br>
                    推送时会自动：1.清理垃圾文件 2.下载海报 3.重命名为[演员-标题] 4.移动到目标目录
                </div>
                <div class="input-group">
                    <label>目标目录 CID (请填写 115 文件夹 ID)</label>
                    <input id="cfg-target-cid" placeholder="例如: 28419384919384">
                </div>
                <button class="btn btn-pri" onclick="saveCfg()">保存配置</button>
            </div>
        </div>

        <div id="database" class="page hidden" style="height:100%; display:flex; flex-direction:column;">
            <h2>资源数据库</h2>
            <div class="card" style="padding:0; flex:1; display:flex; flex-direction:column; min-height:0;">
                <div style="padding:15px; border-bottom:1px solid var(--border); display:flex; justify-content:space-between; align-items:center">
                    <div>
                        <button class="btn btn-info" onclick="pushSelected()">📤 仅推送</button>
                        <button class="btn btn-warn" onclick="organizeSelected()">🛠️ 仅刮削</button>
                        <button class="btn btn-dang" onclick="deleteSelected()">🗑️ 删除</button>
                    </div>
                    <div id="total-count">Loading...</div>
                </div>
                <div class="table-container" style="overflow-y:auto;">
                    <table id="db-tbl">
                        <thead>
                            <tr>
                                <th style="width:40px"><input type="checkbox" onclick="toggleAll(this)"></th>
                                <th style="width:120px">封面</th>
                                <th>标题 / 番号 / 磁力</th>
                                <th>元数据</th>
                                <th>状态</th>
                            </tr>
                        </thead>
                        <tbody></tbody>
                    </table>
                </div>
                <div style="padding:15px;text-align:center;border-top:1px solid var(--border)">
                    <button class="btn btn-pri" onclick="loadDb(dbPage-1)">上一页</button>
                    <span id="page-info" style="margin:0 15px;color:var(--text-sub)">1</span>
                    <button class="btn btn-pri" onclick="loadDb(dbPage+1)">下一页</button>
                </div>
                <div style="height:150px; background:#000; border-top:1px solid var(--border); overflow:hidden; display:flex; flex-direction:column;">
                    <div style="padding:5px 15px; background:#111; font-size:12px; font-weight:bold; color:#888;">📋 刮削/整理日志</div>
                    <div id="log-org" class="log-box" style="flex:1; border:none; border-radius:0; height:auto;"></div>
                </div>
            </div>
        </div>

        <div id="settings" class="page hidden">
            <div class="card">
                <h2>系统设置</h2>
                <div class="input-group">
                    <label>HTTP 代理</label>
                    <input id="cfg-proxy">
                </div>
                <div class="input-group">
                    <label>Flaresolverr 地址</label>
                    <input id="cfg-flare">
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
                    const imgHtml = r.image_url ? `<img src="${r.image_url}" class="cover-img" loading="lazy" onclick="window.open('${r.link}')" style="cursor:pointer">` : `<div class="cover-img" style="display:flex;align-items:center;justify-content:center;color:#555;font-size:10px">无封面</div>`;
                    let statusTags = "";
                    if (r.is_pushed) statusTags += `<span class="tag" style="color:#34d399;background:rgba(16,185,129,0.1)">已推</span>`;
                    if (r.is_renamed) statusTags += `<span class="tag" style="color:#60a5fa;background:rgba(59,130,246,0.1)">已整</span>`;
                    let metaTags = "";
                    if (r.actor) metaTags += `<span class="tag tag-actor">👤 ${r.actor}</span>`;
                    if (r.category) metaTags += `<span class="tag tag-cat">🏷️ ${r.category}</span>`;
                    let cleanMagnet = r.magnets || '';
                    if (cleanMagnet.includes('&')) cleanMagnet = cleanMagnet.split('&')[0];
                    const magnetDisplay = cleanMagnet ? `<div class="magnet-link" onclick="navigator.clipboard.writeText('${cleanMagnet}');alert('磁力已复制')">🔗 ${cleanMagnet.substring(0,20)}...</div>` : '';
                    tbody.innerHTML += `<tr><td><input type="checkbox" class="row-chk" value="${chkValue}"></td><td>${imgHtml}</td><td><div style="font-weight:500;margin-bottom:4px;max-width:300px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${r.title}</div><div style="font-size:12px;color:var(--text-sub);font-family:monospace">${r.code || '无番号'}</div>${magnetDisplay}</td><td>${metaTags}</td><td>${statusTags}</td></tr>`;
                });
            }
        }

        function startScrape(type) {
            const src = document.getElementById('scr-source').value;
            const targetUrl = document.getElementById('scr-target-url').value;
            const dl = getDlState();
            api('start', { type: type, source: src, autoDownload: dl, targetUrl: targetUrl });
        }

        async function deleteSelected() {
            const checkboxes = document.querySelectorAll('.row-chk:checked');
            if (checkboxes.length === 0) { alert("请先勾选!"); return; }
            if(!confirm(\`删除 \${checkboxes.length} 条记录?\`)) return;
            const ids = Array.from(checkboxes).map(cb => cb.value.split('|')[0]);
            try { await request('delete', { method: 'POST', body: JSON.stringify({ ids }) }); loadDb(dbPage); } catch(e) {}
        }

        async function pushSelected() {
            const checkboxes = document.querySelectorAll('.row-chk:checked');
            if (checkboxes.length === 0) { alert("请先勾选!"); return; }
            const magnets = Array.from(checkboxes).map(cb => cb.value);
            const btn = event.target; btn.innerText = "处理中..."; btn.disabled = true;
            try { 
                const res = await request('push', { method: 'POST', body: JSON.stringify({ magnets, organize: false }) }); 
                if (res.success) { alert(\`✅ 推送成功: \${res.count}\`); loadDb(dbPage); } else { alert(\`❌ \${res.msg}\`); }
            } catch(e) { alert("网络错误"); }
            btn.innerText = "📤 仅推送"; btn.disabled = false;
        }

        async function organizeSelected() {
            const checkboxes = document.querySelectorAll('.row-chk:checked');
            if (checkboxes.length === 0) { alert("请先勾选!"); return; }
            const ids = Array.from(checkboxes).map(cb => cb.value.split('|')[0]);
            const btn = event.target; btn.innerText = "请求中..."; btn.disabled = true;
            try { 
                const res = await request('organize', { method: 'POST', body: JSON.stringify({ ids }) }); 
                if (res.success) { alert(\`✅ 已加入队列: \${res.count}\`); } else { alert(\`❌ \${res.msg}\`); }
            } catch(e) { alert("网络错误"); }
            btn.innerText = "🛠️ 仅刮削"; btn.disabled = false;
        }
        
        async function saveCfg() {
            const proxy = document.getElementById('cfg-proxy').value;
            const cookie115 = document.getElementById('cfg-cookie').value;
            const flaresolverrUrl = document.getElementById('cfg-flare').value;
            const targetCid = document.getElementById('cfg-target-cid').value;
            await request('config', { method: 'POST', body: JSON.stringify({ proxy, cookie115, flaresolverrUrl, targetCid }) });
            alert('保存成功');
        }

        // 修改轮询逻辑以显示 Organizer 日志
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
                        el.innerHTML = logs.map(l => \`<div class="log-entry \${l.type==='error'?'err':l.type==='success'?'suc':l.type==='warn'?'warn':''}">\${l.time} \${l.msg}</div>\`).join('');
                        el.scrollTop = el.scrollHeight;
                        return latestSignature;
                    }
                }
                return lastTimeVar;
            };
            
            // 采集日志
            lastLogTimeScr = renderLog('log-scr', res.state.logs, lastLogTimeScr);
            // 刮削日志 (资源库底部)
            lastLogTimeOrg = renderLog('log-org', res.organizerLogs, lastLogTimeOrg);
            
            if(document.getElementById('stat-scr')) document.getElementById('stat-scr').innerText = res.state.totalScraped || 0;
        }, 2000);
    </script>
</body>
</html>
EOF

# 5. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] 可视化反馈版 V13.13.0 部署完成！"
