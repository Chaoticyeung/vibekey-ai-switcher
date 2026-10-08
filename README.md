# Vibe Key 四应用语音控制

把乌兰子 Vibe Key（AU05-X）的旋钮和三个按键，用来切换克劳德（Claude）、代码助手（Codex）、工作伙伴（WorkBuddy）、深度求索（DeepSeek），并通过听写工具（Typeless）输入语音。

## 准备

- macOS、乌兰子工作室（Ulanzi Studio）和已配对的 AU05-X。
- 已安装想要控制的应用，以及听写工具（Typeless）。听写快捷键设为**右 Option 键**。
- 苹果的 Swift 编译工具。若尚未安装，先运行 `xcode-select --install`。

程序会按应用的标识查找安装位置。没装齐四个应用也能安装；切到缺失的应用时会显示提示。

## 安装

在终端运行这一行：

```sh
git clone https://github.com/Chaoticyeung/vibekey-ai-switcher.git && cd vibekey-ai-switcher && sh install.command
```

也可以下载本仓库的压缩包，解压后双击 `install.command`。安装程序会找到当前选中的 AU05-X 预设、备份原文件、写入按键配置、编译控制程序，并设置登录后启动。若有多个预设且无法确认当前预设，会让你选择。

**首次安装后**，请到“系统设置 → 隐私与安全性 → 辅助功能”允许 `VibeKeyBridge`。更新程序后如失效，可关闭再打开该权限。macOS 要求这一步由本人完成。

## 按键

| 操作 | 功能 |
| --- | --- |
| 旋钮直接左转／右转 | 在四个应用间切换选择，屏幕短暂显示选中项 |
| 按下旋钮 | 打开选中的应用 |
| 上方小键 | 开始／结束语音输入 |
| 中间对勾键 | 识别到成对授权按钮时确认；否则发送输入框中的消息 |
| 下方叉号键 | 识别到成对授权按钮时否决；否则发送退出／停止键 |

应用顺序：克劳德（Claude）→ 代码助手（Codex）→ 工作伙伴（WorkBuddy）→ 深度求索（DeepSeek）。

说完可按上方小键结束语音；也可直接按对勾键。直接按对勾时，程序最多等待 20 秒，确认文字进入输入框后再发送。若文字没有进入，会提示“暂未发送”。

授权按钮识别使用窗口文字匹配；四个应用的真实授权弹窗仍需逐一验证。遇到未识别的弹窗，请先用鼠标处理。

## 恢复原预设

每次安装前，原页面配置会保存到 `~/Library/Application Support/VibeKeyBridge/backups/`。退出乌兰子工作室后，将相应备份复制回原预设页面的 `manifest.json`，再重新打开乌兰子工作室。程序本体位于 `~/Applications/VibeKeyBridge.app`；登录启动项位于 `~/Library/LaunchAgents/local.vibekey.bridge.plist`。

## 仓库内容

- `src/VibeKeyBridge.swift`：最终运行程序源码。
- `config/actions.json`：通用按键配置，不含设备编号或个人路径。
- `scripts/install.py`、`install.command`：安装与备份。

本项目是个人自定义配置，与乌兰子及上述应用的开发商无关联。
