# generic-preview.nix — Generic PR preview module generator.
#
# Takes a preview config attrset and returns a NixOS module that provides
# all the infrastructure for PR preview deployments: systemd services,
# management scripts, Caddy reverse proxy, user/group, Nix/Cachix settings.
#
# Usage in nix-openclaw/flake.nix:
#   modules = [
#     (import ./generic-preview.nix opencouncil.preview)
#     (import ./generic-preview.nix opencouncil-tasks.preview)
#   ];
#
# ## Preview config interface
#
# Each repo exports a `preview` attrset from its flake outputs:
#
#   preview = {
#     # ── Required ──────────────────────────────────────────────────────
#     name              : string   — service/script prefix (e.g. "opencouncil")
#     domain            : string   — preview subdomain base (e.g. "preview.opencouncil.gr")
#     defaultBasePort   : int      — port = basePort + prNum (e.g. 3000)
#     mkStartScript     : pkgs -> { port, prNum, prDir, appDir, cfg } -> string
#                         Shell script body to start the app.
#
#     # ── Optional hooks ────────────────────────────────────────────────
#     mkCreateHook      : pkgs -> { prNum, prDir, storePath, port, cfg } -> string
#                         Runs after store-path fetch + symlink, before service start.
#     mkCreateSummary   : pkgs -> { prNum, prDir, port, cfg } -> string
#                         Extra lines printed after the "Preview created" summary.
#     mkDestroyHook     : pkgs -> { prNum, prDir, port, cfg } -> string
#                         Runs after service stop, before rm -rf.
#
#     # ── Optional: extra create-script arguments ───────────────────────
#     createExtraArgs   : { usage : string, initScript : string, parseScript : string }
#                         Inject extra flag parsing into the create script.
#
#     # ── Optional overrides ────────────────────────────────────────────
#     environment       : [string]   — systemd Environment= entries
#                                      (default: ["NODE_ENV=production" "IS_PREVIEW=true"])
#     extraPackages     : pkgs -> [package]  — added to environment.systemPackages
#     extraOptions      : lib -> attrset     — additional NixOS options under services.<name>-preview
#     extraConfig       : { config, lib, pkgs, cfg } -> attrset  — merged into module config
#     extraSudoCommands : { pkgs, serviceName } -> [attrset]     — additional sudo rule entries
#     caddyBaseVirtualHost : bool   — add a virtualHost for the base domain (default: false)
#
#     # ── Cachix defaults ───────────────────────────────────────────────
#     cachix.defaultName      : string
#     cachix.defaultPublicKey : string
#   };

previewConfig:

{ config, lib, pkgs, ... }:

with lib;

let
  pc = previewConfig;
  serviceName = "${pc.name}-preview";
  cfg = config.services.${serviceName};

  hasCreateHook = pc ? mkCreateHook;
  hasDestroyHook = pc ? mkDestroyHook;
  hasCreateSummary = pc ? mkCreateSummary;
  hasCreateExtraArgs = pc ? createExtraArgs;
  hasExtraOptions = pc ? extraOptions;
  hasExtraConfig = pc ? extraConfig;
  hasExtraSudoCommands = pc ? extraSudoCommands;
  hasExtraPackages = pc ? extraPackages;

  environment = if pc ? environment then pc.environment
                else [ "NODE_ENV=production" "IS_PREVIEW=true" ];

  caddyBaseVirtualHost = pc.caddyBaseVirtualHost or false;

  # Script that starts the app — provided by the consuming repo
  startScript = pkgs.writeShellScript "${serviceName}-start" ''
    set -euo pipefail
    PORT="$1"
    PR_NUM=$((PORT - ${toString cfg.basePort}))
    PR_DIR="${cfg.previewsDir}/pr-$PR_NUM"
    APP_DIR="$PR_DIR/app"
    if [ ! -L "$APP_DIR" ] && [ ! -d "$APP_DIR" ]; then
      echo "Error: app not found at $APP_DIR" >&2
      exit 1
    fi
    ${pc.mkStartScript pkgs { port = "$PORT"; prNum = "$PR_NUM"; prDir = "$PR_DIR"; appDir = "$APP_DIR"; inherit cfg; }}
  '';

  # Create script
  createScript = pkgs.writeShellScriptBin "${serviceName}-create" ''
    set -euo pipefail

    ${if hasCreateExtraArgs then ''
    usage() {
      echo "Usage: ${serviceName}-create <pr-number> <nix-store-path> [options]"
      echo ""
      echo "${pc.createExtraArgs.usage}"
    }

    if [ $# -lt 2 ]; then
      usage >&2
      exit 1
    fi

    pr_num="$1"
    store_path="$2"
    shift 2

    ${pc.createExtraArgs.initScript}

    for arg in "$@"; do
      case "$arg" in
        --help|-h) usage; exit 0 ;;
        ${pc.createExtraArgs.parseScript}
        *) echo "Unknown argument: $arg" >&2; usage >&2; exit 1 ;;
      esac
    done
    '' else ''
    if [ $# -ne 2 ]; then
      echo "Usage: ${serviceName}-create <pr-number> <nix-store-path>" >&2
      exit 1
    fi

    pr_num="$1"
    store_path="$2"
    ''}

    port=$((${toString cfg.basePort} + pr_num))
    pr_dir="${cfg.previewsDir}/pr-$pr_num"

    # Fetch store path if not already local
    if [ ! -d "$store_path" ]; then
      echo "Fetching $store_path from binary cache..."
      nix-store --realise "$store_path" || {
        echo "Error: could not fetch store path: $store_path" >&2
        exit 1
      }
    fi

    # Create per-PR directory and symlink to the build
    mkdir -p "$pr_dir"
    ln -sfn "$store_path" "$pr_dir/app"
    chown -R ${cfg.user}:${cfg.group} "$pr_dir"

    echo "Creating preview for PR #$pr_num on port $port"
    echo "  App: $store_path"

    ${optionalString hasCreateHook
      (pc.mkCreateHook pkgs { prNum = "$pr_num"; prDir = "$pr_dir"; storePath = "$store_path"; port = "$port"; inherit cfg; })}

    # Stop existing service if running, then start fresh
    systemctl stop "${serviceName}@$port" 2>/dev/null || true
    systemctl start "${serviceName}@$port"

    # Add Caddy reverse proxy config
    # Clean up any legacy config files (pre-generic-preview naming)
    for legacy in "/etc/caddy/conf.d/pr-$pr_num.conf" "/etc/caddy/conf.d/tasks-pr-$pr_num.conf"; do
      [ -f "$legacy" ] && rm "$legacy"
    done
    config_file="/etc/caddy/conf.d/${pc.name}-pr-$pr_num.conf"
    mkdir -p /etc/caddy/conf.d

    cat > "$config_file" <<CADDYEOF
    pr-$pr_num.${cfg.previewDomain} {
      reverse_proxy localhost:$port {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
      }
    }
    CADDYEOF

    echo "Added Caddy config at $config_file"
    systemctl reload caddy

    echo ""
    echo "Preview created successfully"
    echo "  Local: http://localhost:$port"
    echo "  Public: https://pr-$pr_num.${cfg.previewDomain}"
    echo "  Service: ${serviceName}@$port"
    ${optionalString hasCreateSummary
      (pc.mkCreateSummary pkgs { prNum = "$pr_num"; prDir = "$pr_dir"; port = "$port"; inherit cfg; })}
  '';

  # Destroy script
  destroyScript = pkgs.writeShellScriptBin "${serviceName}-destroy" ''
    set -euo pipefail

    if [ $# -ne 1 ]; then
      echo "Usage: ${serviceName}-destroy <pr-number>" >&2
      exit 1
    fi

    pr_num="$1"
    port=$((${toString cfg.basePort} + pr_num))
    pr_dir="${cfg.previewsDir}/pr-$pr_num"

    echo "Destroying preview for PR #$pr_num (port $port)"

    # Stop app service
    systemctl stop "${serviceName}@$port" || true

    ${optionalString hasDestroyHook
      (pc.mkDestroyHook pkgs { prNum = "$pr_num"; prDir = "$pr_dir"; port = "$port"; inherit cfg; })}

    # Remove per-PR directory
    if [ -d "$pr_dir" ]; then
      rm -rf "$pr_dir"
    fi

    # Remove Caddy config (check both new and legacy filenames)
    caddy_changed=false
    for cf in "/etc/caddy/conf.d/${pc.name}-pr-$pr_num.conf" \
              "/etc/caddy/conf.d/pr-$pr_num.conf" \
              "/etc/caddy/conf.d/tasks-pr-$pr_num.conf"; do
      if [ -f "$cf" ]; then
        rm "$cf"
        echo "Removed Caddy config: $cf"
        caddy_changed=true
      fi
    done
    if [ "$caddy_changed" = "true" ]; then
      systemctl reload caddy
    fi

    echo "Preview destroyed"
  '';

  # List script
  listScript = pkgs.writeShellScriptBin "${serviceName}-list" ''
    set -euo pipefail

    echo "Active ${pc.name} preview instances:"
    echo ""
    systemctl list-units "${serviceName}@*" --all --no-pager
    echo ""
    echo "Deployed builds:"
    for pr_dir in ${cfg.previewsDir}/pr-*; do
      if [ -d "$pr_dir" ]; then
        pr_name="$(basename "$pr_dir")"
        app_link="$pr_dir/app"
        if [ -L "$app_link" ]; then
          echo "  $pr_name -> $(readlink "$app_link")"
        else
          echo "  $pr_name (no app symlink)"
        fi
      fi
    done
  '';

  # Logs script
  logsScript = pkgs.writeShellScriptBin "${serviceName}-logs" ''
    set -euo pipefail

    if [ $# -lt 1 ]; then
      echo "Usage: ${serviceName}-logs <pr-number> [journalctl args...]" >&2
      echo "Example: ${serviceName}-logs 123" >&2
      echo "Example: ${serviceName}-logs 123 -n 50" >&2
      exit 1
    fi

    pr_num="$1"
    shift
    port=$((${toString cfg.basePort} + pr_num))

    if [ $# -eq 0 ]; then
      exec journalctl -u "${serviceName}@$port" -f
    else
      exec journalctl -u "${serviceName}@$port" "$@"
    fi
  '';

in {
  options.services.${serviceName} = {
    enable = mkEnableOption "${pc.name} preview deployments";

    previewsDir = mkOption {
      type = types.path;
      default = "/var/lib/${serviceName}s";
      description = "Directory to store preview instances";
    };

    user = mkOption {
      type = types.str;
      default = "opencouncil";
      description = "User to run preview services";
    };

    group = mkOption {
      type = types.str;
      default = "opencouncil";
      description = "Group to run preview services";
    };

    basePort = mkOption {
      type = types.int;
      default = pc.defaultBasePort;
      description = "Base port for preview instances (PR number will be added)";
    };

    envFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to an environment file with shared runtime env vars (API keys, storage config, etc.)";
    };

    previewDomain = mkOption {
      type = types.str;
      default = pc.domain;
      description = "Domain for preview subdomains (pr-N.<domain>)";
    };

    createUser = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to create the system user and group. Set to false if another
        preview module with the same user is already creating it.
      '';
    };

    cachix = {
      enable = mkEnableOption "Cachix binary cache";
      cacheName = mkOption {
        type = types.str;
        default = (pc.cachix or {}).defaultName or pc.name;
        description = "Cachix cache name";
      };
      publicKey = mkOption {
        type = types.str;
        default = (pc.cachix or {}).defaultPublicKey or "";
        description = "Cachix public key for signature verification";
      };
    };
  } // (if hasExtraOptions then pc.extraOptions lib else {});

  config = mkIf cfg.enable (mkMerge [
    {
      # User and group (only create if createUser is true — set to false when
      # another preview module sharing the same user already creates it)
      users.users.${cfg.user} = mkIf cfg.createUser {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.previewsDir;
        createHome = true;
        shell = pkgs.bash;
      };

      users.groups.${cfg.group} = mkIf cfg.createUser {};

      # Ensure preview directory exists
      systemd.tmpfiles.rules = [
        "d ${cfg.previewsDir} 0755 ${cfg.user} ${cfg.group} -"
        "d /etc/caddy/conf.d 0755 caddy caddy -"
      ];

      # Nix settings
      nix.settings.experimental-features = [ "nix-command" "flakes" ];
      nix.settings.trusted-users = [ "root" cfg.user ];

      # Cachix binary cache
      nix.settings.substituters = mkIf cfg.cachix.enable [
        "https://cache.nixos.org"
        "https://${cfg.cachix.cacheName}.cachix.org"
      ];
      nix.settings.trusted-public-keys = mkIf cfg.cachix.enable [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        cfg.cachix.publicKey
      ];

      # Automatic garbage collection
      nix.gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 30d";
      };

      # Networking
      networking.firewall.allowedTCPPorts = [ 80 443 ];

      # Caddy reverse proxy
      services.caddy = {
        enable = true;
        extraConfig = ''
          import /etc/caddy/conf.d/*
        '';
      };

      # Optional: base domain virtualHost
      services.caddy.virtualHosts = mkIf caddyBaseVirtualHost {
        "${cfg.previewDomain}" = {
          extraConfig = ''
            respond "${pc.name} PR Preview Host - Active previews managed dynamically" 200
          '';
        };
      };

      # Sudo rules
      security.sudo.extraRules = [
        {
          users = [ cfg.user ];
          commands =
            [
              { command = "${pkgs.systemd}/bin/systemctl start ${serviceName}@*"; options = [ "NOPASSWD" ]; }
              { command = "${pkgs.systemd}/bin/systemctl stop ${serviceName}@*"; options = [ "NOPASSWD" ]; }
              { command = "${pkgs.systemd}/bin/systemctl enable ${serviceName}@*"; options = [ "NOPASSWD" ]; }
              { command = "${pkgs.systemd}/bin/systemctl disable ${serviceName}@*"; options = [ "NOPASSWD" ]; }
              { command = "${pkgs.systemd}/bin/systemctl status ${serviceName}@*"; options = [ "NOPASSWD" ]; }
              { command = "${pkgs.systemd}/bin/systemctl reload caddy"; options = [ "NOPASSWD" ]; }
              { command = "/run/current-system/sw/bin/${serviceName}-create"; options = [ "NOPASSWD" ]; }
              { command = "/run/current-system/sw/bin/${serviceName}-destroy"; options = [ "NOPASSWD" ]; }
            ]
            ++ (if hasExtraSudoCommands
                then pc.extraSudoCommands { inherit pkgs serviceName; }
                else []);
        }
      ];

      # Systemd template service
      systemd.services."${serviceName}@" = {
        description = "${pc.name} preview instance on port %i";
        after = [ "network.target" ];

        serviceConfig = {
          Type = "simple";
          User = cfg.user;
          Group = cfg.group;
          Environment = environment ++ [ "PORT=%i" ];
          EnvironmentFile = mkIf (cfg.envFile != null) cfg.envFile;
          ExecStart = "${startScript} %i";
          Restart = "on-failure";
          RestartSec = "5s";

          # Security hardening
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ReadWritePaths = [ cfg.previewsDir ];
        };
      };

      # Management scripts + common utilities
      environment.systemPackages = [
        pkgs.git
        pkgs.cachix
        pkgs.curl
        pkgs.jq
        createScript
        destroyScript
        listScript
        logsScript
      ] ++ (if hasExtraPackages then pc.extraPackages pkgs else []);
    }

    # Merge any extra NixOS config from the preview config
    (if hasExtraConfig
     then pc.extraConfig { inherit config lib pkgs cfg; }
     else {})
  ]);
}
