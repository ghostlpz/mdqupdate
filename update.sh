#!/bin/bash
# VERSION = 13.14.2 (FROM 13.6 FINAL)

echo "🚀 [Upgrade] 正在执行 V13.6 -> V13.14.2 深度重构升级..."
echo "📋 目标: 迁移至 SQLite | 开启 xChina 采集 | 保持 115 整理功能"

# 0. 🛡️ 环境预处理 (解决 SQLite 在 Alpine 下的编译问题)
echo "🔧 安装编译依赖 (防止 sqlite3 安装失败)..."
if command -v apk > /dev/null; then
    sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories
    apk add --no-cache python3 make g++
fi

# 1. 🧹 清理旧架构 (移除 MySQL 和未来版本的残留)
echo "🧹 清理 MySQL 及冗余文件..."
rm -f /app/modules/db.js  # 移除 MySQL 连接池
rm -rf /app/python_service # 移除 Python 服务
rm -f /app/modules/login_pikpak.js # 移除 PikPak
rm -f /app/modules/m3u8_client.js # 移除 M3U8 Client

# 2. 📦 依赖重构 (package.json)
echo "📦 更新依赖配置 (Switching to SQLite)..."
cat > package.json << 'EOF'
{
  "name": "madou-omni",
  "version": "13.14.2",
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
    "json2csv": "^6.0.0",
    "node-schedule": "^2.1.1",
    "sqlite3": "^5.1.6"
  }
}
EOF

# 3. 📝 核心重写: ResourceMgr (SQLite 版 + 兼容 V13.6 整理逻辑)
echo "📝 部署数据库管理器 (含 Renamer 兼容接口)..."
mkdir -p modules
cat > modules/resource_mgr.js << 'EOF'
const sqlite3 = require('sqlite3').verbose();
const path = require('path');
const fs = require('fs');

// 确保持久化目录存在
if (!fs.existsSync('/data')) fs.mkdirSync('/data');
const dbPath = '/data/database.db'; 

const db = new sqlite3.Database(dbPath);

// 初始化表结构
db.serialize(() => {
    db.run(`CREATE TABLE IF NOT EXISTS resources (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        code TEXT UNIQUE,
        title TEXT,
        link TEXT,
        magnets TEXT,
        image TEXT,
        actor TEXT,
        category TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        pushed INTEGER DEFAULT 0,
        renamed INTEGER DEFAULT 0
    )`);
    
    // 自动迁移: 尝试添加新字段 (如果从旧 SQLite 升级)
    const cols = ['magnets', 'image', 'actor', 'category', 'pushed', 'renamed'];
    cols.forEach(col => {
        try { db.run(`ALTER TABLE resources ADD COLUMN ${col} TEXT`); } catch(e) {}
    });
});

// 辅助: Hex 转 Base32 (用于 Hash 匹配)
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
    // 通用保存接口
    save: (data) => {
        return new Promise((resolve, reject) => {
            // 兼容旧版参数 save(title, link, magnets)
            let title, link, magnets, code, image, actor, category;
            if (arguments.length > 1) {
                title = arguments[0]; link = arguments[1]; magnets = arguments[2];
                code = link; 
            } else {
                ({ title, link, magnets, code, image, actor, category } = data);
            }

            // 优先用 Link 或 Code 查重
            db.get("SELECT id FROM resources WHERE link = ? OR code = ?", [link, code || link], (err, row) => {
                if (err) return reject(err);
                if (row) {
                    // 更新磁力
                    db.run("UPDATE resources SET magnets = ? WHERE id = ?", [magnets, row.id]);
                    resolve({ success: true, newInsert: false, id: row.id });
                } else {
                    db.run(`INSERT INTO resources (code, title, link, magnets, image, actor, category) VALUES (?, ?, ?, ?, ?, ?, ?)`,
                        [code || link, title, link, magnets, image, actor, category],
                        function(err) {
                            if (err) return reject(err);
                            resolve({ success: true, newInsert: true, id: this.lastID });
                        }
                    );
                }
            });
        });
    },

    // 🔥 关键兼容: 为 Renamer 提供 Hash 查询 (移植自 13.6)
    queryByHash: (hash) => {
        return new Promise((resolve, reject) => {
            if (!hash) return resolve(null);
            const inputHash = hash.trim().toLowerCase();
            // 构造模糊查询条件 (SQLite 没有 IN (?) 数组解构，需手动拼接 OR)
            // 简单起见，我们获取所有记录在内存匹配 (数据量不大时可行)，或者用 LIKE
            // 为了性能，这里使用 LIKE 匹配磁力链中的 hash
            
            db.get(`SELECT title, renamed FROM resources WHERE magnets LIKE ? LIMIT 1`, [`%${inputHash}%`], (err, row) => {
                if (err) return resolve(null);
                if (row) {
                    resolve({ title: row.title, is_renamed: row.renamed }); // 映射字段名
                } else {
                    resolve(null);
                }
            });
        });
    },

    getByIds: (ids) => {
        return new Promise((resolve, reject) => {
            if (!ids.length) return resolve([]);
            const placeholders = ids.map(() => '?').join(',');
            db.all(`SELECT * FROM resources WHERE id IN (${placeholders})`, ids, (err, rows) => {
                if (err) reject(err); else resolve(rows);
            });
        });
    },
    markAsPushed: (id) => {
        return new Promise((resolve) => db.run("UPDATE resources SET pushed = 1 WHERE id = ?", [id], () => resolve()));
    },
    markAsRenamed: (id) => {
        return new Promise((resolve) => db.run("UPDATE resources SET renamed = 1 WHERE id = ?", [id], () => resolve()));
    },
    // 🔥 关键兼容: Renamer 用 Title 标记
    markAsRenamedByTitle: (title) => {
        return new Promise((resolve) => db.run("UPDATE resources SET renamed = 1 WHERE title = ?", [title], () => resolve()));
    },
    markAsPushedByLink: (link) => {
        return new Promise((resolve) => db.run("UPDATE resources SET pushed = 1 WHERE link = ?", [link], () => resolve()));
    },
    deleteByIds: (ids) => {
        return new Promise((resolve) => {
             const placeholders = ids.map(() => '?').join(',');
             db.run(`DELETE FROM resources WHERE id IN (${placeholders})`, ids, function(err) {
                 if(err) resolve({success:false, error: err.message});
                 else resolve({success:true, count: this.changes});
             });
        });
    },
    getList: (page, limit, filters = {}) => {
        return new Promise((resolve, reject) => {
            const offset = (page - 1) * limit;
            let where = "1=1";
            if (filters.pushed === '0') where += " AND pushed = 0";
            if (filters.pushed === '1') where += " AND pushed = 1";
            if (filters.renamed === '0') where += " AND renamed = 0";
            if (filters.renamed === '1') where += " AND renamed = 1";
            
            db.all(`SELECT * FROM resources WHERE ${where} ORDER BY created_at DESC LIMIT ? OFFSET ?`, [limit, offset], (err, rows) => {
                if (err) return reject(err);
                db.get(`SELECT COUNT(*) as count FROM resources WHERE ${where}`, [], (err, res) => {
                    resolve({ data: rows, total: res ? res.count : 0, page: page });
                });
            });
        });
    },
    getAllForExport: () => {
        return new Promise((resolve, reject) => {
            db.all("SELECT * FROM resources ORDER BY created_at DESC", [], (err, rows) => {
                if(err) reject(err); else resolve(rows);
            });
        });
    }
};
module.exports = ResourceMgr;
EOF

# 4. 📝 升级 115 模块 (modules/login_115.js)
echo "📝 升级 115 登录模块..."
cat > modules/login_115.js << 'EOF'
const axios = require('axios');
const Login115 = {
    async getQrCode() {
        const url = 'https://qrcodeapi.115.com/api/1.0/web/1.0/token';
        const res = await axios.get(url, { headers: { 'User-Agent': 'Mozilla/5.0' } });
        if (res.data.state === 1) {
            const { uid, time, sign } = res.data.data;
            return { uid, time, sign, qr_url: `https://qrcodeapi.115.com/api/1.0/web/1.0/qrcode?w=200&uid=${uid}&time=${time}&sign=${sign}` };
        }
        throw new Error("获取二维码失败");
    },
    async checkStatus(uid, time, sign) {
        const url = `https://qrcodeapi.115.com/get/status/?uid=${uid}&time=${time}&sign=${sign}&_=${Date.now()}`;
        try {
            const res = await axios.get(url);
            const data = res.data;
            if (!data.data) return { success: false, status: -1, msg: "API异常" };
            const status = data.data.status;
            if (status === 2) {
                let cookieStr = "";
                const rawCookie = data.data.cookie;
                if (typeof rawCookie === 'object' && rawCookie !== null) {
                    const parts = [];
                    for (let key in rawCookie) parts.push(`${key}=${rawCookie[key]}`);
                    cookieStr = parts.join('; ');
                } else {
                    cookieStr = JSON.stringify(rawCookie).replace(/["{}]/g, '').replace(/:/g, '=').replace(/,/g, '; ');
                }
                return { success: true, status: 2, cookie: cookieStr };
            }
            if (status === 1) return { success: false, status: 1, msg: "已扫码，等待确认" };
            return { success: false, status: 0, msg: "等待扫码" };
        } catch (e) { return { success: false, status: -1, error: e.message }; }
    },
    // 新增: 离线下载添加任务
    async addTask(magnet) {
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
};
module.exports = Login115;
EOF

# 5. 📝 升级整理器 Renamer (modules/renamer.js)
# 保留 13.6 的整理逻辑，但适配新的 ResourceMgr
echo "📝 适配 115 整理器 (Renamer)..."
cat > modules/renamer.js << 'EOF'
const axios = require('axios');
const ResourceMgr = require('./resource_mgr');
let STATE = { isRunning: false, stopSignal: false, logs: [], stats: { success: 0, fail: 0, skip: 0 } };
const delay = () => new Promise(r => setTimeout(r, 3000));

function log(msg, type = 'info') {
    STATE.logs.push({ time: new Date().toLocaleTimeString(), msg, type });
    if (STATE.logs.length > 200) STATE.logs.shift();
    console.log(`[Renamer] ${msg}`);
}

async function req115(url, method = 'GET', data = null) {
    if (!global.CONFIG.cookie115) throw new Error("未登录 115");
    await delay();
    const headers = { 'Cookie': global.CONFIG.cookie115, 'User-Agent': global.CONFIG.userAgent || 'Mozilla/5.0' };
    if (method === 'POST') headers['Content-Type'] = 'application/x-www-form-urlencoded';
    return axios({ method, url, data, headers });
}

function formatSize(bytes) {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
}

async function checkFolderStatus(cid) {
    try {
        const url = `https://webapi.115.com/files?aid=1&cid=${cid}&o=file_size&asc=0&show_dir=0&limit=50`;
        const res = await req115(url);
        if (!res.data.state) return { status: 'GONE' };
        if (!res.data.data || res.data.data.length === 0) return { status: 'EMPTY' };
        const files = res.data.data;
        files.sort((a, b) => b.s - a.s);
        const largestFile = files[0];
        if (largestFile.s < 104857600) { return { status: 'SMALL', file: largestFile }; }
        return { status: 'OK', file: largestFile };
    } catch (e) { return { status: 'ERROR' }; }
}

const Renamer = {
    getState: () => STATE,
    stop: () => { STATE.stopSignal = true; },
    clearLogs: () => { STATE.logs = []; },
    start: async (inputPages = 0, force = true) => {
        if (STATE.isRunning) return;
        STATE.isRunning = true;
        STATE.stopSignal = false;
        STATE.stats = { success: 0, fail: 0, skip: 0 };
        const isAuto = (inputPages === 0);
        log(`🚀 启动整理 (13.14.2) | 模式: ${isAuto ? "全量" : inputPages + "页"} | 强制: ${force?'是':'否'}`, 'success');
        let currentPage = 1;
        let hasNext = true;
        try {
            while (!STATE.stopSignal && ((isAuto && hasNext) || (!isAuto && currentPage <= inputPages))) {
                log(`📡 扫描列表第 ${currentPage} 页...`);
                const listUrl = `https://115.com/web/lixian/?ct=lixian&ac=task_lists&page=${currentPage}`;
                const res = await req115(listUrl);
                if (!res.data.state) throw new Error("115 API返回失败");
                const tasks = res.data.tasks || [];
                const totalPages = res.data.page_count || 1;
                if (isAuto && currentPage >= totalPages) hasNext = false;
                if (tasks.length === 0) { log("⚠️ 当前页无任务", 'warn'); break; }
                
                for (const task of tasks) {
                    if (STATE.stopSignal) break;
                    const name = task.name || "未知任务";
                    const hash = task.info_hash || task.hash;
                    const fileId = task.file_id || task.cid || task.id;
                    let percent = task.percent;
                    if (percent === undefined && task.percentDone !== undefined) percent = task.percentDone;
                    let status = task.state;
                    if (status === undefined && task.status !== undefined) status = task.status;
                    
                    const isSuccess = fileId && status === 2 && percent === 100;
                    if (!isSuccess) continue; 
                    
                    if (!hash) continue;
                    
                    // 调用 ResourceMgr 新增的 queryByHash
                    const dbRecord = await ResourceMgr.queryByHash(hash);
                    if (dbRecord) {
                        if (!force && dbRecord.is_renamed) { 
                            log(`⏭️ [已整理] ${dbRecord.title.substring(0,10)}... (跳过)`, 'info'); 
                            STATE.stats.skip++; 
                            continue; 
                        }
                        
                        log(`🎯 [命中] ${dbRecord.title.substring(0, 10)}...`, 'success');
                        const check = await checkFolderStatus(fileId);
                        
                        if (check.status === 'OK') {
                            const targetFile = check.file;
                            const currentName = targetFile.n;
                            const ext = currentName.lastIndexOf('.') > -1 ? currentName.substring(currentName.lastIndexOf('.')) : '';
                            
                            // 清理标题逻辑
                            let cleanDbTitle = dbRecord.title.replace(/^[a-zA-Z0-9\s]+/, "").trim();
                            if (!cleanDbTitle) cleanDbTitle = dbRecord.title;
                            const newName = cleanDbTitle + ext;
                            
                            if (currentName !== newName) {
                                log(`✏️ [改名] ${currentName} -> ${newName}`, 'info');
                                const postData = `fid=${targetFile.fid}&file_name=${encodeURIComponent(newName)}`;
                                const editRes = await req115('https://webapi.115.com/files/edit', 'POST', postData);
                                if (editRes.data.state) { 
                                    STATE.stats.success++; 
                                    log(`✅ 改名成功`, 'success'); 
                                    await ResourceMgr.markAsRenamedByTitle(dbRecord.title); 
                                } else { 
                                    STATE.stats.fail++; 
                                    log(`❌ 改名失败: ${editRes.data.error}`, 'error'); 
                                }
                            } else {
                                log(`⏭️ [已正确]`, 'info'); 
                                STATE.stats.skip++; 
                                await ResourceMgr.markAsRenamedByTitle(dbRecord.title); 
                            }
                        }
                    }
                }
                currentPage++;
            }
        } catch (e) { log(`🔥 任务异常: ${e.message}`, 'error'); }
        STATE.isRunning = false;
        log("🏁 任务结束", 'warn');
    }
};
module.exports = Renamer;
EOF

# 6. 📝 部署 xChina 采集器 (modules/scraper_xchina.js)
echo "📝 部署 xChina 采集器..."
cat > modules/scraper_xchina.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const ResourceMgr = require('./resource_mgr');
const Login115 = require('./login_115');

const CONCURRENCY_LIMIT = 3;
const MAX_RETRIES = 3;

// 完整分类 (已精简显示，实际写入时请保留所有)
const FULL_CATS = [
    { name: "麻豆传媒", code: "series-5f904550b8fcc" }, { name: "独立创作者", code: "series-61bf6e439fed6" }, { name: "糖心Vlog", code: "series-61014080dbfde" }, { name: "蜜桃传媒", code: "series-5fe8403919165" }, { name: "星空传媒", code: "series-6054e93356ded" }, { name: "天美传媒", code: "series-60153c49058ce" }, { name: "果冻传媒", code: "series-5fe840718d665" }, { name: "香蕉视频", code: "series-65e5f74e4605c" }, { name: "精东影业", code: "series-60126bcfb97fa" }, { name: "杏吧原版", code: "series-6072997559b46" }, { name: "爱豆传媒", code: "series-63d134c7a0a15" }, { name: "IBiZa Media", code: "series-64e9cce89da21" }, { name: "性视界", code: "series-63490362dac45" }, { name: "ED Mosaic", code: "series-63732f5c3d36b" }, { name: "大象传媒", code: "series-65bcaa9688514" }, { name: "扣扣传媒", code: "series-6230974ada989" }, { name: "萝莉社", code: "series-6360ca9706ecb" }, { name: "SA国际传媒", code: "series-633ef3ef07d33" }, { name: "其他中文AV", code: "series-63986aec205d8" }, { name: "抖阴", code: "series-6248705dab604" }, { name: "葫芦影业", code: "series-6193d27975579" }, { name: "乌托邦", code: "series-637750ae0ee71" }, { name: "爱神传媒", code: "series-6405b6842705b" }, { name: "乐播传媒", code: "series-60589daa8ff97" }, { name: "91茄子", code: "series-639c8d983b7d5" }, { name: "草莓视频", code: "series-671ddc0b358ca" }, { name: "JVID", code: "series-6964cfbda328b" }, { name: "YOYO", code: "series-64eda52c1c3fb" }, { name: "51吃瓜", code: "series-671dd88d06dd3" }, { name: "哔哩传媒", code: "series-64458e7da05e6" }, { name: "映秀传媒", code: "series-6560dc053c99f" }, { name: "西瓜影视", code: "series-648e1071386ef" }, { name: "思春社", code: "series-64be8551bd0f1" }, { name: "有码AV", code: "series-6395aba3deb74" }, { name: "无码AV", code: "series-6395ab7fee104" }, { name: "AV解说", code: "series-6608638e5fcf7" }, { name: "PANS视频", code: "series-63963186ae145" }, { name: "其他模特私拍", code: "series-63963534a9e49" }, { name: "热舞", code: "series-64edbeccedb2e" }, { name: "相约中国", code: "series-63ed0f22e9177" }, { name: "果哥作品", code: "series-6396315ed2e49" }, { name: "SweatGirl", code: "series-68456564f2710" }, { name: "风吟鸟唱作品", code: "series-6396319e6b823" }, { name: "色艺无间", code: "series-6754a97d2b343" }, { name: "黄甫", code: "series-668c3b2de7f1c" }, { name: "日月俱乐部", code: "series-63ab1dd83a1c6" }, { name: "探花现场", code: "series-63965bf7b7f51" }, { name: "主播现场", code: "series-63965bd5335fc" }, { name: "华语电影", code: "series-6396492fdb1a0" }, { name: "日韩电影", code: "series-6396494584b57" }, { name: "欧美电影", code: "series-63964959ddb1b" }, { name: "其他亚洲影片", code: "series-63963ea949a82" }, { name: "门事件", code: "series-63963de3f2a0f" }, { name: "其他欧美影片", code: "series-6396404e6bdb5" }, { name: "无关情色", code: "series-66643478ceedd" }
];

let STATE = { isRunning: false, stopSignal: false, logs: [], totalScraped: 0 };

function log(msg, type = 'info') {
    STATE.logs.push({ time: new Date().toLocaleTimeString(), msg, type });
    if (STATE.logs.length > 200) STATE.logs.shift();
    console.log(`[Scraper-xChina] ${msg}`);
}

function cleanMagnet(magnet) {
    if (!magnet) return '';
    const match = magnet.match(/magnet:\?xt=urn:btih:([a-zA-Z0-9]+)/i);
    if (match) return `magnet:?xt=urn:btih:${match[1]}`;
    return magnet.split('&')[0];
}

function getFlareUrl() {
    let url = global.CONFIG.flaresolverrUrl || 'http://flaresolverr:8191';
    if (url.endsWith('/')) url = url.slice(0, -1);
    if (!url.endsWith('/v1')) url += '/v1';
    return url;
}

async function processVideoTask(task, baseUrl, autoDownload) {
    const { link } = task; 
    
    const flareApi = getFlareUrl();
    let htmlContent = "";
    try {
        const payload = { cmd: 'request.get', url: link, maxTimeout: 60000 };
        if (global.CONFIG.proxy) payload.proxy = { url: global.CONFIG.proxy };
        const res = await axios.post(flareApi, payload, { headers: { 'Content-Type': 'application/json' } });
        if (res.data.status === 'ok') htmlContent = res.data.solution.response;
        else throw new Error(res.data.message);
    } catch(e) { throw new Error(`Req Err: ${e.message}`); }

    const $ = cheerio.load(htmlContent);
    let title = $('h1').text().trim() || task.title;
    let image = $('.vjs-poster img').attr('src') || $('video').attr('poster');
    if (image && !image.startsWith('http')) image = baseUrl + image;

    const actor = $('.model-container .model-item').text().trim() || '未知演员';
    let category = '未分类';
    $('.text').each((i, el) => { if ($(el).find('.joiner').length > 0) category = $(el).find('a').last().text().trim(); });

    let code = '';
    const codeMatch = link.match(/id-([a-zA-Z0-9]+)/);
    if (codeMatch) code = codeMatch[1];

    let magnet = '';
    try {
        const downloadLinkEl = $('a[href*="/download/id-"]');
        if (downloadLinkEl.length > 0) {
            let downloadPageUrl = downloadLinkEl.attr('href');
            if (downloadPageUrl && !downloadPageUrl.startsWith('http')) downloadPageUrl = baseUrl + downloadPageUrl;
            
            const dlPayload = { cmd: 'request.get', url: downloadPageUrl, maxTimeout: 30000 };
            if (global.CONFIG.proxy) dlPayload.proxy = { url: global.CONFIG.proxy };
            const dlRes = await axios.post(flareApi, dlPayload);
            if (dlRes.data.status === 'ok') {
                const $d = cheerio.load(dlRes.data.solution.response);
                const rawMagnet = $d('a.btn.magnet').attr('href');
                if (rawMagnet) magnet = cleanMagnet(rawMagnet);
            }
        }
    } catch (e) {}

    // 只入库磁力
    if (magnet) {
        const saveRes = await ResourceMgr.save({
            title, link, magnets: magnet, code, image, actor, category
        });

        if (saveRes.success) {
            if (saveRes.newInsert) {
                STATE.totalScraped++;
                let extraMsg = "";
                if (autoDownload) {
                    const pushRes = await Login115.addTask(magnet);
                    if (pushRes) { extraMsg = " | 📥 推送成功"; await ResourceMgr.markAsPushedByLink(link); }
                    else extraMsg = " | ⚠️ 推送失败";
                }
                log(`✅ [入库${extraMsg}] ${title.substring(0, 10)}...`, 'success');
                return true;
            } else {
                log(`⏭️ [已存在] ${title.substring(0, 10)}...`, 'info');
                return true;
            }
        }
    }
    return false;
}

async function scrapeCategory(cat, baseUrl, limitPages, autoDownload) {
    let page = 1;
    log(`📂 正在采集: [${cat.name}]`, 'info');
    while (page <= limitPages && !STATE.stopSignal) {
        const listUrl = page === 1 ? `${baseUrl}/videos/${cat.code}.html` : `${baseUrl}/videos/${cat.code}/${page}.html`;
        try {
            const flareApi = getFlareUrl();
            const payload = { cmd: 'request.get', url: listUrl, maxTimeout: 60000 };
            if (global.CONFIG.proxy) payload.proxy = { url: global.CONFIG.proxy };
            let res;
            try { res = await axios.post(flareApi, payload, { headers: { 'Content-Type': 'application/json' } }); } catch(e) { throw new Error(`Req Err: ${e.message}`); }
            if (res.data.status !== 'ok') { log(`⚠️ 访问列表页失败: ${res.data.message}`, 'error'); break; }

            const $ = cheerio.load(res.data.solution.response);
            const items = $('.item.video');
            if (items.length === 0) { log(`⚠️ 第 ${page} 页无内容`, 'warn'); break; }

            const tasks = [];
            items.each((i, el) => {
                const title = $(el).find('.text .title a').text().trim();
                let subLink = $(el).find('.text .title a').attr('href');
                if (title && subLink) {
                    if (!subLink.startsWith('http')) subLink = baseUrl + subLink;
                    tasks.push({ title, link: subLink });
                }
            });

            log(`📡 [${cat.name}] 第 ${page}/${limitPages} 页: ${tasks.length} 个视频`);

            for (let i = 0; i < tasks.length; i += CONCURRENCY_LIMIT) {
                if (STATE.stopSignal) break;
                const chunk = tasks.slice(i, i + CONCURRENCY_LIMIT);
                await Promise.all(chunk.map(async (task) => {
                    for(let k=0; k<MAX_RETRIES; k++){
                        try { return await processVideoTask(task, baseUrl, autoDownload); }
                        catch(e){ if(k===MAX_RETRIES-1) log(`❌ ${task.title.substring(0,10)} 失败: ${e.message}`, 'error'); }
                        await new Promise(r=>setTimeout(r, 1500));
                    }
                }));
                await new Promise(r => setTimeout(r, 500)); 
            }
            page++;
            await new Promise(r => setTimeout(r, 1500));
        } catch (pageErr) { log(`❌ 翻页失败: ${pageErr.message}`, 'error'); break; }
    }
}

const ScraperXChina = {
    getState: () => STATE,
    stop: () => { STATE.stopSignal = true; log('🛑 停止中...', 'warn'); },
    clearLogs: () => { STATE.logs = []; },
    start: async (mode = 'inc', autoDownload = false, selectedCodes = []) => {
        if (STATE.isRunning) return;
        STATE.isRunning = true;
        STATE.stopSignal = false;
        STATE.totalScraped = 0;
        const limitPages = mode === 'full' ? 5000 : 50;
        const baseUrl = "https://xchina.co";
        try {
            let targetCategories = FULL_CATS;
            if (selectedCodes && selectedCodes.length > 0) targetCategories = FULL_CATS.filter(c => selectedCodes.includes(c.code));
            for (let i = 0; i < targetCategories.length; i++) {
                if (STATE.stopSignal) break;
                await scrapeCategory(targetCategories[i], baseUrl, limitPages, autoDownload);
                if (i < targetCategories.length - 1) await new Promise(r => setTimeout(r, 5000));
            }
        } catch (err) { log(`🔥 全局异常: ${err.message}`, 'error'); }
        STATE.isRunning = false;
        log(`🏁 任务结束`, 'warn');
    },
    getCategories: () => FULL_CATS
};
module.exports = ScraperXChina;
EOF

# 7. 📝 升级原有 Scraper (modules/scraper.js)
echo "📝 升级旧版采集器..."
cat > modules/scraper.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const { HttpsProxyAgent } = require('https-proxy-agent');
const ResourceMgr = require('./resource_mgr');
const Login115 = require('./login_115');

let STATE = { isRunning: false, stopSignal: false, logs: [], totalScraped: 0 };
function log(msg, type='info') {
    STATE.logs.push({ time: new Date().toLocaleTimeString(), msg, type });
    if (STATE.logs.length > 200) STATE.logs.shift();
    console.log(`[Scraper] ${msg}`);
}
function getRequest() {
    const options = {
        headers: { 'User-Agent': global.CONFIG.userAgent, 'Referer': 'https://madouqu.com/' },
        timeout: 20000
    };
    if (global.CONFIG.proxy && global.CONFIG.proxy.startsWith('http')) {
        const agent = new HttpsProxyAgent(global.CONFIG.proxy);
        options.httpAgent = agent;
        options.httpsAgent = agent;
    }
    return axios.create(options);
}

const Scraper = {
    getState: () => STATE,
    stop: () => { STATE.stopSignal = true; },
    clearLogs: () => { STATE.logs = []; },
    start: async (limitPages = 5, source = "手动", autoDownload = false) => {
        if (STATE.isRunning) return;
        STATE.isRunning = true;
        STATE.stopSignal = false;
        STATE.totalScraped = 0;
        log(`任务启动 (Madou) | 自动下载: ${autoDownload ? '✅' : '❌'}`, 'success');
        const request = getRequest();
        let page = 1;
        let url = "https://madouqu.com/";
        try {
            while (page <= limitPages && !STATE.stopSignal) {
                log(`📄 抓取第 ${page} 页...`, 'info');
                try {
                    const res = await request.get(url);
                    const $ = cheerio.load(res.data);
                    const posts = $('article h2.entry-title a, h2.entry-title a');
                    if (posts.length === 0) { log(`⚠️ 无内容`, 'warn'); break; }
                    
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
                                const savedRes = await ResourceMgr.save({
                                    title, link, magnets, code: link, category: 'Madou'
                                });
                                
                                if(savedRes && savedRes.success) {
                                    if (savedRes.newInsert) {
                                        STATE.totalScraped++;
                                        let extraMsg = "";
                                        if (autoDownload && match[0]) {
                                            const pushRes = await Login115.addTask(match[0]);
                                            if (pushRes) { extraMsg = " | 📥 推送成功"; await ResourceMgr.markAsPushedByLink(link); }
                                            else { extraMsg = " | ⚠️ 推送失败"; }
                                        }
                                        log(`✅ [入库${extraMsg}] ${title.substring(0, 15)}...`, 'success');
                                    } else {
                                        log(`⏭️ [已存在] ${title.substring(0, 15)}...`, 'info');
                                    }
                                }
                            }
                        } catch (e) { log(`❌ 详情页失败: ${e.message}`, 'error'); }
                        await new Promise(r => setTimeout(r, 1000));
                    }
                    const next = $('a.next').attr('href');
                    if (next) { url = next; page++; await new Promise(r => setTimeout(r, 2000)); } else { break; }
                } catch (pageErr) { log(`❌ 页错误: ${pageErr.message}`, 'error'); break; }
            }
        } catch (err) { log(`异常: ${err.message}`, 'error'); }
        STATE.isRunning = false;
        log(`🏁 任务结束`, 'warn');
    }
};
module.exports = Scraper;
EOF

# 8. 📝 重写 API 路由 (routes/api.js)
echo "📝 更新后端路由..."
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
router.get('/115/qr', async (req, res) => {
    try { const data = await Login115.getQrCode(); res.json({ success: true, data }); } catch(e) { res.json({ success: false, msg: e.message }); }
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

router.post('/push', async (req, res) => {
    const ids = req.body.ids || [];
    const autoOrganize = req.body.organize === true;
    if (ids.length === 0) return res.json({ success: false, msg: "未选择任务" });
    
    let successCount = 0;
    try {
        const items = await ResourceMgr.getByIds(ids);
        for (const item of items) {
            if (!global.CONFIG.cookie115) continue;
            let magnet = item.magnets || '';
            const pushed = await Login115.addTask(magnet);
            if (pushed) {
                successCount++;
                await ResourceMgr.markAsPushed(item.id);
                // 这里调用 Renamer 的 addTask 如果有的话，或者 Renamer 自行扫描
                // 13.6 的 Renamer 是扫描式，所以不需要 addTask，只需推送到 115 即可
            }
            await new Promise(r => setTimeout(r, 200));
        }
        res.json({ success: true, count: successCount, msg: autoOrganize ? "已推送 (请手动启动整理)" : "推送完成" });
    } catch (e) { res.json({ success: false, msg: e.message }); }
});

// 复用 Renamer 启动接口
router.post('/renamer/start', (req, res) => {
    const pages = parseInt(req.body.pages) || 0;
    const force = req.body.force === true;
    Renamer.start(pages, force);
    res.json({ success: true });
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
        const type = req.query.type || 'all';
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
    res.json({ success: false, msg: "系统已锁定在稳定版 V13.14.2" });
});
module.exports = router;
EOF

# 9. 📝 重构入口 app.js (适配 SQLite)
echo "📝 重构入口 app.js..."
cat > app.js << 'EOF'
const express = require('express');
const cors = require('cors');
const cookieParser = require('cookie-parser');
const path = require('path');
const fs = require('fs');
const schedule = require('node-schedule');
const apiRoutes = require('./routes/api');
const Scraper = require('./modules/scraper');
const Renamer = require('./modules/renamer');
// 引入 ResourceMgr 触发数据库初始化
require('./modules/resource_mgr'); 

const app = express();
const PORT = 6002;
const AUTH_PASSWORD = process.env.AUTH_PASSWORD || "admin888";

global.UPDATE_URL = "https://raw.githubusercontent.com/ghostlpz/mdqupdate/refs/heads/main/update.sh";
global.CURRENT_VERSION = "13.14.2";

const CONFIG_PATH = '/data/config.json';
global.CONFIG = {
    proxy: "",
    cookie115: "",
    userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    cronEnabled: false,
    flaresolverrUrl: "http://flaresolverr:8191/v1"
};

if (fs.existsSync(CONFIG_PATH)) {
    try {
        const saved = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
        global.CONFIG = { ...global.CONFIG, ...saved };
        console.log("✅ 配置文件已加载");
    } catch (e) { console.error("配置读取失败", e); }
}

global.saveConfig = () => {
    try {
        fs.writeFileSync(CONFIG_PATH, JSON.stringify(global.CONFIG, null, 2));
    } catch (e) { console.error("配置保存失败", e); }
};

app.use(cors());
app.use(express.json());
app.use(cookieParser());
app.use(express.static(path.join(__dirname, 'public')));

app.use('/api', (req, res, next) => {
    if (req.path === '/login' || req.path === '/check-auth') {
        return next();
    }
    const clientToken = req.headers['authorization'];
    if (clientToken === AUTH_PASSWORD) {
        next();
    } else {
        res.status(401).json({ error: '请重新登录' });
    }
});

app.use('/api', apiRoutes);

// 定时任务
schedule.scheduleJob('0 0 2 * * *', () => {
    if (global.CONFIG.cronEnabled) {
        console.log('⏰ 定时任务触发: 采集');
        Scraper.start(100, "定时任务", true);
    }
});

(async () => {
    app.listen(PORT, '0.0.0.0', () => {
        console.log(`🚀 Madou Omni V${global.CURRENT_VERSION} 启动成功`);
        console.log(`📡 监听地址: http://0.0.0.0:${PORT}`);
    });
})();
EOF

# 10. 📝 更新前端 UI (public/index.html)
echo "📝 更新前端页面..."
cat > public/index.html << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Madou Omni - V13.14.2</title>
    <link rel="stylesheet" href="css/style.css">
</head>
<body>
    <div id="login-overlay">
        <div class="login-box">
            <h2>Madou Omni V13</h2>
            <input type="password" id="auth-pass" placeholder="输入访问密码...">
            <button onclick="login()">解锁系统</button>
        </div>
    </div>
    <div class="container">
        <header>
            <div class="logo">🚀 Madou Omni <span id="version-tag">V13.14.2</span></div>
            <nav>
                <button class="nav-btn active" onclick="switchTab('dashboard')">📊 仪表盘</button>
                <button class="nav-btn" onclick="switchTab('resources')">💾 资源库</button>
                <button class="nav-btn" onclick="switchTab('settings')">⚙️ 系统设置</button>
            </nav>
        </header>

        <div id="tab-dashboard" class="tab-content active">
            <div class="card">
                <h3>🕹️ 采集控制</h3>
                <div class="control-panel">
                    <div class="source-select">
                        <label>数据源：</label>
                        <select id="scrape-source" onchange="toggleCategories()">
                            <option value="madou">Madou (官方源)</option>
                            <option value="xchina" selected>小黄书 (xChina)</option>
                        </select>
                    </div>
                    
                    <div id="cat-select-area" class="cat-area" style="display:none;">
                        <div class="cat-header">
                            <span>选择分类 (多选)</span>
                            <button class="btn-mini" onclick="selectAllCats()">全选</button>
                        </div>
                        <div id="cat-checkboxes" class="cat-grid"></div>
                    </div>

                    <div class="actions">
                        <select id="scrape-type">
                            <option value="inc">增量采集 (前50页)</option>
                            <option value="full">全量采集 (所有页面)</option>
                        </select>
                        <label class="checkbox-label">
                            <input type="checkbox" id="auto-download"> 自动推送到 115
                        </label>
                        <button id="btn-start" class="btn-primary" onclick="startScrape()">🚀 开始采集</button>
                        <button id="btn-stop" class="btn-danger" onclick="stopScrape()">🛑 停止</button>
                    </div>
                </div>
                <div class="status-bar">
                    <div class="status-item">状态: <span id="status-text" class="idle">空闲</span></div>
                    <div class="status-item">已采集: <span id="scraped-count">0</span></div>
                </div>
                <div class="console-box" id="console-log"></div>
            </div>

            <div class="card">
                <h3>📁 整理队列 (115)</h3>
                <div class="input-group" style="display:flex; gap:10px; margin-bottom:10px;">
                    <input id="r-pages" placeholder="扫描页数 (0=全部)" style="width:120px">
                    <label style="display:flex;align-items:center"><input type="checkbox" id="r-force"> 强制模式</label>
                    <button onclick="startRenamer()" class="btn-primary">开始整理</button>
                </div>
                <div class="console-box" id="org-log" style="height: 150px;"></div>
            </div>
        </div>

        <div id="tab-resources" class="tab-content">
            <div class="filter-bar">
                <select id="filter-pushed" onchange="loadData(1)">
                    <option value="">全部推送状态</option>
                    <option value="0">未推送</option>
                    <option value="1">已推送</option>
                </select>
                <button onclick="loadData(1)">🔄 刷新</button>
                <button onclick="batchPush()">☁️ 推送选中到 115</button>
                <button onclick="batchDelete()" class="btn-danger">🗑️ 删除选中</button>
                <button onclick="exportCsv()">📤 导出 CSV</button>
            </div>
            <table class="data-table">
                <thead>
                    <tr>
                        <th width="30"><input type="checkbox" onchange="toggleAll(this)"></th>
                        <th width="80">ID</th>
                        <th>标题</th>
                        <th width="100">演员</th>
                        <th width="80">状态</th>
                        <th width="150">时间</th>
                    </tr>
                </thead>
                <tbody id="data-list"></tbody>
            </table>
            <div class="pagination">
                <button onclick="prevPage()">上一页</button>
                <span id="page-info">1 / 1</span>
                <button onclick="nextPage()">下一页</button>
            </div>
        </div>

        <div id="tab-settings" class="tab-content">
            <div class="card">
                <h3>🌐 网络设置</h3>
                <div class="input-group">
                    <label>HTTP 代理</label>
                    <input id="cfg-proxy" placeholder="http://127.0.0.1:7890">
                </div>
                <div class="input-group">
                    <label>FlareSolverr 地址 (必填)</label>
                    <input id="cfg-flare" placeholder="http://flaresolverr:8191">
                    <div class="desc">用于 xChina 采集，必须部署 flaresolverr 容器</div>
                </div>
            </div>
            <div class="card">
                <h3>☁️ 115 网盘设置</h3>
                <div class="input-group">
                    <label>115 网盘网页版 Cookie</label>
                    <textarea id="cfg-cookie" rows="3" placeholder="UID=...; CID=...; SEID=..."></textarea>
                </div>
                <div class="actions">
                    <button onclick="check115()">📲 扫码登录 115</button>
                </div>
                <div id="qr-area" style="margin-top:15px; text-align:center; display:none;">
                    <div id="qr-code"></div>
                    <p>请使用 115 App 扫码</p>
                </div>
            </div>
            <div class="card">
                <h3>🛠️ 系统维护</h3>
                <button onclick="saveCfg()" class="btn-primary">💾 保存配置</button>
            </div>
        </div>
    </div>
    <script src="js/app.js"></script>
</body>
</html>
EOF

# 11. 📝 更新前端 JS (public/js/app.js)
echo "📝 更新前端脚本..."
cat > public/js/app.js << 'EOF'
let currentPage = 1;
let currentTab = 'dashboard';
let categories = []; 

document.addEventListener('DOMContentLoaded', () => {
    checkAuth();
    loadCategories();
    setInterval(updateStatus, 2000);
});

async function request(endpoint, options = {}) {
    const token = localStorage.getItem('token');
    const headers = { 'Content-Type': 'application/json' };
    if (token) headers['Authorization'] = token;
    try {
        const res = await fetch('/api/' + endpoint, { ...options, headers: { ...headers, ...options.headers } });
        if (res.status === 401) {
            document.getElementById('login-overlay').style.display = 'flex';
            return { success: false, error: 'Unauthorized' };
        }
        return await res.json();
    } catch (e) { console.error(e); return { success: false, error: e.message }; }
}

function login() {
    const pass = document.getElementById('auth-pass').value;
    if(pass) {
        localStorage.setItem('token', pass);
        document.getElementById('login-overlay').style.display = 'none';
        checkAuth();
    }
}

async function checkAuth() {
    const res = await request('check-auth');
    if (res.authenticated) document.getElementById('login-overlay').style.display = 'none';
}

function switchTab(tab) {
    currentTab = tab;
    document.querySelectorAll('.tab-content').forEach(el => el.classList.remove('active'));
    document.getElementById('tab-' + tab).classList.add('active');
    document.querySelectorAll('.nav-btn').forEach(el => el.classList.remove('active'));
    event.target.classList.add('active');
    if (tab === 'resources') loadData(1);
    if (tab === 'settings') loadSettings();
}

async function loadSettings() {
    const res = await request('status');
    if (res.config) {
        document.getElementById('cfg-proxy').value = res.config.proxy || '';
        document.getElementById('cfg-cookie').value = res.config.cookie115 || '';
        document.getElementById('cfg-flare').value = res.config.flaresolverrUrl || '';
    }
}

async function saveCfg() {
    const body = {
        proxy: document.getElementById('cfg-proxy').value,
        cookie115: document.getElementById('cfg-cookie').value,
        flaresolverrUrl: document.getElementById('cfg-flare').value
    };
    await request('config', { method: 'POST', body: JSON.stringify(body) });
    alert('配置已保存');
}

async function loadCategories() {
    const res = await request('categories');
    if (res.categories) {
        categories = res.categories;
        const grid = document.getElementById('cat-checkboxes');
        grid.innerHTML = categories.map(c => 
            `<label><input type="checkbox" value="${c.code}" checked> ${c.name}</label>`
        ).join('');
    }
}

function toggleCategories() {
    const source = document.getElementById('scrape-source').value;
    const catArea = document.getElementById('cat-select-area');
    catArea.style.display = (source === 'xchina') ? 'block' : 'none';
}

function selectAllCats() {
    document.querySelectorAll('#cat-checkboxes input').forEach(cb => cb.checked = true);
}

async function startScrape() {
    const source = document.getElementById('scrape-source').value;
    const type = document.getElementById('scrape-type').value;
    const autoDl = document.getElementById('auto-download').checked;
    
    let cats = [];
    if (source === 'xchina') {
        document.querySelectorAll('#cat-checkboxes input:checked').forEach(cb => cats.push(cb.value));
        if (cats.length === 0) return alert('请至少选择一个分类');
    }

    await request('start', { method: 'POST', body: JSON.stringify({ type, source, autoDownload: autoDl, categories: cats }) });
    alert('采集任务已启动');
}

async function stopScrape() {
    await request('stop', { method: 'POST' });
}

async function startRenamer() {
    const p = document.getElementById('r-pages').value;
    const f = document.getElementById('r-force').checked;
    await request('renamer/start', { method: 'POST', body: JSON.stringify({ pages: p, force: f }) });
    alert('整理任务已启动');
}

async function updateStatus() {
    const res = await request('status');
    if (!res.state) return;
    
    const statusEl = document.getElementById('status-text');
    statusEl.innerText = res.state.isRunning ? "🟢 运行中" : "⚪ 空闲";
    statusEl.className = res.state.isRunning ? "running" : "idle";
    document.getElementById('scraped-count').innerText = res.state.totalScraped;
    
    const logBox = document.getElementById('console-log');
    logBox.innerHTML = res.state.logs.map(l => `<div class="${l.type}">[${l.time}] ${l.msg}</div>`).join('');
    logBox.scrollTop = logBox.scrollHeight;

    const orgLog = document.getElementById('org-log');
    orgLog.innerHTML = res.renamerState.logs.map(l => `<div>[${l.time}] ${l.msg}</div>`).join('');
    orgLog.scrollTop = orgLog.scrollHeight;
}

async function loadData(page) {
    currentPage = page;
    const pushed = document.getElementById('filter-pushed').value;
    const res = await request(`data?page=${page}&pushed=${pushed}`);
    const list = document.getElementById('data-list');
    list.innerHTML = res.data.map(item => `
        <tr>
            <td><input type="checkbox" class="row-chk" value="${item.id}"></td>
            <td>${item.id}</td>
            <td>${item.title}</td>
            <td>${item.actor || '-'}</td>
            <td>
                ${item.pushed ? '<span class="tag tag-success">已推</span>' : '<span class="tag tag-warn">未推</span>'}
                ${item.renamed ? '<span class="tag tag-info">已整</span>' : ''}
            </td>
            <td>${new Date(item.created_at).toLocaleString()}</td>
        </tr>
    `).join('');
    document.getElementById('page-info').innerText = `${res.page} / ${Math.ceil(res.total / 100) || 1}`;
}

function prevPage() { if (currentPage > 1) loadData(currentPage - 1); }
function nextPage() { loadData(currentPage + 1); }

function toggleAll(source) {
    document.querySelectorAll('.row-chk').forEach(cb => cb.checked = source.checked);
}

async function batchPush() {
    const ids = Array.from(document.querySelectorAll('.row-chk:checked')).map(cb => cb.value);
    if (ids.length === 0) return alert('请选择条目');
    await request('push', { method: 'POST', body: JSON.stringify({ ids, organize: true }) });
    alert('已加入推送队列');
}

async function batchDelete() {
    const ids = Array.from(document.querySelectorAll('.row-chk:checked')).map(cb => cb.value);
    if (ids.length === 0) return alert('请选择条目');
    if (!confirm('确定删除选中项？')) return;
    await request('delete', { method: 'POST', body: JSON.stringify({ ids }) });
    loadData(currentPage);
}

async function exportCsv() {
    window.open('/api/export?type=all');
}

async function check115() {
    const qrArea = document.getElementById('qr-area');
    qrArea.style.display = 'block';
    const res = await request('115/qr');
    if (res.success) {
        document.getElementById('qr-code').innerHTML = `<img src="${res.data.qr_url}">`;
        checkLoginLoop(res.data);
    }
}

async function checkLoginLoop(data) {
    const { uid, time, sign } = data;
    const timer = setInterval(async () => {
        const res = await request(`115/check?uid=${uid}&time=${time}&sign=${sign}`);
        if (res.success) {
            clearInterval(timer);
            document.getElementById('cfg-cookie').value = res.cookie;
            alert('登录成功！');
            document.getElementById('qr-area').style.display = 'none';
        }
    }, 2000);
}
EOF

# 12. 🚀 安装并重启
echo "🚀 正在安装 sqlite3 依赖..."
npm install

echo "🔄 重启应用..."
pkill -f "node app.js"

echo "✅ [完成] V13.6 -> V13.14.2 完美重构升级完毕！"
