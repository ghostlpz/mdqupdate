#!/bin/bash
# VERSION = 13.15.2

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.15.2
# 修复: 1. PikPak 登录失败 (移植 Python 项目的 ClientID/Secret)
#       2. PikPak 推送 400 错误 (修正 Payload 结构)
#       3. 增加 Token 持久化与自动刷新逻辑
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署核心协议修正版 (V13.15.2)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.15.2"/' package.json

# 2. 重写 login_pikpak.js (移植核心逻辑)
echo "📝 [1/1] 移植 PikPak 核心驱动..."
cat > modules/login_pikpak.js << 'EOF'
const axios = require('axios');
const { HttpsProxyAgent } = require('https-proxy-agent');
const path = require('path');

// 移植自 pikpak-master 项目的鉴权信息
const CLIENT_ID = "YNxT9w7GMdWvEOKa";
const CLIENT_SECRET = "dbw2OtmVEeuUvIptb1Coygx";

const LoginPikPak = {
    auth: {
        username: '',
        password: '',
        token: '',        // access_token
        refreshToken: '', // refresh_token
        userId: '',
        deviceId: 'madou_omni_v1'
    },
    proxy: null,
    
    setConfig(cfg) {
        if (!cfg) return;
        
        // 1. 设置账号/Token
        if (cfg.pikpak) {
            const val = cfg.pikpak.trim();
            if (val.includes('|')) {
                // 模式A: 账号|密码
                const parts = val.split('|');
                this.auth.username = parts[0].trim();
                this.auth.password = parts[1].trim();
                // 如果切换了账号，清空旧 Token
                // (这里简化处理，假设用户修改配置就是想重置)
            } else if (val.startsWith('Bearer')) {
                // 模式B: 直接填入的 Token (手动模式)
                this.auth.token = val;
            }
        }
        
        // 尝试读取持久化的 Token (如果有)
        if (cfg.pikpak_token) {
            try {
                const t = JSON.parse(cfg.pikpak_token);
                if (t.access_token) this.auth.token = 'Bearer ' + t.access_token;
                if (t.refresh_token) this.auth.refreshToken = t.refresh_token;
                if (t.user_id) this.auth.userId = t.user_id;
            } catch(e) {}
        }

        // 2. 设置代理
        if (cfg.proxy) this.proxy = cfg.proxy;
    },

    getAxiosConfig() {
        const config = {
            headers: {
                'Content-Type': 'application/json',
                'X-Device-Id': this.auth.deviceId,
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/103.0.0.0 Safari/537.36'
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

    // 保存 Token 到全局配置 (持久化)
    saveToken(data) {
        this.auth.token = 'Bearer ' + data.access_token;
        this.auth.refreshToken = data.refresh_token;
        this.auth.userId = data.sub;
        
        if (global.CONFIG) {
            // 将 Token 信息存入隐藏字段 pikpak_token
            global.CONFIG.pikpak_token = JSON.stringify({
                access_token: data.access_token,
                refresh_token: data.refresh_token,
                user_id: data.sub,
                time: Date.now()
            });
            global.saveConfig(); // 触发写入 config.json
        }
    },

    async login() {
        // 1. 如果有 Refresh Token，优先尝试刷新
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
                    console.log('✅ PikPak Token 刷新成功');
                    this.saveToken(res.data);
                    return true;
                }
            } catch (e) {
                console.warn('⚠️ PikPak 刷新失败，转为重新登录:', e.message);
                this.auth.refreshToken = ''; // 刷新失败，清除无效 token
            }
        }

        // 2. 账号密码登录
        if (!this.auth.username || !this.auth.password) {
            if (this.auth.token) return true; // 只有手动填的 token，没法刷新，只能硬用
            return false;
        }

        try {
            console.log('🔑 PikPak 尝试账号密码登录...');
            const url = 'https://user.mypikpak.com/v1/auth/signin';
            const payload = {
                client_id: CLIENT_ID,
                client_secret: CLIENT_SECRET, // 🔥 关键修复: 加上 Secret
                username: this.auth.username,
                password: this.auth.password
            };
            
            // 登录请求不带 Authorization 头
            const config = this.getAxiosConfig();
            delete config.headers['Authorization'];

            const res = await axios.post(url, payload, config);
            if (res.data && res.data.access_token) {
                console.log('✅ PikPak 登录成功');
                this.saveToken(res.data);
                return true;
            }
        } catch (e) {
            const msg = e.response ? `HTTP ${e.response.status} - ${JSON.stringify(e.response.data)}` : e.message;
            console.error(`❌ PikPak 登录失败: ${msg}`);
        }
        return false;
    },

    // 🧪 测试连接
    async testConnection() {
        // 清空 Token 强制验证登录逻辑
        this.auth.token = '';
        this.auth.refreshToken = ''; 
        if (global.CONFIG) global.CONFIG.pikpak_token = ''; // 清除缓存

        const loginSuccess = await this.login();
        if (!loginSuccess) return { success: false, msg: "登录失败: 请检查账号密码或代理" };

        try {
            const url = `https://api-drive.mypikpak.com/drive/v1/files?filters={"trashed":{"eq":false}}&limit=1`;
            await axios.get(url, this.getAxiosConfig());
            return { success: true, msg: "✅ PikPak 连接成功！(API 通畅)" };
        } catch (e) {
            return { success: false, msg: `API 访问错误: ${e.message}` };
        }
    },

    // 修复: 修正 Payload 结构 {"url": {"url": "..."}}
    async addTask(url, parentId = '') {
        // 自动重试逻辑：如果 401 (Token 过期)，则刷新后重试一次
        return await this._addTaskInternal(url, parentId, true);
    },

    async _addTaskInternal(url, parentId, allowRetry) {
        if (!this.auth.token) await this.login();
        
        try {
            const apiUrl = 'https://api-drive.mypikpak.com/drive/v1/files';
            
            let fileName = 'unknown_video';
            try { fileName = path.basename(new URL(url).pathname); } catch(e) {}

            // 🔥 关键修复: 参照 Python 代码的结构
            const payload = {
                kind: "drive#file",
                upload_type: "UPLOAD_TYPE_URL",
                url: { "url": url }, // 🔥 修正: 这里必须是对象，不能是字符串
                name: fileName,
                folder_type: "DOWNLOAD" 
            };
            
            if (parentId && parentId.trim() !== '') {
                payload.parent_id = parentId;
            } else {
                // 如果没有 parentId，Python 代码逻辑是置空，API 默认存根目录
                // payload.folder_type = "DOWNLOAD"; // 已设置
            }

            const res = await axios.post(apiUrl, payload, this.getAxiosConfig());
            return res.data && (res.data.task || res.data.file); 

        } catch (e) {
            // 处理 Token 过期 (401)
            if (allowRetry && e.response && e.response.status === 401) {
                console.log('⚠️ PikPak Token 过期，正在重新登录...');
                this.auth.token = ''; // 清除旧 token
                const relogin = await this.login();
                if (relogin) {
                    return await this._addTaskInternal(url, parentId, false); // 重试一次
                }
            }

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

    // 同样需要支持 Token 过期重试
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

# 3. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.15.2 部署完成！请尝试点击“测试连接”。"
