# Template unit for one project's preview instances. Instance key = PORT
# (parity with the pre-extraction module: opencouncil-preview@3251 is port
# 3251, i.e. basePort + PR number).
{ lib, name, project, topCfg, startScript }:
{
  description = "${name} preview instance on port %i";
  after = [ "network.target" ];
  # Never bounce running previews on nixos-rebuild (microvm.nix precedent).
  restartIfChanged = false;
  serviceConfig = {
    Type = "simple";
    User = topCfg.user;
    Group = topCfg.group;
    Environment = project.environment ++ [ "PORT=%i" ];
    EnvironmentFile = lib.mkIf (project.envFile != null) project.envFile;
    ExecStart = "${startScript} %i";
    Restart = "on-failure";
    RestartSec = "5s";
    SyslogIdentifier = "${name}-preview@%i";
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectHome = true;
    ReadWritePaths = [ project.previewsDir ];
  };
}
