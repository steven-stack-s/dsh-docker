**English** | [简体中文](README.zh-CN.md)

# Deploy DeepSeek Harness (DSH) with Docker

> Deploy [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (DSH) — DeepSeek's official AI coding agent framework (Web UI + CLI) — on **any Docker environment** with one command.

---

## ✨ Highlights

**🧱 Architecture — three-layer separation, ready in seconds, upgrades without image rebuilds**

- **Version-pinned at build + in-image seed** — dsh+pnpm are pre-installed into a seed (`/opt/dsh-seed`) at build time; on first boot the seed is copied to `/opt/dsh` (offline, version-pinned, ready in seconds). The seed stays in the image layer, so a broken main program can be restored offline.
- **Program decoupled from image, upgraded in-container** — the DSH program lives on a mounted volume; daily upgrades are `docker exec dsh npm install -g @deepseek-ai/dsh@<version> && docker restart dsh` — no image rebuild needed.
- **Fully persisted data** — three separate volumes for program / user data (sessions, configs, plugins, memory) / workspace; backup = copy the directory.
- **Secure by default** — `dsh web` intentionally listens only on `127.0.0.1:3081` (official security design); `socat` forwards the external `3080` port into it. Intranet-only by default; password + MFA authentication can be added for remote access.
- **Multi-architecture** — GitHub Actions automatically builds `linux/amd64` + `linux/arm64` images and publishes them to `ghcr.io`.

**🛟 Self-healing — deterministic root-cause analysis, red-line-guarded auto recovery**

- **Deterministic root-cause analysis (no LLM)** — `diagnose.js` attributes boot failures with a rules table + change context and recommends an action (`remove-plugin` / `rollback` / `report-only`); unit-testable, auditable, and predictable.
- **Hard red lines** — auto-recovery touches only the plugin-tree four-piece set (package.json / pnpm-lock.yaml / pnpm-workspace.yaml / node_modules) plus `.rescue` state, **never cordis.patch.yml / sessions / memory / configs / credentials**.
- **Complete fallback ladder** — snapshot rollback → plugin removal → escalated rollback → report-only → lifeboat; every rung has a budget cap and full audit logging.
- **Near-zero-cost snapshots + evidence loop** — `cp -al` hard-link snapshots (auto-degrades to `cp -a` across filesystems); boot output flows through a fifo with per-line timestamps, dual-written to docker logs and evidence, so failures are always traceable.

---

## 📦 Quick Start (3 steps)

```bash
# 1. Clone and configure
git clone https://github.com/steven-stack-s/dsh-docker.git && cd dsh-docker
cp .env.example .env            # edit .env, fill in DEEPSEEK_API_KEY

# 2. Start (on first boot, DSH is copied from the in-image seed; ready in seconds)
docker compose up -d

# 3. Access — docker logs dsh prints a one-time token; first visit http://<host-ip>:3080/?token=<token> (later visits need no token)
```

Detailed steps: [docs/en/01-quick-start.md](docs/en/01-quick-start.md)

---

## 📚 Documentation

| Doc | Content |
|---|---|
| [docs/en/01-quick-start.md](docs/en/01-quick-start.md) | Install, configure, token access, verify |
| [docs/en/02-authentication-remote-access.md](docs/en/02-authentication-remote-access.md) | Optional auth, SSH tunnel, reverse proxy |
| [docs/en/03-upgrade-maintenance.md](docs/en/03-upgrade-maintenance.md) | Upgrade, plugins, keys, backup |
| [docs/en/04-troubleshooting.md](docs/en/04-troubleshooting.md) | Troubleshooting |
| [docs/en/05-platform-differences.md](docs/en/05-platform-differences.md) | Linux / NAS / Docker Desktop differences |
| [docs/en/06-rescue-mode.md](docs/en/06-rescue-mode.md) | Plugin rescue: auto-rollback + **auto-diagnose / root-cause / smart self-heal** + lifeboat, with `rescue report` incident review |

---

## 🔧 Directory Structure

```
.
├── docker-compose.yml        # deployment config (vars in .env.example)
├── Dockerfile                # base image: node:24 + git + socat + openssh-client + pre-baked dsh seed
├── entrypoint.sh             # container entry: copy DSH from seed → socat forward → start web
├── .env.example              # env template (copy to .env)
├── docs/
│   ├── en/                   # English docs
│   └── zh-CN/                # 简体中文文档
├── scripts/t/                # tests: unit tests + host-side end-to-end acceptance scripts
└── .github/workflows/        # CI: build image and publish to ghcr.io

> Running `scripts/t/test-*.sh` requires **node on the host** (6 of them invoke Node scripts such as
> diagnose.js / report.js / probe-ready.js; ubuntu-latest in CI ships it — on a bare shell host install
> node first, or run them with the node inside the container).
```

---

## 🏗️ Architecture

```
Browser
   |
   v
Host :3080 ──> container socat(0.0.0.0:3080) ──> dsh web(127.0.0.1:3081)
```

- At build time, dsh+pnpm are pre-installed into a seed (`/opt/dsh-seed`); the runtime also includes `node:24-slim` + git + ca-certificates + tzdata + socat + openssh-client.
- On first boot, `entrypoint.sh` copies the seed to the mounted volume `/opt/dsh` (in seconds, offline, version-pinned); pnpm comes along with the seed.
- Custom build: `docker build --build-arg DSH_VERSION=<version> --build-arg APT_MIRROR=mirrors.aliyun.com -t dsh-docker:<version> .`
- Three persistent volumes: `./programs` (DSH program), `./dsh` (DSH_HOME user data), `./workspace` (agent workspace).

---

## ⚠️ Security Notes

- `DEEPSEEK_API_KEY` lives only in `.env` (ignored by `.gitignore`) — never commit it.
- Do not expose port `3080` directly to the public internet; for remote access, add authentication + a reverse proxy (see [docs/en/02-authentication-remote-access.md](docs/en/02-authentication-remote-access.md)).
- Back up the whole deployment directory regularly.
---

## 🏷️ Releases

Release history in [CHANGELOG.md](CHANGELOG.md). Image tags follow the dual-version scheme `v<project-version>-dsh<dsh-version>` (e.g. `v0.3.7-dsh0.1.5-rc.1`); pushing a tag in that format auto-builds multi-arch images to `ghcr.io`.

> To run a **pinned** dsh version, set `DSH_IMAGE=ghcr.io/steven-stack-s/dsh-docker:v<project-version>-dsh<dsh-version>` in `.env` (its seed matches that exact dsh version). The default `:latest` is rebuilt on every tag push and tracks the newest published version — it is not a fixed build.

## 📄 License

[MIT](LICENSE)
