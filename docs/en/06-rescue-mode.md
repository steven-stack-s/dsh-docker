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
| Layer 1 · entrypoint auto-diagnose + rollback | attribute the failure with deterministic rules, then roll back to the pre-change baseline or remove the offending plugin, and retry | on by default (needs **both** `RESCUE_AUTO=on` and `RESCUE_SELFHEAL=on`) |
| Layer 2 · lifeboat | when every automatic measure fails, boot a clean minimal profile as a usable entry point | **manual** `RESCUE=1` (there is no automatic fallback today — see the note below) |

> Note: **"automatic fallback into the lifeboat" is not implemented** (earlier revisions of this table said
> "automatic fallback", which did not match the code). When automatic measures and the budget are exhausted the
> entrypoint exits and `restart: unless-stopped` retries; to enter the lifeboat, set `RESCUE=1` in `.env` and run
> `docker compose up -d` (see §5).

## 2. Enabling

Rescue capability is **on by default** — no extra configuration needed:

1. The image must ship the rescue tooling (`/opt/dsh-rescue` and the `rescue` command), baked in by this repo's Dockerfile. If your container is older and `docker exec dsh rescue status` reports command not found, pull a newer image and recreate the container:
```bash
docker compose pull && docker compose up -d
```
> Building locally? Run `docker build --build-arg DSH_VERSION=<version> -t <your-tag> .` first, then point `DSH_IMAGE` at that tag. Compose **deliberately exposes no local build path** (see the comment above `services:` in `docker-compose.yml`: sharing one tag between `image:` and `build:` makes a failed pull silently fall back to stale local code).
2. No data-volume migration needed — snapshots live inside the DSH data volume (see §6).

Relevant environment variables (`.env`; inside the container, inspect with `docker exec dsh env | grep RESCUE`):

| Variable | Default | Meaning |
|---|---|---|
| RESCUE | 0 | 0=normal; 1=lifeboat boot (see §5) |
| RESCUE_AUTO | on | **master switch for automatic intervention**: on=attribute and roll back / remove plugins on failure; off=diagnose + write incident only, never touch the plugin tree |
| RESCUE_START_TIMEOUT | 120 | readiness-probe timeout in seconds |
| RESCUE_KEEP | 3 | how many recent **snapshots** to keep (the newest `boot-healthy` baseline is pinned and never rotated out — see Snapshot retention under §3) |
| RESCUE_MAX_ATTEMPTS | KEEP+1 | boot retry cap (decoupled from the snapshot count; defaults to `RESCUE_KEEP+1`) |
| RESCUE_EVIDENCE_KEEP | KEEP | how many `evidence/boot-*` directories to keep (defaults to `RESCUE_KEEP`) |
| RESCUE_PROFILE | web | target profile for rollback / plugin ops |
| RESCUE_SELFHEAL | on | on=auto remove-plugin / rollback on boot failure; off=diagnose + incident + report only |
| RESCUE_REMOVE_LIMIT | 2 | max auto plugin-removals within the window (over -> report-only) |
| RESCUE_ROLLBACK_LIMIT | 2 | max auto snapshot-rollbacks within the window |
| RESCUE_SELFHEAL_WINDOW | 86400 | sliding window (seconds) for the self-heal budget; it auto-resets when the window expires so the budget can never be exhausted forever |
| RESCUE_SNAPSHOT_ON_HEALTHY | on | take a baseline snapshot once a boot is confirmed healthy (rollback point for changes that bypass the rescue wrappers) |
| RESCUE_SNAPSHOT_MODE | hardlink | `hardlink`=`cp -al` (cheap, shares inodes with live, pollution detected by `rescue verify`); `copy`=`cp -a` immutable copy |
| RESCUE_AUTO_LIFEBOAT | on | boot the clean lifeboat profile after self-heal is exhausted (one-shot marker, applied on the next start) |
| SOCAT_MAX_CHILDREN | 64 | concurrent connection cap for the socat forwarder (fork-per-connection) |
| DEEPSEEK_API_KEY_FILE | (empty) | read the model key from a file (docker secret / mounted file) instead of the environment, so it never shows up in `docker inspect` |
| RESCUE_DIAGNOSE_EVIDENCE | on | tee each dsh boot output to `$DSH_HOME/.rescue/evidence/` for attribution |
| RESCUE_INCIDENT_KEEP | 20 | how many incidents to keep under `$DSH_HOME/.rescue/incidents/` |

**Snapshot retention.** Once the count exceeds `RESCUE_KEEP` the oldest snapshots are evicted, but **the newest `boot-healthy` baseline is pinned and never rotated out**:
self-heal's first pass only accepts a baseline as a rollback target (`rescue_pick_rollback_target` — the only state ever proven to boot),
while the plugin market (dshmarket) and manual changes keep producing snapshots. Plain FIFO would evict the baseline first, leaving self-heal with
nothing but the second pass (any non-scene snapshot). Pinning changes only **which** snapshot is evicted — the cap still holds (`RESCUE_KEEP=2` with
1 oldest baseline + 2 change snapshots evicts the second-oldest change snapshot and keeps the baseline; an all-baseline window keeps shrinking normally).

## 3. Command Cheat Sheet

Run on the host with `docker exec dsh rescue ...` (or directly `rescue ...` inside the container):

| Command | Behavior |
|---|---|
| `docker exec dsh rescue status` | List snapshots, current pointer, DSH version, last event log, and whether the last boot output was captured (read-only). **Inside the lifeboat it also prints a `LIFEBOAT MODE` action block** |
| `docker exec dsh rescue snapshot` | Manually snapshot the current plugin tree (as a rollback target) |
| `docker exec dsh rescue doctor` | Read-only diagnostics: profile dir + package.json, snapshot list, evidence/state/incident dir health, last run state, **tail of the last boot output** (plus the `LIFEBOAT MODE` block inside the lifeboat) |
| `docker exec dsh rescue plugin add <pkg>` | Auto-snapshot first, then run `dsh plugin --profile web add <pkg>` (leave a rollback point before installing) |
| `docker exec dsh rescue plugin remove <pkg>` | Same, to uninstall a plugin |
| `docker exec dsh rescue snapshots` | Snapshot inventory: name / created / mode / **whether it differs from the live tree** / reason |
| `docker exec dsh rescue verify [snap]` | Integrity check: the node_modules tree hash recorded in meta vs recomputed (detects snapshots silently rewritten in place); no argument = check all |
| `docker exec dsh rescue rollback` | Manual rollback; **skips snapshots identical to the live tree** (the "broken scene" snapshots self-heal takes), then `docker restart dsh` |
| `docker exec dsh rescue rollback --to <snap>` | Explicit target; refuses a target identical to live instead of pretending to restore |
| `docker exec dsh rescue rollback --dry-run` | Print which snapshot would be restored; changes nothing |
| `docker exec dsh rescue selfheal status` | Show the self-heal gate and remaining budget (how many removes/rollbacks used, when the window resets) |
| `docker exec dsh rescue selfheal reset` | Clear the self-heal budget and restore self-heal capability immediately |
| `docker exec dsh rescue export [path]` | Pack everything needed for troubleshooting (incidents / state / snapshot meta / environment summary / doctor / tail of the last boot log) into one tar.gz; never includes the plugin tree, sessions, memory or any secret |
| `docker exec dsh rescue lifeboat on\|off\|status` | Request / clear / inspect the "boot the lifeboat on next start" marker (set automatically when self-heal is exhausted) |
| `docker exec dsh rescue dsh-upgrade <version>` | Record the current DSH version as last-good, then upgrade the program to the given version |
| `docker exec dsh rescue dsh-reinstall` | Reinstall the program at the recorded last-good version (lightweight fallback for program incidents) |
| `docker exec dsh rescue lifeboat` | Print instructions to switch to lifeboat (equivalent to RESCUE=1) |
| `docker exec dsh rescue report` | Incident overview table: phase / root-cause category / offending plugin / self-heal outcome (see §4b) |
| `docker exec dsh rescue report <id>` | Expand one incident: rationale / self-heal actions / evidenceRef / redline assertion |
| `docker exec dsh rescue report --json` | Emit incidents as valid JSON (for scripting) |
| `docker exec dsh rescue incident list` | List recorded incident ids |
| `docker exec dsh rescue snapshot --reason '<text>'` | Manual snapshot with trigger context (e.g. `--reason 'plugin add @scope/x'`) for later attribution |
| `docker exec dsh rescue clean [--yes]` | Clean up leftovers after upgrades (dry-run preview by default; `--yes` applies and snapshots first). Includes reclaiming dsh temp artifacts under `TMPDIR` (see §4c) |

> After installing/removing/rolling back plugins, run `docker restart dsh` so the entrypoint boots with the new plugin tree; if boot fails, the entrypoint auto-rolls back (see §4).

> Note: `dsh-upgrade` / `dsh-reinstall` are subcommands of `rescue`. The full forms are `docker exec dsh rescue dsh-upgrade <version>` and `docker exec dsh rescue dsh-reinstall`.

## 4. Auto-rollback (entrypoint)

On restart the entrypoint starts dsh web as a **child process** and runs a **layered readiness probe** (`probe-ready.js`) against 127.0.0.1:3081 inside the container, waiting up to `RESCUE_START_TIMEOUT` (default 120s). “Failed to start” = any layer unsatisfied within the window: L1 TCP not listening, L2 connected but no HTTP response at all, or L3 not satisfied on `--stable` (default 2) consecutive checks. Since v0.3.7 the probe also receives `--pid`, so it fails immediately once the dsh main process is gone instead of waiting out the window.

Rollback flow:

1. Boot failed → `diagnose.js` attributes it with deterministic rules (§4b) and recommends `remove-plugin` / `rollback` / `report-only`;
2. **Before any self-heal action** the master switch is checked: `RESCUE_AUTO` and `RESCUE_SELFHEAL` must **both** be `on`, otherwise it only writes an incident (report-only);
3. `rollback` restores the plugin tree (package.json / pnpm-lock.yaml / pnpm-workspace.yaml / node_modules) to the target snapshot and **retries** (up to `RESCUE_KEEP+1` times);
4. Without diagnose capability / evidence it falls back to the legacy path: with `RESCUE_AUTO=on`, a snapshot present and its fingerprint differing from live (fingerprint = hash of package.json + pnpm-lock.yaml), roll back to the newest snapshot;
5. Every automatic measure failed / budget exhausted → exit and let `restart: unless-stopped` retry; a human must enter the lifeboat with `RESCUE=1` (§5).

After a healthy boot the entrypoint keeps waiting on dsh; if dsh later crashes the container exits and Docker's restart policy takes over. To see whether a rollback happened:

```bash
docker logs dsh --tail 100 | grep -iE 'rollback|healthy|rescue'
```

**Audit log.** Beyond the container log, every rescue event is also appended to a file inside the data volume — **`$DSH_HOME/.rescue/log/rescue.log`** (host default `./dsh/.rescue/log/rescue.log`), so you can audit rescue history even if the container log is gone. Entries include manual `snapshot` / `restore apply|done` / `prune`, plus the auto events now recorded by the entrypoint:

```bash
tail -20 /data/dsh/.rescue/log/rescue.log      # inside the container
# e.g. 2026-09-07T17:12:00+0800 snapshot created snap-0001 (reason: plugin add @scope/x)
#      2026-09-07T17:12:05+0800 selfheal rollback to snap-0001      # this line is in docker logs (elog)
#      2026-09-07T17:12:05+0800 restore apply snap-0001 -> /data/dsh/profiles/web
#      2026-09-07T17:12:08+0800 restore done snap-0001
#      2026-09-07T17:12:08+0800 selfheal rollback ok: snap-0001
#      2026-09-07T17:12:30+0800 baseline snapshot on healthy: snap-0002
#      2026-09-07T17:13:00+0800 boot exhausted; exit for docker restart policy
```

`rescue status` shows the same file's tail as its “last event log”.

## 4b. Auto-diagnose · Root-cause attribution · Smart self-heal (rescue-diagnose)

On top of auto-rollback, the entrypoint provides an **evidence-driven diagnosis + self-heal loop**: each boot's dsh output is teed into an evidence dir, a **deterministic** (non-LLM) rule engine attributes the root cause, the decision matrix acts accordingly, and every incident is written as an auditable record surfaced by `rescue report`. **Hard rule:** self-heal only touches the four plugin-tree files (package.json / pnpm-lock.yaml / pnpm-workspace.yaml / node_modules) and `$DSH_HOME/.rescue` state/incidents — it **never** auto-modifies `cordis.patch.yml`, sessions / memory / config / credentials.

**Trigger paths**

1. **Boot failure** (probe timeout / early child exit): capture this round's evidence → run diagnose attribution (evidence + audit + snapshot meta trigger/reason) → act on `recommendedHeal`: `remove-plugin` (snapshot the scene first, then remove via `dsh plugin remove`, tree-only) / `rollback` (restore the pre-change baseline snapshot) / `report-only` (no auto change; write incident) → write incident, then retry or exit.
2. **Runtime crash**: after a healthy boot dsh exits abnormally → write last-run (abnormalExit) and exit (docker restart hand-off, no infinite respawn in PID1); on the next start the abnormal exit is noted and a runtime incident recorded for `rescue report`. **Conservative default: runtime crashes are reported/attributed only, never auto-removed/rolled back** (avoids collateral damage); dispose manually per the report.

**Self-heal guardrails** (anti-infinite / anti-collateral):

- Budget in `state/selfheal.json`: **within the window**, auto plugin-removals ≤ `RESCUE_REMOVE_LIMIT` and snapshot-rollbacks ≤ `RESCUE_ROLLBACK_LIMIT`; over the limit → report-only. The window (`RESCUE_SELFHEAL_WINDOW`, default 24h) expires automatically and resets the counters, so the budget can never be exhausted forever. Use `rescue selfheal status` to inspect and `rescue selfheal reset` to clear it.
- Rollback targets must be meaningful: snapshots whose fingerprint equals the live tree (typically the "broken scene" taken just before) are skipped — otherwise a rollback changes nothing yet is recorded as `rollback ok` and burns budget.
- Conservative attribution (report rather than wrong-remove): `remove-plugin` only when evidence matches a plugin failure and the offender is the most-recent add; otherwise prefer rollback or report-only.
- A scene snapshot is taken before every self-heal action; all actions go to `rescue.log` and update the matching incident.
- With `RESCUE_SELFHEAL=off`, only diagnose + write incident + hint — never auto-change.

**Where evidence & incidents live** (inside the data volume `$DSH_HOME/.rescue/`):

- `last-web-boot.log`: output of the **last** web boot (overwrite semantics) — the file that makes the root cause visible inside the lifeboat (see §5b).
- `evidence/boot-<seq>-<ts>/`: each boot's dsh output (dsh.log) + temp fifo.
- `incidents/inc-<ts>-<rand>.json`: attribution + self-heal actions + redline assertion for one incident; keep `RESCUE_INCIDENT_KEEP` (default 20).
- `state/last-run.json`, `state/selfheal.json`: last run state / self-heal budget.

Review one incident: `docker exec dsh rescue report <id>`; the output includes `rootCause.rationale` (why it judged so) and `redline.cordisPatchTouched=false` (asserts cordis.patch.yml was not touched this round).

> Calibration note: the log patterns used for attribution are the top-of-file data constants `PLUGIN_FAIL_PATTERNS` in `/opt/dsh-rescue/diagnose.js`. The order is "**first** match the plugin-failure patterns, **then** extract the offending package name" — so an unrelated log line that merely mentions a package name is not mistaken for a plugin failure.

## 4c. Temp-file reclamation (rescue clean)

**Background**: `read_only: true` forces `/tmp` onto tmpfs, which is a **hard in-memory cap** (128m in this repo). While running **temporary tasks / verification tests**, dsh writes three kinds of artifacts into `os.tmpdir()`:

- tool-output spill (results of reading large files or broad searches)
- managed-command output spool (build/test output is easily tens to hundreds of MB)
- workspace-change capture

A single large output can fill 128m. Worse, dsh's own reclamation is unreliable: spill files are swept only **at startup** and only when older than 30 days by default; the command spool only `rmdir`s at process exit (which cannot remove a non-empty directory — upstream notes it waits for an "external cleanup"). Artifacts therefore only accumulate.

**Fix**: `TMPDIR` defaults to the data volume `/data/dsh/tmp` (see《[07 · Environment Variables](07-environment-variables.md)》), turning the ceiling from "128m of memory" into host disk space; reclamation is handled by:

```bash
docker exec dsh rescue doctor          # read-only: shows the current TMPDIR and dsh temp-dir count
docker exec dsh rescue clean           # dry-run: lists stale dirs that would be reclaimed (changes nothing)
docker exec dsh rescue clean --yes     # apply
```

**Safety boundary** (only these are deleted; everything else is left alone):

- Only first-level dirs **from dsh's own name list** whose name matches the `mkdtemp` shape (prefix + exactly 6 alphanumerics): `dsh-spill-*` / `dsh-subprocess-*` / `dsh-subprocess-launch-*` / `dsh-workspace-changes-*` / `dsh-shell-*`.
- `dsh-office-to-pdf-*`, `dsh-open-in-app-*`, `libreoffice-kit-*` and anything else you keep in `TMPDIR` are **never** touched — better to under-delete than to delete the wrong thing.
- Only **stale** entries: dirs written within `RESCUE_TMP_KEEP_MIN` (default 1440 minutes = 24h) are treated as possibly in use and kept.

> Before migrating: once `TMPDIR` moves away from `/tmp`, any `dsh-*` directories **already left behind** in `/tmp` will never be scanned again (dsh's cleanup base follows `TMPDIR` too). Clean them once by hand before switching:
> ```bash
> docker exec dsh sh -c 'rm -rf /tmp/dsh-spill-* /tmp/dsh-subprocess-* /tmp/dsh-workspace-changes-* /tmp/dsh-shell-*'
> ```

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

### 5b. AI-assisted repair flow (getting work done inside the lifeboat)

The lifeboat exists so that a human **or an AI agent** can repair things from the UI and then return to the normal profile. Agents tend to spin here: they **cannot return to the normal profile on their own**, because `RESCUE=1` is a **container environment variable** (unchangeable from inside), `.env` lives on the host and is not mounted, and there is no docker socket in the container (by design — do not weaken it). If the agent kills PID1, `restart: unless-stopped` brings the container back, it reads `RESCUE=1` again and lands in the lifeboat once more — a pointless loop.

The correct flow:

```text
① confirm you are in the lifeboat   rescue status          # prints the LIFEBOAT MODE block
② see why the last boot died        rescue doctor          # echoes the tail of last-web-boot.log
③ repair profiles/web (drop a bad plugin, fix package.json, …)
④ tell the user to run on the host  docker restart dsh
```

Key points:

- **Inside the lifeboat, `rescue status` / `rescue doctor` print a `LIFEBOAT MODE` action block** that hands you the exact command from step ④. On seeing it, an agent should stop trying to restart anything and inform the user instead.
- **Never `kill` PID1 and never try to restart the container from inside**: a restart just lands you back in the lifeboat.
- The only way back to the normal profile is on the host:
  ```bash
  docker restart dsh                       # when .env has RESCUE=0
  sed -i 's/^RESCUE=.*/RESCUE=0/' .env && docker compose up -d   # when .env has RESCUE=1
  ```

**Crash evidence on disk (`last-web-boot.log`).** Once the lifeboat is up the original dsh process is gone, and the container has neither a docker socket nor access to `docker logs` — so the real root cause (e.g. a `Cannot find module 'xxx'` stack) used to be invisible. The entrypoint supervisor loop therefore writes **every** web boot's output, overwriting, to:

```text
$DSH_HOME/.rescue/last-web-boot.log      # host default ./dsh/.rescue/last-web-boot.log
```

- Overwrite semantics (one file per boot attempt, not appended), so it never grows without bound and always holds the **last** attempt.
- On every failed boot the container log (`docker logs dsh`) additionally echoes a `last boot output (tail):` block (last 80 lines by default), so you can locate the cause without opening the file.
- The lifeboat itself never writes this file (`boot_lifeboat` `exec`s directly and uses the container's stdout), so the file always holds the **last failed web boot**.
- Note: the file is primarily dsh **stderr** (crash stacks and module-resolution failures go to stderr); stdout still goes in full to the evidence chain `evidence/boot-*/dsh.log` and to `docker logs`.

**Automatic fallback**: when the self-heal actions and their budget are both exhausted and boot still fails, the entrypoint writes a **one-shot** marker and exits; the next start boots the lifeboat profile (the marker is cleared on entry), so you at least get a UI instead of an endless crashloop. Once the plugin is fixed, a plain `docker restart dsh` returns you to the normal profile. Set `RESCUE_AUTO_LIFEBOAT=off` to disable the automatic fallback.

## 6. Disabling / Backup Tips

**Disable automatic intervention**: set `RESCUE_AUTO=off` (or `RESCUE_SELFHEAL=off`) in `.env` then `docker compose up -d`. With **either** of them off, a boot failure only diagnoses and writes an incident — it **never modifies the plugin tree** — then exits and `restart: unless-stopped` retries. Temporarily turning it off is recommended while troubleshooting plugins.

**Disable rescue mode entirely**: the wrapped commands are manual tools and can't be turned off; setting `RESCUE_AUTO=off` + `RESCUE=0` gives you the plain “no auto-intervention” deployment.

**Backup tip**: rescue snapshots live at `$DSH_HOME/.rescue` inside the DSH data volume (host default `./dsh/.rescue`) and are backed up together with `dsh/` — just back up the whole deployment directory as in §5 of《[03 · Upgrade & Maintenance](03-upgrade-maintenance.md)》. Snapshots and rollback only touch the four plugin files and never sessions / memory / config / credentials.

## 7. Troubleshooting Entry Points

- Container won't start / repeated crashloop → first check `docker logs dsh --tail 100` for `selfheal rollback to` / `no-evidence fallback: rollback to` / `booting clean lifeboat profile` markers, then inspect attribution with `docker exec dsh rescue report` and follow《[04 · Troubleshooting](04-troubleshooting.md)》.
- To end-to-end accept the rescue chain on a real Docker host → run the in-repo script `scripts/t/e2e-rescue-on-host.sh` (it briefly restarts the dsh container; see the header comments).
