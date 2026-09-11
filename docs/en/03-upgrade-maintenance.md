# 03 · Upgrade & Maintenance

> [English](03-upgrade-maintenance.md) | [简体中文](../zh-CN/03-升级与维护.md)

## 1. Upgrade DSH (No Image Rebuild)

At build time, dsh+pnpm are pre-installed into a seed (`/opt/dsh-seed`), and on first boot the seed is copied to `/opt/dsh`. Upgrading = an npm operation inside the container that overwrites `/opt/dsh`:

```bash
docker exec dsh npm install -g @deepseek-ai/dsh@<新版本>
docker restart dsh
```

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
