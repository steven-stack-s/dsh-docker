#!/bin/sh
# ============================================================================
# test-supervise-loop.sh — rescue_supervise() 监督循环分支测试
#
# 用 stub dsh / stub probe / stub diagnose 驱动**真实的** rescue-supervise.sh，
# 只断言可观测行为（容器日志、state 文件、退出码），不碰内部实现细节。
#
# 场景：
#   C1 healthy 路径          : 探测通过 -> 记 last-run=healthy -> 子进程退出码冒泡
#   C2 降级安全 (P0-1a)      : 证据目录不可创建时仍必须启动 dsh，监督不得中断
#   C3 降级安全 (P0-1b)      : incident 写入失败不得中断"已成功的自愈"的重试
#   C4 降级安全 (P0-1c)      : 运行期 incident 写入失败不得阻止 dsh 启动
#   C5 总闸语义 (P0-3a)      : RESCUE_AUTO=off 时不得自动改写插件树
#
# 用法: sh scripts/t/test-supervise-loop.sh      （全通过打印 ALL-PASS）
# ============================================================================
set -u
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME/profiles/web"
printf '%s' '{"name":"web","private":true,"dependencies":{}}' > "$DSH_HOME/profiles/web/package.json"
printf 'lock v1\n' > "$DSH_HOME/profiles/web/pnpm-lock.yaml"

# ---- stub dsh ----
mkdir -p "$T/bin"
cat > "$T/bin/dsh" <<'STUB'
#!/bin/sh
case "${STUB_DSH_MODE:-ok}" in
  ok)    echo "[stub-dsh] started"; sleep "${STUB_DSH_SLEEP:-1}"; exit 0 ;;
  noisy) echo "[stub-dsh] plugin @scope/bad failed to load"; sleep 5; exit 0 ;;
  flood) i=0; while [ "$i" -lt 400 ]; do echo "[stub-dsh] line $i padding padding padding"; i=$((i+1)); done; echo "[stub-dsh] FINAL-MARKER"; sleep 5; exit 0 ;;
  pluginquoted) echo '[stub-dsh] plugin "@scope/bad" failed to load'; sleep 5; exit 0 ;;
  crash) exit 3 ;;
esac
STUB
chmod +x "$T/bin/dsh"
PATH="$T/bin:$PATH"; export PATH

# ---- stub probe（替代 probe-ready.js；由 node 执行，退出码即契约）----
printf 'process.exit(0);\n' > "$T/probe-ok.js"
printf 'setTimeout(function () { process.exit(1); }, 500);\n' > "$T/probe-fail.js"
printf 'setTimeout(function () { process.exit(1); }, 3000);\n' > "$T/probe-slow.js"
# 前 STUB_PROBE_FAIL_TIMES 次探测失败、之后成功（用计数文件在多次 attempt 之间保留状态）
cat > "$T/probe-flaky.js" <<'STUB'
'use strict';
const fs = require('node:fs');
const st = process.env.STUB_PROBE_STATE || '/tmp/probe-state';
const failTimes = Number(process.env.STUB_PROBE_FAIL_TIMES || 1);
let n = 0;
try { n = Number(fs.readFileSync(st, 'utf8')) || 0; } catch (e) {}
n++;
try { fs.writeFileSync(st, String(n)); } catch (e) {}
process.exit(n <= failTimes ? 1 : 0);
STUB

# ---- stub diagnose ----
# 归因调用（不带 --write-incident）-> 输出决策 JSON；写 incident 调用 -> 按 STUB_DIAG_WRITE_RC 失败
cat > "$T/diagnose-stub.js" <<'STUB'
'use strict';
const a = process.argv.slice(2);
if (a.includes('--write-incident')) process.exit(Number(process.env.STUB_DIAG_WRITE_RC || 3));
process.stdout.write(JSON.stringify({
  recommendedHeal: process.env.STUB_DIAG_HEAL || 'rollback',
  recommendedTarget: process.env.STUB_DIAG_TARGET || 'snap-0001',
}));
STUB

. "$HERE/../librescue.sh"
. "$HERE/../rescue-supervise.sh"

# 在复刻 entrypoint 环境的子 shell 里跑一次 rescue_supervise（含 set -e）
# 用法: run_supervise <logfile> [KEY=VALUE ...]
run_supervise() {
  logf="$1"; shift
  (
    set -e
    elog() { printf '[elog] %s\n' "$*"; }
    PORT_INNER=3081; TRUSTED_ARGS=''
    RESCUE_PROFILE=web; RESCUE_START_TIMEOUT=5; RESCUE_KEEP=2
    RESCUE_AUTO=on; RESCUE_SELFHEAL=on
    RESCUE_REMOVE_LIMIT=2; RESCUE_ROLLBACK_LIMIT=2; RESCUE_INCIDENT_KEEP=20
    RESCUE_DIAGNOSE_EVIDENCE=off; RESCUE_SNAPSHOT_ON_HEALTHY=off; RESCUE_EVIDENCE_MAX=1048576
    RESCUE_DIAG=''; LOGTAG=''; LOGTEE=''
    for kv in "$@"; do export "$kv"; done
    rescue_supervise
  ) > "$logf" 2>&1
}

show() { sed -n '1,12p' "$1"; }

# ---------------------------------------------------------------- C1
run_supervise "$T/c1.log" RESCUE_PROBE="$T/probe-ok.js" STUB_DSH_MODE=ok STUB_DSH_SLEEP=1
c1rc=$?
if [ "$c1rc" != 0 ]; then echo "FAIL-c1-exit-code(want=0 got=$c1rc)"; show "$T/c1.log"; exit 1; fi
if ! grep -q 'dsh healthy on 127.0.0.1:3081' "$T/c1.log"; then echo 'FAIL-c1-no-healthy-marker'; show "$T/c1.log"; exit 1; fi
if ! grep -q '"phase":"exited"' "$DSH_HOME/.rescue/state/last-run.json" || ! grep -q '"abnormalExit":false' "$DSH_HOME/.rescue/state/last-run.json"; then
  echo 'FAIL-c1-final-state(want exited/abnormalExit=false)'; cat "$DSH_HOME/.rescue/state/last-run.json"; exit 1
fi

# ---------------------------------------------------------------- C2
run_supervise "$T/c2.log" RESCUE_PROBE="$T/probe-ok.js" RESCUE_DIAGNOSE_EVIDENCE=on \
  RESCUE_DIR="/proc/nonexistent-$$/evidence-root" STUB_DSH_MODE=ok STUB_DSH_SLEEP=1
c2rc=$?
if [ "$c2rc" != 0 ]; then echo "FAIL-c2-supervision-aborted(want=0 got=$c2rc)"; show "$T/c2.log"; exit 1; fi
if ! grep -q 'dsh healthy' "$T/c2.log"; then echo 'FAIL-c2-dsh-never-started'; show "$T/c2.log"; exit 1; fi

# ---------------------------------------------------------------- C3
# 快照必须与 live 有差异，否则"回滚"是 no-op（P1-3 会正确地拒绝它），本用例就测不到
# "自愈已生效、却因 incident 写失败被中断"这条路径。
printf '{"name":"web","private":true,"dependencies":{"stage":"baseline"}}' > "$DSH_HOME/profiles/web/package.json"
REASON_SNAPSHOT=test-baseline rescue_snapshot >/dev/null 2>&1 || true
printf '{"name":"web","private":true,"dependencies":{"stage":"broken"}}' > "$DSH_HOME/profiles/web/package.json"
run_supervise "$T/c3.log" RESCUE_PROBE="$T/probe-fail.js" RESCUE_DIAG="$T/diagnose-stub.js" \
  RESCUE_DIAGNOSE_EVIDENCE=on STUB_DIAG_WRITE_RC=3 STUB_DSH_MODE=noisy
c3rc=$?
if ! grep -q 'boot attempt 2/' "$T/c3.log"; then
  echo 'FAIL-c3-heal-then-incident-failure-aborted-retry'; show "$T/c3.log"; exit 1
fi
if [ "$c3rc" != 1 ]; then echo "FAIL-c3-exit-code(want=1 got=$c3rc)"; show "$T/c3.log"; exit 1; fi

# ---------------------------------------------------------------- C4
mkdir -p "$DSH_HOME/.rescue/state"
printf '%s' '{"phase":"runtime-crash","abnormalExit":true}' > "$DSH_HOME/.rescue/state/last-run.json"
[ -s "$DSH_HOME/.rescue/state/last-run.json" ] || { echo 'FAIL-c4-fixture-write'; exit 1; }
run_supervise "$T/c4.log" RESCUE_PROBE="$T/probe-ok.js" RESCUE_DIAG="$T/diagnose-stub.js" \
  STUB_DIAG_WRITE_RC=3 STUB_DSH_MODE=ok STUB_DSH_SLEEP=1
c4rc=$?
# 正向断言：必须真的进入了"读到 abnormalExit 并尝试写 runtime incident"的分支，
# 否则本用例会退化成"必然通过"（fixture 没写进去也一样绿）。
if ! grep -q 'last run abnormal exit recorded' "$T/c4.log"; then
  echo 'FAIL-c4-abnormal-branch-not-entered'; show "$T/c4.log"; exit 1
fi
if ! grep -q 'boot attempt 1/' "$T/c4.log"; then
  echo 'FAIL-c4-runtime-incident-failure-blocked-boot'; show "$T/c4.log"; exit 1
fi
if ! grep -q 'dsh healthy' "$T/c4.log"; then echo 'FAIL-c4-dsh-never-started'; show "$T/c4.log"; exit 1; fi
if [ "$c4rc" != 0 ]; then echo "FAIL-c4-exit-code(want=0 got=$c4rc)"; show "$T/c4.log"; exit 1; fi

# ---------------------------------------------------------------- C5
run_supervise "$T/c5.log" RESCUE_PROBE="$T/probe-fail.js" RESCUE_DIAG="$T/diagnose-stub.js" \
  RESCUE_DIAGNOSE_EVIDENCE=on RESCUE_AUTO=off STUB_DSH_MODE=noisy
# 正向断言：总闸必须被真正触发（否则"没有 rollback 日志"也可能只是没走到自愈）
if ! grep -q 'RESCUE_AUTO=off; auto-heal disabled' "$T/c5.log"; then
  echo 'FAIL-c5-master-switch-not-triggered'; show "$T/c5.log"; exit 1
fi
if grep -q 'selfheal rollback to' "$T/c5.log"; then
  echo 'FAIL-c5-RESCUE_AUTO=off-still-modified-plugin-tree'; show "$T/c5.log"; exit 1
fi

# ---------------------------------------------------------------- C7
# 失败路径必须把 dsh 的**最后**输出留在证据文件里。
# tee 对文件是块缓冲：若 rescue_close_ev 在 tee 读完/刷盘前就 kill 它，最后一段（往往正是崩溃
# 原因）会凭空消失，diagnose 拿不到证据只能 report-only —— 归因能力静默降级。
run_supervise "$T/c7.log" RESCUE_PROBE="$T/probe-fail.js" RESCUE_DIAGNOSE_EVIDENCE=on \
  RESCUE_AUTO=off STUB_DSH_MODE=flood
evd=$(ls -1d "$DSH_HOME"/.rescue/evidence/boot-* 2>/dev/null | sort | tail -n1)
[ -n "$evd" ] || { echo 'FAIL-c7-no-evidence-dir'; show "$T/c7.log"; exit 1; }
[ -s "$evd/dsh.log" ] || { echo 'FAIL-c7-evidence-empty'; exit 1; }
grep -q 'FINAL-MARKER' "$evd/dsh.log" \
  || { echo "FAIL-c7-evidence-lost-tail($(wc -c < "$evd/dsh.log") bytes)"; exit 1; }

# ---------------------------------------------------------------- C19
# RESCUE_KEEP 此前一配置三语义（快照保留数 / 证据保留数 / 启动重试上限），改一个会连带改另外两个。
# 拆出 RESCUE_MAX_ATTEMPTS 后必须能独立控制重试次数。
rm -rf "$DSH_HOME/.rescue"
mkdir -p "$DSH_HOME/profiles/web"
printf '{"name":"web","private":true,"dependencies":{"a":"1"}}' > "$DSH_HOME/profiles/web/package.json"
REASON_SNAPSHOT=baseline rescue_snapshot >/dev/null 2>&1
printf '{"name":"web","private":true,"dependencies":{"a":"2"}}' > "$DSH_HOME/profiles/web/package.json"
run_supervise "$T/c19.log" RESCUE_PROBE="$T/probe-fail.js" RESCUE_DIAG='' \
  RESCUE_DIAGNOSE_EVIDENCE=off RESCUE_KEEP=3 RESCUE_MAX_ATTEMPTS=2 STUB_DSH_MODE=noisy
grep -q 'boot attempt 2/2' "$T/c19.log" || { echo 'FAIL-c19-max-attempts-not-honoured'; show "$T/c19.log"; exit 1; }
grep -q 'boot attempt 3/' "$T/c19.log" && { echo 'FAIL-c19-retried-past-max-attempts'; show "$T/c19.log"; exit 1; }

# ---------------------------------------------------------------- C20
# 证据保留数必须能独立于快照保留数（此前共用 RESCUE_KEEP：调大快照数会意外多留证据，反之亦然）
_evk="$DSH_HOME/.rescue/evidence"
rm -rf "$_evk"; mkdir -p "$_evk/boot-1-a" "$_evk/boot-2-b" "$_evk/boot-3-c"
RESCUE_KEEP=1 RESCUE_EVIDENCE_KEEP=3 rescue_evidence_prune
[ "$(ls -1d "$_evk"/boot-* 2>/dev/null | wc -l)" = 3 ] \
  || { echo 'FAIL-c20-evidence-keep-not-independent'; exit 1; }
RESCUE_KEEP=9 RESCUE_EVIDENCE_KEEP=1 rescue_evidence_prune
[ "$(ls -1d "$_evk"/boot-* 2>/dev/null | wc -l)" = 1 ] \
  || { echo 'FAIL-c20-evidence-keep-ignored'; exit 1; }

# ---------------------------------------------------------------- C17
# 自愈之后重试成功 -> 必须留下一条 incident。
# 此前 healthy 路径根本不写 incident（只在"还有重试预算"时提前写），于是"曾故障并已自动恢复"
# 这件事在事故记录里完全看不到。
rm -rf "$DSH_HOME/.rescue" "$T/probe-count"
mkdir -p "$DSH_HOME/profiles/web"
printf '{"name":"web","private":true,"dependencies":{"stage":"baseline"}}' > "$DSH_HOME/profiles/web/package.json"
REASON_SNAPSHOT=baseline rescue_snapshot >/dev/null 2>&1
printf '{"name":"web","private":true,"dependencies":{"stage":"broken"}}' > "$DSH_HOME/profiles/web/package.json"
# 用真实 diagnose.js（而非桩），让 incident 的 outcome 走真实的判定与 journal 推断
run_supervise "$T/c17.log" RESCUE_PROBE="$T/probe-flaky.js" RESCUE_DIAG="$HERE/../diagnose.js" \
  RESCUE_DIAGNOSE_EVIDENCE=on \
  STUB_PROBE_STATE="$T/probe-count" STUB_PROBE_FAIL_TIMES=1 STUB_DSH_MODE=pluginquoted
[ "$(ls "$DSH_HOME"/.rescue/incidents/inc-*.json 2>/dev/null | wc -l)" -ge 1 ] \
  || { echo 'FAIL-c17-recovered-run-left-no-incident'; show "$T/c17.log"; exit 1; }
grep -q '"outcome":"recovered' "$DSH_HOME"/.rescue/incidents/inc-*.json \
  || { echo "FAIL-c17-outcome-not-recovered: $(cat "$DSH_HOME"/.rescue/incidents/inc-*.json)"; exit 1; }

# ---------------------------------------------------------------- C18
# 自愈动作成功、但服务始终起不来（crashloop）-> incident 不得写成 recovered-*。
# 此前 outcome 由 journal 推断：只要 rollback 返回 0 就记 recovered-rollback，而完整重试之后
# 服务其实从没起来过 —— 等于告诉用户"已恢复"。
rm -rf "$DSH_HOME/.rescue" "$T/probe-count2"
mkdir -p "$DSH_HOME/profiles/web"
printf '{"name":"web","private":true,"dependencies":{"stage":"baseline"}}' > "$DSH_HOME/profiles/web/package.json"
REASON_SNAPSHOT=baseline rescue_snapshot >/dev/null 2>&1
printf '{"name":"web","private":true,"dependencies":{"stage":"broken"}}' > "$DSH_HOME/profiles/web/package.json"
run_supervise "$T/c18.log" RESCUE_PROBE="$T/probe-flaky.js" RESCUE_DIAG="$HERE/../diagnose.js" \
  RESCUE_DIAGNOSE_EVIDENCE=on \
  STUB_PROBE_STATE="$T/probe-count2" STUB_PROBE_FAIL_TIMES=999 STUB_DSH_MODE=pluginquoted
inc=$(ls "$DSH_HOME"/.rescue/incidents/inc-*.json 2>/dev/null | head -n1)
[ -n "$inc" ] || { echo 'FAIL-c18-no-incident-after-crashloop'; show "$T/c18.log"; exit 1; }
grep -q '"outcome":"recovered' "$inc" && { echo "FAIL-c18-crashloop-reported-as-recovered: $(cat "$inc")"; exit 1; }
grep -q '"outcome":"unrecovered"' "$inc" || { echo "FAIL-c18-outcome-not-unrecovered: $(cat "$inc")"; exit 1; }

# ---------------------------------------------------------------- C16
# 自愈彻底失败后必须留下"自动降级进救生舱"的标记（文档一直承诺"自动降级"，实现里却只有手动
# RESCUE=1）—— 否则用户面对的仍是无限 crashloop，连界面都进不去。
rm -rf "$DSH_HOME/.rescue"
mkdir -p "$DSH_HOME/profiles/web"
printf '{"name":"web","private":true,"dependencies":{"stage":"same"}}' > "$DSH_HOME/profiles/web/package.json"
REASON_SNAPSHOT=baseline rescue_snapshot >/dev/null 2>&1      # 快照与 live 完全相同 -> 无可用回退目标
run_supervise "$T/c16.log" RESCUE_PROBE="$T/probe-fail.js" RESCUE_DIAG="$T/diagnose-stub.js" \
  RESCUE_DIAGNOSE_EVIDENCE=on STUB_DIAG_HEAL=rollback STUB_DIAG_TARGET=snap-0001 STUB_DSH_MODE=noisy
[ -f "$DSH_HOME/.rescue/state/lifeboat-requested" ] \
  || { echo 'FAIL-c16-lifeboat-not-requested-after-exhausted-selfheal'; show "$T/c16.log"; exit 1; }

# 关掉自动降级时不得留标记（给"绝不要自动降级"的用户一个开关）
rm -f "$DSH_HOME/.rescue/state/lifeboat-requested"
run_supervise "$T/c16b.log" RESCUE_PROBE="$T/probe-fail.js" RESCUE_DIAG="$T/diagnose-stub.js" \
  RESCUE_DIAGNOSE_EVIDENCE=on RESCUE_AUTO_LIFEBOAT=off STUB_DIAG_HEAL=rollback STUB_DIAG_TARGET=snap-0001 STUB_DSH_MODE=noisy
[ -f "$DSH_HOME/.rescue/state/lifeboat-requested" ] \
  && { echo 'FAIL-c16b-lifeboat-requested-despite-off'; exit 1; }

# ---------------------------------------------------------------- C15
# socat 是把外部 3080 转到内部 3081 的唯一通道，也是用户的唯一入口，却完全没有监督：
# 它一旦死掉，dsh 仍然健康、容器仍然 green、healthcheck 照样通过，但用户彻底失联。
rm -rf "$DSH_HOME/.rescue"
mkdir -p "$DSH_HOME/profiles/web"
printf '{"name":"web","private":true,"dependencies":{}}' > "$DSH_HOME/profiles/web/package.json"
(
  set -e
  elog() { printf '[elog] %s\n' "$*"; }
  _socat_restarts=0
  start_socat() { _socat_restarts=$((_socat_restarts + 1)); elog "[stub] socat restarted (#$_socat_restarts)"; sleep 300 & SOCAT_PID=$!; }
  PORT_INNER=3081; TRUSTED_ARGS=''
  RESCUE_PROFILE=web; RESCUE_START_TIMEOUT=5; RESCUE_KEEP=2
  RESCUE_AUTO=on; RESCUE_SELFHEAL=on
  RESCUE_REMOVE_LIMIT=2; RESCUE_ROLLBACK_LIMIT=2; RESCUE_INCIDENT_KEEP=20
  RESCUE_DIAGNOSE_EVIDENCE=off; RESCUE_SNAPSHOT_ON_HEALTHY=off; RESCUE_EVIDENCE_MAX=1048576
  RESCUE_DIAG=''; LOGTAG=''; LOGTEE=''
  RESCUE_PROBE="$T/probe-ok.js"; export RESCUE_PROBE
  STUB_DSH_MODE=ok; STUB_DSH_SLEEP=4; export STUB_DSH_MODE STUB_DSH_SLEEP
  sleep 0.2 & SOCAT_PID=$!        # 模拟"转发器刚起来就死掉"
  rescue_supervise
) > "$T/c15.log" 2>&1
grep -q 'socat restarted' "$T/c15.log" || { echo 'FAIL-c15-socat-death-not-handled'; show "$T/c15.log"; exit 1; }

# ---------------------------------------------------------------- C14
# 证据链（tee/logtee）在启动窗口内死掉时，shell 仍持有 fifo 的读端 —— dsh 继续写不会收到 EPIPE，
# 而是在 fifo 缓冲写满后静默卡住（表现为"容器起了但没反应"）。必须检测并释放。
printf 'process.exit(0);\n' > "$T/tee-die.js"
run_supervise "$T/c14.log" RESCUE_PROBE="$T/probe-slow.js" LOGTEE="$T/tee-die.js" \
  RESCUE_DIAGNOSE_EVIDENCE=on RESCUE_AUTO=off STUB_DSH_MODE=noisy
grep -q 'evidence tee died' "$T/c14.log" \
  || { echo 'FAIL-c14-dead-evidence-chain-not-detected'; show "$T/c14.log"; exit 1; }

# ---------------------------------------------------------------- C13
# SIGTERM（docker stop）必须转发给 dsh：PID1 是 dash、dsh 只是后台子进程，若 PID1 直接退出，
# 整个命名空间会被 SIGKILL —— dsh 没有任何落盘机会（会话/记忆可能丢）。而且"计划内停止"不能被
# 记成 runtime crash，否则下次启动会写一条假的 runtime incident 误导排查。
rm -rf "$DSH_HOME/.rescue"
mkdir -p "$DSH_HOME/profiles/web"
printf '{"name":"web","private":true,"dependencies":{}}' > "$DSH_HOME/profiles/web/package.json"
# 注意：这里必须内联一个后台块，而不是复用 run_supervise —— 后者内部还有一层 ( ... ) 子 shell，
# kill 只会打到外层，trap 所在的内层进程收不到信号（真实场景里 entrypoint 是直接在 PID1 进程内
# source 并调用 rescue_supervise 的，没有这层嵌套）。
(
  set -e
  elog() { printf '[elog] %s\n' "$*"; }
  PORT_INNER=3081; TRUSTED_ARGS=''
  RESCUE_PROFILE=web; RESCUE_START_TIMEOUT=5; RESCUE_KEEP=2
  RESCUE_AUTO=on; RESCUE_SELFHEAL=on
  RESCUE_REMOVE_LIMIT=2; RESCUE_ROLLBACK_LIMIT=2; RESCUE_INCIDENT_KEEP=20
  RESCUE_DIAGNOSE_EVIDENCE=off; RESCUE_SNAPSHOT_ON_HEALTHY=off; RESCUE_EVIDENCE_MAX=1048576
  RESCUE_DIAG=''; LOGTAG=''; LOGTEE=''
  RESCUE_PROBE="$T/probe-ok.js"; export RESCUE_PROBE
  STUB_DSH_MODE=ok; STUB_DSH_SLEEP=30; export STUB_DSH_MODE STUB_DSH_SLEEP
  rescue_supervise
) > "$T/c13.log" 2>&1 &
_sv_pid=$!
sleep 2
kill -TERM "$_sv_pid" 2>/dev/null || true
_i=0
while [ "$_i" -lt 150 ]; do kill -0 "$_sv_pid" 2>/dev/null || break; sleep 0.1; _i=$((_i + 1)); done
if kill -0 "$_sv_pid" 2>/dev/null; then
  kill -9 "$_sv_pid" 2>/dev/null || true
  echo 'FAIL-c13-supervise-did-not-exit-on-term'
  exit 1
fi
wait "$_sv_pid" 2>/dev/null; _c13rc=$?
grep -q 'forwarding to dsh' "$T/c13.log" || { echo 'FAIL-c13-signal-not-forwarded'; show "$T/c13.log"; exit 1; }
grep -q '"phase":"stopped"' "$DSH_HOME/.rescue/state/last-run.json" \
  || { echo "FAIL-c13-not-recorded-as-stopped: $(cat "$DSH_HOME/.rescue/state/last-run.json" 2>/dev/null)"; exit 1; }
[ "$_c13rc" = 0 ] || { echo "FAIL-c13-exit-code($_c13rc)"; show "$T/c13.log"; exit 1; }

# ---------------------------------------------------------------- C12
# 自愈靶子必须校验：target 来自诊断证据（日志文本），而日志内容可被第三方插件控制 ——
# 直接拼进命令行等于把"插件作者能写什么日志"提升为"root CLI 参数注入"。
rm -rf "$DSH_HOME/.rescue"
mkdir -p "$DSH_HOME/profiles/web"
printf '{"name":"web","private":true,"dependencies":{"legit-pkg":"1.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
REASON_SNAPSHOT=baseline rescue_snapshot >/dev/null 2>&1
run_supervise "$T/c12.log" RESCUE_PROBE="$T/probe-fail.js" RESCUE_DIAG="$T/diagnose-stub.js" \
  RESCUE_DIAGNOSE_EVIDENCE=on STUB_DIAG_HEAL=remove-plugin STUB_DIAG_TARGET='--global' STUB_DSH_MODE=noisy
grep -q 'invalid target' "$T/c12.log" || { echo 'FAIL-c12-option-injection-target-accepted'; show "$T/c12.log"; exit 1; }
grep -q 'remove-plugin: --global' "$T/c12.log" && { echo 'FAIL-c12-injected-target-executed'; exit 1; }

# 合法形态但不在依赖清单里的包同样必须拒绝（避免删掉清单外的条目）
printf '{"name":"web","private":true,"dependencies":{"legit-pkg":"1.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
run_supervise "$T/c12b.log" RESCUE_PROBE="$T/probe-fail.js" RESCUE_DIAG="$T/diagnose-stub.js" \
  RESCUE_DIAGNOSE_EVIDENCE=on STUB_DIAG_HEAL=remove-plugin STUB_DIAG_TARGET='not-a-dependency' STUB_DSH_MODE=noisy
grep -q 'not in profile dependencies\|不在当前 profile 依赖' "$T/c12b.log" \
  || { echo 'FAIL-c12b-non-dependency-target-accepted'; show "$T/c12b.log"; exit 1; }

# ---------------------------------------------------------------- C10
# 证据修剪在删除持续失败时**不得无限自旋**：它在 PID1 的启动路径上，一旦自旋容器就永远起不来、
# 单核跑满、还没有任何日志（旧实现用 while 循环重新统计，rm 恒失败时 n 永不下降）。
mkdir -p "$T/bin-rmfail"
printf '#!/bin/sh\nexit 1\n' > "$T/bin-rmfail/rm"
chmod +x "$T/bin-rmfail/rm"
_evp="$DSH_HOME/.rescue/evidence"
rm -rf "$_evp"
mkdir -p "$_evp/boot-1-20260101T000000" "$_evp/boot-1-20260101T000001" "$_evp/boot-1-20260101T000002"
(
  PATH="$T/bin-rmfail:$PATH"; export PATH
  RESCUE_KEEP=1; export RESCUE_KEEP
  rescue_evidence_prune
) >/dev/null 2>&1 &
_prune_pid=$!
sleep 3
if kill -0 "$_prune_pid" 2>/dev/null; then
  kill -9 "$_prune_pid" 2>/dev/null || true
  echo 'FAIL-c10-prune-spins-forever-on-rm-failure'
  exit 1
fi
wait "$_prune_pid" 2>/dev/null || true

# ---------------------------------------------------------------- C11
# 只剩 selfheal-* 现场快照时，绝不能拿它当回退目标：那是"自愈动作之前的坏现场"，
# 回滚到它只会把用户推回故障状态。
rm -rf "$DSH_HOME/.rescue"
mkdir -p "$DSH_HOME/profiles/web" "$DSH_HOME/.rescue/snap-0001"
printf '{"name":"web","private":true,"dependencies":{"stage":"live"}}' > "$DSH_HOME/profiles/web/package.json"
printf '{"name":"web","private":true,"dependencies":{"stage":"scene"}}' > "$DSH_HOME/.rescue/snap-0001/package.json"
printf '%s' '{"created":"2026-01-01T00:00:00+0800","reason":"selfheal-rollback snap-0000","profile":"web","mode":"hardlink","treeHash":""}' \
  > "$DSH_HOME/.rescue/snap-0001/meta.json"
if _t=$(rescue_pick_rollback_target 2>/dev/null) && [ -n "$_t" ]; then
  echo "FAIL-c11-picked-scene-snapshot(${_t})"
  exit 1
fi

# ---------------------------------------------------------------- C9
# rescue_close_ev 必须快速返回：tee 退出后不得继续等满超时（每次 boot 失败都会累积这笔开销）。
# 注：当前实现依赖"shell 会及时 reap 已退出的后台子进程"；若将来把等待逻辑换成更笨拙的实现
# （例如对僵尸进程用 kill -0 轮询——它对僵尸恒返回 0），这条断言会立刻变红。
sleep 0.1 & _fake=$!
sleep 0.5                       # 让它退出并停在僵尸状态（此处故意不 wait）
tee_pid=$_fake
t0=$(date +%s%N)
rescue_close_ev
t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
wait "$_fake" 2>/dev/null || true
[ "$ms" -lt 800 ] || { echo "FAIL-c9-close-ev-waits-for-zombie(${ms}ms)"; exit 1; }

# ---------------------------------------------------------------- C8
# 证据修剪必须按"创建时间"而不是目录名排序：boot-<attempt>-<ts> 里的 attempt 每次容器重启都会
# 回绕回 1，字典序会把"重启后第一轮的新证据"排到 boot-2-… 前面当成最老删掉 —— 目录刚建出来就
# 被自己删了（mkfifo 失败 → EVLOG 为空 → diagnose 无证据可读，自愈静默降级为 report-only）。
evroot="$DSH_HOME/.rescue/evidence"
rm -rf "$evroot"
mkdir -p "$evroot/boot-2-20260101T000000" "$evroot/boot-1-20260101T000001" "$evroot/boot-1-20260101T000002"
printf 'old\n' > "$evroot/boot-2-20260101T000000/dsh.log"
printf 'mid\n' > "$evroot/boot-1-20260101T000001/dsh.log"
printf 'cur\n' > "$evroot/boot-1-20260101T000002/dsh.log"
touch -t 202601010000.00 "$evroot/boot-2-20260101T000000"
touch -t 202601010000.01 "$evroot/boot-1-20260101T000001"
touch -t 202601010000.02 "$evroot/boot-1-20260101T000002"
RESCUE_KEEP=2 rescue_evidence_prune "$evroot/boot-1-20260101T000002"
[ -d "$evroot/boot-1-20260101T000002" ] || { echo 'FAIL-c8-prune-deleted-current-evidence'; exit 1; }
[ -d "$evroot/boot-2-20260101T000000" ] && { echo 'FAIL-c8-prune-kept-oldest-by-mtime'; exit 1; }

# ---------------------------------------------------------------- C6
# 场景（P1-3）：diagnose 建议回滚到"最新快照"，而该快照与 live 完全相同（自愈前刚拍的现场）。
# 期望：跳过这个 no-op 目标、改选更早的、指纹确实不同的快照；不得把空回滚记成 rollback ok。
rm -rf "$DSH_HOME/.rescue"
mkdir -p "$DSH_HOME/profiles/web"
printf '{"name":"web","private":true,"dependencies":{"stage":"A"}}' > "$DSH_HOME/profiles/web/package.json"
REASON_SNAPSHOT=baseline-A rescue_snapshot >/dev/null 2>&1
printf '{"name":"web","private":true,"dependencies":{"stage":"B"}}' > "$DSH_HOME/profiles/web/package.json"
REASON_SNAPSHOT=baseline-B rescue_snapshot >/dev/null 2>&1
run_supervise "$T/c6.log" RESCUE_PROBE="$T/probe-fail.js" RESCUE_DIAG="$T/diagnose-stub.js" \
  RESCUE_DIAGNOSE_EVIDENCE=on STUB_DIAG_TARGET=snap-0002 STUB_DSH_MODE=noisy
first_target=$(grep -o 'selfheal rollback to snap-[0-9]*' "$T/c6.log" | head -n1)
[ -n "$first_target" ] || { echo 'FAIL-c6-no-rollback-at-all'; show "$T/c6.log"; exit 1; }
[ "$first_target" = 'selfheal rollback to snap-0001' ] \
  || { echo "FAIL-c6-picked-noop-target($first_target)"; show "$T/c6.log"; exit 1; }

echo ALL-PASS
