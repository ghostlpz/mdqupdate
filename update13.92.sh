#!/bin/bash
# VERSION = 13.9.2

echo "🚀 正在部署 V13.9.2 纯浏览器直连版 (解决 TLS 指纹死循环)..."

# 1. 更新 scraper.js - 彻底重写 XChina 逻辑
echo "📝 更新 /app/modules/scraper.js..."
cat > /app/modules/scraper.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const { HttpsProxyAgent } = require('https-proxy-agent');
const puppeteer = require('puppeteer-core');
const ResourceMgr = require('./resource_mgr');
const fs = require('fs');

let STATE = { isRunning: false, stopSignal: false, logs: [], totalScraped: 0 };

function log(msg, type='info') {
    STATE.logs.push({ time: new Date().toLocaleTimeString(), msg, type });
    if (STATE.logs.length > 200) STATE.logs.shift();
    console.log(`[Scraper] ${msg}`);
}

function findChromium() {
    const paths = ['/usr/bin/chromium-browser', '/usr/bin/chromium', '/usr/bin/google-chrome-stable'];
    for (const p of paths) { if (fs.existsSync(p)) return p; }
    return null;
}

// 通用 HTTP 请求 (仅用于 Madou 和 推送)
function getRequest() {
    const userAgent = global.CONFIG.userAgent || 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    const options = { headers: { 'User-Agent': userAgent }, timeout: 20000 };
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

async function scrapeMadouQu(limitPages, autoDownload) {
    let page = 1;
    let url = "https://madouqu.com/";
    const request = getRequest();
    log(`==== 启动 MadouQu 采集 ====`, 'info');
    while (page <= limitPages && !STATE.stopSignal) {
        try {
            const res = await request.get(url);
            const $ = cheerio.load(res.data);
            const posts = $('article h2.entry-title a, h2.entry-title a');
            if (posts.length === 0) break;
            for (let i = 0; i < posts.length; i++) {
                if (STATE.stopSignal) break;
                const link = $(posts[i]).attr('href');
                const title = $(posts[i]).text().trim();
                try {
                    const detail = await request.get(link);
                    const match = detail.data.match(/magnet:\?xt=urn:btih:[a-zA-Z0-9]{32,40}/gi);
                    if (match) {
                        const saved = await ResourceMgr.save(title, link, match[0]);
                        if(saved) {
                            STATE.totalScraped++;
                            if(autoDownload) pushTo115(match[0]);
                            log(`✅ [入库] ${title.substring(0,10)}...`, 'success');
                        }
                    }
                } catch(e) {}
                await new Promise(r => setTimeout(r, 1000));
            }
            const next = $('a.next').attr('href');
            if (next) { url = next; page++; } else break;
        } catch (e) { log(`Error: ${e.message}`, 'error'); break; }
    }
}

// XChina 纯浏览器逻辑
async function scrapeXChina(limitPages, autoDownload) {
    log(`==== 启动 XChina (纯浏览器极速版) ====`, 'info');
    const execPath = findChromium();
    if (!execPath) { log(`❌ 未找到 Chromium`, 'error'); return; }

    let browser = null;
    try {
        const launchArgs = ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'];
        if (global.CONFIG.proxy) {
            const proxyUrl = global.CONFIG.proxy.replace('http://', '').replace('https://', '');
            launchArgs.push(`--proxy-server=${proxyUrl}`);
        }

        browser = await puppeteer.launch({ executablePath: execPath, headless: 'new', args: launchArgs });
        const page = await browser.newPage();
        
        // 🚀 性能优化：拦截图片、样式、字体
        await page.setRequestInterception(true);
        page.on('request', (req) => {
            const resourceType = req.resourceType();
            if (['image', 'stylesheet', 'font', 'media'].includes(resourceType)) {
                req.abort();
            } else {
                req.continue();
            }
        });

        // 伪装 UA
        await page.setUserAgent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');

        let currPage = 1;
        let url = "https://xchina.co/videos.html";
        const domain = "https://xchina.co";

        while (currPage <= limitPages && !STATE.stopSignal) {
            log(`[XChina] 浏览器正在渲染第 ${currPage} 页...`);
            
            // 访问列表页
            try {
                await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
            } catch(e) {
                log(`❌ 页面加载超时，跳过本页`, 'warn');
                break;
            }

            const content = await page.content();
            const $ = cheerio.load(content);
            
            // 检查 CF 盾
            if ($('title').text().includes('Just a moment') || content.includes('challenge-platform')) {
                log(`🛡️ 遇到 Cloudflare，等待 5 秒自动验证...`, 'warn');
                await new Promise(r => setTimeout(r, 5000));
                // 重新获取内容
                const newContent = await page.content();
                if (newContent.includes('challenge-platform')) {
                    log(`❌ 验证超时，可能需要更换 IP`, 'error');
                    break;
                }
            }

            const posts = $('.list.video-index .item.video');
            if (posts.length === 0) { log(`⚠️ 未找到视频`, 'warn'); break; }

            // 提取本页所有链接
            const items = [];
            posts.each((i, el) => {
                const titleTag = $(el).find('.text .title a');
                let href = titleTag.attr('href');
                if (href && href.startsWith('/')) href = domain + href;
                items.push({ title: titleTag.text().trim(), link: href });
            });

            log(`[XChina] 本页发现 ${items.length} 个资源，开始解析...`);

            for (const item of items) {
                if (STATE.stopSignal) break;
                
                try {
                    // 直接用同一个标签页跳转，保持会话
                    await page.goto(item.link, { waitUntil: 'domcontentloaded', timeout: 30000 });
                    const dContent = await page.content();
                    const $d = cheerio.load(dContent);
                    
                    let dlLink = $d('a[href*="/download/id-"]').attr('href');
                    if (dlLink) {
                        if (dlLink.startsWith('/')) dlLink = domain + dlLink;
                        
                        await page.goto(dlLink, { waitUntil: 'domcontentloaded', timeout: 30000 });
                        const dlContent = await page.content();
                        const $dl = cheerio.load(dlContent);
                        
                        const magnet = $dl('a.btn.magnet[href^="magnet:"]').attr('href');
                        if (magnet) {
                            const saved = await ResourceMgr.save(item.title, item.link, magnet);
                            if(saved) {
                                STATE.totalScraped++;
                                let extraMsg = "";
                                if (autoDownload) {
                                    const pushed = await pushTo115(magnet);
                                    if(pushed) extraMsg = " | 📥 已推115";
                                }
                                log(`✅ [入库${extraMsg}] ${item.title.substring(0, 15)}...`, 'success');
                            }
                        }
                    }
                } catch (e) {
                    log(`❌ 解析单条失败: ${e.message}`, 'error');
                }
                // 稍微休息，太快会被封
                await new Promise(r => setTimeout(r, 1500));
            }

            // 翻页
            const nextHref = $('.pagination a:contains("下一页"), .pagination a:contains("Next"), a.next').attr('href');
            if (nextHref) {
                url = nextHref.startsWith('/') ? domain + nextHref : nextHref;
                currPage++;
                await new Promise(r => setTimeout(r, 2000));
            } else {
                break;
            }
        }

    } catch (e) {
        log(`🔥 浏览器异常: ${e.message}`, 'error');
    } finally {
        if (browser) await browser.close();
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
            await scrapeMadouQu(limitPages, autoDownload);
        } else if (source === 'xchina') {
            await scrapeXChina(limitPages, autoDownload);
        }

        STATE.isRunning = false;
        log(`🏁 任务结束，本次共入库 ${STATE.totalScraped} 条`, 'warn');
    }
};
module.exports = Scraper;
EOF

# 2. 更新版本号
echo "📝 更新 /app/package.json..."
sed -i 's/"version": ".*"/"version": "13.9.2"/' /app/package.json

echo "✅ 升级完成 (V13.9.2)，系统将重启..."
