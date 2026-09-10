#!/bin/sh
# probe-ready.js 单测：分层探测（L1 tcp / L2 http / L3 stable）的判定与退出码契约。
# 退出码语义必须与改造前一致：exit 0 = 就绪，非 0 = 不就绪。
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PROBE="$ROOT/scripts/probe-ready.js"
T=$(mktemp -d)
PIDS=""
cleanup() {
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  rm -rf "$T"
}
trap cleanup EXIT
fail() { echo "FAIL-$1"; exit 1; }
srv() { node -e "$1" & PIDS="$PIDS $!"; }

# --- 用法：缺 port 应 exit 2
if node "$PROBE" >/dev/null 2>&1; then fail usage; fi

# --- A: HTTP 服务就绪 -> exit 0
srv "require('http').createServer((q,s)=>s.end('ok')).listen(39081,'127.0.0.1')"
sleep 1
node "$PROBE" 39081 5000 --quiet || fail a-http-ready

# --- B: 只有 TCP、连上但无 HTTP 应答 -> exit 1（L2 必须拦住）
srv "require('net').createServer(()=>{}).listen(39082,'127.0.0.1')"
sleep 1
if node "$PROBE" 39082 2500 --quiet; then fail b-tcp-only-must-fail; fi

# --- C: 无人监听 -> exit 1
if node "$PROBE" 39089 1500 --quiet; then fail c-no-listener-must-fail; fi

# --- D: --pid 指向已死进程 -> 立即失败（不得等满 timeout）
sh -c 'exit 0' &
deadpid=$!
wait "$deadpid" 2>/dev/null || true
start=$(date +%s)
if node "$PROBE" 39089 30000 --pid "$deadpid" --quiet; then fail d-pid-gone; fi
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 5 ] || fail "d-pid-fast(elapsed=${elapsed}s)"

# --- E: --stable 3 仍应判定就绪（连续确认不误伤）
node "$PROBE" 39081 8000 --stable 3 --quiet || fail e-stable

# --- F: 向后兼容 —— 旧的两参数调用形式（port + timeoutMs）依旧可用
node "$PROBE" 39081 5000 || fail f-legacy-args

echo "ALL-PASS"
