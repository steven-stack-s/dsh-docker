# rescue 原生绑定守护 实施计划

> **状态：未采纳（2026-09-17）。** 对应设计 `issues/2026-09-17-rescue-binding-guard.md`
> 的决策为「暂不实施」——本次故障判为**偶发**（网络 302 + 市场恰在更新 + pnpm 恰在
> `onnxruntime-node` 处失败），护栏职责属上游 `dshmarket` / DSH。
> 本计划**未执行任何步骤**，保留供日后复评时直接开工（复评触发条件见该设计 §10）。

> **面向 Agent 执行者：** 必需子技能：使用 superpower-subagent-driven-development（推荐）或 superpower-executing-plans 按任务逐项执行本计划。步骤使用复选框（`- [ ]`）语法进行跟踪。

**目标：** 让 `dsh-docker` 的 rescue 在「可选插件因原生绑定丢失而静默失效」时，既保得住可用回退点（A），又能自动补回缺失的绑定（B）。

**架构：** 新增一个共用内核 K（`binding-inventory.js`，输出目录内 `.node` 清单），A 用它给快照判级并改进 `rescue_prune_pinned` 的钉住策略（钉「最新 + 最完整」两份基线），B 用它把 live 相对参考基线缺失的 `.node` 从快照复制回来（零网络、不整树回滚）。内核定位采用 `librescue.sh` 内的懒解析，**完全不碰 entrypoint**。

**技术栈：** POSIX sh（`dash` 兼容）、Node.js 24（仅 K 使用）、既有 `scripts/t/test-*.sh` 黑盒测试框架（CI 门禁 1 自动收集）。

**规格：** `issues/2026-09-17-rescue-binding-guard.md`（计划论证以规格为准；执行者需同时阅读两者）

## 全局约束

- **不碰启动路径**：不修改 `entrypoint.sh` 的启动语义，不注入 `NODE_OPTIONS`，不加进程树守卫。
- **不整树回滚**：绝不调用 `rescue_restore` 替换依赖树；B 只复制单个缺失文件。
- **不覆盖已存在文件**：B 仅在目标**不存在**时复制。
- **失败绝不影响启动**：任何环节失败只写 `rescue.log`，与 `rescue_snapshot_baseline()` 同风格。
- **判据口径**：K 扫描 `<dir>` 下所有 `*.node`、**排除 `.pnpm/`**、**无深度限制**、匹配名字结尾（含符号链接），等价于 `find <dir> -name '*.node' -not -path '*/.pnpm/*'`。
- **钉住数公式**：`pinCount = min(2, max(1, RESCUE_KEEP - 1))`。默认 `RESCUE_KEEP=3` → 钉 2 份。
- **新环境变量**：`RESCUE_BINDING_HEAL`（默认 `on`）——控制 B 是否启用。
- **零网络依赖**：A/B 全部为本地文件操作。
- **既有测试不得变红**：`scripts/t/test-prune-pin-baseline.sh` 的 5 个用例必须**继续通过**（不得修改该文件的既有断言）。
- 测试脚本全通过时打印 `ALL-PASS`，失败时打印 `FAIL-<原因>` 并以非 0 退出；每个测试用 `mktemp -d` + `trap 'rm -rf "$T"' EXIT` 隔离。

---

### 任务 1：K 内核 `binding-inventory.js`

**文件：**
- 新建：`scripts/binding-inventory.js`
- 测试：`scripts/t/test-binding-inventory.sh`

**接口：**
- 依赖输入：无（纯新增）
- 对外产出：命令行工具 `node binding-inventory.js <dir> [--json]`
  - stdout：排序后的 `.node` 相对路径，每行一条；`--json` 时为一个 JSON 字符串数组
  - 退出码：`0` 成功（含目录不存在 → 输出空清单）；`2` 用法错误（缺少 `<dir>`）

- [ ] **步骤 1：编写失败的测试**

创建 `scripts/t/test-binding-inventory.sh`：

```sh
#!/bin/sh
# 黑盒测试：binding-inventory.js（rescue 原生绑定守护的内核 K）
#
# 契约：扫描 <dir> 下所有 *.node，排除 .pnpm/，无深度限制，名字结尾匹配（含符号链接）；
#       输出按字典序排序的相对路径；目录不存在时输出空清单且 exit 0；缺参数时 exit 2。
#
# 用法: sh scripts/t/test-binding-inventory.sh    （全通过打印 ALL-PASS）
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
K="$HERE/../binding-inventory.js"
[ -f "$K" ] || { echo "FAIL-kernel-missing: $K"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail() { echo "FAIL-$1"; exit 1; }

# 造一棵树：a 与 b 是有效绑定；.pnpm/c 是虚拟 store 副本（必须排除）；d/deep/e 验证无深度限制
D="$T/nm"
mkdir -p "$D/a/build/Release" "$D/b/prebuilds" "$D/.pnpm/c/build" "$D/d/deep/deeper"
: > "$D/a/build/Release/x.node"
: > "$D/b/prebuilds/y.node"
: > "$D/.pnpm/c/build/zzz.node"
: > "$D/d/deep/deeper/z.node"
: > "$D/notabinding.js"

# 1) 正常目录：排序输出、排除 .pnpm、包含深层
out=$(node "$K" "$D") || fail "exit-nonzero-on-normal-dir"
want="a/build/Release/x.node
b/prebuilds/y.node
d/deep/deeper/z.node"
[ "$out" = "$want" ] || fail "inventory-wrong:[$out]"

# 2) --json 输出合法 JSON 数组且内容一致
j=$(node "$K" "$D" --json) || fail "json-exit-nonzero"
[ "$j" = '["a/build/Release/x.node","b/prebuilds/y.node","d/deep/deeper/z.node"]' ] || fail "json-wrong:[$j]"

# 3) 空目录 → 空清单、exit 0
mkdir -p "$T/empty"
[ -z "$(node "$K" "$T/empty")" ] || fail "empty-dir-not-empty"

# 4) 不存在的目录 → 空清单、exit 0（降级而非报错）
[ -z "$(node "$K" "$T/nonexistent")" ] || fail "missing-dir-not-empty"
node "$K" "$T/nonexistent" >/dev/null 2>&1 || fail "missing-dir-nonzero-exit"

# 5) 缺参数 → exit 2
node "$K" >/dev/null 2>&1
[ $? -eq 2 ] || fail "usage-exit-not-2"

# 6) 无 .node 的目录 → 空清单
mkdir -p "$T/nojs"; : > "$T/nojs/a.js"
[ -z "$(node "$K" "$T/nojs")" ] || fail "no-node-files-not-empty"

echo ALL-PASS
```

- [ ] **步骤 2：运行测试并确认其失败**

运行：`sh scripts/t/test-binding-inventory.sh`
预期：`FAIL-kernel-missing: .../scripts/binding-inventory.js`（文件尚不存在）

- [ ] **步骤 3：编写最小实现**

创建 `scripts/binding-inventory.js`：

```js
#!/usr/bin/env node
// 原生绑定清单（rescue 原生绑定守护的内核 K）。
//
// 用法: node binding-inventory.js <dir> [--json]
//   stdout: 排序后的 .node 相对路径，每行一条；--json 时为 JSON 字符串数组
//   退出码: 0 = 成功（目录不存在时输出空清单）；2 = 用法错误
//
// 契约（与规格 §3 一致）：扫描 <dir> 下所有 *.node、排除 .pnpm/、无深度限制、
// 按名字结尾匹配（因此符号链接也算），等价于
//   find <dir> -name '*.node' -not -path '*/.pnpm/*'
// 纯本地只读，无网络、无写入。
'use strict';
const fs = require('node:fs');
const path = require('node:path');

function walk(root) {
  const out = [];
  const stack = [''];                 // 显式栈：避免深目录递归爆栈
  while (stack.length) {
    const rel = stack.pop();
    const abs = rel ? path.join(root, rel) : root;
    let entries;
    try {
      entries = fs.readdirSync(abs, { withFileTypes: true });
    } catch {
      continue;                       // 不可读目录（权限/竞态）：跳过，不中断整次扫描
    }
    for (const e of entries) {
      const r = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) {
        // Dirent.isDirectory() 对「指向目录的符号链接」返回 false，故天然不会跟随、不会成环
        if (e.name !== '.pnpm') stack.push(r);
      } else if (e.name.endsWith('.node')) {
        out.push(r);                  // 普通文件与符号链接都计（与 find 语义一致）
      }
    }
  }
  return out;
}

function main(argv) {
  const wantJson = argv.includes('--json');
  const dir = argv.find((a) => !a.startsWith('--'));
  if (!dir) {
    process.stderr.write('usage: binding-inventory.js <dir> [--json]\n');
    process.exit(2);
  }
  const list = fs.existsSync(dir) ? walk(dir).sort() : [];
  if (wantJson) {
    process.stdout.write(JSON.stringify(list) + '\n');
  } else if (list.length) {
    process.stdout.write(list.join('\n') + '\n');
  }
  process.exit(0);
}

main(process.argv.slice(2));
```

- [ ] **步骤 4：运行测试并确认其通过**

运行：`sh scripts/t/test-binding-inventory.sh`
预期：`ALL-PASS`

- [ ] **步骤 5：与既有 `find` 口径交叉核对（真机）**

运行：
```sh
sh -c 'a=$(find /data/dsh/profiles/web/node_modules -name "*.node" -not -path "*/.pnpm/*" | sed "s|.*/node_modules/||" | sort); b=$(node scripts/binding-inventory.js /data/dsh/profiles/web/node_modules); [ "$a" = "$b" ] && echo SAME || { echo DIFF; diff <(printf "%s" "$a") <(printf "%s" "$b") | head; }'
```
预期：`SAME`（若为 `DIFF` 则说明 K 与 `find` 口径不一致，必须先修 K 再继续）

- [ ] **步骤 6：提交**

```bash
git add scripts/binding-inventory.js scripts/t/test-binding-inventory.sh
git commit -m "feat(rescue): 新增原生绑定清单内核 binding-inventory.js

rescue 原生绑定守护的内核：扫描目录内 *.node（排除 .pnpm/、无深度限制），
输出排序相对路径清单。用于给快照判级（A）与比对 live 缺失（B）。

契约与 find -name '*.node' -not -path '*/.pnpm/*' 完全一致（已真机交叉核对）。
纯本地只读，无网络无写入；目录不存在时输出空清单并 exit 0。"
```

---

### 任务 2：内核懒解析与 shell 包装

**文件：**
- 修改：`scripts/librescue.sh`（在 `rescue_log()` 定义之后、`profile_dir()` 之前插入两个函数，约第 68 行）
- 测试：`scripts/t/test-librescue-binding.sh`

**接口：**
- 依赖输入：任务 1 的 `scripts/binding-inventory.js`
- 对外产出：
  - `rescue_binding_kernel()` → stdout 打印内核绝对路径，返回 0；找不到返回 1（并缓存进 `RESCUE_BINDING_KERNEL`）
  - `rescue_binding_inventory <dir>` → stdout 打印清单（每行一条）；内核不可用或执行失败时输出空并返回 0

- [ ] **步骤 1：编写失败的测试**

创建 `scripts/t/test-librescue-binding.sh`：

```sh
#!/bin/sh
# 黑盒测试：原生绑定内核的懒解析与 shell 包装（rescue_binding_kernel / rescue_binding_inventory）
#
# 契约：
#   - rescue_binding_kernel 按候选列表定位内核；显式 RESCUE_BINDING_KERNEL 优先级最高
#   - rescue_binding_inventory 输出内核清单；内核缺失/执行失败时输出空并返回 0（降级，不报错）
#
# 用法: sh scripts/t/test-librescue-binding.sh   （全通过打印 ALL-PASS）
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail() { echo "FAIL-$1"; exit 1; }

export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME/profiles/web"
printf %s '{"name":"web"}' > "$DSH_HOME/profiles/web/package.json"
RESCUE_PROFILE=web
. "$HERE/../librescue.sh"

# 造一棵含 .node 的目录
D="$T/nm"; mkdir -p "$D/pkg/build/Release"
: > "$D/pkg/build/Release/a.node"

# 1) 显式指定内核时优先使用它
RESCUE_BINDING_KERNEL=""                 # 先清空缓存
export RESCUE_BINDING_KERNEL="$HERE/../binding-inventory.js"
got=$(rescue_binding_kernel) || fail "kernel-not-found-via-explicit-var"
[ "$got" = "$HERE/../binding-inventory.js" ] || fail "kernel-explicit-ignored:[$got]"

# 2) 包装输出清单
out=$(rescue_binding_inventory "$D") || fail "inventory-wrapper-nonzero"
[ "$out" = "pkg/build/Release/a.node" ] || fail "inventory-wrapper-wrong:[$out]"

# 3) 内核缺失 → 输出空、返回 0（降级而非报错）
RESCUE_BINDING_KERNEL="$T/definitely-missing.js"
out=$(rescue_binding_inventory "$D") || fail "degrade-nonzero"
[ -z "$out" ] || fail "degrade-not-empty:[$out]"

# 4) rescue_binding_kernel 在候选全不存在时返回非 0
( unset RESCUE_BINDING_KERNEL
  # 用一个不含内核的目录冒充 $HERE，令所有候选落空
  HERE="$T/nowhere"
  RESCUE_BINDING_KERNEL=""
  rescue_binding_kernel >/dev/null 2>&1 && exit 1 || exit 0 ) || fail "kernel-should-fail-when-missing"

echo ALL-PASS
```

- [ ] **步骤 2：运行测试并确认其失败**

运行：`sh scripts/t/test-librescue-binding.sh`
预期：`FAIL-kernel-not-found-via-explicit-var`（`rescue_binding_kernel` 尚未定义 → 命令未找到）

- [ ] **步骤 3：编写最小实现**

在 `scripts/librescue.sh` 中，紧跟 `rescue_log()` 定义之后插入：

```sh
# ---- 原生绑定内核（rescue 原生绑定守护）----
# 懒解析：首次调用时按候选列表定位 binding-inventory.js 并缓存进 RESCUE_BINDING_KERNEL。
# 为什么不用 entrypoint 预解析：librescue.sh 被 .（source）时 $0 是调用者，无法自定位；
# 且 entrypoint / rescue CLI / scripts/t/* 三种上下文的 $HERE 各不相同。懒解析覆盖三者，
# 并且完全不碰容器启动路径（规格 §1.4 红线）。
rescue_binding_kernel() {
  if [ -n "${RESCUE_BINDING_KERNEL:-}" ] && [ -f "${RESCUE_BINDING_KERNEL:-}" ]; then
    printf '%s' "$RESCUE_BINDING_KERNEL"; return 0
  fi
  for _bk_c in /opt/dsh-rescue/binding-inventory.js \
               "$HERE/binding-inventory.js" \
               "$HERE/scripts/binding-inventory.js" \
               "$HERE/../binding-inventory.js"; do
    if [ -n "$_bk_c" ] && [ -f "$_bk_c" ]; then
      RESCUE_BINDING_KERNEL="$_bk_c"
      printf '%s' "$_bk_c"; return 0
    fi
  done
  return 1
}

# 原生绑定清单。输出排序后的 .node 相对路径（每行一条）；
# 内核不可用或执行失败时输出空并返回 0 —— 调用方据此降级，绝不因内核问题中断。
rescue_binding_inventory() {
  _bi_dir="$1"
  _bi_k=$(rescue_binding_kernel 2>/dev/null) || return 0
  [ -n "$_bi_k" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  node "$_bi_k" "$_bi_dir" 2>/dev/null || true
  return 0
}
```

- [ ] **步骤 4：运行测试并确认其通过**

运行：`sh scripts/t/test-librescue-binding.sh`
预期：`ALL-PASS`

- [ ] **步骤 5：确认既有测试未被破坏**

运行：`sh scripts/t/test-librescue.sh && sh scripts/t/test-prune-pin-baseline.sh`
预期：两个都打印 `ALL-PASS`（本任务只新增函数，未改既有行为）

- [ ] **步骤 6：提交**

```bash
git add scripts/librescue.sh scripts/t/test-librescue-binding.sh
git commit -m "feat(rescue): 原生绑定内核的懒解析与 shell 包装

rescue_binding_kernel 按候选列表定位 binding-inventory.js（显式变量 > 镜像路径 >
\$HERE 三态），rescue_binding_inventory 输出清单并在内核缺失时降级为空、返回 0。

刻意不用 entrypoint 预解析：既不依赖调用上下文，也完全不碰启动路径。"
```

---

### 任务 3：快照 meta 记录绑定完整性

**文件：**
- 修改：`scripts/librescue.sh`（`rescue_snapshot()` 的 meta 构造，约第 155-161 行）
- 测试：`scripts/t/test-snapshot-binding-meta.sh`

**接口：**
- 依赖输入：任务 2 的 `rescue_binding_inventory()`
- 对外产出：快照 `meta.json` 在可判定时追加两个字段
  - `"bindings":"<md5 of sorted list>"`、`"bindingCount":<N>`
  - 内核不可用时**不写这两个字段**（旧格式，见规格 §4）

- [ ] **步骤 1：编写失败的测试**

创建 `scripts/t/test-snapshot-binding-meta.sh`：

```sh
#!/bin/sh
# 黑盒测试：rescue_snapshot 在 meta 中记录绑定完整性
#
# 契约：
#   - 内核可用时 meta.json 含 "bindings" 与 "bindingCount"，且值稳定可复现
#   - bindingCount 等于该快照 node_modules 内 .node 数量（排除 .pnpm/）
#   - 内核不可用时 meta.json 不含这两个字段（旧格式，向后兼容）
#
# 用法: sh scripts/t/test-snapshot-binding-meta.sh   （全通过打印 ALL-PASS）
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail() { echo "FAIL-$1"; exit 1; }

export DSH_HOME="$T/home"
PD="$DSH_HOME/profiles/web"
mkdir -p "$PD/node_modules/pkg/build/Release"
printf %s '{"name":"web"}' > "$PD/package.json"
: > "$PD/node_modules/pkg/build/Release/a.node"
: > "$PD/node_modules/pkg/build/Release/b.node"
RESCUE_PROFILE=web
. "$HERE/../librescue.sh"
export RESCUE_BINDING_KERNEL="$HERE/../binding-inventory.js"

# 1) 内核可用：记录 bindings + bindingCount
s1=$(REASON_SNAPSHOT='boot-healthy baseline' rescue_snapshot) || fail "snapshot-failed"
m=$(cat "$RESCUE_DIR/$s1/meta.json")
printf '%s' "$m" | grep -q '"bindingCount":2' || fail "bindingCount-wrong:[$m]"
printf '%s' "$m" | grep -q '"bindings":"' || fail "bindings-missing:[$m]"

# 2) 值可复现：同一棵树再拍一次，bindings 哈希相同
s2=$(REASON_SNAPSHOT='boot-healthy baseline' rescue_snapshot) || fail "snapshot2-failed"
b1=$(sed -n 's/.*"bindings":"\([^"]*\)".*/\1/p' "$RESCUE_DIR/$s1/meta.json")
b2=$(sed -n 's/.*"bindings":"\([^"]*\)".*/\1/p' "$RESCUE_DIR/$s2/meta.json")
[ "$b1" = "$b2" ] || fail "bindings-not-reproducible:[$b1]vs[$b2]"

# 3) 内核不可用：不写这两个字段（旧格式）
rm -rf "$RESCUE_DIR"/snap-*
RESCUE_BINDING_KERNEL="$T/missing.js"
s3=$(REASON_SNAPSHOT='boot-healthy baseline' rescue_snapshot) || fail "snapshot3-failed"
m3=$(cat "$RESCUE_DIR/$s3/meta.json")
printf '%s' "$m3" | grep -q '"bindingCount"' && fail "should-omit-when-kernel-missing:[$m3]"
[ -n "$(sed -n 's/.*"treeHash":"\([^"]*\)".*/\1/p' "$RESCUE_DIR/$s3/meta.json")" ] \
  || fail "treeHash-lost-when-kernel-missing"

echo ALL-PASS
```

- [ ] **步骤 2：运行测试并确认其失败**

运行：`sh scripts/t/test-snapshot-binding-meta.sh`
预期：`FAIL-bindingCount-wrong:[...]`（meta 尚无该字段）

- [ ] **步骤 3：编写最小实现**

在 `scripts/librescue.sh` 的 `rescue_snapshot()` 中，把原有 meta 构造改为先算 `_extra` 再拼接。找到这一行：

```sh
  meta="{\"created\":\"$(date -Iseconds)\",\"reason\":\"$reason\",\"dsh\":\"$(dsh --version 2>/dev/null || echo unknown)\",\"profile\":\"$RESCUE_PROFILE\",\"mode\":\"$snap_mode\",\"treeHash\":\"$th\"}"
```

替换为：

```sh
  # 绑定完整性：记录 .node 清单的哈希与数量，供 A（钉住最完整基线）与 B（比对缺失）使用。
  # 内核不可用时不写这两个字段 —— 该快照按「未知完整性」处理，仍可被钉为「最新一份基线」。
  _snap_extra=''
  if rescue_binding_kernel >/dev/null 2>&1; then
    _snap_bi=$(rescue_binding_inventory "$RESCUE_DIR/$snap/node_modules")
    _snap_bc=$(printf '%s\n' "$_snap_bi" | grep -c . 2>/dev/null || printf '0')
    _snap_bs=$(printf '%s' "$_snap_bi" | md5sum | cut -d' ' -f1)
    _snap_extra=",\"bindings\":\"$_snap_bs\",\"bindingCount\":$_snap_bc"
  fi
  meta="{\"created\":\"$(date -Iseconds)\",\"reason\":\"$reason\",\"dsh\":\"$(dsh --version 2>/dev/null || echo unknown)\",\"profile\":\"$RESCUE_PROFILE\",\"mode\":\"$snap_mode\",\"treeHash\":\"$th\"$_snap_extra}"
```

- [ ] **步骤 4：运行测试并确认其通过**

运行：`sh scripts/t/test-snapshot-binding-meta.sh`
预期：`ALL-PASS`

- [ ] **步骤 5：确认既有测试未被破坏**

运行：`sh scripts/t/test-prune-pin-baseline.sh && sh scripts/t/test-snapshot-integrity.sh && sh scripts/t/test-baseline-snapshot.sh`
预期：三个都打印 `ALL-PASS`（新增字段为追加，不改变既有 meta 语义）

- [ ] **步骤 6：提交**

```bash
git add scripts/librescue.sh scripts/t/test-snapshot-binding-meta.sh
git commit -m "feat(rescue): 快照 meta 记录原生绑定完整性

拍快照时记录 bindings（清单哈希）与 bindingCount，供 A 判定「最完整基线」、
B 比对 live 缺失。内核不可用时两字段均不写（旧格式向后兼容，按未知完整性处理）。"
```

---

### 任务 4：方案 A —— 保留策略钉住「最新 + 最完整」

**文件：**
- 修改：`scripts/librescue.sh`
  - `rescue_prune_pinned()`（约第 184-196 行）：由返回单值改为**返回多行**
  - `rescue_prune_victim()`（约第 198-207 行）：由跳过单值改为**跳过名单中任一**
- 测试：`scripts/t/test-prune-pin-completeness.sh`

**接口：**
- 依赖输入：任务 3 写入的 `bindingCount` 字段
- 对外产出：
  - `rescue_prune_pinned()` → stdout 输出 1~2 行被钉住的快照名；**集合**语义（可多行）
  - `rescue_prune_victim <多行名单>` → 输出第一个不在名单中的最老快照名；都在名单中则返回 1
  - `rescue_prune()` **不需要改动**（它已把 `$pin` 原样透传给 victim）

- [ ] **步骤 1：编写失败的测试**

创建 `scripts/t/test-prune-pin-completeness.sh`：

```sh
#!/bin/sh
# 黑盒测试：prune 钉住「最新基线 + 最完整基线」（方案 A）
#
# 背景：原实现只钉最新一份 boot-healthy 基线。2026-09-17 真机事故中，最新的基线
# 已是坏态（缺 better_sqlite3.node），而唯一完好的旧基线反被选为 victim 删除 ——
# 回退点彻底丧失。本测试锁定新契约。
#
# 用法: sh scripts/t/test-prune-pin-completeness.sh   （全通过打印 ALL-PASS）
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME/profiles/web"
printf %s '{"name":"web"}' > "$DSH_HOME/profiles/web/package.json"
RESCUE_PROFILE=web
. "$HERE/../librescue.sh"
R=$RESCUE_DIR

fail() { echo "FAIL-$1"; exit 1; }

# $1=编号 $2=created $3=reason $4=bindingCount（可选）
mk_snap() {
  d="$R/snap-$1"; mkdir -p "$d"; printf x > "$d/package.json"
  bc=""
  [ -n "${4:-}" ] && bc=",\"bindings\":\"h$4\",\"bindingCount\":$4"
  printf '{"created":"%s","reason":"%s","dsh":"x","profile":"web","mode":"hardlink","treeHash":"t"%s}' \
    "$2" "$3" "$bc" > "$d/meta.json"
}
count_snaps() { c=0; for d in "$R"/snap-*; do [ -d "$d" ] && c=$((c+1)); done; printf '%s' "$c"; }

# ---- 1) 本次事故回归：最新基线坏（bindingCount 小），旧基线完好（大）→ 旧基线必须留下 ----
# 注意：必须放 4 份才能触发 KEEP=3 的淘汰（rescue_prune 仅在 count > KEEP 时才动手）。
rm -rf "$R"/snap-*
mk_snap 0100 "2026-09-17T18:00:00+0800" "boot-healthy baseline" 28   # 完好（旧）
mk_snap 0101 "2026-09-17T18:38:00+0800" "pre-clean"                  # 场景快照（应被淘汰）
mk_snap 0102 "2026-09-17T19:20:00+0800" "boot-healthy baseline" 27   # 坏态（新）
mk_snap 0103 "2026-09-17T19:35:00+0800" "pre-clean"                  # 额外场景快照
RESCUE_KEEP=3
rescue_prune
[ -d "$R/snap-0100" ] || fail "complete-old-baseline-evicted"
[ -d "$R/snap-0102" ] || fail "newest-baseline-evicted"
[ ! -d "$R/snap-0101" ] || fail "scene-snapshot-should-be-evicted"
[ -d "$R/snap-0103" ] || fail "newest-snapshot-evicted"

# ---- 2) 钉住数受 KEEP 约束：KEEP=2 → pinCount=1，只钉最新基线（与既有行为一致，不超额）----
rm -rf "$R"/snap-*
mk_snap 0110 "2026-09-17T18:00:00+0800" "boot-healthy baseline" 28   # 更完整但更旧
mk_snap 0111 "2026-09-17T19:00:00+0800" "boot-healthy baseline" 27   # 最新基线
mk_snap 0112 "2026-09-17T19:30:00+0800" "plugin add x"               # 触发淘汰
RESCUE_KEEP=2
rescue_prune
[ "$(count_snaps)" = 2 ] || fail "keep2-window-violated:$(count_snaps)"
[ -d "$R/snap-0111" ] || fail "keep2-newest-baseline-evicted"
[ -d "$R/snap-0112" ] || fail "keep2-newest-evicted"
[ ! -d "$R/snap-0110" ] || fail "keep2-pincount-must-be-1"

# ---- 3) KEEP=1 且全是基线：必须仍能减员到 1（不因钉 2 份而超额/卡死）----
rm -rf "$R"/snap-*
mk_snap 0120 "2026-09-17T18:00:00+0800" "boot-healthy baseline" 28
mk_snap 0121 "2026-09-17T19:00:00+0800" "boot-healthy baseline" 27
mk_snap 0122 "2026-09-17T20:00:00+0800" "boot-healthy baseline" 27
RESCUE_KEEP=1
rescue_prune
[ "$(count_snaps)" = 1 ] || fail "keep1-overcount:$(count_snaps)"
[ -d "$R/snap-0122" ] || fail "keep1-kept-wrong-one"

# ---- 4) 无 bindingCount 字段（旧快照）：退化为「只钉最新」（并列取较新）----
rm -rf "$R"/snap-*
mk_snap 0130 "2026-09-17T18:00:00+0800" "boot-healthy baseline"
mk_snap 0131 "2026-09-17T19:00:00+0800" "boot-healthy baseline"
mk_snap 0132 "2026-09-17T20:00:00+0800" "plugin add x"
RESCUE_KEEP=2
rescue_prune
[ -d "$R/snap-0131" ] || fail "legacy-newest-baseline-evicted"
[ ! -d "$R/snap-0130" ] || fail "legacy-older-baseline-should-be-evictable"

echo ALL-PASS
```

- [ ] **步骤 2：运行测试并确认其失败**

运行：`sh scripts/t/test-prune-pin-completeness.sh`
预期：`FAIL-complete-old-baseline-evicted`（旧实现只钉最新一份，完好的旧基线被删）

- [ ] **步骤 3：编写最小实现**

在 `scripts/librescue.sh` 中，用下述实现**整体替换** `rescue_prune_pinned()` 与 `rescue_prune_victim()`：

```sh
# 本轮要钉住的快照（可多份，每行一个）。
# 候选只取 reason 形如 boot-healthy* 的「被证明能启动过」的基线：
#   ① 最新一份（保持既有行为，兼容旧快照）
#   ② bindingCount 最大的一份（最完整；并列取较新者）
# 份数上限 pinCount = min(2, max(1, RESCUE_KEEP-1))：必须给淘汰留至少 1 个位置，
# 否则 rescue_prune_victim 会因「全部被钉」而返回 1、rescue_prune 随即 break，
# 结果是保留数超出 KEEP 窗口（既有测试用例④即锁定这一约束）。
rescue_prune_pinned() {
  _pp_keep="${RESCUE_KEEP:-3}"
  _pp_max=$(( _pp_keep - 1 ))
  [ "$_pp_max" -ge 1 ] || _pp_max=1
  [ "$_pp_max" -le 2 ] || _pp_max=2

  _pp_newest=''
  _pp_best=''
  _pp_best_cnt=-1
  # 反序：最新 -> 最老
  for d in $(rescue_snapshot_list_by_time | sed '1!G;h;$!d'); do
    n=${d##*/}
    _pp_m=$(rescue_meta_read "$n" 2>/dev/null || true)
    _pp_r=$(printf '%s' "$_pp_m" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p')
    case "$_pp_r" in boot-healthy*) ;; *) continue ;; esac
    [ -n "$_pp_newest" ] || _pp_newest="$n"
    _pp_c=$(printf '%s' "$_pp_m" | sed -n 's/.*"bindingCount":\([0-9]*\).*/\1/p')
    [ -n "$_pp_c" ] || _pp_c=-1
    if [ "$_pp_c" -gt "$_pp_best_cnt" ]; then _pp_best_cnt="$_pp_c"; _pp_best="$n"; fi
  done

  [ -n "$_pp_newest" ] && printf '%s\n' "$_pp_newest"
  if [ "$_pp_max" -ge 2 ] && [ -n "$_pp_best" ] && [ "$_pp_best" != "$_pp_newest" ]; then
    printf '%s\n' "$_pp_best"
  fi
  return 0
}

# 本轮淘汰谁：从最老往最新取第一个「不在钉住名单 $1 中」的快照；都在名单中时返回 1（调用方 break）。
# 名单为多行/空格分隔的多个快照名。不能直接用 rescue_snapshot_oldest()：钉住项可能恰好
# 就是最老那份，那样每轮都会选中它 —— 删不掉却照减计数，结果是悄悄少删甚至死循环。
rescue_prune_victim() {
  for d in $(rescue_snapshot_list_by_time); do
    n=${d##*/}
    _pv_pinned=0
    for _pv_p in $1; do
      if [ "$n" = "$_pv_p" ]; then _pv_pinned=1; break; fi
    done
    [ "$_pv_pinned" = 1 ] && continue
    printf '%s' "$n"
    return 0
  done
  return 1
}
```

- [ ] **步骤 4：运行测试并确认其通过**

运行：`sh scripts/t/test-prune-pin-completeness.sh`
预期：`ALL-PASS`

- [ ] **步骤 5：确认既有 prune 测试未被破坏（关键回归门禁）**

运行：`sh scripts/t/test-prune-pin-baseline.sh`
预期：`ALL-PASS`（其 5 个用例全部保持通过——KEEP=1/2 时 pinCount 恰为 1，行为与旧实现一致）

- [ ] **步骤 6：确认 rescue 快照相关测试整体未回归**

运行：`sh scripts/t/test-snapshot-order.sh && sh scripts/t/test-prune-pin-baseline.sh && sh scripts/t/test-librescue-state.sh`
预期：三个都打印 `ALL-PASS`

- [ ] **步骤 7：提交**

```bash
git add scripts/librescue.sh scripts/t/test-prune-pin-completeness.sh
git commit -m "feat(rescue): prune 钉住「最新 + 最完整」基线（方案 A）

原实现只钉最新一份 boot-healthy 基线。2026-09-17 真机事故里最新基线已是坏态
（缺 better_sqlite3.node），唯一完好的旧基线反被淘汰，回退点彻底丧失。

改为钉住至多两份：最新 + bindingCount 最大。份数上限 min(2, max(1, KEEP-1))
保证留出淘汰位，KEEP=1/2 时恰为 1 份、与旧行为一致 —— 既有
test-prune-pin-baseline.sh 5 个用例全部保持通过。"
```

---

### 任务 5：方案 B —— 启动后精准修复

**文件：**
- 修改：`scripts/librescue.sh`（在 `rescue_verify()` 之后插入 `rescue_binding_heal()`，约第 518 行）
- 修改：`scripts/rescue-supervise.sh:348`（在 `rescue_snapshot_baseline` 之后接线）
- 测试：`scripts/t/test-binding-heal.sh`

**接口：**
- 依赖输入：任务 3 的 `bindingCount`、任务 4 保住的完好基线、任务 2 的 `rescue_binding_inventory()`
- 对外产出：`rescue_binding_heal()` → 无 stdout 输出；副作用为「把 live 缺失的 `.node` 从参考基线复制回来」；**恒返回 0**

- [ ] **步骤 1：编写失败的测试**

创建 `scripts/t/test-binding-heal.sh`：

```sh
#!/bin/sh
# 黑盒测试：rescue_binding_heal（方案 B，启动后精准修复）
#
# 契约：
#   - 参考基线选 bindingCount 最大的 boot-healthy*（并列取较新）
#   - 只补 live 中【不存在】的 .node；已存在者一律不覆盖（红线）
#   - 参考源不可信（rescue_verify 失败）时拒绝使用、不做任何写入
#   - RESCUE_BINDING_HEAL=off 时不执行任何写操作
#   - 无可用参考基线 / 内核缺失时优雅降级，返回 0
#
# 用法: sh scripts/t/test-binding-heal.sh   （全通过打印 ALL-PASS）
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail() { echo "FAIL-$1"; exit 1; }

export DSH_HOME="$T/home"
PD="$DSH_HOME/profiles/web"
RESCUE_PROFILE=web
. "$HERE/../librescue.sh"
export RESCUE_BINDING_KERNEL="$HERE/../binding-inventory.js"

# 造 live（缺 a.node，存在 keep.node）与参考快照（含 a.node 与 keep.node）
setup() {
  rm -rf "$DSH_HOME" "$RESCUE_DIR"; mkdir -p "$DSH_HOME/profiles/web" "$RESCUE_DIR"
  PD="$DSH_HOME/profiles/web"
  mkdir -p "$PD/node_modules/pkg/build/Release"
  printf %s '{"name":"web"}' > "$PD/package.json"
  printf 'LIVE-KEEP' > "$PD/node_modules/pkg/build/Release/keep.node"
  # 参考快照：含两个绑定
  d="$RESCUE_DIR/snap-1000"; mkdir -p "$d/node_modules/pkg/build/Release"
  printf x > "$d/package.json"
  printf 'REF-A' > "$d/node_modules/pkg/build/Release/a.node"
  printf 'REF-KEEP' > "$d/node_modules/pkg/build/Release/keep.node"
  # treeHash 必须与快照实际内容一致，否则 rescue_verify 会判「已被写坏」
  th=$(snapshot_tree_hash "$d/node_modules")
  printf '{"created":"2026-09-17T18:00:00+0800","reason":"boot-healthy baseline","dsh":"x","profile":"web","mode":"hardlink","treeHash":"%s","bindings":"h2","bindingCount":2}' "$th" > "$d/meta.json"
}

# ---- 1) 补齐缺失绑定，且不覆盖已存在文件 ----
setup
rescue_binding_heal || fail "heal-returned-nonzero"
[ -f "$PD/node_modules/pkg/build/Release/a.node" ] || fail "missing-binding-not-restored"
[ "$(cat "$PD/node_modules/pkg/build/Release/a.node")" = "REF-A" ] || fail "restored-content-wrong"
[ "$(cat "$PD/node_modules/pkg/build/Release/keep.node")" = "LIVE-KEEP" ] || fail "existing-file-was-overwritten"

# ---- 2) 参考源不可信（treeHash 不符）→ 拒绝使用、不写入 ----
setup
sed -i 's/"treeHash":"[^"]*"/"treeHash":"BROKEN"/' "$RESCUE_DIR/snap-1000/meta.json"
rescue_binding_heal || fail "heal-untrusted-nonzero"
[ ! -f "$PD/node_modules/pkg/build/Release/a.node" ] || fail "heal-must-refuse-untrusted-source"

# ---- 3) 开关 off → 不写入 ----
setup
RESCUE_BINDING_HEAL=off rescue_binding_heal || fail "heal-off-nonzero"
[ ! -f "$PD/node_modules/pkg/build/Release/a.node" ] || fail "heal-off-should-not-write"

# ---- 4) 无可用参考基线（无 bindingCount 字段）→ 降级、返回 0 ----
setup
sed -i 's/,"bindings":"h2","bindingCount":2//' "$RESCUE_DIR/snap-1000/meta.json"
rescue_binding_heal || fail "heal-no-ref-nonzero"
[ ! -f "$PD/node_modules/pkg/build/Release/a.node" ] || fail "heal-should-skip-without-ref"

# ---- 5) 内核缺失 → 降级、返回 0 ----
setup
RESCUE_BINDING_KERNEL="$T/missing.js" rescue_binding_heal || fail "heal-no-kernel-nonzero"
[ ! -f "$PD/node_modules/pkg/build/Release/a.node" ] || fail "heal-should-skip-without-kernel"

echo ALL-PASS
```

- [ ] **步骤 2：运行测试并确认其失败**

运行：`sh scripts/t/test-binding-heal.sh`
预期：`FAIL-heal-returned-nonzero`（`rescue_binding_heal` 尚未定义）

- [ ] **步骤 3：编写最小实现**

在 `scripts/librescue.sh` 的 `rescue_verify()` 函数**之后**插入：

```sh
# 启动后精准修复（方案 B）：把 live 相对参考基线缺失的原生绑定从快照复制回来。
#
# 为什么不用 rescue_restore：整树回滚会静默丢掉用户此后安装的插件（规格 §1.4 红线）。
# 为什么不下载：各包 prebuild 源不同、无法通用化，且网络本身可能正是故障根因。
#
# 失败安全：任何环节失败只写 rescue.log，恒返回 0，绝不影响启动
#（与紧邻的 rescue_snapshot_baseline 同风格）。
rescue_binding_heal() {
  [ "${RESCUE_BINDING_HEAL:-on}" = on ] || return 0
  rescue_binding_kernel >/dev/null 2>&1 || {
    rescue_log 'binding-heal: kernel unavailable, skipped'; return 0; }

  _bh_pdir=$(profile_dir)
  [ -d "$_bh_pdir/node_modules" ] || return 0

  # 选参考基线：bindingCount 最大的 boot-healthy*（并列取较新；无该字段者不参与）
  _bh_ref=''; _bh_cnt=-1
  for d in $(rescue_snapshot_list_by_time | sed '1!G;h;$!d'); do
    n=${d##*/}
    _bh_m=$(rescue_meta_read "$n" 2>/dev/null || true)
    _bh_r=$(printf '%s' "$_bh_m" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p')
    case "$_bh_r" in boot-healthy*) ;; *) continue ;; esac
    _bh_c=$(printf '%s' "$_bh_m" | sed -n 's/.*"bindingCount":\([0-9]*\).*/\1/p')
    [ -n "$_bh_c" ] || continue
    if [ "$_bh_c" -gt "$_bh_cnt" ]; then _bh_cnt="$_bh_c"; _bh_ref="$n"; fi
  done
  if [ -z "$_bh_ref" ]; then
    rescue_log 'binding-heal: no reference baseline, skipped'; return 0
  fi

  # 源可信性：复用既有 rescue_verify（拦住 hardlink 快照被 live 就地写坏的情况）
  if ! rescue_verify "$_bh_ref" >/dev/null 2>&1; then
    rescue_log "binding-heal: reference $_bh_ref untrusted, skipped"; return 0
  fi

  _bh_src="$RESCUE_DIR/$_bh_ref/node_modules"
  [ -d "$_bh_src" ] || { rescue_log "binding-heal: $_bh_ref has no node_modules, skipped"; return 0; }
  _bh_need=$(rescue_binding_inventory "$_bh_src")
  [ -n "$_bh_need" ] || return 0

  _bh_fixed=0
  for _bh_rel in $_bh_need; do
    case "$_bh_rel" in
      /*|*..*) continue ;;                       # 防御：拒绝绝对路径与路径穿越
    esac
    [ -e "$_bh_pdir/node_modules/$_bh_rel" ] && continue   # 红线：绝不覆盖已存在文件
    [ -e "$_bh_src/$_bh_rel" ] || continue
    mkdir -p "$(dirname "$_bh_pdir/node_modules/$_bh_rel")" 2>/dev/null || continue
    if cp "$_bh_src/$_bh_rel" "$_bh_pdir/node_modules/$_bh_rel" 2>/dev/null; then
      rescue_log "binding-heal: restored $_bh_rel (from $_bh_ref)"
      _bh_fixed=$((_bh_fixed + 1))
    else
      rescue_log "binding-heal: failed to restore $_bh_rel"
    fi
  done
  [ "$_bh_fixed" -gt 0 ] && rescue_log "binding-heal: restored $_bh_fixed binding(s) from $_bh_ref"
  return 0
}
```

- [ ] **步骤 4：运行测试并确认其通过**

运行：`sh scripts/t/test-binding-heal.sh`
预期：`ALL-PASS`

- [ ] **步骤 5：接线到监督循环**

在 `scripts/rescue-supervise.sh` 第 348 行 `rescue_snapshot_baseline` 之后、`rescue_state_write_lastrun` 之前插入一行：

```sh
      rescue_snapshot_baseline
      # 原生绑定守护：从保住的完好基线补回 live 缺失的 .node（失败不影响启动；见规格 §5）
      rescue_binding_heal
      rescue_state_write_lastrun "{...}"
```

（`{...}` 处保留原有该行内容不变，仅在其前插入注释与调用。）

- [ ] **步骤 6：确认接线正确且未破坏监督测试**

运行：
```sh
grep -n -A2 'rescue_snapshot_baseline$' scripts/rescue-supervise.sh
sh scripts/t/test-supervise-source.sh && sh scripts/t/test-supervise-loop.sh
```
预期：`grep` 显示 `rescue_binding_heal` 紧随其后；两个测试打印 `ALL-PASS`

- [ ] **步骤 7：提交**

```bash
git add scripts/librescue.sh scripts/rescue-supervise.sh scripts/t/test-binding-heal.sh
git commit -m "feat(rescue): healthy 后精准补回缺失的原生绑定（方案 B）

从「bindingCount 最大的 boot-healthy 基线」补回 live 缺失的 .node：
只补不覆盖、先经 rescue_verify 验源、拒绝路径穿越、逐文件容错，
任何失败只写 rescue.log 且恒返回 0，绝不影响启动。

刻意不用整树回滚（会丢用户此后装的插件），也不联网下载（各包 prebuild 源不同，
且网络可能正是故障根因）。接线于 rescue_snapshot_baseline 之后。"
```

---

### 任务 6：`rescue` CLI 子命令

**文件：**
- 修改：`scripts/rescue`（在 `snapshots)` 分支之后插入 `bindings)` 分支，约第 239 行）
- 测试：`scripts/t/test-rescue-cmds.sh`（追加用例）

**接口：**
- 依赖输入：任务 2 的 `rescue_binding_inventory()`、任务 4 的 `rescue_prune_pinned()`
- 对外产出：`rescue bindings` → 打印当前 live 的绑定数量与清单；`rescue bindings <snap>` → 打印指定快照的清单

- [ ] **步骤 1：编写失败的测试**

在 `scripts/t/test-rescue-cmds.sh` 的 `echo ALL-PASS` 之前**追加**：

```sh
# ---- bindings：列出 live 与指定快照的原生绑定 ----
# 该文件不 source librescue.sh，而是用 `sh "$RESCUE" ...` 调真实入口；
# 故这里只用 $DSH_HOME/$RESCUE/$fail，不引入 lib 侧 helper。
mkdir -p "$DSH_HOME/profiles/web/node_modules/bind-pkg/build/Release"
: > "$DSH_HOME/profiles/web/node_modules/bind-pkg/build/Release/live.node"
sh "$RESCUE" snapshot >/dev/null 2>&1 || fail bindings-snapshot-failed
latest=$(ls -1d "$DSH_HOME/.rescue"/snap-* 2>/dev/null | sort | tail -1)
[ -n "$latest" ] || fail bindings-no-snapshot

# live：应列出刚造的绑定
out=$(sh "$RESCUE" bindings) || { echo "$out"; fail bindings-live-nonzero; }
printf '%s' "$out" | grep -q 'bind-pkg/build/Release/live.node' || { echo "$out"; fail bindings-live-missing; }

# 指定快照：应列出快照内的同一绑定
out2=$(sh "$RESCUE" bindings "${latest##*/}") || { echo "$out2"; fail bindings-snap-nonzero; }
printf '%s' "$out2" | grep -q 'bind-pkg/build/Release/live.node' || { echo "$out2"; fail bindings-snap-missing; }

# 不存在的快照 → 非 0（并给出提示）
sh "$RESCUE" bindings snap-9999 >/dev/null 2>&1 && fail bindings-unknown-snapshot-should-fail
```

追加位置：该文件末尾 `echo 'ALL-PASS'` 这一行**之前**。

- [ ] **步骤 2：运行测试并确认其失败**

运行：`sh scripts/t/test-rescue-cmds.sh`
预期：`FAIL-bindings-cmd-nonzero`（`bindings` 子命令尚未实现，会落入 `*)` 未知命令分支）

- [ ] **步骤 3：编写最小实现**

在 `scripts/rescue` 的 `snapshots)` 分支结束（`;;`）之后插入：

```sh
  bindings)
    # 原生绑定自查（规格 §7.4）：无参 = live 插件树；带参 = 指定快照。
    # 便于运维确认「关键原生绑定是否齐全」，以及某份基线是否值得当回退点。
    _bg_target="${1:-live}"
    if [ "$_bg_target" = live ]; then
      _bg_dir="$(profile_dir)/node_modules"
    else
      _bg_dir="$RESCUE_DIR/$_bg_target/node_modules"
      [ -d "$_bg_dir" ] || { echo "bindings: 快照不存在或无 node_modules: $_bg_target"; exit 1; }
    fi
    _bg_list=$(rescue_binding_inventory "$_bg_dir")
    if [ -z "$_bg_list" ]; then
      echo "bindings: $_bg_target: no bindings (或内核不可用)"
      exit 0
    fi
    _bg_n=$(printf '%s\n' "$_bg_list" | grep -c .)
    echo "bindings: $_bg_target: $_bg_n 个原生绑定"
    printf '%s\n' "$_bg_list" | sed 's/^/  /'
    ;;
```

- [ ] **步骤 4：运行测试并确认其通过**

运行：`sh scripts/t/test-rescue-cmds.sh`
预期：`ALL-PASS`

- [ ] **步骤 5：真机自查（可选但推荐）**

运行：`RESCUE_BINDING_KERNEL="$PWD/scripts/binding-inventory.js" sh scripts/rescue bindings | head -5`
预期：打印 `bindings: live: 28 个原生绑定` 及路径清单

- [ ] **步骤 6：提交**

```bash
git add scripts/rescue scripts/t/test-rescue-cmds.sh
git commit -m "feat(rescue): 新增 bindings 子命令（原生绑定自查）

rescue bindings 列出 live 插件树的原生绑定；rescue bindings <snap> 列出指定快照。
用于运维确认关键绑定是否齐全，以及某份基线是否值得当回退点。"
```

---

### 任务 7：镜像登记与文档

**文件：**
- 修改：`Dockerfile`（第 117、121、122 行三处清单）
- 修改：`.env.example`（`RESCUE_BINDING_HEAL`）
- 修改：`docs/zh-CN/07-环境变量速查.md` + `docs/en/07-environment-variables.md`
- 修改：`docs/zh-CN/06-救援模式.md` + `docs/en/06-rescue-mode.md`
- 修改：`CHANGELOG.md`（`[Unreleased]`）

**接口：**
- 依赖输入：任务 1 的 `scripts/binding-inventory.js`、任务 5 的 `RESCUE_BINDING_HEAL`
- 对外产出：镜像内 `/opt/dsh-rescue/binding-inventory.js` 存在且可执行；文档登记新变量

- [ ] **步骤 1：登记进镜像并验证**

运行（改前先确认现状）：
```sh
grep -n 'binding-inventory' Dockerfile || echo 'NOT-YET-REGISTERED'
```

编辑 `Dockerfile`：

1. 第 117 行 `COPY` 清单加入 `scripts/binding-inventory.js`：

```dockerfile
COPY scripts/librescue.sh scripts/binding-inventory.js scripts/probe-ready.js scripts/diagnose.js scripts/report.js scripts/logtag.js scripts/logtee.js scripts/rescue-supervise.sh scripts/rescue /opt/dsh-rescue/
```

2. 第 121 行 `sed -i 's/\r$//'` 清单加入 `/opt/dsh-rescue/binding-inventory.js`
3. 第 122 行 `chmod +x` 清单加入 `/opt/dsh-rescue/binding-inventory.js`

- [ ] **步骤 2：编写并运行镜像门禁断言**

在 `scripts/t/test-compose-wiring.sh` 的 `echo ALL-PASS` 之前**追加**：

```sh
# ---- N) 原生绑定内核必须被登记进镜像（否则 rescue 守护在镜像内静默失效）----
grep -q 'scripts/binding-inventory.js' "$ROOT/Dockerfile" || fail "dockerfile-copy-missing-kernel"
grep -q '/opt/dsh-rescue/binding-inventory.js' "$ROOT/Dockerfile" || fail "dockerfile-chmod-sed-missing-kernel"
```

运行：`sh scripts/t/test-compose-wiring.sh`
预期：`ALL-PASS`（若 `fail()` 名称不同则沿用该文件既有断言函数）

- [ ] **步骤 3：登记环境变量并写文档**

在 `.env.example` 中 `RESCUE_SNAPSHOT_ON_HEALTHY` 附近追加：

```sh
# 原生绑定守护：healthy 后把 live 缺失的 .node 从保住的基线快照补回（默认 on）。
# 只补不覆盖、不联网、不整树回滚；失败只记 rescue.log，不影响启动。
#RESCUE_BINDING_HEAL=on
```

在 `docs/zh-CN/07-环境变量速查.md` 与 `docs/en/07-environment-variables.md` 的 rescue 段
各登记一行 `RESCUE_BINDING_HEAL`（默认 `on`、作用、关闭方式）。

在 `docs/zh-CN/06-救援模式.md` 与 `docs/en/06-rescue-mode.md` 说明：
保留策略现在钉住「最新 + 最完整」两份基线；healthy 后会补回缺失原生绑定；
`rescue bindings` 可用于自查。

在 `CHANGELOG.md` 的 `## [Unreleased]` 下新增：

```markdown
### Added
- **rescue 原生绑定守护**：修复「可选插件因原生绑定丢失而静默失效」无法被兜住的问题。
  - **保留策略**：`rescue_prune_pinned` 由「只钉最新基线」改为钉住「最新 + 最完整」两份
    （份数上限 `min(2, max(1, RESCUE_KEEP-1))`），避免唯一完好基线被挤出窗口。
  - **启动后精准修复**：healthy 后从保住的基线补回 live 缺失的 `.node`（只补不覆盖、
    零网络依赖、不整树回滚）；`RESCUE_BINDING_HEAL=off` 可关闭。
  - **`rescue bindings`**：列出 live 或指定快照的原生绑定，便于运维自查。
```

- [ ] **步骤 4：跑完整单测套件（CI 门禁 1）**

运行：
```sh
for f in scripts/t/test-*.sh; do printf '%s: ' "$f"; sh "$f" >/dev/null 2>&1 && echo PASS || echo FAIL; done | grep -v ': PASS' || echo ALL-PASS
```
预期：`ALL-PASS`（无任何一项 FAIL）。若有 FAIL，逐个运行定位。

- [ ] **步骤 5：提交**

```bash
git add Dockerfile .env.example CHANGELOG.md docs/ scripts/t/test-compose-wiring.sh
git commit -m "docs+chore(rescue): 登记原生绑定内核进镜像并补文档

Dockerfile 三处清单（COPY/sed/chmod）加入 binding-inventory.js，并加门禁断言防止
后续遗漏（漏登记会让守护在镜像内静默失效）。登记 RESCUE_BINDING_HEAL，
在 docs 06/07（中英）说明保留策略与修复行为，CHANGELOG 记录本次改动。"
```

---

## 完成标准

全部任务完成后，以下命令必须全绿：

```sh
for f in scripts/t/test-*.sh; do sh "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done; echo done
sh scripts/t/test-prune-pin-baseline.sh    # 既有 5 用例：必须仍 ALL-PASS
sh scripts/t/test-binding-inventory.sh
sh scripts/t/test-librescue-binding.sh
sh scripts/t/test-snapshot-binding-meta.sh
sh scripts/t/test-prune-pin-completeness.sh
sh scripts/t/test-binding-heal.sh
```

并且真机可用性自查通过：

```sh
node scripts/binding-inventory.js /data/dsh/profiles/web/node_modules | wc -l   # 期望 28
find /data/dsh/profiles/web/node_modules -name '*.node' -not -path '*/.pnpm/*' | wc -l  # 同上，须一致
```
