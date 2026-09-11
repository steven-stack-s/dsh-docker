#!/bin/sh
set -eu
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME/profiles/web/node_modules/demo-pkg"
printf '%s' '{"name":"web","dependencies":{"demo":"1.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
printf 'lock v1\n' > "$DSH_HOME/profiles/web/pnpm-lock.yaml"
echo hi > "$DSH_HOME/profiles/web/node_modules/demo-pkg/index.js"
. "$(dirname "$0")/../librescue.sh"

s1=$(rescue_snapshot)
[ "$s1" = "snap-0001" ] || { echo FAIL-snapname; exit 1; }
[ -d "$DSH_HOME/.rescue/snap-0001/node_modules/demo-pkg" ] || { echo FAIL-tree; exit 1; }
i1=$(stat -c%i "$DSH_HOME/profiles/web/node_modules/demo-pkg/index.js")
i2=$(stat -c%i "$DSH_HOME/.rescue/snap-0001/node_modules/demo-pkg/index.js")
[ "$i1" = "$i2" ] || { echo FAIL-hardlink; exit 1; }

printf '%s' '{"name":"web","dependencies":{"demo":"2.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
[ "$(rescue_live_differs_from snap-0001)" = 1 ] || { echo FAIL-differs; exit 1; }
rescue_restore snap-0001
[ "$(rescue_live_differs_from snap-0001)" = 0 ] || { echo FAIL-restore; exit 1; }

export RESCUE_KEEP=1
s2=$(rescue_snapshot)
[ "$s2" = "snap-0002" ] || { echo FAIL-snap2; exit 1; }
[ ! -d "$DSH_HOME/.rescue/snap-0001" ] || { echo FAIL-prune; exit 1; }

# ---- regression: rollback target must survive a scene snapshot (entrypoint RB_TARGET 模式) ----
# rescue_snapshot/rescue_restore 都覆盖全局 $snap；自愈回滚若用 $snap 存目标，
# 拍“现场快照”后目标会被改写，rescue_restore 就会错误恢复现场(坏)快照而非预期基线。
export RESCUE_KEEP=5
printf '%s' '{"name":"web","dependencies":{"demo":"1.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
RB_TARGET=$(rescue_snapshot)                       # 期望回滚到的基线快照名（存于独立变量）
printf '%s' '{"name":"web","dependencies":{"demo":"9.9.9"}}' > "$DSH_HOME/profiles/web/package.json"
REASON_SNAPSHOT="selfheal-rollback $RB_TARGET" rescue_snapshot >/dev/null 2>&1   # 现场快照(坏)
rescue_restore "$RB_TARGET"                        # 应恢复基线(1.0.0)，而非刚建的现场快照
grep -q '"demo":"1.0.0"' "$DSH_HOME/profiles/web/package.json" || { echo FAIL-rollback-collision; exit 1; }
echo ALL-PASS
