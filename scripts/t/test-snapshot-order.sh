#!/bin/sh
# 黑盒测试：快照编号与排序契约（v0.3.5 修复）。
# 背景：next_snap_name 原为「找第一个空缺编号」，prune 删除后编号被重用；
# rescue_snapshot_list 为字典序，取「最新」用 tail 时，补位编号会让旧快照被当成最新 ——
# diagnose/supervise 据此选 baseline，会回滚到错误基线。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB="$ROOT/scripts/librescue.sh"
[ -f "$LIB" ] || { echo "FAIL librescue missing"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME/profiles/web"
printf %s '{"name":"web"}' > "$DSH_HOME/profiles/web/package.json"
RESCUE_PROFILE=web
RESCUE_KEEP=2
. "$LIB"
R=$RESCUE_DIR

fail() { echo "FAIL-$1"; exit 1; }

# 手工造快照：snap-0001 是「最新」（补位编号），snap-0006 是旧快照
mk_snap() { d="$R/snap-$1"; mkdir -p "$d"; printf '{"created":"%s","reason":"%s","dsh":"x"}' "$2" "$3" > "$d/meta.json"; printf x > "$d/package.json"; }
mk_snap 0001 "2026-09-10T11:13:05+0800" "boot-healthy baseline"
mk_snap 0006 "2026-09-08T13:00:42+08:00" "selfheal-rollback snap-0005"

# 1) 编号不得重用空缺：最大号 6 -> 下一个必须是 7（red 阶段会得到 2）
next=$(next_snap_name)
[ "$next" = "snap-0007" ] || fail "next-snap-reuse:$next"

# 2) 「最新/最老」必须按创建时间判定，而非字典序
newest=$(basename "$(rescue_snapshot_newest)")
oldest=$(basename "$(rescue_snapshot_oldest)")
[ "$newest" = "snap-0001" ] || fail "newest-by-time:$newest"
[ "$oldest" = "snap-0006" ] || fail "oldest-by-time:$oldest"

# 3) prune 必须删「时间最老」而不是「编号最小」
#    加两个更旧的快照后（共 4 个，KEEP=2），保留的应是时间最新的两个：0001 与 0007
mk_snap 0007 "2026-09-10T12:00:00+0800" "newer"
mk_snap 0008 "2026-09-01T00:00:00+0800" "oldest"
rescue_prune
ls -1d "$R"/snap-* | xargs -n1 basename | sort > "$T/left"
printf 'snap-0001\nsnap-0007\n' > "$T/want"
diff -u "$T/want" "$T/left" > "$T/d" 2>&1 || { cat "$T/d"; fail prune-by-time; }

echo 'ALL-PASS'