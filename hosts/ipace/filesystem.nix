{ lib, ... }:

{
  # Match the SD image labels; /boot lives on the ext4 root partition.
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
      options = [ "noatime" ];
    };

    "/boot/firmware" = {
      device = "/dev/disk/by-label/FIRMWARE";
      fsType = "vfat";
      # The generic SD image adds noauto; firmware updates need this mounted.
      options = lib.mkForce [ "umask=0077" ];
    };
  };
}
