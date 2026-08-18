# Example preview host — two projects, one of them with a paired sibling.
# This mirrors checks/eval.nix; use it as a starting point for a real host
# (add your hardware config, SSH keys, and ACME/DNS setup).
{ pkgs, ... }:
{
  services.pr-previews = {
    enable = true;

    projects.myapp = {
      hostPattern = "pr-@id@.preview.example.com";
      basePort = 3000;
      envFile = "/var/lib/myapp-preview.env"; # preview-grade secrets only
      # Exec the entrypoint the app's own build produced (runtime ownership:
      # the app runs on the toolchain that built it — see README).
      startScript = _: ctx: ''
        exec "$APP_DIR/bin/start"
      '';
    };

    projects.satellite = {
      hostPattern = "satellite-pr-@id@.preview.example.com";
      basePort = 5000;
      startScript = _: ctx: ''
        export MAIN_APP_URL="${ctx.siblings.myapp.url}"
        exec "$APP_DIR/bin/start"
      '';
    };
  };

  # Wildcard TLS: build Caddy with your DNS provider's plugin and configure
  # the DNS-01 challenge; see https://github.com/caddy-dns
  # services.caddy.package = pkgs.caddy.withPlugins { ... };
}
