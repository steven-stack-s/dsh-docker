# dsh-docker v0.3.7 深度评估：隐藏问题与新功能点

- **评估对象**：`dsh-docker` @ `77962e0`（tag `v0.3.7-dsh0.1.5-rc.1`）
- **方法**：全量通读（78 个文件，核心 ~1700 行）+ 沙箱定向实测 + 3 路独立子代理审计（安全 / 测试CI / 文档一致性）
- **只读**：本评估未修改仓库任何文件；所有实验在 `/tmp` 与临时 `DSH_HOME` 内完成
- **证据约定**：`[实测]` = 本机复现过；`[静态]` = 代码或文档行号推理；`[存疑]` = 需真机 docker 验证

---

## 0. 总体判断

方向与架构是扎实的：镜像/程序分离 + seed 离线秒级就绪、socat 解决 dsh 只监听 loopback、"只动插件树四件套"的红线在代码结构上真实成立（`librescue.sh:126-141`）、归因用确定性规则而非 LLM（可测可审计）。10 个单测全绿（10.7s），注释质量明显高于同类项目。

**问题集中在三处**：

1. **控制面的"承诺"与实现不一致**——文档向用户承诺了 3 个并不存在的能力（关闭自动回退、自动救生舱降级、单容器生命周期预算），用户会据此做出错误判断；
2. **降级路径本身不够健壮**——为"绝不影响启动"而写的降级代码，被 `set -e` 反噬，最坏情况让容器完全起不来；
3. **发布与验证没有门禁**——CI 不跑测试、e2e 存在假绿、tag 校验形同虚设，任何一处回归都能直达 :latest。

**若只修三件事**：P0-1（errexit 逃逸）、P0-2（自愈预算永久失效）、P0-5（CI 门禁 + e2e 假绿）。

---

## 1. P0：隐藏问题（建议本轮修复）

### P0-1 `set -e` 逃逸：降级路径反而让容器起不来 `[实测]`

`entrypoint.sh:2` 是 `set -e`，而 `scripts/rescue-supervise.sh` 由 `. "$SUPERVISE"` **source 进同一 shell**，errexit 全程生效。dash/bash 下 `if` **条件**被豁免，但 `if` **函数体**内的普通命令失败会立即终止整个 shell（已用 dash 与 bash 双向实测确认）。

三处踩中：

| 位置 | 触发条件 | 后果 |
|---|---|---|
| `rescue-supervise.sh:29` `ed="$(attempt_evdir)"` | `attempt_evdir` 的 `mkdir -p` 失败（卷满 / 只读 / 权限） | **dsh 从未被启动**，容器直接以 1 退出 |
| `:241` `rescue_write_runtime_incident`（在 `if` 体内） | node 执行失败或写盘失败 | 监督循环在启动前终止 |
| `:303` `rescue_write_incident "" "$evdir"`（在 `if rescue_do_heal` 的 then 体内） | `.diag.json` 写盘失败、node 异常 | **已成功的自愈被放弃**，不再重试，直接 exit |

实测（受控 harness，真实 source `rescue-supervise.sh`）：

```
A 证据目录创建失败 → exit=1，未打印 "SURVIVED"（应为降级继续）
B incident 写入失败   → exit=1，未打印 "SURVIVED"
```

这与 `:25` 注释的承诺"任何环节失败都回退为普通子进程（绝不让证据捕获阻塞或拖垮监督）"、`:81` "任何失败只记日志、绝不影响启动"**直接矛盾**。而"磁盘满"恰是 NAS 上最常见的故障场景，也正是 rescue 存在的意义。

**修复**：所有"尽力而为"的调用点显式吸收失败——`ed="$(attempt_evdir)" || ed=''`、`rescue_write_incident ... || true`、`rescue_write_runtime_incident || true`；或在 `rescue_supervise()` 入口 `set +e` 并改为显式检查返回码。建议同时加一条"降级路径不得因自身失败中断启动"的单测（stub `mkdir` 失败）。

### P0-2 自愈预算跨重启永久累积 → 自愈会静默永久失效 `[静态]`

`rescue_budget_read/write`（`rescue-supervise.sh:133-143`）读写的 `selfheal.json` 位于 `state_dir()` = `$DSH_HOME/.rescue/state`，而 `DSH_HOME=/data/dsh` 是**持久卷**。预算只在动作成功时自增（`:166 / :183 / :201`），**全文无任何重置逻辑**，`rescue` CLI 也没有 reset 子命令。

因此：累计 2 次 remove + 2 次 rollback 后，**该部署在此后所有重启中永久退化为 report-only**——用户会以为"自愈坏了"，而没有任何日志或命令告诉他预算已耗尽、如何恢复。

文档与实现相反：`.env.example:63` 与 `docs/zh-CN/06-救援模式.md:112` 均写"**单容器生命周期内**自动摘插件 ≤ RESCUE_REMOVE_LIMIT"。

**修复**：预算改为滑动窗口（如 24h 内计数）+ 无故障 N 小时后自动清零；新增 `rescue selfheal status` / `rescue selfheal reset`；更正文档措辞。

### P0-3 控制面承诺与实现不一致（三条）`[静态，其中 2 条经独立复核]`

| # | 文档承诺 | 实现 |
|---|---|---|
| a | `RESCUE_AUTO=off` = 关闭自动回退 / 不自动干预（`.env.example:48-50`、`06-救援模式.md:153,155`、设计规范 :117） | `RESCUE_AUTO` 只在 `rescue-supervise.sh:287` 的 `elif`（无证据兜底分支）被读取；有证据时走 `:282` diagnose 分支，**完全不检查它**，只受 `RESCUE_SELFHEAL` 约束 → 插件树照旧被自动改写 |
| b | 第 2 层救生舱"RESCUE=1 手动 / **自动降级**"（`06:22`、`:78`、审计示例 `:93`） | `boot_lifeboat` 仅有一个调用点 `entrypoint.sh:143`（`RESCUE=1`）；失败路径 `:318-321` 只有 `exit 1` → 交给 `restart: unless-stopped` **无限 crashloop**，没有任何通道能自动起来 |
| c | 自愈预算"单容器生命周期内" | 见 P0-2（持久卷累计） |

a 的后果最具误导性：用户为排查故障而设 `RESCUE_AUTO=off`，正以为系统"只看不动"，插件树却仍被自动改写。

### P0-4 外部链路（socat）是单点，且探针只探内网端口 `[实测 + 静态]`

- healthcheck（`docker-compose.yml:89`）与 rescue 探针（`probe-ready.js`）都只连 `127.0.0.1:3081`；
- 用户实际访问路径是 `宿主 3080 → socat → 3081`（`entrypoint.sh:58`），而 **socat 以 `&` 起、无监督、无重启**。

socat 一旦死掉：容器持续 healthy、rescue 全程不介入、用户完全失联——恰好是"探测口径"与"用户体验口径"不一致导致的静默故障（与该仓库自己反复强调的"端口活着但应用不可用"属同一类问题，只是方向相反）。

另：`socat ...,fork` 无 `max-children`，配合 2g `mem_limit`，外部无认证的并发连接即可耗尽内存触发 dsh OOM-kill（每连接一个进程）。

**修复**：L3 之后再加一层"经 3080 的外部可达性"验证；把 socat 纳入监督（`kill -0` 检测 + 重启）；加 `max-children=64`。

### P0-5 CI 零门禁 + e2e 假绿 + tag 校验形同虚设 `[实测 + 静态]`

- **CI 从不跑测试**：`docker-image.yml` 自 init 起只有 1 个 job（checkout / qemu / buildx / login / build-push）。10 个 CI-ready 的单测（10.7s）没有任何一次在发布前执行。`issues/2026-...架构评审与修复记录.md:69` 已把"CI 加冒烟"列入待办，至今未做。
- **e2e 假绿**：`e2e-rescue-on-host.sh:110` 用 `grep -qiE "healthy|listening"` 判定"恢复健康"，但探针**失败**时会打印 `[probe] L1 tcp: not listening yet`（`probe-ready.js:117`），其 stderr 未重定向（`rescue-supervise.sh:251`）因而进入 docker logs。实测该 grep 命中该失败行 → "第一次尝试失败 + 发生回滚"即可让脚本打印 `PASS`，而服务可能仍未恢复。
- **tag 校验是死代码**：`docker-image.yml:60` 只判 `*-dsh*`。推 `v0.3.7-dsh` 可通过校验，`DSH_VERSION` 从 `TAG#*-dsh` 解析得空串 → `npm install -g @deepseek-ai/dsh@` **静默装成 latest**，镜像 label `dsh-version` 为空，与 CHANGELOG"seed 与 tag 后缀严格一致"直接矛盾。

**修复**：加 `unit-tests` job 并让 build `needs` 它、仅 tag push 才 build；e2e 健康判定锚定成功原文 `[entrypoint] dsh healthy on 127.0.0.1:`；tag 用 `^v[0-9]+\.[0-9]+\.[0-9]+.*-dsh[0-9]` 严格正则；build 后 `docker run --rm <tag> dsh --version` 断言等于 tag 后缀。

### P0-6 硬链接快照**可被写坏**，且指纹看不见 `[实测，子代理复现]`

`librescue.sh:51` 用 `cp -al` 拍快照，`:135` 回滚也用 `cp -al` → 快照与 live 的 `node_modules` **共享 inode**（`scripts/t/test-librescue.sh` 甚至把这做成契约：`FAIL-hardlink`）。任何对 live 文件的**就地改写**（append / sed -i / 原生模块重编）会同时改坏历史快照，而 `rescue_live_differs_from` 只比对 `package.json + pnpm-lock.yaml` 的 md5（`:111-123`），**对 node_modules 的变化完全盲**。

实测链路：拍快照 → 就地 append live 的 `node_modules/pkg/index.js` → 快照同 inode 同步变脏 → `rescue_live_differs_from snap-0001` 返回 **0** → 无证据兜底分支（`rescue-supervise.sh:291-293`）判定"live 未变化"**放弃回滚**。

此前 `issues/` 评审把 `cp -al` 列为"非问题"（理由是 pnpm 走 unlink + rename），但 CHANGELOG v0.3.5 自己承认 `dshmarket` **在 dsh 进程内直接改 profile 的 node_modules**——这条论证的前提不成立。

**修复**：快照改为不可变副本（`cp -a` 或 tar），或在 meta 记录 node_modules 树的 inode/size/mtime 哈希并纳入差异判据；`rescue_restore` 同样不要用 `cp -al` 把 live 重新绑回快照。

### P0-7 快照编号 check-then-act 竞态 `[实测，子代理复现]`

`next_snap_name`（`librescue.sh:24-38`）"读最大号 → +1 → mkdir"无任何锁。两个流程并发即可撞号：`cp: ... File exists`、`mv: cannot stat meta.json.tmp`（meta 丢失 → 时间序判定退化为 mtime）。

真实触发面：**每次 healthy 后的基线快照**（`rescue-supervise.sh:91`）与**用户手动 `rescue plugin add`**（`rescue:64`，且该处**忽略快照失败**）完全可能并发——恰恰发生在"最需要变更前快照正确"的时刻。

**修复**：`mkdir` 原子抢锁（`mkdir snap-XXXX || 重试`）；`rescue plugin` 在快照失败时应中止操作而非继续。

### P0-8 自愈靶子无校验 + CLI 选项注入 `[静态]`

`rescue-supervise.sh:284-286` 从证据 JSON 里取 `recommendedTarget`，来源是 `diagnose.js:29` 的正则 → 允许 `--global` 这类"包名"；`:165` 执行 `dsh plugin --profile X remove "$RM_PKG"`，既无 `--` 分隔，也不校验该包是否真在 profile 依赖里。而失败日志内容可由第三方插件控制（插件自己抛的错误文本）→ 在 root 容器内形成参数注入 / 误删面。

**修复**：加 `--`；包名白名单 `^(@[a-z0-9-~][\w.-]*\/)?[a-z0-9-~][\w.-]*$`；要求目标必须出现在快照 `package.json` 的 `dependencies` 中，否则 report-only。

---

## 2. P1：重要但非阻塞

| # | 问题 | 证据 | 影响 |
|---|---|---|---|
| P1-1 | **无 SIGTERM 转发**：PID1 是 dash，dsh 是后台子进程，全仓无 `trap` | `entrypoint.sh:2`、`rescue-supervise.sh:55-60` | `docker stop` 时 PID1 立即退出 → 命名空间被 SIGKILL → 会话 / 记忆库无落盘机会 |
| P1-2 | **回滚非原子**：先 `rm -rf live/node_modules` 再拷贝 | `librescue.sh:133-135` | 拷贝中途崩溃 / ENOSPC → 只剩半棵树，且此时已无快照可回 |
| P1-3 | **诊断路径丢失指纹校验 → 回滚到"故障现场"**：diagnose 的 `baselineSnapshot` 恒等于"最新快照"，而自愈每次动作前都会先拍现场快照 | `diagnose.js:83-92` + `rescue-supervise.sh:198` vs `:291-293` | 回滚成 no-op 却记录 `rollback ok`，白耗预算并误导用户（旧兜底分支有 `rescue_live_differs_from`，新路径没有） |
| P1-4 | **`rescue rollback` 会回到故障现场**：文档说"回退到最新快照"，而最新快照通常是自愈前拍的坏现场 | `rescue:81`、`06-救援模式.md:55` | 用户按文档操作 = 主动恢复故障状态；且 `rescue status` 只列编号、不显示 reason / 时间，无法辨别好坏快照 |
| P1-5 | **`RESCUE_SNAPSHOT_ON_HEALTHY` 在 compose 下无法关闭**：代码读取，但 compose environment 白名单与 .env.example 均无此项 | 机器化接线核对：这是唯一的真实缺口；CHANGELOG:32 却承诺"=off 可关" | 每次健康都拍基线（挤掉旧快照、占磁盘），用户按文档也关不掉 |
| P1-6 | **fifo 读端被 shell 永久持有**：`exec 3<>"$fifo"` 让 shell 同时持读端与写端；证据链（logtag \| logtee）一旦死亡（如被 OOM-kill，容器只有 2g） | `rescue-supervise.sh:50` | `[实测]` 读者消失后写端不收到 EPIPE，64KB 后进入阻塞 / 背压，dsh 侧缓冲无界增长 → 日志静默丢失或 dsh 卡住；注释只考虑了"避免 open 阻塞" |
| P1-7 | **`PLUGIN_FAIL_PATTERNS` 是死代码**：4 条插件失败模式定义后从未被引用，"是否插件相关"实际由"日志里有没有带引号的包名"决定 | `diagnose.js:10-15`（全仓无第二处引用） | 误判 / 漏判；而文档 `06:125` 恰恰指引用户"调 PLUGIN_FAIL_PATTERNS 参数"——调了不生效 |
| P1-8 | **incident 语义错位**：`:303` 在 `continue` 前写入，outcome 由 journal 推断；真正决定结局的最后一跳（`:311-319`）反而不写 | `rescue-supervise.sh:300-305`、`diagnose.js:187-193` | CrashLoop 中报告显示 `recovered-rollback`，用户以为已恢复 |
| P1-9 | **`RESCUE_KEEP` 一配置三语义**：快照保留数、证据目录保留数、**启动重试上限**（`max_attempt = KEEP + 1`，而 `:211` 注释写"最多 RESCUE_KEEP 次"） | `librescue.sh:80`、`rescue-supervise.sh:71,215` | KEEP=3 → 最坏 4×120s=480s，突破 compose healthcheck 放弃线（300s + 5×30s = 450s），而 `compose:87-88` 的不变式只按单次 120s 叙述 |
| P1-10 | **容器硬化缺省为零**：无 `USER`、无 `cap_drop` / `no-new-privileges` / `pids_limit`，`3080` 绑 0.0.0.0 | `Dockerfile`、`docker-compose.yml:68-82` | LAN 内任何人可借 agent 以 root 执行并读 `/proc/self/environ` 中的 KEY；无认证 DoS |
| P1-11 | **密钥明文经 env**：`DEEPSEEK_API_KEY` 走 environment，`docker inspect` 可见 | `docker-compose.yml:49` | DSH 自身支持 `$DSH_HOME/.credentials.yaml` 与 `$DSH_HOME/.env` 两层，可改走凭据文件 |
| P1-12 | **核心逻辑零覆盖**：`rescue_supervise()`（113 行，含重试 / 预算 / incident / 退出码）与 `entrypoint.sh`（159 行）无任何测试；`test-supervise-source.sh:35` 只断言"函数存在" | `:209-322` | P0-1 / P0-2 / P1-3 全都是这段代码里的缺陷——它们能长期存活，正是因为这里没有测试 |

---

## 3. P2：次要问题

| # | 问题 | 证据 |
|---|---|---|
| P2-1 | `$HERE` 在 entrypoint 中未定义（`librescue.sh:13` 兜底成 `/usr/local/bin`），4 处"仓库布局 fallback"全部失效；`rescue-supervise.sh:216` 更把 probe 路径硬编码为 `/opt/dsh-rescue/probe-ready.js`，非镜像布局直接禁用监督 | `entrypoint.sh:113,120,127,150`、`rescue-supervise.sh:216` |
| P2-2 | `rescue` CLI 重复语句；`report.js:75` `const snaps = countDir(...) ? 0 : 0` 死代码；`diagnose.js:174,184` 的 `cordisPatchTouched` 恒 false，使 `04-故障排查.md:49` 的处置分支成为死代码 | `rescue:82-83`、`report.js:75`、`diagnose.js:174,184` |
| P2-3 | `rescue_evidence_prune` 用字典序排 `boot-<attempt>-<ts>`，`RESCUE_KEEP>9` 时 `boot-10` 排在 `boot-2` 前 → 先删较新证据 | `rescue-supervise.sh:69-77` |
| P2-4 | 默认值四处重复（entrypoint / compose / .env.example / librescue），任一处漂移即静默不一致 | `entrypoint.sh:100-131` 等 |
| P2-5 | `librescue.sh:3` 的 `set -u` 污染 source 方（实测：`. librescue.sh; echo "$X"` 直接报 parameter not set）——今天恰好都有初值，新增可选变量忘默认值即让 PID1 静默退出 | `librescue.sh:3` |
| P2-6 | `DSH_TRUSTED_HOSTS` 未引用展开，且 dsh 对白名单项做 `assertTrustedAuthority` 直接抛错 → 任一项含特殊字符即启动失败，再白耗 120s 自愈预算 | `entrypoint.sh:69-71`（即既有评审 #8，影响面被低估） |
| P2-7 | 文档漂移：`docker-compose.yml:25` 示例仍是 v0.3.6（实际最新 tag v0.3.7）；`README.md:99` 停在 v0.3.0；`docs/zh-CN/01:45` 称 start_period=60s（实际 300s）；`01:56-60` 贴的是中文日志（实际全英文，连英文文档也贴中文）；`04:14` / `06:161` 让用户 grep `rolling back`（代码里不存在该串）；`02-认证与远程访问.md` 与 `05-平台差异.md` 通篇未提 `DSH_TRUSTED_HOSTS`（照着做会得到 `/api` 403） | 多文件 |
| P2-8 | 升级风险未提示：CHANGELOG:27 明示 0.1.2→0.1.5 会话格式升 V3 **迁移后旧版不可读**，而 `03-升级与维护.md:9-12` 直接给升级命令、备份在 §5 且无交叉引用 | `CHANGELOG.md:27`、`03:9-12` |

---

## 4. 已证伪 / 属设计取舍（避免误报）

- **`logtee.js` / `logtag.js` 的 `process.exit` 会截断 stdout**（子代理存疑项）：`[实测]` 20000 行进出均为 20000 行，pipe 与文件两种目标都未截断——**不成立，不列为缺陷**。
- **`.env` 行内注释会污染挂载路径**：compose-go 会剥离 `#` 之后内容，**安全**。
- **`probe-ready.js` L2 任何状态码都算通过**：为兼容认证网关、避免回滚死循环的**正确取舍**（注释已写明理由）。
- **运行期崩溃只报告不自愈**：避免误伤的**保守取舍**，合理。
- **`DSH_TRUSTED_HOSTS` 白名单不可被 socat 绕过**：判据纯 Host 头，与源 IP 无关；但**反向事实**值得写进文档——任何客户端发 `Host: localhost` 即通过栅栏，dsh 注释自述"非认证层"。
- **e2e 不进 CI**：需要真 Docker、会中断 web，取舍合理——但应改为"专用 compose 的一次性容器"（见 F12）后即可进 CI。

---

## 5. 新功能点（按 价值 × 契合度 排序）

### F1 【最高价值】L4「客户端激活层」探针 —— 补上 CHANGELOG 自认的最大盲区

- **背景**：v0.3.7 的"已知边界"写明白屏类故障（升级后 `25 entries did not activate`）探针覆盖不到。但 `[实测]` 我用隔离 `DSH_HOME` 放一个无法解析的 bundle 启动 `dsh web`，进程在**监听端口之前**就抛错退出（`Error: dsh: cannot resolve profile bundle ...`，rc=1）——说明 **bundle 解析类故障本就由 L1 + `--pid` 覆盖**；真正无信号的是"服务端进程健康、客户端插件树激活失败"。
- **方案**：在 L3 之后增加 L4「激活一致性」检查，三档递进：
  1. 抓取 `GET /` 返回的 HTML / 清单，与磁盘上 profile 声明的 bundles / entries 数量比对（服务端生成客户端清单，数量不符即白屏前置信号）；**零新增依赖**；
  2. 匹配启动输出中的失败模式（`did not activate`、`Failed to load`、`Cannot find module`）——需先在真机确认该串是否落到容器日志（这正是 P1-7 中那条死代码本该做的事）；
  3. 可选 `rescue deep-check`：按需（不进基础镜像）用无头浏览器做一次真实激活自检，把"要不要 +数百 MB"交还给用户。
- **价值**：把当前唯一"自愈看不见、用户只能看到白屏"的故障类别纳入体系；**难点**：需先确认服务端是否持有可判定的激活信号；**契合度**：极高（复用现有 fifo 证据链与 diagnose 模式表）；**工作量**：档 1+2 约 0.5～1 天。

### F2 外部链路健康 + socat 守护

- 探针在 L3 稳定后追加"经 3080 的端到端可达性"；监督循环对 socat 做 `kill -0` 检测与重启；`max-children=64`。
- **价值**：消除"容器 healthy 但用户完全失联"的静默故障；**难点**：需避免把 socat 启动早于 dsh 的窗口误判为故障（放在 L3 之后即可）；**契合度**：高；**工作量**：0.5 天。

### F3 自愈预算生命周期修正 + 可观测 / 可重置

- 滑动窗口计数、无故障自动清零、`rescue selfheal status|reset`、启动时把"预算剩余"打进日志与 `rescue doctor`。
- **价值**：修复 P0-2 的永久静默失效；**难点**：旧状态文件迁移；**契合度**：高（state 层已有原子写）；**工作量**：0.5 天。

### F4 PID1 生命周期硬化

- `trap 'kill -TERM $child; wait' TERM INT`；区分"计划内停止"（写 `phase:stopping`，下次启动不计 runtime incident）。
- **价值**：保护会话 / 记忆落盘 + incident 降噪；**难点**：sh 中 trap 与子进程组语义（dsh 可能还有子进程）；**契合度**：高；**工作量**：1 天（含真机 e2e）。

### F5 快照可读性与安全选择

- `rescue snapshots`：列出 时间 / reason / dsh 版本 / 指纹 / 标签（`known-good` / `bad-site`）；`rescue rollback --to <snap> | --list | --dry-run`；默认目标**排除** reason 以 `selfheal-` 开头的现场快照。
- **价值**：修复 P1-4 的用户自毁路径；**难点**：无；**契合度**：极高（纯 librescue + meta 扩展）；**工作量**：0.5 天。

### F6 快照不可变 + 完整性校验（`rescue verify`）

- 快照改 `cp -a` / tar（或至少 `cp -al` 后记录 inode 清单并定期校验）；`rescue verify <snap>` 做树哈希比对，`rollback` 前发现污染则拒绝或改选更早快照。
- **价值**：修复 P0-6，"回退点"从"假设可信"变为"已验证"；**难点**：pnpm 符号链接森林的哈希成本（不跟随 symlink、限制深度）；**契合度**：高；**工作量**：1～1.5 天。

### F7 生命周期自动救生舱（把文档承诺变成现实，或删掉该承诺）

- 连续 N 轮自愈失败后写 marker（`state/lifeboat-requested`），下次启动以 lifeboat profile 起来，并在容器日志 / incident 里明确"已进入救生舱，修好后 `rescue lifeboat off`"。
- **价值**：终结无限 crashloop，给用户一个能操作的入口；**难点**：要与 `RESCUE=1` 手动语义共存、避免"坏树被静默降级而不自知"；**契合度**：高；**工作量**：1 天。

### F8 凭据文件支持

- `DEEPSEEK_API_KEY_FILE`（docker secrets）与 DSH 原生 `$DSH_HOME/.credentials.yaml` 两条路径，`docker inspect` 不再泄密。
- **价值**：消除 P1-11；**难点**：与现有 compose 变量兼容；**契合度**：高；**工作量**：0.5 天。

### F9 容器硬化档（可选但默认接近安全）

- `no-new-privileges`、`cap_drop: [ALL]`、`pids_limit: 256`、可选 `read_only` + tmpfs、可选的 `127.0.0.1` 绑定档（配合 SSH 隧道）。
- **价值**：把"LAN 内可借 agent 获得 root 能力"的风险显式化；**难点**：NAS 平台兼容性（部分内核不支持全部选项，需 graceful）；**契合度**：中高；**工作量**：1 天。

### F10 CI 发布门禁（最小成本、最高杠杆）

- `unit-tests` job（11s）→ build `needs` 它；仅 tag push 才 build/push；`concurrency` 防 :latest 回退；tag 严格正则；`docker run --rm <tag> dsh --version` 断言；workflow 中所有 GitHub 表达式改 `env:` 传参（消除注入面）。
- **价值**：一次性堵住 P0-5 全部四点；**难点**：无；**契合度**：极高；**工作量**：0.5 天。

### F11 文档一致性 lint（`scripts/t/test-docs-consistency.sh`）

- 从源码抽取事实（elog 文案、start_period、compose environment 白名单、rescue 子命令集、.env.example 键集、最新 tag）与 `docs/**/*.md` 逐项断言，挂进 F10 的 job。
- **价值**：本报告 P0-3 / P1-5 / P2-7 共 8 条可被自动拦住；**难点**：需把文案与变量清单抽成单一 manifest；**契合度**：高；**工作量**：1 天。

### F12 e2e 容器化（让端到端测试有资格进 CI）

- 用专用 compose（独立 `DSH_HOME` / 端口 / 预置坏 profile）替代"依赖宿主既有健康容器 + trap 恢复现场"的脚本；断言锚定成功原文而非 `healthy|listening`。
- **价值**：修复 P0-5 的假绿，同时让 e2e 在 CI 可跑；**难点**：CI 内嵌套 docker、耗时；**契合度**：高；**工作量**：1～2 天。

### F13 监督循环分支测试（stub dsh）

- 注入假 `dsh` 可执行文件驱动 `rescue_supervise()`，断言 attempt 次数、预算增减、incident 内容、退出码，以及**降级路径在 mkdir / node 失败时仍能启动**（正是 P0-1 的回归测试）。
- **价值**：为 113 行零覆盖的核心逻辑建立护栏；**难点**：`:216` 的 probe 路径需改为可覆盖；**契合度**：极高；**工作量**：1 天。

### F14 `rescue export` 一键诊断包

- 打包 incidents + evidence + snapshot meta + `rescue doctor` + 容器信息摘要为单个 tar，供求助 / 开 issue。
- **价值**：把"远程排障"从问十句变成发一个文件；**难点**：脱敏（API key、会话内容绝不入包——正好复用红线思路）；**契合度**：高；**工作量**：0.5 天。

---

## 6. 建议路线图

| 波次 | 内容 | 目标 |
|---|---|---|
| **Wave 1（1～2 天）** | P0-1 降级路径健壮化、P0-3 文档与实现对齐（或补实现）、P0-5 CI 门禁 + e2e 断言锚定、F13 监督循环测试 | 让"自愈系统本身不会把容器搞挂"，并建立回归护栏 |
| **Wave 2（2～3 天）** | P0-2 / F3 预算修正、P1-3 / P1-4 / F5 快照选择与可读性、P0-6 / F6 快照不可变 + verify、P1-2 原子回滚 | 让"回退点可信、回退目标正确、用户看得懂" |
| **Wave 3（2～3 天）** | P0-4 / F2 socat 守护、F7 自动救生舱、P1-1 / F4 SIGTERM、P1-10 / F9 硬化、F8 凭据 | 补齐可用性与安全短板 |
| **Wave 4** | F1 L4 探针、F14 export、F11 文档 lint、F12 e2e 容器化 | 能力扩展与长期防腐 |

---

## 7. 与既有 `issues/` 记录的关系

- **已知留档但未实施**：CI 冒烟（评审 §四-1）、证据保留数与 `RESCUE_KEEP` 解耦（§四-2）、`TRUSTED_HOSTS` 引号防护（#8）、模式表版本化（§四-5）——本报告与之呼应，并给出更具体的触发条件。
- **被本报告推翻的"非问题"**：`cp -al` 快照安全（§三-2）——在 `dshmarket` 就地改写的真实场景下，快照可被写坏且指纹检测不到（P0-6，已实测）。
- **本报告新增**：P0-1（errexit 逃逸）、P0-2（预算永久失效）、P0-4（socat 单点）、P0-7（竞态）、P0-8（靶子注入）、P1-1 / P1-3 / P1-6 / P1-7 / P1-8 等，以及全部新功能点。

---

## 8. 实施记录（Wave 1 + Wave 2，本次会话）

已修复并验证（全部改动均以"先写失败测试 → 再实现"完成）：

| 项 | 改动 | 验证 |
|---|---|---|
| **P0-1** | `scripts/rescue-supervise.sh`：`rescue_supervise()` 入口 `set +e` + 降级契约注释；`attempt_evdir` 建目录失败返回空串；`scripts/librescue.sh` 的 `rescue_log` 容错；三个 incident 调用点补 `|| true` | 新增 `scripts/t/test-supervise-loop.sh` 的 C2/C3/C4（先红后绿）；全量 12/12 |
| **P0-3a** | `rescue_do_heal()` 入口加总闸：`RESCUE_AUTO` 与 `RESCUE_SELFHEAL` 取与，任一为 off 都只诊断 | 同测试 C5（先红后绿） |
| **P0-5（CI）** | `.github/workflows/docker-image.yml`：新增 `unit-tests` job（`build` 通过 `needs` 依赖）；加 `concurrency`；tag 校验改严格正则并抽出可测的 `scripts/ci-image-tags.sh`；workflow 内表达式一律改 `env:` 传参；tag 构建后新增镜像自证步骤 | `scripts/t/test-ci-image-tags.sh` 6 用例（含 2 个必须拒绝的负例）；workflow 基础 YAML 检查通过；**CI 首次真机运行待观察** |
| **P0-5（e2e 假绿）** | 健康判定锚定 `[entrypoint] dsh healthy on 127.0.0.1:`；`wait_for_log` 修掉"模式内空格当分隔符"导致 `healthy on` 退化为 `healthy\|on` 的问题；diagnose e2e 的红线被破改为非 0 退出 | 本地复现：探针失败行 `L1 tcp: not listening yet` 不再被判为健康 |
| **P0-3b** | 文档更正"救生舱自动降级"（当前仅手动 `RESCUE=1`）、`RESCUE_AUTO` 语义、自愈预算的真实生命周期；04（中英）不再让用户 grep 源码中不存在的 `rolling back` | 中英 06 + 04 同步，`grep 'rolling back' docs/` 仅剩历史计划文档 |
| **P1-5** | `RESCUE_SNAPSHOT_ON_HEALTHY` 接入 `docker-compose.yml` 与 `.env.example` | 机器化接线核对：不再存在"代码读取但 compose 未注入"的开关 |
| 可测性 | `rescue-supervise.sh` 的 probe 路径支持 `RESCUE_PROBE` 覆盖，并回退仓库布局（原为硬编码 `/opt/dsh-rescue/probe-ready.js`，非镜像布局直接失去监督） | 新测试依赖它注入桩探针 |

**独立评审（子代理）发现并已修复**（评审只读，未改任何文件）：

| 发现 | 修复 |
|---|---|
| **CI 镜像自证根本没执行 `dsh --version`**：本镜像 `ENTRYPOINT ["dsh-entrypoint"]` 不消费 `$@`，镜像名后的命令只会作为 CMD 追加，于是容器照常启动 dsh web —— 起得来则 CI 挂满 6h，起不来则约 4×120s 后误红 | 改为 `--entrypoint /opt/dsh-seed/bin/dsh`，失败时保留 smoke stderr；两个 job 加 `timeout-minutes` 作纵深防御 |
| `concurrency.group` 按 `github.ref` 分组，防不住 `:latest` 这个**共享**输出的竞态（各 tag 的 ref 互不相同） | 改为全局单组 `image-publish` |
| tag 校验漏网：`v0.3.7-dsh0`（npm 按 0.x 解析）、`v0.3.7-dsh-note-dsh0.1.5`（切分出 `-note-dsh0.1.5`）、`v0.1.0-dsh0.1.2-rc.1+build`（Docker tag 非法 `+`）；分支 slug 也会带非法字符 | 严格形态 `v<X.Y.Z>-dsh<X.Y.Z>[-预发布]` + 字符集校验 + slug 清洗；测试补 4 个负例与 1 个正例 |
| 分支构建复用 gha 缓存 → `npm install …@latest` 层命中旧缓存，不再跟随 npm 最新版 | `no-cache` 仅对非 tag 构建生效，tag 构建保留缓存 |
| **`rescue_restore` 的失败被当成成功**：函数末条命令是 `rescue_log`（几乎恒成功），`cp` 失败也返回 0 → 自愈记 `rollback ok`、消耗预算，而插件树其实只被删掉没恢复 | 关键拷贝失败即 `return 1`；新增 `scripts/t/test-librescue-restore.sh`，并**回放旧实现**确认该测试确实能捕获此缺陷 |
| 文档写的 `lifeboat enter` 并不出现在 docker logs（那是 `rescue.log` 的措辞） | 改为 `booting clean lifeboat profile`（中英 04/06 四处 + e2e 注释） |
| 测试脆弱：`test-supervise-loop.sh` 的 C4 在 state 目录缺失时会退化成"必然通过"；C5 只有负向断言 | C4 补 `mkdir -p` 与"确实进入 abnormalExit 分支"的正向断言；C5 补总闸触发断言 |
| `test-probe-ready.sh` 固定端口（39081/39082）会出现 EADDRINUSE flake | 端口改按 PID 派生，连跑 5 次稳定 |

### Wave 2（让回退点可信、回退目标正确、用户看得懂）

| 项 | 改动 | 验证 |
|---|---|---|
| **P1-2 原子回滚** | `rescue_restore` 改为：先在 staging 组装完整新树 → node_modules 用 rename 原子让位/就位 → 三个配置文件写同目录临时名再 rename → 任何一步失败执行回滚事务、live 保持原样 | `test-librescue-restore.sh` 新增"失败不留半棵树"用例（先红：live 被删空） |
| **P0-6/F6 快照可信度** | meta 记录 `profile`/`mode`/`treeHash`；新增 `snapshot_tree_hash()`（不跟随 symlink 的树摘要）与 `rescue_verify()`；新增 `RESCUE_SNAPSHOT_MODE=copy`（真正不可变副本）；CLI `rescue verify` | `test-snapshot-integrity.sh`（4 用例：meta 字段 / 完好通过 / 硬链接污染必须报错 / copy 模式免疫）+ CLI 断言 |
| **P1-3 回滚目标选择** | 新增 `rescue_pick_rollback_target()`：跳过与 live 指纹相同的快照、优先跳过 `selfheal-*` 现场快照，一个可用目标都没有时如实 report-only | `test-supervise-loop.sh` C6（先红：两轮都"回滚"到与 live 相同的快照 = 空操作却记成功） |
| **P0-2/F3 预算生命周期** | 预算读写移入 `librescue.sh` 并增加 `windowStart`；超 `RESCUE_SELFHEAL_WINDOW`（默认 24h）自动清零；CLI `rescue selfheal status|reset` | `test-selfheal-budget.sh`（窗口内保持 / 过期清零 / 写回 windowStart / CLI status+reset） |
| **P1-4/F5 可读性** | `rescue snapshots`（编号/时间/模式/**与 live 是否相同**/原因）；`rescue rollback [--to \| --dry-run \| --list]`，目标与 live 相同时直接拒绝 | `test-rescue-cmds.sh` 新增 5 条断言 + 手动冒烟（输出见下） |
| **额外发现 ①（隐蔽 P1）** | `rescue_evidence_prune` 按**目录名**字典序删"最老"，而 `boot-<attempt>-<ts>` 的 attempt 每次容器重启都回绕到 1 → 重启后第一轮的新证据被自己删掉 → `mkfifo` 失败、`EVLOG` 为空 → diagnose 拿不到证据只能 report-only（自愈静默降级，日志上看不出原因）。改为按 mtime 排序 + 显式保护当前目录 | `test-supervise-loop.sh` C8（先红） |
| **额外发现 ②（隐蔽 P1）** | `rescue_close_ev` 直接 kill tee，而 tee 对文件是块缓冲 → 最后一段输出（往往正是崩溃原因）凭空消失。改为先关闭 fifo 写端让 tee 读到 EOF 刷盘，最多等 2s 再强杀 | `test-supervise-loop.sh` C7（先红：`FINAL-MARKER` 丢失） |

**Wave 2 的独立评审又找出 3 个 Critical + 7 个 Important，均已复现并修复**：

| 评审发现（均为实测复现） | 修复 |
|---|---|
| **降级复制把依赖树套成两层**：`cp -al` 失败后 `cp -a` 未先删目标 —— GNU cp 失败前可能已建出目标目录，于是变成 `DST/SRC`，产出 `node_modules/node_modules/pkg` **且返回 0**（自愈记 rollback ok、耗预算，树更坏）；快照创建端同样写法会让快照自身嵌套 | 降级前显式 `rm -rf` 目标目录 |
| **回滚事务只还原 node_modules**：配置文件替换失败时 live 停在"半新半旧"，日志却谎报 "live tree left unchanged" | 旧配置文件先 rename 进 `bak`，回滚时连 node_modules 一起完整还原 |
| **证据修剪在 rm 持续失败时无限自旋**：它位于 PID1 启动路径，旧实现永不退出（单核跑满、容器起不来、零日志） | 删除失败即停止并写审计日志 |
| **回滚目标会选中 `selfheal-*` 现场快照**（动作**之前**的坏现场），把用户推回故障状态；跨 profile 的快照也能被恢复进别的 profile | 优先 `boot-healthy baseline`、禁止现场快照；`rescue_restore` 直接拒绝 profile 不匹配的快照 |
| **`rescue verify` 两处误判**：快照 node_modules 已丢失却判 OK（随后回滚会删掉 live 的依赖树）；旧快照被判"已损坏"（诱导用户删掉唯一可用的回退点） | 前者报"快照已不完整"，后者改为"跳过完整性校验" |
| **`SAME/differs` 只看配置文件**：copy 模式快照或 pnpm 重装后依赖树完全不同仍显示 SAME，界面告诉用户"回滚没有效果" | 新增 `rescue_snapshot_is_redundant`，把 node_modules 树哈希纳入判据；`rescue snapshots` 与 `rollback --to` 都改用它 |
| **同秒快照的"最新/最老"退化到编号序**，prune 可能淘汰好的 baseline 而留下现场快照 | 用目录 mtime 作为次键 |
| **回滚并发重入 + SIGKILL 残留无 GC** | `$RESCUE_DIR/.restore.lock`（陈旧锁自动接管）+ 启动时清理 work 目录 |
| **`--to`/`--reason` 缺参静默退出**（dash 下 `shift 2` 参数不足直接终止，`\|\| shift` 兜底不可达） | 显式判参并打印 usage |

本轮新增/扩展的回归测试：`test-supervise-loop.sh` 的 C10（修剪不得自旋）、C11（禁止现场快照作目标）；`test-snapshot-integrity.sh` 的"node_modules 缺失""旧快照措辞""冗余判定须看依赖树"；`test-snapshot-order.sh` 的同秒排序；`test-librescue-restore.sh` 的 C1/C2（cp 嵌套、事务回滚完整性）。

**被证伪的假设（没有实施）**：我一度认为 `rescue_close_ev` 的等待循环会因僵尸进程白等满超时，并写了 C9 断言"必须 <800ms 返回"——实测**未变红**（dash 会及时 reap 已退出的后台子进程）。因此没有写那个"修复"，只把断言保留为防退化护栏并改正注释。这正是"必须先看到测试失败"的价值。

手动冒烟（真实 CLI）：

```
$ rescue snapshots
NAME        CREATED              MODE      LIVE     REASON
snap-0001   2026-09-11T23:14:00  hardlink  differs  plugin add @scope/a
snap-0002   2026-09-11T23:14:00  hardlink  SAME     manual second

$ rescue verify                    # live 被就地改写后
verify: snap-0001: node_modules 已被写坏（快照不再可信，勿作为回退点）
$ rescue rollback --to snap-0002   # 与 live 相同
rollback: snap-0002 与当前插件树内容相同，回滚没有任何效果（未做改动）
```

### Wave 3（可用性与安全短板）

| 项 | 改动 | 验证 |
|---|---|---|
| **P0-7 快照编号竞态** | `next_snap_name` 改 mkdir 原子抢号（此前 entrypoint 的健康基线快照与用户 `rescue plugin` 的预防性快照会撞号并互相覆盖，meta 丢失还会让时间序判定退化成 mtime） | `test-snapshot-order.sh` 新增"两次分配不得同名"（先红：都返回 snap-0001） |
| **P0-8 自愈靶子校验** | 包名白名单（拒绝 `-` 开头与非法字符）+ 必须确实是当前 profile 的依赖 —— target 来源是**可被第三方插件控制的日志文本** | C12（先红：`--global` 被当成包名执行） |
| **P1-1 SIGTERM 转发** | `trap` 转发给 dsh 并等其优雅退出；计划内停止记 `stopped`，不再被误记成 runtime crash | C13（先红：信号未转发，PID1 直接死） |
| **P1-6 fifo 读端** | 探测期间监控证据链，死亡即释放 shell 的 fifo fd，让 dsh 的写快速失败而不是在缓冲写满后假死 | C14（先红） |
| **P0-4/F2 socat 守护** | `start_socat` 封装 + 启动窗口与健康运行期持续守护 + `max-children` 上限 | C15（先红） |
| **P1-7 模式表生效** | 先过 `PLUGIN_FAIL_PATTERNS` 再提取包名 | `test-diagnose.sh` G（先红：无关日志因含包名被判 `remove-plugin` 高置信度） |
| **F7 自动救生舱** | 一次性标记 + entrypoint 自动进入 + `rescue lifeboat on\|off\|status` | C16（先红；含 `RESCUE_AUTO_LIFEBOAT=off` 负例） |
| **F8 凭据文件** | `DEEPSEEK_API_KEY_FILE` 优先于环境变量（含 CRLF 兼容、失败不清空既有值） | `test-credentials.sh` |
| **F9 容器硬化** | `no-new-privileges` / `pids_limit` / socat `max-children`；`cap_drop`/`read_only` 以注释给出 | `test-compose-wiring.sh` |

### Wave 4（能力扩展与长期防腐）

| 项 | 改动 | 验证 |
|---|---|---|
| **F11 一致性门禁** | `test-compose-wiring.sh`：断言"代码读取的每个可配置变量都能经 compose 注入且出现在 .env.example"、硬化项在位、`start_period > RESCUE_START_TIMEOUT` | 先红（精确列出 5 个未注入变量）后绿 |
| **F14 rescue export** | 一键诊断包（事故/状态/快照元数据/环境摘要/doctor/最近启动日志尾部），刻意不含插件树、会话、记忆与密钥 | `test-rescue-cmds.sh`（tar 内容断言 + 禁含 node_modules/密钥） |
| **F1 L4 探针** | 读响应体匹配 `Failed to load plugins` / `did not activate`；实测正常实例的 HTML 完全不含这些串，故不会误报；可 `RESCUE_PROBE_FAIL_CHECK=off` 关闭 | `test-probe-ready.sh` G/H（先红） |
| **F12 e2e 容器化** | `e2e-container-selftest.sh`：一次性容器 + 临时卷 + 随机端口，只断言成功原文，结束即清理（可进 CI） | 语法校验通过；**首次真机运行待验证** |

### 遗留清理（P1-8 / P1-9 / P2）

| 项 | 改动 | 验证 |
|---|---|---|
| **P1-8 incident 语义** | 记账推迟到"结局已定"：恢复健康记 `recovered-*`，最终仍失败**显式**记 `unrecovered`（此前 crashloop 会被记成 `recovered-rollback`，而真正恢复的路径反而没有 incident）；诊断产物随之暂存（`DIAG_JSON` 每轮会重置） | C17（先红：自愈恢复后零 incident）、C18（先红：crashloop 被记成 recovered）——两者用**真实 diagnose.js** 走完整链路 |
| **P1-9 KEEP 拆分** | 拆出 `RESCUE_MAX_ATTEMPTS` 与 `RESCUE_EVIDENCE_KEEP`，默认仍跟随 `RESCUE_KEEP` | C19（重试上限独立生效）、C20（证据保留数独立于快照数） |
| **TRUSTED_HOSTS 加固** | 未加引号的展开改为逐项校验（只允许 `[A-Za-z0-9.:_*-]`），非法项丢弃并记审计日志 | `test-trusted-hosts.sh`（含畸形项/命令替换/通配符负例） |
| **`set -u` 污染** | librescue 去掉文件级 `set -u`（它被 PID1 与 CLI 共同 source） | 全量回归 |
| **`$HERE` 未定义** | entrypoint 显式定义 `HERE`（此前三处兜底路径全部失效） | 全量回归 |
| **文档漂移** | 01 的 start_period/日志语言、02+05 的 `DSH_TRUSTED_HOSTS`、03 的不可回读警告、README tag 示例 | grep 复核（中英同步） |

### 真机端到端验证（Wave 5，在真实 Docker 宿主上实跑）

把本次改动挂载进容器，在真机（Docker 29.7.2）上端到端验证，**发现并修复两个单测覆盖不到的缺陷**：

| 缺陷 | 现象（真机） | 修法 | 防回归 |
|---|---|---|---|
| **entrypoint「先用后 source」（Critical）** | `WARN trusted Host allowlist produced no usable entry`；`DEEPSEEK_API_KEY_FILE` 完全没生效——两处调用都在 `source librescue.sh` 之前，`command -v` 判空后静默跳过 | 移到 source 之后 | 新增 `test-entrypoint-order.sh`：静态断言所有 `rescue_*` 调用晚于 source 行（先红：精确列出 4 处违规） |
| **通配符被 glob 成文件名（Important）** | 白名单 `*` 被展开成当前目录的一串文件名，随 CWD 变化 | `set -f` 包住展开循环；字符集收紧为 `[A-Za-z0-9._:-]` | `test-trusted-hosts.sh` 改为逐项断言 + `'*'` 单独输入必须得到空输出（先红） |

**真机确认通过项**：白名单只保留 `good.example.com`（`bad host`/`evil$()`/`*` 全丢弃）· dsh 主进程环境里是**文件里的**密钥（`sk-from-mounted-file`）· 完整自愈链路（probe 秒级失败 → `diagnosis -> heal=rollback target=snap-0003` → `selfheal rollback` → healthy → `incident ... outcome=recovered-rollback`，bundles 被还原）· `rescue snapshots/verify/selfheal status/lifeboat/report/export` 全部正常 · SIGTERM → `forwarding to dsh` + `last-run.phase=stopped` · `rescue lifeboat on` → 下次启动真的以 `--profile lifeboat` 起来 · socat 被杀后守护重启（PID 10 → 346）· CI 门禁的镜像自证命令 `docker run --rm --entrypoint /opt/dsh-seed/bin/dsh <img> --version` 输出 `0.1.2-rc.1`。

**最终状态**：19 个单测全绿、干净环境下同样通过、全部 shell/node 语法检查通过、真机端到端验证通过。

**可执行位**：`entrypoint.sh` / `rescue` / `scripts/t/*.sh` / `scripts/logtag.js` / `scripts/logtee.js` 在 git 里原为 644（只靠镜像 Dockerfile 的 `chmod +x` 赋权），clone 后直接执行会 Permission denied —— 真机 bind-mount 验证时同样丢执行位（本次实际踩到）。现已统一为 100755，并加 `test-script-modes.sh` 门禁。注意本仓库 `core.fileMode=false`，模式是经 `git update-index --chmod=+x` 写入索引的。

**已知边界**：① CI 的镜像自证步骤与 `e2e-container-selftest.sh` 需要真机 Docker 首跑；② `cap_drop: [ALL]` 与 `read_only` 只以注释形式提供（部分 NAS/内核组合需先验证）；③ treeHash 的检测信号是 size+mtime+inode，理论上"还原 mtime 的就地覆盖"仍能骗过它（要根治需内容哈希，代价是大目录全量读取）。

**复现命令**：

```bash
for f in scripts/t/test-*.sh; do sh "$f" || exit 1; done   # 19/19 ALL-PASS
env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root TZ=UTC sh -c 'for f in scripts/t/test-*.sh; do sh "$f" || exit 1; done'   # 干净环境同样通过
```

---

*第 1-7 节为只读评估产物；第 8 节记录本会话已落地的修复。所有 `[实测]` 结论均可在沙箱内用文中给出的方式复现。*
