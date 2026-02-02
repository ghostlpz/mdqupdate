#!/bin/bash
# VERSION = 13.7.4

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本 (Docker 容器版)
# 版本: V13.7.4
# 优化: 发现 URL 规律，跳过详情页直接请求下载页，效率提升 100%
# ---------------------------------------------------------

echo "🚀 [Update] 开始执行逻辑短路优化 (V13.7.4)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.7.4"/' package.json

# 2. 覆盖 modules/scraper_xchina.js
echo "📝 [1/1] 重构采集逻辑 (跳过中间页)..."
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
        
        log(`🚀 xChina 极速版Pro (V13.7.4) | 目标: ${limitPages}页 | 策略: 直连下载页`, 'success');

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

                    for (let i = 0; i < items.length; i++) {
                        if (STATE.stopSignal) break;
                        const el = items[i];
                        const titleEl = $(el).find('.text .title a');
                        const title = titleEl.text().trim();
                        let subLink = titleEl.attr('href'); // /video/id-xxx.html
                        
                        if (!subLink) continue;

                        // ⚡️ 核心优化：直接构造下载页 URL，跳过详情页请求
                        // 将 /video/ 替换为 /download/
                        let downloadPageUrl = subLink.replace('/video/', '/download/');
                        
                        // 确保是绝对路径
                        if (!downloadPageUrl.startsWith('http')) {
                            downloadPageUrl = baseUrl + downloadPageUrl;
                        }
                        
                        // 确保原始链接也是绝对路径（用于入库记录）
                        let fullVideoLink = subLink.startsWith('http') ? subLink : (baseUrl + subLink);

                        try {
                            // 直接请求下载页
                            const $down = await requestViaFlare(downloadPageUrl);
                            const magnet = $down('a.btn.magnet').attr('href');
                            
                            if (magnet && magnet.startsWith('magnet:')) {
                                const saveRes = await ResourceMgr.save(title, fullVideoLink, magnet);
                                if (saveRes.success) {
                                    if (saveRes.newInsert) {
                                        STATE.totalScraped++;
                                        newItemsInPage++;
                                        let extraMsg = "";
                                        if (autoDownload) {
                                            const pushed = await pushTo115(magnet);
                                            extraMsg = pushed ? " | 📥 已推115" : " | ⚠️ 推送失败";
                                            if(pushed) await ResourceMgr.markAsPushedByLink(fullVideoLink);
                                        }
                                        log(`✅ [入库${extraMsg}] ${title.substring(0, 10)}...`, 'success');
                                    } else {
                                        log(`⏭️ [已存在] ${title.substring(0, 10)}...`, 'info');
                                    }
                                }
                            } else { 
                                // 有时候 Cloudflare 还是会抽风或者页面结构变了
                                log(`❌ [无磁力] ${title.substring(0, 10)}... (可能需重试)`, 'warn'); 
                            }

                        } catch (itemErr) { log(`❌ [解析失败] ${title}: ${itemErr.message}`, 'error'); }
                        
                        // 极速模式：每个视频间隔 200ms
                        await new Promise(r => setTimeout(r, 200)); 
                    }

                    if (newItemsInPage === 0 && page > 1) { log(`⚠️ 本页全为旧数据，提前结束`, 'warn'); break; }

                    page++;
                    await new Promise(r => setTimeout(r, 2000)); // 翻页等待 2秒

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

echo "✅ [完成] 逻辑短路补丁已应用。"
