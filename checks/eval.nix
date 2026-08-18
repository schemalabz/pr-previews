# Two-project synthetic host — must evaluate and build a toplevel.
{ nixpkgs, system, module }:
(nixpkgs.lib.nixosSystem {
  inherit system;
  modules = [
    module
    ({ pkgs, ... }: {
      services.pr-previews = {
        enable = true;
        projects.alpha = {
          hostPattern = "pr-@id@.preview.alpha.test";
          basePort = 3000;
          startScript = pkgs: ctx: ''
            cd "$APP_DIR"
            exec ${pkgs.python3}/bin/python3 -m http.server "$PORT"
          '';
        };
        projects.beta = {
          hostPattern = "beta-pr-@id@.preview.alpha.test";
          basePort = 4000;
          envFile = "/var/lib/beta.env";
          caddyBaseVirtualHost = true;
          cachix = { enable = true; name = "example"; publicKey = "example.cachix.org-1:AAAA"; };
          settings.linkedService.domain = "alpha.test";
          startScript = pkgs: ctx: ''
            export SIBLING_URL="${ctx.siblings.alpha.url}"
            exec ${pkgs.python3}/bin/python3 -m http.server "$PORT"
          '';
          createHook = pkgs: ctx: ''
            echo "creating beta preview $pr_num next to ${ctx.siblings.alpha.host}"
          '';
        };
      };
      # Minimal NixOS eval requirements
      fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
      boot.loader.grub.device = "/dev/sda";
      system.stateVersion = "24.11";
    })
  ];
}).config.system.build.toplevel
