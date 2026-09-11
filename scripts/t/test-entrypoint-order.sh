#!/bin/sh
# ============================================================================
# test-entrypoint-order.sh — entrypoint 里"先用后 source"的静态检查
#
# 背景（真机验证发现的真实 bug）：librescue.sh 提供的函数只有在 source 之后才存在。entrypoint 里
# 曾经在 source 之前就调用 rescue_trusted_args / rescue_load_api_key —— `command -v` 判空后静默
# 跳过，于是"Host 白名单校验""凭据文件"这两项在真机上**完全没生效**，而单测（只测函数本身）全绿。
#
# 契约：scripts/entrypoint.sh 中所有 rescue_* 调用的行号必须晚于 librescue.sh 被 source 的行号。
# ============================================================================
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
EP="$ROOT/scripts/entrypoint.sh"
[ -f "$EP" ] || { echo "FAIL entrypoint missing"; exit 1; }

src_line=$(grep -n '^[[:space:]]*\.[[:space:]]*/opt/dsh-rescue/librescue.sh' "$EP" | head -n1 | cut -d: -f1)
[ -n "$src_line" ] || { echo "FAIL librescue-source-line-not-found"; exit 1; }

calls=$(grep -nE 'rescue_[a-z_]+' "$EP" \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vE 'rescue_[a-z_]+[[:space:]]*\(\)' \
  | grep -v 'librescue\.sh' \
  | cut -d: -f1 || true)

bad=0
for ln in $calls; do
  if [ "$ln" -lt "$src_line" ]; then
    echo "FAIL rescue-* called at line $ln but librescue is only sourced at line $src_line:"
    sed -n "${ln}p" "$EP" | sed 's/^/    /'
    bad=1
  fi
done
[ "$bad" -eq 0 ] || exit 1

echo 'ALL-PASS'
