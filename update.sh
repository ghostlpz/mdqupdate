#!/bin/bash
# VERSION = 13.15.3

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.15.3
# 核心: 1:1 复刻 Python 脚本的 App 协议 (解决登录和推送失败)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署 App 协议复刻版 (V13.15.3)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.15.3"/' package.json

# 2. 重写 LoginPikPak (使用 Python 脚本中的 ID/Secret)
echo "📝 [1/1] 替换为 App 鉴权协议..."
cat > modules/login_pikpak.js << 'EOF'
const axios = require('axios');
const { HttpsProxyAgent } = require('https-proxy-agent');
const path = require('path');

// 🔥 核心修正: 移植自 Python 脚本的 App ID
const CLIENT_ID = "YNxT9w7GMdWvEOKa";
const CLIENT_SECRET = "dbw2OtmVEeuUvIptb1Coygx";

const LoginPikPak = {
    auth: {
        username: '',
        password: '',
        token: '',
        refreshToken: '',
        userId: '',
        deviceId: 'madou_omni_v1' // 仅保留用于内部标识，不发给服务器
    },
    proxy: null,
    
    setConfig(cfg) {
        if (!cfg) return;
        if (cfg.pikpak) {
            const val = cfg.pikpak.trim();
            if (val.includes('|')) {
                const parts = val.split('|');
                this.auth.username = parts[0].trim();
                this.auth.password = parts[1].trim();
            } else if (val.startsWith('Bearer')) {
                this.auth.token = val;
            }
        }
        // 读取缓存 Token
        if (cfg.pikpak_token) {
            try {
                const t = JSON.parse(cfg.pikpak_token);
                if (t.access_token) this.auth.token = 'Bearer ' + t.access_token;
                if (t.refresh_token) this.auth.refreshToken = t.refresh_token;
                if (t.user_id) this.auth.userId = t.user_id;
            } catch(e) {}
        }
        if (cfg.proxy) this.proxy = cfg.proxy;
    },

    // 🔥 修正: 严格对齐 Python 脚本的 Header (移除 X-Device-Id)
    getAxiosConfig() {
        const config = {
            headers: {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/103.0.0.0 Safari/537.36',
                'Content-Type': 'application/json; charset=utf-8'
            },
            timeout: 15000
        };
        if (this.auth.token) {
            config.headers['Authorization'] = this.auth.token;
        }
        if (this.proxy) {
            config.httpsAgent = new HttpsProxyAgent(this.proxy);
            config.proxy = false;
        }
        return config;
    },

    saveToken(data) {
        this.auth.token = 'Bearer ' + data.access_token;
        this.auth.refreshToken = data.refresh_token;
        this.auth.userId = data.sub;
        if (global.CONFIG) {
            global.CONFIG.pikpak_token = JSON.stringify({
                access_token: data.access_token,
                refresh_token: data.refresh_token,
                user_id: data.sub,
                time: Date.now()
            });
            global.saveConfig();
        }
    },

    async login() {
        // 1. 尝试刷新 Token
        if (this.auth.refreshToken) {
            console.log('🔄 PikPak 尝试刷新 Token...');
            try {
                const url = 'https://user.mypikpak.com/v1/auth/token';
                const payload = {
                    client_id: CLIENT_ID,
                    client_secret: CLIENT_SECRET,
                    grant_type: "refresh_token",
                    refresh_token: this.auth.refreshToken
                };
                const res = await axios.post(url, payload, this.getAxiosConfig());
                if (res.data && res.data.access_token) {
                    this.saveToken(res.data);
                    console.log('✅ Token 刷新成功');
                    return true;
                }
            } catch (e) {
                console.warn('⚠️ 刷新失败:', e.message);
                this.auth.refreshToken = ''; 
            }
        }

        // 2. 账号密码登录
        if (!this.auth.username || !this.auth.password) return !!this.auth.token;

        try {
            console.log('🔑 PikPak 尝试 App 协议登录...');
            const url = 'https://user.mypikpak.com/v1/auth/signin';
            const payload = {
                client_id: CLIENT_ID,
                client_secret: CLIENT_SECRET, // 关键参数
                username: this.auth.username,
                password: this.auth.password
            };
            
            const config = this.getAxiosConfig();
            delete config.headers['Authorization']; // 登录不需要 Auth 头

            const res = await axios.post(url, payload, config);
            if (res.data && res.data.access_token) {
                console.log('✅ 登录成功');
                this.saveToken(res.data);
                return true;
            }
        } catch (e) {
            const status = e.response ? e.response.status : 'Network Error';
            const data = e.response ? JSON.stringify(e.response.data) : e.message;
            console.error(`❌ 登录失败 [${status}]: ${data}`);
        }
        return false;
    },

    async testConnection() {
        this.auth.token = ''; this.auth.refreshToken = ''; // 强制重测
        if(global.CONFIG) global.CONFIG.pikpak_token = '';

        const success = await this.login();
        if (!success) return { success: false, msg: "登录失败: 请检查账号/密码或代理" };

        try {
            const url = `https://api-drive.mypikpak.com/drive/v1/files?filters={"trashed":{"eq":false}}&limit=1`;
            await axios.get(url, this.getAxiosConfig());
            return { success: true, msg: "✅ 连接成功！(App 协议)" };
        } catch (e) {
            return { success: false, msg: `API 错误: ${e.message}` };
        }
    },

    // 复刻 Python 的 addTask 逻辑 (解决 400 错误)
    async addTask(url, parentId = '') {
        return await this._addTaskInternal(url, parentId, true);
    },

    async _addTaskInternal(url, parentId, allowRetry) {
        if (!this.auth.token) await this.login();
        try {
            const apiUrl = 'https://api-drive.mypikpak.com/drive/v1/files';
            let fileName = 'unknown_video';
            try { fileName = path.basename(new URL(url).pathname); } catch(e) {}

            const payload = {
                kind: "drive#file",
                name: fileName,
                upload_type: "UPLOAD_TYPE_URL",
                url: { "url": url }, // 🔥 结构修正
                folder_type: parentId ? "" : "DOWNLOAD" // 🔥 逻辑修正
            };
            if (parentId) payload.parent_id = parentId;

            const res = await axios.post(apiUrl, payload, this.getAxiosConfig());
            return res.data && (res.data.task || res.data.file); 
        } catch (e) {
            if (allowRetry && e.response && e.response.status === 401) {
                console.log('⚠️ Token 过期重试...');
                this.auth.token = '';
                if (await this.login()) return await this._addTaskInternal(url, parentId, false);
            }
            const errMsg = e.response ? `Status ${e.response.status}: ${JSON.stringify(e.response.data)}` : e.message;
            console.error('PikPak AddTask Error:', errMsg);
            return false;
        }
    },

    // 其他方法保持基础实现 (略有精简)
    async getFileList(parentId = '') {
        if (!this.auth.token) await this.login();
        try {
            let url = `https://api-drive.mypikpak.com/drive/v1/files?filters={"trashed":{"eq":false}}&limit=100`;
            if (parentId) url += `&parent_id=${parentId}`;
            const res = await axios.get(url, this.getAxiosConfig());
            if (res.data && res.data.files) {
                return { data: res.data.files.map(f => ({
                    fid: f.id, n: f.name, s: parseInt(f.size||0),
                    fcid: f.kind === 'drive#folder' ? f.id : undefined,
                    parent_id: f.parent_id
                }))};
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
            await axios.patch(url, { name: newName }, this.getAxiosConfig());
            return { success: true };
        } catch (e) { return { success: false, msg: e.message }; }
    },

    async move(fileIds, targetCid) {
        if (!this.auth.token) await this.login();
        try {
            const url = 'https://api-drive.mypikpak.com/drive/v1/files/batch_move';
            await axios.post(url, { ids: fileIds.split(','), to: { parent_id: targetCid } }, this.getAxiosConfig());
            return true;
        } catch (e) { return false; }
    },

    async deleteFiles(fileIds) {
        if (!this.auth.token) await this.login();
        try {
            const url = 'https://api-drive.mypikpak.com/drive/v1/files/batch_trash';
            await axios.post(url, { ids: fileIds.split(',') }, this.getAxiosConfig());
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
                    return { status_code: 2, folder_cid: f.fcid ? f.fid : f.parent_id, file_id: f.fid, percent: 100 };
                }
            }
        } catch (e) {}
        return null;
    },

    async uploadFile(fileBuffer, fileName, parentId = '') {
        if (!this.auth.token) await this.login();
        try {
            const createUrl = 'https://api-drive.mypikpak.com/drive/v1/files';
            const createPayload = { kind: "drive#file", name: fileName, upload_type: "UPLOAD_TYPE_RESUMABLE" };
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

# 3. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.15.3 像素级复刻版部署完成！"
