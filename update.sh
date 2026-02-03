#!/bin/bash
# VERSION = 13.15.11

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.15.11
# 功能: 1. PikPak 推送时自动创建文件夹 (演员-标题)
#       2. 支持封面图上传到 PikPak
#       3. 修复图片抓取正则 & 增加穿盾下载逻辑
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署完美归档版 (V13.15.11)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.15.11"/' package.json

# 2. 升级 bridge.py (增加建文件夹和上传功能)
echo "📝 [1/3] 升级 Python 桥接服务 (支持上传)..."
cat > /app/python_service/bridge.py << 'EOF'
from flask import Flask, request, jsonify
from pikpakapi import PikPakApi
import asyncio
import logging
import hashlib
import base64

app = Flask(__name__)
SESSION = {
    "username": None, "password": None, "access_token": None, 
    "refresh_token": None, "user_id": None, "device_id": None, "proxy": None
}
logging.basicConfig(level=logging.INFO)

def get_client():
    httpx_args = {"timeout": 30}
    if SESSION["proxy"]: httpx_args["proxy"] = SESSION["proxy"]
    client = PikPakApi(
        username=SESSION["username"], password=SESSION["password"], 
        device_id=SESSION["device_id"], httpx_client_args=httpx_args
    )
    if SESSION["access_token"]:
        client.access_token = SESSION["access_token"]
        client.refresh_token = SESSION["refresh_token"]
        client.user_id = SESSION["user_id"]
    return client

@app.route('/login', methods=['POST'])
def login():
    data = request.json
    username = data.get('username')
    password = data.get('password')
    proxy = data.get('proxy')
    httpx_args = {"timeout": 30}
    if proxy: httpx_args["proxy"] = proxy
    temp_client = PikPakApi(username=username, password=password, httpx_client_args=httpx_args)
    try:
        asyncio.run(temp_client.login())
        SESSION.update({
            "username": username, "password": password, "proxy": proxy,
            "access_token": temp_client.access_token, "refresh_token": temp_client.refresh_token,
            "user_id": temp_client.user_id, "device_id": temp_client.device_id
        })
        return jsonify({'success': True})
    except Exception as e:
        return jsonify({'success': False, 'msg': str(e)}), 500

@app.route('/create_folder', methods=['POST'])
def create_folder():
    if not SESSION["access_token"]: return jsonify({'success': False, 'msg': 'No Token'}), 401
    data = request.json
    name = data.get('name')
    parent_id = data.get('parent_id')
    client = get_client()
    try:
        res = asyncio.run(client.create_folder(name=name, parent_id=parent_id))
        return jsonify({'success': True, 'data': res})
    except Exception as e:
        return jsonify({'success': False, 'msg': str(e)}), 500

@app.route('/add_task', methods=['POST'])
def add_task():
    if not SESSION["access_token"]: return jsonify({'success': False}), 401
    data = request.json
    client = get_client()
    try:
        res = asyncio.run(client.offline_download(file_url=data.get('url'), parent_id=data.get('parent_id')))
        return jsonify({'success': True, 'data': res})
    except Exception as e:
        return jsonify({'success': False, 'msg': str(e)}), 500

@app.route('/upload_file', methods=['POST'])
def upload_file():
    if not SESSION["access_token"]: return jsonify({'success': False}), 401
    data = request.json
    name = data.get('name')
    parent_id = data.get('parent_id')
    file_content = base64.b64decode(data.get('content')) # 接收 Base64
    
    client = get_client()
    try:
        # 手动实现上传流程
        # 1. 计算 Hash
        sha1 = hashlib.sha1(file_content).hexdigest()
        size = len(file_content)
        
        # 2. 创建上传任务
        create_url = f"https://{client.PIKPAK_API_HOST}/drive/v1/files"
        payload = {
            "kind": "drive#file", "name": name, "upload_type": "UPLOAD_TYPE_RESUMABLE",
            "hash": sha1, "size": size
        }
        if parent_id: payload["parent_id"] = parent_id
        
        # 使用 client 的内部方法发送请求
        create_res = asyncio.run(client._request_post(create_url, payload))
        upload_url = create_res.get("upload_url")
        file_id = create_res.get("file", {}).get("id")
        
        # 3. 上传数据
        if upload_url:
            # PUT 请求需要特殊的 content-type
            headers = {"Content-Type": ""}
            asyncio.run(client.httpx_client.put(upload_url, content=file_content, headers=headers))
            
        return jsonify({'success': True, 'file_id': file_id})
    except Exception as e:
        logging.exception("Upload failed")
        return jsonify({'success': False, 'msg': str(e)}), 500

@app.route('/test', methods=['GET'])
def test():
    if not SESSION["access_token"]: return jsonify({'success': False}), 401
    client = get_client()
    try:
        res = asyncio.run(client.file_list(limit=1))
        return jsonify({'success': True, 'data': res})
    except Exception as e:
        return jsonify({'success': False, 'msg': str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5005)
EOF

# 3. 升级 LoginPikPak (暴露新接口)
echo "📝 [2/3] 升级 PikPak 驱动..."
cat > modules/login_pikpak.js << 'EOF'
const axios = require('axios');
const { spawn } = require('child_process');

let pythonProcess = null;
const BRIDGE_URL = 'http://127.0.0.1:5005';

const LoginPikPak = {
    auth: { username: '', password: '' },
    proxy: null,

    setConfig(cfg) {
        if (!cfg) return;
        if (cfg.pikpak && cfg.pikpak.includes('|')) {
            const parts = cfg.pikpak.split('|');
            this.auth.username = parts[0].trim();
            this.auth.password = parts[1].trim();
        }
        if (cfg.proxy) this.proxy = cfg.proxy;
        this.ensureBridgeRunning();
    },

    ensureBridgeRunning() {
        if (pythonProcess && !pythonProcess.killed) return;
        console.log('🐍 [Bridge] 正在启动 Python 中间件...');
        pythonProcess = spawn('python3', ['-u', '/app/python_service/bridge.py'], { stdio: 'inherit' });
        pythonProcess.on('error', (err) => console.error('🐍 [Bridge] 启动失败:', err));
    },

    async waitForBridge() {
        this.ensureBridgeRunning();
        for (let i = 0; i < 20; i++) {
            try {
                await axios.get(`${BRIDGE_URL}/test`, { timeout: 1000 });
                return true;
            } catch (e) {
                if (e.code !== 'ECONNREFUSED' && e.code !== 'ECONNRESET') return true;
                await new Promise(r => setTimeout(r, 500));
            }
        }
        return false;
    },

    async login() {
        await this.waitForBridge();
        try {
            const payload = { username: this.auth.username, password: this.auth.password, proxy: this.proxy };
            const res = await axios.post(`${BRIDGE_URL}/login`, payload);
            return res.data.success;
        } catch (e) { return false; }
    },

    async testConnection() {
        await this.waitForBridge();
        const loginOk = await this.login();
        if (!loginOk) return { success: false, msg: "登录失败" };
        try {
            const res = await axios.get(`${BRIDGE_URL}/test`);
            if (res.data.success) return { success: true, msg: "✅ 桥接连接成功" };
            return { success: false, msg: res.data.msg };
        } catch(e) { return { success: false, msg: e.message }; }
    },

    // 🔥 新增: 创建文件夹
    async createFolder(name, parentId = '') {
        await this.waitForBridge();
        try {
            const res = await axios.post(`${BRIDGE_URL}/create_folder`, { name, parent_id: parentId });
            if (res.data.success) return res.data.data.file.id;
        } catch (e) { console.error('🐍 CreateFolder Err:', e.message); }
        return null;
    },

    // 🔥 新增: 上传文件
    async uploadFile(buffer, name, parentId = '') {
        await this.waitForBridge();
        try {
            // 转为 Base64 传给 Python
            const base64Content = buffer.toString('base64');
            const res = await axios.post(`${BRIDGE_URL}/upload_file`, { 
                name, parent_id: parentId, content: base64Content 
            }, { maxBodyLength: Infinity, maxContentLength: Infinity });
            return res.data.success;
        } catch (e) { console.error('🐍 UploadFile Err:', e.message); }
        return false;
    },

    async addTask(url, parentId = '') {
        await this.waitForBridge();
        try {
            const res = await axios.post(`${BRIDGE_URL}/add_task`, { url, parent_id: parentId });
            return res.data.success;
        } catch (e) { return false; }
    },
    
    // 兼容层
    async getFileList() { return { data: [] }; },
    async searchFile() { return { data: [] }; },
    async rename() { return { success: true }; },
    async move() { return true; },
    async getTaskByHash() { return null; } 
};

if(global.CONFIG) LoginPikPak.setConfig(global.CONFIG);
module.exports = LoginPikPak;
EOF

# 4. 升级 Scraper (实现文件夹+海报逻辑)
echo "📝 [3/3] 升级采集器 (归档/穿盾下载)..."
cat >> modules/scraper_xchina.js << 'EOF'

// 🔥 补丁: 穿盾下载 helper
async function downloadImage(url, baseUrl) {
    if (!url) return null;
    if (!url.startsWith('http')) url = baseUrl + url;
    
    // 使用 axios 配合 User-Agent 和 Referer 尝试穿盾
    try {
        const config = { 
            responseType: 'arraybuffer',
            headers: {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                'Referer': baseUrl
            },
            timeout: 15000
        };
        // 如果配了代理，走代理
        if (global.CONFIG.proxy) {
            const { HttpsProxyAgent } = require('https-proxy-agent');
            config.httpsAgent = new HttpsProxyAgent(global.CONFIG.proxy);
            config.proxy = false;
        }
        
        const res = await axios.get(url, config);
        return res.data;
    } catch (e) {
        console.error(`🖼️ 图片下载失败: ${e.message}`);
        return null;
    }
}

// 🔥 补丁: 覆盖 processVideoTask
async function processVideoTask(task, baseUrl, autoDownload) {
    const { link } = task; 
    
    const flareApi = getFlareUrl();
    let htmlContent = "";
    try {
        const payload = { cmd: 'request.get', url: link, maxTimeout: 60000 };
        if (global.CONFIG.proxy) payload.proxy = { url: global.CONFIG.proxy };
        const res = await axios.post(flareApi, payload, { headers: { 'Content-Type': 'application/json' } });
        if (res.data.status === 'ok') htmlContent = res.data.solution.response;
        else throw new Error(res.data.message);
    } catch(e) { throw new Error(`Req Err: ${e.message}`); }

    const $ = cheerio.load(htmlContent);
    let title = $('h1').text().trim() || task.title;
    
    // 🔥 增强版图片正则 (支持转义字符)
    let image = '';
    // 匹配 poster: 'https:\/\/...' 或 poster: "..."
    const regexPoster = /(?:poster|pic|thumb)\s*[:=]\s*['"]([^'"]+)['"]/i;
    const match = htmlContent.match(regexPoster);
    if (match && match[1]) {
        image = match[1].replace(/\\\//g, '/'); // 修复转义斜杠
    } else {
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

    // 1. 找磁力
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

    // 2. 找 M3U8
    if (!magnet) {
        const regexVideo = /src:\s*['"](https?:\/\/[^'"]+\.m3u8[^'"]*)['"]/;
        const matchVideo = htmlContent.match(regexVideo);
        if (matchVideo && matchVideo[1]) {
            magnet = matchVideo[1].replace(/\\\//g, '/');
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
            
            // 🔥 自动归档流程 🔥
            if (driveType === 'pikpak') {
                // 1. 创建文件夹
                const folderName = `${actor} - ${title}`.trim();
                const folderId = await LoginPikPak.createFolder(folderName);
                
                if (folderId) {
                    // 2. 推送视频到该文件夹
                    const pushed = await LoginPikPak.addTask(magnet, folderId);
                    
                    // 3. 下载并上传海报
                    if (image) {
                        const imgBuf = await downloadImage(image, baseUrl);
                        if (imgBuf) {
                            await LoginPikPak.uploadFile(imgBuf, 'poster.jpg', folderId);
                        }
                    }
                    extraMsg = pushed ? " | 🚀 已推送+归档" : " | ⚠️ 推送失败";
                    if(pushed) await ResourceMgr.markAsPushedByLink(link);
                } else {
                    extraMsg = " | ⚠️ 建文件夹失败";
                }
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

# 5. 重启应用
echo "🔄 重启应用..."
pkill -f "node app.js" || echo "应用可能未运行。"
pkill -f "python3 -u /app/python_service/bridge.py" || true

echo "✅ [完成] V13.15.11 部署完成！"
