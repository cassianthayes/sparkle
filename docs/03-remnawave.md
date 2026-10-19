# 03 — Remnawave panel (titan → sparkle)

What moves: panel `rw.cssnt.ru` + sub page `connect.cssnt.ru` (backend 3.4.5, sub-page 8.0.0, Postgres 18.4, Valkey).
What stays: node `de1` (`de1.cssnt.ru` = 64.188.70.244:2222, external VPS) — untouched.

```
internet → Traefik (sparkle :443) ─┬─ rw.cssnt.ru      → remnawave:3000
                                   └─ connect.cssnt.ru → remnawave-subscription-page:3010
remnawave ──(outbound)──→ de1:2222 (node API), bot Worker webhook
bot Worker ──→ https://rw.cssnt.ru/api
```

- Panel public (as on titan). Images pinned.
- DB moves by `pg_dump` (no sudo on titan needed). New DB password.
- Only `remnawave-db` has a bind mount → only it runs as `1000:100`. Backend/valkey/sub-page: image default (no host files).
- DB + valkey on internal network `remnawave` only.

## 1. Layout

```
/srv/config/stacks/remnawave/compose.yml
/srv/data/remnawave/{db,backup}
/srv/secrets/remnawave.env        panel + postgres (from titan .env)
/srv/secrets/remnawave-sub.env    sub page (from titan subscription/.env)
```

## 2. Config (PC, repo)

`host.nix` — add to `systemd.tmpfiles.rules`:

```nix
    "d /srv/data/remnawave 0755 cassiant users -"
    "d /srv/data/remnawave/db 0700 cassiant users -"
    "d /srv/data/remnawave/backup 0755 cassiant users -"
```

`docker.nix`:

```nix
  stacks = [ "traefik" "navidrome" "remnawave" ];
```

`stacks/remnawave/compose.yml`

```yaml
x-common: &common
  restart: unless-stopped
  ulimits:
    nofile: { soft: 1048576, hard: 1048576 }

services:
  remnawave:
    <<: *common
    image: remnawave/backend:3.4.5
    container_name: remnawave
    hostname: remnawave
    env_file: /srv/secrets/remnawave.env
    volumes:
      - valkey-socket:/var/run/valkey
    networks: [remnawave, proxy]
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:3001/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      remnawave-db: { condition: service_healthy }
      remnawave-redis: { condition: service_healthy }
    labels:
      - traefik.enable=true
      - traefik.http.routers.remnawave.rule=Host(`rw.cssnt.ru`)
      - traefik.http.routers.remnawave.entrypoints=websecure
      - traefik.http.routers.remnawave.tls.certresolver=le
      - traefik.http.services.remnawave.loadbalancer.server.port=3000

  remnawave-db:
    <<: *common
    image: postgres:18.4
    container_name: remnawave-db
    hostname: remnawave-db
    user: "1000:100"
    shm_size: 512mb
    env_file: /srv/secrets/remnawave.env
    environment:
      TZ: UTC   # must stay UTC
    volumes:
      - /srv/data/remnawave/db:/var/lib/postgresql
    networks: [remnawave]
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3

  remnawave-redis:
    <<: *common
    image: valkey/valkey:9-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    command: >
      valkey-server --save "" --appendonly no --maxmemory-policy noeviction
      --loglevel warning --unixsocket /var/run/valkey/valkey.sock --unixsocketperm 777 --port 0
    volumes:
      - valkey-socket:/var/run/valkey
    networks: [remnawave]
    healthcheck:
      test: ['CMD', 'valkey-cli', '-s', '/var/run/valkey/valkey.sock', 'ping']
      interval: 3s
      timeout: 3s
      retries: 3

  remnawave-subscription-page:
    <<: *common
    image: remnawave/subscription-page:8.0.0
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    env_file: /srv/secrets/remnawave-sub.env
    networks: [remnawave, proxy]
    labels:
      - traefik.enable=true
      - traefik.http.routers.remnawave-sub.rule=Host(`connect.cssnt.ru`)
      - traefik.http.routers.remnawave-sub.entrypoints=websecure
      - traefik.http.routers.remnawave-sub.tls.certresolver=le
      - traefik.http.services.remnawave-sub.loadbalancer.server.port=3010

volumes:
  valkey-socket: {}   # socket only, no state

networks:
  remnawave: { internal: true }
  proxy: { external: true }
```

```sh
git add -A && git commit -m "remnawave stack" && git push
```

## 3. PC ssh alias for titan

`~/.ssh/config` (titan moved to `192.168.1.141`; host key = known `titan.cssnt.ru`):

```
Host titan
  HostName 192.168.1.141
  User cassiant
  HostKeyAlias titan.cssnt.ru
```

## 4. Secrets (PC)

```sh
ssh titan 'cat /opt/remnawave/.env' | ssh sparkle 'sudo sh -c "umask 077; cat > /srv/secrets/remnawave.env"'
ssh titan 'cat /opt/remnawave/subscription/.env' | ssh sparkle 'sudo sh -c "umask 077; cat > /srv/secrets/remnawave-sub.env"'
```

New DB password (on sparkle):

```sh
P=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
sudo sed -i -E "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$P|; s|^(DATABASE_URL=\"postgresql://postgres:)[^@]*@|\1$P@|" /srv/secrets/remnawave.env
sudo grep -E '^(POSTGRES_PASSWORD|DATABASE_URL)=' /srv/secrets/remnawave.env   # same password in both
```

## 5. Freeze titan panel + dump DB (PC)

```sh
ssh titan 'docker update --restart=no remnawave remnawave-subscription-page remnawave-db remnawave-redis'
ssh titan 'docker stop remnawave remnawave-subscription-page'          # db stays up for dump
ssh titan 'docker exec remnawave-db pg_dump -U postgres -d postgres -Fc' > ~/Downloads/remnawave-titan.dump
ls -lh ~/Downloads/remnawave-titan.dump                                # ~50–100 KB, not 0
ssh titan 'docker stop remnawave-db remnawave-redis'
```

- `--restart=no` → old panel won't come back after a titan reboot (two panels on one node = conflicts).
- Keep `remnawave-titan.dump` (rollback).

## 6. DB on sparkle, restore (before rebuild!)

Rebuild would start the backend on an empty DB → restore first.

```sh
ssh sparkle
cd /srv/config && git pull
sudo install -d -o cassiant -g users -m 700 /srv/data/remnawave/db
cd stacks/remnawave && sudo docker compose up -d --wait remnawave-db
exit
```

PC:

```sh
ssh sparkle 'docker exec -i remnawave-db pg_restore -U postgres -d postgres --no-owner --clean --if-exists --single-transaction' < ~/Downloads/remnawave-titan.dump
ssh sparkle 'docker exec remnawave-db psql -U postgres -Atc "select count(*) from users; select name from nodes"'   # 4, de1
```

## 7. Apply

```sh
ssh sparkle
cd /srv/config && nixos-rebuild switch --flake .#sparkle --sudo
systemctl status stack-remnawave
docker ps                                  # 4 remnawave containers healthy
docker logs -f remnawave                   # no errors; node de1 connects
docker logs traefik 2>&1 | grep -i acme    # certs rw + connect, no errors
```

## 8. Check

- https://rw.cssnt.ru → login with existing admin.
- Nodes → `de1` online (green), Xray running.
- Users → 3 active, 1 disabled.
- Open a user's sub link `https://connect.cssnt.ru/<shortUuid>` → page loads; client → update subscription OK.
- `https://connect.cssnt.ru/` (no path) → 502 = normal (sub page drops unknown paths).
- Telegram bot: open menu / subscription → data loads (API); a user action → webhook arrives at Worker.

## 9. Backups

`scripts/sparkle-backup.sh` — add before the tar step:

```bash
echo "→ Remnawave DB dump"
ssh "$HOST" 'docker exec remnawave-db pg_dump -U postgres -d postgres -Fc > /srv/data/remnawave/backup/remnawave.dump'
```

and to the tar excludes (live PG files are not consistent; dump is):

```bash
  --exclude=srv/data/remnawave/db \
```

Restore (after 02 restore steps put `/srv/data` + `/srv/secrets` back):

```sh
ssh sparkle
sudo systemctl stop stack-remnawave
sudo rm -rf /srv/data/remnawave/db && sudo install -d -o cassiant -g users -m 700 /srv/data/remnawave/db
cd /srv/config/stacks/remnawave && sudo docker compose up -d --wait remnawave-db
docker exec -i remnawave-db pg_restore -U postgres -d postgres --no-owner --clean --if-exists --single-transaction < /srv/data/remnawave/backup/remnawave.dump
sudo systemctl restart stack-remnawave
```

## Rollback

```sh
ssh sparkle 'sudo systemctl stop stack-remnawave'
ssh titan 'docker update --restart=always remnawave remnawave-subscription-page remnawave-db remnawave-redis && docker start remnawave-db remnawave-redis remnawave remnawave-subscription-page'
```

- Titan is behind router2 → panel not public from there; rollback = data safe, not service.

## Later (titan decommission)

- `/opt/rw-backup-restore` (old backup script) not migrated → replaced by `scripts/sparkle-backup.sh`.
- Remove on titan only when shutting it down: `docker compose down` in `/opt/remnawave` (+ `subscription/`). Volume `remnawave-db-data` kept until then.

## Daily use

```sh
sudo systemctl restart stack-remnawave
docker logs -f remnawave
```

- Upgrade: bump tags in compose (read Remnawave release notes; backend + sub page together) → `scripts/sparkle-backup.sh` → commit → push → pull + rebuild.
