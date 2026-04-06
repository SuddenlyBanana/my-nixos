{ config, pkgs, ... }:

{
  boot.kernelPackages = pkgs.linuxPackages_6_6;

  hardware.nvidia = {
      modesetting.enable = true;
      prime = {
        nvidiaBusId = "PCI:0@1:0:0";
        intelBusId = "PCI:1@0:2:0";
      };

      package = config.boot.kernelPackages.nvidiaPackages.legacy_470;
  };

  services.xserver.videoDrivers = [ "modesetting" ];
}
