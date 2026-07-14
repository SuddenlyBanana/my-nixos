{ ... }:

{
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-uuid/0bcee23e-1305-41d9-98f0-740b0d4ef0c1";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "subvol=@" ];
    };

    "/home" = {
      device = "/dev/disk/by-uuid/0bcee23e-1305-41d9-98f0-740b0d4ef0c1";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "subvol=@home" ];
    };

    "/nix" = {
      device = "/dev/disk/by-uuid/0bcee23e-1305-41d9-98f0-740b0d4ef0c1";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "subvol=@nix" ];
    };

    "/srv" = {
      device = "/dev/disk/by-uuid/0bcee23e-1305-41d9-98f0-740b0d4ef0c1";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "subvol=@srv" ];
    };

    "/var/cache" = {
      device = "/dev/disk/by-uuid/0bcee23e-1305-41d9-98f0-740b0d4ef0c1";
      fsType = "btrfs";
      options =
        [ "noatime" "compress=zstd" "nodatacow" "nodatasum" "subvol=@cache" ];
    };

    "/var/tmp" = {
      device = "/dev/disk/by-uuid/0bcee23e-1305-41d9-98f0-740b0d4ef0c1";
      fsType = "btrfs";
      options =
        [ "noatime" "compress=zstd" "nodatacow" "nodatasum" "subvol=@tmp" ];
    };

    "/var/log" = {
      device = "/dev/disk/by-uuid/0bcee23e-1305-41d9-98f0-740b0d4ef0c1";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "subvol=@log" ];
    };

    "/var/lib/containers" = {
      device = "/dev/disk/by-uuid/0bcee23e-1305-41d9-98f0-740b0d4ef0c1";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "subvol=@containers" ];
    };

    "/var/lib/libvirt/images" = {
      device = "/dev/disk/by-uuid/0bcee23e-1305-41d9-98f0-740b0d4ef0c1";
      fsType = "btrfs";
      options = [ "noatime" "compress=zstd" "nodatacow" "subvol=@images" ];
    };

    "/swap" = {
      device = "/dev/disk/by-uuid/0bcee23e-1305-41d9-98f0-740b0d4ef0c1";
      fsType = "btrfs";
      options = [ "noatime" "nodatacow" "nodatasum" "subvol=@swap" ];
    };

    "/boot" = {
      device = "/dev/disk/by-uuid/B7BF-0896";
      fsType = "vfat";
      options = [ "fmask=0022" "dmask=0022" ];
    };
  };

  swapDevices = [{ device = "/swap/swapfile"; }];
}
