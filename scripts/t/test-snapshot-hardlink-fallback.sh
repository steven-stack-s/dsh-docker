#!/bin/sh
# ============================================================================
# test-snapshot-hardlink-fallback.sh — cp -al 失败回退时不得产出嵌套 node_modules
#
# 真机背景（2026-09-17）：NAS 上 `cp -al` 失败（EXDEV / EACCES）时会在目标留下
# **部分创建的目录树**。旧代码不清理就回退 `cp -a SRC DST`，而 DST 此时已存在 ——
# cp 会把 SRC 拷【进】DST，产出 `node_modules/node_modules` 嵌套目录，每份快照
# 白占约 900MB（真机 snap-0060/0061 各 1.8G，正常应为 904M）。
#
# 做法：用桩 cp 让 `cp -al` 必定"先建目录再失败"（复刻真机行为），其余调用透传真 cp。
# 断言：
#   1) 回退后快照里确实有内容（cp -a 生效）
#   2) **不存在** node_modules/node_modules 嵌套
# ============================================================================
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB="$ROOT/scripts/librescue.sh"
[ -f "$LIB" ] || { echo "FAIL librescue missing"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export DSH_HOME="$T/home"

# --- 桩 cp：-al 先造部分目录树再以非零退出（模拟真机 cp -al 失败）---
STUB="$T/stub"
mkdir -p "$STUB"
REAL_CP=$(command -v cp)
cat > "$STUB/cp" <<EOF
#!/bin/sh
if [ "\$1" = "-al" ]; then
  last=''
  for a in "\$@"; do last="\$a"; done
  mkdir -p "\$last" 2>/dev/null || true
  exit 1
fi
exec "$REAL_CP" "\$@"
EOF
chmod +x "$STUB/cp"

mkdir -p "$DSH_HOME/profiles/web/node_modules/demo-pkg"
echo hi > "$DSH_HOME/profiles/web/node_modules/demo-pkg/index.js"
printf '%s' '{"name":"web"}' > "$DSH_HOME/profiles/web/package.json"

# shellcheck disable=SC1090
. "$LIB"

PATH="$STUB:$PATH" rescue_snapshot >/dev/null 2>&1 || true

snap=$(ls -d "$DSH_HOME/.rescue"/snap-* 2>/dev/null | head -1 || true)
[ -n "$snap" ] || { echo "FAIL no-snapshot-created"; exit 1; }

# 1) 关键：不得出现嵌套（回归点，先判它以便诊断信息准确）
if [ -e "$snap/node_modules/node_modules" ]; then
  echo "FAIL nested-node-modules (cp -al 残留未清理即回退)"
  exit 1
fi

# 2) 回退的 cp -a 必须真的把内容复制到正确位置
[ -f "$snap/node_modules/demo-pkg/index.js" ] \
  || { echo "FAIL fallback-copy-missing (expected $snap/node_modules/demo-pkg/index.js)"; exit 1; }

# 3) 不得残留 cp -al 的临时错误文件
if ls "$DSH_HOME/.rescue"/.cp-al-*.err >/dev/null 2>&1; then
  echo "FAIL cp-al-error-file-left-behind"
  exit 1
fi

echo 'ALL-PASS'
