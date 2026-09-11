#!/bin/sh
# ============================================================================
# test-ci-image-tags.sh — CI 镜像 tag 解析（.github/workflows/docker-image.yml 调用 ci-image-tags.sh）
#
# 覆盖：
#   Tag1 合法双版本 tag          -> 打 <tag> + :latest，dsh_version 取自后缀
#   Tag2 \"v0.3.7-dsh\"（缺 dsh 版本）-> 必须拒绝：空版本会让 npm 静默装 latest（假锁版镜像）
#   Tag3 \"v0.3.7-dshx\"（非数字）    -> 必须拒绝
#   Tag4 项目版本 + 预发布 dsh 版本 -> 正确切分（dsh 版本含 -rc.N）
#   Br1 分支 main                -> 只打 :main（占位 latest 语义不变）
#   Br2 其他分支                 -> 打 :branch-<slug>，绝不污染 :main
#
# 用法: sh scripts/t/test-ci-image-tags.sh    （全通过打印 ALL-PASS）
# ============================================================================
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$HERE/../ci-image-tags.sh"
[ -f "$SCRIPT" ] || { echo "FAIL-script-missing: $SCRIPT"; exit 1; }

run_case() { # $1=ref_type $2=ref_name
  REF_TYPE="$1" REF_NAME="$2" REGISTRY=ghcr.io IMAGE_NAME=Steven-Stack-S/dsh-docker sh "$SCRIPT"
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# ---- Tag1 ----
out=$(run_case tag v0.3.7-dsh0.1.5-rc.1); rc=$?
[ "$rc" = 0 ] || { echo "FAIL-tag1-rc=$rc"; exit 1; }
[ "$(field "$out" dsh_version)" = "0.1.5-rc.1" ] || { echo "FAIL-tag1-dsh-version: $out"; exit 1; }
[ "$(field "$out" proj_version)" = "0.3.7" ] || { echo "FAIL-tag1-proj-version: $out"; exit 1; }
case "$(field "$out" tags)" in
  *:v0.3.7-dsh0.1.5-rc.1,*:latest) : ;;
  *) echo "FAIL-tag1-tags: $out"; exit 1 ;;
esac

# ---- Tag2：空 dsh 版本必须拒绝（否则 npm 装 latest = 假锁版镜像）----
if run_case tag v0.3.7-dsh >/dev/null 2>&1; then echo 'FAIL-tag2-empty-dsh-version-accepted'; exit 1; fi
# ---- Tag3：非数字 dsh 版本必须拒绝 ----
if run_case tag v0.3.7-dshx >/dev/null 2>&1; then echo 'FAIL-tag3-nonnumeric-dsh-version-accepted'; exit 1; fi
# ---- Tag4 ----
out=$(run_case tag v1.0.0-dsh0.2.0) || { echo 'FAIL-tag4-rc'; exit 1; }
[ "$(field "$out" dsh_version)" = "0.2.0" ] || { echo "FAIL-tag4-dsh: $out"; exit 1; }
[ "$(field "$out" proj_version)" = "1.0.0" ] || { echo "FAIL-tag4-proj: $out"; exit 1; }

# ---- Br1 ----
out=$(run_case branch main) || { echo 'FAIL-br1-rc'; exit 1; }
[ "$(field "$out" tags)" = "ghcr.io/steven-stack-s/dsh-docker:main" ] || { echo "FAIL-br1-tags: $out"; exit 1; }
[ "$(field "$out" dsh_version)" = "latest" ] || { echo "FAIL-br1-dsh: $out"; exit 1; }

# ---- Br2：其他分支不得占用 :main ----
out=$(run_case branch feature/x) || { echo 'FAIL-br2-rc'; exit 1; }
[ "$(field "$out" tags)" = "ghcr.io/steven-stack-s/dsh-docker:branch-feature-x" ] || { echo "FAIL-br2-tags: $out"; exit 1; }

# ---- Tag5：dsh 版本必须是三段式（"v0.3.7-dsh0" 会被 npm 当 0.x 解析）----
if run_case tag v0.3.7-dsh0 >/dev/null 2>&1; then echo 'FAIL-tag5-non-semver-dsh-version-accepted'; exit 1; fi
# ---- Tag6：dsh 版本形态必须紧贴 "-dsh"（旧切分对 v0.3.7-dsh-note-dsh0.1.5 会得到 "-note-dsh0.1.5"）----
if run_case tag v0.3.7-dsh-note-dsh0.1.5 >/dev/null 2>&1; then echo 'FAIL-tag6-malformed-tag-accepted'; exit 1; fi
# ---- Tag7：Docker tag 不允许 "+"（build metadata），必须在发布前拒绝而不是让 buildx 报怪错 ----
if run_case tag v0.1.0-dsh0.1.2-rc.1+build >/dev/null 2>&1; then echo 'FAIL-tag7-build-metadata-accepted'; exit 1; fi
# ---- Tag8：无预发布后缀的 dsh 版本必须接受 ----
out=$(run_case tag v0.3.7-dsh0.1.5) || { echo 'FAIL-tag8-rc'; exit 1; }
[ "$(field "$out" dsh_version)" = "0.1.5" ] || { echo "FAIL-tag8-dsh: $out"; exit 1; }
# ---- Br3：分支名里的非法字符必须清洗成合法 Docker tag 字符 ----
out=$(run_case branch 'weird+branch') || { echo 'FAIL-br3-rc'; exit 1; }
[ "$(field "$out" tags)" = "ghcr.io/steven-stack-s/dsh-docker:branch-weird-branch" ] || { echo "FAIL-br3-tags: $out"; exit 1; }

echo ALL-PASS
