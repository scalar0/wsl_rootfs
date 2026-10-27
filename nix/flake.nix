{
  description = "Ubuntu WSL development tools and public settings";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      profile = builtins.fromJSON (builtins.readFile ./profile.json);
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg:
          builtins.elem (nixpkgs.lib.getName pkg) [ "1password-cli" ];
      };
      vendor = import ./vendor.nix { inherit pkgs; };
      catalog = import ./packages.nix { inherit pkgs profile vendor; };
      home = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = { inherit profile catalog; };
        modules = [ ./home.nix ];
      };
    in {
      homeConfigurations.${profile.username} = home;
      packages.${system} = {
        default = home.activationPackage;
        catalog = pkgs.writeText "wsl-rootfs-catalog.json" (builtins.toJSON catalog.metadata);
      };
      checks.${system}.home = home.activationPackage;
      devShells.${system}.default = pkgs.mkShell {
        packages = (with pkgs; [ nix just jq shellcheck shfmt ]) ++ [ vendor.uv ];
      };
    };
}
