#!/bin/bash
# VERSION = 13.9.4

echo "🚀 正在部署 V13.9.4 修复版 (增加鼠标模拟 & 延长验证等待时间)..."

# 1. 更新 scraper.js - 修复等待逻辑
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

// XChina 增强版逻辑
async function scrapeXChina(limitPages, autoDownload) {
    log(`==== 启动 XChina (隐身+鼠标模拟 V13.9.4) ====`, 'info');
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
            '--window-size=1920,1080' // 设置大窗口，看起来像电脑
        ];
        if (global.CONFIG.proxy) {
            const proxyUrl = global.CONFIG.proxy.replace('http://', '').replace('https://', '');
            launchArgs.push(`--proxy-server=${proxyUrl}`);
        }

        browser = await puppeteer.launch({ executablePath: execPath, headless: 'new', args: launchArgs });
        const page = await browser.newPage();
        
        // 伪装脚本
        await page.evaluateOnNewDocument(() => {
            Object.defineProperty(navigator, 'webdriver', { get: () => false });
            // 增加更多伪装
            window.chrome = { runtime: {} };
            Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3] });
            Object.defineProperty(navigator, 'languages', { get: () => ['zh-CN', 'zh'] });
        });

        // 拦截资源
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
            log(`[XChina] 浏览器正在加载第 ${currPage} 页...`);
            
            try {
                // 加载页面
                await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
                
                // === 智能验证核心修复 ===
                // 检查是否遇到盾牌
                const title = await page.title();
                if (title.includes('Just a moment') || title.includes('Attention Required')) {
                    log(`🛡️ 遇到 Cloudflare，开始模拟真人验证 (最多等30秒)...`, 'warn');
                    
                    // 模拟鼠标乱动 (模拟人类焦急等待)
                    for(let k=0; k<10; k++) {
                        if (STATE.stopSignal) break;
                        try {
                            await page.mouse.move(Math.random()*500, Math.random()*500);
                            await page.mouse.down();
                            await page.mouse.up();
                        } catch(e){}
                        await new Promise(r => setTimeout(r, 1000));
                        
                        // 每次动完检查一下是不是通过了
                        const currentTitle = await page.title();
                        if (!currentTitle.includes('Just a moment') && !currentTitle.includes('Attention')) {
                            log(`✨ 验证通过！进入页面...`, 'success');
                            break;
                        }
                    }
                }

                // 强制等待关键元素出现 (这是最稳的，不再依赖固定时间)
                try {
                    await page.waitForSelector('.list.video-index .item.video', { timeout: 30000 });
                } catch(e) {
                    // 如果等了30秒还没出来，说明真的卡住了
                    log(`❌ 验证超时或页面结构变更 (未找到视频列表)`, 'error');
                    // 截图保存以供调试 (可选，这里先只打日志)
                    // const html = await page.content();
                    // log(`Debug: ${html.substring(0, 100)}`);
                    break;
                }

            } catch(e) {
                log(`❌ 页面加载异常: ${e.message}`, 'warn');
                break;
            }

            // 获取数据
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

            if (items.length === 0) { log(`⚠️ 本页无数据`, 'warn'); break; }
            log(`[XChina] 发现 ${items.length} 个资源，开始采集...`);

            for (const item of items) {
                if (STATE.stopSignal) break;
                try {
                    await page.goto(item.link, { waitUntil: 'domcontentloaded', timeout: 30000 });
                    
                    // 详情页也可能遇到验证，稍微等一下
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
                                        if(pushed) extraMsg = " | 📥 已推115";
                                    }
                                    log(`✅ [入库${extraMsg}] ${item.title.substring(0, 15)}...`, 'success');
                                }
                            }
                        } catch(e) {}
                    }
                } catch (e) { log(`❌ 单条失败: ${e.message}`, 'error'); }
                await new Promise(r => setTimeout(r, 1000));
            }

            // 翻页
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
sed -i 's/"version": ".*"/"version": "13.9.4"/' /app/package.json

echo "✅ 升级完成 (V13.9.4)，系统将重启..."
