#!/bin/sh
# 黑盒测试：prune 钉住「最新一份健康基线快照」。
# 背景：自愈选回退目标时第一轮只认 boot-healthy*（rescue_pick_rollback_target）——那是唯一
# 被证明能启动过的状态。而插件市场(dshmarket)/手工会不断产生变更快照，纯 FIFO 轮转会把基线
# 挤出 RESCUE_KEEP 窗口，自愈只能退化到第二轮的任意非现场快照（甚至 report-only）。
# 覆盖：①基线是最老一份时必须留下 ②没有基线时维持原 FIFO 逐出 ③多份基线只钉最新那份
#      ④全是基线时仍能减员（不死循环）⑤KEEP 已满足时不动任何快照。
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
. "$LIB"
R=$RESCUE_DIR

fail() { echo "FAIL-$1"; exit 1; }

# 手工造快照：$1=编号 $2=created $3=reason
mk_snap() {
  d="$R/snap-$1"
  mkdir -p "$d"
  printf '{"created":"%s","reason":"%s","dsh":"x","profile":"web","mode":"hardlink","treeHash":"t"}' "$2" "$3" > "$d/meta.json"
  printf x > "$d/package.json"
}
count_snaps() {
  c=0
  for d in "$R"/snap-*; do
    if [ -d "$d" ]; then c=$((c + 1)); fi
  done
  printf '%s' "$c"
}

# 1) 基线是最老一份（KEEP=2、共 3 份）：必须淘汰「次老的普通快照」，基线留下
rm -rf "$R"/snap-*
mk_snap 0001 "2026-09-10T11:00:00+0800" "boot-healthy baseline"
mk_snap 0002 "2026-09-10T12:00:00+0800" "plugin add alpha"
mk_snap 0003 "2026-09-10T13:00:00+0800" "plugin add beta"
RESCUE_KEEP=2
rescue_prune
[ -d "$R/snap-0001" ] || fail "pin-baseline-evicted"
[ ! -d "$R/snap-0002" ] || fail "prune-did-not-evict-second-oldest"
[ -d "$R/snap-0003" ] || fail "prune-evicted-newest"
[ "$(count_snaps)" = 2 ] || fail "keep-window-violated:$(count_snaps)"
grep -q 'prune .*snap-0002' "$R/log/rescue.log" 2>/dev/null || fail "prune-audit-missing"

# 2) 没有基线时行为不变：仍按时间最老逐出
rm -rf "$R"/snap-*
mk_snap 0010 "2026-09-10T11:00:00+0800" "plugin add a"
mk_snap 0011 "2026-09-10T12:00:00+0800" "plugin add b"
mk_snap 0012 "2026-09-10T13:00:00+0800" "plugin add c"
RESCUE_KEEP=2
rescue_prune
[ ! -d "$R/snap-0010" ] || fail "fifo-evicted-wrong"
if [ -d "$R/snap-0011" ] && [ -d "$R/snap-0012" ]; then :; else fail "fifo-kept-newest"; fi

# 3) 多份基线：只钉最新那份，更旧的基线照旧可被淘汰
rm -rf "$R"/snap-*
mk_snap 0020 "2026-09-10T10:00:00+0800" "boot-healthy baseline"
mk_snap 0021 "2026-09-10T11:00:00+0800" "plugin add x"
mk_snap 0022 "2026-09-10T12:00:00+0800" "boot-healthy baseline"
RESCUE_KEEP=2
rescue_prune
[ ! -d "$R/snap-0020" ] || fail "old-baseline-should-be-evictable"
[ -d "$R/snap-0022" ] || fail "newest-baseline-evicted"
[ -d "$R/snap-0021" ] || fail "middle-snapshot-evicted"

# 4) 全是基线：钉住不能让 prune 卡死或超员，仍保留最新一份
rm -rf "$R"/snap-*
mk_snap 0030 "2026-09-10T10:00:00+0800" "boot-healthy baseline"
mk_snap 0031 "2026-09-10T11:00:00+0800" "boot-healthy baseline"
mk_snap 0032 "2026-09-10T12:00:00+0800" "boot-healthy baseline"
RESCUE_KEEP=1
rescue_prune
[ "$(count_snaps)" = 1 ] || fail "all-baseline-prune-stuck:$(count_snaps)"
[ -d "$R/snap-0032" ] || fail "all-baseline-kept-wrong-one"

# 5) KEEP 已满足：不动任何快照
rm -rf "$R"/snap-*
mk_snap 0040 "2026-09-10T10:00:00+0800" "boot-healthy baseline"
mk_snap 0041 "2026-09-10T11:00:00+0800" "plugin add y"
RESCUE_KEEP=5
rescue_prune
[ "$(count_snaps)" = 2 ] || fail "noop-when-within-keep:$(count_snaps)"

echo ALL-PASS
