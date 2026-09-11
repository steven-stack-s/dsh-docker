#!/bin/sh
# ============================================================================
# test-script-modes.sh — 入口/测试脚本的可执行位门禁
#
# 背景：这些文件在 git 里曾经是 644（靠镜像 Dockerfile 的 chmod 赋权）。镜像内没问题，但
# clone 之后直接 ./rescue 或 ./scripts/t/test-x.sh 会 Permission denied —— 真机手工验证时
# 就踩到过（bind-mount 覆盖后容器里也丢了执行位）。这里把它变成红灯。
#
# 约定：需要被"直接执行"的脚本必须带可执行位；被 source 的库（librescue / rescue-supervise）
# 不需要，也不应该靠执行它们来工作。
# ============================================================================
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

bad=0
check_exec() {
  [ -f "$ROOT/$1" ] || return 0
  [ -x "$ROOT/$1" ] || { echo "FAIL not-executable: $1"; bad=1; }
}

# 需要直接执行的
check_exec scripts/entrypoint.sh
check_exec scripts/rescue
check_exec scripts/ci-image-tags.sh
check_exec scripts/logtag.js
check_exec scripts/logtee.js
for f in scripts/t/*.sh; do
  [ -f "$f" ] || continue
  rel=${f#"$ROOT"/}
  check_exec "$rel"
done

[ "$bad" -eq 0 ] || exit 1
echo 'ALL-PASS'
