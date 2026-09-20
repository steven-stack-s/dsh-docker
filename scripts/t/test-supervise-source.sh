#!/bin/sh
# 黑盒测试：rescue-supervise.sh 的 source 契约（方案 A 拆分后守护）。
# 在 set -u 环境下按 entrypoint 的顺序 source librescue + supervise，
# 验证：无未定义变量、监督编排函数全部可调用、rescue_supervise 存在。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB="$ROOT/scripts/librescue.sh"
SUP="$ROOT/scripts/rescue-supervise.sh"
[ -f "$LIB" ] || { echo "FAIL librescue missing: $LIB"; exit 1; }
[ -f "$SUP" ] || { echo "FAIL supervise missing: $SUP"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME/profiles/web"
printf '%s' '{"name":"web"}' > "$DSH_HOME/profiles/web/package.json"

# entrypoint 在 source 前提供的环境
elog() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
RESCUE_PROFILE=web; RESCUE_KEEP=3; RESCUE_START_TIMEOUT=2
RESCUE_AUTO=on; RESCUE_SELFHEAL=on; RESCUE_REMOVE_LIMIT=2; RESCUE_ROLLBACK_LIMIT=2
RESCUE_DIAGNOSE_EVIDENCE=on; RESCUE_INCIDENT_KEEP=20
PORT_INNER=3081; TRUSTED_ARGS=""
RESCUE_DIAG=""; LOGTAG=""; LOGTEE=""
RESCUE_EVIDENCE_MAX=1000000
# probe 存在性由调用方（entrypoint）保证；此处只验证 source 契约，不跑监督循环。

. "$LIB"
. "$SUP"

fail() { echo "FAIL-$1"; exit 1; }

# 监督编排函数应全部存在
for fn in rescue_ts attempt_evdir rescue_start_child rescue_close_ev rescue_evidence_prune   rescue_diagnose rescue_write_incident rescue_write_runtime_incident rescue_budget_read   rescue_budget_write rescue_journal_add rescue_budget_check rescue_do_heal rescue_supervise; do
  command -v "$fn" >/dev/null 2>&1 || fail "function-missing:$fn"
done

# 救生舱态判定与崩溃证据读取（问题 1/2）：rescue CLI 与 entrypoint 都依赖它们，
# 缺失时 rescue status/doctor 会整段失效 —— 而救生舱里正是最需要这段输出的时候。
for fn in rescue_mode rescue_lastboot_tail rescue_lifeboat_guidance; do
  command -v "$fn" >/dev/null 2>&1 || fail "function-missing:$fn"
done
[ "$(rescue_mode)" = normal ] || fail "rescue_mode-default-should-be-normal"
[ "$(RESCUE=1 rescue_mode)" = lifeboat ] || fail "rescue_mode-RESCUE=1"
[ "$(RESCUE_PROFILE=lifeboat rescue_mode)" = lifeboat ] || fail "rescue_mode-lifeboat-profile"
# 证据文件缺失时必须静默返回（只读诊断不得因此报错），存在时按请求行数回吐尾部
rescue_lastboot_tail 40 >/dev/null 2>&1 || fail "rescue_lastboot_tail-must-not-fail-without-file"
mkdir -p "$RESCUE_DIR"
printf 'a\nb\nc\n' > "$LASTBOOT_FILE"
[ "$(rescue_lastboot_tail 2)" = "$(printf 'b\nc')" ] || fail "rescue_lastboot_tail-wrong-tail"
rm -f "$LASTBOOT_FILE"
[ -z "$(rescue_lastboot_tail 2)" ] || fail "rescue_lastboot_tail-missing-file-not-empty"
rescue_lifeboat_guidance | grep -q 'LIFEBOAT MODE' || fail "guidance-missing-marker"
rescue_lifeboat_guidance | grep -q 'docker restart dsh' || fail "guidance-missing-restart-cmd"

# 纯函数抽查：时间戳格式 / budget 读自空 state / journal 追加
ts=$(rescue_ts)
echo "$ts" | grep -qE '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}\+[0-9]{4}$' || fail "rescue_ts-format:$ts"
mkdir -p "$(state_dir)"
rescue_budget_read
[ "$SELFHEAL_REMOVES" = 0 ] || fail "budget-removes-init"
SELFHEAL_JOURNAL="$T/j"; printf '' > "$SELFHEAL_JOURNAL"
rescue_journal_add boot probe-timeout test
grep -q 'boot|probe-timeout|' "$SELFHEAL_JOURNAL" || fail "journal-add"

# do_heal 在无 target / 空快照时应保守返回非0（不误改树）
heal_rc=0
rescue_do_heal remove-plugin "" 2>/dev/null && heal_rc=1 || heal_rc=0
[ "$heal_rc" = 0 ] || fail "do_heal-empty-target"

echo 'ALL-PASS'
