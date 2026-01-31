#!/bin/sh
# VERSION=13.5.1

echo "🚀 [容器内] 开始执行 V13.5.1 UI 修复..."

cd /app

# 1. 更新 Package.json
cat > package.json << 'EOF'
{
  "name": "madou-omni-system",
  "version": "13.5.1",
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

# 2. 修复 index.html (CSS 调整)
cat > public/index.html << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>Madou Omni Pro</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
    <style>
        :root {
            --primary: #6366f1;
            --primary-hover: #4f46e5;
            --bg-body: #0f172a;
            --bg-sidebar: #1e293b;
            --bg-card: rgba(30, 41, 59, 0.7);
            --border: rgba(148, 163, 184, 0.1);
            --text-main: #f8fafc;
            --text-sub: #94a3b8;
            --success: #10b981;
            --warning: #f59e0b;
            --danger: #ef4444;
            --radius: 12px;
            --shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
        }

        * { box-sizing: border-box; outline: none; -webkit-tap-highlight-color: transparent; }
        
        body {
            background-color: var(--bg-body);
            background-image: radial-gradient(at 0% 0%, rgba(99, 102, 241, 0.15) 0px, transparent 50%),
                              radial-gradient(at 100% 100%, rgba(16, 185, 129, 0.1) 0px, transparent 50%);
            background-attachment: fixed;
            color: var(--text-main);
            font-family: 'Inter', sans-serif;
            margin: 0;
            display: flex;
            height: 100vh;
            overflow: hidden;
        }

        .sidebar {
            width: 260px;
            background: var(--bg-sidebar);
            border-right: 1px solid var(--border);
            display: flex;
            flex-direction: column;
            padding: 20px;
            z-index: 10;
        }

        .logo { font-size: 24px; font-weight: 700; color: var(--text-main); margin-bottom: 40px; }
        .logo span { color: var(--primary); }

        .nav-item {
            display: flex; align-items: center; padding: 12px 16px;
            color: var(--text-sub); text-decoration: none; border-radius: var(--radius);
            margin-bottom: 8px; transition: all 0.2s; font-weight: 500; cursor: pointer;
        }
        .nav-item:hover { background: rgba(255,255,255,0.05); color: var(--text-main); }
        .nav-item.active { background: var(--primary); color: white; box-shadow: 0 4px 12px rgba(99, 102, 241, 0.3); }
        .nav-icon { margin-right: 12px; font-size: 18px; }

        .main { flex: 1; padding: 30px; overflow-y: auto; position: relative; }
        h1 { font-size: 24px; margin: 0 0 20px 0; font-weight: 600; }

        .card {
            background: var(--bg-card); backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px);
            border: 1px solid var(--border); border-radius: var(--radius); padding: 24px; margin-bottom: 24px;
            box-shadow: var(--shadow);
        }

        /* === 🔥 按钮样式修复：默认 auto 宽度，不占满 === */
        .btn {
            padding: 10px 20px;
            border: none; border-radius: 8px; font-weight: 500; cursor: pointer;
            transition: all 0.2s; display: inline-flex; align-items: center; justify-content: center;
            gap: 8px; color: white; font-size: 14px;
            width: auto; /* PC端默认不拉伸 */
            min-width: 100px;
        }
        .btn:active { transform: scale(0.98); }
        .btn-pri { background: var(--primary); }
        .btn-pri:hover { background: var(--primary-hover); }
        
        /* 修复 Success 按钮颜色 */
        .btn-succ { background: var(--success); color: #fff; } 
        .btn-succ:hover { filter: brightness(1.1); }
        
        .btn-dang { background: var(--danger); }
        .btn-warn { background: var(--warning); color: #000; }
        .btn-info { background: #3b82f6; }

        .input-group { margin-bottom: 15px; }
        label { display: block; margin-bottom: 8px; color: var(--text-sub); font-size: 13px; }
        input, select, textarea {
            width: 100%; background: rgba(0,0,0,0.2); border: 1px solid var(--border);
            border-radius: 8px; padding: 10px 12px; color: white; font-family: inherit; transition: 0.2s;
        }
        input:focus, select:focus, textarea:focus { border-color: var(--primary); }

        /* PC端按钮组：左对齐，紧凑 */
        .btn-row { display: flex; gap: 10px; justify-content: flex-start; margin-bottom: 10px; flex-wrap: wrap; }

        .log-box {
            background: #0b1120; border-radius: 8px; padding: 15px; height: 300px;
            overflow-y: auto; font-family: monospace; font-size: 12px; line-height: 1.6; border: 1px solid var(--border);
        }
        .log-box .err{color:#f55} .log-box .warn{color:#fb5} .log-box .suc{color:#5f7}

        .table-container { overflow-x: auto; }
        table { width: 100%; border-collapse: collapse; white-space: nowrap; }
        th { text-align: left; color: var(--text-sub); padding: 12px; border-bottom: 1px solid var(--border); font-size: 13px; }
        td { padding: 12px; border-bottom: 1px solid var(--border); color: var(--text-main); font-size: 14px; }
        
        .tag { padding: 4px 8px; border-radius: 6px; font-size: 11px; font-weight: 600; }
        .tag-push { background: rgba(16, 185, 129, 0.2); color: #34d399; }
        .tag-ren { background: rgba(59, 130, 246, 0.2); color: #60a5fa; }

        .filter-bar { display: flex; gap: 15px; background: rgba(0,0,0,0.2); padding: 15px; border-radius: 8px; align-items: flex-end; margin-bottom: 20px; }
        .filter-item { flex: 1; }
        .filter-item select { margin-bottom: 0; }

        #lock { position: fixed; inset: 0; background: rgba(15, 23, 42, 0.95); z-index: 999; display: flex; align-items: center; justify-content: center; }
        .lock-box { background: var(--bg-sidebar); padding: 40px; border-radius: 16px; width: 100%; max-width: 360px; text-align: center; border: 1px solid var(--border); }
        .hidden { display: none !important; }

        /* === 📱 移动端适配 (App 风格) === */
        @media (max-width: 768px) {
            body { flex-direction: column; height: 100dvh; }
            .sidebar {
                position: fixed; bottom: 0; left: 0; width: 100%; height: 60px;
                flex-direction: row; padding: 0; background: rgba(30, 41, 59, 0.9);
                backdrop-filter: blur(10px); border-top: 1px solid var(--border); border-right: none;
                justify-content: space-around; align-items: center;
            }
            .logo { display: none; }
            .nav-item { flex-direction: column; gap: 4px; padding: 6px; margin: 0; font-size: 10px; background: none !important; color: var(--text-sub); }
            .nav-item.active { color: var(--primary); background: none; box-shadow: none; }
            .nav-icon { margin: 0; font-size: 20px; }
            .main { padding: 15px; padding-bottom: 80px; }
            
            /* 手机端按钮：强制全宽 */
            .btn { width: 100%; margin-right: 0; margin-bottom: 10px; }
            .btn-row { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; } /* 手机上两列布局 */
            
            .filter-bar { flex-direction: column; gap: 10px; }
        }
    </style>
</head>
<body>
    <div id="lock">
        <div class="lock-box">
            <div style="font-size:40px;margin-bottom:20px">🔐</div>
            <h2 style="margin-bottom:20px">系统锁定</h2>
            <input type="password" id="pass" placeholder="输入访问密码" style="text-align:center;font-size:16px;margin-bottom:20px">
            <button class="btn btn-pri" style="width:100%" onclick="login()">解锁进入</button>
            <div id="msg" style="color:var(--danger);margin-top:15px;font-size:14px"></div>
        </div>
    </div>

    <div class="sidebar">
        <div class="logo">⚡ Madou<span>Pro</span></div>
        <a class="nav-item active" onclick="show('scraper')"><span class="nav-icon">🕷️</span> 采集</a>
        <a class="nav-item" onclick="show('renamer')"><span class="nav-icon">📂</span> 整理</a>
        <a class="nav-item" onclick="show('database')"><span class="nav-icon">💾</span> 资源库</a>
        <a class="nav-item" onclick="show('settings')"><span class="nav-icon">⚙️</span> 设置</a>
    </div>

    <div class="main">
        <div id="scraper" class="page">
            <div class="card">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:20px">
                    <h1>资源采集</h1>
                    <div style="font-size:14px;color:var(--text-sub)">今日采集: <span id="stat-scr" style="color:var(--primary);font-weight:bold;font-size:18px">0</span></div>
                </div>
                
                <div class="input-group" style="display:flex;align-items:center;gap:10px;background:rgba(255,255,255,0.05);padding:10px;border-radius:8px;margin-bottom:20px">
                    <input type="checkbox" id="auto-dl" style="width:20px;height:20px;margin:0">
                    <label for="auto-dl" style="margin:0;cursor:pointer">启用自动推送 (采集成功后直接发往 115)</label>
                </div>

                <div class="btn-row">
                    <button class="btn btn-succ" onclick="api('start',{type:'inc', autoDownload: getDlState()})">▶ 增量采集</button>
                    <button class="btn btn-info" onclick="api('start',{type:'full', autoDownload: getDlState()})">♻️ 全量采集</button>
                    <button class="btn btn-dang" onclick="api('stop')">⏹ 停止</button>
                </div>
            </div>

            <div class="card" style="padding:0;overflow:hidden">
                <div style="padding:15px;border-bottom:1px solid var(--border);font-weight:600">📡 实时终端日志</div>
                <div id="log-scr" class="log-box" style="border:none;border-radius:0"></div>
            </div>
        </div>

        <div id="renamer" class="page hidden">
            <div class="card">
                <h1>115 整理助手</h1>
                <div class="input-group">
                    <label>扫描页数 (0 代表全部)</label>
                    <input type="number" id="r-pages" value="0" placeholder="默认扫描全部">
                </div>
                <div class="input-group" style="display:flex;align-items:center;gap:10px;margin-bottom:20px">
                    <input type="checkbox" id="r-force" style="width:20px;margin:0">
                    <label for="r-force" style="margin:0">强制模式 (重新检查已整理项目)</label>
                </div>
                
                <div class="btn-row">
                    <button class="btn btn-pri" style="flex:1" onclick="startRenamer()">🚀 开始整理</button>
                    <button class="btn btn-dang" onclick="api('stop')">⏹ 停止</button>
                </div>

                <div style="margin-top:20px;display:flex;justify-content:space-around;text-align:center;background:rgba(0,0,0,0.2);padding:15px;border-radius:8px">
                    <div><div style="font-size:12px;color:var(--text-sub)">成功</div><div id="stat-suc" style="color:var(--success);font-size:20px;font-weight:bold">0</div></div>
                    <div><div style="font-size:12px;color:var(--text-sub)">失败</div><div id="stat-fail" style="color:var(--danger);font-size:20px;font-weight:bold">0</div></div>
                    <div><div style="font-size:12px;color:var(--text-sub)">跳过</div><div id="stat-skip" style="color:var(--text-sub);font-size:20px;font-weight:bold">0</div></div>
                </div>
            </div>
            <div class="card" style="padding:0;overflow:hidden">
                <div style="padding:15px;border-bottom:1px solid var(--border);font-weight:600">🛠️ 整理日志</div>
                <div id="log-ren" class="log-box" style="border:none;border-radius:0"></div>
            </div>
        </div>

        <div id="database" class="page hidden">
            <h1>资源数据库</h1>
            
            <div class="filter-bar">
                <div class="filter-item">
                    <label>推送状态</label>
                    <select id="filter-push" onchange="loadDb(1)">
                        <option value="">全部</option>
                        <option value="1">✅ 已推送</option>
                        <option value="0">⏳ 未推送</option>
                    </select>
                </div>
                <div class="filter-item">
                    <label>整理状态</label>
                    <select id="filter-ren" onchange="loadDb(1)">
                        <option value="">全部</option>
                        <option value="1">✨ 已整理</option>
                        <option value="0">📝 未整理</option>
                    </select>
                </div>
            </div>

            <div class="card" style="padding:0;overflow:hidden">
                <div style="padding:15px;border-bottom:1px solid var(--border);display:flex;justify-content:space-between;align-items:center;background:rgba(0,0,0,0.1)">
                    <div class="btn-row" style="margin-bottom:0">
                        <button class="btn btn-info" style="padding:6px 12px;font-size:12px;min-width:auto" onclick="pushSelected()">📤 推送选中</button>
                        <button class="btn btn-warn" style="padding:6px 12px;font-size:12px;min-width:auto" onclick="window.open(url('/export?type=all'))">📥 导出CSV</button>
                    </div>
                    <div id="total-count" style="font-size:12px;color:var(--text-sub)">Loading...</div>
                </div>
                
                <div class="table-container">
                    <table id="db-tbl">
                        <thead>
                            <tr>
                                <th style="width:40px"><input type="checkbox" onclick="toggleAll(this)"></th>
                                <th style="width:60px">ID</th>
                                <th>标题</th>
                                <th>磁力链</th>
                                <th style="width:140px">时间</th>
                            </tr>
                        </thead>
                        <tbody></tbody>
                    </table>
                </div>

                <div style="padding:15px;display:flex;justify-content:center;gap:20px;align-items:center;border-top:1px solid var(--border)">
                    <button class="btn btn-pri" style="min-width:auto" onclick="loadDb(dbPage-1)">上一页</button>
                    <span id="page-info" style="color:var(--text-sub)">1</span>
                    <button class="btn btn-pri" style="min-width:auto" onclick="loadDb(dbPage+1)">下一页</button>
                </div>
            </div>
        </div>

        <div id="settings" class="page hidden">
            <h1>系统设置</h1>
            
            <div class="card" style="display:flex;flex-direction:column;align-items:center;justify-content:center;padding:40px">
                <div style="font-size:48px;margin-bottom:20px">📱</div>
                <button class="btn btn-pri" style="font-size:16px;padding:12px 30px" onclick="showQr()">扫码登录 115</button>
                <p style="color:var(--text-sub);margin-top:10px;font-size:13px">使用 115 App 扫码，Cookie 将自动更新</p>
            </div>

            <div class="card" style="border-left: 4px solid var(--success)">
                <h3>☁️ 在线升级</h3>
                <div style="display:flex;justify-content:space-between;align-items:center;margin-top:15px">
                    <div>
                        <div style="font-size:13px;color:var(--text-sub)">当前版本</div>
                        <div id="cur-ver" style="font-size:24px;font-weight:bold;color:var(--text-main)">V13.5.1</div>
                    </div>
                    <button class="btn btn-succ" onclick="runOnlineUpdate()">检查更新</button>
                </div>
            </div>

            <div class="card">
                <h3>网络配置</h3>
                <div class="input-group">
                    <label>HTTP 代理 (例如: http://192.168.1.5:7890)</label>
                    <input id="cfg-proxy" placeholder="留空则直连">
                </div>
                <div class="input-group">
                    <label>115 Cookie (手动填入)</label>
                    <textarea id="cfg-cookie" rows="4" placeholder="UID=...; CID=...; SEID=..."></textarea>
                </div>
                <button class="btn btn-pri" style="width:100%" onclick="saveCfg()">💾 保存配置</button>
            </div>
        </div>
    </div>

    <div id="modal" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,0.8);z-index:1000;justify-content:center;align-items:center;backdrop-filter:blur(5px)">
        <div class="card" style="width:300px;text-align:center;background:var(--bg-sidebar)">
            <h3 style="margin-bottom:20px">请使用 115 App 扫码</h3>
            <div id="qr-img" style="background:white;padding:10px;border-radius:8px;display:inline-block"></div>
            <div id="qr-txt" style="margin:20px 0;color:var(--warning)">正在加载二维码...</div>
            <button class="btn btn-dang" onclick="document.getElementById('modal').style.display='none'">关闭</button>
        </div>
    </div>

    <script src="js/app.js"></script>
    <script>
        // JS 逻辑
        async function loadDb(p) {
            if(p < 1) return;
            dbPage = p;
            document.getElementById('page-info').innerText = p;
            const pushVal = document.getElementById('filter-push').value;
            const renVal = document.getElementById('filter-ren').value;
            
            const res = await request(`data?page=${p}&pushed=${pushVal}&renamed=${renVal}`);
            const tbody = document.querySelector('#db-tbl tbody');
            tbody.innerHTML = '';
            
            if(res.data) {
                document.getElementById('total-count').innerText = "总计: " + (res.total || 0);
                res.data.forEach(r => {
                    const time = new Date(r.created_at).toLocaleDateString();
                    let tags = "";
                    if (r.is_pushed) tags += `<span class="tag tag-push">已推</span> `;
                    if (r.is_renamed) tags += `<span class="tag tag-ren">已整</span>`;
                    const chkValue = `${r.id}|${r.magnets}`;
                    const magnetShort = r.magnets ? r.magnets.substring(0, 15) + '...' : '无';
                    tbody.innerHTML += `
                        <tr>
                            <td><input type="checkbox" class="tbl-chk row-chk" value="${chkValue}"></td>
                            <td><span style="opacity:0.5">#</span>${r.id}</td>
                            <td>
                                <div style="font-weight:500;margin-bottom:4px">${r.title}</div>
                                <div>${tags}</div>
                            </td>
                            <td style="font-family:monospace;font-size:12px;color:var(--text-sub)">${magnetShort}</td>
                            <td style="font-size:12px;color:var(--text-sub)">${time}</td>
                        </tr>`;
                });
            }
        }
    </script>
</body>
</html>
EOF

echo "📦 升级依赖..."
npm install --registry=https://registry.npmmirror.com

echo "🔄 重启应用..."
kill 1

echo "✅ V13.5.1 UI 修复完成！"
