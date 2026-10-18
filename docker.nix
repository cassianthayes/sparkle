{ config, lib, ... }:
let
  stacks = [ "traefik" "navidrome" "remnawave" ];
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
