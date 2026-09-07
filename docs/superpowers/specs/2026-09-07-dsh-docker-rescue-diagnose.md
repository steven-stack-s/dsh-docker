# DSH Docker 插件救援增强 —— 自动排查 · 根因归因 · 智能自愈（rescue-diagnose）设计规范

> 日期：2026-09-07 ｜ 目标仓库：dsh-docker（分支 main，与 dev 源码同基线，均含已交付 rescue 模式）
> 关联文件：entrypoint.sh / scripts/librescue.sh / rescue / scripts/probe-ready.js / Dockerfile / docker-compose.yml / .env.example / docs/zh-CN/06-救援模式.md、04-故障排查.md
> 状态：待用户复核（新增能力设计规范，落地 docs/superpowers/specs/）

## 0. 一句话

在已交付的「救援模式（rescue：boot 探测 + 自动回滚 + 救生舱）」之上，增加一条**证据驱动的诊断与自愈链**：当 dsh 启动失败或运行期崩溃时，entrypoint 自动抓取证据、归因到「根因 + 变更上下文 + 疑似肇事插件」，按保守决策矩阵执行「摘插件 / 回快照 / 报告」闭环，并把每次事故与处置写成可审计的 **incident**，供新增人读命令 `rescue report` 呈现——全程严守红线（绝不动 cordis.patch.yml 与任何会话 / 记忆 / 配置 / 凭据）。

## 1. 背景与现状（已核对的现有能力）

现有 rescue（dev 分支已交付）只解决「boot 失败后机械回滚」：

| 现状能力 | 机制 | 缺口（本次要补） |
|---|---|---|
| boot 失败自动回退 | entrypoint 监督 dsh 子进程，probe 127.0.0.1:3081 窗口(120s)，失败且 live≠最新快照 → 回滚重试(预算 RESCUE_KEEP+1) | 只回滚到「最新且不同」快照，**不做根因归因**、不写 incident、不摘插件、无 report |
| 救生舱 lifeboat | RESCUE=1 / 回滚失败兜底，干净最小 profile | 无变化 |
| 插件操作封装 | rescue plugin add/remove 变更前自动快照 | 只留四件套快照，meta.json 只有 created+dsh，**不记录触发原因/操作上下文**（归因缺证据） |
| 运行期崩溃 | boot healthy 后 entrypoint `wait $child`；dsh 崩 → 容器退出 → docker restart 重新监督 | **无运行期崩溃归因**；重启后全新进程，不知「上次为何崩」 |
| 审计日志 | rescue.log（追加，含 snapshot/restore/lifeboat/boot exhausted） | 只有「发生了什么」，无「为什么」、无结构化 incident |

关键架构事实（决定本设计形态）：
- 主程序 /opt/dsh 与插件树 $DSH_HOME/profiles/web 分卷；插件操作**只改动四件套**（package.json / pnpm-lock.yaml / pnpm-workspace.yaml / node_modules），**不碰** cordis.patch.yml / sessions / storages / settings.yaml / .credentials.yaml / auth（已核实）→ 摘插件与回快照都只落在四件套内，天然守红线。
- 快照根 $DSH_HOME/.rescue/ 与插件树同卷，是证据与状态的落脚点（cp -al 硬链 / 状态文件 / incident / 报告都放这里）。
- entrypoint 已把 dsh 作为子进程监督并 source librescue.sh；librescue 是 rescue 命令与 entrypoint 的共享 POSIX sh 库。
- dsh boot 的 stdout/stderr 现直接进容器日志（docker logs），entrypoint 拿不到逐次 boot 的机器可读输出 → 归因缺第一手日志，须在每轮 boot 尝试时**捕获** dsh 输出到证据目录。
- 本沙箱无 docker / 无 dsh 真机 → 归因规则、摘插件对 cordis.patch.yml 的实际影响等，只能在用户真机做宿主机验收（沿用上期 e2e 模式）。

## 2. 目标与非目标

### 目标
1. 覆盖三类触发（决策①）：**启动失败**、**运行期崩溃**、**变更前基线缺失/存在**，都能归因并给出处置。
2. 智能自愈闭环（决策②）：按归因选择「**摘插件（targeted remove）** / **回快照（rollback）** / **报告（report-only）**」，全部自动执行并留痕，绝不静默或无限 crashloop。
3. 崩溃自动归因写 incident + 人读 `rescue report`（决策③）：entrypoint 每次触发诊断/自愈都写结构化 incident；`rescue report` 聚合呈现。
4. 严守红线（决策④）：所有动作只落在插件树四件套 + $DSH_HOME/.rescue 状态与 incident；cordis.patch.yml、sessions、storages、settings.yaml、.credentials.yaml、auth 与记忆库**一律只读或不动**。
5. 交付形态（决策⑤）：先此规范 + 实施计划，再逐任务实现（POSIX sh + node + 宿主机 e2e），沿用 SDD 逐任务评审。

### 非目标
- 不做 LLM 自由判断：归因是**确定性、启发式、模式驱动**，保守优先，宁可「报告」也不乱拆。
- 不做运行时在 PID1 内无限拉起 dsh（保持现有「崩溃 → docker restart 交接」模型，见 §6.2）。
- 不自动改 cordis.patch.yml、不自动禁用插件配置、不重装主程序 npm 全局包（主程序仅保留既有 dsh-reinstall 轻量兜底）。
- 不做跨机 / 分布式。

## 3. 证据模型（诊断的一切输入都来自这里）

归因必须「有据可依、可复核、不猜」。定义统一**证据目录**与**状态文件**，全部落在 $DSH_HOME/.rescue/ 下，由 entrypoint 与 rescue 命令共同读写。

```
$DSH_HOME/.rescue/
  log/rescue.log                     # 既有审计日志（追加，保持）
  incidents/                          # 新：结构化事故记录
    <incident-id>.json
  evidence/                           # 新：逐次 boot/崩溃的第一手证据快照
    boot-<seq>-<ts>/
      dsh.stdout.log                  # 该轮 dsh 子进程输出（entrypoint tee 捕获）
      dsh.stderr.log
      context.txt                     # 归因输入摘要：状态文件 + 最近审计 + 快照 meta + 环境
  state/
    last-run.json                     # 新：跨容器重启的最近运行状态（boot/healthy/exit + 原因）
    selfheal.json                     # 新：自愈预算/计数（防无限自动摘/回退）
  snap-<NNNN>/meta.json               # 既有 + 增补 trigger/reason 字段
  dsh-version-last-good.txt           # 既有
```

快照 meta.json 从 {created,dsh} 增补为记录**触发上下文**（snapshot 由谁触发：manual / plugin add <pkg> / plugin remove <pkg> / auto-rollback-pre / selfheal-remove <pkg>）——这是「变更前基线」能否被归因的关键。

## 4. 根因归因（诊断器，node）

新增 node 诊断脚本 `scripts/diagnose.js`（与 probe-ready.js 同目录/同风格）。入口在**每次「该轮 boot 判定失败」或「检测到运行期崩溃」**时被调用；输入 = 该轮证据 + state/last-run.json + 最近审计 + 快照 meta + 环境，输出 = 结构化归因 JSON：

```jsonc
{
  "incidentId": "inc-20260907T...-a1b2",
  "phase": "boot" | "runtime",
  "symptom": { "type": "never-listening" | "child-exited-early" | "healthy-then-crash" | "no-baseline", "detail": "..." },
  "changeContext": { "baselinePresent": bool, "baselineSnapshot": "snap-0002"|null, "lastChange": {kind,pkg,ts}|null, "lastGoodSnapshot": "snap-0003" },
  "rootCause": { "category": "...", "offendingPlugin": "..."|null, "confidence": "...", "rationale": "..." },
  "recommendedHeal": "remove-plugin" | "rollback" | "report-only",
  "recommendedTarget": "pkg" | "snap-XXXX" | null
}
```

归因是**确定性规则**。规则（diagnose.js 内，模式表做成顶部可调数据，真机调参）：

1. **phase 判定**：boot 失败=窗口内从未让 3081 监听或子进程先于就绪退出；runtime 崩溃=曾 healthy（state 记 healthy_ts）后子进程异常退出（exit≠0 或信号）。
2. **changeContext / 基线**：审计 + 快照 meta 找「最近一次插件变更」及其「变更前快照（=基线）」。无对应快照（用户没走 rescue 封装、直接 pnpm 改）→ baselinePresent=false → 归因 no-baseline。
3. **boot 归因优先级**（保守，宁报告勿错拆）：
   a. 证据日志命中已知**插件加载失败**模式（error pattern + 包名正则）→ plugin-load-failure、offendingPlugin=命中包 → 若该包正与 lastChange 新增一致 → confidence=high → remove-plugin（摘该新增插件）。
   b. 否则若 lastChange 是新增/升级插件且有基线 → confidence=medium → rollback（回基线，最确定性）。
   c. 否则基线缺失且无法定位 → 视日志归类或 unknown → report-only（提示人工，绝不盲拆）。
   d. 日志明显非插件（Node 版本 / EADDRINUSE / OOM / 主程序）→ 相应归类 → report-only（或既有主程序兜底提示），不自动回退插件树。
4. **runtime 归因**：healthy 后崩溃。崩溃前紧邻插件变更 → 疑插件运行期崩溃 → 摘该插件（中置信）或回基线；长时间 healthy 且无近期变更 → 多为非插件（升级/内存/偶发）→ report-only + 提示，避免把无关崩溃误回退。

> 真机不确定点（§10）：DSH boot 失败日志的具体措辞与包名可提取性。模式表须真机校准。设计上把模式表放 diagnose.js 顶部数据常量，便于一次调参。

## 5. 智能自愈决策矩阵（入口在 entrypoint，执行器复用 librescue）

自愈在 **entrypoint 监督循环内**触发（boot 失败路径），在**崩溃后的下一次容器启动**上补判（runtime 路径 §6.2）。按 recommendedHeal 分派，所有动作只落插件树四件套 + 状态/incident：

| recommendedHeal | 动作（全自动、留痕） | 红线校验 |
|---|---|---|
| remove-plugin | 先快照现场 → 用**既有封装** `dsh plugin --profile web remove <pkg>`（只动四件套，不碰 cordis.patch.yml）→ 重启重试 | ✅ 只动四件套 |
| rollback | 回退 diagnose 给的基线/known-good 快照（复用 rescue_restore，只动四件套）→ 重启重试 | ✅ 只动四件套 |
| report-only | 不自动改；写 incident；boot 失败则视 RESCUE_AUTO 语义进 lifeboat 或 exit 交 restart 策略；提示 `rescue report <id>` | ✅ 无改动 |

**自愈护栏（防无限 / 防误伤）**：
- state/selfheal.json 记**自愈预算**：同一 incident 触发源（根因+目标）在单容器生命周期内自动摘插件/回退合计不超过上限（建议 REMOVE≤2、ROLLBACK≤2，超过转 report-only + lifeboat）。
- 每次自动摘插件前确保**绝不触 cordis.patch.yml**：只经 `dsh plugin remove` 封装，不手写 patch。
- 每次自愈动作前先 `rescue_snapshot`（保留现场供回查），再执行。
- 全部动作写 rescue.log + 更新对应 incident 状态。

## 6. 运行模型

### 6.1 启动失败（boot）路径（增强现有监督循环）
entrypoint 每轮 boot 尝试 **tee 捕获** dsh 子进程输出到 evidence/boot-<seq>-<ts>/ → 判定失败后：更新 last-run.json → 调 diagnose.js 归因 → 按矩阵执行自愈（含护栏、现场快照）→ 写 incident → 自愈后 continue 重试；预算/能力耗尽 → lifeboat 或 exit（沿用现有）。

### 6.2 运行期崩溃（runtime）路径 —— 保持 docker-restart 交接模型
**不在 PID1 内无限拉起**（避免崩溃风暴刷屏/掩盖真因）。模型：
- dsh healthy 后 entrypoint 记 last-run.json 的 healthy_ts + pid；
- dsh 子进程退出（exit≠0 / 信号）→ 先更新 last-run.json（exit_code/signal、uptime、崩溃前是否刚有插件变更）→ 再 exit（现有行为，让 docker restart 干净重启）；
- **下次容器启动** entrypoint 读 last-run.json：若上次「异常退出」→ 调 diagnose（runtime 归因 §4.4）→ 满足条件（崩溃前紧邻插件变更）才自动处置；否则只写 incident + 提示。
→ 补「运行期崩溃归因」又不推翻上期定稿的 PID1 监督模型与 docker restart 兜底。

### 6.3 变更前基线（决策①）
- 走 rescue 封装（plugin add/remove）已自动在变更前快照 → 该快照即**基线**，meta 记 trigger（含被增/删包名），归因直接用。
- 直接 pnpm 改未走封装 → 无基线 → 归因 no-baseline → report-only 或视日志摘插件（可确定肇事包时）→ 明示「无变更前基线，建议先 rescue snapshot」。
- 新增 `rescue snapshot --reason <text>`（可选）让手动快照也能带触发上下文。

## 7. incident（结构化事故记录，决策③）

**entrypoint 崩溃自动归因 → 写 incident**。incident=一次「失败+归因+自愈」完整可审计记录，落 $DSH_HOME/.rescue/incidents/<incident-id>.json。追加/不覆盖（id 含时间戳+随机后缀），原子写（temp+rename）：

```jsonc
{
  "id": "inc-20260907T153512-8f3a", "created": "2026-09-07T15:35:12+08:00",
  "phase": "boot"|"runtime", "trigger": "probe-timeout"|"child-exit"|"manual-report",
  "symptom": { "..." : "..." },
  "changeContext": { "baselinePresent": bool, "lastChange": {...}|null, "lastGoodSnapshot": "..."|null },
  "rootCause": { "category": "...", "offendingPlugin": "..."|null, "confidence": "...", "rationale": "..." },
  "selfHeal": { "recommended": "...", "target": "..."|null,
    "actions": [ { "kind":"snapshot|remove-plugin|rollback", "target":"...", "ts":"...", "outcome":"ok|fail" } ],
    "outcome": "recovered|recovered-remove|recovered-rollback|unrecovered-lifeboat|unrecovered-exit|report-only" },
  "evidenceRef": "evidence/boot-0003-.../",
  "redline": { "cordisPatchTouched": false, "userDataTouched": false }
}
```

`redline` 断言：每次写 incident 前由 entrypoint 把「本次自愈实际动作清单」记入，供 report 与人复核；若触碰（不应发生，属 bug）report 用醒目标记提示。

## 8. 新增命令（人读为主，决策③）

在既有 `rescue` 上扩展（POSIX sh，复用 librescue）：

| 命令 | 行为 |
|---|---|
| `rescue report` | 聚合人读总览：DSH 版本 / profile / 快照列表与指针 / 最近 audit 尾部 / incident 汇总（最近 N 条：时间、phase、rootCause.category、offendingPlugin、selfHeal.outcome）|
| `rescue report <incident-id>` | 单条 incident 详情人读版（归因理由+自愈动作+evidence 指针+redline 断言）|
| `rescue report --json` / `report <id> --json` | 机器可读输出 |
| `rescue incident list` | 列出 incident 文件 |
| `rescue snapshot [--reason <text>]` | 既有 + 可选触发原因（写进 meta）|
| `rescue doctor` | 既有只读诊断增补：evidence/state/incident 目录健康、上次运行状态 |

report 聚合由 `node scripts/report.js` 实现（sh 做壳），POSIX sh 不直接解析 JSON。

## 9. 配置与环境变量

沿用既有 RESCUE / RESCUE_AUTO / RESCUE_START_TIMEOUT / RESCUE_KEEP / RESCUE_PROFILE。新增：
- `RESCUE_SELFHEAL=on`（默认 on）：on=允许自动摘插件/回退闭环；off=只诊断+写 incident+report，不自动改（红线之上的自动化总开关）。
- `RESCUE_REMOVE_LIMIT=2`、`RESCUE_ROLLBACK_LIMIT=2`：自愈预算（§5）。
- `RESCUE_DIAGNOSE_EVIDENCE=on`（默认 on）：on=每轮 boot tee 捕获 dsh 输出到 evidence/；off=省盘但归因退化为只靠 state+audit。
- `RESCUE_INCIDENT_KEEP=20`：incident/evidence 轮转上限（绝不轮转快照）。

## 10. 测试策略
- **沙箱内（无 docker）**：sh -n / node --check 全过、无 bash 专有语法；单元测试（沿用 scripts/t/，临时 DSH_HOME）：librescue 新函数（meta trigger、现场快照、incident 原子写/不覆盖/轮转）；diagnose.js 用**夹具证据**喂入断言归因输出（坏插件命中 / no-baseline / runtime / OOM 各分支）；report.js 输出含 incident 字段。
- **宿主机 e2e（留用户验收，沿用上期 e2e 风格）**：造坏插件→重启→断言 diagnose 归因+自动摘/回退+incident 写入+`rescue report` 可读+数据仍在+cordis.patch.yml 未动；运行期崩溃→重启→断言 incident 记 runtime+按需自愈；no-baseline→report-only；RESCUE_SELFHEAL=off→只诊断不改；**真机校准** diagnose 模式表 + 确认 `dsh plugin remove` 确不触 cordis.patch.yml。

## 11. 本次新增决策（供用户复核）
1. 归因=确定性规则（node diagnose.js），非 LLM；保守优先，宁报告勿错拆。
2. 摘插件=复用既有 `dsh plugin remove` 封装（只动四件套），不手写 cordis.patch.yml。
3. 运行期崩溃保持「崩溃→docker restart 交接 + 跨重启 last-run.json 归因」，不在 PID1 内无限拉起。
4. 快照 meta.json 增补 trigger/reason（变更上下文=归因的基线证据）。
5. incident 追加写盘 + redline 断言；自愈有预算护栏（REMOVE/ROLLBACK 各限次）。
6. 红线之上加总开关 RESCUE_SELFHEAL=on（on 自动闭环 / off 只诊断+报告）。

## 12. 交付物清单
- scripts/diagnose.js（新，node 归因）
- scripts/report.js（新，node，report 聚合/单条/JSON）
- scripts/librescue.sh（改：meta trigger、现场快照带 reason、incident 写/轮转、snapshot --reason）
- rescue（改：+report / report <id> / --json / incident list / snapshot --reason）
- entrypoint.sh（改：boot tee 捕获、调 diagnose、决策矩阵执行、写 incident、runtime last-run 补判）
- scripts/t/* 单元测试 + 新增 e2e-rescue-diagnose-on-host.sh（宿主机验收）
- Dockerfile / docker-compose.yml / .env.example（RESCUE_SELFHEAL / *_LIMIT / INCIDENT_KEEP / EVIDENCE 透传 + /opt/dsh-rescue 拷入 diagnose/report）
- docs/zh-CN/06-救援模式.md、04-故障排查.md（zh/en）更新；README 引用

## 13. 复核后转入实施计划（写入 docs/superpowers/plans/2026-09-07-dsh-docker-rescue-diagnose.md）

