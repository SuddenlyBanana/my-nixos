{
  name,
  credentialsDirectory,
  runUser,
  runGroup,
  agentConfig,
  caCert,
}:

{ lib, pkgs, ... }:
let
  reloadCredentials = pkgs.writeShellApplication {
    name = "reload-openbao-agent-${name}";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
      pkgs.diffutils
    ];
    text = builtins.readFile ./scripts/reload-agent-credentials.sh;
  };
in
{
  systemd.services."openbao-agent-${name}" = {
    description = "Run the ${name} OpenBao agent with AppRole authentication";
    wantedBy = [ "multi-user.target" ];
    requires = [ "network-online.target" ];
    after = [ "network-online.target" ];
    unitConfig = {
      RequiresMountsFor = [
        credentialsDirectory
        caCert
      ];
      ConditionPathExists = [
        "${credentialsDirectory}/role-id"
        "${credentialsDirectory}/secret-id"
      ];
    };
    serviceConfig = {
      Type = "simple";
      User = runUser;
      Group = runGroup;
      UMask = "0077";
      ExecStart = "${lib.getExe pkgs.openbao} agent -config=${agentConfig}";
      Restart = "on-failure";
      RestartSec = "5s";
      LoadCredential = [
        "role-id:${credentialsDirectory}/role-id"
        "secret-id:${credentialsDirectory}/secret-id"
        "ca.crt:${caCert}"
      ];
    };
    environment.BAO_CACERT = "/run/credentials/openbao-agent-${name}.service/ca.crt";
  };
  systemd.paths."openbao-agent-${name}" = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "${credentialsDirectory}/secret-id";
      Unit = "restart-openbao-agent-${name}.service";
    };
  };
  # Host writes through virtiofs need not generate guest inotify events.
  systemd.timers."restart-openbao-agent-${name}" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "5m";
    };
  };
  systemd.services."restart-openbao-agent-${name}" = {
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe reloadCredentials} ${
        lib.escapeShellArgs [
          name
          credentialsDirectory
          caCert
        ]
      }";
    };
  };
}
