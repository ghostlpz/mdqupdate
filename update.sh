import os
import requests
import json
import re
from urllib.parse import urlparse

# 配置部分 (请确保这些配置存在于你的代码中)
FLARESOLVERR_URL = "http://localhost:8191/v1"  # 你的 FlareSolverr 地址
BASE_URL = "https://www.example.com" # 你的目标网站主页，用于伪造 Referer

def sanitize_filename(name):
    """清理文件名，去除系统不允许的特殊字符"""
    return re.sub(r'[\\/*?:"<>|]', "", name).strip()

def get_cookies_via_flaresolverr(target_url):
    """通过 FlareSolverr 获取通过验证的 Cookies 和 User-Agent"""
    headers = {"Content-Type": "application/json"}
    data = {
        "cmd": "request.get",
        "url": target_url,
        "maxTimeout": 60000
    }
    
    try:
        response = requests.post(FLARESOLVERR_URL, headers=headers, json=data)
        if response.status_code == 200:
            result = response.json()
            if result.get('status') == 'ok':
                solution = result['solution']
                return {
                    "cookies": {cookie['name']: cookie['value'] for cookie in solution['cookies']},
                    "user_agent": solution['userAgent']
                }
    except Exception as e:
        print(f"[!] FlareSolverr 调用失败: {e}")
    return None

def download_file(url, save_path, referer_url=None, use_flaresolverr=False):
    """
    通用下载函数：支持图片和视频
    1. 尝试普通下载（带 Referer）
    2. 如果失败且开启了 FlareSolverr，获取 Cookie 后重试
    """
    
    # 默认请求头，伪装成浏览器，并带上 Referer (解决防盗链的关键)
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': referer_url if referer_url else BASE_URL
    }

    session = requests.Session()

    # 逻辑：如果指定要用 FlareSolverr，先获取 Cookie
    if use_flaresolverr:
        print(f"[*] 正在调用 FlareSolverr 获取权限: {url}...")
        fs_data = get_cookies_via_flaresolverr(url) # 或者传入页面 URL
        if fs_data:
            session.cookies.update(fs_data['cookies'])
            headers['User-Agent'] = fs_data['user_agent']
            print("[+] 成功获取 FlareSolverr Cookies")

    try:
        # 发起请求 (stream=True 对大文件/视频很重要)
        with session.get(url, headers=headers, stream=True, timeout=30) as r:
            # 检查状态码
            if r.status_code != 200:
                print(f"[!] 下载失败，状态码: {r.status_code}")
                # 如果普通请求失败（比如403），且还没用 FlareSolverr，可以在这里递归调用自己开启 FlareSolverr
                if not use_flaresolverr and r.status_code in [403, 503]:
                    print("[*] 触发 403/503，尝试使用 FlareSolverr 重试...")
                    return download_file(url, save_path, referer_url, use_flaresolverr=True)
                return False

            # 写入文件
            with open(save_path, 'wb') as f:
                for chunk in r.iter_content(chunk_size=8192):
                    f.write(chunk)
            print(f"[+] 文件已保存: {save_path}")
            return True

    except Exception as e:
        print(f"[!] 下载异常: {e}")
        return False

def push_content_to_local(video_data, base_download_path="./Downloads"):
    """
    核心推送逻辑：建立文件夹并保存视频和图片
    video_data: 包含 'title', 'actor', 'video_url', 'cover_url', 'page_url' 的字典
    """
    actor = sanitize_filename(video_data.get('actor', '未知演员'))
    title = sanitize_filename(video_data.get('title', '未知标题'))
    
    # 1. 建立文件夹: 演员-标题
    folder_name = f"{actor}-{title}"
    folder_path = os.path.join(base_download_path, folder_name)
    
    if not os.path.exists(folder_path):
        os.makedirs(folder_path)
        print(f"[*] 创建目录: {folder_path}")
    
    # 2. 下载海报 (保存为 poster.jpg 或 poster.webp)
    cover_url = video_data.get('cover_url')
    if cover_url:
        # 提取后缀名 (如 .jpg, .webp)，如果没有则默认 .jpg
        ext = os.path.splitext(urlparse(cover_url).path)[1]
        if not ext: ext = ".jpg"
        
        poster_path = os.path.join(folder_path, f"poster{ext}") # 命名为 poster 方便刮削
        
        print(f"[*] 开始下载海报: {cover_url}")
        # 传入 page_url 作为 Referer，这是解决防盗链最有效的方法
        download_file(cover_url, poster_path, referer_url=video_data.get('page_url'))
    
    # 3. 下载视频
    video_url = video_data.get('video_url')
    if video_url:
        # 简单判断是 m3u8 还是直链
        if ".m3u8" in video_url:
            print(f"[!] 注意: 这是一个 m3u8 流媒体，直接保存只能得到列表文件。你需要调用 ffmpeg 下载。")
            # 这里可以扩展 ffmpeg 下载逻辑，暂时先保存 m3u8 文件
            video_path = os.path.join(folder_path, f"{title}.m3u8")
        else:
            video_path = os.path.join(folder_path, f"{title}.mp4")
            
        print(f"[*] 开始下载视频: {video_url}")
        download_file(video_url, video_path, referer_url=video_data.get('page_url'))

# --- 测试调用 ---
if __name__ == "__main__":
    # 模拟数据
    sample_data = {
        "title": "测试视频标题",
        "actor": "某某演员",
        "cover_url": "https://upload.xchina.io/video/67ee3a8d3a95d.webp", # 你的难搞图片
        "video_url": "https://example.com/video.mp4",
        "page_url": "https://xxxxx.com/view/123" # 视频所在的网页地址
    }
    
    push_content_to_local(sample_data)
