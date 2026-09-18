#!/bin/sh
# ============================================================================
# test-release-workflows.sh — GitHub Release 发布路径的静态门禁
#
# 背景（2026-09-18 实测）：tag 被删除后重新推送时，GitHub 会把原 Release 转为 **draft**；
# 而 gh release edit 默认【不改变 draft 状态】—— 于是 workflow 绿灯、job 报成功，
# 用户在 Releases 页面却什么都看不到（匿名 /releases/tags/<tag> 返回 404）。
# 这个失败模式的可怕之处在于：所有信号都是「成功」，没有任何红灯可看。
# 故断言两个 workflow 在【更新已有 Release】时都必须显式 --draft=false。
# ============================================================================
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fail() { echo "FAIL-$1"; exit 1; }

for wf in .github/workflows/create-release.yml .github/workflows/docker-image.yml; do
  f="$ROOT/$wf"
  [ -f "$f" ] || fail "missing-workflow"
  grep -q 'gh release edit' "$f" || fail "no-release-edit-found"
  # 每一条 gh release edit 都必须带 --draft=false。
  # 先剔除注释行：workflow 的说明里会出现 'gh release edit' 这个词，
  # 那是解释、不是命令（本用例第一版就因此误报）。
  if grep 'gh release edit' "$f" | grep -v '^[[:space:]]*#' | grep -v -- '--draft=false' | grep -q .; then
    fail "release-edit-without-draft-false"
  fi
done
echo 'ALL-PASS'