#!/usr/bin/env python3
"""Install the Vibe Key bridge and update the selected AU05-X profile."""

import copy
import datetime as dt
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOME = Path.home()
ULANZI = HOME / "Library/Application Support/Ulanzi/UlanziDeck"
PROFILE_ROOT = ULANZI / "ProfilesV2"
DATA = HOME / "Library/Application Support/VibeKeyBridge"
APP = HOME / "Applications/VibeKeyBridge.app"
AGENT = HOME / "Library/LaunchAgents/local.vibekey.bridge.plist"
LABEL = "local.vibekey.bridge"


def run(*args, check=True):
    return subprocess.run(args, check=check, text=True, capture_output=True)


def fail(message):
    raise RuntimeError(message)


def profile_page():
    if not PROFILE_ROOT.is_dir():
        fail("找不到优篮子工作室的配置目录。请先安装并打开优篮子工作室（Ulanzi Studio），连接 AU05-X。")

    configured_device = configured_name = None
    settings = ULANZI / "config/setting_source.json"
    if settings.exists():
        data = json.loads(settings.read_text())
        configured_device = data.get("CurrentDeviceType")
        current = next((d for d in data.get("Devices", []) if d.get("CurrentDevice") == configured_device), None)
        if current:
            configured_name = current.get("CurrentProfile")

    candidates = []
    for manifest in PROFILE_ROOT.glob("*.ulanziProfile/manifest.json"):
        try:
            data = json.loads(manifest.read_text())
        except (OSError, ValueError):
            continue
        if data.get("Device", {}).get("Model") == "AU05-X":
            candidates.append((manifest.parent, data))
    if not candidates:
        fail("没有找到 AU05-X 的设备预设。请先在优篮子工作室中创建一个预设。")

    matches = [(p, d) for p, d in candidates if d.get("Device", {}).get("UUID") == configured_device and d.get("Name") == configured_name]
    if len(matches) == 1:
        chosen = matches[0]
    elif len(candidates) == 1 and not configured_device:
        chosen = candidates[0]
    else:
        print("找到多个 AU05-X 预设，请选择要修改的一个：")
        for index, (_, data) in enumerate(candidates, 1):
            print(f"  {index}. {data.get('Name') or '未命名'}")
        answer = input("输入序号：").strip()
        if not answer.isdigit() or not 1 <= int(answer) <= len(candidates):
            fail("未选择有效预设，未修改任何内容。")
        chosen = candidates[int(answer) - 1]

    profile_dir, profile = chosen
    page_id = profile.get("Pages", {}).get("Current")
    if not isinstance(page_id, str) or not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", page_id):
        fail("当前页面标识无效，未修改任何内容。")
    profiles_dir = profile_dir / "Profiles"
    page_dir = profiles_dir / page_id
    page = page_dir / "manifest.json"
    if profiles_dir.is_symlink() or page_dir.is_symlink() or page.is_symlink():
        fail("当前页面使用了符号链接，未修改任何内容。")
    if not page.is_file():
        fail("找不到当前预设的页面配置，未修改任何内容。")
    if page.resolve().parent.parent != profiles_dir.resolve():
        fail("当前页面不在所选预设内，未修改任何内容。")
    return profile.get("Name") or "未命名", page


def patched_page(page):
    data = json.loads(page.read_text())
    template = json.loads((ROOT / "config/actions.json").read_text())
    for model in template:
        controller = next((c for c in data.get("Controllers", []) if c.get("Type") == model["Type"]), None)
        if controller is None:
            controller = {"Type": model["Type"], "Actions": {}}
            data.setdefault("Controllers", []).append(controller)
        actions = controller.setdefault("Actions", {})
        for slot, source in model["Actions"].items():
            action = copy.deepcopy(source)
            previous = actions.get(slot, {})
            action["ActionID"] = previous.get("ActionID") or str(uuid.uuid4())
            icon = page.parent / "Images/btn_hotkey.png"
            if icon.is_file():
                action["ViewParam"][0]["Icon"] = str(icon)
            actions[slot] = action
    return data


def build_app(destination):
    macos = destination / "Contents/MacOS"
    macos.mkdir(parents=True)
    shutil.copy2(ROOT / "config/Info.plist", destination / "Contents/Info.plist")
    run("/usr/bin/swiftc", "-O", "-framework", "AppKit", "-framework", "ApplicationServices",
        str(ROOT / "src/VibeKeyBridge.swift"), "-o", str(macos / "VibeKeyBridge"))
    run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(destination))


def stop_studio():
    if run("/usr/bin/pgrep", "-x", "UlanziDeck", check=False).returncode != 0:
        return
    run("/usr/bin/osascript", "-e", 'tell application "Ulanzi Studio" to quit', check=False)
    for _ in range(40):
        if run("/usr/bin/pgrep", "-x", "UlanziDeck", check=False).returncode != 0:
            return
        time.sleep(0.2)
    fail("优篮子工作室仍在运行。请先退出它，然后重新运行安装程序。")


def install_agent():
    AGENT.parent.mkdir(parents=True, exist_ok=True)
    plist = {
        "Label": LABEL,
        "ProgramArguments": ["/usr/bin/open", "-g", "-a", str(APP)],
        "RunAtLoad": True,
        "StandardOutPath": str(DATA / "output.log"),
        "StandardErrorPath": str(DATA / "error.log"),
    }
    with AGENT.open("wb") as stream:
        plistlib.dump(plist, stream)
    domain = f"gui/{os.getuid()}"
    run("/bin/launchctl", "bootout", domain, str(AGENT), check=False)
    run("/bin/launchctl", "bootstrap", domain, str(AGENT))


def main():
    if sys.platform != "darwin":
        fail("本程序仅支持 macOS。")
    if not Path("/usr/bin/swiftc").exists():
        fail("缺少 Swift 编译工具。请先运行 xcode-select --install。")
    profile_name, page = profile_page()
    updated = patched_page(page)

    with tempfile.TemporaryDirectory(prefix="vibekey-install-") as temporary:
        built_app = Path(temporary) / "VibeKeyBridge.app"
        print("正在构建控制程序…")
        build_app(built_app)
        print(f"将更新设备预设：{profile_name}")
        stop_studio()

        DATA.mkdir(parents=True, exist_ok=True)
        backup_dir = DATA / "backups"
        backup_dir.mkdir(exist_ok=True)
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = backup_dir / f"{stamp}-{page.parent.name}-{uuid.uuid4().hex[:8]}-manifest.json"
        shutil.copy2(page, backup)
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix=".vibekey-", suffix=".tmp", dir=page.parent, delete=False) as stream:
            staged = Path(stream.name)
            stream.write(json.dumps(updated, ensure_ascii=False, indent=2) + "\n")
        try:
            staged.replace(page)
        finally:
            staged.unlink(missing_ok=True)

        try:
            run("/usr/bin/pkill", "-x", "VibeKeyBridge", check=False)
            APP.parent.mkdir(exist_ok=True)
            if APP.exists():
                shutil.rmtree(APP)
            shutil.copytree(built_app, APP)
            install_agent()
        except Exception:
            shutil.copy2(backup, page)
            raise
        finally:
            run("/usr/bin/open", "-a", "Ulanzi Studio", check=False)

    print("安装完成。")
    print(f"原设备预设已备份：{backup}")
    print("请在系统设置 → 隐私与安全性 → 辅助功能中允许 VibeKeyBridge；如果已允许过旧版本，请关闭再打开该开关。")
    print("听写工具 Typeless 的听写快捷键需设为右 Option 键。")


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError, ValueError, RuntimeError) as error:
        print(f"安装失败：{error}", file=sys.stderr)
        sys.exit(1)
