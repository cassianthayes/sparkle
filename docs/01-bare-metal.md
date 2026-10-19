# 01 — Bare-metal NixOS (1 disk, ext4, UEFI, DHCP, SSH keys)

## 0. On your PC

```sh
ssh-keygen -t ed25519            # skip if ~/.ssh/id_ed25519 exists
curl https://github.com/cassianthayes.keys   # must list your key; else add it: GitHub → Settings → SSH keys
```

- Download NixOS **minimal** ISO (x86_64, unstable or latest): https://nixos.org/download
- Write USB (check device with `lsblk`):

```sh
sudo dd if=nixos-minimal-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

## 1. BIOS/UEFI

- UEFI: on, CSM/Legacy: off
- Secure Boot: off
- Virtualization (VT-x/AMD-V): on
- Restore on AC power loss: **Power On**
- Boot from USB

## 2. Installer

```sh
sudo passwd nixos                # temp password
ip -br a                         # note IP
```

From PC:

```sh
ssh nixos@<IP>
sudo -i
lsblk                            # confirm nvme0n1
mkdir -p /tmp/config && cd /tmp/config
```

## 3. Config files (`/tmp/config`)

`flake.nix`

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    ssh-keys = { url = "file+https://github.com/cassianthayes.keys"; flake = false; };
  };
  outputs = { nixpkgs, disko, ... }@inputs: {
    nixosConfigurations.sparkle = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        disko.nixosModules.disko
        ./disko.nix
        ./hardware-configuration.nix
        ./host.nix
      ];
    };
  };
}
```

`disko.nix` — disk: nvme0n1

```nix
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/nvme0n1";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
```

Password hash for console login:

```sh
nix --extra-experimental-features "nix-command flakes" shell nixpkgs#mkpasswd -c mkpasswd -m yescrypt
```

`host.nix` — set hash

```nix
{ pkgs, inputs, ... }: {
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "sparkle";
  networking.useDHCP = true;
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  time.timeZone = "Asia/Yekaterinburg";
  i18n.defaultLocale = "en_US.UTF-8";

  users.mutableUsers = false;
  users.users.cassiant = {
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

  systemd.tmpfiles.rules = [ "d /srv/data 0755 root root -" ];

  environment.systemPackages = with pkgs; [ git helix btop curl ];
  environment.variables.EDITOR = "hx";
  environment.variables.COLORTERM = "truecolor";
  environment.enableAllTerminfo = true;

  system.stateVersion = "26.11";
}
```

## 4. Partition + install

```sh
cd /tmp/config
nix --extra-experimental-features "nix-command flakes" \
  run github:nix-community/disko/latest -- --mode destroy,format,mount ./disko.nix
nixos-generate-config --no-filesystems --show-hardware-config > hardware-configuration.nix
mkdir -p /mnt/srv && cp -r /tmp/config /mnt/srv/config
nixos-install --flake /mnt/srv/config#sparkle --no-root-passwd
reboot                            # remove USB
```

## 5. First boot

- Router: DHCP reservation for server MAC.

From PC:

```sh
ssh cassiant@<IP>
sudo chown -R cassiant:users /srv/config
cd /srv/config
git config --global user.name "Cassiant Hayes"
git config --global user.email "cassianthayes@gmail.com"
git init -b main && git add -A && git commit -m "bare-metal base"
```

Push to a **private** GitHub repo (deploy key, never copy PC private key):

```sh
ssh-keygen -t ed25519 -C "sparkle" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
```

- GitHub: create private repo → Settings → Deploy keys → Add → paste → **Allow write access**.

```sh
git remote add origin git@github.com:cassianthayes/<repo>.git
git push -u origin main
```

## 6. Verify

```sh
systemctl --failed                                  # empty
ssh -o PubkeyAuthentication=no cassiant@<IP>           # from PC: must be denied
sudo iptables -S nixos-fw | grep dport               # only 22 open
```

## Daily use

```sh
cd /srv/config
git add -A                                          # flakes ignore untracked files
nixos-rebuild switch --flake .#sparkle --sudo
nix flake update && nixos-rebuild switch --flake .#sparkle --sudo   # updates
nix flake update ssh-keys && nixos-rebuild switch --flake .#sparkle --sudo   # after GitHub key change
```

- Keys are pinned in `flake.lock`; GitHub changes apply only after `nix flake update ssh-keys`.
- Broken boot: pick previous generation in systemd-boot menu.
