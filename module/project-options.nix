# Per-project options. The submodule is a function so defaults can use the
# project's attribute name (`name`).
{ name, lib, ... }:
with lib;
{
  options = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to generate infrastructure for this project.";
    };

    hostPattern = mkOption {
      type = types.str;
      example = "pr-@id@.preview.example.com";
      description = ''
        Hostname pattern for preview instances. `@id@` is replaced with the
        PR number. Keep it a single DNS label under the parent domain your
        wildcard certificate covers (`name-pr-@id@.parent`, never
        `pr-@id@.name.parent`).
      '';
    };

    basePort = mkOption {
      type = types.port;
      description = "Instance port = basePort + PR number.";
    };

    redirectFrom = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "pr-@id@.preview.old-domain.example" ];
      description = ''
        Legacy hostname patterns (same `@id@` substitution as hostPattern)
        kept answering during a domain move: each preview also gets vhosts on
        these names that 301-redirect to the current hostPattern. Remove
        after the migration settles.
      '';
    };

    previewsDir = mkOption {
      type = types.path;
      default = "/var/lib/${name}-previews";
      description = "Directory holding per-PR instance state (`pr-<N>/`).";
    };

    envFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Shared EnvironmentFile for all of this project's instances (API keys
        etc.). Never put fork-reachable secrets here — see the trust model.
      '';
    };

    environment = mkOption {
      type = types.listOf types.str;
      default = [ "NODE_ENV=production" "IS_PREVIEW=true" ];
      description = "systemd Environment= entries for instances.";
    };

    startScript = mkOption {
      type = types.raw;
      description = ''
        `hostPkgs: ctx: string` — shell body that starts the app. Runs with
        env vars PORT, PR_NUM, PR_DIR, APP_DIR set. See the ctx reference in
        the README.

        RUNTIME OWNERSHIP RULE: the application must run on the toolchain
        that built it. Exec an entrypoint produced by the app's own build
        (`exec "$APP_DIR/bin/start"`) — its closure carries the app's own
        runtime. Never launch the app via the `hostPkgs` argument
        (`''${hostPkgs.nodejs}/bin/node …` runs the HOST's Node, not the
        app's): the two nixpkgs coincide only by accident, and the skew
        surfaces as runtime errors that look like the PR's fault. Use
        `hostPkgs` only for host-side auxiliary tools.
      '';
    };

    createHook = mkOption {
      type = types.nullOr types.raw;
      default = null;
      description = ''
        `hostPkgs: ctx: string` — runs after store-path fetch + GC-rooted
        symlink, before service start. Shell vars: pr_num, pr_dir,
        store_path, port. Hooks run tooling, not the application — using
        `hostPkgs` here (psql, curl, jq…) is fine.
      '';
    };

    destroyHook = mkOption {
      type = types.nullOr types.raw;
      default = null;
      description = "`pkgs: ctx: string` — runs after service stop, before rm -rf of the instance dir.";
    };

    createSummary = mkOption {
      type = types.nullOr types.raw;
      default = null;
      description = "`pkgs: ctx: string` — extra lines printed after the create summary.";
    };

    createExtraArgs = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          usage = mkOption {
            type = types.lines;
            description = "Usage text for the extra flags.";
          };
          initScript = mkOption {
            type = types.lines;
            description = "Shell run before flag parsing (defaults).";
          };
          parseScript = mkOption {
            type = types.lines;
            description = "Extra `case` arms for flag parsing.";
          };
        };
      });
      default = null;
      description = "Inject extra flag parsing into the create script (e.g. --with-db).";
    };

    extraPackages = mkOption {
      type = types.raw;
      default = _: [ ];
      description = "`pkgs: [pkg]` — added to environment.systemPackages.";
    };

    extraSudoCommands = mkOption {
      type = types.nullOr types.raw;
      default = null;
      description = "`{ pkgs, serviceName }: [rule]` — extra sudo command entries for the preview user.";
    };

    caddyBaseVirtualHost = mkOption {
      type = types.bool;
      default = false;
      description = "Also serve a static informational vhost at the pattern's parent domain.";
    };

    cachix = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Trust a Cachix binary cache for substituting preview closures.";
      };
      name = mkOption {
        type = types.str;
        default = name;
        description = "Cachix cache name.";
      };
      publicKey = mkOption {
        type = types.str;
        default = "";
        description = "Cachix public key for signature verification.";
      };
    };

    settings = mkOption {
      type = types.submodule { freeformType = with types; attrsOf anything; };
      default = { };
      description = ''
        Free-form project settings, surfaced to script functions as
        ctx.cfg.settings (replaces dynamic option injection).
      '';
    };

    extraConfig = mkOption {
      type = types.nullOr types.raw;
      default = null;
      description = ''
        `{ config, lib, pkgs, cfg }: attrset` — arbitrary NixOS config merged
        into the system (e.g. an auxiliary per-PR database template unit).
      '';
    };
  };
}
