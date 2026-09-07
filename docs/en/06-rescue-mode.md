# 06 · Rescue Mode

> [English](06-rescue-mode.md) | [简体中文](../zh-CN/06-救援模式.md)

DSH Docker's **plugin rescue mode**: when a plugin update/install breaks startup, it automatically rolls back to the last plugin tree that booted, so the service recovers by itself; in the worst case a clean **lifeboat** profile gives you a usable entry point. All user data (sessions / config / credentials / memory bank) is preserved throughout.

> The detailed design lives in the internal spec《[06 · 救援模式设计规范](../zh-CN/06-救援模式-设计规范.md)》(Chinese).

## 1. Design Goals

This repo persists DSH in two parts:

- **Program** /opt/dsh (npm global packages, upgraded via `npm install -g`)
- **Plugin tree** $DSH_HOME/profiles/web (cordis.patch.yml + package.json + pnpm-lock.yaml + node_modules, managed by `dsh plugin`)

**Plugin updates/installs are the most frequent source of startup failures.** Once boot fails, `restart: unless-stopped` causes an endless crashloop, and while the container is down you cannot run manual commands at all. Rescue mode adds three lines of defense:

| Layer | Purpose | Trigger |
|---|---|---|
| Layer 0 · wrapped commands | `rescue plugin` auto-snapshots the current plugin tree; `rescue dsh-upgrade` records the last-good main-program version | run the wrapped command manually |
| Layer 1 · entrypoint auto-rollback | auto-rollback to the last known-good snapshot and retry after a failed boot | on by default (RESCUE_AUTO=on) |
| Layer 2 · lifeboat | when rollback budget is exhausted, boot a clean minimal profile as a usable entry point | RESCUE=1 manually / automatic fallback |

## 2. Enabling

Rescue capability is **on by default** — no extra configuration needed:

1. The image must ship the rescue tooling (`/opt/dsh-rescue` and the `rescue` command), baked in by this repo's Dockerfile. If your container is older and `docker exec dsh rescue status` reports command not found, rebuild the container:
```bash
docker compose up -d --build
```
2. No data-volume migration needed — snapshots live inside the DSH data volume (see §6).

Relevant environment variables (`.env`; inside the container, inspect with `docker exec dsh env | grep RESCUE`):

| Variable | Default | Meaning |
|---|---|---|
| RESCUE | 0 | 0=normal; 1=lifeboat boot (see §5) |
| RESCUE_AUTO | on | on=auto-rollback on boot failure; off=disable |
| RESCUE_START_TIMEOUT | 120 | readiness-probe timeout in seconds |
| RESCUE_KEEP | 3 | how many recent snapshots to keep |
| RESCUE_PROFILE | web | target profile for rollback / plugin ops |

## 3. Command Cheat Sheet

Run on the host with `docker exec dsh rescue ...` (or directly `rescue ...` inside the container):

| Command | Behavior |
|---|---|
| `docker exec dsh rescue status` | List snapshots, current pointer, DSH version, last event log (read-only) |
| `docker exec dsh rescue snapshot` | Manually snapshot the current plugin tree (as a rollback target) |
| `docker exec dsh rescue doctor` | Read-only diagnostics: profile dir + package.json, snapshot list |
| `docker exec dsh rescue plugin add <pkg>` | Auto-snapshot first, then run `dsh plugin --profile web add <pkg>` (leave a rollback point before installing) |
| `docker exec dsh rescue plugin remove <pkg>` | Same, to uninstall a plugin |
| `docker exec dsh rescue rollback` | Manually roll back to the newest snapshot (prints a hint; then `docker restart dsh`) |
| `docker exec dsh rescue dsh-upgrade <version>` | Record the current DSH version as last-good, then upgrade the program to the given version |
| `docker exec dsh rescue dsh-reinstall` | Reinstall the program at the recorded last-good version (lightweight fallback for program incidents) |
| `docker exec dsh rescue lifeboat` | Print instructions to switch to lifeboat (equivalent to RESCUE=1) |

> After installing/removing/rolling back plugins, run `docker restart dsh` so the entrypoint boots with the new plugin tree; if boot fails, the entrypoint auto-rolls back (see §4).

> Note: `dsh-upgrade` / `dsh-reinstall` are subcommands of `rescue`. The full forms are `docker exec dsh rescue dsh-upgrade <version>` and `docker exec dsh rescue dsh-reinstall`.

## 4. Auto-rollback (entrypoint)

On restart the entrypoint starts dsh web as a **child process** and probes 127.0.0.1:3081 inside the container, waiting up to `RESCUE_START_TIMEOUT` (default 120s). “Failed to start” = 3081 not listening within the window, or the dsh main process exited.

Rollback flow:

1. Boot failed → if `RESCUE_AUTO=on` **and** a snapshot exists **and** attempts remain:
2. Take the newest snapshot and check its fingerprint differs from the live plugin tree (fingerprint = hash of package.json + pnpm-lock.yaml);
3. If different, roll the plugin tree (package.json / pnpm-lock.yaml / pnpm-workspace.yaml / node_modules) back to that snapshot and **retry** (up to `RESCUE_KEEP+1` times);
4. No rollback available / budget exhausted and still failing → go to **lifeboat** (§5), or exit and let `restart: unless-stopped` take over.

After a healthy boot the entrypoint keeps waiting on dsh; if dsh later crashes the container exits and Docker's restart policy takes over. To see whether a rollback happened:

```bash
docker logs dsh --tail 100 | grep -iE 'rollback|healthy|rescue'
```

**Audit log.** Beyond the container log, every rescue event is also appended to a file inside the data volume — **`$DSH_HOME/.rescue/log/rescue.log`** (host default `./dsh/.rescue/log/rescue.log`), so you can audit rescue history even if the container log is gone. Entries include manual `snapshot` / `restore apply|done` / `prune`, plus the auto events now recorded by the entrypoint:

```bash
tail -20 /data/dsh/.rescue/log/rescue.log      # inside the container
# e.g. 2026-09-07T15:35:24+0800 restore done snap-0002
#      2026-09-07T17:12:00+0800 auto-rollback start -> snap-0001
#      2026-09-07T17:12:03+0800 auto-rollback done -> snap-0001
#      2026-09-07T17:12:10+0800 lifeboat enter: rollback FAILED
#      2026-09-07T17:13:00+0800 boot exhausted, no rollback available; exit for docker restart policy
```

`rescue status` shows the same file's tail as its “last event log”.

## 5. Lifeboat

When the plugin tree is broken beyond what auto-rollback can fix, a **clean minimal profile** boots a web with no third-party plugins (only the DSH core), still bound to the same `$DSH_HOME` — your data stays readable, bad plugins are simply not loaded, and you can remove the bad plugin / edit cordis.patch.yml / reinstall the program.

Enter lifeboat:

```bash
# edit .env: set RESCUE to 1, then recreate the container
RESCUE=1
docker compose up -d
```

The lifeboat web is still reachable through external port 3080 (socat forwards 3080 → 3081 inside). You can now run maintenance commands with `docker exec dsh` (remove bad plugins, edit config).

Exit lifeboat back to normal:

```bash
# edit .env: set RESCUE back to 0, then recreate the container
RESCUE=0
docker compose up -d
```

> Lifeboat hard rule: never modify the existing `profiles/web/` or any user-data file; sessions/memory produced by lifeboat itself live under `profiles/lifeboat` and can be cleaned up later.

## 6. Disabling / Backup Tips

**Disable auto-rollback**: set `RESCUE_AUTO=off` in `.env` then `docker compose up -d`. After that, a boot failure won't roll back; it exits and `restart: unless-stopped` retries repeatedly — we recommend leaving it on.

**Disable rescue mode entirely**: the wrapped commands are manual tools and can't be turned off; setting `RESCUE_AUTO=off` + `RESCUE=0` gives you the plain “no auto-intervention” deployment.

**Backup tip**: rescue snapshots live at `$DSH_HOME/.rescue` inside the DSH data volume (host default `./dsh/.rescue`) and are backed up together with `dsh/` — just back up the whole deployment directory as in §5 of《[03 · Upgrade & Maintenance](03-upgrade-maintenance.md)》. Snapshots and rollback only touch the four plugin files and never sessions / memory / config / credentials.

## 7. Troubleshooting Entry Points

- Container won't start / repeated crashloop → first check `docker logs dsh --tail 100` for `rolling back` / `lifeboat` markers, then follow《[04 · Troubleshooting](04-troubleshooting.md)》.
- To end-to-end accept the rescue chain on a real Docker host → run the in-repo script `scripts/t/e2e-rescue-on-host.sh` (it briefly restarts the dsh container; see the header comments).
