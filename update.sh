#!/bin/bash
# VERSION = 13.15.10

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.15.10
# 修复: Python 桥接服务 Event loop is closed 错误 (改为单例 Token 多例 Client)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署异步循环修复版 (V13.15.10)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.15.10"/' package.json

# 2. 重写 bridge.py (关键修复: 每次请求重新实例化 Client)
echo "📝 [1/1] 修正 Python 桥接服务..."
cat > /app/python_service/bridge.py << 'EOF'
from flask import Flask, request, jsonify
from pikpakapi import PikPakApi
import asyncio
import logging

app = Flask(__name__)

# 🔥 全局只存 Session 数据，不存 client 对象
SESSION = {
    "username": None,
    "password": None,
    "access_token": None,
    "refresh_token": None,
    "user_id": None,
    "device_id": None,
    "proxy": None
}

logging.basicConfig(level=logging.INFO)

# 工厂函数: 每次调用生成一个带 Token 的新 Client
def get_fresh_client():
    httpx_args = {"timeout": 30}
    if SESSION["proxy"]:
        httpx_args["proxy"] = SESSION["proxy"]
        
    client = PikPakApi(
        username=SESSION["username"], 
        password=SESSION["password"], 
        device_id=SESSION["device_id"], # 保持 DeviceID 一致防止风控
        httpx_client_args=httpx_args
    )
    
    # 注入保存的 Token，免登录
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
    if proxy:
        httpx_args["proxy"] = proxy
        
    # 登录时创建临时 Client
    temp_client = PikPakApi(username=username, password=password, httpx_client_args=httpx_args)
    
    try:
        asyncio.run(temp_client.login())
        
        # 登录成功，保存 Session 数据
        SESSION["username"] = username
        SESSION["password"] = password
        SESSION["proxy"] = proxy
        SESSION["access_token"] = temp_client.access_token
        SESSION["refresh_token"] = temp_client.refresh_token
        SESSION["user_id"] = temp_client.user_id
        SESSION["device_id"] = temp_client.device_id
        
        return jsonify({'success': True, 'msg': 'Login Successful'})
    except Exception as e:
        logging.exception("Login failed")
        return jsonify({'success': False, 'msg': str(e)}), 500

@app.route('/add_task', methods=['POST'])
def add_task():
    if not SESSION["access_token"]:
        return jsonify({'success': False, 'msg': 'Not Logged In'}), 401
    
    data = request.json
    url = data.get('url')
    parent_id = data.get('parent_id')
    
    # 🔥 关键点: 每次请求用新的 Client，避免 Event Loop 关闭问题
    client = get_fresh_client()
    
    try:
        res = asyncio.run(client.offline_download(file_url=url, parent_id=parent_id))
        return jsonify({'success': True, 'data': res})
    except Exception as e:
        logging.exception("Add task failed")
        return jsonify({'success': False, 'msg': str(e)}), 500

@app.route('/test', methods=['GET'])
def test():
    if not SESSION["access_token"]:
        return jsonify({'success': False, 'msg': 'Session not initialized'}), 401
        
    client = get_fresh_client()
    try:
        res = asyncio.run(client.file_list(limit=1))
        return jsonify({'success': True, 'data': res})
    except Exception as e:
        return jsonify({'success': False, 'msg': str(e)}), 500

if __name__ == '__main__':
    print("🚀 Python Bridge running on port 5005...")
    app.run(host='0.0.0.0', port=5005)
EOF

# 3. 杀掉旧进程并重启
echo "🔄 重启应用..."
pkill -f "python3 -u /app/python_service/bridge.py" || true
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.15.10 部署完成！"
echo "👉 这次应该稳了，请再次测试采集！"
