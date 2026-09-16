# rescue clean 升级后环境清理 实施计划

> **面向 Agent 执行者：** 必需子技能：使用 superpower-subagent-driven-development（推荐）或 superpower-executing-plans 按任务逐项执行本计划。步骤使用复选框（`- [ ]`）语法进行跟踪。

**目标：** 为 dsh-docker 新增 `rescue clean` 子命令，清理升级后累积的 npm 缓存、pnpm 孤儿条目与超限救援历史，且绝不破坏 rescue 的回滚基线。

**架构：** 纯函数下沉到 `scripts/librescue.sh`（可被单测直接 source，无需 docker），`scripts/rescue` 只做参数解析与分发。清理前自动拍快照作为护栏，默认 dry-run，真实清理需显式 `--yes`。孤儿判定以 `pnpm-lock.yaml` 的 `packages:` 段引用集为准。

**技术栈：** POSIX sh（dash 兼容）、pnpm 11.x、npm 11.x、Node.js（仅测试中用于造夹具）

**规格：** `docs/superpowers/specs/2026-09-15-rescue-clean-design.md`

## 全局约束

- 语言与兼容性：所有 shell 代码必须 **POSIX sh（dash）兼容**；librescue.sh **不得**设置 `set -u` / `set -e`；所有变量引用一律用 `${VAR:-default}` 形式。
- 审计日志：所有实质性动作必须经 `rescue_log` 记录。
- 失败不得终止调用方：librescue 中的函数在出错时应返回非 0，但不得 `exit`。唯一例外是 `scripts/rescue` 的命令分发层。
- 版本语义：本文档中 pnpm 虚拟存储目录名格式为 `<name-with-+-for-/>@<version>[_<peerSuffix>]`，lockfile `packages:` 段键格式为 `'<name>@<version>'`（含 peer 括号后缀时形如 `<name>@<version>(<peer>)`）。
- 红线（规格 §4.1）：绝不删除 `package.json`、`pnpm-lock.yaml`、`pnpm-workspace.yaml`、被 lockfile 引用的 `.pnpm` 条目、profile 的 `node_modules` 整树、`/opt/dsh-seed`、任何 `snap-*` 快照目录、会话 / 记忆 / 配置 / 凭据。
- 与自愈预算解耦（规格 §5.2）：`rescue clean` 不得读写 `SELFHEAL_REMOVES` / `SELFHEAL_ROLLBACKS`，不得调用 `rescue_budget_write`。
- 默认只读：不带 `--yes` 时不得产生任何文件系统改动。
- 测试门禁：新增测试须置于 `scripts/t/`，命名为 `test-*.sh`，输出结尾必须打印 `ALL-PASS`（沿用既有约定）。
- 提交信息语言：中文，遵循既有 `type(scope): 描述` 格式。

---

### 任务 1：pnpm 虚拟存储目录名解析与孤儿判定

**文件：**
- 修改：`scripts/librescue.sh`（在文件末尾追加，即 `rescue_state_read_selfheal` 之后）
- 测试：`scripts/t/test-rescue-clean.sh`（新建）

**接口：**
- 依赖输入：无（本任务为纯函数起点）
- 对外产出：
  - `rescue_pnpm_dir_to_key <dirName>` → 打印 `<name>@<version>`；无法解析时返回 1 且不打印
  - `rescue_pnpm_locked_keys <lockfile>` → 每行一个 `<name>@<version>`，打印 lockfile `packages:` 段的键（已剥离 peer 括号后缀）
  - `rescue_pnpm_is_orphan <dirName> <lockfile>` → 孤儿返回 0，被引用返回 1

**背景（实测得出，务必遵守）：** 目录名形如 `@wenaixi+dsh-superpower@6.3.1_@deepseek-ai+cordis@4.0.2_ea847881`。解析必须**先按首个 `_` 切掉 peer 后缀**，再在剩余部分定位 name/version 边界。

两个已验证的错误做法，**不要重犯**：
1. **`lastIndexOf("@")`** —— peer 后缀里含 `@`，会误判版本号（实测把在用的 `6.3.1` 误判为孤儿，进而删掉活依赖）。
2. **`${core#@*+}` 这类贪婪 glob 去 scope** —— 实测会把 `@deepseek-ai+dsh-attachment@0.0.1-rc.1` 解析成 `pkg` 为空、`ver` 为 `deepseek-ai/dsh-attachment@0.0.1-rc.1`。

正确做法（下方实现）：切掉 peer 后缀后，剩余 core 内 `@` 至多出现一次，故用 `${core%@*}` / `${core##*@}` 切分并**用「还原校验」确认**，最后校验 version 以数字开头。

- [ ] **步骤 1：编写失败的测试**

创建 `scripts/t/test-rescue-clean.sh`：

```sh
#!/bin/sh
# 黑盒测试：rescue clean 的孤儿判定与清理行为。
# 重点守护两条红线：① 被 lockfile 引用的条目绝不删 ② package.json/lockfile 字节级不变。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB="$ROOT/scripts/librescue.sh"
[ -f "$LIB" ] || { echo "FAIL librescue missing"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME/profiles/web"
# profile 基线文件：任务 3/4 的红线用例要对它们做字节级比对，故此处先建立。
printf '%s' '{"name":"web","dependencies":{"@wenaixi/dsh-superpower":"6.3.0-dsh.10"}}' > "$DSH_HOME/profiles/web/package.json"
RESCUE_PROFILE=web
. "$LIB"

fail() { echo "FAIL-$1"; exit 1; }

# --- 1) 目录名解析：scope 包 + peer 后缀 ---
k=$(rescue_pnpm_dir_to_key '@wenaixi+dsh-superpower@6.3.1_@deepseek-ai+cordis@4.0.2_ea847881') \
  || fail parse-scoped-with-peer
[ "$k" = '@wenaixi/dsh-superpower@6.3.1' ] || fail "parse-scoped-with-peer:$k"

k=$(rescue_pnpm_dir_to_key '@deepseek-ai+cordis@4.0.2') || fail parse-scoped-nopeer
[ "$k" = '@deepseek-ai/cordis@4.0.2' ] || fail "parse-scoped-nopeer:$k"

k=$(rescue_pnpm_dir_to_key 'yaml@2.9.1') || fail parse-plain
[ "$k" = 'yaml@2.9.1' ] || fail "parse-plain:$k"

# 非包目录必须被拒绝（pnpm 内部文件 / 解析失败）
if rescue_pnpm_dir_to_key 'node_modules' >/dev/null 2>&1; then fail 'parse-should-reject-node_modules'; fi
if rescue_pnpm_dir_to_key 'lock.yaml' >/dev/null 2>&1; then fail 'parse-should-reject-lockyaml'; fi

# --- 2) lockfile 键提取：带引号、带 peer 括号后缀 ---
cat > "$DSH_HOME/profiles/web/pnpm-lock.yaml" <<'EOF'
lockfileVersion: '9.0'

importers:

  .:
    dependencies:
      '@wenaixi/dsh-superpower':
        specifier: 6.3.0-dsh.10
        version: 6.3.0-dsh.10(@deepseek-ai/cordis@4.0.2)

packages:

  '@deepseek-ai/cordis@4.0.2':
    resolution: {integrity: sha512-xxx}

  '@wenaixi/dsh-superpower@6.3.0-dsh.10':
    resolution: {integrity: sha512-yyy}

  yaml@2.9.1:
    resolution: {integrity: sha512-zzz}

snapshots:

  '@wenaixi/dsh-superpower@6.3.0-dsh.10(@deepseek-ai/cordis@4.0.2)':
    dependencies:
      '@deepseek-ai/cordis': 4.0.2
EOF

rescue_pnpm_locked_keys "$DSH_HOME/profiles/web/pnpm-lock.yaml" > "$T/keys"
grep -qx '@deepseek-ai/cordis@4.0.2' "$T/keys" || fail keys-missing-cordis
grep -qx '@wenaixi/dsh-superpower@6.3.0-dsh.10' "$T/keys" || fail keys-missing-superpower
grep -qx 'yaml@2.9.1' "$T/keys" || fail keys-missing-yaml
# snapshots 段的键也必须被剥掉 peer 括号（否则 packages 段与 snapshots 段重复计数无害，但不能产生垃圾键）
if grep -q '(' "$T/keys"; then fail keys-should-strip-peer-parens; fi

# --- 3) 孤儿判定 ---
if ! rescue_pnpm_is_orphan '@wenaixi+dsh-superpower@6.3.1_@deepseek-ai+cordis@4.0.2_ea1' "$DSH_HOME/profiles/web/pnpm-lock.yaml"; then
  fail orphan-not-detected
fi
if rescue_pnpm_is_orphan '@wenaixi+dsh-superpower@6.3.0-dsh.10_@deepseek-ai+cordis@4.0.2_ea1' "$DSH_HOME/profiles/web/pnpm-lock.yaml"; then
  fail referenced-wrongly-flagged-orphan
fi
# 关键回归：在用的 6.3.1 存在于 packages 段时绝不能被判为孤儿
sed -i "s/@wenaixi\/dsh-superpower@6.3.0-dsh.10/@wenaixi\/dsh-superpower@6.3.1/" "$DSH_HOME/profiles/web/pnpm-lock.yaml" 2>/dev/null || \
  sed -i '' "s/@wenaixi\/dsh-superpower@6.3.0-dsh.10/@wenaixi\/dsh-superpower@6.3.1/" "$DSH_HOME/profiles/web/pnpm-lock.yaml"
if rescue_pnpm_is_orphan '@wenaixi+dsh-superpower@6.3.1_@deepseek-ai+cordis@4.0.2_ea1' "$DSH_HOME/profiles/web/pnpm-lock.yaml"; then
  fail live-package-misjudged-as-orphan
fi

echo 'ALL-PASS'
```

- [ ] **步骤 2：运行测试并确认其失败**

运行：`sh scripts/t/test-rescue-clean.sh`
预期：FAIL，提示 `rescue_pnpm_dir_to_key: not found`（或 `FAIL parse-scoped-with-peer:` —— 因函数尚未定义，`set -eu` 下命令未找到会直接终止，两种输出均可接受）

- [ ] **步骤 3：编写最小实现**

在 `scripts/librescue.sh` **末尾追加**：

```sh
# ---- rescue clean：升级后环境清理（规格 docs/superpowers/specs/2026-09-15-rescue-clean-design.md）----
# pnpm 虚拟存储目录名 -> "<name>@<version>"。
# 目录名格式：<name-with-+-for-/>@<version>[_<peerSuffix>]
# 【必须】先按首个 "_" 切掉 peer 后缀，再取 indexOf("@", 1) 作为 name/version 分隔。
# 【严禁】用 lastIndexOf("@")：peer 后缀里含 "@"，会把在用的包误判为孤儿并删掉活依赖。
rescue_pnpm_dir_to_key() {
  _pk_dir="$1"
  case "$_pk_dir" in .*) return 1 ;; esac
  # 先切掉 peer 后缀：目录名中 version 段不含 '_'，首个 '_' 之后即为 peer 信息
  _pk_core="${_pk_dir%%_*}"
  [ -n "$_pk_core" ] || return 1
  # 在剩余部分取「最后一个 @」作为 name/version 边界。
  # 合法性：name 中的 '/' 已由 pnpm 替换为 '+'，故 core 内至多出现一个 '@'。
  # 必须用「还原校验」确认切分正确，避免 node_modules / lock.yaml 之类被误判。
  _pk_head="${_pk_core%@*}"     # name 部分
  _pk_ver="${_pk_core##*@}"     # version 部分
  [ -n "$_pk_head" ] || return 1
  [ "${_pk_head}@${_pk_ver}" = "$_pk_core" ] || return 1
  # 版本段必须以数字开头（拒绝 lock.yaml / node_modules 之类）
  case "$_pk_ver" in
    [0-9]*) : ;;
    *) return 1 ;;
  esac
  printf '%s@%s\n' "$(printf '%s' "$_pk_head" | tr '+' '/')" "$_pk_ver"
}

# lockfile 的 packages: 段 -> 每行一个 "<name>@<version>"（剥离 'v(...)' peer 括号后缀与引号）
rescue_pnpm_locked_keys() {
  _lk_file="$1"
  [ -f "$_lk_file" ] || return 1
  # 只取 packages: 与 snapshots: 之间的键行（缩进恰为 2 空格且以 ':' 结尾）
  sed -n '/^packages:[[:space:]]*$/,/^snapshots:[[:space:]]*$/p' "$_lk_file" \
    | sed -n "s/^  \(.*\):[[:space:]]*$/\1/p" \
    | sed "s/^'//; s/'$//" \
    | sed 's/(.*$//'
}

# 孤儿判定：目录名解析出的键不在 lockfile 引用集内 -> 0（孤儿）；被引用 -> 1
rescue_pnpm_is_orphan() {
  _po_dir="$1"; _po_lock="$2"
  _po_key=$(rescue_pnpm_dir_to_key "$_po_dir") || return 1
  _po_keys=$(rescue_pnpm_locked_keys "$_po_lock" 2>/dev/null || printf '')
  case "
$_po_keys
" in
    *"
$_po_key
"*) return 1 ;;
  esac
  return 0
}
```

- [ ] **步骤 4：运行测试并确认其通过**

运行：`sh scripts/t/test-rescue-clean.sh`
预期：PASS，输出 `ALL-PASS`

- [ ] **步骤 5：用真实 pnpm 产物交叉验证解析器**

在临时目录制造真实夹具并核对（此步为手工验证，不写入测试文件）：

```sh
T=$(mktemp -d); cd "$T"
npm_config_cache=/tmp/npm-cache pnpm add yaml@2.9.1 2>&1 | tail -1
ls node_modules/.pnpm | grep -v '^\.'
```
预期：出现的每个真实条目（如 `yaml@2.9.1`）都能被 `rescue_pnpm_dir_to_key` 正确解析为 `yaml@2.9.1`；`.lock.yaml` / `.modules.yaml` / `node_modules` 一律返回非 0。

- [ ] **步骤 6：提交**

```bash
git add scripts/librescue.sh scripts/t/test-rescue-clean.sh
git commit -m "feat(rescue): pnpm 虚拟存储孤儿判定（clean 基础）"
```

---

### 任务 2：npm 缓存与 pnpm store 清理函数

**文件：**
- 修改：`scripts/librescue.sh`（在任务 1 追加内容之后继续追加）
- 测试：`scripts/t/test-rescue-clean.sh`（追加用例）

**接口：**
- 依赖输入：无
- 对外产出：
  - `rescue_clean_npm_cache <dryRun>` → 打印该缓存路径与可回收字节数；`dryRun=0` 时实际删除 `_cacache`
  - `rescue_clean_pnpm_store <dryRun>` → `dryRun=0` 时执行 `pnpm store prune`，打印其输出
  - `rescue_dir_size_bytes <path>` → 打印目录占用的字节数（不可读或不存在时打印 0）

- [ ] **步骤 1：编写失败的测试**

在 `scripts/t/test-rescue-clean.sh` 的 `echo 'ALL-PASS'` **之前**插入：

```sh
# --- 4) 目录体积统计 ---
mkdir -p "$T/sz/a/b"
# 用固定大小文件避免依赖 block size：8 字节 × 2
printf '12345678' > "$T/sz/a/f1"
printf '12345678' > "$T/sz/a/b/f2"
sz=$(rescue_dir_size_bytes "$T/sz")
[ "$sz" -ge 16 ] || fail "dir-size-too-small:$sz"
sz0=$(rescue_dir_size_bytes "$T/does-not-exist")
[ "$sz0" = 0 ] || fail "dir-size-missing-should-be-0:$sz0"

# --- 5) npm 缓存清理：dry-run 不删，实删只删 _cacache ---
CACHE="$T/npmcache"
mkdir -p "$CACHE/_cacache/content-v2" "$CACHE/_logs"
printf 'cache-blob' > "$CACHE/_cacache/content-v2/blob"
printf 'log' > "$CACHE/_logs/keep.log"
NPM_CONFIG_CACHE="$CACHE" npm_config_cache="$CACHE"
export NPM_CONFIG_CACHE="$CACHE"

rescue_clean_npm_cache 1 >/dev/null 2>&1 || true
[ -d "$CACHE/_cacache" ] || fail 'dryrun-deleted-npm-cache'

rescue_clean_npm_cache 0 >/dev/null 2>&1 || true
[ ! -d "$CACHE/_cacache" ] || fail 'real-run-kept-npm-cache'
[ -d "$CACHE/_logs" ] || fail 'must-not-delete-logs-dir'

# --- 6) pnpm store 清理：dry-run 不调用 prune ---
# 用 stub pnpm 记录调用，避免依赖真实网络/存储
STUB="$T/bin"; mkdir -p "$STUB"
cat > "$STUB/pnpm" <<'STUBEOF'
#!/bin/sh
printf '%s\n' "$*" >> "${PNPM_STUB_LOG:?}"
exit 0
STUBEOF
chmod +x "$STUB/pnpm"
export PATH="$STUB:$PATH"
export PNPM_STUB_LOG="$T/pnpm-calls"
: > "$PNPM_STUB_LOG"

rescue_clean_pnpm_store 1 >/dev/null 2>&1 || true
if [ -s "$PNPM_STUB_LOG" ]; then fail 'dryrun-invoked-pnpm-store'; fi

rescue_clean_pnpm_store 0 >/dev/null 2>&1 || true
grep -q 'store prune' "$PNPM_STUB_LOG" || fail 'real-run-did-not-prune-store'
```

- [ ] **步骤 2：运行测试并确认其失败**

运行：`sh scripts/t/test-rescue-clean.sh`
预期：FAIL，提示 `rescue_dir_size_bytes: not found`

- [ ] **步骤 3：编写最小实现**

继续在 `scripts/librescue.sh` 末尾追加：

```sh
# 目录占用字节数（du -sk 的 POSIX 口径）；不存在或不可读时打印 0。
rescue_dir_size_bytes() {
  _ds_p="$1"
  [ -e "$_ds_p" ] || { printf '0'; return 0; }
  _ds_k=$(du -sk "$_ds_p" 2>/dev/null | awk '{print $1}' | head -n1)
  case "$_ds_k" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$((_ds_k * 1024))" ;; esac
}

# C1：npm 下载缓存。只删 _cacache（纯下载缓存），保留 _logs 等同级内容。
# 定位顺序：NPM_CONFIG_CACHE / npm_config_cache -> npm config get cache -> /root/.npm
rescue_clean_npm_cache() {
  _nc_dry="${1:-1}"
  _nc_cache="${NPM_CONFIG_CACHE:-${npm_config_cache:-}}"
  if [ -z "$_nc_cache" ]; then
    _nc_cache=$(npm config get cache 2>/dev/null || printf '')
  fi
  [ -n "$_nc_cache" ] || _nc_cache=/root/.npm
  _nc_target="$_nc_cache/_cacache"
  if [ ! -d "$_nc_target" ]; then
    rescue_log "clean: npm cache absent ($_nc_target)"
    printf 'npm cache: %s (absent, 0 B)\n' "$_nc_cache"
    return 0
  fi
  _nc_sz=$(rescue_dir_size_bytes "$_nc_target")
  if [ "$_nc_dry" = 1 ]; then
    printf 'npm cache: %s (%s B reclaimable)\n' "$_nc_cache" "$_nc_sz"
    return 0
  fi
  rm -rf "$_nc_target" 2>/dev/null || { rescue_log "clean: npm cache removal failed ($_nc_target)"; return 1; }
  rescue_log "clean: removed npm cache $_nc_target (%s B)" "$_nc_sz"
  printf 'npm cache: %s (%s B reclaimed)\n' "$_nc_cache" "$_nc_sz"
}

# C2：pnpm 内容寻址存储。官方语义即「只删 unreferenced」，故直接委托 pnpm store prune。
rescue_clean_pnpm_store() {
  _ps_dry="${1:-1}"
  if ! command -v pnpm >/dev/null 2>&1; then
    rescue_log 'clean: pnpm not found; store prune skipped'
    printf 'pnpm store: pnpm not found (skipped)\n'
    return 0
  fi
  if [ "$_ps_dry" = 1 ]; then
    printf 'pnpm store: would run "pnpm store prune" (removes unreferenced packages only)\n'
    return 0
  fi
  _ps_out=$(pnpm store prune 2>&1) || { rescue_log "clean: pnpm store prune failed: $_ps_out"; return 1; }
  rescue_log "clean: pnpm store prune -> $_ps_out"
  printf 'pnpm store: %s\n' "$_ps_out"
}
```

- [ ] **步骤 4：运行测试并确认其通过**

运行：`sh scripts/t/test-rescue-clean.sh`
预期：PASS，输出 `ALL-PASS`

- [ ] **步骤 5：提交**

```bash
git add scripts/librescue.sh scripts/t/test-rescue-clean.sh
git commit -m "feat(rescue): npm 缓存与 pnpm store 清理函数"
```

---

### 任务 3：profile 孤儿条目清理与救援历史轮转

**文件：**
- 修改：`scripts/librescue.sh`（继续追加）
- 修改：`scripts/rescue-supervise.sh`（把 `rescue_evidence_prune` 下沉复用，或在 librescue 中新增等价函数）
- 测试：`scripts/t/test-rescue-clean.sh`（追加用例）

**接口：**
- 依赖输入：`rescue_pnpm_is_orphan`（任务 1）、`rescue_dir_size_bytes`（任务 2）
- 对外产出：
  - `rescue_clean_pnpm_orphans <profileDir> <dryRun>` → 打印孤儿清单与回收字节；`dryRun=0` 时删除
  - `rescue_clean_rescue_history` → 调用 `rescue_evidence_prune` 与 `rescue_incident_prune`

**关键可见性问题（规格 §7.1 已记录）：** `rescue_evidence_prune` 当前定义在 `scripts/rescue-supervise.sh:91`，而 `scripts/rescue` **只 source `scripts/librescue.sh`**。直接调用会 `command not found`。本任务必须消除该差异 —— 采用**下沉到 librescue** 的方式（与 `rescue_incident_prune` 同址），并在 `rescue-supervise.sh` 中删除重复定义以免覆盖。

- [ ] **步骤 1：编写失败的测试**

在 `echo 'ALL-PASS'` 之前插入：

```sh
# --- 7) profile 孤儿清理：被引用者绝不删 ---
P="$DSH_HOME/profiles/web"
mkdir -p "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa" \
         "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.0-dsh.10_peer_bb" \
         "$P/node_modules/.pnpm"
printf 'old' > "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa/index.js"
printf 'new' > "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.0-dsh.10_peer_bb/index.js"
cat > "$P/pnpm-lock.yaml" <<'EOF'
lockfileVersion: '9.0'

packages:

  '@wenaixi/dsh-superpower@6.3.0-dsh.10':
    resolution: {integrity: sha512-yyy}

snapshots:
EOF
# 红线基线：记录两个受保护文件的字节指纹
before_pkg=$(cksum < "$P/package.json")
before_lock=$(cksum < "$P/pnpm-lock.yaml")

# dry-run：不删任何东西
rescue_clean_pnpm_orphans "$P" 1 >/dev/null 2>&1 || true
[ -d "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa" ] || fail 'dryrun-deleted-orphan'

# 真实清理：孤儿消失、在用者保留
rescue_clean_pnpm_orphans "$P" 0 >/dev/null 2>&1 || true
[ ! -d "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa" ] || fail 'real-run-kept-orphan'
[ -d "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.0-dsh.10_peer_bb" ] || fail 'REGRESSION-deleted-referenced-entry'

# 红线：两个受保护文件字节级不变
[ "$before_pkg" = "$(cksum < "$P/package.json")" ] || fail 'REDLINE-package.json-modified'
[ "$before_lock" = "$(cksum < "$P/pnpm-lock.yaml")" ] || fail 'REDLINE-lockfile-modified'

# --- 8) 救援历史轮转函数在 librescue 上下文可用（可见性回归）---
command -v rescue_evidence_prune >/dev/null 2>&1 || fail 'evidence-prune-not-visible-in-librescue'
command -v rescue_incident_prune >/dev/null 2>&1 || fail 'incident-prune-not-visible-in-librescue'
rescue_clean_rescue_history >/dev/null 2>&1 || fail 'rescue-history-clean-failed'
```

- [ ] **步骤 2：运行测试并确认其失败**

运行：`sh scripts/t/test-rescue-clean.sh`
预期：FAIL，提示 `rescue_clean_pnpm_orphans: not found`

- [ ] **步骤 3：编写最小实现**

先确认 `rescue_supervise.sh` 中 `rescue_evidence_prune` 的完整实现：

```bash
sed -n '85,110p' scripts/rescue-supervise.sh
```

把该函数**原样**复制到 `scripts/librescue.sh` 末尾（保持逻辑一致），再在 `scripts/rescue-supervise.sh` 中删除其定义（避免覆盖 librescue 版本），并在删除处留注释：

```sh
# rescue_evidence_prune 已下沉到 librescue.sh：scripts/rescue 只 source librescue，
# 定义在 supervise 侧会让 `rescue clean` 拿不到它（command not found）。
# 关键取值：_evidence_keep="${RESCUE_EVIDENCE_KEEP:-$RESCUE_KEEP}"
```

然后继续在 `scripts/librescue.sh` 末尾追加：

```sh
# C3：profile 的 .pnpm 中未被 lockfile 引用的条目。
# 安全性：只删「当前 lockfile 未引用」的条目。回滚会连同 lockfile 一起还原，
# 且被删条目在快照里另有独立目录项（cp -al 对目录是新建目录 + 硬链接文件），
# 故清理不破坏 rescue rollback 基线（规格 §6 已实测）。
rescue_clean_pnpm_orphans() {
  _co_pdir="$1"; _co_dry="${2:-1}"
  _co_pnpm="$_co_pdir/node_modules/.pnpm"
  _co_lock="$_co_pdir/pnpm-lock.yaml"
  if [ ! -d "$_co_pnpm" ]; then
    printf 'pnpm orphans: no virtual store at %s (skipped)\n' "$_co_pnpm"
    return 0
  fi
  if [ ! -f "$_co_lock" ]; then
    # 无 lockfile 时无法证明谁是可删的 —— 保守起见一律不动（红线）
    rescue_log "clean: no lockfile at $_co_lock; orphan cleanup skipped"
    printf 'pnpm orphans: lockfile missing (%s) - skipped for safety\n' "$_co_lock"
    return 0
  fi
  _co_n=0; _co_sz=0
  for _co_d in "$_co_pnpm"/*; do
    [ -d "$_co_d" ] || continue
    _co_name=${_co_d##*/}
    rescue_pnpm_is_orphan "$_co_name" "$_co_lock" || continue
    _co_b=$(rescue_dir_size_bytes "$_co_d")
    _co_n=$((_co_n + 1))
    _co_sz=$((_co_sz + _co_b))
    if [ "$_co_dry" = 1 ]; then
      printf 'pnpm orphan: %s (%s B)\n' "$_co_name" "$_co_b"
    else
      rm -rf "$_co_d" 2>/dev/null || rescue_log "clean: failed to remove orphan $_co_name"
      rescue_log "clean: removed pnpm orphan $_co_name ($_co_b B)"
      printf 'pnpm orphan: %s removed (%s B)\n' "$_co_name" "$_co_b"
    fi
  done
  if [ "$_co_n" = 0 ]; then
    printf 'pnpm orphans: none (%s)\n' "$_co_pnpm"
  else
    printf 'pnpm orphans: %s entr%s, %s B\n' "$_co_n" "$([ "$_co_n" = 1 ] && printf y || printf ies)" "$_co_sz"
  fi
}

# C4：显式触发既有轮转（不新写轮转逻辑）
rescue_clean_rescue_history() {
  rescue_evidence_prune 2>/dev/null || true
  rescue_incident_prune 2>/dev/null || true
  rescue_log 'clean: rescue history pruned (evidence + incidents)'
  printf 'rescue history: evidence + incidents pruned\n'
}
```

- [ ] **步骤 4：运行测试并确认其通过**

运行：`sh scripts/t/test-rescue-clean.sh`
预期：PASS，输出 `ALL-PASS`

- [ ] **步骤 5：确认未破坏既有 supervise 测试**

运行：`sh scripts/t/test-supervise-source.sh && sh scripts/t/test-supervise-loop.sh`
预期：两者均通过（`rescue_evidence_prune` 移址后行为不变）

- [ ] **步骤 6：提交**

```bash
git add scripts/librescue.sh scripts/rescue-supervise.sh scripts/t/test-rescue-clean.sh
git commit -m "feat(rescue): profile 孤儿清理与救援历史轮转；evidence_prune 下沉 librescue"
```

---

### 任务 4：`rescue clean` 子命令（护栏编排与 CLI）

**文件：**
- 修改：`scripts/rescue`（第 22 行 usage 串 + 新增 `clean)` 分支）
- 测试：`scripts/t/test-rescue-clean.sh`（追加 CLI 级用例）

**接口：**
- 依赖输入：`rescue_clean_npm_cache` / `rescue_clean_pnpm_store` / `rescue_clean_pnpm_orphans` / `rescue_clean_rescue_history`（任务 2、3）
- 对外产出：`rescue clean [--dry-run|-n] [--yes] [--json]`

**行为契约：**
- 无 `--yes` → 全程只读，不拍快照、不改动任何文件。
- 有 `--yes` → **先拍快照**（`REASON_SNAPSHOT="pre-clean"`，仅当 profile 目录与 `package.json` 均存在），再执行四项清理。
- 不得触碰自愈预算（全局约束）。
- 无 profile 时优雅降级：打印跳过并 `exit 0`。

- [ ] **步骤 1：编写失败的测试**

在 `echo 'ALL-PASS'` 之前插入：

```sh
# --- 9) CLI：默认 dry-run 不产生副作用、不拍快照 ---
RESCUE="$ROOT/scripts/rescue"
[ -x "$RESCUE" ] || fail 'rescue-not-executable'
rm -rf "$RESCUE_DIR"/snap-*
before_n=$(ls -1d "$RESCUE_DIR"/snap-* 2>/dev/null | wc -l | tr -d ' ')
sh "$RESCUE" clean >/dev/null 2>&1 || fail 'clean-dryrun-exit-nonzero'
after_n=$(ls -1d "$RESCUE_DIR"/snap-* 2>/dev/null | wc -l | tr -d ' ')
[ "$before_n" = "$after_n" ] || fail 'dryrun-created-snapshot'
[ -d "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.0-dsh.10_peer_bb" ] || fail 'dryrun-removed-live-entry'

# --- 10) CLI：usage 串包含 clean ---
sh "$RESCUE" >/dev/null 2>&1 || true
usage=$(sh "$RESCUE" 2>&1 || true)
printf '%s' "$usage" | grep -q 'clean' || fail 'usage-missing-clean'

# --- 11) CLI：--yes 拍 pre-clean 快照 ---
# 重建一份孤儿，确保有东西可清
mkdir -p "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.9_peer_zz"
printf 'junk' > "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.9_peer_zz/index.js"
: > "$PNPM_STUB_LOG"
sh "$RESCUE" clean --yes >/dev/null 2>&1 || fail 'clean-yes-exit-nonzero'
ls -1d "$RESCUE_DIR"/snap-* >/dev/null 2>&1 || fail 'clean-yes-created-no-snapshot'
grep -q '"reason":"pre-clean"' "$RESCUE_DIR"/snap-*/meta.json || fail 'pre-clean-reason-missing'
[ ! -d "$P/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.9_peer_zz" ] || fail 'clean-yes-did-not-remove-orphan'

# --- 12) CLI：未知选项须报错退出（非 0）---
if sh "$RESCUE" clean --bogus >/dev/null 2>&1; then fail 'unknown-option-should-fail'; fi

# --- 13) 红线：--yes 后 package.json 与 lockfile 仍字节级不变 ---
[ "$before_pkg" = "$(cksum < "$P/package.json")" ] || fail 'REDLINE-yes-package.json-modified'
[ "$before_lock" = "$(cksum < "$P/pnpm-lock.yaml")" ] || fail 'REDLINE-yes-lockfile-modified'

# --- 14) 与自愈预算解耦 ---
[ ! -f "$RESCUE_DIR/state/selfheal.json" ] || fail 'clean-touched-selfheal-budget'
```

- [ ] **步骤 2：运行测试并确认其失败**

运行：`sh scripts/t/test-rescue-clean.sh`
预期：FAIL，提示 `FAIL clean-dryrun-exit-nonzero`（`clean` 子命令尚未实现，`rescue` 会走 `*) unknown subcommand` 返回 2）

- [ ] **步骤 3：编写最小实现**

修改 `scripts/rescue` 第 22 行的 usage 串，加入 `clean`：

```sh
[ -n "$cmd" ] || { echo 'usage: rescue <snapshot|snapshots|plugin|rollback|dsh-upgrade|dsh-reinstall|status|doctor|lifeboat|report|incident|verify|selfheal|export|clean>'; exit 2; }
```

在 `selfheal)` 分支之后、`verify)` 分支之前插入新分支：

```sh
  clean)
    # 升级后环境清理（规格 docs/superpowers/specs/2026-09-15-rescue-clean-design.md）
    # 默认 dry-run：不带 --yes 时全程只读，不拍快照、不改动任何文件。
    dry=1
    while [ $# -gt 0 ]; do
      case "$1" in
        --yes|-y) dry=0; shift ;;
        --dry-run|-n) dry=1; shift ;;
        *) echo "clean: unknown option '$1'  (usage: rescue clean [--dry-run|-n] [--yes])"; exit 2 ;;
      esac
    done
    if [ "$dry" = 1 ]; then
      echo 'clean: dry-run (no changes will be made; pass --yes to apply)'
      rescue_clean_npm_cache 1 || true
      rescue_clean_pnpm_store 1 || true
      pdir=$(profile_dir)
      rescue_clean_pnpm_orphans "$pdir" 1 || true
      echo 'clean: rescue history rotation skipped in dry-run'
      echo 'clean: dry-run complete — nothing was changed'
      exit 0
    fi
    # ---- 真实清理：先拍快照作为护栏（仅 profile 就绪时）----
    pdir=$(profile_dir)
    if [ -d "$pdir" ] && [ -f "$pdir/package.json" ]; then
      REASON_SNAPSHOT='pre-clean' rescue_snapshot >/dev/null 2>&1 \
        && echo 'clean: pre-clean snapshot created' \
        || echo 'clean: WARN pre-clean snapshot failed; continuing'
    else
      echo "clean: no profile at $pdir — skipping snapshot"
    fi
    rescue_clean_npm_cache 0 || true
    rescue_clean_pnpm_store 0 || true
    rescue_clean_pnpm_orphans "$pdir" 0 || true
    rescue_clean_rescue_history || true
    echo 'clean: done'
    ;;
```

- [ ] **步骤 4：运行测试并确认其通过**

运行：`sh scripts/t/test-rescue-clean.sh`
预期：PASS，输出 `ALL-PASS`

- [ ] **步骤 5：跑完整测试套件确认无回归**

运行：
```bash
for t in scripts/t/test-*.sh; do printf '%-46s' "$(basename "$t")"; sh "$t" >/dev/null 2>&1 && echo PASS || echo FAIL; done
```
预期：全部 PASS（既有 21 项 + 新增 1 项）

- [ ] **步骤 6：提交**

```bash
git add scripts/rescue scripts/t/test-rescue-clean.sh
git commit -m "feat(rescue): rescue clean 子命令（默认 dry-run + pre-clean 快照护栏）"
```

---

### 任务 5：回滚交互回归测试（红线固化）

**文件：**
- 测试：`scripts/t/test-rescue-clean.sh`（追加端到端用例）

**接口：**
- 依赖输入：`rescue_clean_pnpm_orphans`（任务 3）、`rescue_restore`（既有）
- 对外产出：无（纯回归防护）

**目的：** 把规格 §6 的实测结论固化为自动化回归，防止后续改动破坏「清理后可回滚」这一性质。

- [ ] **步骤 1：编写失败的测试**

在 `echo 'ALL-PASS'` 之前插入：

```sh
# --- 15) 回滚交互红线：清理孤儿后仍能回滚到清理前的快照 ---
R2="$T/home2"; export DSH_HOME="$R2"
mkdir -p "$R2/profiles/web"
printf '%s' '{"name":"web","dependencies":{"@wenaixi/dsh-superpower":"6.3.1"}}' > "$R2/profiles/web/package.json"
cat > "$R2/profiles/web/pnpm-lock.yaml" <<'EOF'
lockfileVersion: '9.0'

packages:

  '@wenaixi/dsh-superpower@6.3.1':
    resolution: {integrity: sha512-yyy}

snapshots:
EOF
mkdir -p "$R2/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa"
printf '6.3.1' > "$R2/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa/index.js"

# 重新 source 以套用新 DSH_HOME
. "$LIB"
RESCUE_KEEP=5 REASON_SNAPSHOT='pre-upgrade' rescue_snapshot >/dev/null 2>&1 || fail 'rollback-fixture-snapshot-failed'

# 升级：lockfile 指向新版本，旧版本变孤儿
sed -i 's/@wenaixi\/dsh-superpower@6.3.1/@wenaixi\/dsh-superpower@6.3.9/' "$R2/profiles/web/pnpm-lock.yaml"
printf '%s' '{"name":"web","dependencies":{"@wenaixi/dsh-superpower":"6.3.9"}}' > "$R2/profiles/web/package.json"
mkdir -p "$R2/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.9_peer_bb"
printf '6.3.9' > "$R2/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.9_peer_bb/index.js"

# 清理孤儿（6.3.1 已不被新 lockfile 引用）
rescue_clean_pnpm_orphans "$R2/profiles/web" 0 >/dev/null 2>&1 || true
[ ! -d "$R2/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa" ] || fail 'setup-orphan-not-removed'

# 回滚到 pre-upgrade 快照
snap=$(rescue_snapshot_list_by_time | head -n1)
[ -n "$snap" ] || fail 'no-snapshot-to-restore'
rescue_restore "${snap##*/}" >/dev/null 2>&1 || fail 'restore-failed-after-clean'

# 断言：回滚后 lockfile 与依赖树一致，且 6.3.1 条目重新可用
grep -q '@wenaixi/dsh-superpower@6.3.1' "$R2/profiles/web/pnpm-lock.yaml" || fail 'rollback-lockfile-not-restored'
[ -d "$R2/profiles/web/node_modules/.pnpm/@wenaixi+dsh-superpower@6.3.1_peer_aa" ] \
  || fail 'REGRESSION-rollback-target-missing-after-clean'
```

- [ ] **步骤 2：运行测试并确认其失败（若实现正确则应直接通过）**

运行：`sh scripts/t/test-rescue-clean.sh`
预期：若前置任务实现正确，此用例**直接 PASS**；若失败，说明清理破坏了回滚基线，属实现缺陷，必须修复实现而非放宽测试。

- [ ] **步骤 3：验证红线用例确实能捕获破坏**

临时把 `rescue_clean_pnpm_orphans` 中的 `rescue_pnpm_is_orphan ... || continue` 改为无条件删除（即删除所有条目），运行测试：
运行：`sh scripts/t/test-rescue-clean.sh`
预期：FAIL，提示 `REGRESSION-rollback-target-missing-after-clean` 或 `REGRESSION-deleted-referenced-entry`。
**验证完毕后必须 `git checkout scripts/librescue.sh` 还原该临时改动。**

- [ ] **步骤 4：提交**

```bash
git add scripts/t/test-rescue-clean.sh
git commit -m "test(rescue): 固化 clean 后可回滚的红线回归用例"
```

---

### 任务 6：文档

**文件：**
- 修改：`docs/zh-CN/03-升级与维护.md`（在 §1 之后新增小节）
- 修改：`docs/en/03-upgrade-maintenance.md`（对应章节）
- 修改：`docs/zh-CN/06-救援模式.md`（命令表补 `clean`）
- 修改：`CHANGELOG.md`

**接口：**
- 依赖输入：任务 4 完成的 CLI 行为
- 对外产出：无

- [ ] **步骤 1：在 `docs/zh-CN/03-升级与维护.md` 的 §1 末尾（§2 之前）插入**

```markdown
### 升级后清理残留

长期在容器内升级会累积无人回收的残留。用 `rescue clean` 清理：

```bash
docker exec dsh rescue clean            # 预览（默认 dry-run，不做任何改动）
docker exec dsh rescue clean --yes      # 确认执行
```

清理四项（全部为可证明的垃圾）：

| 项 | 内容 | 说明 |
|---|---|---|
| npm 下载缓存 | `_cacache` | 删后仅需重新下载 |
| pnpm 存储孤儿 | `pnpm store prune` | 官方语义即「只删 unreferenced」 |
| profile 虚拟存储孤儿 | `.pnpm` 中未被 `pnpm-lock.yaml` 引用的条目 | **`pnpm prune` 不会清这些**，是主要的残留来源 |
| 救援历史超限部分 | evidence / incidents | 复用既有 `RESCUE_EVIDENCE_KEEP` / `RESCUE_INCIDENT_KEEP` |

> 🔒 `--yes` 会**先自动拍一份快照**（`reason: pre-clean`）作为回退落点。
> 清理**绝不**触碰 `package.json`、`pnpm-lock.yaml`、被引用的 `.pnpm` 条目与任何快照目录，
> 因此不影响 `rescue rollback` 的能力。
>
> ⚠ 若 profile 使用默认的 `hardlink` 快照模式，被快照引用的文件 inode 仍在，
> 空间可能不会立即释放 —— 这是正常现象，待快照被轮转淘汰后回收。
```

- [ ] **步骤 2：在 `docs/en/03-upgrade-maintenance.md` 对应位置加入英文版**

内容与上表一致，标题为 `### Cleaning up after upgrades`，命令块与表格逐项对应翻译，保留 `rescue clean` / `--yes` / `pre-clean` 等原文标识符。

- [ ] **步骤 3：在 `docs/zh-CN/06-救援模式.md` 的命令表中补一行**

```markdown
| `rescue clean [--yes]` | 升级后清理残留（默认 dry-run 预览；`--yes` 执行并先拍快照） |
```

- [ ] **步骤 4：在 `CHANGELOG.md` 顶部新增条目**

```markdown
### Added
- `rescue clean`：升级后环境清理。默认 dry-run 预览，`--yes` 执行前自动拍 pre-clean 快照。
  清理 npm 缓存、pnpm store 孤儿、profile `.pnpm` 中未被 lockfile 引用的条目与超限救援历史；
  不触碰依赖基线与快照，不影响 `rescue rollback`。
```

- [ ] **步骤 5：校验文档双语链接与标签配对**

运行：
```bash
grep -n 'rescue clean' docs/zh-CN/03-升级与维护.md docs/en/03-upgrade-maintenance.md docs/zh-CN/06-救援模式.md CHANGELOG.md
```
预期：四个文件均有命中，无遗漏。

- [ ] **步骤 6：提交**

```bash
git add docs/zh-CN/03-升级与维护.md docs/en/03-upgrade-maintenance.md docs/zh-CN/06-救援模式.md CHANGELOG.md
git commit -m "docs: rescue clean 使用说明（zh-CN/en）与 CHANGELOG"
```

---

### 任务 7：端到端验收与 CI 门禁

**文件：**
- 修改：`.github/workflows/docker-image.yml`（仅在测试发现遗漏时）
- 测试：`scripts/t/e2e-*.sh`（仅在有 docker 的环境）

**接口：**
- 依赖输入：任务 1–6 全部完成
- 对外产出：无

- [ ] **步骤 1：确认新增测试被 CI 门禁自动收录**

运行：`grep -n "scripts/t/test-" .github/workflows/docker-image.yml | head`
预期：CI 以通配方式遍历 `scripts/t/test-*.sh`（若是显式枚举列表，则需把 `test-rescue-clean.sh` 加入）。

- [ ] **步骤 2：本地跑完整单测套件**

运行：
```bash
for t in scripts/t/test-*.sh; do printf '%-46s' "$(basename "$t")"; sh "$t" >/dev/null 2>&1 && echo PASS || echo FAIL; done
```
预期：全部 PASS，无 FAIL。

- [ ] **步骤 3：shellcheck / dash 兼容性检查（若环境可用）**

运行：
```bash
command -v shellcheck >/dev/null 2>&1 && shellcheck -s sh scripts/librescue.sh scripts/rescue || echo 'shellcheck unavailable - skipped'
dash -n scripts/librescue.sh && dash -n scripts/rescue && echo 'dash syntax OK'
```
预期：无 error 级告警；`dash syntax OK`。

- [ ] **步骤 4：提交（若步骤 1 需要改动 CI 配置）**

```bash
git add .github/workflows/docker-image.yml
git commit -m "ci: 纳入 test-rescue-clean.sh 测试门禁"
```

---

## 完成标准

- [ ] `rescue clean` 无参数时零副作用（不拍快照、不改文件）
- [ ] `rescue clean --yes` 先拍 `pre-clean` 快照，再执行四项清理
- [ ] 被 lockfile 引用的 `.pnpm` 条目在任何路径下都不被删除
- [ ] `package.json` 与 `pnpm-lock.yaml` 在清理前后字节级不变
- [ ] 清理后可成功 `rescue rollback` 到清理前的快照，且依赖条目完整
- [ ] `rescue clean` 不读写自愈预算状态
- [ ] `scripts/t/test-rescue-clean.sh` 通过并输出 `ALL-PASS`
- [ ] 完整测试套件无回归
- [ ] 中英文档与 CHANGELOG 已更新
