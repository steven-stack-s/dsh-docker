#!/bin/sh
# ============================================================================
# test-seed-upgrade.sh — 「镜像 seed 版本 > 卷内版本 → 覆盖 /opt/dsh」的门禁
#
# 背景：原先 entrypoint 只在 `command -v dsh` 失败时才复制 seed，于是**升级镜像并不会**
# 更新 /opt/dsh 卷里的 dsh（实测：换用更新 seed 的镜像重建后，dsh --version 依旧是旧版）。
# 现在改为按版本比较驱动：seed 严格更新就覆盖，相等或卷里更就绝不动（尊重用户容器内装的
# 更高版本）。比较用 scripts/vercmp.sh 的 ver_gt —— 与徽章脚本共用同一份实现，避免语义分叉。
#
# 版本比较属于**静默出错**的地带：比错了不报错，只会让 dsh 停在旧版，或把用户的升级倒回去。
# 故这里同时盯住三件事：比较逻辑在位、日志能看出最终版本、以及 source 顺序（先用后 source
# 会让 ver_gt 根本不存在 —— 本项目的 test-entrypoint-order.sh 就是为同类事故立的）。
# ============================================================================
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
EP="$ROOT/scripts/entrypoint.sh"
VC="$ROOT/scripts/vercmp.sh"
DFILE="$ROOT/Dockerfile"
fail() { echo "FAIL-$1"; exit 1; }

[ -f "$VC" ] || fail vercmp-missing
grep -q '^ver_gt()' "$VC" || fail vercmp-missing-ver_gt

# 1) entrypoint 必须 source vercmp.sh，且在**调用 ver_gt 之前**
src_line=$(grep -n 'vercmp\.sh' "$EP" | grep -v '^[0-9]*:[[:space:]]*#' | head -n1 | cut -d: -f1)
[ -n "$src_line" ] || fail entrypoint-does-not-source-vercmp
use_line=$(grep -n 'ver_gt "' "$EP" | grep -v '^[0-9]*:[[:space:]]*#' | head -n1 | cut -d: -f1)
[ -n "$use_line" ] || fail entrypoint-never-calls-ver_gt
[ "$src_line" -lt "$use_line" ] || fail entrypoint-sources-vercmp-after-use

# 2) 三要素：seed 版本、卷内版本、最终生效版本
grep -q '_seed_ver=' "$EP" || fail entrypoint-missing-seed-version-read
grep -q '_vol_ver=' "$EP" || fail entrypoint-missing-volume-version-read
grep -q 'effective=' "$EP" || fail entrypoint-missing-effective-version-log
# 版本必须从 package.json 读（不依赖把 dsh 跑起来）
grep -q 'node_modules/@deepseek-ai/dsh/package.json' "$EP" || fail entrypoint-not-reading-package.json

# 3) 缺失 vercmp.sh 时必须能降级而不是崩（不能因为库不在就中断启动）
grep -q 'command -v ver_gt >/dev/null 2>&1 || elog' "$EP" || fail entrypoint-missing-vercmp-fallback

# 4) 镜像必须携带 vercmp.sh（COPY + CRLF 归一）
# 不假设 vercmp.sh 是 COPY 行的最后一个文件（同一行以后还会加资产）。
grep -qE '^COPY .*scripts/vercmp\.sh .*/opt/dsh-rescue/' "$DFILE" || fail dockerfile-missing-vercmp-copy
grep -q '/opt/dsh-rescue/vercmp.sh' "$DFILE" || fail dockerfile-missing-vercmp-crlf-fix

echo 'ALL-PASS'