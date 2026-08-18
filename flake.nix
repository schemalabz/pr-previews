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

      templates.default = {
        path = ./templates/default;
        description = "App flake exporting a previews attrset";
      };

      packages.${system}.options-doc =
        let
          eval = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.default
              {
                fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
                boot.loader.grub.device = "/dev/sda";
                system.stateVersion = "24.11";
              }
            ];
          };
          doc = pkgs.nixosOptionsDoc {
            options = eval.options.services.pr-previews;
            transformOptions = opt: opt // {
              declarations = map (_: {
                url = "https://github.com/schemalabz/pr-previews/blob/main/module";
                name = "module";
              }) opt.declarations;
            };
          };
        in
        pkgs.runCommand "options.md" { } "cp ${doc.optionsCommonMark} $out";

      formatter.${system} = pkgs.nixfmt-rfc-style;
    };
}
