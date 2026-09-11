[English](README.md) | **简体中文**

# DSH Docker 部署

> 在**任意 Docker 环境**（Linux 服务器 / NAS / 云主机 / Docker Desktop）一键部署
> [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（DSH）——DeepSeek 官方的 AI 编程 Agent 框架（Web UI + CLI）。

---

## ✨ 方案亮点

**🧱 架构 —— 三层分离，秒级就绪，升级不重建镜像**

- **构建时锁版本 + 镜像内 seed**：构建时预装 dsh+pnpm 到 seed（`/opt/dsh-seed`），首次启动离线复制到 `/opt/dsh`（版本固定、秒级就绪）；seed 保留在镜像层，主程序损坏可离线恢复
- **程序与镜像分离，容器内升级**：DSH 程序本体装在挂载卷，日常升级 = `docker exec dsh npm install -g @deepseek-ai/dsh@<版本> && docker restart dsh`，无需重建镜像
- **数据全持久化**：程序 / 用户数据（会话、配置、插件、记忆库）/ 工作区三卷分离，备份 = 复制目录
- **安全默认**：`dsh web` 刻意只监听 `127.0.0.1:3081`（官方安全设计），`socat` 把外部 `3080` 转发进去；默认内网直连，远程访问可加装账号密码 + MFA 认证
- **多架构**：GitHub Actions 自动构建 `linux/amd64` + `linux/arm64`，发布到 `ghcr.io`

**🛟 自愈体系 —— 确定性归因，守红线自动恢复**

- **确定性根因归因（非 LLM）**：`diagnose.js` 用规则表 + 变更上下文判定启动失败根因并给出处置建议（remove-plugin / rollback / report-only），可单测、可审计、行为可预期
- **严守红线**：自动处置只动插件树四件套（package.json / pnpm-lock.yaml / pnpm-workspace.yaml / node_modules）+ `.rescue` 状态，**绝不动 cordis.patch.yml / 会话 / 记忆 / 配置 / 凭据**
- **完整降级阶梯**：快照回滚 → 摘插件 → 升级 rollback → report-only → lifeboat 救生舱，逐级预算限额，全程审计日志留痕
- **近零成本快照 + 证据闭环**：`cp -al` 硬链接快照（跨文件系统自动降级 `cp -a`）；启动日志经 fifo 逐行加时间戳、双写 docker logs 与 evidence，启动失败有据可查

---

## 📦 快速开始（3 步）

```bash
# 1. 拉取仓库并配置
git clone https://github.com/steven-stack-s/dsh-docker.git && cd dsh-docker
cp .env.example .env            # 编辑 .env，填入 DEEPSEEK_API_KEY

# 2. 启动（首次启动从镜像内 seed 复制 DSH，秒级就绪）
docker compose up -d

# 3. 访问 —— docker logs dsh 会打印一次性 token；首次访问 http://<主机IP>:3080/?token=<token>（之后无需再带）
```

详细步骤见 [docs/zh-CN/01-快速开始.md](docs/zh-CN/01-快速开始.md)。

---

## 📚 文档

| 文档 | 内容 |
|---|---|
| [docs/zh-CN/01-快速开始.md](docs/zh-CN/01-快速开始.md) | 安装、配置、token 访问、验证 |
| [docs/zh-CN/02-认证与远程访问.md](docs/zh-CN/02-认证与远程访问.md) | 可选 dsh-remote 认证、SSH 隧道、反向代理 |
| [docs/zh-CN/03-升级与维护.md](docs/zh-CN/03-升级与维护.md) | 升级、插件、密钥、备份 |
| [docs/zh-CN/04-故障排查.md](docs/zh-CN/04-故障排查.md) | 常见问题 |
| [docs/zh-CN/05-平台差异.md](docs/zh-CN/05-平台差异.md) | Linux / NAS / Docker Desktop 差异 |
| [docs/zh-CN/06-救援模式.md](docs/zh-CN/06-救援模式.md) | 插件救援：自动回退 + **自动排查 / 根因归因 / 智能自愈** + 救生舱，含 `rescue report` 事故审阅 |

---

## 🔧 目录结构

```
.
├── docker-compose.yml        # 部署配置（变量见 .env.example）
├── Dockerfile                # 基础镜像：node:24 + git + socat + openssh-client + 预装 dsh seed
├── scripts/                  # 运行时代码：容器入口、rescue CLI、共享库、探针、归因引擎
├── .env.example              # 环境变量模板（复制为 .env 填写）
├── docs/
│   ├── en/                   # English docs
│   └── zh-CN/                # 简体中文文档
├── scripts/t/                # 测试：单元测试 + 宿主机端到端验收脚本
└── .github/workflows/        # CI：自动构建镜像发布到 ghcr.io

> 跑 `scripts/t/test-*.sh` 需要**宿主有 node**（其中 6 个会调用 diagnose.js / report.js / probe-ready.js
> 等 Node 脚本；CI 的 ubuntu-latest 自带，纯 shell 环境的宿主请先装 node，或直接用容器内的 node）。
```

---

## 🏗️ 架构说明

```
浏览器
   |
   v
宿主机 :3080 ──> 容器 socat(0.0.0.0:3080) ──> dsh web(127.0.0.1:3081)
```

- 镜像构建时预装 dsh+pnpm 到 seed（`/opt/dsh-seed`），运行环境含 `node:24-slim` + git + ca-certificates + tzdata + socat + openssh-client
- 首次启动 `scripts/entrypoint.sh` 把 seed 复制到挂载卷 `/opt/dsh`（秒级、离线、版本固定），pnpm 随 seed 一起就位
- 自定义构建：`docker build --build-arg DSH_VERSION=<版本> --build-arg APT_MIRROR=mirrors.aliyun.com -t dsh-docker:<版本> .`
- 三个持久化卷：`./programs`（DSH 程序本体）、`./dsh`（DSH_HOME 用户数据）、`./workspace`（agent 工作区）

---

## ⚠️ 安全提示

- `DEEPSEEK_API_KEY` 只写在 `.env`（已被 `.gitignore` 忽略），不要提交到仓库
- 不要把 `3080` 直接映射到公网；远程访问请按 [docs/zh-CN/02-认证与远程访问.md](docs/zh-CN/02-认证与远程访问.md) 配置认证 + 反向代理
- 定期备份整个部署目录

---

## 🏷️ 版本

发布历史见 [CHANGELOG.md](CHANGELOG.md)。镜像 tag 采用双版本 `v<项目版本>-dsh<dsh版本>`（如 `v0.4.0-dsh0.1.5-rc.1`）；推送该格式 tag 会自动构建多架构镜像到 `ghcr.io`。

---

## 📄 License

[MIT](LICENSE)
