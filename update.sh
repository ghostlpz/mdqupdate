#!/bin/bash
# VERSION = 13.17.0
# =================================================================
# Madou Omni Update Script
# Target Version: v13.17.0
# Description: Deprecate PikPak & Middleware, Add M3U8 Pro Support
# =================================================================

APP_DIR="/app"
BACKUP_DIR="/app/backup_v13.17.0"
DATE=$(date +%Y%m%d_%H%M%S)

echo "🔄 [1/6] Starting Update to v13.17.0..."

# 1. 备份关键文件
echo "📦 [2/6] Backing up current files..."
mkdir -p $BACKUP_DIR
[ -f "$APP_DIR/modules/scraper.js" ] && cp "$APP_DIR/modules/scraper.js" "$BACKUP_DIR/scraper.js.$DATE.bak"
[ -f "$APP_DIR/routes/api.js" ] && cp "$APP_DIR/routes/api.js" "$BACKUP_DIR/api.js.$DATE.bak"
[ -f "$APP_DIR/public/index.html" ] && cp "$APP_DIR/public/index.html" "$BACKUP_DIR/index.html.$DATE.bak"
[ -f "$APP_DIR/public/js/app.js" ] && cp "$APP_DIR/public/js/app.js" "$BACKUP_DIR/app.js.$DATE.bak"

# 2. 更新 scraper.js (只保留磁力链 & 115)
echo "🛠️ [3/6] Refactoring Scraper (Removing PikPak)..."
cat << 'EOF' > $APP_DIR/modules/scraper.js
const axios = require('axios');
const cheerio = require('cheerio');
const db = require('./db');
const login115 = require('./login_115');
const fs = require('fs');
const path = require('path');

// 日志辅助
const log = (msg, type = 'info') => {
    console.log(`[${type.toUpperCase()}] ${new Date().toLocaleString()} - ${msg}`);
};

/**
 * 核心采集逻辑 - 仅处理磁力链接 (Magnet Only)
 */
async function scrapePage(pageUrl) {
    try {
        log(`Scraping: ${pageUrl}`);
        
        // 1. 请求页面
        const response = await axios.get(pageUrl, {
            headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36' },
            timeout: 15000
        });

        const $ = cheerio.load(response.data);
        const title = $('h1').first().text().trim() || $('title').text().trim();
        
        // 2. 提取磁力链
        let magnet = '';
        $('a').each((i, el) => {
            const href = $(el).attr('href');
            if (href && href.startsWith('magnet:?')) {
                magnet = href;
                return false; // 取第一个
            }
        });

        if (!magnet) {
            log(`No magnet found for: ${title}. Skipping.`, 'warn');
            return { success: false, msg: 'No magnet link' };
        }

        // 3. 查重
        const exists = await db.query('SELECT id FROM resources WHERE magnet = ?', [magnet]);
        if (exists.length > 0) {
            log(`Duplicate: ${title}`, 'info');
            return { success: true, msg: 'Already exists' };
        }

        // 4. 入库
        await db.query('INSERT INTO resources (title, magnet, created_at, status) VALUES (?, ?, NOW(), ?)', [title, magnet, 'pending']);
        log(`Saved to DB: ${title}`, 'success');

        // 5. 推送 115 (如果开启)
        const configPath = path.join(__dirname, '../data/config.json');
        if (fs.existsSync(configPath)) {
            const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
            if (config.enable_115) {
                try {
                    await login115.addOfflineTask(magnet);
                    log(`Pushed to 115: ${title}`, 'success');
                } catch (e) {
                    log(`115 Push Failed: ${e.message}`, 'error');
                }
            }
        }

        return { success: true, title };

    } catch (error) {
        log(`Error: ${error.message}`, 'error');
        return { success: false, error: error.message };
    }
}

// 保持接口兼容性
async function runScraper() {
    log('Starting Scraper Cycle (Magnet Only)...');
    // 实际调度逻辑保留在 app.js 或外部调用
}

module.exports = { scrapePage, runScraper };
EOF

# 3. 更新 api.js (对接 M3U8 Pro, 移除 PikPak, 保留 Update)
echo "🔗 [4/6] Updating API Routes..."
cat << 'EOF' > $APP_DIR/routes/api.js
const express = require('express');
const router = express.Router();
const fs = require('fs');
const path = require('path');
const axios = require('axios');
const { exec } = require('child_process');
const db = require('../modules/db');

const CONFIG_PATH = path.join(__dirname, '../data/config.json');

// --- Helper Functions ---
function getConfig() {
    if (!fs.existsSync(CONFIG_PATH)) return {};
    return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
}

function saveConfig(newConfig) {
    const current = getConfig();
    const updated = { ...current, ...newConfig };
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(updated, null, 2));
    return updated;
}

// --- M3U8 Pro Routes (New) ---

// 1. 提交任务
router.post('/m3u8/task', async (req, res) => {
    const { url, server_ip } = req.body;
    const config = getConfig();
    const targetIp = server_ip || config.m3u8_server_ip;

    if (!targetIp || !url) return res.status(400).json({ success: false, msg: 'Missing IP or URL' });

    try {
        const targetApi = `http://${targetIp}:5003/api/add_task`;
        const response = await axios.post(targetApi, { url }, { timeout: 5000 });
        res.json({ success: true, remote_data: response.data });
    } catch (error) {
        res.status(502).json({ success: false, msg: 'Download Server Error', error: error.message });
    }
});

// 2. 获取队列
router.get('/m3u8/queue', async (req, res) => {
    const config = getConfig();
    if (!config.m3u8_server_ip) return res.json({ waiting_count: 0, msg: 'No Server IP' });

    try {
        const resp = await axios.get(`http://${config.m3u8_server_ip}:5003/api/queue_status`, { timeout: 3000 });
        res.json(resp.data);
    } catch (e) {
        res.json({ waiting_count: -1 });
    }
});

// --- System Routes ---

router.get('/settings', (req, res) => {
    const config = getConfig();
    res.json({ success: true, data: { m3u8_server_ip: config.m3u8_server_ip, enable_115: config.enable_115 } });
});

router.post('/settings', (req, res) => {
    saveConfig(req.body);
    res.json({ success: true });
});

router.get('/resources', async (req, res) => {
    try {
        const rows = await db.query('SELECT * FROM resources ORDER BY id DESC LIMIT 50');
        res.json({ success: true, data: rows });
    } catch (e) { res.status(500).json({ success: false, msg: e.message }); }
});

// --- Update Logic (Preserved) ---
router.post('/update', async (req, res) => {
    // 保留此接口以允许未来的在线更新
    res.json({ success: true, msg: 'Update endpoint active.' });
});

module.exports = router;
EOF

# 4. 更新前端 (UI & Logic)
echo "🎨 [5/6] Updating Frontend..."

# index.html
cat << 'EOF' > $APP_DIR/public/index.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Madou Omni v13.17</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet">
</head>
<body class="bg-gray-100 text-gray-800">
    <div id="app" class="container mx-auto p-4 max-w-4xl">
        <header class="flex justify-between items-center mb-6 bg-white p-4 rounded shadow">
            <h1 class="text-2xl font-bold text-blue-600"><i class="fas fa-robot"></i> Madou Omni</h1>
            <div class="text-sm text-gray-500">v13.17.0 (M3U8 Pro)</div>
        </header>

        <section class="mb-6 bg-white p-4 rounded shadow border-l-4 border-purple-500">
            <h2 class="text-lg font-bold mb-3"><i class="fas fa-film"></i> M3U8 下载服务</h2>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-4">
                <div>
                    <label class="block text-sm font-medium text-gray-700">服务器 IP</label>
                    <div class="flex mt-1">
                        <input type="text" id="serverIpInput" placeholder="192.168.x.x" class="flex-1 p-2 border rounded-l">
                        <button onclick="saveSettings()" class="bg-gray-200 px-4 rounded-r hover:bg-gray-300">保存</button>
                    </div>
                </div>
                <div>
                    <label class="block text-sm font-medium text-gray-700">队列状态</label>
                    <div id="queueStatus" class="mt-2 text-gray-600">Checking...</div>
                </div>
            </div>
            <div class="border-t pt-4">
                <div class="flex mt-1">
                    <input type="text" id="newTaskUrl" placeholder="输入 M3U8/网页 URL" class="flex-1 p-2 border rounded-l">
                    <button onclick="submitM3u8Task()" class="bg-purple-600 text-white px-6 py-2 rounded-r hover:bg-purple-700">
                        <i class="fas fa-download"></i> 提交
                    </button>
                </div>
            </div>
        </section>

        <section class="bg-white p-4 rounded shadow">
            <h2 class="text-lg font-bold mb-3 border-b pb-2"><i class="fas fa-magnet"></i> 磁力链资源库</h2>
            <div id="resourceList" class="space-y-2 text-sm"></div>
        </section>
    </div>
    <script src="js/app.js"></script>
</body>
</html>
EOF

# app.js
cat << 'EOF' > $APP_DIR/public/js/app.js
const API = '/api';

document.addEventListener('DOMContentLoaded', () => {
    loadSettings();
    loadResources();
    setInterval(checkQueue, 5000);
});

async function loadSettings() {
    const res = await fetch(`${API}/settings`);
    const data = await res.json();
    if(data.data.m3u8_server_ip) {
        document.getElementById('serverIpInput').value = data.data.m3u8_server_ip;
        checkQueue();
    }
}

async function saveSettings() {
    const ip = document.getElementById('serverIpInput').value.trim();
    await fetch(`${API}/settings`, {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({ m3u8_server_ip: ip })
    });
    alert('保存成功');
    checkQueue();
}

async function checkQueue() {
    const el = document.getElementById('queueStatus');
    try {
        const res = await fetch(`${API}/m3u8/queue`);
        const data = await res.json();
        el.innerHTML = data.waiting_count >= 0 
            ? `<span class="text-green-600 font-bold">${data.waiting_count}</span> 任务排队中` 
            : '<span class="text-red-400">服务离线</span>';
    } catch { el.innerHTML = '连接失败'; }
}

async function submitM3u8Task() {
    const url = document.getElementById('newTaskUrl').value.trim();
    const ip = document.getElementById('serverIpInput').value.trim();
    if(!url || !ip) return alert('请检查 URL 和 IP');

    const res = await fetch(`${API}/m3u8/task`, {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({ url, server_ip: ip })
    });
    const data = await res.json();
    alert(data.success ? `提交成功! ID: ${data.remote_data.id}` : `失败: ${data.msg}`);
}

async function loadResources() {
    const res = await fetch(`${API}/resources`);
    const json = await res.json();
    document.getElementById('resourceList').innerHTML = json.data.map(i => 
        `<div class="flex justify-between p-2 bg-gray-50 border rounded">
            <span class="truncate w-3/4">${i.title}</span>
            <span class="text-xs px-2 py-1 bg-blue-100 rounded">${i.status}</span>
        </div>`
    ).join('');
}
EOF

# 5. 更新 Package.json 版本号
echo "📝 [6/6] Updating Version to 13.17.0..."
sed -i 's/"version": ".*"/"version": "13.17.0"/' $APP_DIR/package.json

echo "✅ Update Complete. Restarting Container..."
# 尝试退出进程让 Docker 自动重启
kill 1
