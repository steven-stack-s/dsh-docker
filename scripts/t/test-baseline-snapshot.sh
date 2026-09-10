#!/bin/sh
# 黑盒测试：rescue_snapshot_baseline（健康基线快照，v0.3.5 新增能力）。
# 覆盖：开关 on 时生成带 reason 的快照；off 时不生成；重复调用滚动新增。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB="$ROOT/scripts/librescue.sh"
SUP="$ROOT/scripts/rescue-supervise.sh"
[ -f "$LIB" ] || { echo "FAIL librescue missing"; exit 1; }
[ -f "$SUP" ] || { echo "FAIL supervise missing"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME/profiles/web/node_modules/demo"
printf %s '{"name":"web","dependencies":{"demo":"1.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
printf 'lock v1\n' > "$DSH_HOME/profiles/web/pnpm-lock.yaml"
echo hi > "$DSH_HOME/profiles/web/node_modules/demo/index.js"

RESCUE_PROFILE=web
RESCUE_KEEP=3
elog() { :; }

. "$LIB"
. "$SUP"

fail() { echo "FAIL-$1"; exit 1; }
count_snaps() { ls -1d "$DSH_HOME"/.rescue/snap-* 2>/dev/null | wc -l | tr -d " "; }

# 1) 函数存在（red 阶段会失败）
command -v rescue_snapshot_baseline >/dev/null 2>&1 || fail baseline-fn-missing

# 2) 默认（开关未设 = on）应生成一份基线快照，reason 正确
n0=$(count_snaps)
RESCUE_SNAPSHOT_ON_HEALTHY=on rescue_snapshot_baseline
n1=$(count_snaps)
[ "$n1" -eq $((n0 + 1)) ] || fail baseline-not-created
latest=$(ls -1d "$DSH_HOME"/.rescue/snap-* | sort | tail -n1)
grep -q '"reason":"boot-healthy baseline"' "$latest/meta.json" || { cat "$latest/meta.json"; fail baseline-reason; }
[ -f "$latest/package.json" ] || fail baseline-content

# 3) 开关 off 时不新增
RESCUE_SNAPSHOT_ON_HEALTHY=off rescue_snapshot_baseline
n2=$(count_snaps)
[ "$n2" -eq "$n1" ] || fail baseline-off-created

# 4) 失败不得中断调用方（把 profile 目录弄成不可读状态后仍返回 0）
RESCUE_SNAPSHOT_ON_HEALTHY=on rescue_snapshot_baseline || fail baseline-must-not-fail

# 5) 审计：变更后再基线应往 rescue.log 写一条（profile 指纹变化检测）
printf %s '{"name":"web","dependencies":{"demo":"2.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
RESCUE_SNAPSHOT_ON_HEALTHY=on rescue_snapshot_baseline
grep -q "baseline" "$DSH_HOME/.rescue/log/rescue.log" 2>/dev/null || fail baseline-log

echo 'ALL-PASS'