#!/bin/bash
# VERSION = 13.15.6

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.15.6
# 修复: PikPak 账号登录 (移植 Python 项目的加密签名逻辑)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署 PikPak 签名修复版 (V13.15.6)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.15.6"/' package.json

# 2. 重写 login_pikpak.js (引入复杂的加密签名逻辑)
echo "📝 [1/1] 升级 PikPak 驱动 (集成 App 签名算法)..."
cat > modules/login_pikpak.js << 'EOF'
const axios = require('axios');
const { HttpsProxyAgent } = require('https-proxy-agent');
const path = require('path');
const crypto = require('crypto');

// 移植自新 Python 项目的常量
const CLIENT_ID = "YNxT9w7GMdWvEOKa";
const CLIENT_SECRET = "dbw2OtmVEeuUvIptb1Coygx"; // 注意：保留结尾x，Python新版疑似漏了但旧版是对的
const CLIENT_VERSION = "1.47.1";
const PACKAGE_NAME = "com.pikcloud.pikpak";
const SDK_VERSION = "2.0.4.204000";

// 盐值列表 (移植自 utils.py)
const SALTS = [
    "Gez0T9ijiI9WCeTsKSg3SMlx", "zQdbalsolyb1R/", "ftOjr52zt51JD68C3s",
    "yeOBMH0JkbQdEFNNwQ0RI9T3wU/v", "BRJrQZiTQ65WtMvwO", "je8fqxKPdQVJiy1DM6Bc9Nb1",
    "niV", "9hFCW2R1", "sHKHpe2i96", "p7c5E6AcXQ/IJUuAEC9W6", "",
    "aRv9hjc9P+Pbn+u3krN6", "BzStcgE8qVdqjEH16l4", "SqgeZvL5j9zoHP95xWHt",
    "zVof5yaJkPe3VFpadPof"
];

const LoginPikPak = {
    auth: {
        username: '',
        password: '',
        token: '',
        refreshToken: '',
        userId: '',
        deviceId: '' 
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
        if (cfg.pikpak_token) {
            try {
                const t = JSON.parse(cfg.pikpak_token);
                if (t.access_token) this.auth.token = 'Bearer ' + t.access_token;
                if (t.refresh_token) this.auth.refreshToken = t.refresh_token;
                if (t.user_id) this.auth.userId = t.user_id;
            } catch(e) {}
        }
        if (cfg.proxy) this.proxy = cfg.proxy;
        
        // 初始化设备ID (如果没有则生成一个)
        if (!this.auth.deviceId) {
            this.auth.deviceId = crypto.createHash('md5').update('madou_omni_' + Date.now()).digest('hex');
        }
    },

    // --- 加密算法工具函数 (移植自 utils.py) ---

    md5(str) {
        return crypto.createHash('md5').update(str).digest('hex');
    },

    sha1(str) {
        return crypto.createHash('sha1').update(str).digest('hex');
    },

    getTimestamp() {
        return Date.now();
    },

    // 生成验证码签名
    captchaSign(deviceId, timestamp) {
        let sign = CLIENT_ID + CLIENT_VERSION + PACKAGE_NAME + deviceId + timestamp;
        for (const salt of SALTS) {
            sign = this.md5(sign + salt);
        }
        return "1." + sign;
    },

    // 生成设备签名
    generateDeviceSign(deviceId) {
        const base = `${deviceId}${PACKAGE_NAME}1appkey`;
        const sha1Res = this.sha1(base);
        const md5Res = this.md5(sha1Res);
        return `div101.${deviceId}${md5Res}`;
    },

    // 构建复杂的 User-Agent
    buildUserAgent(deviceId, userId = "") {
        const deviceSign = this.generateDeviceSign(deviceId);
        const parts = [
            `ANDROID-${PACKAGE_NAME}/${CLIENT_VERSION}`,
            "protocolVersion/200",
            "accesstype/",
            `clientid/${CLIENT_ID}`,
            `clientversion/${CLIENT_VERSION}`,
            "action_type/",
            "networktype/WIFI",
            "sessionid/",
            `deviceid/${deviceId}`,
            "providername/NONE",
            `devicesign/${deviceSign}`,
            "refresh_token/",
            `sdkversion/${SDK_VERSION}`,
            `datetime/${this.getTimestamp()}`,
            `usrno/${userId}`,
            `appname/${PACKAGE_NAME}`,
            "session_origin/",
            "grant_type/",
            "appid/",
            "clientip/",
            "devicename/Xiaomi_M2004j7ac", // 模拟设备名
            "osversion/13",
            "platformversion/10",
            "accessmode/",
            "devicemodel/M2004J7AC"
        ];
        return parts.join(" ");
    },

    getAxiosConfig(customHeaders = {}) {
        const config = {
            headers: {
                'User-Agent': this.buildUserAgent(this.auth.deviceId, this.auth.userId),
                'Content-Type': 'application/json; charset=utf-8',
                ...customHeaders
            },
            timeout: 15000
        };
        if (this.auth.token) config.headers['Authorization'] = this.auth.token;
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

    // 🔥 关键流程: 初始化验证码 -> 获取 Token
    async captchaInit(action) {
        const url = 'https://user.mypikpak.com/v1/shield/captcha/init';
        const ts = this.getTimestamp();
        const meta = {
            captcha_sign: this.captchaSign(this.auth.deviceId, ts),
            client_version: CLIENT_VERSION,
            package_name: PACKAGE_NAME,
            user_id: this.auth.userId, // 登录前可能为空
            timestamp: ts
        };
        const payload = {
            client_id: CLIENT_ID,
            action: action,
            device_id: this.auth.deviceId,
            meta: meta
        };
        
        try {
            console.log('🛡️ [PikPak] 初始化安全验证...');
            const res = await axios.post(url, payload, this.getAxiosConfig());
            return res.data && res.data.captcha_token;
        } catch(e) {
            console.error('❌ 验证初始化失败:', e.message);
            return null;
        }
    },

    async login() {
        // 1. Refresh Token
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
                // 刷新时好像不需要 device headers 那么严格，但为了保险还是带上
                const res = await axios.post(url, payload, this.getAxiosConfig());
                if (res.data && res.data.access_token) {
                    this.saveToken(res.data);
                    console.log('✅ 刷新成功');
                    return true;
                }
            } catch (e) {
                console.warn('⚠️ 刷新失败，转为重新登录');
                this.auth.refreshToken = ''; 
            }
        }

        // 2. 账号密码登录
        if (!this.auth.username || !this.auth.password) return !!this.auth.token;

        try {
            console.log('🔑 PikPak 尝试加密登录...');
            const loginUrl = 'https://user.mypikpak.com/v1/auth/signin';
            
            // 🔥 第一步: 获取 captcha_token
            const captchaToken = await this.captchaInit(`POST:${loginUrl}`);
            if (!captchaToken) throw new Error("无法获取验证令牌");

            // 🔥 第二步: 携带 token 登录
            const payload = {
                client_id: CLIENT_ID,
                client_secret: CLIENT_SECRET,
                username: this.auth.username,
                password: this.auth.password,
                captcha_token: captchaToken
            };
            
            // 登录请求不需要 Auth 头
            const config = this.getAxiosConfig();
            delete config.headers['Authorization'];

            const res = await axios.post(loginUrl, payload, config);
            if (res.data && res.data.access_token) {
                console.log('✅ 登录成功');
                this.saveToken(res.data);
                return true;
            }
        } catch (e) {
            const data = e.response ? JSON.stringify(e.response.data) : e.message;
            console.error(`❌ 登录失败: ${data}`);
        }
        return false;
    },

    async testConnection() {
        // 清除旧状态强制重试
        this.auth.token = ''; this.auth.refreshToken = '';
        if(global.CONFIG) global.CONFIG.pikpak_token = '';

        const success = await this.login();
        if (!success) return { success: false, msg: "登录失败: 请检查账号密码或代理 (已启用反风控签名)" };

        try {
            const url = `https://api-drive.mypikpak.com/drive/v1/files?filters={"trashed":{"eq":false}}&limit=1`;
            await axios.get(url, this.getAxiosConfig());
            return { success: true, msg: "✅ 连接成功！(加密协议)" };
        } catch (e) {
            return { success: false, msg: `API 错误: ${e.message}` };
        }
    },

    // 其他函数保持 V13.15.4 的修复逻辑 (包含 folder_type 修正)
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
                this.auth.token = '';
                if (await this.login()) return await this._addTaskInternal(url, parentId, false);
            }
            console.error('AddTask Error:', e.response ? JSON.stringify(e.response.data) : e.message);
            return false;
        }
    },
    // ... 其他文件操作函数逻辑不变，省略重复代码 ...
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

echo "✅ [完成] V13.15.6 部署完成！请再次尝试账号密码登录。"
