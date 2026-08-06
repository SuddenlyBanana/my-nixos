{ ... }:

{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/nvme0n1";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          type = "EF00";
          size = "1G";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "fmask=0022" "dmask=0022" ];
          };
        };
        luks = {
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            # Initial passphrase — used ONLY during install and as recovery.
            # nixos-anywhere prompts interactively if passwordFile is unset.                                                                         
            settings = {
              allowDiscards = true; # SSD trim
              bypassWorkqueues = true; # perf on NVMe
            };
            content = {
              type = "btrfs";
              extraArgs = [ "-L" "hadal" "-f" ];
              subvolumes = let
                zstd = [ "noatime" "compress=zstd" ];
                zstdNoCow = zstd ++ [ "nodatacow" "nodatasum" ];
              in {
                "@" = {
                  mountpoint = "/";
                  mountOptions = zstd;
                };
                "@home" = {
                  mountpoint = "/home";
                  mountOptions = zstd;
                };
                "@nix" = {
                  mountpoint = "/nix";
                  mountOptions = zstd;
                };
                "@srv" = {
                  mountpoint = "/srv";
                  mountOptions = zstd;
                };
                "@cache" = {
                  mountpoint = "/var/cache";
                  mountOptions = zstdNoCow;
                };
                "@tmp" = {
                  mountpoint = "/var/tmp";
                  mountOptions = zstdNoCow;
                };
                "@log" = {
                  mountpoint = "/var/log";
                  mountOptions = zstd;
                };
                "@containers" = {
                  mountpoint = "/var/lib/containers";
                  mountOptions = zstd;
                };
                "@images" = {
                  mountpoint = "/var/lib/libvirt/images";
                  mountOptions = zstd ++ [ "nodatacow" ];
                };
                "@swap" = {
                  mountpoint = "/swap";
                  mountOptions = [ "noatime" ];
                  swap.swapfile.size = "16G"; # or whatever
                };
              };
            };
          };
        };
      };
    };
  };
}
