#!/bin/bash
# VERSION = 13.15.4

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.15.4
# 功能: 开启 PikPak 登录的"核磁共振"级调试日志
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署深度调试版 (V13.15.4)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.15.4"/' package.json

# 2. 注入调试版 LoginPikPak
echo "📝 [1/1] 注入调试探针..."
cat > modules/login_pikpak.js << 'EOF'
const axios = require('axios');
const { HttpsProxyAgent } = require('https-proxy-agent');
const path = require('path');

// 移植自 pikpak-master
const CLIENT_ID = "YNxT9w7GMdWvEOKa";
const CLIENT_SECRET = "dbw2OtmVEeuUvIptb1Coygx";

const LoginPikPak = {
    auth: {
        username: '',
        password: '',
        token: '',
        refreshToken: '',
        userId: '',
        deviceId: 'madou_omni_debug'
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
        if (cfg.proxy) this.proxy = cfg.proxy;
    },

    getAxiosConfig() {
        const config = {
            headers: {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/103.0.0.0 Safari/537.36',
                'Content-Type': 'application/json; charset=utf-8'
            },
            timeout: 15000
        };
        if (this.auth.token) config.headers['Authorization'] = this.auth.token;
        
        // 🔍 调试日志: 代理配置
        if (this.proxy) {
            try {
                // 简单校验代理格式
                if (!this.proxy.startsWith('http')) {
                    console.warn(`⚠️ [Debug] 代理地址格式可能错误 (建议 http://...): ${this.proxy}`);
                }
                config.httpsAgent = new HttpsProxyAgent(this.proxy);
                config.proxy = false;
            } catch (e) {
                console.error(`❌ [Debug] 代理初始化失败: ${e.message}`);
            }
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
        console.log('------------------------------------------------');
        console.log('🧪 [PikPak Debug] 开始登录流程...');
        
        // 1. 尝试刷新
        if (this.auth.refreshToken) {
            console.log('🔄 [Debug] 检测到 Refresh Token，尝试刷新...');
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
                    console.log('✅ [Debug] 刷新成功!');
                    this.saveToken(res.data);
                    return true;
                }
            } catch (e) {
                console.warn('⚠️ [Debug] 刷新失败 (将尝试账号登录):', e.message);
                this.auth.refreshToken = ''; 
            }
        }

        // 2. 账号登录
        console.log(`👤 [Debug] 用户名: ${this.auth.username ? this.auth.username.substring(0,3)+'***' : '未设置'}`);
        console.log(`🔑 [Debug] 密码: ${this.auth.password ? '******' : '未设置'}`);
        console.log(`🌐 [Debug] 代理: ${this.proxy || '无'}`);

        if (!this.auth.username || !this.auth.password) {
            if (this.auth.token) {
                console.log('ℹ️ [Debug] 无账号密码，但有手动 Token，尝试直接使用...');
                return true; 
            }
            console.error('❌ [Debug] 缺少账号密码，无法登录');
            return false;
        }

        try {
            const url = 'https://user.mypikpak.com/v1/auth/signin';
            const payload = {
                client_id: CLIENT_ID,
                client_secret: CLIENT_SECRET,
                username: this.auth.username,
                password: this.auth.password
            };
            
            const config = this.getAxiosConfig();
            delete config.headers['Authorization'];

            console.log(`🚀 [Debug] 发起请求: POST ${url}`);
            
            const res = await axios.post(url, payload, config);
            
            console.log(`📥 [Debug] 收到响应: Status ${res.status}`);
            if (res.data && res.data.access_token) {
                console.log('✅ [Debug] 登录成功! 拿到 Token');
                this.saveToken(res.data);
                return true;
            } else {
                console.error('❌ [Debug] 响应数据异常:', JSON.stringify(res.data));
            }
        } catch (e) {
            console.error('------------------------------------------------');
            console.error('❌ [PikPak Login Error Details]');
            if (e.response) {
                // 服务器有返回，但状态码非 2xx
                console.error(`Status Code: ${e.response.status}`);
                console.error(`Status Text: ${e.response.statusText}`);
                console.error(`Response Data: ${JSON.stringify(e.response.data)}`);
            } else if (e.request) {
                // 请求发出去了，没收到响应 (网络问题)
                console.error('No Response Received (Network Issue)');
                console.error(`Error Code: ${e.code}`); // 如 ECONNREFUSED, ETIMEDOUT
                console.error(`Error Message: ${e.message}`);
                console.error('Check your Proxy settings!');
            } else {
                // 设置请求时出错
                console.error(`Request Setup Error: ${e.message}`);
            }
            console.error('------------------------------------------------');
        }
        return false;
    },

    async testConnection() {
        this.auth.token = ''; this.auth.refreshToken = ''; 
        if(global.CONFIG) global.CONFIG.pikpak_token = '';

        console.log('🧪 [Test] 用户点击测试连接...');
        const success = await this.login();
        if (!success) return { success: false, msg: "登录失败，请查看终端详细日志" };

        try {
            console.log('🚀 [Test] 尝试列出文件以验证 Token...');
            const url = `https://api-drive.mypikpak.com/drive/v1/files?filters={"trashed":{"eq":false}}&limit=1`;
            await axios.get(url, this.getAxiosConfig());
            console.log('✅ [Test] API 访问畅通');
            return { success: true, msg: "✅ 连接成功！" };
        } catch (e) {
            console.error(`❌ [Test] API 访问失败: ${e.message}`);
            return { success: false, msg: `API 错误: ${e.message}` };
        }
    },

    // ... 其他函数保持原样 ...
    async addTask(url, parentId = '') { return await this._addTaskInternal(url, parentId, true); },
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
                url: { "url": url },
                folder_type: parentId ? "" : "DOWNLOAD"
            };
            if (parentId) payload.parent_id = parentId;
            const res = await axios.post(apiUrl, payload, this.getAxiosConfig());
            return res.data && (res.data.task || res.data.file); 
        } catch (e) {
            if (allowRetry && e.response && e.response.status === 401) {
                console.log('⚠️ Token过期重试...');
                this.auth.token = '';
                if (await this.login()) return await this._addTaskInternal(url, parentId, false);
            }
            console.error('PikPak AddTask Error:', e.response ? JSON.stringify(e.response.data) : e.message);
            return false;
        }
    },
    async getFileList(parentId = '') { if (!this.auth.token) await this.login(); try { let url = `https://api-drive.mypikpak.com/drive/v1/files?filters={"trashed":{"eq":false}}&limit=100`; if (parentId) url += `&parent_id=${parentId}`; const res = await axios.get(url, this.getAxiosConfig()); if (res.data && res.data.files) { return { data: res.data.files.map(f => ({ fid: f.id, n: f.name, s: parseInt(f.size||0), fcid: f.kind === 'drive#folder' ? f.id : undefined, parent_id: f.parent_id }))}; } } catch (e) { console.error(e.message); } return { data: [] }; },
    async searchFile(keyword, parentId = '') { if (!this.auth.token) await this.login(); try { const list = await this.getFileList(parentId); const matches = list.data.filter(f => f.n.includes(keyword)); return { data: matches }; } catch (e) { return { data: [] }; } },
    async rename(fileId, newName) { if (!this.auth.token) await this.login(); try { const url = `https://api-drive.mypikpak.com/drive/v1/files/${fileId}`; await axios.patch(url, { name: newName }, this.getAxiosConfig()); return { success: true }; } catch (e) { return { success: false, msg: e.message }; } },
    async move(fileIds, targetCid) { if (!this.auth.token) await this.login(); try { const url = 'https://api-drive.mypikpak.com/drive/v1/files/batch_move'; await axios.post(url, { ids: fileIds.split(','), to: { parent_id: targetCid } }, this.getAxiosConfig()); return true; } catch (e) { return false; } },
    async deleteFiles(fileIds) { if (!this.auth.token) await this.login(); try { const url = 'https://api-drive.mypikpak.com/drive/v1/files/batch_trash'; await axios.post(url, { ids: fileIds.split(',') }, this.getAxiosConfig()); return true; } catch (e) { return false; } },
    async getTaskByHash(hashOrUrl, nameHint = '') { if (!this.auth.token) await this.login(); try { if (nameHint) { const searchRes = await this.searchFile(nameHint.substring(0, 10)); if (searchRes.data && searchRes.data.length > 0) { const f = searchRes.data[0]; return { status_code: 2, folder_cid: f.fcid ? f.fid : f.parent_id, file_id: f.fid, percent: 100 }; } } } catch (e) {} return null; },
    async uploadFile(fileBuffer, fileName, parentId = '') { if (!this.auth.token) await this.login(); try { const createUrl = 'https://api-drive.mypikpak.com/drive/v1/files'; const createPayload = { kind: "drive#file", name: fileName, upload_type: "UPLOAD_TYPE_RESUMABLE" }; if (parentId) createPayload.parent_id = parentId; const res1 = await axios.post(createUrl, createPayload, this.getAxiosConfig()); const uploadUrl = res1.data.upload_url; const fileId = res1.data.file.id; if (uploadUrl) { const putConfig = this.getAxiosConfig(); putConfig.headers['Content-Type'] = ''; await axios.put(uploadUrl, fileBuffer, putConfig); return fileId; } } catch (e) { console.error('PP Upload Err:', e.message); } return null; }
};

if(global.CONFIG) LoginPikPak.setConfig(global.CONFIG);
module.exports = LoginPikPak;
EOF

# 3. 重启应用
echo "🔄 重启应用..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.15.4 部署完成！"
echo "👉 请现在去网页点击“测试连接”，然后查看这里的日志输出！"
