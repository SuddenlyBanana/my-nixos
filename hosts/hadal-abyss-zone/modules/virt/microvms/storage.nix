{
  lib,
  pkgs,
  secrets,
  ...
}:

let
  serviceRoot = "/srv/media/services";
  openbaoBootstrapRoot = "/var/lib/openbao-recovery-bootstrap";
  openbaoAddress = "${secrets.privateIps.prefixes.homelabUla}:200::21";
  stateService = "microvm-service-storage.service";
  openbaoRecoveryTlsService = "openbao-recovery-tls-volumes.service";
  persistentServices = [ "openbao" ];

  verifyStorage = pkgs.writeShellApplication {
    name = "verify-microvm-service-storage";
    runtimeInputs = [
      pkgs.btrfs-progs
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = builtins.readFile ./scripts/verify-service-storage.sh;
  };

  generateOpenbaoRecoveryTlsVolumes = pkgs.writeShellApplication {
    name = "generate-openbao-recovery-tls-volumes";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.e2fsprogs
      pkgs.openssl
    ];
    text = builtins.readFile ./openbao/generate-recovery-certificate.sh;
  };

  storageDependencies = extraUnits: {
    requires = [ stateService ] ++ extraUnits;
    after = [ stateService ] ++ extraUnits;
    unitConfig = {
      RequiresMountsFor = "/srv/media";
      AssertPathIsMountPoint = "/srv/media";
    };
  };

  storageDependentUnits = {
    "microvm@postgresql" = storageDependencies [ openbaoRecoveryTlsService ];
    "microvm@openbao" = storageDependencies [ openbaoRecoveryTlsService ];
  };
in
{
  # This Btrfs subvolume contains only temporary bootstrap trust volumes.
  # Persistent service state lives on the raw LVM-thin devices configured by
  # the individual MicroVM modules.
  systemd.tmpfiles.settings."05-microvm-service-storage" = {
    "${serviceRoot}/openbao".v = {
      user = "root";
      group = "kvm";
      mode = "0770";
    };
    "${openbaoBootstrapRoot}".d = {
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
      before = [
        openbaoRecoveryTlsService
      ];
      unitConfig = {
        RequiresMountsFor = "/srv/media";
        AssertPathIsMountPoint = "/srv/media";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe verifyStorage} ${
          lib.escapeShellArgs (map (name: "${serviceRoot}/${name}") persistentServices)
        }";
      };
    };

    openbao-recovery-tls-volumes = {
      description = "Provision the OpenBao recovery TLS trust anchor";
      requires = [ stateService ];
      after = [ stateService ];
      environment = {
        OPENBAO_ADDRESS = openbaoAddress;
        OPENBAO_DNS_NAME = "openbao.home.arpa";
        OPENBAO_RECOVERY_DIR = openbaoBootstrapRoot;
        OPENBAO_RECOVERY_IMAGE = "${serviceRoot}/openbao/recovery-tls.raw";
        OPENBAO_CA_IMAGE = "${serviceRoot}/openbao/ca.raw";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        ExecStart = lib.getExe generateOpenbaoRecoveryTlsVolumes;
      };
    };

  }
  // storageDependentUnits;
}
