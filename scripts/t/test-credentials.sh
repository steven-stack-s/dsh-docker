#!/bin/sh
# ============================================================================
# test-credentials.sh — 凭据文件读取（F8）
#
# 背景：密钥走 environment 会被 `docker inspect` 直接看到，也会出现在容器的 /proc/<pid>/environ。
# 支持 DEEPSEEK_API_KEY_FILE（docker secret / 挂载文件）后，密钥就可以不经过环境变量传递。
#
# 契约：文件存在且可读 -> 读首行（去 CR/LF）写入 DEEPSEEK_API_KEY 并 export；
#       未设置 -> 不动既有环境变量（返回 0）；
#       设置了但不可读 -> 返回非 0（调用方据此告警），且**不得**清空既有变量。
# ============================================================================
set -u
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME"
. "$HERE/../librescue.sh"
fail() { echo "FAIL-$1"; exit 1; }

command -v rescue_load_api_key >/dev/null 2>&1 || fail helper-missing

DEEPSEEK_API_KEY=sk-from-env
DEEPSEEK_API_KEY_FILE=''
rescue_load_api_key || fail unset-file-rc
[ "$DEEPSEEK_API_KEY" = "sk-from-env" ] || fail unset-file-clobbered-env

printf 'sk-from-file\n' > "$T/key"
DEEPSEEK_API_KEY_FILE="$T/key"
rescue_load_api_key || fail file-rc
[ "$DEEPSEEK_API_KEY" = "sk-from-file" ] || fail file-not-loaded

printf 'sk-crlf\r\n' > "$T/key2"
DEEPSEEK_API_KEY_FILE="$T/key2"
rescue_load_api_key || fail crlf-rc
[ "$DEEPSEEK_API_KEY" = "sk-crlf" ] || fail crlf-not-trimmed

DEEPSEEK_API_KEY=sk-keep-me
DEEPSEEK_API_KEY_FILE="$T/does-not-exist"
if rescue_load_api_key; then fail missing-file-must-fail; fi
[ "$DEEPSEEK_API_KEY" = "sk-keep-me" ] || fail missing-file-clobbered-env

echo ALL-PASS
