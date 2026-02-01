#!/bin/bash
# VERSION = 13.9.9

echo "🚀 正在部署 V13.9.9 (支持采集二级页面分类标签)..."

# 1. 更新 ResourceMgr - 自动升级数据库结构
echo "📝 更新 /app/modules/resource_mgr.js..."
cat > /app/modules/resource_mgr.js << 'EOF'
const sqlite3 = require('sqlite3').verbose();
const path = require('path');

const dbPath = path.join(__dirname, '../data/database.sqlite');
const db = new sqlite3.Database(dbPath);

// 初始化数据库
db.serialize(() => {
    db.run(`CREATE TABLE IF NOT EXISTS resources (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT,
        link TEXT UNIQUE,
        magnets TEXT,
        is_pushed INTEGER DEFAULT 0,
        is_renamed INTEGER DEFAULT 0,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )`);

    // ⚡ 自动迁移：尝试添加 category 字段 (如果不存在)
    db.run("ALTER TABLE resources ADD COLUMN category TEXT", (err) => {
        // 如果报错说明字段已存在，忽略即可
    });
});

const ResourceMgr = {
    // 保存资源 (增加了 category 参数)
    save: (title, link, magnets, category = '') => {
        return new Promise((resolve, reject) => {
            const stmt = db.prepare(`INSERT OR IGNORE INTO resources (title, link, magnets, category) VALUES (?, ?, ?, ?)`);
            stmt.run(title, link, magnets, category, function(err) {
                if (err) reject(err);
                else resolve(this.changes > 0); // 如果插入成功返回 true，重复返回 false
            });
            stmt.finalize();
        });
    },

    markAsPushedByLink: (link) => {
        return new Promise((resolve, reject) => {
            db.run("UPDATE resources SET is_pushed = 1 WHERE link = ?", [link], (err) => {
                if (err) reject(err); else resolve(true);
            });
        });
    }
};

module.exports = ResourceMgr;
EOF

# 2. 更新 scraper.js - 增加分类提取逻辑
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

function cleanMagnet(magnet) {
    if (!magnet) return null;
    const match = magnet.match(/(magnet:\?xt=urn:btih:[a-zA-Z0-9]{32,40})/i);
    return match ? match[1] : magnet;
}

function getRequest() {
    const userAgent = global.CONFIG.userAgent || 'Mozilla/5.0';
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
        await axios.post('https://115.com/web/lixian/?ct=lixian&ac=add_task_url', postData, {
            headers: {
                'Cookie': global.CONFIG.cookie115,
                'User-Agent': global.CONFIG.userAgent || 'Mozilla/5.0',
                'Content-Type': 'application/x-www-form-urlencoded'
            }
        });
        return true;
    } catch (e) { return false; }
}

async function scrapeMadouQu(limitPages, autoDownload) {
    // MadouQu 暂时不支持分类提取，逻辑保持精简
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
                        const saved = await ResourceMgr.save(title, link, cleanMagnet(match[0]), 'Madou');
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
    log(`==== 启动 XChina (V13.9.9 含分类采集) ====`, 'info');
    const execPath = findChromium();
    if (!execPath) { log(`❌ 未找到 Chromium`, 'error'); return; }

    let browser = null;
    try {
        const launchArgs = ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--disable-blink-features=AutomationControlled', '--window-size=1280,800'];
        if (global.CONFIG.proxy) {
            const proxyUrl = global.CONFIG.proxy.replace('http://', '').replace('https://', '');
            launchArgs.push(`--proxy-server=${proxyUrl}`);
        }

        browser = await puppeteer.launch({ executablePath: execPath, headless: 'new', args: launchArgs });
        const page = await browser.newPage();
        
        await page.evaluateOnNewDocument(() => { Object.defineProperty(navigator, 'webdriver', { get: () => false }); });
        await page.setUserAgent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');

        let currPage = 1;
        let url = "https://xchina.co/videos.html";
        const domain = "https://xchina.co";

        while (currPage <= limitPages && !STATE.stopSignal) {
            log(`[XChina] 正在加载第 ${currPage} 页...`);
            
            try {
                await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
                // 简单的 Cloudflare 检查
                const title = await page.title();
                if (title.includes('Just a moment')) {
                    log(`🛡️ 等待 Cloudflare...`, 'warn');
                    await new Promise(r => setTimeout(r, 8000));
                }
                try { await page.waitForSelector('.item.video', { timeout: 30000 }); } catch(e) {}
            } catch(e) { log(`❌ 页面加载异常，尝试读取...`, 'error'); }

            const items = await page.evaluate((domain) => {
                const els = document.querySelectorAll('.item.video');
                return Array.from(els).map(el => ({
                    title: el.querySelector('.text .title a')?.innerText.trim(),
                    link: el.querySelector('.text .title a')?.getAttribute('href')
                })).filter(i => i.title && i.link).map(i => {
                    if(i.link.startsWith('/')) i.link = domain + i.link;
                    return i;
                });
            }, domain);

            if (items.length === 0) { log(`⚠️ 未找到数据`, 'warn'); break; }
            log(`[XChina] 发现 ${items.length} 个资源，开始解析...`);

            for (const item of items) {
                if (STATE.stopSignal) break;
                
                try {
                    // 1. 进入详情页 (二级页面)
                    await page.goto(item.link, { waitUntil: 'domcontentloaded', timeout: 45000 });
                    
                    // 2. ⚡⚡⚡ 提取分类标签 ⚡⚡⚡
                    // 通常 XChina 的面包屑在 .path 里面，或者标题下方
                    const category = await page.evaluate(() => {
                        try {
                            // 策略A: 面包屑 (首页 > 中文AV > 强奸乱伦)
                            const breadcrumbs = document.querySelectorAll('.path a, .breadcrumb a');
                            if (breadcrumbs.length > 0) {
                                // 取最后一个面包屑通常就是分类
                                return breadcrumbs[breadcrumbs.length - 1].innerText.trim();
                            }
                            // 策略B: 找包含 "中文AV" 的文本
                            const bodyText = document.body.innerText;
                            const match = bodyText.match(/中文AV\s*-\s*([^\s\n]+)/);
                            if (match) return match[1];
                            
                            return '未分类';
                        } catch(e) { return '未知'; }
                    });

                    // 3. 寻找下载页链接
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
                            const rawMagnet = await page.$eval('a.btn.magnet[href^="magnet:"]', el => el.getAttribute('href'));
                            const cleanLink = cleanMagnet(rawMagnet);

                            if (cleanLink) {
                                // 💾 保存时带上 Category
                                const saved = await ResourceMgr.save(item.title, item.link, cleanLink, category);
                                if(saved) {
                                    STATE.totalScraped++;
                                    let extraMsg = "";
                                    if(autoDownload) {
                                        await pushTo115(cleanLink);
                                        extraMsg = " | 📥 推送OK";
                                    }
                                    // 日志显示分类
                                    log(`✅ [${category}] ${item.title.substring(0, 10)}...${extraMsg}`, 'success');
                                }
                            }
                        } catch(e) {}
                    }
                } catch(e) { log(`❌ 解析失败`, 'warn'); }
                await new Promise(r => setTimeout(r, 1000));
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
        log(`🔥 浏览器崩溃: ${e.message}`, 'error');
    } finally {
        if (browser) await browser.close();
    }
}

module.exports = Scraper;
EOF

# 3. 更新 index.html - 界面显示分类
echo "📝 更新 /app/public/index.html..."
# 这里只替换 loadDb 函数和表格头，为了方便直接用 sed 替换
sed -i 's/<th class="col-title">标题<\/th>/<th class="col-title">标题<\/th><th>分类<\/th>/' /app/public/index.html

# 更新前端 JS 的渲染逻辑 (通过重新写入 index.html 的方式太暴力，建议用 sed 注入)
# 这里我们用一种巧妙的方法：替换整个 loadDb 函数的逻辑
# 注意：由于 html 文件较大，我们使用 perl 正则进行精准替换 (如果环境支持) 或者直接提示用户刷新

echo "⚡ 正在注入前端分类显示代码..."
# 我们通过覆盖 index.html 的方式来更新前端 (最稳妥)
# 获取原文件前半部分
head -n 276 /app/public/index.html > /app/public/index.html.tmp

# 插入新的 loadDb 逻辑
cat >> /app/public/index.html.tmp << 'JS_EOF'
    <script>
        async function loadDb(p) {
            if(p < 1) return;
            dbPage = p;
            document.getElementById('page-info').innerText = p;
            const pushVal = document.getElementById('filter-push').value;
            const renVal = document.getElementById('filter-ren').value;
            const res = await request(`data?page=${p}&pushed=${pushVal}&renamed=${renVal}`);
            const tbody = document.querySelector('#db-tbl tbody');
            
            // 动态更新表头 (如果还没更新)
            const thead = document.querySelector('#db-tbl thead tr');
            if(!thead.innerHTML.includes('分类')) {
                // 在标题后面插入分类列
                const titleTh = thead.querySelector('.col-title');
                const catTh = document.createElement('th');
                catTh.innerText = "分类";
                catTh.style.width = "80px";
                titleTh.after(catTh);
            }

            tbody.innerHTML = '';
            if(res.data) {
                document.getElementById('total-count').innerText = "总计: " + (res.total || 0);
                res.data.forEach(r => {
                    const time = new Date(r.created_at).toLocaleDateString();
                    let tags = "";
                    if (r.is_pushed) tags += `<span class="tag tag-push">已推</span> `;
                    if (r.is_renamed) tags += `<span class="tag tag-ren">已整</span>`;
                    const chkValue = `${r.id}|${r.magnets}`;
                    const magnetText = r.magnets || '';
                    const category = r.category || '未分类';
                    
                    // 渲染行
                    tbody.innerHTML += `<tr>
                        <td><input type="checkbox" class="tbl-chk row-chk" value="${chkValue}"></td>
                        <td><span style="opacity:0.5">#</span>${r.id}</td>
                        <td class="title-cell"><div style="margin-bottom:4px">${r.title}</div><div>${tags}</div></td>
                        <td><span class="tag" style="background:rgba(255,255,255,0.1);">${category}</span></td>
                        <td class="magnet-cell">${magnetText}</td>
                        <td style="font-size:12px;color:var(--text-sub)">${time}</td>
                    </tr>`;
                });
            }
        }
    </script>
</body>
</html>
JS_EOF

# 覆盖回原文件
mv /app/public/index.html.tmp /app/public/index.html

# 4. 更新后端路由 (app.js) 以支持返回 category 字段
# (因为我们是用 SELECT *，只要 resource_mgr 存进去了，API 就能吐出来，所以不用改后端 API 逻辑)

# 5. 更新版本号
sed -i 's/"version": ".*"/"version": "13.9.9"/' /app/package.json

echo "✅ 升级完成！请刷新网页，重新采集即可看到分类标签。"
