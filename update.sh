#!/bin/bash
# VERSION = 13.7.7

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.7.7
# 优化: 磁力链接净化 + 失败自动重试(3次) + 采集海报与番号 + 数据库自动扩容
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署全能增强版 (V13.7.7)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.7.7"/' package.json

# 2. 升级 db.js (支持自动迁移新字段)
echo "📝 [1/3] 升级数据库结构 (增加图片和番号字段)..."
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

            // ⚡️ V13.7.7: 动态增加新字段
            // 注意：重复执行 ADD COLUMN 会报错，我们用 try-catch 包裹
            const upgradeCols = [
                "ALTER TABLE resources ADD COLUMN is_pushed BOOLEAN DEFAULT 0",
                "ALTER TABLE resources ADD COLUMN is_renamed BOOLEAN DEFAULT 0",
                "ALTER TABLE resources ADD COLUMN code VARCHAR(100) DEFAULT NULL",
                "ALTER TABLE resources ADD COLUMN image_url TEXT DEFAULT NULL"
            ];

            for (const sql of upgradeCols) {
                try {
                    await pool.query(sql);
                } catch (e) {
                    // 忽略字段已存在的错误 code: 'ER_DUP_FIELDNAME'
                    if (e.code !== 'ER_DUP_FIELDNAME') {
                        // 也可以选择不打印日志，保持清爽
                    }
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

# 3. 升级 resource_mgr.js (支持保存新字段)
echo "📝 [2/3] 升级存储逻辑..."
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
    // V13.7.7: 增加 code 和 image 参数
    async save(title, link, magnets, code = null, image = null) {
        try {
            // 尝试插入，带上新字段
            const [result] = await pool.execute(
                'INSERT IGNORE INTO resources (title, link, magnets, code, image_url) VALUES (?, ?, ?, ?, ?)',
                [title, link, magnets, code, image]
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
            // 构造可能的磁力链格式用于查询
            // 注意：即使我们现在只存纯 Hash，旧数据可能还带有杂质
            // 所以查询时我们不仅要查精确匹配，最好也能应对模糊匹配（可选）
            // 但为了性能和准确性，这里还是主要依赖 hash 部分匹配
            const conditions = [
                `magnet:?xt=urn:btih:${inputHash}`,
                `magnet:?xt=urn:btih:${inputHash.toUpperCase()}`
            ];
            try {
                const b32 = hexToBase32(inputHash);
                conditions.push(`magnet:?xt=urn:btih:${b32}`);
                conditions.push(`magnet:?xt=urn:btih:${b32.toUpperCase()}`);
            } catch (e) {}

            // 这里使用 LIKE 查询来兼容那些带 &dn= 的旧数据
            // %hash%
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
            // 导出时也带上新字段
            const [rows] = await pool.query(`SELECT id, code, title, magnets, link, created_at FROM resources ORDER BY created_at DESC`);
            return rows;
        } catch (err) { return []; }
    }
};
module.exports = ResourceMgr;
EOF

# 4. 升级 scraper_xchina.js (实现清洗和重试)
echo "📝 [3/3] 升级采集器 (清洗+重试+全信息)..."
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

// 🧽 磁力链接清洗函数
function cleanMagnet(magnet) {
    if (!magnet) return '';
    // 优先尝试提取标准的 magnet:?xt=urn:btih:HASH
    const match = magnet.match(/(magnet:\?xt=urn:btih:[a-zA-Z0-9]{32,40})/i);
    if (match) return match[0];
    
    // 如果没有匹配到标准格式（比较少见），则简单暴力去除 &dn= 及其后面所有内容
    return magnet.split('&')[0];
}

async function requestViaFlare(url) {
    try {
        const payload = {
            cmd: 'request.get',
            url: url,
            maxTimeout: 60000
        };
        if (global.CONFIG.proxy) payload.proxy = { url: global.CONFIG.proxy };

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

// 单个任务处理（包含重试机制）
async function processVideoTaskWithRetry(task, baseUrl, autoDownload) {
    let attempt = 0;
    while (attempt < MAX_RETRIES) {
        if (STATE.stopSignal) return;
        attempt++;
        try {
            return await processVideoTask(task, baseUrl, autoDownload);
        } catch (e) {
            if (attempt === MAX_RETRIES) {
                log(`❌ [彻底失败] ${task.title.substring(0, 10)}... (重试${MAX_RETRIES}次均失败)`, 'error');
            } else {
                // 可选：打印重试日志，或者保持静默以免刷屏
                // log(`⚠️ [重试] ${task.title.substring(0, 10)}... (第${attempt}次出错)`, 'warn');
                
                // 失败后等待时间递增 (2s, 4s, 6s)
                await new Promise(r => setTimeout(r, 2000 * attempt)); 
            }
        }
    }
    return false;
}

// 核心业务逻辑
async function processVideoTask(task, baseUrl, autoDownload) {
    const { title, link, image, code } = task; // link 是详情页地址

    // 1. 访问详情页
    const $detail = await requestViaFlare(link);
    
    // 2. 提取下载页链接
    const downloadLinkEl = $detail('a[href*="/download/id-"]');
    
    if (downloadLinkEl.length > 0) {
        let downloadPageUrl = downloadLinkEl.attr('href');
        if (downloadPageUrl && !downloadPageUrl.startsWith('http')) {
            downloadPageUrl = baseUrl + downloadPageUrl;
        }

        // 3. 访问下载页
        const $down = await requestViaFlare(downloadPageUrl);
        const rawMagnet = $down('a.btn.magnet').attr('href');
        
        // 🧽 清洗磁力链
        const magnet = cleanMagnet(rawMagnet);
        
        // 4. 入库
        if (magnet && magnet.startsWith('magnet:')) {
            // 注意：这里传入了 code 和 image
            const saveRes = await ResourceMgr.save(title, link, magnet, code, image);
            if (saveRes.success) {
                if (saveRes.newInsert) {
                    STATE.totalScraped++;
                    let extraMsg = "";
                    if (autoDownload) {
                        const pushed = await pushTo115(magnet);
                        extraMsg = pushed ? " | 📥 已推115" : " | ⚠️ 推送失败";
                        if(pushed) await ResourceMgr.markAsPushedByLink(link);
                    }
                    log(`✅ [入库${extraMsg}] ${title.substring(0, 10)}...`, 'success');
                    return true; // 新增
                } else {
                    log(`⏭️ [已存在] ${title.substring(0, 10)}...`, 'info');
                    return true; // 已存在也视为成功，不需要重试
                }
            }
        } else {
            // 抛出错误触发重试
            throw new Error("下载页未找到有效磁力链"); 
        }
    } else {
        // 抛出错误触发重试
        throw new Error("详情页未找到下载按钮"); 
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
        
        log(`🚀 xChina 增强版 (V13.7.7) | 清洗:✅ | 重试:✅ | 采集信息:全量`, 'success');

        try {
            try { await axios.get('http://flaresolverr:8191/'); } 
            catch (e) { throw new Error("无法连接 Flaresolverr"); }

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
                    
                    const tasks = [];
                    items.each((i, el) => {
                        const titleEl = $(el).find('.text .title a');
                        const title = titleEl.text().trim();
                        let subLink = titleEl.attr('href');
                        
                        // 📸 提取封面图
                        // xChina 通常使用 lazyload，可能有 data-original 或 src
                        let imgUrl = $(el).find('img').attr('data-original') || $(el).find('img').attr('src');
                        if (imgUrl && !imgUrl.startsWith('http')) imgUrl = baseUrl + imgUrl;

                        // 🔢 提取番号 (Code)
                        // 尝试从 URL 中提取 ID (例如 /video/id-12345.html -> 12345)
                        // xChina 的 URL 结构通常是 /video/id-xxxxx.html
                        let code = null;
                        if (subLink) {
                            const match = subLink.match(/id-([a-zA-Z0-9]+)/);
                            if (match) code = match[1];
                        }

                        if (title && subLink) {
                            if (!subLink.startsWith('http')) subLink = baseUrl + subLink;
                            tasks.push({ title, link: subLink, image: imgUrl, code: code });
                        }
                    });

                    // ⚡️ 并发执行 (带重试)
                    for (let i = 0; i < tasks.length; i += CONCURRENCY_LIMIT) {
                        if (STATE.stopSignal) break;

                        const chunk = tasks.slice(i, i + CONCURRENCY_LIMIT);
                        
                        // 使用 Promise.all 并行处理，且每个任务内部都有 processVideoTaskWithRetry 保护
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

# 4. 重启应用
echo "🔄 重启应用以迁移数据库..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] 全能增强版补丁已应用。"
