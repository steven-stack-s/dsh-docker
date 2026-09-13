#!/bin/sh
# ============================================================================
# test-update-dsh-badge.sh — 覆盖 scripts/update-dsh-badge.sh
# （该脚本由 .github/workflows/docker-image.yml 在 tag 构建成功后调用）
#
# 覆盖：
#   B1 正常改写            -> 版本替换且 shields 转义正确（0.1.5-rc.1 写成 0.1.5--rc.1）
#   B2 幂等                -> 同版本不改写，文件字节不变，退出 0
#   B3 拒绝降级            -> 现值更高时退出 1 且文件保持不变
#   B4 --force 允许降级    -> 退出 0 并改写
#   B5 rc 转正（关键）     -> 0.1.5-rc.1 -> 0.1.5 必须视为**升级**：sort -V 会把它误判为
#                             降级而拒绝，从而让转正版永远推不上徽章
#   B6 锚点缺失            -> 退出 1，绝不静默通过
#   B7 版本形态非法        -> 退出 1
#   B8 --dry-run           -> 报告但不写文件
#   B9 不误伤其他行        -> Release 徽章行里的 v0.4.0-dsh0.1.5-rc.1 必须原样保留
#
# 用法: sh scripts/t/test-update-dsh-badge.sh    （全通过打印 ALL-PASS）
# ============================================================================
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$HERE/../update-dsh-badge.sh"
[ -f "$SCRIPT" ] || { echo "FAIL-script-missing: $SCRIPT"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# 造一个与真实 README 头部同构的 fixture（含 Release 行，用于验证"不误伤"）
make_fixture() { # $1=目标文件 $2=DSH 版本（shields 已转义形态）
  cat > "$1" <<EOF
# Fixture

[![GitHub Release](https://img.shields.io/github/v/release/steven-stack-s/dsh-docker?sort=semver&color=5965d8)](https://github.com/steven-stack-s/dsh-docker/releases)
[![DeepSeek Harness](https://img.shields.io/badge/DeepSeek%20Harness-$2-4aa3ff)](https://github.com/deepseek-ai/deepseek-harness)
[![License](https://img.shields.io/github/license/steven-stack-s/dsh-docker?color=3b7a57)](https://github.com/steven-stack-s/dsh-docker/blob/main/LICENSE)

> body
EOF
}

checksum() { cksum < "$1" | awk '{print $1"-"$2}'; }
badge_ver() { sed -n 's|.*img\.shields\.io/badge/DeepSeek%20Harness-\([^)]*\)-4aa3ff.*|\1|p' "$1" | head -n 1; }

F="$TMP/README.md"

# ---- B1 正常改写（并验证转义）----
make_fixture "$F" "0.1.5--rc.1"
out=$(sh "$SCRIPT" 0.1.6 "$F" 2>&1); rc=$?
[ "$rc" = 0 ] || { echo "FAIL-b1-rc=$rc: $out"; exit 1; }
[ "$(badge_ver "$F")" = "0.1.6" ] || { echo "FAIL-b1-ver: $(badge_ver "$F")"; exit 1; }
case "$out" in *"unchanged"*) echo "FAIL-b1-reported-unchanged: $out"; exit 1 ;; esac

# B1b 目标带预发布 -> 必须写成双连字符
sh "$SCRIPT" 0.1.7-rc.2 "$F" >/dev/null 2>&1 || { echo "FAIL-b1b-rc"; exit 1; }
[ "$(badge_ver "$F")" = "0.1.7--rc.2" ] || { echo "FAIL-b1b-escape: $(badge_ver "$F")"; exit 1; }

# ---- B2 幂等 ----
before=$(checksum "$F")
out=$(sh "$SCRIPT" 0.1.7-rc.2 "$F" 2>&1); rc=$?
[ "$rc" = 0 ] || { echo "FAIL-b2-rc=$rc: $out"; exit 1; }
case "$out" in *"unchanged"*) : ;; *) echo "FAIL-b2-not-unchanged: $out"; exit 1 ;; esac
[ "$before" = "$(checksum "$F")" ] || { echo "FAIL-b2-mutated"; exit 1; }

# ---- B3 拒绝降级 ----
before=$(checksum "$F")
out=$(sh "$SCRIPT" 0.1.6 "$F" 2>&1); rc=$?
[ "$rc" = 1 ] || { echo "FAIL-b3-rc=$rc: $out"; exit 1; }
case "$out" in *"拒绝回退"*) : ;; *) echo "FAIL-b3-msg: $out"; exit 1 ;; esac
[ "$before" = "$(checksum "$F")" ] || { echo "FAIL-b3-mutated"; exit 1; }

# ---- B4 --force 允许降级 ----
sh "$SCRIPT" 0.1.6 "$F" --force >/dev/null 2>&1 || { echo "FAIL-b4-rc"; exit 1; }
[ "$(badge_ver "$F")" = "0.1.6" ] || { echo "FAIL-b4-ver: $(badge_ver "$F")"; exit 1; }

# ---- B5 rc 转正必须算升级（sort -V 反例）----
make_fixture "$F" "0.1.5--rc.1"
sh "$SCRIPT" 0.1.5 "$F" >/dev/null 2>&1 || { echo "FAIL-b5-rc: rc 转正被误判为降级"; exit 1; }
[ "$(badge_ver "$F")" = "0.1.5" ] || { echo "FAIL-b5-ver: $(badge_ver "$F")"; exit 1; }

# ---- B6 锚点缺失 -> 报错，不静默 ----
printf '# 没有徽章的文件\n\n> 无锚点\n' > "$TMP/plain.md"
before=$(checksum "$TMP/plain.md")
out=$(sh "$SCRIPT" 0.2.0 "$TMP/plain.md" 2>&1); rc=$?
[ "$rc" = 1 ] || { echo "FAIL-b6-rc=$rc: $out"; exit 1; }
case "$out" in *"找不到"*) : ;; *) echo "FAIL-b6-msg: $out"; exit 1 ;; esac
[ "$before" = "$(checksum "$TMP/plain.md")" ] || { echo "FAIL-b6-mutated"; exit 1; }

# ---- B7 版本形态非法 ----
out=$(sh "$SCRIPT" "abc" "$F" 2>&1); rc=$?
[ "$rc" = 1 ] || { echo "FAIL-b7-rc=$rc: $out"; exit 1; }
out=$(sh "$SCRIPT" "0.1.5-rc.1+build" "$F" 2>&1); rc=$?
[ "$rc" = 1 ] || { echo "FAIL-b7b-rc=$rc（"+" 非法，必须拒绝）: $out"; exit 1; }

# ---- B8 --dry-run 不写文件 ----
make_fixture "$F" "0.1.5--rc.1"
before=$(checksum "$F")
out=$(sh "$SCRIPT" 0.3.0 --dry-run "$F" 2>&1); rc=$?
[ "$rc" = 0 ] || { echo "FAIL-b8-rc=$rc: $out"; exit 1; }
case "$out" in *"would-update"*) : ;; *) echo "FAIL-b8-msg: $out"; exit 1 ;; esac
[ "$before" = "$(checksum "$F")" ] || { echo "FAIL-b8-mutated"; exit 1; }

# ---- B9 不误伤 Release 徽章行里的 v0.4.0-dsh0.1.5-rc.1 ----
sh "$SCRIPT" 0.9.9 "$F" >/dev/null 2>&1 || { echo "FAIL-b9-rc"; exit 1; }
grep -q 'github/v/release/steven-stack-s/dsh-docker?sort=semver&color=5965d8' "$F" \
  || { echo "FAIL-b9-release-line-damaged"; exit 1; }
grep -q 'DeepSeek%20Harness-0.9.9-4aa3ff' "$F" || { echo "FAIL-b9-target-not-updated"; exit 1; }
# 除徽章外其余内容必须逐字未变
[ "$(wc -l < "$F")" = "7" ] || { echo "FAIL-b9-line-count: $(wc -l < "$F")"; exit 1; }

# ---- B10 多文件（默认双 README 场景）----
make_fixture "$TMP/README.md" "0.1.1"
make_fixture "$TMP/README.zh-CN.md" "0.1.1"
out=$(cd "$TMP" && sh "$SCRIPT" 0.2.0 2>&1); rc=$?
[ "$rc" = 0 ] || { echo "FAIL-b10-rc=$rc: $out"; exit 1; }
[ "$(badge_ver "$TMP/README.md")" = "0.2.0" ] || { echo "FAIL-b10-en"; exit 1; }
[ "$(badge_ver "$TMP/README.zh-CN.md")" = "0.2.0" ] || { echo "FAIL-b10-zh"; exit 1; }
case "$out" in *"改写 2 个文件"*) : ;; *) echo "FAIL-b10-summary: $out"; exit 1 ;; esac

echo "ALL-PASS"
