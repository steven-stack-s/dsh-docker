#!/bin/sh
# ============================================================================
# test-selfheal-budget.sh — 自愈预算的生命周期（窗口 + 可观测 + 可重置）
#
# 背景（P0-2）：预算状态写在数据卷 `state/selfheal.json`，跨容器重启累计且**永不重置**——
# 用满 2 次摘插件 + 2 次回快照后，该部署此后所有重启都只能 report-only，而文档写的是
# "单容器生命周期内"，用户完全看不出自愈已经失效。
#
# 契约：
#   1. 无状态文件：计数从 0 开始，窗口起点为现在
#   2. 窗口内：计数保持
#   3. 窗口过期（RESCUE_SELFHEAL_WINDOW）：计数自动清零，重新获得自愈能力
#   4. 写回时带上 windowStart
#   5. CLI：rescue selfheal status 可读、rescue selfheal reset 可重置
#
# 用法: sh scripts/t/test-selfheal-budget.sh    （全通过打印 ALL-PASS）
# ============================================================================
set -u
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)

export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME"
. "$HERE/../librescue.sh"
state="$DSH_HOME/.rescue/state/selfheal.json"
fail() { echo "FAIL-$1"; exit 1; }

# ---- 1) 无状态文件 ----
rescue_budget_read
[ "$SELFHEAL_REMOVES" = 0 ] || fail fresh-removes
[ "$SELFHEAL_ROLLBACKS" = 0 ] || fail fresh-rollbacks
[ -n "$SELFHEAL_WINDOW_START" ] || fail fresh-window-start

# ---- 2) 窗口内：计数保持 ----
mkdir -p "$(dirname "$state")"
now=$(date +%s)
printf '{"removes":2,"rollbacks":1,"windowStart":"%s"}' "$(date -d "@$((now - 3600))" '+%Y-%m-%dT%H:%M:%S%z')" > "$state"
RESCUE_SELFHEAL_WINDOW=86400 rescue_budget_read
[ "$SELFHEAL_REMOVES" = 2 ] || fail in-window-removes-kept
[ "$SELFHEAL_ROLLBACKS" = 1 ] || fail in-window-rollbacks-kept

# ---- 3) 窗口过期：计数自动清零（自愈能力恢复）----
printf '{"removes":2,"rollbacks":1,"windowStart":"%s"}' "$(date -d "@$((now - 90000))" '+%Y-%m-%dT%H:%M:%S%z')" > "$state"
RESCUE_SELFHEAL_WINDOW=86400 rescue_budget_read
[ "$SELFHEAL_REMOVES" = 0 ] || fail expired-window-removes-reset
[ "$SELFHEAL_ROLLBACKS" = 0 ] || fail expired-window-rollbacks-reset

# ---- 4) 写回带 windowStart ----
SELFHEAL_REMOVES=1; SELFHEAL_ROLLBACKS=0; SELFHEAL_WINDOW_START="$(rescue_ts)"
rescue_budget_write
grep -q '"windowStart":"' "$state" || fail write-window-start
grep -q '"removes":1' "$state" || fail write-removes

# ---- 5) CLI status / reset ----
st=$(sh "$ROOT/scripts/rescue" selfheal status) || fail status-rc
echo "$st" | grep -q 'removes=' || { echo "$st"; fail status-format; }
sh "$ROOT/scripts/rescue" selfheal reset >/dev/null || fail reset-rc
rescue_budget_read
[ "$SELFHEAL_REMOVES" = 0 ] || fail reset-not-cleared
sh "$ROOT/scripts/rescue" selfheal >/dev/null 2>&1 && fail unknown-subcommand-must-fail

echo ALL-PASS
