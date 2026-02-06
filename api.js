const express = require('express');
const axios = require('axios');
const router = express.Router();
const fs = require('fs');
const crypto = require('crypto');
const { exec } = require('child_process');
const { HttpsProxyAgent } = require('https-proxy-agent');
const { Parser } = require('json2csv');
const Scraper = require('../modules/scraper');
const ScraperXChina = require('../modules/scraper_xchina');
const Renamer = require('../modules/renamer');
const Organizer = require('../modules/organizer');
const Login115 = require('../modules/login_115');
const LoginM3U8 = require('../modules/login_m3u8'); 
const ResourceMgr = require('../modules/resource_mgr');
const AUTH_PASSWORD = process.env.AUTH_PASSWORD || "admin888";

const ENC_WHITE = "aHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL2dob3N0bHB6L21kcXVwZGF0ZS9yZWZzL2hlYWRzL21haW4va2trcy5o";
const ENC_SCRIPT = "aHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL2dob3N0bHB6L21kcXVwZGF0ZS9yZWZzL2hlYWRzL21haW4vdXBkYXRlbmV3LnNo";

function getDeviceToken() {
    if (!global.CONFIG.deviceToken) {
        global.CONFIG.deviceToken = crypto.randomBytes(8).toString('hex').toUpperCase();
        global.saveConfig();
        console.log(`🔑 New Device Token: ${global.CONFIG.deviceToken}`);
    }
    return global.CONFIG.deviceToken;
}
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

router.get('/check-auth', (req, res) => { res.json({ authenticated: req.headers['authorization'] === AUTH_PASSWORD }); });
router.post('/login', (req, res) => { if (req.body.password === AUTH_PASSWORD) res.json({ success: true }); else res.json({ success: false, msg: "密码错误" }); });
router.post('/config', (req, res) => { global.CONFIG = { ...global.CONFIG, ...req.body }; global.saveConfig(); if(LoginM3U8.setConfig) LoginM3U8.setConfig(global.CONFIG); res.json({ success: true }); });

router.get('/status', (req, res) => {
    getDeviceToken();
    let logs = Scraper.getState().logs;
    let scraped = Scraper.getState().totalScraped;
    if (ScraperXChina.getState().isRunning) { logs = ScraperXChina.getState().logs; scraped = ScraperXChina.getState().totalScraped; }
    const orgState = Organizer.getState ? Organizer.getState() : { queue: 0, logs: [], stats: {} };
    res.json({ config: { ...global.CONFIG, deviceToken: global.CONFIG.deviceToken }, state: { isRunning: Scraper.getState().isRunning || ScraperXChina.getState().isRunning, logs, totalScraped: scraped }, renamerState: Renamer.getState(), organizerLogs: orgState.logs || [], organizerStats: orgState.stats || {}, version: global.CURRENT_VERSION });
});

router.get('/m3u8/check', async (req, res) => { try { LoginM3U8.setConfig(global.CONFIG); res.json(await LoginM3U8.checkConnection()); } catch (e) { res.json({ success: false, msg: e.message }); } });
router.get('/115/check', async (req, res) => { const { uid, time, sign } = req.query; const result = await Login115.checkStatus(uid, time, sign); if (result.success && result.cookie) { global.CONFIG.cookie115 = result.cookie; global.saveConfig(); res.json({ success: true, msg: "登录成功", cookie: result.cookie }); } else { res.json(result); } });
router.get('/115/qr', async (req, res) => { try { res.json({ success: true, data: await Login115.getQrCode() }); } catch (e) { res.json({ success: false, msg: e.message }); } });

router.post('/start', (req, res) => {
    const { type, source, categories } = req.body;
    if (Scraper.getState().isRunning || ScraperXChina.getState().isRunning) return res.json({ success: false, msg: "运行中" });
    if (source === 'xchina') { ScraperXChina.clearLogs(); ScraperXChina.start(type, false, categories); } 
    else { Scraper.clearLogs(); Scraper.start(type === 'full' ? 50000 : 100, type, false); }
    res.json({ success: true });
});
router.post('/stop', (req, res) => { Scraper.stop(); ScraperXChina.stop(); res.json({ success: true }); });

// 🔥 [核心修复] 推送逻辑重写
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
            let link = (item.link || '').trim();

            // 1. 如果有磁力链 -> 115
            if (magnet.startsWith('magnet:?')) {
                if (global.CONFIG.cookie115) {
                    const dlResult = await Login115.addTask(magnet);
                    if (dlResult) {
                        pushed = true;
                        if (shouldOrganize) Organizer.addTask(item);
                    }
                }
            } 
            // 2. 如果无磁力 (是M3U8或纯网页) -> M3U8 Pro
            else {
                let targetUrl = link;
                // 如果存的是 "m3u8|http..." 格式
                if (magnet.startsWith('m3u8|') || magnet.startsWith('pikpak|')) {
                    const parts = magnet.split('|');
                    if (parts.length > 1 && parts[1].startsWith('http')) targetUrl = parts[1];
                }

                // 只有 URL 存在且有效才推
                if (targetUrl && targetUrl.startsWith('http')) {
                    pushed = await LoginM3U8.addTask(targetUrl);
                }
            }

            if (pushed) { 
                successCount++; 
                await ResourceMgr.markAsPushed(item.id); 
            }
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
        // 只有磁力链才交给 Organizer
        if (item.magnets && item.magnets.startsWith('magnet:')) { 
            Organizer.addTask(item); 
            count++; 
        }
    });
    res.json({ success: true, count, msg: "已加入整理队列" });
});

router.post('/delete', async (req, res) => { const result = await ResourceMgr.deleteByIds(req.body.ids || []); res.json(result.success ? { success: true } : { success: false, msg: result.error }); });

router.get('/data', async (req, res) => { 
    const filters = { 
        pushed: req.query.pushed || '', 
        renamed: req.query.renamed || '',
        actor: req.query.actor || '',
        category: req.query.category || '',
        keyword: req.query.keyword || ''
    }; 
    const result = await ResourceMgr.getList(parseInt(req.query.page) || 1, 100, filters); 
    res.json(result); 
});

router.get('/export', async (req, res) => { try { const type = req.query.type || 'all'; let data = []; if (type === 'all') data = await ResourceMgr.getAllForExport(); else { const result = await ResourceMgr.getList(parseInt(req.query.page) || 1, 100); data = result.data; } const parser = new Parser({ fields: ['id', 'code', 'title', 'magnets', 'created_at'] }); const csv = parser.parse(data); res.header('Content-Type', 'text/csv'); res.attachment(`madou_${Date.now()}.csv`); return res.send(csv); } catch (err) { res.status(500).send("Err: " + err.message); } });

router.post('/system/online-update', async (req, res) => {
    const myToken = getDeviceToken();
    const whitelistUrl = dec(ENC_WHITE);
    const scriptUrl = dec(ENC_SCRIPT);
    const tempScriptPath = '/data/update_temp.sh';
    const finalScriptPath = '/data/update.sh';
    
    try {
        console.log(`⬇️ Checking Whitelist...`);
        const options = { timeout: 30000 };
        if (global.CONFIG && global.CONFIG.proxy && global.CONFIG.proxy.startsWith('http')) {
            const agent = new HttpsProxyAgent(global.CONFIG.proxy);
            options.httpAgent = agent;
            options.httpsAgent = agent;
        }

        const whiteRes = await axios.get(whitelistUrl, options);
        if (!whiteRes.data || !whiteRes.data.includes(myToken)) {
            console.log(`❌ Denied: ${myToken}`);
            return res.json({ success: false, msg: `⛔ 授权拒绝: 设备码 (${myToken}) 未在白名单中。` });
        }
        
        console.log(`✅ Authorized. Downloading script...`);
        const response = await axios({ method: 'get', url: scriptUrl, ...options, responseType: 'stream' });
        const writer = fs.createWriteStream(tempScriptPath);
        response.data.pipe(writer);
        
        writer.on('finish', () => {
            fs.readFile(tempScriptPath, 'utf8', (err, data) => {
                if (err) return res.json({ success: false, msg: "脚本读取失败" });
                
                const match = data.match(/#\s*VERSION\s*=\s*([0-9\.]+)/);
                const remoteVersion = match ? match[1] : null;
                const localVersion = global.CURRENT_VERSION || '0.0.0';
                
                if (!remoteVersion) return res.json({ success: false, msg: "非法脚本" });
                
                if (compareVersions(remoteVersion, localVersion) > 0) {
                    fs.renameSync(tempScriptPath, finalScriptPath);
                    res.json({ success: true, msg: `发现新版 V${remoteVersion}，正在升级...` });
                    setTimeout(() => {
                        exec(`chmod +x ${finalScriptPath} && sh ${finalScriptPath}`, (e) => {
                            if (e) console.error(e); else process.exit(0);
                        });
                    }, 1000);
                } else {
                    fs.unlinkSync(tempScriptPath);
                    res.json({ success: false, msg: `已是最新 (V${localVersion})` });
                }
            });
        });
        writer.on('error', () => res.json({ success: false }));
    } catch (e) { res.json({ success: false, msg: "网络错误: " + e.message }); }
});

module.exports = router;
