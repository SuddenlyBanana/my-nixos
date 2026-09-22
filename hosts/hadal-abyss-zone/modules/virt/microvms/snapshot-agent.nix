{
  controlAddress,
  mountPoint,
  quiesceUnits ? [ ],
}:

{ lib, pkgs, ... }:

let
  snapshotControl = pkgs.writeShellApplication {
    name = "microvm-snapshot-control";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
      pkgs.util-linux
    ];
    text = builtins.readFile ./scripts/snapshot-control.sh;
  };
  commonEnvironment = {
    SNAPSHOT_MOUNT = mountPoint;
    QUIESCE_UNITS = builtins.concatStringsSep " " quiesceUnits;
  };
in
{
  systemd.sockets.microvm-snapshot-control = {
    description = "Host-only MicroVM snapshot control socket";
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = "[${controlAddress}]:9100";
      Accept = true;
      FreeBind = true;
      BindIPv6Only = "ipv6-only";
    };
  };

  systemd.services."microvm-snapshot-control@" = {
    description = "Handle a host snapshot control request";
    unitConfig.RequiresMountsFor = mountPoint;
    environment = commonEnvironment;
    serviceConfig = {
      StandardInput = "socket";
      StandardOutput = "socket";
      StandardError = "journal";
      ExecStart = lib.getExe snapshotControl;
      TimeoutStartSec = 90;
    };
  };
}
