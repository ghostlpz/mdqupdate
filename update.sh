#!/bin/bash
# VERSION = 13.15.9

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.15.9
# 修复: Python 桥接服务 httpx 代理参数报错 (proxies -> proxy)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署 httpx 兼容修复版 (V13.15.9)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.15.9"/' package.json

# 2. 修复 bridge.py (关键修复: proxies -> proxy)
echo "📝 [1/1] 修正 Python 桥接服务..."
cat > /app/python_service/bridge.py << 'EOF'
from flask import Flask, request, jsonify
from pikpakapi import PikPakApi
import asyncio
import logging

app = Flask(__name__)
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
    
    # 🔥 关键修复: 新版 httpx 使用 'proxy' 而非 'proxies'
    httpx_args = {"timeout": 30}
    if proxy:
        httpx_args["proxy"] = proxy
        
    client = PikPakApi(username=username, password=password, httpx_client_args=httpx_args)
    
    try:
        asyncio.run(client.login())
        return jsonify({'success': True, 'msg': 'Login Successful'})
    except Exception as e:
        # 打印完整堆栈以便调试
        logging.exception("Login failed")
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
        logging.exception("Add task failed")
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

# 3. 杀掉旧进程并重启
echo "🔄 重启应用..."
pkill -f "python3 -u /app/python_service/bridge.py" || true
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.15.9 部署完成！"
echo "👉 请再次点击“测试连接”，这次应该能成功登录了。"
