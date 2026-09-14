# dsh-market 安装/更新绕过快照：根因分析与 market-guard 覆盖方案

> **决策（2026-09-14）：暂不实施。** 收益低——现有的 boot 级 `boot-healthy` 基线快照 + 启动自愈已覆盖主场景
> （市场装坏插件 → 重启后启动失败 → 回退基线），本方案补的只是「同一 boot 内多次变更后的精确回退粒度」，触发概率低；
> 成本却落在容器**启动路径**上（入口守卫 / `NODE_OPTIONS` 注入 / 失败熔断 / 多个单测），不划算。
> 本文档保留为**决策记录 + 调查结论**，供日后复评（复评触发条件见 §10）。
>
> 状态：仅设计，无代码改动  ·  调查基线：dshmarket 1.46.1 + DSH 0.1.5-rc.2  ·  2026-09-14
> 结论先行：市场走的是「宿主 dsh 进程内直接 spawn dsh CLI」这条路径，天然绕开 rescue 封装命令。
> 两条能在「变更前」插入动作的钩子都已实测可行，且都不改 DSH、不改 dshmarket：
> ①它 spawn 的入口文件就是**当前 dsh 进程自己的 argv[1]** —— 放一个同名入口守卫即会被自动复用；
> ②DSH **不清洗 `NODE_OPTIONS`** —— `--import` 守卫可覆盖进程树里任何插件命令（含市场换实现后的路径）。

---

## 0. TL;DR

| 问题 | 原因 | 覆盖手段 | 代价 |
| --- | --- | --- | --- |
| 市场点「安装/更新」没有变更前快照 | 市场不经过 `rescue plugin`，直接 spawn `dsh plugin`（lib/plugin-Ddi42qoW.js 只是 pnpm 转发器，本身不打快照） | 在容器侧加守卫：**主**用 `NODE_OPTIONS=--import` 补丁（覆盖任何路径）＋**辅**用同名入口守卫（argv[1] 复用，语义最准），两者都调既有 `rescue snapshot` | 2 个新文件 + 启动接线 + 若干单测；无 DSH/dshmarket 改动 |
| 现有兜底不够 | 健康基线快照是「每次启动一份」，同一 boot 内多次变更只有粒度到 boot；且 `RESCUE_KEEP=3` 会被市场变更快照挤掉 | 保留策略钉住 `boot-healthy`；守卫快照做冗余去重 | `rescue_prune` 小改 + 去重开关 |

---

## 1. 现状：快照只在四个地方产生

| # | 触发点 | 代码位置 | reason | 覆盖对象 |
| --- | --- | --- | --- | --- |
| 1 | `rescue plugin add/remove ...` 封装命令 | `scripts/rescue`（plugin 分支：先 `rescue_snapshot` 再 `dsh plugin ...`） | `plugin add <pkg>` | 用封装命令的用户 |
| 2 | `rescue snapshot --reason ...` 手工 | `scripts/rescue` | 自定义 | 手工 |
| 3 | 自愈动作前拍现场 | `scripts/rescue-supervise.sh`（remove-plugin / rollback 之前） | `selfheal-*` | 自愈链路 |
| 4 | 启动健康后的基线 | `scripts/rescue-supervise.sh` 的 `rescue_snapshot_baseline()` | `boot-healthy baseline` | **为绕过 rescue 封装的变更（含 dshmarket）留的回退点** |

第 4 条是 v0.3.5 就明确为市场场景设计的，`.env.example` 里也写着这件事：

```
#   插件市场(dshmarket)等绕过 rescue 封装的变更靠它当回退点；基线快照同样占用 RESCUE_KEEP 份数。
RESCUE_SNAPSHOT_ON_HEALTHY=on
```

所以现状不是「没有兜底」，而是兜底粒度是 **boot 级**；而 rescue 封装命令提供的是 **单次操作级**。

---

## 2. 根因：市场走的是另一条 CLI 路径（证据链）

### 2.1 市场怎么装插件

`/data/dsh/profiles/web/node_modules/dshmarket/src/dsh-cli.ts`：

```ts
/** Argv re-invoking the CLI that launched this host process ... */
export function dshArgv() {
  const entry = process.argv[1]
  if (entry !== undefined && /[\\/](?:bin\.(?:js|ts)|dsh)$/.test(entry)) {
    const abs = resolve(entry)
    return { file: nodeExecutable(), args: [...process.execArgv, abs], cwd: dirname(abs), viaShell: false }
  }
  return { file: 'dsh', args: [], cwd: undefined, viaShell: winCmdShim }   // PATH 兜底
}

export function runDshPlugin(profile, pluginArgs) {           // 唯一的插件执行入口
  const { file, args, cwd, viaShell } = dshArgv()
  ...
  const child = spawnShim(file, [...args, 'plugin', '--profile', profile, ...pluginArgs], { ... })
}
```

即：安装/更新/卸载 = `node <dsh 入口> plugin --profile web add|remove|update <pkg>`。

变更时机（核对过请求体里的每一次写入，决定守卫拍到的到底是不是「变更前」）：

- **安装**（`/dsh-market/install`，routes.ts:4231-4559）：直到第一次 `runPlugin(config.profile, ['add', target])`（**4365**）之前，
  只有 `readProfileManifestSnapshot()`（4364，只读 dependencies + bundles）等只读步骤；**对 profile 目录的写入 = 0**。
  4365 之后才是 `retargetCollections` / `validateAddedPlugins`（内部再 spawn，属变更后）。
- **更新**（`/dsh-market/update`，routes.ts:2795-3505）：spawn（**3200**）之前同样 0 写入 ——
  `captureUpdateManifest()`（2814）与 `captureProfileLockfile()`（3127，读进内存 Buffer）都是只读。
- **例外（要单独对待）**：`/dsh-market/restore` 会**先** `writeFileSync(package.json)`（1045/1081/1097/1107）再 spawn（1054/1087）；
  `/dsh-market/approve-builds` 会写 `pnpm-workspace.yaml`（3935 → profile.ts:967），但那是**独立请求**。
  这两处的「变更前」已经包含 market 自己的 manifest/workspace 改动，快照价值有限（但也不会更差）。

结论：**守卫在 spawn 前一刻拍到的就是严格的变更前状态**；另外「一次安装」可能派生 2~3 次 `runPlugin`（add → retarget → validate），
所以去重（§5.3）不是可选优化，而是避免把保留窗口冲掉的关键。

市场里所有会改 profile 的操作（`routes.ts` 中 `runPlugin(` 的全部调用点）：

| market 路由 | 派生的插件命令 | 调用点行号 |
| --- | --- | --- |
| `/dsh-market/install` | `add <target>`（retarget / validate 阶段可能再次 `add`） | 4365 |
| `/dsh-market/update` | `add <name>@<ver>` | 3200 |
| `/dsh-market/uninstall` | `remove <name>` | 4058 |
| `/dsh-market/self-uninstall` | `remove dshmarket` | 3717 |
| `/dsh-market/migrate-source` | `install` → `remove` → `add <name>@latest` | 2671 / 2700 / 2706 |
| 内部修复/恢复路径（安装失败后的自修、备份恢复） | `--no-frozen-lockfile install`、`add --force <target>` | 620 / 780 / 926 / 1054 / 1087 |

→ 没有任何一条绕过 `runPlugin`（即 `dsh plugin`）去直接改 profile。因此**只要在 dsh CLI 层或 pnpm 层拦截，就能覆盖市场的全部写操作**。
→ 顺带说明守卫的判定为什么用「argv 里出现变更子命令」而不是「argv[0] 是子命令」：
  market 会前置 pnpm 选项（如 `['--no-frozen-lockfile', '--config.minimumReleaseAge=0', 'install']`）。

### 2.2 为什么现有的 dsh CLI 包装无效

容器里 `/opt/dsh/bin/dsh` 是 **符号链接**：

```
/opt/dsh/bin/dsh -> ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js
```

于是真实 dsh 进程的 `process.argv[1]` 是 **`/opt/dsh/lib/node_modules/@deepseek-ai/dsh/lib/bin.js` 这个绝对路径**，
匹配 2.1 的正则 → 市场用 `node <bin.js>` 重新拉起 CLI，**完全不再查 PATH**。

> 关键推论：把 `dsh` 包装脚本放到 PATH 前面**拦不住市场**（对用户手敲的 `dsh plugin add` 有效，对市场无效）。
> 能被市场复用的只有「argv[1] 那个文件本身」。

### 2.3 顺带确认：市场自重启后仍然是同一个入口

`src/restart.ts` 的 `restartLaunch()` 同样用 `dshArgv()` 重建启动命令行（`args: [...launch.args, ...process.argv.slice(2)]`）。
所以**只要宿主进程以守卫为 argv[1] 启动，市场重启后依然经过守卫**——这是守卫方案能长期成立的关键。

### 2.4 dsh 侧的 plugin 子命令本身没有钩子

`lib/plugin-Ddi42qoW.js`：`runPlugin()` 只做「init profile → spawnSync('pnpm', args, { cwd: profileDir }) → reconcilePlugins」。
没有 pre/post hook、没有快照、没有可注入的环境变量；`package.json` 的 `dsh.profile.bundles` 改写发生在 **pnpm 成功之后**。
因此「变更前」唯一有意义的时刻就是**这条命令启动之后、spawnSync(pnpm) 之前**，也只能从进程边界拦截。

### 2.5 为什么不在 HTTP / 插件树层拦截（已排除）

- `dsh plugin` 是 `bin.js` 里与 profile 模式**并列的独立 mode**（`process.exit(runPlugin(...))`），**完全不进 cordis 树**；
  全内核没有 `prePlugin` / `beforeInstall` / `beforeReload` 之类的钩子；`patchReload: live` 只监听 `cordis.patch.yml`
  （**不监听 package.json / node_modules**），市场装插件不会触发它。
- 树内的 `internal/plugin` 事件只是「某个 fiber 起来了」的通知，**没有 veto / next 参数**，无法当作「变更前」钩子。
- 市场的写操作入口确实全是 HTTP 路由，但 DSH 的 `webServer` 服务**没有中间件 API**：只有 `register`（exact/prefix，重复路径即抛）、
  `registerUpgrade`、`registerFallback`（**只有 1 个座位**，已被前端静态服务占用）、`tapIndex`；分发是「exact → 最长 prefix → fallback → 404」，没有 `next()` 链。
  想拦 `/dsh-market/*` 只能在 `webServer` 实例上**包裹 `register`**，并保证自己先于市场注册 —— 三重实现细节依赖，本方案不采用。

---

### 2.6 市场自带的「快照/备份」为什么不能替代 rescue 快照

| market 机制 | 覆盖面 | 调用时机 | 结论 |
| --- | --- | --- | --- |
| `snapshot.ts`（`<profile>/.dsh-market/snapshots/*.json`，保留 20 份） | 只有 3 个文件：`package.json` / `cordis.patch.yml` / `.dsh-market/state.json`；**不含 `node_modules`、不含 `pnpm-lock.yaml`、不含 `cordis.yml`** | 只在 `/dsh-market/bundle-order`（1819）、手动建快照（1937）、`applyPreset`（presets.ts:308）三处调用；**install/update/uninstall/migrate/rollback/approve-builds 内部 0 次调用** | 恢复不了坏掉的依赖树 |
| `backup.ts` | 递归打包 profile 文件（上限 256 文件 / 2MB，跳过 `node_modules`/`pnpm-lock.yaml`/`.git`/`.dsh-market`） | 只服务导出（backup/WebDAV/Gist）与 bundle-order 的进程内回滚网；**从不自动落盘成快照** | 是「导出/迁移」工具，不是回退点 |
| install 失败回滚（4366-4370） | `restoreProfileManifest()`：**只写回 package.json 的 dependencies 与 dsh.profile.bundles 两个字段** | 失败且非取消 | 不动 `node_modules`、不动 lockfile |
| update 失败回滚（3229-3240） | `add --force` 重装旧精确版本 + 恢复 manifest/lockfile | 失败且 pnpm 真跑过 | 依赖网络与 registry，仍可能失败 |
| 取消（cancel，3946-3967） | **无任何恢复动作** | 用户点取消 | 半成品插件树被刻意保留 |

→ 结论：市场没有任何「变更前、含 node_modules 的完整回退点」，它的自愈也不恢复 `node_modules` 旧字节。
**这正是外部（rescue）快照不可替代的价值**，也是本方案要补的那一块。

（补充事实：market 的持久状态只有 `<profile>/.dsh-market/{state.json, log.ndjson, discovery-compatibility-v1.json, snapshots/}`；
`check.ts` 里出现的 `.dsh-plugin-backups` 在市场代码中**没有任何创建点**，磁盘上也不存在。）

## 3. 三个实测证据（本机复现，非推测）

### 证据 1：守卫能在「变更前」拍到快照

用 pnpm 桩模拟一次市场安装（桩把 profile 的 `pnpm-lock.yaml` 从 `lock v0` 改成 `lock v1 changed`），
守卫在转发前调用 `rescue snapshot --reason "plugin add demo"`：

```
=== run: node <guard> plugin --profile web add demo ===   # 市场形状的 spawn
=== snapshot dir ===
snap-0001
{"created":"...","reason":"plugin add demo","dsh":"0.1.5-rc.2","profile":"web","mode":"hardlink","treeHash":"6675..."}
=== 快照内的 pnpm-lock.yaml ===   lock v0        <- 变更前
=== 变更后的 live ===             lock v1 changed
=== rescue.log ===
... snapshot created snap-0001 (reason: plugin add demo)
[guard] mutation=["add","demo"] snapshot-rc=0 snap=snap-0001
```

快照内容 = 变更前状态，且 `reason` 恰好符合既有契约（见 5.3）。

### 证据 2：`RESCUE_KEEP` 压力会把 `boot-healthy` 基线挤掉

`RESCUE_KEEP=2`，依次拍 `boot-healthy baseline` → `plugin add alpha` → `plugin add beta`：

```
=== remaining snapshots (KEEP=2) ===
snap-0002  plugin add alpha
snap-0003  plugin add beta
=== prune log ===
... snapshot created snap-0001 (reason: boot-healthy baseline)
... prune /tmp/prune-test/home/.rescue/snap-0001      <- 基线被 FIFO 删掉
=== rescue_pick_rollback_target ===
snap-0002
```

守卫上线后，一次「市场批量更新 5 个插件」就会产生 5 份 `plugin add ...` 快照，**把唯一被证明能启动过的基线挤出保留窗口**，
`rescue_pick_rollback_target()` 的第一轮优先（`boot-healthy*`）随之落空。这是方案必须一起解决的副作用。

### 证据 3：守卫的 spawn 形状与市场完全一致

`node /path/to/dsh ...`（市场用的形式）与 `/path/to/dsh ...`（shebang 形式）都能命中守卫，
`--version`、`plugin --profile web list` 等非变更命令转发后输出正常（`0.1.5-rc.2` / pnpm 输出原样）。

---

## 4. 拦截点候选（含取舍）

| 方案 | 原理 | 覆盖范围 | 侵入性 | 跨版本稳健性 | 判断 |
| --- | --- | --- | --- | --- | --- |
| **A. 同名入口守卫**（推荐） | 让 dsh 以 `.../dsh`（JS 文件）为 argv[1] 启动；市场 `dshArgv()` 复用 argv[1] 自动经过守卫 | 市场安装/更新/卸载、市场自重启后的全部 CLI 调用、用户手敲 | 镜像新增 1 文件 + PATH 前置；不改 DSH/dshmarket | 中高：依赖「市场复用 argv[1]」这一明确设计（`dshArgv` + `restartLaunch`） | ✅ 主方案 |
| **B. NODE_OPTIONS --import 补丁** | 在宿主进程里 patch `child_process.spawn/spawnSync/execFile`，命中 `plugin ... add/remove/...` 就先快照 | 任何在 dsh 进程内发起的插件命令（含未来市场改实现） | 环境变量 + 1 个 ESM 文件 | 中：Node 内建模块补丁需 `syncBuiltinESMExports()`（已实测可行），但依赖 DSH 不清洗 NODE_OPTIONS | ⭕ 可选加固 |
| **C. pnpm 包装** | `dsh plugin` 用 `spawnSync('pnpm')`（PATH 查找）；PATH 前置 pnpm 包装，按 cwd 判定 profile 后快照 | 任何最终落到 pnpm 的变更（含市场绕过 dsh CLI 的路径） | PATH 前置 1 个 sh 文件 | 高（pnpm 调用形式稳定） | ⭕ 可选加固 |
| **D. profile 变更 watcher** | entrypoint 常驻监视 `package.json`/`pnpm-lock.yaml`，变化即快照 | 能提前于 node_modules 写入，但不保证 | 中 | 高 | ❌ 不该做主方案：变化瞬间才触发，硬链接快照可能拍到半完成树；只适合做**审计/告警** |
| **E. 上游扩展点** | 让 dshmarket / dsh 提供 pre-op hook | 最干净 | 需上游配合 | — | 📮 中长期：值得提 issue（见 §8） |

### 4.1 A 与 B 的取舍（都实测可行，失败面不同）

| | A · 同名入口守卫 | B · NODE_OPTIONS --import 补丁 |
| --- | --- | --- |
| 依赖 | 市场 `dshArgv()` 复用 argv[1]（+ `restartLaunch()` 同一来源） | Node 标准 env 语义 + `child_process` 公共 API（已实测：DSH 不清洗 NODE_OPTIONS，`--import` 会继承到子进程） |
| 覆盖 | 市场安装/更新/卸载、市场自重启后的调用、用户手敲 `dsh plugin` | 任何在 dsh 进程树里发起的插件命令，含「市场换实现」与直接调 pnpm 的未来路径 |
| 失败面 | **窄**：只插在 dsh 主进程入口一个点 | **宽**：进入所有 node 子进程（pnpm 及其派生、agent 的 bash 工具链）；`--import` 模块抛错会让子进程直接起不来 |
| 审计语义 | 准：守卫明确知道「这是一次 plugin 写操作」，可写精确 reason | 弱一些：需要从 spawn 形状里反推意图 |
| 主要风险 | 市场改掉 argv[1] 复用策略（正则）后失效（失效即静默回到现状，不会更糟） | 与 v0.4.0 P0-1「降级代码反噬」同类：守卫必须写成绝对不抛的幂等模块；且只能由启动环境注入（写进 `.env` 会被 DSH 拒绝启动） |

> **组合建议（默认）**：A 与 B **都上**，共用同一个「判定 → 去重 → 调 `rescue snapshot`」内核，只在挂载点不同：
>
> - **B（NODE_OPTIONS）为主**：不依赖任何 dshmarket 内部实现，覆盖「市场换实现 / 直连 pnpm」等一切路径；
> - **A（同名入口守卫）为辅**：成本极低（1 个文件 + PATH 一行），语义最准（明确「插件写操作」，reason 直接可读），
>   且与 B 的**失效条件互不重叠**——B 失效于「NODE_OPTIONS 被清洗」，A 失效于「市场不再复用 argv[1]」，同时失效概率很低；
> - **C 可选**（POSIX 加固）：仅在还想覆盖「有人绕过 dsh CLI 直接对 profile 跑 pnpm」时启用。
>
> 若只允许上一层：**要覆盖面选 B，要语义与可审计性选 A**。两者都必须带「启动前自检 + 失败熔断」（§5.5）。

---

## 5. 推荐实现：market-guard

### 5.1 组件与接线

```
scripts/market-guard.mjs          # 守卫本体（node ESM，也可放 scripts/rescue-guard/dsh）
  ↓ Dockerfile COPY + chmod +x
/opt/dsh-rescue/bin/dsh           # 必须叫 dsh（argv[1] 后缀契约），且必须是 node 可执行的文件
ENV PATH=/opt/dsh-rescue/bin:$PATH    # 放在 /opt/dsh/bin 之前；npm 升级 dsh 不会覆盖它
```

守卫通过 `fs.realpathSync('/opt/dsh/bin/dsh')` 动态解析真实入口（升级后自动跟随），
`/opt/dsh/bin/dsh` 不存在时回退 `readlink /opt/dsh-seed/bin/dsh`。

`scripts/rescue-supervise.sh` **无需改动**（它用 `dsh ...` 走 PATH，天然命中守卫）；
若担心 PATH 被改动，可另加一行「守卫存在则显式用绝对路径」。

### 5.2 守卫伪代码（关键行为）

```js
#!/usr/bin/env node
import { realpathSync } from 'node:fs'
import { spawnSync } from 'node:child_process'

const argv = process.argv.slice(2)
const MUTATING = new Set(['add', 'remove', 'update', 'uninstall', 'install', 'rebuild'])

const profile = profileFrom(argv) ?? process.env.RESCUE_PROFILE ?? 'web'   // --profile <p> 优先
const isPluginMutation = argv[0] === 'plugin' && argv.some(a => MUTATING.has(a))

if (isPluginMutation && process.env.RESCUE_MARKET_GUARD !== 'off') {
  try {
    const reason = reasonFor(argv)                    // 见 5.3 的 reason 契约
    spawnSync('rescue', ['snapshot', '--reason', reason], {
      env: { ...process.env, RESCUE_PROFILE: profile },
      stdio: ['ignore', 'ignore', 'inherit'],          // 绝不污染 stdout（市场解析 ndjson 进度）
      timeout: Number(process.env.RESCUE_GUARD_TIMEOUT_MS ?? 120000),
    })
  } catch { /* 快照是「附加」能力：任何异常都不得阻断安装 */ }
}

const real = realpathSync('/opt/dsh/bin/dsh')
const r = spawnSync(process.execPath, [...process.execArgv, real, ...argv], { stdio: 'inherit', env: process.env })
process.exit(r.status ?? 1)
```

行为要点：

1. **stdout 必须干净**：市场用 `stdio: ['ignore', 'pipe', 'pipe']` 读 ndjson 进度，守卫日志一律 `stderr`。
2. **退出码与信号语义保持**：`inherit` 转发 + `process.exit(status)`；市场 `killTree`（POSIX 用进程组 `-pid`）能一并杀掉守卫与真实 pnpm。
3. **execArgv 透传**：`[...process.execArgv, real, ...argv]`，否则源启动（`--import tsx/esm`）会失效。
4. **不递归**：守卫只转发一次（真实 CLI 进程内不再有市场）。
5. **非变更命令零副作用**：`plugin list`、`--version`、`plugin --help` 只转发。

### 5.3 与既有 rescue 机制的契约（最容易踩的点）

| 契约 | 要求 | 依据 |
| --- | --- | --- |
| `reason` 前缀 | 必须能被 `/^plugin (add|remove) (\S+)/` 匹配，否则自愈失去「最近一次变更」归因 | `scripts/diagnose.js` 解析 `newest.reason` 得到 `lastChange` |
| `reason` 建议写法 | `plugin add <pkg>` / `plugin remove <pkg>`；更新就是市场的 `plugin add name@ver`，天然匹配 | 与 `scripts/rescue` 的 plugin 分支完全一致 |
| profile | 按 CLI 里的 `--profile` 传 `RESCUE_PROFILE`，`meta.profile` 会被 `rescue_restore` 校验，跨 profile 恢复会被拒绝 | `librescue.sh` 的 `rescue_restore` 有 profile 一致性检查 |
| 回退目标优先级 | 守卫快照（`plugin *`）在 `rescue_pick_rollback_target()` 里属于**第二轮**；`boot-healthy*` 优先。这是对的：只有基线被证明能启动过 | `librescue.sh:236-258` |
| 冗余/重复 | 一次写操作会派生**多次** spawn：安装 `add` → retarget → validate（install.ts:232/242/326）、失败重试（install.ts:105/106/113/125/134/144）、update 失败回滚（routes.ts:620/780）。**只有第一次 spawn 是「变更前」**，其余都是「变更后」；判据只能取「与最新快照是否等价」，因为 spawn 侧拿不到 HTTP 请求上下文 | 复用 `rescue_snapshot_is_redundant()`（`librescue.sh:215`）；这正是 §3 证据 2 里基线被挤掉的放大器。重试时 live 已被改，可能拍到「半成品」快照——它只能当第二轮回退目标，故 `boot-healthy` 优先（§5.4）必须保留 |

### 5.4 必须一起改的保留策略（否则守卫会挤掉基线）

§3 证据 2 已经证明：`RESCUE_KEEP=3` 下，市场连续变更会把 `boot-healthy baseline` 删掉。建议二选一：

- **钉住（推荐）**：`rescue_prune()` 增补「先保一份最新的 `boot-healthy*`，再按最老删除其它」——基线是自愈第一轮的唯一目标，
  且体积/语义与普通快照不同，钉住 1 份完全够用。
- **分池**：`plugin *` 类守卫快照使用独立的 `RESCUE_GUARD_KEEP`（默认 2），与基线池互不挤占。

### 5.5 失败安全（三层，必须有）

> 教训（v0.4.0 P0-1）：为「绝不影响启动」写的降级代码，反而让容器完全起不来。守卫位于启动路径上，必须同样谨慎。

1. **守卫内部**：快照调用整体 `try/catch`，异常只写 stderr 与 `rescue.log`，继续转发（A 方案里快照失败绝不阻断安装）。
2. **守卫异常**：A 方案里解析真实入口失败时，直接 `exit 127` 并把真实路径候选打印到 stderr（不静默假装成功）。
3. **supervise 侧兜底**：`rescue-supervise.sh` 支持 `RESCUE_MARKET_GUARD=off`，或检测「PATH 里第一个 dsh 不是守卫」时打印告警；
   镜像构建期单测断言守卫的 `--version` 与 `/opt/dsh/bin/dsh --version` 一致。
4. **启动前自检**：entrypoint 在启动 dsh 之前做一次「守卫可用性探测」（`guard --self-test` 或直接 `--version` 对比），
   不通过就**自动降级**为真实入口 + 打印告警。B 方案同理：`NODE_OPTIONS` 只在探测通过后才 export。
5. **失败熔断**：守卫连续 N 次（默认 3）快照失败后，在本次 boot 内自我禁用（写 `$DSH_HOME/.rescue/state/guard.json`），
   避免「每次安装都白等一次超时」；下次 boot 重置。
6. **防双快照**：A 与 B 同时上线时，守卫调用 `rescue snapshot` 前设置标记（如 `DSH_RESCUE_SNAP_DONE=1`）并沿用同一份去重状态，
   否则一次安装会因为「A 命中 + B 命中 + 市场可能派生多次 runPlugin」而产生 3~5 份等价快照，反而挤掉保留窗口。

### 5.6 开关与环境变量（与既有 RESCUE_* 风格一致）

```
RESCUE_MARKET_GUARD=on|off        # 默认 on；off = 守卫只转发不拍快照
RESCUE_GUARD_REASON_TAG=          # 可选：附加到 reason 尾部（如 cwd 来源标记），不影响前缀契约
RESCUE_GUARD_TIMEOUT_MS=120000    # 单次快照上限，超时只跳过快照、不阻断安装
```

---

### 5.7 B / C 挂点的差异点（同一内核，换挂载）

**B · NODE_OPTIONS 挂点**

```sh
# entrypoint（或在 Dockerfile 里 ENV）。必须拼接，不能覆盖用户已有值：
export NODE_OPTIONS="--import=/opt/dsh-rescue/market-guard.mjs${NODE_OPTIONS:+ $NODE_OPTIONS}"
```

```js
// market-guard.mjs —— 顶层绝不抛错；只包一层，不改调用语义
try {
  const cp = require('node:child_process')
  const mod = require('node:module')
  for (const k of ['spawn', 'spawnSync', 'execFile', 'execFileSync']) {
    const orig = cp[k]
    cp[k] = function (...a) { if (shouldSnapshot(a)) snapshotOnce(); return orig.apply(this, a) }
  }
  mod.syncBuiltinESMExports()   // 关键：让 ESM 的 `import { spawn }` 也拿到补丁（已实测）
  // 注意：guard 自身不要用 ESM `import { spawn } from 'node:child_process'`，用 createRequire 拿 CJS 对象
} catch { /* 静默：绝不能让子进程起不来 */ }
```

要点：

- **必须调用 `syncBuiltinESMExports()`**：dshmarket 的编译产物是 ESM（`lib/dsh-cli.js` 的 `import { spawn } from 'node:child_process'`），
  而 ESM 命名导入是对 builtin facade 的**取值快照** —— 只改 CJS 导出对象而不 sync，实测**命中 0 次**。
  本机实测（Node v24.21.0）三种情形全部命中：①patch+sync 后首次 ESM import；②**先 ESM import（facade 已创建）再 patch+sync**；③`spawn` / `spawnSync` / `execFile` 三种调用。
  即：只要守卫在进程最早期执行且自带 sync，就不必赌「宿主进程里有没有别的插件先 import 过」。
- 判定要覆盖两种形状：`<node> <bin.js> plugin --profile <p> <mutating>`（市场的路径）与 `pnpm <mutating>` 且 cwd 为 profile（等价于 C 方案）。
- **幂等 + 静默**：该模块会被 pnpm 及其全部 node 派生进程加载，任何 stdout 输出都可能污染市场正在解析的 ndjson 进度流。
- **只能在启动环境注入**：写进 `.env` 会被 DSH 直接拒绝启动（`NODE_OPTIONS` 属 app-boot 的 bootstrap-only 名单）。

**C · pnpm 包装挂点（可选加固）**

- PATH 前置 `pnpm` shim：按 `$1` 判定变更子命令 + `$PWD` 是否为 `$DSH_HOME/profiles/$RESCUE_PROFILE`，命中才快照，随后 `exec` 真实 pnpm。
- 必须对 `pnpm --version`（市场的 `probePnpm`）与 `pnpm store path`（store 清理）**零副作用直通**。
- 解析真实 pnpm 时要排除自身（用绝对路径或 `readlink -f` 跟随 symlink），否则递归。

## 6. 测试计划（沿用 scripts/t/test-*.sh 黑盒风格）

| 用例 | 断言 | 对应风险 |
| --- | --- | --- |
| `test-market-guard-matrix.sh` | `plugin add/remove/update` 命中；`plugin list`、`--version`、`plugin --help`、`pnpm add`（非 plugin）不命中 | 误伤 |
| `test-market-guard-before-change.sh` | 用 pnpm 桩改 live，断言**快照内是变更前内容**、`reason` 正确 | 时序 |
| `test-market-guard-reason-contract.sh` | 快照落盘后 `diagnose.js` 能从中解析出 `lastChange.kind=plugin-add` | 自愈归因 |
| `test-market-guard-fail-safe.sh` | 快照失败 / `rescue` 不存在 / profile 不存在 → 退出码透传、安装照常完成 | 启动与安装不被拖累 |
| `test-market-guard-prune-pin.sh` | `RESCUE_KEEP=2` 下连拍 3 份守卫快照，`boot-healthy` 仍在 | §3 证据 2 |
| `e2e-market-guard-on-host.sh` | 容器内真的打开市场点一次安装 → `rescue snapshots` 多出一份 `plugin add ...`，且 `rescue rollback --dry-run` 指向它 | 端到端 |

---

## 7. 风险与边界

1. **依赖市场实现细节**：`dshArgv()` 的 argv[1] 复用与正则。它自 dshmarket #13 起就存在且是刻意设计，但**跨大版本仍可能变**。
   缓解：C（pnpm 包装）与 B（NODE_OPTIONS）作为独立加固层；上游 issue（§8）把它变成正式契约。
2. **守卫在生产启动路径上**：见 §5.5。守卫只应「透传 + 附加」，不做任何可能失败的判断性逻辑。
3. **`hardlink` 模式的快照可被就地改写污染**（既有问题）：pnpm 解包一般不会就地改写硬链接，但原生模块重建会；`rescue verify` 已能检测。
   市场变更频繁的部署可考虑 `RESCUE_SNAPSHOT_MODE=copy`（磁盘换确定性）。
4. **开销**：每次插件写操作多一次 `cp -al`（秒级 ~ 数秒）+ 一次快照冗余检查；对用户点一次安装的场景完全可接受。
5. **并发**：`next_snap_name()` 已用 `mkdir` 原子抢号，守卫与健康基线并发安全；market 侧 `withMutationLock`（routes.ts:455-478）保证同一时刻只有一条插件命令，
   「全部更新」也是前端串行循环（每次一个 `/dsh-market/update` 请求），不会出现守卫并发写。
6. **Desktop 宿主形态不适用**：dshmarket 在 Desktop 运行时会走 `desktopPnpm` 服务（不经 `child_process.spawn`）。dsh-docker 是本机 web 宿主，不在此列；
   若将来支持 Desktop 形态需重新评估（守卫的 B 挂点会失效，A 挂点取决于 argv[1]）。
7. **两处「market 自己先改再 spawn」的例外**：`/dsh-market/restore` 与 `/dsh-market/approve-builds`（§2.1）。它们是配置/恢复类操作，快照价值低但无害。

---

## 8. 上游建议（可直接作为 issue 文本）

**给 dshmarket**：

- 在 `runDshPlugin()` 之前支持一个可选的外部前置钩子，例如读取 `DSH_MARKET_PRE_OP`（一条命令，参数含操作与包名），
  或**自动检测**：若 `$DSH_HOME/.rescue` 存在且 PATH 上有 `rescue`，则安装前调用 `rescue snapshot --reason "plugin add <pkg>"`。
  对 dsh-docker 用户这是零配置；对其它部署无影响。
- 或者在 `dshArgv()` 旁提供 `DSH_MARKET_DSH_ENTRY` 覆盖入口，让外部 wrapper 有正式挂点。

**给 dsh（DeepSeek Harness）**：

- `dsh plugin` 子命令支持 pre/post 钩子（如 `DSH_PLUGIN_PRE_CMD` / `DSH_PLUGIN_POST_CMD`），让「变更前快照」成为通用能力，而不是各发行版各自包装。
- 或在 profile 层暴露 `dsh.profile.hooks`。

---

## 9. 工作量与建议排期

| 项 | 内容 | 规模 | 依赖 |
| --- | --- | --- | --- |
| T1 | `scripts/market-guard.mjs`（B 挂点）+ `scripts/rescue-guard/dsh`（A 挂点，同名入口）+ Dockerfile / entrypoint 接线 + `.env.example` 变量 | 1 天 | 无 |
| T2 | 保留策略钉住 `boot-healthy`（`librescue.sh`） | 0.5 天 | T1 可并行 |
| T3 | 5 个单测 + 1 个 e2e（§6） | 1 天 | T1/T2 |
| T4 | 文档：`docs/{zh-CN,en}/06`、`03`、`README`、`CHANGELOG` | 0.5 天 | T1/T2/T3 |
| T5 | 上游 issue（dshmarket / dsh） | 0.5 天 | 无 |

验收口径（若将来实施）：容器内真实打开市场点一次安装 → `docker exec dsh rescue snapshots` 出现一条 `plugin add <pkg>`，
其内容等于安装前；随后 `docker exec dsh rescue rollback --dry-run` 指向它；装坏插件导致启动失败时，
自愈能在「同一 boot 内多次变更」的情况下仍精确回退到该次操作之前。

---

## 10. 决策记录（2026-09-14：不实施）

**决策：不实施本方案的任何容器侧改动。** 市场安装/更新继续只享受 boot 级兜底（`boot-healthy` 基线快照 + 启动自愈回滚）。

**理由**

1. **主场景已覆盖**：装坏 → 下次启动失败 → 自愈优先回退 `boot-healthy`（`rescue_pick_rollback_target()` 第一轮），这条链路不依赖单次操作快照。
2. **补的缺口很窄**：本方案只补「同一 boot 内 ≥3 次变更且中途坏掉」的精确粒度 —— 需要用户在一次运行里连续大量改插件。
3. **成本位置差**：入口守卫与 `NODE_OPTIONS` 注入都落在**容器启动路径**上，自身出问题就是「容器起不来」（与 v0.4.0 P0-1 同类风险），
   用可用性换边际粒度不划算。

**复评触发条件（满足其一即值得重新评估）**

- 真实发生「市场连续变更后启动失败，但现存快照都不在想要的变更点之前」；
- `RESCUE_KEEP` 窗口被市场变更快照挤占，`boot-healthy` 基线缺失导致自愈退化为 report-only（`rescue.log` 里可见 prune 掉 baseline）；
- dshmarket 或 dsh 自身提供了正式 hook（届时 §5 的守卫可整体不做，只需接钩子）。

**可独立复议的最小改动（不随本方案绑定）**

- `rescue_prune()` 钉住最新一份 `boot-healthy*`（约 10 行 + 1 个单测）：只防止市场变更快照把唯一回退点挤出 `RESCUE_KEEP` 窗口，不碰启动链。
  仅当观察到基线被 prune 时再单独做这一条。

**零成本路径**

- §8 的上游建议仍可照提：成本在上游、对 dsh-docker 用户零维护 —— 让 dshmarket 支持 pre-op hook，或让 `dsh plugin` 提供 pre/post 钩子。
