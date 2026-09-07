# 02 · Authentication & Remote Access

> [English](02-authentication-remote-access.md) | [简体中文](../zh-CN/02-认证与远程访问.md)

The default configuration is **intranet direct access** (no auth plugin installed): port `3080` is mapped to the host, reachable only within the LAN.
For **remote access across networks** (public internet, off-site), follow this guide to add authentication and use a reverse proxy.

## 1. Access Overview

| Method | Security | Use case |
|---|---|---|
| Local access (`127.0.0.1:3080`) | Highest | Browser on the same machine |
| Intranet direct access (`http://<lan-ip>:3080`) | High (no auth, relies on intranet isolation) | LAN usage |
| SSH tunnel | High (encrypted) | Temporary single-user access from outside |
| Reverse proxy + dsh-remote auth | High (auth layer + HTTPS) | Long-term remote access |

> Browser limitation: some features of `dsh web` (e.g. `crypto.randomUUID`, settings) require a **secure context**
> (HTTPS or localhost). If you hit related errors when accessing the intranet directly by IP, that is the browser's security
> policy; use `localhost`, an SSH tunnel, or HTTPS via a reverse proxy instead.

## 2. Add dsh-remote Authentication (Optional, Recommended for Remote Access)

The [dsh-remote](https://github.com/xgone/dsh-remote) plugin provides **username/password + MFA (TOTP)** authentication;
`/api`, WebSocket, and privileged methods are only allowed after a successful login.

```bash
# Install the plugin (plugin & account data go into the /data/dsh volume, survive container rebuilds)
docker exec dsh dsh plugin --profile web add @xgone/dsh-remote
docker restart dsh
```

### 2.1 Create the First Admin

dsh-remote stores accounts in `$DSH_HOME/auth/store.json`. When the store is empty the login page enters **bootstrap mode** ("Create the first admin account"). The account is **admin**-role by default. Two ways to create it:

**Option A — local browser (loopback only).** Open `http://127.0.0.1:3080` in a browser **on the host machine** (via SSH tunnel or localhost). The login page shows the create-account form — enter a username and a password (≥ 6 chars) and create it. This endpoint refuses non-loopback requests (403) to prevent remote registration hijacking.

**Option B — config bootstrap (headless / NAS / no local browser).** Declare the credentials in the plugin config before starting, and dsh-remote provisions the first admin at boot (idempotent — ignored as soon as any account exists). Edit the `remote` row in `profiles/web/cordis.patch.yml` (mounted into the `/data/dsh` volume — survives restarts):

```yaml
- id: remote
  config:
    enabled: true
    bootstrap:             # only used when the account store is empty
      username: admin
      password: 'a-strong-password'
```

then restart. The log shows `bootstrapped first admin account ... from config`. **After the first login, remove the plaintext credentials from `cordis.patch.yml`.**

> There is no separate "first admin" step for core dsh — see [01](01-quick-start.md). This section is only for dsh-remote.

### 2.2 Log In and Enable MFA

- Visit `http://<host>:3080` and log in with the account you just created
- Settings → Login & Account → Two-factor authentication (MFA) → scan the QR code with Google Authenticator / 1Password
- **MFA is mandatory**: if exposed to the public internet via a reverse proxy, the auth layer is the only line of defense

## 3. SSH Tunnel (Temporary Single-User Access from Outside)

```bash
# Local port forwarding: map remote 3080 to local 3080
ssh -L 3080:127.0.0.1:3080 your-user@host-ip
# Then open http://127.0.0.1:3080 in the browser
```

Works wherever Windows/Mac/Linux ship with a built-in `ssh` — no extra configuration needed.

## 4. Reverse Proxy + HTTPS (Long-Term Remote Access, Recommended)

Using Caddy (automatic HTTPS) as an example; Nginx works the same way:

```bash
# Caddyfile (the domain must resolve to the host; ports 80/443 open)
your-domain.com {
    reverse_proxy 127.0.0.1:3080
}
```

```bash
# Run Caddy with Docker
docker run -d --name caddy \
  -p 80:80 -p 443:443 \
  -v /path/to/Caddyfile:/etc/caddy/Caddyfile \
  -v caddy_data:/data \
  caddy:2
```

> Before exposing through a reverse proxy, make sure dsh-remote is installed and MFA is enabled (see Section 2).

## 5. Security Checklist

- [ ] Remote access: strong password + **MFA (TOTP)**
- [ ] Do not map `3080` directly to the public internet (when no auth is added)
- [ ] Third-party plugins have full permissions; review their source before installing
- [ ] Back up regularly (see [03](03-upgrade-maintenance.md))
