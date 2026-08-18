# Real-app e2e in a local VM (dev-only, IMPURE — references local worktrees).
# The tasks preview is the REQUIRED gate; the opencouncil --with-db flow is
# best-effort with the outcome logged (see dev/REAL-E2E.md).
#
# Run:
#   nix build --impure -f dev/real-e2e.nix -L
#
# Prereqs: seed_data.json fetched to the path below; app worktrees at their
# converted commits.
let
  seedDataPath = "/tmp/claude-1000/-home-kouloumos-schema-labs-projects-nix-openclaw-worktrees-generic-preview-module/e5a6d67b-9b6a-4790-93ac-c99ed722462b/scratchpad/seed_data.json";

  flake = builtins.getFlake (toString ../.);
  nixpkgs = flake.inputs.nixpkgs;
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  nixos-lib = import (nixpkgs + "/nixos/lib") { };

  ocFlake = builtins.getFlake
    "path:/home/kouloumos/schema-labs/projects/opencouncil-worktrees/generic-preview-module";
  tasksFlake = builtins.getFlake
    "path:/home/kouloumos/schema-labs/projects/opencouncil-tasks-worktrees/generic-preview-module";

  ocProd = ocFlake.packages.x86_64-linux.opencouncil-prod;
  ocTasksProd = tasksFlake.packages.x86_64-linux.opencouncil-tasks-prod;
in
nixos-lib.runTest {
  name = "pr-previews-real-e2e";
  hostPkgs = pkgs;

  nodes.machine = { lib, pkgs, ... }: {
    imports = [ flake.nixosModules.default ];

    virtualisation = {
      writableStore = true;
      memorySize = 4096;
      diskSize = 12288;
      cores = 2;
    };

    services.pr-previews = {
      enable = true;
      user = "opencouncil";
      group = "opencouncil";
      projects = {
        opencouncil = lib.mkMerge [
          ocFlake.previews.opencouncil
          { envFile = "/etc/preview-dummy.env"; }
        ];
        opencouncil-tasks = lib.mkMerge [
          tasksFlake.previews.opencouncil-tasks
          { envFile = "/etc/preview-dummy.env"; }
        ];
      };
    };

    # No ACME in the sandbox.
    services.caddy.globalConfig = "auto_https off";

    environment.etc."preview-dummy.env".text = ''
      ANTHROPIC_API_KEY=dummy
      API_TOKENS=["dummy-preview-token"]
      NEXTAUTH_SECRET=dummy-secret-for-e2e
      ELASTICSEARCH_URL=http://127.0.0.1:59998
      DATABASE_URL=postgresql://opencouncil@127.0.0.1:59999/placeholder
      DIRECT_URL=postgresql://opencouncil@127.0.0.1:59999/placeholder
      SKIP_ENV_VALIDATION=1
    '';

    environment.etc."seed_data.json".source = /. + seedDataPath;

    # Anchor the real app closures into the VM's store.
    environment.etc."anchors/oc".source = ocProd;
    environment.etc."anchors/tasks".source = ocTasksProd;
  };

  testScript = ''
    tasks = "${ocTasksProd}"
    oc = "${ocProd}"

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("caddy.service")

    with subtest("REQUIRED: real opencouncil-tasks preview serves HTTP"):
        machine.succeed(f"opencouncil-tasks-preview-create 7 {tasks} >&2")
        machine.wait_for_unit("opencouncil-tasks-preview@4007.service")
        machine.wait_until_succeeds(
            "code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4007/); test \"$code\" != 000",
            timeout=120,
        )
        machine.succeed("test -f /etc/caddy/conf.d/opencouncil-tasks-pr-7.conf")
        machine.succeed(f"nix-store --query --roots {tasks} | grep -q pr-7")
        machine.succeed("opencouncil-tasks-preview-destroy 7 >&2")

    with subtest("BEST-EFFORT: opencouncil --with-db (cluster, PostGIS, migrations, seed, boot)"):
        outcome = "not-started"
        try:
            machine.succeed(
                "mkdir -p /var/lib/opencouncil-previews/pr-9"
                " && cp /etc/seed_data.json /var/lib/opencouncil-previews/pr-9/seed_data.json"
                " && chown -R opencouncil:opencouncil /var/lib/opencouncil-previews/pr-9"
            )
            outcome = "create-started"
            machine.succeed(f"opencouncil-preview-create 9 {oc} --with-db >&2", timeout=900)
            outcome = "create-succeeded"
            machine.wait_for_unit("opencouncil-preview-db@9.service")
            outcome = "db-active"
            machine.wait_for_unit("opencouncil-preview@3009.service")
            outcome = "app-unit-active"
            machine.wait_until_succeeds(
                "code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3009/); test \"$code\" != 000",
                timeout=300,
            )
            outcome = "app-responds"
        except Exception as e:
            machine.log(f"BEST-EFFORT OUTCOME: {outcome}; failure: {e}")
            machine.execute("journalctl -u opencouncil-preview@3009 -n 40 --no-pager >&2 || true")
            machine.execute("journalctl -u opencouncil-preview-db@9 -n 20 --no-pager >&2 || true")
        print(f"### OPENCOUNCIL BEST-EFFORT OUTCOME: {outcome}")
  '';
}
