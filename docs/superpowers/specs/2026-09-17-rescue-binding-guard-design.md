# rescue 原生绑定守护 —— 可选插件静默失效的回退点保护与精准修复

> 状态：待实现
> 日期：2026-09-17
> 适用镜像：dsh-docker（构建时锁版本 + 容器内升级方案）
> 关系：**复评并部分推翻** `issues/2026-09-14-market-install-snapshot-plan.md` 的「暂不实施」结论（其自定的复评触发条件已满足，见 §1.3）

## 1. 背景与问题

2026-09-17 真机发生一次**未被任何现有机制发现、也未被任何机制兜住**的插件失效：

- `@memtensor/memos-local-plugin`（记忆插件）因 `better-sqlite3` 的**原生绑定文件丢失**而无法打开数据库；
- 该插件 `failOnStartupError:false` → **静默 fail-open**，dsh 进程照常运行、主页 200；
- 因此 rescue 的探针判 **healthy**、自愈**不触发**；
- 且唯一含完好绑定的基线快照已被 `RESCUE_KEEP` 挤出窗口，**无回退点可用**。

### 1.1 事件实测结论（真机复现，非推断）

**触发链**（证据：`.dsh-market/log.ndjson`）

```
17:24:53 / 18:19:29  dshmarket 更新 dsh-workbuddy-connect@0.5.4
   → pnpm install 在 onnxruntime-node@1.24.3 postinstall 失败
     （install-utils.js 的 downloadJson 用裸 https.get，不跟随 302
       ← api.nuget.org 被出口网络重定向到 nuget.azure.cn，实测 statusCode=302）
   → ERR_PNPM_EXECUTOR_LIFECYCLE_SCRIPT_FAILED
   → 连带：better-sqlite3 被重装后未生成 build/Release/better_sqlite3.node
   → 18:15 重启后新进程加载磁盘文件 → memos 报
     "Could not locate the bindings file" → fail-open → 插件整体失效
```

**探测盲区**（证据：`probe-ready.js` + 该次 boot 日志）

`probe-ready.js` 的 L4 已是「客户端激活层」探测，但其 4 个 `FAIL_BODY_PATTERNS`
（`Failed to load plugins` / `did not activate` / `dsh-boot-*` / `required startup failure`）
**全是"明确失败文案"**。而本次是**可选插件 + `failOnStartupError:false`** →
零文案、主页正常 → L1/L2/L3/L4 **全通过** → 判 healthy。

**回退点丧失**（证据：`rescue.log` + 快照内 `.node` 清单）

```
19:20:44 snapshot created snap-0068 (reason: boot-healthy baseline)
19:20:44 prune /data/dsh/.rescue/snap-0065      ← 18:00:13 的基线，含【完好】绑定
```

> 口径：`find <dir> -name '*.node' -not -path '*/.pnpm/*'`（与 §3 的 K 一致，**无深度限制**）。

| 快照 | reason | `.node` 数 | 判定 |
|---|---|---|---|
| snap-0065 | boot-healthy baseline | *(已删，无法验证)* | 18:00 boot 时 memos 可用 → 推断含完好绑定 |
| snap-0067 | pre-clean | 27 | 坏态 |
| snap-0068 | boot-healthy baseline | 27 | 坏态 |
| snap-0069 | boot-healthy baseline | **28** | 修复后 |
| live（当前）| — | **28** | 已恢复 |

**差异明细（live − snap-0068）只有一项**：

```
better-sqlite3/build/Release/better_sqlite3.node
```

即本次故障的**唯一缺失文件**——这也印证了判据的灵敏度：整棵依赖树的 28 个绑定里
只少 1 个，用"总数"很难发现，用"**集合差异**"则一目了然。

`rescue_prune_pinned()` 只钉住**最新一份** `boot-healthy*`（= snap-0068，坏态），
于是**唯一完好的旧基线 snap-0065 反被选为 victim 删除**。

### 1.2 三个机制性缺口

| # | 缺口 | 代码位置 | 后果 |
|---|---|---|---|
| **G1** | `rescue_prune_pinned()` 只钉「最新一份」基线 | `librescue.sh:184` | 完好的旧基线被挤掉，回退点丧失 |
| **G2** | 快照不记录「原生绑定是否齐全」 | `rescue_snapshot()` / `snapshot_tree_hash()` | 无法区分「完好基线」与「坏态基线」 |
| **G3** | 探针只匹配明确失败文案 | `probe-ready.js` `FAIL_BODY_PATTERNS` | 可选插件静默失效检测不到，自愈不触发 |

**关键洞察**：G2 的判据是**共用内核**——同一份清单既能支撑 A（钉住好快照），
也能支撑 B（发现 live 缺绑定）。

### 1.3 与 09-14 文档的关系（复评触发条件已满足）

`issues/2026-09-14-market-install-snapshot-plan.md` §10 自定的复评触发条件之一：

> `RESCUE_KEEP` 窗口被市场变更快照挤占，`boot-healthy` 基线缺失导致自愈退化
> （`rescue.log` 里可见 prune 掉 baseline）

**本次已实际命中**（§1.1 的 `prune /data/dsh/.rescue/snap-0065`）。

同时本次**推翻了该文档的一处前提假设**：

| 09-14 文档假设 | 本次实际 |
|---|---|
| 「装坏 → **下次启动失败** → 自愈回退基线」 | dsh **照常启动成功**（可选插件 fail-open）→ 自愈链完全不触发 |
| 「补的缺口很窄：同一 boot 内多次变更」 | 实为**「可选插件静默失效」整个类别**，比估计的宽 |

**结论**：复评通过，但**不恢复**该文档的 market-guard 方案（入口守卫 / `NODE_OPTIONS` 注入）。
理由同该文档 §10：那类改动落在**容器启动路径**上，用可用性换边际粒度。本设计不碰启动链（见 §9）。

### 1.4 红线

- **不触碰容器启动路径**：不改 `entrypoint.sh` 的启动语义，不注入 `NODE_OPTIONS`，不加进程树守卫。
- **不做整树回滚**：本设计只补缺失文件，**绝不**用 `rescue_restore` 替换整棵依赖树
  （那会静默丢掉用户此后安装的插件）。
- **不覆盖已存在文件**：修复只在**缺失**时补，不覆盖 live 中已存在的 `.node`。
- **失败绝不影响启动**：任何环节出错只写 `rescue.log`，与 `rescue_snapshot_baseline()` 同风格。

## 2. 设计决策

### 2.1 判据：相对基线的「缺失」，而非绝对数量

不用「`.node` 总数是否等于某值」——插件增删会改变总数。
用「**基线里有、live 里没有**」作为回归信号，天然免疫版本变化。

### 2.2 修复来源：快照复制，而非网络下载

A 与 B **共用同一份完好基线**：A 保证它被保留，B 从它复制回缺失的 `.node`。

- **零网络依赖**（本次故障恰恰是网络不可达引发的，靠网络修复等于把命门交给同一个依赖）；
- **无需逐包适配**下载源（各包 prebuild 源不同，无法通用化）；
- **已验证可行**：从 snap-0069 复制出的 `better_sqlite3.node` 可正常 `require`，
  导出 `Database/Statement/StatementIterator`。

### 2.3 被排除的方案

| 方案 | 排除理由 |
|---|---|
| 恢复 09-14 的 market-guard（入口守卫 / `NODE_OPTIONS --import`）| 落启动路径，自身故障=容器起不来（同 09-14 §10）|
| 发现异常后自动**整树回滚** | 静默丢失故障后安装的插件；代价高于收益 |
| 从 npmmirror 等镜像**下载**缺失绑定 | 逐包适配不可通用，且依赖网络（本次故障的根因之一）|
| 让 `require()` 加载测试所有原生包 | 慢 + 副作用不可控，且需预先知道"哪些包应有绑定" |
| 提高 `RESCUE_KEEP` 数值 | 治标：仍会按时间淘汰，无法保证留下的是**完好**那份 |

## 3. 内核 K：原生绑定清单

新增 `scripts/binding-inventory.js`（仿 `probe-ready.js`：纯读、无副作用、退出码契约）。

```
用法: node binding-inventory.js <dir> [--json]
输出: 排序后的 .node 相对路径清单（每行一条），或 --json 输出数组
退出: 0 = 成功（含目录不存在时输出空清单）；2 = 用法错误
```

- 扫描范围：`<dir>` 下所有 `*.node`，**排除 `.pnpm/`**（虚拟store 副本不计入）
- 实现：等价于 `find . -name '*.node' -not -path '*/.pnpm/*'` 的纯 JS 版，
  避免 grep/find 平台差异
- shell 包装：`librescue.sh` 新增 `rescue_binding_inventory <dir>`

**已知边界**：清单只看**文件存在性**，不判断文件是否可加载（`dlopen` 需真实加载，
副作用不可控）。若绑定存在但架构/ABI 不符，本设计不覆盖。

## 4. 方案 A：保留策略（`rescue_prune_pinned` 改造）

**目标**：确保 `RESCUE_KEEP` 窗口内**始终有一份"可供回退"的基线**。

现有实现只返回「最新一份 `boot-healthy*`」。改为钉住**至多 2 份**：

1. **最新一份** `boot-healthy*`（保持既有行为，兼容）
2. **`.node` 集合最完整的那份** `boot-healthy*`（可能更旧）

两份相同时只钉一份。`rescue_prune_victim()` 已支持跳过钉住项，需扩展为
支持**多个**钉住项（当前签名 `rescue_prune_victim "$pin"` 单值 → 改为接收集合）。

**钉住数必须受 KEEP 约束**（否则 `rescue_prune()` 的死循环保护会 break，导致保留数超窗口）：

```
pinCount = min(2, max(1, RESCUE_KEEP - 1))
```

| `RESCUE_KEEP` | 钉住数 | 说明 |
|---|---|---|
| 1 | 1 | 退化为现状（留不出位置，只钉最新）|
| 2 | 1 | 留 1 个位置给场景快照 |
| **3（默认）** | **2** | **A 生效**：最新 + 最完整 |
| ≥3 | 2 | 同上 |

**A 仅在 `RESCUE_KEEP >= 3` 时产生新行为**（默认即满足）。这是刻意的：
`rescue_prune_victim()` 在「全部被钉」时返回 1、调用方 `break`，若钉住数 ≥ KEEP 就会
保留超额份数、违反窗口契约。该约束同时让既有测试**全部保持通过**（见 §8）。

**本次推演验证**：若当时钉住 snap-0065 + snap-0068，则淘汰 `pre-clean` 的 snap-0067 →
**snap-0065（含完好绑定）保住**。

**记录方式**：`rescue_snapshot()` 在 meta 增写两个字段：

```json
{ "bindings": "<sha1 of sorted list>", "bindingCount": 28 }
```

`bindingCount` 用于比较完整性；K 失败时**不写**该字段（该快照不参与"最完整"评选，
但仍可被钉为"最新一份"）。

## 5. 方案 B：启动后精准修复（`rescue_binding_heal`）

**时序**：在 `rescue_snapshot_baseline()` 之后触发（即 dsh 已确认 healthy）。**异步、不阻塞启动**。

```
rescue_binding_heal():
  1. [开关] RESCUE_BINDING_HEAL=on? 否则 return 0
  2. [选源] 从保留的 boot-healthy* 中选 bindingCount 最大的一份作为参考基线
            （并列时取较新者）
  3. [验源] rescue_verify <ref> —— 拦住 hardlink 被 live 写坏的情况
            失败则放弃（只记日志）
  4. [比对] missing = K(ref/node_modules) − K(live/node_modules)
  5. [修复] 对每个 missing 项：
             - 目标已存在 → 跳过（红线：不覆盖）
             - mkdir -p 目标父目录
             - cp <ref>/<rel> <live>/<rel>
             - 记 rescue.log
  6. [收尾] 逐个失败即跳过该文件；整体不因单点失败而中止
```

**为什么在 healthy 之后**：修复不应延迟 dsh 可用性；且只有 healthy 后的 live 才是
「用户能看到的状态」，此时比对最有意义。

**与 A 的依赖**：B 的有效性**依赖 A 保住了含完好绑定的基线**。两者必须同批实施
（只做 B 而不改保留策略，可能选到的参考基线本身也是坏态 → 无东西可补）。

## 6. 护栏设计

### 6.1 三层失败安全

| 层 | 失败点 | 行为 |
|---|---|---|
| 1 | K 执行失败（异常退出 / 无输出 / 目录不可读）| 该次不记录 bindings；**不影响拍快照** |
| 2 | B 任一步失败 | 写 `rescue.log`，**绝不影响启动**（同 `rescue_snapshot_baseline`）|
| 3 | 参考基线不可信 | `rescue_verify` 失败 → **拒绝使用**（hardlink 被写坏的场景）|

### 6.2 与既有机制的关系

- **不改** `rescue_verify` / `rescue_restore` / `rescue_pick_rollback_target` 的既有语义；
- **不改** 探针 `probe-ready.js`（G3 的"自动发现"不在本设计范围，见 §2.3）；
- **复用** `rescue_snapshot_baseline()` 的失败安全风格与调用位；
- **新增** 环境变量 `RESCUE_BINDING_HEAL`（默认 `on`），登记进 `.env.example` 与 docs 07。

### 6.3 空间与开销

修复只**复制缺失文件**（正常为 0～数个 `.node`，本次场景为 1 个 2.1MB），
不触发快照拷贝，空间影响可忽略。

K 的扫描开销**实测约 40ms**（真机 profile：216 个顶层包 / 21300 个文件 / 命中 28 个 `.node`），
因此**无需超时保护**。A 期每次拍快照、B 期每次 healthy 各多一次扫描，可忽略。

## 7. 实现落点

### 7.1 `scripts/binding-inventory.js`（新增）

纯函数式检查器：参数解析 → 递归扫描 → 排序输出。无网络、无写入。

> ⚠️ 新增文件**必须同步登记进镜像**，否则 `/opt/dsh-rescue/` 下没有它（详见 §7.6）。

### 7.2 `scripts/librescue.sh`

| 函数 | 改动 |
|---|---|
| `rescue_binding_inventory()` | **新增**：包装 K，回填变量 |
| `rescue_snapshot()` | 写入 meta 的 `bindings` / `bindingCount`（约 +5 行）|
| `rescue_prune_pinned()` | 改为返回**至多 2 份**（最新 + bindingCount 最大）|
| `rescue_prune_victim()` | 支持跳过**多个**钉住项 |
| `rescue_binding_heal()` | **新增**：§5 的比对与补齐逻辑 |

### 7.3 `scripts/rescue-supervise.sh`

在 `rescue_snapshot_baseline()` 调用点之后加一行 `rescue_binding_heal`（失败安全）。

### 7.4 `scripts/rescue`（CLI）

新增只读子命令 `rescue bindings [check]`，便于运维自查（可选，但利于排查与测试）。

### 7.5 文档

- `CHANGELOG.md` → `[Unreleased]` 记录
- `.env.example` → `RESCUE_BINDING_HEAL`
- `docs/zh-CN/07-环境变量速查.md` + `docs/en/07-environment-variables.md` → 同一变量
- `docs/zh-CN/06-救援模式.md` + `docs/en/06-rescue-mode.md` → 保留策略与修复行为说明

### 7.6 `Dockerfile` —— 登记新文件进镜像（**规格补充项**）

`Dockerfile:117` 是**显式文件清单**，新文件不登记则镜像里不存在：

```dockerfile
COPY scripts/librescue.sh scripts/probe-ready.js scripts/diagnose.js scripts/report.js \
     scripts/logtag.js scripts/logtee.js scripts/rescue-supervise.sh scripts/rescue /opt/dsh-rescue/
```

必须做三处登记：

1. `COPY` 行加入 `scripts/binding-inventory.js`
2. `Dockerfile:121` 的 `sed -i 's/\r$//'`（DOS 换行清理）清单中加入同一文件
3. `Dockerfile:122` 的 `chmod +x` 清单中加入同一文件（与 `probe-ready.js` 一致）

**解析方式**（**懒解析，不改 entrypoint**）：在 `librescue.sh` 内新增 `rescue_binding_kernel()`，
首次调用时按候选列表定位并缓存 —— 这样 `entrypoint`、`rescue` CLI、`scripts/t/*` 三种
调用上下文都能找到内核，且**完全不碰启动路径**（比在 entrypoint 里解析更符合 §1.4 红线）。

```sh
rescue_binding_kernel() {
  [ -n "${RESCUE_BINDING_KERNEL:-}" ] && [ -f "${RESCUE_BINDING_KERNEL:-}" ] && {
    printf '%s' "$RESCUE_BINDING_KERNEL"; return 0; }
  for _c in /opt/dsh-rescue/binding-inventory.js \
            "$HERE/binding-inventory.js" \
            "$HERE/scripts/binding-inventory.js" \
            "$HERE/../binding-inventory.js"; do
    [ -n "$_c" ] && [ -f "$_c" ] && { RESCUE_BINDING_KERNEL="$_c"; printf '%s' "$_c"; return 0; }
  done
  return 1
}
```

候选列表覆盖三种上下文：`entrypoint`/`rescue`（`$HERE` = `scripts/`）、
`scripts/t/*`（`$HERE` = `scripts/t/`，靠 `../`）、镜像（`/opt/dsh-rescue/`）。

缺失时：`A` 退化为「只钉最新基线」（现状），`B` 整体跳过并记日志 —— 均不影响启动。

## 8. 测试设计

新增/扩展 `scripts/t/`（黑盒 + 纯函数，无需 docker），纳入 CI 门禁 1。

| # | 用例 | 断言 |
|---|---|---|
| 1 | K：正常目录 | 输出排序后的 `.node` 清单，排除 `.pnpm` |
| 2 | K：空目录 / 不存在目录 | 空清单，`exit 0`（不报错）|
| 3 | 快照写入 bindings | `meta.json` 含 `bindings` + `bindingCount`，值稳定可复现 |
| 4 | **A：最新基线被钉** | 淘汰后最新 `boot-healthy*` 仍在 |
| 5 | **A：最完整基线被钉（本次回归）** | 构造"旧的完好 + 新的缺 1 个 `.node`"，淘汰后**旧的仍在** |
| 6 | A：`pre-clean` 优先被淘汰 | 有基线可钉时，victim 落在非基线快照上 |
| 7 | **B：补齐缺失绑定** | 构造 live 缺 1 个 `.node` + 完好基线 → 该文件被补回、内容与基线一致 |
| 8 | **B：红线——不覆盖已存在文件** | 同名文件内容不同时**保持 live 原样** |
| 9 | **B：拒绝不可信源**（§6.1 第 3 层）| 参考基线被写坏（treeHash 不符）→ **不修复**且只记日志 |
| 10 | B：无可用基线时优雅降级 | 打印跳过并 `exit 0`，不报错 |
| 11 | B：开关关闭 | `RESCUE_BINDING_HEAL=off` 时不执行任何写操作 |
| 12 | **B 失败路径不产生部分写入** | 参考源不可信时（同用例 9），live 的 `.node` 清单与内容**逐字节不变**，仅 `rescue.log` 有记录 |

用例 5、7、8、9 把本设计从真机事件学到的红线钉进回归网。

### 8.1 既有测试兼容性（无需修改，已推演验证）

`scripts/t/test-prune-pin-baseline.sh` 现有 5 个用例**全部保持通过**，因为：

- 旧快照没有 `bindingCount` 字段 → 按「未知完整性」处理，并列时取较新者 → 钉住数与现状一致；
- 且 `pinCount = min(2, max(1, RESCUE_KEEP-1))` 在 `RESCUE_KEEP = 1/2` 时恰为 **1 份**（= 现状）。

| 既有用例 | KEEP | 钉住数 | 结果 |
|---|---|---|---|
| ① 基线是最老一份 | 2 | 1 | ✓ 淘汰次老普通快照，基线留下 |
| ③ 多份基线**只钉最新那份** | 2 | 1 | ✓ 旧断言（更旧基线可被淘汰）**不变** |
| ④ 全是基线仍能减员 | 1 | 1 | ✓ 精简到 1 份，**不超额**（§4 约束的由来）|

**注意**：用例 ③ 的语义是「无 `bindings` 信息时的行为」——本设计**不推翻它**，
而是在 `RESCUE_KEEP >= 3` 且**存在完整性差异**时新增行为（由用例 5 覆盖）。
所以是**新增用例**，而非改动既有断言。

## 9. 影响面

- **向后兼容**：`rescue_prune_pinned()` 由"单值"变"集合"，其唯一调用方是 `rescue_prune()`，
  同文件内改动；不影响快照格式（新字段为**追加**，旧快照无该字段时按"未知完整性"处理，
  仍可被钉为"最新一份"）。
- **默认有副作用（但极小）**：`RESCUE_BINDING_HEAL` 默认 `on`，会在 healthy 后做一次
  目录扫描；仅在**发现缺失**时才写文件。可用 `off` 完全关闭。
- **离线可用**：全部为本地文件操作，**无网络依赖**。
- **不触碰**：容器启动路径（`entrypoint.sh` 启动语义）、`NODE_OPTIONS`、进程树、
  探针判据（`probe-ready.js`）、`rescue_restore()` 整树回滚语义、用户数据。
- **已知不覆盖**（YAGNI，留待复评）：
  1. **G3 的"自动发现"**——可选插件静默失效仍不会被探针发现，本设计只保证"有回退点且能自动补"；
  2. **无任何基线可参考**的场景（如首次安装即坏）——需逐包下载源适配；
  3. **绑定存在但 ABI 不符**的场景——清单只判存在性。
