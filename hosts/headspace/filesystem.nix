{ ... }:

{
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-uuid/03658422-7b04-4745-815e-e64857d01627";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "subvol=@" ];
    };

    "/home" = {
      device = "/dev/disk/by-uuid/03658422-7b04-4745-815e-e64857d01627";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "subvol=@home" ];
    };

    "/nix" = {
      device = "/dev/disk/by-uuid/03658422-7b04-4745-815e-e64857d01627";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "subvol=@nix" ];
    };

    "/srv" = {
      device = "/dev/disk/by-uuid/03658422-7b04-4745-815e-e64857d01627";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "subvol=@srv" ];
    };

    "/var/cache" = {
      device = "/dev/disk/by-uuid/03658422-7b04-4745-815e-e64857d01627";
      fsType = "btrfs";
      options =
        [ "noatime" "compress=zstd" "nodatacow" "nodatasum" "subvol=@cache" ];
    };

    "/var/tmp" = {
      device = "/dev/disk/by-uuid/03658422-7b04-4745-815e-e64857d01627";
      fsType = "btrfs";
      options =
        [ "noatime" "compress=zstd" "nodatacow" "nodatasum" "subvol=@tmp" ];
    };

    "/var/log" = {
      device = "/dev/disk/by-uuid/03658422-7b04-4745-815e-e64857d01627";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "subvol=@log" ];
    };

    "/swap" = {
      device = "/dev/disk/by-uuid/03658422-7b04-4745-815e-e64857d01627";
      fsType = "btrfs";
      options = [ "noatime" "nodatacow" "nodatasum" "subvol=@swap" ];
    };

    "/boot" = {
      device = "/dev/disk/by-uuid/3E66-797B";
      fsType = "vfat";
      options = [ "fmask=0022" "dmask=0022" ];
    };
  };

  swapDevices = [{ device = "/swap/swapfile"; }];
}
