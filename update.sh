#!/bin/bash
# VERSION = 13.16.2

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.16.2
# 核心: 移植 M3U8 Pro 的海报下载算法 (curl_cffi + 校验)
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署海报增强版 (V13.16.2)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.16.2"/' package.json

# 2. 升级 bridge.py (移植核心下载逻辑)
echo "📝 [1/2] 升级 Python 微服务 (集成 Chrome120 模拟)..."
cat > /app/python_service/bridge.py << 'EOF'
from flask import Flask, request, jsonify, Response
from curl_cffi.requests import AsyncSession
import asyncio
import logging
import base64
import hashlib
from pikpakapi import PikPakApi

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

# 全局 Session
SESSION = {
    "username": None, "password": None, "access_token": None, 
    "refresh_token": None, "user_id": None, "device_id": None, "proxy": None
}

# --- 移植自参考代码的图片校验逻辑 ---
def is_valid_image(content):
    try:
        if len(content) < 500: return False # 太小肯定不是高清海报
        header = content[:32]
        # 检查 JPG, PNG, WEBP, BMP 等常见头
        if header.startswith(b'\xff\xd8'): return True
        if header.startswith(b'\x89PNG'): return True
        if header.startswith(b'RIFF') and b'WEBP' in header: return True
        
        # 检查是否误下载了 HTML 报错页面
        try:
            if b'<html' in header.lower() or b'<!doctype' in header.lower():
                return False
        except: pass
        return False
    except: return False

# --- 原有的 PikPak Client 获取逻辑 ---
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

# --- 路由定义 ---

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

# 🔥 核心升级: 穿盾下载接口
@app.route('/download_image', methods=['POST'])
async def download_image():
    data = request.json
    url = data.get('url')
    referer = data.get('referer')
    proxy = data.get('proxy') # Node.js 传过来的代理
    
    if not url: return jsonify({'success': False, 'msg': 'No URL'}), 400

    headers = {
        "Referer": referer if referer else "https://xchina.co",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }
    
    # 构造 curl_cffi 的代理格式
    proxies = {"http": proxy, "https": proxy} if proxy else None

    try:
        # 使用 chrome120 指纹，这是过盾的关键
        async with AsyncSession(impersonate="chrome120", proxies=proxies) as s:
            logging.info(f"🖼️ Downloading: {url} (Ref: {headers['Referer']})")
            resp = await s.get(url, headers=headers, timeout=20)
            
            if resp.status_code == 200:
                content = resp.content
                # 校验文件有效性
                if is_valid_image(content):
                    # 返回二进制图片
                    return Response(content, mimetype="image/jpeg")
                else:
                    logging.error("❌ Downloaded content is not a valid image")
                    return jsonify({'success': False, 'msg': 'Invalid Image Content'}), 400
            else:
                return jsonify({'success': False, 'msg': f'HTTP {resp.status_code}'}), 400
                
    except Exception as e:
        logging.error(f"Download failed: {e}")
        return jsonify({'success': False, 'msg': str(e)}), 500

# 原有的 PikPak 操作接口保持不变
@app.route('/create_folder', methods=['POST'])
def create_folder():
    if not SESSION["access_token"]: return jsonify({'success': False, 'msg': 'No Token'}), 401
    data = request.json
    client = get_client()
    try:
        res = asyncio.run(client.create_folder(name=data.get('name'), parent_id=data.get('parent_id')))
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
    file_content = base64.b64decode(data.get('content'))
    
    client = get_client()
    try:
        sha1 = hashlib.sha1(file_content).hexdigest()
        size = len(file_content)
        create_url = f"https://{client.PIKPAK_API_HOST}/drive/v1/files"
        payload = {
            "kind": "drive#file", "name": name, "upload_type": "UPLOAD_TYPE_RESUMABLE",
            "hash": sha1, "size": size
        }
        if parent_id: payload["parent_id"] = parent_id
        
        create_res = asyncio.run(client._request_post(create_url, payload))
        upload_url = create_res.get("upload_url")
        file_id = create_res.get("file", {}).get("id")
        
        if upload_url:
            headers = {"Content-Type": ""}
            asyncio.run(client.httpx_client.put(upload_url, content=file_content, headers=headers))
            
        return jsonify({'success': True, 'file_id': file_id})
    except Exception as e:
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

# 3. 升级 Scraper (调用新的下载接口，并传递 Referer)
echo "📝 [2/2] 升级采集器 (传递 Referer)..."
# 注意：这里我们只更新 downloadImageViaCurl 函数和 processVideoTask
cat > modules/scraper_xchina.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const ResourceMgr = require('./resource_mgr');
const M3U8Client = require('./m3u8_client');
const { spawn } = require('child_process');

let pythonProcess = null;
const BRIDGE_URL = 'http://127.0.0.1:5005';

function ensureBridge() {
    if (pythonProcess && !pythonProcess.killed) return;
    console.log('🐍 [Bridge] 启动 curl_cffi 服务...');
    pythonProcess = spawn('python3', ['-u', '/app/python_service/bridge.py'], { stdio: 'inherit' });
    pythonProcess.on('error', (err) => console.error('🐍 [Bridge] 启动失败:', err));
}
ensureBridge();

// 🔥 核心调用: 发给 Python 的 /download_image
async function downloadImageViaCurl(url, referer) {
    if (!url) return null;
    try {
        // 请求 Python 服务，模拟 Chrome 下载
        const res = await axios.post(`${BRIDGE_URL}/download_image`, {
            url: url,
            referer: referer, // 必须传这个！
            proxy: global.CONFIG.proxy
        }, { responseType: 'arraybuffer', timeout: 30000 });
        
        return res.data;
    } catch (e) {
        console.error(`🖼️ 图片下载失败: ${e.message}`);
        return null;
    }
}

const CONCURRENCY_LIMIT = 3;
const MAX_RETRIES = 3;

// (省略 FULL_CATS 常量定义，保持不变，节省空间...)
const FULL_CATS = [
    { name: "麻豆传媒", code: "series-5f904550b8fcc" }, { name: "独立创作者", code: "series-61bf6e439fed6" }, { name: "糖心Vlog", code: "series-61014080dbfde" }, { name: "蜜桃传媒", code: "series-5fe8403919165" }, { name: "星空传媒", code: "series-6054e93356ded" }, { name: "天美传媒", code: "series-60153c49058ce" }, { name: "果冻传媒", code: "series-5fe840718d665" }, { name: "香蕉视频", code: "series-65e5f74e4605c" }, { name: "精东影业", code: "series-60126bcfb97fa" }, { name: "杏吧原版", code: "series-6072997559b46" }, { name: "爱豆传媒", code: "series-63d134c7a0a15" }, { name: "IBiZa Media", code: "series-64e9cce89da21" }, { name: "性视界", code: "series-63490362dac45" }, { name: "ED Mosaic", code: "series-63732f5c3d36b" }, { name: "大象传媒", code: "series-65bcaa9688514" }, { name: "扣扣传媒", code: "series-6230974ada989" }, { name: "萝莉社", code: "series-6360ca9706ecb" }, { name: "SA国际传媒", code: "series-633ef3ef07d33" }, { name: "其他中文AV", code: "series-63986aec205d8" }, { name: "抖阴", code: "series-6248705dab604" }, { name: "葫芦影业", code: "series-6193d27975579" }, { name: "乌托邦", code: "series-637750ae0ee71" }, { name: "爱神传媒", code: "series-6405b6842705b" }, { name: "乐播传媒", code: "series-60589daa8ff97" }, { name: "91茄子", code: "series-639c8d983b7d5" }, { name: "草莓视频", code: "series-671ddc0b358ca" }, { name: "JVID", code: "series-6964cfbda328b" }, { name: "YOYO", code: "series-64eda52c1c3fb" }, { name: "51吃瓜", code: "series-671dd88d06dd3" }, { name: "哔哩传媒", code: "series-64458e7da05e6" }, { name: "映秀传媒", code: "series-6560dc053c99f" }, { name: "西瓜影视", code: "series-648e1071386ef" }, { name: "思春社", code: "series-64be8551bd0f1" }, { name: "有码AV", code: "series-6395aba3deb74" }, { name: "无码AV", code: "series-6395ab7fee104" }, { name: "AV解说", code: "series-6608638e5fcf7" }, { name: "PANS视频", code: "series-63963186ae145" }, { name: "其他模特私拍", code: "series-63963534a9e49" }, { name: "热舞", code: "series-64edbeccedb2e" }, { name: "相约中国", code: "series-63ed0f22e9177" }, { name: "果哥作品", code: "series-6396315ed2e49" }, { name: "SweatGirl", code: "series-68456564f2710" }, { name: "风吟鸟唱作品", code: "series-6396319e6b823" }, { name: "色艺无间", code: "series-6754a97d2b343" }, { name: "黄甫", code: "series-668c3b2de7f1c" }, { name: "日月俱乐部", code: "series-63ab1dd83a1c6" }, { name: "探花现场", code: "series-63965bf7b7f51" }, { name: "主播现场", code: "series-63965bd5335fc" }, { name: "华语电影", code: "series-6396492fdb1a0" }, { name: "日韩电影", code: "series-6396494584b57" }, { name: "欧美电影", code: "series-63964959ddb1b" }, { name: "其他亚洲影片", code: "series-63963ea949a82" }, { name: "门事件", code: "series-63963de3f2a0f" }, { name: "其他欧美影片", code: "series-6396404e6bdb5" }, { name: "无关情色", code: "series-66643478ceedd" }
];

let STATE = { isRunning: false, stopSignal: false, logs: [], totalScraped: 0 };

function log(msg, type = 'info') {
    STATE.logs.push({ time: new Date().toLocaleTimeString(), msg, type });
    if (STATE.logs.length > 200) STATE.logs.shift();
    console.log(`[Scraper-xChina] ${msg}`);
}

function cleanMagnet(magnet) {
    if (!magnet) return '';
    const match = magnet.match(/magnet:\?xt=urn:btih:([a-zA-Z0-9]+)/i);
    if (match) return `magnet:?xt=urn:btih:${match[1]}`;
    return magnet.split('&')[0];
}

function getFlareUrl() {
    let url = global.CONFIG.flaresolverrUrl || 'http://flaresolverr:8191';
    if (url.endsWith('/')) url = url.slice(0, -1);
    if (!url.endsWith('/v1')) url += '/v1';
    return url;
}

async function processVideoTask(task, baseUrl, autoDownload) {
    const { link } = task; 
    
    // 1. 获取 HTML
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
    
    // 🔥 图片抓取
    let image = '';
    const regexPoster = /(?:poster|pic|thumb)\s*[:=]\s*['"]([^'"]+)['"]/i;
    const regexCss = /background-image\s*:\s*url\(['"]?([^'"\)]+)['"]?\)/i;
    
    if (htmlContent.match(regexPoster)) image = htmlContent.match(regexPoster)[1].replace(/\\\//g, '/');
    else if (htmlContent.match(regexCss)) image = htmlContent.match(regexCss)[1].replace(/\\\//g, '/');
    else image = $('.vjs-poster img').attr('src') || $('video').attr('poster');
    
    if (image && !image.startsWith('http')) image = baseUrl + image;

    const actor = $('.model-container .model-item').text().trim() || '未知演员';
    let category = '未分类';
    $('.text').each((i, el) => { if ($(el).find('.joiner').length > 0) category = $(el).find('a').last().text().trim(); });

    let code = '';
    const codeMatch = link.match(/id-([a-zA-Z0-9]+)/);
    if (codeMatch) code = codeMatch[1];

    let magnet = '';
    let isM3u8 = false;

    // A. 尝试获取磁力
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

    // B. M3U8 判定
    if (!magnet) {
        isM3u8 = true;
        log(`🔎 [${code}] 发现流媒体资源 (无磁力)`, 'info');
    }

    // 💾 入库逻辑
    if (magnet || isM3u8) {
        const storageValue = isM3u8 ? `m3u8|${link}` : magnet;
        const saveRes = await ResourceMgr.save({
            title, link, magnets: storageValue, code, image, actor, category
        });

        if (saveRes.success) {
            if (saveRes.newInsert) {
                STATE.totalScraped++;
                let extraMsg = "";
                
                // 🔥 投递与归档逻辑 (PikPak)
                if (isM3u8) {
                    const LoginPikPak = require('../modules/login_pikpak');
                    // 1. 建目录 (演员 - 标题)
                    const folderName = `${actor} - ${title}`.trim();
                    const folderId = await LoginPikPak.createFolder(folderName);
                    
                    if (folderId) {
                        // 2. 离线下载视频
                        const pushed = await LoginPikPak.addTask(link, folderId);
                        
                        // 3. 穿盾下载海报并上传 (🔥 这里使用了新移植的 downloadImageViaCurl)
                        if (image) {
                            const imgBuf = await downloadImageViaCurl(image, baseUrl); // 传入 baseUrl 作为 Referer
                            if (imgBuf) {
                                await LoginPikPak.uploadFile(imgBuf, 'poster.jpg', folderId);
                                log(`🖼️ [${code}] 海报上传成功`, 'info');
                            } else {
                                log(`⚠️ [${code}] 海报下载失败 (403/无效)`, 'warn');
                            }
                        }
                        
                        extraMsg = pushed ? " | 🚀 已推送+归档" : " | ⚠️ 推送失败";
                        if(pushed) await ResourceMgr.markAsPushedByLink(link);
                    } else {
                        extraMsg = " | ⚠️ 目录创建失败";
                    }
                } else {
                    extraMsg = " | 💾 磁力已存库";
                }

                log(`✅ [入库] ${code} | ${title.substring(0, 10)}...${extraMsg}`, 'success');
                return true;
            } else {
                log(`⏭️ [已存在] ${title.substring(0, 10)}...`, 'info');
                return true;
            }
        }
    }
    return false;
}

async function scrapeCategory(cat, baseUrl, limitPages, autoDownload) {
    let page = 1;
    log(`📂 正在采集: [${cat.name}]`, 'info');

    while (page <= limitPages && !STATE.stopSignal) {
        const listUrl = page === 1 
            ? `${baseUrl}/videos/${cat.code}.html` 
            : `${baseUrl}/videos/${cat.code}/${page}.html`;
            
        try {
            const flareApi = getFlareUrl();
            const payload = { cmd: 'request.get', url: listUrl, maxTimeout: 60000 };
            if (global.CONFIG.proxy) payload.proxy = { url: global.CONFIG.proxy };
            
            let res;
            try {
                res = await axios.post(flareApi, payload, { headers: { 'Content-Type': 'application/json' } });
            } catch(e) { throw new Error(`Req Err: ${e.message}`); }

            if (res.data.status !== 'ok') {
                 log(`⚠️ 访问列表页失败: ${res.data.message}`, 'error');
                 break;
            }

            const $ = cheerio.load(res.data.solution.response);
            const items = $('.item.video');
            if (items.length === 0) { log(`⚠️ 第 ${page} 页无内容`, 'warn'); break; }

            const tasks = [];
            items.each((i, el) => {
                const title = $(el).find('.text .title a').text().trim();
                let subLink = $(el).find('.text .title a').attr('href');
                if (title && subLink) {
                    if (!subLink.startsWith('http')) subLink = baseUrl + subLink;
                    tasks.push({ title, link: subLink });
                }
            });

            log(`📡 [${cat.name}] 第 ${page}/${limitPages} 页: ${tasks.length} 个视频`);

            for (let i = 0; i < tasks.length; i += CONCURRENCY_LIMIT) {
                if (STATE.stopSignal) break;
                const chunk = tasks.slice(i, i + CONCURRENCY_LIMIT);
                await Promise.all(chunk.map(async (task) => {
                    for(let k=0; k<MAX_RETRIES; k++){
                        try { return await processVideoTask(task, baseUrl, autoDownload); }
                        catch(e){ if(k===MAX_RETRIES-1) log(`❌ ${task.title.substring(0,10)} 失败: ${e.message}`, 'error'); }
                        await new Promise(r=>setTimeout(r, 1500));
                    }
                }));
                await new Promise(r => setTimeout(r, 500)); 
            }
            page++;
            await new Promise(r => setTimeout(r, 1500));

        } catch (pageErr) {
            log(`❌ 翻页失败: ${pageErr.message}`, 'error');
            break;
        }
    }
}

const ScraperXChina = {
    getState: () => STATE,
    stop: () => { STATE.stopSignal = true; log('🛑 停止中...', 'warn'); },
    clearLogs: () => { STATE.logs = []; },
    start: async (mode = 'inc', autoDownload = false, selectedCodes = []) => {
        if (STATE.isRunning) return;
        STATE.isRunning = true;
        STATE.stopSignal = false;
        STATE.totalScraped = 0;
        
        const limitPages = mode === 'full' ? 5000 : 50;
        const baseUrl = "https://xchina.co";
        ensureBridge();

        try {
            let targetCategories = FULL_CATS;
            if (selectedCodes && selectedCodes.length > 0) {
                targetCategories = FULL_CATS.filter(c => selectedCodes.includes(c.code));
            }
            for (let i = 0; i < targetCategories.length; i++) {
                if (STATE.stopSignal) break;
                await scrapeCategory(targetCategories[i], baseUrl, limitPages, autoDownload);
                if (i < targetCategories.length - 1) await new Promise(r => setTimeout(r, 5000));
            }
        } catch (err) { log(`🔥 全局异常: ${err.message}`, 'error'); }
        STATE.isRunning = false;
        log(`🏁 任务结束`, 'warn');
    },
    getCategories: () => FULL_CATS
};
module.exports = ScraperXChina;
EOF

# 4. 覆盖进容器 (针对已经救回来的 madou_omni_system)
echo "🔄 重启应用..."
pkill -f "node app.js" || echo "应用可能未运行。"
pkill -f "python3 -u /app/python_service/bridge.py" || true

echo "✅ [完成] V13.16.2 海报增强版部署完成！"
