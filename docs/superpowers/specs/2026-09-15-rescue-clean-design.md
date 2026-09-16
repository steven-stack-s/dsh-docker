# rescue clean —— 升级后环境清理功能设计

> 状态：待实现
> 日期：2026-09-15
> 适用镜像：dsh-docker（构建时锁版本 + 容器内升级方案）

## 1. 背景与问题

dsh-docker 的设计是**做一次镜像，之后在容器内升级**：

```bash
docker exec dsh npm install -g @deepseek-ai/dsh@<新版本>
docker restart dsh
```

这个方案的原生缺口是：**升级只做「装上新的」，从不做「清掉旧的」**。长期升级会累积无人回收的残留。

### 1.1 实测结论（沙箱复现，非推断）

在 Node 24 / npm 11.19 / pnpm 11.25 环境真实复现升级过程后，得到两条与直觉相反的事实：

**① `dsh` 本体升级：npm 侧是干净的**

```
npm install -g @deepseek-ai/dsh@0.1.5-rc.2     → 296M
npm install -g @deepseek-ai/dsh@0.1.6-alpha.1  → 287M（旧树被整体替换）
```

npm 的全局安装会整体重建 `node_modules` 树，**「旧版 dsh 包目录残留」这一假设不成立**（实测未发现任何 `*0.1.5*` 残留目录）。

**② 插件树（pnpm profile）：真的会残留，已复现**

```
pnpm add @wenaixi/dsh-superpower@6.3.1
pnpm add @wenaixi/dsh-superpower@6.3.0-dsh.10   # 降级

node_modules/.pnpm/ 同时存在：
  @wenaixi+dsh-superpower@6.3.0-dsh.10_...   ← 当前在用
  @wenaixi+dsh-superpower@6.3.1_...          ← 残留 652K，未被回收
```

**关键**：`pnpm prune` 对此**无效**（实测输出 `Already up to date`，孤儿条目纹丝不动）。pnpm 的虚拟存储不会自动 GC 旧入口，这是设计如此。**这是本功能的主要价值点。**

### 1.2 其余残留向量

| 向量 | 位置 | 现状 |
|---|---|---|
| npm 下载缓存 | 容器内 `/root/.npm` | Dockerfile L67 只在**构建期** `rm -rf`；运行期升级持续累积（沙箱实测缓存达 255M） |
| pnpm 内容寻址存储 | `pnpm store path`，与 `/data/dsh` 同文件系统（**卷外**） | 完全无人清理，跨版本堆积 |
| `.dsh-module-fallback` | profile 下 | 已被快照纳入，但无清理覆盖 |

### 1.3 红线

现有 rescue 的快照/回滚（`rescue_snapshot` / `rescue_restore`）**依赖 profile 的 `package.json` + `pnpm-lock.yaml` 作为可回退基线**。清理功能若破坏「回滚到 snap-N 后仍能启动」这一能力，就是制造新的故障源。**这是本设计的最高约束。**

## 2. 设计决策

| 决策 | 选择 | 理由 |
|---|---|---|
| 触发时机 | **手动显式命令** `rescue clean` | 与既有 `rescue snapshot/rollback/verify` 风格一致；可审计、可预测 |
| 清理深度 | **保守**：只清缓存与可证明的孤儿项 | 绝不触碰依赖解析结果，回滚基线完全不受影响 |
| 安全护栏 | **清理前自动快照 + 默认 dry-run** | 沿用 `rescue plugin` 的「变更前自动快照」惯例 |

### 2.1 被排除的方案

- **升级命令内串联自动清理** —— 排除。清理会动 npm/pnpm 存储，失败时与「升级失败」混淆归因；且与既有自愈预算耦合，会污染 rescue 的故障判定。
- **整树重建**（删 `node_modules` 后按 lockfile 重装）—— 排除。直接摧毁 `rescue rollback` 基线：回滚时若 `.pnpm` 已清空且离线，profile 起不来。

## 3. 命令接口

```bash
rescue clean [--dry-run|-n] [--yes] [--json]
```

| 选项 | 语义 |
|---|---|
| 无参数 | **默认即 dry-run**：只打印将清理的内容与可回收空间，不做任何改动 |
| `--yes` | 确认执行真实清理 |
| `--dry-run` / `-n` | 显式 dry-run（与默认同义，供脚本可读性） |
| `--json` | 机器可读输出，供 CI / 诊断包消费 |

## 4. 清理范围

仅四项，全部可证明为垃圾：

| # | 目标 | 判定依据 | 安全性论证 |
|---|---|---|---|
| C1 | npm 下载缓存 | `npm config get cache`（容器内 `/root/.npm`），删 `_cacache` | 纯下载缓存，删后仅需重新下载 |
| C2 | pnpm 内容寻址存储孤儿 | `pnpm store prune` | pnpm 官方语义即「只删 unreferenced」，不碰在用内容 |
| C3 | profile `.pnpm` 中未被 lockfile 引用的入口 | 解析 `pnpm-lock.yaml` 引用集，`.pnpm/<dir>` 不在集合 ⇒ 孤儿 | **已实测**：删孤儿后 live 符号链接不受影响；`pnpm prune` 漏掉这部分 |
| C4 | rescue 证据/事故历史超限部分 | 复用既有 `RESCUE_EVIDENCE_KEEP` / `RESCUE_INCIDENT_KEEP` | 已有轮转逻辑，此处只做显式触发 |

### 4.1 明确不清理（红线）

- `package.json` / `pnpm-lock.yaml` / `pnpm-workspace.yaml`
- `.pnpm` 中**被 lockfile 引用**的入口
- profile 的 `node_modules` 整树
- `/opt/dsh-seed`（离线恢复的兜底）
- 任何 `snap-*` 快照目录
- 会话 / 记忆 / 配置 / 凭据

## 5. 护栏设计

### 5.1 三层护栏

**第一层：清理前自动快照**

`rescue clean --yes` 在真删前自动执行 `REASON_SNAPSHOT="pre-clean"` 的快照，沿用 `rescue_snapshot`。因此自动纳入既有 `RESCUE_KEEP` 轮转与基线钉住逻辑（`rescue_prune_pinned`），**不新增淘汰规则**。

仅在 profile 存在且有 `package.json` 时拍快照（`rescue_snapshot` 的既有前置条件）。

**第二层：默认 dry-run**

无参数 = 只报告；真实清理必须显式 `--yes`。C3 按 lockfile 引用集判定，判定逻辑一旦有 bug 影响面最大，必须让用户先看到将删清单。

**第三层：绝不触碰回滚基线**

见 §4.1，并以测试用例 5、7 固化。

### 5.2 与 rescue 自愈的关系

**明确解耦**：`rescue clean` **不计入** `RESCUE_REMOVE_LIMIT` / `RESCUE_ROLLBACK_LIMIT` 自愈预算。

理由：预算是为「自动改动插件树」设的护栏，而 clean 是用户显式发起、且**不改变依赖解析结果**的操作。计入预算会导致用户清理几次后自愈静默失效，属于错误归因。

## 6. 回滚交互验证（已实测）

针对「清理孤儿后，回滚到清理前快照是否还能启动」这一关键风险，实测了完整危险序列：

| 步骤 | 结果 |
|---|---|
| 拍 hardlink 快照（snap-0001，含 6.3.1） | 快照持有自己的目录项 |
| 升级插件 → 6.3.1 变孤儿 | live 同时存在两个 `.pnpm` 条目 |
| **清理孤儿** | live 只剩 6.3.0-dsh.10；**快照里的 6.3.1 完好** |
| **回滚到 snap-0001** | `package.json` 与 lockfile 还原，插件解析出 **6.3.1** ✓ |
| `pnpm install --frozen-lockfile --offline` | `Already up to date` ✓ |

**为什么安全**：清理只删「未被当前 lockfile 引用的条目」，而回滚会**连同 lockfile 一起还原**；被删条目在快照里另有自己的目录项（`cp -al` 对目录是新建目录 + 硬链接文件，不共享顶层 inode）。实测两者 inode 不同（65156096 vs 65156510）。

**探测依据的确证**：孤儿版本在当前 lockfile 中出现 **0 次**，在用版本出现 4 次 —— lockfile 引用集是可靠的孤儿判据。

**结论**：C3 安全，无需额外保护机制。

### 6.1 关于 hardlink 快照的空间语义

默认 `RESCUE_SNAPSHOT_MODE=hardlink`，快照与 live 共享文件 inode。因此：

- 删孤儿若快照仍持有硬链接，`rm` 只删目录项、inode 仍被快照引用，**磁盘不立即回收**。
- 故「清理回收了多少空间」应按 inode 引用计数估算，不能按 `du` 目测。
- 报告输出需对此保持诚实：区分「已释放」与「仍被快照引用」。

### 6.2 treeHash / `rescue verify` 能检测什么、不能检测什么

**能检测：快照内容被就地改写。** `snapshot_tree_hash` 的摘要含
`%p`（路径）/ `%y`（类型）/ `%s`（大小）/ `%T@`（mtime）/ `%i`（inode），在**拍快照时**计算并写入
`meta.json`；`rescue verify` 重算同一摘要与 `meta.treeHash` 比对。hardlink 模式下快照与 live 共享
inode，任何就地改写（append / `sed -i` / 原生模块重编）会同时改变两边 size 与 mtime，摘要随之变化
—— 这正是 `test-snapshot-integrity.sh` 用例 3 固化的行为（copy 模式的用例 4 则断言其免疫）。

**不能检测：快照模式退化（hardlink → copy）。** 需要明确区分两件事：

- `snapshot_tree_hash` 确实把 inode 计入摘要，因此同一棵树按 `cp -al` 与按 `cp -a` 拍出的快照
  **hash 必然不同**（已实测：同一源树下两种模式摘要不同）；
- **但 treeHash 只在「拍快照时」计算、只在 `rescue verify` 时与 `meta.json` 自比对**。它是
  「快照是否被改动过」的自洽校验，**不是**「快照是不是 hardlink 模式」的断言 ——
  `rescue_verify` 只把 `meta.mode` 用于**打印**，从不校验它与实际的 `cp -al` / `cp -a` 行为是否一致，
  也没有任何断言强制「快照必须是 hardlink 模式」。

因此：**若有人把 `cp -al` 改成 `cp -a`（或设 `RESCUE_SNAPSHOT_MODE=copy`），不会被任何现有测试捕获**
—— 这是**已知盲区**，不在本功能的覆盖范围内，此处如实记录而非声称已覆盖。其影响面也有限：模式退化
只会让快照不再与 live 共享 inode（即变为更安全、更占空间的副本），不会让快照静默失真；
真正会失真的是 `6.1` 所述的「空间不立即回收」语义 —— 而那是**报告准确性问题**，不是**数据可信性问题**。

## 7. 实现落点

遵循项目既有分层（纯函数入库、CLI 只做分发）：

### 7.1 `scripts/librescue.sh` — 新增纯函数

| 函数 | 职责 |
|---|---|
| `rescue_clean_npm_cache` | 定位 `npm config get cache`，仅删 `_cacache`，返回回收字节数 |
| `rescue_clean_pnpm_orphans` | 解析 `pnpm-lock.yaml` 引用集，列出/删除未引用的 `.pnpm/<dir>` |
| `rescue_clean_pnpm_store` | 调 `pnpm store prune`（官方只删 unreferenced） |
| `rescue_clean_rescue_history` | 显式触发 C4：调用**既有** `rescue_evidence_prune` 与 `rescue_incident_prune`，不新写轮转逻辑 |
| `rescue_clean_report` | 汇总输出（dry-run 与实际共用格式） |

> C4 复用既有实现：`rescue_evidence_prune`（位于 `scripts/rescue-supervise.sh`，保留数取
> `${RESCUE_EVIDENCE_KEEP:-$RESCUE_KEEP}`）与 `rescue_incident_prune`（位于 `scripts/librescue.sh`，
> 保留数取 `${RESCUE_INCIDENT_KEEP:-20}`）均已存在，本功能只做显式触发，不重复实现轮转。
>
> 注意：`rescue_evidence_prune` 定义在 supervise 侧，而 `rescue clean` 走的是 `scripts/rescue` → librescue
> 路径。实现时需确认其在 CLI 上下文中的可见性，必要时按 `rescue_incident_prune` 的方式下沉到 librescue。

**风格约束**（与 librescue 现状一致）：不设 `set -u/-e`、全部 `${VAR:-default}`、用 `rescue_log` 记审计、失败不终止调用方。

### 7.2 `scripts/rescue` — 新增子命令

```sh
clean)
  # --yes 才真删；--dry-run/-n 显式预览；--json 机器可读
  # 真删前：REASON_SNAPSHOT="pre-clean" rescue_snapshot（仅 profile 存在且有 package.json）
  ;;
```

同步更新 L22 的 usage 字符串，加入 `clean`。

### 7.3 文档

- `docs/zh-CN/03-升级与维护.md`：新增「升级后清理」小节
- `docs/en/03-upgrade-maintenance.md`：对应章节
- `docs/zh-CN/06-救援模式.md`：命令表补 `clean`

## 8. 测试设计

新增 `scripts/t/test-rescue-clean.sh`（黑盒 + 纯函数，无需 docker），纳入 CI 门禁 1。

| # | 用例 | 断言 |
|---|---|---|
| 1 | dry-run 不改动任何东西 | 前后目录树指纹与 mtime 完全一致 |
| 2 | 孤儿被识别 | 造 fake lockfile，未引用条目出现在 dry-run 清单 |
| 3 | 在用条目**绝不**被删 | 被引用条目清理后仍在 |
| 4 | `--yes` 真删孤儿 | 孤儿消失、在用条目完好 |
| 5 | **红线：lockfile / package.json 永不被删** | 清理后两文件字节级不变 |
| 6 | 清理前自动快照 | `snap-*` 数量 +1 且 `meta.reason` = `pre-clean` |
| 7 | **回滚交互**（§6 实测的固化） | clean → rollback → 插件可解析 |
| 8 | 无 profile / 无 lockfile 时优雅降级 | 打印跳过并 `exit 0`，不报错 |
| 9 | 审计日志 | `rescue.log` 含 clean 动作记录 |

用例 5 与 7 把本设计验证得到的红线钉进回归网，防止后续改动破坏回滚能力。

## 9. 影响面

- **向后兼容**：纯新增子命令，不改动既有命令行为。
- **默认无副作用**：不传 `--yes` 时完全只读。
- **离线可用**：C1/C3 为纯本地文件操作；C2 依赖 pnpm 本地存储。
- **不触碰**：容器启动路径（entrypoint）、自愈编排（rescue-supervise）、探针与诊断。
