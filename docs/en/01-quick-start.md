# 01 · Quick Start

> [English](01-quick-start.md) | [简体中文](../zh-CN/01-快速开始.md)

Deploy DeepSeek Harness (DSH) on any Docker environment.

## 1. Prerequisites

- Docker Engine ≥ 20.10 (with `docker compose` v2 support)
- Ability to pull `node:24-slim` (on mainland China networks, consider configuring a registry mirror accelerator; see [05](05-platform-differences.md))
- A DeepSeek API Key (or another compatible model API)

## 2. Directory Structure

```
dsh-docker/
├── docker-compose.yml   # deployment config
├── Dockerfile           # base image — build it yourself or use the ghcr.io image directly
├── scripts/             # runtime code (entrypoint / rescue CLI / shared library / probes)
└── .env.example         # environment variable template
```

## 3. Installation Steps

### 3.1 Clone the Repo and Configure

```bash
git clone https://github.com/steven-stack-s/dsh-docker.git
cd dsh-docker

cp .env.example .env
# edit .env; at minimum fill in:
#   DEEPSEEK_API_KEY=sk-你的密钥
# the rest have defaults; adjust as needed (port, data directory, resource limits, etc.)
```

> `.env` is ignored by `.gitignore`, so your keys never enter git.

### 3.2 Start

```bash
docker compose up -d
```

On first boot, `scripts/entrypoint.sh` copies dsh+pnpm from the in-image seed (`/opt/dsh-seed`) to the mounted volume `/opt/dsh` — done in seconds, offline, version-pinned (the compose health check uses `start_period: 300s` to cover the first-boot seed copy plus cold start).

### 3.3 View Startup Logs

```bash
docker logs dsh --tail 15
```

Expected output:

```
[entrypoint] first boot: seeding @deepseek-ai/dsh into mounted volume /opt/dsh ...
[entrypoint]   copying in-image seed (/opt/dsh-seed) to /opt/dsh
[entrypoint] dsh ready: /opt/dsh/bin/dsh
[entrypoint] starting socat forward: 0.0.0.0:3080 -> 127.0.0.1:3081 (max-children=64)
[entrypoint] starting dsh web (internal 127.0.0.1:3081)
dsh web: http://127.0.0.1:3081/?token=xxxxxxxx   # ← the launch token, printed on the "dsh web:" line
```

- "opening the default browser" should not appear (`--no-open` is set)
- The `Connection refused` from socat right at startup is normal (dsh is not ready yet) and disappears once dsh is up
- Copy the `?token=...` value from the `dsh web:` line — you need it for the first visit (see §4)

## 4. Access with the Launch Token

DSH core does **not** require an admin account to use. On first boot it issues a **launch token** — printed in the container log (see §3.3) — that unlocks the first visit. The token changes on every restart.

- **First visit**: open `http://<host-ip>:3080/?token=<token-from-log>`
- **Later visits** (same running instance): the token is no longer needed — open `http://<host-ip>:3080` directly

> If you access from a LAN IP or a domain that is not on dsh's automatic allow-list, add it to `DSH_TRUSTED_HOSTS` in `.env` before starting — otherwise the page opens but every `/api` call returns 403 (see the `.env` comment; dsh 0.1.2 only trusts loopback or allow-listed Hosts).
>
> Want username/password + MFA for **remote** access? That is the optional [dsh-remote](https://github.com/xgone/dsh-remote) plugin — see [02](02-authentication-remote-access.md). dsh itself needs no account.

## 5. Verification

- Open `http://<主机IP>:3080` in a browser — first time use `http://<主机IP>:3080/?token=<from-log>`, then open a normal session; you can now chat with the model
- Go to Settings → Models and confirm the API Key is in effect
- In `docker ps`, the `dsh` container status is healthy (first boot copies from the seed, ready in seconds, so the starting phase is very brief)

## 6. Stop / Uninstall

```bash
docker compose down          # stop and remove the container (data stays in ./dsh ./programs ./workspace)
docker compose down -v       # ⚠️ also delete anonymous volumes (no named volumes are used; data lives in the mounted dirs and is unaffected)
rm -rf dsh programs workspace # permanently delete all data
```
