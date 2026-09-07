# ============================================================================
# DSH (DeepSeek Harness) 基础镜像 —— 构建时锁版本 + 容器内升级方案
#
# 【设计】
#   - 构建时预装 dsh + pnpm 到镜像内 /opt/dsh-seed（非挂载路径，运行时不被卷遮蔽）
#   - 首次启动：entrypoint 把 seed 复制到挂载卷 /opt/dsh，立即就绪（无需联网、版本固定）
#   - 日常升级：docker exec dsh npm install -g @deepseek-ai/dsh@<新版本>
#                docker restart dsh
#   - 镜像只在 Node 版本 / 系统依赖 / 想更新基础 dsh 版本时重建。
#
# 【Node 版本要求】DSH 需要 Node >= 22.18（zstd / Promise.withResolvers /
#   stripTypeScriptTypes 等新 API），故用当前 LTS 的 node:24-slim。
# ============================================================================

FROM node:24-slim

# 构建时锁定的 dsh / pnpm 版本（默认 latest，构建阶段解析为当时 npm 上的最新版并固化进镜像）
# 用 build-arg 覆盖即可固定版本：--build-arg DSH_VERSION=1.2.3
ARG DSH_VERSION=latest
ARG PNPM_VERSION=latest

# 可选 apt 镜像源（国内构建加速）：传 --build-arg APT_MIRROR=mirrors.aliyun.com 启用；
# 默认空即用 debian 官方源。对 Debian 12 (bookworm) 的 sources.list 类型自动适配。
ARG APT_MIRROR=

# DSH 运行依赖：git、ca-certificates（HTTPS）、tzdata（时区）、socat（端口转发）
# socat 用途（勿删）：dsh web 刻意只监听 127.0.0.1:3081
# （--host 0.0.0.0 被官方安全拒绝），socat 把外部 0.0.0.0:3080 转发到 127.0.0.1:3081。
RUN if [ -n "$APT_MIRROR" ]; then \
        if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
            sed -i "s|deb.debian.org|${APT_MIRROR}|g; s|security.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list.d/debian.sources; \
        elif [ -f /etc/apt/sources.list ]; then \
            sed -i "s|deb.debian.org|${APT_MIRROR}|g; s|security.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list; \
        fi; \
    fi \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        tzdata \
        socat \
    && rm -rf /var/lib/apt/lists/*

# npm 全局前缀改到 /opt/dsh：该目录整体挂载到宿主机卷，
# 避免挂载 /usr/local 遮蔽镜像内的 node/npm 命令
ENV NPM_CONFIG_PREFIX=/opt/dsh
ENV PATH=/opt/dsh/bin:$PATH

# 预装 dsh + pnpm 到 /opt/dsh-seed（非挂载路径，运行时不被卷遮蔽）。
# entrypoint 在挂载卷 /opt/dsh 为空时，把 seed 整体复制过去 → 首次启动即就绪、离线可用、版本固定。
# 升级仍走 docker exec npm install -g @deepseek-ai/dsh@<新版本> 覆盖到 /opt/dsh。
# 用临时 NPM_CONFIG_PREFIX 覆盖上面的 ENV，让安装落进 seed 而非 /opt/dsh（/opt/dsh 留给运行时挂载）。
RUN NPM_CONFIG_PREFIX=/opt/dsh-seed \
    npm install -g @deepseek-ai/dsh@${DSH_VERSION} pnpm@${PNPM_VERSION} \
    && rm -rf /root/.npm

# 数据根目录：DSH 所有用户数据（会话/配置/插件/记忆库）
ENV DSH_HOME=/data/dsh

# 时区（可用 .env 覆盖）
ENV TZ=Asia/Shanghai

WORKDIR /workspace
EXPOSE 3080

# 救援工具集（librescue + probe + 命令入口 + lifeboat 模板）
# Docker 的 COPY <src> 为目录时只复制其【内容】到目标、不保留目录本身；故先 mkdir 目标目录、
# 再以 <dir>/. 结尾复制，确保内容落在 /opt/dsh-rescue/lifeboat.tmpl/ 子目录（LIFEBOAT_TMPL 语义）。
COPY scripts/librescue.sh scripts/probe-ready.js rescue /opt/dsh-rescue/
RUN mkdir -p /opt/dsh-rescue/lifeboat.tmpl
COPY profiles/lifeboat.tmpl/. /opt/dsh-rescue/lifeboat.tmpl/
ENV LIFEBOAT_TMPL=/opt/dsh-rescue/lifeboat.tmpl
RUN sed -i 's/\r$//' /opt/dsh-rescue/librescue.sh /opt/dsh-rescue/probe-ready.js /opt/dsh-rescue/rescue /opt/dsh-rescue/lifeboat.tmpl/package.json /opt/dsh-rescue/lifeboat.tmpl/cordis.patch.yml \
    && chmod +x /opt/dsh-rescue/rescue /opt/dsh-rescue/probe-ready.js /opt/dsh-rescue/librescue.sh \
    && ln -sf /opt/dsh-rescue/rescue /usr/local/bin/rescue

COPY entrypoint.sh /usr/local/bin/dsh-entrypoint
RUN chmod +x /usr/local/bin/dsh-entrypoint \
    && sed -i 's/\r$//' /usr/local/bin/dsh-entrypoint   # 兼容 Windows 开发的 CRLF 换行

ENTRYPOINT ["dsh-entrypoint"]

# 健康检查：探测 dsh 内部端口 3081（探测 socat 的 3080 会误报健康）
# 构建时已预装 dsh，首次启动只需从 seed 复制（秒级），start_period 可显著缩短
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 \
  CMD node -e "require('net').connect(3081,'127.0.0.1').on('connect',()=>process.exit(0)).on('error',()=>process.exit(1))"
