# End-to-end imperative lifecycle in a VM (modeled on microvm.nix's
# checks/imperative-template.nix). Fake app = a static dir served by the
# project's startScript via python http.server.
{ pkgs, module }:
let
  # The fake app follows the runtime-ownership rule: its build produces its
  # own entrypoint, whose closure carries its own runtime (python here).
  fakeApp = pkgs.runCommand "fake-preview-app" { } ''
    mkdir -p $out/bin $out/share
    echo "hello from preview" > $out/share/index.html
    cat > $out/bin/start <<EOF
    #!${pkgs.runtimeShell}
    exec ${pkgs.python3}/bin/python3 -m http.server "\$PORT" --directory ${placeholder "out"}/share
    EOF
    chmod +x $out/bin/start
  '';
in
{
  name = "pr-previews-lifecycle";
  hostPkgs = pkgs;

  nodes.machine = { pkgs, ... }: {
    imports = [ module ];

    virtualisation.writableStore = true;
    virtualisation.memorySize = 1024;

    services.pr-previews = {
      enable = true;
      projects.demo = {
        hostPattern = "pr-@id@.preview.test";
        basePort = 8000;
        redirectFrom = [ "pr-@id@.old.test" ];
        # Runtime-ownership pattern: exec the app's own entrypoint.
        startScript = _: ctx: ''
          exec "$APP_DIR/bin/start"
        '';
      };
    };

    # No ACME in the sandbox.
    services.caddy.globalConfig = "auto_https off";

    # Make sure the fake app's store path exists in the VM's store.
    environment.etc."fake-app-anchor".source = fakeApp;
  };

  testScript = ''
    app = "${fakeApp}"

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("caddy.service")

    with subtest("create brings up the instance"):
        machine.succeed(f"demo-preview-create 5 {app}")
        machine.wait_for_unit("demo-preview@8005.service")
        machine.wait_until_succeeds("curl -sf http://127.0.0.1:8005/index.html | grep 'hello from preview'")

    with subtest("caddy vhost dropped and caddy reloaded cleanly"):
        machine.succeed("test -f /etc/caddy/conf.d/demo-pr-5.conf")
        machine.succeed("grep -q 'pr-5.old.test' /etc/caddy/conf.d/demo-pr-5.conf")
        machine.succeed("grep -q 'redir https://pr-5.preview.test' /etc/caddy/conf.d/demo-pr-5.conf")
        machine.succeed("systemctl is-active caddy.service")

    with subtest("instance dir and GC root exist"):
        machine.succeed("test -e /var/lib/demo-previews/pr-5/app")
        machine.succeed(f"nix-store --query --roots {app} | grep -q pr-5")

    with subtest("closure survives garbage collection"):
        machine.succeed("nix-collect-garbage >&2")
        machine.succeed(f"test -e {app}")
        machine.succeed("curl -sf http://127.0.0.1:8005/index.html >&2")

    with subtest("destroy tears everything down"):
        machine.succeed("demo-preview-destroy 5")
        machine.fail("systemctl is-active demo-preview@8005.service")
        machine.succeed("test ! -e /var/lib/demo-previews/pr-5")
        machine.succeed("test ! -f /etc/caddy/conf.d/demo-pr-5.conf")
  '';
}
