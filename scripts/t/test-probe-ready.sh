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

# 等服务真正开始监听，而不是固定 sleep 1：在全量运行（负载高）时 node 启动可能超过 1s，
# 于是 probe 面对一个还没起来的服务、用例假失败（本机复现过一次）。
wait_port() {
  _i=0
  while [ "$_i" -lt 60 ]; do
    if node -e "require('net').connect($1,'127.0.0.1').on('connect',()=>process.exit(0)).on('error',()=>process.exit(1))" 2>/dev/null; then
      return 0
    fi
    sleep 0.1; _i=$((_i + 1))
  done
  return 1
}

# 端口按 PID 派生：固定端口在并发/残留监听时会出现 EADDRINUSE（本机复现过），
# 该脚本已纳入 CI 门禁，必须消除这种 flake。
BASE=$(( 39000 + ($$ % 600) ))
PORT_HTTP=$BASE
PORT_TCP=$(( BASE + 1 ))
PORT_FREE=$(( BASE + 2 ))
PORT_BADBODY=$(( BASE + 3 ))

# --- 用法：缺 port 应 exit 2
if node "$PROBE" >/dev/null 2>&1; then fail usage; fi

# --- A: HTTP 服务就绪 -> exit 0
srv "require('http').createServer((q,s)=>s.end('ok')).listen($PORT_HTTP,'127.0.0.1')"
wait_port $PORT_HTTP || fail a-server-not-listening
node "$PROBE" $PORT_HTTP 5000 --quiet || fail a-http-ready

# --- B: 只有 TCP、连上但无 HTTP 应答 -> exit 1（L2 必须拦住）
srv "require('net').createServer(()=>{}).listen($PORT_TCP,'127.0.0.1')"
wait_port $PORT_TCP || fail b-server-not-listening
if node "$PROBE" $PORT_TCP 2500 --quiet; then fail b-tcp-only-must-fail; fi

# --- C: 无人监听 -> exit 1
if node "$PROBE" $PORT_FREE 1500 --quiet; then fail c-no-listener-must-fail; fi

# --- D: --pid 指向已死进程 -> 立即失败（不得等满 timeout）
sh -c 'exit 0' &
deadpid=$!
wait "$deadpid" 2>/dev/null || true
start=$(date +%s)
if node "$PROBE" $PORT_FREE 30000 --pid "$deadpid" --quiet; then fail d-pid-gone; fi
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 5 ] || fail "d-pid-fast(elapsed=${elapsed}s)"

# --- E: --stable 3 仍应判定就绪（连续确认不误伤）
node "$PROBE" $PORT_HTTP 8000 --stable 3 --quiet || fail e-stable

# --- F: 向后兼容 —— 旧的两参数调用形式（port + timeoutMs）依旧可用
node "$PROBE" $PORT_HTTP 5000 || fail f-legacy-args

# --- G: 响应体出现"插件激活失败"标记 -> 必须判不健康 ---
# 这类故障（升级后白屏）的表现是：进程健康、端口在听、HTTP 也正常返回 200+HTML，
# 只有浏览器里是白屏。v0.3.7 的 CHANGELOG 明确承认探针覆盖不到它。
srv "require('http').createServer((q,s)=>{s.writeHead(200,{'Content-Type':'text/html'});s.end('<html><body>Failed to load plugins</body></html>')}).listen($PORT_BADBODY,'127.0.0.1')"
wait_port $PORT_BADBODY || fail g-server-not-listening
if node "$PROBE" $PORT_BADBODY 2500 --quiet; then fail g-boot-failure-marker-must-fail; fi

# --- H: 该检查可关闭（极端部署下若服务端 HTML 恒含类似字样，可回退到旧行为）---
if ! RESCUE_PROBE_FAIL_CHECK=off node "$PROBE" $PORT_BADBODY 2500 --quiet; then
  fail h-fail-check-not-disableable
fi

echo "ALL-PASS"
