# services.pr-previews — generic per-PR preview environments.
# One module instance owns shared infrastructure (user, Nix/Cachix trust,
# Caddy base, GC); each entry in `projects` generates a port-keyed systemd
# template unit, management scripts, Caddy vhost drop-ins, and sudo rules.
# Instances are created imperatively by the generated scripts — no rebuild
# per preview.
#
# Module-system constraint encoded here: every top-level config attribute is
# static; per-project fan-out happens INSIDE each attribute (mapAttrs'/
# concatLists), never by building the mkMerge list from config. This is also
# why `extraConfig` contributions are merged per known namespace (see
# `extraOf` below) instead of as whole config documents.
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.pr-previews;
  enabledProjects = filterAttrs (_: p: p.enable) cfg.projects;

  # "pr-@id@.preview.example.com" -> "preview.example.com"
  baseDomainOf = pattern:
    concatStringsSep "." (tail (splitString "." (replaceStrings [ "@id@" ] [ "0" ] pattern)));

  projectCtxCfg = project: project // { inherit (cfg) user group; };

  # extraConfig results are merged per top-level namespace. Supported
  # namespaces: systemd, environment, security, users, networking, nix.
  # NOT `services`: this module's own options live under `services`, so
  # making that namespace's merge structure depend on cfg.projects would be
  # self-referential (infinite recursion). Static top-level structure is a
  # module-system requirement.
  extraOf = ns:
    mapAttrsToList
      (name: project:
        if project.extraConfig == null then { }
        else
          (project.extraConfig {
            inherit config lib pkgs;
            cfg = projectCtxCfg project;
          }).${ns} or { })
      enabledProjects;

  forEachProject = f: mapAttrsToList f enabledProjects;
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

  config = mkIf (cfg.enable && enabledProjects != { }) {
    assertions =
      (forEachProject (name: _: {
        assertion = builtins.match "[a-z][a-z0-9-]*" name != null;
        message = "services.pr-previews: project name '${name}' must be a lowercase DNS-safe label ([a-z][a-z0-9-]*).";
      }))
      ++ (forEachProject (name: p: {
        assertion = hasInfix "@id@" p.hostPattern;
        message = "services.pr-previews.projects.${name}.hostPattern must contain '@id@'.";
      }))
      ++ [{
        assertion =
          let ports = mapAttrsToList (_: p: p.basePort) enabledProjects;
          in unique ports == ports;
        message = "services.pr-previews: basePort values must be unique across projects.";
      }]
      ++ (forEachProject (name: p: {
        assertion = p.extraConfig == null ||
          !((p.extraConfig { inherit config lib pkgs; cfg = projectCtxCfg p; }) ? services);
        message = "services.pr-previews.projects.${name}.extraConfig may not set `services.*` (supported namespaces: systemd, environment, security, users, networking, nix). Use the module's typed options for Caddy behavior.";
      }));

    users = mkMerge ([
      {
        users.${cfg.user} = {
          isSystemUser = true;
          group = cfg.group;
          home = "/var/lib/pr-previews";
          createHome = true;
          shell = pkgs.bash;
        };
        groups.${cfg.group} = { };
      }
    ] ++ extraOf "users");

    nix = mkMerge ([
      {
        settings = {
          experimental-features = [ "nix-command" "flakes" ];
          trusted-users = [ "root" cfg.user ];
          # unique: projects sharing one cache must not duplicate entries
          substituters = unique (concatLists (forEachProject (_: p:
            optionals p.cachix.enable [ "https://${p.cachix.name}.cachix.org" ])));
          trusted-public-keys = unique (concatLists (forEachProject (_: p:
            optionals p.cachix.enable [ p.cachix.publicKey ])));
        };
        # Weekly GC is safe because every instance holds a GC root
        # (registered by the create script, released on destroy).
        gc = {
          automatic = mkDefault true;
          dates = mkDefault "weekly";
          options = mkDefault "--delete-older-than 30d";
        };
      }
    ] ++ extraOf "nix");

    networking = mkMerge ([
      { firewall.allowedTCPPorts = [ 80 443 ]; }
    ] ++ extraOf "networking");

    # Direct static path — never a namespace-level merge over cfg.projects
    # here (self-reference, see header comment).
    services.caddy = {
      enable = true;
      extraConfig = ''
        import /etc/caddy/conf.d/*
      '';
      virtualHosts = mkMerge (forEachProject (name: p:
        optionalAttrs p.caddyBaseVirtualHost {
          "${baseDomainOf p.hostPattern}" = {
            extraConfig = ''
              respond "${name} PR Preview Host - Active previews managed dynamically" 200
            '';
          };
        }));
    };

    systemd = mkMerge ([
      {
        tmpfiles.rules =
          [ "d /etc/caddy/conf.d 0755 caddy caddy -" ]
          ++ forEachProject (_: p:
            "d ${p.previewsDir} 0755 ${cfg.user} ${cfg.group} -");

        services = mapAttrs'
          (name: project:
            let
              serviceName = "${name}-preview";
              # Placeholder until Task 4 wires the real start script:
              startScript = pkgs.writeShellScript "${serviceName}-start-placeholder" "exit 1";
            in
            nameValuePair "${serviceName}@" (import ./service.nix {
              inherit lib name project startScript;
              topCfg = cfg;
            }))
          enabledProjects;
      }
    ] ++ extraOf "systemd");

    environment = mkMerge ([
      { systemPackages = [ pkgs.git pkgs.cachix pkgs.curl pkgs.jq ]; }
    ] ++ extraOf "environment");

    security = mkMerge ([ { } ] ++ extraOf "security");
  };
}
