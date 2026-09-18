#!/bin/sh
# ============================================================================
# update-dsh-badge.sh — 把 README 里的「DeepSeek Harness 版本」徽章同步到指定版本
#
# 为什么需要它：该徽章是 shields **静态**徽章（badge/DeepSeek%20Harness-<版本>-4aa3ff），
# 没有任何上游数据源，不主动改写就会永远停在发版时写下的那一个版本上
# （对照：control-center 的 README 至今写着 0.1.5-alpha.1）。由
# .github/workflows/docker-image.yml 在 tag 构建成功后调用，因此发版即自动同步。
#
# 用法:
#   sh scripts/update-dsh-badge.sh <dsh-version> [--force] [--dry-run] [file...]
#
#   <dsh-version>  形如 0.1.5-rc.1，与 ci-image-tags.sh 从 tag 后缀解析出的形态一致
#   --force        允许把徽章改成比现值更低的版本（默认拒绝）
#   --dry-run      只报告将要做什么，不写文件
#   [file...]      要处理的文件，默认 README.md README.zh-CN.md
#
# 行为约定:
#   * 幂等：目标与现值相同时不改写、退出 0 —— 让 CI 可以无条件调用而不产生空提交
#   * 只升不降：目标低于现值时拒绝并退出 1（除非 --force）。补发历史 tag 时若照改，
#     会把 README 徽章改回旧版本，故必须挡住
#   * 找不到徽章锚点时**报错退出**，绝不静默跳过：静默跳过 = 徽章永远不更新且无人察觉
#
# 退出码: 0=已最新或改写成功 / 1=参数或内容错误 / 2=用法错误
# ============================================================================
set -eu

usage() {
  cat <<'EOF'
用法: sh scripts/update-dsh-badge.sh <dsh-version> [--force] [--dry-run] [file...]
  <dsh-version>  DSH 版本，形如 0.1.5-rc.1
  --force        允许降级改写（默认拒绝）
  --dry-run      只报告将要做什么，不写文件
  [file...]      默认 README.md README.zh-CN.md
EOF
}

VERSION=''
FORCE=0
DRY=0
FILES=''

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'update-dsh-badge: 未知选项 %s\n' "$1" >&2; exit 2 ;;
    *)
      if [ -z "$VERSION" ]; then VERSION="$1"; else FILES="$FILES $1"; fi
      ;;
  esac
  shift
done

if [ -z "$VERSION" ]; then usage >&2; exit 2; fi
[ -n "$FILES" ] || FILES=' README.md README.zh-CN.md'

# 版本形态与 ci-image-tags.sh 对 tag 后缀的要求保持一致：X.Y.Z 或 X.Y.Z-预发布
if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; then
  printf 'update-dsh-badge: 版本必须形如 X.Y.Z 或 X.Y.Z-预发布（如 0.1.5-rc.1）；实际收到 %s\n' "$VERSION" >&2
  exit 1
fi

# shields 静态徽章的 URL 里 "-" 是 label/message/color 的分隔符，字面连字符须写成 "--"，
# 否则 0.1.5-rc.1 会被切成 "0.1.5" + 颜色 "rc.1"，徽章渲染成畸形。
escape_shields()   { printf '%s' "$1" | sed 's/-/--/g'; }
unescape_shields() { printf '%s' "$1" | sed 's/--/-/g'; }

# 版本比较由 scripts/vercmp.sh 提供 —— entrypoint 也用**同一份**实现（它决定镜像 seed 是否
# 覆盖 /opt/dsh 卷里的 dsh）。两处语义一旦分叉，就会出现「徽章算升级、seed 算降级」这种
# 很难查的不一致，故本文件不再保留副本。
. "$(dirname -- "$0")/vercmp.sh"
command -v ver_gt >/dev/null 2>&1 || { echo 'update-dsh-badge: vercmp.sh missing (should sit next to this script)'; exit 2; }

changed=0
unchanged=0

for f in $FILES; do
  if [ ! -f "$f" ]; then
    printf 'update-dsh-badge: 文件不存在：%s\n' "$f" >&2
    exit 1
  fi

  # 锚点：徽章图片 URL 形如 https://img.shields.io/badge/DeepSeek%20Harness-<版本>-4aa3ff
  # [^)]* 允许版本里带 "-"；行内只有一个 "-4aa3ff"，贪婪匹配会正确回溯到此。
  _cur_esc=$(sed -n 's|.*img\.shields\.io/badge/DeepSeek%20Harness-\([^)]*\)-4aa3ff.*|\1|p' "$f" | head -n 1)
  if [ -z "$_cur_esc" ]; then
    printf 'update-dsh-badge: 在 %s 中找不到 DSH 版本徽章锚点（期望含 img.shields.io/badge/DeepSeek%%20Harness-<版本>-4aa3ff）\n' "$f" >&2
    exit 1
  fi

  _cur=$(unescape_shields "$_cur_esc")

  if [ "$_cur" = "$VERSION" ]; then
    printf 'unchanged: %s (已是 %s)\n' "$f" "$VERSION"
    unchanged=$((unchanged + 1))
    continue
  fi

  if ver_gt "$_cur" "$VERSION" && [ "$FORCE" -ne 1 ]; then
    printf 'update-dsh-badge: %s 现有版本 %s 高于目标 %s，拒绝回退（确需降级请加 --force）\n' "$f" "$_cur" "$VERSION" >&2
    exit 1
  fi

  _new_esc=$(escape_shields "$VERSION")

  if [ "$DRY" -eq 1 ]; then
    printf 'would-update: %s (%s -> %s)\n' "$f" "$_cur" "$VERSION"
    changed=$((changed + 1))
    continue
  fi

  _tmp="$f.upd.$$"
  sed "s|\(img\.shields\.io/badge/DeepSeek%20Harness-\)[^)]*\(-4aa3ff\)|\1${_new_esc}\2|" "$f" > "$_tmp"
  if [ ! -s "$_tmp" ]; then
    rm -f "$_tmp"
    printf 'update-dsh-badge: 改写 %s 时产生空结果，已放弃\n' "$f" >&2
    exit 1
  fi
  # 用 cat 覆盖而非 mv：保留原文件的权限与 inode
  cat "$_tmp" > "$f"
  rm -f "$_tmp"
  printf 'updated: %s (%s -> %s)\n' "$f" "$_cur" "$VERSION"
  changed=$((changed + 1))
done

printf 'update-dsh-badge: 改写 %d 个文件，%d 个已是最新\n' "$changed" "$unchanged"
