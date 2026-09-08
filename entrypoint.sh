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
    # 保留 /opt/dsh-seed：它位于镜像只读层，rm 无法释放镜像空间，且保留可让 rescue dsh-reinstall
    # 在主程序(/opt/dsh 卷)损坏且离线时从 seed 恢复（镜像版本）。重建容器也会重新可见。
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
  RESCUE_DIR="${DSH_HOME:-/data/dsh}/.rescue"
  rescue_log() { :; }
  rescue_dir() { printf '%s' "$RESCUE_DIR"; }
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

# 证据文件轮转器（logtee.js）可用性：tee 替身 + 按 RESCUE_EVIDENCE_MAX 轮转，防 healthy 后活动 dsh.log 无限增长；
# 缺失时降级为原 tee（无轮转，仅在有 logtag 的 tee 证据链时用到）。
LOGTEE=
for _c in /opt/dsh-rescue/logtee.js "$HERE/scripts/logtee.js" "$HERE/logtee.js"; do
  [ -f "$_c" ] && { LOGTEE="$_c"; break; }
done
# 证据文件单文件轮转上限（字节；healthy 后活动 dsh.log 超限即轮转保留最近一段）
RESCUE_EVIDENCE_MAX="${RESCUE_EVIDENCE_MAX:-20971520}"


boot_lifeboat() {
  # $1 = 进入 lifeboat 的原因（缺省=显式 RESCUE=1）；用于 echo 与审计日志，区分用户手动进 vs 回滚失败兜底进
  reason="${1:-rescue requested (RESCUE=1)}"
  elog "[entrypoint] booting clean lifeboat profile ($reason); no third-party plugins; data preserved"
  rescue_log "lifeboat enter: $reason"
  rescue_init_lifeboat
  exec dsh --profile lifeboat --port $PORT_INNER --no-open $TRUSTED_ARGS
}

if [ "${RESCUE:-0}" = "1" ]; then boot_lifeboat; fi

# ===================== 归因自愈编排 + 监督主循环（rescue-supervise）=====================
# 监督 / 诊断 / 自愈编排与主循环由 scripts/rescue-supervise.sh 提供（方案 A 重构：本文件只
# 承担 PID1 生命周期与依赖准备）。supervise 缺失（精简镜像/手动删除）时降级为无监督直启，
# 保证 dsh 仍能启动（等同 probe-ready.js 缺失路径）。
SUPERVISE=
for _c in /opt/dsh-rescue/rescue-supervise.sh "$HERE/scripts/rescue-supervise.sh" "$HERE/rescue-supervise.sh"; do
  [ -f "$_c" ] && { SUPERVISE="$_c"; break; }
done
if [ -n "$SUPERVISE" ]; then
  . "$SUPERVISE"
  rescue_supervise
else
  elog '[entrypoint] WARN rescue-supervise.sh missing; supervision disabled - exec dsh directly'
  exec dsh --profile "$RESCUE_PROFILE" --port $PORT_INNER --no-open $TRUSTED_ARGS
fi
