# 03 · Upgrade & Maintenance

> [English](03-upgrade-maintenance.md) | [简体中文](../zh-CN/03-升级与维护.md)

## 1. Upgrade

An upgrade involves **two independent layers** that do **not** carry each other along — this is the
single most common source of confusion:

| Layer | Contents | How to update |
|---|---|---|
| **Image layer** | `entrypoint`, rescue scripts, `/opt/dsh-seed` (the dsh pinned at build time) | `docker compose pull && docker compose up -d` |
| **dsh itself** | the dsh actually running from the mounted volume `/opt/dsh` | `npm install -g` inside the container |

### ⚠️ Recreating the container does not update dsh itself

On first boot the image copies its seed into `/opt/dsh`, but **only when `command -v dsh` fails**
(`scripts/entrypoint.sh`, step ①). So once the `/opt/dsh` volume already holds a dsh (**any** version),
recreating the container will **not** overwrite it.

**Measured**: take a volume produced by an older image (`0.1.6-alpha.1`) and recreate the container with
a newer image pinning `0.1.6-alpha.2` — `dsh --version` **still reports `0.1.6-alpha.1`**. The image layer
really is the new one (entrypoint and friends updated), but the dsh in the volume was left untouched.
**"I upgraded but the version did not change" is almost always this.**

### Recommended order: image first, then dsh

```bash
# Step 1: update the image layer (entrypoint / rescue scripts / seed)
docker compose pull && docker compose up -d

# Step 2: update dsh itself (~90s measured, 245 dependency packages)
docker exec dsh npm install -g @deepseek-ai/dsh@<version>
docker restart dsh
```

> ⚠️ **Do not reverse the order.** Upgrading dsh first leaves the intermediate state "new dsh + old
> entrypoint" — and the entrypoint is what carries the read-only hardening (disabling the profile's HMR;
> see the hardening section of [07 · Environment variables](07-environment-variables.md)). The
> recommended order keeps every intermediate state safe: the `--patch` injected by the new entrypoint is
> equally valid on older dsh versions (`--patch` exists in `0.1.5-rc.2` / `0.1.6-alpha.1` /
> `0.1.6-alpha.2`, verified one by one).

Verify after upgrading:

```bash
docker exec dsh dsh --version                       # expect: the target version
docker inspect -f '{{.State.Health.Status}}' dsh    # expect: healthy
docker logs dsh 2>&1 | grep -i 'expose-internals'   # expect: no output
```

### Upgrading dsh alone (image layer unchanged)

When the image layer has not changed (e.g. it is already current and you only want a dsh patch
release), do step 2 only:

```bash
docker exec dsh npm install -g @deepseek-ai/dsh@<version>
docker restart dsh
```

### Always spell out the full version (do not use `latest` / `next`)

npm dist-tags are **manually assigned** aliases maintained by the publisher — they do **not** advance
automatically, and the three tags can point at three different versions:

| tag | Points at (checked 2026-09-18) | Meaning |
|---|---|---|
| `latest` | `0.1.5-rc.2` | Stable recommendation — **lags behind `alpha`** |
| `next` | `0.1.5-rc.2` | Newer candidate |
| `alpha` | `0.1.6-alpha.2` | Preview (**the version this image currently pins**) |

> ⚠️ So `npm install -g @deepseek-ai/dsh@latest` does **not** get you the newest version, and never gets
> you an alpha. Always pass the full version: `@0.1.6-alpha.2`. Verify with `docker exec dsh dsh --version`.
>
> 📌 The table above is a **snapshot in time**: dist-tags are assigned by hand and can change at any
> moment — for "where do they point right now", trust the live output of the command in the tip below.

> 💡 Check where the tags currently point: `docker exec dsh npm view @deepseek-ai/dsh dist-tags`.

> ⚠ **Back up first** (see §5): a cross-major upgrade can include an **irreversible** data-format change —
> for example `0.1.2-rc.1 → 0.1.5-rc.1` migrates sessions to V3, after which the **old version can no
> longer read** them (the files remain, but the new format is not understood by the old version). So when
> rolling the dsh version back, roll the `dsh/` data directory back with it.
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

### Rolling back (also two layers)

| What to roll back | How |
|---|---|
| **dsh itself** only | `docker exec dsh npm install -g @deepseek-ai/dsh@<old-version> && docker restart dsh` |
| **Image layer** | point `DSH_IMAGE` in `.env` back at the old tag → `docker compose pull && docker compose up -d` |
| **Everything** | unpack the pre-upgrade backup, including the `dsh/` data directory (see the data-format warning above) |

> 💡 "Old dsh + new image" is a **safe combination**: the `--patch` injected by the new entrypoint works
> just as well on older dsh versions. What you want to avoid is the reverse (new dsh + old entrypoint);
> see the ordering note at the top of this chapter.

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
| Upgrade the image layer | `docker compose pull && docker compose up -d` (does **not** change the dsh in the volume) |
| Upgrade dsh itself | `docker exec dsh npm install -g @deepseek-ai/dsh@<version> && docker restart dsh` |
| Install a plugin | `docker exec dsh dsh plugin --profile web add <package> && docker restart dsh` |
| Change API key | Edit .env → `docker compose up -d` |
| Restart | `docker restart dsh` |
| Backup | `tar czf backup.tar.gz dsh programs workspace .env` |
