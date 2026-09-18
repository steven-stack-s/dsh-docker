#!/bin/sh
# ============================================================================
# test-hmr-off.sh — 容器内关闭 profile HMR 的静态门禁（read_only 生产加固）
#
# 【为什么单独有这个测试】2026-09-18 升级 DSH 0.1.6-alpha.2 时暴露的一次"保护静默失效"：
#   旧做法是让 entrypoint 把 web profile manifest 的 \`patchReload\` 从 "live" 改写成 "startup"
#   来关闭 HMR。alpha.2 **删除了 patchReload 字段**（dsh-app-boot 源码里已无任何引用，实测
#   新建 profile 也不再写入它），于是那次 sed 变成了没人读取的死写入，web 的 HMR 实际转为
#   **默认开启** —— 而旧门禁只 grep entrypoint 里那行文本，**照样全绿**。
#   教训：门禁不能盯"某行实现文本"，要盯"保障本身"。故本测试断言的是：
#     a) 每条启动路径都真的注入了关闭 HMR 的 --patch（漏一处 = 那条路径下 HMR 仍开着）
#     b) 镜像真的携带该叠加层（COPY + CRLF 归一，漏了就静默退化成"没关"）
#     c) 叠加层内容真的禁用了 hmr 条目
#     d) 反向：不得再退回已被 alpha.2 删除的 patchReload 机制
#
# 真实容器级验证（read_only 下 dsh 真的能起来）由 e2e-container-selftest.sh（真 docker）覆盖；
# 本脚本保证这套机制不至于再次漂移。需要：sh(dash)。无其他依赖。
# ============================================================================
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ENTRY="$ROOT/scripts/entrypoint.sh"
SUP="$ROOT/scripts/rescue-supervise.sh"
DFILE="$ROOT/Dockerfile"
YML="$ROOT/scripts/hmr-off.yml"
LIFEBOAT="$ROOT/scripts/lifeboat.tmpl/package.json"
fail() { echo "FAIL-$1"; exit 1; }

for f in "$ENTRY" "$SUP" "$DFILE" "$YML" "$LIFEBOAT"; do
  [ -f "$f" ] || fail "missing-file-$(basename "$f")"
done

# ---- 1) 叠加层：必须真的禁用 hmr 条目 ----
grep -qE '^-[[:space:]]+id:[[:space:]]*hmr[[:space:]]*$' "$YML" || fail hmr-off-missing-hmr-id
# disabled: true 必须出现在 id: hmr 之后（同一 YAML 条目内），而不是文件里任意一处
awk '/^-[[:space:]]+id:[[:space:]]*hmr[[:space:]]*$/{f=1;next} f&&/^-[[:space:]]/{f=0} f&&/disabled:[[:space:]]*true/{found=1} END{exit !found}' "$YML" \
  || fail hmr-off-does-not-disable

# ---- 2) 镜像必须携带 hmr-off.yml（COPY 进 /opt/dsh-rescue，并做 CRLF 归一）----
grep -q 'scripts/hmr-off.yml[[:space:]]*/opt/dsh-rescue/' "$DFILE" || fail dockerfile-missing-hmr-off-copy
grep -q '/opt/dsh-rescue/hmr-off.yml' "$DFILE" || fail dockerfile-missing-hmr-off-crlf-fix

# ---- 3) entrypoint 必须解析叠加层路径（镜像内优先，仓库布局兜底）----
grep -q '/opt/dsh-rescue/hmr-off.yml' "$ENTRY" || fail entrypoint-missing-hmr-off-path
grep -q 'HMR_OFF_YML=' "$ENTRY" || fail entrypoint-missing-hmr-off-var
grep -q 'HMR_OFF_PATCH=' "$ENTRY" || fail entrypoint-missing-hmr-off-args
# set -e 陷阱：hmr_off_args 在"不注入"分支若不显式 return 0，命令替换的非零退出码会让 PID1 退出
grep -q 'return 0' "$ENTRY" || fail entrypoint-hmr-off-args-missing-return-0

# ---- 4) 每一条 dsh 启动路径都必须注入 --patch（漏一处即红灯）----
# 统计而非逐条断言：将来新增启动路径若忘记注入，这里会自动发现。
for pair in "entrypoint:$ENTRY" "supervise:$SUP"; do
  name=${pair%%:*}; file=${pair#*:}
  total=$(grep -c 'dsh --profile' "$file" || true)
  with=$(grep -c 'dsh --profile.*HMR_OFF_PATCH' "$file" || true)
  [ "$total" -gt 0 ] || fail "$name-no-dsh-launch-found"
  [ "$total" = "$with" ] || fail "$name-launch-without-hmr-off($with/$total)"
done

# ---- 5) 反向：不得再依赖 alpha.2 已删除的 patchReload 机制 ----
# （存量 profile 里遗留该字段无影响；但 entrypoint/lifeboat 模板不得再靠它关 HMR）
if grep -q 'patchReload' "$ENTRY"; then
  # 允许出现在解释性注释里，但不允许出现在可执行语句/写入的 JSON 模板里
  grep -qE '^[^#]*patchReload' "$ENTRY" && fail entrypoint-relies-on-removed-patchreload
fi
grep -q 'patchReload' "$LIFEBOAT" && fail lifeboat-template-carries-removed-patchreload
# 旧的 sed 改写必须彻底消失（它是"绿着但已失效"的根源）
grep -qE "s/\"patchReload\"" "$ENTRY" && fail entrypoint-still-rewrites-patchreload

echo 'ALL-PASS'
