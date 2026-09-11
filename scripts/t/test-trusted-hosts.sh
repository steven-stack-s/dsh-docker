#!/bin/sh
# ============================================================================
# test-trusted-hosts.sh — DSH_TRUSTED_HOSTS 解析
#
# 背景：entrypoint 原来是 `for h in $(echo "$DSH_TRUSTED_HOSTS" | tr ',' ' ')`，未加引号的展开
# 会被空白/通配符破坏；而 dsh 对每个白名单项都会做 assertTrustedAuthority，
# 一个畸形条目就会让启动直接失败、白白消耗 RESCUE_START_TIMEOUT 与自愈预算。
#
# 契约：按逗号切分；逐项校验只允许 [A-Za-z0-9.:_*-]；非法项丢弃并记审计日志；输出
#       "--trusted-host <h>" 序列（空输入 -> 空输出）。
# ============================================================================
set -u
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME"
. "$HERE/../librescue.sh"
fail() { echo "FAIL-$1"; exit 1; }

command -v rescue_trusted_args >/dev/null 2>&1 || fail helper-missing

# 1) 正常多值（含端口）
out=$(rescue_trusted_args 'app.example.com,192.168.1.5:3080')
[ "$out" = " --trusted-host app.example.com --trusted-host 192.168.1.5:3080" ] \
  || { echo "FAIL-normal: [$out]"; exit 1; }

# 2) 空输入 -> 空输出
out=$(rescue_trusted_args '')
[ -z "$out" ] || { echo "FAIL-empty: [$out]"; exit 1; }

# 3) 畸形项必须被丢弃（含空格、命令替换、通配符），合法项保留
# 注意：这里逐项单独断言。之前用 `case "$out" in *'*'*)` 一次性匹配，写法容易失效而假绿——
# 真机上就是这样漏掉了 `*` 被当作合法 host 传给了 dsh。
out=$(rescue_trusted_args 'good.com,bad host,evil$(rm -rf /),*')
case "$out" in
  *'--trusted-host good.com'*) : ;;
  *) echo "FAIL-valid-dropped: [$out]"; exit 1 ;;
esac
case "$out" in *bad*) echo "FAIL-space-entry-kept: [$out]"; exit 1 ;; esac
case "$out" in *evil*) echo "FAIL-substitution-kept: [$out]"; exit 1 ;; esac
# 通配符不是合法 host 字符：单独输入必须得到空输出
out=$(rescue_trusted_args '*')
[ -z "$out" ] || { echo "FAIL-wildcard-accepted: [$out]"; exit 1; }

echo ALL-PASS
