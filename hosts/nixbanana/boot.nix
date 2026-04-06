{ lib, pkgs, ... }:

{
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    initrd.availableKernelModules = [ "xhci_pci" "ehci_pci" "ahci" "firewire_ohci" "usbhid" "usb_storage" "sd_mod" "sr_mod" "sdhci_pci" ];
    kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;
    kernelModules = [ "kvm-intel" "b43" ];
    kernelParams = [ ];
  };
}
