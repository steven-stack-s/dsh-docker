# 更新日志 (Changelog)

本项目的版本遵循双版本 tag 约定：`v<项目版本>-dsh<dsh版本>`，如 `v0.3.0-dsh0.1.2-rc.1`，其中后缀为构建时锁定的 DSH 版本（见 Dockerfile 的 `ARG DSH_VERSION`）。推送匹配 `v*` 的 tag 会触发 GitHub Actions 自动构建多架构镜像并发布到 ghcr.io（见 .github/workflows/docker-image.yml）。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)。

## [v0.4.0-dsh0.1.5-rc.1] - 2026-09-12

> 本版是一次大范围的自愈体系加固：8 个 P0、12 个 P1 与主要 P2 全部修复，落地 14 个新功能点，
> 并做了真实 Docker 宿主上的端到端验证（见下方各 Wave 小节与 issues/2026-dsh-docker-v0.3.7-深度评估.md）。

### Fixed
- **降级路径不再被 errexit 反噬（P0-1）**：`rescue_supervise()` 内显式 `set +e`，并对 `attempt_evdir`、`rescue_log`、incident 写入逐处容错。此前证据目录建不出来（卷满 / 只读卷 / 权限）时，`ed="$(attempt_evdir)"` 的失败会因 entrypoint 的 `set -e` 直接终止 PID1 —— **dsh 从未被启动**，恰是 rescue 最该救的场景；自愈成功后写 incident 失败也会让本可继续的重试被放弃。新增 `scripts/t/test-supervise-loop.sh` 覆盖三条降级路径。
- **`RESCUE_AUTO=off` 现在真的关闭自动干预（P0-3a）**：总闸移到 `rescue_do_heal()` 入口，与 `RESCUE_SELFHEAL` 取与。此前它只在"无证据兜底"分支被检查，有证据时 diagnose 驱动的自愈照常自动改写插件树，与 `.env.example` / 06 文档承诺的"不自动干预"不符。
- **CI 发布门禁（P0-5）**：新增 `unit-tests` job（跑 `scripts/t/test-*.sh`，build 通过 `needs` 依赖它）；tag 校验改严格正则 —— `v0.3.7-dsh` 这类空 dsh 版本此前能通过校验，使 `npm install -g @deepseek-ai/dsh@` 静默装 latest（假锁版镜像）；新增 `concurrency` 防并发构建让 `:latest` 回退；workflow 内表达式一律经 `env:` 传入（消除脚本注入面）；tag 构建后新增镜像自证步骤（镜像内 `/opt/dsh-seed/bin/dsh --version` 必须等于 tag 后缀）。
- **e2e 假绿（P0-5）**：`e2e-rescue-on-host.sh` 的健康判定由 `grep -iE "healthy|listening"` 改为锚定 `[entrypoint] dsh healthy on 127.0.0.1:` —— 原模式会被探针**失败**行 `[probe] L1 tcp: not listening yet` 命中，"首次尝试失败 + 发生回滚"即可让脚本打印 PASS。`e2e-rescue-diagnose-on-host.sh` 同步收紧，并修掉 `wait_for_log` 把模式内空格当分隔符（`healthy on` 退化成 `healthy|on`，任何含 "on" 的行都算命中）的问题；该脚本 A 段红线被破时改以非 0 退出（此前恒 exit 0，只打印 note）。

- **`rescue_restore` 的失败不再被当成成功（独立评审发现）**：此前函数最后一条命令是 `rescue_log`（几乎恒成功），于是 `cp` 失败也返回 0 —— 自愈据此记 `rollback ok`、消耗预算，而插件树实际只被 `rm -rf` 删掉、并未恢复。现在关键拷贝失败即 `return 1`，`rescue_do_heal` 如实记 `fail` 并转 report-only；CLI 的 `rescue rollback` 失败也不会再打印 "restored"。新增 `scripts/t/test-librescue-restore.sh`（并用"回放旧实现必红"验证该测试确实能捕获它）。
- **CI 镜像自证步骤修正（独立评审发现）**：`docker run <img> <cmd>` 在本镜像（`ENTRYPOINT ["dsh-entrypoint"]`）下只会把 `<cmd>` 当作 CMD 追加给 entrypoint，而 entrypoint 不消费 `$@` —— 那会照常走 seed/socat 并真的启动 dsh web：起得来就永不返回（CI 挂死），起不来也要等满自愈窗口。已改为 `--entrypoint /opt/dsh-seed/bin/dsh`，失败时保留 smoke 的 stderr；两个 job 各加 `timeout-minutes` 作纵深防御。
- **发布串行化分组修正（独立评审发现）**：`concurrency.group` 原按 `github.ref` 分组，而 `:latest` 是所有 tag 构建**共享**的输出、各 tag 的 ref 互不相同 → 根本不排队。改为全局单组 `image-publish`。
- **tag 形态校验收紧（独立评审发现）**：`v0.3.7-dsh0`、`v0.3.7-dsh-note-dsh0.1.5`、`v0.1.0-dsh0.1.2-rc.1+build` 此前都能通过校验（分别导致 npm 按 0.x 解析、切分出 `-note-dsh0.1.5`、Docker tag 含非法 `+`）。现要求 `v<X.Y.Z>-dsh<X.Y.Z>[-预发布]`，字符集限定为 Docker tag 允许的 `[A-Za-z0-9_.-]`；分支 slug 同步做字符清洗。
- **分支构建不再复用 gha 缓存**：分支构建的 `DSH_VERSION=latest` 是固定字符串，缓存会让 `npm install -g @deepseek-ai/dsh@latest` 那一层命中旧缓存、不再跟随 npm 上的最新版（与 workflow 注释承诺冲突）。tag 构建仍启用缓存以加速可复现构建。
- **文档更正救生舱日志标记**：`lifeboat enter` 只写在 `rescue.log`，docker logs 里是 `booting clean lifeboat profile`（中英 04/06 共四处 + e2e 注释）。

### Added
- `scripts/ci-image-tags.sh`：可单测的镜像 tag / DSH 版本解析（CI 调用），含严格的 tag 格式校验。
- `scripts/t/test-librescue-restore.sh`：锁定 `rescue_restore` 的"成功返回 0 / 失败必须返回非 0"契约。
- `scripts/t/test-ci-image-tags.sh`：6 个用例，含两个"必须拒绝"的负例（空 dsh 版本、非数字 dsh 版本）。
- `scripts/t/test-supervise-loop.sh`：用 stub dsh / probe / diagnose 驱动真实监督循环，覆盖 healthy 路径、三条降级路径与 `RESCUE_AUTO` 总闸语义。

#### Wave 2 · Fixed（原始实现）
- **证据目录被自己删掉（隐蔽的真机级隐患）**：`rescue_evidence_prune` 按**目录名**字典序删"最老"，而目录名是 `boot-<attempt>-<ts>`、`attempt` 每次容器重启都从 1 重新计数 —— 重启后第一轮的 `boot-1-<新>` 会被排到上一轮的 `boot-2-<旧>` 之前、当成最老删掉。后果是新证据**刚建出来就被删**，紧接着 `mkfifo` 失败、`EVLOG` 为空，diagnose 拿不到证据只能 report-only，表现为"自愈偶尔不灵"且日志上完全看不出原因。现改为按创建时间（mtime）排序，并显式保护"当前这一轮"的目录。
- **失败路径丢证据尾部**：`rescue_close_ev` 原来直接 kill tee，而 tee 对文件是块缓冲 —— 最后一段输出（往往正是崩溃原因）会凭空消失。现在先关闭 fifo 写端让 tee 读到 EOF 并刷盘，最多等 2s 才强杀。
- **回滚可能"恢复"到 no-op 目标**：diagnose 建议的目标常常就是最新快照，而自愈每次动作前会先拍现场快照 —— 最新快照很可能与 live 完全相同。此前会照样"回滚"、记 `rollback ok` 并消耗预算，而插件树毫无变化。现由 `rescue_pick_rollback_target` 跳过与 live 相同的快照、优先跳过 `selfheal-*` 现场快照；一个可用目标都没有时如实转 report-only。
- **自愈预算会永久失效**：预算落在数据卷、跨重启累计且永不重置，用满 `RESCUE_REMOVE_LIMIT`+`RESCUE_ROLLBACK_LIMIT` 次后该部署**永久**只能 report-only，而文档写的是"单容器生命周期内"。现引入滑动窗口（`RESCUE_SELFHEAL_WINDOW`，默认 24h）：窗口过期自动清零、自愈能力恢复。

#### Wave 2 · Added
- `rescue verify [snap]`：快照完整性校验 —— 快照 meta 记录 node_modules 树哈希，可检测"快照已被就地改写污染"（hardlink 模式的固有风险），并校验 profile 归属，避免跨 profile 误恢复。
- `rescue snapshots`：快照清单（编号 / 创建时间 / 模式 / 与 live 是否相同 / 变更原因），直接回答"哪个快照还能用"。
- `rescue selfheal status|reset`：自愈预算可观测、可重置（此前既看不到余额也无从恢复）。
- `rescue rollback [--to <snap>] [--dry-run] [--list]`：显式指定目标、预演、并拒绝"目标与 live 相同"的无意义回滚。
- `RESCUE_SNAPSHOT_MODE=copy`：可选的真正不可变快照模式（`cp -a` 独立副本）；回滚时也按快照模式选择复制方式，避免把 copy 快照与 live 重新绑回同一 inode。
- `rescue_snapshot_is_redundant`（库函数）：判断"回滚到某快照是否有效果"，同时考虑配置文件指纹与 node_modules 树哈希。
- 新测试：`test-librescue-restore.sh`（原子性与失败可见性）、`test-snapshot-integrity.sh`、`test-selfheal-budget.sh`；`test-supervise-loop.sh` 新增 C6（目标选择）、C7（证据尾部）、C8（修剪排序）。

#### Wave 2 · Fixed（独立评审发现并已修复）

- **降级复制会把依赖树套成两层（Critical）**：`cp -al` 失败后降级 `cp -a` 时没有先删目标 —— GNU cp 在失败前可能已经建出目标目录，于是 `cp -a SRC DST`（DST 已是目录）变成 `DST/SRC`，产出 `node_modules/node_modules/pkg` 这种嵌套树**而且还返回 0**（自愈据此记 rollback ok、消耗预算，树却更坏）。快照创建端有同样写法，会导致快照自身嵌套而 verify 全部"通过"。现在降级前显式 `rm -rf` 目标目录。
- **回滚事务只还原了 node_modules（Critical）**：配置文件替换失败时，package.json 已换成快照值、pnpm-lock.yaml 还是坏的，live 停在"半新半旧"的混合状态，日志却谎报 "live tree left unchanged"。现在旧配置文件先 rename 进 `bak`，回滚时连 node_modules 一起完整还原。
- **证据修剪在删除失败时无限自旋（Critical）**：`rescue_evidence_prune` 在 PID1 启动路径上，`rm` 持续失败时旧实现永不退出（单核跑满、容器永远起不来、没有任何日志）。现在删除失败即停止并写审计日志。
- **回滚目标可能挑到"现场快照"**：判据只有"与 live 不同"，第二轮放宽还会选中 `selfheal-*`（自愈动作**之前**的坏现场），把用户推回故障状态。现在优先 `boot-healthy baseline`、**禁止**现场快照作目标，没有可用目标时如实 report-only；跨 profile 的快照会被 `rescue_restore` 直接拒绝（此前 meta.profile 只有 verify 用）。
- **`rescue verify` 的两处误判**：meta 记录过 treeHash 但快照的 node_modules 已丢失时曾判 "OK"（随后回滚会把 live 的依赖树一并删掉）；旧快照（无 treeHash）被判"已损坏"，升级后会把用户诱导去删掉唯一可用的回退点 —— 现已区分为"跳过完整性校验"。
- **`SAME`/`differs` 判据过窄**：只看 package.json + lockfile，copy 模式快照或 pnpm 重装后依赖树完全不同仍显示 SAME 并告诉用户"回滚没有效果"。新增 `rescue_snapshot_is_redundant`，把 node_modules 树哈希一并纳入判据，`rescue snapshots` 与 `rollback --to` 都改用它。
- **"最新/最老"在同秒时退化到编号序**：`meta.created` 只有秒级精度，同秒连拍时排序落到字典序上，prune 可能淘汰好的 baseline 而留下现场快照。现在用目录 mtime 作为次键。
- **回滚并发与残留**：新增 `$RESCUE_DIR/.restore.lock`（陈旧锁自动接管，不会永久卡死）避免 CLI 手动回滚与 entrypoint 自愈并发重入；并清理上次被 SIGKILL 留下的 `.rescue-restore.*` / `.rescue-old.*` / `.rescue-bak.*` 工作目录（此前无任何 GC，会残留在插件树里）。
- **`--to` / `--reason` 缺参时静默退出**：dash 下 `shift 2` 参数不足会直接终止脚本，原本的 `|| shift` 兜底根本不可达且没有任何提示。现在显式判参并打印 usage。

#### Wave 3 · Fixed：可用性与安全短板

- **socat 转发器现在有监督（F2）**：3080 是用户的唯一入口，此前却是无人看管的单点 —— 它死掉后 dsh 仍健康、healthcheck 照样通过，用户却彻底失联。现在监督循环在启动窗口与健康运行期持续守护、死掉即重启，并加 `max-children` 上限防止并发连接耗尽容器内存。
- **SIGTERM 转发（P1-1）**：PID1 是 dash、dsh 只是后台子进程，此前 `docker stop` 会让 PID1 立刻退出、命名空间被 SIGKILL，dsh 连落盘机会都没有（会话/记忆有损坏风险）。现在转发给 dsh 并等其优雅退出；计划内停止记为 `stopped` 而非 runtime crash（否则下次启动会写一条假的 runtime incident 把排查带偏）。
- **fifo 读端（P1-6）**：证据链（tee/logtee）在启动窗口内死掉时，shell 仍持有 fifo 读端 —— dsh 的写不会收到 EPIPE，而是在缓冲写满后静默卡住（"容器起来了但完全没反应"）。现在探测期间监控证据链，发现死亡即释放 fd，让 dsh 快速失败而不是假死。
- **自愈靶子校验（P0-8）**：target 来自诊断证据里的**日志文本**，而日志内容可被第三方插件控制 —— 此前 `dsh plugin remove "$target"` 会直接把日志内容当 CLI 参数用（例如 `--global`）。现在校验包名形态（拒绝 `-` 开头与非法字符）并要求它确实是当前 profile 的依赖。
- **`PLUGIN_FAIL_PATTERNS` 真正生效（P1-7）**：该模式表此前定义了却从未参与判定，"是否插件相关"实际只由"日志里有没有带引号的包名"决定 —— 任何打印过 `@scope/x` 的无关日志（配置 dump、第三方库普通报错）都可能被判成插件故障并触发自动摘插件。现在**先**过模式表，**再**提取包名。
- **快照编号竞态（P0-7）**：`next_snap_name` 原是 check-then-act，entrypoint 的健康基线快照与用户 `rescue plugin` 的预防性快照可能撞号并互相覆盖（meta 丢失会让"最新/最老"判定退化成目录 mtime）。现在用 mkdir 原子抢号并自动顺延。
- **L4 客户端激活层探针（F1）**：补上 v0.3.7 自认覆盖不到的白屏盲区 —— 探测时读取响应体，命中 `Failed to load plugins` / `N entries did not activate` 即判不健康。正常实例的 HTML 完全不含这些串（实测 14.7KB 的正常 shell 连 "booting" 都没有），因此不会误报；可用 `RESCUE_PROBE_FAIL_CHECK=off` 关闭。

#### Wave 3/4 · Added

- **自动降级进救生舱（F7）**：自愈与预算都耗尽后写一次性标记，下次启动以干净最小 profile 起来 —— 文档承诺的"自动降级"此前并不存在，用户面对的是无限 crashloop。`RESCUE_AUTO_LIFEBOAT=off` 可关闭，`rescue lifeboat on|off|status` 可手动管理。
- **凭据文件（F8）**：`DEEPSEEK_API_KEY_FILE`（docker secret / 挂载文件）优先于环境变量，密钥不再出现在 `docker inspect` 与 `/proc/<pid>/environ`。
- **`rescue export`（F14）**：一键诊断包（事故 / 状态 / 快照元数据 / 环境摘要 / doctor / 最近启动日志尾部），刻意不含插件树、会话、记忆与任何密钥。
- **容器硬化（F9）**：`no-new-privileges`、`pids_limit`、socat `max-children`；`cap_drop: [ALL]` 与 `read_only` 以注释形式给出（更严格，但部分 NAS/内核组合下需先验证，避免直接破坏部署）。
- **一致性门禁测试（F11）**：`test-compose-wiring.sh` 断言"代码读取的每个可配置变量都能经 compose 注入且出现在 .env.example"、硬化项在位、`start_period > RESCUE_START_TIMEOUT`；`test-credentials.sh` 覆盖凭据文件读取；`e2e-container-selftest.sh`（F12）用一次性容器 + 临时卷 + 随机端口做端到端自检，只断言成功原文、结束即清理。

#### 遗留清理（P1-8 / P1-9 / P2）

- **incident 记账改为"结局已定时写"（P1-8）**：此前在"自愈成功且还有重试预算"时就立刻写、outcome 由 journal 推断 —— 服务随后可能仍然起不来，却已经被记成 `recovered-rollback`；而真正恢复健康的路径又完全不写 incident，"曾故障并已自愈"在事故记录里消失。现在统一在结局已定时写：恢复健康记 `recovered-*`，最终仍失败则**显式**记 `unrecovered`。
- **`RESCUE_KEEP` 语义拆分（P1-9）**：它此前一配置三语义（快照保留数 / 证据保留数 / 启动重试上限 = KEEP+1），改一个会连带改另外两个。现拆出 `RESCUE_MAX_ATTEMPTS` 与 `RESCUE_EVIDENCE_KEEP`，默认仍跟随 `RESCUE_KEEP` 以保持既有行为。
- **`DSH_TRUSTED_HOSTS` 解析加固**：原来用未加引号的 `$(echo ... | tr ',' ' ')` 展开，空白与通配符会把一个条目拆成多个、甚至注入额外参数 —— 而 dsh 对每个白名单项都做 `assertTrustedAuthority`，一个畸形条目就足以让启动失败并白耗自愈预算。现逐项校验（只允许 `[A-Za-z0-9.:_*-]`），非法项丢弃并记审计日志。
- **`librescue.sh` 不再污染 source 方**：去掉文件级 `set -u` —— 它被 entrypoint（PID1）与 rescue CLI 共同 source，擅自开启 nounset 会让"某个变量忘了默认值"直接终止调用方。
- **entrypoint 显式定义 `HERE`**：此前依赖 librescue 恰好也设置了该变量，否则三处兜底路径（diagnose/logtag/logtee）全部失效。
- **文档漂移修正**：`01` 的 `start_period`（60s → 300s）与日志示例（改为实际英文输出）；`02`/`05` 补上"用域名 / NAS IP 访问必须加 `DSH_TRUSTED_HOSTS`，否则页面能开但 `/api` 403"；`03` 补上"跨大版本升级可能不可回读（会话 V3）"的备份与回滚警告；README 的 tag 示例更新为当前版本。

#### 真机端到端验证发现并修复（Wave 5）

在一台真实 Docker 宿主上做了端到端验证（挂载本次改动到容器里实跑），发现两个**单测完全覆盖不到**的缺陷：

- **entrypoint「先用后 source」（Critical）**：`DSH_TRUSTED_HOSTS` 白名单校验与 `DEEPSEEK_API_KEY_FILE` 凭据加载被放在 `source librescue.sh` **之前**，`command -v` 判空后静默跳过 —— 这两项功能在真机上**完全没生效**（真机日志：`WARN trusted Host allowlist produced no usable entry`），而单测只测函数本身、全绿。现已移到 source 之后，并新增 `scripts/t/test-entrypoint-order.sh`：静态断言"entrypoint 里任何 `rescue_*` 调用都必须晚于 librescue 的 source 行"。
- **白名单里的通配符被展开成文件名（Important）**：`rescue_trusted_args` 内部 `for h in $hosts` 未禁用路径展开，条目里的 `*` 会被 glob 成**当前目录的全部文件名**（真机复现：白名单凭空多出一串文件名，且随 CWD 变化）。现在用 `set -f` 包住循环，并把字符集收紧为 `[A-Za-z0-9._:-]`。

真机验证通过项（挂载改动到容器实跑）：白名单只保留合法项、dsh 主进程拿到**文件里的**密钥、完整自愈链路（probe 失败 → 归因 `offender=@scope/broken-bundle` → 自动回滚 → 恢复 healthy → 记 `recovered-rollback` incident）、`rescue` 新命令面（snapshots/verify/selfheal/lifeboat/report/export）、SIGTERM 转发并记 `phase=stopped`、自动降级进救生舱（真的以 `--profile lifeboat` 启动）、socat 被杀后由守护重启（PID 10 → 346）。

#### 可执行位修正

- **入口/测试脚本在仓库里补上可执行位**：`entrypoint.sh`、`rescue`、`scripts/t/*.sh`、`scripts/ci-image-tags.sh`、`scripts/logtag.js`、`scripts/logtee.js` 此前在 git 里是 644（只靠镜像 Dockerfile 的 `chmod +x` 赋权）—— clone 之后直接 `./rescue` 或 `./scripts/t/test-x.sh` 会 Permission denied；真机手工验证用 bind-mount 覆盖时也会丢执行位（本次就踩到过）。现已统一为 100755。
- 新增 `scripts/t/test-script-modes.sh` 门禁：断言上述文件必须带可执行位。`scripts/librescue.sh` / `rescue-supervise.sh` / `diagnose.js` / `report.js` / `probe-ready.js` **保持 644** —— 它们被 `source` 或 `node` 调用，不该靠执行位工作（直接执行 librescue.sh 反而会因缺 DSH_HOME 报错）。
- ⚠ 本仓库的 git 配置是 `core.fileMode=false`，普通 `chmod` 不会被 git 记录：上述模式是用 `git update-index --chmod=+x` 写进索引的。今后新增入口脚本需要同样处理，或把仓库的 `core.fileMode` 设为 `true`。

### Changed
- **回滚改为原子事务**：先在 staging 组装完整新树、成功后再原子切换（node_modules 用 rename 让位/就位，三个配置文件先写同目录临时名再 rename），任何一步失败都执行回滚事务并保持 live 原样 —— 不再出现"先 `rm -rf` 再拷、中途失败留半棵树且已无回退手段"。
- `rescue_snapshot` 的 meta 增加 `profile` / `mode` / `treeHash` 字段（供 verify 与跨 profile 防护使用）。
- `rescue_ts` / `rescue_budget_read` / `rescue_budget_write` 从 `rescue-supervise.sh` 移入 `librescue.sh`：CLI 与监督循环必须共用同一份预算逻辑。
- **`RESCUE_SNAPSHOT_ON_HEALTHY` 接入 compose 与 .env.example**：此前 CHANGELOG 承诺"=off 可关"，但 compose 的 environment 白名单没有它，通过 compose 部署的用户无法关闭。
- 测试加固：`test-supervise-loop.sh` 的 C4 补 fixture 目录前置与"确实进入 abnormalExit 分支"的正向断言（否则 state 目录缺失时该用例会退化成必然通过）、C5 补总闸触发断言；`test-probe-ready.sh` 的固定端口改为按 PID 派生（纳入 CI 门禁后消除 EADDRINUSE flake，连跑 5 次稳定）。
- `rescue-supervise.sh` 的探针路径支持 `RESCUE_PROBE` 覆盖并回退仓库布局（内部钩子，供测试与非镜像布局使用；镜像内 `/opt/dsh-rescue/probe-ready.js` 恒在，正常部署行为不变）。
- 文档与实现对齐：06-救援模式（中英）更正"救生舱自动降级"（当前只有手动 `RESCUE=1`）、`RESCUE_AUTO` 语义、自愈预算的实际生命周期（预算落在持久卷 state/selfheal.json，跨重启累计，而非"单容器生命周期内"）；04-故障排查不再让用户 grep 源码中不存在的 `rolling back`。

## [v0.3.7-dsh0.1.5-rc.1] - 2026-09-10

### Added
- **`probe-ready.js` 分层就绪探测**：启动窗口的健康判定由「TCP 端口可连接」扩展为三层——**L1** TCP 监听、**L2** 在其上完成一次 HTTP 往返、**L3** 连续 `--stable`(默认 2) 次成立。退出码契约不变（exit 0 = 就绪），`rescue-supervise.sh` 的调用语义零变更。
  - L2 **任何状态码都算通过**：装了认证网关（如 `@xgone/dsh-remote`）时，未认证的 `GET /` 返回的是登录页而非应用外壳；若要求 200 + 特定内容，这类实例会被永久判为不健康并触发回滚死循环。故 L2 只证明「HTTP 栈真的能应答」，只有连上了却拿不到任何 HTTP 响应（超时/连接重置）才算失败。
  - 新增可选 `--pid <pid>`：目标进程一消失即立即判失败，把「启动后立刻崩溃」的检测从 `RESCUE_START_TIMEOUT`(默认 120s) 降到秒级（`rescue-supervise.sh` 传入 `$child`；不传则行为与改造前完全一致）。
  - 分层结果以英文 `[probe]` 前缀、按**状态变化**输出：1s 轮询下不刷屏，同时保留「卡在哪一层」的诊断线索。
  - 新增 `scripts/t/test-probe-ready.sh`（用法/HTTP 就绪/仅 TCP 无应答/无监听/`--pid` 秒级失败/`--stable`/旧参数兼容）。

### 已知边界
- **覆盖不到「服务端正常、但浏览器端客户端插件树激活失败」**（如 0.1.2→0.1.5 升级后首启出现的 `25 entries did not activate`）：该类审计只在浏览器端（`dsh-web-frontend`）执行，服务端的端口、HTTP 与客户端模块清单全程正常，探针无从取得差异信号。端到端覆盖需无头浏览器，代价是镜像 +数百 MB、启动变慢十几秒。

## [v0.3.6-dsh0.1.5-rc.1] - 2026-09-10

镜像锁定的 DSH 版本由 `0.1.2-rc.1` 升级至 `0.1.5-rc.1`（tag 后缀同步变更）。CI 依 tag 解析 `DSH_VERSION`（`.github/workflows/docker-image.yml`），故镜像 seed 内即为 0.1.5-rc.1。

### Changed
- **容器日志统一为英文**：`entrypoint.sh` 的 8 处 `elog`（首启播种 / dsh 就绪 / socat 转发 / Host 白名单等，即 `docker logs` 中 `[entrypoint]` 前缀的各行）改为英文，便于日志检索与在非中文环境下的阅读与转发。`rescue` CLI 提示、`rescue report` 及 `diagnose.js` 写入 incident 的诊断文本（`rationale` / `detail` / `kw`）**保持中文**；源码注释与本文档亦保持中文。`scripts/t/` 全量单测通过（9/9）。

### 升级注意（0.1.2-rc.1 → 0.1.5-rc.1）
- 该跨度含**破坏性变更**：会话数据格式升级至 V3（迁移后**旧版不可读**，原文件保留）；插件 Agent API 移除 `ctx.agent`；`Inbox` 改为类型接口；Web 插件面板 Slot 由 `conversation` 迁移为 `main` 的 `conversation` key（原 Detail 面板移除）；Web `minimal` 默认仅提供持久 shell。升级前请确认 profile 内第三方插件已适配新核心。

## [v0.3.5-dsh0.1.2-rc.1] - 2026-09-10

### Added
- **健康基线快照**：entrypoint 在确认 dsh 健康后自动拍一份基线（`RESCUE_SNAPSHOT_ON_HEALTHY=off` 可关）。插件市场（`dshmarket` 在 dsh 进程内直接改 profile 的 package.json/node_modules）**绕过 rescue 封装、不会拍预防性快照**，此前市场更新后启动失败只能 report-only；现由「变更前已有的健康基线」充当回退点，自愈可自动 rollback 恢复。仅在已被证明可启动的状态下拍，失败不影响启动，并在 rescue.log 记 re-baselining 审计（含 profile 指纹变化提示）。

### Fixed
- **快照编号重用 + 「最新/最老」按字典序误判**（会导致自愈回滚到错误快照）：`next_snap_name` 由「找第一个空缺编号」改为「最大编号 + 1」（prune 删除后不再复用编号）；新增 `rescue_snapshot_newest/oldest`（按 meta.created 排序，缺失回退目录 mtime），`diagnose.js` 的最新快照选取、supervise 的 `newest_snap` / 基线 / remove-escalate 目标、`rescue rollback` 与 `rescue_prune` 全部改用它。真机复现：补位编号下旧快照被当成最新。
## [v0.3.4-dsh0.1.2-rc.1] - 2026-09-09

架构评审 1-7 修复（评审全文与逐项记录：`issues/2026-dsh-docker-架构评审与修复记录.md`）。

### Fixed
- **超时口径统一（#1）**：Dockerfile / compose / `.env.example` 三处健康与救援超时注释统一口径——healthcheck 与 rescue 同判据（都连 127.0.0.1:3081），差异仅在放弃时限；`RESCUE_START_TIMEOUT`(120s) 须小于 compose `start_period`(300s)，否则 rescue 会先于 docker 放弃而误回滚仍在冷启动的 dsh。
- **healthy 后活动证据日志无限增长（#2）**：新增 `scripts/logtee.js`（tee 替身 + 轮转），supervise 证据双写链由 `logtag|tee` 改为 `logtag|logtee`——活动 `evidence/boot-*/dsh.log` 超过 `RESCUE_EVIDENCE_MAX`(默认 20MB) 即归档为 `.1` 重建，磁盘占用有界；logtee 缺失时逐级回退原 tee，容器日志不丢。新增 `scripts/t/test-logtee.sh`。
- **主程序离线恢复缺口（#3）**：entrypoint 首启复制 seed 后不再 `rm -rf /opt/dsh-seed`（seed 在镜像只读层，rm 不释放空间且遮蔽离线恢复源）；`rescue dsh-reinstall` 在 npm 源不可达时改从 seed 覆盖恢复（镜像锁定版本）。
- **remove-plugin 对 bundles 型故障不彻底（#4）**：`rescue_do_heal` 的 remove-plugin 分支在 `dsh plugin remove` 失败时于同一 attempt 升级 rollback，回退到场景快照之前最近的好快照；无更早快照或 rollback 预算不足时保持 report-only，不误改树。
- **entrypoint librescue fallback 不完整（#7）**：librescue.sh 缺失的 no-op fallback 补 `RESCUE_DIR` 赋值（此前未定义，dir 函数路径全错）与 `rescue_dir()`。

### Changed
- **NODE_OPTIONS 与 MEM_LIMIT 联动说明（#5）**：`.env.example` 与 compose 注明 DSH 多进程 RSS 显著超堆值、堆值须远小于 MEM_LIMIT 及 OOM-kill 症状与配比示例。
- **image 默认与 build DSH_VERSION 口径（#6）**：compose 注释 + README 明确默认 `:latest` 跟随最近 tag 发布、锁版用 `DSH_IMAGE=v<项目>-dsh<dsh版本>`、pull 与本地 build 两个来源勿混用。

## [v0.3.3-dsh0.1.2-rc.1] - 2026-09-09

### Changed
- **方案 A 重构：entrypoint 拆分**——`entrypoint.sh` 由 386 行减为 148 行薄壳（只承担 PID1 生命周期与依赖准备）；归因自愈编排（证据捕获 / diagnose / incident / budget / 自愈执行器）与监督主循环抽到新 `scripts/rescue-supervise.sh`，由 entrypoint source 后调 `rescue_supervise()`。行为零漂移（三重逐字等价 + source 契约测试 + 真机回归），Dockerfile 同步 COPY。
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
