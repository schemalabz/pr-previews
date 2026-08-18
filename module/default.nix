# services.pr-previews — generic per-PR preview environments.
# One module instance owns shared infrastructure (user, Nix/Cachix trust,
# Caddy base, GC); each entry in `projects` generates a port-keyed systemd
# template unit, management scripts, Caddy vhost drop-ins, and sudo rules.
# Instances are created imperatively by the generated scripts — no rebuild
# per preview.
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.pr-previews;
  enabledProjects = filterAttrs (_: p: p.enable) cfg.projects;

  # "pr-@id@.preview.example.com" -> "preview.example.com"
  baseDomainOf = pattern:
    concatStringsSep "." (tail (splitString "." (replaceStrings [ "@id@" ] [ "0" ] pattern)));
in
{
  options.services.pr-previews = {
    enable = mkEnableOption "per-PR preview environments";

    user = mkOption {
      type = types.str;
      default = "preview";
      description = "Shared system user that owns all preview instances.";
    };

    group = mkOption {
      type = types.str;
      default = "preview";
      description = "Group of the shared preview user.";
    };

    projects = mkOption {
      type = types.attrsOf (types.submodule (import ./project-options.nix));
      default = { };
      description = "Preview projects — one entry per deployable app.";
    };
  };

  config = mkIf (cfg.enable && enabledProjects != { }) (mkMerge (
    [
      {
        assertions =
          (mapAttrsToList (name: _: {
            assertion = builtins.match "[a-z][a-z0-9-]*" name != null;
            message = "services.pr-previews: project name '${name}' must be a lowercase DNS-safe label ([a-z][a-z0-9-]*).";
          }) enabledProjects)
          ++ (mapAttrsToList (name: p: {
            assertion = hasInfix "@id@" p.hostPattern;
            message = "services.pr-previews.projects.${name}.hostPattern must contain '@id@'.";
          }) enabledProjects)
          ++ [{
            assertion =
              let ports = mapAttrsToList (_: p: p.basePort) enabledProjects;
              in unique ports == ports;
            message = "services.pr-previews: basePort values must be unique across projects.";
          }];

        users.users.${cfg.user} = {
          isSystemUser = true;
          group = cfg.group;
          home = "/var/lib/pr-previews";
          createHome = true;
          shell = pkgs.bash;
        };
        users.groups.${cfg.group} = { };

        nix.settings.experimental-features = [ "nix-command" "flakes" ];
        nix.settings.trusted-users = [ "root" cfg.user ];

        # Weekly GC is safe because every instance holds a GC root
        # (registered by the create script, released on destroy).
        nix.gc = {
          automatic = mkDefault true;
          dates = mkDefault "weekly";
          options = mkDefault "--delete-older-than 30d";
        };

        networking.firewall.allowedTCPPorts = [ 80 443 ];

        services.caddy = {
          enable = true;
          extraConfig = ''
            import /etc/caddy/conf.d/*
          '';
        };

        systemd.tmpfiles.rules = [ "d /etc/caddy/conf.d 0755 caddy caddy -" ];

        environment.systemPackages = [ pkgs.git pkgs.cachix pkgs.curl pkgs.jq ];
      }
    ]
    # Per-project config blocks are appended here by Tasks 3-6.
  ));
}
