{ lib, pkgs, topCfg, allProjects }:
with lib;
let
  clusterOwners = filterAttrs (_: p: p.database.cluster != null) allProjects;
  clusterDir = owner: "${allProjects.${owner}.previewsDir}/pr-$pr_num";
  clusterPort = owner: "$((${toString allProjects.${owner}.database.cluster.basePort} + pr_num))";
  psql = "${pkgs.postgresql_16}/bin/psql";
  dbArgs = owner: ''-h 127.0.0.1 -p "${clusterPort owner}" -U ${escapeShellArg topCfg.user}'';
  ready = owner: ''
    systemctl is-active --quiet "${owner}-preview-db@$pr_num" &&
      [ "$(${pkgs.coreutils}/bin/timeout 5 ${psql} ${dbArgs owner} -d postgres -Atc 'SHOW data_directory' 2>/dev/null)" = "${clusterDir owner}/postgres" ]
  '';
  serviceFor = owner: p:
    let
      pg = p.database.cluster.package pkgs;
      settings = concatStringsSep " " (mapAttrsToList (key: value:
        "-c " + escapeShellArg "${key}=${toString value}") p.database.cluster.settings);
      start = pkgs.writeShellApplication {
        name = "${owner}-preview-db-start";
        runtimeInputs = [ pg pkgs.coreutils ];
        text = ''
          pr_num="$1"
          data_dir="${clusterDir owner}/postgres"
          socket_dir="${clusterDir owner}/socket"
          install -d -m 0700 "$data_dir" "$socket_dir"
          if [ ! -f "$data_dir/PG_VERSION" ]; then
            if [ -n "$(find "$data_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
              echo "Error: nonempty PostgreSQL directory without PG_VERSION: $data_dir" >&2
              exit 1
            fi
            initdb -D "$data_dir" --username=${escapeShellArg topCfg.user} --auth=trust
          fi
          exec postgres -D "$data_dir" ${settings} \
            -c "port=${clusterPort owner}" -c listen_addresses=127.0.0.1 \
            -c "unix_socket_directories=$socket_dir"
        '';
      };
    in {
      description = "${owner} preview PostgreSQL for PR %i";
      after = [ "network.target" ];
      restartIfChanged = false;
      serviceConfig = {
        Type = "simple";
        User = topCfg.user;
        Group = topCfg.group;
        ExecStart = "${getExe start} %i";
        Restart = "on-failure";
        RestartSec = "5s";
        UMask = "0077";
      };
    };
in {
  services = mapAttrs' (owner: p: nameValuePair "${owner}-preview-db@" (serviceFor owner p)) clusterOwners;

  forProject = name: project: ctx:
    let
      ownerFor = db: if db."in" == null then name else db."in";
      owners = unique (map ownerFor (attrValues project.database.databases));
      locks = sort builtins.lessThan (unique (map (owner: "${allProjects.${owner}.previewsDir}/.locks") ([ name ] ++ owners)));
      command = dbName: db: action:
        pkgs.writeShellApplication {
          name = "${name}-${dbName}-${action}";
          runtimeInputs = [ pkgs.postgresql_16 pkgs.coreutils ];
          text = ''
            export pr_num="''${pr_num:?}" pr_dir="''${pr_dir:?}" store_path="''${store_path:?}" port="''${port:?}"
            ${db.${action} pkgs ctx}
          '';
        };
      invoke = dbName: db: action: ''
        ${pkgs.util-linux}/bin/runuser -u ${escapeShellArg topCfg.user} -- \
          ${pkgs.coreutils}/bin/env DATABASE_URL="$database_url" DATA_VARIANT="$data_variant" \
          pr_num="$pr_num" pr_dir="$pr_dir" store_path="$store_path" port="$port" \
          ${getExe (command dbName db action)}
      '';
      initDatabase = dbName: db:
        let
          owner = ownerFor db;
          ownerDbs = filterAttrs (_: od: od."in" == null) allProjects.${owner}.database.databases;
        in ''
          database_url="${ctx.databases.${dbName}.url}"
          state_dir="${clusterDir owner}/.databases"
          mkdir -p "$state_dir"
          state_file="$state_dir/${dbName}.json"
          owner_generation='{}'
          ${optionalString (owner != name) ''
            ${concatStrings (mapAttrsToList (ownerDb: _: ''
              if ! generation=$(${pkgs.jq}/bin/jq -er '.generation | numbers' "$state_dir/${ownerDb}.json" 2>/dev/null); then
                echo "Error: owner database ${owner}.${ownerDb} is not initialized; create ${owner} first" >&2
                exit 1
              fi
              owner_generation=$(${pkgs.jq}/bin/jq -cn --argjson previous "$owner_generation" \
                --arg key ${escapeShellArg ownerDb} --argjson generation "$generation" '$previous + {($key): $generation}')
            '') ownerDbs)}
          ''}
          fingerprint="$fingerprint_${dbName}"
          if ! ${pkgs.jq}/bin/jq -e --arg variant "$data_variant" --arg fingerprint "$fingerprint" \
            --argjson ownerGeneration "$owner_generation" \
            '.variant == $variant and .fingerprint == $fingerprint and .ownerGeneration == $ownerGeneration' \
            "$state_file" >/dev/null 2>&1; then
            # Counters survive destroy/recreate so a dependent cannot accept a reused generation.
            counter="${allProjects.${owner}.previewsDir}/.locks/pr-$pr_num-${dbName}.generation"
            generation=0
            if [ -f "$counter" ]; then generation=$(cat "$counter"); fi
            rm -f "$state_file"
            ${pkgs.postgresql_16}/bin/dropdb ${dbArgs owner} --force --if-exists ${escapeShellArg dbName}
            ${pkgs.postgresql_16}/bin/createdb ${dbArgs owner} ${escapeShellArg dbName}
            if ! (
              ${concatMapStrings (extension: ''
                ${psql} "$database_url" -v ON_ERROR_STOP=1 -c ${escapeShellArg ("CREATE EXTENSION IF NOT EXISTS \"" + replaceStrings [ "\"" ] [ "\"\"" ] extension + "\";")} || exit "$?"
              '') db.extensions}
              ${invoke dbName db "init"}
            ); then
              ${pkgs.postgresql_16}/bin/dropdb ${dbArgs owner} --force --if-exists ${escapeShellArg dbName}
              echo "Error: ${name}.${dbName} initialization failed; retry the preview create" >&2
              exit 1
            fi
            generation=$((generation + 1))
            printf '%s\n' "$generation" > "$counter.tmp"
            mv "$counter.tmp" "$counter"
            ${pkgs.jq}/bin/jq -n --arg variant "$data_variant" --arg fingerprint "$fingerprint" \
              --argjson ownerGeneration "$owner_generation" --argjson generation "$generation" \
              '{variant:$variant, fingerprint:$fingerprint, ownerGeneration:$ownerGeneration, generation:$generation}' \
              > "$state_file.tmp"
            mv "$state_file.tmp" "$state_file"
          fi
        '';
    in {
      lock = concatMapStrings (dir: ''
        mkdir -p ${escapeShellArg dir}
        exec {database_lock}>"${dir}/pr-$pr_num.lock"
        ${pkgs.util-linux}/bin/flock "$database_lock"
      '') locks;

      preflight = concatStrings (mapAttrsToList (dbName: db: ''
        database_url="${ctx.databases.${dbName}.url}"
        fingerprint_${dbName}=$(${invoke dbName db "fingerprint"})
        fingerprint="$fingerprint_${dbName}"
        if [ -z "$fingerprint" ] || [[ "$fingerprint" == *$'\n'* ]]; then
          echo "Error: ${name}.${dbName} fingerprint must print one nonempty line" >&2
          exit 1
        fi
      '') project.database.databases);

      create = optionalString (project.database.cluster != null) ''
        if [ ! -f "${clusterDir name}/postgres/PG_VERSION" ]; then
          available=$(${pkgs.coreutils}/bin/df -Pm "$pr_dir" | ${pkgs.gawk}/bin/awk 'NR == 2 { print $4 }')
          if [ "$available" -lt ${toString topCfg.database.minFreeDisk} ]; then
            echo "Error: insufficient free disk for a new ${name} preview cluster ($available MiB)" >&2
            exit 1
          fi
        fi
        if systemctl is-active --quiet "${name}-preview-db@$pr_num" && ! (${ready name}); then
          systemctl stop "${name}-preview-db@$pr_num"
        fi
        if ! systemctl is-active --quiet "${name}-preview-db@$pr_num"; then
          if [ -n "$(${pkgs.iproute2}/bin/ss -H -ltn "sport = :${clusterPort name}")" ]; then
            echo "Error: cluster port ${clusterPort name} is occupied by another process" >&2
            exit 1
          fi
          systemctl start "${name}-preview-db@$pr_num"
        fi
        cluster_ready=false
        for _ in $(seq 1 60); do
          if ${ready name} then cluster_ready=true; break; fi
          sleep 1
        done
        if [ "$cluster_ready" != true ]; then
          echo "Error: ${name} cluster did not become ready on port ${clusterPort name}" >&2
          journalctl -u "${name}-preview-db@$pr_num" -n 30 --no-pager >&2 || true
          exit 1
        fi
      '' + concatMapStrings (owner: optionalString (owner != name) ''
        if ! (${ready owner}); then
          echo "Error: the cluster of ${owner} for PR $pr_num does not exist: create ${owner} first" >&2
          exit 1
        fi
      '') owners + concatStrings (mapAttrsToList initDatabase project.database.databases);

      destroy = concatStrings (mapAttrsToList (dbName: db:
        let owner = ownerFor db; in optionalString (owner != name) ''
          if (${ready owner}); then
            ${pkgs.postgresql_16}/bin/dropdb ${dbArgs owner} --force --if-exists ${escapeShellArg dbName}
          fi
          rm -f "${clusterDir owner}/.databases/${dbName}.json"
        '') project.database.databases) + optionalString (project.database.cluster != null) ''
          systemctl stop "${name}-preview-db@$pr_num"
          systemctl reset-failed "${name}-preview-db@$pr_num" 2>/dev/null || true
        '';
    };
}
