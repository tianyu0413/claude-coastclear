#!/bin/bash
# 修复许可回归：完全离线，所有管理员命令均用记录函数代替。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-consent.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
export CC_DATA_DIR="$TEST_DIR/data"
export CC_NETWORK_SELFTEST=1
for mode in '' --check --once --force --dry-run --yes --wait-lock; do
  (
    if [[ -n "$mode" ]]; then source "$ROOT/cc-network.sh" "$mode"; else source "$ROOT/cc-network.sh"; fi
    cc_admin() { echo "unexpected mutation" >>"$TEST_DIR/admin-calls"; }
    set_timezone America/New_York && exit 1
    [[ ! -s "$TEST_DIR/admin-calls" ]]
  )
done
echo '✓ 默认、后台、兼容参数、预览及单独 --yes 均不能修改时区'
(
  source "$ROOT/cc-network.sh" --apply-timezone
  cc_admin() { echo "$*" >>"$TEST_DIR/admin-calls"; }
  set_timezone America/New_York && exit 1
  if cc_confirm '测试：不应弹出授权' </dev/null; then exit 1; fi
  [[ ! -s "$TEST_DIR/admin-calls" ]]
  REPAIR_CONFIRMED=1
  set_timezone America/New_York
  [[ $(wc -l <"$TEST_DIR/admin-calls" | tr -d ' ') == 1 ]]
)
echo '✓ 未确认或非交互输入拒绝修复；明确确认只执行模拟命令'
(
  export CC_CHECK_SELFTEST=1
  source "$ROOT/cc-check.sh" --fix
  active_service() { echo 'unexpected mutation' >>"$TEST_DIR/unconfirmed-fix"; }
  apply_fixes && exit 1
  [[ ! -e "$TEST_DIR/unconfirmed-fix" ]]
)
echo '✓ 未确认的完整修复在访问网络配置前拒绝执行'
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
r=Path(sys.argv[1]);s=(r/'menubar/StatusApp.swift').read_text()
def body(start,end): return s[s.index(start):s.index(end,s.index(start))]
launch=body('    func applicationDidFinishLaunching','    // 当前检测间隔')
timer=body('    func startScanTimer','    @objc func setInterval')
quit=body('    @objc func quit()', '// 浏览器端信号采集')
assert 'runScript(["--check"], isScan: true)' in launch
assert 'runScript(["--check"], isScan: true)' in timer
assert 'NSApp.terminate(nil)' in quit
for token in ['--fix','--apply-timezone','defaults write','launchctl','moveItem','UserDefaults.standard.set']:
 assert token not in launch+timer+quit, token
fix=body('    @objc func runClaudeFix()', '    @objc func runCheck()')
assert fix.index('guard response == .alertFirstButtonReturn') < fix.index('runScript(["--fix", "--yes"]')
assert 'fm.moveItem' not in s and 'prepareLaunchAgentForRealQuit' not in s
print('✓ 启动与定时任务仅检测，退出不改启动项，修复在确认之后调用')
PY
echo '全部通过'
