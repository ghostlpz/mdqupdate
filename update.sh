#!/bin/bash
# VERSION = 13.17.0
# =================================================================
# Madou Omni Safe Update Script
# Target Version: v13.17.0
# Description: Patch existing files to add M3U8 Pro, Deprecate PikPak
# Mode: Non-destructive (Appends/Edits instead of Overwriting)
# =================================================================

APP_DIR="/app"
BACKUP_DIR="/app/backup_v13.17.0"
DATE=$(date +%Y%m%d_%H%M%S)

echo "🔄 [1/6] Starting Safe Update to v13.17.0..."

# 1. 全量备份 (以防万一)
echo "📦 [2/6] Backing up all current files..."
mkdir -p $BACKUP_DIR
cp -r $APP_DIR/modules $BACKUP_DIR/
cp -r $APP_DIR/routes $BACKUP_DIR/
cp -r $APP_DIR/public $BACKUP_DIR/
echo "✅ Backup saved to $BACKUP_DIR"

# 2. 创建临时补丁脚本 (Patch Script)
# 这个 Node.js 脚本会读取您的旧文件，智能修改，保留原有逻辑
echo "🛠️ [3/6] Applying Code Patches (Smart Edit)..."
cat << 'EOF' > $APP_DIR/patch_manager.js
const fs = require('fs');
const path = require('path');

const API_FILE = path.join(__dirname, 'routes/api.js');
const SCRAPER_FILE = path.join(__dirname, 'modules/scraper.js');

function log(msg) { console.log(`[Patch] ${msg}`); }

// --- 补丁 1: 修改 api.js ---
if (fs.existsSync(API_FILE)) {
    let content = fs.readFileSync(API_FILE, 'utf8');
    
    // 1.1 注释掉 PikPak 和 中间件(5005) 相关路由
    // 使用正则将包含 pikpak 或 :5005 的行加上 // 注释
    const lines = content.split('\n');
    let newLines = lines.map(line => {
        if ((line.match(/pikpak/i) || line.includes('5005')) && !line.trim().startsWith('//')) {
            return '// ' + line + ' (Deprecated v13.17)';
        }
        return line;
    });
    content = newLines.join('\n');

    // 1.2 追加 M3U8 Pro 接口 (如果尚未存在)
    if (!content.includes('/m3u8/task')) {
        const m3u8Logic = `
// ==========================================
// [Added v13.17.0] M3U8 Pro API Interfaces
// ==========================================
router.post('/m3u8/task', async (req, res) => {
    const { url, server_ip } = req.body;
    // 读取配置 (兼容旧版写法)
    let config = {};
    try { 
        config = JSON.parse(fs.readFileSync(path.join(__dirname, '../data/config.json'), 'utf8')); 
    } catch(e) {}

    const targetIp = server_ip || config.m3u8_server_ip;

    if (!targetIp || !url) return res.status(400).json({ success: false, msg: 'Missing IP or URL' });

    try {
        const targetApi = \`http://\${targetIp}:5003/api/add_task\`;
        console.log(\`Forwarding M3U8 task to: \${targetApi}\`);
        const response = await axios.post(targetApi, { url }, { timeout: 5000 });
        res.json({ success: true, remote_data: response.data });
    } catch (error) {
        console.error('M3U8 API Error:', error.message);
        res.status(502).json({ success: false, msg: 'Download Server Error', error: error.message });
    }
});

router.get('/m3u8/queue', async (req, res) => {
    let config = {};
    try { 
        config = JSON.parse(fs.readFileSync(path.join(__dirname, '../data/config.json'), 'utf8')); 
    } catch(e) {}
    
    if (!config.m3u8_server_ip) return res.json({ waiting_count: 0, msg: 'No Server IP' });

    try {
        const resp = await axios.get(\`http://\${config.m3u8_server_ip}:5003/api/queue_status\`, { timeout: 3000 });
        res.json(resp.data);
    } catch (e) {
        res.json({ waiting_count: -1 });
    }
});
// ==========================================
`;
        // 插入到 module.exports 之前
        if (content.includes('module.exports')) {
            content = content.replace('module.exports', m3u8Logic + '\nmodule.exports');
        } else {
            content += m3u8Logic;
        }
        log('Added M3U8 routes to api.js');
    }

    fs.writeFileSync(API_FILE, content);
    log('api.js patched successfully.');
}

// --- 补丁 2: 修改 scraper.js ---
if (fs.existsSync(SCRAPER_FILE)) {
    let content = fs.readFileSync(SCRAPER_FILE, 'utf8');
    
    // 2.1 同样注释掉 PikPak 和 5005 相关逻辑
    const lines = content.split('\n');
    let newLines = lines.map(line => {
        if ((line.match(/pikpak/i) || line.includes('5005')) && !line.trim().startsWith('//')) {
            return '// ' + line + ' (Deprecated v13.17)';
        }
        return line;
    });
    content = newLines.join('\n');
    
    fs.writeFileSync(SCRAPER_FILE, content);
    log('scraper.js patched (PikPak disabled).');
}
EOF

# 执行补丁脚本
node $APP_DIR/patch_manager.js
rm $APP_DIR/patch_manager.js

# 3. 更新前端文件 (UI需要适配新功能，直接替换较为安全，已备份旧版)
echo "🎨 [4/6] Updating Frontend UI..."

# index.html - 增加 M3U8 设置面板
cat << 'HtmlEOF' > $APP_DIR/public/index.html
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
            <div class="text-sm text-gray-500">v13.17.0 (Safe Update)</div>
        </header>

        <section class="mb-6 bg-white p-4 rounded shadow border-l-4 border-purple-500">
            <h2 class="text-lg font-bold mb-3"><i class="fas fa-film"></i> M3U8 下载服务 (New)</h2>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-4">
                <div>
                    <label class="block text-sm font-medium text-gray-700">下载服务器 IP</label>
                    <div class="flex mt-1">
                        <input type="text" id="serverIpInput" placeholder="例如 192.168.1.5" class="flex-1 p-2 border rounded-l">
                        <button onclick="saveSettings()" class="bg-gray-200 px-4 rounded-r hover:bg-gray-300">保存</button>
                    </div>
                </div>
                <div>
                    <label class="block text-sm font-medium text-gray-700">队列状态</label>
                    <div id="queueStatus" class="mt-2 text-gray-600"><i class="fas fa-sync fa-spin"></i> 连接中...</div>
                </div>
            </div>
            <div class="border-t pt-4">
                <label class="block text-sm font-medium text-gray-700">提交新任务</label>
                <div class="flex mt-1">
                    <input type="text" id="newTaskUrl" placeholder="输入 M3U8 或 网页 URL" class="flex-1 p-2 border rounded-l">
                    <button onclick="submitM3u8Task()" class="bg-purple-600 text-white px-6 py-2 rounded-r hover:bg-purple-700">
                        <i class="fas fa-cloud-download-alt"></i> 提交
                    </button>
                </div>
            </div>
        </section>

        <section class="bg-white p-4 rounded shadow">
            <h2 class="text-lg font-bold mb-3 border-b pb-2"><i class="fas fa-list"></i> 资源列表</h2>
            <div id="resourceList" class="space-y-2 text-sm">
                <div class="text-center text-gray-400">加载中...</div>
            </div>
        </section>
    </div>
    <script src="js/app.js"></script>
</body>
</html>
HtmlEOF

# app.js - 增加 M3U8 交互逻辑
cat << 'JsEOF' > $APP_DIR/public/js/app.js
const API = '/api';

document.addEventListener('DOMContentLoaded', () => {
    loadSettings();
    loadResources();
    // 轮询队列状态
    setInterval(checkQueue, 5000);
});

// --- M3U8 逻辑 ---
async function loadSettings() {
    try {
        const res = await fetch(`${API}/settings`);
        const data = await res.json();
        if(data.data && data.data.m3u8_server_ip) {
            document.getElementById('serverIpInput').value = data.data.m3u8_server_ip;
            checkQueue();
        }
    } catch(e) { console.error(e); }
}

async function saveSettings() {
    const ip = document.getElementById('serverIpInput').value.trim();
    if(!ip) return alert('请输入 IP');
    try {
        await fetch(`${API}/settings`, {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({ m3u8_server_ip: ip })
        });
        alert('保存成功');
        checkQueue();
    } catch(e) { alert('保存失败'); }
}

async function checkQueue() {
    const el = document.getElementById('queueStatus');
    try {
        const res = await fetch(`${API}/m3u8/queue`);
        const data = await res.json();
        if (data.waiting_count !== undefined && data.waiting_count !== -1) {
            el.innerHTML = `<span class="text-green-600 font-bold">${data.waiting_count}</span> 任务排队中`;
        } else {
            el.innerHTML = '<span class="text-red-400">服务离线或未配置</span>';
        }
    } catch { el.innerHTML = '连接错误'; }
}

async function submitM3u8Task() {
    const url = document.getElementById('newTaskUrl').value.trim();
    const ip = document.getElementById('serverIpInput').value.trim();
    if(!url || !ip) return alert('请填写 URL 和 IP');

    try {
        const res = await fetch(`${API}/m3u8/task`, {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({ url, server_ip: ip })
        });
        const data = await res.json();
        if(data.success) {
            alert(`提交成功! ID: ${data.remote_data.id}`);
            document.getElementById('newTaskUrl').value = '';
            checkQueue();
        } else {
            alert('失败: ' + (data.msg || data.error));
        }
    } catch(e) { alert('提交请求失败'); }
}

// --- 原有资源列表逻辑 (保留) ---
async function loadResources() {
    const list = document.getElementById('resourceList');
    try {
        const res = await fetch(`${API}/resources`);
        const json = await res.json();
        if (!json.success) return;
        
        list.innerHTML = json.data.map(i => `
            <div class="flex justify-between items-center p-2 bg-gray-50 border rounded hover:bg-gray-100">
                <div class="truncate w-3/4">
                    <div class="font-medium">${i.title}</div>
                    <div class="text-xs text-gray-400">${new Date(i.created_at).toLocaleString()}</div>
                </div>
                <span class="text-xs px-2 py-1 rounded ${i.status === 'completed' ? 'bg-green-100 text-green-800' : 'bg-yellow-100 text-yellow-800'}">
                    ${i.status}
                </span>
            </div>
        `).join('');
    } catch (e) { list.innerHTML = '加载资源失败'; }
}
JsEOF

# 4. 更新版本号
echo "📝 [5/6] Updating Package Version to 13.17.0..."
sed -i 's/"version": ".*"/"version": "13.17.0"/' $APP_DIR/package.json

echo "✅ [6/6] Update Complete! Please restart the container manually if needed."
# 触发 Docker 重启 (可选)
# kill 1
