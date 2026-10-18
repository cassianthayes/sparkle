{ pkgs, inputs, ... }: {
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "sparkle";
  networking.useDHCP = true;
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 80 443 ];

  time.timeZone = "Asia/Yekaterinburg";
  i18n.defaultLocale = "en_US.UTF-8";

  users.mutableUsers = false;
  users.users.cassiant = {
    uid = 1000;
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword = "$y$j9T$h5xYmnt9MnT5QcLc9/zkZ0$ysimb18C4oWmQL8Tzgpyj2rEC03Cx6VQkE0BjbgiMd3";
    openssh.authorizedKeys.keyFiles = [ inputs.ssh-keys ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.trusted-users = [ "@wheel" ];
  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 14d"; };
  nix.optimise.automatic = true;

  hardware.enableRedistributableFirmware = true;
  zramSwap.enable = true;
  services.fstrim.enable = true;

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
  environment.variables.EDITOR = "hx";
  environment.variables.COLORTERM = "truecolor";
  environment.enableAllTerminfo = true;

  system.stateVersion = "26.11";
}
