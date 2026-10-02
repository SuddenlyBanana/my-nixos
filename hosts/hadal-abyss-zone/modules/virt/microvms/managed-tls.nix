{
  name,
  bundlePath,
  outputDir,
  owner,
  group,
  serverName,
  serviceUnit,
  startUnit ? serviceUnit,
}:

{ lib, pkgs, ... }:

let
  activate = pkgs.writeShellApplication {
    name = "activate-${name}-tls";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
      pkgs.systemd
      pkgs.util-linux
    ];
    text = builtins.readFile ./scripts/activate-managed-tls.sh;
  };

  check = pkgs.writeShellApplication {
    name = "check-${name}-tls";
    runtimeInputs = [ pkgs.openssl ];
    text = builtins.readFile ./scripts/check-managed-tls.sh;
  };

  activationUnit = "activate-${name}-tls";
  checkUnit = "check-${name}-tls";
in
{
  systemd.paths.${activationUnit} = {
    description = "Watch the OpenBao-issued ${name} TLS bundle";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = bundlePath;
      Unit = "${activationUnit}.service";
    };
  };

  systemd.services.${activationUnit} = {
    description = "Validate and activate the ${name} TLS certificate";
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = bundlePath;
    environment = {
      TLS_BUNDLE = bundlePath;
      TLS_OUTPUT_DIR = outputDir;
      TLS_OWNER = owner;
      TLS_GROUP = group;
      TLS_SERVER_NAME = serverName;
      TLS_SERVICE_UNIT = serviceUnit;
      TLS_START_UNIT = startUnit;
    };
    serviceConfig = {
      Type = "oneshot";
      UMask = "0077";
      ExecStart = lib.getExe activate;
    };
  };

  systemd.services.${checkUnit} = {
    description = "Check the active ${name} TLS certificate lifetime";
    unitConfig.ConditionPathExists = "${outputDir}/current/server.crt";
    environment = {
      TLS_CERTIFICATE = "${outputDir}/current/server.crt";
      TLS_SERVER_NAME = serverName;
      TLS_WARNING_SECONDS = "604800";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe check;
    };
  };

  systemd.timers.${checkUnit} = {
    description = "Daily ${name} TLS expiry check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "30m";
      Persistent = true;
      Unit = "${checkUnit}.service";
    };
  };
}
