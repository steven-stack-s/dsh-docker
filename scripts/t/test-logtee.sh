#!/bin/sh
# logtee.js 单测：双写 stdout+文件、超限轮转(整段归档到 .1 覆盖旧)、EOF 退出。
# 轮转语义：单文件超 RESCUE_EVIDENCE_MAX 时，把已写整段 rename 为 <file>.1(覆盖旧 .1)，
# 重开新 <file> 继续写 → 磁盘占用有界(~2x上限)，保留最新一段供诊断。
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LT="$ROOT/scripts/logtee.js"
[ -f "$LT" ] || { echo "FAIL logtee missing"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL-$1"; exit 1; }

# 1. 双写 + 大上限不轮转
printf 'hello1\nhello2\n' | RESCUE_EVIDENCE_MAX=100000000 node "$LT" "$T/a.log" > "$T/s1.txt"
[ "$(cat "$T/s1.txt")" = "hello1
hello2" ] || fail "stdout1"
[ "$(cat "$T/a.log")" = "hello1
hello2" ] || fail "file1"
[ -e "$T/a.log.1" ] && fail "noro1"

# 2. 小上限触发轮转：首两行累计超限 → 整段归档 .1；末行进新文件
printf 'aaaa\nbbbb\ncccc\n' | RESCUE_EVIDENCE_MAX=8 node "$LT" "$T/b.log" > "$T/s2.txt"
[ -e "$T/b.log.1" ] || fail "no-rot"
[ "$(cat "$T/b.log.1")" = "aaaa
bbbb" ] || fail "rot-old got:[$(cat "$T/b.log.1")]"
[ "$(cat "$T/b.log")" = "cccc" ] || fail "rot-new got:[$(cat "$T/b.log")]"

# 3. stdout 无论轮转与否都完整
[ "$(cat "$T/s2.txt")" = "aaaa
bbbb
cccc" ] || fail "stdout-rot"

echo 'ALL-PASS'
