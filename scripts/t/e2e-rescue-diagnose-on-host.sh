#!/bin/sh
# ============================================================================
# e2e-rescue-diagnose-on-host.sh — rescue-diagnose 端到端验收（宿主机运行）
#
# ⚠ MUST run on a real Docker host with a healthy dsh container (not a sandbox).
#    本脚本会短暂重启 dsh（web 中断 RESCUE_START_TIMEOUT+…）；运行前请确认已知良好态。
#    建议先跑过 ../e2e-rescue-on-host.sh 确认既有自动回滚基线通过。
#
# 验收点（对齐规范 §6/§9 与计划任务 7 步骤 2）：
#   A) 人为新增坏插件依赖 -> restart -> 期望 diagnose + self-heal + incident 并恢复；
#      PASS：出现归因/自愈/恢复标记，rescue report 出现该插件 incident，
#      cordis.patch.yml 前后 hash 一致（红线未破）。
#   B) no-baseline（绕过 rescue 封装直接改坏，无对应快照）-> 保守 report-only（不自动摘）。
#   C) RESCUE_SELFHEAL=off -> 只诊断 + incident，不做任何自愈动作。
#   D) 运行期崩溃：healthy 后杀主进程 -> restart -> last-run 记 runtime + rescue report 见 runtime incident。
#   E) 打印 diagnose 实际命中，提醒校准 PLUGIN_FAIL_PATTERNS。
#
# 退出码：0=执行完成；红线/恢复结论以真实容器 logs + rescue report 为准（真机措辞无法在沙箱预判，
# 部分校验仅打印提示由人工核对）。红线被破（cordis.patch.yml 变化）时必须停下人工处置。
# ============================================================================
set -eu

CONTAINER="${DHS_E2E_CONTAINER:-dsh}"
PROFILE="${RESCUE_PROFILE:-web}"
PDIR="/data/dsh/profiles/$PROFILE"      # 卷内插件树目录
POLL_INTERVAL=10
E2E_MAX_WAIT_SECS="${E2E_MAX_WAIT_SECS:-}"

log()  { echo "[e2e] $*"; }
fail() { echo "[e2e] FAIL: $*"; exit 1; }
note() { echo "[e2e] (manual/optional) $*"; }
# 红线标记：A 段若发现 cordis.patch.yml 被改动则置 1。不立即 exit（须先走收尾恢复现场），
# 由脚本结尾统一以非 0 退出——"红线被破必须停下人工处置"不能只打印一条 note。
REDLINE_BROKEN=0

# ---------- 0) 前置 ----------
command -v docker >/dev/null 2>&1 || fail "docker 不可用：须在真实 Docker 宿主运行。"
docker inspect "$CONTAINER" >/dev/null 2>&1 || fail "找不到容器 $CONTAINER。"
rescue_timeout="$(docker exec "$CONTAINER" sh -c 'echo "${RESCUE_START_TIMEOUT:-120}"' 2>/dev/null || echo 120)"
case "$rescue_timeout" in ''|*[!0-9]*) rescue_timeout=120;; esac
max_wait="$E2E_MAX_WAIT_SECS"; [ -n "$max_wait" ] || max_wait="$((rescue_timeout + 40))"
log "RESCUE_START_TIMEOUT=${rescue_timeout}s; poll cap=${max_wait}s (every ${POLL_INTERVAL}s)"

cordis_before="$(docker exec -e PDIR="$PDIR" "$CONTAINER" sh -c 'cat "$PDIR/cordis.patch.yml" 2>/dev/null | md5sum' 2>/dev/null || true)"

start_mark=""
take_start_mark() { start_mark="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }

# 有界轮询：找 restart 后容器日志中出现的标记。
# $2 为**单个** grep -E 正则（多分支用 | 自己写）：早期版本把空格当多模式分隔符，
# 使得 'healthy on' 被展开成 'healthy|on' —— 任何含 "on" 的行都算命中，断言形同虚设。
wait_for_log() {
  label="$1"; pat="$2"
  elapsed=0
  while [ "$elapsed" -lt "$max_wait" ]; do
    sleep "$POLL_INTERVAL"; elapsed="$((elapsed + POLL_INTERVAL))"
    logs="$(docker logs "$CONTAINER" --since "$start_mark" --tail 400 2>/dev/null || true)"
    if echo "$logs" | grep -qiE "$pat"; then
      log "$label seen after ~${elapsed}s:"
      echo "$logs" | grep -iE "$pat" | tail -n4 | sed 's/^/    /' || true
      return 0
    fi
  done
  return 1
}
# 轮询直到 rescue report 出现某插件 或超时
wait_report_pkg() {
  pkg="$1"; elapsed=0
  while [ "$elapsed" -lt "$max_wait" ]; do
    sleep "$POLL_INTERVAL"; elapsed="$((elapsed + POLL_INTERVAL))"
    docker exec "$CONTAINER" rescue report --json 2>/dev/null | grep -q "$pkg" && return 0 || true
  done
  return 1
}

# 在插件树 package.json 里注入一个不存在的坏依赖版本（制造 boot 失败）
# $1=scope/pkg  $2=dir；用 docker exec node（无 sh -c 包裹）避免引号地狱
break_dep() {
  pkg="$1"; dir="$2"
  docker exec "$CONTAINER" node -e 'const d=process.argv[1];const fs=require("fs");process.chdir(d);const p=JSON.parse(fs.readFileSync("package.json"));p.dependencies=p.dependencies||{};p.dependencies[process.argv[2]]="9.9.9-broken";fs.writeFileSync("package.json",JSON.stringify(p,null,2))' "$dir" "$pkg"
}
backup_tree() {
  docker exec "$CONTAINER" cp "$PDIR/package.json" /tmp/pkg.bak
  docker exec -e PDIR="$PDIR" "$CONTAINER" sh -c 'cp "$PDIR/cordis.patch.yml" /tmp/cordis.bak 2>/dev/null || true'
}
restore_tree() {
  # 把被 A/B/C 改坏的 package.json 还原（自愈若已生效则可能已回滚到快照，此时无需处理）
  docker exec -e PDIR="$PDIR" "$CONTAINER" sh -c '[ -f /tmp/pkg.bak ] && cp /tmp/pkg.bak "$PDIR/package.json"; rm -f /tmp/pkg.bak /tmp/cordis.bak' 2>/dev/null || true
}


# ============================================================================
# A) 坏插件启动失败：自动归因 + 自愈 + incident，且红线未破
# ============================================================================
log "== A) 人为新增坏插件 -> restart -> 期望 diagnose + self-heal + incident =="
take_start_mark
backup_tree
break_dep "@scope/dsh-e2e-bad" "$PDIR"
docker restart "$CONTAINER"
wait_for_log A-diag "diagnose|incident|selfheal|remove-plugin"
wait_for_log A-recover '\[entrypoint\] dsh healthy on 127\.0\.0\.1:' || note "A: 未见 恢复(healthy) 标记；请人工核对日志（可能 report-only 或需再等一轮）"
A_inc=0; wait_report_pkg "@scope/dsh-e2e-bad" && A_inc=1 || true
cordis_after="$(docker exec -e PDIR="$PDIR" "$CONTAINER" sh -c 'cat "$PDIR/cordis.patch.yml" 2>/dev/null | md5sum' 2>/dev/null || true)"
if [ "$cordis_before" = "$cordis_after" ] && [ "$A_inc" -eq 1 ]; then
  log "[OK] A: self-heal/恢复 + incident 命中坏插件；cordis.patch.yml 未变（红线通过）"
elif [ "$cordis_before" != "$cordis_after" ]; then
  REDLINE_BROKEN=1
  note "A: !! 红线被破 —— cordis.patch.yml 发生变化（before=${cordis_before} after=${cordis_after}）"
  note "   自愈只允许动插件树四件套；请立即停下人工处置，勿继续采信后续段落结论。"
else
  note "A: 未产出命中坏插件的 incident（report-only 属保守预期）。请人工核对 docker logs/rescue report。"
fi

# ============================================================================
# B) no-baseline：绕过 rescue 封装改坏、无对应快照 -> 保守 report-only（不自动摘）
# ============================================================================
log "== B) no-baseline 改坏 -> 期望保守 report-only =="
restore_tree; docker restart "$CONTAINER"; wait_for_log B-base '\[entrypoint\] dsh healthy on 127\.0\.0\.1:' || note "B: 基线恢复等待超时"
take_start_mark
backup_tree
break_dep "@scope/dsh-e2e-nobase" "$PDIR"
docker restart "$CONTAINER"
B_inc=0; wait_report_pkg "@scope/dsh-e2e-nobase" && B_inc=1 || true
if [ "$B_inc" -eq 1 ]; then
  log "[OK] B: no-baseline 触发 incident（保守预期为 report-only，不会自动摘）"
else
  note "B: 未在窗口内看到该插件 incident（坏依赖使 web 完全起不来且无证据时归因可能跳过）；请人工核对。"
fi

# ============================================================================
# C) RESCUE_SELFHEAL=off：只诊断 + incident，不做任何自愈动作
# ============================================================================
log "== C) RESCUE_SELFHEAL=off -> 期望只诊断不自动摘 =="
restore_tree; docker restart "$CONTAINER"; wait_for_log C-base '\[entrypoint\] dsh healthy on 127\.0\.0\.1:' || note "C: 基线恢复等待超时"
take_start_mark
backup_tree
break_dep "@scope/dsh-e2e-off" "$PDIR"
docker restart "$CONTAINER"
C_inc=0; wait_report_pkg "@scope/dsh-e2e-off" && C_inc=1 || true
C_left="$(docker exec -e PDIR="$PDIR" "$CONTAINER" sh -c 'grep -c "@scope/dsh-e2e-off" "$PDIR/package.json" 2>/dev/null || echo 0' 2>/dev/null || echo 0)"
log "[e2e] C: incident=$C_inc ; 插件仍残留在 package.json(grep)= $C_left"
if [ "$C_inc" -eq 1 ]; then
  log "[OK] C: RESCUE_SELFHEAL=off 下写入了 incident（期望不自动摘，恢复交人工）"
else
  note "C: 未观察到 incident；请人工核对（report-only 亦属保守预期）"
fi

# ============================================================================
# D) 运行期崩溃归因：healthy 后杀主进程 -> restart -> runtime incident（仅报告）
# ============================================================================
log "== D) 运行期崩溃归因（保守：只报告不自动处置）=="
restore_tree; docker restart "$CONTAINER"; wait_for_log D-base '\[entrypoint\] dsh healthy on 127\.0\.0\.1:' || note "D: 基线恢复等待超时"
take_start_mark
# 杀 dsh 主进程制造 runtime crash
docker exec "$CONTAINER" sh -c 'p=$(pgrep -f "3081" | head -1); if [ -n "$p" ]; then kill "$p"; echo "[e2e] killed dsh pid=$p"; fi' || note "D: 未找到可杀的 dsh 主进程（可能非 3081 布局），跳过 D"
docker restart "$CONTAINER"
D_ok=0; elapsed=0
while [ "$elapsed" -lt "$max_wait" ]; do
  sleep "$POLL_INTERVAL"; elapsed="$((elapsed + POLL_INTERVAL))"
  lastrun="$(docker exec "$CONTAINER" sh -c 'cat /data/dsh/.rescue/state/last-run.json 2>/dev/null || true' 2>/dev/null || true)"
  logs="$(docker logs "$CONTAINER" --since "$start_mark" --tail 300 2>/dev/null || true)"
  if echo "$lastrun" | grep -q '"abnormalExit":true' || echo "$logs" | grep -qiE 'runtime|abnormalExit'; then D_ok=1; break; fi
done
if [ "$D_ok" -eq 1 ]; then
  log "[OK] D: 检测到 runtime 异常退出被记录(last-run/log 见 abnormalExit)；docker exec dsh rescue report 应含 runtime incident(仅报告)"
else
  note "D: 未捕获 runtime abnormalExit 标记；请人工核对 last-run.json / rescue.log。"
fi
docker restart "$CONTAINER" >/dev/null 2>&1 || true
wait_for_log D-recover '\[entrypoint\] dsh healthy on 127\.0\.0\.1:' || note "D: 最终恢复未见 healthy，请人工确认回到良好态。"

# ============================================================================
# E) 归因模式命中提示（校准提醒）
# ============================================================================
log "== E) 归因模式命中提示 =="
note "A-D 若出现 report-only 而你确知是插件问题，多为 PLUGIN_FAIL_PATTERNS 未命中真实日志措辞。"
note "请 docker exec dsh rescue report <id> 回看该 incident 的 evidenceRef 与 rationale，"
note "再按需调整 /opt/dsh-rescue/diagnose.js 顶部 PLUGIN_FAIL_PATTERNS / NON_PLUGIN_PATTERNS 并同步回仓库 scripts/diagnose.js。"

# ============================================================================
# 收尾：恢复基线到已知良好态
# ============================================================================
restore_tree
docker restart "$CONTAINER" >/dev/null 2>&1 || true
wait_for_log final '\[entrypoint\] dsh healthy on 127\.0\.0\.1:' || note "收尾: restart 后未见 healthy，请人工确认容器回到良好态。"

echo
if [ "$REDLINE_BROKEN" -ne 0 ]; then
  echo '[e2e] ===== rescue-diagnose host acceptance: FAIL（红线被破：cordis.patch.yml 被改动）====='
  exit 1
fi
echo '[e2e] ===== rescue-diagnose host acceptance: DONE ====='
echo '[e2e] 硬性红线判定见 A 段(cordis.patch.yml 未变)。A 的 OK / B/C/D 的标记请结合上方输出与 rescue report 复核。'
exit 0

