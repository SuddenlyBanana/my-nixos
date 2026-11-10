{
  config,
  lib,
  pkgs,
  ...
}:
let
  format = pkgs.writeShellApplication {
    name = "format-hadal-guest-storage";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
      pkgs.xfsprogs
    ];
    text = builtins.readFile ./scripts/format-guest-storage.sh;
  };
in
{
  # An explicit provisioning tool: never autostarted and never imported into
  # the application guests. Formatting happens inside this guest, off-line.
  microvm.vms.storage-format = {
    autostart = false;
    config = {
      microvm = {
        hypervisor = "cloud-hypervisor";
        mem = 1024;
        vcpu = 1;
        storeOnDisk = true;
        vsock.cid = 23;
        shares = [ ];
        volumes =
          map
            (image: {
              inherit image;
              mountPoint = null;
              autoCreate = false;
              direct = true;
              size = 1;
            })
            [
              config.hadal.microvms.rke2.stateDevice
              config.hadal.microvms.postgresql.dataDevice
              config.hadal.microvms.openbao.dataDevice
              config.hadal.microvms.rke2.vaultwardenDevice
            ];
      };
      systemd.services.format-guest-storage = {
        wantedBy = [ "multi-user.target" ];
        unitConfig.OnSuccess = "poweroff.target";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe format;
        };

      };
      system.stateVersion = "26.05";
    };
  };
  systemd.services."microvm@storage-format" = {
    requires = [ "hadal-vm-storage.service" ];
    serviceConfig = {
      Type = lib.mkForce "exec";
      Restart = lib.mkForce "no";
    };
    after = [
      "hadal-vm-storage.service"
    ]
    ++ map (name: "microvm@${name}.service") [
      "openbao"
      "postgresql"
      "rke2"
    ];
    conflicts = map (name: "microvm@${name}.service") [
      "openbao"
      "postgresql"
      "rke2"
    ];
  };
}
