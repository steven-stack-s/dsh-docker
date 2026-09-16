# 03 · Upgrade & Maintenance

> [English](03-upgrade-maintenance.md) | [简体中文](../zh-CN/03-升级与维护.md)

## 1. Upgrade DSH (No Image Rebuild)

At build time, dsh+pnpm are pre-installed into a seed (`/opt/dsh-seed`), and on first boot the seed is copied to `/opt/dsh`. Upgrading = an npm operation inside the container that overwrites `/opt/dsh`:

```bash
docker exec dsh npm install -g @deepseek-ai/dsh@<新版本>
docker restart dsh
```

### Always spell out the full version (do not use `latest` / `next`)

npm dist-tags are **manually assigned** aliases maintained by the publisher — they do **not** advance
automatically, and the three tags can point at three different versions:

| tag | Has pointed at | Meaning |
|---|---|---|
| `latest` | `0.1.5-rc.1` | Stable recommendation — **may lag behind `next`** |
| `next` | `0.1.5-rc.2` | Newer candidate |
| `alpha` | `0.1.6-alpha.1` | Preview (**the version this image currently pins**) |

> ⚠️ So `npm install -g @deepseek-ai/dsh@latest` does **not** get you the newest version, and never gets
> you an alpha. Always pass the full version: `@0.1.6-alpha.1`. Verify with `docker exec dsh dsh --version`.

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
| Upgrade DSH | `docker exec dsh npm install -g @deepseek-ai/dsh@<版本> && docker restart dsh` |
| Install a plugin | `docker exec dsh dsh plugin --profile web add <包名> && docker restart dsh` |
| Change API key | Edit .env → `docker compose up -d` |
| Restart | `docker restart dsh` |
| Backup | `tar czf backup.tar.gz dsh programs workspace .env` |
