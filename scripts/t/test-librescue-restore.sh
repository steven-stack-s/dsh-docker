#!/bin/sh
# ============================================================================
# test-librescue-restore.sh — rescue_restore() 的成功/失败可见性
#
# 背景：rescue_restore 的最后一条命令曾是 rescue_log（几乎恒成功），于是"拷贝失败"也会
# 返回 0 —— 自愈据此把"没恢复成功"记成 rollback ok、消耗预算、并让用户以为已恢复。
# 本测试锁定契约：恢复成功返回 0 且内容一致；恢复失败必须返回非 0。
#
# 用法: sh scripts/t/test-librescue-restore.sh    （全通过打印 ALL-PASS）
# ============================================================================
set -u
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME/profiles/web"
. "$HERE/../librescue.sh"

# ---- 1) 正常恢复：返回 0，且 live 内容与快照一致 ----
printf '{"name":"web","dependencies":{"a":"1.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
printf 'lock v1\n' > "$DSH_HOME/profiles/web/pnpm-lock.yaml"
s=$(REASON_SNAPSHOT=test rescue_snapshot)
[ "$s" = "snap-0001" ] || { echo "FAIL-snapshot-name: $s"; exit 1; }
printf '{"name":"web","dependencies":{"a":"2.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
rescue_restore snap-0001 || { echo 'FAIL-restore-ok-returned-nonzero'; exit 1; }
cmp -s "$DSH_HOME/profiles/web/package.json" "$RESCUE_DIR/snap-0001/package.json" \
  || { echo 'FAIL-restore-content-not-applied'; exit 1; }

# ---- 2) 恢复失败必须可见 ----
# 注入点用 PATH 上的失败 cp：以 root 运行时"目标不可写"之类的手段不生效，
# 且 cp file dir 会"成功"地把文件复制进目录，只有替换 cp 才能真正走到失败分支。
printf '{"name":"web","dependencies":{"a":"3.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
mkdir -p "$T/bin"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/cp"
chmod +x "$T/bin/cp"
if ( PATH="$T/bin:$PATH"; rescue_restore snap-0001 >/dev/null 2>&1 ); then
  echo 'FAIL-restore-failure-reported-as-success'
  exit 1
fi

# ---- 3) 失败必须不留半棵树：恢复中途失败时 live 树应保持原样 ----
# 旧实现是"先 rm -rf node_modules 再拷"，任何拷贝失败都会把 live 删空且无法回退；
# 新实现先在 staging 里组装、成功后才原子替换，失败时 live 一字未动。
rm -rf "$DSH_HOME/profiles/web/package.json"
mkdir -p "$DSH_HOME/profiles/web/node_modules/keepme"
printf 'live-content\n' > "$DSH_HOME/profiles/web/node_modules/keepme/index.js"
printf '{"name":"web","dependencies":{"live":"1"}}' > "$DSH_HOME/profiles/web/package.json"
before_nm=$(find "$DSH_HOME/profiles/web/node_modules" | sort)
before_pkg=$(cat "$DSH_HOME/profiles/web/package.json")
if ( PATH="$T/bin:$PATH"; rescue_restore snap-0001 >/dev/null 2>&1 ); then
  echo 'FAIL-atomic-restore-failure-reported-as-success'
  exit 1
fi
[ -d "$DSH_HOME/profiles/web/node_modules/keepme" ] \
  || { echo 'FAIL-atomic-restore-wiped-live-node-modules'; exit 1; }
[ "$(find "$DSH_HOME/profiles/web/node_modules" | sort)" = "$before_nm" ] \
  || { echo 'FAIL-atomic-restore-changed-live-tree'; exit 1; }
[ "$(cat "$DSH_HOME/profiles/web/package.json")" = "$before_pkg" ] \
  || { echo 'FAIL-atomic-restore-changed-live-package-json'; exit 1; }
# 不留临时垃圾
ls -d "$DSH_HOME/profiles/web"/.rescue-restore.* "$DSH_HOME/profiles/web"/.rescue-old.* >/dev/null 2>&1 \
  && { echo 'FAIL-atomic-restore-left-staging-junk'; exit 1; }

# ---- 4) cp -al 失败降级 cp -a 时不得产生嵌套目录（C1）----
# GNU cp 在失败前可能已经建出目标目录；此时 `cp -a SRC DST`（DST 已存在且是目录）会变成
# DST/SRC —— 产出 node_modules/node_modules 这种嵌套树，而且函数**仍然返回 0**。
mkdir -p "$T/bin-fallback"
cat > "$T/bin-fallback/cp" <<'STUB'
#!/bin/sh
if [ "$1" = "-al" ]; then mkdir -p "$3" 2>/dev/null; exit 1; fi
exec /bin/cp "$@"
STUB
chmod +x "$T/bin-fallback/cp"
rm -rf "$DSH_HOME/profiles/web" "$RESCUE_DIR"
mkdir -p "$DSH_HOME/profiles/web/node_modules/pkg"
printf '{"name":"web","dependencies":{"a":"1.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
printf 'v1\n' > "$DSH_HOME/profiles/web/node_modules/pkg/index.js"
REASON_SNAPSHOT=c1 rescue_snapshot >/dev/null
rm -rf "$DSH_HOME/profiles/web/node_modules"
if ! ( PATH="$T/bin-fallback:$PATH"; rescue_restore snap-0001 >/dev/null 2>&1 ); then
  echo 'FAIL-c1-fallback-restore-rc'; exit 1
fi
[ -f "$DSH_HOME/profiles/web/node_modules/pkg/index.js" ] \
  || { echo 'FAIL-c1-live-node-modules-broken'; find "$DSH_HOME/profiles/web" | head -8; exit 1; }
[ -d "$DSH_HOME/profiles/web/node_modules/node_modules" ] \
  && { echo 'FAIL-c1-nested-node-modules'; exit 1; }

# ---- 5) 配置文件替换失败时，live 必须完整还原（C2）----
# 原实现的事务回滚只还原 node_modules：若 package.json 已换成快照值、pnpm-lock.yaml 替换失败，
# live 会停在"半新半旧"的混合状态，日志却写 "live tree left unchanged"。
mkdir -p "$T/bin-mvfail"
cat > "$T/bin-mvfail/mv" <<'STUB'
#!/bin/sh
case "$2" in *pnpm-lock.yaml) exit 1 ;; esac
exec /bin/mv "$@"
STUB
chmod +x "$T/bin-mvfail/mv"
rm -rf "$DSH_HOME/profiles/web" "$RESCUE_DIR"
mkdir -p "$DSH_HOME/profiles/web/node_modules/pkg"
printf '{"name":"web","dependencies":{"a":"1.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
printf 'lock v1\n' > "$DSH_HOME/profiles/web/pnpm-lock.yaml"
printf 'v1\n' > "$DSH_HOME/profiles/web/node_modules/pkg/index.js"
REASON_SNAPSHOT=c2 rescue_snapshot >/dev/null
printf '{"name":"web","dependencies":{"a":"2.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
printf 'lock v2\n' > "$DSH_HOME/profiles/web/pnpm-lock.yaml"
printf 'v2\n' > "$DSH_HOME/profiles/web/node_modules/pkg/index.js"
b_pkg=$(cat "$DSH_HOME/profiles/web/package.json")
b_lock=$(cat "$DSH_HOME/profiles/web/pnpm-lock.yaml")
if ( PATH="$T/bin-mvfail:$PATH"; rescue_restore snap-0001 >/dev/null 2>&1 ); then
  echo 'FAIL-c2-partial-restore-reported-as-success'; exit 1
fi
[ "$(cat "$DSH_HOME/profiles/web/package.json")" = "$b_pkg" ] \
  || { echo 'FAIL-c2-package-json-not-rolled-back'; cat "$DSH_HOME/profiles/web/package.json"; exit 1; }
[ "$(cat "$DSH_HOME/profiles/web/pnpm-lock.yaml")" = "$b_lock" ] \
  || { echo 'FAIL-c2-lock-not-rolled-back'; cat "$DSH_HOME/profiles/web/pnpm-lock.yaml"; exit 1; }
[ -f "$DSH_HOME/profiles/web/node_modules/pkg/index.js" ] \
  || { echo 'FAIL-c2-node-modules-lost'; find "$DSH_HOME/profiles/web" | head -8; exit 1; }
[ "$(cat "$DSH_HOME/profiles/web/node_modules/pkg/index.js")" = "v2" ] \
  || { echo 'FAIL-c2-node-modules-not-rolled-back'; exit 1; }

echo ALL-PASS
