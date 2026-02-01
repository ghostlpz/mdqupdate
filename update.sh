#!/bin/bash
# VERSION = 13.9.1

echo "🚑 检测到 Chromium 缺失，开始执行 V13.9.1 环境修复..."

# 1. 切换为阿里云镜像源 (解决国内下载失败的问题)
echo "⚡ 正在切换 Alpine 软件源为阿里云..."
sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories

# 2. 更新索引并安装 Chromium
echo "⏳ 正在重装 Chromium (请耐心等待下载)..."
apk update
apk add --no-cache \
    chromium \
    nss \
    freetype \
    harfbuzz \
    ca-certificates \
    ttf-freefont \
    libstdc++

# 3. 验证安装
if [ -f "/usr/bin/chromium-browser" ]; then
    echo "✅ Chromium 安装成功！路径: /usr/bin/chromium-browser"
elif [ -f "/usr/bin/chromium" ]; then
    echo "✅ Chromium 安装成功！路径: /usr/bin/chromium"
else
    echo "❌ 严重警告: Chromium 依然未找到！请检查网络连接。"
fi

# 4. 更新 scraper.js (增加路径自动探测功能)
echo "📝 更新 /app/modules/scraper.js (增加路径容错)..."
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

// 自动寻找 Chromium 可执行文件
function findChromium() {
    const paths = [
        '/usr/bin/chromium-browser', // Alpine 默认
        '/usr/bin/chromium',         // 备用
        '/usr/bin/google-chrome-stable'
    ];
    for (const p of paths) {
        if (fs.existsSync(p)) return p;
    }
    return null;
}

async function solveCloudflare(targetUrl) {
    log(`🛡️ 触发 Cloudflare 拦截，准备启动浏览器...`, 'warn');
    
    const execPath = findChromium();
    if (!execPath) {
        log(`❌ 致命错误: 未找到 Chromium 浏览器！请检查 Docker 环境。`, 'error');
        return null;
    }

    let browser = null;
    try {
        const launchArgs = ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'];
        if (global.CONFIG.proxy) {
            const proxyUrl = global.CONFIG.proxy.replace('http://', '').replace('https://', '');
            launchArgs.push(`--proxy-server=${proxyUrl}`);
        }

        browser = await puppeteer.launch({
            executablePath: execPath, // 使用自动探测到的路径
            headless: 'new',
            args: launchArgs
        });

        const page = await browser.newPage();
        const fakeUA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
        await page.setUserAgent(fakeUA);

        log(`🛡️ 浏览器正在访问目标...`);
        await page.goto(targetUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });
        await new Promise(r => setTimeout(r, 8000)); // 等待盾牌消失

        const cookies = await page.cookies();
        const cookieStr = cookies.map(c => `${c.name}=${c.value}`).join('; ');
        const userAgent = await page.evaluate(() => navigator.userAgent);

        log(`✅ 成功获取通行证!`, 'success');
        return { cookie: cookieStr, ua: userAgent };

    } catch (e) {
        log(`❌ 浏览器破解失败: ${e.message}`, 'error');
        return null;
    } finally {
        if (browser) await browser.close();
    }
}

function getRequest(referer) {
    const userAgent = (global.CONFIG.userAgent && global.CONFIG.userAgent.trim() !== '') 
        ? global.CONFIG.userAgent.trim() 
        : 'Mozilla/5.0';

    const headers = {
        'User-Agent': userAgent,
        'Referer': referer,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
        'Upgrade-Insecure-Requests': '1'
    };
    
    if (global.CONFIG.scraperCookie && global.CONFIG.scraperCookie.trim() !== '') {
        headers['Cookie'] = global.CONFIG.scraperCookie.trim();
    }

    const options = {
        headers: headers,
        timeout: 20000,
        validateStatus: status => status >= 200 && status < 600
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
    let page = 1;
    let url = "https://xchina.co/videos.html";
    const domain = "https://xchina.co";
    
    log(`==== 启动 XChina (混合动力模式) ====`, 'info');
    let retryCount = 0;

    while (page <= limitPages && !STATE.stopSignal) {
        log(`[XChina] 正在请求第 ${page} 页: ${url}`, 'info');
        let request = getRequest(domain);

        try {
            const res = await request.get(url);

            if (res.status === 403 || res.status === 503 || (typeof res.data === 'string' && res.data.includes('challenge-platform'))) {
                if (retryCount >= 3) { log(`❌ 连续破解失败，停止任务。`, 'error'); break; }
                const tokens = await solveCloudflare(url);
                if (tokens) {
                    global.CONFIG.scraperCookie = tokens.cookie;
                    global.CONFIG.userAgent = tokens.ua;
                    global.saveConfig();
                    log(`🔄 凭证已更新，正在重试...`, 'info');
                    retryCount++;
                    await new Promise(r => setTimeout(r, 2000));
                    continue; 
                } else { break; }
            }

            retryCount = 0;
            const $ = cheerio.load(res.data);
            const posts = $('.list.video-index .item.video');

            if (posts.length === 0) { log(`⚠️ 未找到视频`, 'warn'); break; }
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
                    request = getRequest(url);
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
                                    if (pushRes) extraMsg = " | 📥 已推115";
                                }
                                log(`✅ [入库${extraMsg}] ${title.substring(0, 15)}...`, 'success');
                            }
                        }
                    }
                } catch (e) { log(`❌ 解析失败: ${e.message}`, 'error'); }
                await new Promise(r => setTimeout(r, 1000)); 
            }

            const nextHref = $('.pagination a:contains("下一页"), .pagination a:contains("Next"), a.next').attr('href');
            if (nextHref) {
                url = nextHref.startsWith('/') ? domain + nextHref : nextHref;
                page++;
                await new Promise(r => setTimeout(r, 2000));
            } else { break; }

        } catch (err) {
            log(`❌ 网络错误: ${err.message}`, 'error');
            await new Promise(r => setTimeout(r, 5000));
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

# 5. 更新版本号
echo "📝 更新 /app/package.json..."
sed -i 's/"version": ".*"/"version": "13.9.1"/' /app/package.json

echo "✅ 修复完成，系统将重启并生效..."
