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
exec dsh web --port 3081 --no-open $TRUSTED_ARGS
