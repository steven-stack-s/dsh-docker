#!/bin/sh
# 共享函数库：rescue 命令与 entrypoint source 本文件。POSIX sh（dash）兼容。
#
# 刻意**不**在这里设置 set -u / set -e：本文件被 entrypoint（PID1）与 rescue CLI 共同 source，
# 擅自开启 nounset 会让"某个变量忘了默认值"直接终止调用方 —— 而那正是容器启动路径。
# 需要防御的地方一律用 ${VAR:-default} 显式声明。

: "${DSH_HOME:?DSH_HOME must be set}"
RESCUE_PROFILE="${RESCUE_PROFILE:-web}"
RESCUE_DIR="$DSH_HOME/.rescue"
RESCUE_KEEP="${RESCUE_KEEP:-3}"
LOG_DIR="$RESCUE_DIR/log"
LOG_FILE="$LOG_DIR/rescue.log"

# HERE: 继承 source 方(如 rescue 已置为仓库根或 /opt/dsh-rescue)；否则尽力自定位。仅本地开发兜底用，镜像内 LIFEBOAT_TMPL 由 Dockerfile 恒置。
HERE="${HERE:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
LIFEBOAT_TMPL="${LIFEBOAT_TMPL:-$HERE/lifeboat.tmpl}"

# 从文件读取模型密钥（F8）：支持 docker secret / 挂载文件，让密钥不必出现在 environment ——
# 环境变量会被 `docker inspect` 与 /proc/<pid>/environ 直接读走。文件优先于环境变量。
# 返回 0=无需处理或已成功；非 0=显式配置了文件但读取失败（调用方据此告警，且不得清空既有值）。
# 解析 DSH_TRUSTED_HOSTS（逗号分隔）-> "--trusted-host a --trusted-host b"。
# 原来是在 entrypoint 里用未加引号的 `$(echo ... | tr ',' ' ')` 展开：空白与通配符会把一个条目
# 拆成多个、甚至注入额外参数；而 dsh 对每个白名单项都会 assertTrustedAuthority —— 一个畸形条目
# 就足以让启动失败，白白消耗 RESCUE_START_TIMEOUT 与自愈预算。这里逐项校验并丢弃非法项。
rescue_trusted_args() {
  _th_hosts="$1"
  _th_out=''
  [ -n "$_th_hosts" ] || { printf '%s' "$_th_out"; return 0; }
  _th_oldifs="$IFS"; IFS=','
  # 关掉路径展开（glob）：`for x in $var` 会把条目里的 * 展开成当前目录的文件名 ——
  # 真机上表现为"白名单里凭空出现一堆文件名"，而且随工作目录变化。
  case $- in *f*) _th_had_f=1 ;; *) _th_had_f=0 ;; esac
  set -f
  for _th_h in $_th_hosts; do
    IFS="$_th_oldifs"
    case "$_th_h" in
      '') : ;;
      # 允许域名/IP/host:port（字母数字 . _ : -）；* 等通配符不是合法 host 字符，必须丢弃
      *[!A-Za-z0-9._:-]*) rescue_log "trusted host ignored (invalid characters): $_th_h" ;;
      *) _th_out="$_th_out --trusted-host $_th_h" ;;
    esac
    IFS=','
  done
  IFS="$_th_oldifs"
  [ "$_th_had_f" = 1 ] || set +f
  printf '%s' "$_th_out"
}

rescue_load_api_key() {
  [ -n "${DEEPSEEK_API_KEY_FILE:-}" ] || return 0
  if [ ! -r "$DEEPSEEK_API_KEY_FILE" ]; then
    rescue_log "api key file not readable: $DEEPSEEK_API_KEY_FILE"
    return 1
  fi
  _rk=$(head -n1 "$DEEPSEEK_API_KEY_FILE" 2>/dev/null | tr -d '\r\n')
  [ -n "$_rk" ] || { rescue_log "api key file is empty: $DEEPSEEK_API_KEY_FILE"; return 1; }
  DEEPSEEK_API_KEY="$_rk"
  export DEEPSEEK_API_KEY
  return 0
}

rescue_log() {
  # 审计日志是"尽力而为"：路径不可写（卷满/只读）时不得影响调用方——PID1 启动路径也在用它。
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

profile_dir() { printf '%s/profiles/%s' "$DSH_HOME" "$RESCUE_PROFILE"; }
rescue_dir() { printf '%s' "$RESCUE_DIR"; }

next_snap_name() {
  mkdir -p "$RESCUE_DIR"
  # 取「已有最大编号 + 1」而非「第一个空缺编号」：prune 删除后重用编号会让按名排序的
  # 最新/最老判断错乱（诊断与自愈据此选 baseline，会回滚到错误快照）。
  max=0
  for d in "$RESCUE_DIR"/snap-*; do
    [ -d "$d" ] || continue
    num=${d##*/snap-}
    case "$num" in ''|*[!0-9]*) continue ;; esac
    num=$(printf '%s' "$num" | sed 's/^0*//')
    [ -n "$num" ] || num=0
    if [ "$num" -gt "$max" ]; then max=$num; fi
  done
  # 原子抢号：单纯"读最大号 -> 返回 +1"是 check-then-act —— entrypoint 的健康基线快照与用户的
  # `rescue plugin` 预防性快照完全可能并发，两边会选中同一个名字并互相覆盖（meta 甚至丢失，
  # 使"最新/最老"判定退化成目录 mtime）。mkdir 是原子的：谁先建出目录谁拿到号，另一方自动顺延。
  _nsn_n=$((max + 1))
  _nsn_i=0
  while [ "$_nsn_i" -lt 100 ]; do
    _nsn_cand=$(printf 'snap-%04d' "$_nsn_n")
    if mkdir "$RESCUE_DIR/$_nsn_cand" 2>/dev/null; then printf '%s' "$_nsn_cand"; return 0; fi
    _nsn_n=$((_nsn_n + 1))
    _nsn_i=$((_nsn_i + 1))
  done
  return 1
}

rescue_snapshot() {
  pdir=$(profile_dir)
  [ -d "$pdir" ] || { rescue_log "snapshot: profile missing $pdir"; return 1; }
  [ -f "$pdir/package.json" ] || { rescue_log "snapshot: no package.json"; return 1; }
  snap=$(next_snap_name) || { rescue_log "snapshot: cannot allocate a snapshot name"; return 1; }
  mkdir -p "$RESCUE_DIR/$snap"
  for f in package.json pnpm-lock.yaml pnpm-workspace.yaml; do
    if [ -f "$pdir/$f" ]; then cp "$pdir/$f" "$RESCUE_DIR/$snap/$f"; fi
  done
  # 快照模式：hardlink（默认，cp -al，秒级且几乎不占空间，但与 live 共享 inode，
  # 存在"被就地改写污染"的风险，靠 treeHash + rescue verify 检测）；copy（cp -a，独立副本，
  # 真正不可变，代价是 node_modules 全量复制占磁盘）。
  snap_mode="${RESCUE_SNAPSHOT_MODE:-hardlink}"
  if [ -d "$pdir/node_modules" ]; then
    rm -rf "$RESCUE_DIR/$snap/node_modules"
    if [ "$snap_mode" = copy ]; then
      cp -a "$pdir/node_modules" "$RESCUE_DIR/$snap/node_modules" 2>/dev/null \
        || rescue_log "snapshot: cp -a failed ($snap)"
    elif ! cp -al "$pdir/node_modules" "$RESCUE_DIR/$snap/node_modules" 2>/dev/null; then
      rescue_log "snapshot: cp -al failed -> cp -a"
      cp -a "$pdir/node_modules" "$RESCUE_DIR/$snap/node_modules" 2>/dev/null \
        || rescue_log "snapshot: cp -a failed ($snap)"
    fi
  fi
  th=''
  if [ -d "$RESCUE_DIR/$snap/node_modules" ]; then
    th=$(snapshot_tree_hash "$RESCUE_DIR/$snap/node_modules" 2>/dev/null || printf '')
  fi
  # 变更上下文：meta 记 reason（变更前基线归因的证据）。由触发方经 env REASON_SNAPSHOT 传入；
  # 走 rescue 封装(plugin)/entrypoint 自愈时带 trigger；缺省 manual。
  # profile 记下所属 profile，避免切换 RESCUE_PROFILE 后拿错 profile 的快照去恢复；
  # treeHash 供 rescue verify 判断快照是否已被写坏。
  reason="${REASON_SNAPSHOT:-manual}"
  meta="{\"created\":\"$(date -Iseconds)\",\"reason\":\"$reason\",\"dsh\":\"$(dsh --version 2>/dev/null || echo unknown)\",\"profile\":\"$RESCUE_PROFILE\",\"mode\":\"$snap_mode\",\"treeHash\":\"$th\"}"
  rescue_json_write "$RESCUE_DIR/$snap/meta.json" "$meta"
  rescue_log "snapshot created $snap (reason: $reason)"
  rescue_prune
  printf '%s' "$snap"
}

# ---- 变更上下文 / meta 查询 ----
rescue_meta_read() {
  # $1 = snap 名（如 snap-0001）或快照目录；打印其 meta.json，缺省打印空
  s="$1"
  case "$s" in
    snap-*) mf="$RESCUE_DIR/$s/meta.json" ;;
    *)      mf="$1/meta.json" ;;
  esac
  [ -f "$mf" ] || return 1
  cat "$mf"
}

rescue_prune() {
  n=$(ls -1d "$RESCUE_DIR"/snap-* 2>/dev/null | wc -l | tr -d ' ')
  while [ "$n" -gt "$RESCUE_KEEP" ]; do
    oldest=$(rescue_snapshot_oldest)
    [ -n "$oldest" ] || break
    rescue_log "prune $oldest"
    rm -rf "$oldest"
    n=$((n-1))
  done
}

rescue_snapshot_list() { ls -1d "$RESCUE_DIR"/snap-* 2>/dev/null | sort; }

# ---- 时间序（最新/最老）判定 ----
# 编号可能补位（历史遗留）或被 prune 删除后仍按名排序，字典序不足以判定「最新/最老」；
# 凡涉及二者的判断一律走这两个函数，避免诊断/自愈选错 baseline。
rescue_snap_created() {
  # $1 = 快照目录；优先 meta.created，缺失时回退目录 mtime
  d="$1"
  c=$(sed -n 's/.*"created":"\([^"]*\)".*/\1/p' "$d/meta.json" 2>/dev/null | head -n1)
  [ -n "$c" ] || c=$(date -r "$d" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || true)
  printf '%s' "$c"
}
rescue_snapshot_list_by_time() {
  for d in "$RESCUE_DIR"/snap-*; do
    [ -d "$d" ] || continue
    c=$(rescue_snap_created "$d")
    # created 只有秒级精度（且可能缺失）：同秒时用目录 mtime 作为次键，保证"最新/最老"不落到
    # 字典序（编号）上 —— 否则 prune 可能淘汰掉好的 baseline、留下自愈现场快照。
    m=$(date -r "$d" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || printf '0000-00-00T00:00:00')
    printf '%s\t%s\t%s\n' "$c" "$m" "$d"
  done | sort | cut -f3
}
rescue_snapshot_newest() { rescue_snapshot_list_by_time | tail -n1; }
rescue_snapshot_oldest() { rescue_snapshot_list_by_time | head -n1; }

# node_modules 树指纹：不跟随符号链接，摘要 路径/类型/大小/mtime/inode。
# 硬链接模式下快照与 live 共享 inode，任何"就地改写"（append/sed -i/原生模块重编）都会同时
# 改变两边的 size 与 mtime，因此该指纹能发现"快照已被写坏"——纯 cp -al 自身没有这种能力。
snapshot_tree_hash() {
  d="$1"
  [ -d "$d" ] || return 1
  ( cd "$d" 2>/dev/null && find . -mindepth 1 -printf '%p\t%y\t%s\t%T@\t%i\n' 2>/dev/null \
      | LC_ALL=C sort | md5sum | cut -d' ' -f1 )
}

rescue_fingerprint() {
  d="$1"
  ( cat "$d/package.json" 2>/dev/null; cat "$d/pnpm-lock.yaml" 2>/dev/null ) | md5sum | cut -d' ' -f1
}

# 输出 1 表示 live 与快照指纹不同（可安全回滚到它），0 相同
rescue_live_differs_from() {
  snap="$1"
  pdir=$(profile_dir)
  a=$(rescue_fingerprint "$pdir")
  b=$(rescue_fingerprint "$RESCUE_DIR/$snap")
  if [ "$a" != "$b" ]; then echo 1; else echo 0; fi
}

# 快照与当前 live 是否"等价"（即回滚到它没有任何效果）。返回 0 = 等价/冗余。
# 先比配置文件指纹，再比 node_modules 树哈希：只看 package.json+lockfile 会漏掉
# "配置文件相同、依赖树完全不同"的情况（copy 模式快照、pnpm 重装），界面会因此误报
# "回滚没有任何效果"，而实际上会把整棵依赖树换掉。
rescue_snapshot_is_redundant() {
  n="$1"
  [ "$(rescue_live_differs_from "$n" 2>/dev/null || echo 0)" = 1 ] && return 1
  want=$(rescue_meta_read "$n" 2>/dev/null | sed -n 's/.*"treeHash":"\([^"]*\)".*/\1/p')
  if [ -n "$want" ]; then
    live_th=$(snapshot_tree_hash "$(profile_dir)/node_modules" 2>/dev/null || printf '')
    if [ -n "$live_th" ] && [ "$live_th" != "$want" ]; then return 1; fi
  fi
  return 0
}

# 挑一个"有意义的"回退目标：从新到旧找第一个指纹与 live 不同、且不是自愈现场快照的快照。
# 为什么需要（P1-3）：diagnose 建议的目标常常就是"最新快照"，而自愈在每次动作前会先拍现场
# 快照，于是最新快照很可能与 live 完全相同 —— 回滚到它等于什么都不做，却会被记成 rollback ok
# 并消耗预算（真机表现为"自愈明明跑了，插件树没变，预算却没了"）。
rescue_pick_rollback_target() {
  preferred="${1:-}"
  if [ -n "$preferred" ] && [ -d "$RESCUE_DIR/$preferred" ] \
     && [ "$(rescue_live_differs_from "$preferred" 2>/dev/null || echo 0)" = 1 ]; then
    printf '%s' "$preferred"; return 0
  fi
  rev=$(rescue_snapshot_list_by_time | sed '1!G;h;$!d')   # 反序：最新 -> 最老
  [ -n "$rev" ] || return 1
  # 第一轮：优先"健康基线"快照（reason 形如 boot-healthy baseline）——那是唯一被证明能启动过的状态
  for d in $rev; do
    n=${d##*/}
    case "$(rescue_meta_read "$n" 2>/dev/null | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p')" in
      boot-healthy*) ;;
      *) continue ;;
    esac
    if [ "$(rescue_live_differs_from "$n" 2>/dev/null || echo 0)" = 1 ]; then printf '%s' "$n"; return 0; fi
  done
  # 第二轮：其他非现场快照
  for d in $rev; do
    n=${d##*/}
    case "$(rescue_meta_read "$n" 2>/dev/null | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p')" in
      selfheal-*) continue ;;
    esac
    if [ "$(rescue_live_differs_from "$n" 2>/dev/null || echo 0)" = 1 ]; then printf '%s' "$n"; return 0; fi
  done
  # 不再有三轮"放宽到现场快照"：selfheal-* 是自愈动作**之前**的坏现场，拿它当目标只会把
  # 用户推回故障状态。宁可 report-only。
  return 1
}

# 只动插件四件套；cordis.patch.yml 与用户数据一律不碰
rescue_restore() {
  _rr_snap="$1"
  _rr_pdir=$(profile_dir)
  _rr_src="$RESCUE_DIR/$_rr_snap"
  [ -d "$_rr_src" ] || { rescue_log "restore: missing $_rr_src"; return 1; }

  # profile 归属校验：切换 RESCUE_PROFILE 后，A profile 的快照不得被恢复进 B 的插件树
  # （否则表现为"回滚成功，但 B 的依赖树被换成了 A 的"）。
  _rr_meta=$(rescue_meta_read "$_rr_snap" 2>/dev/null || true)
  _rr_prof=$(printf '%s' "$_rr_meta" | sed -n 's/.*"profile":"\([^"]*\)".*/\1/p')
  if [ -n "$_rr_prof" ] && [ "$_rr_prof" != "$RESCUE_PROFILE" ]; then
    rescue_log "restore: refuse $_rr_snap (snapshot profile='$_rr_prof', current RESCUE_PROFILE='$RESCUE_PROFILE')"
    return 1
  fi
  _rr_mode=$(printf '%s' "$_rr_meta" | sed -n 's/.*"mode":"\([^"]*\)".*/\1/p')

  mkdir -p "$_rr_pdir" || { rescue_log "restore: cannot create $_rr_pdir"; return 1; }

  # 互斥锁：CLI 手动回滚与 entrypoint 自愈可能并发；陈旧锁（>1 分钟）自动接管，不会永久卡死
  _rr_lock="$RESCUE_DIR/.restore.lock"
  if ! mkdir "$_rr_lock" 2>/dev/null; then
    if [ -n "$(find "$_rr_lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rescue_log "restore: taking over stale lock $_rr_lock"
    else
      rescue_log "restore: another restore in progress, skipping $_rr_snap"
      return 1
    fi
  fi
  # 清理上次被 SIGKILL 留下的工作目录（此前无任何 GC，会长期残留在插件树里）
  rm -rf "$_rr_pdir"/.rescue-restore.* "$_rr_pdir"/.rescue-old.* "$_rr_pdir"/.rescue-bak.* 2>/dev/null || true

  # ---- ① 组装：先在 staging 里备齐完整新树；任何一步失败都直接放弃，live 一字未动 ----
  # 旧实现是"先 rm -rf live/node_modules 再拷"，中途失败（ENOSPC/权限/拷贝报错）会留下
  # 半棵树、且此时已无回退手段；这里改为 staging + 原子切换 + 失败回滚事务。
  _rr_staging="$_rr_pdir/.rescue-restore.$$"
  _rr_bak="$_rr_pdir/.rescue-bak.$$"
  _rr_old="$_rr_pdir/.rescue-old.$$"
  rm -rf "$_rr_staging" "$_rr_bak" "$_rr_old"
  if ! mkdir -p "$_rr_staging" "$_rr_bak"; then
    rescue_log "restore: cannot create work dirs under $_rr_pdir"
    rmdir "$_rr_lock" 2>/dev/null || true
    return 1
  fi
  rescue_log "restore apply $_rr_snap -> $_rr_pdir"
  # 降级前必须先删掉 cp 可能已经建出的半个目标目录：GNU cp 失败时目标目录可能已存在，
  # 此时 `cp -a SRC DST`（DST 已是目录）会变成 DST/SRC —— 产出 node_modules/node_modules
  # 这种嵌套树，而且函数会"成功"返回（评审实测过）。copy 模式的快照直接用 cp -a。
  if [ -d "$_rr_src/node_modules" ]; then
    _rr_cp_ok=1
    if [ "$_rr_mode" = copy ]; then
      cp -a "$_rr_src/node_modules" "$_rr_staging/node_modules" 2>/dev/null || _rr_cp_ok=0
    elif ! cp -al "$_rr_src/node_modules" "$_rr_staging/node_modules" 2>/dev/null; then
      rm -rf "$_rr_staging/node_modules"
      cp -a "$_rr_src/node_modules" "$_rr_staging/node_modules" 2>/dev/null || _rr_cp_ok=0
    fi
    if [ "$_rr_cp_ok" != 1 ]; then
      rescue_log "restore: copy node_modules FAILED ($_rr_snap)"
      rm -rf "$_rr_staging" "$_rr_bak"
      rmdir "$_rr_lock" 2>/dev/null || true
      return 1
    fi
  fi
  for _rr_f in package.json pnpm-lock.yaml pnpm-workspace.yaml; do
    if [ -f "$_rr_src/$_rr_f" ]; then
      if ! cp "$_rr_src/$_rr_f" "$_rr_staging/$_rr_f" 2>/dev/null; then
        rescue_log "restore: copy $_rr_f FAILED ($_rr_snap)"
        rm -rf "$_rr_staging" "$_rr_bak"
        rmdir "$_rr_lock" 2>/dev/null || true
        return 1
      fi
    fi
  done

  # ---- ② 原子切换：全部用同目录 rename，live 任何时刻都处于"完整旧态"或"完整新态" ----
  _rr_had_nm=0
  if [ -e "$_rr_pdir/node_modules" ]; then
    if mv "$_rr_pdir/node_modules" "$_rr_old" 2>/dev/null; then
      _rr_had_nm=1
    else
      rescue_log "restore: cannot move aside node_modules"
      rm -rf "$_rr_staging" "$_rr_bak"
      rmdir "$_rr_lock" 2>/dev/null || true
      return 1
    fi
  fi
  # 旧配置文件先让位到 bak（rename 同文件系统；失败时留在原处，回滚阶段会据此判断）
  for _rr_f in package.json pnpm-lock.yaml pnpm-workspace.yaml; do
    if [ -e "$_rr_pdir/$_rr_f" ]; then mv "$_rr_pdir/$_rr_f" "$_rr_bak/$_rr_f" 2>/dev/null || true; fi
  done
  _rr_ok=1
  if [ -d "$_rr_staging/node_modules" ]; then
    mv "$_rr_staging/node_modules" "$_rr_pdir/node_modules" 2>/dev/null || _rr_ok=0
  fi
  if [ "$_rr_ok" = 1 ]; then
    for _rr_f in package.json pnpm-lock.yaml pnpm-workspace.yaml; do
      if [ -f "$_rr_staging/$_rr_f" ]; then
        mv "$_rr_staging/$_rr_f" "$_rr_pdir/$_rr_f" 2>/dev/null || { _rr_ok=0; break; }
      fi
    done
  fi
  if [ "$_rr_ok" = 1 ]; then
    rm -rf "$_rr_old" "$_rr_staging" "$_rr_bak" 2>/dev/null || true
    rmdir "$_rr_lock" 2>/dev/null || true
    rescue_log "restore done $_rr_snap"
    return 0
  fi

  # ---- ③ 事务回滚：node_modules 与**三个配置文件**一起还原成切换前的状态 ----
  # 旧实现只还原 node_modules：package.json 已换成快照值、pnpm-lock.yaml 替换失败时，live 会停在
  # "半新半旧"的混合状态，日志却谎报 live unchanged（评审实测）。
  rm -rf "$_rr_pdir/node_modules" 2>/dev/null || true
  if [ "$_rr_had_nm" = 1 ]; then mv "$_rr_old" "$_rr_pdir/node_modules" 2>/dev/null || true; fi
  for _rr_f in package.json pnpm-lock.yaml pnpm-workspace.yaml; do
    if [ -e "$_rr_bak/$_rr_f" ]; then
      rm -f "$_rr_pdir/$_rr_f" 2>/dev/null || true
      mv "$_rr_bak/$_rr_f" "$_rr_pdir/$_rr_f" 2>/dev/null || true
    fi
  done
  rm -rf "$_rr_staging" "$_rr_bak" "$_rr_old" 2>/dev/null || true
  rmdir "$_rr_lock" 2>/dev/null || true
  rescue_log "restore: FAILED, live tree restored to its previous state ($_rr_snap)"
  return 1
}

# 校验一个快照是否仍然可信：meta.treeHash 必须与重算结果一致（快照未被就地写坏），
# meta.profile 必须与当前 RESCUE_PROFILE 一致（防止跨 profile 误恢复）。
# 返回 0=可信；非 0=存在问题（打印原因）。
rescue_verify() {
  snap="$1"
  d="$RESCUE_DIR/$snap"
  [ -d "$d" ] || { echo "verify: $snap: 快照目录不存在"; return 1; }
  mf="$d/meta.json"
  [ -f "$mf" ] || { echo "verify: $snap: meta.json 缺失"; return 1; }
  want=$(sed -n 's/.*"treeHash":"\([^"]*\)".*/\1/p' "$mf" | head -n1)
  prof=$(sed -n 's/.*"profile":"\([^"]*\)".*/\1/p' "$mf" | head -n1)
  mode=$(sed -n 's/.*"mode":"\([^"]*\)".*/\1/p' "$mf" | head -n1)
  [ -n "$mode" ] || mode=unknown
  rc=0
  if [ -n "$prof" ] && [ "$prof" != "$RESCUE_PROFILE" ]; then
    echo "verify: $snap: profile 不匹配（快照属于 '$prof'，当前 RESCUE_PROFILE='$RESCUE_PROFILE'）——用它恢复会污染另一个 profile"
    rc=1
  fi
  if [ -d "$d/node_modules" ]; then
    if [ -z "$want" ]; then
      # 旧快照没有 treeHash：这是"无法校验"，**不是**"已损坏"。若一律判失败并提示删除，
      # 升级后的用户会被诱导删掉唯一可用的回退点。
      echo "verify: $snap: 旧快照（meta 未记录 treeHash），跳过完整性校验"
    else
      got=$(snapshot_tree_hash "$d/node_modules" 2>/dev/null || printf '')
      if [ "$got" != "$want" ]; then
        echo "verify: $snap: node_modules 已被写坏（快照不再可信，勿作为回退点）"
        rc=1
      fi
    fi
  elif [ -n "$want" ]; then
    # meta 记录过树哈希、快照里却没有 node_modules：快照已不完整，回滚会把 live 的依赖树删掉
    echo "verify: $snap: 快照的 node_modules 缺失（meta 记录过树哈希）——快照已不完整"
    rc=1
  fi
  [ "$rc" = 0 ] && echo "verify: $snap OK (mode=$mode, profile=${prof:-?})"
  return $rc
}

# ---- 自动降级进救生舱（F7）----
# 自愈彻底失败时写一个**一次性**标记，下次启动以干净最小 profile 起来 —— 否则用户面对的是
# restart: unless-stopped 的无限 crashloop，连界面都进不去。进入救生舱时清除标记：用户修好
# 插件后直接 docker restart 就能回到正常 profile，不需要再改 .env。
_lifeboat_marker() { printf '%s/lifeboat-requested' "$(state_dir)"; }
rescue_lifeboat_request() { rescue_json_write "$(_lifeboat_marker)" "{\"requested\":\"$(rescue_ts)\",\"reason\":\"${1:-self-heal exhausted}\"}"; }
rescue_lifeboat_requested() { [ -f "$(_lifeboat_marker)" ]; }
rescue_lifeboat_clear() { rm -f "$(_lifeboat_marker)" 2>/dev/null || true; }

rescue_init_lifeboat() {
  mkdir -p "$DSH_HOME/profiles/lifeboat"
  if [ ! -f "$DSH_HOME/profiles/lifeboat/package.json" ]; then
    cp "$LIFEBOAT_TMPL/package.json" "$DSH_HOME/profiles/lifeboat/package.json" 2>/dev/null || true
    cp "$LIFEBOAT_TMPL/cordis.patch.yml" "$DSH_HOME/profiles/lifeboat/cordis.patch.yml" 2>/dev/null || true
    rescue_log 'lifeboat profile initialized'
  fi
}

# ============================================================
# 状态 / 证据 / incident 基础（rescue-diagnose）
# ============================================================
incident_dir(){ printf '%s/incidents' "$RESCUE_DIR"; }
evidence_dir(){ printf '%s/evidence' "$RESCUE_DIR"; }
state_dir(){ printf '%s/state' "$RESCUE_DIR"; }

# 原子 JSON 写盘：写 <f>.tmp.$$ 后 mv 覆盖
rescue_json_write() {
  f="$1"; json="$2"
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$json" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}
rescue_json_read() {
  f="$1"; [ -f "$f" ] || return 1; cat "$f"
}

# incident id：时间戳+随机后缀，追加不覆盖
incident_id() {
  ts=$(date +%Y%m%dT%H%M%S)
  rnd=$(head -c4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ -n "$rnd" ] || rnd=$$
  printf 'inc-%s-%s' "$ts" "$rnd"
}
rescue_incident_write() {
  body="$1"; mkdir -p "$(incident_dir)"
  id=$(incident_id)
  while [ -f "$(incident_dir)/$id.json" ]; do id=$(incident_id); done
  rescue_json_write "$(incident_dir)/$id.json" "$body"
  rescue_log "incident written $id"
  rescue_incident_prune
  printf '%s' "$id"
}
rescue_incident_list() { ls -1t "$(incident_dir)"/inc-*.json 2>/dev/null; }
rescue_incident_prune() {
  n=$(rescue_incident_list | wc -l | tr -d ' ')
  keep="${RESCUE_INCIDENT_KEEP:-20}"
  while [ "$n" -gt "$keep" ]; do
    oldest=$(rescue_incident_list | tail -n1); [ -n "$oldest" ] || break
    rm -f "$oldest"; n=$((n-1))
  done
}

# ---- 自愈预算（持久化在数据卷，但按时间窗口自动过期）----
# 为什么需要窗口（P0-2）：预算原先跨容器重启累计且**永不重置**，用满 2 次摘插件 + 2 次回快照后
# 该部署此后所有重启都只能 report-only，而文档写的是"单容器生命周期内"——自愈静默失效、
# 用户毫无察觉。现在超过 RESCUE_SELFHEAL_WINDOW（默认 86400s）即自动清零，重新获得自愈能力。
rescue_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# 返回 0 = 窗口已过期（调用方应清零计数）。时间解析失败时保守返回 1（不清零）。
rescue_budget_window_expired() {
  start="$1"
  [ -n "$start" ] || return 0
  now=$(date +%s 2>/dev/null) || return 1
  s=$(date -d "$start" +%s 2>/dev/null) || return 1
  [ -n "$now" ] && [ -n "$s" ] || return 1
  [ $(( now - s )) -ge "${RESCUE_SELFHEAL_WINDOW:-86400}" ]
}

rescue_budget_read() {
  bj="$(rescue_state_read_selfheal 2>/dev/null || true)"
  SELFHEAL_REMOVES=0; SELFHEAL_ROLLBACKS=0; SELFHEAL_WINDOW_START=''
  if [ -n "$bj" ]; then
    _rm=$(printf '%s' "$bj" | sed -n 's/.*"removes":\([0-9]*\).*/\1/p')
    _rb=$(printf '%s' "$bj" | sed -n 's/.*"rollbacks":\([0-9]*\).*/\1/p')
    _ws=$(printf '%s' "$bj" | sed -n 's/.*"windowStart":"\([^"]*\)".*/\1/p')
    [ -n "$_rm" ] && SELFHEAL_REMOVES="$_rm"
    [ -n "$_rb" ] && SELFHEAL_ROLLBACKS="$_rb"
    [ -n "$_ws" ] && SELFHEAL_WINDOW_START="$_ws"
  fi
  if rescue_budget_window_expired "$SELFHEAL_WINDOW_START"; then
    [ -n "$SELFHEAL_WINDOW_START" ] && rescue_log "selfheal budget window expired (started $SELFHEAL_WINDOW_START) -> counters reset"
    SELFHEAL_REMOVES=0; SELFHEAL_ROLLBACKS=0
    SELFHEAL_WINDOW_START="$(rescue_ts)"
  fi
  return 0
}

rescue_budget_write() {
  [ -n "${SELFHEAL_WINDOW_START:-}" ] || SELFHEAL_WINDOW_START="$(rescue_ts)"
  rescue_state_write_selfheal "{\"removes\":${SELFHEAL_REMOVES:-0},\"rollbacks\":${SELFHEAL_ROLLBACKS:-0},\"windowStart\":\"$SELFHEAL_WINDOW_START\",\"updated\":\"$(rescue_ts)\"}" 2>/dev/null || true
}

rescue_state_write_lastrun() { rescue_json_write "$(state_dir)/last-run.json" "$1"; }
rescue_state_read_lastrun() { rescue_json_read "$(state_dir)/last-run.json"; }
rescue_state_write_selfheal() { rescue_json_write "$(state_dir)/selfheal.json" "$1"; }
rescue_state_read_selfheal() { rescue_json_read "$(state_dir)/selfheal.json"; }

