# Generates the per-project management scripts. All scripts are
# writeShellApplication (build-time shellcheck). Parity note: flow, output
# text, and shell variable names match the pre-extraction module — app hooks
# depend on pr_num/pr_dir/store_path/port (create/destroy) and
# PORT/PR_NUM/PR_DIR/APP_DIR (start).
{ pkgs, lib, name, project, topCfg, allProjects }:
with lib;
let
  serviceName = "${name}-preview";

  # "@id@" -> a shell expansion of the given variable name.
  substHost = pattern: idVar: replaceStrings [ "@id@" ] [ "\${${idVar}}" ] pattern;
  hostFor = idVar: substHost project.hostPattern idVar;

  # 301-redirect vhosts for legacy hostnames during a domain move.
  redirectBlocks = concatMapStrings (pattern: ''

    ${substHost pattern "pr_num"} {
      redir https://${hostFor "pr_num"}{uri} 301
    }'') project.redirectFrom;

  siblingsFor = idVar: mapAttrs
    (sname: sp: rec {
      port = "$((${toString sp.basePort} + ${idVar}))";
      host = replaceStrings [ "@id@" ] [ "\${${idVar}}" ] sp.hostPattern;
      url = "https://${host}";
    })
    (removeAttrs allProjects [ name ]);

  ctxCfg = project // { inherit (topCfg) user group; };

  mkCtx = { idVar, portVar, dirVar }: {
    id = "\$${idVar}";
    prNum = "\$${idVar}"; # April-compat alias
    port = "\$${portVar}";
    dir = "\$${dirVar}";
    prDir = "\$${dirVar}"; # April-compat alias
    host = hostFor idVar;
    url = "https://${hostFor idVar}";
    cfg = ctxCfg;
    siblings = siblingsFor idVar;
  };

  startCtx = mkCtx { idVar = "PR_NUM"; portVar = "PORT"; dirVar = "PR_DIR"; }
    // { appDir = "$APP_DIR"; };
  hookCtx = mkCtx { idVar = "pr_num"; portVar = "port"; dirVar = "pr_dir"; };
  createCtx = hookCtx // { storePath = "$store_path"; };

  # SC1091 (info): app-provided fragments may source runtime files
  # (per-instance env overrides) that shellcheck cannot follow — inherent
  # to this domain, excluded everywhere.
  mkScript = scriptName: text: pkgs.writeShellApplication {
    name = scriptName;
    runtimeInputs = [ pkgs.nix pkgs.systemd pkgs.coreutils ];
    excludeShellChecks = [ "SC1091" ];
    inherit text;
  };
in
{
  start = pkgs.writeShellApplication {
    name = "${serviceName}-start";
    runtimeInputs = [ pkgs.coreutils ];
    excludeShellChecks = [ "SC1091" ];
    text = ''
      PORT="$1"
      PR_NUM=$((PORT - ${toString project.basePort}))
      PR_DIR="${project.previewsDir}/pr-$PR_NUM"
      APP_DIR="$PR_DIR/app"
      if [ ! -L "$APP_DIR" ] && [ ! -d "$APP_DIR" ]; then
        echo "Error: app not found at $APP_DIR" >&2
        exit 1
      fi
      ${project.startScript pkgs startCtx}
    '';
  };

  create = mkScript "${serviceName}-create" ''
    ${if project.createExtraArgs != null then ''
      usage() {
        echo "Usage: ${serviceName}-create <pr-number> <nix-store-path> [options]"
        echo ""
        echo "${project.createExtraArgs.usage}"
      }

      if [ $# -lt 2 ]; then
        usage >&2
        exit 1
      fi

      pr_num="$1"
      store_path="$2"
      shift 2

      ${project.createExtraArgs.initScript}

      for arg in "$@"; do
        case "$arg" in
          --help|-h) usage; exit 0 ;;
          ${project.createExtraArgs.parseScript}
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

    port=$((${toString project.basePort} + pr_num))
    pr_dir="${project.previewsDir}/pr-$pr_num"

    mkdir -p "$pr_dir"

    # Fetch the closure (no-op if local) and register $pr_dir/app as an
    # indirect GC root in one step. This is what protects live previews
    # from the weekly nix-gc.
    rm -f "$pr_dir/app"
    nix-store --realise "$store_path" --add-root "$pr_dir/app" --indirect >/dev/null || {
      echo "Error: could not fetch store path: $store_path" >&2
      exit 1
    }
    chown -R ${topCfg.user}:${topCfg.group} "$pr_dir"

    echo "Creating preview for PR #$pr_num on port $port"
    echo "  App: $store_path"

    ${optionalString (project.createHook != null) (project.createHook pkgs createCtx)}

    # Stop existing service if running, then start fresh
    systemctl stop "${serviceName}@$port" 2>/dev/null || true
    systemctl start "${serviceName}@$port"

    # Add Caddy reverse proxy config.
    # Clean up any legacy config files (pre-generic-preview naming).
    for legacy in "/etc/caddy/conf.d/pr-$pr_num.conf" "/etc/caddy/conf.d/tasks-pr-$pr_num.conf"; do
      [ -f "$legacy" ] && rm "$legacy"
    done
    config_file="/etc/caddy/conf.d/${name}-pr-$pr_num.conf"
    mkdir -p /etc/caddy/conf.d

    cat > "$config_file" <<CADDYEOF
    ${hostFor "pr_num"} {
      reverse_proxy localhost:$port {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
      }
    }${redirectBlocks}
    CADDYEOF

    echo "Added Caddy config at $config_file"
    systemctl reload caddy

    echo ""
    echo "Preview created successfully"
    echo "  Local: http://localhost:$port"
    echo "  Public: https://${hostFor "pr_num"}"
    echo "  Service: ${serviceName}@$port"
    ${optionalString (project.createSummary != null) (project.createSummary pkgs hookCtx)}
  '';

  destroy = mkScript "${serviceName}-destroy" ''
    if [ $# -ne 1 ]; then
      echo "Usage: ${serviceName}-destroy <pr-number>" >&2
      exit 1
    fi

    pr_num="$1"
    port=$((${toString project.basePort} + pr_num))
    pr_dir="${project.previewsDir}/pr-$pr_num"

    echo "Destroying preview for PR #$pr_num (port $port)"

    systemctl stop "${serviceName}@$port" || true
    # Node apps often exit non-zero on SIGTERM, leaving the unit in "failed"
    # state after an intentional stop — clear it so destroyed previews don't
    # accumulate as failed-unit clutter.
    systemctl reset-failed "${serviceName}@$port" 2>/dev/null || true

    ${optionalString (project.destroyHook != null) (project.destroyHook pkgs hookCtx)}

    # Remove per-PR directory (removing the app symlink also releases the
    # indirect GC root — stale entries in gcroots/auto self-clean).
    if [ -d "$pr_dir" ]; then
      rm -rf "$pr_dir"
    fi

    # Remove Caddy config (check both new and legacy filenames)
    caddy_changed=false
    for cf in "/etc/caddy/conf.d/${name}-pr-$pr_num.conf" \
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

  list = mkScript "${serviceName}-list" ''
    echo "Active ${name} preview instances:"
    echo ""
    systemctl list-units "${serviceName}@*" --all --no-pager
    echo ""
    echo "Deployed builds:"
    for pr_dir in ${project.previewsDir}/pr-*; do
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

  logs = mkScript "${serviceName}-logs" ''
    if [ $# -lt 1 ]; then
      echo "Usage: ${serviceName}-logs <pr-number> [journalctl args...]" >&2
      echo "Example: ${serviceName}-logs 123" >&2
      echo "Example: ${serviceName}-logs 123 -n 50" >&2
      exit 1
    fi

    pr_num="$1"
    shift
    port=$((${toString project.basePort} + pr_num))

    if [ $# -eq 0 ]; then
      exec journalctl -u "${serviceName}@$port" -f
    else
      exec journalctl -u "${serviceName}@$port" "$@"
    fi
  '';
}
