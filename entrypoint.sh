#!/bin/sh
set -e

# ============================================================
# DSH 容器入口（构建时锁版本 + 容器内升级方案）
#   - 首次启动：从镜像内 /opt/dsh-seed 复制 dsh+pnpm 到挂载卷 /opt/dsh
#   - seed 缺失兜底：联网 npm install -g @deepseek-ai/dsh
#   - 日常升级：docker exec dsh npm install -g @deepseek-ai/dsh@<新版本>
#                docker restart dsh
#   - 无需重新构建/拉取镜像
# ============================================================

# 带时间戳日志（格式与 rescue.log 一致 %Y-%m-%dT%H:%M:%S%z）：docker logs 人读时间线
elog() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

if ! command -v dsh >/dev/null 2>&1; then
  elog "[entrypoint] 首次启动：准备 @deepseek-ai/dsh 到挂载卷 /opt/dsh ..."
  if [ -x /opt/dsh-seed/bin/dsh ]; then
    # 从镜像内 seed 复制：离线、版本固定、秒级完成
    elog "[entrypoint]   从镜像内 seed (/opt/dsh-seed) 复制到 /opt/dsh"
    mkdir -p /opt/dsh
    cp -a /opt/dsh-seed/. /opt/dsh/
    rm -rf /opt/dsh-seed   # 复制完清理：容器内不留重复副本（镜像层 seed 不变；回滚需 down+up 新容器）
  else
    # 兜底：seed 不存在（极少见，如手动精简镜像）时联网安装
    elog "[entrypoint]   seed 不存在，走 npm 在线安装"
    if [ -n "$NPM_REGISTRY" ]; then
      npm install -g @deepseek-ai/dsh --registry="$NPM_REGISTRY"
    else
      npm install -g @deepseek-ai/dsh
    fi
  fi
  elog "[entrypoint] DSH 已就绪: $(command -v dsh)"
fi

# pnpm：dsh plugin 命令（插件管理）转发到 pnpm 执行，必须可用
if ! command -v pnpm >/dev/null 2>&1; then
  elog "[entrypoint] 准备 pnpm（插件管理需要）..."
  if [ -x /opt/dsh-seed/bin/pnpm ]; then
    # dsh 段已复制过 seed 的话 pnpm 应已就位；这里兜底单独复制
    mkdir -p /opt/dsh
    cp -a /opt/dsh-seed/. /opt/dsh/
    rm -rf /opt/dsh-seed   # 兜底复制后同样清理
  elif [ -n "$NPM_REGISTRY" ]; then
    npm install -g pnpm --registry="$NPM_REGISTRY"
  else
    npm install -g pnpm
  fi
fi

# dsh web 刻意只监听 127.0.0.1（--host 0.0.0.0 被安全拒绝）。
# 端口分工：dsh 内部监听 127.0.0.1:3081；socat 把外部 0.0.0.0:3080 转发到 3081。
# （socat 不能听 3080 再让 dsh 也听 3080：0.0.0.0 会占用 127.0.0.1，必然 EADDRINUSE）
if command -v socat >/dev/null 2>&1; then
  elog "[entrypoint] 启动 socat 转发: 0.0.0.0:3080 -> 127.0.0.1:3081"
  # 上游 forever + intervall=1：socat 先于 dsh web 启动，dsh 监听 3081 前
  # 若有连接打到 3080，socat 会每秒重试直到 dsh 就绪，而不是抛 Connection refused
  socat TCP-LISTEN:3080,fork,reuseaddr TCP:127.0.0.1:3081,forever,intervall=1 &
fi

elog "[entrypoint] 启动 dsh web (内部 127.0.0.1:3081)"
# --no-open：容器内无浏览器，禁用 dsh 自动打开浏览器
# --trusted-host：dsh 0.1.2 的 /api 通道仅信任 loopback 或白名单 Host；
#   浏览器经局域网 IP / 隧道域名访问时被 403 拒绝（页面能开但连接异常）。
#   通过 DSH_TRUSTED_HOSTS 传入（逗号分隔，如 "192.168.1.5:3080,app.xx.com"）逐一加白。
TRUSTED_ARGS=""
if [ -n "$DSH_TRUSTED_HOSTS" ]; then
  elog "[entrypoint] 白名单 Host: $DSH_TRUSTED_HOSTS"
  for h in $(echo "$DSH_TRUSTED_HOSTS" | tr ',' ' '); do
    TRUSTED_ARGS="$TRUSTED_ARGS --trusted-host $h"
  done
fi
# ===================== 救援模式 =====================
# 加载共享库：优先 /opt/dsh-rescue（镜像内，独立于卷）。
# 缺失时降级为「无自动回退」：定义 no-op，保证老镜像/精简镜像仍能正常 exec 启动。
if [ -f /opt/dsh-rescue/librescue.sh ]; then
  . /opt/dsh-rescue/librescue.sh
else
  elog '[entrypoint] WARN librescue.sh not found; auto-rollback DISABLED'
  rescue_log() { :; }
  rescue_snapshot_list() { :; }
  rescue_live_differs_from() { echo 0; }
  rescue_restore() { :; }
  rescue_init_lifeboat() { :; }
  incident_dir() { printf '%s/incidents' "$RESCUE_DIR"; }
  evidence_dir() { printf '%s/evidence' "$RESCUE_DIR"; }
  state_dir() { printf '%s/state' "$RESCUE_DIR"; }
  rescue_incident_write() { :; }
  rescue_incident_list() { :; }
  rescue_incident_prune() { :; }
  rescue_state_write_lastrun() { :; }
  rescue_state_read_lastrun() { :; }
  rescue_state_write_selfheal() { :; }
  rescue_state_read_selfheal() { :; }
fi

PORT_INNER=3081
RESCUE_START_TIMEOUT="${RESCUE_START_TIMEOUT:-120}"
RESCUE_AUTO="${RESCUE_AUTO:-on}"
RESCUE_PROFILE="${RESCUE_PROFILE:-web}"
RESCUE_KEEP="${RESCUE_KEEP:-3}"
# rescue-diagnose 行为开关与限额（红线：绝不改 cordis.patch.yml / 会话 / 记忆 / 配置 / 凭据）
RESCUE_SELFHEAL="${RESCUE_SELFHEAL:-on}"
RESCUE_REMOVE_LIMIT="${RESCUE_REMOVE_LIMIT:-2}"
RESCUE_ROLLBACK_LIMIT="${RESCUE_ROLLBACK_LIMIT:-2}"
RESCUE_DIAGNOSE_EVIDENCE="${RESCUE_DIAGNOSE_EVIDENCE:-on}"
RESCUE_INCIDENT_KEEP="${RESCUE_INCIDENT_KEEP:-20}"

# 自愈 feature 可用性：diagnose.js 存在才算 enabled（正常镜像置于 /opt/dsh-rescue；仓库布局 fallback scripts/diagnose.js）
RESCUE_DIAG=
for _c in /opt/dsh-rescue/diagnose.js "$HERE/scripts/diagnose.js" "$HERE/diagnose.js"; do
  [ -f "$_c" ] && { RESCUE_DIAG="$_c"; break; }
done
[ -n "$RESCUE_DIAG" ] || elog '[entrypoint] WARN diagnose.js missing; auto-diagnose/self-heal DISABLED'

# 行时间戳过滤器（logtag.js）可用性：给 dsh 输出每行加时间戳；缺失时降级为无时间戳 tee 直连
LOGTAG=
for _c in /opt/dsh-rescue/logtag.js "$HERE/scripts/logtag.js" "$HERE/logtag.js"; do
  [ -f "$_c" ] && { LOGTAG="$_c"; break; }
done


boot_lifeboat() {
  # $1 = 进入 lifeboat 的原因（缺省=显式 RESCUE=1）；用于 echo 与审计日志，区分用户手动进 vs 回滚失败兜底进
  reason="${1:-rescue requested (RESCUE=1)}"
  elog "[entrypoint] booting clean lifeboat profile ($reason); no third-party plugins; data preserved"
  rescue_log "lifeboat enter: $reason"
  rescue_init_lifeboat
  exec dsh --profile lifeboat --port $PORT_INNER --no-open $TRUSTED_ARGS
}

if [ "${RESCUE:-0}" = "1" ]; then boot_lifeboat; fi

# 监督 + 自动回滚循环：把 dsh 作为子进程，启动窗口内探测 3081；
# 失败且 live 插件树 != 最新快照 -> 回滚并重启，最多 RESCUE_KEEP 次；耗尽退出交给 restart。
attempt=0
has_snap=0
[ -n "$(rescue_snapshot_list 2>/dev/null)" ] && has_snap=1
max_attempt=$((RESCUE_KEEP + 1))
probe=/opt/dsh-rescue/probe-ready.js
# [entrypoint] 控制器裁决：probe-ready.js 缺失（/opt/dsh-rescue 整体缺失/精简镜像/手工替换）
# 时无法监督 -> 降级为原始前台 exec，保证慢启动的健康 dsh 不被误杀。
if [ ! -f "$probe" ]; then
  elog '[entrypoint] probe-ready.js missing; supervision disabled - exec dsh directly'
  exec dsh --profile "$RESCUE_PROFILE" --port $PORT_INNER --no-open $TRUSTED_ARGS
fi
# ===== 归因自愈辅助（规范 §6；本环境仅静态校验，真机行为以宿主机 e2e 为准）=====
rescue_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
attempt_evdir() {
  ed="$(evidence_dir)/boot-$attempt-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$ed" 2>/dev/null && printf '%s' "$ed"
}
# 启动 dsh 子进程。RESCUE_DIAGNOSE_EVIDENCE=on 时尽力把输出 tee 到证据目录（同时保留容器日志）；
# 任何环节失败都回退为普通子进程（绝不让证据捕获阻塞或拖垮监督）。回填 $child、$EVLOG(=dsh.log,可空)。
rescue_start_child() {
  EVLOG=''; tee_pid=''
  if [ "$RESCUE_DIAGNOSE_EVIDENCE" = on ]; then
    ed="$(attempt_evdir)"
    if [ -n "$ed" ]; then
      rescue_evidence_prune
      fifo="$ed/dsh.fifo"
      if mkfifo "$fifo" 2>/dev/null; then
        EVLOG="$ed/dsh.log"
        if [ -n "$LOGTAG" ]; then
          # 逐行加时间戳后再 tee：docker logs 与 evidence/dsh.log 每行都带时间（格式同 elog）
          ( exec node "$LOGTAG" < "$fifo" 2>/dev/null ) | tee "$EVLOG" &
          tee_pid=$!
        else
          ( tee "$EVLOG" < "$fifo" ) & tee_pid=$!
        fi
        # 读写方式打开 fifo，使读端(logtag|tee)与 dsh 写端 open 都不阻塞（去死锁）
        exec 3<>"$fifo" 2>/dev/null || { rm -f "$fifo" 2>/dev/null || true; EVLOG=''; }
      fi
    fi
  fi
  if [ -n "$EVLOG" ]; then
    ( exec dsh --profile "$RESCUE_PROFILE" --port $PORT_INNER --no-open $TRUSTED_ARGS >&3 2>&1 ) &
    child=$!
  else
    dsh --profile "$RESCUE_PROFILE" --port $PORT_INNER --no-open $TRUSTED_ARGS &
    child=$!
  fi
}
rescue_close_ev() {
  exec 3>&- 2>/dev/null || true
  if [ -n "$tee_pid" ]; then kill "$tee_pid" 2>/dev/null || true; fi
  tee_pid=''
}
# evidence 修剪：dsh 日志经 tee 持续镜像到证据目录，按 boot-* 保留最近 RESCUE_KEEP 份，
# 防长期运行的 dsh.log 镜像无限累积（healthy 后 tee 不再被提前杀死）。
rescue_evidence_prune() {
  n=$(ls -1d "$(evidence_dir)"/boot-* 2>/dev/null | wc -l | tr -d ' ')
  while [ "$n" -gt "$RESCUE_KEEP" ]; do
    oldest=$(ls -1d "$(evidence_dir)"/boot-* 2>/dev/null | sort | head -n1)
    [ -n "$oldest" ] || break
    rm -rf "$oldest" 2>/dev/null || true
    n=$((n-1))
  done
}
# 诊断：返回 0 并回填 DIAG_JSON。仅当 diagnose 可用（RESCUE_DIAG）才调用。
rescue_diagnose() {
  ph="$1"; trg="$2"; evd="$3"
  [ -n "$RESCUE_DIAG" ] || return 1
  [ -n "$evd" ] || return 1
  out="$(node "$RESCUE_DIAG" --phase "$ph" --evidence "$evd" --rescue-dir "$RESCUE_DIR" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  DIAG_JSON="$out"
  return 0
}
# 写 incident（需 diagnose 产物 DIAG_JSON）。DIAGCAP=0 时 no-op。$1=resolve 词(空则按 journal 推断)。
rescue_write_incident() {
  [ "$DIAGCAP" = 1 ] || return 0
  resolve="$1"; evref="$2"
  [ -n "$DIAG_JSON" ] || return 0
  df="$SELFHEAL_JOURNAL.diag.json"; printf '%s\n' "$DIAG_JSON" > "$df"
  sh_out="$(node "$RESCUE_DIAG" --write-incident --diag-file "$df" --journal "$SELFHEAL_JOURNAL" --trigger "$SELFHEAL_TRIGGER" --evidence-ref "$evref" --resolve "$resolve" 2>/dev/null)"
  [ -n "$sh_out" ] || return 1
  id=$(rescue_incident_write "$sh_out")
  SELFHEAL_INCIDENT="$id"
  elog "[entrypoint] incident written: $id"
}
# 运行期崩溃 incident（规范 §6.2 / 文档 §4b）：下次启动读到上次 abnormalExit 时，写一条 phase=runtime 的
# report-only incident（保守：运行期崩溃仅报告归因、不自动摘/回退，供 rescue report 人工复核）。无 diagnose 则 no-op。
rescue_write_runtime_incident() {
  [ -n "$RESCUE_DIAG" ] || return 0
  body="$(node "$RESCUE_DIAG" --phase runtime --rescue-dir "$RESCUE_DIR" --write-incident --trigger child-exit --resolve report-only 2>/dev/null)" || return 1
  [ -n "$body" ] || return 1
  id=$(rescue_incident_write "$body")
  SELFHEAL_INCIDENT="$id"
  elog "[entrypoint] runtime incident written: $id"
  rescue_log "runtime incident written $id (abnormalExit)"
  return 0
}
rescue_budget_read() {
  bj="$(rescue_state_read_selfheal 2>/dev/null || true)"
  SELFHEAL_REMOVES=0; SELFHEAL_ROLLBACKS=0
  if [ -n "$bj" ]; then
    _rm=$(printf '%s' "$bj" | sed -n 's/.*"removes":\([0-9]*\).*/\1/p'); _rb=$(printf '%s' "$bj" | sed -n 's/.*"rollbacks":\([0-9]*\).*/\1/p')
    [ -n "$_rm" ] && SELFHEAL_REMOVES="$_rm"; [ -n "$_rb" ] && SELFHEAL_ROLLBACKS="$_rb"
  fi
}
rescue_budget_write() {
  rescue_state_write_selfheal "{\"removes\":$SELFHEAL_REMOVES,\"rollbacks\":$SELFHEAL_ROLLBACKS,\"updated\":\"$(rescue_ts)\"}" 2>/dev/null || true
}
rescue_journal_add() {
  [ -n "$SELFHEAL_JOURNAL" ] || return 0
  printf '%s|%s|%s|%s\n' "$1" "$2" "$(rescue_ts)" "$3" >> "$SELFHEAL_JOURNAL"
}
rescue_budget_check() {
  kind="$1"
  if [ "$kind" = remove ]; then [ "$SELFHEAL_REMOVES" -lt "$RESCUE_REMOVE_LIMIT" ]; return $?; fi
  [ "$SELFHEAL_ROLLBACKS" -lt "$RESCUE_ROLLBACK_LIMIT" ]
}
# ---- 自愈执行器：按 recommendedHeal 分派。返回 0=已改变插件树（应重试 boot）；非0=未改变（走 report/exit）。----
rescue_do_heal() {
  heal="$1"; target="$2"
  case "$heal" in
    remove-plugin)
      [ "$RESCUE_SELFHEAL" = on ] || { elog '[entrypoint] RESCUE_SELFHEAL=off; remove-plugin -> report-only'; return 1; }
      [ -n "$target" ] || { elog '[entrypoint] remove-plugin: no target -> report-only'; return 1; }
      if ! rescue_budget_check remove; then elog '[entrypoint] remove budget exceeded -> report-only'; return 1; fi
      # 捕获目标后再拍场景快照（rescue_snapshot 会覆盖全局 $snap/$target 等）
      RM_PKG="$target"
      REASON_SNAPSHOT="selfheal-remove $RM_PKG" rescue_snapshot >/dev/null 2>&1 || rescue_log 'selfheal: scene snapshot skipped'
      elog "[entrypoint] selfheal remove-plugin: $RM_PKG"
      if dsh plugin --profile "$RESCUE_PROFILE" remove "$RM_PKG" >/dev/null 2>&1; then
        SELFHEAL_REMOVES=$((SELFHEAL_REMOVES+1)); rescue_budget_write
        rescue_journal_add remove "$RM_PKG" ok; rescue_log "selfheal remove-plugin ok: $RM_PKG"; return 0
      fi
      rescue_journal_add remove "$RM_PKG" fail; rescue_log "selfheal remove-plugin FAILED: $RM_PKG"; return 1
      ;;
    rollback)
      [ "$RESCUE_SELFHEAL" = on ] || { elog '[entrypoint] RESCUE_SELFHEAL=off; rollback -> report-only'; return 1; }
      # 目标基线快照名需在本函数内独立持有：rescue_snapshot / rescue_restore 均会覆盖全局 $snap，
      # 若用 $snap 作目标，场景快照一建即被改写，回滚会错误地“恢复”到刚建的坏现场。
      RB_TARGET="$target"; [ -n "$RB_TARGET" ] || RB_TARGET="$newest_snap"
      [ -n "$RB_TARGET" ] || { elog '[entrypoint] rollback: no baseline -> report-only'; return 1; }
      if ! rescue_budget_check rollback; then elog '[entrypoint] rollback budget exceeded -> report-only'; return 1; fi
      REASON_SNAPSHOT="selfheal-rollback $RB_TARGET" rescue_snapshot >/dev/null 2>&1 || true
      elog "[entrypoint] selfheal rollback to $RB_TARGET"
      if rescue_restore "$RB_TARGET"; then
        SELFHEAL_ROLLBACKS=$((SELFHEAL_ROLLBACKS+1)); rescue_budget_write
        rescue_journal_add rollback "$RB_TARGET" ok; rescue_log "selfheal rollback ok: $RB_TARGET"; return 0
      fi
      rescue_journal_add rollback "$RB_TARGET" fail; rescue_log "selfheal rollback FAILED: $RB_TARGET"; return 1
      ;;
    *) return 1 ;;
  esac
}

# ---- 状态初始化（归因自愈用；本文件由 entrypoint 监督循环 source，须兼容 set -u）----
EVLOG=''; child=''; tee_pid=''; DIAG_JSON=''
DIAGCAP=0; [ -n "$RESCUE_DIAG" ] && DIAGCAP=1
SELFHEAL_JOURNAL=$(mktemp 2>/dev/null || printf '%s' /tmp/selfheal-journal)
rm -f "$SELFHEAL_JOURNAL" "$SELFHEAL_JOURNAL.diag.json"
SELFHEAL_TRIGGER='boot'; SELFHEAL_INCIDENT=''; evref=''
SELFHEAL_REMOVES=0; SELFHEAL_ROLLBACKS=0
rescue_budget_read

# 最新快照（既有“回滚最新”兜底目标 + 基线参考）
newest_snap=''
[ -n "$(rescue_snapshot_list 2>/dev/null)" ] && newest_snap=$(rescue_snapshot_list 2>/dev/null | tail -n1 | xargs -r basename)

# 上次运行 abnormalExit（运行期崩溃补判，规范 §6.2）：记录即可；自动处置交由报告人工复核（保守默认）
lr=$(rescue_state_read_lastrun 2>/dev/null || true)
if [ -n "$lr" ]; then
  _ab=$(printf '%s' "$lr" | sed -n 's/.*"abnormalExit":\(true\|false\).*/\1/p')
  if [ "$_ab" = true ]; then
    elog '[entrypoint] last run abnormal exit recorded; writing runtime incident for rescue report review'
    rescue_write_runtime_incident
  fi
fi
while :; do
  attempt=$((attempt + 1))
  elog "[entrypoint] boot attempt $attempt/$max_attempt (profile=$RESCUE_PROFILE)"
  SELFHEAL_TRIGGER="boot-attempt-$attempt"
  rescue_start_child
  if node "$probe" "$PORT_INNER" "$((RESCUE_START_TIMEOUT * 1000))"; then
    elog "[entrypoint] dsh healthy on 127.0.0.1:$PORT_INNER"
    # 修复(丢日志根因)：healthy 后不能杀 tee——tee 是 fifo 唯一读端，杀它会让 dsh
    # 后续 stdout 输出无读者而全部丢弃（v0.3.0 tee 证据捕获引入：docker logs 在
    # healthy 之后不再有 dsh 日志）。只释放 entrypoint 自己的写端，tee 继续把 dsh
    # 输出转发到容器 stdout(即 docker logs)与 evidence；dsh 退出(写端 EOF)后 tee 自然结束。
    exec 3>&- 2>/dev/null || true
    rescue_state_write_lastrun "{\"phase\":\"healthy\",\"ts\":\"$(rescue_ts)\",\"pid\":\"$child\",\"abnormalExit\":false}" 2>/dev/null || true
    rc=0
    wait "$child" || rc=$?
    if [ "$rc" -ne 0 ]; then
      rescue_state_write_lastrun "{\"phase\":\"runtime-crash\",\"ts\":\"$(rescue_ts)\",\"exit\":\"$rc\",\"abnormalExit\":true}" 2>/dev/null || true
      rescue_log "dsh crashed after healthy rc=$rc; exit for docker restart policy"
    else
      rescue_state_write_lastrun "{\"phase\":\"exited\",\"ts\":\"$(rescue_ts)\",\"exit\":0,\"abnormalExit\":false}" 2>/dev/null || true
    fi
    exit "$rc"
  fi
  elog "[entrypoint] dsh not ready within ${RESCUE_START_TIMEOUT}s (attempt $attempt)"
  kill "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  rescue_close_ev
  rescue_state_write_lastrun "{\"phase\":\"boot-fail\",\"ts\":\"$(rescue_ts)\",\"attempt\":\"$attempt\",\"abnormalExit\":false}" 2>/dev/null || true

  # ---- 归因判定：有证据文本 -> diagnose；无诊断能力/无证据 -> 走既有“回滚最新快照”兜底 ----
  evdir=''
  if [ -n "$EVLOG" ] && [ -s "$EVLOG" ]; then evdir="$(dirname "$EVLOG")"; fi
  DIAG_JSON=''; heal=''; target=''; diag_ok=0
  if [ -n "$evdir" ] && rescue_diagnose boot probe-timeout "$evdir"; then
    diag_ok=1
    heal=$(printf '%s' "$DIAG_JSON" | sed -n 's/.*"recommendedHeal":"\([^"]*\)".*/\1/p')
    target=$(printf '%s' "$DIAG_JSON" | sed -n 's/.*"recommendedTarget":"\([^"]*\)".*/\1/p')
    elog "[entrypoint] diagnosis -> heal=$heal target=$target"
  elif [ "$RESCUE_AUTO" = on ] && [ "$has_snap" = 1 ] && [ "$attempt" -lt "$max_attempt" ]; then
    # 无证据/无 diagnose 时的既有兜底：live != 最新快照则回滚最新快照
    ns="$newest_snap"
    if [ -n "$ns" ]; then
      dfr=$(rescue_live_differs_from "$ns" 2>/dev/null || echo 0)
      if [ "$dfr" = 1 ]; then heal='rollback'; target="$ns"; elog "[entrypoint] no-evidence fallback: rollback to $ns"; fi
    fi
  fi

  healed=0
  if [ -n "$heal" ]; then
    case "$heal" in
      remove-plugin|rollback)
        if rescue_do_heal "$heal" "$target"; then
          healed=1
          if [ "$attempt" -lt "$max_attempt" ]; then
            rescue_write_incident "" "$evdir"
            continue
          fi
        fi
        ;;
    esac
  fi
  # ---- 未自愈：写 incident(report-only) 后按既有语义 exit（docker restart 策略/手动 RESCUE=1 进 lifeboat）----
  if [ "$healed" = 1 ]; then
    elog '[entrypoint] self-heal applied but max_attempt reached; lifecycle exit for docker restart'
  else
    if [ -n "$diag_ok" ] && [ "$diag_ok" = 1 ]; then
      elog '[entrypoint] no recoverable self-heal; writing report-only incident'
      rescue_write_incident report-only "$evdir"
    fi
    elog '[entrypoint] boot not recoverable -> exit for docker restart policy'
  fi
  rescue_log 'boot exhausted; exit for docker restart policy'
  exit 1
done
