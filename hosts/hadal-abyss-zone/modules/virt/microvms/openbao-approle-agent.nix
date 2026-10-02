{
  name,
  credentialsDirectory,
  runUser,
  runGroup,
  agentConfig,
  caCert,
}:

{ lib, pkgs, ... }:

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
    };
    environment.BAO_CACERT = caCert;
  };
}
