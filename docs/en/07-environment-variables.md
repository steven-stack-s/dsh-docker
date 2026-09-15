# 07 · Environment Variables

> **English** | [简体中文](../zh-CN/07-环境变量速查.md)

This is the **full reference for advanced env vars** that live in `docker-compose.yml`'s `${VAR:-default}` fallbacks
but are not listed in `.env.example`.

`.env.example` only lists the 12 vars used in daily deployment (see the file header). The remaining ~25 vars do not
need to be touched by most users. To customize, **pick one** of the two override methods:

- **Method A · edit the compose default** — change the `${VAR:-default}` expression directly in `docker-compose.yml`,
  e.g. turn `mem_limit: ${MEM_LIMIT:-2g}` into `mem_limit: ${MEM_LIMIT:-3g}`.
- **Method B · append the same var in `.env`** — `docker compose` treats vars present in `.env` as overrides for the
  `${VAR:-...}` defaults. Note that values in `.env` do **not** propagate into the container `environment:` block
  unless compose explicitly lists them; this method only works for vars that appear as `${VAR:-...}` somewhere
  in `docker-compose.yml`.

---

## 1. Self-heal / Lifeboat (RESCUE_*)

| Variable | Default | Meaning |
|---|---|---|
| `RESCUE_START_TIMEOUT` | `120` | Lifeboat's wait-for-dsh-ready probe timeout (seconds). **Must be < the compose healthcheck `start_period`** (default 300s) — otherwise the lifeboat will give up before docker does and roll back a still-cold-booting dsh. |
| `RESCUE_KEEP` | `3` | Number of most-recently-usable snapshots retained. The newest healthy baseline is pinned and never rotates. |
| `RESCUE_MAX_ATTEMPTS` | `4` | Boot retry cap. Defaults to `RESCUE_KEEP + 1`. |
| `RESCUE_EVIDENCE_KEEP` | `3` | Number of `evidence/boot-*` evidence dirs to retain. Defaults to `RESCUE_KEEP`. |
| `RESCUE_PROFILE` | `web` | Target profile for rollback (`web` = Web UI; `cli` etc. are also available). |
| `RESCUE_SELFHEAL` | `on` | Master self-heal switch. AND-ed with `RESCUE_AUTO`: if either is `off`, the system diagnoses but does not auto-change. |
| `RESCUE_REMOVE_LIMIT` | `2` | Per-container-lifetime cap on auto plugin removals. |
| `RESCUE_ROLLBACK_LIMIT` | `2` | Per-container-lifetime cap on snapshot rollbacks. |
| `RESCUE_DIAGNOSE_EVIDENCE` | `on` | Whether to tee each dsh boot output into `$DSH_HOME/.rescue/evidence/`. |
| `RESCUE_EVIDENCE_MAX` | `20971520` | Per-`dsh.log` rotation cap (bytes). |
| `RESCUE_INCIDENT_KEEP` | `20` | `$DSH_HOME/.rescue/incidents` retention count. |
| `RESCUE_SNAPSHOT_ON_HEALTHY` | `on` | Whether to auto-capture a "proven to boot" baseline snapshot. Occupies a slot in `RESCUE_KEEP`; the newest is pinned. |
| `RESCUE_SNAPSHOT_MODE` | `hardlink` | `hardlink` = `cp -al` (seconds, almost free, but shares inodes with live tree — **any in-place rewrite contaminates history**; run `rescue verify` to detect). `copy` = `cp -a` (truly immutable, at the cost of full `node_modules` duplication). |
| `RESCUE_SELFHEAL_WINDOW` | `86400` | Sliding window (seconds) for self-heal budgets. Within the window, auto actions count toward the cap; once the window expires, the counters reset. |
| `RESCUE_AUTO_LIFEBOAT` | `on` | Whether to auto-degrade into the lifeboat after self-heal has exhausted its budget. |

See [06 · Rescue Mode](06-rescue-mode.md). While debugging, set `RESCUE_AUTO=off` and `RESCUE_SELFHEAL=off` so the
system only diagnoses and writes incidents.

---

## 2. Resource limits / runtime

| Variable | Default | Meaning |
|---|---|---|
| `NODE_MAX_OLD_SPACE` | `1024` | Node heap cap (MB). DSH is multi-process; the actual RSS (main + children + client bundle) far exceeds the heap. **The heap must be much smaller than `MEM_LIMIT`** — a good rule: the RSS estimated as `NODE_MAX_OLD_SPACE * 1.5` should stay below half of `MEM_LIMIT`. Otherwise dsh gets OOM-killed by the container (symptom: silent dropped conversations, FATAL ERROR). |
| `PIDS_LIMIT` | `512` | Container process-count cap. socat in fork mode spawns one process per connection; without a cap, concurrent connections can exhaust the container. |
| `SOCAT_MAX_CHILDREN` | `64` | socat concurrent-connection cap. Unbounded external concurrency can exhaust container memory. |
| `MEM_LIMIT` | `2g` | Container memory cap. The N100 + 8GB example leaves headroom for the host OS. |
| `CPU_LIMIT` | `2` | Container CPU cap. |
| `TZ` | `Asia/Shanghai` | Container timezone. Affects all container logs and scheduled tasks. |

---

## 3. Build & image

| Variable | Default | Meaning |
|---|---|---|
| `DSH_IMAGE` | `ghcr.io/steven-stack-s/dsh-docker:latest` | Image pulled at `up`. To pin a version explicitly, use the `v<project>-dsh-<dsh>` tag scheme. For local-build scenarios, switch to your own tag (e.g. `dsh-base:final`). |
| `DSH_VERSION` | `0.1.6-alpha.1` | **Only used for local builds** (compose `build.args`); pins the dsh version baked into the seed. The pulled `:latest` and the local `DSH_VERSION` are two different sources — do not mix. |
| `PNPM_VERSION` | `latest` | **Only used for local builds**; pins the pnpm version baked into the seed. |

---

## 4. Toolchain

| Variable | Default | Meaning |
|---|---|---|
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm/pnpm registry used inside the container (for initial install, dsh upgrades, pnpm install). Keep the default in CN; switch to `https://registry.npmjs.org` for deployments outside CN. |

---

## 5. Credentials

| Variable | Default | Meaning |
|---|---|---|
| `DEEPSEEK_API_KEY_FILE` | (empty) | Mount the model key from a file (docker secret / bind mount) instead of an env var. **Takes priority over `DEEPSEEK_API_KEY`** so the key never appears in `docker inspect`. Example: `DEEPSEEK_API_KEY_FILE=/run/secrets/deepseek_api_key`. |

---

## 6. Debugging tips

- **Inspect the resolved env**: `docker compose config` prints the fully-rendered YAML, including the final value of every `${VAR:-...}`.
- **Diff `.env` vs defaults**: `docker compose config | grep -E '^\s*- [A-Z_]+=' | sort` lists every env that enters the container.
- **One-off override without polluting `.env`**: `VAR=value docker compose up -d`.
