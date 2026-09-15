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

# 1) 代码读取的每个可配置变量都必须能经 compose 注入，且**有文档可查**。
#    "有文档"的判定源有两个（任一命中即可）：
#      - .env.example        —— 日常必填项，写在这里
#      - docs/{zh-CN,en}/07  —— 高级调优项，速查表里给出默认值与覆盖方式
#    为什么不是只认 .env.example：.env.example 已按"精简为日常变量"的定位收敛（12 项），
#    高级项迁到 07 速查表。若仍只认 .env.example，要么门禁形同虚设（被删空），要么把
#    精简又推回去。改为"两处任一命中"，既保住"代码读的变量必须有文档"这条不变式，
#    又允许文档按受众分层。
node -e '
const fs=require("fs"), path=require("path");
const R=process.argv[1];
const files=["scripts/entrypoint.sh","scripts/rescue-supervise.sh","scripts/librescue.sh","scripts/logtee.js","scripts/rescue"];
const code=files.map(f=>fs.readFileSync(path.join(R,f),"utf8")).join("\n");
const vars=new Set();
for(const m of code.matchAll(/\$[{]([A-Z_][A-Z0-9_]*)[:\-}]/g)) vars.add(m[1]);
for(const m of code.matchAll(/process\.env\.([A-Z_][A-Z0-9_]*)/g)) vars.add(m[1]);
const compose=fs.readFileSync(path.join(R,"docker-compose.yml"),"utf8");
const injected=new Set([...compose.matchAll(/^\s*-\s*([A-Z_][A-Z0-9_]*)=/gm)].map(m=>m[1]));
const envex=fs.readFileSync(path.join(R,".env.example"),"utf8");
// 高级变量的文档源：中/英文速查表（缺失时降级为空串，回落到只看 .env.example）
const docFiles=["docs/zh-CN/07-环境变量速查.md","docs/en/07-environment-variables.md"];
const docs=docFiles.map(f=>{ try { return fs.readFileSync(path.join(R,f),"utf8"); } catch { return ""; } }).join("\n");
const PRE=/^(DSH_|RESCUE_|SOCAT_|NPM_|PROGRAMS_|WORKSPACE_|PIDS_|NODE_|MEM_|CPU_|DEEPSEEK_)/;
// 内部/自动变量：由代码或 Dockerfile 提供，不应（也不能）由 compose 注入
const internal=new Set(["REASON_SNAPSHOT","DSH_HOME","SOCAT_PID","SOCAT_PORT","RESCUE_PROBE"]);
let bad=0;
const missCompose=[...vars].filter(v=>PRE.test(v)&&!injected.has(v)&&!internal.has(v));
if(missCompose.length){ console.error("  code reads but compose does NOT inject: "+missCompose.join(", ")); bad=1; }
// 文档判定：.env.example 用 ^VAR= 行首锚定；07 速查表是 markdown 表格，用 \`VAR\` 反引号锚定，
// 避免 "RESCUE_KEEP" 命中 "RESCUE_KEEP_OTHER" 这类子串误判。
const documented=v=>new RegExp("^"+v+"=","m").test(envex) ||
                    new RegExp("\`"+v+"\`").test(docs) ||
                    new RegExp("^\\|\\s*"+v+"\\s*\\|","m").test(docs);
const missDocs=[...vars].filter(v=>PRE.test(v)&&!internal.has(v)&&!documented(v));
if(missDocs.length){ console.error("  missing from .env.example AND docs/07: "+missDocs.join(", ")); bad=1; }
if(!bad) console.log("  injection + docs (.env.example / 07): OK");
process.exit(bad);
' "$ROOT" || fail compose-injection-drift

# 1b) Dockerfile 的 COPY 源必须存在：目录重构（移动 entrypoint.sh / rescue / lifeboat.tmpl）最容易
#     在这里改漏，而构建失败只有在真机 build 时才会暴露。
missing_copy=0
for src in $(awk '/^COPY /{ for (i = 2; i < NF; i++) print $i }' "$ROOT/Dockerfile"); do
  [ -e "$ROOT/$src" ] || { echo "FAIL dockerfile-copy-source-missing: $src"; missing_copy=1; }
done
[ "$missing_copy" -eq 0 ] || exit 1

# 2) 容器硬化必须在位（LAN 内任何能访问 3080 的人都能借 agent 以 root 执行）
grep -q 'no-new-privileges' "$COMPOSE" || fail hardening-missing-no-new-privileges
grep -q 'pids_limit' "$COMPOSE" || fail hardening-missing-pids-limit
grep -q 'max-children' "$ROOT/scripts/entrypoint.sh" || fail hardening-missing-socat-max-children

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
