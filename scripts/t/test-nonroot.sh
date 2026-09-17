#!/bin/sh
# ============================================================================
# test-nonroot.sh — 容器安全加固：非 root 运行 + capability/只读硬化的静态门禁
#
# 验证对象（不改容器、不联网、可在纯 CI 环境跑）：
#   1) docker-compose.yml 必含非 root 相关硬化配置：
#        read_only:true / tmpfs /tmp / cap_drop:[ALL] / cap_add 白名单(CHOWN,DAC_OVERRIDE,SETUID,SETGID)
#        / USER_UID / USER_GID
#   2) entrypoint.sh 的"root 首启 → 降权"模型必在位：
#        root 块（id -u 判断）、seed 复制、chown 三个挂载卷(/opt/dsh,/data/dsh,/workspace)、
#        NPM_CONFIG_CACHE 兜底到可写卷、setpriv 降权、DSH_INIT_DONE 防重入
#   3) Dockerfile 必创建 dsh 用户(USER_UID/USER_GID 参数)且不直接 USER 降权
#
# 真实容器级的三条关键链路（seed 复制 / npm 升级 / rescue 快照+回滚在非 root 下可写）
# 由 e2e-container-selftest.sh（真 docker）覆盖；本脚本保证硬化配置不至于漂移。
#
# 需要：sh(dash)。无其他依赖。
# ============================================================================
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
COMPOSE="$ROOT/docker-compose.yml"
ENTRY="$ROOT/scripts/entrypoint.sh"
DFILE="$ROOT/Dockerfile"
fail() { echo "FAIL-$1"; exit 1; }
[ -f "$COMPOSE" ] || fail compose-missing
[ -f "$ENTRY" ]   || fail entrypoint-missing
[ -f "$DFILE" ]   || fail dockerfile-missing

# ---- 1) compose：capability/只读/非 root 硬化在位 ----
grep -q 'cap_drop' "$COMPOSE" || fail compose-missing-cap-drop
grep -q 'cap_add' "$COMPOSE"  || fail compose-missing-cap-add
grep -q '  - ALL' "$COMPOSE"  || fail compose-cap-drop-not-all
for c in CHOWN DAC_OVERRIDE SETUID SETGID; do
  grep -q "\- $c" "$COMPOSE" || fail "compose-cap-add-missing-$c"
done
grep -qE '^[[:space:]]*read_only:[[:space:]]*true' "$COMPOSE" || fail compose-not-read-only
grep -q 'tmpfs' "$COMPOSE" || fail compose-missing-tmpfs
grep -q '/tmp' "$COMPOSE"  || fail compose-missing-tmpfs-tmp
grep -q 'USER_UID' "$COMPOSE" || fail compose-missing-user-uid
grep -q 'USER_GID' "$COMPOSE" || fail compose-missing-user-gid
grep -q 'no-new-privileges' "$COMPOSE" || fail compose-missing-no-new-privileges

# ---- 2) entrypoint：root 首启 → 降权模型必在位 ----
grep -q 'setpriv' "$ENTRY" || fail entrypoint-missing-setpriv
grep -q 'DSH_INIT_DONE' "$ENTRY" || fail entrypoint-missing-init-done
grep -q '"$(id -u)" = 0' "$ENTRY" || fail entrypoint-missing-root-check
grep -q 'dsh-seed' "$ENTRY" || fail entrypoint-missing-seed
for v in /opt/dsh /data/dsh /workspace; do
  grep -qF "$v" "$ENTRY" || fail "entrypoint-missing-volume-$v"
done
grep -q 'NPM_CONFIG_CACHE' "$ENTRY" || fail entrypoint-missing-npm-cache
grep -q 'chown' "$ENTRY" || fail entrypoint-missing-chown
# read_only 下 web profile 必须固化为 patchReload=startup(关闭 HMR):
# web 是 dsh 唯一默认 patchReload:"live" 的 profile,其 HMR 依赖的 native addon
# (node-addon-require-builtin)在 read_only 根 FS 下无可用 binding,启动即抛
# "--expose-internals is required",dsh 崩溃且 rescue 无法自愈。startup 为官方合法值,
# 改配置后 docker restart 生效(生产加固语义)。acp/headless/sdk 本就默认 startup。
grep -q 'RESCUE_PROFILE' "$ENTRY" || fail entrypoint-missing-rescue-profile
grep -q '"patchReload": "startup"' "$ENTRY" || fail entrypoint-missing-profile-startup
grep -qE 's/"patchReload".*"live".*"startup"' "$ENTRY" || fail entrypoint-missing-profile-rewrite
# 属主可读性归一：chown 只改属主不改权限位，历史 0000 文件会让非 root 启动 EACCES
grep -q -- '-not -perm -u+r' "$ENTRY" || fail entrypoint-missing-perm-normalization
grep -q 'chmod u+rwX' "$ENTRY" || fail entrypoint-missing-perm-chmod
# 属主整备必须是"只改不符的条目"，不得退回对挂载卷全量 chown -R
# （28.8 万 inode 每次全量写；其它小目录的 chown -R 仍属正常，不做一刀切）
grep -q -- '-not -user' "$ENTRY" || fail entrypoint-missing-targeted-chown
if grep -qF 'chown -R "$RUN_USER_ID:$RUN_GROUP_ID" "$v"' "$ENTRY"; then
  fail entrypoint-regressed-to-recursive-volume-chown
fi
# 降权必须容忍"uid 在 /etc/passwd 中查不到"：setpriv --init-groups 会直接失败（rc=1），
# 在 set -e 下会让 PID1 退出 -> 重启死循环，且该块排在 lifeboat 之前（连救生舱都到不了）。
# 故必须先探测，失败则退化为不带附加组降权。
grep -q -- '--init-groups true' "$ENTRY" || fail entrypoint-missing-initgroups-probe
grep -q 'not resolvable in /etc/passwd' "$ENTRY" || fail entrypoint-missing-initgroups-fallback
# 运行用户的 HOME 必须可用：镜像不设 HOME -> Docker 给 root 的 /root(700 root)，降权到 uid 1000
# 后连读都不行，pnpm 读 $HOME/.config/pnpm/config.yaml 直接 EACCES（插件市场报错真因）。
# 镜像层兜底（entrypoint 自动改指）+ compose 显式指定，两条都必须在位。
grep -q 'run-user HOME' "$ENTRY" || fail entrypoint-missing-home-fix
grep -qE '^[[:space:]]*- HOME=' "$COMPOSE" || fail compose-missing-home

# ---- 3) Dockerfile：声明非 root 运行用户（复用镜像自带 node 用户 uid=1000），
#        且没有直接 `USER 1000` 收尾（应保留 root 启动，由 entrypoint 降权后再进运行流程）。
#        若 Dockerfile 改为直接 `USER 1000`，entrypoint 会失去 chown 挂载卷的能力，
#        seed 复制/属主整备将静默失效 —— 故设红灯。
grep -q 'USER_UID' "$DFILE" || fail dockerfile-missing-user-uid-arg
grep -q 'USER_GID' "$DFILE" || fail dockerfile-missing-user-gid-arg
grep -qiE '1000:1000|uid.?1000|node 用户' "$DFILE" || fail dockerfile-missing-run-user-comment
# 不得再声明 ARG USER_UID/USER_GID：它们曾是"声明了却从不被消费"的死参数，
# 却让 .env.example/docs 误以为"必须与构建参数一致"。运行用户只由运行时环境变量决定。
if grep -qE '^[[:space:]]*ARG[[:space:]]+USER_(UID|GID)' "$DFILE"; then
  fail dockerfile-declares-dead-user-arg
fi
if grep -qE '^[[:space:]]*USER[[:space:]]+[0-9]+' "$DFILE"; then
  # 镜像最终以 root 启动（无数字 USER），由 entrypoint setpriv 降权；禁止直接 `USER 1000`。
  fail dockerfile-direct-user
fi

echo 'ALL-PASS'