#!/bin/sh
# ============================================================================
# test-dsh-version-pin.sh — dsh 版本锁定的多处一致性门禁
#
# 为什么需要它：DSH 版本在仓库里同时出现在 Dockerfile 的 ARG、README 中英徽章、docs/03 中英的
# dist-tag 表、CHANGELOG 最新段落。历史上每次换版本都要手工对齐 —— 漏掉任意一处都不会让镜像构建
# 失败，只会让文档悄悄说谎（典型：镜像已是新版，徽章还写着旧版本）。本门禁把这四处钉在一起。
#
# 覆盖：
#   P1 ARG DSH_VERSION 必须是完整三段式版本（拒绝 latest / next / alpha 这类 dist-tag）
#   P2/P3 README.md / README.zh-CN.md 的 DSH 徽章版本 == ARG（npm 风格双横线 0.1.7--alpha.1）
#   P4/P5 docs/zh-CN/03、docs/en/03 的 dist-tag 表 alpha 行 == ARG
#   P6 CHANGELOG 最新版本段落 == ARG
#
# 用法: sh scripts/t/test-dsh-version-pin.sh   （全通过打印 ALL-PASS）
# ============================================================================
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)

fail() { echo "FAIL-$1: $2"; exit 1; }

ARG=$(sed -n 's/^ARG DSH_VERSION=\(.*\)$/\1/p' "$ROOT/Dockerfile" | head -n1)
[ -n "$ARG" ] || fail "arg-missing" "no ARG DSH_VERSION in Dockerfile"

# P1：显式版本，且是完整三段式（可带预发布段）
case "$ARG" in
  latest|next|alpha|beta|rc|"") fail "arg-is-dist-tag" "DSH_VERSION must be explicit, got '$ARG'" ;;
esac
printf '%s\n' "$ARG" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
  || fail "arg-not-semver" "ARG DSH_VERSION='$ARG' is not a full 3-part version"

# P2/P3：README 徽章（npm 语义里预发布段用双横线）
BADGE=$(printf '%s' "$ARG" | sed 's/-/--/')
for f in README.md README.zh-CN.md; do
  grep -q "DeepSeek%20Harness-${BADGE}-" "$ROOT/$f" \
    || fail "badge-$f" "$f badge does not carry $ARG"
done

# P4/P5：docs 03 的 dist-tag 表 alpha 行（用 [|] 与 . 规避反引号的命令替换语义）
for f in docs/zh-CN/03-升级与维护.md docs/en/03-upgrade-maintenance.md; do
  grep -Eq "^[|] .alpha. [|] .$ARG. [|]" "$ROOT/$f" \
    || fail "docs-$f" "$f alpha row does not carry $ARG"
done

# P6：CHANGELOG 段落（形如 ## [v0.4.13-dsh-0.1.7-alpha.1]）
grep -q "^## \[v[0-9.]*-dsh-$ARG\]" "$ROOT/CHANGELOG.md" \
  || fail "changelog" "CHANGELOG has no version section for dsh $ARG"

echo ALL-PASS
