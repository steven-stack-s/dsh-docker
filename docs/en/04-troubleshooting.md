# 04 · Troubleshooting

> [English](04-troubleshooting.md) | [简体中文](../zh-CN/04-故障排查.md)

| Symptom | Cause | Fix |
|---|---|---|
| Container restarts repeatedly, logs `listen EADDRINUSE 127.0.0.1:3080` | The old entrypoint makes socat and dsh fight over the same port | Make sure you use this repo's entrypoint (socat listens on 3080, dsh on 3081) and rebuild the container |
| Errors at startup like `plugin tree failed to load` / `node:zlib` | The base image's Node version is too old | Use this repo's Dockerfile (`node:24-slim`; DSH requires Node ≥ 22.18) |
| The page opens but `/api/...` returns 403 | Not authenticated (dsh-remote scenario) | Make sure you are logged in; the first admin must be created via loopback (see [02](02-authentication-remote-access.md)) |
| Settings page shows `settings are unavailable in this browser` | DSH design: settings are loopback-only | Not a blocker; change settings with curl from the host via `/api/settings.mutate` (see below) |
| `crypto.randomUUID is not a function` | Accessing from a non-HTTPS / non-localhost origin (browser secure context) | Use `localhost`, an SSH tunnel, or a reverse proxy with HTTPS (see [02](02-authentication-remote-access.md)) |
| Copying from the seed on first boot is slow | Windows + WSL bind mount crosses filesystems | Seconds on Linux; on Windows, use a docker named volume or wait for the first copy |
| `docker compose up` reports `DEEPSEEK_API_KEY` not set | `.env` is not configured | Run `cp .env.example .env` and fill in the key |
| Container won't start / repeated crashloop | Broken plugin fails to boot; auto-rollback didn't fire (no snapshot / RESCUE_AUTO=off / rescue tooling not installed) | Check the logs for `rolling back` / `lifeboat` markers; rebuild the image or use the [06 · Rescue Mode](06-rescue-mode.md) lifeboat to remove the bad plugin |

## Configure models with curl on the host

When the settings page is unavailable, you can read and mutate settings from the host with curl.

```bash
# 1. Log in and grab the cookie (only when dsh-remote is enabled; skip if not)
curl -s -c /tmp/dsh-cookies.txt -X POST http://127.0.0.1:3080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"你的用户名","password":"你的密码"}'

# 2. Inspect the current settings
curl -s -b /tmp/dsh-cookies.txt -X POST http://127.0.0.1:3080/api/settings.describe \
  -H 'Content-Type: application/json' \
  -d '{"type":"client-request","rpcId":"r1","method":"settings.describe","payload":{}}'

# 3. Mutate the llm-deepseek namespace (e.g. baseURL)
curl -s -b /tmp/dsh-cookies.txt -X POST http://127.0.0.1:3080/api/settings.mutate \
  -H 'Content-Type: application/json' \
  -d '{"type":"client-request","rpcId":"r2","method":"settings.mutate","payload":{"ns":"llm-deepseek","ops":[{"op":"set","path":["baseURL"],"value":"https://api.deepseek.com"}]}}'
```

## Collect diagnostics

When reporting a problem, please attach:

```bash
docker ps | grep dsh
docker logs dsh --tail 50
docker exec dsh dsh --version
```
