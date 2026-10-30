# Required real-application test. Inputs are local worktrees and a verified seed directory.
# OC_WORKTREE=... TASKS_WORKTREE=... SEED_ARTIFACT_DIR=... nix build --impure -f dev/real-e2e.nix -L
let
  fromEnv = name: fallback: let value = builtins.getEnv name; in if value == "" then fallback else value;
  ocPath = fromEnv "OC_WORKTREE" "/home/kouloumos/.codex/worktrees/per-pr-database/opencouncil";
  tasksPath = fromEnv "TASKS_WORKTREE" "/home/kouloumos/schema-labs/projects/opencouncil-tasks-worktrees/generic-preview-module";
  seedPath = fromEnv "SEED_ARTIFACT_DIR" "/tmp/opencouncil-seed-publication";
  flake = builtins.getFlake (toString ../.);
  nixpkgs = flake.inputs.nixpkgs;
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  nixos-lib = import (nixpkgs + "/nixos/lib") { };
  ocFlake = builtins.getFlake "path:${ocPath}";
  tasksFlake = builtins.getFlake "path:${tasksPath}";
  ocProd = ocFlake.packages.x86_64-linux.opencouncil-prod;
  notisProd = ocFlake.packages.x86_64-linux.notis-prod;
  tasksProd = tasksFlake.packages.x86_64-linux.opencouncil-tasks-prod;
  sameOc = pkgs.runCommand "opencouncil-preview-equivalent-closure" { } ''
    mkdir -p $out
    cp -rs ${ocProd}/. $out/
  '';
  changedOc = pkgs.runCommand "opencouncil-preview-fingerprint-change" { } ''
    mkdir -p $out
    cp -rs ${ocProd}/. $out/
    rm $out/seed-bundle
    mkdir -p $out/seed-bundle/lib
    cat ${ocProd}/seed-bundle/lib/seed.cjs > $out/seed-bundle/lib/seed.cjs
    printf '\n// Equivalent test revision with a different fingerprint.\n' >> $out/seed-bundle/lib/seed.cjs
  '';
in
nixos-lib.runTest {
  name = "pr-previews-real-e2e";
  hostPkgs = pkgs;
  nodes.machine = { lib, pkgs, ... }: {
    imports = [ flake.nixosModules.default ];
    virtualisation = { writableStore = true; memorySize = 4096; diskSize = 16384; cores = 2; };
    services.pr-previews = {
      enable = true;
      user = "opencouncil";
      group = "opencouncil";
      projects = {
        opencouncil = lib.mkMerge [ ocFlake.previews.opencouncil { envFile = "/etc/preview-dummy.env"; startupTimeout = 120; } ];
        opencouncil-tasks = lib.mkMerge [ tasksFlake.previews.opencouncil-tasks { envFile = "/etc/preview-dummy.env"; } ];
        notis = lib.mkMerge [ ocFlake.previews.notis { envFile = "/etc/preview-dummy.env"; startupTimeout = 120; } ];
      };
    };
    services.caddy.globalConfig = "auto_https off";
    environment.etc."preview-dummy.env".text = ''
      ANTHROPIC_API_KEY=dummy
      NOTIS_ADMIN_SECRET=dummy-secret-at-least-16-chars
      API_TOKENS=["dummy-preview-token"]
      NEXTAUTH_SECRET=dummy-secret-for-e2e
      ELASTICSEARCH_URL=http://127.0.0.1:59998
      DATABASE_URL=postgresql://unreachable@127.0.0.1:59999/staging
      DIRECT_URL=postgresql://unreachable@127.0.0.1:59999/staging
      NOTIS_DATABASE_URL=postgresql://unreachable@127.0.0.1:59999/staging_notis
      MAIN_DATABASE_URL=postgresql://unreachable@127.0.0.1:59999/staging
      SKIP_ENV_VALIDATION=1
    '';
    environment.etc."seed/manifest.json".source = /. + "${seedPath}/manifest.json";
    environment.etc."seed/subset.tar.zst".source = /. + "${seedPath}/subset.tar.zst";
    environment.etc."anchors/oc".source = ocProd;
    environment.etc."anchors/notis".source = notisProd;
    environment.etc."anchors/tasks".source = tasksProd;
    environment.etc."anchors/changed-oc".source = changedOc;
    environment.etc."anchors/same-oc".source = sameOc;
    environment.systemPackages = [ pkgs.postgresql_16 ];
  };
  testScript = ''
    import json
    import shlex
    oc = "${ocProd}"
    notis = "${notisProd}"
    tasks = "${tasksProd}"
    changed_oc = "${changedOc}"
    same_oc = "${sameOc}"
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("caddy.service")

    def create_oc(app):
        machine.succeed(f"SEED_ARTIFACT_URL=/etc/seed opencouncil-preview-create 9 {app} --data-variant=default", timeout=900)

    def sql(db, query, user="opencouncil"):
        return machine.succeed(f"psql -h 127.0.0.1 -p 30009 -U {user} -d {db} -Atc {shlex.quote(query)}").strip()

    def state(db):
        return json.loads(machine.succeed(f"cat /var/lib/opencouncil-previews/pr-9/.databases/{db}.json"))

    def process_env(unit, expected):
        machine.succeed(f"pid=$(systemctl show {unit} -p MainPID --value); tr '\\0' '\\n' < /proc/$pid/environ | grep -Fx {shlex.quote(expected)}")

    with subtest("tasks serves HTTP without database declarations"):
        machine.succeed(f"opencouncil-tasks-preview-create 7 {tasks}")
        machine.succeed("opencouncil-tasks-preview-destroy 7")

    with subtest("app loads the subset, migrations, and test accounts"):
        machine.succeed("mkdir -p /var/lib/opencouncil-previews/pr-9; printf '%s\\n' 'DATABASE_URL=postgresql://unreachable@127.0.0.1:59999/staging' 'DIRECT_URL=postgresql://unreachable@127.0.0.1:59999/staging' > /var/lib/opencouncil-previews/pr-9/.env.local")
        create_oc(oc)
        machine.wait_for_unit("opencouncil-preview-db@9.service")
        assert int(sql("opencouncil", 'SELECT count(*) FROM "CouncilMeeting"')) > 0
        assert sql("opencouncil", """SELECT count(*) FROM "User" WHERE email='superadmin@test.com' AND "isSuperAdmin" """) == "1"
        assert sql("opencouncil", 'SELECT count(*) FROM _prisma_migrations WHERE finished_at IS NULL AND rolled_back_at IS NULL') == "0"
        process_env("opencouncil-preview@3009", "DATABASE_URL=postgresql://opencouncil@127.0.0.1:30009/opencouncil")
        process_env("opencouncil-preview@3009", "DIRECT_URL=postgresql://opencouncil@127.0.0.1:30009/opencouncil")
        process_env("opencouncil-preview@3009", "SESSION_COOKIE_SUFFIX=-pr9")
        machine.succeed("curl -sf http://127.0.0.1:3009/ >/dev/null")
        original = state("opencouncil")["generation"]

    with subtest("notis uses its paired database and main read-only role"):
        machine.succeed(f"notis-preview-create 9 {notis}", timeout=300)
        assert int(sql("notis", "SELECT count(*) FROM pg_tables WHERE schemaname='public'")) > 0
        assert sql("opencouncil", "SELECT pg_has_role('notis_service', 'notis_reader', 'member')") == "t"
        assert int(sql("opencouncil", "SELECT count(*) FROM notis_admin_sessions", user="notis_service")) >= 0
        machine.fail("psql -h 127.0.0.1 -p 30009 -U notis_service -d opencouncil -c 'SELECT * FROM \"User\" LIMIT 1'")
        process_env("notis-preview@20009", "NOTIS_DATABASE_URL=postgresql://opencouncil@127.0.0.1:30009/notis")
        process_env("notis-preview@20009", "MAIN_DATABASE_URL=postgresql://notis_service@127.0.0.1:30009/opencouncil")
        process_env("notis-preview@20009", "MAIN_SESSION_COOKIE_NAME=__Secure-oc-session-pr9")
        notis_generation = state("notis")["generation"]

    with subtest("unchanged pushes preserve preview data"):
        sql("opencouncil", 'CREATE TABLE preview_sentinel (id integer); INSERT INTO preview_sentinel VALUES (1)')
        create_oc(same_oc)
        assert state("opencouncil")["generation"] == original
        assert sql("opencouncil", "SELECT count(*) FROM preview_sentinel") == "1"

    with subtest("unsupported variants fail before replacing existing data"):
        machine.fail(f"SEED_ARTIFACT_URL=/etc/seed opencouncil-preview-create 9 {oc} --data-variant=full")
        assert state("opencouncil")["generation"] == original
        assert sql("opencouncil", "SELECT count(*) FROM preview_sentinel") == "1"

    with subtest("seed fingerprint change rebuilds owner and dependent"):
        create_oc(changed_oc)
        assert state("opencouncil")["generation"] > original
        assert sql("opencouncil", "SELECT to_regclass('public.preview_sentinel') IS NULL") == "t"
        machine.succeed(f"notis-preview-create 9 {notis}", timeout=300)
        assert state("notis")["generation"] > notis_generation
        assert int(sql("opencouncil", 'SELECT count(*) FROM "CouncilMeeting"')) > 0

    with subtest("destroy removes dependent database and owner cluster"):
        machine.succeed("notis-preview-destroy 9")
        assert sql("postgres", "SELECT count(*) FROM pg_database WHERE datname='notis'") == "0"
        machine.succeed("opencouncil-preview-destroy 9")
        machine.fail("systemctl is-active opencouncil-preview-db@9")
        machine.succeed("test ! -e /var/lib/opencouncil-previews/pr-9")
  '';
}
