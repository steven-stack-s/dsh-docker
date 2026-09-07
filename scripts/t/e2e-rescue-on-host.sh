#!/bin/sh
# ============================================================================
# e2e-rescue-on-host.sh — 救援模式端到端验收脚本（宿主机运行）
#
# ⚠  IMPORTANT — MUST run on a real Docker host, NOT in a sandbox/CI without docker.
#    本脚本依赖 docker，并会短暂重启 dsh 容器（web 会中断一段时间）。
#    运行前请确认：
#      - 宿主机可用 docker，且当前有健康运行的 dsh 容器（作为 restart 前的良好基线）
#      - 已配置 .env（DEEPSEEK_API_KEY 等），本次验证前的状态是“已知良好”
#      - 能接受 dsh web 中断约 RESCUE_START_TIMEOUT(默认 120s) + 一次完整重启的时间
#
# 验收流程（对应 rescue 设计规范 §9 测试策略 与实施计划步骤 1-5）：
#   1) rescue status              —— 查看快照 / 版本 / 最后日志（只读）
#   2) rescue snapshot            —— 手动为当前“良好”插件树做快照（作为回退目标）
#   3) 人为改坏 web 依赖          —— 模拟坏插件（把 @deepseek-ai/dsh-web-app 指向不存在的版本）
#   4) docker restart dsh         —— 观察 entrypoint 是否自动回退到步骤 2 的快照并恢复健康
#   5) 恢复现场（放在 trap/finally，即使步骤 4 提前失败/中断也会执行）：
#      把 /tmp/pkg.bak 还原回 package.json 并重启容器
#
# 定时设计说明（重要，勿改回固定 sleep）：
#   entrypoint 先以子进程启动 dsh web 并对 127.0.0.1:3081 做就绪探测，等待时长由
#   RESCUE_START_TIMEOUT 决定（默认 120s）。依赖被改坏后 dsh 永远无法打开 3081 →
#   探测须等满整个 RESCUE_START_TIMEOUT 才判定失败 → 才触发自动回滚 → 再重新 boot 探测。
#   因此“回滚发生”远晚于 restart 之后的固定 sleep(25s)。本脚本用【有界轮询】代替：
#     - 每 ~10s 抓一次 docker logs（--since 起始标记，排除 restart 前的旧 healthy 行）
#     - 累计最长等待 = RESCUE_START_TIMEOUT + 40s（可用 E2E_MAX_WAIT_SECS 覆盖）
#     - 同时观察到回滚标记 + 健康标记 → PASS；到点未见 → FAIL 并打印尾部日志供人工核对
#   回滚/健康日志的精确措辞只在真实容器内核对（无法在本沙箱预判），故 grep 用宽松集合：
#     rollback | restored | healthy | rescue
#
# 退出码：0 = PASS（观察到回滚 + 恢复健康）；1 = FAIL/异常
# ============================================================================
set -eu

CONTAINER="${DHS_E2E_CONTAINER:-dsh}"
PROFILE="${RESCUE_PROFILE:-web}"
# PASS 后自动回滚已把 profile 还原为良好快照，置 1 让 cleanup 不再重复恢复/重启
already_restored=0
# 默认最长轮询等待 = RESCUE_START_TIMEOUT + 40；可显式覆盖
E2E_MAX_WAIT_SECS="${E2E_MAX_WAIT_SECS:-}"
POLL_INTERVAL=10

log()  { echo "[e2e] $*"; }
fail() { echo "[e2e] FAIL: $*"; exit 1; }

# ---------- 0) 前置检查（必须在真实 docker 宿主） ----------
command -v docker >/dev/null 2>&1 || fail "docker 不可用：本脚本必须在真实 Docker 宿主机上运行（沙箱/无 docker 环境不能真实验收）。"
docker inspect "$CONTAINER" >/dev/null 2>&1 || fail "找不到容器 $CONTAINER，请先 docker compose up -d 启动 dsh。"

# 读取容器内实际 RESCUE_START_TIMEOUT（restart 前健康态即可读），用于计算轮询上限
timeout_default=120
rescue_timeout="$(docker exec "$CONTAINER" sh -c 'echo "${RESCUE_START_TIMEOUT:-120}"' 2>/dev/null || echo "$timeout_default")"
case "$rescue_timeout" in ''|*[!0-9]*) rescue_timeout="$timeout_default";; esac
if [ -n "$E2E_MAX_WAIT_SECS" ]; then
  max_wait="$E2E_MAX_WAIT_SECS"
else
  max_wait="$((rescue_timeout + 40))"
fi
log "RESCUE_START_TIMEOUT=${rescue_timeout}s，轮询最长上限=${max_wait}s（每 ${POLL_INTERVAL}s）"

# 记录日志时间起点：只统计 restart 之后新 boot 的标记，排除 restart 前的旧 healthy 行
start_mark="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------- 步骤 5 恢复现场放在 trap/finally：任何失败/中断/正常结束都会执行 ----------
cleanup() {
  log "步骤 5 恢复现场（trap 触发）..."
  # 容器在轮询失败/中断后可能处于 crashloop/重启中，docker exec 未必可用 → 全部 || true
  if [ "$already_restored" -eq 0 ]; then
    docker exec -e PROF="$PROFILE" "$CONTAINER" sh -c '[ -f /tmp/pkg.bak ] && cd /data/dsh/profiles/$PROF && cp /tmp/pkg.bak package.json && rm -f /tmp/pkg.bak' 2>/dev/null || true
    docker restart "$CONTAINER" 2>/dev/null || true
    log "现场已恢复（package.json 已还原，容器已请求重启）；请稍候确认 dsh 回到 healthy。"
  else
    # PASS 路径：自动回滚已把 profile 还原为良好快照，无需改 package.json / 无需再重启；仅清理临时备份
    docker exec "$CONTAINER" sh -c 'rm -f /tmp/pkg.bak' 2>/dev/null || true
    log "PASS 路径：自动回滚已还原 profile，仅清理 /tmp/pkg.bak（不再重复重启）。"
  fi
}
trap cleanup EXIT INT TERM

# ---------- 1) status ----------
log '== 1) 查看救援状态（只读） =='
docker exec "$CONTAINER" rescue status

# ---------- 2) 快照当前良好态 ----------
log '== 2) 手动快照当前良好态 =='
docker exec "$CONTAINER" rescue snapshot

# ---------- 3) 人为改坏 web 依赖（模拟坏插件） ----------
log '== 3) 人为把 web 依赖改坏（模拟坏插件） =='
docker exec -e PROF="$PROFILE" "$CONTAINER" sh -c 'cd /data/dsh/profiles/$PROF && cp package.json /tmp/pkg.bak && node -e "const fs=require(\"fs\");const p=JSON.parse(fs.readFileSync(\"package.json\"));if(!p.dependencies)p.dependencies={};p.dependencies[\"@deepseek-ai/dsh-web-app\"]=\"0.0.0-broken\";fs.writeFileSync(\"package.json\",JSON.stringify(p,null,2))"'

# ---------- 4) 重启并轮询观察自动回滚 + 恢复健康 ----------
log '== 4) 重启，轮询观察 entrypoint 是否自动回滚并恢复 =='
docker restart "$CONTAINER"

# 有界轮询：自动回滚只在 RESCUE_START_TIMEOUT 探测超时后才发生（见文件头定时说明）。
# 回滚/健康日志措辞只在真实容器内核对，故用宽松集合 grep。
rollback_seen=0
healthy_seen=0
elapsed=0
while [ "$elapsed" -lt "$max_wait" ]; do
  sleep "$POLL_INTERVAL"
  elapsed="$((elapsed + POLL_INTERVAL))"
  logs="$(docker logs "$CONTAINER" --since "$start_mark" --tail 200 2>/dev/null || true)"
  if [ "$rollback_seen" -eq 0 ] && echo "$logs" | grep -qiE "rollback|restored|rolling back"; then
    rollback_seen=1
    log "检测到【回滚】标记（restart 后约 ${elapsed}s）："
    echo "$logs" | grep -iE "rollback|restored|rolling back" | tail -n3 | sed 's/^/    /' || true
  fi
  if [ "$healthy_seen" -eq 0 ] && echo "$logs" | grep -qiE "healthy|listening"; then
    healthy_seen=1
    log "检测到【健康/恢复】标记（restart 后约 ${elapsed}s）："
    echo "$logs" | grep -iE "healthy|listening" | tail -n3 | sed 's/^/    /' || true
  fi
  if [ "$rollback_seen" -eq 1 ] && [ "$healthy_seen" -eq 1 ]; then
    log "轮询中止：回滚与健康均已观察到（${elapsed}s）"
    break
  fi
done

echo
echo '== 结束：验收判定 =='
docker logs "$CONTAINER" --since "$start_mark" --tail 200 2>/dev/null | grep -iE "rollback|restored|healthy|rescue" | tail -n20 | sed 's/^/  /' || true
echo

if [ "$rollback_seen" -eq 1 ] && [ "$healthy_seen" -eq 1 ]; then
  already_restored=1
  echo "[e2e] PASS ✅ 自动回滚到快照并已恢复健康（rollback + healthy 均已观察到）"
  exit 0
fi
if [ "$rollback_seen" -eq 1 ]; then
  echo "[e2e] FAIL ❌ 已观察到回滚，但未在时限内观察到健康标记（web 可能仍未恢复）。"
else
  echo "[e2e] FAIL ❌ 未在 ${max_wait}s 内观察到回滚标记。"
  echo "[e2e]      可能原因：容器内无可用快照 / RESCUE_AUTO=off / 该坏依赖未致命 / 轮询上限过短。"
  echo "[e2e]      请人工核对上方 docker logs 尾部输出。"
fi
exit 1
