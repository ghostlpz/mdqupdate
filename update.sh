#!/bin/bash
# VERSION = 13.7.2

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本 (Docker 容器版)
# 版本: V13.7.2
# 修复: xChina 采集相对路径报错问题 (Flaresolverr invalid argument)
# ---------------------------------------------------------

echo "🚀 [Update] 开始执行容器内热更新 (V13.7.2)..."
echo "📂 当前工作目录: $(pwd)"

# 1. 更新 package.json
echo "📝 [1/2] 更新版本号..."
sed -i 's/"version": ".*"/"version": "13.7.2"/' package.json

# 2. 覆盖 modules/scraper_xchina.js
# 修复点：在获取 subLink 和 downloadPageUrl 后，立即判断并补全域名
echo "📝 [2/2] 修复采集器路径逻辑..."
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

        // 透传代理配置
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
        
        log(`🚀 xChina 任务启动 (V13.7.2) | 目标: ${limitPages}页 | 代理: ${global.CONFIG.proxy ? '✅' : '❌'}`, 'success');

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

                    for (let i = 0; i < items.length; i++) {
                        if (STATE.stopSignal) break;
                        const el = items[i];
                        const titleEl = $(el).find('.text .title a');
                        const title = titleEl.text().trim();
                        let subLink = titleEl.attr('href'); // 可能是相对路径 /video/...
                        
                        if (!subLink) continue;

                        // 🛠️ 修复1: 确保详情页链接是绝对路径
                        if (!subLink.startsWith('http')) {
                            subLink = baseUrl + subLink;
                        }

                        try {
                            // log(`➡️ 解析详情: ${title.substring(0, 10)}...`);
                            const $detail = await requestViaFlare(subLink);
                            const downloadLinkEl = $detail('a[href*="/download/id-"]');
                            
                            if (downloadLinkEl.length > 0) {
                                let downloadPageUrl = downloadLinkEl.attr('href');
                                
                                // 🛠️ 修复2: 确保下载页链接是绝对路径 (关键修复)
                                if (downloadPageUrl && !downloadPageUrl.startsWith('http')) {
                                    downloadPageUrl = baseUrl + downloadPageUrl;
                                }

                                const $down = await requestViaFlare(downloadPageUrl);
                                const magnet = $down('a.btn.magnet').attr('href');
                                
                                if (magnet && magnet.startsWith('magnet:')) {
                                    const saveRes = await ResourceMgr.save(title, subLink, magnet);
                                    if (saveRes.success) {
                                        if (saveRes.newInsert) {
                                            STATE.totalScraped++;
                                            newItemsInPage++;
                                            let extraMsg = "";
                                            if (autoDownload) {
                                                const pushed = await pushTo115(magnet);
                                                extraMsg = pushed ? " | 📥 已推115" : " | ⚠️ 推送失败";
                                                if(pushed) await ResourceMgr.markAsPushedByLink(subLink);
                                            }
                                            log(`✅ [入库${extraMsg}] ${title.substring(0, 10)}...`, 'success');
                                        } else {
                                            log(`⏭️ [已存在] ${title.substring(0, 10)}...`, 'info');
                                        }
                                    }
                                } else { log(`❌ [无磁力] ${title.substring(0, 10)}...`, 'warn'); }
                            } else { log(`❌ [无下载页] ${title.substring(0, 10)}...`, 'warn'); }

                        } catch (itemErr) { log(`❌ [解析失败] ${title}: ${itemErr.message}`, 'error'); }
                        
                        // 稍微增加延迟，避免 Flaresolverr 压力过大
                        await new Promise(r => setTimeout(r, 1500)); 
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

# 3. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] 路径修复补丁已应用，容器即将重启。"
