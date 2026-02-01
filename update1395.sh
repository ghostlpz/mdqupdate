#!/bin/bash
# VERSION = 13.9.5

echo "🚑 正在部署 V13.9.5 故障诊断版 (开启详细内核日志)..."

# 1. 再次确保依赖完整 (防止上次没装全)
echo "📦 检查系统依赖..."
apk update
apk add --no-cache \
    chromium \
    nss \
    freetype \
    harfbuzz \
    ca-certificates \
    ttf-freefont \
    libstdc++ \
    udev \
    ttf-opensans \
    mesa-gl

# 2. 更新 scraper.js - 开启 dumpio 和防崩溃参数
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
    // 保持原样...
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
    log(`==== 启动 XChina (诊断模式 V13.9.5) ====`, 'info');
    const execPath = findChromium();
    if (!execPath) { log(`❌ 未找到 Chromium`, 'error'); return; }

    let browser = null;
    try {
        const launchArgs = [
            '--no-sandbox', 
            '--disable-setuid-sandbox', 
            '--disable-dev-shm-usage', // 关键：解决 Docker 内存不足崩溃
            '--disable-gpu',           // 关键：NAS 通常没显卡
            '--no-first-run',
            '--no-zygote',             // 关键：Alpine 下防止僵尸进程
            '--single-process',        // 关键：省内存模式
            '--disable-extensions',
            '--disable-blink-features=AutomationControlled'
        ];
        
        if (global.CONFIG.proxy) {
            const proxyUrl = global.CONFIG.proxy.replace('http://', '').replace('https://', '');
            launchArgs.push(`--proxy-server=${proxyUrl}`);
        }

        log(`⚙️ 正在启动浏览器内核...`);
        
        browser = await puppeteer.launch({ 
            executablePath: execPath, 
            headless: 'new', 
            args: launchArgs,
            dumpio: true // 🔥 开启黑匣子：将浏览器内部错误打印到终端
        });

        const page = await browser.newPage();
        
        // 伪装脚本
        await page.evaluateOnNewDocument(() => {
            Object.defineProperty(navigator, 'webdriver', { get: () => false });
        });

        await page.setRequestInterception(true);
        page.on('request', (req) => {
            if (['image', 'stylesheet', 'font', 'media'].includes(req.resourceType())) req.abort();
            else req.continue();
        });

        await page.setUserAgent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');

        let currPage = 1;
        let url = "https://xchina.co/videos.html";
        const domain = "https://xchina.co";

        while (currPage <= limitPages && !STATE.stopSignal) {
            log(`[XChina] 正在加载第 ${currPage} 页...`);
            
            try {
                await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
                
                const title = await page.title();
                if (title.includes('Just a moment') || title.includes('Attention')) {
                    log(`🛡️ 遇到 Cloudflare，模拟验证中...`, 'warn');
                    for(let k=0; k<15; k++) { // 延长等待到 15次循环
                        if (STATE.stopSignal) break;
                        try {
                            await page.mouse.move(Math.random()*500, Math.random()*500);
                        } catch(e){}
                        await new Promise(r => setTimeout(r, 2000)); // 每2秒动一次
                        
                        const t = await page.title();
                        if (!t.includes('Just a moment') && !t.includes('Attention')) {
                            log(`✨ 验证通过！`, 'success');
                            break;
                        }
                    }
                }

                await page.waitForSelector('.list.video-index .item.video', { timeout: 30000 });

            } catch(e) {
                log(`❌ 加载超时或验证失败: ${e.message}`, 'warn');
                break;
            }

            const items = await page.evaluate((domain) => {
                const els = document.querySelectorAll('.list.video-index .item.video');
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

            if (items.length === 0) { log(`⚠️ 未找到数据`, 'warn'); break; }
            log(`[XChina] 发现 ${items.length} 个资源...`);

            for (const item of items) {
                if (STATE.stopSignal) break;
                try {
                    await page.goto(item.link, { waitUntil: 'domcontentloaded', timeout: 30000 });
                    try { await page.waitForSelector('a[href*="/download/id-"]', { timeout: 10000 }); } catch(e){}

                    const dlLink = await page.evaluate((domain) => {
                        const a = document.querySelector('a[href*="/download/id-"]');
                        if(!a) return null;
                        let href = a.getAttribute('href');
                        if(href && href.startsWith('/')) return domain + href;
                        return href;
                    }, domain);

                    if (dlLink) {
                        await page.goto(dlLink, { waitUntil: 'domcontentloaded', timeout: 30000 });
                        try {
                            await page.waitForSelector('a.btn.magnet[href^="magnet:"]', { timeout: 10000 });
                            const magnet = await page.$eval('a.btn.magnet[href^="magnet:"]', el => el.getAttribute('href'));
                            if (magnet) {
                                const saved = await ResourceMgr.save(item.title, item.link, magnet);
                                if(saved) {
                                    STATE.totalScraped++;
                                    let extraMsg = "";
                                    if (autoDownload) {
                                        const pushed = await pushTo115(magnet);
                                        if(pushed) extraMsg = " | 📥 推送OK";
                                    }
                                    log(`✅ [入库${extraMsg}] ${item.title.substring(0, 15)}...`, 'success');
                                }
                            }
                        } catch(e) {}
                    }
                } catch (e) { log(`❌ 单条错误: ${e.message}`, 'error'); }
                await new Promise(r => setTimeout(r, 1500));
            }

            const nextHref = await page.evaluate((domain) => {
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
            } else { break; }
        }

    } catch (e) {
        log(`🔥 浏览器严重崩溃: ${e.message}`, 'error');
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

# 3. 更新版本号
echo "📝 更新 /app/package.json..."
sed -i 's/"version": ".*"/"version": "13.9.5"/' /app/package.json

echo "✅ 升级完成，系统将重启..."
