{ lib, pkgs, ... }:

let
  # PCI vendor:device IDs
  vfioPciIds = [ "15b3:1015" ];
in {
  environment.systemPackages = [ pkgs.sbctl ];

  console.earlySetup = true;

  boot = {
    loader.efi.canTouchEfiVariables = true;

    lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
    };

    kernel.sysctl = {
      "net.ipv6.conf.br-lan.accept_ra" = 2;
      "net.ipv6.conf.br-lan.autoconf" = 1;
    };

    initrd = {
      systemd.enable = true;
      luks.devices.cryptroot.crypttabExtraOpts = [ "tpm2-device=auto" ];
      availableKernelModules =
        [ "xhci_pci" "nvme" "usb_storage" "usbhid" "sd_mod" ];
    };

    kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

    kernelModules =
      [ "kvm-intel" "kvm-amd" "vfio_pci" "vfio_iommu_type1" "vfio" ];

    kernelParams = [ "intel_iommu=on" "amd_iommu=on" "iommu=pt" ]
      ++ lib.optional (vfioPciIds != [ ])
      ("vfio-pci.ids=" + lib.concatStringsSep "," vfioPciIds);
  };
}
