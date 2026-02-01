#!/bin/bash
# VERSION = 13.7.4

echo "🚀 开始升级 Madou-Omni 到 v13.7.4 (全套浏览器指纹伪装)..."

# 1. 更新爬虫模块 (scraper.js) - 注入全套浏览器 Headers
echo "📝 更新 /app/modules/scraper.js..."
cat > /app/modules/scraper.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const { HttpsProxyAgent } = require('https-proxy-agent');
const ResourceMgr = require('./resource_mgr');

let STATE = { isRunning: false, stopSignal: false, logs: [], totalScraped: 0 };

function log(msg, type='info') {
    STATE.logs.push({ time: new Date().toLocaleTimeString(), msg, type });
    if (STATE.logs.length > 200) STATE.logs.shift();
    console.log(`[Scraper] ${msg}`);
}

function getRequest(referer) {
    // 默认 User-Agent (Mac Chrome)
    const defaultUA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    
    // 优先使用用户配置的 UA
    const userAgent = (global.CONFIG.userAgent && global.CONFIG.userAgent.trim() !== '') 
        ? global.CONFIG.userAgent.trim() 
        : defaultUA;

    // 构建全套浏览器头
    const headers = {
        'User-Agent': userAgent,
        'Referer': referer,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
        'Accept-Encoding': 'gzip, deflate, br', // 支持压缩
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8', // 声明语言
        'Cache-Control': 'max-age=0',
        'Connection': 'keep-alive',
        'Upgrade-Insecure-Requests': '1',
        // Cloudflare 重点检查的 Sec 头
        'Sec-Fetch-Dest': 'document',
        'Sec-Fetch-Mode': 'navigate',
        'Sec-Fetch-Site': 'none',
        'Sec-Fetch-User': '?1',
        'Sec-Ch-Ua': '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"',
        'Sec-Ch-Ua-Mobile': '?0',
        'Sec-Ch-Ua-Platform': '"macOS"' // 假装是 Mac
    };
    
    // 如果配置了采集 Cookie，则添加到请求头中
    if (global.CONFIG.scraperCookie && global.CONFIG.scraperCookie.trim() !== '') {
        headers['Cookie'] = global.CONFIG.scraperCookie.trim();
    }

    const options = {
        headers: headers,
        timeout: 20000,
        // 关键：允许 403 状态码不抛出异常，以便我们在代码中处理或查看返回内容
        validateStatus: function (status) {
            return status >= 200 && status < 500; 
        }
    };

    if (global.CONFIG.proxy && global.CONFIG.proxy.startsWith('http')) {
        const agent = new HttpsProxyAgent(global.CONFIG.proxy);
        options.httpAgent = agent;
        options.httpsAgent = agent;
    }
    return axios.create(options);
}

async function pushTo115(magnet) {
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

async function scrapeMadouQu(request, limitPages, autoDownload) {
    let page = 1;
    let url = "https://madouqu.com/";
    log(`==== 正在启动 MadouQu 采集 (Max: ${limitPages}页) ====`, 'info');
    while (page <= limitPages && !STATE.stopSignal) {
        log(`[Madou] 正在抓取第 ${page} 页: ${url}`, 'info');
        try {
            const res = await request.get(url);
            if (res.status === 403) { log(`❌ [Madou] 403 禁止访问，请检查 IP 或 Cookie`, 'error'); break; }
            
            const $ = cheerio.load(res.data);
            const posts = $('article h2.entry-title a, h2.entry-title a');
            if (posts.length === 0) { log(`[Madou] ⚠️ 第 ${page} 页未找到文章`, 'warn'); break; }
            log(`[Madou] 本页发现 ${posts.length} 个资源...`);
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
                        const saved = await ResourceMgr.save(title, link, magnets);
                        if(saved) {
                            STATE.totalScraped++;
                            let extraMsg = "";
                            if (autoDownload && match[0]) {
                                const pushRes = await pushTo115(match[0]);
                                if (pushRes) { extraMsg = " | 📥 已推115"; await ResourceMgr.markAsPushedByLink(link); }
                                else { extraMsg = " | ⚠️ 推送失败"; }
                            }
                            log(`✅ [入库${extraMsg}] ${title.substring(0, 15)}...`, 'success');
                        }
                    } else { log(`❌ [无磁力] ${title.substring(0, 15)}...`, 'warn'); }
                } catch (e) { log(`❌ [Madou失败] ${title.substring(0, 10)}... : ${e.message}`, 'error'); }
                await new Promise(r => setTimeout(r, Math.floor(Math.random() * 1000) + 1000));
            }
            const next = $('a.next').attr('href');
            if (next) { url = next; page++; await new Promise(r => setTimeout(r, 2000)); } 
            else { log("[Madou] 🚫 没有下一页了", 'success'); break; }
        } catch (pageErr) { log(`❌ [Madou] 获取第 ${page} 页失败: ${pageErr.message}`, 'error'); await new Promise(r => setTimeout(r, 5000)); }
    }
}

async function scrapeXChina(request, limitPages, autoDownload) {
    let page = 1;
    let url = "https://xchina.co/videos.html";
    const domain = "https://xchina.co";
    log(`==== 正在启动 XChina 采集 (Max: ${limitPages}页) ====`, 'info');
    while (page <= limitPages && !STATE.stopSignal) {
        log(`[XChina] 正在抓取第 ${page} 页: ${url}`, 'info');
        try {
            const res = await request.get(url);
            
            // 增加状态码检查
            if (res.status === 403) {
                log(`❌ [XChina] 403 拒绝访问！Cloudflare 拦截。`, 'error');
                log(`💡 提示: 请确保 Cookie 和 UA 正确，且 NAS IP 与获取 Cookie 的 IP 一致。`, 'warn');
                break;
            }
            if (res.status === 503) {
                 log(`❌ [XChina] 503 正在进行盾牌验证，Node.js 无法处理。`, 'error');
                 break;
            }

            const $ = cheerio.load(res.data);
            const posts = $('.list.video-index .item.video');
            if (posts.length === 0) { 
                // 如果页面正常返回但找不到元素，可能是返回了验证页
                if (res.data.includes('challenge-platform')) {
                    log(`❌ [XChina] 遇到 Cloudflare 隐形验证，当前 Cookie 失效。`, 'error');
                } else {
                    log(`[XChina] ⚠️ 第 ${page} 页未找到视频 (DOM解析失败)`, 'warn'); 
                }
                break; 
            }

            log(`[XChina] 本页发现 ${posts.length} 个资源...`);
            for (let i = 0; i < posts.length; i++) {
                if (STATE.stopSignal) break;
                const el = posts[i];
                const titleTag = $(el).find('.text .title a');
                let title = titleTag.text().trim();
                let detailLink = titleTag.attr('href');
                if (!title || !detailLink) continue;
                if (detailLink.startsWith('/')) detailLink = domain + detailLink;
                try {
                    const detailRes = await request.get(detailLink);
                    const $d = cheerio.load(detailRes.data);
                    let downloadPageLink = $d('a[href*="/download/id-"]').attr('href');
                    if (downloadPageLink) {
                        if (downloadPageLink.startsWith('/')) downloadPageLink = domain + downloadPageLink;
                        const downloadRes = await request.get(downloadPageLink);
                        const $dl = cheerio.load(downloadRes.data);
                        const magnet = $dl('a.btn.magnet[href^="magnet:"]').attr('href');
                        if (magnet) {
                            const saved = await ResourceMgr.save(title, detailLink, magnet);
                            if(saved) {
                                STATE.totalScraped++;
                                let extraMsg = "";
                                if (autoDownload) {
                                    const pushRes = await pushTo115(magnet);
                                    if (pushRes) { extraMsg = " | 📥 已推115"; await ResourceMgr.markAsPushedByLink(detailLink); }
                                    else { extraMsg = " | ⚠️ 推送失败"; }
                                }
                                log(`✅ [入库${extraMsg}] ${title.substring(0, 15)}...`, 'success');
                            }
                        } else { log(`❌ [XChina无磁力] ${title.substring(0, 15)}...`, 'warn'); }
                    } else { log(`❌ [XChina无下载页] ${title.substring(0, 15)}...`, 'warn'); }
                } catch (e) { log(`❌ [XChina失败] ${title.substring(0, 10)}... : ${e.message}`, 'error'); }
                await new Promise(r => setTimeout(r, Math.floor(Math.random() * 1500) + 1000));
            }
            const nextHref = $('.pagination a:contains("下一页"), .pagination a:contains("Next"), a.next').attr('href');
            if (nextHref) {
                url = nextHref.startsWith('/') ? domain + nextHref : nextHref;
                page++;
                await new Promise(r => setTimeout(r, 2000));
            } else { log("[XChina] 🚫 当前页未发现下一页链接，停止采集", 'success'); break; }
        } catch (pageErr) { 
            log(`❌ [XChina] 获取第 ${page} 页异常: ${pageErr.message}`, 'error'); 
            await new Promise(r => setTimeout(r, 5000)); 
            break; 
        }
    }
}

const Scraper = {
    getState: () => STATE,
    stop: () => { STATE.stopSignal = true; },
    clearLogs: () => { STATE.logs = []; },
    start: async (limitPages = 5, source = "madou", autoDownload = false) => {
        if (STATE.isRunning) return;
        STATE.isRunning = true;
        STATE.stopSignal = false;
        STATE.totalScraped = 0;
        
        log(`🚀 任务启动 | 源: ${source} | 自动下载: ${autoDownload ? '✅开启' : '❌关闭'}`, 'success');

        if (source === 'madou') {
            const req = getRequest('https://madouqu.com/');
            await scrapeMadouQu(req, limitPages, autoDownload);
        } else if (source === 'xchina') {
            const req = getRequest('https://xchina.co/');
            await scrapeXChina(req, limitPages, autoDownload);
        } else {
            log(`❌ 未知的采集源: ${source}`, 'error');
        }

        STATE.isRunning = false;
        log(`🏁 任务结束，本次共入库 ${STATE.totalScraped} 条`, 'warn');
    }
};
module.exports = Scraper;
EOF

# 2. 更新版本号
echo "📝 更新 /app/package.json..."
sed -i 's/"version": ".*"/"version": "13.7.4"/' /app/package.json

echo "✅ 升级完成 (v13.7.4)，系统将自动重启..."
