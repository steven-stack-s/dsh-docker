# DSH Docker 插件救援模式 实施计划

> 面向 Agent 执行者：建议使用 superpower-subagent-driven-development 逐任务执行。步骤用复选框（- [ ]）跟踪。
>
> 环境限制：本仓库实现可在任意 shell 环境编写并用 sh -n 静态校验，但自动回退与救生舱的真实行为只能在用户部署 DSH 的 Docker 主机验证（执行环境无 docker）。凡涉容器内运行/重启的任务，末尾含「宿主机验收」命令段，必须在真实主机跑通。

**目标：** 插件更新/安装后 DSH web 启动失败时，自动回退到变更前 known-good 插件树；回退用尽时用干净 lifeboat profile 起可操作入口；用户数据（会话/记忆/配置/凭据）全程保留。

**架构：** 插件操作封装为 rescue（变更前用 cp -al 硬链快照 profiles/web 插件四件套到 $DSH_HOME/.rescue/，留 3 份）。entrypoint 由 exec dsh web 改为监督子进程并对 127.0.0.1:3081 做启动窗口探测：boot 失败且 live 插件树与最新快照不同 -> 回滚该快照并重启，预算内反复；耗尽转救生舱或交由 docker restart。救生舱 RESCUE=1 用独立 profiles/lifeboat（bundles = dsh-base + dsh-web-app，双锚点免 pnpm 安装）起干净 web。主程序轻量兜底 rescue dsh-reinstall。

**技术栈：** POSIX sh（容器 /bin/sh 为 dash，禁 bash 专有语法）；cp -al 硬链；node 探测脚本做健康检查；docker compose；DSH profile 机制。

**规格：** docs/zh-CN/06-救援模式-设计规范.md。执行者先通读该规范。

> ⚠️ **2026-09-07 已按远端 seed 架构重新对齐本计划。** 本仓库 main 已重置到远端最新 120237b（构建时预装 dsh/pnpm 到镜像 /opt/dsh-seed，首启从 seed 复制到卷 /opt/dsh，完成后 rm -rf seed；日常升级 = docker exec npm install 覆盖 /opt/dsh；新增 DSH_TRUSTED_HOSTS 白名单）。原先基于旧「联网 npm 安装」entrypoint 写的任务 3/5/6 已相应修订：救生舱与正常启动都要带 $TRUSTED_ARGS；主程序兜底语义改为「重开含 seed 的新容器或按 last-good 版本重装」；rescue 工具放镜像独立路径 /opt/dsh-rescue/（不受 /opt/dsh 卷遮蔽，也不随 seed 清理丢失）。

## 全局约束

- 快照根 = $DSH_HOME/.rescue/（容器内 /data/dsh/.rescue/），必须与 profiles/web 同文件系统（硬链前提）。
- 快照 = profiles/web 插件四件套：package.json、pnpm-lock.yaml、pnpm-workspace.yaml、node_modules/；用 cp -al 硬链。默认留 3 份轮转。
- 永不改动/回滚：profiles/web/cordis.patch.yml、.dsh-market/、.dsh-module-fallback/、$DSH_HOME/sessions|storages|settings.yaml|.credentials.yaml|auth/ 及记忆库。
- 所有 shell 必须 POSIX sh（dash）兼容，set -u，禁 bash 数组/[[ ]]/${x//} 等。
- 主程序 /opt/dsh 不做自动回退，仅轻量兜底。
- 每个脚本 #!/bin/sh + set -eu；RESCUE_AUTO=off 时才关闭自动回退。
- 命名小写+连字符；日志统一写 $RESCUE_DIR/log/rescue.log。

---

## 文件结构

本计划新建/修改的文件，单一职责：

- 新建 scripts/librescue.sh：rescue 与 entrypoint 共享的 POSIX sh 函数库（快照/回滚/日志/指纹/状态）。
- 新建 scripts/probe-ready.js：node 小程序，探测 127.0.0.1:PORT 是否监听（entrypoint 用）。
- 新建 rescue（仓库根，POSIX sh）：rescue 命令集入口（snapshot/plugin/rollback/dsh-upgrade/dsh-reinstall/status/doctor/lifeboat）。
- 新建 profiles/lifeboat.tmpl/package.json 与 cordis.patch.yml：救生舱干净 profile 模板。
- 修改 entrypoint.sh：监督 dsh 子进程 + 启动窗口探测 + 自动回滚 + 救生舱分支。
- 修改 Dockerfile：拷入工具/模板到镜像（/opt/dsh-rescue/）并 chmod +x / 入 PATH。
- 修改 docker-compose.yml + .env.example：透传 RESCUE_* 配置。
- 文档：docs/zh-CN/06-救援模式.md、docs/en/06-rescue-mode.md，更新 03/04/README。

---
## 任务 1：librescue.sh —— 快照/回滚/日志/指纹函数库

**文件**
- 新建 scripts/librescue.sh
- 测试 scripts/t/test-librescue.sh（用临时目录构造假 profile 跑 sh）

**接口**
- 依赖输入：shell 环境 + env DSH_HOME、RESCUE_PROFILE（默认 web）。
- 对外产出（任务 2/3/4/6 source 本文件使用）：rescue_dir、profile_dir、rescue_log、next_snap_name、rescue_snapshot、rescue_prune、rescue_snapshot_list、rescue_fingerprint、rescue_live_differs_from、rescue_restore、rescue_record_dsh_version、rescue_init_lifeboat。

- [ ] **步骤 1：写 scripts/librescue.sh**（POSIX sh，dash 兼容）

```sh
#!/bin/sh
# 共享函数库：rescue 命令与 entrypoint source 本文件。POSIX sh（dash）兼容。
set -u

: "${DSH_HOME:?DSH_HOME must be set}"
RESCUE_PROFILE="${RESCUE_PROFILE:-web}"
RESCUE_DIR="$DSH_HOME/.rescue"
RESCUE_KEEP="${RESCUE_KEEP:-3}"
LOG_DIR="$RESCUE_DIR/log"
LOG_FILE="$LOG_DIR/rescue.log"

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
  { echo '{'; echo "  \"created\": \"$(date -Iseconds)\","; echo "  \"dsh\": \"$(dsh --version 2>/dev/null || echo unknown)\""; echo '}'; } > "$RESCUE_DIR/$snap/meta.json"
  rescue_log "snapshot created $snap"
  rescue_prune
  printf '%s' "$snap"
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
```

- [ ] **步骤 2：静态校验** `sh -n scripts/librescue.sh`（预期无输出、exit 0）；如装有 shellcheck 跑 `shellcheck -s sh scripts/librescue.sh` 清零 error。
- [ ] **步骤 3：写测试 scripts/t/test-librescue.sh**

```sh
#!/bin/sh
set -eu
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME/profiles/web/node_modules/demo-pkg"
printf '%s' '{"name":"web","dependencies":{"demo":"1.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
printf 'lock v1\n' > "$DSH_HOME/profiles/web/pnpm-lock.yaml"
echo hi > "$DSH_HOME/profiles/web/node_modules/demo-pkg/index.js"
. "$(dirname "$0")/../librescue.sh"

s1=$(rescue_snapshot)
[ "$s1" = "snap-0001" ] || { echo FAIL-snapname; exit 1; }
[ -d "$DSH_HOME/.rescue/snap-0001/node_modules/demo-pkg" ] || { echo FAIL-tree; exit 1; }
i1=$(stat -c%i "$DSH_HOME/profiles/web/node_modules/demo-pkg/index.js")
i2=$(stat -c%i "$DSH_HOME/.rescue/snap-0001/node_modules/demo-pkg/index.js")
[ "$i1" = "$i2" ] || { echo FAIL-hardlink; exit 1; }

printf '%s' '{"name":"web","dependencies":{"demo":"2.0.0"}}' > "$DSH_HOME/profiles/web/package.json"
[ "$(rescue_live_differs_from snap-0001)" = 1 ] || { echo FAIL-differs; exit 1; }
rescue_restore snap-0001
[ "$(rescue_live_differs_from snap-0001)" = 0 ] || { echo FAIL-restore; exit 1; }

export RESCUE_KEEP=1
s2=$(rescue_snapshot)
[ "$s2" = "snap-0002" ] || { echo FAIL-snap2; exit 1; }
[ ! -d "$DSH_HOME/.rescue/snap-0001" ] || { echo FAIL-prune; exit 1; }
echo ALL-PASS
```

- [ ] **步骤 4：运行** `sh scripts/t/test-librescue.sh`，预期输出 ALL-PASS。
- [ ] **步骤 5：提交** `git add scripts/librescue.sh scripts/t/test-librescue.sh && git commit -m "feat(rescue): librescue.sh 函数库 + 测试"`

---

## 任务 2：probe-ready.js —— 端口监听探测

**文件**：新建 scripts/probe-ready.js。
**接口**：`node scripts/probe-ready.js <port> [timeout_ms]`；窗口内端口可连则 exit 0，超时 exit 1。

- [ ] **步骤 1：写 scripts/probe-ready.js**

```js
// 探测 127.0.0.1:<port> 在 timeout 内是否开始监听。用于 dsh 启动窗口健康判定。
// 用法: node probe-ready.js <port> [timeoutMs]   默认 timeoutMs=120000
const net = require('node:net');
const port = Number(process.argv[2]);
const timeoutMs = Number(process.argv[3] || 120000);
if (!port) { console.error('usage: node probe-ready.js <port> [timeoutMs]'); process.exit(2); }
const deadline = Date.now() + timeoutMs;
function tryOnce() {
  const s = net.connect(port, '127.0.0.1');
  const onOk = () => { s.destroy(); process.exit(0); };
  const onFail = () => { s.destroy(); if (Date.now() >= deadline) process.exit(1); else setTimeout(tryOnce, 1000); };
  s.once('connect', onOk);
  s.once('error', onFail);
}
tryOnce();
```

- [ ] **步骤 2：静态校验** `node --check scripts/probe-ready.js`（无输出 exit 0）。可本机 `node scripts/probe-ready.js 1 200; echo $?` 验证超时路径 exit 1。
- [ ] **步骤 3：提交** `git add scripts/probe-ready.js && git commit -m "feat(rescue): 端口就绪探测脚本"`

---

## 任务 3：rescue 命令集入口

**文件**：新建 rescue；测试 scripts/t/test-rescue-cmds.sh（黑盒）。
**接口**：`rescue <sub>`，sub ∈ snapshot|plugin|rollback|dsh-upgrade|dsh-reinstall|status|doctor|lifeboat。均只操作 rescue/插件树，不动用户数据。

- [ ] **步骤 1：写 rescue**

```sh
#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/scripts/librescue.sh"
cmd="${1:-}"
[ -n "$cmd" ] || { echo 'usage: rescue <snapshot|plugin|rollback|dsh-upgrade|dsh-reinstall|status|doctor|lifeboat>'; exit 2; }
shift

case "$cmd" in
  snapshot) rescue_snapshot ;;
  status)
    echo "RESCUE_DIR=$RESCUE_DIR  KEEP=$RESCUE_KEEP  profile=$(profile_dir)"
    echo 'snapshots:'
    rescue_snapshot_list | sed 's#.*/\(snap-[0-9]*\)#  \1#'
    echo 'last log:'
    tail -n5 "$LOG_FILE" 2>/dev/null || true
    ;;
  doctor)
    pdir=$(profile_dir)
    [ -d "$pdir" ] && echo "ok profile dir: $pdir" || echo "MISSING profile dir: $pdir"
    [ -f "$pdir/package.json" ] && echo 'package.json present' || echo 'package.json MISSING'
    echo 'snapshots:'
    rescue_snapshot_list | sed 's#.*/\(snap-[0-9]*\)#  \1#'
    echo 'read-only diagnostic done'
    ;;
  plugin)
    [ "$#" -gt 0 ] || { echo 'usage: rescue plugin <pnpm args> e.g. add pkg'; exit 2; }
    rescue_snapshot >/dev/null 2>&1 || rescue_log 'plugin: snapshot skipped'
    dsh plugin --profile "$RESCUE_PROFILE" "$@"
    ;;
  rollback)
    list=$(rescue_snapshot_list)
    newest=$(echo "$list" | tail -n1 | xargs -r basename)
    [ -n "$newest" ] || { echo 'no snapshot to rollback to'; exit 1; }
    rescue_restore "$newest"
    echo "restored $newest; restart container: docker restart dsh"
    ;;
  dsh-upgrade)
    target="${1:-}"
    [ -n "$target" ] || { echo 'usage: rescue dsh-upgrade <版本>'; exit 2; }
    v=$(dsh --version 2>/dev/null || echo unknown)
    mkdir -p "$RESCUE_DIR"
    printf '%s\n' "$v" > "$RESCUE_DIR/dsh-version-last-good.txt"
    rescue_log "dsh-upgrade: record last-good $v, installing $target"
    if [ -n "${NPM_REGISTRY:-}" ]; then npm install -g "@deepseek-ai/dsh@$target" --registry="$NPM_REGISTRY"; else npm install -g "@deepseek-ai/dsh@$target"; fi
    echo 'upgraded; restart container: docker restart dsh'
    ;;
  dsh-reinstall)
    # 主程序 seed 已在首启 rm -rf，无法容器内重放镜像 seed；
    # 可靠恢复 = 按 last-good 版本容器内重装（覆盖 /opt/dsh）。
    # 若连 npm 源都不可达，则只能重建含 seed 的镜像容器（任务 6 文档说明）。
    vf="$RESCUE_DIR/dsh-version-last-good.txt"
    [ -f "$vf" ] || { echo "no recorded version: $vf"; exit 1; }
    v=$(cat "$vf")
    rescue_log "dsh-reinstall to $v"
    if [ -n "${NPM_REGISTRY:-}" ]; then npm install -g "@deepseek-ai/dsh@$v" --registry="$NPM_REGISTRY"; else npm install -g "@deepseek-ai/dsh@$v"; fi
    echo 'reinstalled; restart container: docker restart dsh'
    ;;
  lifeboat)
    echo 'set RESCUE=1 in .env then: docker compose up -d  (boots clean lifeboat)'
    ;;
  *) echo "unknown subcommand: $cmd"; exit 2 ;;
esac
```

> **seed 架构说明（2026-09-07）**：主程序 dsh 现在是「构建时锁进 /opt/dsh-seed -> 首启复制到卷 /opt/dsh -> rm -rf seed」。因此：
> 1. dsh-upgrade（容器内 npm 升级覆盖 /opt/dsh）**仍有效**，与官方每日升级方式一致。
> 2. dsh-reinstall 只能按 last-good 版本在容器内 npm 重装；**若想回到镜像自带 seed 版本**，需重建镜像容器（`docker compose up -d --build` 或 pull 固定 tag），因为 seed 已清理、卷 /opt/dsh 是持久化挂载不会被镜像覆盖。
> 3. dsh-version-last-good.txt 由 rescue dsh-upgrade 每次记录，rescue snapshot 的 meta.json 也记 dsh 版本，用于诊断回退时主程序是否被误改。

- [ ] **步骤 2：静态校验** `sh -n rescue`；`chmod +x rescue`。
- [ ] **步骤 3：写测试 scripts/t/test-rescue-cmds.sh**（复用任务 1 思路）：构造临时 home，`RESCUE` 入口以 `sh rescue` 调用，断言 `snapshot` 建出 snap-0001、篡改后 `rollback` 还原、`status` 输出含 RESCUE_DIR。
- [ ] **步骤 4：运行测试** `sh scripts/t/test-rescue-cmds.sh`。
- [ ] **步骤 5：提交** `git add rescue scripts/t/test-rescue-cmds.sh && git commit -m "feat(rescue): rescue 命令集"`

---

## 任务 4：救生舱 lifeboat profile 模板

**文件**：新建 profiles/lifeboat.tmpl/package.json、profiles/lifeboat.tmpl/cordis.patch.yml；librescue.sh 加初始化函数；改 Dockerfile 拷入。

**背景（源码依据）**：@deepseek-ai/dsh-app-boot 的 PROFILE_TEMPLATES.web.bundles = ["@deepseek-ai/dsh-base","@deepseek-ai/dsh-web-app"]，且 bundle 双锚点解析（先 dsh 安装、后 profile node_modules），核心 bundle 由 dsh 安装自带，故干净 lifeboat profile 无需独立 pnpm install 即可 boot。

- [ ] **步骤 1：写 profiles/lifeboat.tmpl/package.json**

```json
{
  "name": "dsh-profile-lifeboat",
  "private": true,
  "dependencies": {},
  "dsh": {
    "profile": {
      "bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"],
      "patchReload": "startup"
    }
  }
}
```

- [ ] **步骤 2：写 profiles/lifeboat.tmpl/cordis.patch.yml**：内容为单行 `[]`（与 DSH 生成的空 profile 根一致）。
- [ ] **步骤 3：librescue.sh 追加 rescue_init_lifeboat**：把模板拷入 $DSH_HOME/profiles/lifeboat/（仅当不存在）。

```sh
# LIFEBOAT_TMPL 由 Dockerfile 设定为 /opt/dsh-rescue/lifeboat.tmpl，本地开发默认走仓库内路径
LIFEBOAT_TMPL="${LIFEBOAT_TMPL:-$HERE/profiles/lifeboat.tmpl}"
rescue_init_lifeboat() {
  mkdir -p "$DSH_HOME/profiles/lifeboat"
  if [ ! -f "$DSH_HOME/profiles/lifeboat/package.json" ]; then
    cp "$LIFEBOAT_TMPL/package.json" "$DSH_HOME/profiles/lifeboat/package.json" 2>/dev/null || true
    cp "$LIFEBOAT_TMPL/cordis.patch.yml" "$DSH_HOME/profiles/lifeboat/cordis.patch.yml" 2>/dev/null || true
    rescue_log 'lifeboat profile initialized'
  fi
}
```

> 注意：$HERE 需在 librescue.sh 顶部定义（取本脚本所在目录）。容器内经镜像绝对路径 /opt/dsh-rescue/ 时由 Dockerfile 预置 LIFEBOAT_TMPL。

- [ ] **步骤 4：提交** `git add profiles/lifeboat.tmpl scripts/librescue.sh && git commit -m "feat(rescue): lifeboat 干净 profile 模板"`

---

## 任务 5：entrypoint 监督式启动 + 自动回滚 + 救生舱

**文件**：修改 entrypoint.sh（关键、风险最高）。
**接口**：保留现有全部行为（seed 复制/兜底装 dsh、pnpm、socat 转发、$TRUSTED_ARGS 白名单），只把最末行 `exec dsh web --port 3081 --no-open $TRUSTED_ARGS` 替换为「加载 rescue 库 -> 救生舱分支 -> 监督循环」。env：RESCUE=1（救生舱）、RESCUE_AUTO（默认 on）、RESCUE_START_TIMEOUT（默认 120）、RESCUE_KEEP、RESCUE_PROFILE（默认 web）。

> ⚠️ **seed 架构集成要点（2026-09-07）**：
> 1. **$TRUSTED_ARGS 必须带进两种 boot**（正常 web 与救生舱 lifeboat），否则 rescue 或 lifeboat 下 /api 403。故把 58-69 行算出的 TRUSTED_ARGS 作为监督循环与 boot_lifeboat 的公共参数。
> 2. rescue 工具在镜像 /opt/dsh-rescue/（与 /opt/dsh-seed 同属镜像层，不受卷遮蔽；seed 复制是拷到 /opt/dsh 卷，/opt/dsh-rescue 不在此卷内）。entrypoint 里 source /opt/dsh-rescue/librescue.sh，不依赖 /opt/dsh 是否就绪。
> 3. 监督循环只在「能对 live 插件树做硬链快照」即 $DSH_HOME/.rescue 就绪时启用自动回退；rescue 库缺失则降级为原 exec（见下方 no-op 降级）。

- [ ] **步骤 1：改写 entrypoint.sh**：把最末 `exec dsh web --port 3081 --no-open $TRUSTED_ARGS` 整行替换为下面整段（其余行 1-69 全部保留不动）

```sh
# ===================== 救援模式 =====================
# 加载共享库：优先 /opt/dsh-rescue（镜像内，独立于卷）。
# 缺失时降级为「无自动回退」：定义 no-op，保证老镜像/精简镜像仍能正常 exec 启动。
if [ -f /opt/dsh-rescue/librescue.sh ]; then
  . /opt/dsh-rescue/librescue.sh
else
  echo '[entrypoint] WARN librescue.sh not found; auto-rollback DISABLED'
  rescue_log() { :; }
  rescue_snapshot_list() { :; }
  rescue_live_differs_from() { echo 0; }
  rescue_restore() { :; }
  rescue_init_lifeboat() { :; }
fi

PORT_INNER=3081
RESCUE_START_TIMEOUT="${RESCUE_START_TIMEOUT:-120}"
RESCUE_AUTO="${RESCUE_AUTO:-on}"
RESCUE_PROFILE="${RESCUE_PROFILE:-web}"
RESCUE_KEEP="${RESCUE_KEEP:-3}"

boot_lifeboat() {
  echo '[entrypoint] RESCUE=1: booting clean lifeboat profile (no third-party plugins); data preserved'
  rescue_init_lifeboat
  exec dsh --profile lifeboat --port $PORT_INNER --no-open $TRUSTED_ARGS
}

if [ "${RESCUE:-0}" = "1" ]; then boot_lifeboat; fi

# 监督 + 自动回滚循环：把 dsh 作为子进程，启动窗口内探测 3081；
# 失败且 live 插件树 != 最新快照 -> 回滚并重启，最多 RESCUE_KEEP 次；耗尽退出交给 restart。
attempt=0
has_snap=0
[ -n "$(rescue_snapshot_list 2>/dev/null)" ] && has_snap=1
max_attempt=$((RESCUE_KEEP + 1))
while :; do
  attempt=$((attempt + 1))
  echo "[entrypoint] boot attempt $attempt/$max_attempt (profile=$RESCUE_PROFILE)"
  dsh web --profile "$RESCUE_PROFILE" --port $PORT_INNER --no-open $TRUSTED_ARGS &
  child=$!
  probe=/opt/dsh-rescue/probe-ready.js
  if node "$probe" "$PORT_INNER" "$((RESCUE_START_TIMEOUT * 1000))"; then
    echo "[entrypoint] dsh healthy on 127.0.0.1:$PORT_INNER"
    wait "$child"
    exit $?
  fi
  echo "[entrypoint] dsh not ready within ${RESCUE_START_TIMEOUT}s (attempt $attempt)"
  kill "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  if [ "$RESCUE_AUTO" = "on" ] && [ "$has_snap" = "1" ] && [ "$attempt" -lt "$max_attempt" ]; then
    newest=$(rescue_snapshot_list 2>/dev/null | tail -n1 | xargs -r basename)
    differs=0
    if [ -n "$newest" ]; then differs=$(rescue_live_differs_from "$newest" 2>/dev/null || echo 0); fi
    if [ -n "$newest" ] && [ "$differs" = "1" ]; then
      echo "[entrypoint] rolling back plugin tree to $newest"
      if rescue_restore "$newest"; then continue; fi
      echo '[entrypoint] rollback FAILED -> lifeboat'
      boot_lifeboat
    fi
  fi
  echo '[entrypoint] no rollback available/exhausted -> exit for docker restart policy'
  exit 1
done
```

> 注意：原 58-69 行的 TRUSTED_ARGS 计算必须**留在被替换行之前**（即仍处于这段代码上方作用域），本段通过 shell 变量捕获它。替换只删掉最末 `exec dsh web ... $TRUSTED_ARGS` 那一行，其上的 TRUSTED_ARGS 循环保留。

- [ ] **步骤 2：静态校验** `sh -n entrypoint.sh`；`shellcheck -s sh entrypoint.sh`（若有）清零 error；逐行核对无 bash 专有语法、$TRUSTED_ARGS 在两种 boot 均传入。
- [ ] **步骤 3：提交** `git add entrypoint.sh && git commit -m "feat(rescue): entrypoint 监督式启动 + 自动回滚 + 救生舱"`
---

## 任务 6：Dockerfile + compose + .env 接线

**文件**：Dockerfile、docker-compose.yml、.env.example。

- [ ] **步骤 1：Dockerfile** 拷入工具到镜像并入 PATH。插入位置：现 seed RUN（第 49-55 行）之后、COPY entrypoint.sh（第 66 行）之前任意处。`/opt/dsh-rescue` 是镜像层路径，**不**在 /opt/dsh 卷内、也不随首启 seed 清理丢失；因此本镜像必须重建（`docker compose up -d --build`）后 rescue 工具才生效——对已部署的旧容器，要获得自动回退能力需重建并 `docker compose up -d`（数据卷不变）：

```dockerfile
# 救援工具集（librescue + probe + 命令入口 + lifeboat 模板）
COPY scripts/librescue.sh scripts/probe-ready.js rescue profiles/lifeboat.tmpl /opt/dsh-rescue/
ENV LIFEBOAT_TMPL=/opt/dsh-rescue/lifeboat.tmpl
RUN chmod +x /opt/dsh-rescue/rescue /opt/dsh-rescue/probe-ready.js /opt/dsh-rescue/librescue.sh && ln -sf /opt/dsh-rescue/rescue /usr/local/bin/rescue
```

> 注意：rescue 的 HERE 指向 /opt/dsh-rescue，其内 librescue.sh 用 source /opt/dsh-rescue/librescue.sh（任务 3 步骤 1 代码需保证在镜像路径下能正确 source；本地开发以仓库根运行则 source $HERE/scripts/librescue.sh）。实现时对 rescue 做双路径兼容。
> 另：entrypoint 在 Dockerfile 里有 CRLF 清洗，rescue/librescue/probe-ready/lifeboat 模板同为仓库文本文件也可能带 Windows CRLF，故拷入 /opt/dsh-rescue 的脚本也要统一做一次行尾清洗再 chmod（与 entrypoint 的 sed 一致），避免 CR 混入 POSIX 脚本。
- [ ] **步骤 2：docker-compose.yml** 在 environment 的 DSH_TRUSTED_HOSTS（现第 49 行）之后追加（缩进与上对齐）：
```yaml
      - RESCUE=${RESCUE:-0}
      - RESCUE_AUTO=${RESCUE_AUTO:-on}
      - RESCUE_START_TIMEOUT=${RESCUE_START_TIMEOUT:-120}
      - RESCUE_KEEP=${RESCUE_KEEP:-3}
      - RESCUE_PROFILE=${RESCUE_PROFILE:-web}
```
- [ ] **步骤 3：.env.example** 在 DSH_TRUSTED_HOSTS 之后追加块：RESCUE=0；RESCUE_AUTO=on；RESCUE_START_TIMEOUT=120；RESCUE_KEEP=3；RESCUE_PROFILE=web。并注释：RESCUE=1 时 docker compose up -d 进救生舱 lifeboat，回到 0 恢复正常。
- [ ] **步骤 4：静态校验** 手动核对 YAML 缩进与变量名；无 docker 环境则跳过 `docker compose config`，改 `python3 -c "import yaml,sys;yaml.safe_load(open('docker-compose.yml'))"`（如有 pyyaml）或目检。
- [ ] **步骤 5：提交** `git add Dockerfile docker-compose.yml .env.example && git commit -m "feat(rescue): Dockerfile/compose/env 接线"`

---

## 任务 7：文档 + 宿主机端到端验收脚本

**文件**：docs/zh-CN/06-救援模式.md、docs/en/06-rescue-mode.md、scripts/t/e2e-rescue-on-host.sh、README/docs 索引更新。

- [ ] **步骤 1：写 docs/zh-CN/06-救援模式.md**（用户向，含：设计目标/如何启用/命令速查/自动回退机制/救生舱用法/关闭方法/备份提示）。命令示例：`docker exec dsh rescue status`、`docker exec dsh rescue snapshot`、`docker exec dsh rescue plugin add <包名>`、`docker exec dsh rescue rollback`、`docker exec dsh dsh-upgrade <版本>`、`docker exec dsh dsh-reinstall`。
- [ ] **步骤 2：写 docs/en/06-rescue-mode.md**（英文版）。
- [ ] **步骤 3：写宿主机验收脚本 scripts/t/e2e-rescue-on-host.sh**：

```sh
#!/bin/sh
set -eu
# 在用户真实部署主机运行：验证 rescue 全链路。会短暂重启 dsh 容器。
echo '== 1) status =='; docker exec dsh rescue status
echo '== 2) 手动快照当前良好态 =='; docker exec dsh rescue snapshot
echo '== 3) 人为把 web 依赖改坏（模拟坏插件） =='
docker exec dsh sh -c 'cd /data/dsh/profiles/web && cp package.json /tmp/pkg.bak && node -e "const fs=require(\"fs\");const p=JSON.parse(fs.readFileSync(\"package.json\"));p.dependencies[\"@deepseek-ai/dsh-web-app\"]=\"0.0.0-broken\";fs.writeFileSync(\"package.json\",JSON.stringify(p,null,2))"'
echo '== 4) 重启，观察 entrypoint 是否自动回滚并恢复 =='
docker restart dsh
sleep 25
docker logs dsh --tail 50 | grep -iE 'rollback|healthy|rescue' || echo '(未在日志找到回滚行，人工核对)'
echo '== 5) 恢复现场 =='
docker exec dsh sh -c 'cd /data/dsh/profiles/web && cp /tmp/pkg.bak package.json && rm -f /tmp/pkg.bak' 2>/dev/null || true
docker restart dsh 2>/dev/null || true
echo '== 结束：核对日志含 rollback-to + healthy 即通过 =='
```

- [ ] **步骤 4：文档索引** README 文档表、docs/zh-CN/03、04 增补 rescue 章节链接与故障排查入口。
- [ ] **步骤 5：提交** `git add -A && git commit -m "docs: 救援模式文档 + 端到端验收脚本"`

---

## 自检记录

- 规格覆盖核对：§4 快照(任务1/3)、§4.4 主程序兜底(rescue dsh-upgrade/dsh-reinstall，任务3)、§5 entrypoint 自动回退(任务5)、§6 救生舱(任务4+5)、§7 命令(任务3)、§8 日志(任务1 rescue_log)、§9 测试(任务1/3 单测 + 任务7 e2e)、§10 交付物(任务1-7)。均有着落。
- 类型一致：函数名 rescue_snapshot/rescue_restore/rescue_live_differs_from/rescue_init_lifeboat 等定义与调用处一致；probe-ready 参数一致；RESCUE_PROFILE/KEEP/START_TIMEOUT 变量在 compose/librescue/entrypoint 间一致。
- 占位符：所有代码块均可落盘；仅 entrypoint 保留段指向现文件既有行，先读再整体替换，属有依据引用。

## 风险与开放项

- cp -al 硬链在 node_modules 含特殊文件时已用 cp -a 兜底；硬链 inode 共享若被插件启动时原地改写会污染快照——DSH/cordis 以 unlink+create 部署通常安全，仍须任务 7 真实验收。
- entrypoint 由 exec 改子进程后，探测到 3081 即认为成功并 wait dsh；若 dsh 监听后又立即崩，wait 透传其退出码，容器退出由 restart 兜底（可接受，勿死循环）。
- 救生舱 `dsh --profile lifeboat` 需真实环境确认能绑定同一 $DSH_HOME 起干净 web；RESCUE=1 时单实例端口 3081 不冲突。
- 镜像内 HERE/LIFEBOAT_TMPL 双路径（仓库根 vs /opt/dsh-rescue）需任务 3/4/6 统一；entrypoint 有 librescue 缺失时的 no-op 降级，保证旧镜像也能跑。
- 镜像内不含 rescue 的旧镜像用户需重建镜像（docker compose up -d --build）才能获得本能力；数据卷无需迁移。
- **seed 架构风险（2026-09-07）**：/opt/dsh-seed 首启复制后即 rm -rf，容器内无法重放主程序 seed；主程序恢复只能容器内 npm 重装（需 npm 源可达）或重建含 seed 的新容器（数据卷保留）。自动回退与救生舱只动 profiles 插件树，不受此限。DSH_TRUSTED_HOSTS 为空时不追加 --trusted-host，两种 boot 行为与旧版一致。

---

执行交接见对话；默认按 superpower-subagent-driven-development 逐任务执行。