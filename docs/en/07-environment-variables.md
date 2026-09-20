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
| `TMPDIR` | `/data/dsh/tmp` | Temp-file root. **Defaults to the data volume** instead of the tmpfs `/tmp` (which is capped at 128m and fills up while dsh runs temporary tasks / verification tests). dsh's tool-output spill, command-output spool and workspace-change capture all use `os.tmpdir()` and follow this. Reclaim with `rescue clean`. |
| `RESCUE_TMP_KEEP_MIN` | `1440` | Retention window (minutes) for `rescue clean` when reclaiming dsh temp artifacts under `TMPDIR`. Anything newer is treated as possibly in use and never deleted. |

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

## 2.5 Security hardening (non-root run / capability / read-only)

Since v0.4.6 the image runs as a **non-root** user and tightens capabilities + read-only root FS:

- **Run user**: the in-image `node` user (uid 1000 gid 1000). The entrypoint first runs as root to seed
  `/opt/dsh` and `chown` the three mounted volumes to the run user, then uses `setpriv` to drop to
  uid 1000 before running dsh / socat / upgrades / rescue. Persistent in-container processes are **not root**.
- **`USER_UID` / `USER_GID`**: override the non-root run user (**usually unnecessary** — leaving them
  unset means `1000:1000`, defaulted by both compose (`${USER_UID:-1000}`) and the entrypoint, and the
  image's built-in `node` user is already `1000`, which matches most NAS/host first non-root users and
  the three mounted volumes). Only override when the volumes on the host are owned by a **different**
  uid and you want to run as that uid.
  ⚠ Prefer a uid that exists in the container's `/etc/passwd` (`1000` = the built-in `node` user):
  `setpriv --init-groups` needs to resolve a username. An unresolvable uid does **not** break startup —
  the entrypoint falls back to dropping privileges **without supplementary groups** (uid/gid still honored).
  (The old note "must equal the Dockerfile build args" was wrong: the image no longer declares those
  build args — they were dead parameters.)
- **Capability convergence** (`docker-compose.yml`): `cap_drop: [ALL]` + minimal allowlist
  `cap_add: [CHOWN, DAC_OVERRIDE, SETUID, SETGID]`. These four are only needed for first-boot
  `chown` of the volumes and `setpriv` uid drop; runtime dsh/agent processes (uid 1000) lack them.
- **Read-only root FS**: `read_only: true` + `tmpfs /tmp` (128m). Only volumes and /tmp are writable.
  **dsh's own temp files do not go to /tmp**: `TMPDIR` defaults to the data volume `/data/dsh/tmp`
  (see `TMPDIR` in §1) — /tmp is a hard 128m in-memory cap that fills quickly while dsh runs
  temporary tasks / verification tests, and after the move /tmp only holds a few system-level
  temp files.
  `NPM_CONFIG_CACHE` defaults to `/opt/dsh/.npm-cache` (inside a writable volume, created and `chown`ed
  to the run user on first boot; usable by both root `docker exec npm` and the node user) so
  `npm install -g` upgrades and rescue cleaning still work.
- **HMR disabled at launch** (via a `--patch` overlay): HMR relies on a native addon
  (`node-addon-require-builtin`) that may have no usable binding under a read-only root FS; dsh then
  throws `--expose-internals is required for HMR service` and crashes. Config changes inside the
  container are also meant to take effect through `docker restart`. The entrypoint therefore injects
  `--patch /opt/dsh-rescue/hmr-off.yml` (overlay: `scripts/hmr-off.yml`) into **every** launch
  command, turning off the base bundle's `hmr` row.
  **Mechanism changed 2026-09-18**: DSH 0.1.6-alpha.2 removed the profile manifest's `patchReload`
  field (from then on it is **silently ignored**) and now enables HMR from the `hmr` row whenever a
  launcher provides a profile context — so the earlier "rewrite `patchReload` to `startup` on first
  boot" approach **no longer works** on alpha.2 (HMR would in fact stay on). Moving the switch to a
  launch argument makes it independent of any version-specific manifest field, so in-container upgrades
  or rollbacks of dsh cannot break it. If you truly need live hot-reload in production, disable
  `read_only` and drop that overlay.
- **NAS / kernel caveat**: `cap_drop:[ALL]` may affect in-volume permissions and hard links
  (rescue snapshot `hardlink` uses `cp -al`) on some NAS storage backends (NFS / certain storage pools).
  Verified in this repo's e2e sandbox; before deploying to a target platform, run
  `scripts/t/e2e-container-selftest.sh` to confirm volume permissions and the rescue chain.
- These hardenings are not toggleable (default security posture); edit `docker-compose.yml` manually
  for looser behavior.

---

## 3. Build & image

| Variable | Default | Meaning |
|---|---|---|
| `DSH_IMAGE` | `ghcr.io/steven-stack-s/dsh-docker:latest` | Image pulled at `up`. To pin a version explicitly, use the `v<project>-dsh-<dsh>` tag scheme. |
| `DSH_VERSION` | (not in compose) | **For manual `docker build` only** (`--build-arg DSH_VERSION=<version>`): pins the dsh version baked into the seed. Compose **deliberately exposes no local build path** — when `image:` and `build:` share one tag, `docker compose up -d` silently falls back to building from the current directory instead of failing, so switching `DSH_IMAGE` to a tag that is not published yet would quietly run an image built from stale code (hit on a real deployment, 2026-09-17). See the comment above `services:` in `docker-compose.yml`. |
| `PNPM_VERSION` | (not in compose) | Same as above — manual `docker build` only; pins the pnpm version baked into the seed. |

---

## 4. Toolchain

| Variable | Default | Meaning |
|---|---|---|
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm/pnpm registry used inside the container (for initial install, dsh upgrades, pnpm install). Keep the default in CN; switch to `https://registry.npmjs.org` for deployments outside CN. |
| `NPM_CONFIG_CACHE` | `/opt/dsh/.npm-cache` | npm/pnpm download cache directory inside the container. Defaults to a writable dir inside a mounted volume (under a read-only root FS `/root/.npm` is unwritable and would break upgrades); override only to another writable path. The cleanup command (`rescue clean`) empties the `_cacache` inside it. |

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
