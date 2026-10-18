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
