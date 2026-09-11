#!/bin/sh
# ============================================================================
# ci-image-tags.sh — 计算镜像 tag 与锁定的 DSH 版本（由 .github/workflows/docker-image.yml 调用）
#
# 输入（env）：REF_TYPE=tag|branch、REF_NAME、REGISTRY、IMAGE_NAME
# 输出（stdout，GITHUB_OUTPUT 的 KEY=VALUE 格式）：tags= / dsh_version= / proj_version=
#
# 为什么单独成文件（P0-5）：这段解析原来内联在 workflow 的 run 里，无法单测，结果校验逻辑
# 形同虚设——旧的 "*"-dsh*" 判断会放过 tag "v0.3.7-dsh"，DSH_VERSION 解析为空后
# `npm install -g @deepseek-ai/dsh@` 会把空 tag 当 latest，产出"标着锁版、实为 latest"的
# 假锁版镜像（且镜像 label 为空）。现在它是可被 scripts/t/test-ci-image-tags.sh 覆盖的纯函数。
# ============================================================================
set -eu

REF_TYPE="${REF_TYPE:-}"
REF_NAME="${REF_NAME:-}"
REGISTRY="${REGISTRY:-ghcr.io}"
IMAGE_NAME="${IMAGE_NAME:-}"
[ -n "$IMAGE_NAME" ] || { echo "ci-image-tags: IMAGE_NAME is required" >&2; exit 2; }

# ghcr.io 要求镜像名全小写
IMAGE_LOWER=$(printf '%s' "$IMAGE_NAME" | tr '[:upper:]' '[:lower:]')

case "$REF_TYPE" in
  tag)
    TAG="$REF_NAME"
    # 严格形态：v<三段项目版本>-dsh<三段 dsh 版本>[-预发布]，字符集限定为 Docker tag 允许的
    # [A-Za-z0-9_.-]。只查 "-dsh 后跟数字" 是不够的，以下都能溜过去并造成假锁版 / 怪错：
    #   v0.3.7-dsh              -> 空版本，npm 静默装 latest
    #   v0.3.7-dsh0             -> npm 当 0.x 解析
    #   v0.3.7-dsh-note-dsh0.1.5 -> 切分出 "-note-dsh0.1.5"
    #   v0.1.0-dsh0.1.2-rc.1+build -> "+" 非法，buildx 报 invalid reference format
    if ! printf '%s' "$TAG" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+-dsh[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
      echo "ci-image-tags: tag 必须形如 v<X.Y.Z>-dsh<X.Y.Z>[-预发布]（如 v0.3.7-dsh0.1.5-rc.1）；实际收到 '$TAG'" >&2
      exit 1
    fi
    DSH_VERSION="${TAG#*-dsh}"
    PROJ_VERSION="${TAG%%-dsh*}"
    PROJ_VERSION="${PROJ_VERSION#v}"
    [ -n "$DSH_VERSION" ] || { echo "ci-image-tags: empty dsh version in '$TAG'" >&2; exit 1; }
    TAGS="${REGISTRY}/${IMAGE_LOWER}:${TAG},${REGISTRY}/${IMAGE_LOWER}:latest"
    ;;
  *)
    # 分支构建：只有 main 才占 :main，其他分支（含 workflow_dispatch 手动触发）打
    # :branch-<slug>，避免把任意分支的代码静默推到 :main。
    if [ "$REF_NAME" = "main" ]; then
      SUFFIX="main"
    else
      # Docker tag 只允许 [A-Za-z0-9_.-]：其余字符统一替换为 '-' 再压缩/去首尾，避免 buildx 直接
      # 报 "invalid reference format"。（注：feature/x 与 feature_x 清洗后同名，会互相覆盖 —— 分支
      # 镜像非发布产物，且发布 job 已由 concurrency 串行化，可接受。）
      slug=$(printf '%s' "$REF_NAME" | tr -c 'A-Za-z0-9_.-' '-' | sed -e 's/-{2,}/-/g' -e 's/^-//' -e 's/-$//')
      [ -n "$slug" ] || slug="unknown"
      SUFFIX="branch-$(printf '%s' "$slug" | cut -c1-80)"
    fi
    TAGS="${REGISTRY}/${IMAGE_LOWER}:${SUFFIX}"
    DSH_VERSION="latest"
    PROJ_VERSION=""
    ;;
esac

printf 'tags=%s\n' "$TAGS"
printf 'dsh_version=%s\n' "$DSH_VERSION"
printf 'proj_version=%s\n' "$PROJ_VERSION"
