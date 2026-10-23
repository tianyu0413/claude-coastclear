#!/bin/bash
# 仅卸载 cc 的用户启动项和应用；保留数据及本地备份，不处理旧应用或系统守护进程。
set -euo pipefail
AGENT="local.cc"
launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$AGENT.plist"
# 不使用 pkill -x cc，避免误杀同名 C 编译器。
if [[ -d /Applications/cc.app ]]; then
  echo "请先退出 cc。确认删除 /Applications/cc.app？[y/N]"
  read -r answer
  case "$answer" in y|Y) rm -rf /Applications/cc.app ;; *) echo "已保留应用。" ;; esac
fi
echo "cc 用户启动项已移除，数据和备份保留。"
