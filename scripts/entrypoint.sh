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

# 版本比较（ver_gt）—— 步骤 ① 用它决定镜像 seed 是否覆盖 /opt/dsh 卷里的 dsh。
# 必须在这里 source：步骤 ① 在 root 首启块内，早于 librescue.sh 被 source 的位置。
# 找不到时降级为「不做版本比较」（行为退回「仅首启复制」），绝不因此中断启动。
for _vc in /opt/dsh-rescue/vercmp.sh "$HERE/scripts/vercmp.sh" "$HERE/vercmp.sh"; do
  if [ -f "$_vc" ]; then . "$_vc"; break; fi
done
command -v ver_gt >/dev/null 2>&1 || elog '[entrypoint] WARN vercmp.sh missing; seed version comparison disabled'

# 把镜像内 seed 复制到挂载卷 /opt/dsh（步骤 ① 与 ② 共用）。
# 【为什么不能直接 cp -a】容器内 root 只有 CHOWN/DAC_OVERRIDE/SETUID/SETGID，**没有 CAP_FOWNER**；
# 而 /opt/dsh 里的文件在首次启动后已被步骤 ③ chown 给运行用户，对「不属于自己的」文件做
# utimes/chmod 会 EPERM，cp 因此**返回非零** —— 在 set -e 下裸调用会直接杀掉 PID1，容器进入
# 重启死循环（真机实测 2026-09-18：某 NAS 上 cp 的 chown 环节未生效，日志被
# 'cp: preserving times ...: Operation not permitted' 刷满，cp 退出码为 1）。
# 对策：先把属主收回 root（CHOWN 在白名单里），再 cp -a 保留属性；万一仍失败，退化为
# 不保留属性的 cp -R —— 内容才决定 dsh 能否运行，元数据尽力而为。步骤 ③ 随后会把属主改回运行用户。
seed_copy() {
  mkdir -p /opt/dsh
  chown -R 0:0 /opt/dsh 2>/dev/null || true
  if ! cp -a /opt/dsh-seed/. /opt/dsh/ 2>/dev/null; then
    elog '[entrypoint] WARN cp -a could not preserve attributes; retrying without them'
    cp -R /opt/dsh-seed/. /opt/dsh/ 2>/dev/null \
      || elog '[entrypoint] WARN seed copy reported errors; continuing with whatever is present'
  fi
}

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

  # ⓪ 运行用户的 HOME 必须可用（真机故障修复 2026-09-17）。
  #    镜像刻意不设 HOME，Docker 会给 root 的 /root；而 /root 是 700 root —— 降权到 uid 1000
  #    后连读都不行。pnpm 会去读 $HOME/.config/pnpm/config.yaml，直接 EACCES：
  #      Failed to read pnpm-workspace.yaml at /root/.config/pnpm/config.yaml:
  #      Permission denied (os error 13)
  #    表现为插件市场「找到 pnpm 了，但 pnpm --version 失败」（实测：HOME=/root 报上述错，
  #    HOME 指向可写目录则 pnpm 12.4.2 正常；pnpm 本体完整，不是 corepack shim）。
  #    默认值取 /workspace 而非 /data/dsh/home：**「新建会话 → 选择工作区」的选择器默认就列
  #    HOME**（dsh-host-directory-picker-browse: `resolve(path ?? homedir())`），且 UI 默认
  #    不显示隐藏文件 —— 放在只有 .config/.local 的目录里会让列表全空（"选取不到工作区"，
  #    真机 2026-09-17）。而 /workspace 下的 code/ session/ 正是用户要选的工作区。
  #    在整备卷属主【之前】设定，后面的 ③/③b 会连带把属主与权限修好；
  #    已是自定义值（用户显式传入）则尊重，不动。
  _home_before="${HOME:-<unset>}"
  if [ -z "${HOME:-}" ] || [ "$HOME" = "/root" ]; then
    export HOME=/workspace
    mkdir -p "$HOME" 2>/dev/null || true
    elog "[entrypoint]   run-user HOME $_home_before is not usable by uid $RUN_USER_ID -> $HOME"
  fi

  # ① 保证 /opt/dsh 卷里的 dsh **不低于**镜像 seed（只升不降）。触发条件（任一）：
  #      a) 卷里没有 dsh               —— 首启
  #      b) 镜像 seed 版本 > 卷内版本  —— 升级镜像后自动跟进，不必再手动 npm install
  #    相等、或卷里反而更新（用户在容器内手动装过更高版本）时**不动**，尊重用户的选择。
  #    版本取自各自安装目录里的 package.json：比跑 `dsh --version` 更快、无副作用，
  #    也不会因 profile / 权限问题失败。ver_gt 由 scripts/vercmp.sh 提供（与徽章脚本共用一份）。
  _dsh_rel=lib/node_modules/@deepseek-ai/dsh/package.json
  _seed_ver=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "/opt/dsh-seed/$_dsh_rel" 2>/dev/null | head -n1)
  _vol_ver=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "/opt/dsh/$_dsh_rel" 2>/dev/null | head -n1)

  _reseed=''
  if ! command -v dsh >/dev/null 2>&1; then
    _reseed='no dsh in volume'
  elif [ -n "$_seed_ver" ] && [ -n "$_vol_ver" ] && command -v ver_gt >/dev/null 2>&1; then
    if ver_gt "$_seed_ver" "$_vol_ver"; then
      _reseed="image seed $_seed_ver > volume $_vol_ver"
    fi
  fi

  if [ -n "$_reseed" ]; then
    elog "[entrypoint]   seeding dsh into /opt/dsh ($_reseed)"
    if [ -x /opt/dsh-seed/bin/dsh ]; then
      # 从镜像内 seed 复制：离线、版本固定、秒级完成（元数据容错见 seed_copy 的注释）。
      # 不删除目标里多出的旧文件（旧版独有的包目录会残留；但 dsh 按自己的 package.json
      # 解析依赖，残留目录不会被加载）—— 保留「复制失败时卷里仍有可用 dsh」的余地。
      elog "[entrypoint]   copying in-image seed (/opt/dsh-seed) to /opt/dsh"
      seed_copy
      [ -x /opt/dsh/bin/dsh ] || elog '[entrypoint] WARN /opt/dsh/bin/dsh missing after seed copy'
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
  fi

  # 无论本轮是否复制，都报出**最终实际生效**的版本 —— 判断「升没升上去」就看这一行。
  _eff_ver=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "/opt/dsh/$_dsh_rel" 2>/dev/null | head -n1)
  elog "[entrypoint] dsh version: seed=${_seed_ver:-unknown} volume(before)=${_vol_ver:-none} effective=${_eff_ver:-unknown}"

  # ② pnpm：dsh plugin 命令（插件管理）转发到 pnpm 执行，必须可用
  if ! command -v pnpm >/dev/null 2>&1; then
    elog "[entrypoint]   preparing pnpm (required for plugin management) ..."
    if [ -x /opt/dsh-seed/bin/pnpm ]; then
      # dsh 段已复制过 seed 的话 pnpm 应已就位；这里兜底单独复制
      seed_copy
    elif [ -n "$NPM_REGISTRY" ]; then
      npm install -g pnpm --registry="$NPM_REGISTRY"
    else
      npm install -g pnpm
    fi
  fi

  # ③ 挂载卷属主整备：把三个持久化卷对齐给运行用户（bridge 了宿主机目录属主差异）
  #    非 root 后 dsh/npm/rescue 都要在卷上读写，属主必须归 dsh。
  #    【为何不用 `chown -R`】真机三卷合计约 28.8 万个文件（/data/dsh 21.7 万）。`chown -R`
  #    会对**每个 inode 都发起一次写**，NAS 上每次启动要跑很久；而这些文件绝大多数本来就
  #    已经是运行用户所有，是纯粹的重复写。改为只对"属主/属组不符"的条目 chown：
  #    语义完全等价（错的一个不漏），但已正确的条目只被 stat 一次、不产生写。
  #    失败不致命（只告警后继续，属主不符可能导致运行期写失败）。
  elog "[entrypoint]   aligning mounted-volume ownership to $RUN_USER_ID:$RUN_GROUP_ID (only entries that differ)"
  for v in /opt/dsh /data/dsh /workspace; do
    mkdir -p "$v"
    find "$v" \( -not -user "$RUN_USER_ID" -o -not -group "$RUN_GROUP_ID" \) \
      -exec chown "$RUN_USER_ID:$RUN_GROUP_ID" {} + 2>/dev/null \
      || elog "[entrypoint]   WARN ownership alignment incomplete for $v (volume may be read-only/foreign-owned)"
  done

  # ③b 属主可读性归一（真机故障修复 2026-09-17）。
  #     chown 只改属主、**不改权限位**：历史遗留的 `0000`（或无 u+r）文件即使用户拥有它，
  #     属主自己也读不了。以 root 运行时被 CAP_DAC_OVERRIDE 掩盖，一旦降权到 uid 1000，
  #     dsh 打开会话/缓存文件就 EACCES → 插件树加载失败 → 启动失败 → 自愈耗尽 → 进 lifeboat。
  #     真机实例 /data/dsh 下有 104 个此类文件（sessions/--*--/session.jsonl.zstd、
  #     storages/session_projcache/sessions/*.json），全部来自 09-07~09-10；这些文件同时
  #     导致 rescue 快照的 `cp -al`/`cp -a` 失败（→ 每次多占约 900MB 的嵌套副本）。
  #     只对"属主无读权限"的条目补 u+rwX（X 仅对目录/已可执行文件加 x，不改文件语义）。
  #     失败不致命：只告警，绝不因此阻断启动（救命的 lifeboat 必须可达）。
  elog "[entrypoint]   normalizing owner-readable bits (fixes legacy 0000 files under uid $RUN_USER_ID)"
  for v in /opt/dsh /data/dsh /workspace; do
    find "$v" -not -perm -u+r -exec chmod u+rwX {} + 2>/dev/null \
      || elog "[entrypoint]   WARN permission normalization incomplete for $v"
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

  # ⑤ 预置 web profile manifest（只写 bundles）。
  #    【2026-09-18 换版本时变更】DSH 0.1.6-alpha.2 起 profile manifest 的 `patchReload`
  #    字段被**完全移除**（dsh-app-boot 源码里已无任何引用；实测新建 web profile 也不再写入它），
  #    HMR 改由 base 组合包的 `hmr` 条目控制：
  #        disabled: !!js "!ctx.get('profileContext')"   → 由启动器拉起即默认启用
  #    （alpha.1 是硬编码 `disabled: true`，即模块热重载 opt-in。）
  #    因此原先「把 patchReload 从 live 改写成 startup 来关闭 HMR」的做法在 alpha.2 下**已失效**：
  #    该字段被静默忽略，sed 改写成了无人读取的死写入，而 web 的 HMR 实际上变成默认开启。
  #    关闭 HMR 现改由**启动参数** --patch 注入叠加层实现（见下方 HMR_OFF_PATCH 与
  #    scripts/hmr-off.yml）：既不碰 manifest，也不碰用户的 cordis.patch.yml。
  #    存量 profile 里遗留的 `patchReload` 字段实测**无害**（被忽略、不报错、不影响启动），
  #    故不做 JSON 字段删除 —— sed 摘字段极易留下尾逗号而毁掉 manifest，收益为零。
  #    dsh 的 initProfile 仅在 manifest 不存在时创建，故此处预置后会被 dsh 沿用。
  if [ -n "$RESCUE_PROFILE" ]; then
    pf="/data/dsh/profiles/$RESCUE_PROFILE/package.json"
    case "$RESCUE_PROFILE" in
      web)
        if [ ! -e "$pf" ]; then
          mkdir -p "/data/dsh/profiles/web"
          cat > "$pf" <<'PPF'
{
  "name": "dsh-profile-web",
  "private": true,
  "dependencies": {},
  "dsh": {
    "profile": {
      "bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]
    }
  }
}
PPF
          elog "[entrypoint]   web profile manifest preset (bundles only; HMR disabled at launch)"
        fi
        # profile 目录(含父级 profiles + 新落盘的 manifest + dsh 首启将创建的 node_modules/lifeboat)
        # 归运行用户。必须 chown 整个 /data/dsh/profiles:仅 chown web 子目录会使父级 profiles
        # 保持 root 属主,dsh 首启 mkdir profiles/node_modules 时 uid 1000 会 EACCES。
        chown -R "$RUN_USER_ID:$RUN_GROUP_ID" /data/dsh/profiles 2>/dev/null || true
        ;;
    esac
  fi

  # ⑥ 降权并重新 exec 本脚本。DSH_INIT_DONE 防止二次进入时再走本块。
  #
  # 【为何要探测 --init-groups】setpriv 的 --init-groups 会用 /etc/passwd 反查该 uid 的
  # 用户名，**uid 不存在时直接失败**：
  #   setpriv: uid 9999 not found, --init-groups requires an user that can be found on the system
  # 本镜像只自带 root 与 node(1000)。若使用者按文档/.env.example 的提示把 USER_UID 改成
  # 宿主上的其它 uid（例如 1024），这条 exec 会在 set -e 下失败 → PID1 退出 → 容器重启死循环，
  # 而且该块排在 lifeboat 之前，**连救生舱都到不了**（真机同类症状：2026-09-17）。
  # 故先探测：能 --init-groups 就带（补全附加组），不能就只设 uid/gid 降权并告警。
  export DSH_INIT_DONE=1
  if setpriv --reuid="$RUN_USER_ID" --regid="$RUN_GROUP_ID" --init-groups true 2>/dev/null; then
    elog "[entrypoint] dropping privileges to uid=$RUN_USER_ID gid=$RUN_GROUP_ID"
    exec setpriv --reuid="$RUN_USER_ID" --regid="$RUN_GROUP_ID" --init-groups "$0" "$@"
  fi
  elog "[entrypoint] WARN uid $RUN_USER_ID not resolvable in /etc/passwd; dropping without supplementary groups"
  elog "[entrypoint]      (supplementary groups are empty; uid/gid still applied as requested)"
  export DSH_INIT_DONE=1
  exec setpriv --reuid="$RUN_USER_ID" --regid="$RUN_GROUP_ID" "$0" "$@"
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

# 关闭 profile 的 HMR（read_only 生产加固，由来见 scripts/hmr-off.yml 文件头）。
# 【为何用启动参数而不是改 profile manifest】DSH 0.1.6-alpha.2 移除了 manifest 的
# patchReload 字段，HMR 改由 base 组合包的 hmr 条目按 profileContext 自动启用；稳定且
# 版本无关的关闭方式是在启动器上叠加 patch。--patch 在 0.1.5-rc.2 / 0.1.6-alpha.1 /
# 0.1.6-alpha.2 上都存在，故容器内升级或回退 dsh 都不会让本条失效——这正是「写 manifest
# 字段」方案在 alpha.2 上翻车的原因（字段随版本被删，写进去没人读，而门禁还在盯文本）。
# 仅对加载 dsh-base（因而真有 hmr 条目）的 profile 注入：web 与 lifeboat。其它 profile
# （如 sdk-minimal）不含该条目，注入只会多打一行 "patch: entry \"hmr\" not found" 的无谓警告。
HMR_OFF_YML=
for _c in /opt/dsh-rescue/hmr-off.yml "$HERE/scripts/hmr-off.yml" "$HERE/hmr-off.yml"; do
  [ -f "$_c" ] && { HMR_OFF_YML="$_c"; break; }
done
# 注意：函数在"不注入"分支必须显式 return 0 —— 命令替换的退出码就是赋值语句的退出码，
# 在 set -e 下返回非零会直接终止 PID1（本文件已有同类真机教训：见 ⑥ 步 setpriv 探测）。
hmr_off_args() {
  case "$1" in
    web|lifeboat)
      if [ -n "$HMR_OFF_YML" ]; then printf -- '--patch %s' "$HMR_OFF_YML"; fi
      ;;
  esac
  return 0
}
HMR_OFF_PATCH=$(hmr_off_args "$RESCUE_PROFILE")
HMR_OFF_PATCH_LIFEBOAT=$(hmr_off_args lifeboat)
if [ -n "$HMR_OFF_PATCH" ]; then
  elog "[entrypoint] HMR disabled via launch overlay: $HMR_OFF_YML"
elif [ -z "$HMR_OFF_YML" ]; then
  elog '[entrypoint] WARN hmr-off.yml missing; HMR keeps its default (see docs if read_only is on)'
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
  exec dsh --profile lifeboat $HMR_OFF_PATCH_LIFEBOAT --port $PORT_INNER --no-open $TRUSTED_ARGS
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
  exec dsh --profile "$RESCUE_PROFILE" $HMR_OFF_PATCH --port $PORT_INNER --no-open $TRUSTED_ARGS
fi
