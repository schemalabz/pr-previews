# Parity harness: builds two toplevels — the April function-generator module
# and the new options module — configured equivalently for one
# opencouncil-shaped project, for diffing generated artifacts.
#
# Usage:
#   nix build -f dev/parity.nix april -o result-april
#   nix build -f dev/parity.nix new -o result-new
let
  flake = builtins.getFlake (toString ../.);
  nixpkgs = flake.inputs.nixpkgs;
  system = "x86_64-linux";

  shaped = rec {
    name = "opencouncil";
    domain = "preview.opencouncil.gr";
    basePort = 3000;
    startBody = pkgs: ''
      cd "$APP_DIR"
      exec ${pkgs.nodejs}/bin/node server.js
    '';
  };

  base = {
    fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
    boot.loader.grub.device = "/dev/sda";
    system.stateVersion = "24.11";
  };

  april = (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      (import ../checks/fixtures/april-generic-preview.nix {
        name = shaped.name;
        domain = shaped.domain;
        defaultBasePort = shaped.basePort;
        mkStartScript = pkgs: ctx: shaped.startBody pkgs;
      })
      ({ ... }: { services.opencouncil-preview.enable = true; } // base)
    ];
  }).config.system.build.toplevel;

  new = (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      flake.nixosModules.default
      ({ pkgs, ... }: {
        services.pr-previews = {
          enable = true;
          user = "opencouncil";
          group = "opencouncil";
          projects.opencouncil = {
            hostPattern = "pr-@id@.${shaped.domain}";
            basePort = shaped.basePort;
            startScript = pkgs: ctx: shaped.startBody pkgs;
          };
        };
      } // base)
    ];
  }).config.system.build.toplevel;
in
{ inherit april new; }
