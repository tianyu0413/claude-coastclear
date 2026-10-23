#!/bin/bash
# 仅定义函数；加载本文件不会写配置、提权或弹窗。

cc_confirm() {
  local answer=""
  [[ "${REPAIR_CONFIRMED:-0}" == "1" ]] && return 0
  if [[ ! -t 0 ]]; then
    echo "未确认，未修改配置。请在终端确认，或明确追加 --yes。" >&2
    return 1
  fi
  read -r -p "$1 [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) REPAIR_CONFIRMED=1; return 0 ;;
    *) echo "已取消，未修改配置。"; return 1 ;;
  esac
}

cc_admin() {
  [[ "${REPAIR_CONFIRMED:-0}" == "1" ]] || return 1
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  elif [[ "${CC_GUI:-0}" == "1" ]]; then
    # 使用 macOS 原生授权，不创建免密 sudo 规则或后台服务。
    local command=""
    printf -v command '%q ' "$@"
    /usr/bin/osascript -e 'on run argv' \
      -e 'do shell script (item 1 of argv) with administrator privileges' \
      -e 'end run' "$command"
  else
    sudo "$@"
  fi
}
