#!/usr/bin/env python3
# 1.1.x → Go 版本地助手的过渡脚本。只放在发布的 macos.zip 里，名字叫 helper.py：
# 1.1.x 的助手在面板里一键更新时只认带 helper.py 的安装包，会把它当成新版助手换上并重启（launchd 的 <LABEL>.helper 服务）。
# 它启动后：从本项目的正式发布下载 macOS 安装包、按 SHA256SUMS 校验、解压，再用一个一次性的 launchd 任务运行
# neu-v6-free install（安装程序会停掉 <LABEL>.helper，也就是本脚本，所以不能由本脚本直接运行它）。
# 安装程序保留配置、订阅、设置、我的规则和流量统计，装成一个服务、自检，不通就暂停 sing-box。
# 这期间 sing-box（1.1.x 里是单独的 <LABEL> 服务）一直在运行，网络不受影响。下载失败就隔一会儿再试。
import glob
import hashlib
import json
import os
import plistlib
import subprocess
import sys
import time
import urllib.request
import uuid

REPO = "Concrise/neu-v6-free"
API = f"https://api.github.com/repos/{REPO}/releases/latest"
PREFIX = f"https://github.com/{REPO}/releases/download/"
BIN_DIR = os.path.dirname(os.path.abspath(__file__))
NAME = os.path.basename(BIN_DIR)
ETC_DIR = f"/usr/local/etc/{NAME}"
VAR_DIR = f"/usr/local/var/{NAME}"


def log(msg):
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} [升级到 Go 版] {msg}", flush=True)


def arg(flag, default):
    a = sys.argv[1:]
    return a[a.index(flag) + 1] if flag in a and a.index(flag) + 1 < len(a) else default


LABEL = arg("-l", f"local.{NAME}")
JOB = LABEL + ".migrate"


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "neu-v6-free"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def job_running():
    out = subprocess.run(["/bin/launchctl", "print", f"system/{JOB}"], capture_output=True, text=True).stdout
    return "state = running" in out


def migrate():
    rel = json.loads(get(API))
    assets = {a["name"]: a["browser_download_url"] for a in rel.get("assets", [])}
    name = next((n for n in assets if n.endswith("-macos.zip")), None)
    if not name or "SHA256SUMS" not in assets:
        raise RuntimeError("最新发布里没有 macOS 安装包或 SHA256SUMS")
    for u in (assets[name], assets["SHA256SUMS"]):
        if not u.startswith(PREFIX):
            raise RuntimeError(f"下载地址不是本项目的发布：{u}")
    data = get(assets[name])
    sums = get(assets["SHA256SUMS"]).decode()
    want = next((l.split()[0] for l in sums.splitlines() if l.strip().endswith("  " + name)), "")
    if hashlib.sha256(data).hexdigest() != want.lower():
        raise RuntimeError("安装包校验不通过（SHA256 不符）")
    stage = os.path.join(ETC_DIR, ".migrate-" + uuid.uuid4().hex)
    os.makedirs(stage, mode=0o700)
    zf = os.path.join(stage, "pkg.zip")
    with open(zf, "wb") as f:
        f.write(data)
    subprocess.run(["/usr/bin/ditto", "-x", "-k", zf, stage], check=True)  # ditto 保留可执行权限
    pkg = next((os.path.dirname(v) for v in glob.glob(os.path.join(stage, "*", "VERSION"))), None)
    if not pkg or not os.path.isfile(os.path.join(pkg, "neu-v6-free")):
        raise RuntimeError("安装包里没有 neu-v6-free")
    plist = os.path.join(stage, JOB + ".plist")
    with open(plist, "wb") as f:
        plistlib.dump({
            "Label": JOB,
            "ProgramArguments": [os.path.join(pkg, "neu-v6-free"), "install", "--from", pkg, "--name", NAME, "--label", LABEL],
            "RunAtLoad": True,
            "StandardOutPath": os.path.join(VAR_DIR, "migrate.log"),
            "StandardErrorPath": os.path.join(VAR_DIR, "migrate.log"),
        }, f)
    subprocess.run(["/bin/launchctl", "bootout", f"system/{JOB}"], capture_output=True)
    subprocess.run(["/bin/launchctl", "bootstrap", "system", plist], check=True, capture_output=True)
    log(f"已校验 {name}，开始安装（输出在 {VAR_DIR}/migrate.log）")


def main():
    if job_running():
        log("安装程序已经在运行")
    else:
        while True:
            try:
                migrate()
                break
            except Exception as e:
                log(f"没成功：{e}；一分钟后再试")
                time.sleep(60)
    # 安装程序会停掉本服务；在那之前保持运行，免得 launchd 反复拉起
    while True:
        time.sleep(60)


if __name__ == "__main__":
    main()
