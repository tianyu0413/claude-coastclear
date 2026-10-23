#!/bin/bash
# cc-network.sh 网络波动状态机自测：不联网，不修改系统时区，不弹真实通知。
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-network.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
export CC_DATA_DIR="$TEST_DIR"
export CC_NETWORK_SELFTEST=1
source "$ROOT/cc-network.sh"

FAIL=0
# 验证真实探针选择逻辑，随后仍由模拟函数完成全部状态机测试。
PROBE_DEFINITION=$(declare -f ip_china)
PROBE_TARGETS=$(eval "$PROBE_DEFINITION"; get_first_ip() { printf '%s\n' "$@"; }; ip_china)
NOTIFY_LOG="$TEST_DIR/notifications"
APPLY_LOG="$TEST_DIR/applied-timezones"
MOCK_CN=""; MOCK_INTL=""; MOCK_GFW=""; MOCK_GOOGLE=1; MOCK_TZ="America/Los_Angeles"; MOCK_COUNTRY=US
MOCK_CURRENT_TZ="America/Los_Angeles"

check() { # check <描述> <实际> <期望>
  if [[ "$2" == "$3" ]]; then
    echo "  ✓ $1"
  else
    echo "  ✗ $1: 实际=$2 期望=$3"
    FAIL=1
  fi
}

value() { awk -F= -v key="$2" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$1" 2>/dev/null; }
notification_count() { [[ -f "$NOTIFY_LOG" ]] && wc -l <"$NOTIFY_LOG" | tr -d ' ' || echo 0; }

ip_china() { [[ -n "$MOCK_CN" ]] && printf '%s|0.010|0.050|0.090|0.120|200\n' "$MOCK_CN"; }
ip_intl() { [[ -n "$MOCK_INTL" ]] && printf '%s|0.020|0.060|0.100|0.140|200\n' "$MOCK_INTL"; }
ip_gfw() { [[ -n "$MOCK_GFW" ]] && printf '%s|0.030|0.070|0.110|0.160|200\n' "$MOCK_GFW"; }
google_reachable() {
  if [[ "$MOCK_GOOGLE" == "1" ]]; then
    printf '%s\n' '0.040|0.080|0.120|0.180|204'; return 0
  fi
  printf '%s\n' '0.000|0.000|0.000|0.900|000'; return 1
}
ip_timezone() { [[ -n "$MOCK_TZ" ]] && printf '%s\n' "$MOCK_TZ"; }
ip_country() { [[ -n "$MOCK_COUNTRY" ]] && printf '%s\n' "$MOCK_COUNTRY"; }
current_timezone() { printf '%s\n' "$MOCK_CURRENT_TZ"; }
apply_timezone() {
  [[ "$1" == "$MOCK_CURRENT_TZ" ]] && return 0
  printf '%s\n' "$1" >>"$APPLY_LOG"
  MOCK_CURRENT_TZ="$1"
  return 0
}

notify() { printf '%s|%s\n' "$1" "$2" >>"$NOTIFY_LOG"; }

run_sample() {
  main >/dev/null 2>&1
  return $?
}

set_sample() {
  MOCK_CN="$1"; MOCK_INTL="$2"; MOCK_GFW="$3"
}

check "国内侧只使用固定探针，不混用备用路径" "$PROBE_TARGETS" "https://myip.ipip.net"

OLD_IP="1.2.3.4"
NEW_IP="5.6.7.8"

printf '%s\n' '① 首次有效结果立即建立基线'
printf '%s\n' 'none|0' >"$STATE"   # 模拟旧版本恰好停在获取失败状态
OLD_EPOCH=$(( $(date +%s) - 90000 ))
printf '%s\n' "$OLD_EPOCH|9|failure|?|0|9|0|9|0|9|0|9|0" >"$HISTORY"
set_sample "$OLD_IP" "$OLD_IP" "$OLD_IP"
run_sample || true
check "网络稳定" "$(value "$STATUS" network)" "ok"
check "记录出口 IP" "$(value "$STATUS" gfw)" "$OLD_IP"
check "建立通知基线" "$(cat "$STATE")" "$OLD_IP|1"
check "没有首次变化通知" "$(notification_count)" "0"
check "写入 HTTPS/TCP 历史字段" "$(awk -F'|' 'NR==1 {print NF}' "$HISTORY")" "29"
check "记录国内 TCP/TLS/TTFB/HTTP" "$(awk -F'|' 'NR==1 {print $14"|"$15"|"$16"|"$17}' "$HISTORY")" "0.010|0.050|0.090|200"
check "记录 Google HTTPS 指标" "$(awk -F'|' 'NR==1 {print $26"|"$27"|"$28"|"$29}' "$HISTORY")" "0.040|0.080|0.120|204"
check "裁掉 24 小时以前记录" "$(grep -c "^${OLD_EPOCH}|" "$HISTORY" || true)" "0"

printf '%s\n' '② 单次接口失败标记复核，稳定基线保留在历史中'
set_sample "$OLD_IP" "" ""
run_sample || true
check "状态为复核中" "$(value "$STATUS" network)" "verifying"
check "失败计数为 1" "$(value "$STATUS" failure_count)" "1"
check "菜单快照缺失路显示未知" "$(value "$STATUS" gfw)" "?"
check "last_state 不写 none" "$(cat "$STATE")" "$OLD_IP|1"
check "不发送 IP 变化通知" "$(notification_count)" "0"

printf '%s\n' '③ 连续两次失败才确认网络波动'
run_sample || true
check "状态为波动中" "$(value "$STATUS" network)" "unstable"
check "失败计数为 2" "$(value "$STATUS" failure_count)" "2"
check "波动时缺失路显示未知" "$(value "$STATUS" gfw)" "?"
check "仍不发送 IP 变化通知" "$(notification_count)" "0"

printf '%s\n' '④ 恢复后连续两次有效结果才解除波动'
set_sample "$OLD_IP" "$OLD_IP" "$OLD_IP"
run_sample || true
check "第一次恢复仍在复核" "$(value "$STATUS" network)" "verifying"
check "恢复确认 1/2" "$(value "$STATUS" confirm_count)" "1"
check "复核时沿用原 IP" "$(value "$STATUS" gfw)" "$OLD_IP"
run_sample || true
check "第二次恢复为稳定" "$(value "$STATUS" network)" "ok"
check "确认计数清零" "$(value "$STATUS" confirm_count)" "0"
check "恢复过程没有虚假通知" "$(notification_count)" "0"

printf '%s\n' '⑤ Google 单路失败能独立记录，不误判三路 IP 波动'
MOCK_GOOGLE=0
run_sample || true
check "Google 不可达但三路状态仍稳定" "$(value "$STATUS" network)" "ok"
check "Google 成功字段为 0" "$(awk -F'|' 'END {print $13}' "$HISTORY")" "0"
check "其余三路均成功" "$(awk -F'|' 'END {print $7 $9 $11}' "$HISTORY")" "111"
MOCK_GOOGLE=1

printf '%s\n' '⑥ 新 IP 连续出现两次后才正式提交并通知'
set_sample "$NEW_IP" "$NEW_IP" "$NEW_IP"
run_sample || true
check "第一次新 IP 仍在复核" "$(value "$STATUS" network)" "verifying"
check "快照展示本轮新 IP" "$(value "$STATUS" gfw)" "$NEW_IP"
check "基线仍是旧 IP" "$(cat "$STATE")" "$OLD_IP|1"
check "第一次不通知" "$(notification_count)" "0"
run_sample || true
check "第二次新 IP 提交" "$(value "$STATUS" gfw)" "$NEW_IP"
check "网络恢复稳定" "$(value "$STATUS" network)" "ok"
check "基线更新为新 IP" "$(cat "$STATE")" "$NEW_IP|1"
check "只发送一次变化通知" "$(notification_count)" "1"
check "通知不包含 none" "$(grep -c 'none' "$NOTIFY_LOG" 2>/dev/null || true)" "0"

printf '%s\n' '⑦ 三路完整但一致性变化也需要连续确认'
set_sample "9.9.9.9" "$NEW_IP" "$NEW_IP"
run_sample || true
check "第一次不一致仍在复核" "$(value "$STATUS" network)" "verifying"
check "立即展示本轮不一致" "$(value "$STATUS" consistent)" "0"
run_sample || true
check "第二次才提交不一致" "$(value "$STATUS" consistent)" "0"
check "不一致提交后网络探测本身稳定" "$(value "$STATUS" network)" "ok"
check "没有额外 IP 变化通知" "$(grep -c '^出口 IP 变化|' "$NOTIFY_LOG" 2>/dev/null || true)" "1"

printf '%s\n' '⑧ 已有检测锁时跳过，不覆盖状态'
BEFORE=$(cat "$STATUS")
HISTORY_BEFORE=$(wc -l <"$HISTORY" | tr -d ' ')
mkdir "$LOCK_DIR"
set_sample "$OLD_IP" "$OLD_IP" "$OLD_IP"
run_sample || true
rmdir "$LOCK_DIR"
check "锁冲突不改快照" "$(cat "$STATUS")" "$BEFORE"
check "日志记录跳过" "$(grep -c '已有出口检测正在运行，本次跳过' "$LOG" || true)" "1"
check "锁冲突不写历史" "$(wc -l <"$HISTORY" | tr -d ' ')" "$HISTORY_BEFORE"

printf '%s\n' '⑨ 分路历史和状态写入均不残留临时文件'
check "共记录 10 次真实检测" "$(wc -l <"$HISTORY" | tr -d ' ')" "10"
check "记录两次接口失败" "$(awk -F'|' '$3 == "failure" {n++} END {print n+0}' "$HISTORY")" "2"
check "只标记一次已确认换 IP" "$(awk -F'|' '$5 == 1 {n++} END {print n+0}' "$HISTORY")" "1"
TMP_COUNT=$(find "$TEST_DIR" -maxdepth 1 -name '*.tmp.*' | wc -l | tr -d ' ')
check "没有临时文件残留" "$TMP_COUNT" "0"

printf '%s\n' '⑩ 同一 IP 的时区变化连续两次才接受'
STABLE_TIMEZONE="America/Los_Angeles"
SNAP_GFWTZ="America/Los_Angeles"
PENDING_TIMEZONE=""; PENDING_TZ_COUNT=0; TIMEZONE_DETAIL=""
confirm_timezone_candidate "$NEW_IP" "$NEW_IP" "America/New_York" || true
check "第一次时区跳变沿用旧值" "$CONFIRMED_TIMEZONE" "America/Los_Angeles"
check "记录时区候选 1/2" "$PENDING_TZ_COUNT" "1"
check "给出时区复核提示" "$(echo "$TIMEZONE_DETAIL" | grep -c '复核中')" "1"
confirm_timezone_candidate "$NEW_IP" "$NEW_IP" "America/New_York" || true
check "第二次相同结果才接受" "$CONFIRMED_TIMEZONE" "America/New_York"
check "更新稳定时区" "$STABLE_TIMEZONE" "America/New_York"
check "时区候选计数清零" "$PENDING_TZ_COUNT" "0"


printf '%s\n' '⑪ 辅助探针失败时，只更新建议时区，不修改系统时区'
TZ_ONLY_IP="9.8.7.6"
set_sample "" "" "$TZ_ONLY_IP"
MOCK_TZ="America/New_York"
MOCK_CURRENT_TZ="America/Los_Angeles"
run_sample || true
check "第一次权威出口变化只复核" "$(value "$STATUS" timezone_ip)" "$NEW_IP"
check "记录权威出口确认 1/2" "$(value "$PROBE_STATE" pending_timezone_ip_count)" "1"
check "第一次不修改系统时区" "$MOCK_CURRENT_TZ" "America/Los_Angeles"
run_sample || true
check "第二次独立确认权威出口" "$(value "$STATUS" timezone_ip)" "$TZ_ONLY_IP"
check "辅助探针波动时仍更新出口时区" "$(value "$STATUS" gfwtz)" "America/New_York"
check "系统时区保持原值" "$MOCK_CURRENT_TZ" "America/Los_Angeles"
check "快照正确展示时区不一致" "$(value "$STATUS" timezone_synced)" "0"

printf '%s\n' '⑫ 系统时区被外部改动后，下一轮检测仍保留用户设置'
MOCK_CURRENT_TZ="Asia/Shanghai"
run_sample || true
check "相同权威出口不自动纠偏" "$MOCK_CURRENT_TZ" "Asia/Shanghai"
check "快照仍展示时区不一致" "$(value "$STATUS" timezone_synced)" "0"
check "默认模式没有时区修改调用" "$([[ ! -s "$APPLY_LOG" ]] && echo yes)" "yes"

printf '%s\n' '⑬ 明确不支持地区只展示出口时区，不自动修改系统时区'
MOCK_COUNTRY=CN; MOCK_TZ=Asia/Shanghai; MOCK_CURRENT_TZ=America/New_York
run_sample || true
run_sample || true
check "不支持地区保留系统时区" "$MOCK_CURRENT_TZ" "America/New_York"
check "状态解释不自动修改" "$(value "$STATUS" timezone_detail | grep -c '不自动修改' || true)" "1"

printf '%s\n' '⑭ 明确确认的修复只在本次执行，不影响后续检测'
MODE=apply; REPAIR_CONFIRMED=1
MOCK_COUNTRY=US; MOCK_TZ=America/New_York; MOCK_CURRENT_TZ=Asia/Shanghai
run_sample || true
run_sample || true
check "确认后允许修改时区（模拟）" "$MOCK_CURRENT_TZ" "America/New_York"
MODE=check; REPAIR_CONFIRMED=0
MOCK_CURRENT_TZ=Asia/Taipei
run_sample || true
check "后续检测不延续修复许可" "$MOCK_CURRENT_TZ" "Asia/Taipei"

printf '%s\n' '⑮ 部分失败时，保留本轮证据，不沿用历史一致'
set_sample "$OLD_IP" "" ""
run_sample || true
check "只有一路成功，结论未知" "$(value "$STATUS" consistent)" unknown
check "失败路不展示历史 IP" "$(value "$STATUS" intl)/$(value "$STATUS" gfw)" "?/?"
check "部分失败标记" "$(value "$STATUS" probe_complete)" 0
set_sample "$OLD_IP" "$NEW_IP" ""
run_sample || true
check "两路不同立即展示分流" "$(value "$STATUS" consistent)" 0
check "展示本轮两路 IP" "$(value "$STATUS" cn)/$(value "$STATUS" intl)" "$OLD_IP/$NEW_IP"
set_sample "$OLD_IP" "$OLD_IP" ""
run_sample || true
check "两路相同但缺一路不能认定一致" "$(value "$STATUS" consistent)" unknown
set_sample "" "" ""
run_sample || true
check "全部失败不能认定一致" "$(value "$STATUS" consistent)" unknown
set_sample "$NEW_IP" "$NEW_IP" "$NEW_IP"
run_sample || true
run_sample || true
check "三路成功相同才认定一致" "$(value "$STATUS" consistent)/$(value "$STATUS" probe_complete)" "1/1"

printf '%s\n' '⑯ 本轮地区确认状态与历史时区分离'
MODE=check; REPAIR_CONFIRMED=0
MOCK_CURRENT_TZ=Asia/Taipei; MOCK_COUNTRY=US; MOCK_TZ=America/Chicago
set_sample "$OLD_IP" "$OLD_IP" "$OLD_IP"
run_sample || true; run_sample || true
check "先建立 Chicago 地区基线" "$(value "$STATUS" region_state)/$(value "$STATUS" gfwtz)" "ok/America/Chicago"
MOCK_TZ=Asia/Taipei; set_sample "$NEW_IP" "$NEW_IP" "$NEW_IP"
run_sample || true
check "换出口第一轮隐藏历史城市" "$(value "$STATUS" region_state)" verifying
check "历史时区保留为参考" "$(value "$STATUS" gfwtz)" America/Chicago
run_sample || true
check "第二轮确认 Taipei" "$(value "$STATUS" region_state)/$(value "$STATUS" gfwtz)" "ok/Asia/Taipei"
MOCK_TZ=""
run_sample || true
check "本轮时区情报失败不能显示旧城市" "$(value "$STATUS" region_state)" unknown
set_sample "$NEW_IP" "$NEW_IP" ""
run_sample || true
check "第三路失败，地区待确认" "$(value "$STATUS" region_state)" unknown
check "地区失败保留确认时间供历史参考" "$([[ -n "$(value "$STATUS" region_last_success)" ]] && echo yes)" yes
check "上述检测不改系统时区" "$MOCK_CURRENT_TZ" Asia/Taipei

printf '%s\n' '⑰ 手动等待检测锁，后台仍跳过'
(
  WAIT_FOR_LOCK=1
  mkdir "$LOCK_DIR"
  sleep() { rmdir "$LOCK_DIR"; }
  acquire_lock || exit 1
  [[ -d "$LOCK_DIR" ]] || exit 1
  release_lock
) || FAIL=1

printf '%s\n' '⑱ 六秒慢响应允许成功，使用真实参数解析的离线桩'
(
  curl() {
    local connect=0 maximum=0 output=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --connect-timeout) connect="$2"; shift ;;
        --max-time) maximum="$2"; shift ;;
        -o) output="$2"; shift ;;
      esac
      shift
    done
    [[ "$connect" == 10 && "$maximum" == 12 ]] || return 28
    sleep 6
    printf '%s\n' 5.6.7.8 >"$output"
    printf '%s\n' '0.010|6.000|6.010|6.020|200'
  }
  result=$(get_first_ip https://offline.test/ip) || exit 1
  [[ "$result" == '5.6.7.8|0.010|6.000|6.010|6.020000|200' ]] || exit 1
) && echo '  ✓ 六秒响应成功，参数为连接 10 秒 / 总计 12 秒' || FAIL=1

if [[ $FAIL -eq 0 ]]; then
  echo
  echo "全部通过"
else
  echo
  echo "存在失败"
fi
exit $FAIL
