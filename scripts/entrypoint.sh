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

# HERE：本脚本所在目录（镜像内 /usr/local/bin）。librescue.sh 用它推导仓库/镜像布局的兜底路径；
# 显式赋值是为了不再依赖"librescue 恰好也设置了它"这种隐式耦合。
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# ----------------------------------------------------------------------------
# 首启 root 初始化 + 非 root 降权（容器安全加固第 2 步）
#
# 本文件被两类方式调用：
#   A) docker 以 root 启动本镜像（镜像无 USER 指令）→ 先做 seed 复制 + 挂载卷属主
#      整备，再 setpriv 降权到 node 用户（uid 1000，镜像自带）重新 exec 本脚本继续走监督/socat；
#   B) 降权后再次进入本脚本（uid!=0）→ 跳过本 root 块，直接运行 socat / dsh。
#
# 为何不直接在镜像里 `USER 1000`：
#   - seed 复制要写宿主 bind mount 的 /opt/dsh（卷可能 root 属主，非 root 无写权）；
#   - 三个挂载卷（/opt/dsh、/data/dsh、/workspace）属主需 chown 给运行用户，
#     只有 root（CAP_CHOWN / DAC_OVERRIDE）能做。
# 故采用「root 启动 → 首启特权整备 → setpriv 降权」模型：常驻进程（dsh/agent/npm/rescue）
# 一律非 root 运行，仅保留最开头的特权初始化。
# ============================================================================
RUN_USER_ID="${USER_UID:-1000}"
RUN_GROUP_ID="${USER_GID:-1000}"
# 运行 profile（默认 web）。须在 root 首启块之前定义：首启块要据它改写 profile manifest
RESCUE_PROFILE="${RESCUE_PROFILE:-web}"

if [ "$(id -u)" = 0 ] && [ "$RUN_USER_ID" != 0 ] && [ -z "${DSH_INIT_DONE:-}" ]; then
  elog "[entrypoint] root first-boot: preparing seed + volume ownership, then dropping to uid $RUN_USER_ID"

  # ① 首启：把镜像内 /opt/dsh-seed 复制到挂载卷 /opt/dsh
  if ! command -v dsh >/dev/null 2>&1; then
    elog "[entrypoint]   seeding @deepseek-ai/dsh into mounted volume /opt/dsh ..."
    if [ -x /opt/dsh-seed/bin/dsh ]; then
      # 从镜像内 seed 复制：离线、版本固定、秒级完成
      elog "[entrypoint]   copying in-image seed (/opt/dsh-seed) to /opt/dsh"
      mkdir -p /opt/dsh
      cp -a /opt/dsh-seed/. /opt/dsh/
      # 保留 /opt/dsh-seed：它位于镜像只读层，rm 无法释放镜像空间，且保留可让 rescue dsh-reinstall
      # 在主程序(/opt/dsh 卷)损坏且离线时从 seed 恢复（镜像版本）。重建容器也会重新可见。
    else
      # 兜底：seed 不存在（极少见，如手动精简镜像）时联网安装
      elog "[entrypoint]   seed missing; falling back to online npm install"
      if [ -n "$NPM_REGISTRY" ]; then
        npm install -g @deepseek-ai/dsh --registry="$NPM_REGISTRY"
      else
        npm install -g @deepseek-ai/dsh
      fi
    fi
    elog "[entrypoint] dsh ready: $(command -v dsh)"
  fi

  # ② pnpm：dsh plugin 命令（插件管理）转发到 pnpm 执行，必须可用
  if ! command -v pnpm >/dev/null 2>&1; then
    elog "[entrypoint]   preparing pnpm (required for plugin management) ..."
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

  # ③ 挂载卷属主整备：把三个持久化卷 chown 给运行用户（bridge 了宿主机目录属主差异）
  #    非 root 后 dsh/npm/rescue 都要在卷上读写，属主必须归 dsh。
  #    chown 失败不致命（只告警后继续，属主不符可能导致运行期写失败）。宿主机目录
  #    若原本已归目标用户（多数 NAS 首用户即 1000），chown 是 no-op。
  elog "[entrypoint]   fixing ownership of mounted volumes to $RUN_USER_ID:$RUN_GROUP_ID"
  for v in /opt/dsh /data/dsh /workspace; do
    mkdir -p "$v"
    chown -R "$RUN_USER_ID:$RUN_GROUP_ID" "$v" \
      || elog "[entrypoint]   WARN chown $v failed (volume may be read-only/root-owned)"
  done

  # ④ npm 缓存根目录：默认在 /root/.npm 落在只读根 FS 上（read_only:true 时不可写）。
  #    显式把它指到 /opt/dsh 卷内（卷可写），并建好属主，确保 npm install -g 缓存可用、
  #    rescue clean 的 _cacache 清理仍命中。
  if [ -z "${NPM_CONFIG_CACHE:-}" ]; then
    NPM_CONFIG_CACHE=/opt/dsh/.npm-cache
    export NPM_CONFIG_CACHE
    elog "[entrypoint]   NPM_CONFIG_CACHE not set -> defaulting to $NPM_CONFIG_CACHE (writable volume)"
  fi
  mkdir -p "$NPM_CONFIG_CACHE"
  chown -R "$RUN_USER_ID:$RUN_GROUP_ID" "$NPM_CONFIG_CACHE" 2>/dev/null || true

  # ⑤ 固定 web profile 为 patchReload=startup(关闭 HMR,read_only 安全)。
  #    web 是 dsh 唯一默认 patchReload:"live"(改 cordis.patch.yml 即时热重载)的 profile;
  #    但 read_only 根 FS 下 HMR 依赖的 native addon(node-addon-require-builtin)无法解析
  #    binding,导致 HMR 插件启动即抛 --expose-internals is required,dsh 崩溃且 rescue 无法自愈。
  #    read_only 生产加固应关闭实时热重载(改配置后 docker restart 生效),与 acp/headless/sdk
  #    等默认 startup 一致。dsh 的 initProfile 仅在 manifest 不存在时创建、normalizeShippedProfile
  #    保留已有显式值 -> 此处预置或改写均会被 dsh 沿用。
  if [ -n "$RESCUE_PROFILE" ]; then
    pf="/data/dsh/profiles/$RESCUE_PROFILE/package.json"
    case "$RESCUE_PROFILE" in
      web)
        if [ -e "$pf" ]; then
          sed -i 's/"patchReload"[[:space:]]*:[[:space:]]*"live"/"patchReload": "startup"/' "$pf" 2>/dev/null \
            || elog "[entrypoint]   WARN failed to rewrite web profile patchReload"
        else
          mkdir -p "/data/dsh/profiles/web"
          cat > "$pf" <<'PPF'
{
  "name": "dsh-profile-web",
  "private": true,
  "dependencies": {},
  "dsh": {
    "profile": {
      "bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"],
      "patchReload": "startup"
    }
  }
}
PPF
        fi
        # profile 目录(含父级 profiles + 新落盘的 manifest + dsh 首启将创建的 node_modules/lifeboat)
        # 归运行用户。必须 chown 整个 /data/dsh/profiles:仅 chown web 子目录会使父级 profiles
        # 保持 root 属主,dsh 首启 mkdir profiles/node_modules 时 uid 1000 会 EACCES。
        chown -R "$RUN_USER_ID:$RUN_GROUP_ID" /data/dsh/profiles 2>/dev/null || true
        elog "[entrypoint]   web profile patchReload -> startup (HMR off, read-only safe)"
        ;;
    esac
  fi

  # ⑥ 降权并重新 exec 本脚本。DSH_INIT_DONE 防止二次进入时再走本块。
  export DSH_INIT_DONE=1
  elog "[entrypoint] dropping privileges to uid=$RUN_USER_ID gid=$RUN_GROUP_ID"
  exec setpriv --reuid="$RUN_USER_ID" --regid="$RUN_GROUP_ID" --init-groups "$0" "$@"
fi

# dsh web 刻意只监听 127.0.0.1（--host 0.0.0.0 被安全拒绝）。
# 端口分工：dsh 内部监听 127.0.0.1:3081；socat 把外部 0.0.0.0:3080 转发到 3081。
# （socat 不能听 3080 再让 dsh 也听 3080：0.0.0.0 会占用 127.0.0.1，必然 EADDRINUSE）
# 端口分工：dsh 内部监听 127.0.0.1:$PORT_INNER；socat 把外部 $SOCAT_PORT 转发进去。
PORT_INNER=3081
SOCAT_PORT="${SOCAT_PORT:-3080}"
# 并发上限：socat 的 fork 模式每连接一个进程，无上限时外部无认证的并发连接即可耗尽容器内存
SOCAT_MAX_CHILDREN="${SOCAT_MAX_CHILDREN:-64}"

# socat 转发器：用户的唯一入口，此前完全没有监督（它死掉后 dsh 仍健康、容器仍 green、healthcheck
# 照样通过，但外部彻底失联）。封装成函数交给监督循环守护，死掉即重启。
start_socat() {
  socat "TCP-LISTEN:$SOCAT_PORT,fork,reuseaddr,max-children=$SOCAT_MAX_CHILDREN" \
        "TCP:127.0.0.1:$PORT_INNER,forever,intervall=1" &
  SOCAT_PID=$!
}

if command -v socat >/dev/null 2>&1; then
  elog "[entrypoint] starting socat forward: 0.0.0.0:$SOCAT_PORT -> 127.0.0.1:$PORT_INNER (max-children=$SOCAT_MAX_CHILDREN)"
  # 上游 forever + intervall=1：socat 先于 dsh web 启动，dsh 监听 3081 前
  # 若有连接打到 3080，socat 会每秒重试直到 dsh 就绪，而不是抛 Connection refused
  start_socat
fi

elog "[entrypoint] starting dsh web (internal 127.0.0.1:3081)"
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
  rescue_trusted_args() { printf '%s' ''; }
  rescue_lifeboat_requested() { return 1; }
  rescue_lifeboat_clear() { :; }
  rescue_lifeboat_request() { :; }
fi

# ---- 以下两项依赖 librescue 提供的函数，必须在上面 source 之后执行 ----
# 真机教训：这两块原来放在 source 之前，`command -v` 判空后静默跳过，于是"Host 白名单校验"与
# "凭据文件"完全没生效，而单测只测函数本身、全绿。scripts/t/test-entrypoint-order.sh 专门盯这个顺序。
#
# 凭据（F8）：DEEPSEEK_API_KEY_FILE 优先于环境变量，让密钥可以只存在于挂载文件 / docker secret 里，
# 不出现在 `docker inspect` 与环境变量中。
if command -v rescue_load_api_key >/dev/null 2>&1; then
  if ! rescue_load_api_key; then
    elog '[entrypoint] WARN DEEPSEEK_API_KEY_FILE set but unreadable/empty; falling back to DEEPSEEK_API_KEY'
  fi
fi

# --trusted-host：dsh 的 /api 通道仅信任 loopback 或白名单 Host；
#   浏览器经局域网 IP / 隧道域名访问时会被 403 拒绝（页面能开但连接异常）。
#   通过 DSH_TRUSTED_HOSTS 传入（逗号分隔，如 "192.168.1.5:3080,app.xx.com"）逐一加白。
TRUSTED_ARGS=""
if [ -n "$DSH_TRUSTED_HOSTS" ]; then
  elog "[entrypoint] trusted Host allowlist: $DSH_TRUSTED_HOSTS"
  if command -v rescue_trusted_args >/dev/null 2>&1; then
    TRUSTED_ARGS=$(rescue_trusted_args "$DSH_TRUSTED_HOSTS")
  fi
  [ -n "$TRUSTED_ARGS" ] || elog '[entrypoint] WARN trusted Host allowlist produced no usable entry (all entries invalid?)'
fi

RESCUE_START_TIMEOUT="${RESCUE_START_TIMEOUT:-120}"
RESCUE_AUTO="${RESCUE_AUTO:-on}"
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

# 自动降级（F7）：自愈彻底失败时留下的标记 —— 以干净最小 profile 起来（一次性：进入即清除，
# 用户修好插件后直接 docker restart 就能回到正常 profile，不必再改 .env）。
if command -v rescue_lifeboat_requested >/dev/null 2>&1 && rescue_lifeboat_requested 2>/dev/null; then
  rescue_lifeboat_clear
  boot_lifeboat "auto fallback: self-heal exhausted"
fi

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
