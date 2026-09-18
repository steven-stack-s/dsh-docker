#!/bin/sh
# ============================================================================
# vercmp.sh — semver 比较（纯函数库；entrypoint 与 update-dsh-badge.sh 共用）
#
# 【为什么单独一个文件】这段逻辑有两个调用方，运行环境却完全不同：
#   - scripts/entrypoint.sh（容器内）：决定镜像 seed 是否覆盖 /opt/dsh 卷里的 dsh
#   - scripts/update-dsh-badge.sh（CI runner 上）：决定 README 的 DSH 版本徽章只升不降
# 两份实现一旦分叉，就会出现「徽章那边算升级、seed 这边算降级」这类极难察觉的不一致，
# 故收敛为一份（项目既有原则：同一份逻辑不留第二份实现，见 librescue.sh 的同类注释）。
#
# 【为什么不能用 sort -V 直接比】它把 "0.1.5" 排在 "0.1.5-rc.1" **之前**，于是 rc 转正
# （0.1.5-rc.1 → 0.1.5，release 时真会发生）会被误判成降级。按 semver §11：主版本相同时，
# 无预发布者更大。下方 ver_gt 显式处理了这一点。
#
# 【约定】本文件只定义函数、无顶层副作用，source 即用。
# ============================================================================

# ver_gt A B —— A 严格大于 B 时返回 0，否则返回非 0（相等、或 A 更小）。
# 支持 X.Y.Z 与 X.Y.Z-预发布；缺省段按 0 处理（"0.1" 等价 "0.1.0"）。
ver_gt() {
  _a=$1; _b=$2
  _am=${_a%%-*}; _ap=''
  case "$_a" in *-*) _ap=${_a#*-} ;; esac
  _bm=${_b%%-*}; _bp=''
  case "$_b" in *-*) _bp=${_b#*-} ;; esac

  _saved_ifs=$IFS
  IFS=.
  set -- $_am; _a1=${1:-0}; _a2=${2:-0}; _a3=${3:-0}
  set -- $_bm; _b1=${1:-0}; _b2=${2:-0}; _b3=${3:-0}
  IFS=$_saved_ifs

  if [ "$_a1" -gt "$_b1" ]; then return 0; fi
  if [ "$_a1" -lt "$_b1" ]; then return 1; fi
  if [ "$_a2" -gt "$_b2" ]; then return 0; fi
  if [ "$_a2" -lt "$_b2" ]; then return 1; fi
  if [ "$_a3" -gt "$_b3" ]; then return 0; fi
  if [ "$_a3" -lt "$_b3" ]; then return 1; fi

  # 主版本相同：无预发布者更大（0.1.6 > 0.1.6-alpha.2）
  if [ -z "$_ap" ] && [ -n "$_bp" ]; then return 0; fi
  if [ -n "$_ap" ] && [ -z "$_bp" ]; then return 1; fi
  if [ -z "$_ap" ]; then return 1; fi

  # 双方都有预发布：逐段比较（alpha.10 > alpha.9，不能被当字符串比）
  _top=$(printf '%s\n%s\n' "$_bp" "$_ap" | LC_ALL=C sort -V | tail -n 1)
  if [ "$_top" = "$_ap" ] && [ "$_ap" != "$_bp" ]; then return 0; fi
  return 1
}