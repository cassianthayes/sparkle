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
