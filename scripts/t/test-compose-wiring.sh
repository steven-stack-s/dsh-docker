#!/bin/sh
# ============================================================================
# test-compose-wiring.sh — compose / .env.example 与代码的一致性门禁（F11）
#
# 为什么需要：Wave 1 就踩过 —— CHANGELOG 承诺 RESCUE_SNAPSHOT_ON_HEALTHY=off 可关，但 compose 的
# environment 白名单里没有它，通过 compose 部署的用户**根本关不掉**。这类"代码读、compose 不注入"
# 的漂移此前没有任何测试拦得住，直到有人在真机上撞见。本测试把它变成红灯。
# ============================================================================
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
COMPOSE="$ROOT/docker-compose.yml"
ENVEX="$ROOT/.env.example"
fail() { echo "FAIL-$1"; exit 1; }
[ -f "$COMPOSE" ] || fail compose-missing
[ -f "$ENVEX" ] || fail envexample-missing

# 1) 代码读取的每个可配置变量都必须能经 compose 注入，且出现在 .env.example
node -e '
const fs=require("fs"), path=require("path");
const R=process.argv[1];
const files=["entrypoint.sh","scripts/rescue-supervise.sh","scripts/librescue.sh","scripts/logtee.js","rescue"];
const code=files.map(f=>fs.readFileSync(path.join(R,f),"utf8")).join("\n");
const vars=new Set();
for(const m of code.matchAll(/\$[{]([A-Z_][A-Z0-9_]*)[:\-}]/g)) vars.add(m[1]);
for(const m of code.matchAll(/process\.env\.([A-Z_][A-Z0-9_]*)/g)) vars.add(m[1]);
const compose=fs.readFileSync(path.join(R,"docker-compose.yml"),"utf8");
const injected=new Set([...compose.matchAll(/^\s*-\s*([A-Z_][A-Z0-9_]*)=/gm)].map(m=>m[1]));
const envex=fs.readFileSync(path.join(R,".env.example"),"utf8");
const PRE=/^(DSH_|RESCUE_|SOCAT_|NPM_|PROGRAMS_|WORKSPACE_|PIDS_|NODE_|MEM_|CPU_|DEEPSEEK_)/;
// 内部/自动变量：由代码或 Dockerfile 提供，不应（也不能）由 compose 注入
const internal=new Set(["REASON_SNAPSHOT","DSH_HOME","SOCAT_PID","SOCAT_PORT","RESCUE_PROBE"]);
let bad=0;
const missCompose=[...vars].filter(v=>PRE.test(v)&&!injected.has(v)&&!internal.has(v));
if(missCompose.length){ console.error("  code reads but compose does NOT inject: "+missCompose.join(", ")); bad=1; }
const missDocs=[...vars].filter(v=>PRE.test(v)&&!internal.has(v)&&!new RegExp("^"+v+"=","m").test(envex));
if(missDocs.length){ console.error("  missing from .env.example: "+missDocs.join(", ")); bad=1; }
if(!bad) console.log("  injection + .env.example: OK");
process.exit(bad);
' "$ROOT" || fail compose-injection-drift

# 2) 容器硬化必须在位（LAN 内任何能访问 3080 的人都能借 agent 以 root 执行）
grep -q 'no-new-privileges' "$COMPOSE" || fail hardening-missing-no-new-privileges
grep -q 'pids_limit' "$COMPOSE" || fail hardening-missing-pids-limit
grep -q 'max-children' "$ROOT/entrypoint.sh" || fail hardening-missing-socat-max-children

# 3) healthcheck 的 start_period 必须 > RESCUE_START_TIMEOUT（注释里写了的口径不变式）
sp=$(grep -m1 'start_period:' "$COMPOSE" | tr -cd '0-9')
rst=$(grep -m1 '^      - RESCUE_START_TIMEOUT=' "$COMPOSE" | tr -cd '0-9')
[ -n "$sp" ] || fail start-period-not-found
[ -n "$rst" ] || fail rescue-timeout-not-found
if [ "$sp" -le "$rst" ]; then
  echo "FAIL start-period(=$sp) must exceed RESCUE_START_TIMEOUT(=$rst)"
  exit 1
fi

echo 'ALL-PASS'
