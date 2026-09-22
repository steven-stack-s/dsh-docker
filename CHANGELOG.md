# 更新日志 (Changelog)

本项目的版本遵循双版本 tag 约定：`v<项目版本>-dsh-<dsh版本>`，如 `v0.3.0-dsh-0.1.2-rc.1`，其中后缀为构建时锁定的 DSH 版本（见 Dockerfile 的 `ARG DSH_VERSION`）。推送匹配 `v*` 的 tag 会触发 GitHub Actions 自动构建多架构镜像并发布到 ghcr.io（见 .github/workflows/docker-image.yml）。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)。

## [Unreleased]

## [v0.5.1-dsh-0.1.7-alpha.1] - 2026-09-22

### Changed
- **镜像锁定的 dsh 升级到 `0.1.7-alpha.1`**（`ARG DSH_VERSION`）。alpha 线的常规推进：seed → 挂载卷 →
  entrypoint 监督的部署链路**未变**，`ver_gt` 仍正确判定 `0.1.7-alpha.1 > 0.1.6-alpha.2`，容器内升级
  不会被镜像 seed 顶回；关闭 HMR 的启动叠加层（`hmr-off.yml`）继续有效 —— 两版
  `dsh-base/cordis.patch.yml` 的 `hmr` 条目逐字节一致。
- **`docs/03` 的 dist-tag 快照更新为 2026-09-22 实测**：`latest → 0.1.5-rc.2`、`next → 0.1.5-rc.3`、
  `alpha → 0.1.7-alpha.1`；README 中英徽章与示例 tag 同步。

### Added
- **Session V4 单向迁移警告**（`docs/03` 中英）：0.1.7 把会话日志升到 **V4**，V3 会话在读取时转换，
  一旦打开并继续写入即落盘 `session.v4.jsonl.zstd`（原 `session.v3...` 保留不动）—— **回退 dsh 版本时
  必须连 `sessions/` 与 `storages/` 一起回滚**。文档已给出升级前备份与回退的完整命令。
- **门禁 `scripts/t/test-dsh-version-pin.sh`**：把"换版本时漏改一处"钉死 —— 断言 `ARG DSH_VERSION`
  是完整三段式版本（拒绝 `latest` / `next` / 裸 `alpha`），且 README 中英徽章、`docs/03` 中英 dist-tag
  表的 `alpha` 行、CHANGELOG 最新版本段落**四处与它一致**。

### Notes
- 0.1.7 的契约变更**集中在插件侧**，本机实测记录见
  `issues/2026-09-22-dsh-0.1.7-alpha.1-适配分析.md`（含 §九 实测执行记录）：
  - 客户端服务 `settingsScope` 被上游移除（新实现为 `configForms`）→ `@xgone/dsh-remote`、
    `dsh-connect-trae` 的 client 插件会一直 `pending`；
  - 设置页 slot 改名（`settings.plugin.item` → `plugins.item`、`plugins.row.config` → `plugins.bundle.config`）；
  - Session V4 拒收 `source.kind === "plugin"` 的旧包壳 → 注入消息的插件必须改用生产者自有 kind
    （如 `plugin:<name>`）；`dsh-free-search` 还需处理 `dsh-settings` 不再导出 `SettingsProvider`。
  以上均为**插件侧适配**，不在镜像职责内；镜像只负责版本锁定与文档记录。
## [v0.4.12-dsh-0.1.6-alpha.2] - 2026-09-20

### Added
- **救生舱（lifeboat）里的 AI 行动指引**：`rescue status` / `rescue doctor` 检测到救生舱态时，
  追加一段 `LIFEBOAT MODE` 指引块，明确给出"修复完成后由用户在宿主机执行
  `docker restart dsh`"的命令，并说明**不要 `kill` PID1**。
  背景：容器内 AI 在救生舱里修完问题后无法自行回到正常 profile —— `RESCUE=1` 是容器环境变量
  （容器内改不了）、`.env` 在宿主机未挂载、容器内没有 docker socket（安全设计，不破坏）。
  若它去 `kill` PID1，`restart: unless-stopped` 拉起后读到的仍是 `RESCUE=1`，只会再次进救生舱，
  白耗一整轮排查。
- **崩溃证据落盘 `last-web-boot.log`**：监督循环把每轮 web 启动的输出覆盖式写入
  `$DSH_HOME/.rescue/last-web-boot.log`，启动失败时额外在容器日志回显 `tail -80` 摘要；
  `rescue doctor` 可回显其尾部。背景：进救生舱后原进程已死、容器内又读不到 `docker logs`，
  真实根因（如 `Cannot find module 'xxx'` 堆栈）此前完全看不见。
- **`TMPDIR` 临时文件根目录**（`/data/dsh/tmp`）：dsh 的工具输出溢出、命令输出 spool、
  工作区变更捕获都走 `os.tmpdir()`，随之从 tmpfs `/tmp` 迁到数据卷。
- **`RESCUE_TMP_KEEP_MIN`**：`rescue clean` 回收 `TMPDIR` 下 dsh 临时产物时的保留窗口
  （分钟，默认 1440 = 24h）。阈值内视为"可能仍在使用"，绝不删。
- `rescue clean` 新增临时产物回收项；`rescue doctor` 报出当前 `TMPDIR` 与 dsh 临时目录数量；
  `rescue export` 的环境白名单纳入 `TMPDIR`。

### Fixed
- **`/tmp` 被"临时任务 / 验证测试"写满**。根因：compose 的 `read_only: true` 让 `/tmp` 只能用
  tmpfs，而它是**内存硬上限**（128m）；dsh 三处都往 `os.tmpdir()` 写，单次大输出即可撞满 ——
  工具输出溢出（读大文件 / 大范围搜索）、被托管命令的输出 spool（构建 / 测试动辄几十上百 MB）、
  工作区变更捕获。且 dsh 自身的回收都不可靠：溢出文件只在**启动时**扫一次、默认只清 30 天前的
  （`cleanupPeriodDays` 默认 30）；命令 spool 只在进程退出时 `rmdirSync`（非空目录删不掉，
  上游代码自己注明要等 "external cleanup"）。于是产物只增不减。
  对策：`TMPDIR` 指向数据卷（`os.tmpdir()` 在 Node 里尊重 `TMPDIR`，三个模块自动跟随，
  **不需要改上游一行代码**），空间上限从"128m 内存"变成宿主机磁盘；回收由 `rescue clean` 兜底
  （dsh 自身清理时机不可靠，故由救援命令接管）。`/tmp` 的 tmpfs **保留不动** —— 原生插件绑定
  要 `dlopen`，需要 `exec`，撤掉会让只读根 FS 下的 `/tmp` 不可写而直接起不来。

  回收的**安全边界**：只删白名单前缀且名字形如 `mkdtemp`（前缀 + 恰好 6 位字母数字）的一级目录
  （`dsh-spill-*` / `dsh-subprocess-*` / `dsh-subprocess-launch-*` / `dsh-workspace-changes-*` /
  `dsh-shell-*` / `dsh-XXXXXX`）。刻意**不删** `dsh-office-to-pdf-*`、`dsh-open-in-app-*`、
  `libreoffice-kit-*` 等转换中间产物（可能正被使用），也不碰用户放在 `TMPDIR` 里的任何东西 ——
  宁可少删，绝不误删。

> **升级提示（重要）**：`TMPDIR` 从 `/tmp` 移走后，`/tmp` 下**已遗留**的 `dsh-*` 目录不会再被
> 任何人扫描（dsh 的清理扫描基准也跟着 `TMPDIR` 走），会永久占着那 128m。首次升级后请手动清一次：
> ```bash
> docker exec dsh sh -c 'rm -rf /tmp/dsh-spill-* /tmp/dsh-subprocess-* /tmp/dsh-workspace-changes-* /tmp/dsh-shell-*'
> ```

### Changed
- `rescue doctor` 输出新增 `last web boot output (tail)` 与 `tmp dir` / `tmp dsh dirs` 两节；
  `rescue status` 新增上一轮启动输出是否落盘的报告（均为只读，不写任何状态）。
- 文档：[06 · 救援模式](docs/zh-CN/06-救援模式.md) 新增 §4c「临时文件回收」与 §5b「AI 自助修复流程」；
  [07 · 环境变量速查](docs/zh-CN/07-环境变量速查.md) 补 `TMPDIR` / `RESCUE_TMP_KEEP_MIN`
  并更正"只读根 FS"段（`/tmp` 不再是 dsh 临时文件的主要落点）。

## [v0.4.11-dsh-0.1.6-alpha.2] - 2026-09-18

> **紧急修复**：v0.4.10 引入的「镜像升级自动同步 dsh」在**部分环境（如 NAS）**下会让容器进入
> **重启死循环**。若你已在跑 v0.4.10 且容器反复重启，请直接升到本版；或把 `DSH_IMAGE` 临时退回
> `v0.4.9`（那一版没有自动同步，不会触发本问题）。

### Fixed
- **seed 复制在 chown 失效的环境下会杀掉 PID1**（真机复现 + 修复验证）。
  容器内 root 只有 `CHOWN/DAC_OVERRIDE/SETUID/SETGID`，**没有 CAP_FOWNER**；而 `/opt/dsh` 里的
  文件在首启后已被步骤 ③ chown 给运行用户，对「不属于自己的」文件做 utimes/chmod 会 EPERM。
  v0.4.10 的步骤 ① 用的是裸 `cp -a`，于是 **cp 返回非零** —— 在 `set -e` 下直接终止 PID1；
  compose 的 `restart: unless-stopped` 把它变成**死循环**，日志被
  `cp: preserving times ...: Operation not permitted` 刷满。

  真机 A/B（去掉 `CAP_CHOWN` 模拟 chown 失效，同一 node 属主卷 + 同一升旧版本号）：

  | 镜像 | 结果 |
  |---|---|
  | v0.4.10 | **running=false, exit=1**，28166 条 preserving-times 错误 |
  | 本版 | **running=true**，dsh 正常升到 `0.1.6-alpha.2`，一句 WARN 后走兜底 |

  修复：seed 复制收敛为 `seed_copy()`（步骤 ① 与 ② pnpm 兜底共用）——先把属主收回 root
  （CHOWN 在白名单里，这步安全），再 `cp -a` 保留属性；仍失败则退化为不保留属性的 `cp -R`
  ——内容才决定 dsh 能否运行，元数据尽力而为。步骤 ③ 随后会把属主改回运行用户。
  `rescue dsh-reinstall` 的离线 seed 恢复同源，一并处理。

  > 注：此前那个「只有 `command -v dsh` 失败才复制」的旧逻辑**不会**踩到这个坑（升级时根本不复制），
  > 是本版的自动同步把它带进了升级路径。

### Tests
- `test-seed-upgrade.sh` 增加断言：必须有 pre-chown 与 `cp -R` 兜底、**不得存在裸 `cp -a`**、
  `seed_copy()` 的定义必须早于调用（POSIX shell 顺序执行，写在调用之后等于不存在）；
  负向用例已验证会红。

## [v0.4.10-dsh-0.1.6-alpha.2] - 2026-09-18

### Added
- **镜像升级时按版本自动同步 dsh 本体**（`entrypoint` 步骤 ① 重写）。此前只在 `command -v dsh`
  失败时才复制 seed，于是**升级镜像并不会更新** `/opt/dsh` 卷里的 dsh —— 实测：换用更新 seed 的
  镜像重建后，`dsh --version` 依旧是旧版本。现在改为版本比较驱动：
  卷里没有 dsh → 复制；**seed 版本 > 卷内版本 → 复制**；相等、或卷内版本更新 → **不动**
  （尊重用户在容器内装的更高版本）。启动日志直接给出三个版本：
  `[entrypoint] dsh version: seed=0.1.6-alpha.2 volume(before)=0.1.6-alpha.1 effective=0.1.6-alpha.2`。
  版本取自各自安装目录的 `package.json`：比跑 `dsh --version` 更快、无副作用，也不会因 profile
  或权限问题失败。缺失比较库时降级为原行为（仅首启复制），绝不因此中断启动。

- `scripts/vercmp.sh`：把 `ver_gt`（semver 比较，按 §11 正确处理预发布）从 `update-dsh-badge.sh`
  抽成共享库 —— entrypoint 与徽章脚本共用**同一份**实现，杜绝「徽章那边算升级、seed 这边算降级」
  这类极难察觉的语义分叉。

### Changed
- **容器内降级 dsh 会被启动逻辑撤销**：这是上一条的必然结果（镜像锁版本优先）。要停在更低版本，
  须把 `DSH_IMAGE` 指向锁定该版本的镜像 tag。`docs/03`（中英）的升级与回滚章节已按新行为重写：
  升级通常**一步即可**（`docker compose pull && docker compose up -d`），回滚同样以镜像 tag 为准；
  README（中英）与速查表同步。

### Tests
- `scripts/t/test-vercmp.sh`：`ver_gt` 语义单测，覆盖 rc 转正、`alpha.10 > alpha.9` 等边界。
- `scripts/t/test-seed-upgrade.sh`：门禁「比较逻辑在位 / 日志含最终生效版本 / **source 顺序早于首次
  使用**（先用后 source 会让 ver_gt 根本不存在 —— 本项目 test-entrypoint-order.sh 就是为同类事故
  而立的）」，并断言镜像携带 vercmp.sh；3 个负向用例已验证会红。

### Verified
- 真机（192.168.1.88，真 Docker）三向对照：alpha.1 卷 + alpha.2 seed → 自动升到 alpha.2；
  版本相等 → 不复制（seeding 日志 0 条）；卷内 mock 成 9.9.9（更高）→ 不降级、保持 9.9.9。

## [v0.4.9-dsh-0.1.6-alpha.2] - 2026-09-18

> 镜像 seed 锁定的 DSH 版本由 `0.1.6-alpha.1` 升到 `0.1.6-alpha.2`。这**不是**一次
> 纯版本号递增：alpha.2 把 HMR 机制整体换代（`@deepseek-ai/cordis-plugin-hmr` →
> 新包 `@deepseek-ai/dsh-hmr`，并**删除** profile manifest 的 `patchReload` 字段），
> 使本项目"首启改写 `patchReload` 来关闭 HMR"的 read_only 加固**静默失效**——而当时的
> 门禁只 grep entrypoint 里的那行文本，**照样全绿**。本版把关闭手段换成与 dsh 版本无关的
> 启动参数叠加层，并补上能真正抓住这类"保护蒸发"的门禁。
> 部署模型、挂载与数据格式**均未变化**，升级后无需改 `.env`。

### Fixed
- **read_only 加固静默失效：关闭 HMR 的手段换代为启动参数叠加层**（DSH 0.1.6-alpha.2 适配，实测）。
  旧做法是首启把 web profile manifest 的 `patchReload` 由 `"live"` 改写成 `"startup"`。
  实测 alpha.2：**该字段已被完全移除** —— `dsh-app-boot` 源码里再无任何引用，新建 profile 也
  不再写入它，存量 profile 上它被**静默忽略**（带该字段仍能启动、不报错）。与此同时 HMR 改由
  base 组合包的 `hmr` 条目控制：
  ```yaml
  # alpha.1：- id: hmr / name: '@deepseek-ai/cordis-plugin-hmr' / disabled: true   ← 默认关（opt-in）
  # alpha.2：- id: hmr / name: '@deepseek-ai/dsh-hmr' / disabled: !!js "!ctx.get('profileContext')"
  ```
  即**只要由启动器拉起（web/headless/sdk/acp 都算）就默认启用** —— web 的配置热重载实际变成
  开着，而 read_only 根 FS 下 HMR 需要的 `ctx.loader.internal` 可能缺席，`dsh-hmr` 会直接抛
  `Error: --expose-internals is required for HMR service` 让 dsh 崩溃。
  现改为 entrypoint 在**每条启动命令**上注入 `--patch /opt/dsh-rescue/hmr-off.yml`
  （新增 `scripts/hmr-off.yml`，只关 `hmr` 条目），既不碰 profile manifest、也不碰用户的
  `cordis.patch.yml`。选启动参数而非 manifest 字段的理由：`--patch` 在 `0.1.5-rc.2` /
  `0.1.6-alpha.1` / `0.1.6-alpha.2` 上**都存在**（已逐一实测），故容器内 `npm install -g`
  升级或回退 dsh 都不会让它失效 —— 而"写进 manifest 的字段"是随版本被删的，正是本次翻车的原因。
  覆盖范围经数量断言：entrypoint 2 条 + supervise 3 条启动路径**全部**注入（漏一条即红灯）。

- **`test-rescue-clean.sh`：dry-run 指纹用例在 tmpfs 上必然假红**（既有缺陷，与本次升级无关，
  经基线 worktree 对照确认）。该用例把 `fp.before`/`fp.after` 写在**被指纹的目录自身**里，
  而指纹含目录自身的 `%s`：tmpfs 的目录 size 随条目数增长（实测 40→60→80），于是 dry-run 明明
  毫无副作用，`.` 的 size 却从 100 变成 120 而报错；ext4 上目录 size 恒为 4096，所以 **CI 常年
  绿、本地沙箱常年红**。指纹文件改落 `$T`（被指纹目录之外）。

### Added
- `scripts/hmr-off.yml`：关闭 profile `hmr` 条目的 launcher 叠加层，由 entrypoint 以
  `--patch` 注入（文件头记录了 alpha.2 的机制变化与实测证据）。
- `scripts/t/test-hmr-off.sh`：盯"保障"而非"实现文本"的门禁 —— 断言叠加层真的禁用了 `hmr`、
  镜像真的携带它（COPY + CRLF 归一）、**每条** `dsh` 启动路径都注入了它，并**反向**断言不得再
  退回已被 alpha.2 删除的 `patchReload` 机制。已用 3 个负向用例验证门禁确实会红
  （撤掉一处注入 / 把 `disabled` 改成 `false` / 让 lifeboat 模板重新带上 `patchReload`）。

### Changed
- **`Dockerfile`：`ARG DSH_VERSION` 由 `0.1.6-alpha.1` 升到 `0.1.6-alpha.2`**；同步修正
  文件头那张已过时的 dist-tag 对照表（实测 2026-09-18：`latest` 已从 `0.1.5-rc.1` 前进到
  `0.1.5-rc.2`，`alpha` 指向 `0.1.6-alpha.2`）。
- **`entrypoint.sh` 第 ⑤ 步**：不再改写/预置 `patchReload`（对 alpha.2 是死写入），只预置不带
  该字段的 manifest，并把关闭 HMR 的动作移到启动参数；新增 `HMR_OFF_PATCH` 解析与兜底
  （`hmr_off_args` 在各分支显式 `return 0` —— 命令替换的非零退出码在 `set -e` 下会直接终止
  PID1）。`rescue-supervise.sh` 对 `HMR_OFF_PATCH` 做空值兜底，维持其"兼容 `set -u`"的自我声明。
- `scripts/lifeboat.tmpl/package.json`：移除已失效的 `patchReload` 字段（救生舱同样走
  `--patch` 关闭路径）。
- **文档同步**（README 中英、docs 03/07 中英、compose 与 workflow 的示例 tag）：`patchReload`
  加固说明改写为新机制并记录换代原因；dist-tag 表更新为实测值并加注"只是某一时刻的快照"；
  README 的 DSH 版本徽章同步到 `0.1.6-alpha.2`。
- `test-nonroot.sh`：删掉两条已失效的 `patchReload` 断言（它们正是"绿着但保护已蒸发"的来源），
  改为断言 `HMR_OFF_PATCH` 在位，完整断言移交 `test-hmr-off.sh`。

## [v0.4.8-dsh-0.1.6-alpha.1] - 2026-09-17

> 承接 v0.4.7 上线后暴露的**非 root 迁移遗留问题**：HOME 指向不可读的 `/root` 导致
> pnpm / 插件市场全废，以及 HOME 落在没有可见子目录的位置导致「新建会话选不到工作区」。
> 镜像 seed 锁定的 DSH 版本仍为 `0.1.6-alpha.1`；本版**不改部署模型**，只把非 root 下的
> HOME 语义修正为「可读写」且「默认打开就能选到工作区」。

### Fixed
- **"选择工作区"列表为空：HOME 不能是没有可见子目录的目录**（真机 2026-09-17）。
  「新建会话 → 选择工作区」的选择器**默认就列 HOME**，且 UI 默认**不显示隐藏文件**：
  `const target = resolve(path ?? homedir())`（`dsh-host-directory-picker-browse`）。
  上一条修复把 HOME 设成 `/data/dsh/home` 时，该目录只有 `.config/.local` 等隐藏项，
  列表因此全空 —— 用户表现为"工作区选取不到"。改用 `HOME=/workspace`：其下的
  `code/`、`session/` 正是要选的工作区，而 `~/.config`、`~/.local`、`~/.gitconfig`
  仍是隐藏项、不会污染列表。entrypoint 的兜底默认值同步改为 `/workspace`。
  （该选择器没有可配置的起始目录：browse 后端只暴露 `maxEntries`，故只能由 HOME 决定。）
  `test-nonroot.sh` 改为**锁值**断言，避免再退回成空列表的目录。

- **非 root 下 HOME 指向不可读的 /root，导致插件市场 pnpm 全废**（真机故障修复 2026-09-17）。
  镜像刻意不设 HOME，Docker 会给 root 的 `/root`；而 `/root` 是 `700 root` —— 降权到 uid 1000
  后连读都不行。pnpm 启动时会读 `$HOME/.config/pnpm/config.yaml`，于是直接 EACCES：
  ```
  Error:   × load configuration
    ╰─▶ Failed to read pnpm-workspace.yaml at /root/.config/pnpm/config.yaml:
        Permission denied (os error 13)
  ```
  表现为插件市场报「找到 pnpm 了，但运行 `pnpm --version` 失败」。
  **实测对照**：`HOME=/root` → 上述报错；`HOME` 指向可写目录 → `pnpm --version` 输出 `12.4.2` 正常。
  另澄清：pnpm 本体是完整 bundle（48MB 单文件 + `dist/`），**不是**需要联网下载的 corepack shim，
  故「设 PNPM_HOME / corepack / brew 重装 pnpm」都是错误方向。
  修复：compose 显式 `HOME=/data/dsh/home`（随数据卷持久化）+ entrypoint 在属主整备前自动纠正
  （原值为空或 `/root` 时改指数据卷内并建目录；用户显式传入其它值则尊重）。
  这同时修好了任何依赖 `$HOME` 的工具（git/gitconfig、插件里的 `os.homedir()`）。
  `test-nonroot.sh` 增加两条门禁（entrypoint 兜底 + compose 显式指定）。

- **`USER_UID`/`USER_GID` 指向容器内不存在的 uid 会重启死循环**（真机 2026-09-17 实测）。
  `setpriv --init-groups` 需要用 `/etc/passwd` 反查该 uid 的用户名，查不到就直接失败：
  `setpriv: uid 1024 not found, --init-groups requires an user that can be found on the system`。
  而 entrypoint 第 ⑥ 步的 `exec setpriv` 在 `set -e` 下会终止 PID1 → 容器重启死循环，
  且该块排在 lifeboat 之前 —— **连救生舱都到不了**（与 2026-09-17 同类症状）。
  更糟的是 `.env.example` 当时正建议用户「按宿主 uid（如 1024）改成对应值」，等于把人往坑里带。
  现在 entrypoint 会先探测（`setpriv ... --init-groups true`），失败则退化为**不带附加组**降权
  并打印告警：uid/gid 仍按指定生效，只是 supplementary groups 为空 —— 不中断启动。

### Changed
- **`Dockerfile` 删除死参数 `ARG USER_UID`/`ARG USER_GID`**：它们声明后从未被任何指令消费，
  却让 `.env.example`/compose/docs 长期写着「须与 Dockerfile 构建参数一致」这种错误约束。
  运行用户只由**运行时环境变量**决定（compose 的 `${USER_UID:-1000}` + entrypoint 双层兜底，
  镜像自带的 `node` 用户即 1000），因此 `.env` 里通常**无需**写这两项 —— `.env.example` 已改为
  默认注释掉，并说明「仅当宿主卷属主不是 1000 时才需要」。compose/docs 07（中英）同步纠正。
  `test-nonroot.sh` 增加两条门禁：必须有 initgroups 探测与退化路径；Dockerfile 不得再声明该 ARG。
- **compose 移除本地构建路径（`build:`），只保留 pull**。（真机教训 2026-09-17）
  `image:` 与 `build:` 共用同一个 tag 时，只要本地没有该镜像，`docker compose up -d` 会
  **回退成"用当前目录的 Dockerfile/scripts 构建"而不是报错**。于是「把 `DSH_IMAGE` 换成本次
  要升级的 tag、但该 tag 在 ghcr 上还没发布」这种情形会**静默退化**为跑一份"用旧 checkout
  构建、名字却像新版本"的镜像 —— 真机表现就是容器内 `/usr/local/bin/dsh-entrypoint` 仍是
  上一版（`DSH_INIT_DONE` 不存在）、日期停在旧构建日，而人以为已经在跑新 tag，排查时极具
  误导性。移除后 **pull 不到即硬失败**，不再有"看似升级成功、实则跑旧代码"的中间态。
  确需自建（离线/内网、换 `APT_MIRROR`、自定义 Node 基础镜像）请显式
  `docker build --build-arg DSH_VERSION=<版本> -t <你的tag> .`，再把该 tag 填进 `DSH_IMAGE`。
  同步更新：docs 07（中英，`DSH_VERSION`/`PNPM_VERSION` 不再经 compose 生效，仅 `--build-arg`）、
  docs 06（中英，重建容器改用 `docker compose pull && up -d`）；
  `test-compose-wiring.sh` 增加"compose 不得声明 `build:`"门禁（忽略注释行）。

## [v0.4.7-dsh-0.1.6-alpha.1] - 2026-09-17

> 跟随 **v0.4.6 真机上线暴露的三个问题**修复（同一个 NAS 实例连续踩到）。
> 镜像 seed 锁定的 DSH 版本仍为 `0.1.6-alpha.1`；本版**不改部署模型**，只把
> 「非 root 迁移」与「tmpfs noexec」两类真实故障在镜像层兜住，使升级不再需要人工
> 改 compose 或手工 chmod。

### Fixed
- **非 root 启动的第二个坑：属主无读权限的历史文件**。
  `chown` 只改属主、**不改权限位**。真机 `/data/dsh` 下有 104 个模式为 `0000` 的
  文件（`sessions/--*--/session.jsonl.zstd`、`storages/session_projcache/sessions/*.json`，
  全部来自 09-07~09-10），连属主自己都读不了：以 root 运行时被 `CAP_DAC_OVERRIDE` 掩盖，
  降权到 uid 1000 后 dsh 打开它们即 `EACCES` → 插件树加载失败 → 启动失败 → 自愈耗尽 → lifeboat
  （`@deepseek-ai/dsh-workspace` 属核心 bundle，**web 与 lifeboat 都会加载它，故两者一起死**，
  表现成"连救生舱都进不去"的无限重启）。
  entrypoint 的 root 首启块现在会在属主整备之后补一遍**属主可读性归一**
  （`find <vol> -not -perm -u+r -exec chmod u+rwX {} +`，只碰无 u+r 的条目，
  `X` 仅对目录/已可执行文件加 x）。失败只告警、绝不阻断启动。
- **镜像层兜底：原生插件绑定缓存不再依赖 `/tmp` 可执行**。v0.4.6 已在 compose 里给
  `tmpfs /tmp` 加了 `exec`，但只要使用者沿用旧 compose（真机即如此），`noexec` 仍会让
  `node-addon-native-custom-loader` 无法 dlopen 复制到 `/tmp` 的 `.node` 绑定，从而
  第三方插件全部 `ERR_MODULE_NOT_FOUND`。现于 `Dockerfile` 设
  `ENV NARB_DISABLE_NATIVE_CACHE=1`：绑定改从 `/opt/dsh`（挂载卷，可执行）原路径加载，
  既不依赖 `/tmp` 可执行、也不额外写盘。`test-compose-wiring.sh` 增加对应门禁。
- **rescue 快照 hardlink 失败的回退会产出 `node_modules/node_modules` 嵌套**。
  `cp -al` 失败时会在目标留下**部分创建的目录树**；原代码未清理就回退 `cp -a SRC DST`，
  而 DST 已存在 → cp 把 SRC 拷**进** DST，产出嵌套目录。真机实测每份快照因此多占约 900MB
  （`snap-0060`/`snap-0061` 各 1.8G，而正常应为 904M）。现回退前先 `rm -rf` 残留，
  与 `.dsh-module-fallback` 分支语义一致；同时把 `cp -al` 的 stderr 前两行写进 rescue.log
  （此前被丢弃，真机排查时无法得知是 EXDEV / EACCES / 配额）。

### Changed
- **启动时的卷属主整备不再全量 `chown -R`**。真机三卷合计约 **28.8 万个文件**
  （`/data/dsh` 21.7 万），而 `chown -R` 会对**每个 inode 都发起一次写**——NAS 上每次启动
  成本很高，且绝大多数文件本来就已归运行用户。改为
  `find <vol> \( -not -user U -o -not -group G \) -exec chown U:G {} +`：
  语义等价（该改的一个不漏），已正确的条目只被 stat、不产生写。

## [v0.4.6-dsh-0.1.6-alpha.1] - 2026-09-17

> 跟随**容器安全加固**落地（非 root 运行 + capability/只读硬化）。镜像 seed 锁定的 DSH 版本
> 仍为 `0.1.6-alpha.1`（与 v0.4.5 相同），**部署/升级/entrypoint 安全模型做了实质改动**：容器由
> root 改为非 root（uid 1000）运行、`cap_drop`+`read_only` 收紧；同时修正
> `DSH_TRUSTED_HOSTS` 与 dsh-remote 关系的文档口径（装认证插件后无需白名单）。

### Added
- **容器安全加固：改为非 root 运行 + 收紧 capability/只读**（在 v0.4.5 之上的部署硬化）。
  - **非 root 运行**：`Dockerfile` 新增 `USER_UID`/`USER_GID`（默认 `1000:1000`），复用镜像自带
    的 `node` 用户（node:24-slim 内置 uid=1000 gid=1000，无需再 groupadd/useradd）。
    镜像**不**直接 `USER 1000`，而是保留 root 启动，由 `entrypoint` 首启完成 seed 复制 +
    把三个挂载卷（`/opt/dsh`、`/data/dsh`、`/workspace`）`chown` 给运行用户后，用
    `setpriv` 降权到 uid 1000 再运行 socat / 监督循环 / dsh web。常驻进程（dsh、agent、
    npm/pnpm 升级、rescue 快照/自愈）一律非 root。`docker exec` 仍保留 root 运维通道。
  - **capability 收敛**：`docker-compose.yml` 启用 `cap_drop: [ALL]` + 最小白名单
    `cap_add: [CHOWN, DAC_OVERRIDE, SETUID, SETGID]`（仅供首启 chown 挂载卷与 setpriv 降权）。
  - **只读根 FS**：`read_only: true` + `tmpfs /tmp`（128m）。根 FS 只读后，`NPM_CONFIG_CACHE`
    由 entrypoint 默认兜底到可写卷 `/opt/dsh/.npm-cache`（`_cacache` 清理仍命中）。
  - **web profile 固化为 `patchReload: startup`（关闭 HMR）**：`web` 是 dsh 唯一默认
    `patchReload:"live"`（改 cordis.patch.yml 即时热重载）的 profile；但其 HMR 依赖的 native
    addon（`node-addon-require-builtin`）在 `read_only` 根 FS 下无可用 binding，启动即抛
    `--expose-internals is required`，dsh 崩溃且 rescue 无法自愈。`entrypoint` 首启会在 root
    段把 web profile manifest 改写为 `patchReload: "startup"`（dsh 官方合法值，改配置后
    `docker restart` 生效，与 acp/headless/sdk 默认一致）。生产加固语义下关闭实时热重载。
    这是 read_only + dsh 0.1.6-alpha.1 的已知交互，`test-nonroot.sh` 已加对应断言。
  - 新增 `USER_UID` / `USER_GID` 环境变量（compose 注入，默认 1000:1000）；`.env.example`
    与 docs/07 速查表登记。
  - 新增单测 `scripts/t/test-nonroot.sh`（seed 复制 / npm 升级 / rescue 快照+回滚三条链路
    在非 root 下的可写性 + `cap_drop`/`read_only` 在位）。`test-compose-wiring.sh` 硬化
    门禁已补 `cap_drop`/`read_only`/`tmpfs` 断言。
  - **注意（NAS/内核）**：`cap_drop:[ALL]` 搭配部分 NAS 存储后端可能影响卷权限（尤其
    rescue hardlink 快照的 `cp -al`）。已在本仓库 e2e 沙箱验证通过；部署到目标平台前
    请先跑 `scripts/t/e2e-container-selftest.sh`。

### Fixed
- **文档口径修正：`DSH_TRUSTED_HOSTS` 与 dsh-remote 的关系**（2026-09-17 实测溯源）。
  原文档把"必须加白否则 `/api` 403"写成无条件警告，但装了认证插件 dsh-remote 的部署
  **不需要**白名单：其 `trustProxy` 在请求通过登录认证后把 Host/Origin 归一为 loopback
  （`127.0.0.1:3081`）再交给 dsh 核心的 Host 信任围栏，围栏自然放行——实测任意域名/
  隧道 Host 登录后 `/api` 均 200；未登录请求在 dsh-remote 的 gate 处即被 403。
  该行为是 dsh-remote 的设计（认证层取代 Host 白名单）。受影响表述已全部修正：
  `.env.example` 与 `docker-compose.yml` 的注释（"必填"改为"未装 dsh-remote 时必填"）、
  docs 01/02/04/05（中英同步，02 的"⚠ 必须把域名加进白名单"改为"ℹ 装 dsh-remote 时
  不需要"）。部署逻辑本身无改动。
- **`tmpfs /tmp` 必须显式带 `exec`（真机故障修复，2026-09-17）**：Docker 的 tmpfs 默认带
  `noexec`。dsh 的 **profile 插件解析**依赖原生插件 `node-addon-native-custom-loader`，它会把
  `node-addon-require-builtin` 的 `.node` 绑定复制到 `$TMPDIR/node-addon-native-custom-loader-<uid>/native-cache/`
  再 `require()`；在 `noexec` 的 `/tmp` 上该加载以 `failed to map segment from shared object`
  失败 → 绑定不可用 → `dsh-app-boot` 装不上 profile 解析 hook（`loader.internal` 为空）→
  **所有第三方插件 `ERR_MODULE_NOT_FOUND`** → web profile 启动失败 → 自愈耗尽 → 进 lifeboat。
  `docker-compose.yml` 的 tmpfs 已改为 `/tmp:size=128m,exec`；`test-compose-wiring.sh` 增加
  对应门禁。注意：**空 profile 的 e2e 不会触发此问题**，只有装了插件的部署才会踩到。
- **修复 CI 红灯：`scripts/t/test-nonroot.sh` 缺可执行位**。仓库 `core.filemode=false`，
  `git add` 不会记录执行位，导致新脚本以 `100644` 入库；CI 的 `test-script-modes.sh` 断言
  `scripts/t/*.sh` 必须可执行，检出后即失败（本地因工作区恰好可执行而漏过）。已用
  `git update-index --chmod=+x` 修正为 `100755`。

## [v0.4.5-dsh-0.1.6-alpha.1] - 2026-09-16

> 跟进 `rescue clean` 功能落地（任务 1-7 + 最终广度评审）。镜像 seed 锁定的 DSH 版本
> 仍为 `0.1.6-alpha.1`（与 v0.4.4 相同），**部署/升级/entrypoint 链路本身未做改动**；
> 本版本的核心增量是新增了清理命令 `rescue clean` 及其相关环境变量。

### Added
- `rescue clean`：升级后环境清理。默认 dry-run 预览，`--yes` 执行前自动拍 pre-clean 快照。
  清理 npm 缓存、pnpm store 孤儿、profile `.pnpm` 中未被 lockfile 引用的条目与超限救援历史；
  不触碰依赖基线与快照，不影响 `rescue rollback`。
- 新环境变量 `NPM_CONFIG_CACHE`：容器内 npm / pnpm 的下载缓存目录。留空时自动探测
  （`npm config get cache`，通常为 `/root/.npm`）；该路径不可写时可指向挂载的卷。
  `rescue clean` 会清空其中的 `_cacache`。（`docker-compose.yml` 与 07 环境变量速查表已登记。）

### Fixed
- `rescue clean --yes` 的 pre-clean 快照护栏现在会**校验快照确实存在**后再执行删除。
  此前 `rescue_snapshot` 尾部的轮转会与既有快照竞争同一个 `RESCUE_KEEP` 窗口：窗口已满
  （尤其被 pinned 的 `boot-healthy` 占满）时，刚拍的 pre-clean 快照会被自己淘汰，而 CLI 仍
  打印「snapshot created」并以 0 退出 —— 用户被告知有回退点、实际没有。现在该场景会**告警、
  以非零退出且不删除任何文件**（fail-closed）。
- `rescue clean` 的清理项失败不再静默：`npm-cache` / `pnpm-store` / `pnpm-orphans` /
  `rescue-history` 中任一项失败都会在 CLI 侧汇总回显（保留「不中断整体流程」的容错语义）。

## [v0.4.4-dsh-0.1.6-alpha.1] - 2026-09-15

> 跟进 DSH 预览版：镜像 seed 锁定的 DSH 版本由 `0.1.5-rc.2` 升至 `0.1.6-alpha.1`
> （npm dist-tag `alpha`）。**本仓库的部署逻辑未做任何改动** —— entrypoint / 自愈救援
> 体系与 v0.4.3 完全一致；经对照验证，seed 复制、lifeboat、快照与 CI 全链路在 0.1.6 下均可用。

### Changed
- **锁定 DSH 版本 `0.1.5-rc.2` → `0.1.6-alpha.1`**：CI 依 tag 后缀解析 `DSH_VERSION`，
  故 `v0.4.4-dsh-0.1.6-alpha.1` 构建出的镜像 seed 内即为 0.1.6-alpha.1；发布门禁 3（镜像自证）
  会在构建后用镜像内 `/opt/dsh-seed/bin/dsh --version` 断言与 tag 后缀一致。
  `Dockerfile` 的 `ARG DSH_VERSION` 与 `docker-compose.yml` 本地构建的默认值同步跟进。
- **文档版本引用同步**：README（中/英）徽章更新为 `0.1.6-alpha.1`；示例 tag、07 环境变量速查表
  的 `DSH_VERSION` 默认值、03 升级文档的 dist-tag 说明表一并更新。

### 升级注意（0.1.5-rc.2 → 0.1.6-alpha.1）

⚠️ **这是 alpha 预览版，不是稳定版。** 生产环境请评估后再跟进；npm 的 `latest` 仍指向 0.1.5-rc.1，
`next` 指向 0.1.5-rc.2 —— 要用本版本必须写全 `@0.1.6-alpha.1`。

- 容器内部署（程序装在卷上）无需重建镜像：
  `docker exec dsh npm install -g @deepseek-ai/dsh@0.1.6-alpha.1 && docker restart dsh`。
  注意：**不能**用 `@latest` 或 `@alpha` 之外的简写，前者根本拿不到 0.1.6。
- 用镜像部署则改用新 tag：`DSH_IMAGE=ghcr.io/steven-stack-s/dsh-docker:v0.4.4-dsh-0.1.6-alpha.1`
  （或继续跟随 `:latest`）。
- **会话数据格式**：0.1.5 → 0.1.6 可能包含不可回读的数据迁移。按 §备份 惯例，升级前请备份
  程序 / 数据 / 工作区三个卷，以便按 docs/zh-CN/03-升级与维护.md 回滚。
- **自定义插件需留意**（若你装了第三方插件）：0.1.6 将服务名 `codeRuntime` 改名为 `ptcRuntime`，
  工作流执行器 `dsh-workflow-worker-thread` 改为 `dsh-workflow-ptc`，且 `tool-ralph` 默认关闭。
  注入旧服务名的插件会激活失败。dsh-docker 的救生舱与自愈可兜底，但仍建议先在测试环境验证。
- 详细变更分析见 `issues/2026-09-15-dsh-0.1.6-alpha.1-适配分析.md`。

## [v0.4.3-dsh-0.1.5-rc.2] - 2026-09-15
### Fixed
- **证据链尾部丢失（`logtag.js` / `logtee.js`）**：两者在 stdin 关闭时调用 `process.exit(0)`，
  而 stdout 接管道时是**异步**的，缓冲区里可能还压着大量未刷出的数据 —— 强退会直接丢弃它们。
  实测 20001 行输入只留下 **8712 行（丢 56%）**，且**尾部（往往正是崩溃原因）整段消失**，
  diagnose 拿不到证据只能 report-only，表现为「自愈偶尔不灵」且日志上完全看不出原因。
  改为 `process.exitCode = 0`，让 Node 在 stdout 自然排空后退出；修复后 20001 行完整保留。
- **`test-compose-wiring.sh` 的门禁与文档分层脱节**：`.env.example` 精简为日常 12 项后，
  高级变量迁到 `docs/07-环境变量速查表`，但门禁仍只认 `.env.example` —— 于是必然红灯。
  改为「`.env.example` 或 07 速查表任一命中」即通过（.env.example 用 `^VAR=` 锚定，
  速查表用反引号/表格列锚定，避免子串误判）。**不变式仍是「代码读的变量必须有文档」**，
  已用「注入一个未文档化变量必须变红」反向验证门禁未被削弱。
- **快照/回滚遗漏 `.dsh-module-fallback`**：DSH 的 bundle 包解析会在 profile 下维护该目录，
  而 `profile/node_modules` 里的 bundle 条目往往是指向它的**符号链接**。旧实现只快照
  `node_modules` + 三个配置文件，回滚后链接还在、目标没了 —— 表现为「回滚成功但 profile 起不来」，
  比不回滚更糟（消耗了自愈预算、改了树、还没修好）。现随 `node_modules` 一并纳入快照与还原事务。

### Changed
- **tag 格式改为 `v<X.Y.Z>-dsh-<X.Y.Z>`（`-dsh-` 两侧都有连字符）**：此前为 `-dsh` 紧贴版本号
  （如 `v0.4.2-dsh0.1.5-rc.2`）。**旧格式不再被接受**：`ci-image-tags.sh` 的正则同步收紧，
  旧格式 tag 会直接报错退出（不再静默切分出错误版本）。
  仓库内 15 个历史 tag 已全部按新格式重建并推送（指向的 commit、annotated 的 message/tagger/
  时间戳、lightweight 类型均原样保留），CHANGELOG 历史标题与 README/workflow/compose 中的示例同步更新。
  > ⚠️ **升级注意**：远端 15 个旧格式 tag 已删除、新格式 tag 已推送（不可逆）。
  > 已用旧 tag 拉取镜像的部署不受影响（ghcr 上已有镜像仍可拉取），但旧 tag 名不再可用；
  > 引用过旧 tag 的脚本 / 文档 / 书签需要改为新格式。
- **`Dockerfile` 的 `ARG DSH_VERSION` 由 `latest` 改为显式版本号（`0.1.5-rc.2`）**：
  npm 的 dist-tag 是发布者**手动指定**的别名、不会自动前进，且默认值会随 npm 上的 tag 变动而
  **静默漂移**（同一份 Dockerfile 在不同时间构建出不同版本）。改后 `docker build` 与
  `docker compose build` 在不传 `DSH_VERSION` 时产出一致的 dsh 版本。
- **`.env.example` 精简为 12 项日常变量**：`docker-compose.yml` 不变（所有变量仍以 `${VAR:-default}` 兜底存在）。
  原 35 项里 25 项高级调优（`RESCUE_*` 细节、`NODE_MAX_OLD_SPACE`、`PIDS_LIMIT`、`SOCAT_MAX_CHILDREN`、
  `NPM_REGISTRY`、`TZ`、`DEEPSEEK_API_KEY_FILE` 等）从 `.env.example` 移除，**默认值不变**。
  保留：`DEEPSEEK_API_KEY`、`DSH_IMAGE`、`DSH_CONTAINER_NAME`、`DSH_PORT`、三个挂卷目录、
  `DSH_TRUSTED_HOSTS`、`MEM_LIMIT`、`CPU_LIMIT`、`RESCUE`、`RESCUE_AUTO`。

### Added
- `scripts/t/test-module-fallback-snapshot.sh`：锁定 `.dsh-module-fallback` 必须随 `node_modules`
  一起快照/还原（见上方 Fixed）。含 6 条断言，并用「回放去掉修复的实现必红」验证其确实能捕获回归。
- **`probe-ready.js` 的 L4 失败文案新增 `/required startup failure/i`**：DSH 0.1.6 起把启动失败
  分为「必需条目」与「可选条目」，前者用该文案。不补则「必需插件挂了但 HTTP 仍返回 200」会被漏判成健康。
- `docs/zh-CN/07-环境变量速查.md` 与 `docs/en/07-environment-variables.md`：高级变量完整速查表
  （按 RESCUE / 资源限制 / 构建 / 工具链 / 凭据分组，含默认值与覆盖方式），并列出两个常见的覆盖方式
  （改 compose 默认值 / 在 `.env` 追加同名变量）。README 中/英文快速开始与文档索引同步指向此文件。

### 升级注意
- **老用户 `.env` 里手动设过的非保留项（如 `RESCUE_KEEP`、`RESCUE_SNAPSHOT_MODE`）将被忽略**：
  `docker compose` 解析不到 `.env` 里的这些键就会走 compose 中的默认值。若你之前调过这些变量，
  升级后请二选一：
  - 把这些变量移到 `docker-compose.yml` 的 `environment:` 段（推荐 —— 更直观）；
  - 或保留在 `.env` 文件里（compose 中没有 `${VAR:-...}` 引用则不会进容器，需手动加到 compose）；
  - 或临时一次性覆盖：`VAR=value docker compose up -d`。
- `.env.example` 行数 103 → 51，**部署行为零变化**（默认值未改）。

## [v0.4.2-dsh-0.1.5-rc.2] - 2026-09-14

### Fixed
- **`prune` 不再把唯一的健康基线挤出窗口**：`rescue_prune()` 现在钉住**最新一份** `boot-healthy` 基线快照（reason 形如 `boot-healthy*`），
  逐出改为「从最老往最新取第一个非钉住项」。背景：自愈选回退目标时第一轮只认基线（`rescue_pick_rollback_target` —— 唯一被证明能启动过的状态），
  而插件市场(dshmarket) / 手工变更会连续产生快照，纯 FIFO 轮转会先把基线删掉，自愈只能退化到第二轮的任意非现场快照（最坏 report-only）。
  钉住只改变「淘汰谁」：总份数仍受 `RESCUE_KEEP` 约束；窗口内全是基线时照常逐出更旧的那些，不会卡死。
  新增 `scripts/t/test-prune-pin-baseline.sh`（5 组用例：基线为最老一份必须留下 / 无基线时行为不变 / 多份基线只钉最新 / 全基线仍能减员 / KEEP 已满足时不动）。
  文档同步：`docs/{zh-CN,en}/06` 参数表与新增「快照保留」说明、`.env.example` 两处注释。

## [v0.4.1-dsh-0.1.5-rc.2] - 2026-09-13

> 例行跟版：镜像 seed 锁定的 DSH 版本由 `0.1.5-rc.1` 升至 `0.1.5-rc.2`（npm 于 2026-09-10 发布，dist-tag `next`）。
> 本仓库的部署逻辑与 v0.4.0 完全一致 —— entrypoint / 自愈救援体系未做任何改动。

### Changed
- **锁定 DSH 版本 `0.1.5-rc.1` → `0.1.5-rc.2`**：CI 依 tag 后缀解析 `DSH_VERSION`（`.github/workflows/docker-image.yml`），故 `v0.4.1-dsh-0.1.5-rc.2` 构建出的镜像 seed 内即为 0.1.5-rc.2；发布门禁 3（镜像自证）会在构建后用镜像内 `/opt/dsh-seed/bin/dsh --version` 断言与 tag 后缀一致。`docker-compose.yml` 中本地构建的默认值 `DSH_VERSION` 同步跟进。
- **文档 tag 示例同步**：README（中/英）的 DSH 版本徽章更新为 `0.1.5-rc.2`；README、`docker-compose.yml` 注释与 workflow 注释中的示例 tag 改为 `v0.4.1-dsh-0.1.5-rc.2`。此徽章此后由 tag 构建成功后的 `scripts/update-dsh-badge.sh` 自动同步，无需手工维护。

### 升级注意（0.1.5-rc.1 → 0.1.5-rc.2）
- 容器内部署（程序装在卷上）无需重建镜像：`docker exec dsh npm install -g @deepseek-ai/dsh@0.1.5-rc.2 && docker restart dsh`。
- 用镜像部署则改用新 tag：`DSH_IMAGE=ghcr.io/steven-stack-s/dsh-docker:v0.4.1-dsh-0.1.5-rc.2`（或继续跟随 `:latest`）。
- 同一 minor 内的预发布迭代，仍建议按惯例在升级前备份整个部署目录（程序 / 数据 / 工作区三个卷），以便按 docs/zh-CN/03-升级与维护.md 回滚。

## [v0.4.0-dsh-0.1.5-rc.1] - 2026-09-12

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
- **tag 形态校验收紧（独立评审发现）**：`v0.3.7-dsh-0`、`v0.3.7-dsh-note-dsh0.1.5`、`v0.1.0-dsh-0.1.2-rc.1+build` 此前都能通过校验（分别导致 npm 按 0.x 解析、切分出 `-note-dsh0.1.5`、Docker tag 含非法 `+`）。现要求 `v<X.Y.Z>-dsh-<X.Y.Z>[-预发布]`，字符集限定为 Docker tag 允许的 `[A-Za-z0-9_.-]`；分支 slug 同步做字符清洗。
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

## [v0.3.7-dsh-0.1.5-rc.1] - 2026-09-10

### Added
- **`probe-ready.js` 分层就绪探测**：启动窗口的健康判定由「TCP 端口可连接」扩展为三层——**L1** TCP 监听、**L2** 在其上完成一次 HTTP 往返、**L3** 连续 `--stable`(默认 2) 次成立。退出码契约不变（exit 0 = 就绪），`rescue-supervise.sh` 的调用语义零变更。
  - L2 **任何状态码都算通过**：装了认证网关（如 `@xgone/dsh-remote`）时，未认证的 `GET /` 返回的是登录页而非应用外壳；若要求 200 + 特定内容，这类实例会被永久判为不健康并触发回滚死循环。故 L2 只证明「HTTP 栈真的能应答」，只有连上了却拿不到任何 HTTP 响应（超时/连接重置）才算失败。
  - 新增可选 `--pid <pid>`：目标进程一消失即立即判失败，把「启动后立刻崩溃」的检测从 `RESCUE_START_TIMEOUT`(默认 120s) 降到秒级（`rescue-supervise.sh` 传入 `$child`；不传则行为与改造前完全一致）。
  - 分层结果以英文 `[probe]` 前缀、按**状态变化**输出：1s 轮询下不刷屏，同时保留「卡在哪一层」的诊断线索。
  - 新增 `scripts/t/test-probe-ready.sh`（用法/HTTP 就绪/仅 TCP 无应答/无监听/`--pid` 秒级失败/`--stable`/旧参数兼容）。

### 已知边界
- **覆盖不到「服务端正常、但浏览器端客户端插件树激活失败」**（如 0.1.2→0.1.5 升级后首启出现的 `25 entries did not activate`）：该类审计只在浏览器端（`dsh-web-frontend`）执行，服务端的端口、HTTP 与客户端模块清单全程正常，探针无从取得差异信号。端到端覆盖需无头浏览器，代价是镜像 +数百 MB、启动变慢十几秒。

## [v0.3.6-dsh-0.1.5-rc.1] - 2026-09-10

镜像锁定的 DSH 版本由 `0.1.2-rc.1` 升级至 `0.1.5-rc.1`（tag 后缀同步变更）。CI 依 tag 解析 `DSH_VERSION`（`.github/workflows/docker-image.yml`），故镜像 seed 内即为 0.1.5-rc.1。

### Changed
- **容器日志统一为英文**：`entrypoint.sh` 的 8 处 `elog`（首启播种 / dsh 就绪 / socat 转发 / Host 白名单等，即 `docker logs` 中 `[entrypoint]` 前缀的各行）改为英文，便于日志检索与在非中文环境下的阅读与转发。`rescue` CLI 提示、`rescue report` 及 `diagnose.js` 写入 incident 的诊断文本（`rationale` / `detail` / `kw`）**保持中文**；源码注释与本文档亦保持中文。`scripts/t/` 全量单测通过（9/9）。

### 升级注意（0.1.2-rc.1 → 0.1.5-rc.1）
- 该跨度含**破坏性变更**：会话数据格式升级至 V3（迁移后**旧版不可读**，原文件保留）；插件 Agent API 移除 `ctx.agent`；`Inbox` 改为类型接口；Web 插件面板 Slot 由 `conversation` 迁移为 `main` 的 `conversation` key（原 Detail 面板移除）；Web `minimal` 默认仅提供持久 shell。升级前请确认 profile 内第三方插件已适配新核心。

## [v0.3.5-dsh-0.1.2-rc.1] - 2026-09-10

### Added
- **健康基线快照**：entrypoint 在确认 dsh 健康后自动拍一份基线（`RESCUE_SNAPSHOT_ON_HEALTHY=off` 可关）。插件市场（`dshmarket` 在 dsh 进程内直接改 profile 的 package.json/node_modules）**绕过 rescue 封装、不会拍预防性快照**，此前市场更新后启动失败只能 report-only；现由「变更前已有的健康基线」充当回退点，自愈可自动 rollback 恢复。仅在已被证明可启动的状态下拍，失败不影响启动，并在 rescue.log 记 re-baselining 审计（含 profile 指纹变化提示）。

### Fixed
- **快照编号重用 + 「最新/最老」按字典序误判**（会导致自愈回滚到错误快照）：`next_snap_name` 由「找第一个空缺编号」改为「最大编号 + 1」（prune 删除后不再复用编号）；新增 `rescue_snapshot_newest/oldest`（按 meta.created 排序，缺失回退目录 mtime），`diagnose.js` 的最新快照选取、supervise 的 `newest_snap` / 基线 / remove-escalate 目标、`rescue rollback` 与 `rescue_prune` 全部改用它。真机复现：补位编号下旧快照被当成最新。
## [v0.3.4-dsh-0.1.2-rc.1] - 2026-09-09

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

## [v0.3.3-dsh-0.1.2-rc.1] - 2026-09-09

### Changed
- **方案 A 重构：entrypoint 拆分**——`entrypoint.sh` 由 386 行减为 148 行薄壳（只承担 PID1 生命周期与依赖准备）；归因自愈编排（证据捕获 / diagnose / incident / budget / 自愈执行器）与监督主循环抽到新 `scripts/rescue-supervise.sh`，由 entrypoint source 后调 `rescue_supervise()`。行为零漂移（三重逐字等价 + source 契约测试 + 真机回归），Dockerfile 同步 COPY。
## [v0.3.2-dsh-0.1.2-rc.1] - 2026-09-09

### Added
- **日志逐行加时间戳**：entrypoint 消息经新 `elog()` 加前缀 `[YYYY-MM-DDTHH:MM:SS±HHMM]`（与 rescue.log 同格式）；dsh 应用输出经新 `scripts/logtag.js` 行过滤器（fifo → logtag | tee）同样逐行带时间戳，docker logs 与 evidence/dsh.log 同步生效；logtag 缺失时降级为原 tee 直连。entrypoint.sh 修正为可执行模式。
## [v0.3.1-dsh-0.1.2-rc.1] - 2026-09-08

### Fixed
- **恢复 healthy 后的完整容器日志**：v0.3.0 的 tee 证据捕获在健康路径调 `rescue_close_ev` 杀掉了 fifo 唯一读端（tee），导致 dsh 在 healthy 之后的所有 stdout 输出无读者而被丢弃——`docker logs` 里 dsh 日志消失（长期还会填满 fifo 缓冲阻塞写端）。现在 healthy 后仅释放 entrypoint 自身写端，tee 持续把 dsh 输出转发到容器日志与证据文件，dsh 退出（EOF）后 tee 自然收尾；boot 失败路径语义不变。
- 新增 `rescue_evidence_prune`：按 `RESCUE_KEEP` 修剪 `evidence/boot-*`，防止 healthy 会话持续镜像的 dsh.log 无限累积。
## [v0.3.0-dsh-0.1.2-rc.1] - 2026-09-08

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

## [v0.2.0-dsh-0.1.2-rc.1] - 2026-09-07

### Added
- 插件**救援模式**设计定稿与实施计划（docs/superpowers/specs|plans 2026-09-07-rescue-mode）：自动回退 + 救生舱（lifeboat）干净 profile 模板；entrypoint 监督式启动 + 自动回滚；`rescue` 命令集初版。
- Dockerfile 正确复制 lifeboat.tmpl 到子目录（mkdir + `dir/.`）；加 openssh-client；rescue.log 审计完整性。
- 救援模式文档 + 端到端验收脚本；修正 .env.example 的 RESCUE_AUTO 语义注释。

## [v0.1.2-dsh-0.1.2-rc.1] - 2026-09-06

### Fixed
- socat 转发上游加 forever+interval 重试，避免 dsh 尚未就绪时出现 Connection refused。

## [v0.1.1-dsh-0.1.2-rc.1] - 2026-09-03

### Fixed
- 修复 `/api` 通道 Host 信任围栏导致的连接异常，新增 `DSH_TRUSTED_HOSTS` 白名单参数。

## [v0.1.0-dsh-0.1.2-rc.1] - 2026-09-03

### Changed
- 双版本 tag 约定（`v<项目版本>-dsh-<dsh版本>`），镜像 label 写入两个版本号；tag 名映射 DSH_VERSION，镜像 seed 与 dsh 版本保持一致。

### Fixed
- 复制 seed 后清理 `/opt/dsh-seed`，避免容器内重复副本；兼容 Windows 开发的 CRLF 换行；支持本地构建并锁定 dsh 版本。

## [0.0.x] - 2026-09-02（初始，未打 tag）

- 初始：DSH Docker 通用部署方案（镜像/程序分离 + 容器内升级 + socat 端口转发）；README 中英双语化 + docs/ 五篇文档；构建时预装 dsh+pnpm 到 seed；ghcr 镜像名转小写。
