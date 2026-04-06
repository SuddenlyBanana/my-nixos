{ ... }:

{
  fileSystems."/" =
    { device = "/dev/disk/by-uuid/03658422-7b04-4745-815e-e64857d01627";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "subvol=@" ];
    };

  fileSystems."/home" =
    { device = "/dev/disk/by-uuid/03658422-7b04-4745-815e-e64857d01627";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "subvol=@home" ];
    };

  fileSystems."/nix" =
    { device = "/dev/disk/by-uuid/03658422-7b04-4745-815e-e64857d01627";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "subvol=@nix" ];
    };

  fileSystems."/srv" =
    { device = "/dev/disk/by-uuid/03658422-7b04-4745-815e-e64857d01627";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "subvol=@srv" ];
    };

  fileSystems."/var/cache" =
    { device = "/dev/disk/by-uuid/03658422-7b04-4745-815e-e64857d01627";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "nodatacow" "nodatasum" "subvol=@cache" ];
    };

  fileSystems."/var/tmp" =
    { device = "/dev/disk/by-uuid/03658422-7b04-4745-815e-e64857d01627";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "nodatacow" "nodatasum" "subvol=@tmp" ];
    };

  fileSystems."/var/log" =
    { device = "/dev/disk/by-uuid/03658422-7b04-4745-815e-e64857d01627";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "subvol=@log" ];
    };

  fileSystems."/swap" =
    { device = "/dev/disk/by-uuid/03658422-7b04-4745-815e-e64857d01627";
      fsType = "btrfs";
      options = [ "noatime" "nodatacow" "nodatasum" "subvol=@swap" ];
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/3E66-797B";
      fsType = "vfat";
      options = [ "fmask=0022" "dmask=0022" ];
    };

  swapDevices = [
    { device = "/swap/swapfile"; }
  ];
}
