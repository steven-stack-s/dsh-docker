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

if ! command -v dsh >/dev/null 2>&1; then
  echo "[entrypoint] 首次启动：准备 @deepseek-ai/dsh 到挂载卷 /opt/dsh ..."
  if [ -x /opt/dsh-seed/bin/dsh ]; then
    # 从镜像内 seed 复制：离线、版本固定、秒级完成
    echo "[entrypoint]   从镜像内 seed (/opt/dsh-seed) 复制到 /opt/dsh"
    mkdir -p /opt/dsh
    cp -a /opt/dsh-seed/. /opt/dsh/
    rm -rf /opt/dsh-seed   # 复制完清理：容器内不留重复副本（镜像层 seed 不变；回滚需 down+up 新容器）
  else
    # 兜底：seed 不存在（极少见，如手动精简镜像）时联网安装
    echo "[entrypoint]   seed 不存在，走 npm 在线安装"
    if [ -n "$NPM_REGISTRY" ]; then
      npm install -g @deepseek-ai/dsh --registry="$NPM_REGISTRY"
    else
      npm install -g @deepseek-ai/dsh
    fi
  fi
  echo "[entrypoint] DSH 已就绪: $(command -v dsh)"
fi

# pnpm：dsh plugin 命令（插件管理）转发到 pnpm 执行，必须可用
if ! command -v pnpm >/dev/null 2>&1; then
  echo "[entrypoint] 准备 pnpm（插件管理需要）..."
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
  echo "[entrypoint] 启动 socat 转发: 0.0.0.0:3080 -> 127.0.0.1:3081"
  # 上游 forever + intervall=1：socat 先于 dsh web 启动，dsh 监听 3081 前
  # 若有连接打到 3080，socat 会每秒重试直到 dsh 就绪，而不是抛 Connection refused
  socat TCP-LISTEN:3080,fork,reuseaddr TCP:127.0.0.1:3081,forever,intervall=1 &
fi

echo "[entrypoint] 启动 dsh web (内部 127.0.0.1:3081)"
# --no-open：容器内无浏览器，禁用 dsh 自动打开浏览器
# --trusted-host：dsh 0.1.2 的 /api 通道仅信任 loopback 或白名单 Host；
#   浏览器经局域网 IP / 隧道域名访问时被 403 拒绝（页面能开但连接异常）。
#   通过 DSH_TRUSTED_HOSTS 传入（逗号分隔，如 "192.168.1.5:3080,app.xx.com"）逐一加白。
TRUSTED_ARGS=""
if [ -n "$DSH_TRUSTED_HOSTS" ]; then
  echo "[entrypoint] 白名单 Host: $DSH_TRUSTED_HOSTS"
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
  echo '[entrypoint] WARN librescue.sh not found; auto-rollback DISABLED'
  rescue_log() { :; }
  rescue_snapshot_list() { :; }
  rescue_live_differs_from() { echo 0; }
  rescue_restore() { :; }
  rescue_init_lifeboat() { :; }
fi

PORT_INNER=3081
RESCUE_START_TIMEOUT="${RESCUE_START_TIMEOUT:-120}"
RESCUE_AUTO="${RESCUE_AUTO:-on}"
RESCUE_PROFILE="${RESCUE_PROFILE:-web}"
RESCUE_KEEP="${RESCUE_KEEP:-3}"

boot_lifeboat() {
  echo '[entrypoint] RESCUE=1: booting clean lifeboat profile (no third-party plugins); data preserved'
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
  echo '[entrypoint] probe-ready.js missing; supervision disabled - exec dsh directly'
  exec dsh web --profile "$RESCUE_PROFILE" --port $PORT_INNER --no-open $TRUSTED_ARGS
fi
while :; do
  attempt=$((attempt + 1))
  echo "[entrypoint] boot attempt $attempt/$max_attempt (profile=$RESCUE_PROFILE)"
  dsh web --profile "$RESCUE_PROFILE" --port $PORT_INNER --no-open $TRUSTED_ARGS &
  child=$!
  probe=/opt/dsh-rescue/probe-ready.js
  if node "$probe" "$PORT_INNER" "$((RESCUE_START_TIMEOUT * 1000))"; then
    echo "[entrypoint] dsh healthy on 127.0.0.1:$PORT_INNER"
    wait "$child"
    exit $?
  fi
  echo "[entrypoint] dsh not ready within ${RESCUE_START_TIMEOUT}s (attempt $attempt)"
  kill "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  if [ "$RESCUE_AUTO" = "on" ] && [ "$has_snap" = "1" ] && [ "$attempt" -lt "$max_attempt" ]; then
    newest=$(rescue_snapshot_list 2>/dev/null | tail -n1 | xargs -r basename)
    differs=0
    if [ -n "$newest" ]; then differs=$(rescue_live_differs_from "$newest" 2>/dev/null || echo 0); fi
    if [ -n "$newest" ] && [ "$differs" = "1" ]; then
      echo "[entrypoint] rolling back plugin tree to $newest"
      if rescue_restore "$newest"; then continue; fi
      echo '[entrypoint] rollback FAILED -> lifeboat'
      boot_lifeboat
    fi
  fi
  echo '[entrypoint] no rollback available/exhausted -> exit for docker restart policy'
  exit 1
done

