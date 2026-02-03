#!/bin/bash
# VERSION = 13.15.7

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.15.7 (Plan B)
# 核心: 部署 Python 中间件，调用原生 pikpakapi 库
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署 Python 桥接版 (V13.15.7)..."

# 1. 环境检测与安装 Python
echo "🔧 [1/5] 正在安装 Python3 环境 (可能需要几分钟)..."
if command -v apk > /dev/null; then
    # Alpine Linux
    sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories
    apk add --no-cache python3 py3-pip
elif command -v apt-get > /dev/null; then
    # Debian/Ubuntu
    apt-get update
    apt-get install -y python3 python3-pip
else
    echo "⚠️ 无法识别系统包管理器，尝试直接使用 python3..."
fi

# 安装 Python 依赖
echo "📦 [2/5] 安装 Python 依赖库 (flask, httpx)..."
pip3 install flask httpx --break-system-packages 2>/dev/null || pip3 install flask httpx

# 2. 部署 Python 代码结构
echo "📝 [3/5] 部署 Python 微服务代码..."
mkdir -p /app/python_service/pikpakapi

# --- 写入 pikpakapi/__init__.py ---
cat > /app/python_service/pikpakapi/__init__.py << 'EOF'
import asyncio
import binascii
import inspect
import json
import logging
import re
from base64 import b64decode, b64encode
from hashlib import md5
from types import NoneType
from typing import Any, Dict, List, Optional, Callable, Coroutine
import httpx
from .PikpakException import PikpakException, PikpakRetryException
from .enums import DownloadStatus
from .utils import (
    CLIENT_ID, CLIENT_SECRET, CLIENT_VERSION, PACKAG_ENAME,
    build_custom_user_agent, captcha_sign, get_timestamp,
)

class PikPakApi:
    PIKPAK_API_HOST = "api-drive.mypikpak.com"
    PIKPAK_USER_HOST = "user.mypikpak.com"

    def __init__(self, username=None, password=None, encoded_token=None, httpx_client_args=None, device_id=None):
        self.username = username
        self.password = password
        self.encoded_token = encoded_token
        self.access_token = None
        self.refresh_token = None
        self.user_id = None
        self.device_id = device_id if device_id else md5(f"{username}{password}".encode()).hexdigest()
        self.captcha_token = None
        httpx_client_args = httpx_client_args or {"timeout": 30}
        self.httpx_client = httpx.AsyncClient(**httpx_client_args)
        self._path_id_cache = {}
        self.user_agent = None
        if encoded_token: self.decode_token()

    def get_headers(self):
        headers = {
            "User-Agent": self.build_custom_user_agent() if self.captcha_token else "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            "Content-Type": "application/json; charset=utf-8",
        }
        if self.access_token: headers["Authorization"] = f"Bearer {self.access_token}"
        if self.captcha_token: headers["X-Captcha-Token"] = self.captcha_token
        if self.device_id: headers["X-Device-Id"] = self.device_id
        return headers

    def build_custom_user_agent(self):
        self.user_agent = build_custom_user_agent(device_id=self.device_id, user_id=self.user_id or "")
        return self.user_agent

    async def _request_post(self, url, data=None, headers=None):
        req_headers = headers or self.get_headers()
        resp = await self.httpx_client.post(url, json=data, headers=req_headers)
        try: return resp.json()
        except: return {}

    async def _request_get(self, url, params=None):
        resp = await self.httpx_client.get(url, params=params, headers=self.get_headers())
        return resp.json()

    async def captcha_init(self, action, meta=None):
        url = f"https://{self.PIKPAK_USER_HOST}/v1/shield/captcha/init"
        if not meta:
            t = f"{get_timestamp()}"
            meta = {
                "captcha_sign": captcha_sign(self.device_id, t),
                "client_version": CLIENT_VERSION,
                "package_name": PACKAG_ENAME,
                "user_id": self.user_id,
                "timestamp": t,
            }
        params = {"client_id": CLIENT_ID, "action": action, "device_id": self.device_id, "meta": meta}
        return await self._request_post(url, data=params)

    async def login(self):
        login_url = f"https://{self.PIKPAK_USER_HOST}/v1/auth/signin"
        metas = {"username": self.username}
        if re.match(r"\w+([-+.]\w+)*@\w+([-.]\w+)*\.\w+([-.]\w+)*", self.username): metas["email"] = self.username
        
        result = await self.captcha_init(action=f"POST:{login_url}", meta=metas)
        captcha_token = result.get("captcha_token", "")
        if not captcha_token: raise Exception("Captcha Init Failed")
        self.captcha_token = captcha_token # 临时存一下用于生成 UA

        login_data = {
            "client_id": CLIENT_ID, "client_secret": CLIENT_SECRET,
            "password": self.password, "username": self.username,
            "captcha_token": captcha_token,
        }
        # 登录请求也要带上精心构造的 UA
        headers = self.get_headers()
        # 注意：登录接口 content-type 不能是 json，得是这个，但看源码它似乎又是 json post? 
        # 原码里 login_data 是 dict，_request_post 发的是 json。
        # 但源码有一处注释说 "Content-Type": "application/x-www-form-urlencoded"
        # 我们按源码逻辑走，它其实是 json post。
        
        resp = await self.httpx_client.post(login_url, json=login_data, headers=headers)
        user_info = resp.json()
        
        if "error" in user_info: raise Exception(user_info.get("error_description", "Login Failed"))
        
        self.access_token = user_info["access_token"]
        self.refresh_token = user_info["refresh_token"]
        self.user_id = user_info["sub"]
        self.captcha_token = None # 用完销毁

    async def offline_download(self, file_url, parent_id=None, name=None):
        url = f"https://{self.PIKPAK_API_HOST}/drive/v1/files"
        data = {
            "kind": "drive#file",
            "name": name,
            "upload_type": "UPLOAD_TYPE_URL",
            "url": {"url": file_url},
            "folder_type": "DOWNLOAD" if not parent_id else "",
            "parent_id": parent_id
        }
        return await self._request_post(url, data)

    async def file_list(self, parent_id=None, limit=100):
        url = f"https://{self.PIKPAK_API_HOST}/drive/v1/files"
        params = {
            "parent_id": parent_id, 
            "limit": limit, 
            "filters": json.dumps({"trashed":{"eq":False}})
        }
        return await self._request_get(url, params)
EOF

# --- 写入 pikpakapi/utils.py ---
cat > /app/python_service/pikpakapi/utils.py << 'EOF'
import hashlib
from uuid import uuid4
import time

CLIENT_ID = "YNxT9w7GMdWvEOKa"
CLIENT_SECRET = "dbw2OtmVEeuUvIptb1Coyg"
CLIENT_VERSION = "1.47.1"
PACKAG_ENAME = "com.pikcloud.pikpak"
SDK_VERSION = "2.0.4.204000 "
APP_NAME = PACKAG_ENAME

def get_timestamp() -> int: return int(time.time() * 1000)
def device_id_generator() -> str: return str(uuid4()).replace("-", "")

SALTS = [
    "Gez0T9ijiI9WCeTsKSg3SMlx", "zQdbalsolyb1R/", "ftOjr52zt51JD68C3s",
    "yeOBMH0JkbQdEFNNwQ0RI9T3wU/v", "BRJrQZiTQ65WtMvwO", "je8fqxKPdQVJiy1DM6Bc9Nb1",
    "niV", "9hFCW2R1", "sHKHpe2i96", "p7c5E6AcXQ/IJUuAEC9W6", "",
    "aRv9hjc9P+Pbn+u3krN6", "BzStcgE8qVdqjEH16l4", "SqgeZvL5j9zoHP95xWHt",
    "zVof5yaJkPe3VFpadPof",
]

def captcha_sign(device_id: str, timestamp: str) -> str:
    sign = CLIENT_ID + CLIENT_VERSION + PACKAG_ENAME + device_id + timestamp
    for salt in SALTS: sign = hashlib.md5((sign + salt).encode()).hexdigest()
    return f"1.{sign}"

def generate_device_sign(device_id, package_name):
    base = f"{device_id}{package_name}1appkey"
    sha1 = hashlib.sha1(base.encode("utf-8")).hexdigest()
    md5 = hashlib.md5(sha1.encode("utf-8")).hexdigest()
    return f"div101.{device_id}{md5}"

def build_custom_user_agent(device_id, user_id):
    ds = generate_device_sign(device_id, PACKAG_ENAME)
    parts = [
        f"ANDROID-{APP_NAME}/{CLIENT_VERSION}", "protocolVersion/200", "accesstype/",
        f"clientid/{CLIENT_ID}", f"clientversion/{CLIENT_VERSION}", "action_type/",
        "networktype/WIFI", "sessionid/", f"deviceid/{device_id}", "providername/NONE",
        f"devicesign/{ds}", "refresh_token/", f"sdkversion/{SDK_VERSION}",
        f"datetime/{get_timestamp()}", f"usrno/{user_id}", f"appname/{APP_NAME}",
        "session_origin/", "grant_type/", "appid/", "clientip/",
        "devicename/Xiaomi_M2004j7ac", "osversion/13", "platformversion/10",
        "accessmode/", "devicemodel/M2004J7AC",
    ]
    return " ".join(parts)
EOF

# --- 写入 pikpakapi/enums.py ---
cat > /app/python_service/pikpakapi/enums.py << 'EOF'
from enum import Enum
class DownloadStatus(Enum):
    downloading = "downloading"
    done = "done"
    error = "error"
    not_found = "not_found"
EOF

# --- 写入 pikpakapi/PikpakException.py ---
cat > /app/python_service/pikpakapi/PikpakException.py << 'EOF'
class PikpakException(Exception): pass
class PikpakAccessTokenExpireException(PikpakException): pass
class PikpakRetryException(PikpakException): pass
EOF

# --- 写入 bridge.py (桥接服务) ---
cat > /app/python_service/bridge.py << 'EOF'
from flask import Flask, request, jsonify
from pikpakapi import PikPakApi
import asyncio
import logging

app = Flask(__name__)
# 全局 Client 实例，保持会话
client = None

# 设置日志
logging.basicConfig(level=logging.INFO)

@app.route('/login', methods=['POST'])
def login():
    global client
    data = request.json
    username = data.get('username')
    password = data.get('password')
    proxy = data.get('proxy')
    
    # 配置代理
    httpx_args = {}
    if proxy:
        httpx_args = {"proxies": proxy, "timeout": 30}
        
    client = PikPakApi(username=username, password=password, httpx_client_args=httpx_args)
    
    try:
        # 异步调用 login
        asyncio.run(client.login())
        return jsonify({'success': True, 'msg': 'Login Successful'})
    except Exception as e:
        return jsonify({'success': False, 'msg': str(e)}), 500

@app.route('/add_task', methods=['POST'])
def add_task():
    global client
    if not client or not client.access_token:
        return jsonify({'success': False, 'msg': 'Not Logged In'}), 401
    
    data = request.json
    url = data.get('url')
    parent_id = data.get('parent_id')
    
    try:
        res = asyncio.run(client.offline_download(file_url=url, parent_id=parent_id))
        return jsonify({'success': True, 'data': res})
    except Exception as e:
        return jsonify({'success': False, 'msg': str(e)}), 500

@app.route('/test', methods=['GET'])
def test():
    global client
    if not client or not client.access_token:
        return jsonify({'success': False, 'msg': 'Session not initialized'}), 401
    try:
        res = asyncio.run(client.file_list(limit=1))
        return jsonify({'success': True, 'data': res})
    except Exception as e:
        return jsonify({'success': False, 'msg': str(e)}), 500

if __name__ == '__main__':
    print("🚀 Python Bridge running on port 5005...")
    app.run(host='0.0.0.0', port=5005)
EOF

# 3. 更新 Node.js 驱动 (login_pikpak.js) 以调用本地 Python 服务
echo "📝 [4/5] 更新 Node.js 驱动以连接 Python 服务..."
cat > modules/login_pikpak.js << 'EOF'
const axios = require('axios');
const { spawn } = require('child_process');
const path = require('path');

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
        
        // 确保 Python 服务运行
        this.ensureBridgeRunning();
    },

    ensureBridgeRunning() {
        if (pythonProcess) return;
        console.log('🐍 [Bridge] 正在启动 Python 中间件...');
        pythonProcess = spawn('python3', ['/app/python_service/bridge.py'], { stdio: 'inherit' });
        pythonProcess.on('error', (err) => console.error('🐍 [Bridge] 启动失败:', err));
    },

    async login() {
        this.ensureBridgeRunning();
        await new Promise(r => setTimeout(r, 2000)); // 等待启动
        try {
            const payload = {
                username: this.auth.username,
                password: this.auth.password,
                proxy: this.proxy
            };
            const res = await axios.post(`${BRIDGE_URL}/login`, payload);
            return res.data.success;
        } catch (e) {
            console.error('🐍 [Bridge] Login Err:', e.message);
            return false;
        }
    },

    async testConnection() {
        if (!this.auth.username) return { success: false, msg: "请先配置账号密码" };
        const loginOk = await this.login();
        if (!loginOk) return { success: false, msg: "Python 桥接服务登录失败" };
        
        try {
            const res = await axios.get(`${BRIDGE_URL}/test`);
            if (res.data.success) return { success: true, msg: "✅ 桥接连接成功 (Python)" };
            return { success: false, msg: "Python API 测试失败: " + res.data.msg };
        } catch(e) { return { success: false, msg: "无法连接 Python 服务: " + e.message }; }
    },

    async addTask(url, parentId = '') {
        try {
            const res = await axios.post(`${BRIDGE_URL}/add_task`, { url, parent_id: parentId });
            return res.data.success;
        } catch (e) {
            // 如果 401 尝试重登一次
            if (e.response && e.response.status === 401) {
                await this.login();
                try {
                    const res2 = await axios.post(`${BRIDGE_URL}/add_task`, { url, parent_id: parentId });
                    return res2.data.success;
                } catch(e2) { return false; }
            }
            console.error('🐍 [Bridge] AddTask Err:', e.message);
            return false;
        }
    },
    
    // 兼容层占位
    async getFileList() { return { data: [] }; },
    async searchFile() { return { data: [] }; },
    async rename() { return { success: true }; },
    async move() { return true; },
    async uploadFile() { return null; },
    async getTaskByHash() { return null; } 
};

if(global.CONFIG) LoginPikPak.setConfig(global.CONFIG);
module.exports = LoginPikPak;
EOF

# 4. 更新 package.json 版本
sed -i 's/"version": ".*"/"version": "13.15.7"/' package.json

# 5. 重启
echo "🔄 [5/5] 重启应用..."
pkill -f "node app.js" || echo "应用可能未运行。"
# 杀掉旧的 python 进程防止冲突
pkill -f "python3 /app/python_service/bridge.py" || true

echo "✅ [完成] V13.15.7 Python 桥接版部署完成！"
echo "👉 请在设置页填入 '账号|密码' (无需 Token)，然后点击测试。"
