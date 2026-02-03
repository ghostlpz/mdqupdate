#!/bin/bash
# VERSION = 13.15.5

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.15.5
# 修复: 1. 图片提取增强 (支持 JS 变量及 CSS 背景图提取)
#       2. PikPak 登录优化 (Token 模式跳过密码验证)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署最终修正版 (V13.15.5)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.15.5"/' package.json

# 2. 升级 Scraper (引入地毯式图片搜索)
echo "📝 [1/2] 升级采集器 (图片正则增强)..."
cat >> modules/scraper_xchina.js << 'EOF'

// 🔥 补丁: 覆盖 processVideoTask
async function processVideoTask(task, baseUrl, autoDownload) {
    const { link } = task; 
    
    // 获取原始 HTML 文本
    const flareApi = getFlareUrl();
    let htmlContent = "";
    try {
        const payload = { cmd: 'request.get', url: link, maxTimeout: 60000 };
        if (global.CONFIG.proxy) payload.proxy = { url: global.CONFIG.proxy };
        const res = await axios.post(flareApi, payload, { headers: { 'Content-Type': 'application/json' } });
        if (res.data.status === 'ok') {
            htmlContent = res.data.solution.response;
        } else {
            throw new Error(`Flaresolverr: ${res.data.message}`);
        }
    } catch(e) { throw new Error(`Req Err: ${e.message}`); }

    const $ = cheerio.load(htmlContent);
    let title = $('h1').text().trim() || task.title;
    
    // 🔥 图片抓取终极方案
    let image = '';
    
    // 1. 尝试匹配 JS 配置中的 poster: "url" (单双引号兼容)
    const regexJsPoster = /poster\s*:\s*['"]([^'"]+)['"]/i;
    // 2. 尝试匹配 CSS 中的 background-image: url("...")
    const regexCssPoster = /background-image\s*:\s*url\(['"]?([^'"\)]+)['"]?\)/i;
    // 3. 尝试匹配 og:image 标签
    const metaImage = $('meta[property="og:image"]').attr('content');

    if (htmlContent.match(regexJsPoster)) {
        image = htmlContent.match(regexJsPoster)[1];
    } else if (htmlContent.match(regexCssPoster)) {
        image = htmlContent.match(regexCssPoster)[1];
    } else if (metaImage) {
        image = metaImage;
    } else {
        // 保底: DOM 查找
        image = $('.vjs-poster img').attr('src') || $('video').attr('poster');
    }
    
    // 补全相对路径
    if (image && !image.startsWith('http')) image = baseUrl + image;

    // ... (以下逻辑保持不变: 演员/分类/磁力/M3U8提取) ...
    const actor = $('.model-container .model-item').text().trim() || '未知演员';
    let category = '未分类';
    $('.text').each((i, el) => { if ($(el).find('.joiner').length > 0) category = $(el).find('a').last().text().trim(); });

    let code = '';
    const codeMatch = link.match(/id-([a-zA-Z0-9]+)/);
    if (codeMatch) code = codeMatch[1];

    let magnet = '';
    let driveType = '115';

    // 1. 找磁力 (115)
    try {
        const downloadLinkEl = $('a[href*="/download/id-"]');
        if (downloadLinkEl.length > 0) {
            let downloadPageUrl = downloadLinkEl.attr('href');
            if (downloadPageUrl && !downloadPageUrl.startsWith('http')) downloadPageUrl = baseUrl + downloadPageUrl;
            
            const dlPayload = { cmd: 'request.get', url: downloadPageUrl, maxTimeout: 30000 };
            if (global.CONFIG.proxy) dlPayload.proxy = { url: global.CONFIG.proxy };
            const dlRes = await axios.post(flareApi, dlPayload);
            if (dlRes.data.status === 'ok') {
                const $d = cheerio.load(dlRes.data.solution.response);
                const rawMagnet = $d('a.btn.magnet').attr('href');
                if (rawMagnet) magnet = cleanMagnet(rawMagnet);
            }
        }
    } catch (e) {}

    // 2. 找 M3U8 (PikPak)
    if (!magnet) {
        const regexVideo = /src:\s*['"](https?:\/\/[^'"]+\.m3u8[^'"]*)['"]/;
        const matchVideo = htmlContent.match(regexVideo);
        if (matchVideo && matchVideo[1]) {
            magnet = matchVideo[1];
            driveType = 'pikpak';
            log(`🔎 [${code}] 启用 M3U8 (PikPak)`, 'info');
        }
    }

    if (magnet) {
        const storageValue = driveType === 'pikpak' ? `pikpak|${magnet}` : magnet;
        const saveRes = await ResourceMgr.save({
            title, link, magnets: storageValue, code, image, actor, category
        });

        if (saveRes.success && saveRes.newInsert) {
            STATE.totalScraped++;
            let extraMsg = "";
            
            if (driveType === 'pikpak') {
                // 尝试推送
                const pushed = await LoginPikPak.addTask(magnet);
                extraMsg = pushed ? " | 🚀 已强制推PikPak" : " | ⚠️ PikPak推送失败";
                if(pushed) await ResourceMgr.markAsPushedByLink(link);
            } else {
                extraMsg = " | 💾 仅存库";
            }

            log(`✅ [入库] ${code} | ${title.substring(0, 10)}...${extraMsg}`, 'success');
            return true;
        } else if (!saveRes.newInsert) {
            log(`⏭️ [已存在] ${title.substring(0, 10)}...`, 'info');
            return true;
        }
    }
    return false;
}
EOF

# 3. 升级 LoginPikPak (优化 Token 逻辑)
echo "📝 [2/2] 优化 PikPak 鉴权..."
# 这里我们微调一下，确保有 Token 时绝对不走账号密码逻辑
sed -i 's/if (!this.auth.username || !this.auth.password) return !!this.auth.token;/if (this.auth.token) return true; if (!this.auth.username || !this.auth.password) return false;/' modules/login_pikpak.js

# 4. 重启应用
echo "🔄 重启应用..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.15.5 部署完成！"
echo "👉 请务必在设置页填入 'Bearer xxxx' 格式的 Token，然后重新测试连接！"
