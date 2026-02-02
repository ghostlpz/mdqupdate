#!/bin/bash
# VERSION = 13.7.6

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.7.6
# 策略: 回退至稳健逻辑 (详情页->下载页) + 3线程并发加速
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署稳健并发版 (V13.7.6)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.7.6"/' package.json

# 2. 重写 scraper_xchina.js
echo "📝 [1/1] 重构采集核心 (3线程+稳健逻辑)..."
cat > modules/scraper_xchina.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const ResourceMgr = require('./resource_mgr');

// ⚡️ 并发数配置 (3线程是 NAS 环境下的安全甜点)
const CONCURRENCY_LIMIT = 3;

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
        // 代理透传 (保留之前的修复)
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

// 单个视频的处理逻辑 (稳健流程)
async function processVideoTask(task, baseUrl, autoDownload) {
    if (STATE.stopSignal) return;
    const { title, link } = task; // link 是详情页地址

    try {
        // 1. 访问详情页
        // log(`➡️ [解析] ${title.substring(0, 10)}...`);
        const $detail = await requestViaFlare(link);
        
        // 2. 提取下载页链接
        const downloadLinkEl = $detail('a[href*="/download/id-"]');
        
        if (downloadLinkEl.length > 0) {
            let downloadPageUrl = downloadLinkEl.attr('href');
            // 补全下载页域名
            if (downloadPageUrl && !downloadPageUrl.startsWith('http')) {
                downloadPageUrl = baseUrl + downloadPageUrl;
            }

            // 3. 访问下载页
            const $down = await requestViaFlare(downloadPageUrl);
            const magnet = $down('a.btn.magnet').attr('href');
            
            // 4. 入库
            if (magnet && magnet.startsWith('magnet:')) {
                const saveRes = await ResourceMgr.save(title, link, magnet);
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
                    }
                }
            } else {
                log(`❌ [无磁力] ${title.substring(0, 10)}...`, 'warn');
            }
        } else {
            log(`❌ [无下载钮] ${title.substring(0, 10)}...`, 'warn');
        }
    } catch (e) {
        log(`❌ [失败] ${title.substring(0, 10)}... : ${e.message}`, 'error');
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
        
        log(`🚀 xChina 稳健并发版 (V13.7.6) | 线程: ${CONCURRENCY_LIMIT}`, 'success');

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
                    log(`🔍 本页发现 ${items.length} 个视频，启动并发采集...`);

                    let newItemsInPage = 0;
                    
                    // 提取本页所有任务
                    const tasks = [];
                    items.each((i, el) => {
                        const title = $(el).find('.text .title a').text().trim();
                        let subLink = $(el).find('.text .title a').attr('href');
                        if (title && subLink) {
                            if (!subLink.startsWith('http')) subLink = baseUrl + subLink;
                            tasks.push({ title, link: subLink });
                        }
                    });

                    // ⚡️ 分批并发执行
                    for (let i = 0; i < tasks.length; i += CONCURRENCY_LIMIT) {
                        if (STATE.stopSignal) break;

                        const chunk = tasks.slice(i, i + CONCURRENCY_LIMIT);
                        
                        // 并行处理当前批次的 3 个任务
                        const results = await Promise.all(chunk.map(task => 
                            processVideoTask(task, baseUrl, autoDownload)
                        ));

                        // 统计
                        newItemsInPage += results.filter(r => r === true).length;

                        // 批次间短暂休息 (500ms)，防止 Flaresolverr 积压
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

# 3. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] 已更新为 V13.7.6 (稳健逻辑 + 3线程)。"
