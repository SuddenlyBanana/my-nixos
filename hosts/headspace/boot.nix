{ lib, pkgs, ... }:

{
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    initrd = {
      luks.devices.cryptroot = {
        device = "/dev/disk/by-partuuid/67cc14f5-22fd-44dc-8cfd-78091902bf39";
	allowDiscards = true;
      };
      availableKernelModules = [
        "xhci_pci"
        "ehci_pci"
        "ahci"
        "firewire_ohci"
        "usbhid"
        "usb_storage"
        "sd_mod"
        "sr_mod"
        "sdhci_pci"
      ];
    };
    kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;
    kernelModules = [ "kvm-intel" "b43" ];
    kernelParams = [ "video=LVDS-2:1440x900@59.90" ];
  };
}
