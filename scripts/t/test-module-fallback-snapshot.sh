#!/bin/sh
# ============================================================================
# test-module-fallback-snapshot.sh — .dsh-module-fallback 必须随 node_modules 一起快照/还原
#
# 背景：DSH 的 bundle 包解析会在 profile 下维护 .dsh-module-fallback/node_modules，
# 而 profile/node_modules 里的 bundle 条目往往是指向它的**符号链接**。
# 旧实现只快照 node_modules + 三个配置文件 -> 回滚后链接还在、目标没了，
# 表现为"回滚成功但 profile 起不来"（比不回滚更糟：消耗了自愈预算还改了树）。
#
# 契约：
#   1. 快照必须捕获 .dsh-module-fallback 的内容
#   2. 回滚必须把 live 的该目录还原成快照时的状态
#   3. live 的符号链接在回滚后必须重新可解析（不悬空）
#   4. 老快照（不含该目录）仍能正常回滚，不得报错
#
# 用法: sh scripts/t/test-module-fallback-snapshot.sh    （全通过打印 ALL-PASS）
# ============================================================================
set -u
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

export DSH_HOME="$T/home"
PDIR="$DSH_HOME/profiles/web"
MFDIR="$PDIR/.dsh-module-fallback/node_modules"
mkdir -p "$PDIR/node_modules" "$MFDIR/bundle-pkg"
printf '{"name":"web","private":true,"dependencies":{}}' > "$PDIR/package.json"
printf 'bundle v1\n' > "$MFDIR/bundle-pkg/index.js"
# profile/node_modules 里是指向 fallback 的符号链接（复刻真实布局）
ln -s "../.dsh-module-fallback/node_modules/bundle-pkg" "$PDIR/node_modules/bundle-pkg"
. "$HERE/../librescue.sh"

# ---- 1) 快照捕获 .dsh-module-fallback ----
s=$(REASON_SNAPSHOT=fallback-test rescue_snapshot) || { echo 'FAIL-snapshot-failed'; exit 1; }
[ -n "$s" ] || { echo 'FAIL-empty-snapshot-name'; exit 1; }
snapdir="$RESCUE_DIR/$s"
[ -e "$snapdir/.dsh-module-fallback/node_modules/bundle-pkg/index.js" ] \
  || { echo 'FAIL-snapshot-missing-module-fallback'; exit 1; }

# ---- 2) 破坏 live：删掉 fallback 目标（制造悬空链接）----
# 注意不要用 "printf > 文件" 就地改写来模拟故障：默认 hardlink 模式下快照与 live 共享 inode，
# 就地改写会**同时改坏快照自己**（这正是 test-snapshot-integrity.sh 记录的已知现象），
# 于是断言测不出"回滚有没有还原目录"。真实故障（插件被卸载/目录被删）走的是删除路径，故用 rm。
rm -rf "$MFDIR/bundle-pkg"
# 注意 -e 会跟随符号链接：目标没了它就为假。-L 才是"链接本身存在"的判据（悬空链接仍为真）。
[ -L "$PDIR/node_modules/bundle-pkg" ] || { echo 'FAIL-test-setup-link-gone'; exit 1; }
# 此刻链接必须确实悬空（-e 为假才算复现成功）
[ -e "$PDIR/node_modules/bundle-pkg/index.js" ] && { echo 'FAIL-test-setup-not-dangling'; exit 1; }

# ---- 3) 回滚 ----
rescue_restore "$s" >/dev/null 2>&1 || { echo 'FAIL-restore-returned-nonzero'; exit 1; }

# ---- 4) fallback 目录内容必须回到 v1 ----
[ -f "$MFDIR/bundle-pkg/index.js" ] || { echo 'FAIL-restore-lost-module-fallback'; exit 1; }
if ! grep -q 'bundle v1' "$MFDIR/bundle-pkg/index.js"; then
  echo "FAIL-restore-wrong-content: $(cat "$MFDIR/bundle-pkg/index.js")"; exit 1
fi

# ---- 5) 符号链接必须重新可解析（不悬空；此处 -e 才是"能解析到目标"的正确判据）----
[ -e "$PDIR/node_modules/bundle-pkg/index.js" ] \
  || { echo 'FAIL-restore-left-dangling-symlink'; exit 1; }

# ---- 6) 老快照（无 .dsh-module-fallback）仍能回滚，不得报错 ----
oldsnap="$RESCUE_DIR/snap-old"
mkdir -p "$oldsnap"
cp "$PDIR/package.json" "$oldsnap/package.json"
printf '{"created":"2026-01-01T00:00:00+0800","reason":"legacy","profile":"web","mode":"hardlink","treeHash":""}' > "$oldsnap/meta.json"
mkdir -p "$oldsnap/node_modules"
cp -a "$PDIR/node_modules/." "$oldsnap/node_modules/" 2>/dev/null || true
rescue_restore "snap-old" >/dev/null 2>&1 || { echo 'FAIL-legacy-snapshot-restore-broke'; exit 1; }

echo 'ALL-PASS'
