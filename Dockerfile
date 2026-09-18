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

# 构建时锁定的 dsh / pnpm 版本。用 build-arg 覆盖即可换版本：--build-arg DSH_VERSION=1.2.3
#
# 【为什么不用 latest】npm 的 dist-tag 是发布者手动指定的别名，**不会自动前进**。
# 当前三个 tag 的实测指向（2026-09-18 核对 npm dist-tags）：
#   latest -> 0.1.5-rc.2    （稳定推荐版，落后于 alpha）
#   next   -> 0.1.5-rc.2    （更新的候选版）
#   alpha  -> 0.1.6-alpha.2 （本镜像锁定的版本）
# 注：latest 曾长期停在 0.1.5-rc.1（rc.2 发布时只推进 next），现已跟上 rc.2；
#     无论它指向谁，都**拿不到 0.1.6**（alpha 线只挂在 alpha tag 下）。
# 用 latest 会带来两个真问题：
#   1) 与 docker-compose.yml 的默认值不一致 —— 不传 DSH_VERSION 时，
#      docker build 与 docker compose build 会产出不同 dsh 版本的镜像；
#   2) 默认值随 npm 上的 tag 变动而静默漂移，同一份 Dockerfile 在不同时间构建出不同版本。
# 故这里钉死一个显式版本；要升级就改这一处，或在 compose/.env 里传 DSH_VERSION 覆盖。
# 注意：alpha 版本必须写全版本号 —— latest/next 都拿不到它。
ARG DSH_VERSION=0.1.6-alpha.2
ARG PNPM_VERSION=latest

# 可选 apt 镜像源（国内构建加速）：传 --build-arg APT_MIRROR=mirrors.aliyun.com 启用；
# 默认空即用 debian 官方源。对 Debian 12 (bookworm) 的 sources.list 类型自动适配。
ARG APT_MIRROR=

# DSH 运行依赖：git、ca-certificates（HTTPS）、tzdata（时区）、socat（端口转发）、openssh-client（容器内 ssh 出去）
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
        openssh-client \
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

# 原生插件绑定缓存必须落在【可执行】文件系统上（真机故障修复 2026-09-17）。
# node-addon-native-custom-loader（node-addon-require-builtin 的加载器）会把 .node 绑定
# 复制到 $TMPDIR/node-addon-native-custom-loader-<uid>/native-cache/ 再 dlopen。Docker 的
# tmpfs（含本仓库 compose 的 /tmp）默认 noexec，dlopen 会以
#   "failed to map segment from shared object"
# 失败 → 绑定不可用 → dsh-app-boot 装不上 profile 解析 hook（loader.internal 为空）→
# 所有第三方插件 ERR_MODULE_NOT_FOUND → web profile 启动失败 → 自愈耗尽 → 进 lifeboat。
# 这里直接禁用该缓存，让绑定从 /opt/dsh（挂载卷，可执行）原路径加载：
# 既不依赖 /tmp 可执行，也不额外写盘。Dockerfile 层兜底 + compose 的 tmpfs exec 双保险。
# （如需保留缓存语义，可改用 NARB_NATIVE_CACHE_DIR 指向卷内可执行目录。）
ENV NARB_DISABLE_NATIVE_CACHE=1

# 时区（可用 .env 覆盖）
ENV TZ=Asia/Shanghai

# ============================================================================
# 非 root 运行用户（容器安全加固）
#
# 【运行模型】root 启动 → 首启初始化 → setpriv 降权
#   - 镜像**不设** `USER 1000`：entrypoint 仍需以 root 完成两类特权操作，
#        ① 首启把镜像内 /opt/dsh-seed 复制进宿主 bind mount 的 /opt/dsh（卷可能 root 属主）；
#        ② 把三个挂载卷（/opt/dsh、/data/dsh、/workspace）chown 给运行用户。
#   - 初始化完成后，entrypoint 用 `setpriv --reuid=1000 --regid=1000 --init-groups`
#     降权到 node 用户（uid 1000），再启动 socat / 监督循环 / dsh web。dsh 及全部子进程
#     （agent、npm/pnpm 升级、rescue 快照/自愈）都以 uid 1000 运行，非 root。
#   - 保留 docker exec 的 root 运维通道（升级、修复脚本），但容器常驻进程非 root。
# 【运行用户】直接复用 node:24-slim 镜像自带的 `node` 用户：uid=1000 gid=1000。
#   它天然契合"uid 1000:1000 = 多数 NAS/宿主首个非 root 用户"，对 bind mount 属主最友好；
#   且无需新建用户（node 镜像已自带）。entrypoint 用 setpriv 降权到 uid 1000 运行。
# 【USER_UID/USER_GID】纯**运行时**环境变量（compose 的 environment 注入），不是 build-arg：
#   镜像刻意不自建用户，而是直接复用 node:24-slim 自带的 `node` 用户（uid 1000 gid 1000），
#   由 entrypoint 在首启时把三个挂载卷 chown 到该 uid 再降权。
#   故这里**不再声明** ARG USER_UID/USER_GID —— 曾经声明过但从未被任何指令消费（死参数），
#   却让文档误以为"必须与构建参数一致"，属于误导。
#   覆盖方式：在 .env 里设 USER_UID/USER_GID（仅当宿主卷属主不是 1000 时才需要；
#   不设即 1000，与 node 用户一致）。注意该 uid 最好能在容器 /etc/passwd 里查到，
#   否则 entrypoint 会退化为"不带附加组"降权（见 entrypoint 第 ⑥ 步）。
# ============================================================================

WORKDIR /workspace
EXPOSE 3080

# 救援工具集（librescue + probe + 命令入口 + lifeboat 模板）
# Docker 的 COPY <src> 为目录时只复制其【内容】到目标、不保留目录本身；故先 mkdir 目标目录、
# 再以 <dir>/. 结尾复制，确保内容落在 /opt/dsh-rescue/lifeboat.tmpl/ 子目录（LIFEBOAT_TMPL 语义）。
# hmr-off.yml 是 HMR 关闭用的 launcher 叠加层，由 entrypoint 以 --patch 注入（见该文件头注释）
COPY scripts/librescue.sh scripts/probe-ready.js scripts/diagnose.js scripts/report.js scripts/logtag.js scripts/logtee.js scripts/rescue-supervise.sh scripts/rescue scripts/hmr-off.yml scripts/vercmp.sh /opt/dsh-rescue/
RUN mkdir -p /opt/dsh-rescue/lifeboat.tmpl
COPY scripts/lifeboat.tmpl/. /opt/dsh-rescue/lifeboat.tmpl/
ENV LIFEBOAT_TMPL=/opt/dsh-rescue/lifeboat.tmpl
# 消除对【构建机 umask】的隐式依赖：COPY 保留源文件权限，而 umask 077 的构建环境会让这些资产
# 在镜像内变成 0600 root —— dsh/rescue 以 uid 1000 运行时根本读不到它们。
# （真机实测 2026-09-18：hmr-off.yml 落到 0600 后 entrypoint 的 --patch 被拒，关闭 HMR 的加固
#   静默失效；而本地单测全绿 —— git 只记录 644/755，正常 umask 下 checkout 出来恰好可读，
#   问题只在 umask 收紧的构建机上出现。）
# 故统一放开读权限：+x 只给需要执行的那三个，其余（含今后新增的资产）一律 a+r。
# 注意：这些说明必须写在 RUN 之前 —— RUN 的续行里出现 # 会被 shell 当注释，吞掉其后的命令。
RUN sed -i 's/\r$//' /opt/dsh-rescue/librescue.sh /opt/dsh-rescue/probe-ready.js /opt/dsh-rescue/diagnose.js /opt/dsh-rescue/report.js /opt/dsh-rescue/logtag.js /opt/dsh-rescue/logtee.js /opt/dsh-rescue/rescue-supervise.sh /opt/dsh-rescue/rescue /opt/dsh-rescue/hmr-off.yml /opt/dsh-rescue/vercmp.sh /opt/dsh-rescue/lifeboat.tmpl/package.json /opt/dsh-rescue/lifeboat.tmpl/cordis.patch.yml \
    && chmod +x /opt/dsh-rescue/rescue /opt/dsh-rescue/probe-ready.js /opt/dsh-rescue/librescue.sh \
    && chmod a+r /opt/dsh-rescue/* /opt/dsh-rescue/lifeboat.tmpl/* \
    && ln -sf /opt/dsh-rescue/rescue /usr/local/bin/rescue

COPY scripts/entrypoint.sh /usr/local/bin/dsh-entrypoint
RUN chmod +x /usr/local/bin/dsh-entrypoint \
    && sed -i 's/\r$//' /usr/local/bin/dsh-entrypoint   # 兼容 Windows 开发的 CRLF 换行

ENTRYPOINT ["dsh-entrypoint"]

# 健康检查：探测 dsh 内部端口 3081（探测 socat 的 3080 会误报健康）。
# 与 rescue 同判据（都连 127.0.0.1:3081）；差异仅在放弃时限。start-period 仅 docker run 直用（不经 compose）时生效；
# 用 docker-compose 时其 healthcheck【覆盖】本值（compose 默认 start_period 300s，更宽松容首启冷启动+复制 seed）。
# 口径：rescue 探测窗口 RESCUE_START_TIMEOUT(默认 120s) 针对每轮 dsh 进程 readiness，须 < docker 放弃时限(300s)，
# 否则 rescue 会先于 docker 放弃而误回滚一个仍在正常冷启动的 dsh。构建时已预装 dsh，复制 seed 秒级。
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 \
  CMD node -e "require('net').connect(3081,'127.0.0.1').on('connect',()=>process.exit(0)).on('error',()=>process.exit(1))"
