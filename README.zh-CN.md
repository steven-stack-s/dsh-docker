[English](README.md) | **简体中文**

# DSH Docker 部署

> 在**任意 Docker 环境**（Linux 服务器 / NAS / 云主机 / Docker Desktop）一键部署
> [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（DSH）——DeepSeek 官方的 AI 编程 Agent 框架（Web UI + CLI）。

---

## ✨ 方案亮点

- **构建时锁版本 + 容器内升级**：镜像构建时预装 dsh+pnpm 到 seed（`/opt/dsh-seed`），首次启动从 seed 复制到 `/opt/dsh`（离线、版本固定、秒级就绪）；升级只需 `docker exec dsh npm install -g @deepseek-ai/dsh@<版本> && docker restart dsh`，无需重建镜像
- **安全默认**：`dsh web` 刻意只监听 `127.0.0.1:3081`（官方安全设计），`socat` 把外部 `3080` 转发进去；默认内网直连，远程访问可加装账号密码 + MFA 认证
- **数据全持久化**：程序 / 用户数据（会话、配置、插件、记忆库）/ 工作区三卷分离，备份 = 复制目录
- **多架构**：GitHub Actions 自动构建 `linux/amd64` + `linux/arm64`，发布到 `ghcr.io`

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
| [docs/zh-CN/06-救援模式.md](docs/zh-CN/06-救援模式.md) | 插件救援模式：自动回退 + 救生舱 |

---

## 🔧 目录结构

```
.
├── docker-compose.yml        # 部署配置（变量见 .env.example）
├── Dockerfile                # 基础镜像：node:24 + git + socat + openssh-client + 预装 dsh seed
├── entrypoint.sh             # 容器入口：从 seed 复制 DSH → socat 转发 → 启动 web
├── .env.example              # 环境变量模板（复制为 .env 填写）
├── docs/
│   ├── en/                   # English docs
│   └── zh-CN/                # 简体中文文档
└── .github/workflows/        # CI：自动构建镜像发布到 ghcr.io
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
- 首次启动 `entrypoint.sh` 把 seed 复制到挂载卷 `/opt/dsh`（秒级、离线、版本固定），pnpm 随 seed 一起就位
- 自定义构建：`docker build --build-arg DSH_VERSION=<版本> --build-arg APT_MIRROR=mirrors.aliyun.com -t dsh-docker:<版本> .`
- 三个持久化卷：`./programs`（DSH 程序本体）、`./dsh`（DSH_HOME 用户数据）、`./workspace`（agent 工作区）

---

## ⚠️ 安全提示

- `DEEPSEEK_API_KEY` 只写在 `.env`（已被 `.gitignore` 忽略），不要提交到仓库
- 不要把 `3080` 直接映射到公网；远程访问请按 [docs/zh-CN/02-认证与远程访问.md](docs/zh-CN/02-认证与远程访问.md) 配置认证 + 反向代理
- 定期备份整个部署目录

---

## 📄 License

[MIT](LICENSE)
