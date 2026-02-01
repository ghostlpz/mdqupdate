#!/bin/bash
# VERSION = 13.8.0

echo "🔥 收到挑战！开始部署核武级更新 V13.8.0 (Puppeteer 浏览器内核)..."
echo "⏳ 正在安装 Chromium 及相关依赖 (可能需要几分钟，请勿中断)..."

# 1. 安装系统级依赖 (Alpine Linux)
# 这一步是为了让 Docker 容器能跑起来真正的 Chrome
apk add --no-cache \
    chromium \
    nss \
    freetype \
    harfbuzz \
    ca-certificates \
    ttf-freefont \
    libstdc++

echo "✅ Chromium 安装完成！"

# 2. 更新 package.json 加入 puppeteer-core
echo "📝 更新 /app/package.json..."
# 使用临时文件确保 JSON 格式正确
cat > /app/package.json << 'EOF'
{
  "name": "madou-omni-system",
  "version": "13.8.0",
  "main": "app.js",
  "dependencies": {
    "axios": "^1.6.0",
    "cheerio": "^1.0.0-rc.12",
    "cookie-parser": "^1.4.6",
    "cors": "^2.8.5",
    "express": "^4.18.2",
    "https-proxy-agent": "^7.0.2",
    "mysql2": "^3.6.5",
    "node-schedule": "^2.1.1",
    "json2csv": "^6.0.0-alpha.2",
    "puppeteer-core": "^21.0.0"
  }
}
EOF

# 3. 更新爬虫模块 (scraper.js) - 引入 Puppeteer
echo "📝 更新 /app/modules/scraper.js..."
cat > /app/modules/scraper.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const { HttpsProxyAgent } = require('https-proxy-agent');
const puppeteer = require('puppeteer-core'); // 引入 puppeteer
const ResourceMgr = require('./resource_mgr');

let STATE = { isRunning: false, stopSignal: false, logs: [], totalScraped: 0 };

function log(msg, type='info') {
    STATE.logs.push({ time: new Date().toLocaleTimeString(), msg, type });
    if (STATE.logs.length > 200) STATE.logs.shift();
    console.log(`[Scraper] ${msg}`);
}

// 普通 HTTP 请求 (用于 Madou)
function getRequest() {
    const options = {
        headers: { 'User-Agent': global.CONFIG.userAgent || 'Mozilla/5.0' },
        timeout: 20000
    };
    if (global.CONFIG.proxy && global.CONFIG.proxy.startsWith('http')) {
        const agent = new HttpsProxyAgent(global.CONFIG.proxy);
        options.httpAgent = agent;
        options.httpsAgent = agent;
    }
    return axios.create(options);
}

// 115 推送
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

// MadouQu 采集逻辑 (保持 Axios，因为它没盾且快)
async function scrapeMadouQu(limitPages, autoDownload) {
    const request = getRequest();
    let page = 1;
    let url = "https://madouqu.com/";
    log(`==== 启动 MadouQu (轻量模式) ====`, 'info');
    while (page <= limitPages && !STATE.stopSignal) {
        log(`[Madou] 抓取第 ${page} 页...`, 'info');
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
                            if (autoDownload) pushTo115(match[0]);
                            log(`✅ [入库] ${title.substring(0,15)}...`, 'success');
                        }
                    }
                } catch (e) {}
                await new Promise(r => setTimeout(r, 1000));
            }
            const next = $('a.next').attr('href');
            if (next) { url = next; page++; } else break;
        } catch (e) { log(`❌ [Madou] 错误: ${e.message}`, 'error'); await new Promise(r => setTimeout(r, 3000)); }
    }
}

// XChina 采集逻辑 (使用 Puppeteer 真浏览器)
async function scrapeXChina(limitPages, autoDownload) {
    log(`==== 启动 XChina (浏览器内核模式) ====`, 'info');
    log(`⚙️ 正在启动 Chromium... (首次启动较慢)`, 'warn');

    let browser = null;
    try {
        // 配置启动参数
        const launchArgs = [
            '--no-sandbox', 
            '--disable-setuid-sandbox',
            '--disable-dev-shm-usage',
            '--disable-gpu'
        ];
        
        // 如果配置了代理，传给浏览器
        if (global.CONFIG.proxy) {
            const proxyUrl = global.CONFIG.proxy.replace('http://', '').replace('https://', '');
            launchArgs.push(`--proxy-server=${proxyUrl}`);
        }

        browser = await puppeteer.launch({
            executablePath: '/usr/bin/chromium-browser', // Alpine 安装的路径
            headless: 'new',
            args: launchArgs
        });

        const page = await browser.newPage();
        
        // 设置浏览器指纹
        const ua = global.CONFIG.userAgent || 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
        await page.setUserAgent(ua);

        // 设置 Cookie (关键！)
        if (global.CONFIG.scraperCookie) {
            const cookieStr = global.CONFIG.scraperCookie;
            const cookies = cookieStr.split(';').map(pair => {
                const [name, ...value] = pair.trim().split('=');
                return { name, value: value.join('='), domain: '.xchina.co' };
            }).filter(c => c.name && c.value);
            if (cookies.length > 0) await page.setCookie(...cookies);
        }

        let currPage = 1;
        let url = "https://xchina.co/videos.html";
        const domain = "https://xchina.co";

        while (currPage <= limitPages && !STATE.stopSignal) {
            log(`[XChina] 正在渲染第 ${currPage} 页...`);
            
            // 访问列表页
            await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
            
            // 获取页面内容传给 cheerio 处理 (比在浏览器里跑 JS 快)
            const content = await page.content();
            const $ = cheerio.load(content);
            
            // 检查是不是被拦了
            if ($('title').text().includes('Just a moment') || content.includes('challenge-platform')) {
                log(`❌ [XChina] 浏览器盾牌验证未通过，请更新 Cookie`, 'error');
                break;
            }

            const posts = $('.list.video-index .item.video');
            if (posts.length === 0) { log(`⚠️ 未找到视频，可能已到底`, 'warn'); break; }

            // 获取本页所有链接，然后一个个去详情页
            const items = [];
            posts.each((i, el) => {
                const titleTag = $(el).find('.text .title a');
                let href = titleTag.attr('href');
                if (href && href.startsWith('/')) href = domain + href;
                items.push({ title: titleTag.text().trim(), link: href });
            });

            log(`[XChina] 发现 ${items.length} 个视频，开始逐个解析...`);

            for (const item of items) {
                if (STATE.stopSignal) break;
                try {
                    // 进入详情页
                    await page.goto(item.link, { waitUntil: 'domcontentloaded', timeout: 30000 });
                    const dContent = await page.content();
                    const $d = cheerio.load(dContent);
                    
                    // 找下载页链接
                    let dlLink = $d('a[href*="/download/id-"]').attr('href');
                    if (dlLink) {
                        if (dlLink.startsWith('/')) dlLink = domain + dlLink;
                        
                        // 进入下载页
                        await page.goto(dlLink, { waitUntil: 'domcontentloaded', timeout: 30000 });
                        const dlContent = await page.content();
                        const $dl = cheerio.load(dlContent);
                        
                        const magnet = $dl('a.btn.magnet[href^="magnet:"]').attr('href');
                        if (magnet) {
                             const saved = await ResourceMgr.save(item.title, item.link, magnet);
                             if(saved) {
                                STATE.totalScraped++;
                                if (autoDownload) pushTo115(magnet);
                                log(`✅ [入库] ${item.title.substring(0, 15)}...`, 'success');
                             }
                        }
                    }
                } catch (e) { log(`❌ 解析失败: ${e.message}`, 'error'); }
                
                // 稍微休息下，模拟真人
                await new Promise(r => setTimeout(r, 2000));
            }

            // 翻页逻辑
            const nextHref = $('.pagination a:contains("下一页"), .pagination a:contains("Next"), a.next').attr('href');
            if (nextHref) {
                url = nextHref.startsWith('/') ? domain + nextHref : nextHref;
                currPage++;
            } else {
                break;
            }
        }

    } catch (e) {
        log(`🔥 浏览器核心崩溃: ${e.message}`, 'error');
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

echo "✅ 核心模块替换完成！"
echo "♻️  正在重启服务以应用新依赖..."
