# 05 — Hardening: Docker socket proxy + Remnawave passkey

Audit 2026-10-19: no open holes. These two close the biggest "if X gets hacked" risks.

| # | Now | After |
|---|---|---|
| 1 | traefik + mc-router mount `/var/run/docker.sock` (`:ro` does NOT limit the API → bug = root on host) | each talks to its own socket proxy: read-only API (GET containers/events), no POST, no exec |
| 2 | Remnawave admin = password only, panel public | passkey login, password login off |

## 1. Docker socket proxy

- One proxy per stack (`traefik-socket-proxy`, `mc-router-socket-proxy`), on a stack-internal network `socket` (no internet, nobody else on it).
- Image `ghcr.io/tecnativa/docker-socket-proxy:v0.5.0`. Default = GET only, `POST=0`.

`stacks/traefik/compose.yml`

```yaml
services:
  traefik:
    image: traefik:v3
    container_name: traefik
    restart: unless-stopped
    depends_on: [traefik-socket-proxy]
    command:
      - --providers.docker=true
      - --providers.docker.endpoint=tcp://traefik-socket-proxy:2375
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=proxy
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.le.acme.tlschallenge=true
      - --certificatesresolvers.le.acme.email=cassianthayes@gmail.com
      - --certificatesresolvers.le.acme.storage=/acme/acme.json
    ports: ["80:80", "443:443"]
    volumes:
      - /srv/data/traefik:/acme
    networks: [proxy, socket]

  traefik-socket-proxy:
    image: ghcr.io/tecnativa/docker-socket-proxy:v0.5.0
    container_name: traefik-socket-proxy
    restart: unless-stopped
    environment:
      CONTAINERS: 1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [socket]

networks:
  proxy: { external: true }
  socket: { internal: true }
```

`stacks/mc-router/compose.yml`

```yaml
services:
  mc-router:
    image: itzg/mc-router:1.48.0
    container_name: mc-router
    restart: unless-stopped
    depends_on: [mc-router-socket-proxy]
    environment:
      IN_DOCKER: "true"
      DOCKER_SOCKET: tcp://mc-router-socket-proxy:2375
      USE_PROXY_PROTOCOL: "true"
    ports: ["25565:25565"]
    networks: [minecraft, socket]

  mc-router-socket-proxy:
    image: ghcr.io/tecnativa/docker-socket-proxy:v0.5.0
    container_name: mc-router-socket-proxy
    restart: unless-stopped
    environment:
      CONTAINERS: 1
      NETWORKS: 1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [socket]

networks:
  minecraft: { external: true }
  socket: { internal: true }
```

- `group_add: ["131"]` removed (mc-router no longer touches the socket).
- Later: mc-router auto-sleep would need `POST: 1` on its proxy.

Apply (traefik + mc-router restart, ~seconds; MC players get kicked once):

```sh
git add -A && git commit -m "docker socket proxies" && git push
ssh sparkle 'cd /srv/config && git pull && nixos-rebuild switch --flake .#sparkle --sudo'
```

Check:

```sh
ssh sparkle 'docker ps --format "{{.Names}} {{.Status}}"'
ssh sparkle 'docker logs traefik 2>&1 | grep -i error | tail'            # none
ssh sparkle 'docker logs mc-router 2>&1 | tail -3'                       # route mc.cssnt.ru created
curl -sI https://music.cssnt.ru | head -1; curl -sI https://rw.cssnt.ru | head -1
```

Proxy really read-only (expect `403`):

```sh
ssh sparkle 'docker exec traefik wget -qO- --post-data="" http://traefik-socket-proxy:2375/containers/navidrome/stop'
ssh sparkle 'docker exec traefik wget -qO- http://traefik-socket-proxy:2375/images/json'
```

- Socket now mounted only in: the 2 proxies (tiny, no network access to outside).

## 2. Remnawave passkey

Needs: phone/PC with passkey support (Google Password Manager, iCloud Keychain, Bitwarden, YubiKey…).

1. https://rw.cssnt.ru → Settings → Authentication → Passkey:
   - RP ID: `rw.cssnt.ru`
   - Origin: `https://rw.cssnt.ru`
   - Enabled: on → save.
2. Profile / Passkeys → Add passkey → confirm on device.
3. Log out → log in with passkey → works.
4. Settings → Authentication → Password: off → save.
5. Second device: register a 2nd passkey (backup).

Locked out (lost passkey):

```sh
ssh sparkle
docker exec -it remnawave cli        # → "Enable password authentication" (or "Reset superadmin")
```

- Bot keeps working: it uses an API token, not the admin login.
