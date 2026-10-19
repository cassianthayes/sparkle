# 02 — Docker, Traefik, Navidrome, Telegram upload, backups

Network:

```
internet 83.219.30.33 → main router 192.168.0.1 ─┬─ sparkle 192.168.0.9   ← DMZ
                                                  └─ router2 192.168.0.6 ─┬─ PC 192.168.1.3
                                                                          └─ titan
```

- Main router: reserve `192.168.0.9` for sparkle.
- PC `~/.ssh/config`:

```
Host sparkle
  HostName 192.168.0.9
  User cassiant
```

## 1. Layout

```
/srv/config/            git
  flake.nix host.nix docker.nix
  stacks/traefik/compose.yml
  stacks/navidrome/compose.yml
/srv/data/              backed up
  traefik/  navidrome/{data,backup,music/telegram}
/srv/secrets/           root 600, not in git, backed up
  navidrome-upload.env
```

## 2. Host changes

`flake.nix` — add modules:

```nix
        ./host.nix
        ./docker.nix
```

`host.nix` — change:

```nix
  networking.firewall.allowedTCPPorts = [ 22 80 443 ];

  users.users.cassiant = {
    uid = 1000;
    # ...rest unchanged
  };

  systemd.tmpfiles.rules = [
    "d /srv/data 0755 root root -"
    "d /srv/secrets 0700 root root -"
    "d /srv/data/traefik 0700 root root -"
    "d /srv/data/navidrome 0755 cassiant users -"
    "d /srv/data/navidrome/data 0755 cassiant users -"
    "d /srv/data/navidrome/backup 0755 cassiant users -"
    "d /srv/data/navidrome/music 0755 cassiant users -"
    "d /srv/data/navidrome/music/telegram 0755 cassiant users -"
  ];

  environment.systemPackages = with pkgs; [ git helix btop curl rsync ];
```

`docker.nix`

```nix
{ config, lib, ... }:
let
  stacks = [ "traefik" "navidrome" ];
  docker = "${config.virtualisation.docker.package}/bin/docker";
in {
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
    daemon.settings.log-driver = "local";
  };
  users.users.cassiant.extraGroups = [ "docker" ];

  systemd.services = {
    docker-network-proxy = {
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = "${docker} network inspect proxy >/dev/null 2>&1 || ${docker} network create proxy";
    };
  } // lib.listToAttrs (map (name: {
    name = "stack-${name}";
    value = {
      after = [ "docker-network-proxy.service" "network-online.target" ];
      requires = [ "docker-network-proxy.service" ];
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

## 3. Traefik

`stacks/traefik/compose.yml`

```yaml
services:
  traefik:
    image: traefik:v3
    container_name: traefik
    restart: unless-stopped
    command:
      - --providers.docker=true
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
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /srv/data/traefik:/acme
    networks: [proxy]
networks:
  proxy: { external: true }
```

## 4. Navidrome + upload endpoint

`stacks/navidrome/compose.yml`

```yaml
services:
  navidrome:
    image: deluan/navidrome:latest
    container_name: navidrome
    restart: unless-stopped
    user: "1000:100"
    environment:
      ND_BACKUP_PATH: /backup
      ND_BACKUP_COUNT: 7
    volumes:
      - /srv/data/navidrome/data:/data
      - /srv/data/navidrome/backup:/backup
      - /srv/data/navidrome/music:/music:ro
    networks: [proxy]
    labels:
      - traefik.enable=true
      - traefik.http.routers.navidrome.rule=Host(`music.cssnt.ru`)
      - traefik.http.routers.navidrome.entrypoints=websecure
      - traefik.http.routers.navidrome.tls.certresolver=le
      - traefik.http.services.navidrome.loadbalancer.server.port=4533

  upload:
    image: rclone/rclone:1
    container_name: navidrome-upload
    restart: unless-stopped
    user: "1000:100"
    command: serve webdav /music --addr :8090
    env_file: /srv/secrets/navidrome-upload.env
    volumes:
      - /srv/data/navidrome/music/telegram:/music
    networks: [proxy]
    labels:
      - traefik.enable=true
      - traefik.http.routers.navidrome-upload.rule=Host(`music.cssnt.ru`) && PathPrefix(`/upload`)
      - traefik.http.routers.navidrome-upload.entrypoints=websecure
      - traefik.http.routers.navidrome-upload.tls.certresolver=le
      - traefik.http.routers.navidrome-upload.middlewares=navidrome-upload-strip
      - traefik.http.middlewares.navidrome-upload-strip.stripprefix.prefixes=/upload
      - traefik.http.services.navidrome-upload.loadbalancer.server.port=8090
networks:
  proxy: { external: true }
```

## 5. Secrets

On sparkle:

```sh
sudo sh -c 'umask 077; printf "RCLONE_USER=telegram\nRCLONE_PASS=%s\n" $(head -c 24 /dev/urandom | od -An -tx1 | tr -d " \n") > /srv/secrets/navidrome-upload.env'
```

Worker (PC):

```sh
cd ~/Documents/navidrome-gateway
ssh sparkle 'sudo grep PASS /srv/secrets/navidrome-upload.env | cut -d= -f2' | tr -d '\n' | npx wrangler secret put WEBDAV_PASS
```

## 6. Apply

```sh
cd /srv/config
git add -A && git commit -m "docker, traefik, navidrome"
nixos-rebuild switch --flake .#sparkle --sudo
systemctl status stack-traefik stack-navidrome
docker ps
```

## 7. Music

From PC (titan has no rsync → tar):

```sh
mkdir -p ~/Desktop/titan-music
ssh cassiant@192.168.0.8 'tar -C /opt/navidrome/music/telegram -cf - .' | tar -C ~/Desktop/titan-music -xf -
rsync -a --info=progress2 ~/Desktop/titan-music/ cassiant@192.168.0.9:/srv/data/navidrome/music/telegram/
rsync -a --ignore-existing --info=progress2 ~/Desktop/telegram/ cassiant@192.168.0.9:/srv/data/navidrome/music/telegram/
```

## 8. Test before cutover (LAN)

```sh
echo '192.168.0.9 music.cssnt.ru' | sudo tee -a /etc/hosts       # PC
```

- Open https://music.cssnt.ru → accept cert warning → create admin user → library scans.

```sh
curl -k -u telegram:<RCLONE_PASS> -T /path/test.mp3 https://music.cssnt.ru/upload/test.mp3   # 201
sudo sed -i '/music.cssnt.ru/d' /etc/hosts                         # PC
```

## 9. Cutover

- Main router: DMZ → `192.168.0.9` (was titan).

```sh
ssh sparkle 'sudo systemctl restart stack-traefik'                 # retry ACME now
ssh sparkle 'docker logs -f traefik'                               # cert obtained, no acme errors
curl -I https://music.cssnt.ru                                     # valid cert
```

- Telegram: send a track to bot → `✅ Added` → appears in Navidrome.
- If `music.cssnt.ru` fails from LAN → PC `/etc/hosts`: `192.168.0.9 music.cssnt.ru`.
- Rollback: main router DMZ → titan.

## 10. Backups (manual, from PC)

Script: `scripts/sparkle-backup.sh` (run on PC from repo root) → `~/Downloads/sparkle-<datetime>.tar.zst`.

```sh
scripts/sparkle-backup.sh
```

- Contents: `/srv/data` (music, Navidrome DB + snapshots, certs) + `/srv/secrets`.
- Navidrome DB snapshots kept: last 7 in `/srv/data/navidrome/backup`.
- Delete old archives in `~/Downloads` by hand.

Check archive:

```sh
tar -tf ~/Downloads/sparkle-<datetime>.tar.zst | head
```

Restore (same or new machine after 01 + this repo):

```sh
ssh sparkle 'sudo systemctl stop stack-navidrome stack-traefik'
zstd -dc ~/Downloads/sparkle-<datetime>.tar.zst | ssh sparkle 'sudo tar -C / -xpf -'
ssh sparkle 'sudo systemctl start stack-traefik stack-navidrome'
```

DB broken after restore:

```sh
ssh sparkle
sudo systemctl stop stack-navidrome
ls -t /srv/data/navidrome/backup | head -1                         # newest snapshot
sudo cp /srv/data/navidrome/backup/<newest> /srv/data/navidrome/data/navidrome.db
sudo rm -f /srv/data/navidrome/data/navidrome.db-wal /srv/data/navidrome/data/navidrome.db-shm
sudo chown 1000:100 /srv/data/navidrome/data/navidrome.db
sudo systemctl start stack-navidrome
```

## Daily use

```sh
sudo systemctl restart stack-navidrome                             # restart stack
cd /srv/config/stacks/navidrome && sudo docker compose pull && sudo systemctl restart stack-navidrome   # update images
docker logs -f navidrome
```

- Edit compose → commit → `nixos-rebuild switch` restarts changed stacks.
