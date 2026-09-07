#!/bin/sh
# 共享函数库：rescue 命令与 entrypoint source 本文件。POSIX sh（dash）兼容。
set -u

: "${DSH_HOME:?DSH_HOME must be set}"
RESCUE_PROFILE="${RESCUE_PROFILE:-web}"
RESCUE_DIR="$DSH_HOME/.rescue"
RESCUE_KEEP="${RESCUE_KEEP:-3}"
LOG_DIR="$RESCUE_DIR/log"
LOG_FILE="$LOG_DIR/rescue.log"

# HERE: 继承 source 方(如 rescue 已置为仓库根或 /opt/dsh-rescue)；否则尽力自定位。仅本地开发兜底用，镜像内 LIFEBOAT_TMPL 由 Dockerfile 恒置。
HERE="${HERE:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
LIFEBOAT_TMPL="${LIFEBOAT_TMPL:-$HERE/profiles/lifeboat.tmpl}"

rescue_log() {
  mkdir -p "$LOG_DIR"
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE"
}

profile_dir() { printf '%s/profiles/%s' "$DSH_HOME" "$RESCUE_PROFILE"; }
rescue_dir() { printf '%s' "$RESCUE_DIR"; }

next_snap_name() {
  mkdir -p "$RESCUE_DIR"
  i=1
  while [ -d "$RESCUE_DIR/snap-$(printf '%04d' "$i")" ]; do i=$((i+1)); done
  printf 'snap-%04d' "$i"
}

rescue_snapshot() {
  pdir=$(profile_dir)
  [ -d "$pdir" ] || { rescue_log "snapshot: profile missing $pdir"; return 1; }
  [ -f "$pdir/package.json" ] || { rescue_log "snapshot: no package.json"; return 1; }
  snap=$(next_snap_name)
  mkdir -p "$RESCUE_DIR/$snap"
  for f in package.json pnpm-lock.yaml pnpm-workspace.yaml; do
    if [ -f "$pdir/$f" ]; then cp "$pdir/$f" "$RESCUE_DIR/$snap/$f"; fi
  done
  if [ -d "$pdir/node_modules" ]; then
    rm -rf "$RESCUE_DIR/$snap/node_modules"
    if ! cp -al "$pdir/node_modules" "$RESCUE_DIR/$snap/node_modules" 2>/dev/null; then
      rescue_log "snapshot: cp -al failed -> cp -a"
      cp -a "$pdir/node_modules" "$RESCUE_DIR/$snap/node_modules"
    fi
  fi
  # 变更上下文：meta 记 reason（变更前基线归因的证据）。由触发方经 env REASON_SNAPSHOT 传入；
  # 走 rescue 封装(plugin)/entrypoint 自愈时带 trigger；缺省 manual。
  reason="${REASON_SNAPSHOT:-manual}"
  meta="{\"created\":\"$(date -Iseconds)\",\"reason\":\"$reason\",\"dsh\":\"$(dsh --version 2>/dev/null || echo unknown)\"}"
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
    oldest=$(ls -1d "$RESCUE_DIR"/snap-* 2>/dev/null | sort | head -n1)
    [ -n "$oldest" ] || break
    rescue_log "prune $oldest"
    rm -rf "$oldest"
    n=$((n-1))
  done
}

rescue_snapshot_list() { ls -1d "$RESCUE_DIR"/snap-* 2>/dev/null | sort; }

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

# 只动插件四件套；cordis.patch.yml 与用户数据一律不碰
rescue_restore() {
  snap="$1"
  pdir=$(profile_dir)
  src="$RESCUE_DIR/$snap"
  [ -d "$src" ] || { rescue_log "restore: missing $src"; return 1; }
  mkdir -p "$pdir"
  rescue_log "restore apply $snap -> $pdir"
  rm -rf "$pdir/node_modules"
  if [ -d "$src/node_modules" ]; then
    if ! cp -al "$src/node_modules" "$pdir/node_modules" 2>/dev/null; then cp -a "$src/node_modules" "$pdir/node_modules"; fi
  fi
  for f in package.json pnpm-lock.yaml pnpm-workspace.yaml; do
    if [ -f "$src/$f" ]; then cp "$src/$f" "$pdir/$f"; else rm -f "$pdir/$f"; fi
  done
  rescue_log "restore done $snap"
}

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

rescue_state_write_lastrun() { rescue_json_write "$(state_dir)/last-run.json" "$1"; }
rescue_state_read_lastrun() { rescue_json_read "$(state_dir)/last-run.json"; }
rescue_state_write_selfheal() { rescue_json_write "$(state_dir)/selfheal.json" "$1"; }
rescue_state_read_selfheal() { rescue_json_read "$(state_dir)/selfheal.json"; }

