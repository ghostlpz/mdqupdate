#!/bin/bash
# VERSION = 13.14.7

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.14.7
# 修复: 1. PikPak 添加任务报 400 错误 (参数净化)
#       2. M3U8 页面图片抓取失败 (正则增强)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署 PikPak/图片 修复版 (V13.14.7)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.14.7"/' package.json

# 2. 修复 LoginPikPak (解决 400 错误)
echo "📝 [1/2] 修复 PikPak 驱动..."
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
                'Authorization': this.auth.token
            }
        };
        if (this.proxy) {
            config.httpsAgent = new HttpsProxyAgent(this.proxy);
            config.proxy = false;
        }
        return config;
    },

    async login() {
        if (this.auth.token && !this.auth.password) return true;
        if (!this.auth.username || !this.auth.password) return false;

        try {
            const url = 'https://user.mypikpak.com/v1/auth/signin';
            const payload = {
                client_id: "YNxT9w7GMvwD3",
                username: this.auth.username,
                password: this.auth.password
            };
            const config = { headers: { 'Content-Type': 'application/json' } };
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
            console.error('❌ PikPak 登录失败:', e.message);
        }
        return false;
    },

    // 修复：净化 payload，解决 400 错误
    async addTask(url, parentId = '') {
        if (!this.auth.token) await this.login();
        try {
            const apiUrl = 'https://api-drive.mypikpak.com/drive/v1/files';
            
            // 尝试从 URL 提取文件名作为默认名，避免 PikPak 识别错误
            let fileName = 'unknown_video';
            try { fileName = path.basename(new URL(url).pathname); } catch(e) {}

            const payload = {
                kind: "drive#file",
                upload_type: "UPLOAD_TYPE_URL",
                url: url,
                name: fileName
            };
            
            // 🔥 关键修复：只有 parentId 有值时才传，传空字符串必报 400
            if (parentId) {
                payload.parent_id = parentId;
            }

            const res = await axios.post(apiUrl, payload, this.getAxiosConfig());
            return res.data && (res.data.task || res.data.file); 
        } catch (e) {
            // 打印详细错误信息以便调试
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

# 3. 修复 Scraper (增强图片正则)
echo "📝 [2/2] 升级采集器 (优化图片提取)..."
cat >> modules/scraper_xchina.js << 'EOF'

// 🔥 补丁: 覆盖 processVideoTask 修复图片和推送逻辑
async function processVideoTask(task, baseUrl, autoDownload) {
    const { link } = task; 
    const $ = await requestViaFlare(link);
    
    let title = $('h1').text().trim() || task.title;
    
    // 🔥 图片抓取核心优化
    let image = '';
    
    // 策略1: 优先尝试从 JS 配置中提取 (针对 M3U8 页面最有效)
    // 匹配: poster: "https://..." 或 poster: 'https://...'
    const htmlContent = $.html();
    const regexPoster = /poster\s*:\s*["']([^"']+)["']/i;
    const matchPoster = htmlContent.match(regexPoster);
    if (matchPoster && matchPoster[1]) {
        image = matchPoster[1];
    }

    // 策略2: 如果正则没抓到，或抓到的是相对路径，尝试 DOM 补充
    if (!image || !image.startsWith('http')) {
        const domImage = $('.vjs-poster img').attr('src') || $('video').attr('poster');
        if (domImage) image = domImage;
    }
    
    // 补全相对路径
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
            const $down = await requestViaFlare(downloadPageUrl);
            const rawMagnet = $down('a.btn.magnet').attr('href');
            if (rawMagnet) magnet = cleanMagnet(rawMagnet);
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
                const pushed = await LoginPikPak.addTask(magnet);
                // 成功返回 task 对象或文件对象
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

echo "✅ [完成] V13.14.7 修复版部署完成！"
