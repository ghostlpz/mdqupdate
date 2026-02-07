#!/bin/sh
# VERSION = 13.19.1
# Madou Omni - Cloud Auth with Proxy Support
# ---------------------------------------------------------
# 1. 后端: api.js (增加代理支持，读取 process.env.PROXY_URL)
# 2. 前端: index.html (登录遮罩)
# 3. 前端: app.js (拦截逻辑)
# ---------------------------------------------------------

set -e

echo "🚀 [Update] 开始升级 v13.19.1 (代理修复版)..."

# =========================================================
# 1. 备份
# =========================================================
echo "📦 [Backup] 备份核心文件..."
cp /app/routes/api.js /app/routes/api.js.bak.$(date +%s)
cp /app/public/js/app.js /app/public/js/app.js.bak.$(date +%s)
cp /app/public/index.html /app/public/index.html.bak.$(date +%s)

# =========================================================
# 2. 重写 api.js (植入云验证 + 代理支持)
# =========================================================
echo "🔧 [Backend] 更新 api.js (集成代理)..."

cat > /app/routes/api.js << 'EOF'
const express = require('express');
const axios = require('axios');
const router = express.Router();
const fs = require('fs');
const crypto = require('crypto');
const { exec } = require('child_process');
const { HttpsProxyAgent } = require('https-proxy-agent');
const { Parser } = require('json2csv');

// 📦 保持原有业务模块
const Scraper = require('../modules/scraper');
const ScraperXChina = require('../modules/scraper_xchina');
const Renamer = require('../modules/renamer');
const Organizer = require('../modules/organizer');
const Login115 = require('../modules/login_115');
const LoginM3U8 = require('../modules/login_m3u8'); 
const ResourceMgr = require('../modules/resource_mgr');

// ==========================================
// 🛡️ 云端验证配置
// ==========================================
const CLOUD_API_BASE = 'http://maddd.store:30009/api';
const HEARTBEAT_INTERVAL = 60 * 1000;
const CONFIG_PATH = '/data/config.json';

global.IS_LOGGED_IN = false;
if (!global.CONFIG) global.CONFIG = {};

// 辅助函数：保存配置
function saveConfigLocal(newConf) {
    if (global.saveConfig) {
        global.CONFIG = { ...global.CONFIG, ...newConf };
        global.saveConfig();
    } else {
        try {
            let current = {};
            if (fs.existsSync(CONFIG_PATH)) current = JSON.parse(fs.readFileSync(CONFIG_PATH));
            const merged = { ...current, ...newConf };
            fs.writeFileSync(CONFIG_PATH, JSON.stringify(merged, null, 2));
            global.CONFIG = merged;
        } catch(e) {}
    }
}

function getDeviceToken() {
    if (!global.CONFIG.deviceToken) {
        global.CONFIG.deviceToken = crypto.randomBytes(8).toString('hex').toUpperCase();
        saveConfigLocal({});
    }
    return global.CONFIG.deviceToken;
}

// 🔥 [核心] 获取代理配置
function getAxiosConfig(timeout = 10000) {
    // 优先读取 Docker 环境变量，其次读取 Config 文件
    const proxyUrl = process.env.PROXY_URL || global.CONFIG.proxy;
    const config = { timeout };
    
    if (proxyUrl && proxyUrl.startsWith('http')) {
        // console.log(`🔌 Using Proxy: ${proxyUrl}`);
        const agent = new HttpsProxyAgent(proxyUrl);
        config.httpAgent = agent;
        config.httpsAgent = agent;
    }
    return config;
}

// ==========================================
// 📡 登录与心跳 (带代理)
// ==========================================

router.post('/login', async (req, res) => {
    const { username, password } = req.body;
    const myToken = getDeviceToken();

    try {
        console.log(`📡 [Auth] Connecting: ${username}`);
        // 使用带代理的配置
        const response = await axios.post(
            `${CLOUD_API_BASE}/login`, 
            { username, password, clientToken: myToken }, 
            getAxiosConfig(10000)
        );

        const data = response.data;
        if (data.success) {
            console.log("✅ [Auth] Success");
            global.IS_LOGGED_IN = true;
            saveConfigLocal({ username, authToken: data.token, nonce: data.initNonce });
            res.json({ success: true, token: data.token });
            sendHeartbeat();
        } else {
            console.log(`⛔ [Auth] Failed: ${data.msg}`);
            res.json({ success: false, msg: data.msg });
        }
    } catch (e) {
        console.error(`⚠️ [Auth Error] ${e.message}`);
        res.json({ success: false, msg: "验证服务器连接失败 (请检查代理)" });
    }
});

async function sendHeartbeat() {
    if (!global.IS_LOGGED_IN) return;
    const myToken = getDeviceToken();
    const myNonce = global.CONFIG.nonce;

    try {
        const res = await axios.post(
            `${CLOUD_API_BASE}/heartbeat`, 
            { clientToken: myToken, clientNonce: myNonce }, 
            getAxiosConfig(5000)
        );

        const data = res.data;
        if (data.action === 'OK' && data.nextNonce) {
            if (myNonce !== data.nextNonce) saveConfigLocal({ nonce: data.nextNonce });
        } else if (data.action === 'LOGOUT') {
            console.error(`⛔ [Security] 强制下线: ${data.msg}`);
            global.IS_LOGGED_IN = false;
            saveConfigLocal({ authToken: null });
        }
    } catch (e) { 
        console.warn(`⚠️ [Heartbeat] Lost: ${e.message}`); 
    }
}
setInterval(sendHeartbeat, HEARTBEAT_INTERVAL);

// 权限中间件
const verifyLogin = (req, res, next) => {
    const whitelist = ['/login', '/status', '/check-auth', '/system/online-update'];
    if (whitelist.includes(req.path)) return next();
    if (global.IS_LOGGED_IN) return next();
    return res.status(401).json({ success: false, msg: "Access Denied" });
};
router.use(verifyLogin);

// ==========================================
// 🚀 原有业务逻辑 (完整保留)
// ==========================================

const ENC_WHITE = "aHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL2dob3N0bHB6L21kcXVwZGF0ZS9yZWZzL2hlYWRzL21haW4va2trcy5o";
const ENC_SCRIPT = "aHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL2dob3N0bHB6L21kcXVwZGF0ZS9yZWZzL2hlYWRzL21haW4vdXBkYXRlbmV3LnNo";

function dec(s) { return Buffer.from(s, 'base64').toString('utf-8'); }
function compareVersions(v1, v2) {
    if (!v1 || !v2) return 0;
    const p1 = v1.split('.').map(Number); const p2 = v2.split('.').map(Number);
    for (let i = 0; i < Math.max(p1.length, p2.length); i++) {
        const n1 = p1[i] || 0; const n2 = p2[i] || 0;
        if (n1 > n2) return 1; if (n1 < n2) return -1;
    }
    return 0;
}

router.get('/check-auth', (req, res) => { res.json({ authenticated: global.IS_LOGGED_IN }); });

router.post('/config', (req, res) => { 
    global.CONFIG = { ...global.CONFIG, ...req.body }; 
    if(global.saveConfig) global.saveConfig(); 
    if(LoginM3U8.setConfig) LoginM3U8.setConfig(global.CONFIG); 
    res.json({ success: true }); 
});

router.get('/status', (req, res) => {
    getDeviceToken();
    let logs = Scraper.getState().logs;
    let scraped = Scraper.getState().totalScraped;
    if (ScraperXChina.getState().isRunning) { logs = ScraperXChina.getState().logs; scraped = ScraperXChina.getState().totalScraped; }
    const orgState = Organizer.getState ? Organizer.getState() : { queue: 0, logs: [], stats: {} };
    res.json({ 
        loggedIn: global.IS_LOGGED_IN, 
        config: { ...global.CONFIG, deviceToken: global.CONFIG.deviceToken }, 
        state: { isRunning: Scraper.getState().isRunning || ScraperXChina.getState().isRunning, logs, totalScraped: scraped }, 
        renamerState: Renamer.getState(), 
        organizerLogs: orgState.logs || [], 
        organizerStats: orgState.stats || {}, 
        version: global.CURRENT_VERSION 
    });
});

router.get('/m3u8/check', async (req, res) => { try { LoginM3U8.setConfig(global.CONFIG); res.json(await LoginM3U8.checkConnection()); } catch (e) { res.json({ success: false, msg: e.message }); } });
router.get('/115/check', async (req, res) => { const { uid, time, sign } = req.query; const result = await Login115.checkStatus(uid, time, sign); if (result.success && result.cookie) { global.CONFIG.cookie115 = result.cookie; if(global.saveConfig) global.saveConfig(); res.json({ success: true, msg: "登录成功", cookie: result.cookie }); } else { res.json(result); } });
router.get('/115/qr', async (req, res) => { try { res.json({ success: true, data: await Login115.getQrCode() }); } catch (e) { res.json({ success: false, msg: e.message }); } });

router.post('/start', (req, res) => {
    const { type, source, categories, autoDownload } = req.body;
    if (Scraper.getState().isRunning || ScraperXChina.getState().isRunning) return res.json({ success: false, msg: "运行中" });
    if (source === 'xchina') { ScraperXChina.clearLogs(); ScraperXChina.start(type, autoDownload===true, categories); } 
    else { Scraper.clearLogs(); Scraper.start(type === 'full' ? 50000 : 100, type, autoDownload===true); }
    res.json({ success: true });
});
router.post('/stop', (req, res) => { Scraper.stop(); ScraperXChina.stop(); res.json({ success: true }); });

router.post('/push', async (req, res) => {
    const ids = req.body.ids || [];
    const shouldOrganize = req.body.organize === true;
    if (ids.length === 0) return res.json({ success: false, msg: "未选择" });
    
    let successCount = 0;
    try {
        const items = await ResourceMgr.getByIds(ids);
        for (const item of items) {
            let pushed = false;
            let magnet = (item.magnets || '').trim();
            
            if (magnet.startsWith('magnet:?')) {
                if (global.CONFIG.cookie115) {
                    if (await Login115.addTask(magnet)) {
                        pushed = true;
                        if (shouldOrganize) Organizer.addTask(item);
                    }
                }
            } else {
                let targetUrl = item.link || '';
                if (magnet.startsWith('m3u8|') || magnet.startsWith('pikpak|')) {
                    const parts = magnet.split('|');
                    if (parts.length > 1 && parts[1].startsWith('http')) targetUrl = parts[1];
                }
                if (targetUrl && targetUrl.startsWith('http')) {
                    pushed = await LoginM3U8.addTask(targetUrl);
                }
            }
            if (pushed) { successCount++; await ResourceMgr.markAsPushed(item.id); }
            await new Promise(r => setTimeout(r, 500));
        }
        res.json({ success: true, count: successCount, msg: shouldOrganize ? "已推并加入刮削" : "已推送" });
    } catch (e) { res.json({ success: false, msg: e.message }); }
});

router.post('/organize', async (req, res) => {
    const ids = req.body.ids || [];
    const items = await ResourceMgr.getByIds(ids);
    let count = 0;
    items.forEach(item => {
        if (item.magnets && item.magnets.startsWith('magnet:')) { Organizer.addTask(item); count++; }
    });
    res.json({ success: true, count, msg: "已加入整理队列" });
});

router.post('/delete', async (req, res) => { const result = await ResourceMgr.deleteByIds(req.body.ids || []); res.json(result.success ? { success: true } : { success: false, msg: result.error }); });

router.get('/data', async (req, res) => { 
    const filters = { pushed: req.query.pushed, renamed: req.query.renamed, actor: req.query.actor, category: req.query.category, keyword: req.query.keyword }; 
    const result = await ResourceMgr.getList(parseInt(req.query.page) || 1, 100, filters); 
    res.json(result); 
});

router.get('/export', async (req, res) => { try { const type = req.query.type || 'all'; let data = []; if (type === 'all') data = await ResourceMgr.getAllForExport(); else { const result = await ResourceMgr.getList(parseInt(req.query.page) || 1, 100); data = result.data; } const parser = new Parser({ fields: ['id', 'code', 'title', 'magnets', 'created_at'] }); const csv = parser.parse(data); res.header('Content-Type', 'text/csv'); res.attachment(`madou_${Date.now()}.csv`); return res.send(csv); } catch (err) { res.status(500).send("Err: " + err.message); } });

// 在线更新 (使用 getAxiosConfig 获取代理)
router.post('/system/online-update', async (req, res) => {
    const myToken = getDeviceToken();
    const whitelistUrl = dec(ENC_WHITE);
    const scriptUrl = dec(ENC_SCRIPT);
    const tempScriptPath = '/data/update_temp.sh';
    const finalScriptPath = '/data/update.sh';
    
    try {
        console.log(`⬇️ Update Check...`);
        // 使用 getAxiosConfig 获取代理配置
        const options = getAxiosConfig(30000); 
        options.responseType = 'stream'; // 下载需要 stream

        // 第一次请求白名单 (这里不需要 stream，但 getAxiosConfig 也没副作用)
        const whiteOpts = getAxiosConfig(15000);
        const whiteRes = await axios.get(whitelistUrl, whiteOpts);
        
        // 下载脚本
        const response = await axios({ method: 'get', url: scriptUrl, ...options });
        const writer = fs.createWriteStream(tempScriptPath);
        response.data.pipe(writer);
        
        writer.on('finish', () => {
            fs.readFile(tempScriptPath, 'utf8', (err, data) => {
                if (err) return res.json({ success: false, msg: "Read Error" });
                const match = data.match(/#\s*VERSION\s*=\s*([0-9\.]+)/);
                const remoteVersion = match ? match[1] : null;
                const localVersion = global.CURRENT_VERSION || '0.0.0';
                if (remoteVersion && compareVersions(remoteVersion, localVersion) > 0) {
                    fs.renameSync(tempScriptPath, finalScriptPath);
                    res.json({ success: true, msg: `Updating to V${remoteVersion}...` });
                    setTimeout(() => { exec(`chmod +x ${finalScriptPath} && sh ${finalScriptPath}`, (e) => { if (e) console.error(e); else process.exit(0); }); }, 1000);
                } else {
                    fs.unlinkSync(tempScriptPath);
                    res.json({ success: false, msg: `Latest (V${localVersion})` });
                }
            });
        });
        writer.on('error', () => res.json({ success: false }));
    } catch (e) { res.json({ success: false, msg: "Net Error: " + e.message }); }
});

module.exports = router;
EOF

# =========================================================
# 3. 智能修补 index.html
# =========================================================
echo "🎨 [Frontend] 更新 index.html..."

OVERLAY='<div id="login-overlay" style="position:fixed;inset:0;background:rgba(15,23,42,0.98);z-index:10000;display:flex;justify-content:center;align-items:center;backdrop-filter:blur(10px);display:none;"><div class="card" style="width:380px;padding:40px;background:#1e293b;border:1px solid rgba(255,255,255,0.1);box-shadow:0 25px 50px -12px rgba(0,0,0,0.5);"><div style="text-align:center;margin-bottom:30px;"><div style="font-size:32px;margin-bottom:10px;">⚡</div><h2 style="margin:0;color:#fff;">Madou Omni</h2><p style="color:#64748b;font-size:14px;margin-top:5px;">安全终端登录</p></div><div class="input-group"><label>云端账号</label><input type="text" id="cloud-user" placeholder="Username" style="padding:12px;background:#0f172a;"></div><div class="input-group"><label>密码</label><input type="password" id="cloud-pass" placeholder="Password" style="padding:12px;background:#0f172a;"></div><div id="login-msg" style="color:#ef4444;font-size:13px;margin-bottom:15px;text-align:center;min-height:20px;"></div><button class="btn btn-pri" style="width:100%;padding:12px;font-size:16px;font-weight:600;" onclick="doCloudLogin()">登 录 / 激 活</button><div style="margin-top:20px;text-align:center;font-size:12px;color:#475569;">Protected by Rolling-Key™ Security</div></div></div>'

if ! grep -q "login-overlay" /app/public/index.html; then
    sed -i "s|<body>|<body>${OVERLAY}|" /app/public/index.html
    sed -i 's|id="lock"|id="lock" class="hidden"|' /app/public/index.html
fi

# =========================================================
# 4. 更新 app.js
# =========================================================
echo "🧠 [Frontend] 更新 app.js..."

cat > /app/public/js/app.js << 'EOF'
let dbPage = 1; let qrTimer = null;
const XCHINA_CATS = [
    { name: "麻豆传媒", code: "series-5f904550b8fcc" }, { name: "独立创作者", code: "series-61bf6e439fed6" },
    { name: "糖心Vlog", code: "series-61014080dbfde" }, { name: "蜜桃传媒", code: "series-5fe8403919165" },
    { name: "星空传媒", code: "series-6054e93356ded" }, { name: "天美传媒", code: "series-60153c49058ce" },
    { name: "果冻传媒", code: "series-5fe840718d665" }, { name: "香蕉视频", code: "series-65e5f74e4605c" },
    { name: "精东影业", code: "series-60126bcfb97fa" }, { name: "杏吧原版", code: "series-6072997559b46" },
    { name: "爱豆传媒", code: "series-63d134c7a0a15" }, { name: "IBiZa Media", code: "series-64e9cce89da21" },
    { name: "性视界", code: "series-63490362dac45" }, { name: "ED Mosaic", code: "series-63732f5c3d36b" },
    { name: "大象传媒", code: "series-65bcaa9688514" }, { name: "扣扣传媒", code: "series-6230974ada989" },
    { name: "萝莉社", code: "series-6360ca9706ecb" }, { name: "SA国际传媒", code: "series-633ef3ef07d33" },
    { name: "其他中文AV", code: "series-63986aec205d8" }, { name: "抖阴", code: "series-6248705dab604" },
    { name: "葫芦影业", code: "series-6193d27975579" }, { name: "乌托邦", code: "series-637750ae0ee71" },
    { name: "爱神传媒", code: "series-6405b6842705b" }, { name: "乐播传媒", code: "series-60589daa8ff97" },
    { name: "91茄子", code: "series-639c8d983b7d5" }, { name: "草莓视频", code: "series-671ddc0b358ca" },
    { name: "JVID", code: "series-6964cfbda328b" }, { name: "YOYO", code: "series-64eda52c1c3fb" },
    { name: "51吃瓜", code: "series-671dd88d06dd3" }, { name: "哔哩传媒", code: "series-64458e7da05e6" },
    { name: "映秀传媒", code: "series-6560dc053c99f" }, { name: "西瓜影视", code: "series-648e1071386ef" },
    { name: "思春社", code: "series-64be8551bd0f1" }, { name: "有码AV", code: "series-6395aba3deb74" },
    { name: "无码AV", code: "series-6395ab7fee104" }, { name: "AV解说", code: "series-6608638e5fcf7" },
    { name: "PANS视频", code: "series-63963186ae145" }, { name: "其他模特私拍", code: "series-63963534a9e49" },
    { name: "热舞", code: "series-64edbeccedb2e" }, { name: "相约中国", code: "series-63ed0f22e9177" },
    { name: "果哥作品", code: "series-6396315ed2e49" }, { name: "SweatGirl", code: "series-68456564f2710" },
    { name: "风吟鸟唱作品", code: "series-6396319e6b823" }, { name: "色艺无间", code: "series-6754a97d2b343" },
    { name: "黄甫", code: "series-668c3b2de7f1c" }, { name: "日月俱乐部", code: "series-63ab1dd83a1c6" },
    { name: "探花现场", code: "series-63965bf7b7f51" }, { name: "主播现场", code: "series-63965bd5335fc" },
    { name: "华语电影", code: "series-6396492fdb1a0" }, { name: "日韩电影", code: "series-6396494584b57" },
    { name: "欧美电影", code: "series-63964959ddb1b" }, { name: "其他亚洲影片", code: "series-63963ea949a82" },
    { name: "门事件", code: "series-63963de3f2a0f" }, { name: "其他欧美影片", code: "series-6396404e6bdb5" },
    { name: "无关情色", code: "series-66643478ceedd" }
];

async function request(ep, opt={}) {
    const t = localStorage.getItem('token'); const h = {'Content-Type':'application/json'}; if(t) h['Authorization']=t;
    try { 
        const r = await fetch('/api/'+ep, {...opt, headers:{...h, ...opt.headers}}); 
        if(r.status===401){ showLogin(); throw new Error("401"); } 
        return await r.json(); 
    } catch(e){ return {success:false, msg:e.message}; }
}

function showLogin() { document.getElementById('login-overlay').style.display='flex'; }
function hideLogin() { document.getElementById('login-overlay').style.display='none'; }

async function doCloudLogin() {
    const u=document.getElementById('cloud-user').value; const p=document.getElementById('cloud-pass').value;
    const btn=event.target; const msg=document.getElementById('login-msg');
    if(!u||!p){msg.innerText="请输入账号密码";return;}
    btn.disabled=true; btn.innerText="验证中..."; msg.innerText="";
    try{
        const res=await fetch('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:u,password:p})});
        const data=await res.json();
        if(data.success){ hideLogin(); location.reload(); }
        else{ msg.innerText=data.msg||"登录失败"; }
    }catch(e){ msg.innerText="网络连接错误"; }
    finally{ btn.disabled=false; btn.innerText="登录 / 激活"; }
}

window.onload = async () => {
    const oldLock = document.getElementById('lock'); if(oldLock) oldLock.classList.add('hidden');
    try {
        const s = await request('status');
        if (s.loggedIn) hideLogin(); else showLogin();
        if(s.config){
            if(s.config.proxy) document.getElementById('cfg-proxy').value=s.config.proxy;
            if(s.config.cookie115) document.getElementById('cfg-cookie').value=s.config.cookie115;
            if(s.config.flaresolverrUrl) document.getElementById('cfg-flare').value=s.config.flaresolverrUrl;
            if(s.config.targetCid) document.getElementById('cfg-target-cid').value=s.config.targetCid;
            if(s.config.m3u8_url) document.getElementById('cfg-m3u8-url').value=s.config.m3u8_url;
            if(s.config.m3u8_target) document.getElementById('cfg-m3u8-target').value=s.config.m3u8_target;
            if(s.config.m3u8_pwd) document.getElementById('cfg-m3u8-pwd').value=s.config.m3u8_pwd;
            if(s.config.deviceToken) document.getElementById('device-token').innerText=s.config.deviceToken;
        }
        if(s.version) document.getElementById('cur-ver').innerText="V"+s.version;
    } catch(e) { showLogin(); }
    renderCats();
};

async function login() { }
function renderCats() {
    const src=document.getElementById('scr-source').value; const area=document.getElementById('cat-area'); const list=document.getElementById('cat-list');
    if(src==='xchina'){ area.classList.remove('hidden'); if(list.innerHTML.trim()==='') list.innerHTML=XCHINA_CATS.map(c=>`<label class="cat-item active" style="margin-bottom:0"><input type="checkbox" class="cat-chk" value="${c.code}" checked onchange="this.parentElement.classList.toggle('active',this.checked)"> ${c.name}</label>`).join(''); } else { area.classList.add('hidden'); }
}
function toggleAllCats() { const chks=document.querySelectorAll('.cat-chk'); if(chks.length>0){ const s=!chks[0].checked; chks.forEach(c=>{c.checked=s;c.dispatchEvent(new Event('change'));}); } }
function copyToken() { const v=document.getElementById('device-token').innerText; if(v&&v!=='读取中...') {navigator.clipboard.writeText(v); alert('✅ 授权码已复制');} }
function show(id) {
    document.querySelectorAll('.page').forEach(e=>e.classList.add('hidden')); document.getElementById(id).classList.remove('hidden');
    document.querySelectorAll('.nav-item').forEach(e=>e.classList.remove('active')); if(event&&event.target) event.target.closest('.nav-item').classList.add('active');
    if(id==='database') loadDb(1);
}
async function api(act, body={}) { const r=await request(act,{method:'POST',body:JSON.stringify(body)}); if(!r.success&&r.msg) alert("❌ "+r.msg); if(r.success&&act==='start') alert("✅ 任务已启动"); }
function startScrape(t) {
    const src=document.getElementById('scr-source').value; const dl=document.getElementById('auto-dl').checked; let cats=[];
    if(src==='xchina'){ const chks=document.querySelectorAll('.cat-chk:checked'); cats=Array.from(chks).map(c=>c.value); if(cats.length===0 && !confirm("⚠️ 未选分类将采集全站，确定？")) return; }
    api('start', {type:t, source:src, autoDownload:dl, categories:cats});
}
async function runOnlineUpdate() { const btn=event.target; const txt=btn.innerText; btn.innerText="⏳ 检查中..."; btn.disabled=true; try{const r=await request('system/online-update',{method:'POST'}); if(r.success){alert("🚀 "+r.msg); setTimeout(()=>location.reload(),15000);}else{alert("❌ "+r.msg);}}catch(e){alert("请求失败");} btn.innerText=txt; btn.disabled=false; }
async function saveCfg() {
    const b={
        proxy:document.getElementById('cfg-proxy').value, cookie115:document.getElementById('cfg-cookie').value, flaresolverrUrl:document.getElementById('cfg-flare').value, targetCid:document.getElementById('cfg-target-cid').value,
        m3u8_url:document.getElementById('cfg-m3u8-url').value, m3u8_target:document.getElementById('cfg-m3u8-target').value, m3u8_pwd:document.getElementById('cfg-m3u8-pwd').value
    };
    await request('config',{method:'POST',body:JSON.stringify(b)}); alert('✅ 配置已保存');
}
async function checkM3U8() { const btn=event.target; const txt=btn.innerText; btn.innerText="Testing..."; btn.disabled=true; await saveCfg(); try{const r=await request('m3u8/check'); alert(r.success?r.msg:"❌ "+r.msg);}catch(e){alert("Fail");} btn.innerText=txt; btn.disabled=false; }
function toggleAll(s) { document.querySelectorAll('.row-chk').forEach(c=>c.checked=s.checked); }
async function pushSelected(org) {
    const chks=document.querySelectorAll('.row-chk:checked'); if(chks.length===0){alert("请勾选");return;}
    const ids=Array.from(chks).map(c=>c.value.split('|')[0]); const btn=event.target; const txt=btn.innerText; btn.innerText="处理中..."; btn.disabled=true;
    try{const r=await request('push',{method:'POST',body:JSON.stringify({ids,organize:org})}); if(r.success){alert("✅ "+r.msg);loadDb(dbPage);}else{alert("❌ "+r.msg);}}catch(e){alert("Error");} btn.innerText=txt; btn.disabled=false;
}
async function organizeSelected() {
    const chks=document.querySelectorAll('.row-chk:checked'); if(chks.length===0){alert("请勾选");return;}
    const ids=Array.from(chks).map(c=>c.value.split('|')[0]); const btn=event.target; btn.innerText="Req..."; btn.disabled=true;
    try{const r=await request('organize',{method:'POST',body:JSON.stringify({ids})}); if(r.success)alert("✅ 加入队列");else alert("❌ "+r.msg);}catch(e){alert("Error");} btn.innerText="🛠️ 仅刮削"; btn.disabled=false;
}
async function deleteSelected() {
    const chks=document.querySelectorAll('.row-chk:checked'); if(chks.length===0){alert("请勾选");return;}
    if(!confirm("确定删除?"))return; const ids=Array.from(chks).map(c=>c.value.split('|')[0]);
    try{await request('delete',{method:'POST',body:JSON.stringify({ids})}); loadDb(dbPage);}catch(e){}
}
function resetFilters() { document.getElementById('filter-keyword').value=''; document.getElementById('filter-actor').value=''; document.getElementById('filter-cat').value=''; document.getElementById('filter-pushed').value=''; document.getElementById('filter-renamed').value=''; loadDb(1); }
async function loadDb(p) {
    if(p<1)return; dbPage=p; document.getElementById('page-info').innerText=p; document.getElementById('total-count').innerText="Loading...";
    const kw=document.getElementById('filter-keyword').value; const actor=document.getElementById('filter-actor').value; const cat=document.getElementById('filter-cat').value;
    const pushed=document.getElementById('filter-pushed').value; const renamed=document.getElementById('filter-renamed').value;
    try {
        const r=await request(`data?page=${p}&keyword=${kw}&actor=${actor}&category=${cat}&pushed=${pushed}&renamed=${renamed}`);
        const tb=document.querySelector('#db-tbl tbody'); tb.innerHTML='';
        if(r.data){
            document.getElementById('total-count').innerText="总计: "+(r.total||0);
            r.data.forEach(x=>{
                const img=x.image_url?`<img src="${x.image_url}" class="cover-img" onclick="window.open('${x.link}')" style="cursor:pointer">`:`<div class="cover-img" style="color:#555;font-size:10px;display:flex;align-items:center;justify-content:center">无图</div>`;
                let st=""; if(x.is_pushed)st+=`<span class="tag" style="color:#34d399;background:rgba(16,185,129,0.1)">已推</span>`; if(x.is_renamed)st+=`<span class="tag" style="color:#60a5fa;background:rgba(59,130,246,0.1)">已整</span>`;
                let meta=""; if(x.actor)meta+=`<span class="tag tag-actor" onclick="document.getElementById('filter-actor').value='${x.actor}';loadDb(1)">👤 ${x.actor}</span>`; if(x.category)meta+=`<span class="tag tag-cat" onclick="document.getElementById('filter-cat').value='${x.category}';loadDb(1)">🏷️ ${x.category}</span>`;
                let mg=x.magnets||''; let ml='🔗'; if(mg.includes('m3u8'))ml='📺'; if(mg.includes('&'))mg=mg.split('&')[0];
                const md=mg?`<div class="magnet-link" onclick="navigator.clipboard.writeText('${mg}');alert('Copied')">${ml} ${mg.substring(0,20)}...</div>`:'';
                tb.innerHTML+=`<tr><td><input type="checkbox" class="row-chk" value="${x.id}|${x.magnets}"></td><td>${img}</td><td><div style="font-weight:500;max-width:300px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${x.title}</div><div style="font-size:12px;color:#94a3b8;font-family:monospace">${x.code||'无番号'}</div>${md}</td><td>${meta}</td><td>${st}</td></tr>`;
            });
        }
    } catch(e) { document.getElementById('total-count').innerText="Error"; }
}

let lastLogTimeScr=""; let lastLogTimeOrg="";
setInterval(async()=>{
    if(document.getElementById('login-overlay').style.display !== 'none') return;
    const r=await request('status'); if(!r.config)return;
    const log=(id,ls,lt)=>{
        const el=document.getElementById(id); if(!el||!ls.length)return lt;
        const last=ls[ls.length-1]; const sig=last.time+last.msg;
        if(sig!==lt){ el.innerHTML=ls.map(l=>`<div class="log-entry ${l.type==='error'?'err':l.type==='success'?'suc':l.type==='warn'?'warn':''}"><span class="time">[${l.time}]</span> ${l.msg}</div>`).join(''); el.scrollTop=el.scrollHeight; return sig; } return lt;
    };
    lastLogTimeScr=log('log-scr',r.state.logs,lastLogTimeScr); lastLogTimeOrg=log('log-org',r.organizerLogs,lastLogTimeOrg);
    if(r.organizerStats && document.getElementById('org-progress-fill')){
        const s=r.organizerStats; const p=s.total>0?(s.processed/s.total)*100:0;
        document.getElementById('org-progress-fill').style.width=p+'%';
        document.getElementById('org-status-txt').innerText=s.total>0?(s.processed<s.total?`🎬 处理中: ${s.current}`:'✅ 完成'):'空闲';
        document.getElementById('org-status-count').innerText=`${s.processed} / ${s.total}`;
    }
    if(document.getElementById('stat-scr')) document.getElementById('stat-scr').innerText=r.state.totalScraped||0;
}, 2000);

async function showQr() {
    const m=document.getElementById('modal'); m.classList.remove('hidden');
    const r=await request('115/qr'); if(!r.success)return;
    const {uid,time,sign,qr_url}=r.data; document.getElementById('qr-img').innerHTML=`<img src="${qr_url}" width="200">`;
    if(qrTimer)clearInterval(qrTimer);
    qrTimer=setInterval(async()=>{
        const c=await request(`115/check?uid=${uid}&time=${time}&sign=${sign}`);
        const t=document.getElementById('qr-txt');
        if(c.success){t.innerText="✅ 成功! 刷新...";t.style.color="#0f0";clearInterval(qrTimer);setTimeout(()=>{m.classList.add('hidden');location.reload();},1000);}
        else if(c.status===1){t.innerText="📱 已扫码";t.style.color="#fb5";}
    },1500);
}
EOF

# =========================================================
# 5. 完成
# =========================================================
echo "🔄 升级完成，正在重启服务..."
pkill -f "node app.js" || true

exit 0
