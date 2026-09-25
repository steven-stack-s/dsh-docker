# 03 · Upgrade & Maintenance

> [English](03-upgrade-maintenance.md) | [简体中文](../zh-CN/03-升级与维护.md)

## 1. Upgrade

An upgrade involves **two layers**, but normally **one step is enough** — because an image upgrade
syncs dsh itself automatically:

| Layer | Contents | How to update |
|---|---|---|
| **Image layer** | `entrypoint`, rescue scripts, `/opt/dsh-seed` (the dsh pinned at build time) | `docker compose pull && docker compose up -d` |
| **dsh itself** | the dsh actually running from the mounted volume `/opt/dsh` | the step above **does it for you** (see below); or `npm install -g` on its own |

### The image upgrade syncs dsh itself by version

On startup the entrypoint (`scripts/entrypoint.sh`, step ①) compares the **image seed's version** with
the **version of the dsh in the volume**:

| Situation | Action |
|---|---|
| No dsh in the volume | Copy the seed (first boot) |
| **Seed version > volume version** | **Copy the seed** — dsh follows the image upgrade automatically |
| Versions equal | Do nothing (no redundant copy) |
| Volume version is newer (you installed a higher one in-container) | **Do nothing** — your choice is respected |

The startup log prints all three versions, so one line answers "did it actually upgrade?":

```
[entrypoint] dsh version: seed=0.1.7-rc.2 volume(before)=0.1.7-alpha.2 effective=0.1.7-rc.2
```

So an upgrade normally needs only:

```bash
docker compose pull && docker compose up -d
docker exec dsh dsh --version                       # expect: the image seed's version
docker inspect -f '{{.State.Health.Status}}' dsh    # expect: healthy
docker logs dsh 2>&1 | grep 'dsh version'           # all three versions at a glance
docker logs dsh 2>&1 | grep -i 'expose-internals'   # expect: no output
```

### Upgrading / downgrading dsh alone

When the image seed has not changed, or you want a version **different from the image**, use npm inside
the container:

```bash
docker exec dsh npm install -g @deepseek-ai/dsh@<version>
docker restart dsh
```

> ⚠️ **Upgrades stick, downgrades get reverted**: install a version **higher** than the seed and the next
> startup sees `seed < volume` → it does nothing, so your version stays; install one **lower** than the
> seed and the next startup overwrites it with the seed. That is deliberate — the image's pinned version
> wins. To stay on a lower version, point `DSH_IMAGE` at an image tag that pins it.
>
> 💡 By the same rule, `docker exec dsh rescue dsh-upgrade <version>` gets overwritten on the next startup
> if the version it installs is lower than the image seed. For a lasting pin, always go through the image tag.
>
> ⚠️ If you do change dsh by hand, **upgrade the image first, then dsh**: the reverse order leaves the
> intermediate state "new dsh + old entrypoint", and the entrypoint carries the read-only hardening
> (disabling the profile's HMR; see the hardening section of [07 · Environment variables](07-environment-variables.md)).

### Always spell out the full version (do not use `latest` / `next`)

npm dist-tags are **manually assigned** aliases maintained by the publisher — they do **not** advance
automatically, and the three tags can point at three different versions:

| tag | Points at (checked 2026-09-25) | Meaning |
|---|---|---|
| `latest` | `0.1.5-rc.3` | Stable recommendation — **lags behind `rc`** |
| `next` | `0.1.7-rc.2` | Candidate (**the version this image currently pins**) |
| `alpha` | `0.1.7-alpha.2` | Preview |

> ⚠️ So `npm install -g @deepseek-ai/dsh@latest` does **not** get you the newest version, and never gets
> the newest version (it is `0.1.5-rc.3`; the newest `0.1.7-rc.2` sits under `next`). Always pass the
> full version: `@0.1.7-rc.2`. Verify with `docker exec dsh dsh --version`.
>
> 📌 The table above is a **snapshot in time**: dist-tags are assigned by hand and can change at any
> moment — for "where do they point right now", trust the live output of the command in the tip below.

> 💡 Check where the tags currently point: `docker exec dsh npm view @deepseek-ai/dsh dist-tags`.

> ⚠ **Back up first** (see §5): a cross-major upgrade can include an **irreversible** data-format change —
> for example `0.1.2-rc.1 → 0.1.5-rc.1` migrates sessions to V3, after which the **old version can no
> longer read** them (the files remain, but the new format is not understood by the old version). So when
> rolling the dsh version back, roll the `dsh/` data directory back with it.
>
> ⚠️ **Since 0.1.7-alpha.1 the session log is V4, and the move is one-way**: a V3 session is converted to V4
> on **read**, and as soon as it is opened and written to, `session-persistence-jsonl` publishes the
> **current-format successor** (`session.v4.jsonl.zstd`; the original `session.v3...` stays untouched).
> In other words, any session written after the upgrade **cannot be read by 0.1.6 again** — a rollback must
> move the version and the data together:
>
> ```bash
> # before upgrading (inside the container)
> docker exec dsh sh -c "tar czf /data/dsh/backup-sessions-$(date +%F-%H%M).tgz -C /data/dsh sessions storages"
> # rollback (inside the container): downgrade, restore the same backup, then restart
> docker exec dsh rescue dsh-reinstall
> docker exec dsh sh -c "tar xzf /data/dsh/backup-sessions-*.tgz -C /data/dsh"
> docker restart dsh
> ```
>
> Also from 0.1.7: `settings.yaml` is imported **once** into profile plugin configuration by the Settings
> service and the file is renamed to `settings.yaml.imported` (see §9 of
> `issues/2026-09-22-dsh-0.1.7-alpha.1-适配分析.md`).
>
> To leave yourself a fallback point, use `docker exec dsh rescue dsh-upgrade <version>`: it records the
> current version as last-good first.

Check the current version:

```bash
docker exec dsh dsh --version
```

> Rebuild the image when: the base environment changes (Node major version / system dependencies), or you want to update the dsh base version baked into the seed:
> `docker build --build-arg DSH_VERSION=<version> --build-arg APT_MIRROR=mirrors.aliyun.com -t <your-repo>/dsh-docker:<version> .` and update `DSH_IMAGE` in `.env`.
>
> ⚠️ A new image does **not** update the dsh inside the `/opt/dsh` volume either (the seed is copied only
> when the volume holds no dsh at all — see the top of this chapter), so after rebuilding the image you
> still need step 2 of the two-step upgrade.

### Rolling back (driven by the image tag)

Because startup syncs dsh to the image seed by version, **rollbacks must go through the image tag too**:

| What to roll back | How |
|---|---|
| Back to the old dsh version | point `DSH_IMAGE` in `.env` back at the old tag → `docker compose pull && docker compose up -d` (dsh follows that image's seed automatically — no manual npm) |
| Temporarily change dsh (no image swap) | `docker exec dsh npm install -g @deepseek-ai/dsh@<version> && docker restart dsh` — ⚠️ it only survives if that version is **≥ the image seed**; otherwise the next startup overwrites it |
| **Everything** | unpack the pre-upgrade backup, including the `dsh/` data directory (see the data-format warning above) |

> ⚠️ "Old dsh + new image" is **no longer a viable combination**: the new image's seed displaces the old
> dsh on the next startup. To stay on an older version you must roll the **image tag** back as well — an
> unavoidable consequence of the image's pinned version winning.

### Cleaning up after upgrades

Upgrading inside the container over a long period accumulates leftovers that nothing reclaims. Use `rescue clean` to clear them:

```bash
docker exec dsh rescue clean            # preview (dry-run by default, changes nothing)
docker exec dsh rescue clean --yes      # apply
```

It cleans four things (all provably garbage):

| Item | What | Notes |
|---|---|---|
| npm download cache | `_cacache` | deleting it only means downloading again |
| pnpm store orphans | `pnpm store prune` | official semantics: "delete unreferenced only" |
| profile virtual-store orphans | entries under `.pnpm` not referenced by `pnpm-lock.yaml` | **`pnpm prune` does not clear these**, and they are the main source of leftovers |
| over-limit rescue history | evidence / incidents | reuses the existing `RESCUE_EVIDENCE_KEEP` / `RESCUE_INCIDENT_KEEP` |

> 🔒 `--yes` takes an **automatic snapshot first** (`reason: pre-clean`) as a fallback point, and
> **verifies that it actually exists** before deleting anything. If that snapshot cannot be created, or is
> rotated away immediately after being taken (e.g. the retention window is already full), `clean` **warns,
> exits non-zero and deletes nothing** — it would rather skip cleaning than delete files without a usable
> rollback point.
>
> ⚠ To satisfy the retention window (`RESCUE_KEEP`), taking the pre-clean snapshot **may** evict the oldest
> **non-pinned** snapshot under the existing rotation policy (snapshots whose reason starts with
> `boot-healthy` are pinned and never evicted). If an old snapshot you were keeping disappears, raise
> `RESCUE_KEEP` before cleaning.
>
> Apart from that rotation, cleaning **never** touches `package.json`, `pnpm-lock.yaml` or referenced
> `.pnpm` entries, so it does not affect the ability of `rescue rollback`.

> ⚠ If the profile uses the default `hardlink` snapshot mode, files still referenced by a snapshot keep
> their inode, so space may not be freed immediately — that is expected; it is reclaimed once the snapshot
> is rotated out.

## 2. Install / Remove Plugins

```bash
docker exec dsh dsh plugin --profile web add <包名>
docker exec dsh dsh plugin --profile web remove <包名>
docker restart dsh
```

Plugins and data are written to the `/data/dsh` volume, and survive container rebuilds/restarts.

> ⚠ Plugin changes (especially update/install) are the most frequent cause of startup failure. Prefer the wrapped commands in [06 · Rescue Mode](06-rescue-mode.md) for installing plugins (they snapshot automatically before the change); if a broken plugin stops the container from starting, the entrypoint rolls back automatically.

## 3. Change the API Key

```bash
# Edit .env, change DEEPSEEK_API_KEY, then:
docker compose up -d
```

## 4. Check Status and Logs

```bash
docker ps | grep dsh              # container status (healthy / starting / unhealthy)
docker logs dsh --tail 100        # logs
docker stats dsh                  # resource usage
```

## 5. Backup

**Just back up the whole deployment directory** (program + data + configuration are all inside):

```bash
cd <部署目录>        # directory containing docker-compose.yml
tar czf dsh-backup-$(date +%Y%m%d).tar.gz dsh programs workspace .env
```

To restore: extract the backup back into the original directory and run `docker compose up -d`.

> The most important part of the data is `dsh/` (DSH_HOME: sessions, configs, plugins, credentials, Hindsight memory bank).
> `workspace/` is the agent workspace; back it up as needed.

## 6. Update the Image (When the Base Environment Changes)

```bash
docker compose pull        # pull the new ghcr.io image
docker compose up -d       # rebuild the container
```

## 7. Common Maintenance Command Cheat Sheet

| Operation | Command |
|---|---|
| Check version | `docker exec dsh dsh --version` |
| Upgrade (image + dsh follows) | `docker compose pull && docker compose up -d` |
| Change dsh alone | `docker exec dsh npm install -g @deepseek-ai/dsh@<version> && docker restart dsh` (survives only if ≥ image seed) |
| Install a plugin | `docker exec dsh dsh plugin --profile web add <package> && docker restart dsh` |
| Change API key | Edit .env → `docker compose up -d` |
| Restart | `docker restart dsh` |
| Backup | `tar czf backup.tar.gz dsh programs workspace .env` |
