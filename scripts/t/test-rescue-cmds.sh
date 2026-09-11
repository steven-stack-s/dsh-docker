#!/bin/sh
# 黑盒测试：rescue 命令集入口（snapshot / rollback / status）。
# 复用任务 1 思路：临时 DSH_HOME + trap 清理，以 `sh rescue ...` 调用真实入口。
# 仅操作用户 profile 插件树与 .rescue 目录，不动真实数据。
set -eu

# 定位仓库根（test 位于 scripts/t/ -> 上溯两级）与 rescue 入口
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RESCUE="$ROOT/scripts/rescue"
[ -f "$RESCUE" ] || { echo "FAIL rescue not found: $RESCUE"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME/profiles/web/node_modules/demo-pkg"
# 构造一个可快照的 profile（含四件套里被 librescue 关注的 package.json / pnpm-lock.yaml）
printf '%s' '{"name":"web","dependencies":{"demo":"1.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
printf 'lock v1\n' > "$DSH_HOME/profiles/web/pnpm-lock.yaml"
echo hi > "$DSH_HOME/profiles/web/node_modules/demo-pkg/index.js"

# 注意：librescue.sh 在 source 时读取 DSH_HOME，故 DSH_HOME 已在上面 export。
# rescue snapshot 内含 `dsh --version 2>/dev/null || echo unknown`，无 dsh 也可通过。

fail() { echo "FAIL-$1"; exit 1; }

# --- snapshot: 应建出 snap-0001，并把 package.json 复制进去 ---
out=$(sh "$RESCUE" snapshot)
[ -d "$DSH_HOME/.rescue/snap-0001/package.json" ] || { [ -f "$DSH_HOME/.rescue/snap-0001/package.json" ] || fail snapshot-dir; }
[ -f "$DSH_HOME/.rescue/snap-0001/package.json" ] || fail snapshot-file
grep -q 'demo\":\"1.0.0' "$DSH_HOME/.rescue/snap-0001/package.json" || fail snapshot-content

# --- tamper + rollback: 篡改 live package.json 后 rollback 应还原 ---
printf '%s' '{"name":"web","dependencies":{"demo":"2.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
out2=$(sh "$RESCUE" rollback)
echo "$out2" | grep -q 'restored snap-0001' || fail rollback-msg
grep -q 'demo\":\"1.0.0' "$DSH_HOME/profiles/web/package.json" || fail rollback-restore

# --- status: 输出应含 RESCUE_DIR 与 snap 列表 ---
out3=$(sh "$RESCUE" status)
echo "$out3" | grep -q "RESCUE_DIR=$DSH_HOME/.rescue" || fail status-rescue-dir
echo "$out3" | grep -q 'snap-0001' || fail status-snap-list


# --- snapshot --reason: meta 记 reason（变更上下文）---
sh "$RESCUE" snapshot --reason 'plugin add @scope/demo' >/dev/null
grep -q '"reason":"plugin add @scope/demo"' "$DSH_HOME/.rescue/snap-0002/meta.json" || fail snapshot-reason
[ -f "$DSH_HOME/.rescue/snap-0002/meta.json" ] || fail snapshot-reason-file

# --- incident list: 列出 incidents 目录里的文件 ---
mkdir -p "$DSH_HOME/.rescue/incidents"
printf '%s' '{"id":"inc-TEST","phase":"boot"}' > "$DSH_HOME/.rescue/incidents/inc-TEST.json"
il=$(sh "$RESCUE" incident list)
echo "$il" | grep -q 'inc-TEST' || fail incident-list

# --- report: 输出含标题与 incident ---
rep=$(sh "$RESCUE" report)
echo "$rep" | grep -q 'DSH rescue report' || fail report-title
echo "$rep" | grep -q 'inc-TEST' || fail report-incident

# --- doctor（增强，Fix 2）---
mkdir -p "$DSH_HOME/.rescue/state" "$DSH_HOME/.rescue/evidence"
printf '%s' '{"phase":"healthy","ts":"x","abnormalExit":false}' > "$DSH_HOME/.rescue/state/last-run.json"
doc=$(sh "$RESCUE" doctor)
echo "$doc" | grep -q 'incidents dir ok' || { echo "doc=$doc"; fail doctor-incidents; }
echo "$doc" | grep -q 'evidence dir ok' || fail doctor-evidence
echo "$doc" | grep -q 'state dir ok' || fail doctor-state
echo "$doc" | grep -q 'last run: phase=healthy' || { echo "doc=$doc"; fail doctor-lastrun; }

# --- verify: 完好快照必须通过（快照完整性 P0-6）---
if ! sh "$RESCUE" verify >/tmp/rescue-verify.out 2>&1; then
  cat /tmp/rescue-verify.out
  fail verify-fresh-snapshots
fi
# --- verify: live 被就地改写（硬链接共享 inode）后，快照已不可信，必须报错 ---
printf 'tamper-after-snapshot\n' >> "$DSH_HOME/profiles/web/node_modules/demo-pkg/index.js"
if sh "$RESCUE" verify >/tmp/rescue-verify2.out 2>&1; then
  cat /tmp/rescue-verify2.out
  fail verify-missed-pollution
fi
echo "$(cat /tmp/rescue-verify2.out)" | grep -q 'snap-000' || fail verify-no-detail

# --- snapshots: 列表必须带"与 live 相同/不同"标记（P1-4：用户要能分辨哪个可用）---
sn=$(sh "$RESCUE" snapshots)
echo "$sn" | grep -q 'snap-0001' || { echo "$sn"; fail snapshots-list; }
echo "$sn" | grep -qE 'SAME|differs' || { echo "$sn"; fail snapshots-live-marker; }

# --- rollback --dry-run 不得改动任何东西 ---
printf '%s' '{"name":"web","dependencies":{"demo":"9.9.9"}}' > "$DSH_HOME/profiles/web/package.json"
dr=$(sh "$RESCUE" rollback --dry-run) || fail rollback-dryrun-rc
echo "$dr" | grep -q 'dry-run' || { echo "$dr"; fail rollback-dryrun-msg; }
grep -q '9.9.9' "$DSH_HOME/profiles/web/package.json" || fail rollback-dryrun-mutated-live

# --- rollback --to 不存在的快照 -> 非 0 ---
sh "$RESCUE" rollback --to snap-9999 >/dev/null 2>&1 && fail rollback-to-missing-must-fail

# --- rollback --to 一个与 live 完全相同的快照 -> 必须拒绝（否则会把空操作记成"已恢复"）---
sh "$RESCUE" snapshot >/dev/null
same=$(sh "$RESCUE" snapshots | grep -E 'SAME' | head -n1 | awk '{print $1}')
[ -n "$same" ] || fail snapshots-no-same-detected
if sh "$RESCUE" rollback --to "$same" >/tmp/rb-noop.out 2>&1; then
  cat /tmp/rb-noop.out; fail rollback-to-noop-must-fail
fi

# --- rollback（无参）必须跳过与 live 相同的快照，挑真正不同的那个 ---
out=$(sh "$RESCUE" rollback) || { echo "$out"; fail rollback-auto-rc; }
echo "$out" | grep -q 'restored snap-' || { echo "$out"; fail rollback-auto-msg; }
grep -q '1.0.0' "$DSH_HOME/profiles/web/package.json" || fail rollback-auto-restored-differing-snapshot

# --- export: 生成诊断包，且只含救援元数据（不含插件树/会话/密钥）---
exp="$T/bundle.tar.gz"
sh "$RESCUE" export "$exp" >/dev/null || fail export-rc
[ -f "$exp" ] || fail export-no-file
tl=$(tar -tzf "$exp")
echo "$tl" | grep -q 'environment.txt' || { echo "$tl"; fail export-no-env; }
echo "$tl" | grep -q 'incidents/' || { echo "$tl"; fail export-no-incidents; }
echo "$tl" | grep -q 'node_modules' && { echo "$tl"; fail export-must-not-contain-node-modules; }
echo "$tl" | grep -qi 'sk-' && { echo "$tl"; fail export-must-not-contain-secrets; }

echo 'ALL-PASS'
