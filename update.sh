#!/bin/bash
# VERSION = 13.16.5

echo "🚀 [Update] 开始执行 v13.16.5 全量修复与优化 ..."

cd /app

# 1. 更新版本号
sed -i "s/global.CURRENT_VERSION = '.*';/global.CURRENT_VERSION = '13.16.5';/" app.js
if [ -f "package.json" ]; then
    sed -i 's/"version": ".*"/"version": "13.16.5"/' package.json
fi

# 2. 修改采集页数 (确保生效)
# MadouQu: 500 -> 10000
sed -i 's/const maxPage = limit > 1000 ? 500 : 5;/const maxPage = limit > 1000 ? 10000 : 50;/' modules/scraper.js
# xChina: 5000 -> 10000
sed -i "s/const limitPages = mode === 'full' ? 5000 : 50;/const limitPages = mode === 'full' ? 10000 : 50;/" modules/scraper_xchina.js

# 3. 覆盖 index.html (UI 优化：搜索框并排)
cat > public/index.html << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>Madou Omni Pro</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
    <style>
        :root { --primary: #6366f1; --bg-body: #0f172a; --bg-card: rgba(30, 41, 59, 0.7); --text-main: #f8fafc; --text-sub: #94a3b8; --border: rgba(148, 163, 184, 0.1); }
        * { box-sizing: border-box; }
        body { background: var(--bg-body); color: var(--text-main); font-family: 'Inter', sans-serif; margin: 0; display: flex; height: 100vh; overflow: hidden; }
        
        .sidebar { width: 260px; background: #1e293b; padding: 20px; display: flex; flex-direction: column; border-right: 1px solid var(--border); flex-shrink: 0; z-index: 100; }
        .logo { font-size: 24px; font-weight: 700; margin-bottom: 40px; } .logo span { color: var(--primary); }
        .nav-item { padding: 12px; color: var(--text-sub); border-radius: 8px; margin-bottom: 8px; cursor: pointer; display: block; text-decoration: none; transition: 0.2s; }
        .nav-item:hover { background: rgba(255,255,255,0.05); color: #fff; }
        .nav-item.active { background: var(--primary); color: white; }
        
        .main { flex: 1; padding: 30px; overflow-y: auto; display: flex; flex-direction: column; position: relative; }
        .page { display: flex; flex-direction: column; height: 100%; }
        .hidden { display: none !important; }
        
        .card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 12px; padding: 24px; margin-bottom: 24px; flex-shrink: 0; }
        .btn { padding: 8px 16px; border-radius: 6px; border: none; cursor: pointer; color: white; font-size: 14px; transition: 0.2s; white-space: nowrap; }
        .btn:active { transform: scale(0.98); }
        .btn-pri { background: var(--primary); }
        .btn-succ { background: #10b981; } .btn-dang { background: #ef4444; } .btn-info { background: #3b82f6; } .btn-warn { background: #f59e0b; color: #000; }
        
        .input-group { margin-bottom: 15px; } label { display: block; margin-bottom: 5px; font-size: 13px; color: var(--text-sub); }
        .desc { font-size: 12px; color: #64748b; margin-top: 4px; }
        input, select, textarea { width: 100%; background: rgba(0,0,0,0.2); border: 1px solid var(--border); padding: 8px; color: white; border-radius: 6px; font-size: 14px; }
        
        .log-box { background: #0b1120; height: 300px; overflow-y: auto; padding: 15px; font-family: monospace; font-size: 12px; border-radius: 8px; }
        .log-entry.err { color: #f87171; } .log-entry.suc { color: #4ade80; } .log-entry.warn { color: #fbbf24; }
        
        .table-container { overflow-x: auto; flex: 1; min-height: 300px; border: 1px solid var(--border); border-radius: 8px; background: rgba(0,0,0,0.2); }
        table { width: 100%; border-collapse: collapse; font-size: 13px; min-width: 600px; }
        th, td { text-align: left; padding: 12px; border-bottom: 1px solid var(--border); vertical-align: middle; }
        th { color: var(--text-sub); background: #1e293b; position: sticky; top: 0; z-index: 10; }
        .cover-img { width: 80px; height: 50px; object-fit: cover; border-radius: 4px; background: #000; }
        
        .tag { padding: 2px 6px; border-radius: 4px; font-size: 10px; margin-right: 4px; display: inline-block; background: rgba(255,255,255,0.1); white-space: nowrap; cursor: pointer; transition: 0.2s; }
        .tag:hover { opacity: 0.8; }
        .tag-actor { color: #f472b6; background: rgba(244, 114, 182, 0.1); }
        .tag-cat { color: #fbbf24; background: rgba(251, 191, 36, 0.1); }
        
        .magnet-link { display: inline-block; max-width: 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #a5b4fc; background: rgba(99,102,241,0.1); padding: 2px 6px; border-radius: 4px; font-family: monospace; font-size: 11px; cursor: pointer; margin-top: 4px; }
        
        .progress-bar-container { height: 4px; background: rgba(255,255,255,0.1); width: 100%; margin-top: 5px; border-radius: 2px; overflow: hidden; }
        .progress-bar-fill { height: 100%; background: var(--primary); width: 0%; transition: width 0.3s; }
        .status-text { font-size: 11px; color: #94a3b8; display: flex; justify-content: space-between; margin-bottom: 2px; }
        
        #lock { position: fixed; inset: 0; background: rgba(15,23,42,0.95); z-index: 9999; display: flex; align-items: center; justify-content: center; }
        #modal { position:fixed; inset:0; background:rgba(0,0,0,0.8); z-index:2000; display:flex; justify-content:center; align-items:center; }

        .cat-item { display:flex; align-items:center; font-size:12px; cursor:pointer; padding:6px 10px; border-radius:6px; background:rgba(255,255,255,0.05); border:1px solid transparent; transition:0.2s; user-select:none; }
        .cat-item:hover { background:rgba(255,255,255,0.1); }
        .cat-item.active { background:rgba(59,130,246,0.2); border-color:#3b82f6; color:#93c5fd; }
        .cat-item input { margin-right:6px; width:auto; accent-color:#3b82f6; }

        /* 🔥 优化后的筛选栏样式 */
        .filter-section { background: rgba(0,0,0,0.2); border-radius: 8px; padding: 15px; margin-bottom: 15px; border: 1px solid var(--border); }
        .filter-row { display: flex; gap: 10px; margin-bottom: 10px; align-items: center; }
        .filter-row:last-child { margin-bottom: 0; }
        .filter-input { background: rgba(0,0,0,0.3); border: 1px solid var(--border); color: #fff; padding: 8px; border-radius: 6px; font-size: 13px; }
        .filter-select { background: rgba(0,0,0,0.3); border: 1px solid var(--border); color: #fff; padding: 8px; border-radius: 6px; font-size: 13px; min-width: 100px; }
        .filter-label { font-size: 12px; color: var(--text-sub); margin-right: 5px; white-space: nowrap; }

        @media (max-width: 768px) {
            body { flex-direction: column; }
            .sidebar { 
                width: 100%; height: 60px; padding: 0; flex-direction: row; 
                position: fixed; bottom: 0; left: 0; border-top: 1px solid var(--border); 
                border-right: none; justify-content: space-around; align-items: center; background: #1e293b;
            }
            .logo { display: none; }
            .nav-item { margin: 0; padding: 5px; flex: 1; text-align: center; border-radius: 0; display: flex; flex-direction: column; justify-content: center; align-items: center; font-size: 10px; background: transparent !important; height: 100%; }
            .nav-item span { font-size: 18px; margin-bottom: 2px; }
            .nav-item.active { color: var(--primary); }
            
            .main { padding: 15px; margin-bottom: 60px; }
            .card { padding: 15px; margin-bottom: 15px; }
            
            h2 { font-size: 18px; margin-top: 0; }
            .table-container { border: none; background: transparent; }
            .cover-img { width: 60px; height: 40px; }
            .btn-group-mobile { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
            .btn { width: 100%; padding: 10px; }
            #lock > div { width: 85%; }
            #cat-list { grid-template-columns: repeat(auto-fill, minmax(90px, 1fr)) !important; }
            
            .filter-row { flex-direction: column; align-items: stretch; gap: 8px; }
        }
    </style>
</head>
<body>
    <div id="lock">
        <div style="text-align:center; width: 300px;">
            <h2 style="margin-bottom:20px">🔐 系统锁定</h2>
            <input type="password" id="pass" placeholder="输入密码" style="text-align:center;margin-bottom:20px;padding:12px;">
            <button class="btn btn-pri" style="width:100%;padding:12px;" onclick="login()">解锁</button>
        </div>
    </div>

    <div class="sidebar">
        <div class="logo">⚡ Madou<span>Omni</span></div>
        <a class="nav-item active" onclick="show('scraper')"><span>🕷️</span> 采集任务</a>
        <a class="nav-item" onclick="show('organizer')"><span>📂</span> 刮削服务</a>
        <a class="nav-item" onclick="show('database')"><span>💾</span> 资源库</a>
        <a class="nav-item" onclick="show('settings')"><span>⚙️</span> 系统设置</a>
    </div>

    <div class="main">
        
        <div id="scraper" class="page">
            <div class="card">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:20px">
                    <h2>资源采集</h2>
                    <div>今日: <span id="stat-scr" style="color:var(--primary);font-weight:bold;font-size:18px">0</span></div>
                </div>
                
                <div class="input-group">
                    <label>数据源</label>
                    <select id="scr-source" onchange="renderCats()" style="padding:10px;">
                        <option value="madou">🍄 麻豆区 (MadouQu)</option>
                        <option value="xchina">📘 小黄书 (xChina)</option>
                    </select>
                </div>
                
                <div id="cat-area" class="hidden" style="margin-bottom:15px;">
                    <div style="display:flex;justify-content:space-between;margin-bottom:8px;">
                        <label style="margin:0">目标分类 (默认全选)</label>
                        <a onclick="toggleAllCats()" style="font-size:12px;color:var(--primary);cursor:pointer">反选/全选</a>
                    </div>
                    <div id="cat-list" style="display:grid;grid-template-columns:repeat(auto-fill, minmax(110px, 1fr));gap:8px;max-height:240px;overflow-y:auto;padding:2px;"></div>
                </div>

                <div class="input-group" style="display:flex;align-items:center;gap:10px;margin-bottom:20px;">
                    <input type="checkbox" id="auto-dl" style="width:20px;height:20px;"> 
                    <label style="margin:0;cursor:pointer;font-size:14px;" for="auto-dl">采集并自动推送到网盘</label>
                </div>
                
                <div class="btn-group-mobile" style="display:flex; gap:10px;">
                    <button class="btn btn-succ" onclick="startScrape('inc')">▶ 增量采集</button>
                    <button class="btn btn-info" onclick="startScrape('full')">♻️ 全量采集</button>
                    <button class="btn btn-dang" onclick="api('stop')">⏹ 停止</button>
                </div>
            </div>
            
            <div class="card" style="padding:0; flex:1; display:flex; flex-direction:column; min-height:0;">
                <div style="padding:15px;border-bottom:1px solid var(--border);font-weight:600;flex-shrink:0;">📡 运行日志</div>
                <div id="log-scr" class="log-box" style="flex:1;border-radius:0 0 12px 12px;"></div>
            </div>
        </div>
        
        <div id="organizer" class="page hidden">
            <div class="card">
                <h2>115 智能刮削</h2>
                <div style="color:var(--text-sub);padding:10px 0;line-height:1.6;">
                    此功能仅针对 115 磁力链任务。<br>
                    <span style="color:#fbbf24">⚠️ M3U8 任务</span> 会自动推送到你的 M3U8 Pro 服务。
                </div>
            </div>
        </div>
        
        <div id="database" class="page hidden">
            <h2>资源数据库</h2>
            <div class="card" style="padding:0; flex:1; display:flex; flex-direction:column; min-height:0;">
                
                <div class="filter-section">
                    <div class="filter-row">
                        <input id="filter-keyword" class="filter-input" style="flex:2" placeholder="🔍 标题 / 番号" onkeypress="if(event.key==='Enter') loadDb(1)">
                        <input id="filter-actor" class="filter-input" style="flex:1" placeholder="👤 演员" onkeypress="if(event.key==='Enter') loadDb(1)">
                        <input id="filter-cat" class="filter-input" style="flex:1" placeholder="🏷️ 厂牌" onkeypress="if(event.key==='Enter') loadDb(1)">
                        <button class="btn btn-pri" onclick="loadDb(1)">查询</button>
                    </div>
                    
                    <div class="filter-row" style="justify-content: space-between; margin-top: 10px;">
                        <div style="display:flex;gap:10px;align-items:center;flex:1">
                            <span class="filter-label">状态:</span>
                            <select id="filter-pushed" class="filter-select" onchange="loadDb(1)">
                                <option value="">推送 (全部)</option>
                                <option value="1">✅ 已推送</option>
                                <option value="0">⬜ 未推送</option>
                            </select>
                            <select id="filter-renamed" class="filter-select" onchange="loadDb(1)">
                                <option value="">刮削 (全部)</option>
                                <option value="1">✅ 已整理</option>
                                <option value="0">⬜ 未整理</option>
                            </select>
                        </div>
                        <button class="btn btn-sm btn-outline-secondary" onclick="resetFilters()" style="font-size:12px;">🔄 重置</button>
                    </div>
                </div>

                <div style="padding:0 15px 15px 15px; border-bottom:1px solid var(--border); display:flex; flex-wrap:wrap; gap:10px; justify-content:space-between; align-items:center; flex-shrink:0;">
                    <div class="btn-group-mobile" style="display:flex;gap:8px;flex-wrap:wrap;">
                        <button class="btn btn-info" onclick="pushSelected(false)">📤 仅推送</button>
                        <button class="btn btn-succ" onclick="pushSelected(true)">🚀 推送+刮削</button>
                        <button class="btn btn-warn" onclick="organizeSelected()">🛠️ 仅刮削(115)</button>
                        <button class="btn btn-dang" onclick="deleteSelected()">🗑️ 删除</button>
                    </div>
                    <div id="total-count" style="font-size:12px;color:var(--text-sub);margin-top:5px;">Loading...</div>
                </div>
                
                <div class="table-container">
                    <table id="db-tbl">
                        <thead>
                            <tr>
                                <th style="width:40px"><input type="checkbox" onclick="toggleAll(this)" style="width:16px;height:16px;"></th>
                                <th style="width:90px">封面</th>
                                <th>信息</th>
                                <th>标签</th>
                                <th>状态</th>
                            </tr>
                        </thead>
                        <tbody></tbody>
                    </table>
                </div>
                
                <div style="padding:15px;text-align:center;border-top:1px solid var(--border);flex-shrink:0;">
                    <button class="btn btn-pri" onclick="loadDb(dbPage-1)">上一页</button>
                    <span id="page-info" style="margin:0 15px;color:var(--text-sub)">1</span>
                    <button class="btn btn-pri" onclick="loadDb(dbPage+1)">下一页</button>
                </div>

                <div style="height:150px; background:#000; border-top:1px solid var(--border); display:flex; flex-direction:column; flex-shrink:0;">
                    <div style="padding:8px 15px; background:#111; border-bottom:1px solid #222;">
                        <div class="status-text"><span id="org-status-txt">⏳ 空闲</span><span id="org-status-count">0 / 0</span></div>
                        <div class="progress-bar-container"><div id="org-progress-fill" class="progress-bar-fill"></div></div>
                    </div>
                    <div id="log-org" class="log-box" style="flex:1; border:none; border-radius:0; height:auto; padding-top:5px;"></div>
                </div>
            </div>
        </div>
        
        <div id="settings" class="page hidden">
            <div class="card" style="overflow-y:auto; max-height:100%;">
                <h2>系统设置</h2>
                
                <div class="input-group">
                    <label>HTTP 代理</label>
                    <input id="cfg-proxy" placeholder="http://127.0.0.1:7890">
                </div>
                <div class="input-group">
                    <label>Flaresolverr 地址</label>
                    <input id="cfg-flare">
                </div>
                <div class="input-group">
                    <label>115 Cookie</label>
                    <textarea id="cfg-cookie" rows="3"></textarea>
                </div>
                <div class="input-group">
                    <label>目标目录 CID (115)</label>
                    <input id="cfg-target-cid" placeholder="例如: 28419384919384">
                </div>
                
                <hr style="border:0;border-top:1px solid var(--border);margin:20px 0">
                
                <h3>M3U8 Pro 服务配置</h3>
                <div class="desc" style="margin-bottom:10px">替换原 PikPak 功能，用于下载流媒体视频</div>
                
                <div class="input-group">
                    <label>API 地址</label>
                    <div style="display:flex;gap:10px">
                        <input id="cfg-m3u8-url" placeholder="http://ip:5003" style="flex:1">
                        <button class="btn btn-info" onclick="checkM3U8()" style="white-space:nowrap">🧪 测试</button>
                    </div>
                </div>
                <div class="input-group">
                    <label>Alist 上传路径</label>
                    <input id="cfg-m3u8-target" placeholder="/115/Downloads">
                </div>
                <div class="input-group">
                    <label>Alist 管理员密码</label>
                    <input id="cfg-m3u8-pwd" type="password">
                </div>
                
                <button class="btn btn-pri" style="margin-top:20px; width:auto; min-width: 150px; align-self: flex-start;" onclick="saveCfg()">💾 保存配置</button>
                
                <hr style="border:0;border-top:1px solid var(--border);margin:20px 0">
                <div style="display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:10px;">
                    <div>版本: <span id="cur-ver" style="color:var(--primary);font-weight:bold">Loading</span></div>
                    <div>
                        <button class="btn btn-succ" onclick="runOnlineUpdate()">检查更新</button>
                        <button class="btn btn-info" style="margin-left:5px" onclick="showQr()">扫码登录115</button>
                    </div>
                </div>
            </div>
        </div>
        
    </div>
    
    <div id="modal" class="hidden">
        <div class="card" style="width:300px;text-align:center;background:#1e293b;">
            <div id="qr-img" style="background:#fff;padding:10px;border-radius:8px;"></div>
            <div id="qr-txt" style="margin:20px 0;">请使用115 App扫码</div>
            <button class="btn btn-dang" onclick="document.getElementById('modal').classList.add('hidden')">关闭</button>
        </div>
    </div>

    <script src="js/app.js"></script>
</body>
</html>
EOF

# 4. 覆盖前端 JS (必须包含完整的日志轮询和扫码逻辑)
cat > public/js/app.js << 'EOF'
let dbPage = 1;
let qrTimer = null;

// ✅ xChina 分类数据
const XCHINA_CATS = [
    { name: "麻豆传媒", code: "series-5f904550b8fcc" }, { name: "独立创作者", code: "series-61bf6e439fed6" },
    { name: "糖心Vlog", code: "series-61014080dbfde" }, { name: "蜜桃传媒", code: "series-5fe8403919165" },
    { name: "星空传媒", code: "series-6054e93356ded" }, { name: "天美传媒", code: "series-60153c49058ce" },
    { name: "果冻传媒", code: "series-5fe840718d665" }, { name: "香蕉视频", code: "series-65e5f74e4605c" },
    { name: "精东影业", code: "series-60126bcfb97fa" }, { name: "杏吧原版", code: "series-6072997559b46" },
    { name: "爱豆传媒", code: "series-63d134c7a0a15" }, { name: "IBiZa Media", code: "series-64e9cce89da21" },
    { name: "性视界", code: "series-63490362dac45" }, { name: "ED Mosaic", code: "series-63732f5c3d36b" },
    { name: "大象传媒", code: "series-65bcaa9688514" }, { name: "扣扣传媒", code: "series-6230974ada989" },
    { name: "萝莉社", code: "series-6360ca9706ecb" }, { name: "SA国际传媒", code: "series-633ef3ef07d33" },
    { name: "其他中文AV", code: "series-63986aec205d8" }, { name: "抖阴", code: "series-6248705dab604" },
    { name: "葫芦影业", code: "series-6193d27975579" }, { name: "乌托邦", code: "series-637750ae0ee71" },
    { name: "爱神传媒", code: "series-6405b6842705b" }, { name: "乐播传媒", code: "series-60589daa8ff97" },
    { name: "91茄子", code: "series-639c8d983b7d5" }, { name: "草莓视频", code: "series-671ddc0b358ca" },
    { name: "JVID", code: "series-6964cfbda328b" }, { name: "YOYO", code: "series-64eda52c1c3fb" },
    { name: "51吃瓜", code: "series-671dd88d06dd3" }, { name: "哔哩传媒", code: "series-64458e7da05e6" },
    { name: "映秀传媒", code: "series-6560dc053c99f" }, { name: "西瓜影视", code: "series-648e1071386ef" },
    { name: "思春社", code: "series-64be8551bd0f1" }, { name: "有码AV", code: "series-6395aba3deb74" },
    { name: "无码AV", code: "series-6395ab7fee104" }, { name: "AV解说", code: "series-6608638e5fcf7" },
    { name: "PANS视频", code: "series-63963186ae145" }, { name: "其他模特私拍", code: "series-63963534a9e49" },
    { name: "热舞", code: "series-64edbeccedb2e" }, { name: "相约中国", code: "series-63ed0f22e9177" },
    { name: "果哥作品", code: "series-6396315ed2e49" }, { name: "SweatGirl", code: "series-68456564f2710" },
    { name: "风吟鸟唱作品", code: "series-6396319e6b823" }, { name: "色艺无间", code: "series-6754a97d2b343" },
    { name: "黄甫", code: "series-668c3b2de7f1c" }, { name: "日月俱乐部", code: "series-63ab1dd83a1c6" },
    { name: "探花现场", code: "series-63965bf7b7f51" }, { name: "主播现场", code: "series-63965bd5335fc" },
    { name: "华语电影", code: "series-6396492fdb1a0" }, { name: "日韩电影", code: "series-6396494584b57" },
    { name: "欧美电影", code: "series-63964959ddb1b" }, { name: "其他亚洲影片", code: "series-63963ea949a82" },
    { name: "门事件", code: "series-63963de3f2a0f" }, { name: "其他欧美影片", code: "series-6396404e6bdb5" },
    { name: "无关情色", code: "series-66643478ceedd" }
];

async function request(endpoint, options = {}) {
    const token = localStorage.getItem('token');
    const headers = { 'Content-Type': 'application/json' };
    if (token) headers['Authorization'] = token;
    try {
        const res = await fetch('/api/' + endpoint, { ...options, headers: { ...headers, ...options.headers } });
        if (res.status === 401) {
            localStorage.removeItem('token');
            document.getElementById('lock').classList.remove('hidden');
            throw new Error("未登录");
        }
        return await res.json();
    } catch (e) { console.error(e); return { success: false, msg: e.message }; }
}

async function login() {
    const p = document.getElementById('pass').value;
    const res = await fetch('/api/login', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({password: p}) });
    const data = await res.json();
    if (data.success) { localStorage.setItem('token', p); document.getElementById('lock').classList.add('hidden'); } else { alert("密码错误"); }
}

function renderCats() {
    const src = document.getElementById('scr-source').value;
    const area = document.getElementById('cat-area');
    const list = document.getElementById('cat-list');
    if (src === 'xchina') {
        area.classList.remove('hidden'); 
        if (list.innerHTML.trim() === '') {
            list.innerHTML = XCHINA_CATS.map(c => 
                `<label class="cat-item active" style="margin-bottom:0">
                    <input type="checkbox" class="cat-chk" value="${c.code}" checked onchange="this.parentElement.classList.toggle('active', this.checked)"> 
                    ${c.name}
                </label>`
            ).join('');
        }
    } else { area.classList.add('hidden'); }
}

function toggleAllCats() {
    const chks = document.querySelectorAll('.cat-chk');
    if(chks.length > 0) {
        const targetState = !chks[0].checked;
        chks.forEach(c => { c.checked = targetState; c.dispatchEvent(new Event('change')); });
    }
}

window.onload = async () => {
    const res = await request('check-auth');
    if (res.authenticated) document.getElementById('lock').classList.add('hidden');
    document.getElementById('pass').addEventListener('keypress', e => { if(e.key === 'Enter') login(); });
    
    const r = await request('status');
    if(r.config) {
        if(document.getElementById('cfg-proxy')) document.getElementById('cfg-proxy').value = r.config.proxy || '';
        if(document.getElementById('cfg-cookie')) document.getElementById('cfg-cookie').value = r.config.cookie115 || '';
        if(document.getElementById('cfg-flare')) document.getElementById('cfg-flare').value = r.config.flaresolverrUrl || '';
        if(document.getElementById('cfg-target-cid')) document.getElementById('cfg-target-cid').value = r.config.targetCid || '';
        if(document.getElementById('cfg-m3u8-url')) document.getElementById('cfg-m3u8-url').value = r.config.m3u8_url || '';
        if(document.getElementById('cfg-m3u8-target')) document.getElementById('cfg-m3u8-target').value = r.config.m3u8_target || '';
        if(document.getElementById('cfg-m3u8-pwd')) document.getElementById('cfg-m3u8-pwd').value = r.config.m3u8_pwd || '';
    }
    if(r.version && document.getElementById('cur-ver')) document.getElementById('cur-ver').innerText = "V" + r.version;
    renderCats();
};

function show(id) {
    document.querySelectorAll('.page').forEach(e => e.classList.add('hidden'));
    document.getElementById(id).classList.remove('hidden');
    document.querySelectorAll('.nav-item').forEach(e => e.classList.remove('active'));
    if(event && event.target) event.target.closest('.nav-item').classList.add('active');
    if(id === 'database') loadDb(1);
    if(id === 'settings') {
        setTimeout(async () => {
            const r = await request('status');
            if(r.config) {
                 if(document.getElementById('cfg-proxy')) document.getElementById('cfg-proxy').value = r.config.proxy || '';
                 if(document.getElementById('cfg-cookie')) document.getElementById('cfg-cookie').value = r.config.cookie115 || '';
                 if(document.getElementById('cfg-flare')) document.getElementById('cfg-flare').value = r.config.flaresolverrUrl || '';
                 if(document.getElementById('cfg-target-cid')) document.getElementById('cfg-target-cid').value = r.config.targetCid || '';
                 if(document.getElementById('cfg-m3u8-url')) document.getElementById('cfg-m3u8-url').value = r.config.m3u8_url || '';
                 if(document.getElementById('cfg-m3u8-target')) document.getElementById('cfg-m3u8-target').value = r.config.m3u8_target || '';
                 if(document.getElementById('cfg-m3u8-pwd')) document.getElementById('cfg-m3u8-pwd').value = r.config.m3u8_pwd || '';
            }
        }, 100);
    }
}

function getDlState() { return document.getElementById('auto-dl').checked; }

async function api(act, body={}) { 
    const res = await request(act, { method: 'POST', body: JSON.stringify(body) }); 
    if(!res.success && res.msg) alert("❌ " + res.msg);
    if(res.success && act === 'start') alert("✅ 任务已启动");
}

function startScrape(type) {
    const src = document.getElementById('scr-source').value;
    const dl = getDlState();
    let cats = [];
    if (src === 'xchina') {
        const chks = document.querySelectorAll('.cat-chk:checked');
        cats = Array.from(chks).map(c => c.value);
        if (cats.length === 0) {
            if(!confirm("⚠️ 您没有选择任何分类，这将采集全站所有视频 (非常慢)，确定吗？")) return;
        }
    }
    api('start', { type: type, source: src, autoDownload: dl, categories: cats });
}

async function runOnlineUpdate() {
    const btn = event.target; const oldTxt = btn.innerText; btn.innerText = "⏳ 检查中..."; btn.disabled = true;
    try {
        const res = await request('system/online-update', { method: 'POST' });
        if(res.success) { alert("🚀 " + res.msg); setTimeout(() => location.reload(), 15000); } 
        else { alert("❌ " + res.msg); }
    } catch(e) { alert("请求失败"); }
    btn.innerText = oldTxt; btn.disabled = false;
}

async function saveCfg() {
    const proxy = document.getElementById('cfg-proxy').value;
    const cookie115 = document.getElementById('cfg-cookie').value;
    const flaresolverrUrl = document.getElementById('cfg-flare').value;
    const targetCid = document.getElementById('cfg-target-cid').value;
    const m3u8_url = document.getElementById('cfg-m3u8-url').value;
    const m3u8_target = document.getElementById('cfg-m3u8-target').value;
    const m3u8_pwd = document.getElementById('cfg-m3u8-pwd').value;
    const body = { proxy, cookie115, flaresolverrUrl, targetCid, m3u8_url, m3u8_target, m3u8_pwd };
    await request('config', { method: 'POST', body: JSON.stringify(body) });
    alert('✅ 配置已保存');
}

async function checkM3U8() {
    const btn = event.target; const oldTxt = btn.innerText; btn.innerText = "⏳ 测试中..."; btn.disabled = true;
    await saveCfg();
    try {
        const res = await request('m3u8/check');
        if(res.success) alert(res.msg); else alert("❌ " + res.msg);
    } catch(e) { alert("请求失败"); }
    btn.innerText = oldTxt; btn.disabled = false;
}

function toggleAll(source) { const checkboxes = document.querySelectorAll('.row-chk'); checkboxes.forEach(cb => cb.checked = source.checked); }

async function pushSelected(organize = false) {
    const checkboxes = document.querySelectorAll('.row-chk:checked');
    if (checkboxes.length === 0) { alert("请先勾选!"); return; }
    const ids = Array.from(checkboxes).map(cb => cb.value.includes('|') ? cb.value.split('|')[0] : cb.value);
    const btn = event.target; const oldText = btn.innerText; btn.innerText = "处理中..."; btn.disabled = true;
    try { 
        const res = await request('push', { method: 'POST', body: JSON.stringify({ ids, organize }) }); 
        if (res.success) { alert(`✅ ${res.msg}`); loadDb(dbPage); } else { alert(`❌ 失败: ${res.msg}`); }
    } catch(e) { alert("网络请求失败"); }
    btn.innerText = oldText; btn.disabled = false;
}

async function organizeSelected() {
    const checkboxes = document.querySelectorAll('.row-chk:checked');
    if (checkboxes.length === 0) { alert("请先勾选!"); return; }
    const ids = Array.from(checkboxes).map(cb => cb.value.includes('|') ? cb.value.split('|')[0] : cb.value);
    const btn = event.target; btn.innerText = "请求中..."; btn.disabled = true;
    try { 
        const res = await request('organize', { method: 'POST', body: JSON.stringify({ ids }) }); 
        if (res.success) { alert(`✅ 已加入队列: ${res.count}`); } else { alert(`❌ ${res.msg}`); }
    } catch(e) { alert("网络错误"); }
    btn.innerText = "🛠️ 仅刮削"; btn.disabled = false;
}

async function deleteSelected() {
    const checkboxes = document.querySelectorAll('.row-chk:checked');
    if (checkboxes.length === 0) { alert("请先勾选!"); return; }
    if(!confirm(`确定要删除 ${checkboxes.length} 条记录吗？`)) return;
    const ids = Array.from(checkboxes).map(cb => cb.value.includes('|') ? cb.value.split('|')[0] : cb.value);
    try { await request('delete', { method: 'POST', body: JSON.stringify({ ids }) }); loadDb(dbPage); } catch(e) {}
}

function resetFilters() {
    document.getElementById('filter-keyword').value = '';
    document.getElementById('filter-actor').value = '';
    document.getElementById('filter-cat').value = '';
    document.getElementById('filter-pushed').value = '';
    document.getElementById('filter-renamed').value = '';
    loadDb(1);
}

async function loadDb(p) {
    if(p < 1) return;
    dbPage = p;
    document.getElementById('page-info').innerText = p;
    const totalCountEl = document.getElementById('total-count');
    totalCountEl.innerText = "Loading...";
    
    const kw = document.getElementById('filter-keyword').value;
    const actor = document.getElementById('filter-actor').value;
    const cat = document.getElementById('filter-cat').value;
    const pushed = document.getElementById('filter-pushed').value;
    const renamed = document.getElementById('filter-renamed').value;
    
    const params = new URLSearchParams({ page: p, keyword: kw, actor: actor, category: cat, pushed: pushed, renamed: renamed });

    try {
        const res = await request(`data?${params.toString()}`);
        const tbody = document.querySelector('#db-tbl tbody');
        tbody.innerHTML = '';
        if(res.data) {
            totalCountEl.innerText = "总计: " + (res.total || 0);
            res.data.forEach(r => {
                const chkValue = `${r.id}|${r.magnets || ''}`;
                const imgHtml = r.image_url ? `<img src="${r.image_url}" class="cover-img" loading="lazy" onclick="window.open('${r.link}')" style="cursor:pointer">` : `<div class="cover-img" style="display:flex;align-items:center;justify-content:center;color:#555;font-size:10px">无封面</div>`;
                
                let statusTags = "";
                if (r.is_pushed) statusTags += `<span class="tag" style="color:#34d399;background:rgba(16,185,129,0.1)">已推</span>`;
                if (r.is_renamed) statusTags += `<span class="tag" style="color:#60a5fa;background:rgba(59,130,246,0.1)">已整</span>`;
                
                let metaTags = "";
                if (r.actor) metaTags += `<span class="tag tag-actor" onclick="document.getElementById('filter-actor').value='${r.actor}';loadDb(1)" title="筛选此演员">👤 ${r.actor}</span>`;
                if (r.category) metaTags += `<span class="tag tag-cat" onclick="document.getElementById('filter-cat').value='${r.category}';loadDb(1)" title="筛选此分类">🏷️ ${r.category}</span>`;
                
                let cleanMagnet = r.magnets || '';
                let magnetLabel = '🔗';
                if(cleanMagnet.includes('m3u8')) magnetLabel = '📺'; else if(cleanMagnet.includes('pikpak')) magnetLabel = '📺';
                if (cleanMagnet.includes('&')) cleanMagnet = cleanMagnet.split('&')[0];
                const magnetDisplay = cleanMagnet ? `<div class="magnet-link" onclick="navigator.clipboard.writeText('${cleanMagnet}');alert('链接已复制')">${magnetLabel} ${cleanMagnet.substring(0, 20)}...</div>` : '';
                
                tbody.innerHTML += `<tr><td><input type="checkbox" class="row-chk" value="${chkValue}" style="width:16px;height:16px;"></td><td>${imgHtml}</td><td><div style="font-weight:500;margin-bottom:4px;max-width:300px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis" title="${r.title}">${r.title}</div><div style="font-size:12px;color:var(--text-sub);font-family:monospace">${r.code || '无番号'}</div>${magnetDisplay}</td><td>${metaTags}</td><td>${statusTags}</td></tr>`;
            });
        } else { totalCountEl.innerText = "加载失败"; }
    } catch(e) { totalCountEl.innerText = "网络错误"; }
}

// 🔥🔥 补回丢失的日志轮询逻辑 🔥🔥
let lastLogTimeScr = "";
let lastLogTimeOrg = "";
setInterval(async () => {
    if(!document.getElementById('lock').classList.contains('hidden')) return;
    const res = await request('status');
    if(!res.config) return;
    
    const renderLog = (elId, logs, lastTimeVar) => {
        const el = document.getElementById(elId);
        if(!el) return lastTimeVar;
        if(logs && logs.length > 0) {
            const latestLog = logs[logs.length-1];
            const latestSignature = latestLog.time + latestLog.msg;
            if (latestSignature !== lastTimeVar) {
                el.innerHTML = logs.map(l => `<div class="log-entry ${l.type==='error'?'err':l.type==='success'?'suc':l.type==='warn'?'warn':''}"><span class="time">[${l.time}]</span> ${l.msg}</div>`).join('');
                el.scrollTop = el.scrollHeight;
                return latestSignature;
            }
        }
        return lastTimeVar;
    };
    
    lastLogTimeScr = renderLog('log-scr', res.state.logs, lastLogTimeScr);
    lastLogTimeOrg = renderLog('log-org', res.organizerLogs, lastLogTimeOrg);
    
    if(res.organizerStats && document.getElementById('org-progress-fill')) {
        const s = res.organizerStats;
        const percent = s.total > 0 ? (s.processed / s.total) * 100 : 0;
        document.getElementById('org-progress-fill').style.width = percent + '%';
        let statusText = s.current || '空闲';
        if(s.total > 0) {
            if(s.processed < s.total) statusText = '🎬 处理中: ' + statusText;
            else statusText = '✅ 完成';
        }
        document.getElementById('org-status-txt').innerText = statusText;
        document.getElementById('org-status-count').innerText = `${s.processed} / ${s.total}`;
    }
    
    if(document.getElementById('stat-scr')) document.getElementById('stat-scr').innerText = res.state.totalScraped || 0;
}, 2000);

// 🔥🔥 补回丢失的扫码逻辑 🔥🔥
async function showQr() {
    const m = document.getElementById('modal'); m.classList.remove('hidden');
    const res = await request('115/qr'); if(!res.success) return;
    const { uid, time, sign, qr_url } = res.data;
    document.getElementById('qr-img').innerHTML = `<img src="${qr_url}" width="200">`;
    if(qrTimer) clearInterval(qrTimer);
    qrTimer = setInterval(async () => {
        const chk = await request(`115/check?uid=${uid}&time=${time}&sign=${sign}`);
        const txt = document.getElementById('qr-txt');
        if(chk.success) { txt.innerText = "✅ 成功! 刷新..."; txt.style.color = "#0f0"; clearInterval(qrTimer); setTimeout(() => { m.classList.add('hidden'); location.reload(); }, 1000); }
        else if (chk.status === 1) { txt.innerText = "📱 已扫码"; txt.style.color = "#fb5"; }
    }, 1500);
}
EOF

# 5. 覆盖 API 路由 (确保筛选参数透传)
cat > routes/api.js << 'EOF'
const express = require('express');
const axios = require('axios');
const router = express.Router();
const fs = require('fs');
const { exec } = require('child_process');
const { HttpsProxyAgent } = require('https-proxy-agent');
const { Parser } = require('json2csv');
const Scraper = require('../modules/scraper');
const ScraperXChina = require('../modules/scraper_xchina');
const Renamer = require('../modules/renamer');
const Organizer = require('../modules/organizer');
const Login115 = require('../modules/login_115');
const LoginM3U8 = require('../modules/login_m3u8'); 
const ResourceMgr = require('../modules/resource_mgr');
const AUTH_PASSWORD = process.env.AUTH_PASSWORD || "admin888";

function compareVersions(v1, v2) {
    if (!v1 || !v2) return 0;
    const p1 = v1.split('.').map(Number);
    const p2 = v2.split('.').map(Number);
    for (let i = 0; i < Math.max(p1.length, p2.length); i++) {
        const n1 = p1[i] || 0;
        const n2 = p2[i] || 0;
        if (n1 > n2) return 1;
        if (n1 < n2) return -1;
    }
    return 0;
}

router.get('/check-auth', (req, res) => { res.json({ authenticated: req.headers['authorization'] === AUTH_PASSWORD }); });
router.post('/login', (req, res) => { if (req.body.password === AUTH_PASSWORD) res.json({ success: true }); else res.json({ success: false, msg: "密码错误" }); });
router.post('/config', (req, res) => { global.CONFIG = { ...global.CONFIG, ...req.body }; global.saveConfig(); if(LoginM3U8.setConfig) LoginM3U8.setConfig(global.CONFIG); res.json({ success: true }); });

router.get('/status', (req, res) => {
    let logs = Scraper.getState().logs;
    let scraped = Scraper.getState().totalScraped;
    if (ScraperXChina.getState().isRunning) {
        logs = ScraperXChina.getState().logs;
        scraped = ScraperXChina.getState().totalScraped;
    }
    const orgState = Organizer.getState ? Organizer.getState() : { queue: 0, logs: [], stats: {} };
    res.json({ config: global.CONFIG, state: { isRunning: Scraper.getState().isRunning || ScraperXChina.getState().isRunning, logs, totalScraped: scraped }, renamerState: Renamer.getState(), organizerLogs: orgState.logs || [], organizerStats: orgState.stats || {}, version: global.CURRENT_VERSION });
});

router.get('/m3u8/check', async (req, res) => { try { LoginM3U8.setConfig(global.CONFIG); res.json(await LoginM3U8.checkConnection()); } catch (e) { res.json({ success: false, msg: e.message }); } });
router.get('/115/check', async (req, res) => { const { uid, time, sign } = req.query; const result = await Login115.checkStatus(uid, time, sign); if (result.success && result.cookie) { global.CONFIG.cookie115 = result.cookie; global.saveConfig(); res.json({ success: true, msg: "登录成功", cookie: result.cookie }); } else { res.json(result); } });
router.get('/115/qr', async (req, res) => { try { res.json({ success: true, data: await Login115.getQrCode() }); } catch (e) { res.json({ success: false, msg: e.message }); } });

router.post('/start', (req, res) => {
    const { type, source, categories } = req.body;
    if (Scraper.getState().isRunning || ScraperXChina.getState().isRunning) return res.json({ success: false, msg: "运行中" });
    if (source === 'xchina') { ScraperXChina.clearLogs(); ScraperXChina.start(type, false, categories); } 
    else { Scraper.clearLogs(); Scraper.start(type === 'full' ? 50000 : 100, type, false); }
    res.json({ success: true });
});
router.post('/stop', (req, res) => { Scraper.stop(); ScraperXChina.stop(); res.json({ success: true }); });

router.post('/push', async (req, res) => {
    const ids = req.body.ids || [];
    const shouldOrganize = req.body.organize === true;
    if (ids.length === 0) return res.json({ success: false, msg: "未选择" });
    let successCount = 0;
    try {
        const items = await ResourceMgr.getByIds(ids);
        for (const item of items) {
            let pushed = false;
            let magnet = item.magnets || '';
            if (magnet.startsWith('m3u8|') || magnet.startsWith('pikpak|')) {
                let targetUrl = item.link;
                if (!targetUrl && magnet.includes('|http')) targetUrl = magnet.split('|')[1];
                if (targetUrl && targetUrl.startsWith('http')) pushed = await LoginM3U8.addTask(targetUrl);
            } 
            else {
                if (global.CONFIG.cookie115) {
                    const dlResult = await Login115.addTask(magnet);
                    if (dlResult) {
                        pushed = true;
                        if (shouldOrganize) Organizer.addTask(item);
                    }
                }
            }
            if (pushed) { successCount++; await ResourceMgr.markAsPushed(item.id); }
            await new Promise(r => setTimeout(r, 500));
        }
        res.json({ success: true, count: successCount, msg: shouldOrganize ? "已推并加入刮削" : "已推送" });
    } catch (e) { res.json({ success: false, msg: e.message }); }
});

router.post('/organize', async (req, res) => {
    const ids = req.body.ids || [];
    const items = await ResourceMgr.getByIds(ids);
    let count = 0;
    items.forEach(item => {
        if (!item.magnets.startsWith('m3u8|')) { Organizer.addTask(item); count++; }
    });
    res.json({ success: true, count, msg: "已加入整理队列" });
});

router.post('/delete', async (req, res) => { const result = await ResourceMgr.deleteByIds(req.body.ids || []); res.json(result.success ? { success: true } : { success: false, msg: result.error }); });

// ✅ 核心修复：透传所有筛选参数
router.get('/data', async (req, res) => { 
    const filters = { 
        pushed: req.query.pushed || '', 
        renamed: req.query.renamed || '',
        actor: req.query.actor || '',
        category: req.query.category || '',
        keyword: req.query.keyword || ''
    }; 
    const result = await ResourceMgr.getList(parseInt(req.query.page) || 1, 100, filters); 
    res.json(result); 
});

router.get('/export', async (req, res) => { try { const type = req.query.type || 'all'; let data = []; if (type === 'all') data = await ResourceMgr.getAllForExport(); else { const result = await ResourceMgr.getList(parseInt(req.query.page) || 1, 100); data = result.data; } const parser = new Parser({ fields: ['id', 'code', 'title', 'magnets', 'created_at'] }); const csv = parser.parse(data); res.header('Content-Type', 'text/csv'); res.attachment(`madou_${Date.now()}.csv`); return res.send(csv); } catch (err) { res.status(500).send("Err: " + err.message); } });

router.post('/system/online-update', async (req, res) => {
    const updateUrl = global.UPDATE_URL || 'https://raw.githubusercontent.com/ghostlpz/mdqupdate/refs/heads/main/update.sh';
    const options = { timeout: 30000 };
    if (global.CONFIG && global.CONFIG.proxy && global.CONFIG.proxy.startsWith('http')) {
        const agent = new HttpsProxyAgent(global.CONFIG.proxy);
        options.httpAgent = agent;
        options.httpsAgent = agent;
    }
    const tempScriptPath = '/data/update_temp.sh';
    const finalScriptPath = '/data/update.sh';
    try {
        console.log(`⬇️ 正在检查更新: ${updateUrl}`);
        const response = await axios({ method: 'get', url: updateUrl, ...options, responseType: 'stream' });
        const writer = fs.createWriteStream(tempScriptPath);
        response.data.pipe(writer);
        writer.on('finish', () => {
            fs.readFile(tempScriptPath, 'utf8', (err, data) => {
                if (err) return res.json({ success: false, msg: "脚本读取失败" });
                const match = data.match(/#\s*VERSION\s*=\s*([0-9\.]+)/);
                const remoteVersion = match ? match[1] : null;
                const localVersion = global.CURRENT_VERSION || '0.0.0';
                if (!remoteVersion) return res.json({ success: false, msg: "无版本信息" });
                
                console.log(`🔍 版本对比: ${localVersion} -> ${remoteVersion}`);
                if (compareVersions(remoteVersion, localVersion) > 0) {
                    fs.renameSync(tempScriptPath, finalScriptPath);
                    res.json({ success: true, msg: `发现新版 V${remoteVersion}，正在升级...` });
                    setTimeout(() => {
                        exec(`chmod +x ${finalScriptPath} && sh ${finalScriptPath}`, (error, stdout, stderr) => {
                            if (error) console.error(`❌ 升级失败: ${error.message}`);
                            else {
                                console.log(`✅ 升级完成，正在重启...`);
                                try { fs.renameSync(finalScriptPath, finalScriptPath + '.bak'); } catch(e){}
                                process.exit(0);
                            }
                        });
                    }, 1000);
                } else {
                    fs.unlinkSync(tempScriptPath);
                    res.json({ success: false, msg: `已是最新 (V${localVersion})` });
                }
            });
        });
        writer.on('error', (err) => { res.json({ success: false, msg: "下载失败" }); });
    } catch (e) { res.json({ success: false, msg: "网络错误: " + e.message }); }
});

module.exports = router;
EOF

# 6. 覆盖 ResourceMgr (确保支持模糊查询)
cat > modules/resource_mgr.js << 'EOF'
const { pool } = require('./db');

function hexToBase32(hex) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
    let binary = '';
    for (let i = 0; i < hex.length; i++) {
        binary += parseInt(hex[i], 16).toString(2).padStart(4, '0');
    }
    let base32 = '';
    for (let i = 0; i < binary.length; i += 5) {
        const chunk = binary.substr(i, 5);
        const index = parseInt(chunk.padEnd(5, '0'), 2);
        base32 += alphabet[index];
    }
    return base32;
}

const ResourceMgr = {
    async save(data) {
        if (arguments.length > 1 && typeof arguments[0] === 'string') {
            data = {
                title: arguments[0],
                link: arguments[1],
                magnets: arguments[2],
                code: arguments[3] || null,
                image: arguments[4] || null
            };
        }
        try {
            const [result] = await pool.execute(
                'INSERT IGNORE INTO resources (title, link, magnets, code, image_url, actor, category) VALUES (?, ?, ?, ?, ?, ?, ?)',
                [
                    data.title, 
                    data.link, 
                    data.magnets, 
                    data.code || null, 
                    data.image || null, 
                    data.actor || null, 
                    data.category || null
                ]
            );
            return { success: true, newInsert: result.affectedRows > 0 };
        } catch (err) { 
            console.error(err);
            return { success: false, newInsert: false }; 
        }
    },
    
    async getByIds(ids) {
        if (!ids || ids.length === 0) return [];
        try {
            const placeholders = ids.map(() => '?').join(',');
            const [rows] = await pool.query(
                `SELECT * FROM resources WHERE id IN (${placeholders})`, 
                ids
            );
            return rows;
        } catch (err) { return []; }
    },

    async deleteByIds(ids) {
        if (!ids || ids.length === 0) return { success: false, count: 0 };
        try {
            const placeholders = ids.map(() => '?').join(',');
            const [result] = await pool.query(
                `DELETE FROM resources WHERE id IN (${placeholders})`, 
                ids
            );
            return { success: true, count: result.affectedRows };
        } catch (err) {
            return { success: false, error: err.message };
        }
    },

    async queryByHash(hash) {
        if (!hash) return null;
        try {
            const inputHash = hash.trim().toLowerCase();
            const [rows] = await pool.query(
                'SELECT * FROM resources WHERE magnets LIKE ? OR magnets LIKE ? LIMIT 1',
                [`%${inputHash}%`, `%${inputHash.toUpperCase()}%`]
            );
            return rows.length > 0 ? rows[0] : null;
        } catch (err) { return null; }
    },

    async markAsPushed(id) { try { await pool.query('UPDATE resources SET is_pushed = 1 WHERE id = ?', [id]); } catch (e) {} },
    async markAsPushedByLink(link) { try { await pool.query('UPDATE resources SET is_pushed = 1 WHERE link = ?', [link]); } catch (e) {} },
    async markAsRenamedByTitle(title) { try { await pool.query('UPDATE resources SET is_renamed = 1 WHERE title = ?', [title]); } catch (e) {} },

    // 🔥 升级：多维筛选逻辑
    async getList(page, limit, filters = {}) {
        try {
            const offset = (page - 1) * limit;
            let conditions = [];
            let values = [];

            // 1. 状态筛选
            if (filters.pushed === '1') conditions.push("is_pushed = 1");
            if (filters.pushed === '0') conditions.push("is_pushed = 0");
            if (filters.renamed === '1') conditions.push("is_renamed = 1");
            if (filters.renamed === '0') conditions.push("is_renamed = 0");
            
            // 2. 标签筛选
            if (filters.actor) {
                conditions.push("actor LIKE ?");
                values.push(`%${filters.actor}%`);
            }
            if (filters.category) {
                conditions.push("category LIKE ?");
                values.push(`%${filters.category}%`);
            }
            // 3. 关键词搜索
            if (filters.keyword) {
                conditions.push("(title LIKE ? OR code LIKE ? OR actor LIKE ?)");
                values.push(`%${filters.keyword}%`, `%${filters.keyword}%`, `%${filters.keyword}%`);
            }

            let whereClause = "";
            if (conditions.length > 0) whereClause = " WHERE " + conditions.join(" AND ");

            const countSql = `SELECT COUNT(*) as total FROM resources${whereClause}`;
            const [countRows] = await pool.query(countSql, values);
            const total = countRows[0].total;

            const dataSql = `SELECT * FROM resources${whereClause} ORDER BY created_at DESC LIMIT ? OFFSET ?`;
            values.push(parseInt(limit), parseInt(offset));

            const [rows] = await pool.query(dataSql, values);
            return { total, data: rows };
        } catch (err) {
            console.error(err);
            return { total: 0, data: [], error: err.message };
        }
    },

    async getAllForExport() {
        try {
            const [rows] = await pool.query(`SELECT * FROM resources ORDER BY created_at DESC`);
            return rows;
        } catch (err) { return []; }
    }
};
module.exports = ResourceMgr;
EOF

echo "✅ v13.16.5 全量修复完成！UI已优化，日志已恢复，筛选功能已就绪。正在重启..."
