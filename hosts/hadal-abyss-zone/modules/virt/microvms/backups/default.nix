{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

let
  cfg = config.hadal.backups;
  topology = import ../topology.nix { inherit secrets; };
  mount = "/mnt/hadal-backup";
  checkMount = pkgs.writeShellApplication {
    name = "check-hadal-backup-mount";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
      pkgs.gnugrep
    ];
    runtimeEnv = {
      BACKUP_MOUNT = mount;
      EXPECTED_NFS_DEVICE = cfg.nfsDevice;
    };
    text = builtins.readFile ./check-mount.sh;
  };
  pgbackrest = pkgs.writeShellApplication {
    name = "hadal-pgbackrest";
    runtimeInputs = [ pkgs.coreutils ];
    runtimeEnv = {
      PGBACKREST_BINARY = lib.getExe pkgs.pgbackrest;
      CHECK_BACKUP_MOUNT = lib.getExe checkMount;
    };
    text = builtins.readFile ./pgbackrest.sh;
  };
  common = {
    fileSystems.${mount} = {
      device = cfg.nfsDevice;
      fsType = "nfs4";
      options = [
        "nfsvers=4.2"
        "proto=tcp"
        "hard"
        "noauto"
        "nofail"
        "x-systemd.automount"
        "x-systemd.idle-timeout=600"
        "x-systemd.mount-timeout=30s"
      ];
    };
    environment.systemPackages = [
      checkMount
      pkgs.restic
      pkgs.nfs-utils
    ];
    boot.supportedFilesystems = [ "nfs" ];
  };
  resticJob = name: paths: {
    services.restic.backups.${name} = {
      repository = "${mount}/restic-${name}";
      passwordFile = "/run/hadal-bootstrap/restic-password";
      initialize = false;
      inherit paths;
      pruneOpts = [
        "--keep-daily 14"
        "--keep-weekly 8"
        "--keep-monthly 12"
      ];
      timerConfig = {
        OnCalendar = "*-*-* 03:30:00";
        Persistent = true;
      };
      backupPrepareCommand = lib.mkDefault (lib.getExe checkMount);
      checkOpts = [ "--read-data-subset=5%" ];
    };
    # The module's check and backup/prune share the mount guard. No plaintext
    # fallback repository can be created under an absent NAS mount.
    systemd.services."restic-backups-${name}".unitConfig.RequiresMountsFor = mount;
  };
in
{
  imports = [ ./online-snapshots.nix ];

  options.hadal.backups = {
    mountCheck = lib.mkOption {
      type = lib.types.package;
      internal = true;
      readOnly = true;
      default = checkMount;
    };
    enable = lib.mkEnableOption "encrypted native backups to the NFS NAS";
    onlineSnapshots.enable = lib.mkEnableOption "matched online filesystem snapshots after recovery/retention validation";
    nasAddress = lib.mkOption {
      type = lib.types.str;
      default = "REPLACE_WITH_NAS_IPV6";
      description = "Raw NAS IPv6 for narrow guest routes and TCP/2049 firewall permissions.";
    };
    nfsDevice = lib.mkOption {
      type = lib.types.str;
      default = "[REPLACE_WITH_NAS_IPV6]:/REPLACE_WITH_NFS_EXPORT";
      description = "NFSv4 export; keep disabled until the NAS and independent encryption-key recovery are ready.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          !(lib.hasInfix "REPLACE_WITH" cfg.nasAddress || lib.hasInfix "REPLACE_WITH" cfg.nfsDevice)
          && lib.hasInfix ":" cfg.nasAddress
          && lib.hasPrefix "[" cfg.nfsDevice;
        message = "Set hadal.backups.nasAddress and bracketed IPv6 nfsDevice before enabling NAS backups.";
      }
    ];

    networking.firewall.extraForwardRules = ''
      iifname "br-db" oifname "br-lan" \
        ip6 saddr { ${topology.infrastructure.postgresqlAddress}, ${topology.infrastructure.openbaoAddress} } \
        ip6 daddr ${cfg.nasAddress} tcp dport 2049 accept comment "infrastructure backups to NAS"
    '';

    microvm.vms.postgresql.config = { config, lib, ... }: {
      imports = [ common ];
      systemd.network.networks."20-primary".routes = [
        {
          Destination = "${cfg.nasAddress}/128";
          Gateway = topology.infrastructure.hostAddress;
        }
      ];
      environment.systemPackages = [ pgbackrest ];
      services.pgbackrest = {
        enable = true;
        repos.localhost = {
          path = "${mount}/pgbackrest";
          cipher-type = "aes-256-cbc";
          retention-full = 4;
          retention-diff = 14;
        };
        settings = {
          process-max = 2;
          start-fast = true;
        };
        stanzas.default.jobs = {
          weekly = {
            schedule = "Sun *-*-* 02:00:00";
            type = "full";
          };
          daily = {
            schedule = "Mon..Sat *-*-* 02:00:00";
            type = "diff";
          };
        };
      };
      users.users.pgbackrest.createHome = lib.mkForce false;
      services.postgresql.settings = {
        archive_mode = "on";
        archive_timeout = "60s";
        archive_command = lib.mkForce ''${lib.getExe pgbackrest} --stanza=default archive-push "%p"'';
      };
      systemd.services = {
        postgresql.serviceConfig.LoadCredential = [
          "pgbackrest-pass:/run/hadal-bootstrap/pgbackrest-pass"
        ];
      }
      // lib.genAttrs [ "pgbackrest-default-weekly" "pgbackrest-default-daily" ] (unit: {
        unitConfig.RequiresMountsFor = mount;
        after = [ "postgresql.service" ];
        requires = [ "postgresql.service" ];
        serviceConfig = {
          User = lib.mkForce "postgres";
          Group = lib.mkForce "postgres";
          LoadCredential = [ "pgbackrest-pass:/run/hadal-bootstrap/pgbackrest-pass" ];
          ExecStartPre = lib.mkForce "${lib.getExe pgbackrest} --stanza=default stanza-create";
          ExecStart = lib.mkForce "${lib.getExe pgbackrest} --stanza=default --type=${
            if lib.hasSuffix "weekly" unit then "full" else "diff"
          } backup";
        };
      });
    };

    microvm.vms.openbao.config = {
      imports = [
        common
        (resticJob "openbao" [ "/run/restic-backups-openbao/raft.snap" ])
      ];
      systemd.network.networks."20-primary".routes = [
        {
          Destination = "${cfg.nasAddress}/128";
          Gateway = topology.infrastructure.hostAddress;
        }
      ];
      services.restic.backups.openbao = {
        backupPrepareCommand = ''
          set -euo pipefail
          ${lib.getExe checkMount}
          ${lib.getExe pkgs.bash} ${./openbao-snapshot.sh}
        '';
        backupCleanupCommand = "${pkgs.coreutils}/bin/rm -f /run/restic-backups-openbao/raft.snap";
        extraBackupArgs = [ "--tag openbao-raft" ];
      };
      systemd.services.restic-backups-openbao = {
        path = [
          pkgs.openbao
          pkgs.jq
          pkgs.coreutils
        ];
        environment = {
          BAO_ADDR = "https://[::1]:8202";
          BAO_TLS_SERVER_NAME = "openbao.infra.windows.moe";
          BAO_CACERT = "/run/hadal-bootstrap/ca.crt";
        };
        serviceConfig = {
          RuntimeDirectoryMode = "0700";
          LoadCredential = [
            "role-id:/run/hadal-bootstrap/backup-role-id"
            "secret-id:/run/hadal-bootstrap/backup-secret-id"
          ];
        };
      };
    };

    microvm.vms.rke2.config = { config, ... }: {
      imports = [
        common
        (resticJob "rke2" [
          "/var/lib/rancher/rke2/server/db/snapshots"
          "/var/lib/rancher/rke2/server/token"
          "/etc/rancher/rke2"
        ])
      ];
      services.restic.backups.rke2.backupPrepareCommand = ''
        set -euo pipefail
        ${lib.getExe checkMount}
        ${lib.getExe config.services.rke2.package} etcd-snapshot save --name=offhost
      '';
    };
  };
}
