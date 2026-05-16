"""
从 Chrome 一键获取云原神配置。
启动 CDP 浏览器让用户登录后手动 F5，自动捕获 token。
支持多账号：追加新账号或覆盖已有账号。
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid

import httpx
import websocket
import yaml


_DEBUG_PORT = 49222
_MHYY_URL = "https://ys.mihoyo.com/cloud/#/"
_CHROME_CANDIDATES = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    os.path.expandvars(r"%LocalAppData%\Google\Chrome\Application\chrome.exe"),
]


def _log(msg, level="info"):
    p = {"info": "[INFO]", "warn": "[WARN]", "err": "[ERR]"}.get(level, "")
    print(f"[MHYY] {p} {msg}", flush=True)


# ============================================================
#  Chrome CDP 浏览器
# ============================================================

def _find_chrome():
    for p in _CHROME_CANDIDATES:
        if os.path.isfile(p):
            return p
    r = subprocess.run(["where", "chrome"], capture_output=True, text=True, shell=True)
    if r.returncode == 0:
        for line in r.stdout.strip().splitlines():
            if os.path.isfile(line):
                return line
    return None


def _kill_port(port):
    try:
        r = subprocess.run(["netstat", "-ano"], capture_output=True, text=True, shell=True)
        for line in r.stdout.splitlines():
            if "LISTENING" in line and f":{port}" in line:
                pid = line.strip().split()[-1]
                subprocess.run(["taskkill", "/F", "/PID", pid], capture_output=True, shell=True)
    except Exception:
        pass


def _launch_chrome():
    chrome = _find_chrome()
    if not chrome:
        raise RuntimeError("未找到 Chrome，请确认已安装。")

    _kill_port(_DEBUG_PORT)
    time.sleep(0.5)

    profile = os.path.join(os.environ.get("TEMP", os.getcwd()), "mhyy_chrome_cdp")

    # 清除 CDP 浏览器缓存，强制重新登录
    if os.path.isdir(profile):
        _log("正在清除浏览器缓存...")
        shutil.rmtree(profile, ignore_errors=True)
        _log("浏览器缓存已清除，需要重新登录")

    subprocess.Popen(
        [chrome,
         f"--remote-debugging-port={_DEBUG_PORT}",
         f"--user-data-dir={profile}",
         "--remote-allow-origins=*",
         "--no-first-run", "--no-default-browser-check",
         _MHYY_URL],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NEW_PROCESS_GROUP,
    )

    for i in range(20):
        time.sleep(1)
        try:
            if httpx.get(f"http://127.0.0.1:{_DEBUG_PORT}/json/version", timeout=2).status_code == 200:
                _log("Chrome 调试端口就绪")
                return
        except Exception:
            pass
    raise RuntimeError("Chrome 启动超时")


def _find_and_connect():
    """找到 mihoyo 页面并返回 (ws, page_url)。"""
    for _ in range(15):
        try:
            for tab in httpx.get(f"http://127.0.0.1:{_DEBUG_PORT}/json", timeout=3).json():
                if tab.get("type") == "page" and "mihoyo" in tab.get("url", "").lower():
                    ws_url = tab.get("webSocketDebuggerUrl", "")
                    if ws_url:
                        return websocket.create_connection(ws_url, timeout=10), tab["url"]
        except Exception:
            pass
        time.sleep(1)
    raise RuntimeError("未找到云原神页面，请在 Chrome 中打开 https://ys.mihoyo.com/cloud/#/")


def _build_result(headers):
    token = headers.get("x-rpc-combo_token", "")
    channel = headers.get("x-rpc-channel", "")
    game_biz = headers.get("x-rpc-cg-game_biz", "")
    region = "os" if (channel == "mihoyo" or game_biz == "hk4e_global") else "cn"
    if os.environ.get("MHYY_GLOBAL") == "1":
        region = "os"

    bbsid = ""
    for p in token.split(";"):
        if p.startswith("oi="):
            bbsid = p[3:]
            break

    _log(f"捕获成功! BBSID={bbsid}, region={region}")
    return {
        "token": token,
        "type": int(headers.get("x-rpc-client_type", "16")),
        "sysver": headers.get("x-rpc-sys_version", "Windows 10"),
        "deviceid": headers.get("x-rpc-device_id", str(uuid.uuid4())),
        "devicename": headers.get("x-rpc-device_name", "Unknown"),
        "devicemodel": headers.get("x-rpc-device_model", "Unknown"),
        "appid": headers.get("x-rpc-app_id", ""),
        "region": region,
    }


# ============================================================
#  CDP 捕获
# ============================================================

def _capture_via_cdp():
    """启动 Chrome → 用户登录 → F5 刷新 → 捕获 token"""
    _launch_chrome()

    print("")
    _log("=" * 55)
    _log("请在 Chrome 中登录你的米哈游账号")
    _log("登录成功后回到云原神页面，按 F5 刷新")
    _log("脚本会自动从刷新触发的网络请求中捕获 token")
    _log("=" * 55)
    print("")

    deadline = time.time() + 300
    reconnect_count = 0

    while time.time() < deadline:
        try:
            ws, page_url = _find_and_connect()
            reconnect_count += 1
            if reconnect_count == 1:
                _log(f"已连接到页面 ({page_url[:70]})，等待登录...")

            # 启用 Network 监听
            ws.send(json.dumps({"id": 1, "method": "Network.enable"}))

            # 吞掉使能响应
            ws.settimeout(0.3)
            for _ in range(10):
                try:
                    ws.recv()
                except Exception:
                    break

            ws.settimeout(2.0)

            while time.time() < deadline:
                try:
                    msg = json.loads(ws.recv())

                    if msg.get("method") == "Network.requestWillBeSent":
                        req = msg.get("params", {}).get("request", {})
                        req_url = req.get("url", "")
                        headers = req.get("headers", {})
                        token = headers.get("x-rpc-combo_token", "")

                        if "api-cloudgame" in req_url.lower():
                            has = "YES" if re.search(r"oi=\d+", token) else "NO "
                            _log(f"[请求] token={has}  {req_url[:100]}")

                            if re.search(r"oi=\d+", token):
                                result = _build_result(headers)
                                ws.close()
                                return result

                except websocket.WebSocketTimeoutException:
                    pass
                except json.JSONDecodeError:
                    pass
                except Exception:
                    break

            ws.close()
            _log("连接断开，重新连接...", "warn")
            time.sleep(2)

        except RuntimeError:
            remaining = int(deadline - time.time())
            if remaining <= 0:
                raise
            time.sleep(3)

    raise RuntimeError("超时")


# ============================================================
#  交互式选择 + 写入 config.yml
# ============================================================

def _read_existing_config():
    config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.yml")
    if os.path.isfile(config_path):
        with open(config_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
        if isinstance(data, dict):
            return data
    return {}


def _select_account_index(accounts):
    """展示已有账号，让用户选择追加或覆盖。返回 None 表示追加，返回数字表示覆盖的索引。"""
    if not accounts:
        return None

    print("")
    _log(f"当前已有 {len(accounts)} 个账号:")
    for i, acct in enumerate(accounts):
        token = acct.get("token", "")
        bbsid = "N/A"
        m = re.search(r"oi=(\d+)", str(token))
        if m:
            bbsid = m.group(1)
        token_preview = str(token)[:60] + "..." if len(str(token)) > 60 else str(token)
        _log(f"  [{i + 1}] BBSID: {bbsid}  token: {token_preview}")

    print("")
    _log("请选择操作:")
    _log(f"  [A] 追加为新账号（第 {len(accounts) + 1} 个）")
    for i in range(len(accounts)):
        _log(f"  [{i + 1}] 覆盖第 {i + 1} 个账号")

    while True:
        choice = input("请输入选项: ").strip().upper()
        if choice == "A":
            return None
        try:
            idx = int(choice) - 1
            if 0 <= idx < len(accounts):
                return idx
        except ValueError:
            pass
        _log("无效选项，请重新输入", "warn")


def update_config(account, index=None):
    """写入 config.yml。index=None 追加，index=N 覆盖第 N 个账号。"""
    config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.yml")
    existing = _read_existing_config()

    accounts = existing.get("accounts", [])
    if not isinstance(accounts, list):
        accounts = []

    if index is not None and 0 <= index < len(accounts):
        accounts[index].update(account)
        _log(f"已覆盖第 {index + 1} 个账号")
    else:
        accounts.append(account)
        _log(f"已追加为第 {len(accounts)} 个账号")

    existing["accounts"] = accounts
    existing.setdefault("proxy", "")
    existing.setdefault("notifications", {
        "serverchan": {"key": ""},
        "dingtalk": {"webhook_url": ""},
        "telegram": {"bot_token": "", "chat_id": ""},
        "pushplus": {"key": ""},
    })

    header = (
        "# 使用前请阅读文档：https://bili33.top/posts/MHYY-AutoCheckin-Manual/\n"
        "# 有问题请前往Github开启issue：https://github.com/GamerNoTitle/MHYY/issues\n"
        "\n"
    )
    with open(config_path, "w", encoding="utf-8") as f:
        f.write(header)
        f.write("proxy: ''\n")
        f.write("\n")
        f.write("notifications:\n")
        f.write("  serverchan:\n")
        f.write("    key: ''\n")
        f.write("  dingtalk:\n")
        f.write("    webhook_url: ''\n")
        f.write("  telegram:\n")
        f.write("    bot_token: ''\n")
        f.write("    chat_id: ''\n")
        f.write("  pushplus:\n")
        f.write("    key: ''\n")
        f.write("\n")
        f.write("######## 以下为账号配置项，可以多账号，详情请参考文档 ########\n")
        f.write("accounts:\n")

        for idx, acct in enumerate(accounts):
            comment = "第一个账号" if idx == 0 else f"第{idx + 1}个账号"
            f.write(f"  # {comment}\n")
            f.write(f"  - token: {acct.get('token', '')}\n")
            f.write(f"    type: {acct.get('type', '')}\n")
            f.write(f"    sysver: {acct.get('sysver', '')}\n")
            f.write(f"    deviceid: {acct.get('deviceid', '')}\n")
            f.write(f"    devicename: {acct.get('devicename', '')}\n")
            f.write(f"    devicemodel: {acct.get('devicemodel', '')}\n")
            f.write(f"    appid: {acct.get('appid', '')}\n")

    _log(f"配置已写入 {config_path}")


# ============================================================
#  Main
# ============================================================

def main():
    _log("===== MHYY 一键获取配置 =====")

    try:
        account = _capture_via_cdp()

        # 读取现有账号，让用户选择追加或覆盖
        existing = _read_existing_config()
        existing_accounts = existing.get("accounts", [])
        if not isinstance(existing_accounts, list):
            existing_accounts = []

        index = _select_account_index(existing_accounts)
        update_config(account, index)

        _log("=" * 50)
        _log("搞定! 获取到的配置:")
        print(f"  token:     {account['token'][:50]}...")
        print(f"  type:      {account['type']}")
        print(f"  sysver:    {account['sysver']}")
        print(f"  region:    {account['region']}")

        if index is not None:
            print(f"  操作:      覆盖第 {index + 1} 个账号")
        else:
            print(f"  操作:      追加为第 {len(existing_accounts) + 1} 个账号")

    except KeyboardInterrupt:
        _log("用户取消", "warn")
        sys.exit(1)
    except Exception as e:
        _log(f"获取失败: {e}", "err")
        sys.exit(1)


if __name__ == "__main__":
    main()
