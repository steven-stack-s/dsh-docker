#!/bin/sh
# 黑盒测试：rescue 命令集入口（snapshot / rollback / status）。
# 复用任务 1 思路：临时 DSH_HOME + trap 清理，以 `sh rescue ...` 调用真实入口。
# 仅操作用户 profile 插件树与 .rescue 目录，不动真实数据。
set -eu

# 定位仓库根（test 位于 scripts/t/ -> 上溯两级）与 rescue 入口
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RESCUE="$ROOT/rescue"
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

echo 'ALL-PASS'
