{ config, ... }:

{
  boot = {
    extraModulePackages = [ config.boot.kernelPackages.broadcom_sta ];
    kernelModules = [ "wl" ];
    blacklistedKernelModules = [
      "b43"
      "b43legacy"
      "ssb"
      "bcm43xx"
      "brcm80211"
      "brcmfmac"
      "brcmsmac"
    ];
  };
}
