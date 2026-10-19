# sparkle — homelab server (NixOS flake + Docker Compose stacks)

This repo = the whole server config. Clone on PC: `~/Desktop/sparkle`. On server: `/srv/config`.
Private GitHub `cassianthayes/sparkle` (server pulls via deploy key).

## How we work (teamwork)

The user and Claude work as a team, step by step. Each feature/migration = one round:

1. **Analyze** — read the repo, `docs/`, and the live server (read-only: `ssh sparkle '...'`). Gather facts first (versions, data sizes, configs, what depends on what). Never guess what can be checked.
2. **Ask** — every real choice (naming, exposure, versions, trade-offs) → AskUserQuestion, recommended option first with "(Recommended)". Don't ask what has a clear default or can be checked.
3. **Plan** — write `docs/NN-topic.md` (next free number). Then a short chat summary: what was found, plan steps, what needs user action. **Stop → user reviews.**
4. **Apply** — only after the user says go. Follow the guide exactly. If reality differs → fix, then update the guide so it matches what was actually done.
5. **Verify** — check every piece end to end (containers healthy, logs clean, HTTPS/cert from outside, data counts match, unrelated stacks NOT restarted). Show results as a table.
6. **Record** — update the Status section below + Decisions/Gotchas if something new was learned. Commit + push.

Style:
- Guides: only compact instructions — commands, config blocks, short bullets, tables. No prose.
- Chat: simple plain words, short tables/examples. The user may ask "what do you mean?" → explain the concept, not more jargon.
- Report honestly: what was checked vs not checked, what failed, own mistakes immediately (what happened, impact, fix).
- Keep the user informed during long tasks (one line: what you're doing now).
- When the user asks a question mid-task, answer it, then continue.

## Safety rules

- Changes on the server (rebuild, restart, data moves) only as part of an approved plan. Read-only checks are always fine.
- Hard-to-undo actions (delete data, overwrite, stop services outside the plan) → ask first, even if they seem implied.
- Other machines (titan, routers, de1 VPS) = read-only unless the user explicitly says otherwise.
- Never print secrets. Redact when reading env files (`sed` the values). Secrets live only in `/srv/secrets` (root 600), never in git.
- Before touching `docker.nix` / `host.nix` units: `nixos-rebuild dry-activate` → confirm unrelated stacks won't restart.
- Before upgrades / risky changes: `scripts/sparkle-backup.sh`.
- Minecraft console: commands take player names (`op list` ops a player named "list"!). Look up syntax before running.
- Tests against own services: non-destructive only (probes, a few wrong logins, scans) — no brute force, no load.

## Apply workflow

```sh
# PC, repo root
git add -A && git commit -m "..." && git push
ssh sparkle 'cd /srv/config && git pull --ff-only && nixos-rebuild switch --flake .#sparkle --sudo'
```

- Rebuild as `cassiant` with `--sudo` (repo owned by cassiant; plain root rebuild fails).
- Rebuild restarts only stacks whose `stacks/<name>/` changed (`restartTriggers`).
- Commit messages end with the Co-Authored-By line from the session's attribution instructions.
- Manual compose on server: `cd /srv/config/stacks/<name> && sudo docker compose ...` (sudo: env files are root 600).

## Repo layout

```
flake.nix  host.nix  docker.nix  disko.nix  hardware-configuration.nix
stacks/<name>/compose.yml      one per service → systemd unit stack-<name>
docs/NN-topic.md               step guides (history + how-to), server-setup.md = original plan/background
scripts/sparkle-backup.sh      PC: pull full backup archive
```

Server paths: `/srv/config` (this repo) · `/srv/data/<service>` (state, backed up) · `/srv/secrets` (root 600, backed up, not in git).

## Recipes

**New service (stack)**
1. `stacks/<name>/compose.yml`: `container_name`, `restart: unless-stopped`, pinned image tag, `user: "1000:100"` where the image allows, bind mounts into `/srv/data/<name>`, secrets via `env_file: /srv/secrets/<name>.env`.
2. Web → network `proxy` + Traefik labels (`Host(...)`, `entrypoints=websecure`, `tls.certresolver=le`, `loadbalancer.server.port`). DB/cache → stack-internal network (`internal: true`), never `proxy`.
3. No `ports:` (only Traefik 80/443 and mc-router 25565 publish). No docker.sock (use a socket proxy, see `docs/05-hardening.md`).
4. `host.nix` tmpfiles for `/srv/data/<name>`; `docker.nix` → add to `stacks`.
5. Stateful DB: restore data **before** first rebuild (`docs/03-remnawave.md` §6). Add dump step to `scripts/sparkle-backup.sh`.
6. DNS A record `<sub>.cssnt.ru → 83.219.30.33` (user does it).

**New Minecraft server** → `docs/04-minecraft.md` "Add another server".

## Decisions

- Host: NixOS **unstable**, flake `.#sparkle`. Single NVMe `/dev/nvme0n1`, ext4, UEFI + systemd-boot, disko, no LUKS. DHCP + router reservation.
- User `cassiant` (uid 1000, group users/100), wheel, sudo without password. SSH keys from `github.com/cassianthayes.keys` (flake input `ssh-keys`, pinned in flake.lock). SSH: keys only, no root.
- TZ `Asia/Yekaterinburg`. Tools: git, helix (`EDITOR=hx`), btop, curl, rsync.
- Firewall: NixOS iptables. Open: 22, 80, 443, 25565. Docker published ports bypass it → only Traefik + mc-router publish.
- Stacks: one systemd unit `stack-<name>` each (`docker.nix`); external networks `proxy` (all) and `minecraft` (`mc-*` stacks only, via `lib.hasPrefix`), each created by its own unit `docker-network-<net>`.
- Docker socket: only in per-stack socket proxies (`ghcr.io/tecnativa/docker-socket-proxy`, GET-only, internal net `socket`). Never mount docker.sock into app containers.
- Traefik v3: docker provider via `tcp://traefik-socket-proxy:2375`, ACME TLS-ALPN, resolver `le`, email `cassianthayes@gmail.com`, ACME store `/srv/data/traefik/acme.json`.
- Images pinned to exact versions (except navidrome `latest`, traefik `v3`, rclone `1`). Upgrade = bump tag → backup → commit → rebuild.
- Backups: manual from PC, `scripts/sparkle-backup.sh` → `~/Downloads/sparkle-<datetime>.tar.zst` (Navidrome snapshot, Remnawave `pg_dump`, MC `save-off` during tar; raw PG dir excluded). ~7 GB. No restic yet.

## Services

| Service | Stack | URL | Notes |
|---|---|---|---|
| Traefik | `traefik` | — | + `traefik-socket-proxy` |
| Navidrome | `navidrome` | `music.cssnt.ru` | music `/srv/data/navidrome/music`; fresh DB (titan's not migrated) |
| Upload (rclone WebDAV) | `navidrome` | `music.cssnt.ru/upload` | basic auth `telegram`, `/srv/secrets/navidrome-upload.env`; used by navidrome-gateway Worker |
| Remnawave panel | `remnawave` | `rw.cssnt.ru` | backend 3.4.5, postgres 18.4, valkey; public (bot needs API) |
| Remnawave sub page | `remnawave` | `connect.cssnt.ru` | 8.0.0; `/` → 502 is normal |
| mc-router | `mc-router` | `:25565` | PROXY protocol to backends; + `mc-router-socket-proxy` |
| Minecraft `2weekphase` | `mc-2weekphase` | `mc.cssnt.ru` | Paper 26.3-205, 4G, AuthMe (offline mode) |

## Network

- Domain `cssnt.ru`, public IP `83.219.30.33`. Main router ZTE RT-GM-4 `192.168.0.1` → DMZ → sparkle `192.168.0.9` (reserved).
- Router2 `192.168.0.6` → PC `192.168.1.3`, titan `192.168.1.141`. PC reaches sparkle; sparkle can't reach PC.
- PC SSH aliases: `sparkle`, `titan` (HostKeyAlias `titan.cssnt.ru`).
- PC runs Throne VPN (TUN): port scans from PC are fake (every port "open"); traffic to `83.219.30.33` goes direct (hairpin). Verify exposure on sparkle side (firewall counters / temporary LOG rule).

## External things (not in this repo)

- **titan** (old server, Debian 13, `192.168.1.141`): everything migrated; Remnawave containers stopped (`--restart=no`), PufferPanel server stopped. Still has Navidrome DB (`/var/lib/navidrome`, not migrated — open decision). sudo needs password. Read-only. To be shut down.
- **de1** node: `de1.cssnt.ru` 64.188.70.244:2222, external VPS, Remnawave node. Not managed here.
- **navidrome-gateway** (`~/Documents/navidrome-gateway`): CF Worker, Telegram → PUT `music.cssnt.ru/upload/<file>`; secret `WEBDAV_PASS` = `RCLONE_PASS`.
- **cassiant_connect_bot** (`~/Documents/cassiant_connect_bot`): CF Worker VPN-shop bot; calls `https://rw.cssnt.ru/api` (token in panel DB); panel webhooks → `cassiant-connect-bot.cassianthayes.workers.dev/remnawave`.

## Gotchas (learned the hard way)

- Changing a unit that others `Require` (e.g. `docker-network-proxy`) restarts them all → add new units instead of editing shared ones.
- DB migrations: start only the DB container, restore, then rebuild — otherwise the app initializes an empty DB.
- `pg_dump` (not `pg_dumpall`): dumpall would overwrite the new role password.
- itzg/minecraft-server: env vars override server.properties (and it has defaults, e.g. MOTD, difficulty) → set key values explicitly; diff against the old file after first start. Default healthcheck fails with PROXY protocol → `mc-monitor status --use-proxy`.
- mc-router: proxy protocol is global → every backend must accept it.
- Remnawave lockout: `docker exec -it remnawave cli` → "Enable password authentication" / "Reset superadmin".
- Traefik's TLS-ALPN challenge needs the DMZ/443 pointing at sparkle.

## Status

Done (all applied + verified 2026-10-19, user confirmed):
- `docs/01-bare-metal.md` — NixOS install.
- `docs/02-navidrome.md` — Docker, Traefik, Navidrome, Telegram upload, backups.
- `docs/03-remnawave.md` — Remnawave panel + sub page from titan (pg_dump restore, node de1 connected).
- `docs/04-minecraft.md` — mc-router + `2weekphase` from titan PufferPanel.
- `docs/05-hardening.md` — security audit (no open holes), Docker socket proxies; Remnawave passkey (user).

Open:
- Navidrome DB on titan (accounts/playlists/favorites) — migrate or drop? Then shut titan down.
