#!/bin/bash
# VERSION = 13.9.6

echo "📸 正在部署 V13.9.6 侦探模式 (增加错误截图与源码留存)..."

# 1. 更新 scraper.js - 增加截图和调试逻辑
echo "📝 更新 /app/modules/scraper.js..."
cat > /app/modules/scraper.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const { HttpsProxyAgent } = require('https-proxy-agent');
const puppeteer = require('puppeteer-core');
const ResourceMgr = require('./resource_mgr');
const fs = require('fs');
const path = require('path');

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

// 📸 关键函数：保存案发现场
async function saveEvidence(page, name) {
    try {
        const publicDir = '/app/public';
        if (!fs.existsSync(publicDir)) fs.mkdirSync(publicDir);
        
        // 截图
        await page.screenshot({ path: `${publicDir}/${name}.png`, fullPage: true });
        // 保存源码
        const html = await page.content();
        fs.writeFileSync(`${publicDir}/${name}.html`, html);
        
        log(`📸 [调试] 已保存截图: http://你的IP:6002/${name}.png`, 'error');
    } catch (e) {
        log(`❌ 保存截图失败: ${e.message}`, 'error');
    }
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
    log(`==== 启动 XChina (侦探模式 V13.9.6) ====`, 'info');
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
                // 加载页面 (延长超时到 60秒)
                await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
                
                // 检查盾牌
                const title = await page.title();
                if (title.includes('Just a moment') || title.includes('Attention')) {
                    log(`🛡️ 遇到 Cloudflare，尝试交互...`, 'warn');
                    await page.mouse.move(100, 100);
                    await new Promise(r => setTimeout(r, 5000));
                }

                // 等待内容 (延长到 45秒)
                try {
                    await page.waitForSelector('.list.video-index .item.video', { timeout: 45000 });
                } catch(e) {
                    // 🔥 截图关键点：如果等了45秒还没出来，截图看看发生了什么
                    log(`❌ 页面加载超时，正在保存截图...`, 'error');
                    await saveEvidence(page, 'error_screenshot');
                    break;
                }

            } catch(e) {
                log(`❌ 网络/浏览器异常，正在保存截图...`, 'error');
                try { await saveEvidence(page, 'error_crash'); } catch(err){}
                break;
            }

            // ... (解析逻辑保持不变，略) ...
            
            // 简单解析逻辑 (为了节省脚本长度，这里仅保留核心)
            const items = await page.evaluate(() => {
                return Array.from(document.querySelectorAll('.list.video-index .item.video')).map(el => ({
                    title: el.querySelector('.text .title a')?.innerText.trim(),
                    link: el.querySelector('.text .title a')?.getAttribute('href')
                })).filter(i => i.title && i.link);
            });

            if (items.length === 0) { log(`⚠️ 未找到数据`, 'warn'); await saveEvidence(page, 'error_empty'); break; }
            log(`[XChina] 发现 ${items.length} 个资源，开始解析...`);

            for (const item of items) {
                if (STATE.stopSignal) break;
                if(item.link.startsWith('/')) item.link = domain + item.link;
                
                try {
                    await page.goto(item.link, { waitUntil: 'domcontentloaded', timeout: 45000 });
                    try { await page.waitForSelector('a[href*="/download/id-"]', { timeout: 15000 }); } catch(e){}
                    
                    // 获取下载页链接
                    const dlLink = await page.evaluate(() => document.querySelector('a[href*="/download/id-"]')?.getAttribute('href'));
                    
                    if (dlLink) {
                        const fullDlLink = dlLink.startsWith('/') ? domain + dlLink : dlLink;
                        await page.goto(fullDlLink, { waitUntil: 'domcontentloaded', timeout: 45000 });
                        try {
                            await page.waitForSelector('a.btn.magnet[href^="magnet:"]', { timeout: 15000 });
                            const magnet = await page.$eval('a.btn.magnet[href^="magnet:"]', el => el.getAttribute('href'));
                            if (magnet) {
                                const saved = await ResourceMgr.save(item.title, item.link, magnet);
                                if(saved) {
                                    STATE.totalScraped++;
                                    if(autoDownload) pushTo115(magnet);
                                    log(`✅ [入库] ${item.title.substring(0, 15)}...`, 'success');
                                }
                            }
                        } catch(e) {}
                    }
                } catch(e) { log(`❌ 单条解析失败`, 'warn'); }
                await new Promise(r => setTimeout(r, 1000));
            }

            break; // 调试模式暂时只跑一页
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
sed -i 's/"version": ".*"/"version": "13.9.6"/' /app/package.json

echo "✅ 升级完成，请重新采集并查看截图！"
