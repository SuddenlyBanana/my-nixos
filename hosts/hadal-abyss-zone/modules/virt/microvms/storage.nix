{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

let
  serviceRoot = "/srv/media/services";
  snapshotRoot = "/srv/media/.snapshots/microvms";
  postgresAddress = "${secrets.privateIps.prefixes.homelabUla}:209::10";
  vaultwardenAddress = "${secrets.privateIps.prefixes.homelabUla}:209::11";
  stateService = "microvm-service-storage.service";
  credentialService = "vaultwarden-postgresql-credentials.service";
  tlsService = "postgresql-tls-volumes.service";
  persistentServices = [
    "postgresql"
    "vaultwarden"
  ];

  verifyStorage = pkgs.writeShellApplication {
    name = "verify-microvm-service-storage";
    runtimeInputs = [
      pkgs.btrfs-progs
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = builtins.readFile ./scripts/verify-service-storage.sh;
  };

  generateCredentials = pkgs.writeShellApplication {
    name = "generate-vaultwarden-postgresql-credentials";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.e2fsprogs
      pkgs.openssl
    ];
    text = builtins.readFile ./scripts/generate-vaultwarden-credentials.sh;
  };

  generateTlsVolumes = pkgs.writeShellApplication {
    name = "generate-postgresql-tls-volumes";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.e2fsprogs
      pkgs.openssl
    ];
    text = builtins.readFile ./postgresql/generate-certificate.sh;
  };

  snapshotServices = pkgs.writeShellApplication {
    name = "snapshot-microvm-services";
    runtimeInputs = [
      pkgs.btrfs-progs
      pkgs.coreutils
      pkgs.findutils
      pkgs.netcat-openbsd
      pkgs.systemd
    ];
    text = builtins.readFile ./scripts/snapshot-services.sh;
  };

  storageDependentUnits = lib.genAttrs (map (name: "microvm@${name}") persistentServices) (_: {
    requires = [
      stateService
      credentialService
      tlsService
    ];
    after = [
      stateService
      credentialService
      tlsService
    ];
    unitConfig = {
      RequiresMountsFor = "/srv/media";
      AssertPathIsMountPoint = "/srv/media";
    };
  });
in
{
  # The `v` entries are real Btrfs subvolumes. The early file name makes sure
  # they exist before the MicroVM services create their raw volume images.
  systemd.tmpfiles.settings."05-microvm-service-storage" = {
    "${serviceRoot}/postgresql".v = {
      user = "root";
      group = "kvm";
      mode = "0770";
    };
    "${serviceRoot}/vaultwarden".v = {
      user = "root";
      group = "kvm";
      mode = "0770";
    };
    "${serviceRoot}/postgresql/tls".d = {
      user = "root";
      group = "root";
      mode = "0700";
    };
    "${serviceRoot}/vaultwarden/credentials".d = {
      user = "root";
      group = "root";
      mode = "0700";
    };
    "${snapshotRoot}/postgresql".d = {
      user = "root";
      group = "root";
      mode = "0700";
    };
    "${snapshotRoot}/vaultwarden".d = {
      user = "root";
      group = "root";
      mode = "0700";
    };
  };

  systemd.services = {
    microvm-service-storage = {
      description = "Verify persistent MicroVM Btrfs subvolumes";
      requires = [ "srv-media.mount" ];
      after = [
        "srv-media.mount"
        "systemd-tmpfiles-setup.service"
      ];
      before = [ credentialService ];
      unitConfig = {
        RequiresMountsFor = "/srv/media";
        AssertPathIsMountPoint = "/srv/media";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe verifyStorage} ${serviceRoot}/postgresql ${serviceRoot}/vaultwarden";
      };
    };

    vaultwarden-postgresql-credentials = {
      description = "Provision the Vaultwarden PostgreSQL client credential";
      requires = [ stateService ];
      after = [ stateService ];
      environment = {
        CREDENTIAL_DIR = "${serviceRoot}/vaultwarden/credentials";
        CREDENTIAL_IMAGE = "${serviceRoot}/vaultwarden/credentials.raw";
        POSTGRES_ADDRESS = postgresAddress;
        POSTGRES_CA = "/etc/postgresql-ca/ca.crt";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        ExecStart = lib.getExe generateCredentials;
      };
    };

    postgresql-tls-volumes = {
      description = "Provision PostgreSQL TLS material as read-only volumes";
      requires = [ stateService ];
      after = [ stateService ];
      environment = {
        POSTGRES_ADDRESS = postgresAddress;
        POSTGRES_DNS_NAME = "postgres.home.arpa";
        POSTGRES_TLS_DIR = "${serviceRoot}/postgresql/tls";
        POSTGRES_TLS_IMAGE = "${serviceRoot}/postgresql/tls.raw";
        POSTGRES_CA_IMAGE = "${serviceRoot}/postgresql/ca.raw";
        POSTGRES_UID = toString config.ids.uids.postgres;
        POSTGRES_GID = toString config.ids.gids.postgres;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        ExecStart = lib.getExe generateTlsVolumes;
      };
    };

    snapshot-microvm-services = {
      description = "Freeze and snapshot persistent MicroVM service subvolumes";
      requires = [ stateService ];
      after = [ stateService ];
      environment = {
        SERVICE_ROOT = serviceRoot;
        SNAPSHOT_ROOT = snapshotRoot;
        RETENTION_DAYS = "14";
        FREEZE_TIMEOUT = "90";
        CONTROL_PORT = "9100";
      };
      unitConfig = {
        RequiresMountsFor = "/srv/media";
        AssertPathIsMountPoint = "/srv/media";
      };
      serviceConfig = {
        Type = "oneshot";
        UMask = "0077";
        Nice = 10;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 7;
        ExecStart = "${lib.getExe snapshotServices} vaultwarden@${vaultwardenAddress} postgresql@${postgresAddress}";
      };
    };
  }
  // storageDependentUnits;

  systemd.timers.snapshot-microvm-services = {
    description = "Daily persistent MicroVM snapshots";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:15:00";
      RandomizedDelaySec = "20m";
      Persistent = true;
      Unit = "snapshot-microvm-services.service";
    };
  };
}
