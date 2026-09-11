# 05 · Platform Differences

> [English](05-platform-differences.md) | [简体中文](../zh-CN/05-平台差异.md)

This guide is written against a baseline of **generic Linux + Docker Engine**. Every platform is essentially the same underneath (all are Linux containers); the differences are only in paths, the container manager, and network settings. Jump to the section for your platform.

## 1. General Linux Servers (Recommended Baseline)

- Cloud hosts / VPS / home mini-PCs / soft routers, running Ubuntu/Debian/CentOS/OpenWrt, etc.
- After installing Docker Engine + the compose plugin, just follow [01](01-quick-start.md).
- On networks in mainland China, configure a registry mirror first for faster pulls:

```bash
# /etc/docker/daemon.json
{
  "registry-mirrors": ["https://docker.m.daocloud.io", "https://dockerproxy.com"]
}
systemctl restart docker
```

## 2. Synology DSM

> ⚠ **When accessing over the NAS IP** (`http://192.168.x.x:3080`), add `192.168.x.x:3080` to
> `DSH_TRUSTED_HOSTS` in `.env`: dsh only trusts loopback or allow-listed Hosts, and a missing entry
> shows up as "the page opens but `/api` returns 403".

- **Install**: Package Center → search and install "Container Manager" (Docker's official package); includes compose support.
- **Paths**: Shared folders are mounted at `/volume1/...`; create a deployment directory inside a shared folder (e.g. `/volume1/docker/dsh-docker/`), and write absolute paths into `.env`:

  ```
  PROGRAMS_DIR=/volume1/docker/dsh-docker/programs
  DSH_DATA_DIR=/volume1/docker/dsh-docker/dsh
  WORKSPACE_DIR=/volume1/docker/dsh-docker/workspace
  ```

- **Commands**: Log in via SSH and run `docker compose ...`; you can also import `docker-compose.yml` in the "Project" tab of the Container Manager GUI.
- **Notes**: `compose.yaml` syntax is compatible; Container Manager projects do not support all variable interpolation, so keep `.env` in the same directory as the compose file.

## 3. UGREEN UGOS Pro

- **Install**: Install "Docker" from the App Center; SSH must be enabled in Control Panel → Terminal.
- **Paths**: Shared folders are at `/volume1/...`, same approach as Synology.
- **Commands**: After SSH login, run `docker compose up -d`.
- **Container management**: You can also import a compose file in the UGOS Docker GUI.

## 4. QNAP QTS / QuTS hero

- **Install**: Install "Container Station" from App Center; enable SSH (Control Panel → Network & File Services → Telnet/SSH).
- **Paths**: Shared folders are at `/share/...`, e.g. `/share/Container/dsh-docker/`.
- **Commands**: After SSH login, run `docker compose up -d`.

## 5. Windows / macOS Docker Desktop

- **Install**: Download Docker Desktop from the official site (Windows needs the WSL 2 or Hyper-V backend; macOS needs Apple Silicon or Intel).
- **Commands**: Run `docker compose ...` in PowerShell / Terminal.
- **Paths**: Use absolute paths in `.env`; Windows example:

  ```
  PROGRAMS_DIR=D:/docker/dsh-docker/programs
  DSH_DATA_DIR=D:/docker/dsh-docker/dsh
  WORKSPACE_DIR=D:/docker/dsh-docker/workspace
  ```

- **Ports**: Docker Desktop handles port mapping automatically; access via `http://localhost:3080`.
- **macOS resources**: Adjust memory/CPU in Docker Desktop → Settings → Resources (this guide defaults to 2g / 2 cores).
- **Windows file-mount performance**: for heavy small-file IO, put the data directory on the WSL 2 internal filesystem (`\\wsl$\docker-desktop\...`) for better performance.
- **Notes**: In PowerShell, escape `$` with a backtick when it has special meaning in compose variables, or just write the values directly in `.env`.

## 6. Lightweight Environments Without Docker (K3s / Podman, etc.)

- Podman: `podman-compose up -d` or `podman play kube` (converting compose to k8s needs a conversion tool).
- The files in this repo are based on Docker compose v2 syntax; orchestrators such as K3s require manual conversion — using Docker directly is recommended.
