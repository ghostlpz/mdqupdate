#!/bin/sh
# VERSION=13.2.1

echo "🚀 [容器内] 开始执行 OTA 在线升级 (Target: V13.2.1)..."

# 1. 确保在正确的工作目录
cd /app

echo "📂 正在更新系统文件..."

# 2. 更新 Package.json (直接覆盖当前目录文件)
cat > package.json << 'EOF'
{
  "name": "madou-omni-system",
  "version": "13.2.1",
  "main": "app.js",
  "dependencies": {
    "axios": "^1.6.0",
    "cheerio": "^1.0.0-rc.12",
    "cookie-parser": "^1.4.6",
    "cors": "^2.8.5",
    "express": "^4.18.2",
    "https-proxy-agent": "^7.0.2",
    "mysql2": "^3.6.5",
    "node-schedule": "^2.1.1",
    "json2csv": "^6.0.0-alpha.2"
  }
}
EOF

# 3. 更新 UI (增加手机适配)
# 确保目标目录存在
mkdir -p public

cat > public/index.html << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN" data-bs-theme="dark">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Madou Omni V13.2.1 Mobile</title>
    <style>
        :root{--bg:#1e1e2f;--card:#27293d;--txt:#e1e1e6;--acc:#e14eca}
        body{background:var(--bg);color:var(--txt);font-family:sans-serif;margin:0;display:flex}
        
        .sidebar{width:240px;background:#000;height:100vh;display:flex;flex-direction:column;border-right:1px solid #333;flex-shrink:0}
        .sidebar h2{padding:20px;text-align:center;color:var(--acc);margin:0;border-bottom:1px solid #333}
        .nav-item{padding:15px 20px;cursor:pointer;color:#aaa;text-decoration:none;display:block;transition:0.3s}
        .nav-item:hover,.nav-item.active{color:var(--acc);background:#ffffff0d;font-weight:bold;border-left:4px solid var(--acc)}
        
        .main{flex:1;padding:20px;overflow-y:auto;height:100vh;width:100%}
        .card{background:var(--card);border-radius:8px;padding:20px;margin-bottom:20px}
        
        .log-box{height:350px;background:#111;color:#0f0;font-family:monospace;font-size:12px;overflow-y:scroll;padding:10px;border-radius:4px;white-space: pre-wrap;word-break: break-all;}
        .log-box .err{color:#f55} .log-box .warn{color:#fb5} .log-box .suc{color:#5f7}
        
        .btn{padding:10px 20px;border:none;border-radius:4px;cursor:pointer;color:#fff;font-weight:bold;margin-right:10px}
        .btn-pri{background:var(--acc)} .btn-dang{background:#d33} .btn-succ{background:#28a745} .btn-warn{background:#ffc107;color:#000}
        .btn-info{background:#17a2b8;color:#fff}
        
        input,textarea{background:#111;border:1px solid #444;color:#fff;padding:8px;border-radius:4px;width:100%;box-sizing:border-box;margin-bottom:10px}
        table{width:100%;border-collapse:collapse;table-layout:fixed;} 
        th,td{text-align:left;padding:10px;border-bottom:1px solid #444;overflow:hidden;text-overflow:ellipsis;vertical-align:middle;}
        
        .tag { padding: 2px 6px; border-radius: 4px; font-size: 10px; font-weight: bold; margin-right: 5px; }
        .tag-push { background: #28a745; color: #fff; }
        .tag-ren { background: #17a2b8; color: #fff; }
        
        #lock{position:fixed;top:0;left:0;width:100%;height:100%;background:#000;z-index:999;display:flex;justify-content:center;align-items:center}
        #lock .box{background:var(--card);padding:40px;border-radius:10px;width:300px;text-align:center;border:1px solid #444}
        .hidden{display:none!important}
        .check-group { display: flex; align-items: center; margin-bottom: 15px; }
        .check-group input { width: 20px; height: 20px; margin: 0 10px 0 0; }
        .tbl-chk { width: 18px; height: 18px; cursor: pointer; }

        /* 🔥 手机端适配 */
        @media (max-width: 768px) {
            body { flex-direction: column; }
            .sidebar { width: 100%; height: auto; flex-direction: row; flex-wrap: wrap; border-right: none; border-bottom: 2px solid #333; padding-bottom: 5px; justify-content: space-around; }
            .sidebar h2 { width: 100%; border-bottom: none; padding: 10px; font-size: 18px; }
            .nav-item { border-left: none !important; border-bottom: 3px solid transparent; padding: 10px 5px; font-size: 13px; flex: 1; text-align: center; white-space: nowrap; }
            .nav-item.active { border-bottom: 3px solid var(--acc); background: none; color: var(--acc); }
            .main { padding: 10px; height: auto; overflow: visible; }
            .card { padding: 15px; }
            .btn { display: block; width: 100%; margin-bottom: 10px; margin-right: 0; padding: 12px 0; }
            .card:has(table) { overflow-x: auto; -webkit-overflow-scrolling: touch; }
            table { min-width: 600px; }
            #g-status { width: 100%; padding: 10px; font-size: 12px; background: #111; }
        }
    </style>
</head>
<body>
    <div id="lock">
        <div class="box">
            <h2 style="color:#e14eca">🔒 系统锁定</h2>
            <input type="password" id="pass" placeholder="请输入密码" style="text-align:center;font-size:18px;margin:20px 0">
            <button class="btn btn-pri" style="width:100%" onclick="login()">解锁</button>
            <div id="msg" style="color:#f55;margin-top:10px"></div>
        </div>
    </div>

    <div class="sidebar">
        <h2>🤖 Madou</h2>
        <a class="nav-item active" onclick="show('scraper')">采集</a>
        <a class="nav-item" onclick="show('renamer')">整理</a>
        <a class="nav-item" onclick="show('database')">库</a>
        <a class="nav-item" onclick="show('settings')">设置</a>
        <div style="margin-top:auto;padding:20px;text-align:center;color:#666" id="g-status">待机</div>
    </div>

    <div class="main">
        <div id="scraper" class="page">
            <h1>资源采集</h1>
            <div class="card">
                <div class="check-group">
                    <input type="checkbox" id="auto-dl">
                    <label for="auto-dl">📥 采集成功后自动推送到 115 离线下载</label>
                </div>
                <button class="btn btn-succ" onclick="api('start',{type:'inc', autoDownload: getDlState()})">▶ 增量采集</button>
                <button class="btn btn-warn" onclick="api('start',{type:'full', autoDownload: getDlState()})">♻️ 全量采集</button>
                <button class="btn btn-dang" onclick="api('stop')">⏹ 停止</button>
                <span style="float:right;font-size:20px">本次采集: <b id="stat-scr" style="color:#e14eca">0</b></span>
            </div>
            <div class="card">
                <h3>实时日志</h3>
                <div id="log-scr" class="log-box"></div>
            </div>
        </div>

        <div id="renamer" class="page hidden">
            <h1>115 整理</h1>
            <div class="card">
                <label>扫描页数 (0=全部)</label>
                <input type="number" id="r-pages" value="0">
                <div class="check-group" style="margin-top:10px">
                    <input type="checkbox" id="r-force">
                    <label for="r-force">⚠️ 强制重新整理 (勾选后会处理“已整理”的项目，速度较慢)</label>
                </div>
                <button class="btn btn-pri" onclick="startRenamer()">▶ 开始整理</button>
                <button class="btn btn-dang" onclick="api('stop')">⏹ 停止</button>
                <div style="margin-top:10px">
                    成功: <b style="color:#5f7" id="stat-suc">0</b> | 
                    失败: <b style="color:#f55" id="stat-fail">0</b> | 
                    跳过: <b style="color:#aaa" id="stat-skip">0</b>
                </div>
            </div>
            <div class="card">
                <h3>操作日志</h3>
                <div id="log-ren" class="log-box"></div>
            </div>
        </div>

        <div id="database" class="page hidden">
            <h1>已入库资源</h1>
            <div class="card">
                <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:10px">
                    <div>
                        <button class="btn btn-pri" style="width:auto" onclick="loadDb(dbPage-1)">◀</button>
                        <span id="page-info" style="margin:0 10px">第 1 页</span>
                        <button class="btn btn-pri" style="width:auto" onclick="loadDb(dbPage+1)">▶</button>
                    </div>
                    <h3 style="margin:0; color:#e14eca; font-size:16px" id="total-count">📚 0</h3>
                </div>
                <div style="float:right; margin-bottom:10px; width:100%">
                    <button class="btn btn-info" onclick="pushSelected()">📤 推送选中</button>
                    <button class="btn btn-warn" onclick="window.open(url('/export?type=all'))">导出全部</button>
                </div>
            </div>
            <div class="card">
                <table id="db-tbl">
                    <thead>
                        <tr>
                            <th style="width:30px"><input type="checkbox" class="tbl-chk" onclick="toggleAll(this)"></th>
                            <th style="width:40px">ID</th>
                            <th style="width:40%">标题</th>
                            <th style="width:35%">磁力链</th>
                            <th style="width:120px">入库时间</th>
                        </tr>
                    </thead>
                    <tbody></tbody>
                </table>
            </div>
        </div>

        <div id="settings" class="page hidden">
            <h1>设置</h1>
            <div class="card" style="text-align:center">
                <button class="btn btn-pri" onclick="showQr()">📱 115 扫码登录</button>
                <p style="color:#888;margin-top:10px">扫码后 Cookie 自动填充</p>
            </div>
            
            <div class="card" style="border-left: 4px solid #e14eca">
                <div style="display:flex; justify-content:space-between; align-items:center">
                    <h3>🔄 系统升级</h3>
                    <span id="cur-ver" style="color:#e14eca; font-weight:bold">V13.2.1</span>
                </div>
                <p style="color:#aaa; font-size:12px; margin-bottom:10px">
                    升级源: GitHub (ghostlpz/mdqupdate) <br>
                    系统会自动检测新版本。如果存在更新，将自动下载并重启。
                </p>
                <button class="btn btn-warn" onclick="runOnlineUpdate()">☁️ 检查并升级</button>
            </div>

            <div class="card">
                <label>HTTP 代理</label>
                <input id="cfg-proxy" placeholder="http://...">
                <label>Cookie</label>
                <textarea id="cfg-cookie" rows="5"></textarea>
                <button class="btn btn-pri" onclick="saveCfg()">保存配置</button>
            </div>
        </div>
    </div>

    <div id="modal" style="display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:#000000cc;z-index:900;justify-content:center;align-items:center">
        <div style="background:#fff;padding:20px;border-radius:8px;text-align:center">
            <h3 style="color:#000">115 扫码</h3>
            <div id="qr-img"></div>
            <div id="qr-txt" style="color:#000;margin-top:10px">...</div>
            <button class="btn btn-dang" onclick="document.getElementById('modal').style.display='none'" style="margin-top:10px">关闭</button>
        </div>
    </div>

    <script src="js/app.js"></script>
</body>
</html>
EOF

echo "📦 正在安装依赖..."
# 注意：容器内没有 docker 命令，直接运行 npm
# 使用国内源加速
npm install --registry=https://registry.npmmirror.com

echo "✅ 升级完成！脚本退出后容器将自动重启..."
