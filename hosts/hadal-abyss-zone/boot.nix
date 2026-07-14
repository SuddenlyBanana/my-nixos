{ lib, pkgs, ... }:

let
  # PCI vendor:device IDs of the SFP28 NIC ports to hand to the OpnSense VM.
  # Get with `lspci -nn | grep -i ethernet` on the host and fill in.
  vfioPciIds = [ "15b3:1015" ];
in {
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    initrd.availableKernelModules =
      [ "xhci_pci" "nvme" "usb_storage" "usbhid" "sd_mod" ];
    kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

    kernelModules =
      [ "kvm-intel" "kvm-amd" "vfio_pci" "vfio_iommu_type1" "vfio" ];

    kernelParams = [ "intel_iommu=on" "amd_iommu=on" "iommu=pt" ]
      ++ lib.optional (vfioPciIds != [ ])
      ("vfio-pci.ids=" + lib.concatStringsSep "," vfioPciIds);
  };
}
