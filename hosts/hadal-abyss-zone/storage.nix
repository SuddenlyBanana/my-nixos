{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  automatic = config.hadal.storage.automaticActivation;
  checkHealth = pkgs.writeShellApplication {
    name = "check-hadal-storage-health";
    runtimeInputs = [
      pkgs.lvm2
      pkgs.jq
    ];
    text = builtins.readFile ./storage/check-health.sh;
  };
  activate = pkgs.writeShellApplication {
    name = "activate-hadal-vm-storage";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.lvm2
      pkgs.util-linux
    ];
    text = builtins.readFile ./storage/activate-vm-storage.sh;
  };
  register = pkgs.writeShellApplication {
    name = "activate-hadal-bcache";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.bcache-tools
      pkgs.gawk
      pkgs.systemd
      pkgs.util-linux
    ];
    text = builtins.readFile ./storage/activate-bcache.sh;
  };
  cryptUnit = name: "systemd-cryptsetup@${utils.escapeSystemdPath name}";

  cryptUnits = map (name: "${cryptUnit name}.service") [
    "hadal-vm-a"
    "hadal-vm-b"
    "hadal-vm-cache"
  ];
  lvNames = [
    "rke2-state"
    "postgresql-data"
    "openbao-data"
    "vaultwarden-data"
  ];
in
{
  options.hadal.storage.automaticActivation = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Automatically open/mount the new VM and media storage at boot. Disable only for explicit provisioning.";
  };

  config = {
    systemd.services.hadal-storage-health = {
      description = "Check VM RAID and thin-pool capacity thresholds";
      requires = [ "hadal-vm-storage.service" ];
      after = [ "hadal-vm-storage.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe checkHealth;
      };
    };
    systemd.timers.hadal-storage-health = lib.mkIf automatic {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitActiveSec = "5min";
      };
    };
    # Provisioning is explicit: ordinary NixOS activation never reformats disks.
    disko.devices.disk = {
      media-1tb-a = {
        type = "disk";
        device = "/dev/disk/by-id/wwn-0x5000c5002d4b2546";
        content = {
          type = "gpt";
          partitions.hadal-vm-a = {
            label = "hadal-vm-a";
            size = "930G";
            type = "8309";
          };
        };
      };
      media-2tb = {
        type = "disk";
        device = "/dev/disk/by-id/wwn-0x5000c50065b35f96";
        content = {
          type = "gpt";
          partitions = {
            hadal-vm-b = {
              label = "hadal-vm-b";
              size = "930G";
              type = "8309";
              priority = 1;
            };
            hadal-media-b = {
              label = "hadal-media-b";
              size = "100%";
              priority = 2;
            };
          };
        };
      };
      media-1tb-b = {
        type = "disk";
        device = "/dev/disk/by-id/wwn-0x50024e9204309cb2";
        content = {
          type = "gpt";
          partitions.hadal-media-a = {
            label = "hadal-media-a";
            size = "930G";
          };
        };
      };
      media-cache = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-eui.0025388191be451d";
        content = {
          type = "gpt";
          partitions = {
            hadal-vm-cache = {
              label = "hadal-vm-cache";
              size = "96G";
              type = "8309";
              priority = 1;
            };
            hadal-media-cache = {
              label = "hadal-media-cache";
              size = "100%";
              priority = 2;
            };
          };
        };
      };
    };

    environment.etc."crypttab".source =
      if automatic then
        ./crypttab
      else
        pkgs.writeText "hadal-manual-crypttab" (
          lib.replaceStrings [ "luks," ] [ "luks,noauto," ] (builtins.readFile ./crypttab)
        );
    environment.etc."lvm/profile.d/hadal-thin.profile".source = ./storage/hadal-thin.profile;
    boot.kernelModules = [
      "bcache"
      "dm-raid"
      "raid1"
      "dm-cache"
      "dm-cache-smq"
      "dm-thin-pool"
    ];
    services.lvm = {
      enable = true;
      dmeventd.enable = true;
      boot.thin.enable = true;
    };
    environment.systemPackages = with pkgs; [
      bcache-tools
      cryptsetup
      xfsprogs
      btrfs-progs
    ];
    services.udev.extraRules = lib.concatMapStringsSep "\n" (
      name:
      ''SUBSYSTEM=="block", ENV{DM_VG_NAME}=="hadal-vm", ENV{DM_LV_NAME}=="${name}", GROUP="kvm", MODE="0660"''
    ) lvNames;

    systemd.services.hadal-vm-storage = {
      description = "Activate and validate mirrored cached VM thin storage";
      requires = cryptUnits;
      after = cryptUnits ++ [ "lvm2-monitor.service" ];
      wantedBy = lib.optional automatic "multi-user.target";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe activate;
      };
    };
    systemd.services.${cryptUnit "hadal-vm-a"} = {
      after = [ "agenix-install-secrets.service" ];
      overrideStrategy = "asDropin";
    };

    systemd.services.${cryptUnit "hadal-vm-b"} = {
      after = [ "agenix-install-secrets.service" ];
      overrideStrategy = "asDropin";
    };

    systemd.services.${cryptUnit "hadal-vm-cache"} = {
      after = [ "agenix-install-secrets.service" ];
      overrideStrategy = "asDropin";
    };
    systemd.services.hadal-bcache = {
      description = "Register the two media backing devices and their writeback cache";
      wantedBy = lib.optional automatic "multi-user.target";
      wants = [ "systemd-udev-settle.service" ];
      after = [
        "systemd-udev-settle.service"
        "systemd-modules-load.service"
      ];
      before = [
        "cryptsetup.target"
        "shutdown.target"
      ];
      conflicts = [ "shutdown.target" ];
      # cryptsetup@media* must run before sysinit; ordinary service defaults
      # would order registration after sysinit and create a boot cycle.
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe register;
        TimeoutStartSec = "120s";
      };
    };
    systemd.services."systemd-cryptsetup@media0" = {
      requires = [ "hadal-bcache.service" ];
      after = [
        "hadal-bcache.service"
        "agenix-install-secrets.service"
      ];
      overrideStrategy = "asDropin";
    };
    systemd.services."systemd-cryptsetup@media1" = {
      requires = [ "hadal-bcache.service" ];
      after = [
        "hadal-bcache.service"
        "agenix-install-secrets.service"
      ];
      overrideStrategy = "asDropin";
    };
    fileSystems."/srv/media" = {
      device = "/dev/mapper/media0";
      fsType = "btrfs";
      options =
        lib.optionals (!automatic) [
          "noauto"
          "nofail"
        ]
        ++ [
          "noatime"
          "compress=zstd:3"
          "device=/dev/mapper/media1"
          "x-systemd.requires=systemd-cryptsetup@media0.service"
          "x-systemd.requires=systemd-cryptsetup@media1.service"
          "x-systemd.device-timeout=120s"
        ];
    };
  };
}
