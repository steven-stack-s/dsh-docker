# DSH Docker 救援增强（rescue-diagnose）—— 自动排查 · 根因归因 · 智能自愈 实施计划

> **面向 Agent 执行者：** 必需子技能：superpower-subagent-driven-development（推荐）逐任务执行。步骤用复选框（- [ ]）跟踪。
>
> **环境限制：** 本仓库实现可在任意 shell 环境编写，并用 sh -n / node --check + 单元测试静态/沙箱校验；但「真实 dsh boot 失败归因」「摘插件对 cordis.patch.yml 的实际影响」「运行期崩溃补判」只能在用户部署 DSH 的 Docker 主机验证（执行环境无 docker / 无 dsh 真机）。凡涉容器内运行/重启/真实 dsh 行为的部分，末尾含「宿主机验收」命令段，须在真实主机跑通。

**目标：** 在已交付的 rescue 模式（boot 探测 + 自动回滚 + 救生舱）之上，新增「证据驱动的诊断 + 智能自愈」闭环：启动失败 / 运行期崩溃时自动归因（确定性规则，非 LLM），按决策矩阵执行「摘插件 / 回快照 / 报告」，把每次事故写成可审计 incident，提供人读 rescue report —— 全程严守红线（绝不自动改 cordis.patch.yml 与会话 / 记忆 / 配置 / 凭据）。

**架构：** entrypoint 监督循环每轮 boot tee 捕获 dsh 输出到 $DSH_HOME/.rescue/evidence/，失败/崩溃时更新 state/last-run.json 并调用 node 诊断器 diagnose.js 归因（读证据 + 审计 rescue.log + 快照 meta），输出 recommendedHeal。entrypoint 按矩阵分派：remove-plugin（快照现场 → dsh plugin remove 封装，只动四件套）/ rollback（rescue_restore 回基线）/ report-only；带 selfheal.json 预算护栏，并把「归因 + 动作 + redline 断言」写为 incident。运行期崩溃沿用「崩溃→docker restart 交接 + 跨重启 last-run.json 补判」，不在 PID1 内无限拉起。rescue report 由 node report.js 聚合呈现。

**技术栈：** POSIX sh（dash，禁 bash 专有语法）；node（probe-ready.js 同风格，仅内置 net/fs/path）；cp -al 硬链快照（既有）；docker compose / DSH profile 机制（既有）。

**规格：** ../issues/2026-09-07-rescue-diagnose-spec.md（原 docs/superpowers/specs/，已归入 issues/）。执行者先通读该规范。

## 全局约束

- 红线：任何代码路径**不得**写 cordis.patch.yml、sessions/、storages/、settings.yaml、.credentials.yaml、auth/ 与记忆库。摘插件只经既有 `dsh plugin --profile "$RESCUE_PROFILE" remove <pkg>` 封装；快照/回退只动插件树四件套。
- 所有 shell：#!/bin/sh + set -eu，dash 兼容，禁 bash 数组 / [[ ]] / ${x//} / local(可省略)。
- node 脚本：#! 无需；node --check 通过；仅用 node:net / node:fs / node:path / node:child_process。
- 状态/incident 落在 $DSH_HOME/.rescue/ 下：log/rescue.log（既有）、incidents/、evidence/、state/last-run.json、state/selfheal.json。
- JSON 写盘一律**原子写**（写 <f>.tmp 后 mv 覆盖）；incident **追加不覆盖**（id 含时间戳+随机后缀），新文件重名则加后缀重试。
- 新增 env 仅透传并设默认：RESCUE_SELFHEAL=on / RESCUE_REMOVE_LIMIT=2 / RESCUE_ROLLBACK_LIMIT=2 / RESCUE_DIAGNOSE_EVIDENCE=on / RESCUE_INCIDENT_KEEP=20。既有 RESCUE_* 全部保留语义。
- 命名小写+连字符；审计与 incident 时间统一 `date +%Y-%m-%dT%H:%M:%S%z`。
- 提交信息：`feat(rescue): ...`；单测以 `echo ALL-PASS` / 非零退出表达；静态校验 sh -n 全过、无 CRLF（Dockerfile 有 sed 去 CRLF，库文件保持 LF）。

---

## 文件结构（单职责）

- 修改 scripts/librescue.sh：+状态/incident/evidence 目录常量、json_* 原子写助手、meta trigger 写入、rescue_snapshot --reason、rescue_incident_write / rescue_incident_list / rescue_incident_prune、rescue_state_write/read（last-run / selfheal）。
- 新建 scripts/diagnose.js：node 归因引擎（纯函数式、可夹具测）。
- 新建 scripts/report.js：node，读 incidents/evidence/snapshots/audit 生成人读或 JSON 报告。
- 修改 rescue：命令集扩展（report / report <id> / report --json / incident list / snapshot --reason），sh 壳调 report.js。
- 修改 entrypoint.sh：evidence tee 捕获、last-run 写、崩溃补判、调 diagnose、决策矩阵、写 incident、护栏。
- 新建 scripts/t/test-librescue-state.sh、scripts/t/test-diagnose.sh（夹具）、scripts/t/test-report.sh；新建 scripts/t/e2e-rescue-diagnose-on-host.sh（宿主机验收）。
- 修改 Dockerfile / docker-compose.yml / .env.example：拷入 diagnose.js/report.js + env 透传。
- 文档：docs/zh-CN/06-救援模式.md、04-故障排查.md（zh/en 同步），README 引用；规范/计划已落 docs/superpowers/{specs,plans}。

---

## 任务 1：librescue.sh —— 状态 / 证据 / incident 基础 + meta trigger

**文件**：修改 scripts/librescue.sh；新建 scripts/t/test-librescue-state.sh

**接口**：依赖既有 env/函数（DSH_HOME / RESCUE_PROFILE / RESCUE_KEEP / RESCUE_DIR；rescue_log / rescue_snapshot / next_snap_name / rescue_prune / rescue_restore）。对外产出（任务 2/3/4/5 用）：目录函数 incident_dir / evidence_dir / state_dir；rescue_incident_write（id 去重、落盘、prune、打印 id）/ rescue_incident_list / rescue_incident_prune；rescue_state_write_lastrun / rescue_state_read_lastrun / rescue_state_write_selfheal / rescue_state_read_selfheal；rescue_json_write（原子）/ rescue_json_read；rescue_snapshot 增补 --reason 写 meta trigger。

关键实现（追加到 librescue.sh）：

```sh
incident_dir(){ printf '%s/incidents' "$RESCUE_DIR"; }
evidence_dir(){ printf '%s/evidence' "$RESCUE_DIR"; }
state_dir(){ printf '%s/state' "$RESCUE_DIR"; }

rescue_json_write(){ f="$1"; json="$2"; mkdir -p "$(dirname "$f")"; printf '%s\n' "$json" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"; }
rescue_json_read(){ f="$1"; [ -f "$f" ] || return 1; cat "$f"; }

incident_id(){ ts=$(date +%Y%m%dT%H%M%S); rnd=$(head -c4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n'); [ -n "$rnd" ] || rnd=$$; printf 'inc-%s-%s' "$ts" "$rnd"; }
rescue_incident_write(){ body="$1"; mkdir -p "$(incident_dir)"; id=$(incident_id); while [ -f "$(incident_dir)/$id.json" ]; do id=$(incident_id); done; rescue_json_write "$(incident_dir)/$id.json" "$body"; rescue_log "incident written $id"; rescue_incident_prune; printf '%s' "$id"; }
rescue_incident_list(){ ls -1t "$(incident_dir)"/inc-*.json 2>/dev/null; }
rescue_incident_prune(){ n=$(rescue_incident_list | wc -l | tr -d ' '); keep="${RESCUE_INCIDENT_KEEP:-20}"; while [ "$n" -gt "$keep" ]; do oldest=$(rescue_incident_list | tail -n1); [ -n "$oldest" ] || break; rm -f "$oldest"; n=$((n-1)); done; }
rescue_state_write_lastrun(){ rescue_json_write "$(state_dir)/last-run.json" "$1"; }
rescue_state_read_lastrun(){ rescue_json_read "$(state_dir)/last-run.json"; }
rescue_state_write_selfheal(){ rescue_json_write "$(state_dir)/selfheal.json" "$1"; }
rescue_state_read_selfheal(){ rescue_json_read "$(state_dir)/selfheal.json"; }
```

rescue_snapshot 改造：现尾部直接 `> "$RESCUE_DIR/$snap/meta.json"` 改为先组 meta 字符串再 rescue_json_write；meta 增补 `trigger`/`reason` 字段（取值自可选参数或 env REASON_SNAPSHOT，默认 manual）。rescue_snapshot 签名保持向后兼容：`rescue_snapshot [--reason <text>]`。

**步骤**：1) 写测试 scripts/t/test-librescue-state.sh（临时 DSH_HOME：snapshot --reason 后 meta 含 reason；两次 incident_write id 不同且文件存在；RESCUE_INCIDENT_KEEP=1 下第三次写后只剩 1 份；state roundtrip）。2) 运行确认 FAIL（函数未定义）。3) 实现上述函数 + snapshot 改造。4) 运行 `sh scripts/t/test-librescue-state.sh` → ALL-PASS；`sh -n scripts/librescue.sh`。5) 提交 `feat(rescue): librescue 状态/incident/meta-trigger 基础`。

---

## 任务 2：diagnose.js —— 归因引擎（node，纯函数可夹具测）

**文件**：新建 scripts/diagnose.js；新建 scripts/t/test-diagnose.sh（夹具证据 + 断言各分支）。

**接口**：输入 = 证据目录（dsh stdout/stderr）+ state/last-run.json + 审计 rescue.log + env；输出 stdout 单行 JSON（字段见规范 §4），exit 0。

关键结构：顶部数据常量 `PLUGIN_FAIL_PATTERNS`（真机校准点）+ 包名提取正则；读证据文本；读审计末行找最近 `plugin (add|remove) <pkg>` 及其前序 `snapshot created snap-NNNN` → baselinePresent/baselineSnapshot/lastChange；决策（规范 §4.3/4.4）：命中插件失败模式且 offender=lastChange 新增 → remove-plugin(high/medium)；命中但 offender 非新增 → rollback；未命中但有基线+插件变更 → rollback(medium)；无基线 → report-only；命中非插件(EADDRINUSE/OOM/Node 版本) → 对应 category + report-only；runtime 且久 healthy 无近变更 → report-only。输出 {incidentId, phase, symptom, changeContext, rootCause{category,offendingPlugin,confidence,rationale}, recommendedHeal, recommendedTarget}。

**步骤**：1) 写 test-diagnose.sh：构造 evidence/boot-1/dsh.stderr.log 含 `failed to load plugin '@scope/bad-plugin'`、空 stdout、audit 含 `snapshot created snap-0002` 与 `plugin add @scope/bad-plugin`；调 diagnose.js --phase boot ... 输出重定向，断言含 `recommendedHeal: remove-plugin`、`offendingPlugin: @scope/bad-plugin`、`confidence: high`。2) 运行确认 FAIL。3) 实现 diagnose.js（纯函数 module.exports + 顶层 run；--phase/--evidence/--lastrun/--log 参数解析）。4) `sh scripts/t/test-diagnose.sh` → ALL-PASS；`node --check scripts/diagnose.js`。5) 提交 `feat(rescue): diagnose.js 归因引擎`。

---

## 任务 3：report.js —— 人读 / JSON 报告聚合（node）

**文件**：新建 scripts/report.js；新建 scripts/t/test-report.sh。

**接口**：`node report.js`（总览）/ `report.js <id>` / `report.js --json`；依赖 incidents/evidence/snapshots 与 rescue.log。

**实现**：读 incidents/*.json（容忍缺字段），输出：总览含标题/时间、incident 表（id/created/phase/category/offendingPlugin/outcome）、快照数与 evidence 目录数；某 incident 的 redline 断言为 true → 醒目标记 `!!! REDLINE TOUCH !!!`。`<id>`：单条全字段展开（rationale/actions/evidenceRef/redline）。`--json`：输出合法 JSON。

**步骤**：1) 写 test-report.sh：造 2 个 incident json + 空快照/evidence 目录，运行断言 stdout 含 incident id 与字段、`--json` 输出可被 node 解析。2) FAIL。3) 实现。4) ALL-PASS + node --check。5) 提交 `feat(rescue): report.js 报告聚合`。

---

## 任务 4：rescue 命令集扩展（report / incident list / snapshot --reason）

**文件**：修改 rescue（复用 report.js + librescue 新函数）。

**实现**（在 rescue 的 case 追加）：

```sh
snapshot)
  reason=''; [ "${1:-}" = '--reason' ] && { reason="$2"; shift 2; }
  REASON_SNAPSHOT="$reason" rescue_snapshot ;;
report)
  RPT="$HERE/scripts/report.js"; [ -f "$RPT" ] || RPT="$HERE/report.js"
  node "$RPT" "$@" ;;
incident)
  [ "${1:-}" = 'list' ] && { rescue_incident_list | sed 's#.*/##'; exit 0; }
  echo 'usage: rescue incident list'; exit 2 ;;
```

（HERE 已由开头 symlink 解析逻辑给出；image flat 布局 report.js/diagnose.js 在 $HERE 同目录。注意 rescue 开头 usage 串同步补 report/incident。）

**步骤**：1) 在 scripts/t/test-rescue-cmds.sh 追加断言（report 有输出、incident list 列文件、snapshot --reason meta 含 reason），先跑确认 FAIL。2) 实现。3) ALL-PASS + sh -n rescue。4) 提交 `feat(rescue): rescue report / incident list / snapshot --reason`。

---

## 任务 5：entrypoint.sh —— 证据捕获 + 归因 + 自愈闭环 + incident

**文件**：修改 entrypoint.sh（无 dsh 真机，静态 + sh -n + 沙箱逻辑测试为准，真实归因/自愈留宿主机验收）。

**改造点**（对齐规范 §6）：
1. 每轮启动 dsh 前把 stdout+stderr **tee** 到 evidence/boot-$attempt-$ts/（受 RESCUE_DIAGNOSE_EVIDENCE 门控，目录 mkdir -p）。
2. probe 成功（healthy）后：写 last-run.json（healthy_ts+pid）；随后 `wait $child; rc=$?` —— child 退出先更新 last-run.json（exit rc/signal、uptime、崩溃前是否刚有插件变更），再 `exit $rc`（保留 docker restart 交接，规范 §6.2）。
3. 进入监督 while 前读 last-run.json：若上次异常退出 → 调 diagnose（runtime 路径）→ 满足条件（崩溃前紧邻插件变更且 RESCUE_SELFHEAL=on）则先自愈一次再进循环；并写 runtime incident。
4. boot 失败路径：probe 超时/子进程早退 → 更新 last-run → 调 diagnose → 按 recommendedHeal 走矩阵：remove-plugin（现场快照 REASON_SNAPSHOT='selfheal-remove <pkg>' → `dsh plugin --profile "$RESCUE_PROFILE" remove <pkg>` → 成功则重置重试）/ rollback（rescue_restore 指定 snap → continue）/ report-only（写 incident → 视 RESCUE_AUTO 进 lifeboat 或 exit）。每次自愈前查 selfheal.json 预算（REMOVE/ROLLBACK ≤ RESCUE_REMOVE_LIMIT/RESCUE_ROLLBACK_LIMIT），超限转 report-only+lifeboat。
5. 每次动作后把该 incident 的 selfHeal.actions 追加、outcome 更新，收尾写 redline 断言（本轮未触 cordis.patch.yml 等 → false）。
6. RESCUE_SELFHEAL=off → 只 diagnose + 写 incident + echo 提示，不自动改。
7. 保持既有 max_attempt / has_snap / differs 门控与降级逻辑（无 probe/无 librescue 时仍降级 exec）。

**步骤**：1) 按上述改造（可先把 entrypoint 的 boot-fail 判定与自愈分支写成独立 shell 函数 rescue_boot_heal，便于 source 测试）。2) 静态校验：`sh -n entrypoint.sh`、`sh -n rescue`、`node --check scripts/*.js`、全部单测 ALL-PASS。3) 提交 `feat(rescue): entrypoint 归因 + 智能自愈闭环 + incident`。

---

## 任务 6：Dockerfile / compose / .env 接线

**文件**：Dockerfile / docker-compose.yml / .env.example。

**步骤**：1) Dockerfile `COPY scripts/librescue.sh scripts/probe-ready.js rescue /opt/dsh-rescue/` 追加 `scripts/diagnose.js scripts/report.js`；sed 去 CRLF 列表追加二者；chmod 无需（node 直跑）。2) docker-compose environment 追加 RESCUE_SELFHEAL/RESCUE_REMOVE_LIMIT/RESCUE_ROLLBACK_LIMIT/RESCUE_DIAGNOSE_EVIDENCE/RESCUE_INCIDENT_KEEP（带默认，与既有 RESCUE_* 一致缩进）。3) .env.example 追加同 5 项带注释。4) 静态校验（sh -n；COPY 目标与 rescue/entrypoint 读取路径一致；sed 无破坏）。无 docker 则 `docker compose config` 留宿主机验收。5) 提交 `feat(rescue): Dockerfile/compose/env 接线 RESCUE_SELFHEAL 等`。

---

## 任务 7：文档 + 宿主机 e2e 验收脚本

**文件**：docs/zh-CN/06-救援模式.md、04-故障排查.md（zh/en 同步）、README；新建 scripts/t/e2e-rescue-diagnose-on-host.sh。

**步骤**：1) 06-救援模式新增「诊断与自愈」小节（report / incident list / snapshot --reason、新 env、evidence/incident 说明、红线再声明）；04 故障排查表补「自动归因与 rescue report」入口；zh/en 同步；README 命令速查加 report。2) 新建 e2e-rescue-diagnose-on-host.sh（沿用上期 poll-loop 风格，trap cleanup）：A 造坏插件→docker restart dsh→轮询 `docker exec dsh rescue report` 断言出现 incident、recommendedHeal、数据仍在、cordis.patch.yml 未被改（前后 hash）；B no-baseline（直接改 package.json 加坏包不 snapshot）→ 断言 report-only/提示；C RESCUE_SELFHEAL=off → 只诊断不改；D 运行期崩溃：healthy 后杀主进程→重启→report 记 runtime；E 打印 diagnose 实际命中提醒校准 PLUGIN_FAIL_PATTERNS。3) sh -n；沙箱无法真机，末尾输出「宿主机验收清单」。4) 提交 `docs(rescue): 诊断与自愈文档 + e2e 验收脚本`。

---

## 任务 8：全分支广度评审 + 宿主机验收清单

- [ ] 逐任务已评审（规格 + 质量）；广度评审整链 evidence→diagnose→selfheal→incident→report 端到端一致；红线静态核查（grep 确认无写 cordis.patch.yml 路径）；sh -n / node --check / 全部单测 ALL-PASS。
- [ ] 产出宿主机验收清单：1 docker compose config；2 docker compose up -d --build（/opt/dsh-rescue 含 diagnose.js/report.js）；3 docker exec dsh rescue doctor / report；4 sh scripts/t/e2e-rescue-diagnose-on-host.sh；5 手动 rescue snapshot --reason / incident list；6 RESCUE_SELFHEAL=off 对照；7 确认 cordis.patch.yml 与数据未动。
- [ ] 收尾：finishing-a-development-branch（push/合并由用户定）。