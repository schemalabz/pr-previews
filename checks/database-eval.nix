{ nixpkgs, system, module }:
let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  project = port: {
    hostPattern = "pr-@id@.preview.test";
    basePort = port;
    startScript = _: ctx: ''echo '${ctx.databases.main.url}' '';
  };
  owner = (project 3000) // {
    database.cluster = { package = p: p.postgresql_16; basePort = 30000; };
    database.databases.main = {
      init = _: _: "true";
      fingerprint = _: _: "echo one";
    };
  };
  dependent = (project 20000) // {
    database.databases.aux = {
      "in" = "owner";
      init = _: _: "true";
      fingerprint = _: _: "echo one";
    };
  };
  evaluate = projects: (lib.nixosSystem {
    inherit system;
    modules = [ module {
      services.pr-previews = { enable = true; inherit projects; };
      fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
      boot.loader.grub.device = "/dev/sda";
      system.stateVersion = "24.11";
    } ];
  }).config;
  errors = projects: map (a: a.message)
    (builtins.filter (a: !a.assertion) (evaluate projects).assertions);
  rejects = fragment: projects: lib.any (lib.hasInfix fragment) (errors projects);
in
assert errors { inherit owner dependent; } == [ ];
assert errors { demo = (project 3000) // { startScript = _: _: "true"; }; } == [ ];
assert rejects "unknown or disabled" { dependent = lib.recursiveUpdate dependent { database.databases.aux."in" = "missing"; }; };
assert rejects "unknown or disabled" { inherit dependent; owner = owner // { enable = false; }; };
assert rejects "has no cluster" { inherit dependent; owner = (project 3000) // { startScript = _: _: "true"; }; };
assert rejects "duplicate database" { inherit owner; dependent = lib.recursiveUpdate dependent { database.databases = { main = dependent.database.databases.aux; }; }; };
assert rejects "port ranges overlap" { owner = lib.recursiveUpdate owner { database.cluster.basePort = 5432; }; };
assert rejects "port ranges overlap" {
  inherit owner;
  other = lib.recursiveUpdate owner { basePort = 20000; database.cluster.basePort = 35000; };
};
assert rejects "identifier" { owner = owner // { database = owner.database // { databases."bad-name" = owner.database.databases.main; }; }; };
assert rejects "owner database" { owner = owner // { database = owner.database // { databases = { }; }; }; };
pkgs.runCommand "pr-previews-database-eval" { } "touch $out"
