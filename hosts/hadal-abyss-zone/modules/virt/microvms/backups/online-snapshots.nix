{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.hadal.backups;
  python = pkgs.python3.withPackages (p: [ p.psycopg ]);
  agent = mount: postgres: {
    systemd.sockets.hadal-backup-control = {
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "vsock::9100" ];
    };
    systemd.services.hadal-backup-control = {
      requires = lib.optional postgres "postgresql.service";
      after = lib.optional postgres "postgresql.service";
      path = [ pkgs.util-linux ];
      environment = {
        SNAPSHOT_MOUNT = mount;
        SNAPSHOT_POSTGRES = if postgres then "1" else "0";
      };
      serviceConfig = {
        ExecStart = "${python}/bin/python3 ${./snapshot-agent.py}";
        ExecStopPost = "-${pkgs.util-linux}/bin/fsfreeze --unfreeze ${mount}";
        Restart = "on-failure";
        RestartSec = "5s";
        UMask = "0077";
        TimeoutStopSec = "30s";
      };
    };
  };
in
{
  config = lib.mkIf (cfg.enable && cfg.onlineSnapshots.enable) {
    # The private Cloud Hypervisor VSOCK control plane is host-only. No root
    # freeze/unfreeze protocol or PostgreSQL backup control is exposed on IP.
    microvm.vms.postgresql.config = agent "/var/lib/postgresql" true;
    microvm.vms.rke2.config = agent "/var/lib/hadal-pv/vaultwarden" false;

    fileSystems."/mnt/hadal-backup" = {
      device = cfg.nfsDevice;
      fsType = "nfs4";
      options = [
        "nfsvers=4.2"
        "proto=tcp"
        "hard"
        "noauto"
        "nofail"
        "x-systemd.automount"
        "x-systemd.mount-timeout=30s"
      ];
    };
    systemd.services.hadal-online-backup = {
      description = "Stream matched online PostgreSQL and Vaultwarden filesystem snapshots to NAS";
      requires = [
        "microvm@postgresql.service"
        "microvm@rke2.service"
      ];
      after = [
        "microvm@postgresql.service"
        "microvm@rke2.service"
      ];
      unitConfig.RequiresMountsFor = "/mnt/hadal-backup";
      path = [
        pkgs.lvm2
        pkgs.partclone
        pkgs.restic
      ];
      environment = {
        CHECK_BACKUP_MOUNT = "${config.hadal.backups.mountCheck}/bin/check-hadal-backup-mount";
        RESTIC_REPOSITORY = "/mnt/hadal-backup/restic-vaultwarden-pair";
      };
      serviceConfig = {
        Type = "oneshot";
        UMask = "0077";
        RuntimeDirectory = "hadal-online-backup";
        RuntimeDirectoryMode = "0700";
        LoadCredential = [ "restic-password:/run/agenix/hadal-bootstrap-restic-password" ];
        ExecStart = "${python}/bin/python3 ${./snapshot-pair.py}";
        TimeoutStartSec = "6h";
      };
    };
    systemd.timers.hadal-online-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 04:00:00";
        Persistent = true;
      };
    };
  };
}
