#!/bin/bash
# VERSION = 13.9.7

echo "🚀 正在部署 V13.9.7 强行读取版 (针对情况D优化)..."

# 1. 更新 scraper.js - 忽略超时，强行解析
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

async function scrapeXChina(limitPages, autoDownload) {
    log(`==== 启动 XChina (强行读取版 V13.9.7) ====`, 'info');
    const execPath = findChromium();
    if (!execPath) { log(`❌ 未找到 Chromium`, 'error'); return; }

    let browser = null;
    try {
        const launchArgs = [
            '--no-sandbox', 
            '--disable-setuid-sandbox', 
            '--disable-dev-shm-usage',
            '--disable-gpu',
            '--disable-blink-features=AutomationControlled',
            '--window-size=1280,800'
        ];
        
        if (global.CONFIG.proxy) {
            const proxyUrl = global.CONFIG.proxy.replace('http://', '').replace('https://', '');
            launchArgs.push(`--proxy-server=${proxyUrl}`);
        }

        browser = await puppeteer.launch({ executablePath: execPath, headless: 'new', args: launchArgs });
        const page = await browser.newPage();
        
        // 伪装
        await page.evaluateOnNewDocument(() => {
            Object.defineProperty(navigator, 'webdriver', { get: () => false });
        });
        await page.setUserAgent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');

        let currPage = 1;
        let url = "https://xchina.co/videos.html";
        const domain = "https://xchina.co";

        while (currPage <= limitPages && !STATE.stopSignal) {
            log(`[XChina] 浏览器正在加载第 ${currPage} 页...`);
            
            try {
                // 加载页面
                await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
                
                // 检查盾牌
                const title = await page.title();
                if (title.includes('Just a moment') || title.includes('Attention')) {
                    log(`🛡️ 遇到 Cloudflare，稍等片刻...`, 'warn');
                    await page.mouse.move(100, 100);
                    await new Promise(r => setTimeout(r, 8000));
                }

                // ⚡ 核心修改：尝试等待，但如果不出现也不报错，直接硬读
                try {
                    // 放宽选择器，只查 .item.video
                    await page.waitForSelector('.item.video', { timeout: 30000 });
                } catch(e) {
                    log(`⚠️ 等待超时，尝试强行读取页面内容...`, 'warn');
                }

            } catch(e) {
                log(`❌ 网络异常，尝试读取缓存...`, 'error');
            }

            // 直接提取数据 (无论上面是否超时)
            const items = await page.evaluate((domain) => {
                // 放宽选择器：只要包含 item video 样式的 div 都算
                const els = document.querySelectorAll('.item.video');
                const results = [];
                els.forEach(el => {
                    const t = el.querySelector('.text .title a');
                    if(t) {
                        let href = t.getAttribute('href');
                        if(href && href.startsWith('/')) href = domain + href;
                        results.push({ title: t.innerText.trim(), link: href });
                    }
                });
                return results;
            }, domain);

            if (items.length === 0) { 
                log(`⚠️ 本页未提取到数据 (可能还在盾牌页)`, 'warn'); 
                // 如果连续失败，可能真的被封了，这里可以加个 break 或者重试逻辑
                // 暂时先 break 避免死循环
                break; 
            }
            
            log(`[XChina] 成功提取 ${items.length} 个资源! 开始入库...`);

            for (const item of items) {
                if (STATE.stopSignal) break;
                
                // 详情页逻辑
                try {
                    await page.goto(item.link, { waitUntil: 'domcontentloaded', timeout: 45000 });
                    
                    // 同样，详情页也“硬读”
                    try { await page.waitForSelector('a[href*="/download/id-"]', { timeout: 10000 }); } catch(e){}
                    
                    const dlLink = await page.evaluate((domain) => {
                        const a = document.querySelector('a[href*="/download/id-"]');
                        if(!a) return null;
                        let href = a.getAttribute('href');
                        if(href && href.startsWith('/')) return domain + href;
                        return href;
                    }, domain);
                    
                    if (dlLink) {
                        const fullDlLink = dlLink.startsWith('/') ? domain + dlLink : dlLink;
                        await page.goto(fullDlLink, { waitUntil: 'domcontentloaded', timeout: 45000 });
                        try {
                            await page.waitForSelector('a.btn.magnet[href^="magnet:"]', { timeout: 10000 });
                            const magnet = await page.$eval('a.btn.magnet[href^="magnet:"]', el => el.getAttribute('href'));
                            if (magnet) {
                                const saved = await ResourceMgr.save(item.title, item.link, magnet);
                                if(saved) {
                                    STATE.totalScraped++;
                                    let extraMsg = "";
                                    if(autoDownload) {
                                        const pushed = await pushTo115(magnet);
                                        if(pushed) extraMsg = " | 📥 推送OK";
                                    }
                                    log(`✅ [入库${extraMsg}] ${item.title.substring(0, 15)}...`, 'success');
                                }
                            }
                        } catch(e) {}
                    }
                } catch(e) { log(`❌ 单条解析失败`, 'warn'); }
                await new Promise(r => setTimeout(r, 1000));
            }

            // 翻页
            const nextHref = await page.evaluate((domain) => {
                // 尝试多种“下一页”的选择器
                const a = document.querySelector('.pagination a:contains("下一页")') || 
                          Array.from(document.querySelectorAll('.pagination a')).find(el => el.textContent.includes('下一页') || el.textContent.includes('Next'));
                if(!a) return null;
                let href = a.getAttribute('href');
                if(href && href.startsWith('/')) return domain + href;
                return href;
            }, domain);

            if (nextHref) {
                url = nextHref;
                currPage++;
                await new Promise(r => setTimeout(r, 2000));
            } else {
                break;
            }
        }

    } catch (e) {
        log(`🔥 浏览器崩溃: ${e.message}`, 'error');
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
sed -i 's/"version": ".*"/"version": "13.9.7"/' /app/package.json

echo "✅ 升级完成，请重新采集！"
