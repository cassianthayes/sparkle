# 04 — Minecraft: mc-router + `2weekphase` (PufferPanel → itzg)

Server (from titan PufferPanel `4ab943c6`):

| | |
|---|---|
| Type | Paper 26.3 build 205, Java 25, heap 4 GB |
| World | `world` (8.2 GB, nether/end inside `world/dimensions`) |
| Plugins | AuthMe 6.0.1 (SQLite), Chunky 1.5.3, spark |
| Auth | `online-mode=false` + AuthMe (`maxRegPerIp: 1` → needs real IPs) |
| Ops | `cassiant`; whitelist off |

```
player → mc.cssnt.ru:25565 → mc-router (PROXY protocol) → mc-2weekphase:25565
                                   ↑ watches docker labels, no restart for new servers
```

- One stack per thing: `mc-router`, `mc-<name>` per server. New server = new stack → mc-router + other servers untouched.
- Shared external network `minecraft` (own unit, only `mc-*` stacks require it → existing stacks unchanged).
- Only `mc.cssnt.ru` routed (no default; unknown names/IP rejected).
- PROXY protocol on → every future server must accept it (Paper: `proxies.proxy-protocol: true`).
- Always on (no auto-sleep).
- `server.properties`: important values set by env (in git); rest kept from titan file.

## 1. Layout

```
/srv/config/stacks/mc-router/compose.yml
/srv/config/stacks/mc-2weekphase/compose.yml
/srv/data/minecraft/2weekphase/        = old PufferPanel server dir (/data in container)
```

## 2. Config (PC, repo)

`host.nix`:

```nix
  networking.firewall.allowedTCPPorts = [ 22 80 443 25565 ];
```

add to `systemd.tmpfiles.rules`:

```nix
    "d /srv/data/minecraft 0755 cassiant users -"
    "d /srv/data/minecraft/2weekphase 0755 cassiant users -"
```

`docker.nix` — networks as a list, `mc-*` stacks also need `minecraft`:

```nix
{ config, lib, ... }:
let
  stacks = [ "traefik" "navidrome" "remnawave" "mc-router" "mc-2weekphase" ];
  networks = [ "proxy" "minecraft" ];
  docker = "${config.virtualisation.docker.package}/bin/docker";
  netUnits = name: [ "docker-network-proxy.service" ]
    ++ lib.optional (lib.hasPrefix "mc-" name) "docker-network-minecraft.service";
in {
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
    daemon.settings.log-driver = "local";
  };
  users.users.cassiant.extraGroups = [ "docker" ];

  systemd.services = lib.listToAttrs (map (net: {
    name = "docker-network-${net}";
    value = {
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = "${docker} network inspect ${net} >/dev/null 2>&1 || ${docker} network create ${net}";
    };
  }) networks) // lib.listToAttrs (map (name: {
    name = "stack-${name}";
    value = {
      after = netUnits name ++ [ "network-online.target" ];
      requires = netUnits name;
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ (./stacks + "/${name}") ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        WorkingDirectory = "/srv/config/stacks/${name}";
        ExecStart = "${docker} compose up -d --remove-orphans";
        ExecStop = "${docker} compose down";
      };
    };
  }) stacks);
}
```

`stacks/mc-router/compose.yml`

```yaml
services:
  mc-router:
    image: itzg/mc-router:1.48.0
    container_name: mc-router
    restart: unless-stopped
    group_add: ["131"]   # host docker group (NixOS fixed gid) → socket access
    environment:
      IN_DOCKER: "true"
      USE_PROXY_PROTOCOL: "true"
    ports: ["25565:25565"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [minecraft]
networks:
  minecraft: { external: true }
```

`stacks/mc-2weekphase/compose.yml`

```yaml
services:
  mc-2weekphase:
    image: itzg/minecraft-server:2026.9.2-java25
    container_name: mc-2weekphase
    restart: unless-stopped
    stop_grace_period: 2m
    stdin_open: true
    tty: true
    environment:
      EULA: "TRUE"
      TYPE: PAPER
      VERSION: "26.3"
      PAPER_BUILD: "205"
      MEMORY: 4G
      USE_AIKAR_FLAGS: "true"
      UID: 1000
      GID: 100
      TZ: Asia/Yekaterinburg
      # server.properties (unset = kept from file)
      MOTD: '§dсамые смешные мемы§r\n§e>> двухнедельная фаза'
      DIFFICULTY: normal
      MAX_PLAYERS: 100
      ONLINE_MODE: "false"
      ENFORCE_SECURE_PROFILE: "false"
      SPAWN_PROTECTION: 0
    healthcheck:   # default one pings without PROXY header → fails
      test: ["CMD", "mc-monitor", "status", "--use-proxy", "--host", "localhost", "--port", "25565"]
      interval: 10s
      start_period: 1m
      retries: 6
    volumes:
      - /srv/data/minecraft/2weekphase:/data
    networks: [minecraft]
    labels:
      mc-router.host: mc.cssnt.ru
networks:
  minecraft: { external: true }
```

```sh
git add -A && git commit -m "minecraft: mc-router + 2weekphase" && git push
```

## 3. Data (PC)

Snapshot (taken 2026-10-19, server was stopped cleanly): `~/Downloads/pufferpanel/pufferpanel-snapshot.tgz`.

```sh
cd ~/Downloads/pufferpanel
tar -C x -xzf pufferpanel-snapshot.tgz var/lib/pufferpanel/servers/4ab943c6
S=x/var/lib/pufferpanel/servers/4ab943c6
rm -f $S/server.jar $S/world/session.lock                 # PufferPanel jar; itzg downloads its own
cp $S/server.properties server.properties.titan           # for diff after first start
sed -i 's/^  proxy-protocol: false$/  proxy-protocol: true/' $S/config/paper-global.yml
grep -n 'proxy-protocol' $S/config/paper-global.yml       # true
ssh sparkle 'sudo install -d -o cassiant -g users /srv/data/minecraft/2weekphase'
rsync -a --info=progress2 $S/ sparkle:/srv/data/minecraft/2weekphase/
```

- rsync as cassiant → files owned `1000:100`.

## 4. Apply

```sh
ssh sparkle
cd /srv/config && git pull
nixos-rebuild dry-activate --flake .#sparkle --sudo        # must NOT restart traefik/navidrome/remnawave
nixos-rebuild switch --flake .#sparkle --sudo
systemctl status stack-mc-router stack-mc-2weekphase
docker logs -f mc-2weekphase                               # downloads Paper 26.3-205, "Done (..s)!"
docker logs mc-router                                      # route mc.cssnt.ru → mc-2weekphase
```

properties drift check (PC):

```sh
diff ~/Downloads/pufferpanel/server.properties.titan <(ssh sparkle cat /srv/data/minecraft/2weekphase/server.properties)
```

- Expected diffs only: `enable-rcon=true`, `rcon.password` (checked 2026-10-19: OK). Anything else → set env in compose to the titan value.

## 5. Check

- Client → `mc.cssnt.ru` → server list shows MOTD + player count.
- Join → `/login <pass>` (AuthMe, old password) → same place/inventory.
- Real IP: `docker logs mc-2weekphase | grep "logged in"` → your public IP, not `172.x`.
- Nether/End portals → chunks present.

## 6. Backups

`scripts/sparkle-backup.sh` — around the tar step (all `mc-*` servers via label):

```bash
mc() { ssh "$HOST" 'for c in $(docker ps --filter label=mc-router.host --format "{{.Names}}"); do docker exec $c rcon-cli '"$*"'; done'; }

echo "→ Minecraft: flush + pause saving"
mc save-all flush
mc save-off
trap 'mc save-on; rm -f "$OUT.part"; exit 1' ERR INT TERM   # Ctrl-C → saving back on
```

after tar:

```bash
mc save-on
```

- World ≈ 8 GB, already compressed → archive ≈ 7 GB total (first run: 6.9 GB, ~2.5 min).

## Rollback

```sh
ssh sparkle 'sudo systemctl stop stack-mc-2weekphase stack-mc-router'
```

- Titan data untouched (PufferPanel server stopped). Snapshot on PC.

## Daily use

```sh
docker exec -i mc-2weekphase rcon-cli          # console (exit: Ctrl-D)
docker exec mc-2weekphase rcon-cli "say hi"    # one command
docker attach mc-2weekphase                    # raw console; detach Ctrl-P Ctrl-Q (not Ctrl-C!)
docker logs -f mc-2weekphase
sudo systemctl restart stack-mc-2weekphase
```

- Update Paper: bump `VERSION`/`PAPER_BUILD` → `scripts/sparkle-backup.sh` → commit → push → pull + rebuild.
- Plugins: `/srv/data/minecraft/2weekphase/plugins/` → restart stack.

## Add another server (no mc-router downtime)

1. DNS: `A <name>.cssnt.ru → 83.219.30.33`.
2. `host.nix` tmpfiles: `"d /srv/data/minecraft/<name> 0755 cassiant users -"`.
3. Copy `stacks/mc-2weekphase/` → `stacks/mc-<name>/`; change container name, data path, `mc-router.host`, `TYPE`/`VERSION`/`MEMORY`, drop `MOTD`/old-world env.
4. Must accept PROXY protocol: Paper → `config/paper-global.yml` `proxies.proxy-protocol: true` (after first start, then restart). Keep the `--use-proxy` healthcheck.
5. `docker.nix` → add `"mc-<name>"` to `stacks`.
6. Commit → push → pull + rebuild → only `stack-mc-<name>` starts; mc-router picks up the label live.
