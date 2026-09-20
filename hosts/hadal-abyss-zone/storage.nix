{ ... }:

{
  disko.devices.disk = {
    media-2tb = {
      type = "disk";
      device = "/dev/disk/by-id/wwn-0x5000c50065b35f96";
      content.type = "gpt";
      content.partitions.bcache.size = "100%";
    };

    media-1tb-a = {
      type = "disk";
      device = "/dev/disk/by-id/wwn-0x5000c5002d4b2546";
      content.type = "gpt";
      content.partitions.bcache.size = "100%";
    };

    media-1tb-b = {
      type = "disk";
      device = "/dev/disk/by-id/wwn-0x50024e9204309cb2";
      content.type = "gpt";
      content.partitions.bcache.size = "100%";
    };

    media-cache = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-eui.0025388191be451d";
      content.type = "gpt";
      content.partitions.bcache.size = "100%";
    };
  };

  environment.etc."crypttab".source = ./crypttab;

  fileSystems."/srv/media" = {
    device = "/dev/mapper/media0";
    fsType = "btrfs";
    options = [
      "noatime"
      "compress=zstd:3"
      "device=/dev/mapper/media1"
      "device=/dev/mapper/media2"
      "x-systemd.requires=systemd-cryptsetup@media0.service"
      "x-systemd.requires=systemd-cryptsetup@media1.service"
      "x-systemd.requires=systemd-cryptsetup@media2.service"
      "x-systemd.device-timeout=120s"
    ];
  };
}
