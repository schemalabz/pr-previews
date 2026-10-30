{ lib, pkgs, topCfg, allProjects }:
with lib;
let
  lifecycle = import ./database-lifecycle.nix { inherit lib pkgs topCfg allProjects; };
  entries = concatLists (mapAttrsToList (name: p:
    mapAttrsToList (dbName: db: {
      inherit name dbName db;
      owner = if db."in" == null then name else db."in";
    }) p.database.databases) allProjects);
  owners = filterAttrs (_: p: p.database.cluster != null) allProjects;
  ownerExists = e: hasAttr e.owner allProjects;
  clusterFor = e: if ownerExists e then allProjects.${e.owner}.database.cluster else null;
  overlaps = a: b: a < b + 10000 && b < a + 10000;
in {
  inherit (lifecycle) services forProject;
  assertions = concatMap (e: [
    { assertion = ownerExists e; message = "database ${e.name}.${e.dbName}: unknown or disabled cluster owner '${e.owner}'."; }
    { assertion = !ownerExists e || clusterFor e != null; message = "database ${e.name}.${e.dbName}: owner '${e.owner}' has no cluster."; }
    { assertion = builtins.match "[a-z_][a-z0-9_]*" e.dbName != null && stringLength e.dbName <= 63;
      message = "database ${e.name}.${e.dbName}: database name must be a PostgreSQL identifier of at most 63 characters."; }
    { assertion = e.db."in" == null || e.db."in" != e.name;
      message = "database ${e.name}.${e.dbName}: use null for a database in its own cluster."; }
    { assertion = length (filter (other: other.owner == e.owner && other.dbName == e.dbName) entries) == 1;
      message = "duplicate database '${e.dbName}' in cluster '${e.owner}'."; }
  ]) entries ++ concatLists (mapAttrsToList (name: p: [
    { assertion = any (e: e.name == name && e.db."in" == null) entries;
      message = "cluster '${name}' must declare an owner database."; }
    { assertion = all (key: !(elem key [ "port" "listen_addresses" "unix_socket_directories" "data_directory" ])) (attrNames p.database.cluster.settings);
      message = "cluster '${name}': listener and data directory settings are managed by the module."; }
    { assertion = p.database.cluster.basePort + 9999 <= 65535;
      message = "cluster '${name}' port range exceeds 65535."; }
    { assertion = all (app: !overlaps p.database.cluster.basePort app.basePort) (attrValues allProjects)
        && all (other: other == name || !overlaps p.database.cluster.basePort owners.${other}.database.cluster.basePort) (attrNames owners);
      message = "cluster '${name}': database and application port ranges overlap (PR numbers below 10000)."; }
  ]) owners);

  urlsFor = name: idVar: mapAttrs (dbName: db:
    let
      owner = if db."in" == null then name else db."in";
      cluster = if hasAttr owner allProjects then allProjects.${owner}.database.cluster else null;
      base = if cluster == null then 0 else cluster.basePort;
    in { url = "postgresql://${topCfg.user}@127.0.0.1:$((${toString base} + ${idVar}))/${dbName}"; }
  ) allProjects.${name}.database.databases;
}
