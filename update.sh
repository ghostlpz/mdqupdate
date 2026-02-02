#!/bin/bash
# VERSION = 13.14.4

# ---------------------------------------------------------
# Madou-Omni 在线升级脚本
# 版本: V13.14.4
# 核心: 1. 新增 PikPak 驱动 (登录/任务/文件操作)
#       2. Scraper 集成 M3U8 提取 -> 自动推 PikPak
#       3. Organizer 支持双核 (115/PikPak) 自动切换
# ---------------------------------------------------------

echo "🚀 [Update] 开始部署 PikPak 双核驱动版 (V13.14.4)..."

# 1. 更新 package.json
sed -i 's/"version": ".*"/"version": "13.14.4"/' package.json

# 2. 新增模块: login_pikpak.js (PikPak 核心驱动)
echo "📝 [1/4] 部署 PikPak 驱动..."
cat > modules/login_pikpak.js << 'EOF'
const axios = require('axios');

// PikPak API 封装 (对齐 Login115 接口)
const LoginPikPak = {
    auth: {
        username: '',
        password: '',
        token: '',
        userId: '',
        deviceId: 'madou_omni_v1'
    },
    
    // 初始化配置
    setConfig(cfg) {
        // cfg.pikpak 格式建议: "username|password" 或 直接 "Bearer xxxx"
        if (!cfg || !cfg.pikpak) return;
        if (cfg.pikpak.startsWith('Bearer')) {
            this.auth.token = cfg.pikpak;
        } else if (cfg.pikpak.includes('|')) {
            const parts = cfg.pikpak.split('|');
            this.auth.username = parts[0].trim();
            this.auth.password = parts[1].trim();
        }
    },

    getHeaders() {
        return {
            'Content-Type': 'application/json',
            'X-Device-Id': this.auth.deviceId,
            'Authorization': this.auth.token
        };
    },

    // 登录获取 Token
    async login() {
        if (this.auth.token && !this.auth.password) return true; // 已有Token且无密码，直接用
        if (!this.auth.username || !this.auth.password) return false;

        try {
            const url = 'https://user.mypikpak.com/v1/auth/signin';
            const payload = {
                client_id: "YNxT9w7GMvwD3",
                username: this.auth.username,
                password: this.auth.password
            };
            const res = await axios.post(url, payload, { headers: { 'Content-Type': 'application/json' } });
            if (res.data && res.data.access_token) {
                this.auth.token = 'Bearer ' + res.data.access_token;
                this.auth.userId = res.data.sub;
                console.log('✅ PikPak 登录成功');
                return true;
            }
        } catch (e) {
            console.error('❌ PikPak 登录失败:', e.message);
        }
        return false;
    },

    // 添加离线任务 (对应 115 addTask)
    // 对于 M3U8，PikPak 支持直接通过 url 添加
    async addTask(url, parentId = '') {
        if (!this.auth.token) await this.login();
        try {
            const apiUrl = 'https://api-drive.mypikpak.com/drive/v1/files';
            const payload = {
                kind: "drive#file",
                folder_type: "DOWNLOAD",
                upload_type: "UPLOAD_TYPE_URL",
                url: url,
                parent_id: parentId
            };
            const res = await axios.post(apiUrl, payload, { headers: this.getHeaders() });
            return res.data && res.data.task; // 返回任务对象
        } catch (e) {
            console.error('PikPak AddTask Error:', e.message);
            return false;
        }
    },

    // 获取文件列表 (对应 115 getFileList)
    async getFileList(parentId = '') {
        if (!this.auth.token) await this.login();
        try {
            let url = `https://api-drive.mypikpak.com/drive/v1/files?filters={"trashed":{"eq":false}}&limit=100`;
            if (parentId) url += `&parent_id=${parentId}`;
            
            const res = await axios.get(url, { headers: this.getHeaders() });
            // 转换格式以匹配 115 的结构 (Organizer 需要)
            // 115: data: [ { fid, n, s, fcid(if folder) } ]
            // PikPak: files: [ { id, name, size, kind } ]
            if (res.data && res.data.files) {
                const list = res.data.files.map(f => ({
                    fid: f.id,
                    n: f.name,
                    s: parseInt(f.size || 0),
                    fcid: f.kind === 'drive#folder' ? f.id : undefined, // 文件夹标记
                    parent_id: f.parent_id
                }));
                return { data: list };
            }
        } catch (e) { console.error(e.message); }
        return { data: [] };
    },

    // 搜索文件 (对应 115 searchFile)
    async searchFile(keyword, parentId = '') {
        if (!this.auth.token) await this.login();
        try {
            // PikPak 搜索比较麻烦，通常用 list 过滤
            // 这里简化为：获取列表然后前端过滤 (因为通常是在特定文件夹内找)
            // 如果是全局搜，PikPak 没有直接且好用的全局搜索 API 暴露给普通用户
            // 我们假设是在整理流程中，通常是在 parentId 下找
            const list = await this.getFileList(parentId);
            const matches = list.data.filter(f => f.n.includes(keyword));
            return { data: matches };
        } catch (e) { return { data: [] }; }
    },

    // 重命名 (对应 115 rename)
    async rename(fileId, newName) {
        if (!this.auth.token) await this.login();
        try {
            const url = `https://api-drive.mypikpak.com/drive/v1/files/${fileId}`;
            const payload = { name: newName };
            const res = await axios.patch(url, payload, { headers: this.getHeaders() });
            return { success: !!res.data.id };
        } catch (e) { return { success: false, msg: e.message }; }
    },

    // 移动 (对应 115 move)
    async move(fileIds, targetCid) {
        if (!this.auth.token) await this.login();
        try {
            const url = 'https://api-drive.mypikpak.com/drive/v1/files/batch_move';
            const ids = fileIds.split(',');
            const payload = {
                ids: ids,
                to: { parent_id: targetCid }
            };
            const res = await axios.post(url, payload, { headers: this.getHeaders() });
            return true;
        } catch (e) { return false; }
    },

    // 删除 (对应 115 deleteFiles)
    async deleteFiles(fileIds) {
        if (!this.auth.token) await this.login();
        try {
            const url = 'https://api-drive.mypikpak.com/drive/v1/files/batch_trash';
            const ids = fileIds.split(',');
            const payload = { ids: ids };
            await axios.post(url, payload, { headers: this.getHeaders() });
            return true;
        } catch (e) { return false; }
    },

    // 查找任务/文件 (对应 115 getTaskByHash)
    // PikPak 的 m3u8 任务通常没有 hash，我们用 name 或 url 匹配
    // 返回结构尽量模拟 115
    async getTaskByHash(hashOrUrl, nameHint = '') {
        if (!this.auth.token) await this.login();
        try {
            // 1. 先去 upload/tasks 找正在进行的
            const taskUrl = 'https://api-drive.mypikpak.com/drive/v1/tasks?filters={"phase":{"eq":"PHASE_TYPE_RUNNING"}}';
            const res = await axios.get(taskUrl, { headers: this.getHeaders() });
            // ... 任务检查逻辑复杂，PikPak 秒传很快，通常直接去文件列表找即可
            
            // 2. 直接去文件列表找 (假设已完成)
            // 我们搜索名字包含 nameHint 的文件
            if (nameHint) {
                const searchRes = await this.searchFile(nameHint.substring(0, 10)); // 搜前几个字
                if (searchRes.data && searchRes.data.length > 0) {
                    const f = searchRes.data[0];
                    return {
                        status_code: 2, // 模拟 115 成功码
                        folder_cid: f.fcid ? f.fid : f.parent_id, // 如果找到的是文件夹，返回它；如果是视频，返回它爹
                        file_id: f.fid,
                        percent: 100
                    };
                }
            }
        } catch (e) {}
        return null;
    },

    // 上传文件 (对应 115 uploadFile)
    // PikPak 上传小文件流程: POST files (upload_type=RESUMABLE) -> 获取 upload_url -> PUT data
    async uploadFile(fileBuffer, fileName, parentId = '') {
        if (!this.auth.token) await this.login();
        try {
            // 1. 创建上传任务
            const createUrl = 'https://api-drive.mypikpak.com/drive/v1/files';
            const createPayload = {
                kind: "drive#file",
                name: fileName,
                parent_id: parentId,
                upload_type: "UPLOAD_TYPE_RESUMABLE"
            };
            const res1 = await axios.post(createUrl, createPayload, { headers: this.getHeaders() });
            const uploadUrl = res1.data.upload_url;
            const fileId = res1.data.file.id;

            // 2. 上传数据
            if (uploadUrl) {
                await axios.put(uploadUrl, fileBuffer, {
                    headers: { 'Content-Type': '' } // PikPak PUT 要求
                });
                return fileId;
            }
        } catch (e) { console.error('PP Upload Err:', e.message); }
        return null;
    }
};

// 启动时尝试加载配置
if(global.CONFIG && global.CONFIG.pikpak) LoginPikPak.setConfig(global.CONFIG);

module.exports = LoginPikPak;
EOF

# 3. 升级 Scraper (使用 LoginPikPak)
echo "📝 [2/4] 升级采集器 (支持推送到 PikPak)..."
# 注意：这里我们修改 scraper_xchina.js 引入 LoginPikPak 并调用
sed -i "s|const ResourceMgr = require('./resource_mgr');|const ResourceMgr = require('./resource_mgr');\nconst LoginPikPak = require('./login_pikpak');|" modules/scraper_xchina.js

# 使用 sed 插入逻辑太复杂，直接重写关键函数 processVideoTask
# 我们利用 cat 将 processVideoTask 函数完全覆盖，加入 M3U8 -> PikPak 逻辑
cat >> modules/scraper_xchina.js << 'EOF'

// 🔥 补丁: 覆盖 processVideoTask 函数以支持 PikPak
async function processVideoTask(task, baseUrl, autoDownload) {
    const { link } = task; 
    const $ = await requestViaFlare(link);
    
    let title = $('h1').text().trim() || task.title;
    let image = $('.vjs-poster img').attr('src') || $('video').attr('poster');
    if (image && !image.startsWith('http')) image = baseUrl + image;
    
    const actor = $('.model-container .model-item').text().trim() || '未知演员';
    
    let category = '';
    $('.text').each((i, el) => { if ($(el).find('.joiner').length > 0) category = $(el).find('a').last().text().trim(); });
    if (!category) category = '未分类';

    let code = '';
    const codeMatch = link.match(/id-([a-zA-Z0-9]+)/);
    if (codeMatch) code = codeMatch[1];

    let magnet = '';
    let driveType = '115'; // 默认 115

    // 1. 优先找磁力 (115)
    try {
        const downloadLinkEl = $('a[href*="/download/id-"]');
        if (downloadLinkEl.length > 0) {
            let downloadPageUrl = downloadLinkEl.attr('href');
            if (downloadPageUrl && !downloadPageUrl.startsWith('http')) downloadPageUrl = baseUrl + downloadPageUrl;
            const $down = await requestViaFlare(downloadPageUrl);
            const rawMagnet = $down('a.btn.magnet').attr('href');
            if (rawMagnet) magnet = cleanMagnet(rawMagnet);
        }
    } catch (e) {}

    // 2. 备用找 M3U8 (PikPak)
    if (!magnet) {
        const htmlContent = $.html();
        const regex = /src:\s*['"](https?:\/\/[^'"]+\.m3u8[^'"]*)['"]/;
        const match = htmlContent.match(regex);
        if (match && match[1]) {
            magnet = match[1];
            driveType = 'pikpak'; // 标记为 PikPak
            log(`🔎 [${code}] 启用 M3U8 (PikPak)`, 'info');
        }
    }

    if (magnet) {
        // 保存时带上 driveType (需要 ResourceMgr 支持或存在 magnets 字段里)
        // 这里我们将 driveType 拼接到 magnet 前面，用 | 分隔，ResourceMgr 会原样存入
        // 例如: "pikpak|https://....m3u8"
        const storageValue = driveType === 'pikpak' ? `pikpak|${magnet}` : magnet;

        const saveRes = await ResourceMgr.save({
            title, link, magnets: storageValue, code, image, actor, category
        });

        if (saveRes.success && saveRes.newInsert) {
            STATE.totalScraped++;
            let extraMsg = "";
            
            if (autoDownload) {
                if (driveType === 'pikpak') {
                    // 推送 PikPak
                    const pushed = await LoginPikPak.addTask(magnet);
                    extraMsg = pushed ? " | 📥 已推PikPak" : " | ⚠️ PikPak推送失败";
                    if(pushed) await ResourceMgr.markAsPushedByLink(link);
                } else {
                    // 推送 115
                    const pushed = await pushTo115(magnet);
                    extraMsg = pushed ? " | 📥 已推115" : " | ⚠️ 115推送失败";
                    if(pushed) await ResourceMgr.markAsPushedByLink(link);
                }
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

# 4. 升级 Organizer (双核支持)
echo "📝 [3/4] 升级整理核心 (双核驱动)..."
# 我们需要在 Organizer 里根据任务类型选择 Driver
cat > modules/organizer.js << 'EOF'
const axios = require('axios');
const cheerio = require('cheerio');
const Login115 = require('./login_115');
const LoginPikPak = require('./login_pikpak'); // 🔥 引入 PikPak
const ResourceMgr = require('./resource_mgr');

let TASKS = []; 
let IS_RUNNING = false;
let LOGS = [];
let STATS = { total: 0, processed: 0, success: 0, fail: 0, current: '' };

function log(msg, type = 'info') {
    const time = new Date().toLocaleTimeString();
    console.log(`[Organizer ${time}] ${msg}`);
    LOGS.push({ time, msg, type });
    if (LOGS.length > 200) LOGS.shift();
}

function getFlareUrl() {
    let url = global.CONFIG.flaresolverrUrl || 'http://flaresolverr:8191';
    if (url.endsWith('/')) url = url.slice(0, -1);
    if (!url.endsWith('/v1')) url += '/v1';
    return url;
}

async function fetchMetaViaFlare(url) {
    const flareApi = getFlareUrl();
    try {
        const payload = { cmd: 'request.get', url: url, maxTimeout: 60000 };
        if (global.CONFIG.proxy) payload.proxy = { url: global.CONFIG.proxy };
        const res = await axios.post(flareApi, payload, { headers: { 'Content-Type': 'application/json' } });
        if (res.data.status === 'ok') return cheerio.load(res.data.solution.response);
        throw new Error(`Flaresolverr: ${res.data.message}`);
    } catch (e) { throw new Error(`MetaReq Err: ${e.message}`); }
}

const Organizer = {
    getState: () => ({ queue: TASKS.length, isRunning: IS_RUNNING, logs: LOGS, stats: STATS }),

    addTask: (resource) => {
        if (resource.is_renamed) return;
        if (TASKS.length === 0 && !IS_RUNNING) STATS = { total: 0, processed: 0, success: 0, fail: 0, current: '' };
        if (!TASKS.find(t => t.id === resource.id)) {
            resource.retryCount = 0;
            // 🔥 识别驱动类型
            if (resource.magnets && resource.magnets.startsWith('pikpak|')) {
                resource.driveType = 'pikpak';
                resource.realMagnet = resource.magnets.replace('pikpak|', '');
            } else {
                resource.driveType = '115';
                resource.realMagnet = resource.magnets;
            }
            
            TASKS.push(resource);
            STATS.total++;
            log(`➕ 加入队列 [${resource.driveType}]: ${resource.title.substring(0, 15)}...`, 'info');
            Organizer.run();
        }
    },

    run: async () => {
        if (IS_RUNNING || TASKS.length === 0) return;
        IS_RUNNING = true;
        while (TASKS.length > 0) {
            const item = TASKS[0];
            STATS.current = `${item.title} (${item.driveType})`;
            try {
                const success = await Organizer.processItem(item);
                TASKS.shift(); 
                if (success) {
                    STATS.processed++; STATS.success++;
                    await ResourceMgr.markAsRenamedByTitle(item.title);
                } else { throw new Error("流程未完成"); }
            } catch (e) {
                TASKS.shift();
                item.retryCount = (item.retryCount || 0) + 1;
                STATS.processed++;
                if (item.retryCount < 5) {
                    log(`⚠️ 重试 (${item.retryCount}/5): ${e.message}`, 'warn');
                    STATS.fail++; TASKS.push(item); STATS.total++;
                } else {
                    log(`❌ 放弃: ${item.title}`, 'error'); STATS.fail++;
                }
            }
            await new Promise(r => setTimeout(r, 2000));
        }
        IS_RUNNING = false; STATS.current = '空闲'; log(`🏁 队列完毕`, 'success');
    },

    generateNfo: async (item, standardName) => {
        if (!item.link) return null;
        log(`🕷️ 抓取元数据...`);
        const $ = await fetchMetaViaFlare(item.link);
        const plot = $('.introduction').text().trim() || '无简介';
        const date = $('.date').first().text().replace('发行日期:', '').trim() || '';
        const studio = $('.studio').text().replace('片商:', '').trim() || '';
        const tags = []; $('.tag').each((i, el) => tags.push($(el).text().trim()));
        
        let xml = `<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>\n<movie>\n`;
        xml += `  <title>${item.title}</title>\n  <originaltitle>${item.code}</originaltitle>\n  <plot>${plot}</plot>\n  <releasedate>${date}</releasedate>\n  <studio>${studio}</studio>\n`;
        if (item.actor) xml += `  <actor>\n    <name>${item.actor}</name>\n    <type>Actor</type>\n  </actor>\n`;
        tags.forEach(tag => xml += `  <tag>${tag}</tag>\n`);
        xml += `  <thumb>poster.jpg</thumb>\n  <fanart>fanart.jpg</fanart>\n</movie>`;
        return Buffer.from(xml, 'utf-8');
    },

    processItem: async (item) => {
        // 🔥 选择驱动
        const Driver = item.driveType === 'pikpak' ? LoginPikPak : Login115;
        const targetCid = global.CONFIG.targetCid; // PikPak 也可以用这个配置项作为目标目录ID
        
        if (!targetCid) throw new Error("未配置目标目录ID");

        log(`▶️ 开始处理 [${item.driveType}]`);

        // 1. 定位 (115用Hash，PikPak用文件名搜索，因为M3U8没Hash)
        let folderCid = null;
        let retryCount = 0;
        
        while (retryCount < 5) {
            // PikPak 模式下，直接传名字去搜
            const query = item.driveType === 'pikpak' ? item.title : (item.realMagnet.match(/[a-fA-F0-9]{40}/) || [])[0];
            
            if (query) {
                const task = await Driver.getTaskByHash(query, item.title); // PikPak 驱动会利用第二个参数
                if (task && task.status_code === 2) {
                    folderCid = task.folder_cid || task.file_id;
                    log(`✅ 任务已就绪`);
                    break;
                }
            }
            retryCount++;
            await new Promise(r => setTimeout(r, 3000));
        }

        // 搜索保底
        if (!folderCid) {
            const cleanTitle = item.title.replace(/[【\[].*?[\]】]/g, '').substring(0, 6).trim();
            const searchRes = await Driver.searchFile(cleanTitle, 0); // 0 = 根目录
            if (searchRes.data && searchRes.data.length > 0) {
                // PikPak 返回的可能是文件也可能是文件夹
                // 如果是 M3U8 转存，通常是一个 .mp4 文件，而不是文件夹
                const hit = searchRes.data[0];
                folderCid = hit.fcid || hit.fid; // 如果是文件，CID就是它自己(逻辑上)
                log(`✅ 搜索命中: ${hit.n}`);
            }
        }

        if (!folderCid) throw new Error("无法定位资源");

        // 2. 构造名称
        let actor = item.actor;
        let title = item.title;
        if (!actor || actor === '未知演员') {
            const match = title.match(/^(.*?)\s*[（(](.*)[）)]$/);
            if (match) { title = match[1].trim(); actor = match[2].trim(); }
        }
        let standardName = `${actor && actor!=='未知演员' ? actor+' - ' : ''}${title}`.trim();
        standardName = standardName.replace(/[\\/:*?"<>|]/g, "").trim().substring(0, 200);

        // 3. 处理视频 (改名)
        // 注意: PikPak 的 "文件夹" 概念如果是单文件，逻辑需微调
        // 这里简单起见，假设 folderCid 是一个文件夹 (115) 或 视频文件本身 (PikPak M3U8)
        
        let workingDirId = folderCid;
        
        // 如果是 PikPak 且 folderCid 指向一个文件，我们需要创建一个文件夹把它放进去吗？
        // 为了保持一致性：是的。
        if (item.driveType === 'pikpak') {
             // 检查 folderCid 是不是文件
             // 这里简化逻辑：我们直接对 folderCid 改名
             const renRes = await Driver.rename(folderCid, standardName + ".mp4");
             if (!renRes.success) throw new Error("视频改名失败");
             
             // PikPak M3U8 下载往往是单文件，为了放 NFO/海报，我们需要建一个文件夹
             // 但 PikPak API 建文件夹较繁琐。
             // 策略变更：PikPak 模式下，海报和 NFO 直接传到和视频同级目录下，并以此命名。
             // 比如: /Downloads/大卫 - 标题.mp4, /Downloads/大卫 - 标题.nfo
             // 所以 workingDirId = 视频的父目录
             // 我们需要获取视频详情来知道父目录
             // ... 鉴于复杂度，这里暂时只改名。NFO/海报 尝试上传到 targetCid (目标归档目录)
             workingDirId = targetCid; 
        } else {
            // 115 逻辑 (文件夹改名)
            await Driver.rename(folderCid, standardName);
            // 视频改名
            const files = (await Driver.getFileList(folderCid)).data;
            const mainVideo = files.find(f => !f.fcid); // 简单找第一个文件
            if (mainVideo) await Driver.rename(mainVideo.fid, standardName + ".mp4");
        }

        // 4. 海报 & NFO (通用)
        try {
            if (item.image_url) {
                const imgRes = await axios.get(item.image_url, { responseType: 'arraybuffer' });
                await Driver.uploadFile(imgRes.data, "poster.jpg", workingDirId);
                await Driver.uploadFile(imgRes.data, "thumb.jpg", workingDirId); 
            }
            const nfoBuf = await Organizer.generateNfo(item, standardName);
            if (nfoBuf) await Driver.uploadFile(nfoBuf, `${standardName}.nfo`, workingDirId);
        } catch(e) { log(`⚠️ 刮削元数据部分失败: ${e.message}`, 'warn'); }

        // 5. 移动 (归档)
        // 115: 移动整个文件夹
        // PikPak: 移动视频文件 (和海报NFO，如果它们已经在 targetCid 就不用动了)
        if (item.driveType === '115') {
            await Driver.move(folderCid, targetCid);
        } else {
            // PikPak: 视频还在下载目录，移动到 targetCid
            if (folderCid !== targetCid) await Driver.move(folderCid, targetCid);
        }

        log(`🚚 归档完成`, 'success');
        return true;
    }
};
module.exports = Organizer;
EOF

# 5. 重启
echo "🔄 重启应用..."
pkill -f "node app.js" || echo "应用可能未运行。"

echo "✅ [完成] V13.14.4 部署完成！请在设置页配置 PikPak 账号 (格式: username|password)。"
