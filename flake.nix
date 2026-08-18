{
  description = "Self-hosted per-PR preview environments for NixOS — systemd + Caddy + your flake. No Docker, no Kubernetes.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      nixos-lib = import (nixpkgs + "/nixos/lib") { };
    in
    {
      nixosModules.pr-previews = ./module;
      nixosModules.default = self.nixosModules.pr-previews;

      checks.${system} = {
        eval = import ./checks/eval.nix {
          inherit nixpkgs system;
          module = self.nixosModules.default;
        };
        lifecycle = nixos-lib.runTest (import ./checks/lifecycle.nix {
          inherit pkgs;
          module = self.nixosModules.default;
        });
      };

      formatter.${system} = pkgs.nixfmt-rfc-style;
    };
}
