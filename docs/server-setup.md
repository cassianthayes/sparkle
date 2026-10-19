# Self-hosting setup: one server with a public IP, run with Docker Compose

## Recommended stack

| Need | Choice | Why |
|---|---|---|
| Host OS, declarative | **NixOS** (flake in git) | The whole host is one config: firewall, SSH, Docker, backups and the units that start your stacks. Rebuilding on a new machine is one command. |
| Services | **Plain `compose.yml` per service** | Easy to move to another machine, works anywhere, and you can copy examples from upstream docs. |
| HTTP reverse proxy | **Traefik** | You route a container by adding labels to it. It can also pass TLS through by SNI on port 443, which you need for Remnawave/Xray. |
| Minecraft routing | **itzg/mc-router** | Routes by the hostname the player connects to, so many servers share port 25565. |
| Minecraft panel | **Pelican** (Pterodactyl fork) or **Crafty Controller** | See the Minecraft section. |
| Backups | **restic** to an off-site target (Hetzner Storage Box, B2), declared in NixOS | Backups are encrypted and deduplicated, and you can keep snapshots going back in time. |
| Secrets | **sops-nix** or **agenix** | Encrypted secrets can live in the same git repo as the config. |

If you don't want to learn Nix, use Debian with an Ansible playbook instead. It's less strict but follows the same idea.

## Layout: keep config and data separate

```
/srv/
  config/              ← git repo (flake + stacks); you only rebuild this
    flake.nix
    host.nix
    stacks/
      traefik/compose.yml
      navidrome/compose.yml
      remnawave/compose.yml
      minecraft/compose.yml
  data/                ← everything stateful; only this needs backing up
    navidrome/  remnawave/  minecraft/  traefik/acme.json
```

Every container uses bind mounts into `/srv/data/<service>`; avoid anonymous volumes.

To migrate: install NixOS from the flake (`nixos-anywhere` + `disko` lets you do this remotely), run `restic restore` into `/srv/data`, and the stacks come up on their own.

## Host config (NixOS sketch)

```nix
{ pkgs, lib, ... }:
let stacks = [ "traefik" "navidrome" "remnawave" "minecraft" ];
in {
  virtualisation.docker.enable = true;

  services.openssh = {
    enable = true;
    settings = { PasswordAuthentication = false; PermitRootLogin = "prohibit-password"; };
  };
  networking.firewall.allowedTCPPorts = [ 22 80 443 25565 ];

  # one systemd unit per compose stack
  systemd.services = lib.listToAttrs (map (name: {
    name = "stack-${name}";
    value = {
      after = [ "docker.service" "network-online.target" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        WorkingDirectory = "/srv/config/stacks/${name}";
        ExecStart = "${pkgs.docker}/bin/docker compose up -d --remove-orphans";
        ExecStop  = "${pkgs.docker}/bin/docker compose down";
      };
    };
  }) stacks);

  services.restic.backups.offsite = {
    paths = [ "/srv/data" ];
    repository = "sftp:u123@u123.your-storagebox.de:/backups";
    passwordFile = "/run/secrets/restic";
    timerConfig.OnCalendar = "03:00";
    pruneOpts = [ "--keep-daily 7" "--keep-weekly 4" "--keep-monthly 6" ];
    backupPrepareCommand = ''
      ${pkgs.docker}/bin/docker exec remnawave-db pg_dumpall -U postgres > /srv/data/remnawave/dump.sql
      ${pkgs.docker}/bin/docker exec mc-survival rcon-cli save-all flush || true
    '';
  };
}
```

**Docker's published ports bypass the host firewall.** Only Traefik and mc-router should publish ports. Every other service joins a shared `proxy` network and publishes nothing. If something must be published, bind it to `127.0.0.1:PORT:PORT`.

## Traefik (`stacks/traefik/compose.yml`)

```yaml
services:
  traefik:
    image: traefik:v3
    restart: unless-stopped
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=proxy
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.le.acme.tlschallenge=true
      - --certificatesresolvers.le.acme.email=you@example.com
      - --certificatesresolvers.le.acme.storage=/acme/acme.json
    ports: ["80:80", "443:443"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /srv/data/traefik:/acme
    networks: [proxy]
networks:
  proxy: { external: true }   # docker network create proxy (or declare it in a oneshot unit)
```

## Navidrome (`stacks/navidrome/compose.yml`)

```yaml
services:
  navidrome:
    image: deluan/navidrome:latest
    restart: unless-stopped
    volumes:
      - /srv/data/navidrome:/data
      - /srv/media/music:/music:ro
    networks: [proxy]
    labels:
      - traefik.enable=true
      - traefik.http.routers.navidrome.rule=Host(`music.example.com`)
      - traefik.http.routers.navidrome.tls.certresolver=le
      - traefik.http.services.navidrome.loadbalancer.server.port=4533
networks:
  proxy: { external: true }
```

## Remnawave

- **Panel:** set it up like Navidrome, behind Traefik on `panel.example.com`. Its Postgres and Redis go on an internal network only. Upstream recommends hiding the panel behind a secret path or cookie, or limiting it to your IP.
- **Node (Xray, VLESS Reality on 443) on the same box:** this clashes with Traefik, which also wants 443. Fix it with a Traefik **TCP router and TLS passthrough** by SNI:

  ```yaml
  labels:
    - traefik.enable=true
    - traefik.tcp.routers.xray.rule=HostSNI(`your-reality-sni.com`)
    - traefik.tcp.routers.xray.entrypoints=websecure
    - traefik.tcp.routers.xray.tls.passthrough=true
    - traefik.tcp.services.xray.loadbalancer.server.port=443
  ```

  Use `network_mode` or the `proxy` network so Traefik can reach the node. Xray then sees the raw TLS, so Reality keeps working, and all your other domains still go to the HTTP services.
- Running the panel and node on separate machines is cleaner, but this setup works on one.

## Minecraft (`stacks/minecraft/compose.yml`)

The Java protocol isn't HTTP, so Traefik can't route it. **mc-router** reads the hostname from the client's handshake instead:

```yaml
services:
  router:
    image: itzg/mc-router
    restart: unless-stopped
    ports: ["25565:25565"]
    command: --in-docker --auto-scale-up   # discovers servers via labels, can wake stopped ones
    volumes: ["/var/run/docker.sock:/var/run/docker.sock:ro"]

  survival:
    image: itzg/minecraft-server
    container_name: mc-survival
    environment: { EULA: "TRUE", TYPE: PAPER, VERSION: "1.21.4", MEMORY: 4G }
    volumes: ["/srv/data/minecraft/survival:/data"]
    labels: ["mc-router.host=survival.example.com"]

  creative:
    image: itzg/minecraft-server
    environment: { EULA: "TRUE", TYPE: FABRIC, MEMORY: 3G }
    volumes: ["/srv/data/minecraft/creative:/data"]
    labels: ["mc-router.host=creative.example.com"]
```

Players connect to `survival.example.com` and `creative.example.com`, both on the default port. Bedrock uses UDP and can't be routed by hostname, so each Bedrock server needs its own port.

**Choosing a panel:**

- **Declarative (matches your goal):** define servers with itzg in compose as above. For console, files and restarts, add a light UI such as **Crafty Controller**, or a web RCON tool. Servers stay defined in git.
- **Full hosting panel** (create servers in the UI, users, schedules, file manager): **Pelican Panel + Wings**, with the panel behind Traefik. Wings creates the containers itself, so those servers aren't in your compose files. Back up Wings' data directory, and point mc-router at Wings' ports with a static mapping (`--mapping survival.example.com=localhost:25566`).

Pick: **itzg + mc-router** if you're the only admin; **Pelican** if friends need to manage their own servers.

## Backups

- Use restic snapshots of `/srv/data`, with database dumps taken first (the `backupPrepareCommand` above).
- For Minecraft, you can add an `itzg/mc-backup` sidecar for more frequent world backups.
- Test a restore on a throwaway VM once. A backup you've never restored from may not work.

## Hardening for a public IP

- SSH with keys only. Optionally move it off port 22 or put it behind Tailscale or WireGuard.
- Only ports 80, 443 and 25565 open (plus any UDP ports you need).
- Use CrowdSec or fail2ban reading Traefik's logs, and `services.tailscale` for admin UIs you don't want public.
- Automatic updates: `system.autoUpgrade` for the host, and either Renovate on your stacks repo or `watchtower` in monitor-only mode for images.
