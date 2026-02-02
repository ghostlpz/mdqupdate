#!/bin/bash
# VERSION = 13.14.8

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.14.8
# 功能: 为 PikPak 增加 "测试连接" 功能 (UI + API)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署连接测试增强版 (V13.14.8)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.14.8"/' package.json

# 2. 升级 LoginPikPak (增加 testConnection 方法)
echo "📝 [1/3] 升级 PikPak 驱动 (增加测试接口)..."
cat > modules/login_pikpak.js << 'EOF'
const axios = require('axios');
const { HttpsProxyAgent } = require('https-proxy-agent');
const path = require('path');

const LoginPikPak = {
    auth: {
        username: '',
        password: '',
        token: '',
        userId: '',
        deviceId: 'madou_omni_v1'
    },
    proxy: null,
    
    setConfig(cfg) {
        if (!cfg) return;
        if (cfg.pikpak) {
            if (cfg.pikpak.startsWith('Bearer')) {
                this.auth.token = cfg.pikpak;
            } else if (cfg.pikpak.includes('|')) {
                const parts = cfg.pikpak.split('|');
                this.auth.username = parts[0].trim();
                this.auth.password = parts[1].trim();
            }
        }
        if (cfg.proxy) this.proxy = cfg.proxy;
    },

    getAxiosConfig() {
        const config = {
            headers: {
                'Content-Type': 'application/json',
                'X-Device-Id': this.auth.deviceId,
                'Authorization': this.auth.token
            }
        };
        if (this.proxy) {
            config.httpsAgent = new HttpsProxyAgent(this.proxy);
            config.proxy = false;
        }
        return config;
    },

    async login() {
        if (this.auth.token && !this.auth.password) return true;
        if (!this.auth.username || !this.auth.password) return false;

        try {
            const url = 'https://user.mypikpak.com/v1/auth/signin';
            const payload = {
                client_id: "YNxT9w7GMvwD3",
                username: this.auth.username,
                password: this.auth.password
            };
            const config = { headers: { 'Content-Type': 'application/json' } };
            if (this.proxy) {
                config.httpsAgent = new HttpsProxyAgent(this.proxy);
                config.proxy = false;
            }

            const res = await axios.post(url, payload, config);
            if (res.data && res.data.access_token) {
                this.auth.token = 'Bearer ' + res.data.access_token;
                this.auth.userId = res.data.sub;
                console.log('✅ PikPak 登录成功');
                return true;
            }
        } catch (e) {
            console.error('❌ PikPak 登录失败:', e.message);
        }
        return false;
    },

    // 🔥 新增：测试连接
    async testConnection() {
        // 1. 尝试登录
        const loginSuccess = await this.login();
        if (!loginSuccess) return { success: false, msg: "登录失败，请检查账号密码或代理" };

        // 2. 尝试获取文件列表 (证明 API 通畅)
        try {
            const url = `https://api-drive.mypikpak.com/drive/v1/files?filters={"trashed":{"eq":false}}&limit=1`;
            await axios.get(url, this.getAxiosConfig());
            return { success: true, msg: "✅ 连接成功！(API 通畅)" };
        } catch (e) {
            return { success: false, msg: `登录成功但 API 访问失败: ${e.message}` };
        }
    },

    async addTask(url, parentId = '') {
        if (!this.auth.token) await this.login();
        try {
            const apiUrl = 'https://api-drive.mypikpak.com/drive/v1/files';
            let fileName = 'unknown_video';
            try { fileName = path.basename(new URL(url).pathname); } catch(e) {}

            const payload = {
                kind: "drive#file",
                upload_type: "UPLOAD_TYPE_URL",
                url: url,
                name: fileName
            };
            if (parentId) payload.parent_id = parentId;

            const res = await axios.post(apiUrl, payload, this.getAxiosConfig());
            return res.data && (res.data.task || res.data.file); 
        } catch (e) {
            const errMsg = e.response ? `Status ${e.response.status}: ${JSON.stringify(e.response.data)}` : e.message;
            console.error('PikPak AddTask Error:', errMsg);
            return false;
        }
    },

    async getFileList(parentId = '') {
        if (!this.auth.token) await this.login();
        try {
            let url = `https://api-drive.mypikpak.com/drive/v1/files?filters={"trashed":{"eq":false}}&limit=100`;
            if (parentId) url += `&parent_id=${parentId}`;
            
            const res = await axios.get(url, this.getAxiosConfig());
            if (res.data && res.data.files) {
                const list = res.data.files.map(f => ({
                    fid: f.id,
                    n: f.name,
                    s: parseInt(f.size || 0),
                    fcid: f.kind === 'drive#folder' ? f.id : undefined,
                    parent_id: f.parent_id
                }));
                return { data: list };
            }
        } catch (e) { console.error(e.message); }
        return { data: [] };
    },

    async searchFile(keyword, parentId = '') {
        if (!this.auth.token) await this.login();
        try {
            const list = await this.getFileList(parentId);
            const matches = list.data.filter(f => f.n.includes(keyword));
            return { data: matches };
        } catch (e) { return { data: [] }; }
    },

    async rename(fileId, newName) {
        if (!this.auth.token) await this.login();
        try {
            const url = `https://api-drive.mypikpak.com/drive/v1/files/${fileId}`;
            const payload = { name: newName };
            const res = await axios.patch(url, payload, this.getAxiosConfig());
            return { success: !!res.data.id };
        } catch (e) { return { success: false, msg: e.message }; }
    },

    async move(fileIds, targetCid) {
        if (!this.auth.token) await this.login();
        try {
            const url = 'https://api-drive.mypikpak.com/drive/v1/files/batch_move';
            const ids = fileIds.split(',');
            const payload = { ids: ids, to: { parent_id: targetCid } };
            const res = await axios.post(url, payload, this.getAxiosConfig());
            return true;
        } catch (e) { return false; }
    },

    async deleteFiles(fileIds) {
        if (!this.auth.token) await this.login();
        try {
            const url = 'https://api-drive.mypikpak.com/drive/v1/files/batch_trash';
            const ids = fileIds.split(',');
            const payload = { ids: ids };
            await axios.post(url, payload, this.getAxiosConfig());
            return true;
        } catch (e) { return false; }
    },

    async getTaskByHash(hashOrUrl, nameHint = '') {
        if (!this.auth.token) await this.login();
        try {
            if (nameHint) {
                const searchRes = await this.searchFile(nameHint.substring(0, 10));
                if (searchRes.data && searchRes.data.length > 0) {
                    const f = searchRes.data[0];
                    return {
                        status_code: 2,
                        folder_cid: f.fcid ? f.fid : f.parent_id,
                        file_id: f.fid,
                        percent: 100
                    };
                }
            }
        } catch (e) {}
        return null;
    },

    async uploadFile(fileBuffer, fileName, parentId = '') {
        if (!this.auth.token) await this.login();
        try {
            const createUrl = 'https://api-drive.mypikpak.com/drive/v1/files';
            const createPayload = {
                kind: "drive#file",
                name: fileName,
                upload_type: "UPLOAD_TYPE_RESUMABLE"
            };
            if (parentId) createPayload.parent_id = parentId;

            const res1 = await axios.post(createUrl, createPayload, this.getAxiosConfig());
            const uploadUrl = res1.data.upload_url;
            const fileId = res1.data.file.id;

            if (uploadUrl) {
                const putConfig = this.getAxiosConfig();
                putConfig.headers['Content-Type'] = ''; 
                await axios.put(uploadUrl, fileBuffer, putConfig);
                return fileId;
            }
        } catch (e) { console.error('PP Upload Err:', e.message); }
        return null;
    }
};

if(global.CONFIG) LoginPikPak.setConfig(global.CONFIG);
module.exports = LoginPikPak;
EOF

# 3. 升级 API (增加 check 路由)
echo "📝 [2/3] 升级 API (增加 /pikpak/check)..."
# 注意：直接追加路由比较麻烦，这里我们覆盖 api.js
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
const LoginPikPak = require('../modules/login_pikpak'); // 引入
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
    // 立即刷新 PikPak 配置
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

// 🔥 新增：PikPak 测试接口
router.get('/pikpak/check', async (req, res) => {
    try {
        // 确保使用最新配置
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

# 4. 更新前端 (增加测试按钮和逻辑)
echo "📝 [3/3] 升级前端界面 (增加测试按钮)..."
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
                <div class="input-group">
                    <label>PikPak 账号 (用户名|密码)</label>
                    <div style="display:flex;gap:10px">
                        <input id="cfg-pikpak" placeholder="username|password" style="flex:1">
                        <button class="btn btn-info" onclick="checkPikPak()">🧪 测试连接</button>
                    </div>
                </div>
                
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
        
        async function checkPikPak() {
            const btn = event.target;
            const oldTxt = btn.innerText;
            btn.innerText = "⏳ 测试中...";
            btn.disabled = true;
            
            // 先保存配置
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

# 5. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.14.8 部署完成！"
