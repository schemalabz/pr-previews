{ pkgs, module }:
let
  app = fingerprint: pkgs.runCommand "database-preview-${fingerprint}" { } ''
    mkdir -p $out/bin $out/share
    echo ${fingerprint} > $out/fingerprint
    echo ready > $out/share/index.html
    cat > $out/bin/start <<EOF
    #!${pkgs.runtimeShell}
    exec ${pkgs.python3}/bin/python3 -m http.server "\$PORT" --directory ${placeholder "out"}/share
    EOF
    chmod +x $out/bin/start
  '';
  legacy = pkgs.runCommand "legacy-preview-without-database-inputs" { } "mkdir -p $out";
  one = app "one";
  two = app "two";
  database = {
    init = pkgs: _: ''
      ${pkgs.postgresql_16}/bin/psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v variant="$DATA_VARIANT" <<'SQL'
      CREATE TABLE marker (variant text);
      INSERT INTO marker VALUES (:'variant');
      SQL
      if [ "$DATA_VARIANT" = fail ]; then exit 1; fi
      echo initialized >> "$pr_dir/init-count"
    '';
    fingerprint = _: _: ''cat "$store_path/fingerprint"'';
  };
in {
  name = "pr-previews-database";
  hostPkgs = pkgs;
  nodes.machine = { pkgs, ... }: {
    imports = [ module ];
    virtualisation = { writableStore = true; memorySize = 1024; diskSize = 8192; };
    services.pr-previews = {
      enable = true;
      projects.demo = {
        hostPattern = "pr-@id@.preview.test";
        basePort = 8000;
        startupTimeout = 15;
        database.cluster = { package = p: p.postgresql_16; basePort = 30000; };
        database.databases.main = database;
        startScript = _: ctx: ''
          export DATABASE_URL="${ctx.databases.main.url}"
          exec "$APP_DIR/bin/start"
        '';
      };
      projects.aux = {
        hostPattern = "aux-pr-@id@.preview.test";
        basePort = 20000;
        startupTimeout = 15;
        database.databases.aux = database // { "in" = "demo"; };
        startScript = _: ctx: ''
          export MAIN_DATABASE_URL="${ctx.siblings.demo.databases.main.url}"
          export DATABASE_URL="${ctx.databases.aux.url}"
          exec "$APP_DIR/bin/start"
        '';
      };
    };
    services.caddy.globalConfig = "auto_https off";
    environment.systemPackages = [ pkgs.postgresql_16 pkgs.jq ];
    environment.etc."anchors/one".source = one;
    environment.etc."anchors/two".source = two;
    environment.etc."anchors/legacy".source = legacy;
  };
  testScript = ''
    import json
    one = "${one}"
    two = "${two}"
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("caddy.service")

    def sql(db, query, pr=5):
        return machine.succeed(f"psql -h 127.0.0.1 -p {30000 + pr} -U preview -d {db} -Atc \"{query}\"").strip()

    def state(db):
        return json.loads(machine.succeed(f"cat /var/lib/demo-previews/pr-5/.databases/{db}.json"))

    with subtest("dependent before owner fails"):
        machine.fail(f"aux-preview-create 5 {one} > /tmp/dependent.log 2>&1")
        machine.succeed("grep -q 'create demo first' /tmp/dependent.log")

    with subtest("first create initializes both databases and passes context URLs"):
        machine.succeed(f"demo-preview-create 5 {one}")
        machine.succeed(f"aux-preview-create 5 {one}")
        assert sql("main", "SELECT variant FROM marker") == "default"
        assert sql("aux", "SELECT variant FROM marker") == "default"
        machine.succeed("pid=$(systemctl show aux-preview@20005 -p MainPID --value); tr '\\0' '\\n' < /proc/$pid/environ | grep -x 'MAIN_DATABASE_URL=postgresql://preview@127.0.0.1:30005/main'")
        original = state("main")["generation"]

    with subtest("unchanged create preserves data"):
        sql("main", "INSERT INTO marker VALUES ('sentinel')")
        machine.succeed(f"demo-preview-create 5 {one}")
        assert state("main")["generation"] == original
        assert sql("main", "SELECT count(*) FROM marker") == "2"

    with subtest("an incompatible closure preserves the running application"):
        machine.fail("demo-preview-create 5 ${legacy}")
        assert machine.succeed("readlink /var/lib/demo-previews/pr-5/app").strip() == one
        machine.succeed("systemctl is-active demo-preview@8005")
        assert sql("main", "SELECT count(*) FROM marker") == "2"

    with subtest("redeploy adopts an active cluster on its old port"):
        machine.succeed("mkdir -p /run/systemd/system/demo-preview-db@5.service.d")
        machine.succeed("printf '%s\\n' '[Service]' 'ExecStart=' 'ExecStart=${pkgs.postgresql_16}/bin/postgres -D /var/lib/demo-previews/pr-5/postgres -c port=5437 -c listen_addresses=127.0.0.1 -c unix_socket_directories=/var/lib/demo-previews/pr-5/socket' > /run/systemd/system/demo-preview-db@5.service.d/old-port.conf")
        machine.succeed("systemctl daemon-reload; systemctl restart demo-preview-db@5")
        machine.wait_until_succeeds("psql -h 127.0.0.1 -p 5437 -U preview -d main -Atc 'SELECT 1'")
        machine.succeed("rm /run/systemd/system/demo-preview-db@5.service.d/old-port.conf; systemctl daemon-reload")
        machine.succeed("systemd-run --unit=stalled-database-port ${pkgs.python3}/bin/python3 -c \"import socket,time; s=socket.socket(); s.bind(('127.0.0.1',30005)); s.listen(); connection,_=s.accept(); time.sleep(60)\"")
        machine.wait_until_succeeds("${pkgs.iproute2}/bin/ss -H -ltn 'sport = :30005' | grep -q .")
        machine.fail(f"timeout 15 demo-preview-create 5 {one} > /tmp/stalled-port.log 2>&1")
        machine.succeed("grep -q 'occupied' /tmp/stalled-port.log")
        machine.succeed("systemctl stop stalled-database-port")
        machine.succeed(f"demo-preview-create 5 {one}")
        assert state("main")["generation"] == original
        assert sql("main", "SELECT count(*) FROM marker") == "2"

    with subtest("fingerprint change rebuilds owner and then dependent"):
        aux_generation = state("aux")["generation"]
        machine.succeed(f"demo-preview-create 5 {two}")
        assert state("main")["generation"] > original
        assert sql("main", "SELECT count(*) FROM marker") == "1"
        machine.succeed(f"aux-preview-create 5 {one}")
        assert state("aux")["generation"] > aux_generation

    with subtest("variant changes rebuild the database"):
        machine.succeed(f"demo-preview-create 5 {two} --data-variant=alternate")
        assert sql("main", "SELECT variant FROM marker") == "alternate"

    with subtest("failed initialization leaves no database or successful state"):
        machine.fail(f"demo-preview-create 5 {two} --data-variant=fail")
        assert sql("postgres", "SELECT count(*) FROM pg_database WHERE datname='main'") == "0"
        machine.succeed("test ! -e /var/lib/demo-previews/pr-5/.databases/main.json")
        machine.fail(f"aux-preview-create 5 {one}")
        machine.succeed(f"demo-preview-create 5 {two}")
        machine.succeed(f"aux-preview-create 5 {one}")
        assert sql("main", "SELECT variant FROM marker") == "default"

    with subtest("concurrent creates initialize only once"):
        machine.succeed(f"demo-preview-create 7 {one} >/tmp/create-a.log 2>&1 & a=$!; demo-preview-create 7 {one} >/tmp/create-b.log 2>&1 & b=$!; wait $a; wait $b")
        assert machine.succeed("wc -l < /var/lib/demo-previews/pr-7/init-count").strip() == "1"
        machine.succeed("demo-preview-destroy 7")

    with subtest("an unrelated process cannot satisfy cluster readiness"):
        machine.succeed("systemd-run --unit=occupied-port ${pkgs.python3}/bin/python3 -m http.server 30006")
        machine.wait_until_succeeds("curl -s http://127.0.0.1:30006/ >/dev/null")
        machine.fail(f"demo-preview-create 6 {one} >/tmp/occupied.log 2>&1")
        machine.succeed("grep -q 'occupied' /tmp/occupied.log")
        machine.succeed("systemctl stop occupied-port")
        machine.succeed("demo-preview-destroy 6")

    with subtest("destroy dependent keeps the owner; destroy owner removes the cluster"):
        machine.succeed("aux-preview-destroy 5")
        assert sql("postgres", "SELECT count(*) FROM pg_database WHERE datname='aux'") == "0"
        assert sql("main", "SELECT count(*) FROM marker") == "1"
        machine.succeed("demo-preview-destroy 5")
        machine.fail("systemctl is-active demo-preview-db@5")
        machine.succeed("test ! -e /var/lib/demo-previews/pr-5")

    with subtest("capacity refuses a new cluster"):
        machine.succeed("mount -t tmpfs -o size=16m tmpfs /var/lib/demo-previews")
        machine.fail(f"demo-preview-create 8 {one} >/tmp/capacity.log 2>&1")
        machine.succeed("grep -q 'free disk' /tmp/capacity.log")
        machine.succeed("test ! -e /var/lib/demo-previews/pr-8/postgres/PG_VERSION")
        machine.succeed("umount /var/lib/demo-previews")

    with subtest("invalid PR identifiers are rejected"):
        for pr in ["0", "10000", "../escape", "-1", "abc"]:
            machine.fail(f"demo-preview-create {pr} {one}")
  '';
}
