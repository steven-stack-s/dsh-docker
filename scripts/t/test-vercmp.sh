#!/bin/sh
# ============================================================================
# test-vercmp.sh — ver_gt（semver 比较）的语义门禁
#
# 为什么单独测：entrypoint 用 ver_gt 决定「镜像 seed 是否该覆盖 /opt/dsh 卷里的 dsh」，
# 而版本比较是**静默出错**的经典地带 —— 比错了不会报错，只会让 dsh 停留在旧版本（或把
# 用户的升级倒回去）。项目里已有一次教训：不能用 sort -V 直接比，它把 "0.1.5" 排在
# "0.1.5-rc.1" 之前，会把 rc 转正误判成降级（见 update-dsh-badge.sh 注释）。
#
# 本测试直接覆盖 ver_gt 本身；update-dsh-badge.sh 与 entrypoint 共用这一份实现。
# ============================================================================
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VERCMP="$ROOT/scripts/vercmp.sh"
[ -f "$VERCMP" ] || { echo 'FAIL vercmp.sh missing'; exit 1; }
. "$VERCMP"
command -v ver_gt >/dev/null 2>&1 || { echo 'FAIL ver_gt not defined by vercmp.sh'; exit 1; }

bad=0
gt()  { if ver_gt "$1" "$2"; then :; else echo "FAIL expect-gt: $1 > $2"; bad=1; fi; }
ngt() { if ver_gt "$1" "$2"; then echo "FAIL expect-not-gt: $1 <= $2"; bad=1; fi; }

# --- 本次升级的真实场景 ---
gt  0.1.6-alpha.2 0.1.6-alpha.1
ngt 0.1.6-alpha.1 0.1.6-alpha.2
# --- 相等 ---
ngt 0.1.6-alpha.2 0.1.6-alpha.2
ngt 0.1.5          0.1.5
# --- 正式版 > 同号预发布（rc 转正必须算升级）---
gt  0.1.6        0.1.6-alpha.2
gt  0.1.5        0.1.5-rc.1
ngt 0.1.6-alpha.2 0.1.6
ngt 0.1.5-rc.1   0.1.5
# --- 段位进位 ---
gt  0.1.6-alpha.1 0.1.5-rc.2
gt  0.2.0         0.1.9
gt  1.0.0         0.9.9
ngt 0.1.5-rc.2   0.1.6-alpha.1
# --- 预发布逐段（数值段不能被当字符串比）---
gt  0.1.6-alpha.10 0.1.6-alpha.9
ngt 0.1.6-alpha.9  0.1.6-alpha.10
ngt 0.1.6-alpha.1  0.1.6-beta.0
gt  0.1.6-beta.0   0.1.6-alpha.9

[ "$bad" -eq 0 ] || exit 1
echo 'ALL-PASS'