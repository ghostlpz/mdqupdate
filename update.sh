#!/bin/bash
# VERSION = 13.15.1

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.15.1
# 修复: PikPak 登录支持直接填入 Token (解决账号密码登录失败问题)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署 Token 直连版 (V13.15.1)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.15.1"/' package.json

# 2. 升级 LoginPikPak (支持 Token 识别)
echo "📝 [1/2] 升级 PikPak 驱动 (支持 Token)..."
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
        
        // 1. 设置账号/Token
        if (cfg.pikpak) {
            const val = cfg.pikpak.trim();
            if (val.includes('|')) {
                // 模式A: 账号|密码
                const parts = val.split('|');
                this.auth.username = parts[0].trim();
                this.auth.password = parts[1].trim();
                this.auth.token = ''; // 清空旧 Token，强制重登
            } else {
                // 模式B: 直接 Token
                // 自动补全 Bearer
                this.auth.token = val.startsWith('Bearer') ? val : 'Bearer ' + val;
                this.auth.username = '';
                this.auth.password = '';
            }
        }
        
        // 2. 设置代理
        if (cfg.proxy) this.proxy = cfg.proxy;
    },

    getAxiosConfig() {
        const config = {
            headers: {
                'Content-Type': 'application/json',
                'X-Device-Id': this.auth.deviceId,
                'Authorization': this.auth.token || ''
            },
            timeout: 10000
        };
        if (this.proxy) {
            config.httpsAgent = new HttpsProxyAgent(this.proxy);
            config.proxy = false;
        }
        return config;
    },

    async login() {
        // 如果已经有 Token (用户填写的)，直接验证有效性即可，视为登录成功
        if (this.auth.token && !this.auth.username) return true;
        
        // 否则尝试用账号密码换 Token
        if (!this.auth.username || !this.auth.password) return false;

        try {
            const url = 'https://user.mypikpak.com/v1/auth/signin';
            const payload = {
                client_id: "YNxT9w7GMvwD3",
                username: this.auth.username,
                password: this.auth.password
            };
            const config = { 
                headers: { 'Content-Type': 'application/json' },
                timeout: 10000
            };
            if (this.proxy) {
                config.httpsAgent = new HttpsProxyAgent(this.proxy);
                config.proxy = false;
            }

            const res = await axios.post(url, payload, config);
            if (res.data && res.data.access_token) {
                this.auth.token = 'Bearer ' + res.data.access_token;
                this.auth.userId = res.data.sub;
                console.log('✅ PikPak 登录成功 (账号模式)');
                return true;
            }
        } catch (e) {
            const msg = e.response ? `HTTP ${e.response.status}` : e.message;
            console.error(`❌ PikPak 登录失败 (${msg})`);
        }
        return false;
    },

    // 🧪 测试连接
    async testConnection() {
        // 尝试登录 (如果是 Token 模式，这里直接返回 true)
        const loginSuccess = await this.login();
        if (!loginSuccess && !this.auth.token) return { success: false, msg: "登录失败: 请检查账号密码或代理" };

        try {
            // 尝试列出文件来验证 Token 有效性
            const url = `https://api-drive.mypikpak.com/drive/v1/files?filters={"trashed":{"eq":false}}&limit=1`;
            await axios.get(url, this.getAxiosConfig());
            return { success: true, msg: "✅ PikPak 连接成功！(Token 有效)" };
        } catch (e) {
            if (e.response && e.response.status === 401) {
                return { success: false, msg: "❌ Token 已过期或无效，请重新提取" };
            }
            return { success: false, msg: `API 访问错误: ${e.message}` };
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
                name: fileName,
                folder_type: "DOWNLOAD"
            };
            
            if (parentId && parentId.trim() !== '') {
                payload.parent_id = parentId;
            }

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

# 3. 更新 UI (更新标签说明)
echo "📝 [2/2] 升级前端界面..."
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
                    <label>PikPak 账号 / Token</label>
                    <div style="display:flex;gap:10px">
                        <input id="cfg-pikpak" placeholder="账号|密码 或 Bearer Token" style="flex:1">
                        <button class="btn btn-info" onclick="checkPikPak()">🧪 测试连接</button>
                    </div>
                    <div class="desc">建议直接填入 Token (Bearer xxxx)，因为账号密码登录易受验证码拦截</div>
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

# 5. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.15.1 部署完成，请在设置页填入 Bearer Token 即可！"
