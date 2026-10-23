#!/bin/bash
# 明确执行本脚本才安装；仅 --autostart 选项会注册登录启动并启动应用。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
AUTOSTART=0
case "${1:-}" in
  "") ;;
  --autostart) AUTOSTART=1 ;;
  *) echo "用法：bash install.sh [--autostart]" >&2; exit 2 ;;
esac
bash "$DIR/menubar/build.sh"
ditto "$DIR/menubar/cc.app" /Applications/cc.app
codesign --force --deep --sign - /Applications/cc.app
if [[ "$AUTOSTART" == "1" ]]; then
  AGENT="local.cc"
  mkdir -p "$HOME/Library/LaunchAgents"
  cp "$DIR/menubar/$AGENT.plist" "$HOME/Library/LaunchAgents/$AGENT.plist"
  launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$AGENT.plist"
  echo "已按 --autostart 请求注册登录启动。cc 启动后仅检测。"
else
  echo "已安装 /Applications/cc.app，未启动应用，未注册登录启动。"
fi
