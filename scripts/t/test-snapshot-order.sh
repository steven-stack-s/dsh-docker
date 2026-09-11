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
# 抢号现在会真正建出目录（原子性所需），本用例只验证编号，清理掉以免影响后面的排序断言
rm -rf "$R/snap-0007"

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

# 4) meta.created 只有秒级精度：同秒连拍时必须用目录 mtime 作为次键，
#    否则"最新/最老"会落到字典序（编号）上，prune 可能淘汰好的 baseline、留下现场快照。
rm -rf "$R"/snap-*
mk_snap 0011 "2026-01-01T00:00:00+0800" "tie-later"
mk_snap 0012 "2026-01-01T00:00:00+0800" "tie-earlier"
touch -t 202601010000.05 "$R/snap-0011"    # 实际更晚
touch -t 202601010000.01 "$R/snap-0012"    # 实际更早
n2=$(basename "$(rescue_snapshot_newest)")
o2=$(basename "$(rescue_snapshot_oldest)")
[ "$n2" = "snap-0011" ] || fail "same-second-newest-by-mtime:$n2"
[ "$o2" = "snap-0012" ] || fail "same-second-oldest-by-mtime:$o2"

# 5) 编号分配必须原子：两次调用不得给出同一个名字
#    （并发场景：entrypoint 的健康基线快照 与 用户 rescue plugin add 的预防性快照 会同时发生；
#     旧的"读最大号 -> +1 -> 返回"是 check-then-act，两边会选中同一个 snap-XXXX，
#     然后互相覆盖/报 File exists，meta 还可能丢失导致时间序判定退化）
rm -rf "$R"/snap-*
a=$(next_snap_name)
b=$(next_snap_name)
[ "$a" = "snap-0001" ] || fail "atomic-first-name:$a"
[ "$b" = "snap-0002" ] || fail "atomic-second-name:$b"
[ "$a" != "$b" ] || fail atomic-collision

echo 'ALL-PASS'