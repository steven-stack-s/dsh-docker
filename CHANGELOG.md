# 更新日志 (Changelog)

本项目的版本遵循双版本 tag 约定：`v<项目版本>-dsh<dsh版本>`，如 `v0.3.0-dsh0.1.2-rc.1`，其中后缀为构建时锁定的 DSH 版本（见 Dockerfile 的 `ARG DSH_VERSION`）。推送匹配 `v*` 的 tag 会触发 GitHub Actions 自动构建多架构镜像并发布到 ghcr.io（见 .github/workflows/docker-image.yml）。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)。

## [v0.3.2-dsh0.1.2-rc.1] - 2026-09-09

### Added
- **日志逐行加时间戳**：entrypoint 消息经新 `elog()` 加前缀 `[YYYY-MM-DDTHH:MM:SS±HHMM]`（与 rescue.log 同格式）；dsh 应用输出经新 `scripts/logtag.js` 行过滤器（fifo → logtag | tee）同样逐行带时间戳，docker logs 与 evidence/dsh.log 同步生效；logtag 缺失时降级为原 tee 直连。entrypoint.sh 修正为可执行模式。
## [v0.3.1-dsh0.1.2-rc.1] - 2026-09-08

### Fixed
- **恢复 healthy 后的完整容器日志**：v0.3.0 的 tee 证据捕获在健康路径调 `rescue_close_ev` 杀掉了 fifo 唯一读端（tee），导致 dsh 在 healthy 之后的所有 stdout 输出无读者而被丢弃——`docker logs` 里 dsh 日志消失（长期还会填满 fifo 缓冲阻塞写端）。现在 healthy 后仅释放 entrypoint 自身写端，tee 持续把 dsh 输出转发到容器日志与证据文件，dsh 退出（EOF）后 tee 自然收尾；boot 失败路径语义不变。
- 新增 `rescue_evidence_prune`：按 `RESCUE_KEEP` 修剪 `evidence/boot-*`，防止 healthy 会话持续镜像的 dsh.log 无限累积。
## [v0.3.0-dsh0.1.2-rc.1] - 2026-09-08

插件**救援体系**完整落地：在 v0.2.0 的「自动回退 + 救生舱」之上，补齐**自动排查 / 根因归因 / 智能自愈**闭环（rescue-diagnose），并新增配套文档与宿主机验收脚本。全程严守红线：只动插件树四件套与 `$DSH_HOME/.rescue`，绝不自动改 `cordis.patch.yml`、会话 / 记忆 / 配置 / 凭据。

### Added
- **librescue 函数库**（`scripts/librescue.sh`）：快照/回滚/状态/incident/meta-trigger 的基础能力（`scripts/t/test-librescue*.sh` 单测）。
- **`rescue` 命令集**：`snapshot`（含 `--reason` 记录变更上下文）/ `rollback` / `status` / `doctor` / `incident list` / `report`（`rescue report <id>` 展开归因与自愈动作）；`plugin add|remove` 先自动快照再调 `dsh plugin`，留回退点。
- **证据驱动的归因引擎**（`scripts/diagnose.js`，确定性规则非 LLM）：捕获每轮 dsh 启动输出到证据目录，读证据 + 审计 + 快照 meta 的 reason，归因根因并按决策矩阵给出 `remove-plugin / rollback / report-only` 建议。
- **incident 记录**（entrypoint 写入，`rescue report` 人读呈现）：归因 + 自愈动作 + redline 断言（`cordisPatchTouched / userDataTouched` 恒为 false）。
- **运行期崩溃归因**：dsh healthy 后异常退出写 last-run（abnormalExit），下次启动记录 runtime incident；**保守默认仅报告、不自动摘/回退**。
- **`rescue doctor` 只读诊断**：报 profile 目录 / package.json / 快照列表 / evidence-state-incident 目录健康 / 上次运行状态。
- 配套**设计规范与实施计划**（`docs/superpowers/specs|plans/2026-09-07-...rescue-diagnose.md`）、中文文档（06-救援模式.md §4b）+ 英文镜像，以及宿主机端到端验收脚本（`scripts/t/e2e-rescue-*.sh`）。

### Fixed
- 回滚在修复点场景下应还原命名基线而非现场快照（`rescue rollback` 的 RB_TARGET 语义）。
- diagnose.js 允许缺证据目录（运行期崩溃仅靠 changeContext 即可归因，不因缺失 evidence 而报错）。
- entrypoint 读 abnormalExit 后真正写入 phase=runtime incident（对齐规范 §6.2 声称的行为）。

### Docs
- 记录真机实测边界：`remove-plugin` 经 `dsh plugin remove` 只清 `dependencies`、不清 `dsh.profile.bundles`；对 bundles 条目型启动故障会如实降级 report-only，可靠自愈是 rollback（见 06-救援模式.md §4b-1）。

## [v0.2.0-dsh0.1.2-rc.1] - 2026-09-07

### Added
- 插件**救援模式**设计定稿与实施计划（docs/superpowers/specs|plans 2026-09-07-rescue-mode）：自动回退 + 救生舱（lifeboat）干净 profile 模板；entrypoint 监督式启动 + 自动回滚；`rescue` 命令集初版。
- Dockerfile 正确复制 lifeboat.tmpl 到子目录（mkdir + `dir/.`）；加 openssh-client；rescue.log 审计完整性。
- 救援模式文档 + 端到端验收脚本；修正 .env.example 的 RESCUE_AUTO 语义注释。

## [v0.1.2-dsh0.1.2-rc.1] - 2026-09-06

### Fixed
- socat 转发上游加 forever+interval 重试，避免 dsh 尚未就绪时出现 Connection refused。

## [v0.1.1-dsh0.1.2-rc.1] - 2026-09-03

### Fixed
- 修复 `/api` 通道 Host 信任围栏导致的连接异常，新增 `DSH_TRUSTED_HOSTS` 白名单参数。

## [v0.1.0-dsh0.1.2-rc.1] - 2026-09-03

### Changed
- 双版本 tag 约定（`v<项目版本>-dsh<dsh版本>`），镜像 label 写入两个版本号；tag 名映射 DSH_VERSION，镜像 seed 与 dsh 版本保持一致。

### Fixed
- 复制 seed 后清理 `/opt/dsh-seed`，避免容器内重复副本；兼容 Windows 开发的 CRLF 换行；支持本地构建并锁定 dsh 版本。

## [0.0.x] - 2026-09-02（初始，未打 tag）

- 初始：DSH Docker 通用部署方案（镜像/程序分离 + 容器内升级 + socat 端口转发）；README 中英双语化 + docs/ 五篇文档；构建时预装 dsh+pnpm 到 seed；ghcr 镜像名转小写。
