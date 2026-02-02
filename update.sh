#!/bin/bash
# VERSION = 13.11.3

# ---------------------------------------------------------
# Madou-Omni 紧急修复补丁
# 版本: V13.11.3
# 修复: 1. 修复 saveCfg 缺少 JSON.stringify 导致的保存失败
#       2. 优化 loadDb 错误处理，防止资源库卡死
# ---------------------------------------------------------

echo "🚀 [Update] 开始执行紧急修复 (V13.11.3)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.11.3"/' package.json

# 2. 覆盖 public/js/app.js (修复核心 Bug)
echo "📝 [1/1] 修复前端逻辑..."
cat > public/js/app.js << 'EOF'
let dbPage = 1;
let qrTimer = null;

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
    } catch (e) { 
        console.error("API请求失败:", endpoint, e); 
        return { success: false, msg: e.message }; 
    }
}

async function login() {
    const p = document.getElementById('pass').value;
    const res = await fetch('/api/login', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({password: p}) });
    const data = await res.json();
    if (data.success) { localStorage.setItem('token', p); document.getElementById('lock').classList.add('hidden'); } else { alert("密码错误"); }
}

window.onload = async () => {
    const res = await request('check-auth');
    if (res.authenticated) document.getElementById('lock').classList.add('hidden');
    document.getElementById('pass').addEventListener('keypress', e => { if(e.key === 'Enter') login(); });
    
    // 初始加载配置
    if(document.getElementById('cfg-target-cid')) {
        const status = await request('status');
        if(status.config) {
            document.getElementById('cfg-target-cid').value = status.config.targetCid || '';
        }
    }
};

function show(id) {
    document.querySelectorAll('.page').forEach(e => e.classList.add('hidden'));
    document.getElementById(id).classList.remove('hidden');
    document.querySelectorAll('.nav-item').forEach(e => e.classList.remove('active'));
    if(event && event.target) {
       const target = event.target.closest('.nav-item');
       if(target) target.classList.add('active');
    }
    if(id === 'database') loadDb(1);
    if(id === 'settings' || id === 'organizer') {
        setTimeout(async () => {
            const r = await request('status');
            if(r.config) {
                if(document.getElementById('cfg-proxy')) document.getElementById('cfg-proxy').value = r.config.proxy || '';
                if(document.getElementById('cfg-cookie')) document.getElementById('cfg-cookie').value = r.config.cookie115 || '';
                if(document.getElementById('cfg-flare')) document.getElementById('cfg-flare').value = r.config.flaresolverrUrl || '';
                if(document.getElementById('cfg-target-cid')) document.getElementById('cfg-target-cid').value = r.config.targetCid || '';
            }
            if(r.version && document.getElementById('cur-ver')) {
                document.getElementById('cur-ver').innerText = "V" + r.version;
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
    const targetUrl = document.getElementById('scr-target-url') ? document.getElementById('scr-target-url').value : '';
    const dl = getDlState();
    api('start', { type: type, source: src, autoDownload: dl, targetUrl: targetUrl });
}

async function startRenamer() { const p = document.getElementById('r-pages').value; const f = document.getElementById('r-force').checked; api('renamer/start', { pages: p, force: f }); }

async function runOnlineUpdate() {
    const btn = event.target;
    const oldTxt = btn.innerText;
    btn.innerText = "⏳ 检查中...";
    btn.disabled = true;
    try {
        const res = await request('system/online-update', { method: 'POST' });
        if(res.success) {
            alert("🚀 " + res.msg);
            setTimeout(() => location.reload(), 15000);
        } else {
            alert("❌ " + res.msg);
        }
    } catch(e) { alert("请求失败"); }
    btn.innerText = oldTxt;
    btn.disabled = false;
}

// 🔥 修复：增加 JSON.stringify
async function saveCfg() {
    const proxy = document.getElementById('cfg-proxy') ? document.getElementById('cfg-proxy').value : undefined;
    const cookie115 = document.getElementById('cfg-cookie') ? document.getElementById('cfg-cookie').value : undefined;
    const flaresolverrUrl = document.getElementById('cfg-flare') ? document.getElementById('cfg-flare').value : undefined;
    const targetCid = document.getElementById('cfg-target-cid') ? document.getElementById('cfg-target-cid').value : undefined;
    
    const body = {};
    if(proxy !== undefined) body.proxy = proxy;
    if(cookie115 !== undefined) body.cookie115 = cookie115;
    if(flaresolverrUrl !== undefined) body.flaresolverrUrl = flaresolverrUrl;
    if(targetCid !== undefined) body.targetCid = targetCid;

    // 关键修复点：JSON.stringify(body)
    await request('config', { method: 'POST', body: JSON.stringify(body) });
    alert('✅ 配置已保存');
}

function toggleAll(source) { const checkboxes = document.querySelectorAll('.row-chk'); checkboxes.forEach(cb => cb.checked = source.checked); }

async function pushSelected(organize = false) {
    const checkboxes = document.querySelectorAll('.row-chk:checked');
    if (checkboxes.length === 0) { alert("请先勾选需要推送的资源！"); return; }
    
    // 兼容新旧逻辑，尝试获取 value
    const magnets = Array.from(checkboxes).map(cb => {
        const val = cb.value;
        // 如果是 id|magnet 格式，直接返回；如果是纯ID，这里可能无法工作，需要注意 loadDb 的实现
        return val; 
    });
    
    const btn = event.target; const oldText = btn.innerText; btn.innerText = "处理中..."; btn.disabled = true;
    try { 
        const res = await request('push', { method: 'POST', body: JSON.stringify({ magnets, organize }) }); 
        if (res.success) { 
            alert(`✅ ${res.msg} (成功: ${res.count})`); 
            loadDb(dbPage); 
        } else { 
            alert(`❌ 失败: ${res.msg}`); 
        } 
    } catch(e) { alert("网络请求失败"); }
    btn.innerText = oldText; btn.disabled = false;
}

async function deleteSelected() {
    const checkboxes = document.querySelectorAll('.row-chk:checked');
    if (checkboxes.length === 0) { alert("请先勾选!"); return; }
    if(!confirm(`确定要删除选中的 ${checkboxes.length} 条记录吗？`)) return;

    // 提取 ID (兼容 id|magnet 格式)
    const ids = Array.from(checkboxes).map(cb => {
        return cb.value.includes('|') ? cb.value.split('|')[0] : cb.value;
    });
    
    try { 
        const res = await request('delete', { method: 'POST', body: JSON.stringify({ ids }) }); 
        if (res.success) { 
            alert(`✅ 成功删除 ${res.count} 条记录`); 
            loadDb(dbPage); 
        } else { 
            alert(`❌ 失败: ${res.msg}`); 
        } 
    } catch(e) { alert("网络请求失败"); }
}

async function loadDb(p) {
    if(p < 1) return;
    dbPage = p;
    document.getElementById('page-info').innerText = p;
    const totalCountEl = document.getElementById('total-count');
    totalCountEl.innerText = "Loading...";
    
    try {
        const res = await request(`data?page=${p}`);
        const tbody = document.querySelector('#db-tbl tbody');
        tbody.innerHTML = '';
        
        if(res.data) {
            totalCountEl.innerText = "总计: " + (res.total || 0);
            res.data.forEach(r => {
                const chkValue = `${r.id}|${r.magnets || ''}`;
                const imgHtml = r.image_url ? 
                    `<img src="${r.image_url}" class="cover-img" loading="lazy" onclick="window.open('${r.link}')" style="cursor:pointer">` : 
                    `<div class="cover-img" style="display:flex;align-items:center;justify-content:center;color:#555;font-size:10px">无封面</div>`;
                
                let statusTags = "";
                if (r.is_pushed) statusTags += `<span class="tag" style="color:#34d399;background:rgba(16,185,129,0.1)">已推</span>`;
                if (r.is_renamed) statusTags += `<span class="tag" style="color:#60a5fa;background:rgba(59,130,246,0.1)">已整</span>`;

                let metaTags = "";
                if (r.actor) metaTags += `<span class="tag tag-actor">👤 ${r.actor}</span>`;
                if (r.category) metaTags += `<span class="tag tag-cat">🏷️ ${r.category}</span>`;

                let cleanMagnet = r.magnets || '';
                if (cleanMagnet.includes('&')) cleanMagnet = cleanMagnet.split('&')[0];
                const magnetDisplay = cleanMagnet ? `<div class="magnet-link" onclick="navigator.clipboard.writeText('${cleanMagnet}');alert('磁力已复制')">🔗 ${cleanMagnet.substring(0, 20)}...</div>` : '';

                tbody.innerHTML += `
                    <tr>
                        <td><input type="checkbox" class="row-chk" value="${chkValue}"></td>
                        <td>${imgHtml}</td>
                        <td>
                            <div style="font-weight:500;margin-bottom:4px;max-width:300px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${r.title}</div>
                            <div style="font-size:12px;color:var(--text-sub);font-family:monospace">${r.code || '无番号'}</div>
                            ${magnetDisplay}
                        </td>
                        <td>${metaTags}</td>
                        <td>${statusTags}</td>
                    </tr>`;
            });
        } else {
            totalCountEl.innerText = "加载失败";
        }
    } catch(e) {
        totalCountEl.innerText = "网络错误";
        console.error(e);
    }
}

// 恢复日志轮询
let lastLogTimeScr = "";
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
    
    if(document.getElementById('stat-scr')) {
        document.getElementById('stat-scr').innerText = res.state.totalScraped || 0;
    }
}, 2000);

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

# 3. 重启应用
echo "🔄 重启应用以生效..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] 修复补丁 V13.11.3 已应用，请刷新浏览器 (Ctrl+F5) 并重新保存配置。"
