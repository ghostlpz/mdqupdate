#!/bin/bash
# VERSION = 13.16.2

echo "🚀 [Update] 开始执行在线更新 v13.16.2 ..."

cd /app

# 1. 更新版本号
sed -i "s/global.CURRENT_VERSION = '.*';/global.CURRENT_VERSION = '13.16.2';/" app.js
if [ -f "package.json" ]; then
    sed -i 's/"version": ".*"/"version": "13.16.2"/' package.json
fi

# 2. 修改采集器页数限制 (使用 sed 精准替换)

# MadouQu: 全量 500->10000, 增量 5->50
sed -i 's/const maxPage = limit > 1000 ? 500 : 5;/const maxPage = limit > 1000 ? 10000 : 50;/' modules/scraper.js

# xChina: 全量 5000->10000 (增量原本就是50，无需变动)
sed -i "s/const limitPages = mode === 'full' ? 5000 : 50;/const limitPages = mode === 'full' ? 10000 : 50;/" modules/scraper_xchina.js


# 3. 升级 ResourceMgr (支持筛选逻辑)
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

    // 🔥 升级：支持多维筛选
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
            
            // 2. 标签筛选 (模糊匹配)
            if (filters.actor) {
                conditions.push("actor LIKE ?");
                values.push(`%${filters.actor}%`);
            }
            if (filters.category) {
                conditions.push("category LIKE ?");
                values.push(`%${filters.category}%`);
            }
            // 3. 关键词搜索 (标题或番号或演员)
            if (filters.keyword) {
                conditions.push("(title LIKE ? OR code LIKE ? OR actor LIKE ?)");
                values.push(`%${filters.keyword}%`, `%${filters.keyword}%`, `%${filters.keyword}%`);
            }

            let whereClause = "";
            if (conditions.length > 0) whereClause = " WHERE " + conditions.join(" AND ");

            // 查总数
            const countSql = `SELECT COUNT(*) as total FROM resources${whereClause}`;
            const [countRows] = await pool.query(countSql, values);
            const total = countRows[0].total;

            // 查数据
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


# 4. 升级 API 路由 (放行新参数)
# 使用 sed 替换 /data 接口定义，增加 keyword, actor, category 参数解析
sed -i "s|const filters = { pushed: req.query.pushed || '', renamed: req.query.renamed || '' };|const filters = { pushed: req.query.pushed || '', renamed: req.query.renamed || '', actor: req.query.actor || '', category: req.query.category || '', keyword: req.query.keyword || '' };|" routes/api.js


# 5. 升级前端 HTML (添加筛选栏)
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

        /* 🔥 筛选工具栏样式 */
        .filter-section { background: rgba(0,0,0,0.2); border-radius: 8px; padding: 15px; margin-bottom: 15px; border: 1px solid var(--border); }
        .filter-row { display: flex; gap: 10px; margin-bottom: 10px; align-items: center; flex-wrap: wrap; }
        .filter-row:last-child { margin-bottom: 0; }
        .filter-input { flex: 1; min-width: 140px; background: rgba(0,0,0,0.3); border: 1px solid var(--border); color: #fff; padding: 8px; border-radius: 6px; font-size: 13px; }
        .filter-select { background: rgba(0,0,0,0.3); border: 1px solid var(--border); color: #fff; padding: 8px; border-radius: 6px; font-size: 13px; min-width: 100px; }
        .filter-label { font-size: 12px; color: var(--text-sub); margin-right: 5px; }

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
                        <input id="filter-keyword" class="filter-input" placeholder="🔍 搜标题/番号" onkeypress="if(event.key==='Enter') loadDb(1)">
                        <input id="filter-actor" class="filter-input" placeholder="👤 搜演员" onkeypress="if(event.key==='Enter') loadDb(1)">
                        <input id="filter-cat" class="filter-input" placeholder="🏷️ 搜厂牌/分类" onkeypress="if(event.key==='Enter') loadDb(1)">
                        <button class="btn btn-pri" onclick="loadDb(1)">查询</button>
                    </div>
                    <div class="filter-row" style="justify-content: flex-start; gap: 20px;">
                        <div style="display:flex;align-items:center;">
                            <span class="filter-label">推送状态:</span>
                            <select id="filter-pushed" class="filter-select" onchange="loadDb(1)">
                                <option value="">全部</option>
                                <option value="1">✅ 已推送</option>
                                <option value="0">⬜ 未推送</option>
                            </select>
                        </div>
                        <div style="display:flex;align-items:center;">
                            <span class="filter-label">刮削状态:</span>
                            <select id="filter-renamed" class="filter-select" onchange="loadDb(1)">
                                <option value="">全部</option>
                                <option value="1">✅ 已整理</option>
                                <option value="0">⬜ 未整理</option>
                            </select>
                        </div>
                        <div style="flex:1; text-align:right;">
                            <button class="btn btn-sm btn-outline-secondary" onclick="resetFilters()" style="font-size:12px;padding:4px 8px;">🔄 重置条件</button>
                        </div>
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

# 6. 升级前端 JS (适配筛选逻辑)
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

// ✅ 渲染分类的核心函数 (UI Bug 修复点)
// 生成 HTML 时，给 label 添加 .cat-item 类，并绑定 onchange 事件来实现蓝色选中效果
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
    } else {
        area.classList.add('hidden'); 
    }
}

function toggleAllCats() {
    const chks = document.querySelectorAll('.cat-chk');
    if(chks.length > 0) {
        const targetState = !chks[0].checked;
        chks.forEach(c => {
            c.checked = targetState;
            c.dispatchEvent(new Event('change')); // 触发视觉更新
        });
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

// 🔥 新增：重置筛选条件
function resetFilters() {
    document.getElementById('filter-keyword').value = '';
    document.getElementById('filter-actor').value = '';
    document.getElementById('filter-cat').value = '';
    document.getElementById('filter-pushed').value = '';
    document.getElementById('filter-renamed').value = '';
    loadDb(1);
}

// 🔥 升级：loadDb 支持多维筛选参数
async function loadDb(p) {
    if(p < 1) return;
    dbPage = p;
    document.getElementById('page-info').innerText = p;
    const totalCountEl = document.getElementById('total-count');
    totalCountEl.innerText = "Loading...";
    
    // 获取筛选参数
    const kw = document.getElementById('filter-keyword').value;
    const actor = document.getElementById('filter-actor').value;
    const cat = document.getElementById('filter-cat').value;
    const pushed = document.getElementById('filter-pushed').value;
    const renamed = document.getElementById('filter-renamed').value;
    
    // 构建查询字符串
    const params = new URLSearchParams({ 
        page: p, 
        keyword: kw, actor: actor, category: cat, 
        pushed: pushed, renamed: renamed 
    });

    try {
        const res = await request(`data?${params.toString()}`);
        const tbody = document.querySelector('#db-tbl tbody');
        tbody.innerHTML = '';
        if(res.data) {
            totalCountEl.innerText = "总计: " + (res.total || 0);
            res.data.forEach(r => {
                const chkValue = `${r.id}|${r.magnets || ''}`;
                
                const imgHtml = r.image_url 
                    ? `<img src="${r.image_url}" class="cover-img" loading="lazy" onclick="window.open('${r.link}')" style="cursor:pointer">` 
                    : `<div class="cover-img" style="display:flex;align-items:center;justify-content:center;color:#555;font-size:10px">无封面</div>`;
                
                let statusTags = "";
                if (r.is_pushed) statusTags += `<span class="tag" style="color:#34d399;background:rgba(16,185,129,0.1)">已推</span>`;
                if (r.is_renamed) statusTags += `<span class="tag" style="color:#60a5fa;background:rgba(59,130,246,0.1)">已整</span>`;
                
                // 标签增加点击筛选功能
                let metaTags = "";
                if (r.actor) metaTags += `<span class="tag tag-actor" onclick="document.getElementById('filter-actor').value='${r.actor}';loadDb(1)" title="筛选此演员">👤 ${r.actor}</span>`;
                if (r.category) metaTags += `<span class="tag tag-cat" onclick="document.getElementById('filter-cat').value='${r.category}';loadDb(1)" title="筛选此分类">🏷️ ${r.category}</span>`;
                
                let cleanMagnet = r.magnets || '';
                let magnetLabel = '🔗';
                if(cleanMagnet.includes('m3u8')) magnetLabel = '📺';
                else if(cleanMagnet.includes('pikpak')) magnetLabel = '📺';
                
                if (cleanMagnet.includes('&')) cleanMagnet = cleanMagnet.split('&')[0];
                const magnetDisplay = cleanMagnet 
                    ? `<div class="magnet-link" onclick="navigator.clipboard.writeText('${cleanMagnet}');alert('链接已复制')">${magnetLabel} ${cleanMagnet.substring(0, 20)}...</div>` 
                    : '';
                
                tbody.innerHTML += `<tr><td><input type="checkbox" class="row-chk" value="${chkValue}" style="width:16px;height:16px;"></td><td>${imgHtml}</td><td><div style="font-weight:500;margin-bottom:4px;max-width:300px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis" title="${r.title}">${r.title}</div><div style="font-size:12px;color:var(--text-sub);font-family:monospace">${r.code || '无番号'}</div>${magnetDisplay}</td><td>${metaTags}</td><td>${statusTags}</td></tr>`;
            });
        } else { totalCountEl.innerText = "加载失败"; }
    } catch(e) { totalCountEl.innerText = "网络错误"; }
}
EOF

echo "✅ 在线更新脚本 v13.16.2 已部署，系统将自动重启..."
