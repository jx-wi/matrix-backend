{
  description = "matrix backend";
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.11";
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = {
    nixpkgs,
    lanzaboote,
    sops-nix,
    ...
  }:
  {
    nixosConfigurations.matrix-backend = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hardware-configuration.nix
        ./configuration.nix
        lanzaboote.nixosModules.lanzaboote
        sops-nix.nixosModules.sops
      ];
    };
  };
}
