#!/bin/bash
# VERSION = 13.14.9

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.14.9
# 修复: 1. PikPak 400 错误 (恢复 folder_type 字段)
#       2. M3U8 图片抓取 (改用原始 HTML 正则匹配)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署 PikPak/图片 终极修复版 (V13.14.9)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.14.9"/' package.json

# 2. 修复 LoginPikPak (解决 400 错误 + 代理优化)
echo "📝 [1/2] 修复 PikPak 驱动 (协议补全)..."
cat > modules/login_pikpak.js << 'EOF'
const axios = require('axios');
const { HttpsProxyAgent } = require('https-proxy-agent');
const path = require('path');

const LoginPikPak = {
    auth: {
        username: '',
        password: '',
        token: '',
        userId: '',
        deviceId: 'madou_omni_v1'
    },
    proxy: null,
    
    setConfig(cfg) {
        if (!cfg) return;
        if (cfg.pikpak) {
            if (cfg.pikpak.startsWith('Bearer')) {
                this.auth.token = cfg.pikpak;
            } else if (cfg.pikpak.includes('|')) {
                const parts = cfg.pikpak.split('|');
                this.auth.username = parts[0].trim();
                this.auth.password = parts[1].trim();
            }
        }
        if (cfg.proxy) this.proxy = cfg.proxy;
    },

    getAxiosConfig() {
        const config = {
            headers: {
                'Content-Type': 'application/json',
                'X-Device-Id': this.auth.deviceId,
                'Authorization': this.auth.token || ''
            },
            timeout: 10000 // 增加超时设置
        };
        if (this.proxy) {
            config.httpsAgent = new HttpsProxyAgent(this.proxy);
            config.proxy = false;
        }
        return config;
    },

    async login() {
        // 如果有 Token 且不强制重登，先试用
        if (this.auth.token && !this.auth.username) return true;
        if (!this.auth.username || !this.auth.password) return false;

        try {
            const url = 'https://user.mypikpak.com/v1/auth/signin';
            const payload = {
                client_id: "YNxT9w7GMvwD3",
                username: this.auth.username,
                password: this.auth.password
            };
            // 登录专用配置
            const config = { 
                headers: { 'Content-Type': 'application/json' },
                timeout: 10000
            };
            if (this.proxy) {
                config.httpsAgent = new HttpsProxyAgent(this.proxy);
                config.proxy = false;
            }

            const res = await axios.post(url, payload, config);
            if (res.data && res.data.access_token) {
                this.auth.token = 'Bearer ' + res.data.access_token;
                this.auth.userId = res.data.sub;
                console.log('✅ PikPak 登录成功');
                return true;
            }
        } catch (e) {
            const msg = e.response ? `HTTP ${e.response.status}` : e.message;
            console.error(`❌ PikPak 登录失败 (${msg})`);
        }
        return false;
    },

    // 🧪 测试连接
    async testConnection() {
        // 强制重新登录以验证账号
        this.auth.token = ''; 
        const loginSuccess = await this.login();
        if (!loginSuccess) return { success: false, msg: "登录失败: 请检查账号/密码或代理连通性" };

        try {
            const url = `https://api-drive.mypikpak.com/drive/v1/files?filters={"trashed":{"eq":false}}&limit=1`;
            await axios.get(url, this.getAxiosConfig());
            return { success: true, msg: "✅ PikPak 连接成功！" };
        } catch (e) {
            return { success: false, msg: `API 访问错误: ${e.message}` };
        }
    },

    // 修复: 增加 folder_type，净化参数
    async addTask(url, parentId = '') {
        if (!this.auth.token) await this.login();
        try {
            const apiUrl = 'https://api-drive.mypikpak.com/drive/v1/files';
            
            let fileName = 'unknown_video';
            try { fileName = path.basename(new URL(url).pathname); } catch(e) {}

            const payload = {
                kind: "drive#file",
                upload_type: "UPLOAD_TYPE_URL",
                url: url,
                name: fileName,
                folder_type: "DOWNLOAD" // 🔥 关键修复: 离线下载必须带这个
            };
            
            if (parentId && parentId.trim() !== '') {
                payload.parent_id = parentId;
            }

            const res = await axios.post(apiUrl, payload, this.getAxiosConfig());
            return res.data && (res.data.task || res.data.file); 
        } catch (e) {
            const errMsg = e.response ? `Status ${e.response.status}: ${JSON.stringify(e.response.data)}` : e.message;
            console.error('PikPak AddTask Error:', errMsg);
            return false;
        }
    },

    async getFileList(parentId = '') {
        if (!this.auth.token) await this.login();
        try {
            let url = `https://api-drive.mypikpak.com/drive/v1/files?filters={"trashed":{"eq":false}}&limit=100`;
            if (parentId) url += `&parent_id=${parentId}`;
            
            const res = await axios.get(url, this.getAxiosConfig());
            if (res.data && res.data.files) {
                const list = res.data.files.map(f => ({
                    fid: f.id,
                    n: f.name,
                    s: parseInt(f.size || 0),
                    fcid: f.kind === 'drive#folder' ? f.id : undefined,
                    parent_id: f.parent_id
                }));
                return { data: list };
            }
        } catch (e) { console.error(e.message); }
        return { data: [] };
    },

    async searchFile(keyword, parentId = '') {
        if (!this.auth.token) await this.login();
        try {
            const list = await this.getFileList(parentId);
            const matches = list.data.filter(f => f.n.includes(keyword));
            return { data: matches };
        } catch (e) { return { data: [] }; }
    },

    async rename(fileId, newName) {
        if (!this.auth.token) await this.login();
        try {
            const url = `https://api-drive.mypikpak.com/drive/v1/files/${fileId}`;
            const payload = { name: newName };
            const res = await axios.patch(url, payload, this.getAxiosConfig());
            return { success: !!res.data.id };
        } catch (e) { return { success: false, msg: e.message }; }
    },

    async move(fileIds, targetCid) {
        if (!this.auth.token) await this.login();
        try {
            const url = 'https://api-drive.mypikpak.com/drive/v1/files/batch_move';
            const ids = fileIds.split(',');
            const payload = { ids: ids, to: { parent_id: targetCid } };
            const res = await axios.post(url, payload, this.getAxiosConfig());
            return true;
        } catch (e) { return false; }
    },

    async deleteFiles(fileIds) {
        if (!this.auth.token) await this.login();
        try {
            const url = 'https://api-drive.mypikpak.com/drive/v1/files/batch_trash';
            const ids = fileIds.split(',');
            const payload = { ids: ids };
            await axios.post(url, payload, this.getAxiosConfig());
            return true;
        } catch (e) { return false; }
    },

    async getTaskByHash(hashOrUrl, nameHint = '') {
        if (!this.auth.token) await this.login();
        try {
            if (nameHint) {
                const searchRes = await this.searchFile(nameHint.substring(0, 10));
                if (searchRes.data && searchRes.data.length > 0) {
                    const f = searchRes.data[0];
                    return {
                        status_code: 2,
                        folder_cid: f.fcid ? f.fid : f.parent_id,
                        file_id: f.fid,
                        percent: 100
                    };
                }
            }
        } catch (e) {}
        return null;
    },

    async uploadFile(fileBuffer, fileName, parentId = '') {
        if (!this.auth.token) await this.login();
        try {
            const createUrl = 'https://api-drive.mypikpak.com/drive/v1/files';
            const createPayload = {
                kind: "drive#file",
                name: fileName,
                upload_type: "UPLOAD_TYPE_RESUMABLE"
            };
            if (parentId) createPayload.parent_id = parentId;

            const res1 = await axios.post(createUrl, createPayload, this.getAxiosConfig());
            const uploadUrl = res1.data.upload_url;
            const fileId = res1.data.file.id;

            if (uploadUrl) {
                const putConfig = this.getAxiosConfig();
                putConfig.headers['Content-Type'] = ''; 
                await axios.put(uploadUrl, fileBuffer, putConfig);
                return fileId;
            }
        } catch (e) { console.error('PP Upload Err:', e.message); }
        return null;
    }
};

if(global.CONFIG) LoginPikPak.setConfig(global.CONFIG);
module.exports = LoginPikPak;
EOF

# 3. 修复 Scraper (使用原始HTML正则抓图)
echo "📝 [2/2] 升级采集器 (优化图片提取)..."
cat >> modules/scraper_xchina.js << 'EOF'

// 🔥 补丁: 覆盖 processVideoTask 修复图片和推送逻辑
async function processVideoTask(task, baseUrl, autoDownload) {
    const { link } = task; 
    
    // 改动1: 获取 response.data 原始文本，而不是 cheerio 对象，防止 script 被转义
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
    
    // 🔥 改动2: 暴力正则匹配图片 (针对 M3U8 页面)
    let image = '';
    // 匹配 poster: 'http...' (支持单双引号，忽略空格)
    // 您的案例: poster: 'https://...'
    const regexPoster = /(?:poster|pic|thumb)\s*:\s*['"]([^'"]+)['"]/i;
    const matchPoster = htmlContent.match(regexPoster);
    
    if (matchPoster && matchPoster[1]) {
        image = matchPoster[1];
    } else {
        // 保底：尝试 DOM
        image = $('.vjs-poster img').attr('src') || $('video').attr('poster');
    }
    
    if (image && !image.startsWith('http')) image = baseUrl + image;

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
            
            // 这里需要再次请求下载页
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

    // 2. 找 M3U8 (PikPak) - 使用原始HTML正则
    if (!magnet) {
        // 您的案例: src: 'https://...'
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

# 4. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.14.9 终极修复版部署完成！"
