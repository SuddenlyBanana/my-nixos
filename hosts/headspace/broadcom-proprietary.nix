{ config, ... }:

{
  boot = {
    extraModulePackages = [
      (config.boot.kernelPackages.broadcom_sta.overrideAttrs (old: {
        # Backport the patches missing from nixpkgs' release 59. Source:
        # https://github.com/rpmfusion/wl-kmod/tree/5156986093f0f12ed04fe913b0a2f9e996c24274
        patches = old.patches ++ [
          ./patches/wl-kmod-036_kernel_7.1_adaptation_replace_net_device_struct_with_wireless_dev_struct.patch
          ./patches/wl-kmod-037_kernel_6.13_remove_flush_scheduled_work.patch
          ./patches/wl-kmod-038_kernel_7.2_adaptation_remove_strncpy_function.patch
        ];
      }))
    ];
    kernelModules = [ "wl" ];
    blacklistedKernelModules = [
      "b43"
      "b43legacy"
      "ssb"
      "bcma"
      "bcm43xx"
      "brcm80211"
      "brcmfmac"
      "brcmsmac"
    ];
  };
}
