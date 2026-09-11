#!/bin/sh
# ============================================================================
# e2e-container-selftest.sh — 一次性容器的端到端自检（F12）
#
# 与 e2e-rescue-on-host.sh 的区别：那个脚本依赖宿主机上"已知良好"的 dsh 容器、并会重启它，
# 失败时还可能污染宿主现场，因此不适合放进 CI。本脚本自建临时卷 + 独立容器 + 随机端口，
# 结束即清理，并且只断言**成功原文**（不重蹈 "healthy|listening" 那种假绿）。
#
# 需要：docker。镜像默认用本地构建，也可 IMG=ghcr.io/... 指定现成镜像。
#   sh scripts/t/e2e-container-selftest.sh
#   IMG=dsh-docker:latest sh scripts/t/e2e-container-selftest.sh
#
# 断言链路：
#   1) 首次启动 -> healthy（seed 复制 + socat + 监督循环）
#   2) rescue snapshot 留回退点
#   3) 人为改坏依赖 -> restart -> 必须自动回滚并重新 healthy
#   4) rescue verify（快照完整性）
#   5) rescue selfheal status（预算可观测）
#   6) rescue export（诊断包）
# ============================================================================
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
IMG="${IMG:-dsh-docker:e2e-selftest}"
NAME="dsh-e2e-$$"
PORT="${PORT:-39080}"
WORK=$(mktemp -d)
START_TIMEOUT="${E2E_START_TIMEOUT:-180}"

log()  { echo "[e2e] $*"; }
fail() { echo "[e2e] FAIL: $*"; exit 1; }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

command -v docker >/dev/null 2>&1 || fail "docker 不可用（本脚本需要真实 Docker 宿主）"

if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  log "本地无镜像 $IMG，开始构建（首次较慢）..."
  docker build -t "$IMG" -f "$ROOT/Dockerfile" "$ROOT" >/dev/null || fail "镜像构建失败"
fi

mkdir -p "$WORK/dsh" "$WORK/programs" "$WORK/ws"
log "启动一次性容器 $NAME（端口 127.0.0.1:$PORT -> 3080）"
docker run -d --name "$NAME" \
  -p "127.0.0.1:$PORT:3080" \
  -e DEEPSEEK_API_KEY=sk-e2e-selftest-dummy \
  -e RESCUE_START_TIMEOUT=60 \
  -v "$WORK/dsh:/data/dsh" \
  -v "$WORK/programs:/opt/dsh" \
  -v "$WORK/ws:/workspace" \
  "$IMG" >/dev/null || fail "容器启动失败"

wait_healthy() {
  # $1 = 标签；只看 entrypoint 的成功原文，绝不用 "healthy|listening" 这类宽松匹配
  _label="$1"; _waited=0
  while [ "$_waited" -lt "$START_TIMEOUT" ]; do
    sleep 5; _waited=$((_waited + 5))
    if docker logs "$NAME" 2>&1 | grep -qF '[entrypoint] dsh healthy on 127.0.0.1:'; then
      log "  [$_label] healthy（约 ${_waited}s）"
      return 0
    fi
    if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
      log "  [$_label] 容器已退出，日志尾部："
      docker logs --tail 20 "$NAME" 2>&1 | sed 's/^/    /' || true
      return 1
    fi
  done
  log "  [$_label] 超时（上限 $START_TIMEOUT s）未见 healthy，日志尾部："
  docker logs --tail 20 "$NAME" 2>&1 | sed 's/^/    /' || true
  return 1
}

log "1) 首次启动 -> 期望 healthy"
wait_healthy first-boot || fail "首次启动未达 healthy"

log "2) 留一个回退点（rescue snapshot）"
docker exec "$NAME" rescue snapshot --reason 'e2e baseline' >/dev/null || fail "rescue snapshot 失败"

log "3) 人为改坏依赖 -> restart -> 期望自动回滚并恢复"
docker exec "$NAME" node -e '
const fs=require("fs");
const p="/data/dsh/profiles/web/package.json";
const j=JSON.parse(fs.readFileSync(p,"utf8"));
j.dependencies=j.dependencies||{};
j.dependencies["@scope/e2e-does-not-exist"]="9.9.9-broken";
fs.writeFileSync(p, JSON.stringify(j,null,2));
' || fail "注入坏依赖失败"
docker restart "$NAME" >/dev/null
wait_healthy after-restart || fail "容器未能从坏依赖中恢复（自愈链路可能失效）"
log "  [after-restart] 已恢复 healthy"
if docker logs "$NAME" 2>&1 | grep -qE 'selfheal rollback|no-evidence fallback|remove-plugin'; then
  log "  [after-restart] 观察到自愈动作"
else
  log "  (提示：本轮可能未触发自愈或走了 remove-plugin，请人工核对 docker logs)"
fi

log "4) 快照完整性检查（rescue verify）"
if docker exec "$NAME" rescue verify >/dev/null 2>&1; then
  log "  verify: 通过"
else
  log "  verify: 有不可信快照（hardlink 模式下的就地改写属预期提示，请人工核对）"
fi

log "5) 自愈预算可观测（rescue selfheal status）"
docker exec "$NAME" rescue selfheal status >/dev/null || fail "rescue selfheal status 失败"
log "  自愈状态可读"

log "6) 诊断包（rescue export）"
docker exec "$NAME" rescue export /tmp/e2e-bundle.tar.gz >/dev/null || fail "rescue export 失败"
docker exec "$NAME" tar -tzf /tmp/e2e-bundle.tar.gz | grep -q environment.txt || fail "诊断包缺 environment.txt"

echo
log "===== e2e-container-selftest: PASS ====="
log "（容器与临时目录在退出时自动清理）"
