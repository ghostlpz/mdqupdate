#!/bin/bash
# VERSION = 13.8.0

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.8.0
# 核心升级: 全字段采集 (封面/演员/分类/番号) + 前端UI重构展示
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署旗舰版 (V13.8.0)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.8.0"/' package.json

# 2. 升级数据库 (增加 actor 和 category 字段)
echo "📝 [1/4] 升级数据库结构..."
cat > modules/db.js << 'EOF'
const mysql = require('mysql2/promise');
const dbConfig = {
    host: process.env.DB_HOST || 'db',
    user: process.env.DB_USER || 'root',
    password: process.env.DB_PASSWORD || 'zzxx1122',
    database: 'crawler_db',
    waitForConnections: true,
    connectionLimit: 10
};
const pool = mysql.createPool(dbConfig);

async function initDB() {
    let retries = 20;
    while (retries > 0) {
        try {
            const tempConn = await mysql.createConnection({
                host: dbConfig.host, user: dbConfig.user, password: dbConfig.password
            });
            await tempConn.query(`CREATE DATABASE IF NOT EXISTS crawler_db;`);
            await tempConn.end();
            
            await pool.query(`
                CREATE TABLE IF NOT EXISTS resources (
                    id INT AUTO_INCREMENT PRIMARY KEY,
                    title TEXT,
                    link VARCHAR(255) UNIQUE,
                    magnets TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    INDEX idx_link (link),
                    INDEX idx_created (created_at)
                );
            `);

            // ⚡️ V13.8.0: 字段全量补全
            const upgradeCols = [
                "ALTER TABLE resources ADD COLUMN is_pushed BOOLEAN DEFAULT 0",
                "ALTER TABLE resources ADD COLUMN is_renamed BOOLEAN DEFAULT 0",
                "ALTER TABLE resources ADD COLUMN code VARCHAR(100) DEFAULT NULL",
                "ALTER TABLE resources ADD COLUMN image_url TEXT DEFAULT NULL",
                "ALTER TABLE resources ADD COLUMN actor VARCHAR(100) DEFAULT NULL",
                "ALTER TABLE resources ADD COLUMN category VARCHAR(100) DEFAULT NULL"
            ];

            for (const sql of upgradeCols) {
                try {
                    await pool.query(sql);
                } catch (e) {
                    if (e.code !== 'ER_DUP_FIELDNAME') console.log("DB Msg:", e.message);
                }
            }

            console.log("✅ 数据库结构校验完成");
            return;
        } catch (err) {
            console.log(`⏳ DB 连接重试 (${retries})...`);
            await new Promise(r => setTimeout(r, 5000));
            retries--;
        }
    }
}
module.exports = { pool, initDB };
EOF

# 3. 升级 ResourceMgr (写入新字段)
echo "📝 [2/4] 升级数据存储逻辑..."
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
    // V13.8.0: 增加 actor 和 category
    async save(data) {
        // 兼容旧调用方式 save(title, link, magnets)
        if (arguments.length > 1 && typeof arguments[0] === 'string') {
            data = {
                title: arguments[0],
                link: arguments[1],
                magnets: arguments[2],
                code: arguments[3] || null,
                image: arguments[4] || null
            };
        }

        try {
            const [result] = await pool.execute(
                'INSERT IGNORE INTO resources (title, link, magnets, code, image_url, actor, category) VALUES (?, ?, ?, ?, ?, ?, ?)',
                [
                    data.title, 
                    data.link, 
                    data.magnets, 
                    data.code || null, 
                    data.image || null, 
                    data.actor || null, 
                    data.category || null
                ]
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
            // 模糊匹配以兼容旧数据
            const [rows] = await pool.query(
                'SELECT title, is_renamed FROM resources WHERE magnets LIKE ? OR magnets LIKE ? LIMIT 1',
                [`%${inputHash}%`, `%${inputHash.toUpperCase()}%`]
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
            const [rows] = await pool.query(`SELECT * FROM resources ORDER BY created_at DESC`);
            return rows;
        } catch (err) { return []; }
    }
};
module.exports = ResourceMgr;
EOF

# 4. 升级 scraper_xchina.js (全字段解析逻辑)
echo "📝 [3/4] 升级采集核心 (解析所有HTML元素)..."
cat > modules/scraper_xchina.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const ResourceMgr = require('./resource_mgr');

const CONCURRENCY_LIMIT = 3;
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

async function requestViaFlare(url) {
    try {
        const payload = { cmd: 'request.get', url: url, maxTimeout: 60000 };
        if (global.CONFIG.proxy) payload.proxy = { url: global.CONFIG.proxy };

        const res = await axios.post('http://flaresolverr:8191/v1', payload, { 
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

// 核心：单视频全字段解析
async function processVideoTask(task, baseUrl, autoDownload) {
    // task.link 是详情页地址
    const { link } = task; 

    // 1. 进入详情页 (必须进，为了获取元数据)
    const $ = await requestViaFlare(link);
    
    // --- 解析开始 ---
    
    // 2. 获取标题 (优先 H1，或者 fallback 到 task.title)
    let title = $('h1').text().trim() || task.title;

    // 3. 获取封面 (解析 video-js poster)
    // 元素: <div class="vjs-poster"><picture><img src="..."></picture></div>
    let image = $('.vjs-poster img').attr('src');
    if (image && !image.startsWith('http')) image = baseUrl + image;

    // 4. 获取演员 (Model)
    // 元素: <div class="model-container"><a ...>沈娜娜</a></div>
    const actor = $('.model-container .model-item').text().trim() || '未知演员';

    // 5. 获取分类 (Category)
    // 元素: <div class="text">...<span class="joiner">-</span><a ...>麻豆传媒</a></div>
    // 逻辑: 找到包含 joiner 的 text 块，取最后一个 a 标签
    let category = '';
    $('.text').each((i, el) => {
        if ($(el).find('.joiner').length > 0) {
            category = $(el).find('a').last().text().trim();
        }
    });
    if (!category) category = '未分类';

    // 6. 提取番号 (Code) - 从 URL 提取
    let code = '';
    const codeMatch = link.match(/id-([a-zA-Z0-9]+)/);
    if (codeMatch) code = codeMatch[1];

    // --- 解析结束 ---

    // 7. 提取下载链接
    const downloadLinkEl = $('a[href*="/download/id-"]');
    if (downloadLinkEl.length === 0) throw new Error("无下载入口");

    let downloadPageUrl = downloadLinkEl.attr('href');
    if (downloadPageUrl && !downloadPageUrl.startsWith('http')) {
        downloadPageUrl = baseUrl + downloadPageUrl;
    }

    // 8. 进入下载页取磁力
    const $down = await requestViaFlare(downloadPageUrl);
    const rawMagnet = $down('a.btn.magnet').attr('href');
    const magnet = cleanMagnet(rawMagnet);

    if (magnet && magnet.startsWith('magnet:')) {
        // 保存所有字段
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
                // 日志显示更丰富的信息
                log(`✅ [入库] ${code} | ${actor} | ${title.substring(0, 10)}...${extraMsg}`, 'success');
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
        
        log(`🚀 xChina 旗舰版 (V13.8.0) | 全信息采集`, 'success');

        try {
            try { await axios.get('http://flaresolverr:8191/'); } 
            catch (e) { throw new Error("无法连接 Flaresolverr"); }

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
                    
                    // 仅从列表页提取基础链接和标题，详情在 processVideoTask 中获取
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

# 5. 重构前端 index.html (展示海报和新字段)
echo "📝 [4/4] 重构前端界面 (支持海报墙模式)..."
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

        <div id="renamer" class="page hidden">
            <div class="card">
                <h2>115 整理助手</h2>
                <div class="input-group"><label>扫描页数</label><input type="number" id="r-pages" value="0"></div>
                <div class="input-group"><input type="checkbox" id="r-force" style="width:auto"> <label style="display:inline">强制重整</label></div>
                <button class="btn btn-pri" onclick="startRenamer()">开始整理</button>
                <div id="log-ren" class="log-box" style="margin-top:20px;height:200px"></div>
            </div>
        </div>
        <div id="settings" class="page hidden">
            <div class="card">
                <h2>系统设置</h2>
                <div class="input-group"><label>HTTP 代理</label><input id="cfg-proxy"></div>
                <div class="input-group"><label>115 Cookie</label><textarea id="cfg-cookie" rows="3"></textarea></div>
                <button class="btn btn-pri" onclick="saveCfg()">保存</button>
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
        // 覆盖 app.js 中的 loadDb 以适应新 UI
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
                    // 处理封面图 (如果没有则用默认占位)
                    const imgHtml = r.image_url ? 
                        `<img src="${r.image_url}" class="cover-img" loading="lazy" onclick="window.open('${r.link}')" style="cursor:pointer">` : 
                        `<div class="cover-img" style="display:flex;align-items:center;justify-content:center;color:#555;font-size:10px">无封面</div>`;
                    
                    // 状态标签
                    let statusTags = "";
                    if (r.is_pushed) statusTags += `<span class="tag" style="color:#34d399;background:rgba(16,185,129,0.1)">已推</span>`;
                    if (r.is_renamed) statusTags += `<span class="tag" style="color:#60a5fa;background:rgba(59,130,246,0.1)">已整</span>`;

                    // 元数据标签
                    let metaTags = "";
                    if (r.actor) metaTags += `<span class="tag tag-actor">👤 ${r.actor}</span>`;
                    if (r.category) metaTags += `<span class="tag tag-cat">🏷️ ${r.category}</span>`;

                    tbody.innerHTML += `
                        <tr>
                            <td><input type="checkbox" class="row-chk" value="${chkValue}"></td>
                            <td>${imgHtml}</td>
                            <td>
                                <div style="font-weight:500;margin-bottom:4px;max-width:300px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${r.title}</div>
                                <div style="font-size:12px;color:var(--text-sub);font-family:monospace">${r.code || '无番号'}</div>
                            </td>
                            <td>${metaTags}</td>
                            <td>${statusTags}</td>
                        </tr>`;
                });
            }
        }
    </script>
</body>
</html>
EOF

# 5. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] 旗舰版部署完成，请刷新浏览器 (Ctrl+F5) 查看新界面。"
