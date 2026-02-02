#!/bin/bash
# VERSION = 13.14.5

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.14.5
# 核心: 1. PikPak 模块增加 Proxy 代理支持 (解决 NAS 无法连接问题)
#       2. 采集逻辑分流: 磁力只存库，M3U8 强制推 PikPak
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署 PikPak 代理增强版 (V13.14.5)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.14.5"/' package.json

# 2. 升级 LoginPikPak (增加代理支持)
echo "📝 [1/2] 升级 PikPak 驱动 (集成代理隧道)..."
cat > modules/login_pikpak.js << 'EOF'
const axios = require('axios');
const { HttpsProxyAgent } = require('https-proxy-agent');

// PikPak API 封装 (带代理支持)
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
        // 1. 设置账号
        if (cfg.pikpak) {
            if (cfg.pikpak.startsWith('Bearer')) {
                this.auth.token = cfg.pikpak;
            } else if (cfg.pikpak.includes('|')) {
                const parts = cfg.pikpak.split('|');
                this.auth.username = parts[0].trim();
                this.auth.password = parts[1].trim();
            }
        }
        // 2. 设置代理
        if (cfg.proxy) {
            this.proxy = cfg.proxy;
        }
    },

    // 获取 Axios 配置 (包含 Header 和 Agent)
    getAxiosConfig() {
        const config = {
            headers: {
                'Content-Type': 'application/json',
                'X-Device-Id': this.auth.deviceId,
                'Authorization': this.auth.token
            }
        };
        // 🔥 关键: 注入代理 Agent
        if (this.proxy) {
            config.httpsAgent = new HttpsProxyAgent(this.proxy);
            config.proxy = false; // 禁用 axios 默认代理逻辑，使用 agent
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
            
            // 登录请求也要走代理
            const config = { 
                headers: { 'Content-Type': 'application/json' } 
            };
            if (this.proxy) {
                config.httpsAgent = new HttpsProxyAgent(this.proxy);
                config.proxy = false;
            }

            const res = await axios.post(url, payload, config);
            if (res.data && res.data.access_token) {
                this.auth.token = 'Bearer ' + res.data.access_token;
                this.auth.userId = res.data.sub;
                console.log('✅ PikPak 登录成功 (Via Proxy)');
                return true;
            }
        } catch (e) {
            console.error('❌ PikPak 登录失败:', e.message);
        }
        return false;
    },

    async addTask(url, parentId = '') {
        if (!this.auth.token) await this.login();
        try {
            const apiUrl = 'https://api-drive.mypikpak.com/drive/v1/files';
            const payload = {
                kind: "drive#file",
                folder_type: "DOWNLOAD",
                upload_type: "UPLOAD_TYPE_URL",
                url: url,
                parent_id: parentId
            };
            const res = await axios.post(apiUrl, payload, this.getAxiosConfig());
            return res.data && res.data.task;
        } catch (e) {
            console.error('PikPak AddTask Error:', e.message);
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
                parent_id: parentId,
                upload_type: "UPLOAD_TYPE_RESUMABLE"
            };
            const res1 = await axios.post(createUrl, createPayload, this.getAxiosConfig());
            const uploadUrl = res1.data.upload_url;
            const fileId = res1.data.file.id;

            if (uploadUrl) {
                // 上传数据 (PUT) 也要走代理
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

# 3. 升级 Scraper (实现差异化推送策略)
echo "📝 [2/2] 升级采集策略 (磁力存库/M3U8推PikPak)..."
cat >> modules/scraper_xchina.js << 'EOF'

// 🔥 补丁: 覆盖 processVideoTask 实现差异化逻辑
async function processVideoTask(task, baseUrl, autoDownload) {
    const { link } = task; 
    const $ = await requestViaFlare(link);
    
    let title = $('h1').text().trim() || task.title;
    let image = $('.vjs-poster img').attr('src') || $('video').attr('poster');
    if (image && !image.startsWith('http')) image = baseUrl + image;
    
    const actor = $('.model-container .model-item').text().trim() || '未知演员';
    
    let category = '';
    $('.text').each((i, el) => { if ($(el).find('.joiner').length > 0) category = $(el).find('a').last().text().trim(); });
    if (!category) category = '未分类';

    let code = '';
    const codeMatch = link.match(/id-([a-zA-Z0-9]+)/);
    if (codeMatch) code = codeMatch[1];

    let magnet = '';
    let driveType = '115';

    // 1. 优先找磁力 (115)
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

    // 2. 备用找 M3U8 (PikPak)
    if (!magnet) {
        const htmlContent = $.html();
        const regex = /src:\s*['"](https?:\/\/[^'"]+\.m3u8[^'"]*)['"]/;
        const match = htmlContent.match(regex);
        if (match && match[1]) {
            magnet = match[1];
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
            
            // 🔥 差异化策略 🔥
            if (driveType === 'pikpak') {
                // M3U8: 强制立即推送 (不管 autoDownload 选没选，防止失效)
                const pushed = await LoginPikPak.addTask(magnet);
                extraMsg = pushed ? " | 🚀 已强制推PikPak" : " | ⚠️ PikPak推送失败(请检查代理)";
                if(pushed) await ResourceMgr.markAsPushedByLink(link);
            } else {
                // 磁力: 仅存库 (除非用户勾选了 autoDownload 才会推 115)
                /* 用户要求: "有磁力的存入数据库就行了"
                   因此，这里我们忽略 autoDownload 选项，或者你可以取消注释下面的代码来恢复手动控制
                */
                // if (autoDownload) { 
                //    await pushTo115(magnet); 
                //    extraMsg = " | 📥 已推115"; 
                // } else {
                   extraMsg = " | 💾 仅存库";
                // }
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

echo "✅ [完成] V13.14.5 代理增强版部署完成！"
