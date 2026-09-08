# dsh-docker 架构评审与修复记录

- 日期：2026（会话内，基于 v0.3.3 全量通读）
- 范围：镜像/程序分离 + socat 转发 + rescue 自愈体系 的整体设计、方案、实现审查
- 方法：逐文件通读 Dockerfile / docker-compose.yml / .env.example / entrypoint.sh / scripts/rescue-supervise.sh / scripts/librescue.sh / rescue / diagnose.js / report.js / logtag.js / probe-ready.js / lifeboat.tmpl / GitHub Actions workflow / CHANGELOG
- 状态：评审结论 + 修复实施记录（issues 1-7）

---

## 一、总体评价

项目整体设计扎实且克制：镜像/程序分离 + socat 转发解决 dsh 只监听 loopback 的矛盾；seed 复制实现离线秒级就绪；rescue 自愈体系严格遵守'只动插件树四件套'红线；归因用确定性规则而非 LLM（可测、可解释）；日志逐行时间戳；测试用宿主机 e2e 真实验证。代码注释质量高，CHANGELOG 诚实记录边界。

问题不在方向，而在**一致性、资源管理、少数边界场景的降级完整性**。

---

## 二、问题清单与修复（编号 1-8，本次实施 1-7）

### #1 三处启动/健康超时口径相互冲突
| 位置 | 超时 |
|---|---|
| Dockerfile HEALTHCHECK | start_period 60s |
| docker-compose healthcheck | start_period 300s（覆盖镜像内） |
| rescue 探测 probe-ready.js | RESCUE_START_TIMEOUT 默认 120s |

后果：rescue 判定失败并回滚的门槛（120s）比 docker 健康检查容忍（300s）更激进，慢启动可能被 rescue 误判回滚。
修复：统一 Dockerfile/compose 静态声明，明确 rescue 探测窗口语义并文档化。

### #2 健康运行的 evidence dsh.log 持续增长
v0.3.1 修复后 tee 在 healthy 后继续转发 dsh 输出；rescue_evidence_prune 只在 boot 时按目录数修剪，**当前会话的活动 boot-<latest>/dsh.log 从启动一直写到结束**，高日志长稳运行会无限增长。
修复：新增 logtee.js（stdin→stdout + append 到证据文件，超过阈值轮转/清空），替换 `logtag | tee` 双写链。

### #3 主程序（dsh）离线恢复能力缺失
entrypoint 首启 rm -rf /opt/dsh-seed。一旦 /opt/dsh 卷损坏且离线，rescue dsh-reinstall 依赖 npm 源不可达即失败。rescue 快照只覆盖插件树，不覆盖 dsh 主程序。
修复：改为'复制 seed 后保留在容器可写层之外可用'——首启不删除 seed（或提供离线重装兜底路径），让 dsh-reinstall 离线可从 seed 恢复。

### #4 插件级自愈 remove-plugin 对 bundles 型故障不彻底
remove-plugin 经 dsh plugin remove 只清 dependencies 不清 bundles；对 bundles 条目型启动故障会白耗预算且失败。
修复：diagnose 决策 remove-plugin 失败/疑似 bundles 型时，在同一 attempt 升级为 rollback。

### #5 NODE_OPTIONS 与 mem_limit 无联动
默认 max-old-space-size=1024 + mem_limit 2g。dsh 多进程 RSS 超 1g 堆；用户调小 MEM_LIMIT 而不调 NODE_OPTIONS 易 OOM-killed（与 NAS 对话中断相关）。
修复：文档 + .env.example 明确联动关系与建议比例。

### #6 image 默认与 build 默认的 DSH 版本预期不一致
compose image 默认 :latest（npm 最新漂移），build DSH_VERSION 默认 0.1.2-rc.1（锁定）。用户以为锁版实为漂移。
修复：README/.env.example/compose 注释明示锁定 tag 用法。

### #7 entrypoint 的 librescue 缺失 fallback 不完整
librescue.sh 缺失时 no-op fallback 未定义 rescue_dir（只定义 incident/evidence/state_dir）。若恰好只删 librescue 而 supervise 仍在，引用 rescue_dir 处会崩。
修复：fallback 补齐 rescue_dir 等 supervise 引用函数，并加 source 后必需函数断言。

### #8 TRUSTED_ARGS 逗号切分展开（低风险，本次不做）
`for h in $(echo $DSH_TRUSTED_HOSTS | tr ',' ' ')` 对含特殊字符的 Host 会被展开；域名/IP 场景安全。本次按用户要求仅修复 1-7，此项记录留档。

---

## 三、非问题（已核实，避免误报）

- 快照排序 snap-0001 固定 %04d 补零 + sort：字典序=数值序，>9 也正确。
- cp -al 硬链接快照：pnpm install 多写新文件+rename 不改旧 inode，多数场景安全；跨 FS 已降级 cp -a。
- lifeboat 复用全局 dsh-base/web-app，dependencies 空：符合 dsh 插件语义。

---

## 四、可完善方向（本次未实施，留档）

1. CI 只构建镜像不跑测试，可在 workflow 加容器冒烟（build 后 probe + rescue doctor）。
2. 证据保留数与快照 RESCUE_KEEP 解耦，避免崩溃证据被快照 prune 误清。
3. 健康崩溃可加'崩溃 N 次后自动回退'可配置档位（默认 off）。
4. '通用 Docker 部署'声称 vs 只提供 compose，可补裸 docker run 示例。
5. diagnose.js 模式表收敛为版本化配置文件 + 记录真实故障样本。

---

## 五、修复实施记录

### #1 超时口径统一 —— 已完成
- Dockerfile HEALTHCHECK：补注释明确 start-period 仅 docker run 直用生效，compose 会覆盖为 300s；口径：RESCUE_START_TIMEOUT(120s) 针对每轮 dsh 进程 readiness，须 < docker 放弃时限(300s)。
- docker-compose.yml healthcheck：补注释说明与 rescue 同判据、start_period 与 RESCUE_START_TIMEOUT 的约束关系。
- .env.example RESCUE_START_TIMEOUT：补口径说明 + 与 healthcheck start_period 的联动提醒。
- 验证：sh -n 语法检查。

### #2 healthy 后活动证据日志无限增长 —— 已完成
- 新增 scripts/logtee.js：tee 替身 + 文件轮转器。逐行读 stdin → 写 stdout（docker logs）+ append 到证据文件；超过 RESCUE_EVIDENCE_MAX(默认 20MB)时整段归档为 <file>.1（覆盖旧）并重建文件，磁盘占用有界(~2x 上限)。EOF 自动退出。
- scripts/rescue-supervise.sh rescue_start_child：证据双写链从 `logtag|tee` 改为 `logtag|logtee`（有 logtag+logtee），逐级回退保持容器日志不丢。
- entrypoint.sh：探测 LOGTEE（镜像/仓库布局），默认 RESCUE_EVIDENCE_MAX。
- Dockerfile：COPY + CRLF 处理新增 logtee.js。
- .env.example / docker-compose.yml：新增 RESCUE_EVIDENCE_MAX 透传。
- 新增测试 scripts/t/test-logtee.sh（双写 / 轮转 / stdout 不丢）→ ALL-PASS。

### #3 主程序离线恢复缺口 —— 已完成
- entrypoint.sh：首启复制 seed 后**不再 rm -rf /opt/dsh-seed**（seed 在镜像只读层，rm 不释放空间且会遮蔽离线恢复源）；两处 rm 均移除，保留 seed 供容器内离线恢复。
- rescue dsh-reinstall：npm 重装失败/离线时，若 /opt/dsh-seed 可用则从 seed 覆盖 /opt/dsh（恢复镜像锁定版），否则明确报错。
- 验证：sh -n + rescue status 冒烟。

### #4 remove-plugin 对 bundles 型故障不彻底 —— 已完成
- scripts/rescue-supervise.sh rescue_do_heal remove-plugin 分支：dsh plugin remove **失败**时同一 attempt 升级 rollback，回退到「场景快照(selfheal-remove，已是 newest)之前」最近的好快照；无更早快照或 rollback 预算不足则保持 report-only（不误改树）。
- 验证：test-supervise-source.sh / test-rescue-cmds.sh 回归 ALL-PASS。

### #5 NODE_OPTIONS 与 MEM_LIMIT 无联动 —— 已完成
- .env.example：补 DSH 多进程 RSS 显著超堆值、堆值须远小于 MEM_LIMIT、OOM-kill 症状与配比示例。
- docker-compose.yml NODE_OPTIONS：补联动警示注释。

### #6 image 默认 vs build DSH_VERSION 预期不一致 —— 已完成
- docker-compose.yml：补注释明确默认 :latest 跟随最近 tag 发布、锁版用 DSH_IMAGE=v<项目>-dsh<版本>；pull 与本地 build 两个来源勿混用。
- README.md Releases：补 pinned 版本用法说明。

### #7 entrypoint fallback 缺 rescue_dir / RESCUE_DIR —— 已完成
- entrypoint.sh librescue 缺失 fallback：补 rescue_dir() 定义 + RESCUE_DIR="${DSH_HOME:-/data/dsh}/.rescue"（此前 dir 函数引用未定义的 $RESCUE_DIR，路径全错）。
- 验证：sh -n。

### #8 TRUSTED_ARGS 引号防护 —— 本次未做（按用户要求仅 1-7），留档见第二节。

### 回归
- scripts/t/ 全部沙箱单测：test-librescue / test-librescue-state / test-rescue-cmds / test-diagnose / test-report / test-supervise-source / test-logtee → 全部 ALL-PASS。
- e2e-rescue-*-on-host.sh 需真机 docker，沙箱无法运行，提交前建议在真机跑一次。

