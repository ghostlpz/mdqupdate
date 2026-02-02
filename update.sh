#!/bin/bash
# VERSION = 13.7.1

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本 (Docker 容器版)
# 版本: V13.7.1
# 修复: xChina 采集模块增加 Proxy 透传，解决 Flaresolverr 连接超时
# ---------------------------------------------------------

echo "🚀 [Update] 开始执行容器内热更新 (V13.7.1)..."
echo "📂 当前工作目录: $(pwd)"

# 1. 更新 package.json
# 直接修改当前目录下的 package.json
echo "📝 [1/6] 更新版本号..."
sed -i 's/"version": ".*"/"version": "13.7.1"/' package.json

# 2. 更新 modules/resource_mgr.js
# 路径：./modules/resource_mgr.js
echo "📝 [2/6] 升级资源管理器..."
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
            const [result] = await pool.execute(
                'INSERT IGNORE INTO resources (title, link, magnets) VALUES (?, ?, ?)',
                [title, link, magnets]
            );
            return { success: true, newInsert: result.affectedRows > 0 };
        } catch (err) { 
            console.error(err);
            return { success: false, newInsert: false }; 
        }
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

    async getList(page, limit, filters = {}) {
        try {
            const offset = (page - 1) * limit;
            let whereClause = "";
            const conditions = [];
            if (filters.pushed === '1') conditions.push("is_pushed = 1");
            if (filters.pushed === '0') conditions.push("is_pushed = 0");
            if (filters.renamed === '1') conditions.push("is_renamed = 1");
            if (filters.renamed === '0') conditions.push("is_renamed = 0");
            if (conditions.length > 0) whereClause = " WHERE " + conditions.join(" AND ");

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

# 3. 创建 modules/scraper_xchina.js
# 路径：./modules/scraper_xchina.js
# 重点：此处已添加 proxy 逻辑
echo "📝 [3/6] 部署 xChina 采集核心 (含代理修复)..."
cat > modules/scraper_xchina.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const ResourceMgr = require('./resource_mgr');

let STATE = { isRunning: false, stopSignal: false, logs: [], totalScraped: 0 };

function log(msg, type = 'info') {
    STATE.logs.push({ time: new Date().toLocaleTimeString(), msg, type });
    if (STATE.logs.length > 200) STATE.logs.shift();
    console.log(`[Scraper-xChina] ${msg}`);
}

async function requestViaFlare(url) {
    try {
        const payload = {
            cmd: 'request.get',
            url: url,
            maxTimeout: 60000
        };

        // 🔥 关键修复：将系统配置的代理传给 Flaresolverr
        if (global.CONFIG.proxy) {
            payload.proxy = { url: global.CONFIG.proxy };
        }

        const res = await axios.post('http://flaresolverr:8191/v1', payload, { 
            headers: { 'Content-Type': 'application/json' } 
        });

        if (res.data.status === 'ok') {
            return cheerio.load(res.data.solution.response);
        } else {
            throw new Error(`Flaresolverr Error: ${res.data.message}`);
        }
    } catch (e) {
        throw new Error(`请求失败: ${e.message}`);
    }
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

const ScraperXChina = {
    getState: () => STATE,
    stop: () => { STATE.stopSignal = true; },
    clearLogs: () => { STATE.logs = []; },
    
    start: async (limitPages = 5, autoDownload = false) => {
        if (STATE.isRunning) return;
        STATE.isRunning = true;
        STATE.stopSignal = false;
        STATE.totalScraped = 0;
        
        log(`🚀 xChina 任务启动 | 目标: ${limitPages}页 | 代理: ${global.CONFIG.proxy ? '✅已启用' : '❌未配置'}`, 'success');

        try {
            try { await axios.get('http://flaresolverr:8191/'); } 
            catch (e) { throw new Error("无法连接 Flaresolverr，请检查 docker-compose 是否已配置该服务"); }

            let page = 1;
            const baseUrl = "https://xchina.co";
            
            while (page <= limitPages && !STATE.stopSignal) {
                const listUrl = page === 1 ? `${baseUrl}/videos.html` : `${baseUrl}/videos/${page}.html`;
                log(`📡 正在扫描第 ${page} 页...`, 'info');

                try {
                    const $ = await requestViaFlare(listUrl);
                    const items = $('.item.video');
                    
                    if (items.length === 0) { log(`⚠️ 第 ${page} 页未发现视频`, 'warn'); break; }
                    log(`🔍 本页发现 ${items.length} 个视频...`);

                    let newItemsInPage = 0;

                    for (let i = 0; i < items.length; i++) {
                        if (STATE.stopSignal) break;
                        const el = items[i];
                        const titleEl = $(el).find('.text .title a');
                        const title = titleEl.text().trim();
                        const subLink = titleEl.attr('href');
                        const fullLink = baseUrl + subLink;

                        if (!subLink) continue;

                        try {
                            const $detail = await requestViaFlare(fullLink);
                            const downloadLinkEl = $detail('a[href*="/download/id-"]');
                            
                            if (downloadLinkEl.length > 0) {
                                const downloadPageUrl = downloadLinkEl.attr('href');
                                const $down = await requestViaFlare(downloadPageUrl);
                                const magnet = $down('a.btn.magnet').attr('href');
                                
                                if (magnet && magnet.startsWith('magnet:')) {
                                    const saveRes = await ResourceMgr.save(title, fullLink, magnet);
                                    if (saveRes.success) {
                                        if (saveRes.newInsert) {
                                            STATE.totalScraped++;
                                            newItemsInPage++;
                                            let extraMsg = "";
                                            if (autoDownload) {
                                                const pushed = await pushTo115(magnet);
                                                extraMsg = pushed ? " | 📥 已推115" : " | ⚠️ 推送失败";
                                                if(pushed) await ResourceMgr.markAsPushedByLink(fullLink);
                                            }
                                            log(`✅ [入库${extraMsg}] ${title.substring(0, 10)}...`, 'success');
                                        } else {
                                            log(`⏭️ [已存在] ${title.substring(0, 10)}...`, 'info');
                                        }
                                    }
                                } else { log(`❌ [无磁力] ${title.substring(0, 10)}...`, 'warn'); }
                            } else { log(`❌ [无下载页] ${title.substring(0, 10)}...`, 'warn'); }

                        } catch (itemErr) { log(`❌ [解析失败] ${title}: ${itemErr.message}`, 'error'); }
                        await new Promise(r => setTimeout(r, 2000)); 
                    }

                    if (newItemsInPage === 0 && page > 1) { log(`⚠️ 本页全为旧数据，提前结束`, 'warn'); break; }

                    page++;
                    await new Promise(r => setTimeout(r, 3000));

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

# 4. 更新 routes/api.js
# 路径：./routes/api.js
echo "📝 [4/6] 更新 API 路由逻辑..."
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
    res.json({ 
        config: global.CONFIG, 
        state: { isRunning: Scraper.getState().isRunning || ScraperXChina.getState().isRunning, logs, totalScraped: scraped }, 
        renamerState: Renamer.getState(), 
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

    if (Scraper.getState().isRunning || ScraperXChina.getState().isRunning) {
        return res.json({ success: false, msg: "已有任务正在运行" });
    }

    if (source === 'xchina') {
        const pages = type === 'full' ? 50 : 5;
        ScraperXChina.clearLogs();
        ScraperXChina.start(pages, autoDl);
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

# 5. 更新 public/index.html
# 路径：./public/index.html
echo "📝 [5/6] 刷新前端 UI..."
cat > public/index.html << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>Madou Omni Pro</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
    <style>
        :root {
            --primary: #6366f1;
            --primary-hover: #4f46e5;
            --bg-body: #0f172a;
            --bg-sidebar: #1e293b;
            --bg-card: rgba(30, 41, 59, 0.7);
            --border: rgba(148, 163, 184, 0.1);
            --text-main: #f8fafc;
            --text-sub: #94a3b8;
            --success: #10b981;
            --warning: #f59e0b;
            --danger: #ef4444;
            --radius: 12px;
            --shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
        }

        * { box-sizing: border-box; outline: none; -webkit-tap-highlight-color: transparent; }
        
        body {
            background-color: var(--bg-body);
            background-image: radial-gradient(at 0% 0%, rgba(99, 102, 241, 0.15) 0px, transparent 50%),
                              radial-gradient(at 100% 100%, rgba(16, 185, 129, 0.1) 0px, transparent 50%);
            background-attachment: fixed;
            color: var(--text-main);
            font-family: 'Inter', sans-serif;
            margin: 0;
            display: flex;
            height: 100vh;
            overflow: hidden;
        }

        .sidebar {
            width: 260px; background: var(--bg-sidebar); border-right: 1px solid var(--border);
            display: flex; flex-direction: column; padding: 20px; z-index: 10;
        }
        .logo { font-size: 24px; font-weight: 700; color: var(--text-main); margin-bottom: 40px; }
        .logo span { color: var(--primary); }
        .nav-item {
            display: flex; align-items: center; padding: 12px 16px; color: var(--text-sub);
            text-decoration: none; border-radius: var(--radius); margin-bottom: 8px;
            transition: all 0.2s; font-weight: 500; cursor: pointer;
        }
        .nav-item:hover { background: rgba(255,255,255,0.05); color: var(--text-main); }
        .nav-item.active { background: var(--primary); color: white; box-shadow: 0 4px 12px rgba(99, 102, 241, 0.3); }
        .nav-icon { margin-right: 12px; font-size: 18px; }

        .main { flex: 1; padding: 30px; overflow-y: auto; position: relative; }
        h1 { font-size: 24px; margin: 0 0 20px 0; font-weight: 600; }

        .card {
            background: var(--bg-card); backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px);
            border: 1px solid var(--border); border-radius: var(--radius); padding: 24px; margin-bottom: 24px;
            box-shadow: var(--shadow);
        }

        .btn {
            padding: 10px 24px; border: none; border-radius: 8px; font-weight: 500; cursor: pointer;
            transition: all 0.2s; display: inline-flex; align-items: center; justify-content: center;
            gap: 8px; color: white; font-size: 14px; min-width: 100px;
        }
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
        input, select, textarea {
            width: 100%; background: rgba(0,0,0,0.2); border: 1px solid var(--border);
            border-radius: 8px; padding: 10px 12px; color: white; font-family: inherit; transition: 0.2s;
        }
        input:focus, select:focus, textarea:focus { border-color: var(--primary); }
        .btn-row { display: flex; gap: 10px; justify-content: flex-start; margin-bottom: 10px; flex-wrap: wrap; }

        .log-box {
            background: #0b1120; border-radius: 8px; padding: 15px; height: 300px;
            overflow-y: auto; font-family: monospace; font-size: 12px; line-height: 1.6; border: 1px solid var(--border);
        }
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
                
                <div class="input-group" style="margin-bottom:15px">
                    <div style="margin-bottom:5px;font-size:13px;color:#94a3b8">选择数据源</div>
                    <select id="scr-source" style="background:rgba(0,0,0,0.3);border:1px solid rgba(255,255,255,0.1)">
                        <option value="madou">🍄 麻豆区 (MadouQu)</option>
                        <option value="xchina">📘 小黄书 (xChina)</option>
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
                    // 修复：显示完整磁力链
                    const magnetText = r.magnets || '';
                    tbody.innerHTML += `
                        <tr>
                            <td><input type="checkbox" class="tbl-chk row-chk" value="${chkValue}"></td>
                            <td><span style="opacity:0.5">#</span>${r.id}</td>
                            <td class="title-cell">
                                <div style="margin-bottom:4px">${r.title}</div>
                                <div>${tags}</div>
                            </td>
                            <td class="magnet-cell">${magnetText}</td>
                            <td style="font-size:12px;color:var(--text-sub)">${time}</td>
                        </tr>`;
                });
            }
        }
    </script>
</body>
</html>
EOF

# 6. 更新 public/js/app.js
# 路径：./public/js/app.js
echo "📝 [6/6] 更新 JS 逻辑..."
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
    // Handle click event or manual call
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
    await request('config', { method: 'POST', body: JSON.stringify({ proxy: document.getElementById('cfg-proxy').value, cookie115: document.getElementById('cfg-cookie').value }) });
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

# 7. 重启应用
# 在容器内部，我们需要通过杀死 node 进程来触发 Docker 的自动重启机制
echo "🔄 尝试重启应用..."
pkill -f "node app.js" || echo "应用可能未运行或已停止。"

echo "✅ [完成] 更新脚本已执行完毕，系统即将重启。"
